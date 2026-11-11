// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit
import CommonCrypto
import Security
import KasaKit

/// Account-derived protocol keys. The email and password are discarded after derivation.
/// These keys still grant local access and must only be persisted in Keychain.
public struct KasaCredentials: Codable, Sendable {
    let v1: Data
    let v2: Data

    public init(email: String, password: String) {
        let user = Data(email.utf8), secret = Data(password.utf8)
        v1 = Data(Insecure.MD5.hash(data: Data(Insecure.MD5.hash(data: user)) + Data(Insecure.MD5.hash(data: secret))))
        v2 = KasaCrypto.sha256(Data(Insecure.SHA1.hash(data: user)) + Data(Insecure.SHA1.hash(data: secret)))
    }
}

enum KasaCrypto {
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// The current discovery probe advertises an ephemeral RSA public key. IOT
    /// devices expose their transport metadata outside the encrypted payload; we
    /// do not need or retain the optional encrypted setup information.
    static func discoveryProbe() throws -> Data {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                        kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let exported = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw KasaError.unavailable
        }
        func der(_ tag: UInt8, _ body: Data) -> Data {
            var length = Data()
            if body.count < 128 { length.append(UInt8(body.count)) }
            else { length.append(contentsOf: [0x82, UInt8(body.count >> 8), UInt8(body.count & 255)]) }
            return Data([tag]) + length + body
        }
        let algorithm = Data([0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00])
        let spki = der(0x30, algorithm + der(0x03, Data([0]) + exported))
        let pem = "-----BEGIN PUBLIC KEY-----\n" + spki.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END PUBLIC KEY-----\n"
        let body = try JSONSerialization.data(withJSONObject: ["params": ["rsa_key": pem]], options: .sortedKeys)
        guard body.count <= 65535 else { throw KasaError.invalidResponse }
        var header = Data([2,0,0,1,UInt8(body.count >> 8),UInt8(body.count & 255),17,0])
        header.append(try randomSeed().prefix(4))
        header.append(contentsOf: [0x5a,0x6b,0x7c,0x8d])
        var packet = header + body
        var crc: UInt32 = 0xffff_ffff
        for byte in packet {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        packet.replaceSubrange(12..<16, with: bigEndian(crc ^ 0xffff_ffff))
        return packet
    }

    static func randomSeed() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KasaError.unavailable
        }
        return Data(bytes)
    }

    static func xorEncode(_ data: Data) -> Data {
        var previous: UInt8 = 0xab
        return Data(data.map { byte in previous ^= byte; return previous })
    }

    static func xorDecode(_ data: Data) -> Data {
        var previous: UInt8 = 0xab
        return Data(data.map { byte in let plain = previous ^ byte; previous = byte; return plain })
    }

    static func bigEndian(_ number: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: number >> 24), UInt8(truncatingIfNeeded: number >> 16),
              UInt8(truncatingIfNeeded: number >> 8), UInt8(truncatingIfNeeded: number)])
    }

    static func number(_ data: Data) throws -> UInt32 {
        guard data.count == 4 else { throw KasaError.invalidResponse }
        return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func aes(_ data: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        guard key.count == 16, iv.count == 16, data.count <= KasaCoding.limit else {
            throw KasaError.invalidResponse
        }
        let capacity = data.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: capacity)
        var length = 0
        let result = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                data.withUnsafeBytes { input in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress, input.baseAddress, data.count, &output, capacity, &length)
                }
            }
        }
        guard result == kCCSuccess else { throw KasaError.invalidResponse }
        return Data(output.prefix(length))
    }
}

struct KasaCipher {
    let key: Data
    let iv: Data
    let signatureKey: Data
    var sequence: UInt32

    init(local: Data, remote: Data, auth: Data) throws {
        guard local.count == 16, remote.count == 16, [16,32].contains(auth.count) else { throw KasaError.invalidResponse }
        let seeds = local + remote + auth
        key = Data(KasaCrypto.sha256(Data("lsk".utf8) + seeds).prefix(16))
        let fullIV = KasaCrypto.sha256(Data("iv".utf8) + seeds)
        iv = Data(fullIV.prefix(12))
        sequence = try KasaCrypto.number(Data(fullIV.suffix(4)))
        signatureKey = Data(KasaCrypto.sha256(Data("ldk".utf8) + seeds).prefix(28))
    }

    mutating func seal(_ data: Data) throws -> Data {
        sequence &+= 1
        let counter = KasaCrypto.bigEndian(sequence)
        let ciphertext = try KasaCrypto.aes(data, key: key, iv: iv + counter, encrypt: true)
        return KasaCrypto.sha256(signatureKey + counter + ciphertext) + ciphertext
    }

    func open(_ data: Data) throws -> Data {
        guard data.count >= 48 else { throw KasaError.invalidResponse }
        let ciphertext = Data(data.dropFirst(32)), counter = KasaCrypto.bigEndian(sequence)
        guard KasaCrypto.equal(Data(data.prefix(32)), KasaCrypto.sha256(signatureKey + counter + ciphertext)) else {
            throw KasaError.invalidResponse
        }
        return try KasaCrypto.aes(ciphertext, key: key, iv: iv + counter, encrypt: false)
    }
}

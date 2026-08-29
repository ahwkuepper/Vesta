// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit
import Security

/// Certificate pinning shared by pairing and the transport.
enum BridgePinning {

    /// SHA-256 over the certificate's public key (SPKI), not the whole certificate.
    ///
    /// Hashing the certificate itself would break on renewal even though the bridge
    /// and its key are unchanged; the key survives that.
    static func publicKeyHash(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            return nil
        }
        return Data(SHA256.hash(data: data))
    }

    /// The leaf certificate a server presented.
    static func leafCertificate(from trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }

    /// Whether a presented certificate is the bridge we paired with.
    ///
    /// The common name must still match the bridge ID, but that is a cheap
    /// pre-filter rather than the decision: it is public information and forgeable
    /// by anyone on the network. The key hash is what settles it.
    static func matches(certificate: SecCertificate,
                        bridgeID: String,
                        expectedKeyHash: Data?) -> Bool {
        var commonName: CFString?
        SecCertificateCopyCommonName(certificate, &commonName)
        let name = (commonName as String?)?.lowercased() ?? ""
        guard !name.isEmpty, name == bridgeID.lowercased() else { return false }

        // No hash stored: credentials predate pinning. The name check is all that is
        // available, and the transport re-pins on success so this happens once.
        guard let expectedKeyHash else { return true }

        guard let presented = publicKeyHash(of: certificate) else { return false }
        return hashesMatch(presented: presented, expected: expectedKeyHash)
    }

    /// Constant-time comparison: this checks attacker-supplied input against a
    /// stored value, so it must not leak how far the match got.
    static func hashesMatch(presented: Data, expected: Data) -> Bool {
        guard presented.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(presented, expected) { difference |= a ^ b }
        return difference == 0
    }
}

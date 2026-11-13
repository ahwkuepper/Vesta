// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import KasaKit

/// Each operation has a fresh session: no shared cookies, sequence races, or stale
/// authentication after sleep. Mutation requests are never automatically replayed.
public protocol KasaServing: Sendable {
    func discover() async throws -> [KasaDevice]
    func read(_ device: KasaDevice, credentials: KasaCredentials?) async throws -> [KasaDevice]
    func schedules(_ device: KasaDevice, credentials: KasaCredentials?) async throws -> KasaScheduleState
    func changeSchedule(_ change: KasaScheduleChange, device: KasaDevice, credentials: KasaCredentials?) async throws -> KasaScheduleState
    func apply(_ command: KasaCommand, to device: KasaDevice, credentials: KasaCredentials?) async throws
}

public struct KasaClient: KasaServing {
    public init() {}
    public func discover() async throws -> [KasaDevice] { try await KasaSockets.discovery() }

    public func read(_ device: KasaDevice, credentials: KasaCredentials?) async throws -> [KasaDevice] {
        let response = try await exchange(device, data: Data(#"{"system":{"get_sysinfo":{}}}"#.utf8), credentials: credentials)
        return try KasaCoding.devices(KasaCoding.object(response), base: device)
    }

    public func apply(_ command: KasaCommand, to device: KasaDevice, credentials: KasaCredentials?) async throws {
        let request = try KasaCoding.request(command, device: device)
        let response = try KasaCoding.object(await exchange(device, data: request, credentials: credentials))
        try KasaCoding.checkErrors(response)
        // A valid JSON object without the requested module is not an acknowledgement.
        let sent = try KasaCoding.object(request)
        for (module, value) in sent where module != "context" {
            guard let reply = response[module] as? [String: Any], let methods = value as? [String: Any] else { throw KasaError.invalidResponse }
            for method in methods.keys {
                guard let result = reply[method] as? [String: Any],
                      KasaCoding.integer(result["err_code"], in: -100_000...100_000) == 0 else { throw KasaError.invalidResponse }
            }
        }
    }

    func exchange(_ device: KasaDevice, data: Data, credentials: KasaCredentials?) async throws -> Data {
        try LocalNetwork.requireLocal(device.host)
        switch device.transport {
        case .xor: return try await KasaSockets.exchange(host: device.host, payload: data)
        case .klap:
            guard let credentials else { throw KasaError.authentication }
            return try await KLAPRequest(host: device.host).perform(data, credentials: credentials)
        case .unsupported: throw KasaError.unsupported
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct KLAPRequest {
    let host: String

    func perform(_ payload: Data, credentials: KasaCredentials) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let local = try KasaCrypto.randomSeed()
        let (hello, headers) = try await post("handshake1", data: local, cookie: nil, session: session)
        guard hello.count == 48 else { throw KasaError.invalidResponse }
        let remote = Data(hello.prefix(16)), proof = Data(hello.suffix(32))
        let auth: Data
        let answer: Data
        // Firmware's advertised login version is inconsistent. Verify the server's
        // proof against the two documented schemes, never send either account key.
        if KasaCrypto.equal(proof, KasaCrypto.sha256(local + remote + credentials.v2)) {
            auth = credentials.v2
            answer = KasaCrypto.sha256(remote + local + auth)
        } else if KasaCrypto.equal(proof, KasaCrypto.sha256(local + credentials.v1)) {
            auth = credentials.v1
            answer = KasaCrypto.sha256(remote + auth)
        } else { throw KasaError.authentication }
        guard let url = headers.url else { throw KasaError.invalidResponse }
        let fields = headers.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .first(where: { $0.name == "TP_SESSIONID" }), cookie.value.count <= 256,
              cookie.value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }) else {
            throw KasaError.invalidResponse
        }
        let cookieHeader = "TP_SESSIONID=" + cookie.value
        _ = try await post("handshake2", data: answer, cookie: cookieHeader, session: session)
        var cipher = try KasaCipher(local: local, remote: remote, auth: auth)
        let encrypted = try cipher.seal(payload)
        let (response, _) = try await post("request", data: encrypted, cookie: cookieHeader,
            sequence: Int32(bitPattern: cipher.sequence), session: session)
        return try cipher.open(response)
    }

    private func post(_ path: String, data: Data, cookie: String?, sequence: Int32? = nil,
                      session: URLSession) async throws -> (Data, HTTPURLResponse) {
        try LocalNetwork.requireLocal(host)
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.port = 80
        components.path = "/app/" + path
        if let sequence { components.queryItems = [URLQueryItem(name: "seq", value: String(sequence))] }
        guard let url = components.url else { throw KasaError.localNetwork }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw KasaError.invalidResponse }
            if response.statusCode == 401 || response.statusCode == 403 { throw KasaError.authentication }
            guard response.statusCode == 200, response.expectedContentLength <= KasaCoding.limit else { throw KasaError.invalidResponse }
            var body = Data()
            for try await byte in bytes {
                guard body.count < KasaCoding.limit else { throw KasaError.invalidResponse }
                body.append(byte)
            }
            return (body, response)
        } catch let error as KasaError { throw error }
        catch { throw KasaError.unavailable }
    }
}

// Existing test transports can omit scheduling until explicitly exercising it.
public extension KasaServing {
    func schedules(_ device: KasaDevice, credentials: KasaCredentials?) async throws -> KasaScheduleState { throw KasaScheduleError.unsupported }
    func changeSchedule(_ change: KasaScheduleChange, device: KasaDevice, credentials: KasaCredentials?) async throws -> KasaScheduleState { throw KasaScheduleError.unsupported }
}

public extension KasaClient {
    func schedules(_ device: KasaDevice, credentials: KasaCredentials?) async throws -> KasaScheduleState {
        let request = try KasaScheduleCoding.request("get_rules", device: device, clock: true)
        let response = try KasaCoding.object(await exchange(device, data: request, credentials: credentials))
        return try KasaScheduleCoding.decode(response, device: device)
    }

    func changeSchedule(_ change: KasaScheduleChange, device: KasaDevice, credentials: KasaCredentials?) async throws -> KasaScheduleState {
        let current = try await schedules(device, credentials: credentials)
        let mutation = try KasaScheduleCoding.mutation(change, current: current, device: device)
        let request = try KasaScheduleCoding.request(mutation.method, payload: mutation.payload, device: device)
        var addedID: String?
        do {
            let response = try KasaCoding.object(await exchange(device, data: request, credentials: credentials))
            let result = try KasaScheduleCoding.result(response, method: mutation.method, device: device)
            addedID = result["id"] as? String
        } catch let error as KasaError {
            if case .rejected = error { throw error }
            // A lost response does not mean the write failed. Never replay it.
            throw KasaScheduleError.unconfirmed
        }
        do {
            let after = try await schedules(device, credentials: credentials)
            guard KasaScheduleCoding.confirmed(change, after: after, addedID: addedID, device: device) else {
                throw KasaScheduleError.unconfirmed
            }
            return after
        } catch { throw KasaScheduleError.unconfirmed }
    }
}

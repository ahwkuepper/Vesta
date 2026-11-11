import Foundation
import Security

public actor NestReader {
    private let store: any CredentialStore
    private let http: any HTTPClient
    private let now: @Sendable () -> Date
    private let allowsControl: Bool
    public init(store: any CredentialStore = KeychainStore(), http: any HTTPClient = GoogleHTTPClient(),
                now: @escaping @Sendable () -> Date = { Date() }, allowsControl: Bool = false) {
        self.store = store; self.http = http; self.now = now
        self.allowsControl = allowsControl
    }

    public func setup(_ credentials: Credentials) throws {
        var value = credentials
        if let old = try store.load() {
            guard old.projectID == value.projectID, old.clientID == value.clientID else {
                throw ReaderError.differentAccount
            }
            value = old
            value.clientSecret = credentials.clientSecret
        }
        try store.save(value)
    }

    public func status() throws -> String {
        guard let c = try store.load() else { return "Not configured." }
        if c.refreshToken != nil {
            var text = "Refresh token saved in Keychain. Run read to verify live access."
            if let expiry = c.refreshExpiresAt {
                text += " Google-reported expiry: \(expiry.ISO8601Format())."
            }
            return text
        }
        return "Client configuration saved in Keychain; authorization is still needed."
    }

    public func forget() throws { try store.delete() }

    public func authorizationURL() throws -> URL {
        var c = try configured()
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw ReaderError.invalidConfiguration
        }
        let state = Data(random).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        c.pendingState = state; c.pendingSince = now()
        var parts = URLComponents()
        parts.scheme = "https"; parts.host = "nestservices.google.com"
        parts.path = "/partnerconnections/\(c.projectID)/auth"
        parts.queryItems = [
            .init(name: "client_id", value: c.clientID),
            .init(name: "redirect_uri", value: "https://www.google.com"),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/sdm.service"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state)
        ]
        guard let url = parts.url else { throw ReaderError.invalidConfiguration }
        // Fail before sending the user through consent if Keychain is unavailable.
        try store.save(c)
        return url
    }

    public func connect(redirect: String) async throws -> Readings {
        var c = try configured()
        guard let state = c.pendingState, let since = c.pendingSince else { throw ReaderError.notAuthorized }
        guard (0...1200).contains(now().timeIntervalSince(since)) else { throw ReaderError.expiredAuthorization }
        let code = try Self.authorizationCode(redirect, state: state)
        try store.save(c) // Verify write access before consuming a single-use code.
        let tokens = try await token(c, fields: ["grant_type": "authorization_code", "code": code,
                                               "redirect_uri": "https://www.google.com"])
        guard let refresh = tokens.refresh_token, !refresh.isEmpty else { throw ReaderError.missingRefreshToken }
        c.refreshToken = refresh
        c.refreshExpiresAt = tokens.refresh_token_expires_in.map { now().addingTimeInterval($0) }
        c.pendingState = nil; c.pendingSince = nil
        // Persist FIRST: a device API failure must not lose the authorization.
        try store.save(c)
        return try await readings(c, access: tokens.access_token)
    }

    public func read() async throws -> Readings {
        let (c, access) = try await refreshed()
        return try await readings(c, access: access)
    }

    /// The standalone CLI never opts in. Each user command is checked against a
    /// fresh device read and sent once; an ambiguous failure is not retried.
    public func execute(_ command: NestCommand, resource: String) async throws -> Readings {
        guard allowsControl else { throw ReaderError.permissionDenied }
        let (c, access) = try await refreshed()
        let current = try await readings(c, access: access)
        guard let thermostat = current.thermostats.first(where: { $0.resource == resource }),
              NestCommand.validResource(resource, project: c.projectID) else { throw ReaderError.invalidConfiguration }
        let body = try command.body(for: thermostat)
        guard let url = URL(string: "https://smartdevicemanagement.googleapis.com/v1/" + resource + ":executeCommand") else {
            throw ReaderError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try Self.validate(try await http.send(request))
        return try await readings(c, access: access)
    }

    private func refreshed() async throws -> (Credentials, String) {
        var c = try configured()
        guard let refresh = c.refreshToken, !refresh.isEmpty else { throw ReaderError.notAuthorized }
        if let expiry = c.refreshExpiresAt, expiry <= now() { throw ReaderError.reauthorize }
        let tokens = try await token(c, fields: ["grant_type": "refresh_token", "refresh_token": refresh])
        // Google normally omits refresh_token here. Never replace it with nil.
        if let rotated = tokens.refresh_token, !rotated.isEmpty { c.refreshToken = rotated }
        if let interval = tokens.refresh_token_expires_in { c.refreshExpiresAt = now().addingTimeInterval(interval) }
        try store.save(c)
        return (c, tokens.access_token)
    }

    private func configured() throws -> Credentials {
        guard let c = try store.load() else { throw ReaderError.notConfigured }
        guard UUID(uuidString: c.projectID) != nil, c.clientID.hasSuffix(".apps.googleusercontent.com"),
              !c.clientSecret.isEmpty else { throw ReaderError.invalidConfiguration }
        return c
    }

    public static func authorizationCode(_ raw: String, state: String) throws -> String {
        guard raw.utf8.count <= 65_536 else { throw ReaderError.invalidRedirect }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Text editors sometimes export a Markdown-escaped URL.
        for character in ["?", "&", "=", "/"] { text = text.replacingOccurrences(of: "\\" + character, with: character) }
        guard let u = URLComponents(string: text), u.scheme == "https", u.host == "www.google.com",
              u.user == nil, u.password == nil, u.port == nil, u.fragment == nil,
              u.path == "" || u.path == "/" else { throw ReaderError.invalidRedirect }
        let items = u.queryItems ?? []
        guard !items.contains(where: { $0.name == "error" }),
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value,
              (1...8192).contains(code.utf8.count), !code.contains(where: { $0.isWhitespace }) else {
            throw ReaderError.invalidRedirect
        }
        return code
    }

    private struct Tokens: Decodable {
        let access_token: String
        let token_type: String
        let refresh_token: String?
        let refresh_token_expires_in: Double?
    }

    private func token(_ c: Credentials, fields: [String: String]) async throws -> Tokens {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { throw ReaderError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var values = fields
        values["client_id"] = c.clientID; values["client_secret"] = c.clientSecret
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(values.sorted(by: { $0.key < $1.key }).map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(encoded)"
        }.joined(separator: "&").utf8)
        let response = try await http.send(request)
        try Self.validate(response)
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: response.body),
              !tokens.access_token.isEmpty, tokens.access_token.utf8.count <= 16_384,
              !tokens.access_token.contains(where: { $0.isWhitespace }),
              tokens.token_type.lowercased() == "bearer",
              (tokens.refresh_token?.utf8.count ?? 0) <= 16_384,
              tokens.refresh_token_expires_in.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw ReaderError.malformedResponse
        }
        return tokens
    }

    private func readings(_ c: Credentials, access: String) async throws -> Readings {
        guard let url = URL(string: "https://smartdevicemanagement.googleapis.com/v1/enterprises/\(c.projectID)/devices") else {
            throw ReaderError.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await http.send(request)
        try Self.validate(response)
        return try Readings.decode(response.body, fetchedAt: now())
    }

    static func validate(_ response: HTTPResponse) throws {
        guard response.body.count <= 1_048_576 else { throw ReaderError.responseTooLarge }
        guard (200...299).contains(response.status) else {
            // Never surface Google response text: it may echo credentials or URLs.
            let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
            switch object?["error"] as? String {
            case "invalid_grant": throw ReaderError.reauthorize
            case "invalid_client": throw ReaderError.invalidClient
            default: break
            }
            switch response.status {
            case 401: throw ReaderError.reauthorize
            case 403: throw ReaderError.permissionDenied
            case 429: throw ReaderError.rateLimited
            default: throw ReaderError.http(response.status)
            }
        }
    }
}

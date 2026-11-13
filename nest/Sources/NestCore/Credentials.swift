import Foundation
import Security

public enum ReaderError: Error, LocalizedError, Equatable {
    case invalidFile, invalidConfiguration, notConfigured, notAuthorized, differentAccount
    case invalidRedirect, expiredAuthorization, missingRefreshToken, malformedResponse
    case reauthorize, invalidClient, permissionDenied, rateLimited, network, responseTooLarge
    case http(Int), keychain(Int32)
    case invalidCommand

    public var errorDescription: String? {
        switch self {
        case .invalidCommand: "That change isn’t available in the thermostat’s current mode or temperature range. Refresh its settings and try again."
        case .invalidFile: "Cannot read that file, or it exceeds the 64 KB input limit."
        case .invalidConfiguration: "Expected Google web-client credentials and a Device Access project UUID."
        case .notConfigured: "Run setup with your credentials JSON and Device Access project ID first."
        case .notAuthorized: "Run authorize, approve access in Google, then run connect with the saved redirect URL."
        case .differentAccount: "Another client or project is already configured. Run forget explicitly before replacing it."
        case .invalidRedirect: "The redirect URL does not match the pending authorization. Use the latest authorize link and save the complete returned URL, including state."
        case .expiredAuthorization: "The pending authorization expired. Run authorize again."
        case .missingRefreshToken: "Google returned no refresh token. Run authorize again and complete the consent screen."
        case .malformedResponse: "Google returned an invalid response; no readings are available."
        case .reauthorize: "Google rejected the authorization or refresh token. Run authorize again. For weekly expiration, check the OAuth app's Testing status."
        case .invalidClient: "Google rejected the OAuth client. Check the client ID and secret in Google Cloud, then rerun setup."
        case .permissionDenied: "Google denied device access. Check that the Smart Device Management API is enabled and the home and thermostat are authorized."
        case .rateLimited: "Google's request limit was reached. Try again later."
        case .network: "The Google request failed or timed out. Stored credentials were retained; try again later."
        case .responseTooLarge: "Google's response exceeded the 1 MB limit."
        case .http(let status): "Google returned HTTP \(status). Stored credentials were retained."
        case .keychain(let status): status == -25320
            ? "Wake and unlock this Mac, then refresh to allow access to your saved Nest authorization."
            : "Keychain operation failed (\(status)). Unlock the login Keychain or allow this signed app to access its entry."
        }
    }
}

public struct Credentials: Codable, Sendable, Equatable {
    public var projectID: String
    public var clientID: String
    public var clientSecret: String
    public var refreshToken: String?
    public var refreshExpiresAt: Date?
    public var pendingState: String?
    public var pendingSince: Date?

    public init(projectID: String, clientID: String, clientSecret: String) {
        self.projectID = projectID
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public static func imported(_ data: Data, projectID: String) throws -> Self {
        struct Document: Decodable {
            struct Web: Decodable { let client_id: String; let client_secret: String }
            let web: Web
        }
        guard data.count <= 65_536, UUID(uuidString: projectID) != nil,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.web.client_id.hasSuffix(".apps.googleusercontent.com"),
              !document.web.client_id.contains(where: { $0.isWhitespace }),
              (1...1024).contains(document.web.client_id.count),
              (1...4096).contains(document.web.client_secret.count) else {
            throw ReaderError.invalidConfiguration
        }
        return Self(projectID: projectID.lowercased(), clientID: document.web.client_id,
                    clientSecret: document.web.client_secret)
    }
}

public protocol CredentialStore: Sendable {
    func load() throws -> Credentials?
    func save(_ value: Credentials) throws
    func delete() throws
}

public struct KeychainStore: CredentialStore {
    public init() {}
    private var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.ahwkuepper.NestReader.oauth",
        kSecAttrAccount as String: "google-sdm"
    ] }

    public func load() throws -> Credentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ReaderError.keychain(status) }
        guard let data = result as? Data, data.count <= 65_536,
              let value = try? JSONDecoder().decode(Credentials.self, from: data) else {
            throw ReaderError.keychain(errSecDecode)
        }
        return value
    }

    public func save(_ value: Credentials) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 65_536 else { throw ReaderError.invalidConfiguration }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ReaderError.keychain(status) }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        let added = SecItemAdd(q as CFDictionary, nil)
        guard added == errSecSuccess else { throw ReaderError.keychain(added) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ReaderError.keychain(status)
        }
    }
}

public func readInputFile(_ path: String) throws -> Data {
    do {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let data = try file.read(upToCount: 65_537) ?? Data()
        guard !data.isEmpty, data.count <= 65_536 else { throw ReaderError.invalidFile }
        return data
    } catch { throw ReaderError.invalidFile }
}

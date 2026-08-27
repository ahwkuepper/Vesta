import Foundation
import Security

/// Where the bridge is and how to talk to it.
///
/// The application key is a credential: it grants full control of every light on
/// the bridge to whoever holds it. It lives in the Keychain, not in a dotfile the
/// sandbox cannot read anyway, and never in the repo.
public struct BridgeCredentials: Sendable, Codable, Equatable {
    public var address: String
    public var bridgeID: String
    public var appKey: String
    /// SHA-256 of the bridge certificate's public key, captured at pairing.
    ///
    /// This is what identity is actually established by. The bridge ID is not a
    /// secret — it is published in mDNS, returned unauthenticated by `/api/config`,
    /// and derived from the MAC — so a certificate bearing it proves nothing. Only
    /// the key pair is unforgeable.
    ///
    /// Optional so credentials stored before pinning existed still decode; those
    /// re-pin on the next successful connection rather than locking the user out.
    public var publicKeyHash: Data?

    /// The bridge's stable mDNS hostname, derived from its ID.
    ///
    /// A bridge ID is the MAC widened to EUI-64 by inserting `fffe` in the middle:
    /// `aabbcc` + `fffe` + `112233` for MAC `aa:bb:cc:11:22:33`. Removing that
    /// padding gives the `.local` name the bridge answers to. This is the most
    /// reliable way back to a bridge whose DHCP lease changed — the name follows
    /// the device, so no browsing is needed.
    public var localHostname: String? {
        let id = bridgeID.lowercased()
        guard id.count == 16, id.dropFirst(6).prefix(4) == "fffe" else { return nil }
        return "\(id.prefix(6))\(id.suffix(6)).local"
    }

    public init(address: String, bridgeID: String, appKey: String,
                publicKeyHash: Data? = nil) {
        self.address = address
        self.bridgeID = bridgeID
        self.appKey = appKey
        self.publicKeyHash = publicKeyHash
    }
}

public enum BridgeStore {
    private static let service = "dev.lumo.Lumo.bridge"
    private static let account = "default"

    public static func save(_ credentials: BridgeCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // The app runs at login and needs the key without the user unlocking
        // anything, but it should never leave this Mac.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // The delete above can fail silently when the existing item's ACL
            // belongs to a different code identity — e.g. it was written by an
            // earlier ad-hoc signed build. Update in place rather than failing.
            let update = [kSecValueData as String: data] as CFDictionary
            let updateStatus = SecItemUpdate(query as CFDictionary, update)
            guard updateStatus == errSecSuccess else {
                throw BridgeError.keychain(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw BridgeError.keychain(status)
        }
    }

    public static func load() -> BridgeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(BridgeCredentials.self, from: data)
    }

    public static func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

public enum BridgeError: LocalizedError {
    case notFound
    case notLocalAddress
    case linkButtonNotPressed
    case http(Int, String)
    case keychain(OSStatus)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .notFound:              "No Hue Bridge found on this network."
        case .notLocalAddress:
            "That address is not on your local network. Lumo only pairs with a bridge on your own network."
        case .linkButtonNotPressed:  "Press the round button on the Bridge, then try again."
        case .http(let code, _):
            // Deliberately ignores the body. The bridge answers 429 with a full HTML
            // error page, which ended up verbatim in a banner in the popover.
            switch code {
            case 429: "The bridge is busy — that change was sent too quickly."
            case 401, 403: "The bridge rejected Lumo’s key. It may need pairing again."
            case 404: "The bridge no longer has that light or scene."
            case 500...599: "The bridge reported an internal error."
            default: "The bridge refused that change (HTTP \(code))."
            }
        case .keychain(let s):       "Keychain error \(s)."
        case .malformedResponse:     "The Bridge sent a response Lumo could not read."
        }
    }
}

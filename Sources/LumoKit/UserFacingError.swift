import Foundation

/// A failure worth showing someone.
///
/// The previous `lastError: String?` was written in eight places and read in none,
/// so every rejected write, failed scene save and partially-applied room switch
/// vanished silently — the app looked broken with no explanation. This carries
/// enough to say what failed and when, and is identifiable so the UI can animate one
/// banner out and the next in.
public struct UserFacingError: Identifiable, Equatable, Sendable {
    public let id = UUID()
    /// What the user was trying to do, in their terms: "Couldn't save the scene".
    public let action: String
    /// Why it failed, from the transport.
    public let reason: String
    public let date: Date

    public init(action: String, reason: String, date: Date = .now) {
        self.action = action
        self.reason = reason
        self.date = date
    }

    public var message: String { "\(action). \(reason)" }

    public static func == (a: UserFacingError, b: UserFacingError) -> Bool { a.id == b.id }
}

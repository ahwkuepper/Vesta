import Foundation

/// Which transport is talking to the lights.
///
/// A domain concept rather than a detail of the app model: the diagnostics report
/// and the CLI both need to say which one is in use, and neither should have to
/// depend on the user interface to find out.
public enum TransportMode: String, CaseIterable, Identifiable, Sendable {
    case bridge
    case bluetooth

    public var id: String { rawValue }
    public var title: String { self == .bridge ? "Bridge" : "Bluetooth" }
}

import Foundation
import AppKit
import VestaKit
import VestaBridge

/// A health report the user can copy and send.
///
/// Vesta sends no telemetry — nothing leaves the machine on its own, and that stays
/// true. So the diagnostic has to be something a person can produce *after*
/// something went wrong, without having enabled anything in advance: a report they
/// can read, check, and paste into an issue.
///
/// It deliberately carries no light names, room names or scene names. Those are the
/// names of things in someone's home, they are never needed to debug a connection,
/// and a report is a thing people paste in public.
@MainActor
enum Diagnostics {

    static func report(store: LightStore, mode: AppModel.Mode) -> String {
        var lines: [String] = []

        lines.append("Vesta diagnostics — \(Self.timestamp())")
        lines.append("")

        // Environment
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("app        \(version) (\(build))")
        lines.append("macOS      \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("built for  macOS \(Self.deploymentTarget) — \(Self.appearance)")
        lines.append("arch       \(Self.architecture)")
        lines.append("transport  \(mode.title)")
        lines.append("")

        // Connection
        if let credentials = BridgeStore.load() {
            // The bridge ID and its mDNS name are both derived from the bridge's MAC
            // address, and this report exists to be pasted into issues. What matters
            // for debugging is *how* it is being reached, not which device it is.
            lines.append("bridge     reached by \(Self.addressKind(credentials.address))")
            // Salted per install, so two reports from the same home cannot be
            // linked by a stranger reading public issues.
            let salt = credentials.fingerprintSalt ?? Data()
            lines.append("bridge id  \(Fingerprint.of(credentials.bridgeID, salt: salt))")
            lines.append("app key    \(Fingerprint.of(credentials.appKey, salt: salt))")
        } else {
            lines.append("bridge     not paired")
        }
        lines.append("state      \(store.availability.message ?? "ready")")
        lines.append("last sync  \(Self.age(store.lastSyncAt))")
        lines.append("last event \(Self.age(store.lastEventAt))")
        lines.append("")

        // Contents, as counts only.
        let unreachable = store.lights.filter { $0.connection == .unreachable }.count
        let needPairing = store.lights.filter { $0.connection == .needsPairing }.count
        lines.append("lights     \(store.lights.count) "
                     + "(\(store.commandableLights.count) controllable, "
                     + "\(unreachable) unreachable, \(needPairing) unpaired)")
        lines.append("rooms      \(store.rooms.count)")
        lines.append("unroomed   \(store.unroomedLights.count)")
        lines.append("scenes     \(store.scenes.count) "
                     + "(\(store.scenes.filter(\.isActive).count) active)")
        if let error = store.lastError {
            lines.append("")
            lines.append("last error \(error.action): \(error.reason)")
        }
        lines.append("")
        lines.append("For detail, collect the log:")
        lines.append("  \(Log.collectCommand)")

        return lines.joined(separator: "\n")
    }

    // MARK: - Details

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: .now)
    }

    /// How long ago, or "never".
    private static func age(_ date: Date?) -> String {
        guard let date else { return "never" }
        let seconds = Int(Date.now.timeIntervalSince(date))
        if seconds < 2 { return "just now" }
        if seconds < 90 { return "\(seconds)s ago" }
        if seconds < 5400 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    /// Whether we are talking to the bridge by its stable mDNS name or a raw
    /// address — the distinction that matters when DHCP recovery is suspect.
    private static func addressKind(_ address: String) -> String {
        if address.hasSuffix(".local") { return "mDNS name (survives DHCP changes)" }
        if address.contains(":") { return "IPv6 address" }
        if address.split(separator: ".").allSatisfy({ Int($0) != nil }) {
            return "IPv4 address (will break if the lease changes)"
        }
        return "hostname"
    }



    private static var deploymentTarget: String {
        #if os(macOS)
        // Reported rather than assumed: it decides whether this build gets Liquid
        // Glass, and it is the first thing to check when the look is wrong.
        return Self.linkedDeploymentTarget ?? "unknown"
        #endif
    }

    private static let linkedDeploymentTarget: String? = {
        guard let plist = Bundle.main.infoDictionary,
              let minimum = plist["LSMinimumSystemVersion"] as? String else { return nil }
        return minimum
    }()

    /// Which variant this binary is, not which OS it happens to be running on.
    ///
    /// `#available` is a runtime check, so a classic build running on macOS 26
    /// reported "Liquid Glass" — the exact confusion this line exists to resolve.
    /// `VESTA_GLASS` is set by Package.swift from the deployment target.
    private static var appearance: String {
        #if VESTA_GLASS
        return "Liquid Glass"
        #else
        return "classic"
        #endif
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

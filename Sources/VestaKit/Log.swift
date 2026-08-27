import Foundation
import os

/// Structured logging for Vesta.
///
/// `os.Logger` rather than `print`, for three reasons that matter to an app someone
/// runs for years:
///
///  - It reaches the unified log, so a user can produce a diagnostic after the fact
///    with `log show --predicate 'subsystem == "io.github.ahwkuepper.Vesta"' --last 1h` — no
///    reproduction required, and nothing to enable in advance.
///  - It costs nothing when nobody is reading. Messages are only formatted if the
///    log is actually being collected.
///  - Its privacy annotations are enforced by the system. Light and room names are
///    the names of things in someone's home; they are logged as `%{private}` so they
///    are redacted unless the user deliberately collects with private data enabled.
///    Nothing here ever leaves the machine on its own.
///
/// Categories mirror the module boundaries, so `--predicate 'category == "bridge"'`
/// narrows to the transport without noise from the UI.
public enum Log {
    private static let subsystem = "io.github.ahwkuepper.Vesta"

    /// Bridge and Bluetooth transports: requests, retries, re-homing, event stream.
    public static let transport = Logger(subsystem: subsystem, category: "transport")
    /// The observable model: resyncs, scene recalls, optimistic write rollbacks.
    public static let store = Logger(subsystem: subsystem, category: "store")
    /// Menu bar item, popover lifecycle, presentation.
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    /// Pairing, credentials, and anything touching the Keychain.
    public static let setup = Logger(subsystem: subsystem, category: "setup")

    /// The command a user runs to collect a diagnostic. Kept next to the logger so
    /// it cannot drift from the subsystem it refers to.
    public static var collectCommand: String {
        "log show --predicate 'subsystem == \"\(subsystem)\"' --last 1h --info --debug"
    }
}

// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import VestaKit
import VestaBridge

/// Drives first-run pairing.
///
/// Pairing existed only as a command-line flag, which meant a downloaded, notarised
/// Vesta opened to "Looking for lights…" and offered no way forward. Everything
/// needed was already here — discovery, the pairing exchange, the Keychain write —
/// with no path to it from the interface.
///
/// The physical button press is what authorises pairing, so the flow is built around
/// that moment rather than hiding it: find the bridge first, then ask for the press,
/// then poll for the sixty seconds the bridge allows.
@MainActor
@Observable
public final class PairingController {

    public enum Step: Equatable {
        case idle
        case searching
        /// Found bridges. Empty means the search finished and found none.
        case choosing([BridgeDiscovery.Candidate])
        /// Waiting for the button, with the seconds left in the bridge's window.
        case pressButton(host: String, secondsLeft: Int)
        case paired
        case failed(String)
    }

    public private(set) var step: Step = .idle
    /// Typed by hand when discovery finds nothing — some networks block mDNS.
    public var manualHost: String = ""

    private var work: Task<Void, Never>?

    public init() {}

    public func search() {
        work?.cancel()
        step = .searching
        work = Task { [weak self] in
            let found = await BridgeDiscovery.find()
            guard let self, !Task.isCancelled else { return }
            self.step = .choosing(found)
        }
    }

    /// Pairs with a host, polling until the button is pressed or the window closes.
    public func pair(host: String) {
        work?.cancel()
        let deadline = 60
        step = .pressButton(host: host, secondsLeft: deadline)

        work = Task { [weak self] in
            let pairing = BridgePairing()

            // The countdown is only for the person watching; the bridge enforces its
            // own window, and `pair` polls until it closes.
            let ticker = Task { [weak self] in
                for remaining in stride(from: deadline - 1, through: 0, by: -1) {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    if case .pressButton = self.step {
                        self.step = .pressButton(host: host, secondsLeft: remaining)
                    }
                }
            }
            defer { ticker.cancel() }

            do {
                let bridgeID = try await pairing.identify(host: host)
                let credentials = try await pairing.pair(host: host, bridgeID: bridgeID)
                try BridgeStore.save(credentials)
                guard let self, !Task.isCancelled else { return }
                Log.setup.info("paired with a bridge from the interface")
                self.step = .paired
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.setup.error("pairing failed: \(error.localizedDescription, privacy: .public)")
                self.step = .failed(Self.explain(error))
            }
        }
    }

    /// Places the controller in a given step, for rendering states that cannot be
    /// reached once a bridge is paired.
    func forceStep(_ step: Step) { self.step = step }

    public func cancel() {
        work?.cancel()
        step = .idle
    }

    /// Turns a transport error into something worth reading. `BridgeError` already
    /// carries user-facing text; anything else would surface as a URLError number.
    private static func explain(_ error: Error) -> String {
        if let bridge = error as? BridgeError, let described = bridge.errorDescription {
            return described
        }
        let code = (error as NSError).code
        if code == NSURLErrorCannotFindHost || code == NSURLErrorCannotConnectToHost {
            return "Couldn’t reach that address. Check it is your bridge and on this network."
        }
        if code == NSURLErrorNotConnectedToInternet {
            return "macOS hasn’t granted local network access yet. Try again in a moment."
        }
        return "Pairing didn’t complete. \(error.localizedDescription)"
    }
}

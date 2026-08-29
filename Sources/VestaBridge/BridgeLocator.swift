// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import VestaKit

/// Finds the paired bridge again after its DHCP lease changes.
///
/// Identity is established by key pinning, not by trusting mDNS. mDNS supplies only
/// a candidate address; a candidate is accepted only once a pinned request to it
/// succeeds, which requires the private key recorded when the user pressed the
/// button on the bridge. A device that seizes the old address, answers the mDNS
/// query, or is simply a second bridge on the network cannot produce that key.
///
/// Re-homing is logged. A silent change of address is exactly what an attacker
/// inducing one would want, and it must be visible afterwards even though it is
/// no longer sufficient to compromise anything.
public enum BridgeLocator {

    /// Credentials with an address that currently works, or nil if the bridge
    /// cannot be found. Persists the address when it has changed.
    /// `verifyCurrentFirst: false` skips re-probing an address that just failed.
    public static func locate(_ credentials: BridgeCredentials,
                              verifyCurrentFirst: Bool = true) async -> BridgeCredentials? {
        if verifyCurrentFirst, await probe(credentials) { return credentials }

        // The derived .local name resolves through mDNS and follows the bridge
        // across DHCP changes. Bonjour browsing was tried here too, but resolving a
        // discovered endpoint to an address never completes under the app sandbox —
        // NWConnection sits in `.preparing` indefinitely — so it was removed rather
        // than left in as a fallback that cannot fire. The derived name needs no
        // browsing anyway: we always know the bridge ID once paired.
        let candidates = [credentials.localHostname].compactMap { $0 }

        for host in candidates where host != credentials.address {
            var candidate = credentials
            candidate.address = host
            guard await probe(candidate) else { continue }

            // Persisted only after a pinned request to the new address succeeded,
            // so a candidate that merely answered is never written to the Keychain.
            Log.transport.error(
                "bridge re-homed from \(credentials.address, privacy: .private) to \(host, privacy: .private)")
            do {
                try BridgeStore.save(candidate)
            } catch {
                // The address still works for this session; it just will not
                // survive a restart. Worth saying rather than swallowing.
                Log.transport.error("could not persist the new bridge address")
            }
            return candidate
        }
        Log.transport.error("bridge could not be found at any known address")
        return nil
    }

    private static func probe(_ credentials: BridgeCredentials) async -> Bool {
        await BridgeTransport(credentials: credentials).probe()
    }
}

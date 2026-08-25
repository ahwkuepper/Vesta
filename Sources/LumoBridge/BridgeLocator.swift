import Foundation

/// Finds the paired bridge again after its DHCP lease changes.
///
/// Identity is established by TLS pinning, not by trusting mDNS: a candidate is
/// accepted only if a real pinned request to it succeeds, which requires presenting
/// the certificate whose common name is the bridge ID we paired with. A device that
/// seizes the old address, or a second bridge on the network, is rejected.
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
            if await probe(candidate) {
                try? BridgeStore.save(candidate)
                return candidate
            }
        }
        return nil
    }

    private static func probe(_ credentials: BridgeCredentials) async -> Bool {
        await BridgeTransport(credentials: credentials).probe()
    }
}

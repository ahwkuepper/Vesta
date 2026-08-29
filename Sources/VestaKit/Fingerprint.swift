// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CryptoKit

/// Identifies a value in a diagnostics report without disclosing it.
///
/// Lives here, in the domain, rather than beside the report that uses it — the
/// report is in a non-testable executable target, so the test had to reimplement
/// this function. A test that asserts against its own copy of the code would keep
/// passing after the shipped version changed.
///
/// Salted per install. An unsalted hash is stable across every report a person ever
/// pastes, so a stranger could link separate public issues to the same household, or
/// confirm a guessed bridge ID by comparing fingerprints. The salt makes a
/// fingerprint meaningful only within one report, which is all it was ever for.
public enum Fingerprint {

    /// Four hex characters and a length. Enough to tell two values apart in a single
    /// report; not enough to recover either.
    public static func of(_ value: String, salt: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: salt)
        hasher.update(data: Data(value.utf8))
        let digest = Array(hasher.finalize())
        let short = (UInt16(digest[0]) << 8) | UInt16(digest[1])
        return String(format: "%04x (%d chars)", short, value.count)
    }

    /// A random salt, generated once per install and stored alongside the
    /// credentials it fingerprints.
    public static func newSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        // Falls back to a per-process random on the vanishingly unlikely failure
        // path: a weaker salt still beats no salt, and this must never crash a
        // diagnostics report.
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes)
    }
}

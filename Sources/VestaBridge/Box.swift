// Copyright 2026 Andreas Küpper
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Minimal lock box, for state touched from arbitrary Network.framework and
/// URLSession callback queues.
final class Box<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

extension Box where Value == Bool {
    /// Sets true and returns the previous value, for one-shot continuation guards.
    func swap(_ newValue: Bool) -> Bool {
        withLock { current in
            let old = current
            current = newValue
            return old
        }
    }
}

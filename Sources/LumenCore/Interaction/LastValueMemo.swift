// LastValueMemo.swift
// One remembered answer, keyed on its input: recompute only when the input changed.
//
// For the views that re-body on every mouse event of an unrelated drag. Any slider in
// the develop column bumps `EditRevision`, every observing panel re-bodies, and a panel
// whose drawing is a pure function of a slow-moving input recomputes it each time for
// nothing. The Colour Mixer's ribbon is the case that wanted this (B3-04): 97
// `ColorEngine.bandWeights` evaluations — 97 array allocations, 776 arc evaluations — per
// mouse event of an Exposure drag, for a picture that only changes when a ring handle
// moves. One entry is the whole cache: the input is the live state, and the previous
// state is never asked for again.
//
// Locked rather than actor-isolated so LumenCore stays free of UI isolation; the views
// that use it are on the main actor anyway, so the lock is never contended.

import Foundation

public final class LastValueMemo<Key: Equatable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (key: Key, value: Value)?
    /// How many times `value(for:compute:)` had to compute. Read by tests.
    public private(set) var misses = 0

    public init() {}

    /// The remembered value when `key` equals the last key asked for; otherwise
    /// `compute(key)`, remembered in its place.
    public func value(for key: Key, compute: (Key) -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let entry, entry.key == key { return entry.value }
        let value = compute(key)
        entry = (key, value)
        misses += 1
        return value
    }
}

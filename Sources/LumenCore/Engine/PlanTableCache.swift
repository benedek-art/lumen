// PlanTableCache.swift
// The two expensive tables a `RenderPlan` bakes, kept across frames.
//
// `RenderPlan` is built fresh for every frame of every drag, and it bakes `finishLUT`
// unconditionally — 35 937 samples of display transform, gamut soft-clip and curve at
// the interactive size. Measured on a release build with a DEFAULT recipe, after the
// `CurveStack.isIdentity` fix took the per-pixel LUT walk out of it, that is 23.7 ms
// per plan at size 33 and 3.4 ms at the draft size of 17. None of it changes while the
// photographer drags a slider that has nothing to do with picture formation.
//
// Which is most of them. `finishLUT` depends on the render preset, the display white
// target, the film stock, the tone curve, and the white/black ANCHORS — and the anchors
// are `defaultWhiteAnchorEV − 1.5 · whites` and the matching black, so they move only
// with Whites and Blacks. Exposure, Contrast, Highlights, Shadows, every zone, every
// presence and denoise and sharpening control, every mask, and the vignette all leave
// this table bit-identical. `colorGradeLUT` is the same story for the colour and grade
// stack: it is untouched by anything in Develop's tone or detail subtrees.
//
// Why this is safe to share. The key is built from every input the closure reads, so a
// hit returns exactly the table a rebuild would have produced — the cache cannot change
// a pixel, only the time it takes to get one. That is the property to preserve when
// adding a table here: if a closure captures something, it goes in the key, or the cache
// starts lying. Bake sizes above the interactive one are not cached at all; an export
// bakes 274 625 samples once and holding 6.6 MB for it afterwards is pure waste.

import Foundation

/// Baked colour tables, reused across frames when their inputs have not moved.
/// Public for exactly one member — `anyBakePending`, the viewer's question. The
/// working surface (slots, keys, the table calls) stays internal: the cache's
/// correctness argument lives in this file and no caller outside it gets to
/// participate.
public enum PlanTableCache {

    /// Which table, so the two never collide on a key.
    enum Slot: String {
        case finish
        /// The finish table with a soft proof mapped over it. A separate slot rather
        /// than a variant of `finish`, because the flag overlay needs both at once.
        case finishProofed
        case colorGrade
    }

    /// Eight entries per slot. A drag revisits one key over and over, so even one would
    /// hit almost always; eight covers flipping between a couple of render presets or
    /// A/B-ing two recipes without thrashing, plus the stale chain a drag through
    /// `tableAllowingStale` leaves behind. Each entry at the interactive size is about
    /// 1.4 MB, so a full cache is under 24 MB.
    private static let capacity = 8

    private static let lock = NSLock()
    private static var entries: [Slot: [(key: String, table: LUT3D)]] = [:]

    /// One background bake at a time per slot, newest request wins.
    ///
    /// `pending` holds at most ONE deferred bake per slot — the latest one asked for.
    /// A drag produces a fresh key on every mouse event; baking each of them would
    /// just replay the drag in the background at 23.7 ms a step, seconds behind the
    /// hand. Only the newest can ever be shown, so only the newest is kept.
    private static var inFlight: Set<Slot> = []
    private static var pending: [Slot: (key: String, bakeExact: () -> LUT3D)] = [:]
    private static let bakeQueue = DispatchQueue(label: "lumen.plantable.bake",
                                                 qos: .userInitiated)

    // MARK: Counters (docs/23 M1b: cache-hit counters on the HUD)

    /// What the cache did, counted since launch (or the last `resetStats`). The HUD's
    /// job is to turn "the sliders feel fast" into numbers; a drag whose hit rate is
    /// not ~100% after its first frame is the cache being defeated by a key bug, and
    /// nothing but a counter can see that on a live machine.
    public struct Stats: Equatable, Sendable {
        public var hits = 0
        public var bakes = 0
        public var staleServes = 0
    }
    private static var stats = Stats()

    public static var currentStats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    public static func resetStats() {
        lock.lock()
        stats = Stats()
        lock.unlock()
    }

    /// The table for `key`, building it only if it is not already held.
    ///
    /// `build` runs OUTSIDE the lock. Two threads racing on the same cold key will both
    /// bake, which wastes one bake and is still cheaper than serialising every render
    /// behind a mutex — and because the key determines the table, the loser's result is
    /// indistinguishable from the winner's.
    static func table(_ slot: Slot, key: String, size: Int,
                      build: () -> LUT3D) -> LUT3D {
        guard size <= LUT3D.interactiveSize else { return build() }

        lock.lock()
        let hit = entries[slot]?.first { $0.key == key }?.table
        if hit != nil { stats.hits += 1 } else { stats.bakes += 1 }
        lock.unlock()
        if let hit { return hit }

        let built = build()

        lock.lock()
        var slotEntries = entries[slot] ?? []
        slotEntries.removeAll { $0.key == key }
        slotEntries.insert((key: key, table: built), at: 0)
        if slotEntries.count > capacity { slotEntries.removeLast(slotEntries.count - capacity) }
        entries[slot] = slotEntries
        lock.unlock()

        return built
    }

    /// The table for `key` if it is already held; otherwise the NEWEST table in the
    /// slot while the exact one bakes in the background. Draft frames only.
    ///
    /// This is what lets Whites, Blacks, the curve, the mixer and the wheels drag at
    /// frame rate instead of paying a 23.7 ms finish bake (and often a colour-grade
    /// bake on top) inside every frame: the drag frame shows the previous event's
    /// table — one mouse event of slider travel stale, an error that decays to zero
    /// the moment the hand pauses — and the exact bake lands off the render path,
    /// picked up by the next frame. Settle and export must never come through here;
    /// they call `table`, which blocks on the exact bake, so the picture at rest and
    /// the exported file are exact by construction.
    ///
    /// The first request ever for a slot has nothing to be stale from and bakes
    /// synchronously — a cold app pays one exact bake, not a blank frame.
    static func tableAllowingStale(_ slot: Slot, key: String, size: Int,
                                   build: @escaping () -> LUT3D) -> LUT3D {
        guard size <= LUT3D.interactiveSize else { return build() }

        lock.lock()
        let slotEntries = entries[slot] ?? []
        if let hit = slotEntries.first(where: { $0.key == key })?.table {
            stats.hits += 1
            lock.unlock()
            return hit
        }
        guard let newest = slotEntries.first?.table else {
            lock.unlock()
            return table(slot, key: key, size: size, build: build)
        }
        stats.staleServes += 1
        // Replace, never append: only the newest deferred bake can ever be shown.
        pending[slot] = (key: key, bakeExact: build)
        let mustStart = !inFlight.contains(slot)
        if mustStart { inFlight.insert(slot) }
        lock.unlock()

        if mustStart { bakeQueue.async { drainPending(slot) } }
        return newest
    }

    /// Bake the latest pending key for `slot`, and keep going if another arrived while
    /// baking. Runs on `bakeQueue`; `inFlight` guarantees one drain per slot.
    private static func drainPending(_ slot: Slot) {
        while true {
            lock.lock()
            guard let next = pending.removeValue(forKey: slot) else {
                inFlight.remove(slot)
                lock.unlock()
                return
            }
            lock.unlock()

            let built = next.bakeExact()

            lock.lock()
            var slotEntries = entries[slot] ?? []
            slotEntries.removeAll { $0.key == next.key }
            slotEntries.insert((key: next.key, table: built), at: 0)
            if slotEntries.count > capacity {
                slotEntries.removeLast(slotEntries.count - capacity)
            }
            entries[slot] = slotEntries
            lock.unlock()
        }
    }

    /// True while a background bake (or a queued one) is outstanding for `slot`.
    /// For tests, and for a caller that wants to know whether a settle render would
    /// still find a fresher table than the frame it just drew.
    static func hasPendingBake(_ slot: Slot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.contains(slot) || pending[slot] != nil
    }

    /// Any slot at all — the app-facing form of the question above, public because
    /// the viewer's settle loop is the caller `hasPendingBake` was written for and
    /// never had (docs/23 audit queue item 7): a settle that gives up "because a
    /// draft of this very recipe is already up" must first know that draft is not
    /// riding a stale table still baking in the background.
    public static var anyBakePending: Bool {
        hasPendingBake(.finish) || hasPendingBake(.finishProofed)
            || hasPendingBake(.colorGrade)
    }

    /// Drop everything. For tests that want to measure a cold bake, and for a caller
    /// that has just finished an export and would rather have the memory back.
    ///
    /// Deliberately does NOT cancel an in-flight background bake — the drain loop will
    /// finish and store its table into the fresh cache, which is stale-cache behaviour,
    /// not corruption: the key still describes the table exactly.
    static func clear() {
        lock.lock()
        entries.removeAll()
        pending.removeAll()
        lock.unlock()
    }

    /// A stable string for any `Encodable` input, or nil if it cannot be encoded.
    ///
    /// Nil means "do not cache" at the call site rather than "cache under a blank key":
    /// two different recipes that both failed to encode must not collide, and a stage
    /// that renders the wrong table is a far worse failure than one that renders slowly.
    static func key(_ parts: [String], _ encodables: [any Encodable]) -> String? {
        var pieces = parts
        for value in encodables {
            guard let tree = try? CanonicalJSON.tree(of: value) else { return nil }
            pieces.append(CanonicalJSON.serialize(tree))
        }
        return pieces.joined(separator: "|")
    }
}

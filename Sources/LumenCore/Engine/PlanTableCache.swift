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
enum PlanTableCache {

    /// Which table, so the two never collide on a key.
    enum Slot: String {
        case finish
        case colorGrade
    }

    /// Four entries per slot. A drag revisits one key over and over, so even one would
    /// hit almost always; four covers flipping between a couple of render presets or
    /// A/B-ing two recipes without thrashing. Each entry at the interactive size is
    /// about 1.4 MB, so a full cache is under 12 MB.
    private static let capacity = 4

    private static let lock = NSLock()
    private static var entries: [Slot: [(key: String, table: LUT3D)]] = [:]

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

    /// Drop everything. For tests that want to measure a cold bake, and for a caller
    /// that has just finished an export and would rather have the memory back.
    static func clear() {
        lock.lock()
        entries.removeAll()
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

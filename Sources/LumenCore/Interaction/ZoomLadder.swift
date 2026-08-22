// ZoomLadder.swift
// One zoom ladder, for every surface that has a zoom.
//
// This project has now shipped the same bug twice on different keys. The first time,
// the keymap ran its own arithmetic on `zoomLevel` for Z and −, so the keyboard walked
// 1 → 0.5 → 0.25 without ever snapping back to Fit and never anchored at the cursor,
// while a mouse click went through the viewport verbs and did both. That was fixed by
// routing Z and − through the verbs. Space was left behind doing
// `zoomLevel = zoomLevel == 0 ? 1 : 0` — the same two-ladders bug, on the one key whose
// own documentation promised the anchoring the line skipped.
//
// The reason it could happen twice is that the rule lived in a method rather than in a
// value: there was nothing to compare a second implementation against, and nothing that
// could fail when one appeared. So the rule is here, as pure arithmetic on a Double,
// with tests — and the viewport, the compare panes and the keymap all read it.
//
// `0` means fit; anything else is a ratio of image pixels to device pixels, so 1.0 is
// true 1:1 on the panel and 2.0 puts one image pixel on a 2×2 block.

import Foundation

public enum ZoomLadder {

    public static let fit: Double = 0
    public static let oneToOne: Double = 1
    public static let twoToOne: Double = 2

    /// Past this, a ratio is a typo or a runaway gesture rather than an intention.
    public static let maximum: Double = 16

    /// Zooming out below this snaps to fit instead of halving forever. Without it the
    /// only way back to fit is a different key, which is how a user ends up at 12%.
    public static let fitSnap: Double = 0.35

    /// What `cycleZoom` walks through.
    public static let ladder: [Double] = [fit, oneToOne, twoToOne]

    /// Ratios within this of each other are the same rung. Comparing Doubles for
    /// equality is how a ladder loses its place after one round trip.
    public static let tolerance: Double = 0.001

    /// Everything that reaches the zoom state goes through here: a non-finite ratio
    /// becomes fit rather than a NaN that propagates into the pan arithmetic and the
    /// drawn size.
    public static func clamp(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return fit }
        return Swift.max(fit, Swift.min(ratio, maximum))
    }

    public static func isFit(_ ratio: Double) -> Bool { clamp(ratio) <= 0 }

    /// Whether a move to `target` should keep the point under the cursor pinned. Fit
    /// centres the frame, so there is nothing to hold in place.
    public static func anchorsAtCursor(target: Double) -> Bool { !isFit(target) }

    /// Space and Z: fit ↔ 1:1. Anywhere above fit returns to fit, so the key is a way
    /// out of 2:1 as well as a way in to 1:1.
    public static func toggleTarget(from current: Double) -> Double {
        isFit(current) ? oneToOne : fit
    }

    /// Walks fit → 1:1 → 2:1 → fit. A ratio that is not on the ladder — arrived at by
    /// zoom-in steps — is treated as position zero, so the next press lands on 1:1.
    public static func cycleTarget(from current: Double) -> Double {
        let ratio = clamp(current)
        var index = 0
        for (i, step) in ladder.enumerated() where abs(step - ratio) < tolerance {
            index = i
        }
        return ladder[(index + 1) % ladder.count]
    }

    /// One step in. From fit the first step is 1:1, not twice nothing.
    public static func zoomInTarget(from current: Double) -> Double {
        let ratio = clamp(current)
        return clamp(isFit(ratio) ? oneToOne : ratio * 2)
    }

    /// One step out, snapping to fit rather than halving indefinitely. Already at fit,
    /// there is nowhere further out to go.
    public static func zoomOutTarget(from current: Double) -> Double {
        let ratio = clamp(current)
        guard !isFit(ratio) else { return fit }
        let next = ratio / 2
        return next < fitSnap ? fit : clamp(next)
    }

    /// What the badge says. The three named rungs read as names; anything else reads
    /// as a percentage, because "150%" is a fact and "1.5:1" is a puzzle.
    public static func label(_ ratio: Double) -> String {
        let value = clamp(ratio)
        if isFit(value) { return "FIT" }
        if abs(value - oneToOne) < tolerance { return "1:1" }
        if abs(value - twoToOne) < tolerance { return "2:1" }
        return String(format: "%.0f%%", value * 100)
    }
}

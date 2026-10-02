// GroupMove.swift
// One slider, many values: what happens when a control moves a whole set at once and
// the set is not free to move as far as the pointer asks.
//
// The Colour Mixer's "All bands" row is the case that forced this file (B3-01). The
// row reads the mean of the eight bands and writes the difference, and it clamped
// EACH BAND into ±100 as it went. Worked through: bands `[+50, −50, 0 …]`, mean 0,
// dragged to +100. The offset is +100, band 0 asks for 150 and is clipped to 100 while
// every other band moves the full 100 — so the difference the photographer built
// between Red and Blue, the whole content of the edit, is squeezed out at the rail and
// does not come back when the drag comes back. The readout under the ring said, in as
// many words, "the spread between them is preserved."
//
// The rule that keeps the promise is one line of arithmetic and it is the same rule
// every group-move control in every editor uses: the SET stops when the FIRST member
// reaches the rail. A group move is then a rigid translation — every difference inside
// the set survives it, and dragging back to where you started restores the set, which
// is the property a photographer is actually relying on when they reach for a control
// that moves everything. "Survives" and "restores" are to floating-point round-off,
// with zero restored exactly; `moved` states that contract and why it is the right one.
//
// It is stated here rather than in the panel because it is arithmetic, because a panel
// in `#if os(macOS)` cannot be tested at all, and because the second control that wants
// it — any "move them all" row over a set of bounded values — must not re-derive it.

import Foundation

public enum GroupMove {

    /// How far the whole set may shift before its first member hits a rail.
    ///
    /// The sign of `requested` picks which rail matters: moving up, the binding member
    /// is whichever value is nearest `upper`; moving down, whichever is nearest `lower`.
    /// A non-finite request, or an empty set, moves nothing.
    ///
    /// A value ALREADY outside the bounds — which only a decoded recipe can produce,
    /// since every writer clamps — reports zero headroom in the direction that would
    /// take it further out and full headroom back toward the range. That is the
    /// behaviour that lets a hostile sidecar be dragged back into range rather than
    /// freezing the row. `moved` goes further and makes such a set legal before it
    /// asks this, so the row and the drag agree about where the set starts.
    public static func allowed(_ values: [Double], requested: Double,
                               lower: Double, upper: Double) -> Double {
        guard requested.isFinite, !values.isEmpty, upper >= lower else { return 0 }
        if requested == 0 { return 0 }
        var headroom = Double.infinity
        for v in values {
            guard v.isFinite else { return 0 }
            let room = requested > 0 ? upper - v : v - lower
            headroom = Swift.min(headroom, Swift.max(room, 0))
        }
        guard headroom.isFinite else { return 0 }
        return requested > 0 ? Swift.min(requested, headroom)
                             : Swift.max(requested, -headroom)
    }

    /// The set translated by as much of `requested` as it can take.
    ///
    /// THE LEGAL-STATE CONTRACT (S-06). A move starts from `legal(values)` — every
    /// member finite and inside the rails — and returns a legal set. From a legal set
    /// the move is a rigid translation: every difference inside the set survives it, to
    /// floating-point round-off, and the way back is the same translation reversed. It
    /// is NOT bit-exact in general and does not pretend to be: `v + d − d` is not `v`
    /// in IEEE 754, and a few ulps of a ±100 slider (≈1e−14) are four hundred billion
    /// times smaller than its 0.05 display step. The one place an ulp is visible is
    /// exactly zero — the panel's Reset dot lights on `!= 0` — so a result within
    /// `zeroSnap` of zero IS zero, and a band dragged out and back comes home clean.
    ///
    /// An ILLEGAL set — which only a hand-edited or foreign sidecar can produce, since
    /// every writer clamps and JSON cannot carry NaN — is made legal first, coherently:
    /// out-of-range members are clamped to their rail and non-finite ones read as 0,
    /// the same reading `mean` gives them, so the number the row shows is the number
    /// the drag moves from. The repair happens on the first touch and is then an
    /// ordinary set: `[150, 0]` dragged down 10 is `[90, −10]`, and back up is
    /// `[100, 0]` — reversible from the state the photographer can actually see. A set
    /// whose spread fills the whole range has nowhere to go, and says so by not moving.
    ///
    /// An inverted range is refused outright: the set comes back as it was.
    public static func moved(_ values: [Double], by requested: Double,
                             lower: Double, upper: Double) -> [Double] {
        guard upper >= lower else { return values }
        let start = legal(values, lower: lower, upper: upper)
        let delta = allowed(start, requested: requested, lower: lower, upper: upper)
        guard delta != 0 else { return start }
        let snap = zeroSnap(lower: lower, upper: upper)
        return start.map { v in
            // The clamp is for floating-point addition AT a rail, which can land a
            // hair outside it; the offset itself never breaches one.
            let out = Num.clamp(v + delta, lower, upper)
            return abs(out) <= snap ? 0 : out
        }
    }

    /// The set as a group row may hold it: finite, inside the rails, and with a
    /// round-off residue around zero read as the zero it is. Identity on any set a
    /// writer in this app produced.
    public static func legal(_ values: [Double], lower: Double,
                             upper: Double) -> [Double] {
        guard upper >= lower else { return values }
        let snap = zeroSnap(lower: lower, upper: upper)
        return values.map { v in
            let out = Num.clamp(v.isFinite ? v : 0, lower, upper)
            return abs(out) <= snap ? 0 : out
        }
    }

    /// How close to zero counts as zero: 1e−12 of the range — 2e−10 for ±100. Round-off
    /// from a move and its reverse is a few ulps of the rail (≈3e−14); the smallest
    /// step any control writes is a thousandth or more. Nothing a photographer set is
    /// inside it, and nothing round-off leaves is outside it. Never snaps to a zero the
    /// range does not contain.
    static func zeroSnap(lower: Double, upper: Double) -> Double {
        guard lower <= 0, upper >= 0 else { return 0 }
        return (upper - lower) * 1e-12
    }

    /// The mean, which is what a group row shows when it is at rest. Written here beside
    /// the move so the two cannot come to disagree about what the row's value IS.
    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        var total = 0.0
        for v in values { total += v.isFinite ? v : 0 }
        return total / Double(values.count)
    }
}

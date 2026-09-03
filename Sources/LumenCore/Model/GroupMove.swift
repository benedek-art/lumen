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
// the set survives it exactly, and dragging back to where you started restores the set
// bit for bit, which is the property a photographer is actually relying on when they
// reach for a control that moves everything.
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
    /// freezing the row.
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
    /// Every difference inside the returned set equals the difference inside the input:
    /// that is the whole contract, and it is what `allowed` buys. The result is still
    /// clamped elementwise afterwards — not because the offset can breach a rail, which
    /// it cannot, but because floating-point addition at the rail can land a hair
    /// outside it and a stored value one ulp past ±100 would read as "modified" forever.
    public static func moved(_ values: [Double], by requested: Double,
                             lower: Double, upper: Double) -> [Double] {
        let delta = allowed(values, requested: requested, lower: lower, upper: upper)
        guard delta != 0 else { return values }
        return values.map { Num.clamp($0 + delta, lower, upper) }
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

// SliderDrag.swift
// What a drag of N points across a slider track is worth, and what happens to a
// gesture whose middle was dropped.
//
// Why this exists. The owner's first session reported Highlights, Whites and Blacks as
// "not working", with 2, 11 and −7 on the screen — tiny values on ±100 controls, where
// the effect SHOULD be close to invisible. The offered reading was that the interface
// had dropped most of the gesture and he had then judged a control that moved two
// units. That reading is checkable, and this file is where it gets checked, because
// the slider itself lives in a target with no tests.
//
// The answer, stated as arithmetic below: a RELATIVE drag is a pure function of where
// the pointer is NOW relative to where the press began. It reads no accumulator and
// no history. So dropping any number of interior samples — one, ten, all of them —
// cannot change what the gesture is worth, as long as ONE sample carrying the final
// travel is delivered. Event coalescing keeps the newest event and discards the older
// ones, which is exactly the sample that survives. Dropped events therefore cannot
// shrink a drag, and the "the UI ate his gesture" theory does not hold at the
// arithmetic.
//
// What CAN shrink it is the other half: if no sample carrying the final travel is ever
// delivered, the value stops wherever the last delivered sample left it. A gesture
// torn down mid-drag does that; so does a release that carries the final position and
// is thrown away. The viewer's slider was throwing it away — its `onEnded` set a flag
// and ignored `location` entirely — so the value a drag was worth depended on whether
// the last motion sample happened to arrive before the mouse came up. `endedValue` is
// the rule that closes it: the release is a sample like any other, and the last one.

import Foundation

/// One slider's track, as the numbers a drag is resolved against.
///
/// This is a description of the control that already ships, not a new one: `width` is
/// the track's own width in points, and a drag across the whole of it covers the whole
/// range, which is what "1:1 with the track" means. Nothing here changes any range,
/// any step, or the order the clamp and the snap are applied in — reproducing that
/// order is the point, since a model that rounds differently from the control it
/// describes is not a model of it.
public struct SliderTrack: Sendable, Equatable {

    /// Track width in points. The denominator of every travel.
    public let width: Double
    public let lowerBound: Double
    public let upperBound: Double
    /// Quantum the value is rounded to. Zero or negative means no rounding.
    public let step: Double

    public init(width: Double, lowerBound: Double, upperBound: Double, step: Double) {
        self.width = width
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.step = step
    }

    /// How much value one full track width covers.
    public var span: Double { upperBound - lowerBound }

    /// False for a track that has not been laid out yet, or a degenerate range. Every
    /// entry point below returns the value unchanged rather than dividing by it.
    public var isUsable: Bool {
        width > 0 && span > 0 && width.isFinite && span.isFinite
    }

    public func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return lowerBound }
        return Swift.min(Swift.max(value, lowerBound), upperBound)
    }

    public func snapped(_ value: Double) -> Double {
        guard step > 0, value.isFinite else { return value }
        return (value / step).rounded() * step
    }

    /// Clamp then snap, in that order — the order the control applies them in.
    public func resolve(_ value: Double) -> Double { snapped(clamped(value)) }

    /// Where a press at `x` points from the track's leading edge lands.
    ///
    /// This is the jump that makes clicking the track do something. It is absolute, and
    /// it is the ONLY absolute step in a gesture: everything after it is relative to
    /// the point of the press.
    public func valueAtPress(x: Double) -> Double {
        guard isUsable, x.isFinite else { return lowerBound }
        return resolve(lowerBound + (x / width) * span)
    }

    /// What a drag anchored at `start` is worth once the pointer has travelled
    /// `travelled` points.
    ///
    /// A pure function of the CURRENT pointer position. No accumulator, no dependence
    /// on how many samples came before — which is the property the whole file is about.
    public func value(from start: Double, travelled: Double) -> Double {
        guard isUsable, travelled.isFinite else { return resolve(start) }
        return resolve(start + (travelled / width) * span)
    }

    /// How far the pointer has to travel to move a control from `from` to `to`. The
    /// answer to "how big a gesture is a full-range move?", which is what decides
    /// whether a reported value is a small drag or a large one that went wrong.
    public func travelNeeded(from: Double, to: Double) -> Double {
        guard isUsable else { return 0 }
        return ((to - from) / span) * width
    }
}

/// The law about which samples of a gesture matter.
public enum SliderDrag {

    /// What a gesture is worth given only the samples that were actually delivered.
    ///
    /// `delivered` is the travel carried by each sample the control got to run, in
    /// order — the subsequence of the gesture that survived coalescing, a blocked main
    /// actor, or both. Only the last one is read, which is the whole point: an
    /// interface that drops the middle of a drag still lands on the right value.
    public static func outcome(track: SliderTrack, from start: Double,
                               delivered: [Double]) -> Double {
        guard let last = delivered.last else { return track.resolve(start) }
        return track.value(from: start, travelled: last)
    }

    /// The value a release must commit, given where the press began and where the
    /// pointer was let go.
    ///
    /// Identical arithmetic to a motion sample, deliberately. A release IS a motion
    /// sample — the last one — and treating it as anything else is how a gesture ends
    /// somewhere other than under the cursor.
    public static func endedValue(track: SliderTrack, from start: Double,
                                  travelled: Double) -> Double {
        track.value(from: start, travelled: travelled)
    }

    /// Whether a press at `pressX` landed close enough to the thumb's drawn position
    /// `thumbX` — both in points from the track's leading edge — to count as having
    /// picked the thumb up rather than as having pressed the bare track.
    ///
    /// Wider than the thumb is drawn: the target is small and the penalty for missing
    /// it is the value jumping to wherever the press landed.
    public static let thumbGrabRadius: Double = 11

    public static func grabsThumb(pressX: Double, thumbX: Double) -> Bool {
        guard pressX.isFinite, thumbX.isFinite else { return false }
        return abs(pressX - thumbX) <= thumbGrabRadius
    }
}

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

/// Which way a slider's track maps position to value.
///
/// A slider is a statement that the whole control is worth dragging. The Temp row was
/// not: on a linear Kelvin axis from 2000 to 50000, the top 72.9% of the track carries
/// 4.4% of the change, and the first fifth carries 93.3%. The owner's first session
/// reported it as "why does it go from 2,000 Kelvin to 50,000 Kelvin? I don't think
/// anything even changes above like 15,000" — which is not a misreading of the control,
/// it is an accurate measurement of it.
///
/// The fix is the axis every camera UI already steps in underneath, and that this
/// package's own eyedropper search already uses: mireds, 1e6/K. `ColorTemperature`'s
/// comment has said so since it was written — "the axis that is perceptually even in
/// Kelvin and the reason every camera UI steps in mireds underneath" — while the
/// slider above it stayed linear. On the mired axis the same range spends its fifths
/// 21.4 / 33.6 / 18.8 / 15.6 / 10.5, so the worst fifth is within 3.2× of the best
/// instead of 233×.
///
/// Both cases are strictly monotone increasing in value, which is what lets every
/// other method here keep working by converting at its boundaries and doing its
/// arithmetic in axis space.
public enum SliderScale: String, Sendable, Equatable, Codable, CaseIterable {

    /// Position is the value. Every control but Temp.
    case linear

    /// Position is proportional to −1e6/value: the mired axis, negated so that
    /// position still increases with value and no caller has to reason about a track
    /// whose span runs backwards. Requires a strictly positive range.
    case reciprocal

    /// Position coordinate for a value. Monotone increasing in `value`.
    public func axis(_ value: Double) -> Double {
        switch self {
        case .linear:
            return value
        case .reciprocal:
            guard value > 0, value.isFinite else { return -.infinity }
            return -1e6 / value
        }
    }

    /// Inverse of `axis`, and exactly its inverse over a range this scale can represent.
    public func value(atAxis a: Double) -> Double {
        switch self {
        case .linear:
            return a
        case .reciprocal:
            guard a < 0, a.isFinite else { return .infinity }
            return -1e6 / a
        }
    }

    /// Whether this scale is defined across `lowerBound...upperBound`. A reciprocal
    /// axis needs both ends strictly positive; asking for one that straddles zero is a
    /// programming error at the call site, and the track reports itself unusable
    /// rather than dividing by it.
    public func canRepresent(lowerBound: Double, upperBound: Double) -> Bool {
        switch self {
        case .linear:
            return true
        case .reciprocal:
            return lowerBound > 0 && upperBound > 0
        }
    }
}

/// One slider's track, as the numbers a drag is resolved against.
///
/// This is a description of the control that already ships, not a new one: `width` is
/// the track's own width in points, and a drag across the whole of it covers the whole
/// range, which is what "1:1 with the track" means. Nothing here changes any range,
/// any step, or the order the clamp and the snap are applied in — reproducing that
/// order is the point, since a model that rounds differently from the control it
/// describes is not a model of it.
///
/// Every travel is resolved in AXIS space and converted back at the boundary, so a
/// non-linear `scale` changes where a value sits on the track without changing any of
/// the rules above: the step is still in the value's own units, the clamp still
/// precedes the snap, and a release is still just the last sample.
public struct SliderTrack: Sendable, Equatable {

    /// Track width in points. The denominator of every travel.
    public let width: Double
    public let lowerBound: Double
    public let upperBound: Double
    /// Quantum the value is rounded to. Zero or negative means no rounding.
    public let step: Double
    /// How position maps to value. Defaults to the linear axis every control but Temp
    /// uses, so adding this changed no existing call site.
    public let scale: SliderScale

    public init(width: Double, lowerBound: Double, upperBound: Double, step: Double,
                scale: SliderScale = .linear) {
        self.width = width
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.step = step
        self.scale = scale
    }

    /// How much value one full track width covers. Still the value-space span, which
    /// is what "range" means to a caller; the arithmetic below uses `axisSpan`.
    public var span: Double { upperBound - lowerBound }

    /// Position coordinate of the low end of the track.
    public var axisLower: Double { scale.axis(lowerBound) }
    /// Position coordinate of the high end.
    public var axisUpper: Double { scale.axis(upperBound) }
    /// How much axis one full track width covers. Positive for any usable track,
    /// because every scale is monotone increasing.
    public var axisSpan: Double { axisUpper - axisLower }

    /// False for a track that has not been laid out yet, a degenerate range, or a
    /// range this scale cannot represent. Every entry point below returns the value
    /// unchanged rather than dividing by it.
    public var isUsable: Bool {
        width > 0 && span > 0 && width.isFinite && span.isFinite
            && scale.canRepresent(lowerBound: lowerBound, upperBound: upperBound)
            && axisSpan > 0 && axisSpan.isFinite
    }

    public func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return lowerBound }
        return Swift.min(Swift.max(value, lowerBound), upperBound)
    }

    /// Clamp in POSITION space, which is where a travel has to be pinned before it is
    /// converted back. Converting first and clamping after would hand `value(atAxis:)`
    /// coordinates outside the scale's domain — for the reciprocal axis that is the
    /// half-line through zero, where the value is infinite and then changes sign.
    public func clampedAxis(_ a: Double) -> Double {
        guard a.isFinite else { return axisLower }
        return Swift.min(Swift.max(a, axisLower), axisUpper)
    }

    public func snapped(_ value: Double) -> Double {
        guard step > 0, value.isFinite else { return value }
        return (value / step).rounded() * step
    }

    /// Clamp then snap, in that order — the order the control applies them in.
    public func resolve(_ value: Double) -> Double { snapped(clamped(value)) }

    /// One arrow press, or ten of them under ⇧.
    ///
    /// Denominated in STEPS rather than in points, because that is what a key press
    /// means and it is the one input to a slider that has no pointer behind it. A step
    /// is also the smallest distinguishable move — the drag snaps to it — so a nudge
    /// finer than one step would be a key that appears to do nothing.
    ///
    /// Clamps to the SOFT range, like a drag and unlike typing. The asymmetry is the
    /// existing contract: the hard range is where you go deliberately, by saying a
    /// number, not where you can arrive by leaning on an arrow key.
    ///
    /// BUT IT MUST NOT EVICT A VALUE THAT IS ALREADY OUT THERE, and it used to. The rule
    /// above says an arrow cannot take you PAST the soft limit; it says nothing about a
    /// value that got past it by the route the contract provides. Type −8 into Exposure
    /// (legal: the hard range is ±10) and tap → once, or ⌥-scroll one click: `resolve`
    /// clamped to the soft ±5 and the value jumped **three stops** from a gesture that
    /// promises 0.01 EV — in the direction of the arrow or against it, indifferently, and
    /// unrecoverable except by retyping. Every slider with a wider hard range had this:
    /// Exposure, Tint (a jump of up to 150 units), the six Zones rows, three export rows.
    ///
    /// So the clamp becomes one-sided. A value inside the soft range still cannot leave
    /// it. A value already outside may move by one step in either direction and is held
    /// where it is rather than dragged home — the arrow does what it says, and the only
    /// way back inside is the same deliberate one that got it out.
    ///
    /// A non-finite input holds the value rather than propagating: a NaN in a recipe is
    /// data loss, because the canonical JSON refuses non-conforming floats and collapses
    /// to "{}" on its way to the sidecar.
    public func nudged(_ value: Double, steps: Int) -> Double {
        guard value.isFinite else { return value }
        guard isUsable, steps != 0 else { return resolve(value) }
        let moved = value + Double(steps) * step
        // The window this nudge may land in: the soft range, widened just far enough to
        // include wherever the value already is.
        let low = Swift.min(lowerBound, value)
        let high = Swift.max(upperBound, value)
        return snapped(Swift.min(Swift.max(moved, low), high))
    }

    /// Where along the track a value is drawn, 0…1. The view's thumb offset and fill
    /// width come from here rather than from arithmetic inlined into a layout closure,
    /// so the picture and the drag cannot disagree about where a value sits.
    public func fraction(of value: Double) -> Double {
        guard isUsable else { return 0 }
        return (clampedAxis(scale.axis(clamped(value))) - axisLower) / axisSpan
    }

    /// Where a press at `x` points from the track's leading edge lands.
    ///
    /// This is the jump that makes clicking the track do something. It is absolute, and
    /// it is the ONLY absolute step in a gesture: everything after it is relative to
    /// the point of the press.
    public func valueAtPress(x: Double) -> Double {
        guard isUsable, x.isFinite else { return lowerBound }
        return resolve(scale.value(atAxis: clampedAxis(axisLower + (x / width) * axisSpan)))
    }

    /// What a drag anchored at `start` is worth once the pointer has travelled
    /// `travelled` points.
    ///
    /// A pure function of the CURRENT pointer position. No accumulator, no dependence
    /// on how many samples came before — which is the property the whole file is about.
    public func value(from start: Double, travelled: Double) -> Double {
        guard isUsable, travelled.isFinite else { return resolve(start) }
        let startAxis = clampedAxis(scale.axis(clamped(start)))
        return resolve(scale.value(atAxis: clampedAxis(startAxis + (travelled / width) * axisSpan)))
    }

    /// How far the pointer has to travel to move a control from `from` to `to`. The
    /// answer to "how big a gesture is a full-range move?", which is what decides
    /// whether a reported value is a small drag or a large one that went wrong.
    public func travelNeeded(from: Double, to: Double) -> Double {
        guard isUsable else { return 0 }
        let a = clampedAxis(scale.axis(clamped(from)))
        let b = clampedAxis(scale.axis(clamped(to)))
        return ((b - a) / axisSpan) * width
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

    /// Whether a move from `from` to `to` passed through `detent` — the question a
    /// haptic tick at a slider's default has to answer.
    ///
    /// CROSSING, not proximity, and the difference is the whole of it. "Within a
    /// tolerance of the default" is true for many consecutive samples of a slow drag,
    /// so a proximity test buzzes continuously while the hand loiters near zero and
    /// turns a landmark into a rumble. Crossing is true for exactly one sample, which
    /// is what makes the tick mean "you just passed it".
    ///
    /// Landing exactly on the detent counts; leaving it does not. Otherwise a drag that
    /// stopped on zero would tick twice — once arriving, once departing — and the
    /// arrival is the event worth feeling.
    public static func crossesDetent(from: Double, to: Double, detent: Double) -> Bool {
        guard from.isFinite, to.isFinite, detent.isFinite, from != to else { return false }
        if to == detent { return true }
        if from == detent { return false }
        return (from < detent) != (to < detent)
    }
}

/// A drag that can change gear part-way through without moving the value.
///
/// ⇧ makes a drag fine (docs/28 Phase 6, and D45's list of deliberate omissions). The
/// reason it needs a type rather than a multiply is stated in that plan and is worth
/// repeating where the code is: `SliderTrack.value(from:travelled:)` reads the pointer's
/// CURRENT offset from the press, absolutely, with no accumulator — which is exactly what
/// makes a dropped sample harmless. Scaling that absolute offset the instant ⇧ goes down
/// also scales the travel already spent, so the thumb jumps backward to a quarter of
/// where the hand had taken it, and jumps forward again on release.
///
/// So the gesture carries an anchor instead: the value it had reached, and the travel at
/// which the gear last changed. Every sample is still resolved from the pointer's current
/// position, so the dropped-sample property survives intact — the anchor only moves when
/// the modifier does.
public struct FineDrag: Equatable, Sendable {

    /// A quarter. Fine enough to place a value the coarse gear skips over, coarse enough
    /// that crossing a ±100 track still takes one gesture rather than four.
    public static let scale: Double = 0.25

    private var anchorValue: Double
    private var anchorTravel: Double
    private var isFine: Bool

    public init(startValue: Double, fine: Bool = false) {
        self.anchorValue = startValue
        self.anchorTravel = 0
        self.isFine = fine
    }

    /// What the gesture is worth now, and a replacement gearbox ONLY if the gear moved.
    ///
    /// The odd shape is the important part, and it is about what a `@State` write costs
    /// rather than about arithmetic. The mutating form below writes on every call, and
    /// in SwiftUI a `@State` write is a view invalidation — so a slider that used it
    /// would publish on every mouse event of every drag, including the majority that do
    /// not move the value at all because the pointer has not crossed a step. That is
    /// precisely the per-event cost `CommandState` and `EditRevision` exist to keep off
    /// this path. Returning nil for "nothing to store" lets the view write only when ⇧
    /// actually changes, which is a handful of times per gesture at most.
    public func resolving(track: SliderTrack, travelled: Double,
                          fine: Bool) -> (value: Double, changedGear: FineDrag?) {
        guard travelled.isFinite else { return (track.resolve(anchorValue), nil) }
        guard fine != isFine else {
            return (resolved(track: track, travelled: travelled), nil)
        }
        // Rebase at the value the OLD gear had already reached — `next` is built from
        // `self`, whose `isFine` has not moved yet — so the change of gear is worth
        // exactly nothing.
        var next = self
        next.anchorValue = resolved(track: track, travelled: travelled)
        next.anchorTravel = travelled
        next.isFine = fine
        return (next.resolved(track: track, travelled: travelled), next)
    }

    /// What the gesture is worth now, given where the pointer is and whether ⇧ is down.
    ///
    /// The convenient form, and the one the tests read. A view should prefer
    /// `resolving` — see its note.
    public mutating func value(track: SliderTrack, travelled: Double,
                               fine: Bool) -> Double {
        let out = resolving(track: track, travelled: travelled, fine: fine)
        if let changed = out.changedGear { self = changed }
        return out.value
    }

    private func resolved(track: SliderTrack, travelled: Double) -> Double {
        let gear = isFine ? Self.scale : 1
        return track.value(from: anchorValue,
                           travelled: (travelled - anchorTravel) * gear)
    }
}

/// A wheel or a two-finger scroll, read as whole steps of a control.
///
/// WHAT MAKES A SCROLL DIFFERENT FROM A DRAG, which is the only reason this is a type
/// rather than `travelled / pointsPerStep` written inline in a view. Everything above
/// resolves a gesture ABSOLUTELY, from where the press began — the property that makes a
/// dropped sample harmless, and most of what this file is about. A scroll has no press.
/// It arrives as increments and never says where it started, so the only honest reading
/// is cumulative, and a cumulative reading has to KEEP the travel that has not yet earned
/// a step or a gentle scroll moves the control not at all.
///
/// The residue is therefore the type. Its property, and the one the tests pin, is the
/// nearest thing a scroll has to the dropped-sample rule: N points of scrolling are worth
/// the same number of steps however they are chopped up — one event of 80, or eighty
/// events of 1.
///
/// Denominated in STEPS rather than in range, like `SliderTrack.nudged` and unlike the
/// drag, because that is what lets ONE constant serve ninety controls whose ranges run
/// from ±1 to 2000–50000 K. A step is already the smallest move each control considers
/// meaningful, so a wheel click worth one of them is worth roughly the same amount of
/// judgement everywhere.
public struct ScrollNudge: Equatable, Sendable {

    /// How much continuous scrolling one step of the control is worth.
    ///
    /// A comfortable two-finger swipe delivers on the order of 150 points, so it is worth
    /// about 19 steps: 19 units on a ±100 tone control, 0.19 EV on Exposure. Both are a
    /// tweak rather than a journey, which is what the wheel is for — crossing a range is
    /// the track's job at one track width, and placing a value exactly is the readout
    /// scrub's at three.
    public static let pointsPerStep: Double = 8

    /// Travel that has not yet earned a step, carried rather than discarded. Without it a
    /// slow scroll delivers two or three points per event, every one of them rounds to
    /// nothing, and the control appears not to answer the wheel at all.
    private var residue: Double = 0

    public init() {}

    /// Whole steps earned by one more scroll event, keeping the remainder.
    ///
    /// `precise` is AppKit's `hasPreciseScrollingDeltas`, and it is the flag that tells
    /// the two instruments apart. A trackpad reports POINTS and is continuous, so its
    /// delta accumulates as it stands. A wheel reports LINES and is discrete, so one line
    /// converts to exactly one step — which makes a click of the wheel exactly a press of
    /// ←/→, and that equivalence is the whole idea of the feature: the arrows without
    /// having to focus the row first.
    ///
    /// A non-finite delta is refused rather than added. NaN in the residue is permanent,
    /// and a control that quietly stops answering the wheel until its panel is rebuilt is
    /// a defect nobody would think to report as one.
    public mutating func steps(scrolling delta: Double, precise: Bool) -> Int {
        guard delta.isFinite else { return 0 }
        residue += precise ? delta : delta * Self.pointsPerStep
        // `Int(_:)` traps on a value it cannot represent rather than saturating. No hand
        // on a trackpad produces a residue this large, which is exactly why the
        // conversion is guarded instead of trusted.
        guard abs(residue) < 1e12 else {
            residue = 0
            return 0
        }
        let whole = (residue / Self.pointsPerStep).rounded(.towardZero)
        guard whole != 0 else { return 0 }
        residue -= whole * Self.pointsPerStep
        return Int(whole)
    }

    /// Drop the remainder because a new gesture has begun.
    ///
    /// Only a trackpad can say when one does — a wheel has no phases, which is the whole
    /// difficulty this feature was blocked on. It matters because a few points left over
    /// from the last flick would otherwise fire the first step of the next one early,
    /// which reads as a control that moves before the hand does.
    public mutating func beginGesture() {
        residue = 0
    }
}

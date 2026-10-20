// RefineBudget.swift
// The two-tier refine's timing contract, as arithmetic rather than as a comment.
//
// docs/12 §12.2 budgets progressive refine to full quality at "≤200 ms after drag
// pause", measured input→photon. The viewer implemented that as a single constant —
// a 250 ms sleep — under a comment saying the 250 ms "is the settle window plus the
// pass itself". It is not: the sleep runs BEFORE the quality pass is asked for, so
// full quality lands at 250 ms plus however long the pass takes. The budget could not
// be met by any render, however fast, on any machine. The comment and the code
// disagreed, and nothing could notice because a sleep in a SwiftUI file has no test
// target.
//
// So the budget is split here, where the split can be asserted: the settle is a
// DEBOUNCE, deliberately a small share of the budget, and what remains is the
// allowance the two render passes have to fit inside.
//
// What this type does NOT claim: that the passes do fit. Nothing in this repository
// has ever timed a render on the machine that ships it (audit UX-01 — the five-loop
// gate has no instrumentation at all). This makes the budget arithmetic honest and
// checkable; measuring the passes against `renderAllowanceNanoseconds` is the separate
// job that would let anyone say the loop is met.

import Foundation

/// A progressive-refine deadline and how it is spent.
public struct RefineBudget: Sendable, Equatable {

    /// Everything the budget covers, from the last input event to full quality on
    /// screen: the debounce, the draft pass and the quality pass.
    public let totalNanoseconds: UInt64

    /// How long the viewer waits, after the draft lands, before asking for quality.
    ///
    /// A debounce, and only a debounce. A drag delivers events every 8–16 ms, so a
    /// window several frames wide is enough to distinguish "the hand stopped" from
    /// "the hand is between events" — and a window any wider is spent doing nothing
    /// while the deadline runs.
    ///
    /// Erring short is close to free: a quality pass started during a drag is
    /// superseded by generation number and discarded, which costs work that was
    /// already going to be thrown away. Erring long cannot be recovered at all.
    public let settleNanoseconds: UInt64

    public init(totalNanoseconds: UInt64, settleNanoseconds: UInt64) {
        self.totalNanoseconds = totalNanoseconds
        self.settleNanoseconds = settleNanoseconds
    }

    /// What is left of the budget for the draft and quality passes once the debounce
    /// has been paid. Zero when the debounce alone has already spent the deadline —
    /// which is the state this file was written to make visible.
    public var renderAllowanceNanoseconds: UInt64 {
        totalNanoseconds > settleNanoseconds ? totalNanoseconds - settleNanoseconds : 0
    }

    /// The fraction of the deadline spent waiting rather than rendering.
    public var settleShare: Double {
        guard totalNanoseconds > 0 else { return 1 }
        return Double(settleNanoseconds) / Double(totalNanoseconds)
    }

    /// False when the debounce alone meets or exceeds the deadline, so no render of
    /// any speed could land inside it. A budget that fails this is broken by
    /// construction, not by being slow.
    public var isAchievable: Bool { settleNanoseconds < totalNanoseconds }

    /// The loupe and every compare pane, which share one refine driver.
    ///
    /// 200 ms is docs/12's number, not a choice made here. 40 ms is the debounce: two
    /// and a half frames at 60 Hz, comfortably longer than the gap between two events
    /// of a live drag and a fifth of the deadline, leaving 160 ms — the great majority
    /// of the budget — to the passes that actually produce pixels.
    public static let loupe = RefineBudget(totalNanoseconds: 200_000_000,
                                           settleNanoseconds: 40_000_000)

    /// The debounce for a DISCRETE edit: one arrow press, one VoiceOver step, a typed
    /// value — the edit opened and closed its gesture in one go, so the request moved
    /// the recipe and the settle tick together, on the photo already showing, with no
    /// drag sample before it.
    ///
    /// Such an edit has no release to wait for, so 40 ms after it the full-resolution
    /// pass starts, and the render actor cannot give that pass back. Tapping six or
    /// eight times a second then paid a settle per press that the next press threw
    /// away, and each press's draft queued behind the last one's settle.
    ///
    /// Measured FROM THE REQUEST, not from the draft's landing: taps 125–167 ms apart
    /// must all arrive inside the cancellable sleep whatever the draft cost, so the
    /// window is the widest gap plus a little, and still under the 200 ms deadline.
    public static let discreteEditWindowNanoseconds: UInt64 = 175_000_000

    /// How long to sleep before the quality pass, `elapsed` after the request began.
    /// A drag's pause keeps the plain debounce; a discrete edit sleeps out the rest of
    /// its window, and never less than the plain debounce.
    public func debounceNanoseconds(discreteEdit: Bool, elapsed: UInt64 = 0) -> UInt64 {
        guard discreteEdit else { return settleNanoseconds }
        let rest = Self.discreteEditWindowNanoseconds > elapsed
            ? Self.discreteEditWindowNanoseconds - elapsed : 0
        return Swift.max(settleNanoseconds, rest)
    }

    /// Whether a request is a discrete edit. A photo switch made while a gesture is
    /// latched also moves the tick (the switch flushes it), and so does a drag's
    /// release whose last sample moved the recipe; neither is a burst of presses, so
    /// both keep the short debounce.
    public static func isDiscreteEdit(isSettleAsk: Bool, needsDraft: Bool,
                                      samePhotograph: Bool,
                                      previousRequestWasMidGesture: Bool) -> Bool {
        isSettleAsk && needsDraft && samePhotograph && !previousRequestWasMidGesture
    }
}

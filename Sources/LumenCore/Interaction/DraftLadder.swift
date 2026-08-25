// DraftLadder.swift
// Which resolution a draft frame renders at, decided by what draft frames have been
// costing — arithmetic in LumenCore rather than a constant in a view, like every rule
// in this directory and for the same reason: the viewer's fixed draft size had no test
// target and nothing could notice when its assumptions stopped holding.
//
// The gates that used to make drafts cheap are gone (docs/23 M1a): a draft runs the
// FULL pipeline at reduced resolution, and the resolution is the one lever left.
// Measured on a runner GPU — weaker than any Mac this app will meet — the whole graph
// costs 28 ms at 1024, 45 ms at 1536, 42 ms at 2048; an M-series machine lands under
// the ~35 ms drag budget at the top rung and a weak one does not. No constant is right
// for both, so the ladder listens: it steps DOWN the moment drafts run hot, and steps
// back UP only after a run of comfortably-cheap frames says the machine has headroom.
// Down fast, up slow — a hot frame is felt immediately and a wasted opportunity is
// not.

import Foundation

/// A resolution ladder driven by measured draft frame times.
///
/// Pure state machine: feed it each draft's milliseconds, ask it the long edge for
/// the next one. It never sizes ABOVE what the caller asks for — a settle at 1024
/// wants a draft at 1024, not the ladder's top — so the answer is
/// `min(rung, requested)`.
public struct DraftLadder: Sendable, Equatable {

    /// Top to bottom. 1024 is the floor the old fixed draft shipped at; 2048 is where
    /// a draft at fit is indistinguishable from the settle on a 5K display.
    public static let rungs: [Int] = [2048, 1600, 1280, 1024]

    /// The drag budget a draft must fit inside (docs/12 §12.2's slider loop, less a
    /// couple of milliseconds for delivery and compositing).
    public static let budgetMilliseconds: Double = 35

    /// One frame over `stepDownOver` steps down: a hot draft is a dropped frame the
    /// hand feels NOW, and one sample is evidence enough at 3x the noise of a GPU
    /// timing. Stepping UP waits for `stepUpAfter` consecutive frames under
    /// `stepUpUnder` — headroom has to be a pattern before it is spent.
    public static let stepDownOver: Double = budgetMilliseconds * 1.3
    public static let stepUpUnder: Double = budgetMilliseconds * 0.5
    public static let stepUpAfter: Int = 12

    /// Index into `rungs`. Starts at the top: the first frames on a fast machine
    /// should not look worse because a slow machine exists.
    public private(set) var rung: Int = 0
    private var cheapStreak: Int = 0

    public init() {}

    /// The long edge the next draft should render at, given what the caller wants.
    public func longEdge(requested: Int) -> Int {
        Swift.min(Self.rungs[rung], Swift.max(requested, 64))
    }

    /// Record what a draft cost. Only frames rendered AT the ladder's current answer
    /// teach it — a draft that was smaller because the settle itself was small says
    /// nothing about the rung's affordability.
    public mutating func record(draftMilliseconds ms: Double, renderedLongEdge: Int,
                                requested: Int) {
        guard ms.isFinite, ms > 0 else { return }
        guard renderedLongEdge == longEdge(requested: requested),
              renderedLongEdge == Self.rungs[rung] else { return }

        if ms > Self.stepDownOver {
            if rung < Self.rungs.count - 1 {
                rung += 1
            }
            cheapStreak = 0
            return
        }
        if ms < Self.stepUpUnder {
            cheapStreak += 1
            if cheapStreak >= Self.stepUpAfter, rung > 0 {
                rung -= 1
                cheapStreak = 0
            }
        } else {
            cheapStreak = 0
        }
    }
}

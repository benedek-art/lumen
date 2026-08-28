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

    /// Top to bottom. 2048 is where a draft at fit is indistinguishable from the settle
    /// on a 5K display; 576 is where a frame IN MOTION still reads as the photograph.
    ///
    /// 1024 used to be the floor, under the reasoning that "below it the answer is the
    /// budget failing, not a smaller picture". That is true of a frame at REST and
    /// false of the only frames this ladder sizes. A draft exists for the duration of a
    /// hand's movement, and a moving image cannot show detail — the eye cannot resolve
    /// it, which is why every editor in this class drops preview resolution during a
    /// drag and restores it on release. Lumen already restores it: the settle runs at
    /// the full request the moment the gesture ends. So the floor was refusing the one
    /// trade that buys smoothness, on a machine that had already proved it could not
    /// afford 1024 — and the alternative it insisted on was not a sharper picture but a
    /// slower one, which is the picture arriving in steps.
    ///
    /// The ladder still only descends on MEASURED heat, so a machine with headroom
    /// never sees these rungs at all.
    public static let rungs: [Int] = [2048, 1600, 1280, 1024, 768, 576]

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

    /// Record what a draft cost.
    ///
    /// The two directions take DIFFERENT evidence, and conflating them is what left
    /// this ladder deaf on every window the app actually runs in.
    ///
    /// Heat is evidence wherever it is measured. Cost is monotone in pixels: a frame
    /// that blew the budget at 1280 px proves 2048 would have blown it harder, so a hot
    /// frame steps down whatever size it was rendered at. The old guard demanded
    /// `renderedLongEdge == rungs[rung]` in both directions — and at fit the loupe never
    /// asks for `rungs[0]`. `PhotoRenderModel.load` requests `max(1024, fullLongEdge/2)`
    /// where `fullLongEdge` is the viewport in device pixels bucketed to 256, so a
    /// 16-inch MacBook Pro's loupe asks for about 1280 and a 5K display for about 1728.
    /// Neither is 2048. The guard fired on every single frame of every drag at fit, the
    /// rung never moved, and the one mechanism whose job is to hold a drag inside
    /// `budgetMilliseconds` observed nothing for the life of the process. It looked
    /// correct because every test fed `requested: 4096` — the value the app asks for
    /// only when ZOOMED, which is the one place a drag does not normally happen.
    ///
    /// Cheapness is NOT transferable, and that half of the old guard was right: 1 ms at
    /// 512 px says nothing about whether 2048 is affordable, so a step UP still requires
    /// a run of frames rendered at the rung itself.
    ///
    /// Both directions still require the frame to have been this ladder's OWN answer —
    /// a caller that rendered some other size measured something else.
    public mutating func record(draftMilliseconds ms: Double, renderedLongEdge: Int,
                                requested: Int) {
        guard ms.isFinite, ms > 0 else { return }
        guard renderedLongEdge == longEdge(requested: requested) else { return }

        if ms > Self.stepDownOver {
            // Down to the first rung strictly CHEAPER THAN WHAT WAS JUST MEASURED, not
            // merely one index down.
            //
            // The rung index and the size delivered are two different things whenever
            // the caller's request is the binding constraint, which at fit it always
            // is: `longEdge` answers `min(rungs[rung], requested)`. A loupe asking for
            // 1280 with the ladder at rung 0 renders 1280, and stepping 2048 → 1600
            // changes the answer to `min(1600, 1280)` — 1280 again. The frame that was
            // too expensive would be rendered at exactly the same size it was too
            // expensive at, for as many hot frames as it takes to walk the index past
            // the request. Naming the measured size instead makes one hot frame mean
            // one visible step down, which is the "down fast" this ladder promises.
            let target = Self.rungs.firstIndex { $0 < renderedLongEdge }
                ?? (Self.rungs.count - 1)
            rung = Swift.max(rung, target)
            cheapStreak = 0
            return
        }
        // Anything short of heat clears the streak, including a cheap frame rendered
        // below the rung: it is not evidence FOR the rung, and letting it merely be
        // neutral would let a run of tiny frames sit inside a streak that a hot one
        // should have broken.
        guard renderedLongEdge == Self.rungs[rung], ms < Self.stepUpUnder else {
            cheapStreak = 0
            return
        }
        cheapStreak += 1
        if cheapStreak >= Self.stepUpAfter, rung > 0 {
            rung -= 1
            cheapStreak = 0
        }
    }
}

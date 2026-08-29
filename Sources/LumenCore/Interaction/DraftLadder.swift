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

    /// Top to bottom, in image pixels.
    ///
    /// 4096 is `LoupeView.maxRenderLongEdge`, the largest long edge the app ever asks
    /// for, so the TOP rung caps nothing: a machine with headroom drafts at exactly the
    /// resolution the settle will deliver and a drag is simply sharp. That is what the
    /// top of a ladder should mean — "as good as what you asked for", not "some
    /// fraction of it". The viewer used to take `max(floor, settle / 2)` before this
    /// ladder ever saw the number, so a drag was capped at half the settle's resolution
    /// on every machine forever; that is what made the picture go soft under the hand
    /// and sharpen on release, and it was a guess from before anything measured a frame.
    ///
    /// 576 is the floor. 1024 used to be, under the reasoning that "below it the answer
    /// is the budget failing, not a smaller picture" — true of a frame at REST and false
    /// of the only frames this ladder sizes. A draft exists for the duration of a hand's
    /// movement, and a moving image cannot show detail; the settle restores everything
    /// the moment the hand stops. Refusing to go below 1024 on a machine that had proved
    /// it could not afford 1024 bought not a sharper picture but a slower one.
    ///
    /// The steps between are close enough that one hot frame gives back a sensible
    /// amount rather than half the picture, since `record` steps to the first rung
    /// strictly below the size it just measured.
    ///
    /// MEASURED (`DragProbeTests`, per-rung, draft path, CI runner): 80.7 ms at 1728,
    /// 61.9 at 1280, 52.6 at 1024, 37.3 at 768, 34.8 at 576 — and 64.2 / 47.9 / 45.2 /
    /// 38.7 / 37.4 on a second run. Two monotone sweeps, so pixels genuinely buy frames
    /// all the way down. The ladder only descends on measured heat, so a machine with
    /// headroom never sees the low rungs at all.
    public static let rungs: [Int] = [4096, 3072, 2560, 2048, 1600, 1280, 1024, 768, 576]

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

    /// A gap between two delivered frames longer than this is not a drag — the hand
    /// paused, or the app was idle waiting for input. Half a second is far outside any
    /// continuous gesture's frame period and far inside a human pause.
    public static let continuityCeilingMilliseconds: Double = 500

    /// WHAT A FRAME ACTUALLY COST THE HAND, which is not what the renderer reports.
    ///
    /// `record` is fed a wall time measured around the render call. That covers actor
    /// queueing, the render and the readback — and nothing after it: handing the
    /// CGImage to SwiftUI, the body pass, the texture upload, compositing. None of
    /// that is small, and none of it is visible to a ladder that only times the render.
    /// The hole matters more the more pixels a draft carries, and removing the
    /// half-resolution cap quadrupled them: a fit draft went from about 4 MB per frame
    /// to 17, a zoomed one from 11 to 45. A ladder blind to that would sit at the top
    /// rung reporting cheap frames while the picture ticked.
    ///
    /// The interval BETWEEN two delivered frames does see all of it, because the next
    /// render cannot start until the main actor has finished with the last one. But it
    /// is only a measure of cost when the loop is saturated: a slow hand produces long
    /// gaps because the app was idle, and reading those as expense would step the
    /// ladder down for the crime of being asked for less.
    ///
    /// `handWasWaiting` is what separates the two, and the viewer already has the
    /// signal: `.task(id:)` cancels the render task the moment a newer event reaches
    /// the view, so a task that finds itself cancelled when its frame lands is one that
    /// had work queued behind it the whole time. That is saturation, exactly.
    public static func costSample(renderMilliseconds: Double,
                                  sincePreviousFrameMilliseconds: Double?,
                                  handWasWaiting: Bool) -> Double {
        guard handWasWaiting,
              let period = sincePreviousFrameMilliseconds,
              period.isFinite, period > 0,
              period <= continuityCeilingMilliseconds
        else { return renderMilliseconds }
        // The period should already include the render; `max` is the guard against a
        // clock or a pipeline that says otherwise, so the sample is never LESS than
        // work known to have happened.
        return Swift.max(renderMilliseconds, period)
    }

    /// EVERYTHING THE RENDER'S OWN TIMER CANNOT SEE, as a number rather than an
    /// inference.
    ///
    /// `costSample` above folds the display path into the ladder's input so the ladder
    /// stops being blind to it. This exposes the same quantity SEPARATELY, because the
    /// ladder and a person want different things from it: the ladder needs one cost to
    /// act on, and a person needs to know WHICH of the two halves is large, since they
    /// have opposite fixes. A slow render wants fewer pixels — which the ladder already
    /// does by itself. A cheap render whose frames still arrive slowly means the time is
    /// going somewhere after `createCGImage`: the handoff to SwiftUI as a fresh
    /// `Image(decorative:)`, the body pass, the texture upload, compositing — the path
    /// a Metal-layer viewport would replace and a resolution ladder would not.
    ///
    /// Three rounds of this project have argued about which of those it is without ever
    /// printing the difference, and `DragProbeTests` says in its own header that it
    /// stops one step before the answer. This is that step, measured where it actually
    /// happens.
    ///
    /// Nil unless the loop is saturated, for `costSample`'s reason: an idle gap between
    /// two frames is the hand's, not the machine's, and subtracting a render from it
    /// would report a hand's pause as a display cost.
    public static func afterRenderMilliseconds(renderMilliseconds: Double,
                                               sincePreviousFrameMilliseconds: Double?,
                                               handWasWaiting: Bool) -> Double? {
        guard handWasWaiting,
              let period = sincePreviousFrameMilliseconds,
              period.isFinite, period > 0,
              period <= continuityCeilingMilliseconds,
              renderMilliseconds.isFinite
        else { return nil }
        // Never negative: the period is measured landing-to-landing and the render is
        // measured inside it, so a larger render than period means a clock or an
        // ordering this function should report as "nothing after", not as a negative.
        return Swift.max(0, period - renderMilliseconds)
    }

    /// WHETHER A FRAME'S COST DESCRIBES THE STEADY STATE AT ITS SIZE.
    ///
    /// The ladder's lever is the decode scale. `PipelineRenderer.renderPreview` derives
    /// `scaleFactor` from the size it is asked for, runs the WHOLE graph at the decoded
    /// resolution, and only applies geometry afterwards — which is what makes a smaller
    /// rung genuinely cheaper. But `AppleRawSource` keys its decode cache on that scale
    /// factor, so the first frame at a NEW size pays a fresh RAW decode that no later
    /// frame at that size will pay. On a 45 MP file that decode is the largest single
    /// cost in the interaction.
    ///
    /// Feeding it to the ladder is a cascade. A hot frame steps down; the first frame at
    /// the new rung pays a decode and is therefore also slow; the ladder reads that as
    /// "the step did not help" and steps again; that pays another decode. It walks to
    /// the floor on a machine that could have held two rungs higher, and what the
    /// photographer sees is a drag that gets BLURRIER the longer it lasts — the
    /// complaint this round is about, arriving through the mechanism meant to prevent
    /// it.
    ///
    /// So a sample counts only when the previous frame was rendered at the same size.
    /// The first frame of a session, of a gesture after a zoom, and of every rung
    /// change is skipped. The cost of skipping is that a rung which cannot be afforded
    /// is caught on the second frame rather than the first; the cost of not skipping is
    /// a ladder that mistakes its own transition for the destination.
    public static func isRepresentative(renderedLongEdge: Int,
                                        previousRenderedLongEdge: Int?) -> Bool {
        guard let previous = previousRenderedLongEdge else { return false }
        return renderedLongEdge == previous
    }

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
    ///
    /// `allowStepUp` is false while a hand is on a control. Stepping DOWN mid-drag is a
    /// machine giving back what it cannot afford, and the hand feels it as the picture
    /// keeping up. Stepping UP mid-drag is the opposite trade — it spends frame rate on
    /// sharpness the eye cannot resolve in a moving picture — and it does something
    /// worse than that: at the boundary between two rungs it oscillates, and every
    /// crossing is a visible change in the picture's sharpness, several times a second,
    /// under the hand. That is a flicker of exactly the kind this project has just
    /// finished removing for a different reason. So within a gesture the ladder is
    /// monotone downward, and it earns rungs back between gestures, where a single
    /// change of sharpness is invisible.
    public mutating func record(draftMilliseconds ms: Double, renderedLongEdge: Int,
                                requested: Int, allowStepUp: Bool = true) {
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
        // BANKED while the hand is down, not discarded. Gating the step-up on "not
        // mid-gesture" is right — a rung earned back under a moving hand is a visible
        // change of sharpness. Throwing the evidence away with it is not, because
        // drags are very nearly the only time this ladder sees a frame at all: drafts
        // come from slider edits, and otherwise only from a photo switch, a zoom or a
        // matte landing. Discarding it made the ladder a one-way ratchet — one hard
        // drag on one heavy photograph dropped the rung for the rest of the session
        // and left every later drag needlessly soft on a machine that could afford
        // better. `gestureEnded` spends it.
        guard allowStepUp else { return }
        if cheapStreak >= Self.stepUpAfter, rung > 0 {
            rung -= 1
            cheapStreak = 0
        }
    }

    /// A SETTLE IS A MEASUREMENT OF THE TOP OF THE LADDER, AND THE LADDER WAS IGNORING
    /// IT.
    ///
    /// Climbing was `stepUpAfter` cheap frames for one rung, spent once per gesture. So
    /// from the floor the ladder needed EIGHT separate drags, each with twelve
    /// comfortable frames in it, to get back to full resolution. That is fine as a
    /// response to a machine that genuinely cannot afford the top rung, and badly wrong
    /// as a response to a TRANSIENT — a heavy photograph, a background task, or a defect
    /// since fixed. When every drag frame cost 457 ms because the decode was being
    /// re-run per frame, this ladder correctly walked to the floor; when that was fixed,
    /// it stayed there, and every slider stayed blurry on a machine that could by then
    /// afford anything. The owner reported precisely that, in those words.
    ///
    /// The evidence to climb was already being measured and thrown away. Every gesture
    /// ends with a settle: a render at the FULL requested size, timed by the same clock.
    /// And it is conservative evidence, which is what makes this sound rather than
    /// hopeful — a settle pays EXACT table bakes where a draft serves them stale, so a
    /// settle inside the budget proves a draft at that size is inside it too. An
    /// inequality, not an estimate.
    ///
    /// It only ever climbs, never claims a size it did not measure, and one settle is
    /// enough — which makes recovery immediate instead of eight gestures long.
    public mutating func recordSettle(milliseconds ms: Double, renderedLongEdge: Int) {
        guard ms.isFinite, ms > 0, ms < Self.budgetMilliseconds else { return }
        guard renderedLongEdge > 0 else { return }
        // The largest rung index whose size still covers what was measured. Naming the
        // measured size rather than jumping to rung 0 keeps the claim exactly as big as
        // the evidence: a cheap settle at 2560 says nothing about 4096.
        let target = Self.rungs.lastIndex { $0 >= renderedLongEdge } ?? 0
        rung = Swift.min(rung, target)
        cheapStreak = 0
    }

    /// The hand came up. Spend a streak banked during the gesture, where a single
    /// change of sharpness costs nothing to look at.
    ///
    /// Heat during the gesture will already have cleared the streak, so a drag that ran
    /// hot earns nothing here — which is the whole point: the evidence is a WHOLE
    /// gesture of comfortable frames, not a hopeful reset.
    public mutating func gestureEnded() {
        if cheapStreak >= Self.stepUpAfter, rung > 0 {
            rung -= 1
        }
        cheapStreak = 0
    }
}

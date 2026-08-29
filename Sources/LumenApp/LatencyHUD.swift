// LatencyHUD.swift
// The numbers behind "the sliders feel slow" (docs/23 M1b).
//
// Nine responsiveness fixes have landed across three rounds of this project and not
// one was ever verified by a measurement on the machine that matters. This is the
// instrument that ends that: with the HUD on (Debug menu), every draft and settle
// stamps its wall time — measured around the await, so actor queueing is included,
// because queueing is what a hand feels — and every pixel-touching edit stamps the
// input side, so the headline number is input→draft-on-screen, the latency contract's
// own definition (docs/12 §12.2).
//
// Off by default and free when off: the writes are gated on `enabled`, so no
// @Published fires per frame for a HUD nobody is looking at.
//
// THE OBSERVER EFFECT, stated rather than hidden. With the HUD ON, every input event
// publishes and re-bodies this one small view, and its body takes both cache locks to
// read their counters. That is main-actor work per mouse event added by the instrument
// whose headline number is how much main-actor work per mouse event there is. It is
// one view with six text lines against a window's worth of panels, so it does not
// change which explanation the `in/out` pair points at — but if the two rates are
// marginal rather than decisive, read them again with the HUD off by watching the
// picture instead, rather than trusting the fourth significant figure.

#if os(macOS)

import Foundation
import LumenCore
import LumenPipeline
import SwiftUI

@MainActor
final class LatencyHUD: ObservableObject {

    static let shared = LatencyHUD()
    private init() {}

    /// Gates every write. Plain var: toggling rides AppState's own publish.
    var enabled = false

    @Published private(set) var inputToDraftMs: Double?
    @Published private(set) var draftMs: Double?
    @Published private(set) var draftLongEdge: Int?
    @Published private(set) var settleMs: Double?
    @Published private(set) var settleLongEdge: Int?
    /// Set when the last draft came back SMALLER than it was asked for — the frame on
    /// screen is not the frame the ladder thinks it sized. Nil when they agree, so the
    /// line stays quiet in the normal case and speaks only when there is something to
    /// say.
    @Published private(set) var draftShortfall: Int?

    /// THE HALF OF A FRAME NOBODY HAS EVER PRINTED.
    ///
    /// `draftMs` is the render, measured around the await. This is the rest of the
    /// interval between two delivered frames while the loop is saturated: the CGImage
    /// handed to SwiftUI as a fresh `Image(decorative:)`, the body pass, the texture
    /// upload, compositing. `DragProbeTests` says in its own header that it stops one
    /// step before this, and the last three rounds have argued about whether it matters
    /// without measuring it. Nil when the hand is not saturating the loop, because then
    /// the gap is the hand's.
    @Published private(set) var afterRenderMs: Double?

    /// THE PAIR THAT ENDS THE ARGUMENT.
    ///
    /// Latency alone cannot tell the two explanations for a stepping slider apart, and
    /// they want opposite fixes. Input at 60–120/s with frames at 8/s is a render that
    /// cannot keep up with a hand it can see. Input at 10/s with frames at 10/s is a
    /// render loop keeping up perfectly with a gesture it is only seeing a tenth of —
    /// the main actor missing its window between two mouse-moved events and AppKit
    /// coalescing the rest, which no render optimisation touches. `EventRate` in
    /// LumenCore holds the arithmetic and the argument in full.
    @Published private(set) var inputsPerSecond: Double?
    @Published private(set) var framesPerSecond: Double?

    /// HOW FAST THE COLOUR TABLES ARE ACTUALLY LANDING.
    ///
    /// A third explanation for a stepping slider, which neither `in/out` nor
    /// `draft/after` can see, and which applies to exactly the controls the owner names
    /// most: Whites and Blacks move the tone ANCHORS, which re-keys `finishLUT` on every
    /// mouse event. The drag then rides `tableAllowingStale` while the exact bake — 15
    /// to 18 ms of 35 937 samples — runs on `bakeQueue`.
    ///
    /// So for those controls the picture's visible response is gated by the BAKE rate,
    /// not the frame rate. The renderer can deliver thirty frames a second that are all
    /// the same picture, because they are all reading the same stale table, and the
    /// picture only moves when a bake lands. Thirty honest frames a second showing ten
    /// distinct pictures is a slider that ticks, and every instrument this project has
    /// built so far would call it healthy.
    ///
    /// The counters for this already existed; only the totals were shown, which cannot
    /// be read during a drag. A rate can.
    @Published private(set) var bakesPerSecond: Double?
    @Published private(set) var staleServesPerSecond: Double?

    private var lastInputAt: UInt64?
    private var inputRate = EventRate()
    private var frameRate = EventRate()
    private var lastTableStats: PlanTableCache.Stats?
    private var lastTableStatsAt: Double?

    private func nowSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    /// A pixel-touching edit happened. The next draft that lands closes the loop.
    func noteInput() {
        guard enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lastInputAt = now
        inputRate.record(at: Double(now) / 1e9)
        inputsPerSecond = inputRate.perSecond(now: Double(now) / 1e9)
    }

    /// `longEdge` is what was DELIVERED; `requestedLongEdge` is what was asked for.
    /// Printing only the request is how a blurry picture reported "@2560" for three
    /// rounds: the number could not disagree with the code that chose it, so it
    /// confirmed the viewer's intention and said nothing about the frame. Measured
    /// against the delivered extent it becomes evidence — a shortfall means the render
    /// path returned less than the ladder thinks it sized, which is a lead on any
    /// uncropped photograph.
    func noteDraft(milliseconds: Double, longEdge: Int, requestedLongEdge: Int? = nil,
                   afterRenderMilliseconds: Double? = nil) {
        guard enabled else { return }
        draftMs = milliseconds
        draftLongEdge = longEdge
        // KEPT, not overwritten with nil — otherwise this line can never be read.
        //
        // `afterRenderMilliseconds` is nil unless the loop was saturated when the frame
        // landed, and the LAST frame of every gesture is by definition the one with
        // nothing queued behind it. Assigning it unconditionally meant the final frame
        // of every drag wiped the reading, so the number was only ever on screen while
        // the hand was moving — which is exactly when nobody can read a HUD. All five of
        // the owner's screenshots show a dash here, and that is why.
        //
        // So the last MEASURED value stays up. The rates above go to "—" when the drag
        // stops, which is what tells a reader this number belongs to the gesture that
        // just ended rather than to right now.
        if let afterRenderMilliseconds { afterRenderMs = afterRenderMilliseconds }
        if let requestedLongEdge, requestedLongEdge > longEdge {
            draftShortfall = requestedLongEdge
        } else {
            draftShortfall = nil
        }
        let now = nowSeconds()
        frameRate.record(at: now)
        framesPerSecond = frameRate.perSecond(now: now)
        sampleTableTraffic(now: now)
        // A drag that has stopped must stop claiming a rate, or the last number of the
        // last gesture is read as the current one.
        if inputRate.isIdle(now: now) { inputsPerSecond = nil }
        if let input = lastInputAt {
            inputToDraftMs = Double(DispatchTime.now().uptimeNanoseconds - input) / 1e6
            lastInputAt = nil  // one edit, one closure of the loop
        }
    }

    /// Turn the cache's running totals into rates, sampled once per delivered frame.
    ///
    /// Deltas rather than an `EventRate`, because the counters are incremented inside
    /// the cache by whatever thread is baking; this side only ever reads them. A gap
    /// longer than a gesture means the drag stopped, so the rates are dropped rather
    /// than averaged across a pause — the same reasoning as `EventRate.isIdle`.
    private func sampleTableTraffic(now: Double) {
        let stats = PlanTableCache.currentStats
        defer { lastTableStats = stats; lastTableStatsAt = now }
        guard let previous = lastTableStats, let at = lastTableStatsAt else { return }
        let elapsed = now - at
        guard elapsed > 0, elapsed < 1.0 else {
            bakesPerSecond = nil
            staleServesPerSecond = nil
            return
        }
        bakesPerSecond = Double(stats.bakes - previous.bakes) / elapsed
        staleServesPerSecond = Double(stats.staleServes - previous.staleServes) / elapsed
    }

    func noteSettle(milliseconds: Double, longEdge: Int) {
        guard enabled else { return }
        settleMs = milliseconds
        settleLongEdge = longEdge
    }
}

/// The overlay itself: three monospaced lines in the loupe's corner. Numbers, not
/// judgement — the budgets live in docs/12 and the owner's eye.
struct LatencyHUDView: View {
    @ObservedObject private var hud = LatencyHUD.shared

    private func line(_ label: String, _ ms: Double?, _ edge: Int?) -> String {
        guard let ms else { return "\(label)      —" }
        let size = edge.map { " @\($0)" } ?? ""
        return String(format: "%@ %6.1f ms%@", label, ms, size)
    }

    /// hits / bakes / stale-serves since launch. Read live at render — the view
    /// re-renders on every draft and settle note, which is exactly when the numbers
    /// have moved. The tables line is the fraud detector M1a promised: a drag whose
    /// hit+stale share is not ~100% after its first frame means a cache key is being
    /// defeated, and no eye can see that without the counter.
    private func cacheLine(_ label: String, hits: Int, bakes: Int,
                           stale: Int) -> String {
        "\(label) \(hits)h \(bakes)b \(stale)s"
    }

    /// Events the app SAW per second against frames it delivered per second, on one
    /// line because neither number means anything alone. Read it during a drag: the two
    /// being close and low is dropped input; `in` high and `out` low is the render.
    private func rateLine(in inputs: Double?, out frames: Double?) -> String {
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "  — " }
            return String(format: "%4.0f", value)
        }
        return "in/out    \(number(inputs))/s \(number(frames))fps"
    }

    /// Bakes landing against tables served stale, per second. Read during a drag on
    /// Whites or Blacks: `stale/s` near the input rate with `bakes/s` far below it means
    /// the frames are honest and the PICTURE is not moving with them.
    private func rateLine(bakes: Double?, stale: Double?) -> String {
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "  — " }
            return String(format: "%4.0f", value)
        }
        return "bake/stale\(number(bakes))/s \(number(stale))/s"
    }

    var body: some View {
        let tables = PlanTableCache.currentStats
        let rasters = MaskRasterCache.currentStats
        return VStack(alignment: .leading, spacing: 2) {
            Text(rateLine(in: hud.inputsPerSecond, out: hud.framesPerSecond))
            Text(line("input→draft", hud.inputToDraftMs, nil))
            Text(line("draft      ", hud.draftMs, hud.draftLongEdge)
                    + (hud.draftShortfall.map { " (asked \($0))" } ?? ""))
            // Sits directly under `draft` because the two are one frame split in half,
            // and the split is the whole diagnosis: `draft` large wants fewer pixels,
            // which the ladder already does by itself; `after` large wants a Metal
            // plate, which nothing in this app has yet.
            Text(line("after      ", hud.afterRenderMs, nil))
            Text(line("settle     ", hud.settleMs, hud.settleLongEdge))
            Text(cacheLine("tables     ", hits: tables.hits, bakes: tables.bakes,
                           stale: tables.staleServes))
            // The same two counters as RATES, which is the only form in which they can
            // be read during a drag. On Whites and Blacks every event re-keys the finish
            // table, so `stale/s` tracks the hand and `bakes/s` is how often the picture
            // can actually CHANGE: a frame served a stale table is the previous
            // picture, however honest the frame rate above it looks.
            Text(rateLine(bakes: hud.bakesPerSecond, stale: hud.staleServesPerSecond))
            Text(cacheLine("rasters    ", hits: rasters.hits, bakes: rasters.bakes,
                           stale: rasters.staleServes))
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Lumen.primaryText)
        .padding(6)
        .background(Color.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .allowsHitTesting(false)
    }
}

#endif

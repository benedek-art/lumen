// DragProbeTests.swift
// What a DRAG frame costs — the measurement this repository has never had.
//
// `PerfProbeTests` next door prints a graph-cost table, and it cannot answer the
// owner's complaint, because it measures the opposite of a drag in four ways at once:
// it takes the BEST of four repetitions, reuses ONE `RenderPlan` across all of them,
// renders the SAME source every time, and excludes the decode. That is the ideal warm
// case. A drag is a new plan on every frame — the whole point is that a number moved —
// over a source the renderer must re-derive, and what a hand feels is not the best
// frame but the WORST ones: a p95 of 90 ms with a p50 of 30 is a picture that steps,
// and a best-of-four would print 30 and call it fine.
//
// So this file measures the four things that decide whether a slider feels connected:
//
//   1. THE DISTRIBUTION. Every frame of a simulated 48-event drag is timed and the
//      p50 / p95 / max printed. `DraftLadder.budgetMilliseconds` (35 ms) is the bar.
//   2. PER CONTROL. Exposure moves one matrix; Whites moves the tone ANCHORS, which
//      re-keys the finish LUT; a mixer slider re-keys the colour+grade LUT; Texture
//      moves presence. These have very different per-frame costs and the owner reports
//      them all as equally bad, so the numbers should say which of that is true.
//   3. PER SIZE, across the rungs the app actually asks for at fit (~1280 on a 16-inch
//      MacBook Pro, ~1728 on a 5K panel) and the cheap rungs the ladder can now reach.
//   4. LAZY vs MATERIALIZED input, and WITH vs WITHOUT the CPU readback — the two
//      structural costs the drag loop pays per frame and could stop paying.
//
// WHERE THIS PROBE STOPS, stated because a conclusion was once drawn past it. The last
// thing timed is `createCGImage` (or the render into an IOSurface). What happens NEXT
// in the app is not measured here at all: the finished CGImage is handed to SwiftUI as
// a fresh `Image(decorative:)` every frame, which becomes layer contents and a texture
// upload on the main actor — about 4.4 MB at 1280×853 RGBA8. So the readback rows below
// answer "is the GPU→CPU copy inside the RENDER expensive" (no) and say nothing about
// whether DISPLAYING the result is. A Metal-layer viewport replaces the second of those,
// not the first, and this file is not evidence against it.
//
// Everything here PRINTS and asserts only a sanity ceiling. A shared CI runner's GPU is
// not the owner's Mac, and a threshold tuned to one would fail spuriously on the other;
// the numbers are read from the log and from the in-app HUD. What the file guarantees
// is that the numbers exist and describe a drag.
//
// HOW TO READ THE OUTPUT, because two conclusions have already been drawn from it
// wrongly. This runner's noise floor is large: in one run the SAME measurement —
// Exposure, draft path, 1280 px — appears three times, in the per-control table, the
// per-rung table and the structural table, at 64.4, 47.9 and 50.5 ms. That is a 34%
// spread on an identical configuration, so
//
//   · a MONOTONE SWEEP is trustworthy. The rung ladder fell 1728 → 576 in both runs
//     that have taken it, by 2.32× and 1.72×; five points moving together in one
//     direction is not noise, and that is the finding that fewer pixels still buy
//     frames.
//   · a ROW-VS-ROW difference under about 40% is NOT. "Materializing the decode is
//     worth ~10%" was recorded from one run and reversed in the next (lazy+iosurface
//     44.1 against materialized+iosurface 47.0). "Exposure is the expensive control"
//     survived a warm-up pass and is still just its own 34% spread.
//
// So: to test one change, sweep it, or run it enough times to beat the floor. Do not
// read two adjacent rows and conclude.
#if os(macOS)
import XCTest
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
@testable import LumenCore
@testable import LumenPipeline

final class DragProbeTests: XCTestCase {

    // MARK: - The drag being simulated

    /// A human drag of about half a second at display rate. Long enough for a p95 to
    /// mean something, short enough to keep the whole probe inside the lane's budget.
    private static let events: Int = 48

    /// How many SETTLE frames to price. A settle happens once per gesture, so what is
    /// wanted from it is an order of magnitude, not a tail.
    private static let settleEvents: Int = 12

    /// Which slider the hand is on. Each case moves ONE control across a realistic
    /// travel, because what a frame costs depends on which tables the move invalidates
    /// — the difference between hitting `PlanTableCache` and cold-baking a 33³ LUT.
    private enum Control: String, CaseIterable {
        case exposure   = "Exposure"      // S6 matrix only; every table cached
        case whites     = "Whites"        // moves the tone anchors → re-keys the finish LUT
        case texture    = "Texture"       // S8 presence, a real spatial cost
        case saturation = "Saturation"    // re-keys the colour+grade LUT
        case sharpen    = "Sharpen"       // S12, spatial, at the end of the graph

        /// The recipe at `t` ∈ 0…1 through the drag, on a photograph that already has
        /// work on it — a drag never starts from an empty recipe, and an empty one
        /// short-circuits half the graph's identity checks.
        func recipe(at t: Double) -> Recipe {
            var r = Recipe()
            r.develop.tone.exposure = 0.4
            r.develop.tone.contrast = 20
            r.develop.tone.highlights = -40
            r.develop.tone.shadows = 25
            r.develop.raw.temp = 5200
            r.develop.color.vibrance = 10
            r.develop.detail.clarity = 25
            r.develop.detail.sharpen.amount = 60
            r.develop.denoise.mode = .classic
            switch self {
            case .exposure:   r.develop.tone.exposure = -1 + 2 * t
            case .whites:     r.develop.tone.whites = -60 + 120 * t
            case .texture:    r.develop.detail.texture = 100 * t
            case .saturation: r.develop.color.saturation = -50 + 100 * t
            case .sharpen:    r.develop.detail.sharpen.amount = 100 * t
            }
            return r
        }
    }

    // MARK: - Sources

    /// A frame with gradients and fine structure, as a LAZY Core Image recipe — the
    /// shape `AppleRawSource.decode` hands the graph. Its cache holds
    /// `filter.outputImage`, which is a description of work, not the result of it, so
    /// whatever sits above it may be re-derived on every evaluation.
    private func lazyFrame(longEdge: Int) -> CIImage {
        let w = longEdge, h = longEdge * 2 / 3
        let rect = CGRect(x: 0, y: 0, width: w, height: h)

        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: w, y: h)
        gradient.color0 = CIColor(red: 0.02, green: 0.03, blue: 0.05)
        gradient.color1 = CIColor(red: 0.9, green: 0.8, blue: 0.6)

        let checker = CIFilter.checkerboardGenerator()
        checker.width = 6
        checker.color0 = CIColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
        checker.color1 = CIColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)

        return checker.outputImage!.cropped(to: rect)
            .applyingFilter("CIMultiplyCompositing",
                            parameters: [kCIInputBackgroundImageKey:
                                            gradient.outputImage!.cropped(to: rect)])
    }

    /// The same picture, evaluated ONCE into real pixels and re-wrapped. This is what
    /// caching a decode would look like if it cached the decode rather than the
    /// intention to decode.
    private func materializedFrame(longEdge: Int, context: CIContext) -> CIImage {
        let lazyImage = lazyFrame(longEdge: longEdge)
        guard let cg = context.createCGImage(lazyImage, from: lazyImage.extent) else {
            return lazyImage
        }
        return CIImage(cgImage: cg)
    }

    // MARK: - Timing

    private struct Distribution {
        let p50: Double
        let p95: Double
        let max: Double
        let over: Int          // frames past the drag budget
        let count: Int
        /// What the table cache did across the drag. On the draft path a frame that
        /// served STALE is a frame whose colour is as old as the outstanding bake — so
        /// "47 stale of 47" plus a slow bake is a picture stepping at the bake's rate
        /// even though every frame here timed fast.
        let traffic: PlanTableCache.Stats?

        init(_ samples: [Double], traffic: PlanTableCache.Stats? = nil) {
            self.traffic = traffic
            let sorted = samples.sorted()
            func at(_ q: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                let i = Swift.min(sorted.count - 1,
                                  Swift.max(0, Int((Double(sorted.count - 1) * q).rounded())))
                return sorted[i]
            }
            p50 = at(0.50)
            p95 = at(0.95)
            max = sorted.last ?? 0
            over = samples.filter { $0 > DraftLadder.budgetMilliseconds }.count
            count = samples.count
        }

        var line: String {
            let head = String(
                format: "p50 %6.1f  p95 %6.1f  max %6.1f  over-budget %2d/%2d",
                p50, p95, max, over, count)
            guard let traffic else { return head }
            return head + String(format: "  tables %dh/%db/%ds",
                                 traffic.hits, traffic.bakes, traffic.staleServes)
        }
    }

    /// Run one simulated drag and time every frame the way the app pays for it: a fresh
    /// plan, the graph rebuilt, and the pixels forced.
    ///
    /// `readback` chooses how the frame is forced. `true` is what the viewer does
    /// today — `createCGImage`, a synchronous GPU→CPU copy of the whole frame, which
    /// SwiftUI then uploads back to the GPU as an `Image` texture. `false` renders into
    /// an IOSurface and never leaves the GPU, which is what a Metal-layer viewport
    /// would do. The difference between the two is the cost of the round trip.
    private func drag(control: Control, longEdge: Int, source: CIImage,
                      context: CIContext, readback: Bool,
                      allowStaleTables: Bool = true) -> Distribution {
        let height = longEdge * 2 / 3
        // A drag is many frames and wants a p95; a settle is ONE frame per gesture and
        // needs only enough samples to be a number. Sampling both at 48 would spend
        // most of this probe's runtime re-measuring the bake it already knows about —
        // a Whites settle is ~385 ms on the runner, so 47 of them is eighteen seconds
        // of lane time for a distribution nobody reads the tail of.
        let events = allowStaleTables ? Self.events : Self.settleEvents
        var samples: [Double] = []
        samples.reserveCapacity(events)
        // Accumulated PER TIMED FRAME rather than once around the whole row, because a
        // settle row now renders an untimed draft before each sample (below) and that
        // draft's traffic is not the settle's.
        var traffic = PlanTableCache.Stats()
        let options = RenderGraph.Options(longEdge: longEdge,
                                          lutSize: LUT3D.interactiveSize)

        // IOSurface-backed, so the frame can be produced without ever crossing back to
        // the CPU — the comparison the readback line below is for.
        var destination: CVPixelBuffer?
        if !readback {
            let attributes: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, longEdge, height,
                                kCVPixelFormatType_32BGRA, attributes as CFDictionary,
                                &destination)
        }

        for event in 0..<events {
            // A hand does not land on round numbers, and a value that repeats would let
            // a cache answer a question the drag never asks.
            //
            // THE SETTLE SAMPLES A SUBSET OF THE DRAFT'S OWN VALUES. It used to sample
            // `(event + 0.5) / 12` against the draft's `(event + 0.5) / 48` — odd
            // ninety-sixths against even ones — so the two sets could never coincide,
            // and the settle row was measured against a cache full of tables it was
            // arithmetically incapable of asking for. `0h` was guaranteed before the
            // first frame ran, and the row was read for two rounds as "the settle path
            // is not wired to the cache", which was false. A settle is the frame after
            // a drag ENDS, on the value the hand stopped at; it is priced here at every
            // fourth value the draft just visited, which is that frame.
            let stride = Self.events / Self.settleEvents
            let index = allowStaleTables ? event : event * stride
            let t = (Double(index) + 0.5) / Double(Self.events)
            let recipe = control.recipe(at: t)

            // A SETTLE IS THE FRAME AFTER A DRAG ENDS, and this is the half of I1-02
            // that sampling a subset of the draft's values did not fix.
            //
            // The settle row renders 12 frames at spread values with nothing before
            // them, so the cache it meets is whatever the previous row left. The draft
            // row before it visited 48 values re-keying the finish table at each, and
            // the cache holds EIGHT entries per slot — so by the time the draft ends,
            // only its last eight keys are resident, and a settle sampling the whole
            // travel can address at most one of them. `0h/36b` on Whites was
            // arithmetically guaranteed before the first frame ran, and it has been
            // read for three rounds as "the settle path is not wired to the cache".
            //
            // What a settle actually meets is the cache the drag that just ended left
            // one mouse event ago. So each settle sample now renders its own draft
            // frame first, untimed, at the same value: the drag's last event, then the
            // settle. That is the pair the photographer performs, and it is the only
            // arrangement in which this row's hit count means anything.
            if !allowStaleTables {
                let lastDragFrame = RenderPlan(recipe: recipe,
                                               lutSize: LUT3D.interactiveSize,
                                               allowStaleTables: true)
                let warm = RenderGraph().build(source, plan: lastDragFrame,
                                               options: options)
                _ = context.createCGImage(warm, from: warm.extent, format: .RGBA8,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }

            PlanTableCache.resetStats()
            let t0 = DispatchTime.now().uptimeNanoseconds
            // `allowStaleTables` is the whole difference between a DRAFT and a SETTLE,
            // and getting it wrong makes this probe measure the wrong pass entirely:
            // with it false, every frame blocks on an exact 33³ bake, which is what a
            // settle does once per gesture and what a drag must never do.
            let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.interactiveSize,
                                  allowStaleTables: allowStaleTables)
            let out = RenderGraph().build(source, plan: plan, options: options)
            if let destination {
                context.render(out, to: destination, bounds: out.extent,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            } else {
                _ = context.createCGImage(out, from: out.extent, format: .RGBA8,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            let frame = PlanTableCache.currentStats
            traffic.hits += frame.hits
            traffic.bakes += frame.bakes
            traffic.staleServes += frame.staleServes
            traffic.deferredBakes += frame.deferredBakes
            traffic.joinedBakes += frame.joinedBakes

            // The first event of a gesture pays warm-up the rest of the drag does not,
            // and it is not what "the slider ticks" describes.
            if event > 0 { samples.append(ms) }
        }
        return Distribution(samples, traffic: traffic)
    }

    private func context() -> CIContext {
        CIContext(options: [.workingFormat: CIFormat.RGBAh])
    }

    /// Run some frames and throw them away, before anything is timed.
    ///
    /// NOT the same as dropping the first event of each drag, which this file already
    /// did and which is not enough. Core Image compiles a kernel the first time it is
    /// evaluated, and the graph holds a dozen of them, so the cost is paid once PER
    /// PROCESS — and it lands entirely on whichever row happens to be measured first.
    /// The run that exposed this reported Exposure at a 63.3 ms p50 against Whites at
    /// 27.9, Saturation at 25.0 and Sharpen at 22.5, which reads as "Exposure is the
    /// expensive control" and is the exact opposite of the truth: Exposure re-keys the
    /// fewest tables of the five. It was simply first in `Control.allCases`. The
    /// per-rung table had the same tell — its first row, 1728, was the only one out of
    /// line with the curve below it.
    ///
    /// A probe whose first row is always wrong is worse than no probe, because the
    /// first row is the one a reader anchors on.
    private func warmUp(context: CIContext, longEdge: Int) {
        let source = materializedFrame(longEdge: longEdge, context: context)
        for i in 0..<4 {
            let recipe = Control.exposure.recipe(at: Double(i) / 4)
            let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.interactiveSize,
                                  allowStaleTables: false)
            let out = RenderGraph().build(
                source, plan: plan,
                options: RenderGraph.Options(longEdge: longEdge,
                                             lutSize: LUT3D.interactiveSize))
            _ = context.createCGImage(out, from: out.extent, format: .RGBA8,
                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
    }

    /// SAY WHICH BUILD THESE NUMBERS CAME FROM, every time.
    ///
    /// `swift test` builds debug, and the two halves of a frame respond to that very
    /// differently: the GPU time is the GPU's and barely moves, while everything on the
    /// CPU — `RenderPlan`'s construction, and above all a 33³ table bake, which is
    /// ~36 000 evaluations of a transform containing three cube roots, an `atan2`, a
    /// sine and a cosine — is inflated by roughly an order of magnitude with the
    /// optimiser off. A debug bake read as a shipping cost is a fictional emergency;
    /// a release bake read as a debug artefact is a real one dismissed. The line is
    /// printed rather than left to be remembered.
    private func printBuildMode() {
        #if DEBUG
        print("DRAGPROBE build: DEBUG — CPU-side costs (plan construction, table "
                + "bakes) are inflated roughly 10× against the shipping build. GPU "
                + "time is not. Compare rows, not absolutes.")
        #else
        print("DRAGPROBE build: RELEASE")
        #endif
    }

    /// Left-aligned to a fixed width, so the printed table reads as columns. Done here
    /// rather than with `%-12@`: the width flag applies to the pointer, not the string,
    /// for an object conversion, and prints unpadded.
    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text
            : text + String(repeating: " ", count: width - text.count)
    }

    // MARK: - The probes

    /// THE HEADLINE. Every control, at the size a real loupe asks for at fit, timed per
    /// frame with a fresh plan — the number the owner's "tick by tick" is a description
    /// of.
    /// THE SETTLE ROW HAS TO BE ABLE TO HIT THE CACHE (I1-02).
    ///
    /// N-002 — "the settle path bakes tables with zero cache hits" — has been read off
    /// this probe for three rounds, and for three rounds it was arithmetic rather than
    /// a measurement. Two separate reasons, both in the sampling:
    ///
    /// 1. The settle used to sample `(e + 0.5) / 12` against the draft's
    ///    `(e + 0.5) / 48` — odd ninety-sixths against even ones, two sets that can
    ///    never coincide. `0h` was guaranteed before the first frame ran.
    /// 2. Fixing that to a subset was not enough. The cache holds EIGHT entries per
    ///    slot; a Whites drag re-keys the finish table at all 48 values, so only its
    ///    last eight survive, and a settle spread across the whole travel can address
    ///    at most one of them.
    ///
    /// Both are fixed — the values are a subset, and each settle sample now renders its
    /// own draft frame first, which is what a settle IS. These assertions are the
    /// arithmetic, so they fail without a GPU and without waiting for the probe.
    func testTheSettleRunCanAddressWhatTheDraftRunLeftBehind() {
        let stride = Self.events / Self.settleEvents
        XCTAssertGreaterThan(stride, 0,
                             "settleEvents must divide into events, or the settle's "
                                 + "sample values stop being draft values at all")
        XCTAssertEqual(stride * Self.settleEvents, Self.events,
                       "\(Self.events) draft events do not divide evenly into "
                           + "\(Self.settleEvents) settle events, so the last settle "
                           + "sample walks off the end of the drag")

        let draftValues = Set((0..<Self.events).map { (Double($0) + 0.5) / Double(Self.events) })
        let settleValues = (0..<Self.settleEvents)
            .map { (Double($0 * stride) + 0.5) / Double(Self.events) }
        for v in settleValues {
            XCTAssertTrue(draftValues.contains(v),
                          "the settle prices \(v), which the draft never visits — so "
                              + "the cache cannot hold a table for it however well the "
                              + "render path is wired")
        }

        // And the second half: a settle must not be asked to hit a table the drag
        // pushed out. Whites re-keys the finish slot at every one of the 48 values and
        // the slot holds 8, so the only settle samples the drag could still be holding
        // are the ones inside its last eight events — which is why each settle sample
        // renders its own draft frame instead of relying on the row before it.
        //
        // TWO of twelve, and the first version of this assertion said one and went red
        // on the lane. The settle values are `(4e + 0.5)/48`, so the last two are 40.5
        // and 44.5 and BOTH sit inside the final eight events (40…47). Ten of twelve
        // were unreachable, which is the point and is unchanged; the count was simply
        // miscounted.
        let lastResidentEvent = Self.events - PlanTableCache.capacityPerSlot
        let reachableWithoutItsOwnDraft = settleValues.filter {
            $0 > Double(lastResidentEvent) / Double(Self.events)
        }
        XCTAssertEqual(
            reachableWithoutItsOwnDraft.count, 2,
            "this assertion exists to record WHY the settle renders its own draft "
                + "frame: with a \(PlanTableCache.capacityPerSlot)-entry slot and a "
                + "control that re-keys on every event, only \(reachableWithoutItsOwnDraft.count) "
                + "of these \(Self.settleEvents) samples could survive the drag. If "
                + "that stops being true the pairing can be revisited — but do not "
                + "remove it on the strength of a green row")
    }

    func testWhatADragFrameCostsPerControl() throws {
        let ctx = context()
        // ≈ a 16-inch MacBook Pro's loupe at fit: a 1180 pt centre pane at 2× buckets
        // to 2560, and `PhotoRenderModel.load` asks for half of it.
        let longEdge = 1280
        warmUp(context: ctx, longEdge: longEdge)
        let source = materializedFrame(longEdge: longEdge, context: ctx)

        printBuildMode()
        print("DRAGPROBE ── per control, \(longEdge) px, budget "
                + "\(DraftLadder.budgetMilliseconds) ms ──")
        // DRAFT is what every frame of a drag pays; SETTLE is what the one frame after
        // the hand stops pays. They differ by `allowStaleTables`, and the gap between
        // them is the whole value of stale-while-bake — printed rather than assumed,
        // because the first version of this probe passed `false` for both and reported
        // a settle's cost as a drag's, which is a 10× error in the direction of panic.
        for control in Control.allCases {
            for stale in [true, false] {
                let d = drag(control: control, longEdge: longEdge, source: source,
                             context: ctx, readback: true, allowStaleTables: stale)
                print("DRAGPROBE \(stale ? "draft " : "settle") "
                        + "\(pad(control.rawValue, 11)) \(d.line)")
                XCTAssertLessThan(d.max, 10_000,
                                  "a \(control.rawValue) frame took over ten seconds — "
                                      + "something is broken, not merely slow")
            }
        }
    }

    /// What the ladder buys. The rungs the app asks for at fit (1728, 1280) against the
    /// cheap rungs it can now reach once a hot frame is actually heard (768, 576).
    ///
    /// The ladder could not reach any of them before: `record` demanded a frame
    /// rendered at exactly `rungs[rung]`, and at fit the loupe never asks for one, so
    /// the rung never moved however long the frames took.
    func testWhatEachRungCostsUnderADrag() throws {
        let ctx = context()
        printBuildMode()
        for longEdge in [1728, 1280, 1024, 768, 576] { warmUp(context: ctx, longEdge: longEdge) }
        print("DRAGPROBE ── per rung, Exposure (draft path), budget "
                + "\(DraftLadder.budgetMilliseconds) ms ──")
        for longEdge in [1728, 1280, 1024, 768, 576] {
            let source = materializedFrame(longEdge: longEdge, context: ctx)
            let d = drag(control: .exposure, longEdge: longEdge, source: source,
                         context: ctx, readback: true)
            print("DRAGPROBE rung \(pad(String(longEdge), 5)) \(d.line)")
            XCTAssertLessThan(d.max, 10_000, "a frame at \(longEdge) px took over ten "
                                  + "seconds — something is broken, not merely slow")
        }
    }

    /// The two structural costs the drag loop pays on every frame, priced separately so
    /// the work to remove them can be ranked before it is done rather than after.
    ///
    ///   · LAZY vs MATERIALIZED source — `AppleRawSource.decodeCache` USED TO STORE
    ///     `filter.outputImage`, a description of the decode rather than its pixels, so
    ///     whatever it takes to produce them was paid again on every frame of the drag.
    ///     Here the input is a two-filter generator chain; a 45 MP RAW's demosaic is a
    ///     great deal more than two filters, so treat the gap this prints as a FLOOR on
    ///     what materializing a real decode is worth, not an estimate of it.
    ///
    ///     THE FLOOR NOW HAS A CEILING BESIDE IT, measured in the app on the owner's
    ///     machine rather than here: a draft frame at 2048 px cost **457 ms** against a
    ///     settle at 2560 px costing **14.5 ms** — thirty times slower at a smaller
    ///     size, which is a 33 MP demosaic running once per frame and nothing else.
    ///     This probe printed single-digit percentages for the same defect and the
    ///     conclusion drawn from it was that materializing was not worth doing. The
    ///     caveat above was right and was read as noise. The lesson is narrower than
    ///     "measure": a probe whose SUBJECT is synthetic cannot bound a cost that lives
    ///     entirely in the thing it replaced. `AppleRawSource` now materializes, so
    ///     these rows measure a defect the app no longer has — keep them, because they
    ///     are what a regression would show up in.
    ///   · READBACK vs IOSurface — the viewer ends every frame with `createCGImage`, a
    ///     synchronous GPU→CPU copy of the whole frame, which SwiftUI then uploads back
    ///     to the GPU. Rendering to an IOSurface prices the same frame without the
    ///     round trip.
    func testWhatTheLazySourceAndTheReadbackCost() throws {
        let ctx = context()
        let longEdge = 1280
        warmUp(context: ctx, longEdge: longEdge)
        let lazyInput = lazyFrame(longEdge: longEdge)
        let materialized = materializedFrame(longEdge: longEdge, context: ctx)

        printBuildMode()
        print("DRAGPROBE ── structural costs, Exposure (draft path), \(longEdge) px ──")
        let pairs: [(String, CIImage, Bool)] = [
            ("lazy   + readback", lazyInput, true),
            ("materialized + readback", materialized, true),
            ("lazy   + iosurface", lazyInput, false),
            ("materialized + iosurface", materialized, false),
        ]
        for (name, source, readback) in pairs {
            let d = drag(control: .exposure, longEdge: longEdge, source: source,
                         context: ctx, readback: readback)
            print("DRAGPROBE \(pad(name, 26)) \(d.line)")
            XCTAssertLessThan(d.max, 10_000,
                              "\(name) took over ten seconds — broken, not slow")
        }
    }
}
#endif

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
// Everything here PRINTS and asserts only a sanity ceiling. A shared CI runner's GPU is
// not the owner's Mac, and a threshold tuned to one would fail spuriously on the other;
// the numbers are read from the log and from the in-app HUD. What the file guarantees
// is that the numbers exist and describe a drag.
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

        init(_ samples: [Double]) {
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
            String(format: "p50 %6.1f  p95 %6.1f  max %6.1f  over-budget %2d/%2d",
                   p50, p95, max, over, count)
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
                      context: CIContext, readback: Bool) -> Distribution {
        let height = longEdge * 2 / 3
        var samples: [Double] = []
        samples.reserveCapacity(Self.events)

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

        for event in 0..<Self.events {
            // A hand does not land on round numbers, and a value that repeats would let
            // a cache answer a question the drag never asks.
            let t = (Double(event) + 0.5) / Double(Self.events)
            let recipe = control.recipe(at: t)

            let t0 = DispatchTime.now().uptimeNanoseconds
            let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.interactiveSize)
            let options = RenderGraph.Options(longEdge: longEdge,
                                              lutSize: LUT3D.interactiveSize)
            let out = RenderGraph().build(source, plan: plan, options: options)
            if let destination {
                context.render(out, to: destination, bounds: out.extent,
                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            } else {
                _ = context.createCGImage(out, from: out.extent, format: .RGBA8,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6

            // The first event of a gesture pays warm-up the rest of the drag does not,
            // and it is not what "the slider ticks" describes.
            if event > 0 { samples.append(ms) }
        }
        return Distribution(samples)
    }

    private func context() -> CIContext {
        CIContext(options: [.workingFormat: CIFormat.RGBAh])
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
    func testWhatADragFrameCostsPerControl() throws {
        let ctx = context()
        // ≈ a 16-inch MacBook Pro's loupe at fit: a 1180 pt centre pane at 2× buckets
        // to 2560, and `PhotoRenderModel.load` asks for half of it.
        let longEdge = 1280
        let source = materializedFrame(longEdge: longEdge, context: ctx)

        print("DRAGPROBE ── per control, \(longEdge) px, budget "
                + "\(DraftLadder.budgetMilliseconds) ms ──")
        for control in Control.allCases {
            let d = drag(control: control, longEdge: longEdge, source: source,
                         context: ctx, readback: true)
            print("DRAGPROBE \(pad(control.rawValue, 11)) \(d.line)")
            XCTAssertLessThan(d.max, 10_000,
                              "a \(control.rawValue) drag frame took over ten seconds — "
                                  + "something is broken, not merely slow")
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
        print("DRAGPROBE ── per rung, Exposure, budget "
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
    ///   · LAZY vs MATERIALIZED source — `AppleRawSource.decodeCache` stores
    ///     `filter.outputImage`, a description of the decode rather than its pixels, so
    ///     whatever it takes to produce them may be paid again on every frame of the
    ///     drag. Here the input is a two-filter generator chain; a 45 MP RAW's demosaic
    ///     is a great deal more than two filters, so treat the gap this prints as a
    ///     FLOOR on what materializing a real decode is worth, not an estimate of it.
    ///   · READBACK vs IOSurface — the viewer ends every frame with `createCGImage`, a
    ///     synchronous GPU→CPU copy of the whole frame, which SwiftUI then uploads back
    ///     to the GPU. Rendering to an IOSurface prices the same frame without the
    ///     round trip.
    func testWhatTheLazySourceAndTheReadbackCost() throws {
        let ctx = context()
        let longEdge = 1280
        let lazyInput = lazyFrame(longEdge: longEdge)
        let materialized = materializedFrame(longEdge: longEdge, context: ctx)

        print("DRAGPROBE ── structural costs, Exposure, \(longEdge) px ──")
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

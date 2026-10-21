// AutoToneQualityTests.swift
// WS-09: Auto Tone judged on what it renders, not on which branches it took. Each frame
// is rendered through the reference renderer with the tone sliders at zero, read back
// the way the app reads its proxy (8-bit sRGB, inverted into scene EV), handed to
// `AutoTone.auto`, and rendered again with Auto's values.

import XCTest
@testable import LumenCore

final class AutoToneQualityTests: XCTestCase {

    /// 8-bit sRGB bytes of a frame rendered with `recipe`, as the app's proxy holds them.
    private func encoded(_ frame: ImageBuffer, _ recipe: Recipe) -> [UInt8] {
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
        let out = ReferenceRenderer.render(frame, plan: plan)
        let m = RGBColorSpace.rec2020.matrix(to: .srgb)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(out.width * out.height * 3)
        for y in 0..<out.height {
            for x in 0..<out.width {
                let c = m.apply(out[x, y] * plan.displayWhite)
                for v in [c.r, c.g, c.b] {
                    bytes.append(UInt8((TransferFunction.srgb.encode(Num.saturate(v)) * 255)
                        .rounded()))
                }
            }
        }
        return bytes
    }

    private func statistics(_ frame: ImageBuffer, _ recipe: Recipe) -> AutoTone.Statistics {
        let transform = DisplayTransform.forRecipe(recipe)
        return AutoTone.statistics(encodedSRGB: encoded(frame, recipe), channels: 3,
                                   transform: transform, displayWhite: transform.white)!
    }

    /// Auto as the app runs it: the answer, then up to `maxClipRefinements` corrective
    /// proxy renders.
    private func auto(_ frame: ImageBuffer) -> (AutoTone.Result, AutoTone.Statistics) {
        let probe = Recipe()
        let stats = statistics(frame, probe)
        var result = AutoTone.auto(from: stats, render: probe.look.render.resolved())
        for _ in 0..<AutoTone.maxClipRefinements {
            var trial = probe
            result.apply(to: &trial)
            guard let next = AutoTone.refine(
                result, probe: stats, render: probe.look.render.resolved(),
                measuredClip: statistics(frame, trial).clippedFraction ?? 0,
                measuredCrush: statistics(frame, trial).crushedFraction ?? 0) else { break }
            result = next
        }
        return (result, stats)
    }

    /// Sorted encoded luminance (0…1) and the fraction of pixels with a channel at 255.
    private func luma(_ bytes: [UInt8]) -> (sorted: [Double], clipped: Double) {
        let w = RGBColorSpace.srgb.luminanceWeights
        var out: [Double] = []
        var clipped = 0
        for i in stride(from: 0, to: bytes.count, by: 3) {
            let r = TransferFunction.srgb.decode(Double(bytes[i]) / 255)
            let g = TransferFunction.srgb.decode(Double(bytes[i + 1]) / 255)
            let b = TransferFunction.srgb.decode(Double(bytes[i + 2]) / 255)
            out.append(TransferFunction.srgb.encode(w.r * r + w.g * g + w.b * b))
            if bytes[i] == 255 || bytes[i + 1] == 255 || bytes[i + 2] == 255 { clipped += 1 }
        }
        return (out.sorted(), Double(clipped) / Double(out.count))
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        sorted[Swift.min(sorted.count - 1, Int(p * Double(sorted.count)))]
    }

    private func rendered(_ frame: ImageBuffer, _ result: AutoTone.Result)
        -> (sorted: [Double], clipped: Double) {
        var r = Recipe()
        result.apply(to: &r)
        return luma(encoded(frame, r))
    }

    /// A textured frame spanning `lo…hi` EV around mid-grey.
    private func ramp(_ lo: Double, _ hi: Double, size: Int = 96) -> ImageBuffer {
        ImageBuffer(width: size, height: size) { u, v in
            let ev = lo + (hi - lo) * (0.7 * u + 0.3 * v)
            return RGB(gray: 0.18 * exp2(ev))
        }
    }

    /// SPEC 1: the median lands on the key, whatever the capture's exposure.
    func testAutoPlacesTheMedianOnTheKeyAcrossCaptureExposures() {
        for shift in [-3.0, -1.5, 0, 1.5] {
            let frame = ramp(-4 + shift, 1.5 + shift)
            let (result, _) = auto(frame)
            let median = percentile(rendered(frame, result).sorted, 0.5)
            XCTAssertEqual(median, AutoTone.keyTarget, accuracy: 0.03,
                           "capture shifted \(shift) EV: median \(median)")
        }
    }

    /// SPEC 2: the same scene captured at different exposures gets the same picture.
    func testAutoIsConsistentAcrossBracketedCaptures() {
        let a = ramp(-4, 1.5), b = ramp(-4.7, 0.8)    // 0.7 EV apart, like 6929/6933
        let ra = auto(a).0, rb = auto(b).0
        XCTAssertEqual(rb.tone.exposure - ra.tone.exposure, 0.7, accuracy: 0.06)
        let ma = percentile(rendered(a, ra).sorted, 0.5)
        let mb = percentile(rendered(b, rb).sorted, 0.5)
        XCTAssertEqual(ma, mb, accuracy: 0.01)
    }

    /// SPEC 3: endpoints go to just-clip on a frame that can reach them, and only the
    /// top fraction of a percent clips.
    func testAutoSetsEndpointsToJustClip() {
        let frame = ramp(-7, 2.6)
        let (result, _) = auto(frame)
        let out = rendered(frame, result)
        XCTAssertGreaterThan(percentile(out.sorted, 0.995), 0.93,
                             "Whites left the top short of white: \(result.tone)")
        XCTAssertLessThan(percentile(out.sorted, 0.002), 0.04,
                          "Blacks left the bottom short of black: \(result.tone)")
        XCTAssertLessThan(out.clipped, 0.01, "Auto clipped \(out.clipped * 100) %")
    }

    /// SPEC 4: a low-key frame keeps its bright subject. Exposure is capped by the
    /// brightest 2 % and then by the measured clip, so a dark room with a saturated lit
    /// window is not dragged to mid-grey and the window does not blow.
    func testAutoProtectsTheBrightSubjectOfALowKeyFrame() {
        let frame = ImageBuffer(width: 100, height: 100) { u, v in
            (u > 0.4 && u < 0.6 && v > 0.4 && v < 0.6)
                ? RGB(0.18 * exp2(1.2), 0.18 * exp2(0.6), 0.18 * exp2(-0.5))   // warm window
                : RGB(gray: 0.18 * exp2(-5 + 2 * u))
        }
        let (result, _) = auto(frame)
        let out = rendered(frame, result)
        XCTAssertLessThanOrEqual(out.clipped, AutoTone.clipAllowance + 0.001,
                                 "the window blew: \(out.clipped * 100) %")
        XCTAssertLessThan(percentile(out.sorted, 0.5), AutoTone.keyTarget,
                          "a low-key frame was lifted to an average key")
    }

    /// SPEC 5: the prediction Auto solves against is the picture the renderer makes.
    func testAutoPredictionMatchesTheRender() {
        let frame = ramp(-6, 2)
        let (result, stats) = auto(frame)
        let out = rendered(frame, result)
        let predicted = AutoTone.predictEncoded(stats, tone: result.tone,
                                                render: Recipe().look.render.resolved(),
                                                percentiles: [0.05, 0.5, 0.95])
        for (p, want) in zip([0.05, 0.5, 0.95], predicted) {
            XCTAssertEqual(percentile(out.sorted, p), want, accuracy: 0.03, "p\(p)")
        }
    }

    /// SPEC 6: Vibrance is modest, more on a muted frame, never Saturation.
    func testAutoVibranceIsModestAndFollowsChroma() {
        var last = Double.infinity
        for c in stride(from: 0.0, through: 0.15, by: 0.01) {
            let v = AutoTone.vibrance(forMeanChroma: c)
            XCTAssertTrue(AutoTone.vibranceLimit.contains(v), "\(v) at chroma \(c)")
            XCTAssertLessThanOrEqual(v, last)
            last = v
        }
        XCTAssertEqual(AutoTone.vibrance(forMeanChroma: nil), 10)
        var recipe = Recipe()
        recipe.develop.color.saturation = 7
        AutoTone.Result(tone: Tone(exposure: 1), vibrance: 12).apply(to: &recipe)
        XCTAssertEqual(recipe.develop.color.saturation, 7, "Auto touched Saturation")
        XCTAssertEqual(recipe.develop.color.vibrance, 12)
    }

    /// SPEC 7: every value inside Auto's own envelope, finite on degenerate input,
    /// deterministic.
    func testAutoStaysInItsEnvelopeAndIsFinite() {
        for bins in [[Double](repeating: 0, count: 128), [], [1.0]] {
            let r = AutoTone.auto(from: AutoTone.Statistics(histogram: bins))
            XCTAssertEqual(r.tone, Tone())
        }
        for seed in 0..<14 {
            var bins = [Double](repeating: 0, count: 128)
            let centre = 6 + seed * 9
            for i in Swift.max(centre - 8, 0)..<Swift.min(centre + 8, 128) { bins[i] = 50 }
            let stats = AutoTone.Statistics(histogram: bins, meanChroma: 0.04)
            let r = AutoTone.auto(from: stats)
            XCTAssertEqual(r, AutoTone.auto(from: stats), "not deterministic")
            let t = r.tone
            XCTAssertTrue(AutoTone.exposureLimit.contains(t.exposure), "\(t)")
            XCTAssertTrue(AutoTone.contrastLimit.contains(t.contrast), "\(t)")
            XCTAssertTrue(AutoTone.highlightsLimit.contains(t.highlights), "\(t)")
            XCTAssertTrue(AutoTone.shadowsLimit.contains(t.shadows), "\(t)")
            XCTAssertTrue(AutoTone.whitesLimit.contains(t.whites), "\(t)")
            XCTAssertTrue(AutoTone.blacksLimit.contains(t.blacks), "\(t)")
            XCTAssertTrue((-4...4).contains(t.contrastPivot), "\(t)")
            // A frame Auto declines (all black, all blown) gets no Vibrance either.
            XCTAssertTrue(r.tone == Tone() ? r.vibrance == 0
                          : AutoTone.vibranceLimit.contains(r.vibrance), "\(r)")
        }
    }

    /// A frame with nothing to place — all black, or all blown — is left alone rather
    /// than given Exposure +4 and Whites +60 out of nothing.
    func testAutoLeavesAnAllBlackOrAllBlownFrameAlone() {
        for value in [0.0, 0.18 * exp2(7)] {
            let frame = ImageBuffer(width: 48, height: 48) { _, _ in RGB(gray: value) }
            XCTAssertEqual(auto(frame).0.tone, Tone(), "frame at \(value)")
        }
    }

    /// On the Linear look there is no white or black point: Auto sets no endpoints and
    /// no Contrast there, only Exposure and the zonal sliders.
    func testAutoOnTheLinearLookLeavesTheEndpointsAlone() {
        var stats = AutoTone.Statistics(histogram: (0..<128).map { $0 > 40 && $0 < 80 ? 10 : 0 })
        stats.meanChroma = 0.02
        var look = Recipe().look.render.resolved()
        look.linear = true
        let r = AutoTone.auto(from: stats, render: look)
        XCTAssertEqual(r.tone.whites, 0)
        XCTAssertEqual(r.tone.blacks, 0)
        XCTAssertEqual(r.tone.contrast, 0)
        XCTAssertNotEqual(r.tone.exposure, 0)
    }

    /// The crush loop backs Vibrance off where Blacks has no reach.
    func testTheCrushLoopLowersVibranceOnTheLinearLook() throws {
        var stats = AutoTone.Statistics(histogram: (0..<128).map { $0 > 40 && $0 < 80 ? 10 : 0 })
        stats.meanChroma = 0.01
        stats.crushedFraction = 0.01
        var look = Recipe().look.render.resolved()
        look.linear = true
        let first = AutoTone.auto(from: stats, render: look)
        let next = try XCTUnwrap(AutoTone.refine(first, probe: stats, render: look,
                                                 measuredClip: 0, measuredCrush: 0.03))
        XCTAssertEqual(next.vibrance, first.vibrance - 5)
        XCTAssertNil(AutoTone.refine(first, probe: stats, render: look,
                                     measuredClip: 0, measuredCrush: 0.012))
    }
}

// EngineTests.swift
// The develop engine's contracts, asserted as properties rather than as numbers.
// Where docs/04 says a control "never moves the white point" or "holds perceived
// brightness", there is a test here that would fail if it stopped being true.

import XCTest
@testable import LumenCore

final class EngineTests: XCTestCase {

    // MARK: - Display transform

    func testTransformHitsAllFourAnchors() {
        for preset in ["Neutral", "Soft", "Punchy", "Film Base"] {
            var p = DisplayTransformParams.preset(named: preset)
            p.whiteAnchorEV = 5
            p.blackAnchorEV = -9
            let t = DisplayTransform(p)

            // Mid-grey → 0.18 display-linear, exactly, at every preset.
            XCTAssertEqual(t.tone(0.18), 0.18, accuracy: 1e-9, preset)
            // The white anchor → display white.
            XCTAssertEqual(t.tone(0.18 * pow(2.0, 5.0)), t.white, accuracy: 1e-9, preset)
            // The black anchor → the black floor.
            XCTAssertEqual(t.tone(0.18 * pow(2.0, -9.0)), t.black, accuracy: 1e-9, preset)
            // Zero and negative scene values cannot produce anything below the floor.
            XCTAssertEqual(t.tone(0), t.black, accuracy: 1e-12, preset)
        }
    }

    func testTransformIsMonotone() {
        for preset in DisplayTransformParams.presetNames {
            let t = DisplayTransform(DisplayTransformParams.preset(named: preset))
            XCTAssertNil(t.firstNonMonotonicX(), "\(preset) produced an inverted curve")
        }
        // And at the extremes of the parameter space, which is where an inverted
        // curve would actually show up.
        for contrast in [0.1, 1.0, 3.0, 10.0] {
            for skew in [-1.0, -0.5, 0, 0.5, 1.0] {
                var p = DisplayTransformParams()
                p.contrast = contrast
                p.skew = skew
                let t = DisplayTransform(p)
                XCTAssertNil(t.firstNonMonotonicX(), "contrast \(contrast) skew \(skew)")
            }
        }
    }

    func testContrastIsTheLogLogSlopeAtMidGrey() {
        for contrast in [0.8, 1.5, 2.5, 4.0] {
            var p = DisplayTransformParams()
            p.contrast = contrast
            let t = DisplayTransform(p)
            let h = 0.001
            let hi = t.tone(0.18 * pow(2, h))
            let lo = t.tone(0.18 * pow(2, -h))
            let slope = (log2(hi) - log2(lo)) / (2 * h)
            XCTAssertEqual(slope, contrast, accuracy: contrast * 0.02, "contrast \(contrast)")
        }
    }

    func testSkewLeavesTheSlopeAtTheePivotAlone() {
        var slopes: [Double] = []
        for skew in [-1.0, -0.5, 0, 0.5, 1.0] {
            var p = DisplayTransformParams()
            p.skew = skew
            let t = DisplayTransform(p)
            let h = 0.001
            let slope = (log2(t.tone(0.18 * pow(2, h))) - log2(t.tone(0.18 * pow(2, -h))))
                / (2 * h)
            slopes.append(slope)
        }
        guard let first = slopes.first else { return XCTFail("no slopes") }
        for s in slopes {
            XCTAssertEqual(s, first, accuracy: 0.05, "skew changed the pivot slope")
        }
    }

    func testSkewActuallyChangesTheShape() {
        var a = DisplayTransformParams(); a.skew = -0.8
        var b = DisplayTransformParams(); b.skew = 0.8
        let ta = DisplayTransform(a), tb = DisplayTransform(b)
        // Off the pivot the two curves must differ visibly, or the control is
        // decorative. Compared relatively, because deep in the toe an absolute
        // threshold measures the toe's depth rather than skew's effect.
        var worstRelative = 0.0
        for i in 1..<40 {
            let ev = -8 + Double(i) * 0.3
            let x = 0.18 * pow(2.0, ev)
            let va = ta.tone(x), vb = tb.tone(x)
            let reference = Swift.max(va, vb)
            guard reference > 1e-6 else { continue }
            worstRelative = Swift.max(worstRelative, abs(va - vb) / reference)
        }
        XCTAssertGreaterThan(worstRelative, 0.05,
                             "skew moved the curve by less than 5% anywhere")
    }

    func testHDRPeakRaisesWhiteButNotMidGrey() {
        var sdr = DisplayTransformParams()
        var hdr = DisplayTransformParams()
        hdr.whiteTarget = 400
        let a = DisplayTransform(sdr), b = DisplayTransform(hdr)
        XCTAssertEqual(a.tone(0.18), 0.18, accuracy: 1e-9)
        XCTAssertEqual(b.tone(0.18), 0.18, accuracy: 1e-9)
        XCTAssertEqual(b.white, 4.0, accuracy: 1e-9)
        XCTAssertGreaterThan(b.tone(0.18 * 16), a.tone(0.18 * 16))
        sdr.whiteTarget = 100
    }

    func testLinearPresetIsAStraightScaling() {
        let t = DisplayTransform(.linearPreset)
        XCTAssertEqual(t.tone(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.tone(2.0), 1.0, accuracy: 1e-9)   // clipped at display white
    }

    func testNeutralsStayNeutralThroughTheTransform() {
        let t = DisplayTransform(.neutral)
        for v in [0.02, 0.18, 0.6, 3.0] {
            let out = t.apply(RGB(gray: v), gamut: nil)
            XCTAssertEqual(out.r, out.g, accuracy: 1e-6, "grey \(v) picked up a cast")
            XCTAssertEqual(out.g, out.b, accuracy: 1e-6, "grey \(v) picked up a cast")
        }
    }

    // MARK: - Tone engine

    func testHighlightsCannotReachTheWhitePoint() {
        let e = ToneEngine(tone: Tone(highlights: 100))
        XCTAssertEqual(e.highlightWeight(e.whiteAnchorEV), 0, accuracy: 1e-9)
        XCTAssertEqual(e.highlightWeight(0), 0, accuracy: 1e-9)
        // and it does something in between
        XCTAssertGreaterThan(e.highlightWeight(e.whiteAnchorEV / 2), 0.9)
    }

    func testShadowsCannotReachTheBlackPoint() {
        let e = ToneEngine(tone: Tone(shadows: 100))
        XCTAssertEqual(e.shadowWeight(e.blackAnchorEV), 0, accuracy: 1e-9)
        XCTAssertEqual(e.shadowWeight(0), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(e.shadowWeight(e.blackAnchorEV / 2), 0.9)
    }

    func testHighlightsAndShadowsStayOutOfEachOthersTerritory() {
        let h = ToneEngine(tone: Tone(highlights: 100))
        let s = ToneEngine(tone: Tone(shadows: 100))
        XCTAssertEqual(h.stops(at: -3), 0, accuracy: 1e-9)
        XCTAssertEqual(s.stops(at: 3), 0, accuracy: 1e-9)
    }

    func testWhitesAndBlacksMoveTheAnchorsNotTheGain() {
        let neutral = ToneEngine()
        let bright = ToneEngine(tone: Tone(whites: 100, blacks: 100))
        XCTAssertLessThan(bright.whiteAnchorEV, neutral.whiteAnchorEV)
        XCTAssertLessThan(bright.blackAnchorEV, neutral.blackAnchorEV)
        // They contribute no gain of their own — that is the whole point.
        XCTAssertEqual(bright.stops(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(bright.stops(at: 2), 0, accuracy: 1e-9)
    }

    func testWhitesBrightensThroughTheTransform() {
        var params = DisplayTransformParams()
        let plain = ToneEngine()
        plain.applyAnchors(to: &params)
        let a = DisplayTransform(params)

        var params2 = DisplayTransformParams()
        let pushed = ToneEngine(tone: Tone(whites: 100))
        pushed.applyAnchors(to: &params2)
        let b = DisplayTransform(params2)

        let highlight = 0.18 * pow(2.0, 3.0)
        XCTAssertGreaterThan(b.tone(highlight), a.tone(highlight))
    }

    func testContrastPivotHoldsStill() {
        let e = ToneEngine(tone: Tone(contrast: 60, contrastPivot: -1))
        XCTAssertEqual(e.contrastMapped(-1), -1, accuracy: 1e-9)
        XCTAssertGreaterThan(e.contrastMapped(0), 0)     // above the pivot, pushed up
        XCTAssertLessThan(e.contrastMapped(-2), -2)      // below it, pushed down
    }

    /// Contrast is a *local* slope change around the pivot, and the ends of the scale
    /// are pinned. That is a stronger promise than "the slope comes back to 1": a
    /// slope of 1 far out still leaves a constant offset, which at contrast 100 would
    /// push a highlight three and a half stops up and out of the shaper's domain.
    /// Pinning the ends means a contrast push can never clip a highlight it was not
    /// asked to touch, and can never send a deep shadow to negative infinity.
    func testContrastPinsTheEndsOfTheScale() {
        for contrast in [-100.0, -40, 40, 100] {
            let e = ToneEngine(tone: Tone(contrast: contrast))
            for t in [-LumenLog.maxEV, LumenLog.maxEV] {
                XCTAssertEqual(e.contrastMapped(t), t, accuracy: 1e-9,
                               "contrast \(contrast) moved the end of the scale at \(t) EV")
            }
        }
    }

    /// And inside the window it does what the slider says: the slope at the pivot is
    /// the slope the control promises.
    func testContrastHitsItsSlopeAtThePivot() {
        for (contrast, expected) in [(100.0, 1.6), (50.0, 1.3), (-100.0, 0.4)] {
            let e = ToneEngine(tone: Tone(contrast: contrast))
            let slope = (e.contrastMapped(0.05) - e.contrastMapped(-0.05)) / 0.1
            XCTAssertEqual(slope, expected, accuracy: 0.01, "contrast \(contrast)")
        }
    }

    func testExposureIsAnHonestGain() {
        XCTAssertEqual(ToneEngine(tone: Tone(exposure: 1)).exposureGain, 2, accuracy: 1e-12)
        XCTAssertEqual(ToneEngine(tone: Tone(exposure: -2)).exposureGain, 0.25, accuracy: 1e-12)
    }

    func testIdentityToneIsDetected() {
        XCTAssertTrue(ToneEngine().isIdentity)
        XCTAssertTrue(ToneEngine(tone: Tone(exposure: 2, whites: 50)).isIdentity)
        XCTAssertFalse(ToneEngine(tone: Tone(highlights: -10)).isIdentity)
    }

    func testToneGainLUTMatchesTheDirectEvaluation() {
        let e = ToneEngine(tone: Tone(contrast: 30, highlights: -50, shadows: 40))
        let lut = e.bakeGainLUT()
        for v in [0.01, 0.05, 0.18, 0.5, 2.0] {
            let expected = e.gain(at: log2(v / 0.18))
            let got = lut.evaluate(LumenLog.encode(v))
            XCTAssertEqual(got, expected, accuracy: expected * 0.01, "at \(v)")
        }
    }

    // MARK: - Auto

    func testAutoLiftsAnUnderexposedFrame() {
        // The axis spans -12…+12 EV over 128 bins, so bin 42 is about four stops
        // below mid-grey. Pile the frame up there.
        var bins = [Double](repeating: 0, count: 128)
        for i in 38..<47 { bins[i] = 100 }
        let stats = AutoTone.Statistics(histogram: bins, minEV: -12, maxEV: 12)
        let suggestion = AutoTone.suggest(from: stats)
        XCTAssertGreaterThan(suggestion.exposure, 0.5)
        XCTAssertLessThanOrEqual(suggestion.exposure, 5)
    }

    /// A histogram piled into a range of bins, on the −12…+12 EV axis over 128 bins.
    private func autoHistogram(_ range: Range<Int>) -> [Double] {
        var bins = [Double](repeating: 0, count: 128)
        for i in range { bins[i] = 100 }
        return bins
    }

    /// `AutoTone.suggest` has five guarded branches. Two tests covered it: one asserted
    /// `exposure` only, the other asserted ranges — which `Tone()` satisfies. Deleting
    /// the highlights, shadows, whites/blacks and contrast blocks outright left both
    /// green, nothing ever set `faceMeanEV` so the face path and `contrastPivot` were
    /// dead, and nothing checked that Auto pulls an overexposed frame DOWN.
    ///
    /// Every expected value below was computed by simulating the function against the
    /// same histogram, so these are what it does, not what it ought to do.
    func testAutoDrivesEveryBranchItHas() {
        // Blown: exposure pulls down to its limit and Highlights goes to full recovery.
        let blown = AutoTone.suggest(from: AutoTone.Statistics(
            histogram: autoHistogram(100..<126)))
        XCTAssertEqual(blown.exposure, -5, accuracy: 0.1,
                       "Auto did not pull an overexposed frame down")
        XCTAssertEqual(blown.highlights, -100, accuracy: 0.1,
                       "Auto did not recover blown highlights")

        // A frame spanning the whole axis: both ends need work and the endpoints do
        // not, which is the case that separates the four branches from one another.
        let wide = AutoTone.suggest(from: AutoTone.Statistics(
            histogram: autoHistogram(10..<121)))
        XCTAssertEqual(wide.highlights, -100, accuracy: 0.1)
        XCTAssertEqual(wide.shadows, 100, accuracy: 0.1,
                       "Auto did not lift buried shadows")
        XCTAssertEqual(wide.whites, 0, accuracy: 0.1,
                       "Auto opened the endpoints on a frame that already spans them")
        XCTAssertEqual(wide.blacks, 0, accuracy: 0.1)
        XCTAssertEqual(wide.contrast, 0, accuracy: 0.1,
                       "Auto added contrast to a frame that is not compressed")

        // A flat scene: the endpoints open and contrast comes up, gently.
        let flat = AutoTone.suggest(from: AutoTone.Statistics(
            histogram: autoHistogram(60..<68)))
        XCTAssertEqual(flat.whites, 50.08, accuracy: 0.1,
                       "Auto did not open the whites on a flat scene")
        XCTAssertEqual(flat.blacks, -41.73, accuracy: 0.1,
                       "Auto did not open the blacks on a flat scene")
        XCTAssertEqual(flat.contrast, 31.1, accuracy: 0.1,
                       "Auto did not add contrast to a compressed midtone")
        XCTAssertLessThanOrEqual(flat.contrast, 40,
                                 "Auto that shouts is Auto the user turns off")

        // With a face, exposure anchors on the face rather than the median, and the
        // contrast pivot moves off zero — the whole face-weighted path, which nothing
        // had ever exercised because no test set `faceMeanEV`.
        let face = AutoTone.suggest(from: AutoTone.Statistics(
            histogram: autoHistogram(60..<69), faceMeanEV: -2.0))
        XCTAssertEqual(face.exposure, 1.65, accuracy: 0.1,
                       "Auto did not place the face at its target")
        XCTAssertEqual(face.contrastPivot, -0.35, accuracy: 0.1,
                       "the contrast pivot ignored the face")
        // Without a face the pivot stays at zero.
        XCTAssertEqual(AutoTone.suggest(from: AutoTone.Statistics(
            histogram: autoHistogram(60..<69))).contrastPivot, 0, accuracy: 1e-12)
    }

    /// An empty or degenerate histogram must produce a usable suggestion rather than a
    /// NaN that reaches a slider.
    func testAutoSurvivesADegenerateHistogram() {
        for bins in [[Double](repeating: 0, count: 128), [], [1.0]] {
            let t = AutoTone.suggest(from: AutoTone.Statistics(histogram: bins))
            for (name, value) in [("exposure", t.exposure), ("contrast", t.contrast),
                                  ("highlights", t.highlights), ("shadows", t.shadows),
                                  ("whites", t.whites), ("blacks", t.blacks),
                                  ("pivot", t.contrastPivot)] {
                XCTAssertTrue(value.isFinite,
                              "\(name) came back \(value) for a \(bins.count)-bin "
                                  + "histogram")
            }
        }
    }

    func testAutoStaysInsideEverySliderRange() {
        for seed in 0..<12 {
            var bins = [Double](repeating: 0, count: 128)
            let centre = 10 + seed * 9
            for i in Swift.max(centre - 6, 0)..<Swift.min(centre + 6, 128) { bins[i] = 50 }
            let s = AutoTone.suggest(from: AutoTone.Statistics(histogram: bins))
            XCTAssertTrue((-5...5).contains(s.exposure), "exposure \(s.exposure)")
            XCTAssertTrue((-100...100).contains(s.contrast))
            XCTAssertTrue((-100...100).contains(s.highlights))
            XCTAssertTrue((-100...100).contains(s.shadows))
            XCTAssertTrue((-100...100).contains(s.whites))
            XCTAssertTrue((-100...100).contains(s.blacks))
            XCTAssertTrue((-4...4).contains(s.contrastPivot))
        }
    }

    // MARK: - Curves

    func testDefaultCurveIsIdentity() {
        let stack = CurveStack(CurveSet())
        XCTAssertTrue(stack.isIdentity)
        let c = RGB(0.2, 0.5, 0.7)
        XCTAssertLessThan(stack.apply(c).maxAbsDifference(c), 1e-12)
    }

    func testParametricCurveStaysMonotoneAtExtremes() {
        for h in [-100.0, 0, 100] {
            for s in [-100.0, 0, 100] {
                let p = ParametricCurve(highlights: h, lights: -s, darks: s, shadows: -h)
                let lut = CurveStack.bakeParametric(p, size: 512)
                var previous = -Double.infinity
                for i in 0..<512 {
                    let v = lut.samples[i]
                    XCTAssertGreaterThanOrEqual(v, previous - 1e-9,
                                                "non-monotone at h=\(h) s=\(s)")
                    previous = v
                }
            }
        }
    }

    func testParametricCurvePinsBothEndpoints() {
        let p = ParametricCurve(highlights: 100, lights: 100, darks: -100, shadows: -100)
        let lut = CurveStack.bakeParametric(p, size: 256)
        XCTAssertEqual(lut.evaluate(0), 0, accuracy: 1e-9)
        XCTAssertEqual(lut.evaluate(1), 1, accuracy: 1e-9)
    }

    func testPointCurvePassesThroughItsPoints() {
        let set = CurveSet(point: [[0, 0], [0.5, 0.75], [1, 1]])
        let stack = CurveStack(set)
        XCTAssertEqual(stack.master(0.5), 0.75, accuracy: 1e-6)
    }

    func testLuminancePreservingCurveDoesNotShiftHue() {
        let set = CurveSet(point: [[0, 0], [0.25, 0.45], [1, 1]], preserveLuminance: true)
        let stack = CurveStack(set)
        let input = RGB(0.30, 0.12, 0.06)
        let out = stack.apply(input)
        let before = OKLabTransform.working.toLCh(input)
        let after = OKLabTransform.working.toLCh(out)
        XCTAssertEqual(after.h, before.h, accuracy: 2.0)
        XCTAssertGreaterThan(after.L, before.L)
    }

    func testSettingPointReplacesNearbyPoints() {
        let pts = CurveStack.settingPoint([[0, 0], [0.5, 0.5], [1, 1]], x: 0.505, y: 0.7)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[1][1], 0.7, accuracy: 1e-9)
    }

    // MARK: - White balance

    func testWhiteBalanceIsIdentityAtAsShot() {
        let wb = WhiteBalanceEngine(asShotKelvin: 5200, asShotTint: 12,
                                    targetKelvin: nil, targetTint: nil)
        XCTAssertTrue(wb.isIdentity)
        XCTAssertLessThan(wb.matrix.maxAbsDifference(.identity), 1e-12)
    }

    func testLoweringTemperatureCoolsThePicture() {
        let wb = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                    targetKelvin: 3000, targetTint: 0)
        let neutral = wb.apply(RGB(gray: 0.18))
        XCTAssertGreaterThan(neutral.b / neutral.r, 1.2, "3000 K target should cool")

        let warm = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                      targetKelvin: 9000, targetTint: 0)
        let warmed = warm.apply(RGB(gray: 0.18))
        XCTAssertGreaterThan(warmed.r / warmed.b, 1.1, "9000 K target should warm")
    }

    func testEyedropperNeutralizesASampledColour() {
        let asShotK = 5500.0, asShotT = 0.0
        let current = WhiteBalanceEngine(asShotKelvin: asShotK, asShotTint: asShotT,
                                         targetKelvin: nil, targetTint: nil)
        // A grey card photographed under light warmer than the as-shot assumption.
        let castMatrix = WhiteBalanceEngine.adaptation(asShot: (asShotK, asShotT),
                                                       target: (3400, 20),
                                                       space: .rec2020).inverse
        let sample = castMatrix.apply(RGB(gray: 0.18))

        let solved = WhiteBalanceEngine.neutralizing(sample: sample,
                                                     asShotKelvin: asShotK,
                                                     asShotTint: asShotT,
                                                     current: current)
        let corrected = WhiteBalanceEngine(asShotKelvin: asShotK, asShotTint: asShotT,
                                           targetKelvin: solved.kelvin,
                                           targetTint: solved.tint).apply(sample)
        let mean = (corrected.r + corrected.g + corrected.b) / 3
        XCTAssertGreaterThan(mean, 0)
        XCTAssertEqual(corrected.r / mean, 1, accuracy: 0.03)
        XCTAssertEqual(corrected.b / mean, 1, accuracy: 0.03)
    }

    func testLinearStageFusesItsThreeInputs() {
        let wb = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                    targetKelvin: 4000, targetTint: 0)
        let stage = LinearStage(whiteBalance: wb, exposureGain: 2,
                                printerLightGains: RGB(1, 1, 1))
        let direct = wb.apply(RGB(0.2, 0.3, 0.4)) * 2
        XCTAssertLessThan(stage.apply(RGB(0.2, 0.3, 0.4)).maxAbsDifference(direct), 1e-12)
    }

    // MARK: - Export

    /// The export subfolder is a security boundary: `appendingPathComponent` appends a
    /// multi-component string verbatim and the exporter then creates intermediate
    /// directories, so `../../..` writes outside the folder the open panel granted —
    /// the one thing that panel exists to decide.
    ///
    /// It had no test. The logic was inline in `AppStateActions`, a target with no test
    /// target, and the reference implementation's "check" of it defined its own copy
    /// inline and verified that — mirroring nothing. It now lives in `LumenCore` and
    /// both the exporter and the sheet's preview call it.
    func testExportSubfolderCannotEscapeTheChosenDirectory() {
        for hostile in ["../../..", "..", "./../etc", "a/../../b", "/etc/passwd",
                        "//..//..//", "  ..  /x", "..\\..\\Windows", "C:/Users",
                        ".", "/", "../"] {
            let parts = ExportRecipe.sanitizedSubfolderComponents(hostile)
            for part in parts {
                XCTAssertFalse(part == "." || part == "..",
                               "\(hostile) survived as a traversal component")
                XCTAssertFalse(part.contains("/") || part.contains("\\"),
                               "\(hostile) survived carrying a separator: \(part)")
                XCTAssertFalse(part.contains(":"),
                               "\(hostile) survived carrying a colon: \(part)")
                XCTAssertFalse(part.isEmpty)
            }
        }

        // Ordinary subfolders are untouched — a sanitizer that mangled real input
        // would be its own bug.
        XCTAssertEqual(ExportRecipe.sanitizedSubfolderComponents("Web/2026"),
                       ["Web", "2026"])
        XCTAssertEqual(ExportRecipe.sanitizedSubfolderComponents("hdr"), ["hdr"])
        XCTAssertEqual(ExportRecipe.sanitizedSubfolderComponents(nil), [])
        XCTAssertEqual(ExportRecipe.sanitizedSubfolderComponents(""), [])

        // "C:/Users" keeps its components, with the colon replaced — it is a mangled
        // paste, not an attack, and dropping it silently would lose the user's folder.
        XCTAssertEqual(ExportRecipe.sanitizedSubfolderComponents("C:/Users"),
                       ["C-", "Users"])

        // The preview and the written path must agree, which is why they share this.
        for sub in ["Web/2026", "../../etc", "C:/Users", "", "a/../b"] {
            XCTAssertEqual(ExportRecipe.sanitizedSubfolderPath(sub),
                           ExportRecipe.sanitizedSubfolderComponents(sub)
                               .joined(separator: "/"),
                           "the preview path and the written path diverged for \(sub)")
        }
    }

    func testResizeNeverUpscalesByDefault() {
        var r = ExportRecipe(name: "t", resizeMode: .longEdge, resizeValue: 4000)
        let size = r.targetSize(sourceWidth: 2000, sourceHeight: 1000)
        XCTAssertEqual(size.width, 2000)
        r.allowUpscale = true
        XCTAssertEqual(r.targetSize(sourceWidth: 2000, sourceHeight: 1000).width, 4000)
    }

    func testResizeModesComputeTheRightEdge() {
        let r = ExportRecipe(name: "t", resizeMode: .longEdge, resizeValue: 1000)
        let landscape = r.targetSize(sourceWidth: 4000, sourceHeight: 2000)
        XCTAssertEqual(landscape.width, 1000)
        XCTAssertEqual(landscape.height, 500)
        let portrait = r.targetSize(sourceWidth: 2000, sourceHeight: 4000)
        XCTAssertEqual(portrait.height, 1000)
    }

    func testMegapixelResizeHitsItsTarget() {
        let r = ExportRecipe(name: "t", resizeMode: .megapixels, resizeValue: 4)
        let size = r.targetSize(sourceWidth: 6000, sourceHeight: 4000)
        let mp = Double(size.width * size.height) / 1_000_000
        XCTAssertEqual(mp, 4, accuracy: 0.02)
    }

    func testGainMapRoundTrip() {
        let sdr = RGB(0.2, 0.4, 0.6)
        let hdr = RGB(0.4, 0.9, 1.8)
        let logGain = GainMap.logGain(hdr: hdr, sdr: sdr)
        let lo = -1.0, hi = 3.0
        let encoded = RGB(GainMap.encode(logGain.r, min: lo, max: hi),
                          GainMap.encode(logGain.g, min: lo, max: hi),
                          GainMap.encode(logGain.b, min: lo, max: hi))
        let reconstructed = GainMap.reconstruct(sdr: sdr, encodedMap: encoded,
                                                min: lo, max: hi,
                                                displayHeadroomEV: 2,
                                                contentHeadroomEV: 2)
        XCTAssertLessThan(reconstructed.maxAbsDifference(hdr), 1e-6)
    }

    func testGainMapAtZeroHeadroomReturnsTheSDRBase() {
        let sdr = RGB(0.2, 0.4, 0.6)
        let reconstructed = GainMap.reconstruct(sdr: sdr, encodedMap: RGB(1, 1, 1),
                                                min: -1, max: 3,
                                                displayHeadroomEV: 0,
                                                contentHeadroomEV: 2)
        XCTAssertLessThan(reconstructed.maxAbsDifference(sdr), 1e-9)
    }

    func testOutputSharpenScalesWithMediumAndAmount() {
        let screen = OutputSharpen(medium: .screen, amount: .standard)
        let matteHigh = OutputSharpen(medium: .matte, amount: .high)
        XCTAssertTrue(OutputSharpen(medium: .none, amount: .low).isIdentity)
        XCTAssertGreaterThan(matteHigh.baseRadius(), screen.baseRadius())
        XCTAssertGreaterThan(matteHigh.energy(), screen.energy())
        XCTAssertGreaterThan(OutputSharpen(medium: .matte, amount: .standard).baseRadius(),
                             OutputSharpen(medium: .glossy, amount: .standard).baseRadius())
    }

    func testSoftProofFlagsOutOfGamutColours() {
        // A saturated Rec.2020 green is well outside sRGB.
        XCTAssertTrue(SoftProof.isOutOfGamut(RGB(0, 1, 0), working: .rec2020, proof: .srgb))
        XCTAssertFalse(SoftProof.isOutOfGamut(RGB(0.4, 0.4, 0.4),
                                              working: .rec2020, proof: .srgb))
    }
}

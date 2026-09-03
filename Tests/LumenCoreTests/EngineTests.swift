// EngineTests.swift
// The develop engine's contracts, asserted as properties rather than as numbers.
// Where docs/04 says a control "never moves the white point" or "holds perceived
// brightness", there is a test here that would fail if it stopped being true.

import XCTest
@testable import LumenCore

final class EngineTests: XCTestCase {

    // MARK: - Display transform

    func testTransformHitsAllFourAnchors() {
        // Driven off `presetNames` rather than a hardcoded list, which had drifted:
        // the list here named four and the type ships five, and `preset(named:)` falls
        // back to `.neutral` for anything it does not recognise — so renaming a preset
        // silently turned this into four copies of the Neutral case.
        //
        // Linear is excluded by name: it is a straight scaling with no shoulder, so it
        // cannot hit the black anchor, and `testLinearPresetIsAStraightScaling` covers
        // it instead.
        let anchored = DisplayTransformParams.presetNames.filter { $0 != "Linear" }
        XCTAssertEqual(anchored.count, 4, "the preset list changed — is the new one "
                           + "anchored, or does it belong with Linear?")
        for preset in anchored {
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

    func testSkewLeavesTheSlopeAtThePivotAlone() {
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
        let sdr = DisplayTransformParams()
        var hdr = DisplayTransformParams()
        hdr.whiteTarget = 400
        let a = DisplayTransform(sdr), b = DisplayTransform(hdr)
        XCTAssertEqual(a.tone(0.18), 0.18, accuracy: 1e-9)
        XCTAssertEqual(b.tone(0.18), 0.18, accuracy: 1e-9)
        XCTAssertEqual(b.white, 4.0, accuracy: 1e-9)
        XCTAssertGreaterThan(b.tone(0.18 * 16), a.tone(0.18 * 16))
        // Raising the peak must not raise the floor — black is a fraction of SDR white,
        // not of the display peak, which is what keeps an HDR display from washing out
        // the shadows. (This line used to be a dead `sdr.whiteTarget = 100` store.)
        XCTAssertEqual(b.black, a.black, accuracy: 1e-12)
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

    /// Highlights is a SHELF: nothing at mid-grey, full strength at the white anchor.
    ///
    /// It used to be a bump — a raised cosine that peaked halfway to the anchor and
    /// returned to zero AT it — and this test asserted that shape. Two things followed.
    /// Highlights −100 did nothing whatsoever to the brightest values, so the one
    /// control a photographer reaches for to pull back a blown sky left the sky exactly
    /// where it was and darkened the tones below it instead. And a bump's steep slope
    /// forced the monotonicity limiter to cap the amount near 0.56, which measured as
    /// 79% of the slider's effect living in its first half and its strength varying
    /// 3.6x across the Contrast range.
    ///
    /// Reaching the white point is the correct behaviour and is what makes recovery
    /// work. Mid-grey staying untouched is the part that must not change.
    func testHighlightsIsAShelfThatReachesTheHighlights() {
        let e = ToneEngine(tone: Tone(highlights: 100))
        XCTAssertEqual(e.highlightWeight(0), 0, accuracy: 1e-9,
                       "Highlights must not touch mid-grey")
        XCTAssertGreaterThan(e.highlightWeight(e.whiteAnchorEV), 0.99,
                             "Highlights must reach the white point, or it cannot "
                                 + "recover a blown highlight")
        // Monotone rising, so every part of the range gets more than the part below it.
        var previous = -1.0
        for step in 0...20 {
            let w = e.highlightWeight(Double(step) / 20 * e.whiteAnchorEV)
            XCTAssertGreaterThanOrEqual(w, previous)
            previous = w
        }
    }

    /// Shadows is the mirror shelf, and it saturates at HALF the black anchor.
    ///
    /// Not at the anchor, because the two ends of the range are not symmetric in what a
    /// viewer can see: the display transform's toe puts −9 EV at sRGB code 0.5 and −5.5
    /// at 2.5, so a shelf reaching full strength at the anchor spends itself where
    /// there is nothing to move. Measured, that was Shadows +100 worth 9.1 code values
    /// against Highlights' 38.5. Saturating at −4.5 EV takes it to 32.7.
    func testShadowsIsAShelfAimedWhereShadowsAreVisible() {
        let e = ToneEngine(tone: Tone(shadows: 100))
        XCTAssertEqual(e.shadowWeight(0), 0, accuracy: 1e-9,
                       "Shadows must not touch mid-grey")
        XCTAssertGreaterThan(e.shadowWeight(e.blackAnchorEV * ToneEngine.shadowShelfEnd),
                             0.99, "Shadows must be at full strength by the point the "
                                 + "toe stops leaving room to move")
        var previous = -1.0
        for step in 0...20 {
            let w = e.shadowWeight(Double(step) / 20 * e.blackAnchorEV)
            XCTAssertGreaterThanOrEqual(w, previous)
            previous = w
        }
    }

    /// Highlights must not reach a shadow and Shadows must not reach a highlight —
    /// INCLUDING where the monotonicity limiter binds, which is the only place either
    /// of them has ever been able to.
    ///
    /// What was here were two one-slider slices: `stops(at: -3) == 0` for
    /// `Tone(highlights: 100)` and its mirror. Both are satisfied by the weight
    /// functions alone. A lone slider is precisely the case a shared scale cannot
    /// couple, because there is nothing to couple it TO — so the assertion could not
    /// fail however badly the scale leaked, and it did not fail while the scale leaked
    /// this far: at `Tone(contrast: -100, shadows: -100, whites: -100, blacks: -100)`,
    /// dragging Highlights from −100 to +40 LIGHTENED −2 EV by 24.4 sRGB code values,
    /// and the top 60 points of the slider rendered byte-identically there.
    /// `highlightWeight(-2)` is exactly 0 at that tone. The leak was the scale.
    ///
    /// So the sweep now runs the whole neighbourhood and counts how much of it BINDS.
    /// A sweep that never binds is a sweep that proves nothing here, which is why the
    /// count is asserted rather than trusted.
    func testHighlightsAndShadowsStayOutOfEachOthersTerritory() {
        // The original one-slider slices, kept and tightened.
        XCTAssertEqual(ToneEngine(tone: Tone(highlights: 100)).stops(at: -3), 0,
                       accuracy: 1e-12)
        XCTAssertEqual(ToneEngine(tone: Tone(shadows: 100)).stops(at: 3), 0,
                       accuracy: 1e-12)

        let below = stride(from: -12.0, through: 0.0, by: 0.25).map { $0 }
        let above = stride(from: 0.0, through: 7.0, by: 0.25).map { $0 }
        var binding = 0
        var settings = 0
        var worstLeak = (amount: 0.0, label: "")

        for contrast in [-100.0, -60, 0, 60] {
            for pivot in [-3.0, 0, 3] {
                for whites in [-100.0, 0, 20, 100] {
                    for blacks in [-100.0, 0, 100] {
                        for partner in [-100.0, -60, 0, 60, 100] {
                            // Highlights against a fixed everything-else. Nothing at or
                            // below mid-grey may move, at any setting of Highlights.
                            var reference: [Double]?
                            for highlights in stride(from: -100.0, through: 100,
                                                     by: 10.0) {
                                let e = ToneEngine(tone: Tone(
                                    contrast: contrast, contrastPivot: pivot,
                                    highlights: highlights, shadows: partner,
                                    whites: whites, blacks: blacks))
                                settings += 1
                                if e.zonalScale < 1 - 1e-12 { binding += 1 }
                                let probe = below.map { e.stops(at: $0) }
                                if let base = reference {
                                    for (i, v) in probe.enumerated()
                                    where abs(v - base[i]) > worstLeak.amount {
                                        worstLeak = (abs(v - base[i]),
                                                     "Highlights \(highlights) moved "
                                                        + "\(below[i]) EV by "
                                                        + "\(v - base[i]) stops at "
                                                        + "c\(contrast) p\(pivot) "
                                                        + "s\(partner) w\(whites) "
                                                        + "b\(blacks)")
                                    }
                                } else {
                                    reference = probe
                                }
                            }
                            // Shadows against a fixed everything-else, mirrored.
                            reference = nil
                            for shadows in stride(from: -100.0, through: 100, by: 10.0) {
                                let e = ToneEngine(tone: Tone(
                                    contrast: contrast, contrastPivot: pivot,
                                    highlights: partner, shadows: shadows,
                                    whites: whites, blacks: blacks))
                                settings += 1
                                if e.zonalScale < 1 - 1e-12 { binding += 1 }
                                let probe = above.map { e.stops(at: $0) }
                                if let base = reference {
                                    for (i, v) in probe.enumerated()
                                    where abs(v - base[i]) > worstLeak.amount {
                                        worstLeak = (abs(v - base[i]),
                                                     "Shadows \(shadows) moved "
                                                        + "\(above[i]) EV by "
                                                        + "\(v - base[i]) stops at "
                                                        + "c\(contrast) p\(pivot) "
                                                        + "h\(partner) w\(whites) "
                                                        + "b\(blacks)")
                                    }
                                } else {
                                    reference = probe
                                }
                            }
                        }
                    }
                }
            }
        }

        // The sweep has to spend real time where the scale is doing something, or it is
        // the old test with more loops around it. The old independence check skipped
        // every binding case by construction and that is exactly what it missed.
        XCTAssertGreaterThan(binding, settings / 10,
                             "only \(binding) of \(settings) settings bound the zonal "
                                 + "limiter — this sweep is not testing the coupling")
        XCTAssertEqual(worstLeak.amount, 0, accuracy: 1e-12, worstLeak.label)
    }

    /// Whites and Blacks move the anchors AND carry a tonal shelf of their own.
    ///
    /// This used to assert they contribute no gain — "that is the whole point" — and
    /// the anchors alone were not enough to make them mean anything. Measured on a
    /// −9…+5 EV grey ramp in sRGB code values, full travel was worth 12.3 for Whites
    /// and 1.2 for Blacks: the toe and shoulder have already compressed those regions,
    /// so moving where the endpoint lands moves almost no visible pixel. A slider worth
    /// one code value out of 255 is one a photographer would call broken, and Blacks is
    /// not an obscure control.
    ///
    /// The anchor move is kept — it is what defines the endpoint — and the shelves give
    /// them authority. Both now measure 14–38 code values, in the same band as
    /// Highlights and Shadows.
    func testWhitesAndBlacksMoveBothTheAnchorsAndTheCurve() {
        let neutral = ToneEngine()
        let bright = ToneEngine(tone: Tone(whites: 100, blacks: 100))
        XCTAssertLessThan(bright.whiteAnchorEV, neutral.whiteAnchorEV)
        XCTAssertLessThan(bright.blackAnchorEV, neutral.blackAnchorEV)
        // Mid-grey is still theirs to leave alone.
        XCTAssertEqual(bright.stops(at: 0), 0, accuracy: 1e-9,
                       "Whites and Blacks must not move mid-grey")
        // And each reaches real authority in its own end of the range.
        XCTAssertGreaterThan(ToneEngine(tone: Tone(whites: 100)).stops(at: 3.5), 0.4,
                             "Whites has no reach into the highlights")
        XCTAssertGreaterThan(ToneEngine(tone: Tone(blacks: 100)).stops(at: -4), 0.4,
                             "Blacks has no reach into the shadows")
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
        // Exposure alone is still identity for the GAIN curve — it is a matrix scale
        // applied upstream. Whites is not, since it now carries a shelf; leaving it out
        // of the guard collapsed `toneGainLUT` to two samples and threw that shelf away
        // before it reached a pixel.
        XCTAssertTrue(ToneEngine(tone: Tone(exposure: 2)).isIdentity)
        XCTAssertFalse(ToneEngine(tone: Tone(whites: 50)).isIdentity)
        XCTAssertFalse(ToneEngine(tone: Tone(blacks: 50)).isIdentity)
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

    // MARK: - Display white, and which mechanism actually holds it

    /// ToneEngine's header claimed for a long time that Highlights' window "tapers to
    /// zero at the white anchor, so Highlights can never push a pixel past display
    /// white — implemented as geometry". Since the shelf rework that is false twice
    /// over: `highlightWeight` is `smoothstep(0, whiteAnchor, t)`, which is 1 AT the
    /// anchor and 1 above it, so Highlights ±100 applies its full ±2 EV to pixels that
    /// are already at and beyond white. That is deliberate — a bump left a blown sky
    /// exactly where it was, which is what the rework existed to fix.
    ///
    /// The invariant survived the rework anyway, on a different mechanism: the display
    /// transform's curve saturates at the anchor. This asserts both halves — that the
    /// shelf really does reach past white, and that the render still cannot — so the
    /// words in that file are now backed rather than believed.
    func testHighlightsCannotRenderPastDisplayWhite() {
        // The shelf, first: full weight at the anchor and above it.
        let up = ToneEngine(tone: Tone(highlights: 100))
        XCTAssertEqual(up.highlightWeight(up.whiteAnchorEV), 1, accuracy: 1e-12,
                       "the highlight shelf does not reach the white anchor")
        XCTAssertEqual(up.highlightWeight(up.whiteAnchorEV + 4), 1, accuracy: 1e-12,
                       "the highlight shelf falls off above the white anchor")
        XCTAssertGreaterThan(up.stops(at: up.whiteAnchorEV + 3), 1.0,
                             "Highlights +100 does nothing above display white")

        // And the render, which is where the promise is actually kept. The ramp runs
        // eight stops past the anchor, so the claim is tested where it could fail.
        let frame = ImageBuffer(width: 96, height: 4) { u, _ in
            RGB(gray: 0.18 * exp2(-8 + 21 * u))
        }
        for highlights in [0.0, 50.0, 100.0] {
            for whites in [0.0, 100.0] {
                for contrast in [0.0, 100.0] {
                    var recipe = Recipe()
                    recipe.develop.tone.highlights = highlights
                    recipe.develop.tone.whites = whites
                    recipe.develop.tone.contrast = contrast
                    let plan = RenderPlan(recipe: recipe)
                    // Both paths: the baked table the shipping graph resamples, whose
                    // output is normalized against display white, and the exact f64
                    // twin, which is where the mechanism actually is. A table cannot
                    // exceed the maximum of the values it interpolates, so the exact
                    // path is the one that could fail first.
                    let label = "Highlights \(highlights) / Whites \(whites) / "
                        + "Contrast \(contrast)"
                    let tabled = ReferenceRenderer.render(frame, plan: plan)
                    let exact = ReferenceRenderer.renderExact(frame, plan: plan)
                    var tabledPeak = 0.0
                    var exactPeak = 0.0
                    for y in 0..<tabled.height {
                        for x in 0..<tabled.width {
                            // Finiteness first. `Swift.max` returns the OTHER operand
                            // when one is NaN, so a running maximum quietly steps over
                            // every NaN in the frame — which is how the first draft of
                            // this test passed against a transform whose curve was
                            // producing NaN above the anchor rather than white.
                            XCTAssertTrue(tabled[x, y].isFinite,
                                          "\(label) rendered \(tabled[x, y]) at \(x)")
                            XCTAssertTrue(exact[x, y].isFinite,
                                          "\(label) formed \(exact[x, y]) at \(x)")
                            tabledPeak = Swift.max(tabledPeak, tabled[x, y].maxComponent)
                            exactPeak = Swift.max(exactPeak, exact[x, y].maxComponent)
                        }
                    }
                    XCTAssertLessThanOrEqual(
                        tabledPeak, 1.0 + 1e-6,
                        "\(label) rendered \(tabledPeak) against display white 1.0")
                    XCTAssertLessThanOrEqual(
                        exactPeak, plan.displayWhite + 1e-9,
                        "\(label) formed \(exactPeak) against display white "
                            + "\(plan.displayWhite)")
                }
            }
        }
    }

    // MARK: - Auto's statistics, taken through the curve the render applied

    /// Inverting the display transform has to land back where it started, or every
    /// number downstream of it is a different kind of wrong from the one it replaced.
    func testSceneEVInvertsTheDisplayTransformBetweenItsAnchors() {
        for whites in [0.0, 100.0, -100.0] {
            var recipe = Recipe()
            recipe.develop.tone.whites = whites
            let transform = DisplayTransform.forRecipe(recipe)
            let histogram = AutoTone.SceneHistogram(transform: transform)
            let lo = transform.params.blackAnchorEV
            let hi = transform.params.whiteAnchorEV

            var ev = lo + 0.1
            while ev < hi - 0.1 {
                let display = transform.tone(DisplayTransform.midGrey * exp2(ev))
                XCTAssertEqual(histogram.sceneEV(displayLuminance: display), ev,
                               accuracy: 0.05, "round trip failed at \(ev) EV")
                ev += 0.25
            }
            // Censored, not extrapolated, outside the anchors: the reading is "at least
            // this bright", which is what makes the highlight branch reachable.
            XCTAssertEqual(histogram.sceneEV(displayLuminance: transform.white * 4), hi,
                           accuracy: 1e-9)
            XCTAssertEqual(histogram.sceneEV(displayLuminance: 0), lo, accuracy: 1e-9)
            XCTAssertEqual(histogram.sceneEV(displayLuminance: .nan), lo, accuracy: 1e-9)
        }

        // The plan the picture is actually rendered through must be the same transform,
        // or the inversion is against a curve nothing applied.
        var recipe = Recipe()
        recipe.develop.tone.whites = 40
        recipe.develop.tone.blacks = -30
        recipe.look.render.preset = "Punchy"
        XCTAssertEqual(DisplayTransform.forRecipe(recipe).params,
                       RenderPlan(recipe: recipe).displayTransform.params)
    }

    /// Auto recovers a blown sky — the single most common thing an Auto button does,
    /// and the one branch of `suggest` that could never fire on the frames that need it.
    ///
    /// `AppStateActions.histogramStatistics` binned `log2(displayLuminance / 0.18)` off
    /// the rendered proxy and called the result a scene EV. A display-referred value
    /// cannot exceed 1.0, so that expression cannot exceed +2.47 EV, and highlight
    /// recovery fires on `percentileEV(0.995) + exposure > 3.0`. The threshold was
    /// unreachable. Every engine test fed FABRICATED statistics, so all five branches
    /// looked covered while the shipping measurement had no test at all.
    ///
    /// This runs the real measurement: a scene-referred frame, through the real render,
    /// quantized to 8 bits the way the proxy is, and back through the inversion.
    func testAutoRecoversABlownSkyThroughTheRealMeasurement() {
        // A third of the frame is sky at +6 EV — past the white anchor, so it renders
        // as flat display white and there is nothing left in the pixels to read. The
        // rest is a normally-exposed subject just under mid-grey.
        let frame = ImageBuffer(width: 96, height: 96) { u, v in
            v < 0.35 ? RGB(gray: 0.18 * exp2(6)) : RGB(gray: 0.18 * exp2(-1 + u))
        }
        let recipe = Recipe()
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
        let rendered = ReferenceRenderer.render(frame, plan: plan)

        var histogram = AutoTone.SceneHistogram(
            transform: DisplayTransform.forRecipe(recipe))
        let sRGB = RGBColorSpace.srgb
        var whitePixels = 0
        for y in 0..<rendered.height {
            for x in 0..<rendered.width {
                // Through 8-bit sRGB and back, because that is what the app measures:
                // the proxy is a CGImage, and the quantization is part of the path.
                let c = rendered[x, y] * plan.displayWhite
                let quantized = RGB(
                    TransferFunction.srgb.decode(
                        (TransferFunction.srgb.encode(Num.saturate(c.r)) * 255).rounded() / 255),
                    TransferFunction.srgb.decode(
                        (TransferFunction.srgb.encode(Num.saturate(c.g)) * 255).rounded() / 255),
                    TransferFunction.srgb.decode(
                        (TransferFunction.srgb.encode(Num.saturate(c.b)) * 255).rounded() / 255))
                if quantized.maxComponent >= 1 { whitePixels += 1 }
                histogram.add(displayLuminance: sRGB.luminance(quantized))
            }
        }
        XCTAssertGreaterThan(Double(whitePixels) / Double(rendered.count), 0.2,
                             "INVALID PROBE: the sky did not render as display white, "
                                 + "so nothing here is clipped and there is nothing to "
                                 + "recover")

        let stats = histogram.statistics
        XCTAssertGreaterThan(stats.percentileEV(0.995), 3.0,
                             "the frame's brightest half-percent measured "
                                 + "\(stats.percentileEV(0.995)) EV — a display-referred "
                                 + "reading cannot exceed +2.47 and cannot reach the "
                                 + "recovery threshold")

        let auto = AutoTone.suggest(from: stats)
        XCTAssertLessThan(auto.highlights, 0,
                          "Auto wrote Highlights \(auto.highlights) on a blown sky")

        // The mirror case, so the fix is not "always recover": a frame that fits
        // comfortably inside the anchors gets no recovery and no shadow lift.
        let easy = ImageBuffer(width: 96, height: 96) { u, _ in
            RGB(gray: 0.18 * exp2(-2 + 3 * u))
        }
        let easyRender = ReferenceRenderer.render(easy, plan: plan)
        var easyHistogram = AutoTone.SceneHistogram(
            transform: DisplayTransform.forRecipe(recipe))
        for y in 0..<easyRender.height {
            for x in 0..<easyRender.width {
                easyHistogram.add(displayLuminance:
                    sRGB.luminance(easyRender[x, y] * plan.displayWhite))
            }
        }
        let easyAuto = AutoTone.suggest(from: easyHistogram.statistics)
        XCTAssertEqual(easyAuto.highlights, 0, accuracy: 1e-9,
                       "Auto recovered highlights on a frame that has none")
        XCTAssertEqual(easyAuto.shadows, 0, accuracy: 1e-9,
                       "Auto lifted shadows on a frame that has none buried")
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
                // Every size the app bakes, and EXACTLY monotone at each — no epsilon.
                // The slack used to be 1e-9, which is both a hole and a puzzle: it
                // permitted the very dips it was meant to catch, and it left the
                // reader to guess whether a small backward step was expected. The
                // samples are produced by a running maximum, so `>=` is now literally
                // true and anything less is a real defect.
                //
                // Several sizes because the failure was size-dependent and invisible
                // at the default: the limiter certifies a grid of `i / 1024` while
                // `LUT1D` stores `i / (size - 1)`, and those coincide nowhere but the
                // endpoints. Testing one size tested one accident.
                for size in [256, 512, 1024] {
                    let lut = CurveStack.bakeParametric(p, size: size)
                    XCTAssertEqual(lut.samples.count, size)
                    var previous = -Double.infinity
                    for (i, v) in lut.samples.enumerated() {
                        XCTAssertGreaterThanOrEqual(
                            v, previous,
                            "non-monotone at h=\(h) s=\(s) size=\(size) index=\(i)")
                        previous = v
                    }
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

    /// The point of `preserveLuminance`: curve the luminance, carry the chroma ratios,
    /// so a contrast curve is not also a saturation boost — or a hue rotation.
    ///
    /// The tolerance used to be 2 degrees, which is a visible shift on a saturated red
    /// and 300× looser than what actually happens. Scaling all three channels by one
    /// factor on the ENCODED axis and decoding back is, in the power-law region, exactly
    /// a linear scale — so the hue moves by 0.007°, not 2°.
    ///
    /// It only stops being exact when a channel clips at the top of the encoded range,
    /// and then it moves fast: at a scale of 2.0 this same colour swings 12°. So the
    /// no-clip precondition is asserted alongside it. If a future curve change pushes
    /// this case into clipping, that assertion fails and says so, instead of the hue
    /// assertion failing for a reason nobody can see from the message.
    func testLuminancePreservingCurveDoesNotShiftHue() {
        let set = CurveSet(point: [[0, 0], [0.25, 0.45], [1, 1]], preserveLuminance: true)
        let stack = CurveStack(set)
        let input = RGB(0.30, 0.12, 0.06)
        let out = stack.apply(input)
        for (name, value) in [("r", out.r), ("g", out.g), ("b", out.b)] {
            XCTAssertLessThan(value, 0.999,
                              "the \(name) channel clipped, so this no longer measures "
                                  + "hue preservation")
        }
        let before = OKLabTransform.working.toLCh(input)
        let after = OKLabTransform.working.toLCh(out)
        XCTAssertEqual(after.h, before.h, accuracy: 0.1)
        XCTAssertGreaterThan(after.L, before.L)
        // Chroma rides along rather than being boosted — the saturation half of the
        // same claim, which nothing asserted at all.
        XCTAssertEqual(after.C / after.L, before.C / before.L, accuracy: 0.02,
                       "the curve changed chroma relative to lightness")
    }

    func testSettingPointReplacesNearbyPoints() {
        let pts = CurveStack.settingPoint([[0, 0], [0.5, 0.5], [1, 1]], x: 0.505, y: 0.7)
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[1][1], 0.7, accuracy: 1e-9)
        // The x too — whether the survivor takes the new x or keeps the old one is the
        // interesting half of "replaces", and it was unasserted. It KEEPS the old one:
        // dragging within the snap radius of an existing point moves that point
        // vertically rather than sliding it sideways under the cursor, which is what
        // makes a curve editor feel like it has handles.
        XCTAssertEqual(pts[1][0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(pts[0], [0, 0])
        XCTAssertEqual(pts[2], [1, 1])

        // Outside the snap radius it is a new point, not a replacement.
        let added = CurveStack.settingPoint([[0, 0], [0.5, 0.5], [1, 1]],
                                            x: 0.75, y: 0.8)
        XCTAssertEqual(added.count, 4)
        XCTAssertEqual(added[2][0], 0.75, accuracy: 1e-9)
        XCTAssertEqual(added[2][1], 0.8, accuracy: 1e-9)
        // And the result stays sorted, which every downstream interpolator assumes.
        XCTAssertEqual(added.map { $0[0] }, added.map { $0[0] }.sorted())
    }

    // MARK: - White balance

    func testWhiteBalanceIsIdentityAtAsShot() {
        let wb = WhiteBalanceEngine(asShotKelvin: 5200, asShotTint: 12,
                                    targetKelvin: nil, targetTint: nil)
        XCTAssertTrue(wb.isIdentity)
        XCTAssertLessThan(wb.matrix.maxAbsDifference(.identity), 1e-12)
    }

    // MARK: - The Temp/Tint rows and the neutral the render adapts from

    /// What the panel shows while `raw.temp` is nil, written back into the recipe, must
    /// change no pixel. That is the entire contract, and it was broken for every file
    /// that was not shot at 5500 K.
    ///
    /// The panel stood a literal 5500 in for the as-shot neutral it had no way to see,
    /// so on a 3200 K tungsten frame the row read 5500 while the render adapted from
    /// 3200 — and the first touch of the slider wrote the fabricated number, which the
    /// adaptation then honoured. A multi-thousand-Kelvin jump cut on a drag the
    /// photographer had not finished starting.
    ///
    /// The assertion is on the MATRIX rather than on the displayed number, because the
    /// number is the thing that was wrong: a test comparing it against a constant would
    /// have passed happily against 5500.
    func testTheTempRowShowsTheNeutralTheRenderAdaptsFrom() {
        let neutrals = [(3200.0, 12.0), (2850.0, 0.0), (5500.0, 0.0),
                        (6500.0, 10.0), (7500.0, -20.0),
                        // Past both clamps, so the row shows what the engine will use.
                        (500.0, -900.0), (99000.0, 900.0)]
        for (kelvin, tint) in neutrals {
            let asShot = WhiteBalanceEngine.Neutral(kelvin: kelvin, tint: tint)
            let shown = WhiteBalanceEngine.displayed(temp: nil, tint: nil, asShot: asShot)
            XCTAssertTrue(shown.isAsShot,
                          "a recipe with no override does not read as As Shot")

            let firstTouch = WhiteBalanceEngine(asShotKelvin: kelvin, asShotTint: tint,
                                                targetKelvin: shown.temperature,
                                                targetTint: shown.tint)
            XCTAssertTrue(firstTouch.isIdentity,
                          "writing the displayed \(shown.temperature) K / \(shown.tint) "
                              + "back onto a file shot at \(kelvin) K / \(tint) is not "
                              + "the same white balance")
            XCTAssertLessThan(firstTouch.matrix.maxAbsDifference(.identity), 1e-12,
                              "the first drag moved the picture at \(kelvin) K")

            // Nothing about "as shot" survives an override: an explicit value is shown
            // as itself, and the section reads as modified.
            let overridden = WhiteBalanceEngine.displayed(temp: 4100, tint: 7,
                                                          asShot: asShot)
            XCTAssertEqual(overridden.temperature, 4100, accuracy: 1e-12)
            XCTAssertEqual(overridden.tint, 7, accuracy: 1e-12)
            XCTAssertFalse(overridden.isAsShot)
        }

        // What the defect actually cost, as a number. A 5500 K stand-in on a tungsten
        // frame is not a rounding error in the readout — it is a visible adaptation.
        let fabricated = WhiteBalanceEngine(asShotKelvin: 3200, asShotTint: 0,
                                            targetKelvin: 5500, targetTint: 0)
        XCTAssertGreaterThan(fabricated.matrix.maxAbsDifference(.identity), 0.1,
                             "INVALID PROBE: 3200 K to 5500 K is not a visible move, so "
                                 + "this test is not measuring what it claims to")
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

    /// Capture sharpening's toggle has to be a toggle.
    ///
    /// The RAW stage's two branches were inverted: `auto == false` computed
    /// `(nil ?? 100) / 100 == 1` and applied the FULL measured strength, so turning
    /// capture sharpening off rendered the identical picture while the panel printed
    /// "Capture sharpening is off for this photo". And the Amount override lives inside
    /// a disclosure the panel shows only when `auto` is true — the branch that never
    /// read it — so the one control was invisible where it worked and inert where it
    /// showed.
    func testCaptureSharpeningStrengthFollowsItsToggleAndItsAmount() {
        // Off is off. This is the assertion that would have caught it.
        XCTAssertEqual(CaptureSharpen(auto: false).strengthFraction, 0, accuracy: 1e-12)
        XCTAssertEqual(CaptureSharpen(auto: false, amount: 150).strengthFraction, 0,
                       accuracy: 1e-12,
                       "an amount survived the off switch")

        // On with no override is the measurement itself, unscaled.
        XCTAssertEqual(CaptureSharpen(auto: true).strengthFraction, 1, accuracy: 1e-12)

        // The override is a PERCENTAGE of the measurement, so it has to be
        // proportional — this is the half that was read as a 0…1 fraction, which pinned
        // everything at or above 1 to maximum and made 25 and 150 both "full".
        XCTAssertEqual(CaptureSharpen(auto: true, amount: 50).strengthFraction, 0.5,
                       accuracy: 1e-12)
        XCTAssertEqual(CaptureSharpen(auto: true, amount: 25).strengthFraction, 0.25,
                       accuracy: 1e-12)
        XCTAssertEqual(CaptureSharpen(auto: true, amount: 150).strengthFraction, 1.5,
                       accuracy: 1e-12)
        XCTAssertNotEqual(CaptureSharpen(auto: true, amount: 25).strengthFraction,
                          CaptureSharpen(auto: true, amount: 150).strengthFraction)

        // And it is bounded and total: no setting produces a non-finite multiplier.
        // NaN needs an explicit guard rather than the clamp, because `Num.clamp` is
        // `min(max(x, lo), hi)` over Swift's generic `Comparable` min/max, and those
        // propagate NaN — every comparison against it is false, so `max(nan, 0)` is nan
        // and a slider typo would reach Core Image as `Float.nan`.
        let hostileAmounts: [Double] = [-50, 0, 500, .infinity, -.infinity, .nan]
        for amount in hostileAmounts {
            let f = CaptureSharpen(auto: true, amount: amount).strengthFraction
            XCTAssertTrue(f.isFinite, "amount \(amount) produced \(f)")
            XCTAssertGreaterThanOrEqual(f, 0)
            XCTAssertLessThanOrEqual(f, CaptureSharpen.maxStrength)
        }
    }

    /// Detail has to reach the GPU sharpener, and it can only reach it as a radius.
    ///
    /// `CIUnsharpMask` takes a radius and an intensity. The graph passed `sharpen.radius`
    /// straight through, so Detail — a live slider in the panel, correctly implemented
    /// in the reference renderer — was read by nothing at all on the shipping path.
    /// Detail weights the two finest wavelet bands there, which is the same statement
    /// as "sharpen at a smaller scale", so a radius is an honest carrier for it.
    func testSharpeningDetailReachesTheRadiusItStandsInFor() {
        // Detail 0 leaves the Radius slider exactly where the user put it.
        for radius in [0.5, 1.0, 2.0, 3.0] {
            XCTAssertEqual(ManualSharpen(radius: radius, detail: 0).unsharpRadius,
                           radius, accuracy: 1e-12)
        }
        // And more Detail means a smaller radius, strictly, at every base radius.
        for radius in [0.5, 1.0, 2.0, 3.0] {
            var previous = Double.infinity
            for detail in stride(from: 0.0, through: 100.0, by: 5) {
                let value = ManualSharpen(radius: radius, detail: detail).unsharpRadius
                XCTAssertLessThan(value, previous,
                                  "Detail \(detail) at radius \(radius) did not "
                                      + "sharpen finer than \(detail - 5) did")
                previous = value
            }
            // Half the base radius at the top of the slider.
            XCTAssertEqual(ManualSharpen(radius: radius, detail: 100).unsharpRadius,
                           radius * 0.5, accuracy: 1e-12)
        }
        // Total: no setting escapes what the filter accepts, including hostile input.
        for radius in [-1.0, 0, 99, .infinity, .nan] {
            for detail in [-50.0, 0, 500, .infinity, .nan] {
                let value = ManualSharpen(radius: radius, detail: detail).unsharpRadius
                XCTAssertTrue(value.isFinite && value >= 0.2 && value <= 5,
                              "radius \(radius) detail \(detail) gave \(value)")
            }
        }
    }

    /// The denoise mode switch has to switch something, and the visible slider has to
    /// be the one that acts.
    ///
    /// In `.ai` the RAW stage read `classic.luma` and `classic.chroma` — which the AI
    /// panel does not show — and ignored `amount`, which is the only slider it does
    /// show. So switching Classic → AI rendered identically and dragging the AI Amount
    /// slider did nothing, while two hidden values drove the result.
    func testTheDenoiseModeSwitchAndItsVisibleSliderBothAct() {
        // Off is off, whatever else is set.
        let off = Denoise(mode: .off, amount: 100,
                          classic: ClassicNR(luma: 90, chroma: 90)).appleStandIn
        XCTAssertEqual(off.luma, 0, accuracy: 1e-12)
        XCTAssertEqual(off.chroma, 0, accuracy: 1e-12)

        // Classic hands the decoder NOTHING now that Lumen's own Tier 1 runs in the
        // graph. Leaving Apple's stage on underneath it would denoise the frame twice
        // — once with a model of this sensor and once with somebody else's guess — and
        // the two smoothings compound where they agree.
        let classic = Denoise(mode: .classic,
                              classic: ClassicNR(luma: 40, chroma: 60)).appleStandIn
        XCTAssertEqual(classic.luma, 0, accuracy: 1e-12,
                       "the decoder's own luminance NR is still on under Tier 1")
        XCTAssertEqual(classic.chroma, 0, accuracy: 1e-12,
                       "the decoder's own colour NR is still on under Tier 1")

        // AI follows `amount`, and does NOT follow the hidden Classic values. The
        // hidden numbers are deliberately different from every amount used here — set
        // them equal and the test cannot tell the two sources apart.
        let hidden = ClassicNR(luma: 15, chroma: 30)
        let quiet = Denoise(mode: .ai, amount: 10, classic: hidden).appleStandIn
        let loud = Denoise(mode: .ai, amount: 90, classic: hidden).appleStandIn
        XCTAssertGreaterThan(loud.luma, quiet.luma + 0.1,
                             "the AI Amount slider did not change the luminance pass")
        XCTAssertGreaterThan(loud.chroma, quiet.chroma + 0.1,
                             "the AI Amount slider did not change the colour pass")
        XCTAssertNotEqual(loud.chroma, 0.30, accuracy: 1e-9,
                          "AI mode is still reading the hidden Classic chroma")
        XCTAssertNotEqual(loud.luma, 0.15, accuracy: 1e-9,
                          "AI mode is still reading the hidden Classic luma")

        // And the switch itself changes what the decoder is asked for.
        var recipe = Denoise(mode: .classic, amount: 90,
                             classic: ClassicNR(luma: 10, chroma: 10))
        let asClassic = recipe.appleStandIn
        recipe.mode = .ai
        let asAI = recipe.appleStandIn
        XCTAssertNotEqual(asClassic.chroma, asAI.chroma, accuracy: 1e-9,
                          "Classic and AI rendered the same for the same recipe")

        // Classic's two sliders are no longer part of the decode key, which is what
        // stopped a Luminance drag from re-demosaicing a 45-megapixel frame per frame.
        let quietClassic = Denoise(mode: .classic,
                                   classic: ClassicNR(luma: 0, chroma: 0)).appleStandIn
        let loudClassic = Denoise(mode: .classic,
                                  classic: ClassicNR(luma: 100, chroma: 100)).appleStandIn
        XCTAssertEqual(quietClassic.luma, loudClassic.luma, accuracy: 1e-12)
        XCTAssertEqual(quietClassic.chroma, loudClassic.chroma, accuracy: 1e-12)

        // Total: nothing escapes 0…1, including hostile input.
        let hostile: [Double] = [-50, 0, 500, .infinity, -.infinity, .nan]
        for value in hostile {
            for mode in [Denoise.Mode.off, .classic, .ai] {
                let pair = Denoise(mode: mode, amount: value,
                                   classic: ClassicNR(luma: value, chroma: value))
                    .appleStandIn
                XCTAssertTrue(pair.luma.isFinite && pair.luma >= 0 && pair.luma <= 1,
                              "\(mode) at \(value) gave luma \(pair.luma)")
                XCTAssertTrue(pair.chroma.isFinite && pair.chroma >= 0
                                  && pair.chroma <= 1,
                              "\(mode) at \(value) gave chroma \(pair.chroma)")
            }
        }
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

    // MARK: - Export must never write over something

    /// Export had no collision guard and no overwrite guard, and the encoders truncate.
    /// Re-exporting into a folder that already held a delivery replaced it silently.
    func testAFreePathIsUsedUnchanged() {
        let wanted = URL(fileURLWithPath: "/Export/DSC_0001.jpg")
        XCTAssertEqual(ExportRecipe.disambiguated(wanted) { _ in false }, wanted)
    }

    func testATakenPathIsSuffixedRatherThanOverwritten() {
        let wanted = URL(fileURLWithPath: "/Export/DSC_0001.jpg")
        let taken: Set<URL> = [wanted]
        let got = ExportRecipe.disambiguated(wanted) { taken.contains($0) }
        XCTAssertNotEqual(got, wanted, "the existing delivery would be overwritten")
        XCTAssertEqual(got, URL(fileURLWithPath: "/Export/DSC_0001-1.jpg"))
        XCTAssertEqual(got.pathExtension, "jpg", "the format extension was lost")
    }

    /// Two frames with the same basename in different subfolders resolve to one output
    /// path, so the run has to keep walking until it finds a free one.
    func testItWalksPastEveryTakenName() {
        let wanted = URL(fileURLWithPath: "/Export/DSC_0001.jpg")
        let taken: Set<URL> = [
            wanted,
            URL(fileURLWithPath: "/Export/DSC_0001-1.jpg"),
            URL(fileURLWithPath: "/Export/DSC_0001-2.jpg"),
        ]
        XCTAssertEqual(ExportRecipe.disambiguated(wanted) { taken.contains($0) },
                       URL(fileURLWithPath: "/Export/DSC_0001-3.jpg"))
    }

    /// Simulates the export loop itself: same source basename, same recipe, same
    /// destination folder. Every job must end up somewhere different.
    func testAWholeRunOfCollidingNamesProducesDistinctFiles() {
        var claimed: Set<URL> = []
        var results: [URL] = []
        for _ in 0..<5 {
            let path = ExportRecipe.disambiguated(
                URL(fileURLWithPath: "/Export/DSC_0001.jpg")) { claimed.contains($0) }
            claimed.insert(path)
            results.append(path)
        }
        XCTAssertEqual(Set(results).count, 5,
                       "five exports collapsed onto \(Set(results).count) files")
    }

    /// An extensionless destination must not grow a stray dot.
    func testDisambiguatingAPathWithNoExtension() {
        let wanted = URL(fileURLWithPath: "/Export/delivery")
        let got = ExportRecipe.disambiguated(wanted) { $0 == wanted }
        XCTAssertEqual(got, URL(fileURLWithPath: "/Export/delivery-1"))
    }

    /// A name that already contains dots keeps all but the last as part of the stem.
    func testDisambiguatingKeepsInnerDots() {
        let wanted = URL(fileURLWithPath: "/Export/shoot.final.tif")
        let got = ExportRecipe.disambiguated(wanted) { $0 == wanted }
        XCTAssertEqual(got, URL(fileURLWithPath: "/Export/shoot.final-1.tif"))
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

    /// The export sheet prints `appliedRadius` and the renderer runs it, so it must be
    /// `baseRadius` through the renderer's own clamp — inside the bounds they are the
    /// same number, past them the sheet must claim the clamp and not the formula
    /// (matte at the Resolution field's typed ceiling of 2400 ppi derives 24 px; the
    /// renderer runs 12), and Off must stay exactly zero because the renderer skips
    /// the filter entirely rather than sharpening at the clamp's floor.
    func testAppliedRadiusIsTheRadiusTheRendererRuns() {
        let matte = OutputSharpen(medium: .matte, amount: .standard)
        XCTAssertEqual(matte.appliedRadius(printPPI: 300), matte.baseRadius(printPPI: 300),
                       accuracy: 1e-12, "inside the clamp nothing changes")
        XCTAssertEqual(matte.appliedRadius(printPPI: 2_400),
                       OutputSharpen.appliedRadiusBounds.upperBound,
                       accuracy: 1e-12,
                       "past the clamp the readout must claim the clamp")
        XCTAssertEqual(OutputSharpen().appliedRadius(printPPI: 300), 0,
                       "Off sharpens nothing, not 0.3 px")
    }

    func testSoftProofFlagsOutOfGamutColours() {
        // A saturated Rec.2020 green is well outside sRGB.
        XCTAssertTrue(SoftProof.isOutOfGamut(RGB(0, 1, 0), working: .rec2020, proof: .srgb))
        XCTAssertFalse(SoftProof.isOutOfGamut(RGB(0.4, 0.4, 0.4),
                                              working: .rec2020, proof: .srgb))
    }
}

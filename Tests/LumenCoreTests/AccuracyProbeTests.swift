// M2's accuracy instruments (docs/23): the owner's charter is calibrated, smooth,
// competitive — these are the first two, measured where the engine actually runs.
//
// Printing probes in the PerfProbeTests tradition: measure first, pin bounds second.
// Each test prints one compact line per subject so a CI log is a data table; the
// asserts are catastrophic backstops (a broken instrument must still fail), not
// tuned tolerances — those get pinned in a follow-up WITH the numbers in hand.
import XCTest
@testable import LumenCore

final class AccuracyProbeTests: XCTestCase {

    // MARK: Calibration — the written physical contract, asserted

    /// Exposure's contract is the oldest one in photography: +1.00 doubles the light.
    /// The slider feeds `ToneEngine.exposureGain` into the fused linear matrix (S6),
    /// so the claim is testable at exactly the stage where it is defined —
    /// scene-linear, before picture formation compresses anything.
    func testExposureIsCalibratedInStops() {
        for ev in [-4.0, -2.0, -1.0, -0.33, 0.5, 1.0, 2.0, 4.0] {
            var recipe = Recipe()
            recipe.develop.tone.exposure = ev
            let plan = RenderPlan(recipe: recipe)
            let out = plan.linear.matrix.apply(RGB(gray: 0.18))
            XCTAssertEqual(out.r / 0.18, pow(2, ev), accuracy: pow(2, ev) * 1e-9,
                           "Exposure \(ev) must scale scene-linear light by exactly "
                               + "2^\(ev) — this is the slider's printed meaning")
        }
    }

    /// Contrast's contract, asserted through the FULL tabled pipeline this time
    /// (the travel probe showed it holds; this pins it): mid-grey is the pivot, and
    /// the pivot does not move, at any contrast, ever.
    func testContrastLeavesMidGreyExactlyAlone() {
        func rendered(_ contrast: Double) -> Double {
            var recipe = Recipe()
            recipe.develop.tone.contrast = contrast
            let plan = RenderPlan(recipe: recipe)
            let frame = ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0.18) }
            return ReferenceRenderer.render(frame, plan: plan)[4, 4].r
        }
        let base = rendered(0)
        for c in [-100.0, -50.0, 50.0, 100.0] {
            XCTAssertEqual(rendered(c) * 255, base * 255, accuracy: 0.25,
                           "Contrast \(c) moved mid-grey — the pivot's whole meaning "
                               + "is that it does not move")
        }
    }

    /// Temp writes the Kelvin it shows — anchored to the CIE standard, not to the
    /// code's own locus (M2 calibration contract). The daylight branch of the locus
    /// must land on the PUBLISHED D-illuminant chromaticities: D65 at (0.3127,
    /// 0.3290) and D50 at (0.3457, 0.3585). The Kelvin values carry the 1968 c₂
    /// revision (D65 ≈ 6504 K, D50 ≈ 5003 K) because that is what the published xy
    /// pairs are defined at; a slider showing "6504" must mean the illuminant the
    /// standard calls that. Tolerance 0.0015 in xy — the CIE polynomials are quoted
    /// to four figures and the locus blends analytically, so anything past a
    /// milli-xy is a real disagreement with the standard, not rounding.
    func testTheKelvinSliderLandsOnThePublishedDIlluminants() {
        let d65 = ColorTemperature.chromaticity(kelvin: 6504, tint: 0)
        XCTAssertEqual(d65.x, 0.3127, accuracy: 0.0015,
                       "6504 K renders x=\(d65.x) against D65's published 0.3127")
        XCTAssertEqual(d65.y, 0.3290, accuracy: 0.0015,
                       "6504 K renders y=\(d65.y) against D65's published 0.3290")

        let d50 = ColorTemperature.chromaticity(kelvin: 5003, tint: 0)
        XCTAssertEqual(d50.x, 0.3457, accuracy: 0.0015,
                       "5003 K renders x=\(d50.x) against D50's published 0.3457")
        XCTAssertEqual(d50.y, 0.3585, accuracy: 0.0015,
                       "5003 K renders y=\(d50.y) against D50's published 0.3585")
    }

    /// The four range sliders' endpoint targets, asserted through the full gain
    /// stage against the engine's own DOCUMENTED constants (M2 calibration
    /// contract): Highlights and Shadows own ±2.0 EV of range compression at full
    /// deflection, Whites +100 lifts its shelf 1.3 EV, Blacks −100 drops its shelf
    /// 2.2 EV. Measured as the peak stop shift over the whole tonal axis, so a
    /// weight curve that stopped reaching 1, a solver that started scaling a
    /// single-control move, or an edited constant all fail here by name.
    func testTheToneEndpointsDeliverTheirDocumentedEV() {
        func peakShift(_ mutate: (inout Tone) -> Void) -> Double {
            var tone = Tone()
            mutate(&tone)
            let engine = ToneEngine(tone: tone, zones: Zones())
            var peak = 0.0
            var t = -14.0
            while t <= 9.0 {
                peak = Swift.max(peak, abs(Num.safeLog2(engine.gain(at: t))))
                t += 0.05
            }
            return peak
        }
        XCTAssertEqual(peakShift { $0.highlights = -100 },
                       ToneEngine.highlightShadowRangeEV, accuracy: 0.05,
                       "Highlights −100 must compress its zone by the documented "
                           + "\(ToneEngine.highlightShadowRangeEV) EV")
        XCTAssertEqual(peakShift { $0.shadows = 100 },
                       ToneEngine.highlightShadowRangeEV, accuracy: 0.05,
                       "Shadows +100 must lift its zone by the documented "
                           + "\(ToneEngine.highlightShadowRangeEV) EV")
        XCTAssertEqual(peakShift { $0.whites = 100 },
                       ToneEngine.whiteToneEV, accuracy: 0.05,
                       "Whites +100 must lift its shelf by the documented "
                           + "\(ToneEngine.whiteToneEV) EV")
        XCTAssertEqual(peakShift { $0.blacks = -100 },
                       ToneEngine.blackToneEV, accuracy: 0.05,
                       "Blacks −100 must drop its shelf by the documented "
                           + "\(ToneEngine.blackToneEV) EV")
    }

    /// The Zones panel's contract (docs/04): the five default pivots sit at
    /// −4 / −2 / 0 / +2 / +4 EV around mid-grey. The shipped constants put "Mids"
    /// at scene −2 EV and "Darks" at −7.9 EV, where the display toe shows almost
    /// nothing — the slider dossier's #1 defect. This reads the stored pivots back
    /// through the engine's own axis, so the numbers and the docs cannot drift
    /// apart again.
    func testTheDefaultZonePivotsSitAtTheirDocumentedEVs() {
        let engine = ToneEngine(tone: Tone(), zones: Zones())
        let span = engine.whiteAnchorEV - engine.blackAnchorEV
        let documented: [Double] = [-4, -2, 0, 2, 4]
        let stored = Zones.defaultPivots
        XCTAssertEqual(stored.count, documented.count)
        for (x, ev) in zip(stored, documented) {
            XCTAssertEqual(x * span + engine.blackAnchorEV, ev, accuracy: 1e-9,
                           "a default pivot sits at \(x * span + engine.blackAnchorEV) "
                               + "EV where docs/04 documents \(ev) EV")
        }
    }

    /// Path-to-white: does overexposure BLEACH? The owner cranked Exposure to +4.7
    /// and got a pastel painting — sky still blue, sand still yellow, at 98%
    /// brightness — and called it fake. He was right: real film and every serious
    /// renderer desaturate toward white as channels blow out. This measures the
    /// residual display chroma of a saturated patch across an exposure sweep, at
    /// several hue-preservation settings, so the default is chosen by number and
    /// the bleach can never silently vanish again.
    func testOverexposureBleachesTowardWhite() {
        // Two patches with different lessons. Sun-lit sand is saturated but
        // plausible — it sits INSIDE the inset gamut, so it bleaches under either
        // orientation of the AgX matrices, and it is the patch that let the reversed
        // inset ship: this test and the darktable/RawTherapee baselines both went
        // green on it while a genuinely saturated colour never whitened at all. The
        // saturated red is the audit's conviction patch: with the inset applied in
        // the expanding direction its low channels went NEGATIVE, tone()'s x > 0
        // guard pinned them at the black floor, and no exposure could ever bleach
        // it (residual chroma 0.99 at +7 EV). A path-to-white test that only walks
        // colours the inset cannot push negative is not testing the path.
        let sand = RGB(1.0, 0.72, 0.42)
        let saturatedRed = RGB(0.36, 0.011, 0.011)
        func residualChroma(_ patch: RGB, exposureEV: Double,
                            huePreservation: Double) -> Double {
            var recipe = Recipe()
            recipe.develop.tone.exposure = exposureEV
            recipe.look.render.huePreservation = huePreservation
            let plan = RenderPlan(recipe: recipe)
            let frame = ImageBuffer(width: 8, height: 8) { _, _ in patch }
            let out = ReferenceRenderer.render(frame, plan: plan)[4, 4]
            let mx = out.maxComponent
            guard mx > 1e-6 else { return 0 }
            return (mx - Swift.min(out.r, Swift.min(out.g, out.b))) / mx
        }
        for (name, patch) in [("sand", sand), ("red ", saturatedRed)] {
            for hp in [100.0, 65.0, 0.0] {
                var line = String(format: "PATHTOWHITE %@ hp %3.0f:", name, hp)
                for ev in [0.0, 2.0, 3.0, 4.0, 5.0, 7.0] {
                    line += String(format: "  +%.0fEV %.3f", ev,
                                   residualChroma(patch, exposureEV: ev,
                                                  huePreservation: hp))
                }
                print(line)
            }
        }
        // The contract, pinned at the DEFAULT preset, for BOTH patches: pushed
        // +5 EV (sand) / +7 EV (the deeper red starts darker) the colour must have
        // lost most of itself on the way to white.
        let hp = DisplayTransformParams().huePreservation
        let sandAt5 = residualChroma(sand, exposureEV: 5, huePreservation: hp)
        let sandAt0 = residualChroma(sand, exposureEV: 0, huePreservation: hp)
        XCTAssertLessThan(sandAt5, sandAt0 * 0.45,
                          "at +5 EV the default rendering keeps \(sandAt5) of the "
                              + "sand patch's chroma vs \(sandAt0) at 0 EV — "
                              + "overexposure must bleach, not turn pastel")
        let redAt7 = residualChroma(saturatedRed, exposureEV: 7, huePreservation: hp)
        let redAt0 = residualChroma(saturatedRed, exposureEV: 0, huePreservation: hp)
        XCTAssertLessThan(redAt7, redAt0 * 0.45,
                          "at +7 EV the default rendering keeps \(redAt7) of a "
                              + "saturated red's chroma vs \(redAt0) at 0 EV — a "
                              + "colour the inset pushes hardest must still reach "
                              + "white, or the inset is running backwards")
    }

    /// The baked cube and `toneGainScale` are two halves of one number: the graph
    /// multiplies them back together (RenderGraph.applyTone), so they must divide by
    /// the SAME peak. They did not: the cube divided by the true sample maximum
    /// (floored at 1e-9) while the scale floored at 1.0 — so for any tone curve whose
    /// gain is everywhere below 1 (global zones at −1 EV: every sample exactly 0.5)
    /// the cube stored 1.0, the scale returned 1.0, and the GPU applied NO gain while
    /// the reference darkened a full stop. The product is the contract, asserted on
    /// exactly such a curve.
    func testBakedToneCubeTimesScaleEqualsTheGainTable() {
        var recipe = Recipe()
        recipe.develop.zones.global.ev = -1
        let plan = RenderPlan(recipe: recipe)
        guard let cube = plan.toneGainCubeBaked else {
            return XCTFail("a −1 EV global zone move must produce a live tone stage")
        }
        let scale = plan.toneGainScale
        for encoded in stride(from: 0.05, through: 0.95, by: 0.15) {
            let applied = cube.sample(RGB(gray: encoded)).r * scale
            let reference = plan.toneGainLUT.evaluate(encoded)
            XCTAssertEqual(applied, reference, accuracy: 0.02,
                "at encoded \(encoded) the GPU applies gain \(applied) while the "
                    + "reference table says \(reference) — the cube and the scale "
                    + "normalize by different peaks")
        }
    }

    /// THE SAME PAIR, ON THE PATH A DRAG ACTUALLY TAKES — which the test above never
    /// touches, because it builds its plan with the default `allowStaleTables: false`.
    ///
    /// The cube stores `gain / peak` and the graph multiplies `plan.toneGainScale`
    /// back, and the comment where it is baked says it outright: the two "are
    /// meaningless except as a pair". A draft frame gets the cube from
    /// `PlanTableCache.tableAllowingStale`, which by design returns the NEWEST table in
    /// the slot when this event's key misses — a cube normalized by a PREVIOUS event's
    /// peak. `toneGainScale` is not cached at all: it is recomputed from this event's
    /// `toneGainLUT`. So on every draft frame of a tone drag the GPU computes
    ///
    ///     oldGain(v) / oldPeak × newPeak
    ///
    /// instead of `newGain(v)` — the whole picture wrong by a global factor of
    /// `newPeak / oldPeak`, snapping back to correct whenever a background bake lands.
    /// That is a brightness pulse, and it appears on exactly the controls that move the
    /// peak gain: Contrast and Blacks above all, then Whites, Shadows, Highlights and
    /// the zones. It is what the owner reported as flicker once the notching was gone.
    ///
    /// The fix is that the tone cube does not take the stale path. It is the cheapest
    /// of the cached tables by a wide margin — 32³ samples of a 1-D lookup, measured at
    /// or below the noise floor of `PlanCostProbeTests` in a release build, against the
    /// 33³ finish and colour-grade tables at 15–18 ms — so it can simply be exact.
    /// Dragging a NON-tone control still hits the cache and pays nothing.
    func testTheToneCubeAndItsScaleStayAPairOnTheDRAFTPath() {
        PlanTableCache.clear()

        func plan(blacks: Double, stale: Bool) -> RenderPlan {
            var recipe = Recipe()
            recipe.develop.tone.contrast = 25
            recipe.develop.tone.blacks = blacks
            return RenderPlan(recipe: recipe, allowStaleTables: stale)
        }

        // Populate the slot, the way the first frame of a drag does.
        _ = plan(blacks: 0, stale: true)

        // Now the events that follow it, each with a key the cache has never seen —
        // which is every event of a real drag.
        for blacks in stride(from: 10.0, through: 80.0, by: 10.0) {
            let drafted = plan(blacks: blacks, stale: true)
            guard let cube = drafted.toneGainCubeBaked else {
                return XCTFail("a blacks move must produce a live tone stage")
            }
            let scale = drafted.toneGainScale
            for encoded in stride(from: 0.05, through: 0.95, by: 0.15) {
                let applied = cube.sample(RGB(gray: encoded)).r * scale
                let reference = drafted.toneGainLUT.evaluate(encoded)
                XCTAssertEqual(
                    applied, reference, accuracy: 0.02,
                    "blacks \(Int(blacks)), encoded \(encoded): the draft applies gain "
                        + "\(applied) where the table says \(reference). A cube "
                        + "normalized by one event's peak is being scaled by another "
                        + "event's — the picture is wrong by that ratio and snaps back "
                        + "when the background bake lands, which is the flicker.")
            }
        }
    }

    // MARK: Smoothness — does the shipping cube track the reference table?

    /// The GPU evaluates tone through a 32-knot cube resampled from the 1024-sample
    /// gain table — one knot per ~0.77 EV of encoded domain. Wherever the gain curve
    /// bends faster than trilinear interpolation can follow, the shipped picture
    /// diverges from the reference. This measures that divergence across the whole
    /// tonal axis for the moves a photographer actually makes.
    func testTheToneCubeFollowsTheReferenceTableAcrossTheTonalAxis() {
        let moves: [(String, (inout Recipe) -> Void)] = [
            ("highlights-100+shadows+100", { $0.develop.tone.highlights = -100
                                             $0.develop.tone.shadows = 100 }),
            ("highlights+50", { $0.develop.tone.highlights = 50 }),
            ("shadows+100", { $0.develop.tone.shadows = 100 }),
            ("whites+100", { $0.develop.tone.whites = 100 }),
            ("blacks-100", { $0.develop.tone.blacks = -100 }),
            ("contrast+50", { $0.develop.tone.contrast = 50 }),
            ("contrast-50", { $0.develop.tone.contrast = -50 }),
        ]
        for (name, apply) in moves {
            var recipe = Recipe()
            apply(&recipe)
            let plan = RenderPlan(recipe: recipe)
            XCTAssertFalse(plan.toneIsIdentity, "\(name) should engage the tone stage")
            let lut = plan.toneGainLUT
            let cube = plan.toneGainCubeBaked ?? plan.toneGainCube()
            let scale = plan.toneGainScale
            var maxErr = 0.0
            var meanErr = 0.0
            var atEV = 0.0
            let steps = 2048
            for i in 0...steps {
                let y = Double(i) / Double(steps)
                let ref = lut.evaluate(y)
                let shipped = cube.sample(RGB(gray: y)).r * scale
                guard ref > 1e-6, shipped > 1e-6 else { continue }
                let err = abs(log2(shipped / ref))
                meanErr += err
                if err > maxErr {
                    maxErr = err
                    atEV = Num.safeLog2(LumenLog.decode(y) / 0.18)
                }
            }
            meanErr /= Double(steps + 1)
            print(String(format: "TONECUBE %@: max %.4f EV at scene %+.1f EV, mean %.5f EV",
                         name, maxErr, atEV, meanErr))
            // Backstop only. 0.5 EV of cube-vs-table error would be a broken bake,
            // not an interpolation nuance; the real bound gets pinned from the data.
            XCTAssertLessThan(maxErr, 0.5,
                              "\(name): the 32-knot cube has left the reference table "
                                  + "entirely — that is a defect, not knot density")
        }

        // The export contract, asserted: an export-fidelity plan bakes the
        // export-size cube, and on the worst interactive case (Whites +100,
        // 0.080 EV at 32 knots) the finer cube must cut the error by at least half.
        // Trilinear error falls with the square of knot spacing, so the expected
        // factor is ~4; half is the backstop that still proves the mechanism.
        var whites = Recipe()
        whites.develop.tone.whites = 100
        let exportPlan = RenderPlan(recipe: whites, lutSize: LUT3D.exportSize)
        guard let exportCube = exportPlan.toneGainCubeBaked else {
            XCTFail("an export plan with live tone has no baked cube")
            return
        }
        XCTAssertEqual(exportCube.size, LUT3D.exportSize,
                       "the export plan must carry the export-grade tone cube")
        let lut = exportPlan.toneGainLUT
        let scale = exportPlan.toneGainScale
        var maxErr = 0.0
        for i in 0...2048 {
            let y = Double(i) / 2048.0
            let ref = lut.evaluate(y)
            let shipped = exportCube.sample(RGB(gray: y)).r * scale
            guard ref > 1e-6, shipped > 1e-6 else { continue }
            maxErr = Swift.max(maxErr, abs(log2(shipped / ref)))
        }
        print(String(format: "TONECUBE-EXPORT whites+100 @%d knots: max %.4f EV",
                     LUT3D.exportSize, maxErr))
        XCTAssertLessThan(maxErr, 0.040,
                          "the export cube must at least halve the 32-knot worst case")
    }

    /// The number the interactive-cube decision waits on (docs/23 M2): what a finer
    /// bake costs at plan-init time, which during a drag is every mouse event.
    func testWhatAFinerToneCubeCostsToBake() {
        var recipe = Recipe()
        recipe.develop.tone.whites = 100
        let plan = RenderPlan(recipe: recipe)
        for size in [32, 48, LUT3D.exportSize] {
            let t0 = DispatchTime.now().uptimeNanoseconds
            var cubes = 0
            for _ in 0..<10 {
                _ = plan.toneGainCube(size: size)
                cubes += 1
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                / Double(cubes)
            print(String(format: "BAKECOST tone cube %d^3: %6.2f ms per bake", size, ms))
        }
    }

    // MARK: Smoothness — does fine slider travel produce fine output steps?

    /// The owner's words: "it switches little by little instead of going up in a
    /// ramp." A ramp, measured: sweep each basic control at 201 steps and record the
    /// display-referred output of uniform patches through the REAL tabled pipeline
    /// (ReferenceRenderer.render — bakes the same gain table the graph resamples).
    /// A smooth control has per-step deltas clustered around their median; plateaus
    /// followed by jumps are quantization with a slider attached.
    func testEachBasicToneControlRespondsSmoothlyAcrossFineTravel() {
        // Shadow, dark-mid, mid-grey, bright-mid, highlight — the tones a
        // photographer watches while dragging.
        let patches: [Double] = [0.02, 0.09, 0.18, 0.36, 0.72]
        let controls: [(String, ClosedRange<Double>, (inout Recipe, Double) -> Void)] = [
            ("exposure", -5.0...5.0, { $0.develop.tone.exposure = $1 }),
            ("contrast", -100...100, { $0.develop.tone.contrast = $1 }),
            ("highlights", -100...100, { $0.develop.tone.highlights = $1 }),
            ("shadows", -100...100, { $0.develop.tone.shadows = $1 }),
            ("whites", -100...100, { $0.develop.tone.whites = $1 }),
            ("blacks", -100...100, { $0.develop.tone.blacks = $1 }),
        ]
        let steps = 200
        for (name, range, apply) in controls {
            // One output series per patch luminance.
            var series = [[Double]](repeating: [], count: patches.count)
            for i in 0...steps {
                let v = range.lowerBound
                    + (range.upperBound - range.lowerBound) * Double(i) / Double(steps)
                var recipe = Recipe()
                apply(&recipe, v)
                let plan = RenderPlan(recipe: recipe)
                for (p, L) in patches.enumerated() {
                    let frame = ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: L) }
                    let out = ReferenceRenderer.render(frame, plan: plan)
                    series[p].append(out[4, 4].r)
                }
            }
            for (p, L) in patches.enumerated() {
                // The renderer hands back display-LINEAR light; the owner's eye and
                // histogram live behind the sRGB transfer. Encode first, or every
                // shadow number understates by the gamma and the table lies about
                // exactly the tones these sliders exist for.
                let s = series[p].map { TransferFunction.srgb.encode(Num.saturate($0)) }
                var deltas = [Double]()
                for i in 1..<s.count { deltas.append(abs(s[i] - s[i - 1])) }
                let sorted = deltas.sorted()
                let median = sorted[sorted.count / 2]
                let maxStep = sorted.last ?? 0
                let total = s.max()! - s.min()!
                // The owner's symptom, as a number: the longest run of consecutive
                // slider steps the picture ignored, judged against this control's OWN
                // mean step (swing/steps) — smooth-and-gentle is not a plateau,
                // dead-then-jump is, and an absolute threshold confused the two on
                // every low-authority row of the first run of this probe.
                let meanStep = total / Double(deltas.count)
                var longestDeadRun = 0
                var run = 0
                if meanStep > 0 {
                    for d in deltas {
                        if d < meanStep * 0.1 {
                            run += 1
                            longestDeadRun = Swift.max(longestDeadRun, run)
                        } else {
                            run = 0
                        }
                    }
                }
                print(String(
                    format: "TRAVEL %@ @%.2f: swing %6.2f cv, median step %.3f cv, "
                        + "max step %.3f cv (%.1fx mean), longest dead run %d/%d",
                    name, L, total * 255, median * 255, maxStep * 255,
                    meanStep > 0 ? maxStep / meanStep : 0,
                    longestDeadRun, deltas.count))
                // Backstops: the series must be finite, and a control whose whole
                // travel does nothing at every watched tone is dead, which the proof
                // records already forbid.
                XCTAssertTrue(s.allSatisfy(\.isFinite),
                              "\(name) @\(L): non-finite output in the sweep")
            }
            // Exposure at mid-grey is the canary: its display response must be
            // strictly monotone across the whole sweep — any inversion is a defect
            // whatever the smoothness numbers say.
            if name == "exposure" {
                let mid = series[2]
                for i in 1..<mid.count {
                    XCTAssertGreaterThanOrEqual(mid[i], mid[i - 1] - 1e-9,
                        "exposure's display response inverted between steps "
                            + "\(i - 1) and \(i)")
                }
            }
        }
    }
}

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
            let cube = plan.toneGainCube32 ?? plan.toneGainCube()
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

// ProofMetrics.swift
//
// The measurements docs/20 defines the six proofs in terms of. Every number a proof
// record carries comes from here, so that "authority" means one thing across two
// hundred controls and a number taken today is comparable with one taken in six months.
//
// The unit is deliberate. Authority is reported in **sRGB code values at the display**,
// 0…255, not in scene-referred float. A control that moves a scene value by 0.01 has
// done something invisible at the bottom of the curve and something obvious at the top,
// and docs/19's whole reason for existing is that nobody could tell which until the
// number was denominated where the eye actually reads it. Blacks moving "0.004" sounds
// fine; Blacks moving 2.9 of 255 levels is a dead control, and it is the same fact.

import Foundation
import LumenCore

enum ProofMetrics {

    // MARK: - The display axis

    /// sRGB OETF. Inlined for the same reason `ProofFrames` inlines its EOTF: the ruler
    /// must not be built out of the thing being measured.
    ///
    /// The clamp is written value-first. `Swift.min(1, .nan)` returns 1 and
    /// `Swift.max(0, 1)` returns 1, so the original order turned a non-finite render
    /// into a frame of clean 255s before any metric saw it — the ruler laundering the
    /// thing it is meant to measure (TEST-01). Value-first is identical for every finite
    /// input and carries a NaN through to the assertions.
    static func linearToSRGB(_ x: Double) -> Double {
        let v = Swift.min(Swift.max(x, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// Display-linear render output → code values in 0…255, one per channel per pixel.
    static func codeValues(_ image: ImageBuffer) -> [Double] {
        var out = [Double]()
        out.reserveCapacity(image.count * 3)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let c = image[x, y]
                out.append(linearToSRGB(c.r) * 255)
                out.append(linearToSRGB(c.g) * 255)
                out.append(linearToSRGB(c.b) * 255)
            }
        }
        return out
    }

    // MARK: - P3 authority

    /// Peak separation between two renders, in code values. This is the P3 number.
    static func authority(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        let ca = codeValues(a), cb = codeValues(b)
        precondition(ca.count == cb.count, "authority needs two renders of one frame")
        var peak = 0.0
        // `runningMax`, not `Swift.max`: every other number in a record is derived
        // from this one, and an accumulator that steps over a NaN reports a control
        // as merely weak instead of broken (TEST-01).
        for i in 0..<ca.count { peak = runningMax(peak, abs(ca[i] - cb[i])) }
        return peak
    }

    /// Mean absolute separation, in code values. Reported alongside the peak because a
    /// control that moves six pixels by 40 levels and everything else by nothing is a
    /// different animal from one that moves the whole frame by 4, and the peak alone
    /// cannot tell them apart.
    static func meanSeparation(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        let ca = codeValues(a), cb = codeValues(b)
        precondition(ca.count == cb.count)
        var total = 0.0
        for i in 0..<ca.count { total += abs(ca[i] - cb[i]) }
        return total / Double(ca.count)
    }

    // MARK: - P2 aliveness

    /// The result of sweeping a control across its travel.
    struct Sweep {
        /// Peak code-value change from each step to the one before it.
        let stepDeltas: [Double]
        /// Peak code-value change from the first setting to each setting.
        let cumulative: [Double]
        /// Indices (into `stepDeltas`) where the render did not change at all.
        var deadSteps: [Int] { stepDeltas.indices.filter { stepDeltas[$0] < 1e-9 } }
        /// Smallest step that did move, ignoring the ones that did not.
        var smallestLiveStep: Double {
            stepDeltas.filter { $0 >= 1e-9 }.min() ?? 0
        }
        /// Authority over the whole travel.
        var authority: Double { cumulative.last ?? 0 }
        /// Whether the cumulative response only ever grows — a control that reverses
        /// direction mid-travel is doing two things and the user can only see one.
        ///
        /// Kept EXACT, at a tolerance of a billionth of a code value, and kept as a
        /// boolean. It is a true statement about the measurement and it stays in the
        /// record; what it is not is a thing to assert, for the reasons `givenBack`
        /// gives. Softening it with a tolerance would have erased a finding instead of
        /// explaining one.
        var isMonotone: Bool {
            zip(cumulative, cumulative.dropFirst()).allSatisfy { $1 >= $0 - 1e-9 }
        }

        /// How much of its own effect the control takes BACK over its travel: the sum of
        /// every backward step in the cumulative response, in code values.
        ///
        /// This is the number `isMonotone` should have been, and the difference is
        /// scale. The boolean answers "did the peak separation ever fall", at a
        /// tolerance of 1e-9 — which is an exactness the ruler does not have and a
        /// property two of the mixer's controls do not possess for reasons that are not
        /// defects (PROOF-01):
        ///
        ///  · `mixer.magenta.sat` gives back 0.46 of 85.81 code values, half a percent,
        ///    and it is the RULER. The engine is exactly monotone: on chart patch 17 the
        ///    post-mixer lightness and hue hold at 0.58292 and 344.248° at every one of
        ///    the 21 settings while chroma steps linearly 0 → 0.29101, and the band
        ///    weights are [0,0,0,0,0,0,0,1] with the chroma gate at 1.0 — dead centre,
        ///    not a boundary. `RenderPlan.exactColor` is monotone at all 21 steps in the
        ///    channel that carries the peak. Only the 65³ colour-grade table reverses,
        ///    and its error there converges away with table size, which is what makes it
        ///    interpolation rather than behaviour: green at Sat +90 measures 0.031798
        ///    exactly, 0.002685 at 65³ and 0.030754 at 129³. A monotonicity test at 1e-9
        ///    is asking a sampled table for an exactness it does not have.
        ///
        ///  · `mixer.red.hue` gives back 0.95 of 106.83, under one percent, and gives it
        ///    back with the tables removed as well — so this one is not the ruler. The
        ///    engine is again exactly monotone in the axis it moves: chart patch 15
        ///    holds L 0.50023 and C 0.15267 while its hue steps 4.5° per 10 units, the
        ///    45° at ±100 that `ColorEngine.hueRangeDegrees` promises. What reverses is
        ///    the patch's BLUE channel, which the rotation drives through zero — 0.01238
        ///    at +40, 0.00073 at +60, −0.00784 at +80 — after which the colour is
        ///    outside the gamut and picture formation, not the mixer, decides what blue
        ///    is rendered. The peak chord from one end of a curve is not a monotone
        ///    function of the angle, and past the boundary it flattens and drifts.
        ///
        ///    The hypothesis on file was different and is false: red's feather does
        ///    straddle the wrap point (its arc runs 351.73°…66.73°), but band membership
        ///    is evaluated on the STAGE INPUT hue, which no slider moves. Nothing crosses
        ///    a boundary — the weights are [1,0,0,0,0,0,0,0] at every setting.
        ///
        /// What the shape is actually worth catching is DETAIL-14's: a control that
        /// hands back a share of its effect the photographer can see. That is a
        /// fraction, not a boolean, so it is measured as one and asserted as one.
        ///
        /// The floor is written value-first on purpose. `Swift.max(0, x)` returns 0 for
        /// a NaN and `Swift.max(x, 0)` returns the NaN, so this order carries a
        /// non-finite render into the sum and the assertion fails instead of reading a
        /// clean zero (TEST-01).
        var givenBack: Double {
            zip(cumulative, cumulative.dropFirst())
                .reduce(0) { $0 + Swift.max($1.0 - $1.1, 0) }
        }
        /// Fraction of the total effect delivered in the first half of the travel.
        /// docs/19 found Highlights putting 87% of its work into its first half, which
        /// is a control whose top half is decoration.
        var frontLoading: Double {
            guard let total = cumulative.last, total > 1e-9 else { return 0 }
            return cumulative[cumulative.count / 2] / total
        }
    }

    /// Sweep a control and measure it. `render` is handed each setting in turn.
    ///
    /// `steps` defaults to 21 because docs/20 requires at least twenty and an odd count
    /// puts a sample exactly on the midpoint, which is where `frontLoading` reads.
    static func sweep(from lo: Double, to hi: Double, steps: Int = 21,
                      render: (Double) -> ImageBuffer) -> Sweep
    {
        precondition(steps >= 2)
        var renders = [ImageBuffer]()
        for i in 0..<steps {
            renders.append(render(lo + (hi - lo) * Double(i) / Double(steps - 1)))
        }
        var stepDeltas = [Double](), cumulative = [Double]()
        for i in 1..<steps {
            stepDeltas.append(authority(renders[i - 1], renders[i]))
            cumulative.append(authority(renders[0], renders[i]))
        }
        return Sweep(stepDeltas: stepDeltas, cumulative: cumulative)
    }

    // MARK: - P4 behaviour

    /// Worst excursion beyond the input's own range, in code values, measured near a
    /// known edge. This is the halo/rim number, and it is TWO numbers.
    ///
    /// A sharpening or local-contrast operator is allowed to steepen an edge. It is not
    /// allowed to make one side brighter than the frame's brightest input or darker than
    /// its darkest — that is a rim, and it is the artifact that separates a good
    /// implementation of these operators from a naive one.
    ///
    /// Split by direction, because for one operator on the registry the two directions
    /// are not the same kind of fact and their maximum told a story that was not true
    /// (PROOF-02). `detail.dehaze` recorded 51.14 on a veiled sky, which read as a rim
    /// and was investigated as one; measured separately it is 0.00 above the frame's
    /// brightest value and 51.14 below its darkest, on 84% of the ground and 0% of the
    /// sky. Removing a veil restores a black point, and a black point cannot be restored
    /// without going under the veiled frame's own floor. The number was right and its
    /// name was wrong.
    ///
    /// Both accumulators are `runningMax` rather than `Swift.max` (TEST-01). A ceiling is
    /// asserted against this number, and a render that had gone non-finite would fail
    /// both comparisons, accumulate nothing, and report an excursion of 0.00 — a clean
    /// pass on a frame that is entirely NaN.
    static func overshoot(_ rendered: ImageBuffer, against input: ImageBuffer)
        -> (above: Double, below: Double)
    {
        let inCodes = codeValues(input), outCodes = codeValues(rendered)
        precondition(inCodes.count == outCodes.count)
        let lo = inCodes.min() ?? 0, hi = inCodes.max() ?? 255
        var above = 0.0, below = 0.0
        for v in outCodes {
            guard v.isFinite else { above = .nan; below = .nan; break }
            if v > hi { above = runningMax(above, v - hi) }
            if v < lo { below = runningMax(below, lo - v) }
        }
        return (above, below)
    }

    /// Largest hue rotation between two renders, in degrees, over pixels with enough
    /// chroma for a hue to mean anything.
    ///
    /// The chroma floor is not fussiness: hue is undefined on the neutral axis, and
    /// without a floor the metric reports enormous rotations on grey pixels where the
    /// numerator is rounding error. `Protect Skin` scored zero on every skin tone for
    /// months behind exactly this kind of unguarded angle.
    static func hueRotation(_ a: ImageBuffer, _ b: ImageBuffer,
                            chromaFloor: Double = 0.02) -> Double
    {
        let ctx = OKLabTransform.working
        var worst = 0.0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let la = ctx.toLCh(a[x, y]), lb = ctx.toLCh(b[x, y])
                guard la.C > chromaFloor, lb.C > chromaFloor else { continue }
                var d = abs(Num.wrapHue(lb.h - la.h))
                if d > 180 { d = 360 - d }
                worst = Swift.max(worst, d)
            }
        }
        return worst
    }

    /// Largest change in perceived brightness between two renders, in OKLab L.
    /// A control that claims to move chroma only is measured against this.
    static func luminanceShift(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        let ctx = OKLabTransform.working
        var worst = 0.0
        for y in 0..<a.height {
            for x in 0..<a.width {
                worst = Swift.max(worst, abs(ctx.toLab(b[x, y]).L - ctx.toLab(a[x, y]).L))
            }
        }
        return worst
    }

    /// Largest change in chroma between two renders, in OKLab C.
    /// A control that claims to move luminance only is measured against this.
    static func chromaShift(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        let ctx = OKLabTransform.working
        var worst = 0.0
        for y in 0..<a.height {
            for x in 0..<a.width {
                worst = Swift.max(worst, abs(ctx.toLCh(b[x, y]).C - ctx.toLCh(a[x, y]).C))
            }
        }
        return worst
    }

    /// RMS difference from a ground-truth frame, in code values. The residual metric a
    /// denoise proof is scored on, against `ProofFrames.cleanISO6400`.
    static func rmsAgainst(_ truth: ImageBuffer, _ test: ImageBuffer) -> Double {
        let a = codeValues(truth), b = codeValues(test)
        precondition(a.count == b.count)
        var sum = 0.0
        for i in 0..<a.count { let d = a[i] - b[i]; sum += d * d }
        return (sum / Double(a.count)).squareRoot()
    }

    /// How much of a known edge survives an operation, as a fraction of the original
    /// step. Below 1 means the edge was softened; a colour denoiser that returns 0.65
    /// here has eaten a third of the boundary.
    static func edgeRetention(_ processed: ImageBuffer, against input: ImageBuffer,
                              acrossColumn column: Int) -> Double
    {
        func step(_ image: ImageBuffer) -> Double {
            var left = 0.0, right = 0.0
            var n = 0
            for y in 0..<image.height {
                left += image[Swift.max(0, column - 4), y].r
                right += image[Swift.min(image.width - 1, column + 4), y].r
                n += 1
            }
            return abs(right / Double(n) - left / Double(n))
        }
        let original = step(input)
        guard original > 1e-12 else { return 1 }
        return step(processed) / original
    }
}

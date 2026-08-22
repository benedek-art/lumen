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
    static func linearToSRGB(_ x: Double) -> Double {
        let v = Swift.max(0, Swift.min(1, x))
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
        for i in 0..<ca.count { peak = Swift.max(peak, abs(ca[i] - cb[i])) }
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
        var isMonotone: Bool {
            zip(cumulative, cumulative.dropFirst()).allSatisfy { $1 >= $0 - 1e-9 }
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

    /// Worst overshoot beyond the input's own range, in code values, measured near a
    /// known edge. This is the halo/rim number.
    ///
    /// A sharpening or local-contrast operator is allowed to steepen an edge. It is not
    /// allowed to make one side brighter than the frame's brightest input or darker than
    /// its darkest — that is a rim, and it is the artifact that separates a good
    /// implementation of these operators from a naive one.
    static func overshoot(_ rendered: ImageBuffer, against input: ImageBuffer) -> Double {
        let inCodes = codeValues(input), outCodes = codeValues(rendered)
        precondition(inCodes.count == outCodes.count)
        let lo = inCodes.min() ?? 0, hi = inCodes.max() ?? 255
        var worst = 0.0
        for v in outCodes {
            if v > hi { worst = Swift.max(worst, v - hi) }
            if v < lo { worst = Swift.max(worst, lo - v) }
        }
        return worst
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

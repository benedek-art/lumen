// WhiteBalanceEngine.swift
// White balance as a CAT16 chromatic adaptation at stage S6 (D9, docs/14 §2.1.4) —
// NOT as a decode-time multiplier.
//
// The decode always runs at camera-reference WB, so a neutral surface arrives as
// RGB(1,1,1). The user's Kelvin/Tint says which illuminant to neutralize; the residual
// adaptation between that and the as-shot neutral is this matrix. Two consequences the
// whole cache design leans on: dragging the temperature slider never invalidates the
// decode, the AI-denoise artifact, or the retouch cache — the three most expensive
// things Lumen owns — and WB composes as one 3×3 with Exposure and Printer Lights into
// the cheapest stage in the pipeline.

import Foundation

public struct WhiteBalanceEngine: Sendable {

    public let asShot: (kelvin: Double, tint: Double)
    public let target: (kelvin: Double, tint: Double)
    public let space: RGBColorSpace

    /// The working-space matrix this stage multiplies by. Identity when the target
    /// equals the as-shot neutral, exactly.
    public let matrix: Mat3

    public init(asShotKelvin: Double, asShotTint: Double,
                targetKelvin: Double?, targetTint: Double?,
                space: RGBColorSpace = .rec2020) {
        let aK = Num.clamp(asShotKelvin, ColorTemperature.minKelvin, ColorTemperature.maxKelvin)
        let aT = Num.clamp(asShotTint, -300, 300)
        let tK = Num.clamp(targetKelvin ?? aK, ColorTemperature.minKelvin, ColorTemperature.maxKelvin)
        let tT = Num.clamp(targetTint ?? aT, -300, 300)
        self.asShot = (aK, aT)
        self.target = (tK, tT)
        self.space = space
        self.matrix = WhiteBalanceEngine.adaptation(asShot: (aK, aT), target: (tK, tT), space: space)
    }

    /// Adapting *from* the target illuminant *to* the as-shot one is what makes the
    /// slider behave the way photographers expect: setting a lower Kelvin than the
    /// scene actually had cools the picture.
    public static func adaptation(asShot: (kelvin: Double, tint: Double),
                                  target: (kelvin: Double, tint: Double),
                                  space: RGBColorSpace) -> Mat3 {
        if asShot.kelvin == target.kelvin && asShot.tint == target.tint {
            return .identity
        }
        let source = ColorTemperature.chromaticity(kelvin: target.kelvin, tint: target.tint)
        let destination = ColorTemperature.chromaticity(kelvin: asShot.kelvin, tint: asShot.tint)
        let xyzAdapt = ChromaticAdaptation.adapt(from: source.xyz(), to: destination.xyz(),
                                                 cone: ChromaticAdaptation.cat16)
        return space.fromXYZ * xyzAdapt * space.toXYZ
    }

    public func apply(_ c: RGB) -> RGB { matrix.apply(c) }

    public var isIdentity: Bool {
        asShot.kelvin == target.kelvin && asShot.tint == target.tint
    }

    // MARK: - Eyedropper (D9)

    /// Kelvin/Tint that render `sample` neutral, where `sample` is a working-space
    /// colour measured on the CURRENT render (i.e. with `current` already applied).
    ///
    /// Solved by search rather than inversion: the locus is a fitted curve, so a
    /// closed-form inverse would be a second approximation layered on the first. Two
    /// passes over mired space cost well under a millisecond and are exact against the
    /// forward model, which is the property that matters when the user clicks a grey card.
    public static func neutralizing(sample: RGB, asShotKelvin: Double, asShotTint: Double,
                                    current: WhiteBalanceEngine,
                                    space: RGBColorSpace = .rec2020) -> (kelvin: Double, tint: Double) {
        // Undo the current WB so we search against the decoded value.
        let decoded = current.matrix.inverse.apply(sample)
        guard decoded.isFinite, decoded.maxComponent > 1e-9 else {
            return (asShotKelvin, asShotTint)
        }

        func residualChroma(kelvin: Double, tint: Double) -> Double {
            let m = adaptation(asShot: (asShotKelvin, asShotTint),
                               target: (kelvin, tint), space: space)
            let out = m.apply(decoded)
            let mean = (out.r + out.g + out.b) / 3
            guard mean > 1e-9 else { return .infinity }
            let n = out / mean
            return (n.r - 1) * (n.r - 1) + (n.g - 1) * (n.g - 1) + (n.b - 1) * (n.b - 1)
        }

        var bestK = asShotKelvin
        var bestT = asShotTint
        var best = Double.infinity

        // Coarse sweep: even steps in mireds (the perceptually uniform axis) × tint.
        var mired = 1e6 / ColorTemperature.maxKelvin
        let miredEnd = 1e6 / ColorTemperature.minKelvin
        while mired <= miredEnd {
            let k = 1e6 / mired
            var t = -150.0
            while t <= 150 {
                let d = residualChroma(kelvin: k, tint: t)
                if d < best { best = d; bestK = k; bestT = t }
                t += 10
            }
            mired += 8
        }

        // Refine around the winner.
        let centreMired = 1e6 / bestK
        var m2 = Swift.max(1e6 / ColorTemperature.maxKelvin, centreMired - 10)
        let m2End = Swift.min(miredEnd, centreMired + 10)
        let tCentre = bestT
        while m2 <= m2End {
            let k = 1e6 / m2
            var t = Swift.max(-300, tCentre - 12)
            let tEnd = Swift.min(300, tCentre + 12)
            while t <= tEnd {
                let d = residualChroma(kelvin: k, tint: t)
                if d < best { best = d; bestK = k; bestT = t }
                t += 0.5
            }
            m2 += 0.25
        }

        return (Num.clamp(bestK, ColorTemperature.minKelvin, ColorTemperature.maxKelvin),
                Num.clamp(bestT, -150, 150))
    }
}

// MARK: - The fused linear stage (S6)

/// White balance, Exposure and Printer Lights fuse into one 3×3 plus a gain — the
/// cheapest stage in the pipeline, placed exactly where it protects the expensive
/// caches above it.
public struct LinearStage: Sendable {
    public let matrix: Mat3

    public init(whiteBalance: WhiteBalanceEngine, exposureGain: Double, printerLightGains: RGB) {
        let gains = RGB(exposureGain * printerLightGains.r,
                        exposureGain * printerLightGains.g,
                        exposureGain * printerLightGains.b)
        self.matrix = Mat3.diagonal(gains) * whiteBalance.matrix
    }

    public init(matrix: Mat3) {
        self.matrix = matrix
    }

    public func apply(_ c: RGB) -> RGB { matrix.apply(c) }

    public var isIdentity: Bool { matrix.maxAbsDifference(.identity) < 1e-12 }
}

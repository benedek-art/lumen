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

    /// The tint the render actually uses at the current target: `target.tint` with
    /// its magenta half bounded by `ColorTemperature.tintLimit(kelvin:)`.
    ///
    /// Surfaced for the same reason `ToneEngine.effectiveHighlights` is: the engine
    /// has clamped this correctly since the tint guard landed and told nobody, so on
    /// a warm frame the slider's last stretch moved a number on screen and no pixel —
    /// which reads as a broken control unless the UI can say "bounded by physics
    /// here". The panel reads this and badges when it diverges from the slider.
    public var effectiveTint: Double {
        ColorTemperature.clampedTint(kelvin: target.kelvin, tint: target.tint)
    }

    // MARK: - What the Temp/Tint rows show while the recipe says "as shot"

    /// The neutral a file was actually shot at — `CIRAWFilter.neutralTemperature` for a
    /// camera file, and the fixed daylight reference for a rendered one, which is the
    /// same pair `RenderPlan` is handed and adapts from.
    public struct Neutral: Equatable, Sendable {
        public let kelvin: Double
        public let tint: Double

        public init(kelvin: Double, tint: Double) {
            self.kelvin = kelvin
            self.tint = tint
        }

        /// What a file recording no camera neutral adapts from (docs/04's fallback for
        /// non-raw input). It is a real answer for a JPEG and a WRONG one for a RAW,
        /// which is the whole of the defect below.
        public static let reference = Neutral(kelvin: 5500, tint: 0)
    }

    /// What a Temp/Tint row displays, and therefore what its first drag writes.
    public struct AsShotDisplay: Equatable, Sendable {
        public let temperature: Double
        public let tint: Double
        /// True while the recipe carries no override and the numbers above are the
        /// file's own neutral rather than the photographer's.
        public let isAsShot: Bool
    }

    /// `raw.temp`/`raw.tint` are optional, and nil means "as shot" — the decode's own
    /// neutral, a real number that lives on the image source. A slider cannot show "no
    /// value", so it stands a number in while the field is nil.
    ///
    /// That stand-in was the literal 5500, for every file. On a 3200 K tungsten frame
    /// the row read 5500 K when the render was adapting from 3200, and the first touch
    /// of the slider wrote the number the row was showing — so the picture jump-cut
    /// 2300 K on a drag the photographer had not finished starting. The panel's own
    /// comment admitted it: "the decode's own neutral, which is a real number the UI
    /// does not know."
    ///
    /// The contract this function exists to keep is one line long: **what the row shows,
    /// written back into the recipe, must change no pixel**. Everything else about the
    /// display follows from that, and `testTheTempRowShowsTheNeutralTheRenderAdaptsFrom`
    /// asserts it against the adaptation matrix rather than against the number.
    ///
    /// Clamped to the same limits `init` clamps its target to, so a file reporting
    /// something absurd shows the value the engine will actually use rather than one it
    /// will silently pull in.
    public static func displayed(temp: Double?, tint: Double?,
                                 asShot: Neutral) -> AsShotDisplay {
        let kelvin = Num.clamp(asShot.kelvin,
                               ColorTemperature.minKelvin, ColorTemperature.maxKelvin)
        let tintValue = Num.clamp(asShot.tint, -300, 300)
        return AsShotDisplay(temperature: temp ?? kelvin,
                             tint: tint ?? tintValue,
                             isAsShot: temp == nil && tint == nil)
    }

    // MARK: - Eyedropper (D9)

    /// Kelvin/Tint that render `sample` neutral, where `sample` is a working-space
    /// colour measured on the CURRENT render (i.e. with `current` already applied).
    ///
    /// Solved by search rather than inversion: the locus is a fitted curve, so a
    /// closed-form inverse would be a second approximation layered on the first. A
    /// bounded search in mired/tint space minimizes the actual forward model, including
    /// its physical tint guard, rather than introducing a separate inverse model.
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
            // Search the engine/typed range, not only the slider's soft travel.
            // adaptation still applies the physical, temperature-dependent guard.
            var t = -300.0
            while t <= 300 {
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

        // Near the positive tint guard, Kelvin and tint trade off along a narrow
        // valley. The best coarse seed's fixed refinement box can miss its minimum
        // even when the exact manual correction is legal. Walk that valley with a
        // bounded pattern search; each accepted move strictly improves the measured
        // neutral residual. A fixed evaluation budget also bounds picker latency.
        var remaining = 48
        for level in 0..<10 {
            let step = 4.0 / pow(2.0, Double(level))
            for _ in 0..<8 {
                guard remaining > 0, best > 1e-14 else { break }
                remaining -= 1
                let centre = 1e6 / bestK
                let tint = bestT
                var nextK = bestK
                var nextT = bestT
                var nextError = best
                for dm in [-1.0, 0, 1] {
                    for dt in [-1.0, 0, 1] where dm != 0 || dt != 0 {
                        let m = Num.clamp(centre + dm * step,
                                          1e6 / ColorTemperature.maxKelvin, miredEnd)
                        let t = Num.clamp(tint + dt * step, -300, 300)
                        let k = 1e6 / m
                        let error = residualChroma(kelvin: k, tint: t)
                        if error < nextError { nextError = error; nextK = k; nextT = t }
                    }
                }
                guard nextError < best else { break }
                best = nextError
                bestK = nextK
                bestT = nextT
            }
        }

        return (Num.clamp(bestK, ColorTemperature.minKelvin, ColorTemperature.maxKelvin),
                Num.clamp(bestT, -300, 300))
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

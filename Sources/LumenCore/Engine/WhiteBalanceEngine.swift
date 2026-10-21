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
        // A file with no defined neutral adapts from the rendered-file reference
        // rather than from NaN; a NaN target means "as shot", which is what nil means.
        let neutral = Neutral.sanitizedAsShot(kelvin: asShotKelvin, tint: asShotTint)
        let aK = Num.clamp(neutral.kelvin, ColorTemperature.minKelvin, ColorTemperature.maxKelvin)
        let aT = Num.clamp(neutral.tint, -300, 300)
        let tK = Num.clampFinite(targetKelvin ?? aK, ColorTemperature.minKelvin,
                                 ColorTemperature.maxKelvin, fallback: aK)
        let tT = Num.clampFinite(targetTint ?? aT, -300, 300, fallback: aT)
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

        /// The neutral a render may adapt FROM, given what the decoder reported.
        ///
        /// `CIRAWFilter.neutralTemperature`/`neutralTint` have no defined value for a
        /// file that records no camera neutral — a LinearRaw, one-sample-per-pixel
        /// monochrome DNG with no ColorMatrix, AsShotNeutral or CalibrationIlluminant
        /// is the case on record (corpus 1087, Leica M Monochrom). A non-finite or
        /// non-positive temperature is not a temperature, so the pair becomes the
        /// rendered-file `reference`; a finite temperature with a non-finite tint keeps
        /// the temperature and takes tint 0. Every real neutral passes through
        /// unchanged, so no camera file with a neutral renders differently.
        ///
        /// Only the RENDER side is sanitised. The source still hands Apple's own value
        /// back to the filter at decode, so the decode itself is untouched.
        public static func sanitizedAsShot(kelvin: Double, tint: Double) -> Neutral {
            guard kelvin.isFinite, kelvin > 0 else { return reference }
            return Neutral(kelvin: kelvin, tint: tint.isFinite ? tint : reference.tint)
        }
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
        let neutral = Neutral.sanitizedAsShot(kelvin: asShot.kelvin, tint: asShot.tint)
        let kelvin = Num.clamp(neutral.kelvin,
                               ColorTemperature.minKelvin, ColorTemperature.maxKelvin)
        let tintValue = Num.clamp(neutral.tint, -300, 300)
        return AsShotDisplay(temperature: temp ?? kelvin,
                             tint: tint ?? tintValue,
                             isAsShot: temp == nil && tint == nil)
    }

    // MARK: - Named presets (docs/04 §2.1)

    /// A named illuminant the preset menu offers. Picking one writes ordinary Temp/Tint
    /// numbers the photographer can then argue with; the glyph the menu draws beside the
    /// name is the panel's business and stays there.
    public struct Preset: Equatable, Sendable {
        public let name: String
        public let kelvin: Double
        public let tint: Double

        public init(name: String, kelvin: Double, tint: Double) {
            self.name = name
            self.kelvin = kelvin
            self.tint = tint
        }
    }

    /// The conventional daylight/tungsten anchors, in menu order. Daylight sits before
    /// Flash on purpose: they share 5500 K and differ only in tint, and the first match
    /// wins in `presetName`.
    public static let presets: [Preset] = [
        Preset(name: "Daylight", kelvin: 5500, tint: 10),
        Preset(name: "Cloudy", kelvin: 6500, tint: 10),
        Preset(name: "Shade", kelvin: 7500, tint: 10),
        Preset(name: "Tungsten", kelvin: 2850, tint: 0),
        Preset(name: "Fluorescent", kelvin: 3800, tint: 21),
        Preset(name: "Flash", kelvin: 5500, tint: 0),
    ]

    /// What the preset menu's title reads: "As Shot", a preset's name, or "Custom".
    ///
    /// The row reports what the numbers ARE rather than what was last clicked — the
    /// Lightroom grammar docs/04 writes as "any manual move flips to Custom". "What the
    /// numbers are" means the pair the render adapts TO, which is `displayed`'s pair:
    /// a nil field stands for the file's own (clamped) neutral, not for zero.
    ///
    /// This lived in the panel and got both halves of that wrong. It answered "As Shot"
    /// whenever Temp was nil without looking at Tint, so a Tint-only drag to +40 turned
    /// the picture magenta under a menu that still read — and ticked — As Shot. And it
    /// read a nil Tint as 0, so Temp 5500 on a frame shot at tint +10 (which renders
    /// 5500/+10, exactly Daylight) was labelled Flash, and on a frame shot at +3 (which
    /// matches nothing) was labelled Flash too. Moving it here puts it beside
    /// `displayed`, so the title and the two rows cannot disagree, and where a test can
    /// reach it.
    public static func presetName(temp: Double?, tint: Double?, asShot: Neutral,
                                  presets: [Preset] = WhiteBalanceEngine.presets) -> String {
        let display = displayed(temp: temp, tint: tint, asShot: asShot)
        guard !display.isAsShot else { return "As Shot" }
        for preset in presets
        where abs(preset.kelvin - display.temperature) < 1 && abs(preset.tint - display.tint) < 1 {
            return preset.name
        }
        return "Custom"
    }

    // MARK: - Eyedropper (D9)

    /// Whether a neutral sample is fit to solve from, read on the decoded window —
    /// camera-reference white balance, linear Rec.2020, before any of Lumen's stages.
    ///
    /// `neutralizing` will always return an answer, and that is the problem: a click on
    /// a blown sky or a specular highlight solves a confident, wrong white balance from
    /// channels the sensor clipped, and a click in deep shadow solves one from noise.
    /// The old guard refused only a mean of exactly zero, so the "too dark" message the
    /// app carried was unreachable.
    ///
    /// CLIPPED: any channel of the window's max at ≥ 95% of `clipLevel`. Sensor white is
    /// 1.0 in the decode convention; measured clipped areas on the corpus sit at
    /// 1.00–1.19, with p99.99 ≈ 1.0 on every clipped frame. 0.95 is 0.07 EV of headroom —
    /// below the sensor's non-linearity and the highlight reconstruction ramp. Clipped
    /// wins over dark: a window holding a clipped speck is wrong whatever its mean.
    ///
    /// TOO DARK: Rec.2020 luminance of the mean below 0.002 (−6.5 EV, a near-black on
    /// screen), or any mean channel ≤ 0. Measured at the Fit window, ISO 3200 frames
    /// wander 36 mired at Y ≈ 0.002 and 5–6 at 0.02; the ISO 100 Z7 II 0.9 at 0.01. The
    /// floor refuses only where every ISO is mostly noise; it does not try to be
    /// ISO-aware (docs/quality/lanes/WS-02/SPEC.md E1).
    public static func neutralSampleRefusal(mean: RGB, windowMax: RGB,
                                            clipLevel: Double = 1.0) -> NeutralSampleRefusal? {
        let peak = Swift.max(windowMax.r, windowMax.g, windowMax.b)
        if !peak.isFinite || peak >= 0.95 * clipLevel { return .clipped }
        guard mean.isFinite, mean.r > 0, mean.g > 0, mean.b > 0 else { return .tooDark }
        let luminance = 0.2627 * mean.r + 0.6780 * mean.g + 0.0593 * mean.b
        return luminance < 0.002 ? .tooDark : nil
    }

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
        // The same neutral `init` adapts from, so a file with none cannot seed the
        // search (or the fallback answer) with NaN.
        // Clamped exactly as `init` clamps it, so the search minimizes the model the
        // render runs: unclamped, a file reporting 1800 K searched against an 1800 K
        // neutral the render never adapts from, and a click on a grey card left it
        // blue-magenta.
        let sanitized = Neutral.sanitizedAsShot(kelvin: asShotKelvin, tint: asShotTint)
        let shot = Neutral(kelvin: Num.clamp(sanitized.kelvin, ColorTemperature.minKelvin,
                                             ColorTemperature.maxKelvin),
                           tint: Num.clamp(sanitized.tint, -300, 300))
        // Undo the current WB so we search against the decoded value.
        let decoded = current.matrix.inverse.apply(sample)
        guard decoded.isFinite, decoded.maxComponent > 1e-9 else {
            return (shot.kelvin, shot.tint)
        }

        func residualChroma(kelvin: Double, tint: Double) -> Double {
            let m = adaptation(asShot: (shot.kelvin, shot.tint),
                               target: (kelvin, tint), space: space)
            let out = m.apply(decoded)
            let mean = (out.r + out.g + out.b) / 3
            guard mean > 1e-9 else { return .infinity }
            let n = out / mean
            return (n.r - 1) * (n.r - 1) + (n.g - 1) * (n.g - 1) + (n.b - 1) * (n.b - 1)
        }

        var bestK = shot.kelvin
        var bestT = shot.tint
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

        // Report the tint the render will USE. Every magenta past the guard renders
        // identically, so the search cannot tell them apart and keeps the first grid
        // point it met beyond the bound — +10 written where +3.5 renders at 2000 K,
        // which the Tint row then flags as "bounded by physics" on the user's own
        // click. `temperatureAndTint` already reports the bounded value; this is the
        // same contract. Pixel-identical: `chromaticity` clamps to exactly this.
        let kelvin = Num.clamp(bestK, ColorTemperature.minKelvin, ColorTemperature.maxKelvin)
        return (kelvin,
                ColorTemperature.clampedTint(kelvin: kelvin, tint: Num.clamp(bestT, -300, 300)))
    }
}

/// Why a neutral sample was refused (`WhiteBalanceEngine.neutralSampleRefusal`). Each
/// case says what to do instead, because "could not read a neutral" alone leaves the
/// photographer guessing whether to click brighter or darker.
public enum NeutralSampleRefusal: Equatable, Sendable, CaseIterable {
    case tooDark
    case clipped

    public var message: String {
        switch self {
        case .tooDark: return "Too dark there to read a neutral — try a lit grey."
        case .clipped: return "That spot is clipped, so its colour is not real — "
            + "try a grey below the highlights."
        }
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

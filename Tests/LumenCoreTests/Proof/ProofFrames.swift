// ProofFrames.swift
//
// The fixed set of synthetic frames every proof is measured on (docs/20 §"The proof
// frame"). A control is swept on the smallest frame that contains what it acts on, and
// the record names which one.
//
// This file exists because docs/19 twice recorded a "dead" control that was the probe's
// fault. `colorDetail` scales a shrinkage threshold where the CHROMA edge map is high,
// and measured dead on a near-neutral frame. `hotPixels` measured dead on a frame with
// no hot pixels. Both came alive the moment the frame contained their subject. A dead
// reading on the wrong frame is a defect in the measurement, and the only defence is a
// named, fixed, reviewable set of inputs.
//
// Every frame is SCENE-REFERRED and linear, built around mid-grey at 0.18, because that
// is the axis the pipeline is denominated in. The sRGB constants below are decoded here
// rather than through `TransferFunction` on purpose: a proof frame is fixed input data,
// and deriving it from the library under test would let a transfer-function regression
// move the ruler and the thing being measured together.

import Foundation
import LumenCore

enum ProofFrames {
    /// Scene-referred mid-grey. Every frame is anchored to it.
    static let midGrey = 0.18

    /// The working space frames are delivered in. `RenderPlan` and `ReferenceRenderer`
    /// both default to Rec.2020, so a frame authored in sRGB primaries is converted
    /// rather than reinterpreted — the difference is 12° of hue on a saturated red and
    /// is exactly the kind of error a colour proof exists to catch.
    static let workingSpace = RGBColorSpace.rec2020

    // MARK: - Transfer

    /// IEC 61966-2-1 sRGB EOTF, inlined as fixed data (see the file note).
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    // MARK: - Deterministic noise

    /// xorshift64*, seeded per frame. Deterministic across platforms and runs: a proof
    /// whose input changes between runs cannot have a committed record.
    struct Noise {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }
        /// Uniform in [0,1).
        mutating func uniform() -> Double {
            Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
        /// Standard normal, Box–Muller. Two uniforms in, one normal out.
        mutating func normal() -> Double {
            let u1 = Swift.max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
    }

    // MARK: - The frames

    /// A linear grey ramp spanning −8…+5 EV around mid-grey, left to right.
    ///
    /// The range is the one docs/19 measured the six tone sliders over, so an authority
    /// number taken here is comparable with the numbers already in that document.
    static func neutralRamp(width: Int = 256, height: Int = 32) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, _ in
            RGB(gray: midGrey * exp2(-8 + 13 * u))
        }
    }

    /// The 24 ColorChecker patches, 6×4, in the working space.
    ///
    /// Values are the standard sRGB renderings of the chart, decoded to linear and
    /// scaled so that Neutral 5 lands on mid-grey — the chart's own 18% patch is the
    /// anchor the rest of the pipeline is built around. Patches 1 and 2 are dark and
    /// light skin, which is what the skin-protection and skin-line proofs measure on.
    static func colourChart(width: Int = 240, height: Int = 160) -> ImageBuffer {
        // Standard ColorChecker sRGB, 8-bit.
        let patches: [(Double, Double, Double)] = [
            (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67),
            (133, 128, 177), (103, 189, 170), (214, 126, 44), (80, 91, 166),
            (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
            (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31),
            (187, 86, 149), (8, 133, 161), (243, 243, 242), (200, 200, 200),
            (160, 160, 160), (122, 122, 122), (85, 85, 85), (52, 52, 52),
        ]
        // Neutral 5 is patch 22 (index 21); scale it onto mid-grey.
        let neutral5 = srgbToLinear(122.0 / 255.0)
        let scale = midGrey / neutral5
        let toWorking = RGBColorSpace.srgb.matrix(to: workingSpace)

        let linear: [RGB] = patches.map { p in
            let c = RGB(srgbToLinear(p.0 / 255) * scale,
                        srgbToLinear(p.1 / 255) * scale,
                        srgbToLinear(p.2 / 255) * scale)
            return toWorking.apply(c)
        }
        return ImageBuffer(width: width, height: height) { u, v in
            let col = Swift.min(Int(u * 6), 5)
            let row = Swift.min(Int(v * 4), 3)
            return linear[row * 6 + col]
        }
    }

    /// The scene-linear working-space colour of a ColorChecker patch, 1-based.
    ///
    /// Point Colour selects by SAMPLED COLOUR: `PointColor.sample` is a working-space
    /// triple, and the engine's selection weight is a distance from it in OKLCh. A
    /// swatch whose sample is not a colour the frame actually contains selects nothing,
    /// weight is zero at every pixel, and the whole control measures dead — the same
    /// class of probe error `colorDetail` and `hotPixels` recorded, arriving through the
    /// control's parameters rather than through the frame. This is the accessor that
    /// makes the two agree by construction.
    static func chartPatchColour(_ number: Int) -> RGB {
        let frame = colourChart()
        let p = chartPatchCentre(number)
        return frame[p.x, p.y]
    }

    /// Index of a ColorChecker patch in `colourChart`, 1-based as the chart numbers them.
    /// Dark skin is 1, light skin is 2, Neutral 5 is 22.
    static func chartPatchCentre(_ number: Int, width: Int = 240, height: Int = 160)
        -> (x: Int, y: Int)
    {
        let i = number - 1
        let col = i % 6, row = i / 6
        return (Int((Double(col) + 0.5) / 6 * Double(width)),
                Int((Double(row) + 0.5) / 4 * Double(height)))
    }

    // MARK: - The tonal colour wedge

    /// The eight band-centre hues, as full-saturation sRGB triples.
    ///
    /// Transcribed as FIXED DATA, exactly like the ColorChecker patches above and for
    /// the same reason: a frame derived at run time from `ColorEngine.bandHueCentres`
    /// and `OKLabTransform` would move whenever either of them moved, and the ruler
    /// would follow the thing being measured. Each triple was found once by walking the
    /// full-saturation sRGB hue wheel and keeping the position whose working-space OKLab
    /// hue was closest to a band centre; the worst residual is 0.011°.
    ///
    /// `testTheWedgeSitsOnTheBandCentres` re-derives those angles and fails if this
    /// table has stopped describing them. That failure would be real information — the
    /// band anchor is golden-locked and a `pipelineVersion` bump — rather than noise.
    static let bandCentreSRGB: [(Double, Double, Double)] = [
        (255, 0, 0), (255, 172, 0), (220, 255, 0), (0, 255, 184),
        (0, 229, 255), (0, 135, 255), (144, 0, 255), (255, 0, 189),
    ]

    /// Eight saturated hues, one per band centre, over the WHOLE tonal axis the zone
    /// systems are denominated on: −9…+5 EV, which is `ToneEngine`'s black and white
    /// anchors and therefore exactly the span `ZoneWindows` normalizes into [0,1].
    ///
    /// **Why neither existing colour frame would do, said plainly, because getting this
    /// wrong is how this repository has produced three fake findings.**
    ///
    /// `colourChart` carries chroma and nothing else. Its darkest patch sits about
    /// −2.5 EV from mid-grey and its brightest about +2.2, so on the grading panel's
    /// −9…+5 axis the entire chart lands inside the MID zone. Sweeping the shadows or
    /// the highlights wheel there measures a zone window that is nearly closed over
    /// every pixel in the frame — which is precisely the mistake
    /// `testAGradingWheelsHueIsContinuousAndClosed` records having made and fixed
    /// ("the shadows wheel had almost nothing to act on and a 180° rotation moved the
    /// probes by 0.007"). The primaries' Shadows Tint is worse served still: its window
    /// is pinned at −3 EV with a 1.5 EV half-width (`ColorEngine.tintPivotEV`), so the
    /// chart reaches only the very foot of it.
    ///
    /// `neutralRamp` spans the axis and carries no chroma at all. A purity control, a
    /// hue rotation and a B&W band all need a colour to act on, and `chromaGate` shuts
    /// two of them off entirely on the neutral axis.
    ///
    /// The wedge is NOT the frame for a control whose full deflection reaches the code
    /// value ceiling. Its top rows are +5 EV and render at 255, so a peak-separation
    /// metric on a control that can drive a hue to black reports one clipped pixel and
    /// the same number for every hue — which is what happened to the B&W mix, measured
    /// here at 254.92 and 254.50 for two different bands before it moved to the chart.
    ///
    /// The wedge is both: eight columns of constant hue, each row a constant luminance,
    /// so every zone window and every hue band has an equally saturated representative
    /// at every tonal position. Scaling an RGB triple scales OKLab's `a` and `b` by the
    /// same cube root, so a column's hue is EXACTLY constant down its whole length and
    /// only its chroma falls with luminance — the way a darker surface colour behaves.
    static func tonalColourWedge(width: Int = 256, height: Int = 128) -> ImageBuffer {
        let toWorking = RGBColorSpace.srgb.matrix(to: workingSpace)
        let weights = RGBColorSpace.srgb.luminanceWeights
        // Normalized to unit luminance in sRGB before the matrix. Luminance is CIE Y and
        // the matrix preserves XYZ, so the working-space luminance is the same number:
        // every column of a row sits at ONE tonal position, which is what makes a zone
        // window's weight the same for all eight hues.
        let directions: [RGB] = bandCentreSRGB.map { p in
            let c = RGB(srgbToLinear(p.0 / 255), srgbToLinear(p.1 / 255),
                        srgbToLinear(p.2 / 255))
            let y = Swift.max(c.r * weights.r + c.g * weights.g + c.b * weights.b, 1e-12)
            return toWorking.apply(RGB(c.r / y, c.g / y, c.b / y))
        }
        return ImageBuffer(width: width, height: height) { u, v in
            let column = Swift.min(Int(u * 8), 7)
            let luminance = midGrey * exp2(-9 + 14 * v)
            return directions[column] * luminance
        }
    }

    /// Which column of `tonalColourWedge` carries a band, and at which row an EV sits.
    static func wedgeSample(band: Int, ev: Double,
                            width: Int = 256, height: Int = 128) -> (x: Int, y: Int) {
        let u = (Double(band) + 0.5) / 8
        let v = (ev + 9) / 14
        return (Int(u * Double(width)),
                Swift.max(0, Swift.min(height - 1, Int(v * Double(height)))))
    }

    /// A hard vertical edge, four stops from one side to the other.
    ///
    /// The edge is where a sharpening halo, a clarity rim and an edge-aware mask all
    /// show themselves, and the four-stop step is large enough that an overshoot is
    /// unambiguous rather than lost in the quantization of a gentle one.
    static func stepEdge(width: Int = 128, height: Int = 128) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, _ in
            RGB(gray: midGrey * (u < 0.5 ? exp2(-2) : exp2(2)))
        }
    }

    // MARK: - The film gate frames

    // Both spatial stages of the Film Lab are denominated in MICRONS AT THE GATE, not in
    // pixels, and the existing frames are far too small to carry either kernel. That is
    // not a subtlety — on `stepEdge` at 128 pixels both controls measure as broken:
    //
    //   · Halation's first bounce is 65 µm on a 36 mm gate, which is
    //     `0.065 / 36 × longEdge` pixels. At 128 that is a σ of 0.23 PIXELS: the glow
    //     never leaves the pixel it came from, no light crosses the edge, and the
    //     control measured 4.31 code values over its whole travel.
    //   · Grain's plate scale is a pitch on the print times the render's pixels per
    //     print millimetre, floored at half a pixel so a plate cell can never be
    //     smaller than the sampling grid. On a 256-pixel ramp that product is 0.04…0.17
    //     for the whole 0.5…2.0 travel of Grain Size, so every setting hits the floor
    //     and all twenty-one renders came out byte-identical: authority 0.00, twenty
    //     dead steps, on a control that works.
    //
    // Neither reading was a defect in the engine. Both were this file being asked for a
    // frame it did not have — the same class of mistake as sweeping Sharpen Masking on a
    // flat field, arriving through the frame's SIZE rather than its content. The sizes
    // below are chosen from the arithmetic above: 2048 puts halation's first bounce at
    // 3.7 px and its third at 6.4, and 4096 clears the plate floor across the whole of
    // Grain Size, including its bottom end.

    /// `stepEdge` at a long edge big enough for a film-gate kernel — 2048 px, where
    /// halation's three bounces land at σ = 3.7, 5.2 and 6.4 pixels.
    ///
    /// Same four-stop step and the same construction, so a number taken here is
    /// comparable with a sharpening number taken on `stepEdge`; only the sampling
    /// density differs, which is precisely the axis this frame exists to change.
    static func wideStepEdge(width: Int = 2048, height: Int = 32) -> ImageBuffer {
        stepEdge(width: width, height: height)
    }

    /// `fineTexture` at a long edge big enough for a frame-denominated sharpening
    /// radius — 2048 px, where Radius's 0.5…3.0 travel scales to σ = 0.4…2.4 px against
    /// the 2, 4, 8 and 16 px periods the strips carry.
    ///
    /// The same four frequencies and the same construction, so a number taken here is
    /// comparable with one taken on `fineTexture`; only the sampling density differs,
    /// which is precisely the axis this frame exists to change — the same relationship
    /// `wideStepEdge` has to `stepEdge`, for the same reason one octave down.
    ///
    /// At the 256 px original that travel scaled to σ = 0.05…0.15: under, or a rounding
    /// error above, `SpatialOps.gaussianBlur`'s own support floor, so the unsharp half
    /// of S12 never ran and Detail swept a mix between a dead term and a live one
    /// (E2-04). `SharpeningFrameTests` is the guard that keeps that from coming back.
    static func wideFineTexture(width: Int = 2048, height: Int = 64) -> ImageBuffer {
        fineTexture(width: width, height: height)
    }

    /// A grey ramp at a long edge big enough that a grain plate cell exceeds a pixel —
    /// 4096 px, where the plate scale runs 0.68…2.7 across Grain Size's 0.5…2.0 travel.
    ///
    /// A ramp rather than a flat patch because grain's amplitude envelope is
    /// `√(p(1−p))` in DENSITY: it vanishes at both ends of the tonal range and peaks in
    /// the middle, so a frame at one density measures one point of a curve.
    static func grainField(width: Int = 4096, height: Int = 32) -> ImageBuffer {
        neutralRamp(width: width, height: height)
    }

    /// Band-limited detail at four spatial frequencies, in vertical strips.
    ///
    /// Periods of 2, 4, 8 and 16 pixels, at ±20% of mid-grey. Texture, Clarity and
    /// capture sharpening all claim to act on a band; a frame with one frequency cannot
    /// tell "boosted the right band" from "boosted everything".
    static func fineTexture(width: Int = 256, height: Int = 64) -> ImageBuffer {
        let periods = [2.0, 4.0, 8.0, 16.0]
        return ImageBuffer(width: width, height: height) { u, _ in
            let strip = Swift.min(Int(u * 4), 3)
            let x = u * Double(width)
            let m = sin(2 * Double.pi * x / periods[strip])
            return RGB(gray: midGrey * (1 + 0.2 * m))
        }
    }

    /// A clean frame plus a photon-and-read noise model at ISO 6400.
    ///
    /// Variance is `signal / gain + read²` in electrons, converted back to the scene
    /// axis — the same shot-noise model the denoise profile is denominated in, so a
    /// denoise proof is measured against noise of the shape the code claims to expect.
    /// `cleanISO6400()` returns the same frame without the noise, which is what a
    /// residual-error metric needs as ground truth.
    static func noisyISO6400(width: Int = 128, height: Int = 128, seed: UInt64 = 6400)
        -> ImageBuffer
    {
        var rng = Noise(seed: seed)
        var image = cleanISO6400(width: width, height: height)
        let fullWellElectrons = 1500.0   // at ISO 6400 on a modern full-frame sensor
        let readElectrons = 3.0
        for y in 0..<height {
            for x in 0..<width {
                let c = image[x, y]
                func perturb(_ v: Double) -> Double {
                    let electrons = Swift.max(v, 0) / midGrey * fullWellElectrons * 0.18
                    let sigma = (electrons + readElectrons * readElectrons).squareRoot()
                    let delta = rng.normal() * sigma
                    return Swift.max(0, v + delta / (fullWellElectrons * 0.18) * midGrey)
                }
                image[x, y] = RGB(perturb(c.r), perturb(c.g), perturb(c.b))
            }
        }
        return image
    }

    /// The noise-free twin of `noisyISO6400` — ground truth for a residual metric.
    ///
    /// Deliberately not flat: a denoiser that destroys detail scores perfectly on a flat
    /// frame, which is how a smoothing bug survives a residual-error test.
    static func cleanISO6400(width: Int = 128, height: Int = 128) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, v in
            let ramp = midGrey * exp2(-3 + 5 * v)
            let detail = 1 + 0.15 * sin(2 * Double.pi * u * Double(width) / 6.0)
            let patch = u < 0.5 ? 1.0 : 1.0        // luminance only; chroma frame below
            return RGB(gray: ramp * detail * patch)
        }
    }

    /// A veiled gradient with a known airlight and a known transmission.
    ///
    /// `I = J·t + A·(1 − t)`, so the clear scene `J`, the airlight `A` and the
    /// transmission `t` are all recoverable and a dehaze proof has ground truth rather
    /// than an opinion.
    ///
    /// It is also the frame that has twice reverted the Texture port: the upper half is
    /// a smooth, steep gradient, which a structure tensor reads as coherent almost
    /// everywhere even though it is a sky and not an edge. Any coherence gate that
    /// cannot tell a ramp from an edge kills positive Texture here, and that failure is
    /// the thing this frame is for.
    static func hazySky(width: Int = 128, height: Int = 128) -> ImageBuffer {
        let airlight = RGB(0.55, 0.62, 0.78)   // a blue-white veil, scene-referred
        return ImageBuffer(width: width, height: height) { u, v in
            // Clear scene: a sky gradient above, a textured ground below.
            let clear: RGB
            if v < 0.6 {
                clear = RGB(0.10 + 0.05 * v, 0.16 + 0.08 * v, 0.34 + 0.10 * v)
            } else {
                let t = 1 + 0.25 * sin(2 * Double.pi * u * Double(width) / 5.0)
                clear = RGB(0.13 * t, 0.11 * t, 0.08 * t)
            }
            // Transmission falls with distance; distance falls with height in frame.
            let transmission = 0.25 + 0.65 * v
            return RGB(clear.r * transmission + airlight.r * (1 - transmission),
                       clear.g * transmission + airlight.g * (1 - transmission),
                       clear.b * transmission + airlight.b * (1 - transmission))
        }
    }

    /// The airlight `hazySky` was built with — ground truth for a dehaze proof.
    static let hazySkyAirlight = RGB(0.55, 0.62, 0.78)

    /// Isolated single-pixel spikes on an otherwise clean frame, at known sites.
    ///
    /// Both polarities: a hot-pixel filter gated on a strict extremum has to catch a
    /// dark spike as well as a bright one, and a one-pixel LINE must survive — a median
    /// that eats it is removing detail, not defects.
    static func hotPixels(width: Int = 64, height: Int = 64) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height) { _, v in
            RGB(gray: midGrey * exp2(-1 + 2 * v))
        }
        for site in hotPixelSites {
            let base = image[site.x, site.y]
            image[site.x, site.y] = site.hot
                ? RGB(gray: base.r * 40) : RGB(gray: base.r * 0.02)
        }
        // A one-pixel-wide line that must NOT be removed.
        for y in 8..<(height - 8) { image[width / 3, y] = RGB(gray: midGrey * 3) }
        return image
    }

    /// Where `hotPixels` put its spikes, and which way each one goes.
    static let hotPixelSites: [(x: Int, y: Int, hot: Bool)] = [
        (11, 9, true), (23, 17, true), (41, 30, false),
        (52, 44, true), (18, 51, false), (37, 57, true),
    ]

    /// A saturated colour boundary — red against blue at equal luminance.
    ///
    /// Equal luminance on purpose: it isolates a CHROMA operation. Colour denoise,
    /// defringe and chromatic-aberration removal all act here, and docs/19 measured
    /// that Colour denoise at 100 destroys 35% of exactly this edge.
    static func chromaEdge(width: Int = 128, height: Int = 128) -> ImageBuffer {
        let toWorking = RGBColorSpace.srgb.matrix(to: workingSpace)
        let weights = RGBColorSpace.srgb.luminanceWeights
        // Two hues scaled to the same luminance, so any luminance change is the
        // operation's doing and not the frame's.
        let redRaw = RGB(1.0, 0.05, 0.05), blueRaw = RGB(0.05, 0.1, 1.0)
        func luma(_ c: RGB) -> Double {
            c.r * weights.r + c.g * weights.g + c.b * weights.b
        }
        let target = midGrey
        let red = toWorking.apply(RGB(redRaw.r * target / luma(redRaw),
                                      redRaw.g * target / luma(redRaw),
                                      redRaw.b * target / luma(redRaw)))
        let blue = toWorking.apply(RGB(blueRaw.r * target / luma(blueRaw),
                                       blueRaw.g * target / luma(blueRaw),
                                       blueRaw.b * target / luma(blueRaw)))
        return ImageBuffer(width: width, height: height) { u, _ in
            u < 0.5 ? red : blue
        }
    }

    /// `chromaEdge` under the same ISO 6400 noise model `noisyISO6400` uses, with
    /// `chromaEdge()` itself as ground truth.
    ///
    /// The two frames it is made of each answer half the question and neither answers
    /// it alone. `noisyISO6400`'s clean twin is neutral, so a colour denoiser that
    /// annihilates every chroma band scores PERFECTLY on it — there is no chroma signal
    /// to lose. `chromaEdge` carries the signal but no noise, so it can say what an
    /// operation costs and never what it is worth. Composed, one residual number scores
    /// the whole trade, which is what "is Colour 100 better than Colour 25" needs and
    /// what nobody could answer while the two frames stayed apart.
    ///
    /// The model is per-pixel Poisson–Gaussian taken from `NoiseProfile.forISO(6400)`
    /// itself, so the noise is the shape the engine's thresholds are denominated in —
    /// scoring a denoiser against noise it was never told about proves nothing about
    /// the slider.
    static func noisyChromaEdge(width: Int = 128, height: Int = 128,
                                seed: UInt64 = 6400, iso: Double = 6400) -> ImageBuffer
    {
        var rng = Noise(seed: seed)
        var image = chromaEdge(width: width, height: height)
        let profile = NoiseProfile.forISO(iso)
        for y in 0..<height {
            for x in 0..<width {
                var c = image[x, y]
                for channel in 0..<3 {
                    let v = Swift.max(c[channel], 0)
                    c[channel] = Swift.max(v + rng.normal() * profile.sigma(at: v), 0)
                }
                image[x, y] = c
            }
        }
        return image
    }

    /// `cleanISO6400`'s scene under `NoiseProfile.forISO(iso)`'s own model — the
    /// cross-ISO twin of `noisyChromaEdge(iso:)`, for asking where the LUMINANCE
    /// travel's optimum sits at each gain. Same reasoning as there: the noise must be
    /// the shape the engine's thresholds are denominated in, or the sweep measures
    /// the mismatch instead of the slider.
    static func noisyLumaFrame(width: Int = 128, height: Int = 128,
                               seed: UInt64 = 6400, iso: Double = 6400) -> ImageBuffer
    {
        var rng = Noise(seed: seed)
        var image = cleanISO6400(width: width, height: height)
        let profile = NoiseProfile.forISO(iso)
        for y in 0..<height {
            for x in 0..<width {
                var c = image[x, y]
                for channel in 0..<3 {
                    let v = Swift.max(c[channel], 0)
                    c[channel] = Swift.max(v + rng.normal() * profile.sigma(at: v), 0)
                }
                image[x, y] = c
            }
        }
        return image
    }
}

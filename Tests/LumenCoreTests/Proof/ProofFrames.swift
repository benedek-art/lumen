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
}

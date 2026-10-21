// CreativeSharpening.swift
// S12 — creative sharpening: Lightroom's Amount / Radius / Detail / Masking contract,
// plus Halo Damping, as one stage both renderers run (`RenderGraph.applySharpen` is the
// GPU twin, from the same constants and the same discrete taps).
//
// WHAT CHANGED AND WHY (docs/quality/lanes/WS-18/AUDIT.md has the measurements):
//
//   · RADIUS IS NATIVE PIXELS, as in Lightroom, Capture One and RawTherapee. It was a
//     fraction of the frame (σ = radius × longEdge / 2560), so on a 7008 px export
//     Radius 1 was a 2.74 px blur and the 0.5 minimum was 1.37 px: fine sharpening was
//     unreachable on any file above 2560 px, and Amount 70 rimmed the sky gaps in the
//     A7 IV frame. σ = radius × decode scale now: 1 px on the sensor at 1:1 and on
//     export, and the same sensor pixel's worth of blur on a downsampled preview — so
//     a fit view shows sharpening the way a fit view of the exported file does, which
//     is to say barely, and 1:1 is where it is judged (as in every raw editor).
//   · IT NO LONGER BRIGHTENS THE PICTURE. The unsharp mask ran on log2 luminance and
//     was applied as 2^Δ, and the mean of 2^Δ is above 1 when Δ averages zero:
//     +0.084 EV over the whole A7 IV frame at Amount 100. It runs on the cube root of
//     luminance now (a perceptual lightness, CIE L*'s exponent) where the same
//     convexity is a third as strong, and the halo bound below removes most of the
//     rest.
//   · DETAIL IS LIGHTROOM'S DETAIL: halo suppression. Every pixel's sharpened value is
//     first held to the range a halo cannot leave (`CaptureStage.peakBounds`: the 3×3
//     [min, max], extended only at genuine one- or two-pixel peaks — a twig, a ridge,
//     a fine line — so texture keeps its gain). Detail is how much of the OVERSHOOT
//     past that bound is let back in: 0 is halo-free edge sharpening, 100 is a free
//     unsharp mask. It used to cross-fade toward a fixed-scale wavelet band that
//     ignored Radius (Radius 0.5 and 3 measured identical at Detail 100).
//   · HALO DAMPING DAMPS THE HALO: it scales the bright-side part of that same
//     overshoot, which is the rim itself. It used to gate on the local USM value,
//     which landed mid-edge (the pinned defect in FieldBaselineProbeTests).
//   · MASKING IS LIGHTROOM'S MASKING: 0 sharpens everything, 50 already leaves flat
//     areas out, 100 keeps only strong edges. The edge measure is the window-averaged
//     gradient magnitude of √Y, where shot noise has one amplitude at every tone — the
//     old EV/px gradient read shadow noise as edges because log2 expands it. `maskPlane` is the exact
//     plane the render multiplies by, and it is what ⌥-dragging Masking shows.
//   · BOTH RENDERERS READ THE S12 INPUT. The reference built its edge mask and fine
//     band at S8, before colour, grade and local adjustments; the GPU built them from
//     the real S12 input. Neither reads the S8 decomposition now.

import Foundation

public struct SharpenStage: Sendable, Equatable {

    /// USM gain in perceptual luminance, 0…1.5 (Amount / 100).
    public let amount: Double
    /// Gaussian σ in the pixels of the buffer being sharpened.
    public let sigma: Double
    /// Fraction of the overshoot past the halo bound let back in, 0…1.
    public let detail: Double
    public let masking: Double
    public let haloDamping: Double

    /// How far a genuine peak may extend past its 3×3 range, which is where Detail's
    /// TEXTURE half lives: 0.25 at Detail 0 (fine texture and noise grains, which are
    /// one-pixel peaks, barely grow), S4's 1.0 at Detail ~43, 2.0 at Detail 100. With a
    /// fixed allowance Detail only moved edges — measured, noise gain 1.592 at both
    /// Detail 0 and Detail 100.
    public var peakAllowance: Double { 0.25 + 1.75 * detail }
    /// The most the stage may move a pixel, as a luminance ratio (±2 EV).
    public static let ratioLimit: Double = 4

    public init(_ p: ManualSharpen, decodeScale: Double) {
        let s = (decodeScale.isFinite && decodeScale > 0) ? Swift.min(decodeScale, 1) : 1
        func clean(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
            v.isFinite ? Num.clamp(v, lo, hi) : fallback
        }
        amount = clean(p.amount, 0, 150, 0) / 100
        sigma = clean(p.radius, 0.5, 3.0, 1.0) * s
        detail = clean(p.detail, 0, 100, 25) / 100
        masking = clean(p.masking, 0, 100, 0) / 100
        haloDamping = clean(p.haloSuppression, 0, 100, 0) / 100
    }

    public var isIdentity: Bool { amount <= 0 }

    /// Perceptual luminance: the cube root, floored at zero.
    public static func perceptual(_ y: Double) -> Double { cbrt(Swift.max(y, 0)) }

    /// The plane Masking measures edges on: √Y. Square root is the variance-stabilizing
    /// transform for shot noise (the Anscombe transform without its offset), so photon
    /// noise has the same amplitude in it from shadow to highlight and ONE knee means
    /// the same thing everywhere. The first cut measured on the cube root, where the
    /// G9's ISO 3200 shadow noise still read ~1.5× the mid-tone noise and leaked
    /// through Masking 50 (evidence/after_2348_masking.png was made to check this).
    public static func edgeMeasure(_ y: Double) -> Double { Swift.max(y, 0).squareRoot() }

    /// The Masking knees on the window-averaged |∇√Y| (units: √luminance per pixel;
    /// mid-grey is 0.424, a blurred 2 EV step 0.09→0.36 averages ~0.07/px, and the
    /// G9's real ISO 3200 noise ~0.012/px — the ISO 3200 seed profile alone says 0.008).
    ///
    /// `lo = 0.035·m^1.25`, `hi = 2·lo + 0.002`. At 0 the mask is exactly 1 (a separate
    /// branch, so Masking 0 is the unmasked stage bit for bit). At 50 `lo` is 0.0147,
    /// above that noise; at 100 `lo` is 0.035 and `hi` 0.072, so a 2 EV edge keeps most
    /// of its sharpening and texture keeps none.
    public static func maskKnees(masking m: Double) -> (lo: Double, hi: Double) {
        let lo = 0.035 * pow(Num.saturate(m), 1.25)
        return (lo, 2 * lo + 0.002)
    }

    /// The Masking plane for an edge-measure (√Y) plane: 1 = sharpened, 0 = left
    /// alone. Exactly what `apply` multiplies by, and what the ⌥-drag view draws.
    public static func maskPlane(edgeMeasure e: Plane, masking: Double) -> Plane {
        guard masking > 0 else { return Plane(width: e.width, height: e.height, fill: 1) }
        var magnitude = Plane(width: e.width, height: e.height)
        for y in 0..<e.height {
            for x in 0..<e.width {
                let gx = (e.clampedSample(x + 1, y) - e.clampedSample(x - 1, y)) * 0.5
                let gy = (e.clampedSample(x, y + 1) - e.clampedSample(x, y - 1)) * 0.5
                magnitude[x, y] = (gx * gx + gy * gy).squareRoot()
            }
        }
        let averaged = SpatialOps.boxApproximatedGaussian(magnitude, sigma: 1.5)
        let k = maskKnees(masking: masking)
        return averaged.map { Num.smoothstep(k.lo, k.hi, $0) }
    }

    /// The ⌥-drag view: the mask computed from DISPLAYED sRGB pixels (what the viewer
    /// holds), as an 8-bit grey image, white = sharpened. The render measures on its own
    /// scene-linear S12 input, which the viewer does not have; decoding the sRGB
    /// transfer gets display-linear luminance, and through a global tone curve that
    /// moves the knees by the curve's local slope — close in mid-tones, conservative
    /// (more masked) in compressed highlights. A visualization, stated as one.
    public static func maskPreview(sRGB bytes: [UInt8], width: Int, height: Int,
                                   bytesPerPixel: Int = 4, masking: Double) -> [UInt8] {
        guard width > 0, height > 0, bytes.count >= width * height * bytesPerPixel
        else { return [] }
        var e = Plane(width: width, height: height)
        let w = RGBColorSpace.srgb.luminanceWeights
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * bytesPerPixel
                func lin(_ b: UInt8) -> Double {
                    TransferFunction.srgb.decode(Double(b) / 255)
                }
                let lum = w.r * lin(bytes[i]) + w.g * lin(bytes[i + 1]) + w.b * lin(bytes[i + 2])
                e[x, y] = edgeMeasure(lum)
            }
        }
        return maskPlane(edgeMeasure: e, masking: masking).values.map {
            UInt8((Num.saturate(Double($0)) * 255).rounded())
        }
    }

    public func apply(_ image: ImageBuffer, space: RGBColorSpace = .rec2020) -> ImageBuffer {
        guard !isIdentity, image.width >= 3, image.height >= 3 else { return image }
        let lum = image.luminancePlane(space: space)
        let p = lum.map { Self.perceptual($0) }
        let blurred = CaptureStage.blur(p, taps: CaptureStage.gaussianTaps(sigma: sigma))
        let mask = Self.maskPlane(edgeMeasure: lum.map { Self.edgeMeasure($0) },
                                  masking: masking)

        var out = image
        for y in 0..<image.height {
            for x in 0..<image.width {
                let c = p[x, y]
                guard c > 1e-4 else { continue }
                let target = sharpened(c: c, blurred: blurred[x, y],
                                       bounds: CaptureStage.peakBounds(
                                           p, x, y, allowance: peakAllowance))
                let v = c + Num.saturate(mask[x, y]) * (target - c)
                let ratio = Num.clamp(pow(Swift.max(v, 0) / c, 3),
                                      1 / Self.ratioLimit, Self.ratioLimit)
                if ratio != 1 { out[x, y] = image[x, y] * ratio }
            }
        }
        return out
    }

    /// One pixel's sharpened perceptual value before masking.
    func sharpened(c: Double, blurred: Double, bounds: (lo: Double, hi: Double)) -> Double {
        let free = c + amount * (c - blurred)
        let bounded = Num.clamp(free, bounds.lo, bounds.hi)
        var over = free - bounded
        if over > 0 { over *= 1 - haloDamping }
        return bounded + detail * over
    }
}

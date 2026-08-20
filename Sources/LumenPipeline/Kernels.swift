// Kernels.swift
// The complete custom-shader surface of Lumen's render path: ten small kernels.
//
// That number is the point. Nearly every colour-bearing stage is a pure RGB→RGB
// function, so the engine evaluates it once in LumenCore's reference implementation
// and bakes it into a lookup table that the stock colour-cube filter applies
// (docs/14 §5, adapted: Core Image is used as a graph compiler, and the graph's
// per-pixel colour work is one table fetch rather than nine hand-ported shaders).
// What remains here is only what a table cannot express: the log shaper that makes an
// unbounded scene fit a bounded table, image-by-image arithmetic for the guided
// filter, mask compositing, grain, and the vignette's dependence on position.
//
// Every kernel has a Swift twin in LumenCore, and PipelineGoldenTests renders both to
// compare them. A kernel that fails to compile leaves `KernelLibrary.isAvailable`
// false and the renderer falls back to the CPU reference path — slower, identical
// pixels, and honest about it in the UI rather than silently wrong.

#if os(macOS)

import CoreImage
import Foundation
import LumenCore

public enum KernelLibrary {

    // MARK: - Sources

    /// Scene-linear → the shaper's [0,1] log domain. The twin of `LumenLog.encode`.
    static let logEncodeSource = LumenLog.encodeKernelSource

    /// The shaper's domain → scene-linear. The twin of `LumenLog.decode`.
    static let logDecodeSource = LumenLog.decodeKernelSource

    /// Per-channel product of two images. Used for tone gain, vignette and any other
    /// "multiply by a field" stage; unlike CIMultiplyBlendMode it does not clamp,
    /// which matters when both sides are scene-referred and unbounded.
    static let multiplySource = """
    kernel vec4 lumenMultiply(__sample a, __sample b) {
        return vec4(a.rgb * b.rgb, a.a);
    }
    """

    /// Per-channel square — the guided filter's correlation term.
    static let squareSource = """
    kernel vec4 lumenSquare(__sample a) {
        return vec4(a.rgb * a.rgb, a.a);
    }
    """

    /// Luminance broadcast to all three channels. The weights are passed in so the
    /// working space is never assumed.
    static let luminanceSource = """
    kernel vec4 lumenLuminance(__sample a, vec3 w) {
        float y = dot(a.rgb, w);
        return vec4(y, y, y, a.a);
    }
    """

    /// Guided filter, coefficient step: from the local mean of I and of I², produce
    /// the per-pixel (a, b) that make the filter edge-aware.
    ///   a = var / (var + eps),  b = meanI · (1 − a),  var = meanII − meanI²
    static let guidedCoefficientsSource = """
    kernel vec4 lumenGuidedCoefficients(__sample meanI, __sample meanII, float eps) {
        float mi = meanI.r;
        float v = max(meanII.r - mi * mi, 0.0);
        float a = v / (v + eps);
        float b = mi * (1.0 - a);
        return vec4(a, b, 0.0, 1.0);
    }
    """

    /// Guided filter, apply step: q = mean(a)·I + mean(b).
    static let guidedApplySource = """
    kernel vec4 lumenGuidedApply(__sample coefficients, __sample guide) {
        float q = coefficients.r * guide.r + coefficients.g;
        return vec4(q, q, q, 1.0);
    }
    """

    /// Presence: turn a band of the base–detail decomposition into a gain field.
    /// `hi` and `lo` are two log-luminance scales from the guided filter, so the
    /// difference is a band of detail and the gain is halo-free by construction —
    /// the guided filter has no gradient reversal, which is the whole reason it beats
    /// a bilateral base for this job.
    static let detailGainSource = """
    kernel vec4 lumenDetailGain(__sample hi, __sample lo, float k) {
        float g = exp2(k * (hi.r - lo.r));
        return vec4(g, g, g, 1.0);
    }
    """

    /// Dehaze recombination: I' = (I − A)/max(t, t0) + A, on the transmission map the
    /// guided filter refined. `A` arrives already neutralized of its colour cast, which
    /// is what stops recovered skies from going magenta.
    static let dehazeSource = """
    kernel vec4 lumenDehaze(__sample image, __sample transmission, vec3 airlight,
                            float floorT) {
        float t = max(transmission.r, floorT);
        vec3 out = (image.rgb - airlight) / t + airlight;
        return vec4(out, image.a);
    }
    """

    /// Add a blurred glow field back into the image in linear light — halation's
    /// recombination, and the same shape any additive bloom needs.
    static let addGlowSource = """
    kernel vec4 lumenAddGlow(__sample image, __sample glow, vec3 strength) {
        return vec4(image.rgb + glow.rgb * strength, image.a);
    }
    """

    /// Highlight energy above the clip point, which is what actually scatters in the
    /// film base. Everything below `threshold` contributes nothing.
    static let highlightEnergySource = """
    kernel vec4 lumenHighlightEnergy(__sample image, float threshold, float boost) {
        vec3 e = max(image.rgb - vec3(threshold), vec3(0.0)) * boost;
        return vec4(e, 1.0);
    }
    """

    /// Composite an adjusted image over a base through a single-channel mask.
    /// Linear interpolation, unclamped — the local stage blends scene-referred values.
    static let blendMaskSource = """
    kernel vec4 lumenBlendMask(__sample base, __sample over, __sample mask) {
        float m = clamp(mask.r, 0.0, 1.0);
        return vec4(mix(base.rgb, over.rgb, m), base.a);
    }
    """

    /// Density-domain grain (docs/14 §5.7). Amplitude peaks at mid densities and
    /// vanishes at Dmin and Dmax, which is why film grain lives in the midtones and
    /// clean film blacks stay clean — the property a constant-sigma RGB overlay
    /// cannot reproduce.
    static let grainSource = """
    kernel vec4 lumenGrain(__sample image, __sample noise, float amount, float dmax) {
        vec3 c = max(image.rgb, vec3(1e-5));
        vec3 d = -log(c) / log(10.0);
        vec3 p = clamp(d / dmax, 0.0, 1.0);
        vec3 amp = sqrt(max(p * (vec3(1.0) - p), vec3(0.0)));
        vec3 n = (noise.rgb - vec3(0.5)) * 2.0;
        vec3 d2 = d + amp * n * amount;
        vec3 out = pow(vec3(10.0), -d2);
        return vec4(out, image.a);
    }
    """

    /// Vignette as an EV multiply in scene-linear (docs/14 §2.1.11: the lens vignettes
    /// the light before it reaches the film, so this belongs upstream of the curve and
    /// gets highlight-priority behaviour free from the transform's shoulder).
    static let vignetteSource = """
    kernel vec4 lumenVignette(__sample image, vec2 centre, vec2 invRadius, float ev,
                              float feather) {
        vec2 d = (destCoord() - centre) * invRadius;
        float r = length(d);
        float t = smoothstep(1.0 - feather, 1.0, r);
        float gain = exp2(ev * t);
        return vec4(image.rgb * gain, image.a);
    }
    """

    // MARK: - Compiled kernels

    public static let logEncode = make(logEncodeSource)
    public static let logDecode = make(logDecodeSource)
    public static let multiply = make(multiplySource)
    public static let square = make(squareSource)
    public static let luminance = make(luminanceSource)
    public static let guidedCoefficients = make(guidedCoefficientsSource)
    public static let guidedApply = make(guidedApplySource)
    public static let blendMask = make(blendMaskSource)
    public static let grain = make(grainSource)
    public static let vignette = make(vignetteSource)
    public static let detailGain = make(detailGainSource)
    public static let dehaze = make(dehazeSource)
    public static let addGlow = make(addGlowSource)
    public static let highlightEnergy = make(highlightEnergySource)

    /// Every kernel compiled. False means this macOS build rejected the kernel
    /// language and the renderer must use the CPU reference path.
    public static var isAvailable: Bool { unavailableKernels.isEmpty }

    /// Names of the kernels that failed, for the diagnostic the UI shows rather than
    /// pretending everything is fine.
    public static var unavailableKernels: [String] {
        let all: [(String, CIColorKernel?)] = [
            ("logEncode", logEncode), ("logDecode", logDecode),
            ("multiply", multiply), ("square", square), ("luminance", luminance),
            ("guidedCoefficients", guidedCoefficients), ("guidedApply", guidedApply),
            ("blendMask", blendMask), ("grain", grain), ("vignette", vignette),
            ("detailGain", detailGain), ("dehaze", dehaze), ("addGlow", addGlow),
            ("highlightEnergy", highlightEnergy),
        ]
        return all.filter { $0.1 == nil }.map { $0.0 }
    }

    /// The kernels the core colour path cannot run without. Presence, film and mask
    /// stages degrade individually; without these the whole graph is wrong.
    public static var coreAvailable: Bool {
        logEncode != nil && logDecode != nil && multiply != nil && luminance != nil
    }

    private static func make(_ source: String) -> CIColorKernel? {
        CIColorKernel(source: source)
    }

    // MARK: - Convenience application

    public static func apply(_ kernel: CIColorKernel?, extent: CGRect,
                             _ arguments: [Any]) -> CIImage? {
        guard let kernel else { return nil }
        return kernel.apply(extent: extent, arguments: arguments)
    }
}

// MARK: - Cube upload

public enum ColorCube {

    /// Wrap a baked table in the stock colour-cube filter. The data layout LUT3D
    /// produces (red fastest, then green, then blue; RGBA floats) is exactly what
    /// Core Image wants, so this is a memcpy and a filter, not a conversion.
    public static func filter(_ lut: LUT3D, image: CIImage) -> CIImage? {
        let data = lut.data.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(lut.size, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        return filter.outputImage
    }
}

#endif

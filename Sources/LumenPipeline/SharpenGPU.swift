// SharpenGPU.swift
// S12 creative sharpening on the GPU: the twin of `SharpenStage.apply`
// (LumenCore/Image/CreativeSharpening.swift — the algorithm and its reasons are there).
//
//   SharpenStage                        here
//   ──────────────────────────────      ──────────────────────────────────────────────
//   perceptual(Y) = ∛max(Y, 0)          `luminance`, then `power(1/3)`
//   edgeMeasure(Y) = √max(Y, 0)         `power(1/2)`
//   CaptureStage.blur (13 taps)         `CaptureKernels.gauss13`, the same Floats
//   maskPlane(√Y): |∇|, box σ1.5, knees `CaptureKernels.gradientMagnitude`, three `box3`
//                                       passes per axis, `CaptureKernels.gate`
//   peakBounds + sharpened + ratio      `sharpenRatio`, one 17-tap neighbourhood kernel
//   image × ratio                       `KernelLibrary.multiply`
//
// The old path (log-luminance USM, à-trous fine band, `structureTensor` mask) is gone
// from the render; its kernels stay compiled because other goldens still read them.

#if os(macOS)

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import LumenCore

enum SharpenKernels {

    /// `max(y, 0)^e`: the cube root (`SharpenStage.perceptual`) and the square root
    /// (`SharpenStage.edgeMeasure`) from one kernel.
    static let powerSource = """
    kernel vec4 lumenSharpenPower(__sample y, float e) {
        float p = pow(max(y.r, 0.0), e);
        return vec4(p, p, p, 1.0);
    }
    """

    static func bounds(_ dx: String, _ dy: String) -> String {
        let t = { (k: Int, sg: String) in
            "sample(p, samplerTransform(p, d \(sg) \(k).0 * vec2(\(dx), \(dy)))).r"
        }
        return """
                a1 = \(t(1, "-"));
                b1 = \(t(1, "+"));
                a2 = \(t(2, "-"));
                b2 = \(t(2, "+"));
                mn = min(mn, min(a1, b1));
                mx = max(mx, max(a1, b1));
                up = max(up, c - max(a1, b1));
                up = max(up, c - max(a2, b1) - abs(a1 - c));
                up = max(up, c - max(a1, b2) - abs(b1 - c));
                dn = max(dn, min(a1, b1) - c);
                dn = max(dn, min(a2, b1) - c - abs(a1 - c));
                dn = max(dn, min(a1, b2) - c - abs(b1 - c));

        """
    }

    /// `SharpenStage.apply`'s per-pixel arithmetic: the halo bound, Detail and Halo
    /// Damping on the overshoot past it, the mask, and the luminance ratio. Reach 2.
    static let ratioSource = """
    kernel vec4 lumenSharpenRatio(sampler p, sampler blurred, sampler mask,
                                  float amount, float detail, float halo,
                                  float allowance, float limit) {
        vec2 d = destCoord();
        float c = sample(p, samplerTransform(p, d)).r;
        float mn = c;
        float mx = c;
        float up = 0.0;
        float dn = 0.0;
        float a1;
        float b1;
        float a2;
        float b2;
    \(bounds("1.0", "0.0"))\(bounds("0.0", "1.0"))\(bounds("1.0", "1.0"))\(bounds("1.0", "-1.0"))
        float b = sample(blurred, samplerTransform(blurred, d)).r;
        float m = clamp(sample(mask, samplerTransform(mask, d)).r, 0.0, 1.0);
        float freeV = c + amount * (c - b);
        float bounded = clamp(freeV, mn - allowance * dn, mx + allowance * up);
        float over = freeV - bounded;
        over = over > 0.0 ? over * (1.0 - halo) : over;
        float tgt = bounded + detail * over;
        float v = c + m * (tgt - c);
        float q = max(v, 0.0) / max(c, 1e-4);
        float r = c > 1e-4 ? clamp(q * q * q, 1.0 / limit, limit) : 1.0;
        return vec4(r, r, r, 1.0);
    }
    """

    static let power = CIColorKernel(source: powerSource)
    static let ratio = CIKernel(source: ratioSource)

    static var unavailable: [String] {
        let all: [(String, CIKernel?)] = [("sharpenPower", power),
                                          ("sharpenRatio", ratio)]
        return all.filter { $0.1 == nil }.map { $0.0 }
    }

    static var available: Bool {
        unavailable.isEmpty && KernelLibrary.luminance != nil
            && KernelLibrary.multiply != nil && KernelLibrary.box3 != nil
            && CaptureKernels.gauss13 != nil && CaptureKernels.gradientMagnitude != nil
            && CaptureKernels.gate != nil
    }
}

extension RenderGraph {

    /// S12 for an already-resolved stage. If a kernel is missing the stage falls back
    /// to a stock luminance-blind unsharp mask rather than vanishing: a softer, cruder
    /// picture beats a stage that silently does nothing.
    static func applySharpen(_ image: CIImage, stage: SharpenStage) -> CIImage {
        guard !stage.isIdentity else { return image }
        let extent = image.extent
        guard extent.width >= 3, extent.height >= 3 else { return image }
        if SharpenKernels.available, let out = sharpened(image, stage: stage, extent: extent) {
            return out
        }
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image.clampedToExtent()
        filter.radius = Float(stage.sigma)
        filter.intensity = Float(stage.amount)
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    /// The Masking plane on the GPU from a √Y plane, for the parity test.
    static func sharpenMask(edgeMeasure p: CIImage, masking: Double,
                            extent: CGRect) -> CIImage? {
        guard masking > 0 else { return constant(RGB(gray: 1), extent: extent) }
        guard let magnitude = KernelLibrary.applyNeighbourhood(
                CaptureKernels.gradientMagnitude, extent: extent, reach: 1, [clamped(p)])
        else { return nil }
        var averaged = magnitude
        for _ in 0..<3 {
            guard let horizontal = KernelLibrary.applyNeighbourhood(
                    KernelLibrary.box3, extent: extent, reach: 1,
                    [clamped(averaged), CIVector(x: 1, y: 0)]),
                  let vertical = KernelLibrary.applyNeighbourhood(
                    KernelLibrary.box3, extent: extent, reach: 1,
                    [clamped(horizontal), CIVector(x: 0, y: 1)])
            else { return nil }
            averaged = vertical
        }
        let k = SharpenStage.maskKnees(masking: masking)
        return KernelLibrary.apply(CaptureKernels.gate, extent: extent,
                                   [averaged, Float(k.lo), Float(k.hi)])
    }

    private static func sharpened(_ image: CIImage, stage: SharpenStage,
                                  extent: CGRect) -> CIImage? {
        let w = RGBColorSpace.rec2020.luminanceWeights
        guard let lum = KernelLibrary.apply(KernelLibrary.luminance, extent: extent,
                                            [image, CIVector(x: w.r, y: w.g, z: w.b)]),
              let p = KernelLibrary.apply(SharpenKernels.power, extent: extent,
                                          [lum, Float(1.0 / 3.0)]),
              let e = KernelLibrary.apply(SharpenKernels.power, extent: extent,
                                          [lum, Float(0.5)])
        else { return nil }

        let taps = CaptureStage.gaussianTaps(sigma: stage.sigma)
        let w0 = CIVector(x: CGFloat(taps[0]), y: CGFloat(taps[1]),
                          z: CGFloat(taps[2]), w: CGFloat(taps[3]))
        let w1 = CIVector(x: CGFloat(taps[4]), y: CGFloat(taps[5]), z: CGFloat(taps[6]))
        let reach = CGFloat(CaptureStage.tapRadius)
        guard let h = KernelLibrary.applyNeighbourhood(
                CaptureKernels.gauss13, extent: extent, reach: reach,
                [clamped(p), CIVector(x: 1, y: 0), w0, w1]),
              let blurred = KernelLibrary.applyNeighbourhood(
                CaptureKernels.gauss13, extent: extent, reach: reach,
                [clamped(h), CIVector(x: 0, y: 1), w0, w1]),
              let mask = sharpenMask(edgeMeasure: e, masking: stage.masking, extent: extent),
              let ratio = KernelLibrary.applyNeighbourhood(
                SharpenKernels.ratio, extent: extent, reach: 2,
                [clamped(p), clamped(blurred), clamped(mask), Float(stage.amount),
                 Float(stage.detail), Float(stage.haloDamping),
                 Float(stage.peakAllowance), Float(SharpenStage.ratioLimit)])
        else { return nil }
        return KernelLibrary.apply(KernelLibrary.multiply, extent: extent, [image, ratio])
    }
}

#endif

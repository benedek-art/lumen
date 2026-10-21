// CaptureSharpenGPU.swift
// S4 on the GPU: the twin of `CaptureStage.apply` (LumenCore/Image/CaptureSharpening.swift),
// built from the same constants and the same discrete taps. Read that file first; the
// algorithm and the reasons for each step are there, and are not repeated here.
//
// Each step's twin:
//
//   CaptureStage                      here
//   ─────────────────────────────     ───────────────────────────────────────────────
//   luminancePlane, max(·, 0)          `luminance` + `highlightEnergy(0, 1)` (the floor
//                                      `logLuminance` already uses)
//   blur(_:taps:) (13-tap, clamped)    `gauss13` twice, on the clamped plane, with the
//                                      Floats `CaptureStage.gaussianTaps` returns
//   richardsonLucy ratio / update      `ratio`, `update` — the same floor and the same 8×
//   clampedDelta (4 directions, ±2)    `delta`, a 17-tap neighbourhood kernel
//   VST.forward                        `vst`, re-centred on mid-grey the way the denoise's
//                                      `encodedForward` is, which keeps the gradient the
//                                      gate reads precise in half float; a constant
//                                      offset does not change a gradient
//   gate: |∇|, box-averaged, knees     `gradient`, three `box3` passes per axis (the
//                                      operator `testEdgeMapMatchesTheReference` pins
//                                      to `boxApproximatedGaussian(σ 1.5)`), `gate`
//   × gate × strength, then the clamp  inside `delta`
//   ±limit, ratio                      `lumaRatio`
//
// If a kernel is missing the stage returns its input: a soft picture, not a wrong one,
// and the same failure the CPU path cannot have.

#if os(macOS)

import CoreImage
import Foundation
import LumenCore

enum CaptureKernels {

    static let gauss13Source = """
    kernel vec4 lumenCaptureGauss13(sampler src, vec2 dir, vec4 w0, vec3 w1) {
        vec2 p = destCoord();
        vec4 c = sample(src, samplerTransform(src, p));
        float acc = w0.x * c.r;
        acc += w0.y * (sample(src, samplerTransform(src, p - dir)).r
                       + sample(src, samplerTransform(src, p + dir)).r);
        acc += w0.z * (sample(src, samplerTransform(src, p - 2.0 * dir)).r
                       + sample(src, samplerTransform(src, p + 2.0 * dir)).r);
        acc += w0.w * (sample(src, samplerTransform(src, p - 3.0 * dir)).r
                       + sample(src, samplerTransform(src, p + 3.0 * dir)).r);
        acc += w1.x * (sample(src, samplerTransform(src, p - 4.0 * dir)).r
                       + sample(src, samplerTransform(src, p + 4.0 * dir)).r);
        acc += w1.y * (sample(src, samplerTransform(src, p - 5.0 * dir)).r
                       + sample(src, samplerTransform(src, p + 5.0 * dir)).r);
        acc += w1.z * (sample(src, samplerTransform(src, p - 6.0 * dir)).r
                       + sample(src, samplerTransform(src, p + 6.0 * dir)).r);
        return vec4(acc, acc, acc, 1.0);
    }
    """

    static let ratioSource = """
    kernel vec4 lumenCaptureRatio(__sample observed, __sample blurred) {
        float b = blurred.r;
        float r = b > 1e-7 ? observed.r / b : 1.0;
        r = clamp(r, 0.0, 8.0);
        return vec4(r, r, r, 1.0);
    }
    """

    static let updateSource = """
    kernel vec4 lumenCaptureUpdate(__sample estimate, __sample correction) {
        float v = max(estimate.r * correction.r, 0.0);
        return vec4(v, v, v, 1.0);
    }
    """

    /// `CaptureStage.clampedDelta`: the correction scaled by gate × strength, then
    /// held inside the 3×3 range except at a genuine one- or two-pixel peak or trough
    /// that stands 8–16 profile noise σ clear of its neighbours
    /// (`CaptureStage.peakSignificanceLow/High`).
    /// The four directions are written out rather than looped over an array, which the
    /// kernel language does not reliably accept. Reach 2.
    static let deltaSource = """
    kernel vec4 lumenCaptureDelta(sampler observed, sampler deconvolved, sampler gate,
                                  float allowance, float lumFloor, float strength,
                                  float shot, float read, float sigLo, float sigHi) {
        vec2 p = destCoord();
        float yc = max(sample(observed, samplerTransform(observed, p)).r, lumFloor);
        float c = log2(yc);
        float mn = c;
        float mx = c;
        float up = 0.0;
        float dn = 0.0;
        float a1;
        float b1;
        float a2;
        float b2;
        a1 = log2(max(sample(observed, samplerTransform(observed, p - 1.0 * vec2(1.0, 0.0))).r, lumFloor));
        b1 = log2(max(sample(observed, samplerTransform(observed, p + 1.0 * vec2(1.0, 0.0))).r, lumFloor));
        a2 = log2(max(sample(observed, samplerTransform(observed, p - 2.0 * vec2(1.0, 0.0))).r, lumFloor));
        b2 = log2(max(sample(observed, samplerTransform(observed, p + 2.0 * vec2(1.0, 0.0))).r, lumFloor));
        mn = min(mn, min(a1, b1));
        mx = max(mx, max(a1, b1));
        up = max(up, c - max(a1, b1));
        up = max(up, c - max(a2, b1) - abs(a1 - c));
        up = max(up, c - max(a1, b2) - abs(b1 - c));
        dn = max(dn, min(a1, b1) - c);
        dn = max(dn, min(a2, b1) - c - abs(a1 - c));
        dn = max(dn, min(a1, b2) - c - abs(b1 - c));
        a1 = log2(max(sample(observed, samplerTransform(observed, p - 1.0 * vec2(0.0, 1.0))).r, lumFloor));
        b1 = log2(max(sample(observed, samplerTransform(observed, p + 1.0 * vec2(0.0, 1.0))).r, lumFloor));
        a2 = log2(max(sample(observed, samplerTransform(observed, p - 2.0 * vec2(0.0, 1.0))).r, lumFloor));
        b2 = log2(max(sample(observed, samplerTransform(observed, p + 2.0 * vec2(0.0, 1.0))).r, lumFloor));
        mn = min(mn, min(a1, b1));
        mx = max(mx, max(a1, b1));
        up = max(up, c - max(a1, b1));
        up = max(up, c - max(a2, b1) - abs(a1 - c));
        up = max(up, c - max(a1, b2) - abs(b1 - c));
        dn = max(dn, min(a1, b1) - c);
        dn = max(dn, min(a2, b1) - c - abs(a1 - c));
        dn = max(dn, min(a1, b2) - c - abs(b1 - c));
        a1 = log2(max(sample(observed, samplerTransform(observed, p - 1.0 * vec2(1.0, 1.0))).r, lumFloor));
        b1 = log2(max(sample(observed, samplerTransform(observed, p + 1.0 * vec2(1.0, 1.0))).r, lumFloor));
        a2 = log2(max(sample(observed, samplerTransform(observed, p - 2.0 * vec2(1.0, 1.0))).r, lumFloor));
        b2 = log2(max(sample(observed, samplerTransform(observed, p + 2.0 * vec2(1.0, 1.0))).r, lumFloor));
        mn = min(mn, min(a1, b1));
        mx = max(mx, max(a1, b1));
        up = max(up, c - max(a1, b1));
        up = max(up, c - max(a2, b1) - abs(a1 - c));
        up = max(up, c - max(a1, b2) - abs(b1 - c));
        dn = max(dn, min(a1, b1) - c);
        dn = max(dn, min(a2, b1) - c - abs(a1 - c));
        dn = max(dn, min(a1, b2) - c - abs(b1 - c));
        a1 = log2(max(sample(observed, samplerTransform(observed, p - 1.0 * vec2(1.0, -1.0))).r, lumFloor));
        b1 = log2(max(sample(observed, samplerTransform(observed, p + 1.0 * vec2(1.0, -1.0))).r, lumFloor));
        a2 = log2(max(sample(observed, samplerTransform(observed, p - 2.0 * vec2(1.0, -1.0))).r, lumFloor));
        b2 = log2(max(sample(observed, samplerTransform(observed, p + 2.0 * vec2(1.0, -1.0))).r, lumFloor));
        mn = min(mn, min(a1, b1));
        mx = max(mx, max(a1, b1));
        up = max(up, c - max(a1, b1));
        up = max(up, c - max(a2, b1) - abs(a1 - c));
        up = max(up, c - max(a1, b2) - abs(b1 - c));
        dn = max(dn, min(a1, b1) - c);
        dn = max(dn, min(a2, b1) - c - abs(a1 - c));
        dn = max(dn, min(a1, b2) - c - abs(b1 - c));
        float t = log2(max(sample(deconvolved, samplerTransform(deconvolved, p)).r,
                           lumFloor));
        float g = clamp(sample(gate, samplerTransform(gate, p)).r, 0.0, 1.0);
        float wanted = c + (t - c) * g * strength;
        float sigma = sqrt(max(shot * yc + read, 1e-12)) / (yc * 0.6931471805599453);
        float wUp = smoothstep(sigLo * sigma, sigHi * sigma, up);
        float wDn = smoothstep(sigLo * sigma, sigHi * sigma, dn);
        float d = clamp(wanted, mn - allowance * wDn * dn, mx + allowance * wUp * up) - c;
        return vec4(d, d, d, 1.0);
    }
    """

    /// The generalized Anscombe transform, re-centred on `x0`:
    /// `f(y) − f(x0) = 2(y − x0) / (√u + √u0)`, `u = a·y + 3a²/8 + b`.
    static let vstSource = """
    kernel vec4 lumenCaptureVST(__sample y, float a, float offset, float sqrtU0, float x0) {
        float u = max(a * y.r + offset, 0.0);
        float v = 2.0 * (y.r - x0) / (sqrt(u) + sqrtU0);
        return vec4(v, v, v, 1.0);
    }
    """

    /// Central-difference |∇| — `CaptureStage.gate`'s magnitude plane. Reach 1.
    static let gradientMagnitudeSource = """
    kernel vec4 lumenCaptureGradient(sampler src) {
        vec2 p = destCoord();
        float xp = sample(src, samplerTransform(src, p + vec2(1.0, 0.0))).r;
        float xm = sample(src, samplerTransform(src, p - vec2(1.0, 0.0))).r;
        float yp = sample(src, samplerTransform(src, p + vec2(0.0, 1.0))).r;
        float ym = sample(src, samplerTransform(src, p - vec2(0.0, 1.0))).r;
        float gx = (xp - xm) * 0.5;
        float gy = (yp - ym) * 0.5;
        float m = sqrt(gx * gx + gy * gy);
        return vec4(m, m, m, 1.0);
    }
    """

    static let gateSource = """
    kernel vec4 lumenCaptureGate(__sample m, float lo, float hi) {
        float g = smoothstep(lo, hi, m.r);
        return vec4(g, g, g, 1.0);
    }
    """

    static let gauss13 = CIKernel(source: gauss13Source)
    static let gradientMagnitude = CIKernel(source: gradientMagnitudeSource)
    static let gate = CIColorKernel(source: gateSource)
    static let ratio = CIColorKernel(source: ratioSource)
    static let update = CIColorKernel(source: updateSource)
    static let delta = CIKernel(source: deltaSource)
    static let vst = CIColorKernel(source: vstSource)

    /// Names of the S4 kernels that failed to compile. Not on `KernelLibrary`'s core
    /// roster: a missing one leaves capture sharpening off, it does not take the whole
    /// GPU path down. `CaptureSharpenParityTests` asserts this is empty.
    static var unavailable: [String] {
        let all: [(String, CIKernel?)] = [
            ("captureGauss13", gauss13), ("captureRatio", ratio),
            ("captureUpdate", update), ("captureDelta", delta),
            ("captureVST", vst), ("captureGradient", gradientMagnitude),
            ("captureGate", gate),
        ]
        return all.filter { $0.1 == nil }.map { $0.0 }
    }

    static var available: Bool {
        unavailable.isEmpty && KernelLibrary.luminance != nil
            && KernelLibrary.highlightEnergy != nil && KernelLibrary.box3 != nil
            && KernelLibrary.lumaRatio != nil
    }
}

extension RenderGraph {

    /// S4 — `plan.capture` at this decode's scale. `noiseScale` is s² for a decode at
    /// linear scale s (the convention S3 reads), so the stage is told the same scale
    /// S3 is.
    func applyCaptureSharpen(_ image: CIImage, plan: RenderPlan, options: Options) -> CIImage {
        let ns = options.noiseScale
        let scale = (ns.isFinite && ns > 0) ? Swift.min(ns, 1).squareRoot() : 1
        return Self.applyCaptureSharpen(image, stage: plan.capture.scaled(decodeScale: scale))
    }

    /// The stage on one image, already scaled. Static so the parity test can call it
    /// with a hand-built `CaptureStage`.
    static func applyCaptureSharpen(_ image: CIImage, stage: CaptureStage) -> CIImage {
        guard !stage.isIdentity, CaptureKernels.available else { return image }
        let extent = image.extent
        guard extent.width >= 3, extent.height >= 3 else { return image }
        return captureSharpened(image, stage: stage, extent: extent) ?? image
    }

    private static func captureSharpened(_ image: CIImage, stage: CaptureStage,
                                         extent: CGRect) -> CIImage? {
        let w = RGBColorSpace.rec2020.luminanceWeights
        guard let rawLum = KernelLibrary.apply(KernelLibrary.luminance, extent: extent,
                                               [image, CIVector(x: w.r, y: w.g, z: w.b)]),
              let lum = KernelLibrary.apply(KernelLibrary.highlightEnergy, extent: extent,
                                            [rawLum, Float(0.0), Float(1.0)])
        else { return nil }

        let taps = CaptureStage.gaussianTaps(sigma: stage.sigma)
        let w0 = CIVector(x: CGFloat(taps[0]), y: CGFloat(taps[1]),
                          z: CGFloat(taps[2]), w: CGFloat(taps[3]))
        let w1 = CIVector(x: CGFloat(taps[4]), y: CGFloat(taps[5]), z: CGFloat(taps[6]))
        let reach = CGFloat(CaptureStage.tapRadius)
        func gauss(_ plane: CIImage) -> CIImage? {
            guard let h = KernelLibrary.applyNeighbourhood(
                    CaptureKernels.gauss13, extent: extent, reach: reach,
                    [RenderGraph.clamped(plane), CIVector(x: 1, y: 0), w0, w1])
            else { return nil }
            return KernelLibrary.applyNeighbourhood(
                CaptureKernels.gauss13, extent: extent, reach: reach,
                [RenderGraph.clamped(h), CIVector(x: 0, y: 1), w0, w1])
        }

        // Richardson–Lucy.
        var estimate = lum
        for _ in 0..<CaptureStage.iterations {
            guard let blurred = gauss(estimate),
                  let ratio = KernelLibrary.apply(CaptureKernels.ratio, extent: extent,
                                                  [lum, blurred]),
                  let correction = gauss(ratio),
                  let next = KernelLibrary.apply(CaptureKernels.update, extent: extent,
                                                 [estimate, correction])
            else { return nil }
            estimate = next
        }

        // The gate: VST, central-difference |∇|, averaged by three box passes per
        // axis, smoothstep in noise σ.
        let a = stage.profile.a
        let offset = 0.375 * a * a + stage.profile.b
        let x0 = 0.18
        let sqrtU0 = Swift.max(a * x0 + offset, 0).squareRoot()
        guard let stabilized = KernelLibrary.apply(
                CaptureKernels.vst, extent: extent,
                [lum, Float(a), Float(offset), Float(sqrtU0), Float(x0)]),
              let magnitude = KernelLibrary.applyNeighbourhood(
                CaptureKernels.gradientMagnitude, extent: extent, reach: 1,
                [RenderGraph.clamped(stabilized)])
        else { return nil }
        var averaged = magnitude
        for _ in 0..<3 {
            guard let horizontal = KernelLibrary.applyNeighbourhood(
                    KernelLibrary.box3, extent: extent, reach: 1,
                    [RenderGraph.clamped(averaged), CIVector(x: 1, y: 0)]),
                  let vertical = KernelLibrary.applyNeighbourhood(
                    KernelLibrary.box3, extent: extent, reach: 1,
                    [RenderGraph.clamped(horizontal), CIVector(x: 0, y: 1)])
            else { return nil }
            averaged = vertical
        }
        guard let gate = KernelLibrary.apply(
                CaptureKernels.gate, extent: extent,
                [averaged, Float(CaptureStage.gateLow), Float(CaptureStage.gateHigh)])
        else { return nil }
        guard let delta = KernelLibrary.applyNeighbourhood(
                CaptureKernels.delta, extent: extent, reach: 2,
                [RenderGraph.clamped(lum), RenderGraph.clamped(estimate),
                 RenderGraph.clamped(gate), Float(CaptureStage.peakAllowance),
                 Float(CaptureStage.logFloor), Float(stage.strength),
                 Float(stage.profile.a), Float(stage.profile.b),
                 Float(CaptureStage.peakSignificanceLow),
                 Float(CaptureStage.peakSignificanceHigh)])
        else { return nil }
        return KernelLibrary.apply(KernelLibrary.lumaRatio, extent: extent,
                                   [image, delta, Float(CaptureStage.limitEV)])
    }
}

#endif

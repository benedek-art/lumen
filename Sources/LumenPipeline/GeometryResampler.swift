// GeometryResampler.swift
// S16 on the GPU: the twin of `GeometryResample` (LumenCore/Image/GeometryStage.swift).
//
// Two general kernels and nothing else:
//
//   · `halve` — one separable Lanczos-3 pass along one axis at σ = L/⌈L/2⌉, run twice
//     (horizontal, then vertical) per halving, exactly as `GeometryResample.halve` does;
//   · `resample` — the geometric pass: the 3×3 map evaluated at `destCoord()`, separable
//     Lanczos-3 weights in source axes widened by σ ≤ 2, normalized, taps read from a
//     clamp-to-edge image, half-pixel fade outside the source.
//
// Both are generated with a fixed tap count, because a kernel language loop wants a
// constant bound: 6 taps (σ = 1, the common case of a rotation or crop at or above
// output size) or 12 (σ up to 2). Taps past the filter's reach carry zero weight by
// construction — the window starts at floor(p − ½) − reach + 1, so a tap beyond 2·reach
// sits ≥ 3σ from p — which is why the 12-tap kernel agrees with the CPU's 2·reach-tap
// loop and not merely approximately.
//
// WHY NOT `CIImage.transformed(by:)`. That is what `applyGeometry` used, and it samples
// through Core Image's default bilinear sampler: a triangle filter, MTF 0.81 at 0.25
// cycles/px against this kernel's 1.01 (GeometryStageTests, spec line 4). And with an
// output scale it resampled twice. Both are gone from the delivered path.

#if os(macOS)

import CoreImage
import Foundation
import LumenCore

enum GeometryKernels {

    /// The Lanczos-3 weight, as CIKL. `GeometryResample.Filter.lanczos3.weight` twin.
    private static let lanczos = """
    float lumenLanczos3(float t) {
        float x = abs(t);
        if (x < 1.0e-6) { return 1.0; }
        if (x >= 3.0) { return 0.0; }
        float px = 3.14159265358979 * x;
        return 3.0 * sin(px) * sin(px / 3.0) / (px * px);
    }
    """

    /// `r0..r2` are the rows of the output → source map in Core Image coordinates;
    /// `params` is (σ, reach, source width, source height); `footprint` is source pixels
    /// per output pixel at this pass, the unit `GeometryResample.cover` fades in.
    static func resampleSource(taps: Int) -> String {
        """
        \(lanczos)
        kernel vec4 lumenGeometryResample\(taps)(sampler src, vec3 r0, vec3 r1, vec3 r2,
                                                  vec4 params, float footprint) {
            vec3 h = vec3(destCoord(), 1.0);
            float w = dot(r2, h);
            if (w <= 0.0) { return vec4(0.0); }
            vec2 p = vec2(dot(r0, h), dot(r1, h)) / w;
            float covX = clamp((min(p.x, params.z - p.x) / footprint + 1.5) * 2.0, 0.0, 1.0);
            float covY = clamp((min(p.y, params.w - p.y) / footprint + 1.5) * 2.0, 0.0, 1.0);
            float coverage = covX * covY;
            if (coverage <= 0.0) { return vec4(0.0); }
            float sigma = params.x;
            vec2 base = floor(p - 0.5) - params.y + 1.0;
            float sumX = 0.0;
            float sumY = 0.0;
            for (int k = 0; k < \(taps); k++) {
                sumX += lumenLanczos3((base.x + float(k) + 0.5 - p.x) / sigma);
                sumY += lumenLanczos3((base.y + float(k) + 0.5 - p.y) / sigma);
            }
            vec4 acc = vec4(0.0);
            for (int j = 0; j < \(taps); j++) {
                float cy = base.y + float(j) + 0.5;
                float wy = lumenLanczos3((cy - p.y) / sigma);
                if (wy != 0.0) {
                    vec4 row = vec4(0.0);
                    for (int k = 0; k < \(taps); k++) {
                        float cx = base.x + float(k) + 0.5;
                        float wx = lumenLanczos3((cx - p.x) / sigma);
                        if (wx != 0.0) {
                            row += wx * sample(src, samplerTransform(src, vec2(cx, cy)));
                        }
                    }
                    acc += wy * row;
                }
            }
            float norm = sumX * sumY;
            if (norm != 0.0) { acc = acc / norm; }
            return acc * coverage;
        }
        """
    }

    /// One halving pass. `axis` is (1, 0) or (0, 1); `params` is (ratio = L/L′, reach).
    static let halveSource = """
    \(lanczos)
    kernel vec4 lumenGeometryHalve(sampler src, vec2 axis, vec2 params) {
        vec2 d = destCoord();
        float along = dot(d, axis);
        vec2 across = d - along * axis;
        float p = along * params.x;
        float sigma = max(1.0, params.x);
        float base = floor(p - 0.5) - params.y + 1.0;
        float sum = 0.0;
        vec4 acc = vec4(0.0);
        for (int k = 0; k < 12; k++) {
            float c = base + float(k) + 0.5;
            float wgt = lumenLanczos3((c - p) / sigma);
            if (wgt != 0.0) {
                acc += wgt * sample(src, samplerTransform(src, across + c * axis));
                sum += wgt;
            }
        }
        if (sum != 0.0) { acc = acc / sum; }
        return acc;
    }
    """

    static let resample6 = CIKernel(source: resampleSource(taps: 6))
    static let resample12 = CIKernel(source: resampleSource(taps: 12))
    static let halve = CIKernel(source: halveSource)

    /// Names of the S16 kernels that failed to compile. Empty on every supported macOS;
    /// `applyGeometry` falls back to Core Image's own transform, and says so in the log,
    /// when it is not (see NEEDS.md: the roster belongs to WS-58).
    static var unavailable: [String] {
        let all: [(String, CIKernel?)] = [("geometryResample6", resample6),
                                          ("geometryResample12", resample12),
                                          ("geometryHalve", halve)]
        return all.filter { $0.1 == nil }.map(\.0)
    }

    // MARK: - Application

    /// S16 over a zero-origin image of `map`'s source size. Nil when a kernel is missing.
    static func apply(_ image: CIImage, map: GeometryMap) -> CIImage? {
        guard let resample6, let resample12, let halve else { return nil }
        var source = image
        var w = map.sourceWidth, h = map.sourceHeight
        // Top-left map, rescaled exactly as `GeometryResample.apply` rescales it.
        var toSource = map.outputToSource
        let (halvings, _) = GeometryResample.plan(minification: minification(toSource, map))
        for _ in 0..<halvings {
            let w2 = Swift.max(1, (w + 1) / 2), h2 = Swift.max(1, (h + 1) / 2)
            guard let x = halvePass(source, kernel: halve, horizontal: true,
                                    inLength: w, outLength: w2, across: h),
                  let y = halvePass(x, kernel: halve, horizontal: false,
                                    inLength: h, outLength: h2, across: w2) else { return nil }
            toSource = Homography.scale(Double(w2) / Double(w), Double(h2) / Double(h)) * toSource
            source = y
            w = w2; h = h2
        }
        let footprint = minification(toSource, map)
        let sigma = GeometryResample.plan(minification: footprint).sigma
        let reach = GeometryResample.reach(.lanczos3, sigma: sigma)
        // Into Core Image's y-up frame on both sides: M_ci = F_src · M · F_out.
        let fOut = Homography(1, 0, 0, 0, -1, Double(map.outputHeight), 0, 0, 1)
        let fSrc = Homography(1, 0, 0, 0, -1, Double(h), 0, 0, 1)
        let m = (fSrc * toSource.normalized * fOut).normalized
        let extent = CGRect(x: 0, y: 0, width: map.outputWidth, height: map.outputHeight)
        let sourceExtent = CGRect(x: 0, y: 0, width: w, height: h)
        let clamped = source.cropped(to: sourceExtent).clampedToExtent()
        let kernel = 2 * reach <= 6 ? resample6 : resample12
        let margin = CGFloat(reach + 2)
        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in
                GeometryKernels.roi(of: rect, through: m, margin: margin,
                                    fallback: sourceExtent)
            },
            arguments: [
                clamped,
                CIVector(x: m.m0, y: m.m1, z: m.m2),
                CIVector(x: m.m3, y: m.m4, z: m.m5),
                CIVector(x: m.m6, y: m.m7, z: m.m8),
                CIVector(x: sigma, y: CGFloat(reach), z: CGFloat(w), w: CGFloat(h)),
                footprint,
            ])
    }

    private static func minification(_ m: Homography, _ map: GeometryMap) -> Double {
        let j = m.jacobian(Double(map.outputWidth) / 2, Double(map.outputHeight) / 2)
        let det = abs(j.0 * j.3 - j.1 * j.2)
        return det.isFinite && det > 0 ? det.squareRoot() : 1
    }

    private static func halvePass(_ image: CIImage, kernel: CIKernel, horizontal: Bool,
                                  inLength: Int, outLength: Int, across: Int) -> CIImage? {
        let ratio = Double(inLength) / Double(outLength)
        let reach = GeometryResample.reach(.lanczos3, sigma: Swift.max(1, ratio))
        let inExtent = horizontal
            ? CGRect(x: 0, y: 0, width: inLength, height: across)
            : CGRect(x: 0, y: 0, width: across, height: inLength)
        let outExtent = horizontal
            ? CGRect(x: 0, y: 0, width: outLength, height: across)
            : CGRect(x: 0, y: 0, width: across, height: outLength)
        let clamped = image.cropped(to: inExtent).clampedToExtent()
        let pad = CGFloat(reach + 2)
        return kernel.apply(
            extent: outExtent,
            roiCallback: { _, rect in
                horizontal
                    ? CGRect(x: rect.minX * ratio - pad, y: rect.minY,
                             width: rect.width * ratio + 2 * pad, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY * ratio - pad,
                             width: rect.width, height: rect.height * ratio + 2 * pad)
            },
            arguments: [
                clamped,
                CIVector(x: horizontal ? 1 : 0, y: horizontal ? 0 : 1),
                CIVector(x: ratio, y: CGFloat(reach)),
            ])?.cropped(to: outExtent)
    }

    /// The source rectangle an output rectangle reads: its corners through the map,
    /// widened by the filter's reach. A rectangle whose corners cross the horizon
    /// (w ≤ 0, only reachable with an extreme manual Upright) reads the whole source.
    private static func roi(of rect: CGRect, through m: Homography, margin: CGFloat,
                            fallback: CGRect) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for (x, y) in [(rect.minX, rect.minY), (rect.maxX, rect.minY),
                       (rect.minX, rect.maxY), (rect.maxX, rect.maxY)] {
            let p = m.apply(Double(x), Double(y))
            guard p.w > 0, p.x.isFinite, p.y.isFinite else { return fallback.insetBy(dx: -margin, dy: -margin) }
            minX = Swift.min(minX, CGFloat(p.x)); maxX = Swift.max(maxX, CGFloat(p.x))
            minY = Swift.min(minY, CGFloat(p.y)); maxY = Swift.max(maxY, CGFloat(p.y))
        }
        // A projective map can bulge between corners only if the horizon crosses the
        // rectangle, which the guard above excludes; the bounding box is exact.
        return CGRect(x: minX - margin, y: minY - margin,
                      width: maxX - minX + 2 * margin, height: maxY - minY + 2 * margin)
    }
}

#endif

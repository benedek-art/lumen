// GeometryStage.swift
// S16, the geometry stage, as a definition: crop, straighten, flip, Upright and the
// output scale, composed into ONE projective map and ONE resample (docs/14 §5.8).
//
// WHY THIS FILE EXISTS. Until it did, the CPU reference never cropped or rotated
// anything. Geometry lived only in `PipelineRenderer.applyGeometry`, which is `#if
// os(macOS)` and rotated through `CIImage.transformed(by:)` — Core Image's default
// BILINEAR sampler, a triangle filter that drops a 0.25 cycle/px grating to about 0.6 of
// its amplitude at any non-trivial angle — and, when an output size was also asked for,
// resampled a second time with Lanczos. So the GPU rotation was soft, the "one
// resample" its comment promised was two, and no machine without a GPU could look at a
// straightened photograph at all.
//
// THE MAP. Every part of the geometry is a 3×3 homography on pixel coordinates, so the
// whole stage is one: `GeometryMap.outputToSource` takes a continuous OUTPUT pixel
// coordinate (top-left origin, pixel i spans [i, i+1]) to the continuous SOURCE coordinate
// it samples. Built in this order, outermost first:
//
//     output px ─A→ crop-relative, straightened frame (y up, centred on the usable frame)
//               ─B→ un-flip, un-rotate          (the inverse of the GPU's orientation)
//               ─C→ un-Upright                  (`UprightSolver`, normalized by long edge)
//               ─D→ source px
//
// A, B and D are the arithmetic `PipelineRenderer.geometryRects` has always encoded —
// flip first, then rotate by −angle in Core Image's y-up frame, crop as a fraction of the
// inscribed rectangle `CropGeometry.usableSize` names — re-derived here in closed form
// and checked against `geometryRects` itself on macOS (GeometryGPUParityTests).
//
// THE RESAMPLER. Lanczos-3, separable in source axes, normalized, clamp-to-edge taps.
// The kernel is widened by the local minification σ = √|det J| of the map (source pixels
// per output pixel) so a downscale is filtered rather than point-sampled. σ is capped at
// 2 by first HALVING the source as many times as it takes (each halving the same
// separable Lanczos-3 at exactly σ = W/⌈W/2⌉ ≤ 2), because a GPU kernel needs a fixed
// tap bound and 12 × 12 is the most this stage is allowed to read per pixel. The GPU twin
// (`KernelLibrary.geometryResample`/`geometryHalve`) runs the same chain with the same
// weights, so the two agree to float round-off instead of to "both are Lanczos".
//
// Outside the source (only reachable with Upright's Scale below 100 or an Offset), the
// output fades to transparent black over half an output pixel. Inside it, everything is
// opaque — including the outermost pixels of a straightened crop, whose taps reach past
// the edge and read the clamped edge pixel, the same convention `PipelineRenderer.scaled`
// adopted for the Lanczos resize (docs/31 round one §12). See `cover` for the one-pixel
// allowance the outward-rounded grid needs.

import Foundation

// MARK: - Homography

/// A row-major 3×3 projective map on 2-D points, applied as `(x, y, 1) ↦ M · (x, y, 1)`
/// and dehomogenized. Inline doubles rather than `Mat3`'s nested arrays, because this one
/// is evaluated per output pixel.
public struct Homography: Equatable, Sendable {
    public var m0, m1, m2, m3, m4, m5, m6, m7, m8: Double

    public init(_ m0: Double, _ m1: Double, _ m2: Double,
                _ m3: Double, _ m4: Double, _ m5: Double,
                _ m6: Double, _ m7: Double, _ m8: Double) {
        (self.m0, self.m1, self.m2) = (m0, m1, m2)
        (self.m3, self.m4, self.m5) = (m3, m4, m5)
        (self.m6, self.m7, self.m8) = (m6, m7, m8)
    }

    public static let identity = Homography(1, 0, 0, 0, 1, 0, 0, 0, 1)

    public static func translation(_ x: Double, _ y: Double) -> Homography {
        Homography(1, 0, x, 0, 1, y, 0, 0, 1)
    }

    public static func scale(_ x: Double, _ y: Double) -> Homography {
        Homography(x, 0, 0, 0, y, 0, 0, 0, 1)
    }

    /// Counter-clockwise by `radians` in a y-UP frame.
    public static func rotation(_ radians: Double) -> Homography {
        let c = cos(radians), s = sin(radians)
        return Homography(c, -s, 0, s, c, 0, 0, 0, 1)
    }

    public var rows: [Double] { [m0, m1, m2, m3, m4, m5, m6, m7, m8] }

    public static func * (a: Homography, b: Homography) -> Homography {
        Homography(
            a.m0 * b.m0 + a.m1 * b.m3 + a.m2 * b.m6,
            a.m0 * b.m1 + a.m1 * b.m4 + a.m2 * b.m7,
            a.m0 * b.m2 + a.m1 * b.m5 + a.m2 * b.m8,
            a.m3 * b.m0 + a.m4 * b.m3 + a.m5 * b.m6,
            a.m3 * b.m1 + a.m4 * b.m4 + a.m5 * b.m7,
            a.m3 * b.m2 + a.m4 * b.m5 + a.m5 * b.m8,
            a.m6 * b.m0 + a.m7 * b.m3 + a.m8 * b.m6,
            a.m6 * b.m1 + a.m7 * b.m4 + a.m8 * b.m7,
            a.m6 * b.m2 + a.m7 * b.m5 + a.m8 * b.m8)
    }

    public var determinant: Double {
        m0 * (m4 * m8 - m5 * m7) - m1 * (m3 * m8 - m5 * m6) + m2 * (m3 * m7 - m4 * m6)
    }

    /// The inverse, normalized so `m8` is 1 where it can be. Nil for a singular map.
    public var inverse: Homography? {
        let det = determinant
        guard abs(det) > 1e-300, det.isFinite else { return nil }
        let r = Homography(
            (m4 * m8 - m5 * m7) / det, (m2 * m7 - m1 * m8) / det, (m1 * m5 - m2 * m4) / det,
            (m5 * m6 - m3 * m8) / det, (m0 * m8 - m2 * m6) / det, (m2 * m3 - m0 * m5) / det,
            (m3 * m7 - m4 * m6) / det, (m1 * m6 - m0 * m7) / det, (m0 * m4 - m1 * m3) / det)
        return r.normalized
    }

    /// Scaled so the bottom-right entry is 1 (a homography is defined up to scale).
    public var normalized: Homography {
        guard abs(m8) > 1e-300 else { return self }
        let k = 1 / m8
        return Homography(m0 * k, m1 * k, m2 * k, m3 * k, m4 * k, m5 * k, m6 * k, m7 * k, 1)
    }

    /// The image of a point. `w` is returned so a caller can see a point that went
    /// behind the projection centre (w ≤ 0) rather than receive its mirror.
    @inlinable public func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double, w: Double) {
        let w = m6 * x + m7 * y + m8
        return ((m0 * x + m1 * y + m2) / w, (m3 * x + m4 * y + m5) / w, w)
    }

    /// The 2×2 Jacobian of the dehomogenized map at a point, as (∂x/∂x, ∂x/∂y, ∂y/∂x,
    /// ∂y/∂y).
    public func jacobian(_ x: Double, _ y: Double) -> (Double, Double, Double, Double) {
        let w = m6 * x + m7 * y + m8
        let u = m0 * x + m1 * y + m2
        let v = m3 * x + m4 * y + m5
        let w2 = w * w
        return ((m0 * w - u * m6) / w2, (m1 * w - u * m7) / w2,
                (m3 * w - v * m6) / w2, (m4 * w - v * m7) / w2)
    }

    /// Largest absolute entry difference after both are normalized.
    public func maxDifference(_ other: Homography) -> Double {
        let a = normalized.rows, b = other.normalized.rows
        return zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }
}

// MARK: - The map

/// Where every output pixel of S16 comes from. One definition, used by the CPU stage
/// below, by `PipelineRenderer.applyGeometry` on the GPU, and by the mask tools' point
/// mappings, so the three cannot disagree about a convention.
public struct GeometryMap: Sendable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    /// The delivered frame, in whole pixels: the crop's bounds in the scaled,
    /// straightened frame, rounded OUTWARD to that frame's pixel grid — the extent Core
    /// Image's integral render of `applyGeometry`'s crop has always had, and the
    /// rectangle `RenderGraph.applyVignette` centres its ellipse on (`target.integral`).
    /// So it is `CropGeometry.Resolved.outputWidth` or one more.
    public let outputWidth: Int
    public let outputHeight: Int
    /// Output pixels per straightened-frame pixel (the export/preview scale).
    public let scale: Double
    /// The crop in OUTPUT pixels before rounding — the continuous rectangle the
    /// normalized display coordinates are fractions of — and where it starts inside the
    /// whole-pixel grid (0…1 px).
    public let targetWidth: Double
    public let targetHeight: Double
    public let targetOriginX: Double
    public let targetOriginY: Double
    /// Output pixel coordinate → source pixel coordinate (both top-left origin).
    public let outputToSource: Homography
    /// Source pixel coordinate → output pixel coordinate.
    public let sourceToOutput: Homography
    /// The Upright homography alone, in normalized centred y-up coordinates (identity
    /// when there is none).
    public let upright: Homography
    /// True when the stage changes nothing: same size, identity map.
    public let isIdentity: Bool

    public init(geometry: Geometry, sourceWidth: Int, sourceHeight: Int,
                targetLongEdge: Int? = nil, allowUpscale: Bool = false,
                skipCrop: Bool = false) {
        let w = Double(Swift.max(sourceWidth, 1)), h = Double(Swift.max(sourceHeight, 1))
        self.sourceWidth = Swift.max(sourceWidth, 1)
        self.sourceHeight = Swift.max(sourceHeight, 1)
        var effective = geometry
        if skipCrop { effective.crop = Crop() }
        let resolved = CropGeometry.resolve(sourceWidth: w, sourceHeight: h,
                                            geometry: effective,
                                            targetLongEdge: targetLongEdge,
                                            allowUpscale: allowUpscale)
        let s = resolved.scale > 0 && resolved.scale.isFinite ? resolved.scale : 1
        scale = s

        // The GPU's orientation, `flip ∘ R(−angle)` in Core Image's y-up frame about the
        // ORIGIN, and where it puts the source centre — the centre of the usable frame.
        let theta = -effective.angle * .pi / 180
        let rc = (cos(theta) * w / 2 - sin(theta) * h / 2, sin(theta) * w / 2 + cos(theta) * h / 2)
        let oc = (effective.flipH ? -rc.0 : rc.0, rc.1)
        // The crop in that frame, scaled, and its outward-rounded pixel grid. The nudge
        // keeps an edge that is an integer in exact arithmetic from rounding a whole
        // pixel outward on float noise.
        let tMinX = (oc.0 - resolved.usableWidth / 2 + resolved.x) * s
        let tMaxY = (oc.1 + resolved.usableHeight / 2 - resolved.y) * s
        let tMaxX = tMinX + resolved.width * s
        let tMinY = tMaxY - resolved.height * s
        let nudge = 1e-7
        let gx0 = (tMinX + nudge).rounded(.down), gx1 = (tMaxX - nudge).rounded(.up)
        let gy0 = (tMinY + nudge).rounded(.down), gy1 = (tMaxY - nudge).rounded(.up)
        outputWidth = Swift.max(Int(gx1 - gx0), 1)
        outputHeight = Swift.max(Int(gy1 - gy0), 1)
        targetWidth = resolved.width * s
        targetHeight = resolved.height * s
        targetOriginX = tMinX - gx0
        targetOriginY = gy1 - tMaxY

        // A: output px → the straightened frame, relative to the usable centre, y up.
        let a = Homography(1 / s, 0, gx0 / s - oc.0,
                           0, -1 / s, gy1 / s - oc.1,
                           0, 0, 1)
        // B: the inverse of the GPU's orientation `flip ∘ R(−angle)`: R(angle) ∘ flip.
        let flip = effective.flipH ? Homography.scale(-1, 1) : .identity
        let b = Homography.rotation(effective.angle * .pi / 180) * flip
        // C: the inverse Upright, conjugated from normalized to centred pixel units.
        let long = Swift.max(w, h)
        let up = UprightSolver.homography(effective.upright, sourceWidth: w,
                                          sourceHeight: h)
        upright = up
        var c = Homography.identity
        if up != .identity, let inv = up.inverse {
            c = Homography.scale(long, long) * inv * Homography.scale(1 / long, 1 / long)
        }
        // D: centred y-up → source px, top-left origin.
        let d = Homography(1, 0, w / 2, 0, -1, h / 2, 0, 0, 1)
        let m = (d * c * b * a).normalized
        outputToSource = m
        sourceToOutput = m.inverse ?? .identity
        let exact = m.maxDifference(.identity) < 1e-12
        isIdentity = exact && outputWidth == self.sourceWidth
            && outputHeight == self.sourceHeight
    }

    /// Source pixels per output pixel at the centre of the frame — the minification the
    /// resampler widens its kernel by.
    public var minification: Double {
        let j = outputToSource.jacobian(Double(outputWidth) / 2, Double(outputHeight) / 2)
        let det = abs(j.0 * j.3 - j.1 * j.2)
        return det.isFinite && det > 0 ? det.squareRoot() : 1
    }

    /// A point in the DISPLAYED frame (normalized 0…1 over the crop, top-left origin) as
    /// the source-normalized coordinate a recipe stores. The CPU definition of
    /// `PipelineRenderer.sourceNormalized`, which now calls it.
    public func sourceNormalized(displayedX u: Double, displayedY v: Double) -> (x: Double, y: Double) {
        let p = outputToSource.apply(targetOriginX + u * targetWidth,
                                     targetOriginY + v * targetHeight)
        return (p.x / Double(sourceWidth), p.y / Double(sourceHeight))
    }

    /// The exact inverse of `sourceNormalized`.
    public func displayedNormalized(sourceX x: Double, sourceY y: Double) -> (x: Double, y: Double) {
        guard targetWidth > 0, targetHeight > 0 else { return (0, 0) }
        let p = sourceToOutput.apply(x * Double(sourceWidth), y * Double(sourceHeight))
        return ((p.x - targetOriginX) / targetWidth, (p.y - targetOriginY) / targetHeight)
    }
}

// MARK: - The resampler

public enum GeometryResample {

    /// Lanczos-3 is the stage. The other two exist so the measurement can say what
    /// they would have cost: bilinear is what `CIImage.transformed(by:)` did, bicubic
    /// (Keys, a = −0.5) is the reference the lane's MTF claim is stated against.
    public enum Filter: Sendable {
        case lanczos3, bicubic, bilinear

        public var support: Double {
            switch self {
            case .lanczos3: return 3
            case .bicubic: return 2
            case .bilinear: return 1
            }
        }

        @inlinable public func weight(_ t: Double) -> Double {
            let x = abs(t)
            switch self {
            case .lanczos3:
                if x < 1e-9 { return 1 }
                if x >= 3 { return 0 }
                let px = Double.pi * x
                return 3 * sin(px) * sin(px / 3) / (px * px)
            case .bicubic:
                let a = -0.5
                if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
                if x < 2 { return ((a * x - 5 * a) * x + 8 * a) * x - 4 * a }
                return 0
            case .bilinear:
                return x < 1 ? 1 - x : 0
            }
        }
    }

    /// The most a kernel is widened by before the source is halved instead. The GPU
    /// kernel's fixed tap bound (2 · ⌈3 · 2⌉ = 12 per axis) is this number.
    public static let maximumSigma: Double = 2

    /// Tap reach either side, in source pixels, for a kernel widened by `sigma`.
    @inlinable public static func reach(_ filter: Filter, sigma: Double) -> Int {
        Int((filter.support * sigma - 1e-9).rounded(.up))
    }

    /// How many halvings come before the geometric pass, and the σ that pass then uses.
    public static func plan(minification f: Double) -> (halvings: Int, sigma: Double) {
        var n = 0
        var r = f.isFinite && f > 0 ? f : 1
        while r > maximumSigma, n < 16 { r /= 2; n += 1 }
        return (n, Swift.max(1, r))
    }

    /// S16 on the CPU: the reference the GPU kernel is measured against.
    public static func apply(_ image: ImageBuffer, map: GeometryMap,
                             filter: Filter = .lanczos3) -> ImageBuffer {
        if map.isIdentity, image.width == map.sourceWidth, image.height == map.sourceHeight {
            return image
        }
        var source = image
        // The map is in the coordinates of the frame it was built for; a caller handing
        // a different-size buffer (a scaled decode) gets the same picture.
        var toSource = Homography.scale(Double(image.width) / Double(map.sourceWidth),
                                        Double(image.height) / Double(map.sourceHeight))
            * map.outputToSource
        let f = minification(toSource, map: map)
        let (halvings, _) = plan(minification: f)
        for _ in 0..<halvings {
            let before = (w: source.width, h: source.height)
            source = halve(source, filter: filter)
            toSource = Homography.scale(Double(source.width) / Double(before.w),
                                        Double(source.height) / Double(before.h)) * toSource
        }
        let footprint = minification(toSource, map: map)
        let sigma = plan(minification: footprint).sigma
        return resample(source, outputToSource: toSource.normalized,
                        width: map.outputWidth, height: map.outputHeight,
                        sigma: sigma, footprint: footprint, filter: filter)
    }

    static func minification(_ m: Homography, map: GeometryMap) -> Double {
        let j = m.jacobian(Double(map.outputWidth) / 2, Double(map.outputHeight) / 2)
        let det = abs(j.0 * j.3 - j.1 * j.2)
        return det.isFinite && det > 0 ? det.squareRoot() : 1
    }

    /// Halve both axes (⌈W/2⌉ × ⌈H/2⌉) with the separable filter at σ = W/⌈W/2⌉,
    /// horizontal pass first — the order the GPU kernel chain uses.
    public static func halve(_ image: ImageBuffer, filter: Filter = .lanczos3) -> ImageBuffer {
        let w2 = Swift.max(1, (image.width + 1) / 2)
        let h2 = Swift.max(1, (image.height + 1) / 2)
        let horizontal = resample1D(image, outLength: w2, horizontal: true, filter: filter)
        return resample1D(horizontal, outLength: h2, horizontal: false, filter: filter)
    }

    /// One separable pass: output sample i (centre i + ½) reads source position
    /// (i + ½) · L/L′, widened by σ = L/L′.
    static func resample1D(_ image: ImageBuffer, outLength: Int, horizontal: Bool,
                           filter: Filter) -> ImageBuffer {
        let inLength = horizontal ? image.width : image.height
        let ratio = Double(inLength) / Double(outLength)
        let sigma = Swift.max(1, ratio)
        let r = reach(filter, sigma: sigma)
        let outW = horizontal ? outLength : image.width
        let outH = horizontal ? image.height : outLength
        // Weights depend only on the output index, so they are tabulated once.
        var starts = [Int](repeating: 0, count: outLength)
        var weights = [Float](repeating: 0, count: outLength * 2 * r)
        for i in 0..<outLength {
            let p = (Double(i) + 0.5) * ratio
            let base = Int((p - 0.5).rounded(.down))
            let first = base - r + 1
            starts[i] = first
            var sum = 0.0
            var local = [Double](repeating: 0, count: 2 * r)
            for k in 0..<(2 * r) {
                let centre = Double(first + k) + 0.5
                let wgt = filter.weight((centre - p) / sigma)
                local[k] = wgt
                sum += wgt
            }
            for k in 0..<(2 * r) { weights[i * 2 * r + k] = Float(sum != 0 ? local[k] / sum : 0) }
        }
        var out = ImageBuffer(width: outW, height: outH)
        let src = image.pixels
        let inW = image.width
        out.pixels.withUnsafeMutableBufferPointer { buffer in
            let dst = Unchecked(buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: outH) { y in
                for x in 0..<outW {
                    let i = horizontal ? x : y
                    let first = starts[i]
                    var acc = SIMD4<Float>(repeating: 0)
                    for k in 0..<(2 * r) {
                        let wgt = weights[i * 2 * r + k]
                        if wgt == 0 { continue }
                        let t = Swift.min(Swift.max(first + k, 0), inLength - 1)
                        let si = horizontal ? (y * inW + t) * 4 : (t * inW + x) * 4
                        acc += wgt * SIMD4(src[si], src[si + 1], src[si + 2], src[si + 3])
                    }
                    let di = (y * outW + x) * 4
                    dst.value[di] = acc.x
                    dst.value[di + 1] = acc.y
                    dst.value[di + 2] = acc.z
                    dst.value[di + 3] = acc.w
                }
            }
        }
        return out
    }

    /// The geometric pass: inverse-mapped, separable weights in source axes, normalized,
    /// clamp-to-edge taps, and an edge fade (`cover`) in OUTPUT pixels: `footprint` is
    /// source pixels per output pixel at this pass.
    public static func resample(_ image: ImageBuffer, outputToSource m: Homography,
                                width: Int, height: Int, sigma: Double,
                                footprint: Double = 1,
                                filter: Filter) -> ImageBuffer {
        let r = reach(filter, sigma: sigma)
        let taps = 2 * r
        let w = image.width, h = image.height
        let fw = Double(w), fh = Double(h)
        let f = footprint.isFinite && footprint > 0 ? footprint : 1
        let src = image.pixels
        var out = ImageBuffer(width: Swift.max(width, 1), height: Swift.max(height, 1))
        let outW = out.width, outH = out.height
        out.pixels.withUnsafeMutableBufferPointer { buffer in
            let dst = Unchecked(buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: outH) { oy in
                var wx = [Double](repeating: 0, count: taps)
                var wy = [Double](repeating: 0, count: taps)
                for ox in 0..<outW {
                    let p = m.apply(Double(ox) + 0.5, Double(oy) + 0.5)
                    let di = (oy * outW + ox) * 4
                    guard p.w > 0, p.x.isFinite, p.y.isFinite else {
                        dst.value[di] = 0; dst.value[di + 1] = 0
                        dst.value[di + 2] = 0; dst.value[di + 3] = 0
                        continue
                    }
                    let coverage = cover(p.x, fw, f) * cover(p.y, fh, f)
                    if coverage <= 0 {
                        dst.value[di] = 0; dst.value[di + 1] = 0
                        dst.value[di + 2] = 0; dst.value[di + 3] = 0
                        continue
                    }
                    let bx = Int((p.x - 0.5).rounded(.down)) - r + 1
                    let by = Int((p.y - 0.5).rounded(.down)) - r + 1
                    var sx = 0.0, sy = 0.0
                    for k in 0..<taps {
                        wx[k] = filter.weight((Double(bx + k) + 0.5 - p.x) / sigma)
                        sx += wx[k]
                        wy[k] = filter.weight((Double(by + k) + 0.5 - p.y) / sigma)
                        sy += wy[k]
                    }
                    var acc = SIMD4<Double>(repeating: 0)
                    for j in 0..<taps where wy[j] != 0 {
                        let ty = Swift.min(Swift.max(by + j, 0), h - 1)
                        var row = SIMD4<Double>(repeating: 0)
                        for k in 0..<taps where wx[k] != 0 {
                            let tx = Swift.min(Swift.max(bx + k, 0), w - 1)
                            let si = (ty * w + tx) * 4
                            row += wx[k] * SIMD4(Double(src[si]), Double(src[si + 1]),
                                                 Double(src[si + 2]), Double(src[si + 3]))
                        }
                        acc += wy[j] * row
                    }
                    let norm = sx * sy
                    let v = norm != 0 ? acc / norm : acc
                    dst.value[di] = Float(v.x * coverage)
                    dst.value[di + 1] = Float(v.y * coverage)
                    dst.value[di + 2] = Float(v.z * coverage)
                    dst.value[di + 3] = Float(v.w * coverage)
                }
            }
        }
        return out
    }

    /// 1 inside the source and up to one OUTPUT pixel beyond it, falling to 0 over the
    /// next half output pixel. The allowance is the delivered grid's: its edges round
    /// outward to whole pixels (`GeometryMap.outputWidth`), so on a straightened crop
    /// the outermost pixel centres can overhang the inscribed frame — and with it the
    /// source corner it touches — by up to √2/2 px. Those pixels read the clamped edge,
    /// as `PipelineRenderer.scaled` does; only a real exposed border (Upright's Scale
    /// below 100, an Offset) fades to transparent.
    @inlinable static func cover(_ p: Double, _ extent: Double, _ footprint: Double) -> Double {
        let inside = Swift.min(p, extent - p) / footprint
        return Swift.min(Swift.max((inside + 1.5) * 2, 0), 1)
    }

    struct Unchecked: @unchecked Sendable {
        let value: UnsafeMutablePointer<Float>
        init(_ value: UnsafeMutablePointer<Float>) { self.value = value }
    }
}

// MARK: - The stage

public enum GeometryStage {

    /// S16 on a rendered buffer: what `PipelineRenderer.renderReference` and
    /// `lumen-render` call after `ReferenceRenderer.render`. `sourceSize` is the size the
    /// geometry is measured against when the buffer is a scaled decode of it; it only
    /// changes the output size, never where the crop falls.
    public static func apply(_ image: ImageBuffer, geometry: Geometry,
                             targetLongEdge: Int? = nil,
                             filter: GeometryResample.Filter = .lanczos3) -> ImageBuffer {
        let map = GeometryMap(geometry: geometry, sourceWidth: image.width,
                              sourceHeight: image.height, targetLongEdge: targetLongEdge)
        return GeometryResample.apply(image, map: map, filter: filter)
    }
}

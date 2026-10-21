// UprightDetector.swift
// The straight lines Upright solves from: a line-segment detector in the manner of LSD
// (von Gioi et al. 2010) — gradient orientation, region growing over pixels whose level
// line agrees, a rectangle fitted to each region — run on the log luminance of a proxy.
//
// Log luminance so an edge in a shadow counts as much as the same edge in the sky: the
// detector looks for structure, and exposure is not structure. A proxy (≤ 1600 px) because
// the lines a perspective correction needs are the long ones, and their direction is
// better conditioned at a scale where a brick's texture is below the noise floor.
//
// The output is source-normalized `Upright.Segment`s, the form the recipe stores; see
// `UprightSolver` for why detection runs once at edit time and never inside a render.

import Foundation

public enum UprightDetector {

    /// Long edge of the analysis proxy.
    public static let analysisLongEdge = 1600
    /// Shortest segment kept, as a fraction of the proxy's long edge.
    public static let minimumLengthFraction = 0.03
    /// Level-line agreement for region growing (LSD's τ).
    static let angleTolerance = 22.5 * Double.pi / 180

    /// Every straight segment worth solving from, longest first, at most `limit`.
    public static func detect(_ image: ImageBuffer, limit: Int = 200) -> [Upright.Segment] {
        var proxy = image
        while Swift.max(proxy.width, proxy.height) > analysisLongEdge {
            proxy = GeometryResample.halve(proxy)
        }
        let w = proxy.width, h = proxy.height
        guard w >= 16, h >= 16 else { return [] }

        // Log luminance, lightly smoothed.
        let weights = RGBColorSpace.rec2020.luminanceWeights
        var luma = Plane(width: w, height: h)
        for i in 0..<(w * h) {
            let y = weights.r * Double(proxy.pixels[i * 4])
                + weights.g * Double(proxy.pixels[i * 4 + 1])
                + weights.b * Double(proxy.pixels[i * 4 + 2])
            luma.values[i] = Float(log2(Swift.max(y, 1e-4)))
        }
        luma = SpatialOps.gaussianBlur(luma, sigma: 0.8)

        // Gradient (2×2 LSD stencil, centred between pixels) and its level-line angle.
        var magnitude = [Float](repeating: 0, count: w * h)
        var angle = [Float](repeating: 0, count: w * h)
        for y in 0..<(h - 1) {
            for x in 0..<(w - 1) {
                let a = luma.values[y * w + x], b = luma.values[y * w + x + 1]
                let c = luma.values[(y + 1) * w + x], d = luma.values[(y + 1) * w + x + 1]
                let gx = 0.5 * ((b - a) + (d - c))
                let gy = 0.5 * ((c - a) + (d - b))
                magnitude[y * w + x] = (gx * gx + gy * gy).squareRoot()
                angle[y * w + x] = atan2(gx, -gy)
            }
        }

        // Threshold: an edge of a tenth of a stop per pixel, or the 75th percentile of
        // the frame, whichever is higher — a flat sky contributes nothing, a busy facade
        // only its strongest edges.
        let sortedMagnitudes = magnitude.sorted()
        let p75 = sortedMagnitudes[Int(Double(sortedMagnitudes.count) * 0.75)]
        let threshold = Swift.max(Float(0.1), p75)

        // Seeds in descending magnitude.
        var order: [Int] = []
        order.reserveCapacity(w * h / 4)
        for i in 0..<(w * h) where magnitude[i] > threshold { order.append(i) }
        order.sort { magnitude[$0] > magnitude[$1] }

        var used = [Bool](repeating: false, count: w * h)
        let minLength = minimumLengthFraction * Double(Swift.max(w, h))
        var segments: [(seg: Upright.Segment, length: Double)] = []
        var region: [Int] = []
        var stack: [Int] = []

        for seed in order where !used[seed] {
            region.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            used[seed] = true
            stack.append(seed)
            var sumCos = Double(cos(angle[seed])), sumSin = Double(sin(angle[seed]))
            var regionAngle = Double(angle[seed])
            while let i = stack.popLast() {
                region.append(i)
                let x = i % w, y = i / w
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w - 1, ny < h - 1 else { continue }
                        let j = ny * w + nx
                        guard !used[j], magnitude[j] > threshold else { continue }
                        var diff = abs(Double(angle[j]) - regionAngle)
                        if diff > .pi { diff = 2 * .pi - diff }
                        guard diff < angleTolerance else { continue }
                        used[j] = true
                        stack.append(j)
                        sumCos += Double(cos(angle[j]))
                        sumSin += Double(sin(angle[j]))
                        regionAngle = atan2(sumSin, sumCos)
                    }
                }
            }
            guard Double(region.count) >= minLength * 0.8 else { continue }
            guard let fitted = fit(region, width: w, magnitude: magnitude),
                  fitted.length >= minLength,
                  fitted.width <= 2.5,
                  Double(region.count) >= 0.7 * fitted.length else { continue }
            // Pixel corners sit at the gradient stencil's centre, half a pixel in.
            let s = Upright.Segment(x0: (fitted.p.0 + 1) / Double(w), y0: (fitted.p.1 + 1) / Double(h),
                                    x1: (fitted.q.0 + 1) / Double(w), y1: (fitted.q.1 + 1) / Double(h))
            segments.append((s, fitted.length))
        }
        return segments.sorted { $0.length > $1.length }.prefix(limit).map(\.seg)
    }

    /// Magnitude-weighted principal axis of a region: its endpoints along the axis and
    /// its RMS width across it, in proxy pixels.
    static func fit(_ region: [Int], width w: Int, magnitude: [Float])
        -> (p: (Double, Double), q: (Double, Double), length: Double, width: Double)? {
        var sw = 0.0, sx = 0.0, sy = 0.0
        for i in region {
            let m = Double(magnitude[i])
            sw += m; sx += m * Double(i % w); sy += m * Double(i / w)
        }
        guard sw > 0 else { return nil }
        let cx = sx / sw, cy = sy / sw
        var xx = 0.0, yy = 0.0, xy = 0.0
        for i in region {
            let m = Double(magnitude[i])
            let dx = Double(i % w) - cx, dy = Double(i / w) - cy
            xx += m * dx * dx; yy += m * dy * dy; xy += m * dx * dy
        }
        xx /= sw; yy /= sw; xy /= sw
        let theta = 0.5 * atan2(2 * xy, xx - yy)
        let ux = cos(theta), uy = sin(theta)
        var lo = Double.infinity, hi = -Double.infinity, across = 0.0
        for i in region {
            let dx = Double(i % w) - cx, dy = Double(i / w) - cy
            let t = dx * ux + dy * uy
            lo = Swift.min(lo, t); hi = Swift.max(hi, t)
            let n = -dx * uy + dy * ux
            across += n * n
        }
        let width = (across / Double(region.count)).squareRoot()
        return ((cx + lo * ux, cy + lo * uy), (cx + hi * ux, cy + hi * uy), hi - lo + 1, width)
    }
}

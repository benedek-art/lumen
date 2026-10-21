// HealQualitySupport.swift
// What "a heal that a photographer would trust" is measured with (docs/quality/lanes/
// WS-56/SPEC.md). Every fixture is a CLEAN frame plus a synthesised defect, so the clean
// frame is the ground truth the healed result is scored against:
//
//   · colourError    OKLab ΔE ×100 between the mean of the healed core (ρ < 0.8) and
//                    the clean frame's mean over the same pixels. ~1 is a just-visible
//                    shift on a flat field.
//   · blotch         the largest |low-pass(L_out − L_truth)| inside the disc, OKLab L ×100,
//                    low-pass a box of R/3. Catches a halo, a dark ring or a patch that is
//                    re-lit wrong in one part of the disc, which a mean hides.
//   · seamStep       the gradient discontinuity at the boundary: in 24 sectors, the step
//                    |mean L over ρ∈[0.88,1.0) − mean L over ρ∈[1.0,1.12)|, averaged, MINUS
//                    the same number on the clean frame (whose own texture has some). ×100.
//   · seamGradient   mean |∇L| over ρ∈[0.85,1.15], healed ÷ clean. 1 is no added edge.
//   · textureRatio   std of the high-pass L inside ρ < 0.8, healed ÷ clean. 1 is the same
//                    grain; < 1 is a smeared patch, > 1 a patch busier than its context.
//
// The LFI reader/writer is the corpus's own format (scripts/proof/CORPUS.md).

import Foundation
@testable import LumenCore

enum HealQuality {

    struct HealMetrics: CustomStringConvertible {
        var colourError: Double
        var blotch: Double
        var seamStep: Double
        var seamGradient: Double
        var textureRatio: Double

        var description: String {
            String(format: "ΔE %.2f  blotch %.2f  seamStep %+.2f  seamGrad %.2f  texture %.2f",
                   colourError, blotch, seamStep, seamGradient, textureRatio)
        }

        var json: [String: Double] {
            ["colourError": colourError, "blotch": blotch, "seamStep": seamStep,
             "seamGradient": seamGradient, "textureRatio": textureRatio]
        }
    }

    static let lab = OKLabTransform.Context(space: .rec2020)

    /// OKLab of a scene-linear value normalised so the frame's reference white is 1 —
    /// `scale` is supplied by the caller (the ring mean ÷ 0.18), so dark and bright
    /// fixtures are judged at the same perceptual operating point.
    static func okLab(_ c: RGB, scale: Double) -> OKLab {
        lab.toLab(RGB(Swift.max(c.r * scale, 0), Swift.max(c.g * scale, 0),
                      Swift.max(c.b * scale, 0)))
    }

    static func metrics(healed: ImageBuffer, truth: ImageBuffer, cx: Double, cy: Double,
                        radius: Double) -> HealMetrics {
        metrics(healed: healed, truth: truth,
                box: (cx - 1.7 * radius, cy - 1.7 * radius, cx + 1.7 * radius, cy + 1.7 * radius),
                centre: (cx, cy), radius: radius) { x, y in hypot(x - cx, y - cy) / radius }
    }

    /// The same five numbers for any shape: `rho(x, y)` is the normalized distance from
    /// the shape (0 inside its core, 1 at its boundary) at pixel centre (x, y); `box`
    /// bounds ρ ≤ 1.7; `radius` (pixels) sets the blotch low-pass; sectors for the seam step are angles about `centre`.
    static func metrics(healed: ImageBuffer, truth: ImageBuffer,
                        box: (Double, Double, Double, Double), centre: (Double, Double),
                        radius: Double, rho rhoAt: (Double, Double) -> Double) -> HealMetrics {
        let cx = centre.0, cy = centre.1
        // Operating point: the clean ring's mean luminance taken to mid-grey.
        let x0 = Swift.max(Int(box.0), 0)
        let y0 = Swift.max(Int(box.1), 0)
        let x1 = Swift.min(Int(box.2) + 1, truth.width)
        let y1 = Swift.min(Int(box.3) + 1, truth.height)
        let w = x1 - x0, h = y1 - y0
        var rhoPlane = [Double](repeating: 9, count: w * h)
        for y in 0..<h { for x in 0..<w {
            rhoPlane[y * w + x] = rhoAt(Double(x0 + x) + 0.5, Double(y0 + y) + 0.5)
        } }
        var ringSum = 0.0, ringN = 0.0
        for y in 0..<h { for x in 0..<w where rhoPlane[y * w + x] >= 1.15
                && rhoPlane[y * w + x] < 1.6 {
            let c = truth[x0 + x, y0 + y]
            ringSum += 0.2627 * c.r + 0.678 * c.g + 0.0593 * c.b
            ringN += 1
        } }
        let scale = ringN > 0 && ringSum > 0 ? 0.18 / (ringSum / ringN) : 1
        var labOut = [OKLab](repeating: OKLab(L: 0, a: 0, b: 0), count: w * h)
        var labTruth = labOut
        for y in 0..<h { for x in 0..<w {
            labOut[y * w + x] = okLab(healed[x0 + x, y0 + y], scale: scale)
            labTruth[y * w + x] = okLab(truth[x0 + x, y0 + y], scale: scale)
        } }
        func rho(_ x: Int, _ y: Int) -> Double { rhoPlane[y * w + x] }

        // Colour.
        var mo = (0.0, 0.0, 0.0), mt = (0.0, 0.0, 0.0), n = 0.0
        for y in 0..<h { for x in 0..<w where rho(x, y) < 0.8 {
            let o = labOut[y * w + x], t = labTruth[y * w + x]
            mo.0 += o.L; mo.1 += o.a; mo.2 += o.b
            mt.0 += t.L; mt.1 += t.a; mt.2 += t.b
            n += 1
        } }
        let colourError = n > 0
            ? 100 * sqrt(pow((mo.0 - mt.0) / n, 2) + pow((mo.1 - mt.1) / n, 2)
                         + pow((mo.2 - mt.2) / n, 2))
            : 0

        // Blotch: box-filtered L difference.
        let k = Swift.max(Int((radius / 3).rounded()), 1)
        var diff = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) { diff[i] = labOut[i].L - labTruth[i].L }
        let lowDiff = boxBlur(diff, w, h, k)
        var blotch = 0.0
        for y in 0..<h { for x in 0..<w where rho(x, y) < 1 {
            blotch = Swift.max(blotch, abs(lowDiff[y * w + x]))
        } }

        // Seam step per sector.
        func sectorStep(_ L: [OKLab]) -> Double {
            let sectors = 24
            var inner = [Double](repeating: 0, count: sectors), innerN = inner
            var outer = inner, outerN = inner
            for y in 0..<h { for x in 0..<w {
                let r = rho(x, y)
                guard r >= 0.88, r < 1.12 else { continue }
                let a = atan2(Double(y0 + y) + 0.5 - cy, Double(x0 + x) + 0.5 - cx)
                let s = Swift.min(Int((a + .pi) / (2 * .pi) * Double(sectors)), sectors - 1)
                if r < 1 { inner[s] += L[y * w + x].L; innerN[s] += 1 }
                else { outer[s] += L[y * w + x].L; outerN[s] += 1 }
            } }
            var acc = 0.0, m = 0.0
            for s in 0..<sectors where innerN[s] > 0 && outerN[s] > 0 {
                acc += abs(inner[s] / innerN[s] - outer[s] / outerN[s])
                m += 1
            }
            return m > 0 ? acc / m : 0
        }
        let seamStep = 100 * (sectorStep(labOut) - sectorStep(labTruth))

        // Seam gradient.
        func gradientMean(_ L: [OKLab]) -> Double {
            var acc = 0.0, m = 0.0
            for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                let r = rho(x, y)
                guard r >= 0.85, r <= 1.15 else { continue }
                let gx = L[y * w + x + 1].L - L[y * w + x - 1].L
                let gy = L[(y + 1) * w + x].L - L[(y - 1) * w + x].L
                acc += hypot(gx, gy)
                m += 1
            } }
            return m > 0 ? acc / m : 0
        }
        let gt = gradientMean(labTruth)
        let seamGradient = gt > 1e-9 ? gradientMean(labOut) / gt : 1

        // Texture: std of L − box3(L) in the core.
        func highpassStd(_ L: [OKLab]) -> Double {
            let plain = L.map { $0.L }
            let low = boxBlur(plain, w, h, 2)
            var s = 0.0, s2 = 0.0, m = 0.0
            for y in 0..<h { for x in 0..<w where rho(x, y) < 0.8 {
                let v = plain[y * w + x] - low[y * w + x]
                s += v; s2 += v * v; m += 1
            } }
            guard m > 1 else { return 0 }
            return sqrt(Swift.max(s2 / m - (s / m) * (s / m), 0))
        }
        let ht = highpassStd(labTruth)
        let textureRatio = ht > 1e-9 ? highpassStd(labOut) / ht : 1

        return HealMetrics(colourError: colourError, blotch: 100 * blotch, seamStep: seamStep,
                       seamGradient: seamGradient, textureRatio: textureRatio)
    }

    /// How much CLEAN patches of this picture differ from the truth here: the metrics of
    /// the truth itself, displaced by 2.5 radii in 8 directions, median of each. A heal
    /// on texture cannot reproduce the exact leaves that were under the defect; it can be
    /// as close as the picture's own neighbouring patches are, and that is the bar.
    static func naturalVariation(truth: ImageBuffer, cx: Double, cy: Double,
                                 radius: Double) -> HealMetrics {
        var rows: [HealMetrics] = []
        for k in 0..<8 {
            let t = Double(k) * .pi / 4
            let ox = Int((cos(t) * 2.5 * radius).rounded())
            let oy = Int((sin(t) * 2.5 * radius).rounded())
            var shifted = truth
            forEachPixel(truth, cx, cy, radius, 0, 1) { x, y, _ in
                shifted[x, y] = truth.clampedSample(x + ox, y + oy)
            }
            rows.append(metrics(healed: shifted, truth: truth, cx: cx, cy: cy, radius: radius))
        }
        func median(_ f: (HealMetrics) -> Double) -> Double {
            let v = rows.map(f).sorted()
            return (v[3] + v[4]) / 2
        }
        return HealMetrics(colourError: median { $0.colourError }, blotch: median { $0.blotch },
                       seamStep: median { $0.seamStep }, seamGradient: median { $0.seamGradient },
                       textureRatio: median { $0.textureRatio })
    }

    static func forEachPixel(_ image: ImageBuffer, _ cx: Double, _ cy: Double,
                             _ radius: Double, _ r0: Double, _ r1: Double,
                             _ body: (Int, Int, Double) -> Void) {
        let x0 = Swift.max(Int(cx - r1 * radius), 0)
        let y0 = Swift.max(Int(cy - r1 * radius), 0)
        let x1 = Swift.min(Int(cx + r1 * radius) + 1, image.width)
        let y1 = Swift.min(Int(cy + r1 * radius) + 1, image.height)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 { for x in x0..<x1 {
            let r = hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy) / radius
            if r >= r0 && r < r1 { body(x, y, r) }
        } }
    }

    static func boxBlur(_ v: [Double], _ w: Int, _ h: Int, _ k: Int) -> [Double] {
        var tmp = v, out = v
        for y in 0..<h { for x in 0..<w {
            var s = 0.0, m = 0.0
            for i in Swift.max(x - k, 0)...Swift.min(x + k, w - 1) { s += v[y * w + i]; m += 1 }
            tmp[y * w + x] = s / m
        } }
        for y in 0..<h { for x in 0..<w {
            var s = 0.0, m = 0.0
            for j in Swift.max(y - k, 0)...Swift.min(y + k, h - 1) { s += tmp[j * w + x]; m += 1 }
            out[y * w + x] = s / m
        } }
        return out
    }

    /// A dark wire or scratch along a polyline: multiplicative, soft-edged, `halfWidth`
    /// pixels to where it fades out.
    static func addWire(_ image: ImageBuffer, points: [(Double, Double)], halfWidth: Double,
                        depth: Double) -> ImageBuffer {
        var out = image
        let line = points.map { StrokeHeal.Point($0.0, $0.1) }
        let xs = points.map { $0.0 }, ys = points.map { $0.1 }
        let x0 = Swift.max(Int((xs.min() ?? 0) - halfWidth - 1), 0)
        let x1 = Swift.min(Int((xs.max() ?? 0) + halfWidth + 2), image.width)
        let y0 = Swift.max(Int((ys.min() ?? 0) - halfWidth - 1), 0)
        let y1 = Swift.min(Int((ys.max() ?? 0) + halfWidth + 2), image.height)
        for y in y0..<y1 { for x in x0..<x1 {
            let d = StrokeHeal.distance(StrokeHeal.Point(Double(x) + 0.5, Double(y) + 0.5),
                                        to: line) / halfWidth
            guard d < 1 else { continue }
            let t = 1 - d * d
            out[x, y] = image[x, y] * (1 - depth * t * t)
        } }
        return out
    }

    /// Paint a heal stroke along `points` (pixels) with the app's auto offset, and apply it.
    static func healStroke(_ image: ImageBuffer, points: [(Double, Double)], radius: Double,
                           mode: HealMode = .heal,
                           feather: Double = 50) -> (ImageBuffer, BrushStroke) {
        let w = Double(image.width), h = Double(image.height)
        var stroke = BrushStroke(points: points.map { BrushPoint(x: $0.0 / w, y: $0.1 / h) },
                                 size: 2 * radius / Swift.max(w, h), feather: feather,
                                 density: 100, retouch: StrokeRetouch(mode: mode, dx: 0, dy: 0))
        if let found = StrokeSourceSearch.autoOffset(for: stroke, in: image) {
            stroke.retouch?.dx = found.dx
            stroke.retouch?.dy = found.dy
        }
        return (StrokeHeal.apply(image, strokes: [stroke]), stroke)
    }

    static func strokeMetrics(healed: ImageBuffer, truth: ImageBuffer,
                              points: [(Double, Double)], reach: Double) -> HealMetrics {
        let line = points.map { StrokeHeal.Point($0.0, $0.1) }
        let xs = points.map { $0.0 }, ys = points.map { $0.1 }
        let box = ((xs.min() ?? 0) - 1.7 * reach, (ys.min() ?? 0) - 1.7 * reach,
                   (xs.max() ?? 0) + 1.7 * reach, (ys.max() ?? 0) + 1.7 * reach)
        let centre = ((box.0 + box.2) / 2, (box.1 + box.3) / 2)
        return metrics(healed: healed, truth: truth, box: box, centre: centre,
                       radius: reach) { x, y in
            StrokeHeal.distance(StrokeHeal.Point(x, y), to: line) / reach
        }
    }

    // MARK: Defects

    /// A dust shadow: a multiplicative soft disc (sensor dust is out of focus, so it
    /// darkens and does not hide texture), `depth` at its centre, gone by `radius`.
    static func addDust(_ image: ImageBuffer, cx: Double, cy: Double, radius: Double,
                        depth: Double) -> ImageBuffer {
        var out = image
        forEachPixel(image, cx, cy, radius, 0, 1) { x, y, r in
            let t = Swift.max(1 - r * r, 0)
            let f = 1 - depth * t * t
            out[x, y] = image[x, y] * f
        }
        return out
    }

    /// A blemish: a reddish-brown multiplicative tint, opaque-ish at the centre, with a
    /// soft edge — what a spot on skin is to the camera.
    static func addBlemish(_ image: ImageBuffer, cx: Double, cy: Double, radius: Double,
                           tint: RGB = RGB(0.62, 0.42, 0.40)) -> ImageBuffer {
        var out = image
        forEachPixel(image, cx, cy, radius, 0, 1) { x, y, r in
            let t = Swift.max(1 - r * r, 0)
            let a = t * t * (3 - 2 * t)
            let c = image[x, y]
            out[x, y] = RGB(c.r * (1 - a + a * tint.r), c.g * (1 - a + a * tint.g),
                            c.b * (1 - a + a * tint.b))
        }
        return out
    }

    /// A bright speck with a hard core — a pollen grain or a specular on a leaf.
    static func addSpeck(_ image: ImageBuffer, cx: Double, cy: Double, radius: Double,
                         value: RGB) -> ImageBuffer {
        var out = image
        forEachPixel(image, cx, cy, radius, 0, 1) { x, y, r in
            let a = r < 0.6 ? 1 : 1 - (r - 0.6) / 0.4
            out[x, y] = image[x, y].mix(value, a)
        }
        return out
    }

    // MARK: Synthetic scenes

    /// A sky: a vertical and slight horizontal gradient of blue with fine sensor noise.
    static func sky(width: Int = 256, height: Int = 192, noise: Double = 0.004) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let t = Double(y) / Double(height), s = Double(x) / Double(width)
            let base = RGB(0.10 + 0.08 * t + 0.01 * s, 0.17 + 0.07 * t, 0.36 + 0.03 * t)
            let n = (spotNoise(x, y, 1) - 0.5) * 2 * noise
            image[x, y] = base * (1 + n / 0.17)
        } }
        return image
    }

    /// Foliage-like texture: multi-scale value noise in green, strong local contrast,
    /// no period — the kind of picture a repeated source shows up in.
    static func foliage(width: Int = 256, height: Int = 192) -> ImageBuffer {
        func value(_ x: Double, _ y: Double, _ cell: Double, _ salt: UInt64) -> Double {
            let gx = x / cell, gy = y / cell
            let ix = Int(floor(gx)), iy = Int(floor(gy))
            let fx = gx - floor(gx), fy = gy - floor(gy)
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            let a = spotNoise(ix, iy, salt), b = spotNoise(ix + 1, iy, salt)
            let c = spotNoise(ix, iy + 1, salt), d = spotNoise(ix + 1, iy + 1, salt)
            return (a * (1 - sx) + b * sx) * (1 - sy) + (c * (1 - sx) + d * sx) * sy
        }
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let px = Double(x), py = Double(y)
            let v = 0.5 * value(px, py, 9, 11) + 0.3 * value(px, py, 4, 12)
                + 0.2 * value(px, py, 2, 13)
            let shade = 0.25 + 1.5 * pow(v, 2.2)
            let warm = value(px, py, 23, 14)
            image[x, y] = RGB(0.035 + 0.02 * warm, 0.07, 0.025) * shade
                * (1 + 0.6 * Double(x) / Double(width))
        } }
        return image
    }

    /// Skin: a warm, slowly varying tone with fine pore-scale texture.
    static func skin(width: Int = 256, height: Int = 192) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let t = Double(x) / Double(width), s = Double(y) / Double(height)
            let shade = 0.75 + 0.4 * t - 0.15 * s
            let pore = (spotNoise(x, y, 21) - 0.5) * 0.06
                + (spotNoise(x / 3, y / 3, 22) - 0.5) * 0.05
            image[x, y] = RGB(0.42, 0.27, 0.20) * (shade * (1 + pore))
        } }
        return image
    }

    // MARK: LFI

    static func readLFI(_ path: String) -> ImageBuffer? {
        guard let data = FileManager.default.contents(atPath: path), data.count >= 16,
              String(data: data.prefix(4), encoding: .ascii) == "LFI1" else { return nil }
        func u32(_ o: Int) -> Int {
            Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24
        }
        let w = u32(4), h = u32(8)
        guard u32(12) == 3, data.count >= 16 + w * h * 12 else { return nil }
        var pixels = [Float](repeating: 1, count: w * h * 4)
        data.withUnsafeBytes { raw in
            let floats = raw.baseAddress!.advanced(by: 16).assumingMemoryBound(to: Float.self)
            for i in 0..<(w * h) {
                pixels[i * 4] = floats[i * 3]
                pixels[i * 4 + 1] = floats[i * 3 + 1]
                pixels[i * 4 + 2] = floats[i * 3 + 2]
            }
        }
        return ImageBuffer(width: w, height: h, pixels: pixels)
    }

    static func writeLFI(_ image: ImageBuffer, _ path: String) {
        var data = Data("LFI1".utf8)
        for v in [image.width, image.height, 3] {
            var le = UInt32(v).littleEndian
            data.append(Data(bytes: &le, count: 4))
        }
        var floats = [Float](repeating: 0, count: image.width * image.height * 3)
        for i in 0..<(image.width * image.height) {
            floats[i * 3] = image.pixels[i * 4]
            floats[i * 3 + 1] = image.pixels[i * 4 + 1]
            floats[i * 3 + 2] = image.pixels[i * 4 + 2]
        }
        floats.withUnsafeBytes { data.append(contentsOf: $0) }
        FileManager.default.createFile(atPath: path, contents: data)
    }

    static func crop(_ image: ImageBuffer, x: Int, y: Int, width: Int,
                     height: Int) -> ImageBuffer {
        var out = ImageBuffer(width: width, height: height)
        for j in 0..<height { for i in 0..<width {
            out[i, j] = image.clampedSample(x + i, y + j)
        } }
        return out
    }

    /// Auto-source a spot exactly as the app does on a whole frame, then apply it.
    static func heal(_ image: ImageBuffer, cx: Double, cy: Double, radius: Double,
                     mode: HealMode = .heal, feather: Double = HealSpot.defaultFeather,
                     opacity: Double = 100) -> (ImageBuffer, HealSpot) {
        let w = Double(image.width), h = Double(image.height)
        var spot = HealSpot(id: "q", mode: mode, x: cx / w, y: cy / h,
                            sourceX: cx / w, sourceY: cy / h,
                            radius: radius / Swift.max(w, h), feather: feather,
                            opacity: opacity)
        if let source = SpotSourceSearch.autoSource(for: spot, in: image) {
            spot.sourceX = source.x
            spot.sourceY = source.y
        }
        return (SpotRetouch.apply(image, spots: [spot]), spot)
    }
}

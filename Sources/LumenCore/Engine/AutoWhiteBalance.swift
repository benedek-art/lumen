// AutoWhiteBalance.swift
// Auto white balance: a Temp/Tint suggestion from scene statistics (WS-03, SPEC line 12).
//
// Input is the decode itself — scene-linear Rec.2020 at camera-reference white balance,
// so a surface the camera thought neutral arrives as R = G = B.
//
// CAST-INVARIANT BY CONSTRUCTION (round 3). Everything is measured in CAT16 cone space,
// as (ln L/M, ln S/M) relative to the working white. The engine's white balance is a von
// Kries step in exactly that space, so a wrong as-shot — a tungsten frame shot on
// Daylight — moves every pixel by the SAME vector there: a pure translation. The search
// below runs over ABSOLUTE candidate illuminants (Adobe/DNG Temp 1667–50000 K × tint
// −50…+60) and scores the picture under each one, so it finds the same light however
// wrong the camera's as-shot was. The round-2 estimator searched a window around the
// as-shot and recovered nothing beyond a ~25 mired cast; this one recovers 150.
//
// FOR EACH CANDIDATE LIGHT, AFTER CORRECTING BY IT:
//   · near-neutral evidence — the share of luminance (cone M) within 0.02 of neutral;
//   · a grey ladder — the luminance span of those near-neutral pixels (a chart, a white
//     wall in light and shade, an overcast sky; a single dyed object spans little);
//   · white-patch agreement — the brightest 2 % should be near neutral too;
//   · skin — the skin wedge (Monk 1–10 and both ColorChecker skins) is measured AFTER the
//     candidate's correction, so a cast does not make every pixel look like skin, and
//     skin pixels count 5 % in grey-world and white-patch.
// The best candidate's estimate blends near-neutral : white-patch : grey-world as
// 1 : 0.1 : 0.05, all in the corrected cone space.
//
// FALLING BACK. A frame with no credible neutral (quality below 0.02, e.g. a frame of
// lawn or of skin) stays at as-shot; full trust from 0.06. One more term is deliberately
// NOT cast-invariant: when the answer moves the light by 20–50 mired from the camera's
// as-shot, the move is cut to 40 %. That is the band where a near-white surface (a warm
// paper, a blue cloth) and a real camera error look the same — SPEC 14's chart-OUT runs
// are exactly that — and below 8 mired or above 80 mired the evidence is trusted fully:
// a 100–150 mired error is a wrong preset, not a subject colour.
//
// Deterministic and cheap: one pass into a ≈640 px block proxy, a 400×400 feature
// histogram, ~16 000 candidate lights read off it, and full evaluation of the 12 best.

import Foundation

public enum AutoWhiteBalance {

    /// A pixel rectangle in the input image (top-left origin) to leave out of the
    /// statistics — a colour chart, a burnt-in watermark, a region the user excludes.
    public struct Region: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Temp/Tint in the slider's convention (Adobe/DNG, `ColorTemperature`), plus how
    /// much of the move away from as-shot the statistics supported (0 = as-shot).
    public struct Estimate: Equatable, Sendable {
        public let kelvin: Double
        public let tint: Double
        public let confidence: Double

        public init(kelvin: Double, tint: Double, confidence: Double) {
            self.kelvin = kelvin
            self.tint = tint
            self.confidence = confidence
        }
    }

    // MARK: - Tuning (measured on the WS-03 corpus; see BUILD-NOTES.md, round 3)

    /// Long edge of the block-averaged proxy the statistics run on.
    static let proxyLongEdge = 640
    /// A channel whose frame maximum is at least this is treated as able to clip…
    static let clipCandidate: Float = 0.5
    /// …and a pixel at ≥ 95 % of that maximum is treated as clipped.
    static let clipFraction: Float = 0.95
    /// Feature histogram: [−2, 2) in both axes at 0.01.
    static let histogramBins = 400
    static let histogramStep = 0.01
    /// Near-neutral radius in corrected (ln L/M, ln S/M).
    static let neutralRadius = 0.02
    /// Candidate lights: mired 20…600 in 2, tint −50…+60 in 2.
    static let candidateMireds = stride(from: 20.0, through: 600.0, by: 2).map { $0 }
    static let candidateTints = stride(from: -50.0, through: 60.0, by: 2).map { $0 }
    /// Peaks evaluated in full.
    static let peakCount = 12
    /// Grey ladder: no credit below 0.3 stops of span, full credit from 1.0.
    static let ladderLow = 0.3
    static let ladderHigh = 1.0
    /// White-patch disagreement at which agreement has fallen to 1/e.
    static let whitePatchScale = 0.25
    /// Quality at which the move starts, and at which it is fully trusted.
    static let qualityLow = 0.02
    static let qualityHigh = 0.06
    /// The ambiguity band, in mired of illuminant move: ramps in over 8…20, out over
    /// 50…80, cutting the move by 60 % inside it.
    static let ambiguity = (rise0: 8.0, rise1: 20.0, fall0: 50.0, fall1: 80.0, cut: 0.6)
    /// Blend weights.
    static let weightNearNeutral = 1.0
    static let weightWhitePatch = 0.1
    static let weightGreyWorld = 0.05
    /// Weight of a skin-wedge pixel in grey-world and white-patch.
    static let skinWeight = 0.05
    /// Share of the brightest (cone M) the white patch averages.
    static let whitePatchPercentile = 0.98

    // MARK: - Estimate

    /// Suggest Temp/Tint for `image`, the scene-linear Rec.2020 decode at
    /// camera-reference white balance, shot at `asShot`. `excluding` regions are left
    /// out of every statistic. A frame with no usable evidence returns `asShot` itself
    /// (sanitised and clamped the way `WhiteBalanceEngine.init` reads it).
    public static func estimate(_ image: ImageBuffer, asShot: WhiteBalanceEngine.Neutral,
                                excluding: [Region] = []) -> Estimate {
        let sanitized = WhiteBalanceEngine.Neutral.sanitizedAsShot(kelvin: asShot.kelvin,
                                                                   tint: asShot.tint)
        let shot = (kelvin: Num.clamp(sanitized.kelvin, ColorTemperature.minKelvin,
                                      ColorTemperature.maxKelvin),
                    tint: Num.clamp(sanitized.tint, -300, 300))
        let asShotAnswer = Estimate(kelvin: shot.kelvin, tint: shot.tint, confidence: 0)

        let samples = proxy(image, excluding: excluding)
        guard let found = search(samples, asShot: shot) else { return asShotAnswer }
        let p = found.shift.0 * found.confidence
        let q = found.shift.1 * found.confidence
        guard found.confidence > 0, abs(p) > 1e-9 || abs(q) > 1e-9,
              let solved = light(shiftedBy: (p, q), from: shot) else {
            return asShotAnswer
        }
        let kelvin = Num.clamp(solved.kelvin, ColorTemperature.minKelvin,
                               ColorTemperature.maxKelvin)
        let tint = ColorTemperature.clampedTint(
            kelvin: kelvin, tint: Num.clamp(solved.tint, ColorTemperature.minTint,
                                            ColorTemperature.maxTint),
            asShot: shot)
        return Estimate(kelvin: kelvin, tint: tint, confidence: found.confidence)
    }

    /// The target (Kelvin, tint) at which `WhiteBalanceEngine.adaptation` from `asShot`
    /// renders `decodedNeutral` — a colour measured on the decode — exactly R = G = B.
    ///
    /// Closed form, because the adaptation is von Kries in CAT16: the output cone
    /// response is the input's times as-shot / target, so the target's cone response is
    /// the input's times the as-shot's over the working white's. Then the exact inverse
    /// of the convention (`ColorTemperature.temperatureAndTint`).
    public static func neutralTarget(decodedNeutral: RGB,
                                     asShot: (kelvin: Double, tint: Double),
                                     space: RGBColorSpace = .rec2020)
        -> (kelvin: Double, tint: Double)? {
        let c = ChromaticAdaptation.cat16.apply(space.toXYZ.apply(decodedNeutral))
        let w = ChromaticAdaptation.cat16.apply(space.toXYZ.apply(RGB(1, 1, 1)))
        guard c.r > 0, c.g > 0, c.b > 0, w.r > 0, w.g > 0, w.b > 0 else { return nil }
        return light(shiftedBy: (log(c.r / c.g) - log(w.r / w.g),
                                 log(c.b / c.g) - log(w.b / w.g)), from: asShot)
    }

    /// The light whose cone response is the as-shot's moved by `shift` in
    /// (ln L/M, ln S/M), in Adobe/DNG Temp/Tint.
    static func light(shiftedBy shift: (Double, Double),
                      from asShot: (kelvin: Double, tint: Double))
        -> (kelvin: Double, tint: Double)? {
        let a = ChromaticAdaptation.cat16.apply(
            ColorTemperature.chromaticity(kelvin: asShot.kelvin, tint: asShot.tint).xyz())
        let t = RGB(a.r * exp(shift.0), a.g, a.b * exp(shift.1))
        let xyz = ChromaticAdaptation.cat16Inverse.apply(t)
        let sum = xyz.r + xyz.g + xyz.b
        guard sum.isFinite, sum > 0 else { return nil }
        let pair = ColorTemperature.temperatureAndTint(for: Chromaticity(xyz.r / sum, xyz.g / sum))
        guard pair.kelvin.isFinite, pair.tint.isFinite else { return nil }
        return pair
    }

    // MARK: - Proxy

    /// Block means of the unclipped, non-excluded pixels, at about `proxyLongEdge` on
    /// the long side. A block that is less than three-quarters usable is dropped rather
    /// than averaged from a corner.
    static func proxy(_ image: ImageBuffer, excluding: [Region]) -> [RGB] {
        let w = image.width, h = image.height
        let block = Swift.max(1, Int((Double(Swift.max(w, h)) / Double(proxyLongEdge))
            .rounded(.up)))
        let cols = w / block, rows = h / block
        guard cols > 0, rows > 0 else { return [] }

        return image.pixels.withUnsafeBufferPointer { px -> [RGB] in
            // Per-channel frame maximum: a channel that reaches high enough can clip,
            // and its clipped pixels carry the sensor's ceiling, not the scene's colour.
            var maxR: Float = 0, maxG: Float = 0, maxB: Float = 0
            var i = 0
            let n = w * h * 4
            while i < n {
                maxR = Swift.max(maxR, px[i])
                maxG = Swift.max(maxG, px[i + 1])
                maxB = Swift.max(maxB, px[i + 2])
                i += 4
            }
            let clipR = maxR >= clipCandidate ? clipFraction * maxR : Float.infinity
            let clipG = maxG >= clipCandidate ? clipFraction * maxG : Float.infinity
            let clipB = maxB >= clipCandidate ? clipFraction * maxB : Float.infinity

            var sumR = [Double](repeating: 0, count: cols)
            var sumG = [Double](repeating: 0, count: cols)
            var sumB = [Double](repeating: 0, count: cols)
            var count = [Int](repeating: 0, count: cols)
            var out: [RGB] = []
            out.reserveCapacity(cols * rows)
            let needed = Int((0.75 * Double(block * block)).rounded(.up))
            for by in 0..<rows {
                for c in 0..<cols { sumR[c] = 0; sumG[c] = 0; sumB[c] = 0; count[c] = 0 }
                for y in (by * block)..<(by * block + block) {
                    let rowRegions = excluding.filter { y >= $0.y && y < $0.y + $0.height }
                    let base = y * w * 4
                    for x in 0..<(cols * block) {
                        if !rowRegions.isEmpty,
                           rowRegions.contains(where: { x >= $0.x && x < $0.x + $0.width }) {
                            continue
                        }
                        let j = base + x * 4
                        let r = px[j], g = px[j + 1], b = px[j + 2]
                        guard r < clipR, g < clipG, b < clipB else { continue }
                        let c = x / block
                        sumR[c] += Double(r)
                        sumG[c] += Double(g)
                        sumB[c] += Double(b)
                        count[c] += 1
                    }
                }
                for c in 0..<cols where count[c] >= needed {
                    let k = Double(count[c])
                    out.append(RGB(sumR[c] / k, sumG[c] / k, sumB[c] / k))
                }
            }
            return out
        }
    }


    // MARK: - The search

    /// (ln L/M, ln S/M) of a working-space colour relative to the working white, and its
    /// cone M (the luminance weight: a cast scales it by one constant for every pixel,
    /// so rankings by it do not change with the cast). Nil when a cone is not positive.
    static let coneFromWorking: Mat3 = ChromaticAdaptation.cat16 * RGBColorSpace.rec2020.toXYZ
    static let whiteCone: RGB = coneFromWorking.apply(RGB(1, 1, 1))

    static func feature(_ c: RGB) -> (p: Double, q: Double, m: Double)? {
        let k = coneFromWorking.apply(c)
        guard k.r > 1e-6, k.g > 1e-6, k.b > 1e-6 else { return nil }
        return (log(k.r / k.g) - log(whiteCone.r / whiteCone.g),
                log(k.b / k.g) - log(whiteCone.b / whiteCone.g), k.g)
    }

    /// Skin, in corrected cone features (neutral at 0): the Monk 1–10 and ColorChecker
    /// skin patches sit at ln L/M 0.015…0.16 and ln S/M −0.08…−0.65.
    static func isSkin(p: Double, q: Double) -> Bool {
        p > 0 && p < 0.2 && q < -0.06 && q > -0.75 && q < -2 * p
    }

    struct Found {
        let shift: (Double, Double)
        let confidence: Double
    }

    private struct Candidate {
        let shift: (Double, Double)
        let nearNeutral: (Double, Double)
        let quality: Double
    }

    static func search(_ samples: [RGB], asShot: (kelvin: Double, tint: Double)) -> Found? {
        var fp: [Double] = [], fq: [Double] = [], fm: [Double] = [], rgb: [RGB] = []
        fp.reserveCapacity(samples.count)
        fq.reserveCapacity(samples.count)
        fm.reserveCapacity(samples.count)
        rgb.reserveCapacity(samples.count)
        var total = 0.0
        for s in samples {
            guard let f = feature(s), f.m > 1e-4 else { continue }
            fp.append(f.p)
            fq.append(f.q)
            fm.append(f.m)
            rgb.append(s)
            total += f.m
        }
        let n = fp.count
        guard n > 0, total > 0 else { return nil }

        // Luminance histogram of the features, then its box sum over ±2 bins.
        let bins = histogramBins, step = histogramStep
        var hist = [Double](repeating: 0, count: bins * bins)
        for i in 0..<n {
            let a = Int(((fp[i] + 2) / step).rounded(.down))
            let b = Int(((fq[i] + 2) / step).rounded(.down))
            guard a >= 0, a < bins, b >= 0, b < bins else { continue }
            hist[a * bins + b] += fm[i] / total
        }
        let reach = Int((neutralRadius / step).rounded())
        var cumulative = [Double](repeating: 0, count: (bins + 1) * (bins + 1))
        for a in 0..<bins {
            var row = 0.0
            for b in 0..<bins {
                row += hist[a * bins + b]
                cumulative[(a + 1) * (bins + 1) + b + 1] = cumulative[a * (bins + 1) + b + 1] + row
            }
        }
        func boxSum(_ a: Int, _ b: Int) -> Double {
            let a0 = Swift.max(0, a - reach), a1 = Swift.min(bins, a + reach + 1)
            let b0 = Swift.max(0, b - reach), b1 = Swift.min(bins, b + reach + 1)
            let w = bins + 1
            return cumulative[a1 * w + b1] - cumulative[a0 * w + b1]
                - cumulative[a1 * w + b0] + cumulative[a0 * w + b0]
        }

        // Every candidate light, as the shift it predicts for a neutral, and the
        // near-neutral share it would make.
        let a = ChromaticAdaptation.cat16.apply(
            ColorTemperature.chromaticity(kelvin: asShot.kelvin, tint: asShot.tint).xyz())
        let mireds = candidateMireds, tints = candidateTints
        let rows = mireds.count, cols = tints.count
        var shifts = [(Double, Double)](repeating: (0, 0), count: rows * cols)
        var score = [Double](repeating: -1, count: rows * cols)
        for i in 0..<rows {
            for j in 0..<cols {
                let c = ChromaticAdaptation.cat16.apply(
                    DNGTemperature.chromaticity(kelvin: 1e6 / mireds[i], tint: tints[j]).xyz())
                let rl = c.r / a.r, rm = c.g / a.g, rs = c.b / a.b
                guard rl > 0, rm > 0, rs > 0 else { continue }
                let s = (log(rl / rm), log(rs / rm))
                shifts[i * cols + j] = s
                let ba = Int(((s.0 + 2) / step).rounded(.towardZero))
                let bb = Int(((s.1 + 2) / step).rounded(.towardZero))
                score[i * cols + j] = boxSum(Swift.min(Swift.max(ba, 0), bins - 1),
                                             Swift.min(Swift.max(bb, 0), bins - 1))
            }
        }
        // Local maxima over a 9×9 neighbourhood, strongest first (row-major ties).
        var peaks: [Int] = []
        for i in 0..<rows {
            for j in 0..<cols {
                let v = score[i * cols + j]
                guard v > 0.005 else { continue }
                var isPeak = true
                for di in -4...4 where isPeak {
                    for dj in -4...4 {
                        let ii = i + di, jj = j + dj
                        guard ii >= 0, ii < rows, jj >= 0, jj < cols else { continue }
                        if score[ii * cols + jj] > v { isPeak = false; break }
                    }
                }
                if isPeak { peaks.append(i * cols + j) }
            }
        }
        peaks = peaks.enumerated().sorted {
            score[$0.element] != score[$1.element]
                ? score[$0.element] > score[$1.element] : $0.offset < $1.offset
        }.prefix(peakCount).map(\.element)

        // The white patch: brightest 2 % by cone M (percentile by linear interpolation).
        let sortedM = fm.sorted()
        let rank = whitePatchPercentile * Double(n - 1)
        let lo = Int(rank.rounded(.down)), hi = Swift.min(n - 1, lo + 1)
        let threshold = sortedM[lo] + (sortedM[hi] - sortedM[lo]) * (rank - Double(lo))
        var wpMean = RGB(0, 0, 0)
        var wpCount = 0.0
        for i in 0..<n where fm[i] >= threshold {
            wpMean = RGB(wpMean.r + rgb[i].r, wpMean.g + rgb[i].g, wpMean.b + rgb[i].b)
            wpCount += 1
        }
        guard wpCount > 0, let whitePatch = feature(wpMean / wpCount) else { return nil }

        func evaluate(_ start: (Double, Double)) -> Candidate? {
            var cp = start.0, cq = start.1
            var radius = 0.06
            for _ in 0..<4 {
                var sw = 0.0, sp = 0.0, sq = 0.0
                for i in 0..<n {
                    let dp = fp[i] - cp, dq = fq[i] - cq
                    guard (dp * dp + dq * dq).squareRoot() < radius else { continue }
                    sw += fm[i]
                    sp += fp[i] * fm[i]
                    sq += fq[i] * fm[i]
                }
                guard sw > 0 else { break }
                cp = sp / sw
                cq = sq / sw
                radius = Swift.max(neutralRadius, radius * 0.7)
            }
            var inside: [Double] = []
            var insideM = 0.0, skinM = 0.0
            var gw = RGB(0, 0, 0), gwW = 0.0
            var wp = RGB(0, 0, 0), wpW = 0.0
            for i in 0..<n {
                let dp = fp[i] - cp, dq = fq[i] - cq
                if (dp * dp + dq * dq).squareRoot() < neutralRadius {
                    inside.append(fm[i])
                    insideM += fm[i]
                }
                let skin = isSkin(p: dp, q: dq)
                if skin { skinM += fm[i] }
                let w = skin ? skinWeight : 1
                gw = RGB(gw.r + rgb[i].r * w, gw.g + rgb[i].g * w, gw.b + rgb[i].b * w)
                gwW += w
                if fm[i] >= threshold {
                    wp = RGB(wp.r + rgb[i].r * w, wp.g + rgb[i].g * w, wp.b + rgb[i].b * w)
                    wpW += w
                }
            }
            guard inside.count >= 20, gwW > 0, wpW > 0,
                  let greyWorld = feature(gw / gwW), let whites = feature(wp / wpW) else {
                return nil
            }
            inside.sort()
            let p10 = inside[Int(0.1 * Double(inside.count - 1))]
            let p90 = inside[Int(0.9 * Double(inside.count - 1))]
            let span = log2(p90 / Swift.max(p10, 1e-6))
            let ladder = Num.clamp((span - ladderLow) / (ladderHigh - ladderLow), 0, 1)
            let dwp = ((whitePatch.p - cp) * (whitePatch.p - cp)
                + (whitePatch.q - cq) * (whitePatch.q - cq)).squareRoot()
            let quality = insideM / total * ladder
                * exp(-(dwp / whitePatchScale) * (dwp / whitePatchScale)) * (1 - skinM / total)
            let weights = weightNearNeutral + weightWhitePatch + weightGreyWorld
            let blend = ((weightNearNeutral * cp + weightWhitePatch * whites.p
                            + weightGreyWorld * greyWorld.p) / weights,
                         (weightNearNeutral * cq + weightWhitePatch * whites.q
                            + weightGreyWorld * greyWorld.q) / weights)
            return Candidate(shift: blend, nearNeutral: (cp, cq), quality: quality)
        }

        var best: Candidate?
        for peak in peaks {
            guard let c = evaluate(shifts[peak]) else { continue }
            if best == nil || c.quality > best!.quality { best = c }
        }
        guard let chosen = best else { return nil }

        func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
            let t = Num.clamp((x - e0) / (e1 - e0), 0, 1)
            return t * t * (3 - 2 * t)
        }
        let evidence = smooth(qualityLow, qualityHigh, chosen.quality)
        var prior = 1.0
        if let moved = light(shiftedBy: chosen.shift, from: asShot) {
            let d = abs(1e6 / moved.kelvin - 1e6 / asShot.kelvin)
            let band = smooth(ambiguity.rise0, ambiguity.rise1, d)
                * (1 - smooth(ambiguity.fall0, ambiguity.fall1, d))
            prior = 1 - ambiguity.cut * band
        }
        return Found(shift: chosen.shift, confidence: Num.clamp(evidence * prior, 0, 1))
    }
}

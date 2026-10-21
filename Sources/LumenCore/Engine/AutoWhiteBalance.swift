// AutoWhiteBalance.swift
// Auto white balance: a Temp/Tint suggestion from scene statistics (WS-03, SPEC line 12).
//
// Input is the decode itself — scene-linear Rec.2020 at camera-reference white balance,
// so a surface the camera thought neutral arrives as R = G = B. Everything below works
// in log-chroma relative to that as-shot neutral, (p, q) = (ln R/G, ln B/G), where the
// as-shot is the origin and an illuminant error is a displacement.
//
// THREE ESTIMATES, ONE ANSWER.
//   · grey-world — the mean of the frame. Robust, and wrong whenever one colour owns
//     the frame (foliage pulls it to magenta, a blue cloth to yellow).
//   · white-patch — the mean of the brightest unclipped 2 %. Right when the brightest
//     thing is a white, wrong when it is a sky or a lamp.
//   · near-neutral (grey-edge's cousin, gamut-constrained) — an iteratively re-centred,
//     shrinking window around the as-shot neutral, luminance-weighted. It finds the
//     greys a camera's own estimate is near, and it is the one that carries the
//     weight: on the corpus charts it lands within a few mired of the chart greys.
// They are blended 1 : 0.1 : 0.05 (near-neutral : white-patch : grey-world).
//
// CONFIDENCE, AND FALLING BACK. The camera's own as-shot is a strong prior — it beat
// both naive estimators on three of the five chart frames (AUDIT.md finding 7) — so the
// answer is the as-shot moved toward the blend by a confidence in [0, 1], the product of
//   · how close the blend is to the as-shot (a big correction is less likely to be right
//     than a big subject colour: 1346 without its chart sees a cool background at −0.18
//     in ln B/G and would turn the frame amber),
//   · how much luminance sits in the near-neutral cluster (no greys, no evidence),
//   · how far white-patch agrees with near-neutral,
//   · and 1 − the luminance share of skin.
// SKIN-SAFE: pixels in the skin wedge are down-weighted to 5 % in every estimate, and
// a frame that is mostly skin barely moves — greying a portrait is the one Auto failure
// nobody forgives.
//
// Deterministic (no randomness, fixed sequential order) and cheap: one pass over the
// frame into a ≈640 px block proxy, then a few passes over the proxy. 2400×1600 runs in
// well under a tenth of a second in release.

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

    // MARK: - Tuning (measured on the WS-03 chart frames; see BUILD-NOTES.md)

    /// Long edge of the block-averaged proxy the statistics run on.
    static let proxyLongEdge = 640
    /// A channel whose frame maximum is at least this is treated as able to clip…
    static let clipCandidate: Float = 0.5
    /// …and a pixel at ≥ 95 % of that maximum is treated as clipped.
    static let clipFraction: Float = 0.95
    /// Near-neutral window: starting radius, floor, shrink per pass, passes.
    static let windowStart = 0.15
    static let windowFloor = 0.05
    static let windowShrink = 0.7
    static let windowPasses = 6
    /// Radius of the cluster whose luminance share is the evidence term.
    static let clusterRadius = 0.04
    /// Luminance share at which the evidence term saturates.
    static let clusterShareForFullConfidence = 0.15
    /// Distance from as-shot (ln-chroma) at which the prior has fallen to 1/e.
    static let priorScale = 0.15
    /// White-patch ↔ near-neutral disagreement at which agreement has fallen to 1/e.
    static let agreementScale = 0.3
    /// Blend weights.
    static let weightNearNeutral = 1.0
    static let weightWhitePatch = 0.1
    static let weightGreyWorld = 0.05
    /// Weight of a skin-wedge pixel relative to any other.
    static let skinWeight = 0.05
    /// Share of the brightest luminance the white patch averages.
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
        guard let shift = logChromaShift(samples) else { return asShotAnswer }
        guard shift.confidence > 0, shift.p != 0 || shift.q != 0 else {
            return asShotAnswer
        }
        let neutral = RGB(exp(shift.p), 1, exp(shift.q))
        guard let solved = neutralTarget(decodedNeutral: neutral, asShot: shot) else {
            return asShotAnswer
        }
        let kelvin = Num.clamp(solved.kelvin, ColorTemperature.minKelvin,
                               ColorTemperature.maxKelvin)
        let tint = ColorTemperature.clampedTint(
            kelvin: kelvin, tint: Num.clamp(solved.tint, ColorTemperature.minTint,
                                            ColorTemperature.maxTint),
            asShot: shot)
        return Estimate(kelvin: kelvin, tint: tint, confidence: shift.confidence)
    }

    /// The target (Kelvin, tint) at which `WhiteBalanceEngine.adaptation` from `asShot`
    /// renders `decodedNeutral` — a colour measured on the decode — exactly R = G = B.
    ///
    /// Closed form, because the adaptation is von Kries in CAT16: the output cone
    /// response is the input's times as-shot / target, so the target's cone response is
    /// the input's times the as-shot's over the working white's. Then the exact inverse
    /// of the convention (`ColorTemperature.temperatureAndTint`). The eyedropper's
    /// search (`neutralizing`) finds the same pair by minimisation; this is the
    /// statistics path, where thousands of evaluations per press would buy nothing.
    public static func neutralTarget(decodedNeutral: RGB,
                                     asShot: (kelvin: Double, tint: Double),
                                     space: RGBColorSpace = .rec2020)
        -> (kelvin: Double, tint: Double)? {
        let cone = ChromaticAdaptation.cat16
        let c = cone.apply(space.toXYZ.apply(decodedNeutral))
        let a = cone.apply(ColorTemperature.chromaticity(kelvin: asShot.kelvin,
                                                         tint: asShot.tint).xyz())
        let w = cone.apply(space.toXYZ.apply(RGB(1, 1, 1)))
        guard w.r != 0, w.g != 0, w.b != 0 else { return nil }
        let t = RGB(a.r * c.r / w.r, a.g * c.g / w.g, a.b * c.b / w.b)
        let xyz = ChromaticAdaptation.cat16Inverse.apply(t)
        let sum = xyz.r + xyz.g + xyz.b
        guard sum.isFinite, sum > 0 else { return nil }
        let chroma = Chromaticity(xyz.r / sum, xyz.g / sum)
        let pair = ColorTemperature.temperatureAndTint(for: chroma)
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

    // MARK: - The statistics

    struct Shift {
        let p: Double
        let q: Double
        let confidence: Double
    }

    /// Is this (ln R/G, ln B/G) in the skin wedge at camera-reference white balance:
    /// R/G 1.04…1.9, B/G 0.40…0.97, and redder than it is blue-deficient by at least
    /// 0.12 — every Monk tone 2–8 and both ColorChecker skins, none of the chart greys.
    static func isSkin(p: Double, q: Double) -> Bool {
        p > log(1.04) && p < log(1.9) && q < log(0.97) && q > log(0.40) && p - q > 0.12
    }

    /// The confidence-scaled move away from as-shot, in log-chroma. Nil when nothing in
    /// the frame is usable.
    static func logChromaShift(_ samples: [RGB]) -> Shift? {
        var p: [Double] = [], q: [Double] = [], lum: [Double] = [], weight: [Double] = []
        var rgb: [RGB] = []
        p.reserveCapacity(samples.count)
        q.reserveCapacity(samples.count)
        lum.reserveCapacity(samples.count)
        weight.reserveCapacity(samples.count)
        rgb.reserveCapacity(samples.count)
        var skinLum = 0.0, totalLum = 0.0
        for s in samples where s.r > 1e-4 && s.g > 1e-4 && s.b > 1e-4 {
            let pp = log(s.r / s.g), qq = log(s.b / s.g)
            let y = 0.2627 * s.r + 0.6780 * s.g + 0.0593 * s.b
            let skin = isSkin(p: pp, q: qq)
            p.append(pp)
            q.append(qq)
            lum.append(y)
            weight.append(skin ? skinWeight : 1)
            rgb.append(s)
            totalLum += y
            if skin { skinLum += y }
        }
        let n = p.count
        guard n > 0, totalLum > 0 else { return nil }
        let skinShare = skinLum / totalLum

        // Near-neutral: a shrinking window, re-centred on its own luminance-weighted
        // mean, starting at the as-shot neutral.
        var cp = 0.0, cq = 0.0
        var radius = windowStart
        for _ in 0..<windowPasses {
            var sw = 0.0, sp = 0.0, sq = 0.0
            for i in 0..<n {
                let dp = p[i] - cp, dq = q[i] - cq
                guard (dp * dp + dq * dq).squareRoot() < radius else { continue }
                let wy = weight[i] * lum[i]
                sw += wy
                sp += p[i] * wy
                sq += q[i] * wy
            }
            guard sw >= 1e-9 else { break }
            cp = sp / sw
            cq = sq / sw
            radius = Swift.max(windowFloor, radius * windowShrink)
        }
        var inCluster = 0.0, allWeighted = 0.0
        for i in 0..<n {
            let wy = weight[i] * lum[i]
            allWeighted += wy
            let dp = p[i] - cp, dq = q[i] - cq
            if (dp * dp + dq * dq).squareRoot() < clusterRadius { inCluster += wy }
        }
        let clusterShare = allWeighted > 0 ? inCluster / allWeighted : 0

        // Grey-world.
        var gw = RGB(0, 0, 0)
        var gwWeight = 0.0
        for i in 0..<n {
            gw = RGB(gw.r + rgb[i].r * weight[i], gw.g + rgb[i].g * weight[i],
                     gw.b + rgb[i].b * weight[i])
            gwWeight += weight[i]
        }
        let gwP = log(gw.r / gw.g), gwQ = log(gw.b / gw.g)

        // White-patch: the brightest 2 % (percentile by linear interpolation).
        let sorted = lum.sorted()
        let rank = whitePatchPercentile * Double(n - 1)
        let lo = Int(rank.rounded(.down)), hi = Swift.min(n - 1, lo + 1)
        let threshold = sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - Double(lo))
        var wp = RGB(0, 0, 0)
        for i in 0..<n where lum[i] >= threshold {
            wp = RGB(wp.r + rgb[i].r * weight[i], wp.g + rgb[i].g * weight[i],
                     wp.b + rgb[i].b * weight[i])
        }
        let wpP = log(wp.r / wp.g), wpQ = log(wp.b / wp.g)
        guard gwP.isFinite, gwQ.isFinite, wpP.isFinite, wpQ.isFinite else { return nil }

        let total = weightNearNeutral + weightWhitePatch + weightGreyWorld
        let bp = (weightNearNeutral * cp + weightWhitePatch * wpP + weightGreyWorld * gwP) / total
        let bq = (weightNearNeutral * cq + weightWhitePatch * wpQ + weightGreyWorld * gwQ) / total

        let distance = (bp * bp + bq * bq).squareRoot()
        let prior = exp(-(distance / priorScale) * (distance / priorScale))
        let evidence = Swift.min(1, clusterShare / clusterShareForFullConfidence)
        let disagreement = ((wpP - cp) * (wpP - cp) + (wpQ - cq) * (wpQ - cq)).squareRoot()
        let agreement = exp(-(disagreement / agreementScale) * (disagreement / agreementScale))
        let confidence = Num.clamp(prior * evidence * agreement * (1 - skinShare), 0, 1)
        return Shift(p: bp * confidence, q: bq * confidence, confidence: confidence)
    }
}

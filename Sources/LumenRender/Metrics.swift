// Metrics.swift — the numbers an audit uses to prove a slider right or wrong. Every
// definition is restated in main.swift's header; keep the two together.

import Foundation
import LumenCore

struct Percentiles: Codable {
    let p1: Double
    let p5: Double
    let p50: Double
    let p95: Double
    let p99: Double
}

struct LuminanceMetrics: Codable {
    let meanLinear: Double
    let medianLinear: Double
    let meanEncoded: Double
    let medianEncoded: Double
    let percentilesLinear: Percentiles
    let percentilesEncoded: Percentiles
}

struct ChannelPct: Codable {
    let r: Double
    let g: Double
    let b: Double
    let any: Double
}

struct ClippingMetrics: Codable {
    let definition: String
    let highlightsPct: ChannelPct
    let shadowsPct: ChannelPct
}

struct ColourMetrics: Codable {
    let space: String
    let meanChroma: Double
    let meanChromaOfChromatic: Double
    let chromaThreshold: Double
    let chromaticPct: Double
    let hueBinsDegrees: [String]
    /// Fraction of chromatic pixels per 30° OKLab hue bin; sums to 1 (or all 0).
    let hueHistogram: [Double]
    /// The same, weighted by chroma.
    let hueHistogramChromaWeighted: [Double]
}

struct ImageMetrics: Codable {
    let width: Int
    let height: Int
    let outputSpace: String
    let luminance: LuminanceMetrics
    let clipping: ClippingMetrics
    let colour: ColourMetrics
    let meanEncodedRGB: [Double]
    let renderSeconds: Double
}

/// Per-pixel quantities a sweep needs after the image metrics are taken.
struct PixelPlanes {
    let encodedLuminance: [Float]
    let linearLuminance: [Float]
    let lab: [Float]          // CIELAB D65, interleaved
}

enum Metrics {

    static let chromaThreshold = 0.02

    static func percentile(_ sorted: [Float], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = p / 100 * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Swift.min(lo + 1, sorted.count - 1)
        let t = pos - Double(lo)
        return Double(sorted[lo]) * (1 - t) + Double(sorted[hi]) * t
    }

    static func percentiles(_ sorted: [Float]) -> Percentiles {
        Percentiles(p1: percentile(sorted, 1), p5: percentile(sorted, 5),
                    p50: percentile(sorted, 50), p95: percentile(sorted, 95),
                    p99: percentile(sorted, 99))
    }

    static func measure(_ img: EncodedImage, space: OutputSpace,
                        seconds: Double) -> (ImageMetrics, PixelPlanes) {
        let n = img.width * img.height
        let w = space.space.luminanceWeights
        let wr = Float(w.r), wg = Float(w.g), wb = Float(w.b)
        let ok = OKLabTransform.Context(space: space.space)
        let toXYZ = space.space.toXYZ
        let white = toXYZ.apply(RGB(1, 1, 1))

        var yLin = [Float](repeating: 0, count: n)
        var yEnc = [Float](repeating: 0, count: n)
        var lab = [Float](repeating: 0, count: n * 3)
        var chroma = [Float](repeating: 0, count: n)
        var hue = [Float](repeating: 0, count: n)

        yLin.withUnsafeMutableBufferPointer { yl in
        yEnc.withUnsafeMutableBufferPointer { ye in
        lab.withUnsafeMutableBufferPointer { lb in
        chroma.withUnsafeMutableBufferPointer { cb in
        hue.withUnsafeMutableBufferPointer { hb in
            let ylp = yl.baseAddress!, yep = ye.baseAddress!, lbp = lb.baseAddress!
            let cbp = cb.baseAddress!, hbp = hb.baseAddress!
            let rows = img.height, width = img.width
            img.linear.withUnsafeBufferPointer { lin in
                DispatchQueue.concurrentPerform(iterations: rows) { y in
                    for x in 0..<width {
                        let i = y * width + x
                        let r = lin[i * 3], g = lin[i * 3 + 1], b = lin[i * 3 + 2]
                        let yv = wr * r + wg * g + wb * b
                        ylp[i] = yv
                        yep[i] = Float(TransferFunction.srgb.encode(Double(Swift.max(yv, 0))))
                        let c = RGB(Double(r), Double(g), Double(b))
                        let o = ok.toLab(c)
                        cbp[i] = Float(o.chroma)
                        hbp[i] = Float(o.hue)
                        let l = cieLab(toXYZ.apply(c), white: white)
                        lbp[i * 3] = Float(l.0); lbp[i * 3 + 1] = Float(l.1)
                        lbp[i * 3 + 2] = Float(l.2)
                    }
                }
            }
        }}}}}

        let sortedLin = yLin.sorted(), sortedEnc = yEnc.sorted()
        let meanLin = yLin.reduce(0.0) { $0 + Double($1) } / Double(n)
        let meanEnc = yEnc.reduce(0.0) { $0 + Double($1) } / Double(n)

        var hiR = 0, hiG = 0, hiB = 0, hiAny = 0, loR = 0, loG = 0, loB = 0, loAny = 0
        var sumRGB = [0.0, 0.0, 0.0]
        for i in 0..<n {
            let r = img.codes[i * 3], g = img.codes[i * 3 + 1], b = img.codes[i * 3 + 2]
            if r == 255 { hiR += 1 }; if g == 255 { hiG += 1 }; if b == 255 { hiB += 1 }
            if r == 255 || g == 255 || b == 255 { hiAny += 1 }
            if r == 0 { loR += 1 }; if g == 0 { loG += 1 }; if b == 0 { loB += 1 }
            if r == 0 || g == 0 || b == 0 { loAny += 1 }
            sumRGB[0] += Double(r); sumRGB[1] += Double(g); sumRGB[2] += Double(b)
        }
        func pct(_ c: Int) -> Double { Double(c) / Double(n) * 100 }

        var hist = [Double](repeating: 0, count: 12)
        var histW = [Double](repeating: 0, count: 12)
        var chromaSum = 0.0, chromaticSum = 0.0, chromatic = 0
        for i in 0..<n {
            let c = Double(chroma[i])
            chromaSum += c
            guard c > chromaThreshold else { continue }
            chromatic += 1
            chromaticSum += c
            let bin = Swift.min(Int(Double(hue[i]) / 30), 11)
            hist[bin] += 1
            histW[bin] += c
        }
        let hTotal = hist.reduce(0, +), wTotal = histW.reduce(0, +)
        let colour = ColourMetrics(
            space: "OKLab (LumenCore OKLabTransform, CAT16) of \(space.displayName) "
                + "display-linear output",
            meanChroma: chromaSum / Double(n),
            meanChromaOfChromatic: chromatic > 0 ? chromaticSum / Double(chromatic) : 0,
            chromaThreshold: chromaThreshold,
            chromaticPct: pct(chromatic),
            hueBinsDegrees: (0..<12).map { "\($0 * 30)-\($0 * 30 + 30)" },
            hueHistogram: hist.map { hTotal > 0 ? $0 / hTotal : 0 },
            hueHistogramChromaWeighted: histW.map { wTotal > 0 ? $0 / wTotal : 0 })

        let metrics = ImageMetrics(
            width: img.width, height: img.height, outputSpace: space.displayName,
            luminance: LuminanceMetrics(
                meanLinear: meanLin, medianLinear: percentile(sortedLin, 50),
                meanEncoded: meanEnc, medianEncoded: percentile(sortedEnc, 50),
                percentilesLinear: percentiles(sortedLin),
                percentilesEncoded: percentiles(sortedEnc)),
            clipping: ClippingMetrics(
                definition: "% of pixels whose undithered 8-bit code is 255 (highlights) "
                    + "or 0 (shadows), per channel",
                highlightsPct: ChannelPct(r: pct(hiR), g: pct(hiG), b: pct(hiB), any: pct(hiAny)),
                shadowsPct: ChannelPct(r: pct(loR), g: pct(loG), b: pct(loB), any: pct(loAny))),
            colour: colour,
            meanEncodedRGB: sumRGB.map { $0 / Double(n) / 255 },
            renderSeconds: seconds)
        return (metrics, PixelPlanes(encodedLuminance: yEnc, linearLuminance: yLin, lab: lab))
    }

    // MARK: CIELAB + CIEDE2000

    static func cieLab(_ xyz: RGB, white: RGB) -> (Double, Double, Double) {
        func f(_ t: Double) -> Double {
            let d = 6.0 / 29.0
            return t > d * d * d ? cbrt(t) : t / (3 * d * d) + 4.0 / 29.0
        }
        let fx = f(xyz.r / white.r), fy = f(xyz.g / white.g), fz = f(xyz.b / white.b)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// CIEDE2000 (Sharma, Wu & Dalal 2005), kL = kC = kH = 1.
    static func deltaE2000(_ l1: Double, _ a1: Double, _ b1: Double,
                           _ l2: Double, _ a2: Double, _ b2: Double) -> Double {
        let rad = Double.pi / 180
        let c1 = (a1 * a1 + b1 * b1).squareRoot(), c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cBar = (c1 + c2) / 2
        let c7 = pow(cBar, 7)
        let g = 0.5 * (1 - (c7 / (c7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot(), c2p = (a2p * a2p + b2 * b2).squareRoot()
        func hp(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / rad
            return h < 0 ? h + 360 : h
        }
        let h1p = hp(b1, a1p), h2p = hp(b2, a2p)
        let dLp = l2 - l1
        let dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp / 2 * rad)
        let lBarp = (l1 + l2) / 2
        let cBarp = (c1p + c2p) / 2
        var hBarp = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 { hBarp = (h1p + h2p) / 2 }
            else if h1p + h2p < 360 { hBarp = (h1p + h2p + 360) / 2 }
            else { hBarp = (h1p + h2p - 360) / 2 }
        }
        let t = 1 - 0.17 * cos((hBarp - 30) * rad) + 0.24 * cos(2 * hBarp * rad)
            + 0.32 * cos((3 * hBarp + 6) * rad) - 0.20 * cos((4 * hBarp - 63) * rad)
        let dTheta = 30 * exp(-pow((hBarp - 275) / 25, 2))
        let cBarp7 = pow(cBarp, 7)
        let rc = 2 * (cBarp7 / (cBarp7 + pow(25, 7))).squareRoot()
        let l50 = (lBarp - 50) * (lBarp - 50)
        let sl = 1 + 0.015 * l50 / (20 + l50).squareRoot()
        let sc = 1 + 0.045 * cBarp
        let sh = 1 + 0.015 * cBarp * t
        let rt = -sin(2 * dTheta * rad) * rc
        let x = dLp / sl, y = dCp / sc, z = dHp / sh
        return (x * x + y * y + z * z + rt * y * z).squareRoot()
    }

    struct DeltaE: Codable {
        let mean: Double
        let p95: Double
        let max: Double
    }

    static func deltaE(_ a: PixelPlanes, _ b: PixelPlanes) -> DeltaE {
        let n = a.lab.count / 3
        var d = [Float](repeating: 0, count: n)
        d.withUnsafeMutableBufferPointer { dp in
            let p = dp.baseAddress!
            let chunk = 4096
            DispatchQueue.concurrentPerform(iterations: (n + chunk - 1) / chunk) { c in
                for i in (c * chunk)..<Swift.min(n, (c + 1) * chunk) {
                    p[i] = Float(deltaE2000(Double(a.lab[i * 3]), Double(a.lab[i * 3 + 1]),
                                            Double(a.lab[i * 3 + 2]), Double(b.lab[i * 3]),
                                            Double(b.lab[i * 3 + 1]), Double(b.lab[i * 3 + 2])))
                }
            }
        }
        let mean = d.reduce(0.0) { $0 + Double($1) } / Double(Swift.max(n, 1))
        let sorted = d.sorted()
        return DeltaE(mean: mean, p95: percentile(sorted, 95), max: Double(sorted.last ?? 0))
    }
}

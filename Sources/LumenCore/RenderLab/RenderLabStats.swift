// RenderLabStats.swift
// Measurements of a delivered 8-bit sRGB frame, and of the change between two frames.
// Both lab backends (shipping on macOS, reference on Linux) measure through this file.

import Foundation

/// An 8-bit sRGB frame, RGBA interleaved, top row first.
public struct RenderLabImage: Sendable {
    public var width: Int
    public var height: Int
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4, "RGBA size mismatch")
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public init(width: Int, height: Int, fill: UInt8) {
        self.init(width: width, height: height,
                  rgba: [UInt8](repeating: fill, count: width * height * 4))
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 }
    }

    /// Encode a display-linear working-space buffer (`ReferenceRenderer` output) the
    /// way `PipelineRenderer.cgImage(from:)` does: primaries to sRGB, clamp, sRGB
    /// transfer, round.
    public init(displayLinear buffer: ImageBuffer, space: RGBColorSpace = .rec2020) {
        let toOutput = space.matrix(to: .srgb)
        var bytes = [UInt8](repeating: 255, count: buffer.width * buffer.height * 4)
        func byte(_ v: Double) -> UInt8 {
            guard v.isFinite else { return 0 }
            return UInt8((Num.saturate(v) * 255).rounded())
        }
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let c = TransferFunction.srgb.encode(toOutput.apply(buffer[x, y]).clamped(0, 1))
                let i = (y * buffer.width + x) * 4
                bytes[i] = byte(c.r)
                bytes[i + 1] = byte(c.g)
                bytes[i + 2] = byte(c.b)
            }
        }
        self.init(width: buffer.width, height: buffer.height, rgba: bytes)
    }
}

/// A rectangle of a chart with a known scene value, in unit coordinates (top-left origin).
public struct RenderLabPatch: Codable, Sendable {
    public var name: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    /// Scene-linear working-space (linear Rec.2020, mid-grey 0.18) value fed in.
    public var scene: [Double]?

    public init(name: String, x: Double, y: Double, w: Double, h: Double, scene: RGB?) {
        self.name = name
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.scene = scene.map { [$0.r, $0.g, $0.b] }
    }
}

public struct RenderLabStats: Codable, Sendable {

    public struct ChannelHistogram: Codable, Sendable {
        public var r: [Int]
        public var g: [Int]
        public var b: [Int]
        /// Relative luminance (from linear sRGB), re-encoded to an sRGB code value.
        public var luma: [Int]
    }

    public struct Luma: Codable, Sendable {
        public var mean: Double
        public var median: Double
        public var p01: Double
        public var p05: Double
        public var p25: Double
        public var p75: Double
        public var p95: Double
        public var p99: Double
        public var stdev: Double
        /// Mean relative luminance Y (linear, 0…1) — doubles when light doubles.
        public var meanLinearY: Double
    }

    public struct Clipping: Codable, Sendable {
        /// Fractions of pixels (0…1).
        public var anyChannelAt0: Double
        public var anyChannelAt255: Double
        public var allChannelsAt0: Double
        public var allChannelsAt255: Double
        public var channelAt0: [Double]
        public var channelAt255: [Double]
    }

    public struct Colour: Codable, Sendable {
        /// OKLab (the codebase's perceptual space, `OKLabTransform`) of the sRGB output.
        public var meanL: Double
        public var meanA: Double
        public var meanB: Double
        public var meanChroma: Double
        public var chromaP95: Double
        /// Fraction of pixels with OKLab chroma above 0.02.
        public var chromaticFraction: Double
        /// 36 bins of 10° (bin 0 = 0…10°), chroma-weighted, normalised to sum 1.
        public var hueHistogram: [Double]
        public var samples: Int
    }

    public struct PatchReadout: Codable, Sendable {
        public var name: String
        public var scene: [Double]?
        /// Mean sRGB code values over the patch's inner 60%.
        public var srgb: [Double]
        /// The same mean, decoded to linear sRGB.
        public var linear: [Double]
        public var linearY: Double
        public var L: Double
        public var C: Double
        public var h: Double
        /// Per-pixel standard deviation of the luma code value: noise, grain, texture.
        public var lumaStdev: Double
    }

    public var width: Int
    public var height: Int
    public var histogram: ChannelHistogram
    public var channelMeans: [Double]
    public var luma: Luma
    public var clipping: Clipping
    public var colour: Colour
    /// Fractions of pixels by luma code: <26, 26–76, 77–178, 179–229, ≥230.
    public var tonalZones: [Double]
    public var patches: [PatchReadout]?

    // MARK: - Tables

    static let linearOfCode: [Double] = (0..<256).map {
        TransferFunction.srgb.decode(Double($0) / 255)
    }
    static let oklab = OKLabTransform.Context(space: .srgb)

    @inline(__always) static func lumaCode(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        let y = 0.2126 * linearOfCode[Int(r)] + 0.7152 * linearOfCode[Int(g)]
            + 0.0722 * linearOfCode[Int(b)]
        return Swift.min(255, Swift.max(0, Int((TransferFunction.srgb.encode(y) * 255).rounded())))
    }

    @inline(__always) static func linearY(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        0.2126 * linearOfCode[Int(r)] + 0.7152 * linearOfCode[Int(g)]
            + 0.0722 * linearOfCode[Int(b)]
    }

    @inline(__always) static func lab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> OKLab {
        oklab.toLab(RGB(linearOfCode[Int(r)], linearOfCode[Int(g)], linearOfCode[Int(b)]))
    }

    /// Stride that keeps per-pixel colour work near `budget` samples.
    static func sampleStep(for count: Int, budget: Int = 300_000) -> Int {
        Swift.max(1, Int((Double(count) / Double(budget)).squareRoot().rounded(.up)))
    }

    static func percentile(_ hist: [Int], _ q: Double) -> Double {
        let total = hist.reduce(0, +)
        guard total > 0 else { return 0 }
        let target = q * Double(total)
        var acc = 0
        for (i, n) in hist.enumerated() {
            acc += n
            if Double(acc) >= target { return Double(i) }
        }
        return 255
    }

    // MARK: - Measure

    public init(_ image: RenderLabImage, patches: [RenderLabPatch]? = nil) {
        let w = image.width, h = image.height, n = w * h
        let px = image.rgba
        var hr = [Int](repeating: 0, count: 256)
        var hg = hr, hb = hr, hl = hr
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumY = 0.0
        var any0 = 0, any255 = 0, all0 = 0, all255 = 0
        var c0 = [0, 0, 0], c255 = [0, 0, 0]
        var zones = [0, 0, 0, 0, 0]
        for i in 0..<n {
            let r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2]
            hr[Int(r)] += 1; hg[Int(g)] += 1; hb[Int(b)] += 1
            let l = Self.lumaCode(r, g, b)
            hl[l] += 1
            sumR += Double(r); sumG += Double(g); sumB += Double(b)
            sumY += Self.linearY(r, g, b)
            if r == 0 { c0[0] += 1 }
            if g == 0 { c0[1] += 1 }
            if b == 0 { c0[2] += 1 }
            if r == 255 { c255[0] += 1 }
            if g == 255 { c255[1] += 1 }
            if b == 255 { c255[2] += 1 }
            if r == 0 || g == 0 || b == 0 { any0 += 1 }
            if r == 255 || g == 255 || b == 255 { any255 += 1 }
            if r == 0 && g == 0 && b == 0 { all0 += 1 }
            if r == 255 && g == 255 && b == 255 { all255 += 1 }
            zones[l < 26 ? 0 : l < 77 ? 1 : l < 179 ? 2 : l < 230 ? 3 : 4] += 1
        }
        let fn = Double(Swift.max(n, 1))
        width = w
        height = h
        histogram = ChannelHistogram(r: hr, g: hg, b: hb, luma: hl)
        channelMeans = [sumR / fn, sumG / fn, sumB / fn]
        var lumaSum = 0.0, lumaSq = 0.0
        for (i, c) in hl.enumerated() {
            lumaSum += Double(i * c)
            lumaSq += Double(i * i * c)
        }
        let mean = lumaSum / fn
        luma = Luma(mean: mean, median: Self.percentile(hl, 0.5),
                    p01: Self.percentile(hl, 0.01), p05: Self.percentile(hl, 0.05),
                    p25: Self.percentile(hl, 0.25), p75: Self.percentile(hl, 0.75),
                    p95: Self.percentile(hl, 0.95), p99: Self.percentile(hl, 0.99),
                    stdev: Swift.max(0, lumaSq / fn - mean * mean).squareRoot(),
                    meanLinearY: sumY / fn)
        clipping = Clipping(anyChannelAt0: Double(any0) / fn,
                            anyChannelAt255: Double(any255) / fn,
                            allChannelsAt0: Double(all0) / fn,
                            allChannelsAt255: Double(all255) / fn,
                            channelAt0: c0.map { Double($0) / fn },
                            channelAt255: c255.map { Double($0) / fn })
        tonalZones = zones.map { Double($0) / fn }

        let step = Self.sampleStep(for: n)
        var sL = 0.0, sA = 0.0, sB = 0.0, sC = 0.0, samples = 0, chromatic = 0
        var hue = [Double](repeating: 0, count: 36)
        var chromaHist = [Int](repeating: 0, count: 256)
        for y in Swift.stride(from: 0, to: h, by: step) {
            for x in Swift.stride(from: 0, to: w, by: step) {
                let i = (y * w + x) * 4
                let lab = Self.lab(px[i], px[i + 1], px[i + 2])
                sL += lab.L; sA += lab.a; sB += lab.b
                let c = lab.chroma
                sC += c
                samples += 1
                chromaHist[Swift.min(255, Int(c * 500))] += 1
                if c > 0.02 {
                    chromatic += 1
                    hue[Swift.min(35, Int(lab.hue / 10))] += c
                }
            }
        }
        let fs = Double(Swift.max(samples, 1))
        let hueTotal = hue.reduce(0, +)
        colour = Colour(meanL: sL / fs, meanA: sA / fs, meanB: sB / fs,
                        meanChroma: sC / fs,
                        chromaP95: Self.percentile(chromaHist, 0.95) / 500,
                        chromaticFraction: Double(chromatic) / fs,
                        hueHistogram: hueTotal > 0 ? hue.map { $0 / hueTotal } : hue,
                        samples: samples)
        self.patches = patches.map { list in list.map { Self.readout($0, image) } }
    }

    static func patchPixels(_ p: RenderLabPatch, _ image: RenderLabImage) -> [Int] {
        let insetW = p.w * 0.2, insetH = p.h * 0.2
        let x0 = Int(((p.x + insetW) * Double(image.width)).rounded())
        let x1 = Int(((p.x + p.w - insetW) * Double(image.width)).rounded())
        let y0 = Int(((p.y + insetH) * Double(image.height)).rounded())
        let y1 = Int(((p.y + p.h - insetH) * Double(image.height)).rounded())
        var out: [Int] = []
        for y in Swift.max(0, y0)..<Swift.max(Swift.max(0, y0) + 1, Swift.min(image.height, y1)) {
            for x in Swift.max(0, x0)..<Swift.max(Swift.max(0, x0) + 1, Swift.min(image.width, x1)) {
                if x < image.width, y < image.height { out.append((y * image.width + x) * 4) }
            }
        }
        return out
    }

    static func readout(_ p: RenderLabPatch, _ image: RenderLabImage) -> PatchReadout {
        let idx = patchPixels(p, image)
        let px = image.rgba
        var s = [0.0, 0.0, 0.0], lin = [0.0, 0.0, 0.0], l = 0.0, l2 = 0.0
        for i in idx {
            for c in 0..<3 {
                s[c] += Double(px[i + c])
                lin[c] += linearOfCode[Int(px[i + c])]
            }
            let code = Double(lumaCode(px[i], px[i + 1], px[i + 2]))
            l += code
            l2 += code * code
        }
        let n = Double(Swift.max(idx.count, 1))
        let linear = lin.map { $0 / n }
        let lab = oklab.toLab(RGB(linear[0], linear[1], linear[2]))
        let ml = l / n
        return PatchReadout(name: p.name, scene: p.scene, srgb: s.map { $0 / n },
                            linear: linear,
                            linearY: 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2],
                            L: lab.L, C: lab.chroma, h: lab.hue,
                            lumaStdev: Swift.max(0, l2 / n - ml * ml).squareRoot())
    }
}

/// How one frame differs from a reference frame of the same size.
public struct RenderLabDelta: Codable, Sendable {

    public struct ToneBand: Codable, Sendable {
        /// Reference luma code range, inclusive lower bound.
        public var from: Int
        public var to: Int
        public var fraction: Double
        /// Mean signed luma change (code values) of the pixels that started in this band.
        public var meanLumaShift: Double
        public var meanAbsChange: Double
    }

    public struct PatchDelta: Codable, Sendable {
        public var name: String
        public var dL: Double
        public var dC: Double
        public var dh: Double
        /// Linear luminance ratio against the reference (2.0 = one stop brighter).
        public var ratioY: Double
    }

    public var comparable: Bool
    public var note: String?
    /// Mean |Δ| over R, G and B, in code values.
    public var meanAbs: Double = 0
    public var maxAbs: Int = 0
    public var p99Abs: Double = 0
    /// Fraction of pixels where any channel moved by more than two code values.
    public var changedFraction: Double = 0
    public var meanLumaShift: Double = 0
    public var meanAbsLumaShift: Double = 0
    /// Linear mean-luminance ratio, frame over reference.
    public var linearYRatio: Double = 1
    public var byTone: [ToneBand] = []
    /// OKLab chroma change, mean signed.
    public var meanChromaShift: Double = 0
    /// Chroma-weighted mean |Δhue| in degrees, over pixels chromatic in both frames.
    public var meanAbsHueShift: Double = 0
    /// Chroma-weighted mean signed Δhue in degrees.
    public var meanHueShift: Double = 0
    /// Fraction of compared samples that were chromatic in both frames.
    public var hueSampleFraction: Double = 0
    public var patches: [PatchDelta]?
    /// Median `ratioY` over the chart's patches, when there are patches.
    public var patchRatioMedian: Double?

    public init(_ image: RenderLabImage, against ref: RenderLabImage,
                patches: [RenderLabPatch]? = nil) {
        guard image.width == ref.width, image.height == ref.height else {
            comparable = false
            note = "sizes differ: \(image.width)x\(image.height) vs \(ref.width)x\(ref.height)"
            return
        }
        comparable = true
        let n = image.width * image.height
        let a = image.rgba, b = ref.rgba
        var absHist = [Int](repeating: 0, count: 256)
        var sumAbs = 0, maxAbs = 0, changed = 0
        var sumL = 0.0, sumAbsL = 0.0, yA = 0.0, yB = 0.0
        let bands = [(0, 63), (64, 127), (128, 191), (192, 255)]
        var bandCount = [0, 0, 0, 0]
        var bandShift = [0.0, 0.0, 0.0, 0.0]
        var bandAbs = [0.0, 0.0, 0.0, 0.0]
        for i in 0..<n {
            let o = i * 4
            var pixelMax = 0
            for c in 0..<3 {
                let d = abs(Int(a[o + c]) - Int(b[o + c]))
                absHist[d] += 1
                sumAbs += d
                if d > pixelMax { pixelMax = d }
            }
            if pixelMax > maxAbs { maxAbs = pixelMax }
            if pixelMax > 2 { changed += 1 }
            let la = RenderLabStats.lumaCode(a[o], a[o + 1], a[o + 2])
            let lb = RenderLabStats.lumaCode(b[o], b[o + 1], b[o + 2])
            let dl = Double(la - lb)
            sumL += dl
            sumAbsL += abs(dl)
            yA += RenderLabStats.linearY(a[o], a[o + 1], a[o + 2])
            yB += RenderLabStats.linearY(b[o], b[o + 1], b[o + 2])
            let band = Swift.min(3, lb / 64)
            bandCount[band] += 1
            bandShift[band] += dl
            bandAbs[band] += abs(dl)
        }
        let fn = Double(Swift.max(n, 1))
        self.meanAbs = Double(sumAbs) / (3 * fn)
        self.maxAbs = maxAbs
        self.p99Abs = RenderLabStats.percentile(absHist, 0.99)
        self.changedFraction = Double(changed) / fn
        self.meanLumaShift = sumL / fn
        self.meanAbsLumaShift = sumAbsL / fn
        self.linearYRatio = yB > 0 ? yA / yB : 1
        self.byTone = bands.enumerated().map { k, r in
            let c = Double(Swift.max(bandCount[k], 1))
            return ToneBand(from: r.0, to: r.1, fraction: Double(bandCount[k]) / fn,
                            meanLumaShift: bandCount[k] > 0 ? bandShift[k] / c : 0,
                            meanAbsChange: bandCount[k] > 0 ? bandAbs[k] / c : 0)
        }

        let step = RenderLabStats.sampleStep(for: n)
        var dC = 0.0, samples = 0, hueW = 0.0, hueAbs = 0.0, hueSigned = 0.0, hueN = 0
        for y in Swift.stride(from: 0, to: image.height, by: step) {
            for x in Swift.stride(from: 0, to: image.width, by: step) {
                let o = (y * image.width + x) * 4
                let la = RenderLabStats.lab(a[o], a[o + 1], a[o + 2])
                let lb = RenderLabStats.lab(b[o], b[o + 1], b[o + 2])
                dC += la.chroma - lb.chroma
                samples += 1
                if la.chroma > 0.02, lb.chroma > 0.02 {
                    let w = Swift.min(la.chroma, lb.chroma)
                    let dh = Num.hueDelta(lb.hue, la.hue)
                    hueAbs += abs(dh) * w
                    hueSigned += dh * w
                    hueW += w
                    hueN += 1
                }
            }
        }
        let fs = Double(Swift.max(samples, 1))
        self.meanChromaShift = dC / fs
        self.meanAbsHueShift = hueW > 0 ? hueAbs / hueW : 0
        self.meanHueShift = hueW > 0 ? hueSigned / hueW : 0
        self.hueSampleFraction = Double(hueN) / fs

        if let patches, !patches.isEmpty {
            var ratios: [Double] = []
            self.patches = patches.map { p in
                let ra = RenderLabStats.readout(p, image)
                let rb = RenderLabStats.readout(p, ref)
                let ratio = rb.linearY > 1e-6 ? ra.linearY / rb.linearY : 0
                if rb.linearY > 1e-4, rb.linearY < 0.95 { ratios.append(ratio) }
                let chromatic = ra.C > 0.02 && rb.C > 0.02
                return PatchDelta(name: p.name, dL: ra.L - rb.L, dC: ra.C - rb.C,
                                  dh: chromatic ? Num.hueDelta(rb.h, ra.h) : 0,
                                  ratioY: ratio)
            }
            ratios.sort()
            self.patchRatioMedian = ratios.isEmpty ? nil : ratios[ratios.count / 2]
        }
    }
}

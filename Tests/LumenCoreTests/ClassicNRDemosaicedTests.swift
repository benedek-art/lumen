// ClassicNRDemosaicedTests.swift
// WS-19/20 acceptance lines that can be checked without the corpus: Tier 1 on frames
// that went through a mosaic and a demosaic, which is what every frame S3 sees did.
//
// DenoiseTests' frames carry white noise per pixel, and white noise is what hid the
// calibration defect this file pins: a demosaic interpolates two thirds of every
// channel, so noise leaves the finest band and piles up at 2–8 px, where thresholds
// denominated in white-noise σ never reached it. Here the noise is drawn per PHOTOSITE
// from the profile and then demosaiced (bilinear, RGGB), so the band structure is a
// demosaic's. Bilinear is not AHD and not Apple's, which is why the corpus numbers live
// in the lane's SPEC and these tests assert the shape of each claim with margin.

import XCTest
@testable import LumenCore

final class ClassicNRDemosaicedTests: XCTestCase {

    // MARK: - Frames

    private static func gaussian(x: Int, y: Int, seed: UInt64) -> Double {
        func mix(_ v: UInt64) -> UInt64 {
            var z = v &+ 0x9E3779B97F4A7C15
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        let base = mix(seed &+ UInt64(bitPattern: Int64(x &* 73_856_093))
                       &+ UInt64(bitPattern: Int64(y &* 19_349_663)))
        let u1 = Double(base >> 11) / Double(1 << 53)
        let u2 = Double(mix(base) >> 11) / Double(1 << 53)
        let r = (-2 * Foundation.log(Swift.max(u1, 1e-12))).squareRoot()
        return r * Foundation.cos(2 * Double.pi * u2)
    }

    /// RGGB site colour of a photosite.
    private static func site(_ x: Int, _ y: Int) -> Int {
        switch (y & 1, x & 1) {
        case (0, 0): return 0
        case (1, 1): return 2
        default: return 1
        }
    }

    /// Sample `scene` onto an RGGB mosaic, add per-photosite Poisson–Gaussian noise from
    /// `profile` (none when nil), apply `defect` to the raw values, and demosaic
    /// bilinearly.
    private func demosaiced(_ scene: (Int, Int) -> RGB, width: Int, height: Int,
                            profile: NoiseProfile?, seed: UInt64 = 0xC0FFEE,
                            defect: ((Int, Int, Double) -> Double)? = nil) -> ImageBuffer {
        var raw = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var v = scene(x, y)[Self.site(x, y)]
                if let profile {
                    v += Self.gaussian(x: x, y: y, seed: seed) * profile.sigma(at: v)
                }
                if let defect { v = defect(x, y, v) }
                raw[y * width + x] = v
            }
        }
        func at(_ x: Int, _ y: Int) -> Double {
            raw[Swift.min(Swift.max(y, 0), height - 1) * width
                + Swift.min(Swift.max(x, 0), width - 1)]
        }
        var out = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                var c = RGB.zero
                for ch in 0..<3 {
                    if Self.site(x, y) == ch { c[ch] = at(x, y); continue }
                    var sum = 0.0
                    var n = 0.0
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let sx = Swift.min(Swift.max(x + dx, 0), width - 1)
                            let sy = Swift.min(Swift.max(y + dy, 0), height - 1)
                            if Self.site(sx, sy) == ch && (ch != 1 || dx == 0 || dy == 0) {
                                sum += at(sx, sy)
                                n += 1
                            }
                        }
                    }
                    c[ch] = n > 0 ? sum / n : 0
                }
                out[x, y] = c
            }
        }
        return out
    }

    private func engine(_ params: ClassicNR, iso: Double = 3200) -> ClassicalDenoise {
        ClassicalDenoise(params, profile: NoiseProfile.forISO(iso))
    }

    /// The colour axes the engine shrinks along, in linear light: u and v' of
    /// `toY0U0V0` applied to the linear values (exactly what a chroma-only operation
    /// may move), and Rec.2020 luminance (what it may not).
    private func chroma(_ c: RGB) -> (u: Double, v: Double) {
        let d = ClassicalDenoise.toY0U0V0.apply(c)
        return (d.g, d.b)
    }

    private func luminance(_ c: RGB) -> Double {
        RGBColorSpace.rec2020.luminance(c)
    }

    // MARK: - 19.2 Colour noise vanishes at the default

    /// Colour at its default (25, Detail 50, Smoothness 50) on a demosaiced ISO-3200
    /// grey field must take out at least 70 % of the chroma noise. The shipped
    /// white-noise thresholds left about half of it, which is the colour mottle the
    /// owner saw on every high-ISO frame.
    func testColourDefaultRemovesDemosaicedChromaNoise() {
        let profile = NoiseProfile.forISO(3200)
        let w = 128, h = 128
        let noisy = demosaiced({ _, _ in RGB(gray: 0.18) }, width: w, height: h,
                               profile: profile)
        func chromaSigma(_ image: ImageBuffer) -> Double {
            var acc = 0.0
            var n = 0.0
            for y in 16..<(h - 16) {
                for x in 16..<(w - 16) {
                    let c = chroma(image[x, y])
                    acc += c.u * c.u + c.v * c.v
                    n += 1
                }
            }
            return (acc / n).squareRoot()
        }
        let before = chromaSigma(noisy)
        XCTAssertGreaterThan(before, 1e-3, "the frame carries no chroma noise")
        let out = engine(ISODefaults.classic(forISO: 3200)).apply(noisy)
        let after = chromaSigma(out)
        XCTAssertLessThan(after, before * 0.30,
                          "the ISO-3200 default left \(after / before) of the demosaiced "
                              + "chroma noise")
    }

    // MARK: - 19.3 …without bleeding at edges

    /// An equal-luminance red/blue step (only a chroma operation can move it) plus a
    /// 2 px colour line, demosaiced with and without noise. At the default the step's
    /// 10–90 % transition must not widen by more than a pixel against the noise-free
    /// twin, and the line must keep at least 70 % of its contrast.
    func testColourDefaultDoesNotBleedAnEqualLuminanceEdge() {
        let profile = NoiseProfile.forISO(3200)
        let w = 160, h = 96
        // Two colours of equal Rec.2020 luminance.
        let weights = RGBColorSpace.rec2020.luminanceWeights
        let warm = RGB(0.30, 0.12, 0.10)
        let coolBase = RGB(0.10, 0.12, 0.40)
        let scaleCool = luminance(warm) / luminance(coolBase)
        let cool = coolBase * scaleCool
        XCTAssertEqual(weights.r * warm.r + weights.g * warm.g + weights.b * warm.b,
                       luminance(cool), accuracy: 1e-12)
        let scene: (Int, Int) -> RGB = { x, _ in
            if x >= 110 && x < 112 { return warm }       // the 2 px line on cool ground
            return x < 60 ? warm : cool
        }
        let clean = demosaiced(scene, width: w, height: h, profile: nil)
        let noisy = demosaiced(scene, width: w, height: h, profile: profile)
        let out = engine(ISODefaults.classic(forISO: 3200)).apply(noisy)

        // Column profile of u, averaged over the middle rows.
        func column(_ image: ImageBuffer) -> [Double] {
            (0..<w).map { x in
                var s = 0.0
                for y in 24..<(h - 24) { s += chroma(image[x, y]).u }
                return s / Double(h - 48)
            }
        }
        let c = column(clean)
        let o = column(out)
        func width10to90(_ p: [Double]) -> Double {
            let lo = p[40...50].reduce(0, +) / 11
            let hi = p[70...80].reduce(0, +) / 11
            func crossing(_ f: Double) -> Double {
                let level = lo + f * (hi - lo)
                for x in 50..<70 {
                    let a = p[x] - level
                    let b = p[x + 1] - level
                    if a == 0 { return Double(x) }
                    if (a < 0) != (b < 0) { return Double(x) + a / (a - b) }
                }
                return .nan
            }
            return abs(crossing(0.9) - crossing(0.1))
        }
        let cleanWidth = width10to90(c)
        let outWidth = width10to90(o)
        XCTAssertTrue(cleanWidth.isFinite && outWidth.isFinite,
                      "could not locate the step: \(cleanWidth), \(outWidth)")
        XCTAssertLessThanOrEqual(outWidth, cleanWidth + 1.0,
                                 "the default widened an equal-luminance colour edge from "
                                     + "\(cleanWidth) px to \(outWidth) px")

        let ground = c[95...105].reduce(0, +) / 11
        let groundOut = o[95...105].reduce(0, +) / 11
        let lineClean = abs(c[110] + c[111] - 2 * ground) / 2
        let lineOut = abs(o[110] + o[111] - 2 * groundOut) / 2
        XCTAssertGreaterThan(lineOut, lineClean * 0.70,
                             "the default kept \(lineOut / lineClean) of a 2 px colour "
                                 + "line's contrast")
    }

    // MARK: - 19.4 Colour NR leaves luminance alone

    /// Colour alone must not move luminance. With the old equal-weight basis, zeroing
    /// chroma detail traded red against blue and Lab L* with it (4 % of fine texture on
    /// the A7 IV sim). In the oblique basis the luma plane is untouched in VST space, so
    /// what reaches linear luminance is only the inverse transform's curvature: here
    /// the luminance change must stay under a tenth of the chroma change.
    func testColourAloneLeavesLuminanceAlone() {
        let profile = NoiseProfile.forISO(3200)
        let w = 96, h = 96
        // Textured colour so there is chroma detail to remove and luminance detail to
        // lose.
        let scene: (Int, Int) -> RGB = { x, y in
            let t = 0.5 + 0.5 * Foundation.sin(Double(x) * 0.7) * Foundation.cos(Double(y) * 0.5)
            return RGB(0.10 + 0.20 * t, 0.15 + 0.05 * t, 0.25 - 0.15 * t)
        }
        let noisy = demosaiced(scene, width: w, height: h, profile: profile)
        let out = engine(ClassicNR(luma: 0, chroma: 25)).apply(noisy)
        var dl = 0.0
        var dc = 0.0
        for y in 16..<(h - 16) {
            for x in 16..<(w - 16) {
                let l = luminance(out[x, y]) - luminance(noisy[x, y])
                let a = chroma(out[x, y])
                let b = chroma(noisy[x, y])
                dl += l * l
                dc += (a.u - b.u) * (a.u - b.u) + (a.v - b.v) * (a.v - b.v)
            }
        }
        XCTAssertGreaterThan(dc, 0, "Colour 25 moved no chroma at all")
        XCTAssertLessThan(dl.squareRoot(), 0.10 * dc.squareRoot(),
                          "Colour alone moved luminance by \(dl.squareRoot()) against a "
                              + "chroma change of \(dc.squareRoot())")
    }

    /// The basis pair is an exact inverse, and the chroma rows see no luminance: a
    /// change along (1,1,1) moves only the first coordinate, and the first coordinate
    /// IS Rec.2020 luminance (weights normalised to sum 1).
    func testTheBasisIsAnExactInverseWithALuminanceFreeChromaPlane() {
        let f = ClassicalDenoise.toY0U0V0
        let i = ClassicalDenoise.fromY0U0V0
        let product = f * i
        XCTAssertLessThan(product.maxAbsDifference(.identity), 1e-12)
        let grey = f.apply(RGB(1, 1, 1))
        XCTAssertEqual(grey.r, 1, accuracy: 1e-12)
        XCTAssertEqual(grey.g, 0, accuracy: 1e-12)
        XCTAssertEqual(grey.b, 0, accuracy: 1e-12)
        let wts = RGBColorSpace.rec2020.luminanceWeights
        let sum = wts.r + wts.g + wts.b
        for c in [RGB(0.3, 0.1, 0.05), RGB(0.02, 0.5, 0.2), RGB(0.7, 0.7, 0.9)] {
            XCTAssertEqual(f.apply(c).r, (wts.r * c.r + wts.g * c.g + wts.b * c.b) / sum,
                           accuracy: 1e-12)
            // A chroma-only edit (u, v' changed, y kept) leaves luminance where it was.
            var d = f.apply(c)
            d.g += 0.05
            d.b -= 0.03
            let back = i.apply(d)
            XCTAssertEqual(RGBColorSpace.rec2020.luminance(back),
                           RGBColorSpace.rec2020.luminance(c), accuracy: 1e-12)
        }
    }

    // MARK: - 19.6 / 19.7 Luminance and its Detail on a demosaiced frame

    /// Luminance must keep removing more luma noise through its whole useful range on
    /// demosaiced noise — the shipped curve flattened out because it never reached the
    /// 2–8 px bands — and Detail must keep its authority.
    func testLuminanceReachesDemosaicedMottle() {
        let profile = NoiseProfile.forISO(3200)
        let w = 128, h = 128
        let noisy = demosaiced({ _, _ in RGB(gray: 0.18) }, width: w, height: h,
                               profile: profile)
        func lumaSigma(_ image: ImageBuffer) -> Double {
            var values: [Double] = []
            for y in 16..<(h - 16) {
                for x in 16..<(w - 16) { values.append(luminance(image[x, y])) }
            }
            let mean = values.reduce(0, +) / Double(values.count)
            return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                        / Double(values.count)).squareRoot()
        }
        let before = lumaSigma(noisy)
        var previous = before
        for slider in [10.0, 25.0, 50.0, 75.0] {
            let s = lumaSigma(engine(ClassicNR(luma: slider, chroma: 0)).apply(noisy))
            XCTAssertLessThan(s, previous,
                              "Luminance \(slider) removed no more than the step below")
            previous = s
        }
        XCTAssertLessThan(previous, before * 0.35,
                          "Luminance 75 left \(previous / before) of demosaiced luma noise")
        let strict = lumaSigma(engine(ClassicNR(luma: 50, chroma: 0, lumaDetail: 0))
            .apply(noisy))
        let loose = lumaSigma(engine(ClassicNR(luma: 50, chroma: 0, lumaDetail: 100))
            .apply(noisy))
        XCTAssertGreaterThan(loose, strict * 1.5,
                             "Luminance Detail 0→100 kept only \(loose / strict)× the noise")
    }

    // MARK: - WS-20 Hot pixels on a demosaiced frame

    /// Single-photosite defects on a red, a green and a blue site, a Gaussian star
    /// (σ 1 px) and a 2 px specular disc, all through the same demosaic on an ISO-3200
    /// field. Hot Pixels 50: each defect's smear left at ≤ 30 % of its peak; the star
    /// and the disc keep ≥ 90 % of theirs.
    func testHotPixelsRemoveDemosaicedDefectsAndKeepStarsAndSpeculars() {
        let profile = NoiseProfile.forISO(3200)
        let w = 96, h = 96
        let defects = [(20, 20), (41, 20), (61, 21)]   // R site, G site, B site
        for (index, d) in defects.enumerated() {
            XCTAssertEqual(Self.site(d.0, d.1), index, "defect \(d) is not on site \(index)")
        }
        let star = (30, 60)
        let spec = (70, 60)
        let base: (Int, Int) -> RGB = { _, _ in RGB(gray: 0.10) }
        let featured: (Int, Int) -> RGB = { x, y in
            var c = RGB(gray: 0.10)
            let ds = Double((x - star.0) * (x - star.0) + (y - star.1) * (y - star.1))
            c = c + RGB(gray: 0.8 * Foundation.exp(-ds / 2))
            let dd = Double((x - spec.0) * (x - spec.0) + (y - spec.1) * (y - spec.1))
                .squareRoot()
            c = c + RGB(gray: 1.5 * Num.saturate(2.5 - dd))
            return c
        }
        let hot: (Int, Int, Double) -> Double = { x, y, v in
            defects.contains { $0 == (x, y) } ? v + 0.6 : v
        }
        let plain = demosaiced(base, width: w, height: h, profile: profile)
        let scene = demosaiced(featured, width: w, height: h, profile: profile, defect: hot)
        let clean = demosaiced(featured, width: w, height: h, profile: profile)
        let pass = engine(ClassicNR(luma: 0, chroma: 0, hotPixels: 50))
        let out = pass.apply(scene)
        let outClean = pass.apply(clean)

        func peak(_ a: ImageBuffer, _ b: ImageBuffer, around p: (Int, Int)) -> Double {
            var m = 0.0
            for y in (p.1 - 2)...(p.1 + 2) {
                for x in (p.0 - 2)...(p.0 + 2) {
                    m = Swift.max(m, (a[x, y] - b[x, y]).maxComponent)
                }
            }
            return m
        }
        for d in defects {
            let before = peak(scene, clean, around: d)
            let after = peak(out, outClean, around: d)
            XCTAssertGreaterThan(before, 0.1, "defect at \(d) did not register")
            XCTAssertLessThan(after, before * 0.30,
                              "defect at \(d) kept \(after / before) of its peak")
        }
        for (name, p) in [("star", star), ("specular", spec)] {
            let before = peak(clean, plain, around: p)
            let after = peak(outClean, pass.apply(plain), around: p)
            XCTAssertGreaterThan(after, before * 0.90,
                                 "the \(name) kept \(after / before) of its peak")
        }
    }

    /// Plain demosaiced noise is not a defect: Hot Pixels 50 changes almost nothing,
    /// Hot Pixels 0 changes nothing, and the count never falls as the slider rises.
    func testHotPixelsLeavePlainNoiseAloneAndGrowMonotonically() {
        let profile = NoiseProfile.forISO(3200)
        let w = 128, h = 128
        let noisy = demosaiced({ x, y in
            RGB(gray: 0.05 + 0.25 * Double(x + y) / Double(w + h))
        }, width: w, height: h, profile: profile, seed: 0xBEEF)
        func changed(_ slider: Double) -> Int {
            let out = engine(ClassicNR(luma: 0, chroma: 0, hotPixels: slider)).apply(noisy)
            var n = 0
            for y in 0..<h {
                for x in 0..<w where out[x, y] != noisy[x, y] { n += 1 }
            }
            return n
        }
        XCTAssertEqual(changed(0), 0, "Hot Pixels 0 changed pixels")
        var previous = 0
        for slider in [25.0, 50.0, 75.0, 100.0] {
            let n = changed(slider)
            XCTAssertGreaterThanOrEqual(n, previous,
                                        "Hot Pixels \(slider) changed fewer pixels than "
                                            + "the step below it")
            previous = n
            if slider == 50 {
                XCTAssertLessThanOrEqual(Double(n), 0.001 * Double(w * h),
                                         "Hot Pixels 50 changed \(n) plain-noise pixels")
            }
        }
        XCTAssertLessThanOrEqual(Double(previous), 0.01 * Double(w * h),
                                 "Hot Pixels 100 changed \(previous) plain-noise pixels")
    }
}

// PresenceBandTests.swift
// WS-14 Texture & Clarity, the unit half of docs/quality/lanes/WS-14/SPEC.md §12 (U1–U10).
//
// Each test drives the presence stage the way `ReferenceRenderer` does — a
// `Decomposition` built at `max(Int(0.02·L), 3)`, then `DetailEngine.apply` — on a
// synthetic strip whose long edge sets the scales (every presence σ is a fraction of
// the long edge) and whose short edge keeps it cheap. Amplitudes are read on log2 Y.
//
// Spec U11: each test runs in ≤ 5 s and the suite in ≤ 30 s in a debug build. The
// long-edge-dependent probes keep their long edge (6000 px strips) and carry as few
// rows as the measurement needs — 8 for the x-only sinusoids — and the slider sweeps
// reuse one decomposition per frame.

import Foundation
import XCTest
@testable import LumenCore

final class PresenceBandTests: XCTestCase {

    // MARK: - Helpers

    /// A grey frame from a per-pixel luminance function.
    private func grey(_ width: Int, _ height: Int,
                      _ y: (Int, Int) -> Double) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for row in 0..<height {
            for x in 0..<width { image[x, row] = RGB(gray: y(x, row)) }
        }
        return image
    }

    private func node(_ image: ImageBuffer) -> DetailEngine.Decomposition {
        let longEdge = Swift.max(image.width, image.height)
        return DetailEngine.Decomposition(
            image: image, workingRadius: Swift.max(Int(Double(longEdge) * 0.02), 3))
    }

    /// `ReferenceRenderer`'s S8, on a decomposition built once per frame (the
    /// decomposition is a function of the image alone, so a slider sweep reuses it).
    private func render(_ image: ImageBuffer, texture: Double = 0, clarity: Double = 0,
                        dehaze: Double = 0,
                        node given: DetailEngine.Decomposition? = nil) -> ImageBuffer {
        let node = given ?? self.node(image)
        var detail = Detail()
        detail.texture = texture
        detail.clarity = clarity
        detail.dehaze = dehaze
        return DetailEngine.apply(image, detail: detail, decomposition: node)
    }

    private func log2Y(_ image: ImageBuffer) -> Plane {
        image.luminancePlane(space: .rec2020).map { log2(Swift.max($0, 1e-9)) }
    }

    /// Deterministic uniform noise in [-0.5, 0.5).
    private struct LCGNoise {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) - 0.5
        }
        mutating func gaussian() -> Double {
            var s = 0.0
            for _ in 0..<12 { s += next() }
            return s
        }
    }

    /// Approximately 1/f log-luminance texture: octaves of bilinearly interpolated
    /// random grids at equal amplitude (equal energy per octave, which is 1/f in 2-D),
    /// normalised to `std` EV.
    private func pinkLog(_ width: Int, _ height: Int, std: Double, seed: UInt64) -> Plane {
        var field = Plane(width: width, height: height)
        var noise = LCGNoise(state: seed)
        var cell = 2.0
        while cell < Double(Swift.max(width, height)) / 2 {
            let gw = Int(Double(width) / cell) + 2
            let gh = Int(Double(height) / cell) + 2
            var grid = [Double](repeating: 0, count: gw * gh)
            for i in grid.indices { grid[i] = noise.next() }
            for y in 0..<height {
                let fy = Double(y) / cell
                let y0 = Int(fy), ty = fy - Double(y0)
                for x in 0..<width {
                    let fx = Double(x) / cell
                    let x0 = Int(fx), tx = fx - Double(x0)
                    let a = grid[y0 * gw + x0] * (1 - tx) + grid[y0 * gw + x0 + 1] * tx
                    let b = grid[(y0 + 1) * gw + x0] * (1 - tx)
                        + grid[(y0 + 1) * gw + x0 + 1] * tx
                    field[x, y] = field[x, y] + (a * (1 - ty) + b * ty)
                }
            }
            cell *= 2
        }
        let mean = field.mean
        var variance = 0.0
        for v in field.values { variance += (Double(v) - mean) * (Double(v) - mean) }
        let scale = std / Swift.max((variance / Double(field.values.count)).squareRoot(), 1e-12)
        return field.map { ($0 - mean) * scale }
    }

    /// A log-sinusoid along x on an 8 px strip, and its decomposition.
    private func sinusoid(longEdge: Int, period: Double,
                          amplitude: Double = 0.05) -> (ImageBuffer, DetailEngine.Decomposition) {
        let input = grey(longEdge, 8) { x, _ in
            0.18 * pow(2.0, amplitude * cos(2 * Double.pi * Double(x) / period))
        }
        return (input, node(input))
    }

    /// Gain of a log-sinusoid: the projection of the output's log2 Y onto the input's
    /// along the middle row, over the central half of the strip.
    private func gain(_ probe: (ImageBuffer, DetailEngine.Decomposition),
                      texture: Double = 0, clarity: Double = 0) -> Double {
        let (input, n) = probe
        let output = render(input, texture: texture, clarity: clarity, node: n)
        let a = log2Y(input), b = log2Y(output)
        let w = input.width, row = input.height / 2
        let x0 = w / 4, x1 = 3 * w / 4
        var meanA = 0.0, meanB = 0.0
        for x in x0..<x1 { meanA += a[x, row]; meanB += b[x, row] }
        meanA /= Double(x1 - x0); meanB /= Double(x1 - x0)
        var num = 0.0, den = 0.0
        for x in x0..<x1 {
            num += (b[x, row] - meanB) * (a[x, row] - meanA)
            den += (a[x, row] - meanA) * (a[x, row] - meanA)
        }
        return num / Swift.max(den, 1e-12)
    }

    // MARK: - U1 (M5): zero is an exact identity

    func testZeroIsABitExactIdentityAlsoWithDehaze() {
        let input = grey(512, 64) { x, y in
            0.18 * pow(2.0, 0.3 * sin(Double(x) * 0.37) * cos(Double(y) * 0.21))
        }
        let out = render(input)
        XCTAssertEqual(out.pixels, input.pixels, "texture = clarity = 0 moved a pixel")

        // With Dehaze on, presence at 0 must leave exactly Dehaze's own picture.
        let node = DetailEngine.Decomposition(image: input, workingRadius: 10)
        var detail = Detail()
        detail.dehaze = 25
        let both = DetailEngine.apply(input, detail: detail, decomposition: node)
        let dehazeOnly = DetailEngine.applyDehaze(input, amount: 25, decomposition: node)
        XCTAssertEqual(both.pixels, dehazeOnly.pixels,
                       "texture = clarity = 0 changed Dehaze's result")
    }

    // MARK: - U2 (S1, S4, S5, S6): where each control acts

    func testEachControlActsInItsOwnBandAt24Megapixels() {
        let t8 = gain(sinusoid(longEdge: 6000, period: 8), texture: 100)
        let t64 = gain(sinusoid(longEdge: 6000, period: 64), texture: 100)
        XCTAssertGreaterThanOrEqual(t8, 1.5, "Texture +100 at an 8 px period: \(t8)")
        XCTAssertLessThanOrEqual(t64, 1.15, "Texture +100 at a 64 px period: \(t64)")

        let c100 = gain(sinusoid(longEdge: 6000, period: 100), clarity: 100)
        XCTAssertGreaterThanOrEqual(c100, 1.3, "Clarity +100 at a 100 px period: \(c100)")
        for period in [3.0, 4.0] {
            let g = gain(sinusoid(longEdge: 6000, period: period), clarity: 100)
            XCTAssertLessThanOrEqual(g, 1.15, "Clarity +100 at a \(period) px period: \(g)")
        }
    }

    // MARK: - U3 (M1, M4): monotone slider, no sign flip at any size

    func testBandCentreGainIsMonotoneAndNegativeNeverFlipsSign() {
        let values: [Double] = [-100, -50, -25, 25, 50, 100]
        for longEdge in [512, 1024, 6000] {
            // The band centre where it is representable; at a small preview the finest
            // period the frame can carry (2.5 px), which is where the band is.
            let tProbe = sinusoid(longEdge: longEdge,
                                  period: Swift.max(Double(longEdge) / 750, 2.5))
            let cProbe = sinusoid(longEdge: longEdge, period: Double(longEdge) / 60)
            var t: [Double] = [], c: [Double] = []
            for v in values {
                t.append(gain(tProbe, texture: v))
                c.append(gain(cProbe, clarity: v))
            }
            t.insert(1, at: 3)
            c.insert(1, at: 3)
            for i in 1..<t.count {
                XCTAssertGreaterThan(t[i], t[i - 1], "Texture at \(longEdge) px: \(t)")
                XCTAssertGreaterThan(c[i], c[i - 1], "Clarity at \(longEdge) px: \(c)")
            }
            // −100 at every period down to Nyquist keeps the sign.
            for period in [2.0, 3.0, 4.0, 8.0, 16.0, 32.0] {
                let probe = sinusoid(longEdge: longEdge, period: period)
                let gT = gain(probe, texture: -100)
                let gC = gain(probe, clarity: -100)
                XCTAssertGreaterThanOrEqual(gT, 0, "Texture -100, \(period) px @ \(longEdge)")
                XCTAssertGreaterThanOrEqual(gC, 0, "Clarity -100, \(period) px @ \(longEdge)")
            }
        }
    }

    // MARK: - U4 (B1/B2): brightness

    func testNeitherControlMovesTheMeanBrightness() {
        let field = pinkLog(1024, 64, std: 0.25, seed: 4)
        let input = grey(1024, 64) { x, y in 0.18 * pow(2.0, field[x, y]) }
        func encodedMean(_ image: ImageBuffer) -> Double {
            let lum = image.luminancePlane(space: .rec2020)
            var s = 0.0
            for v in lum.values {
                s += TransferFunction.srgb.encode(Num.saturate(Double(v)))
            }
            return s / Double(lum.values.count)
        }
        let before = encodedMean(input)
        let n = node(input)
        for (t, c) in [(100.0, 0.0), (-100, 0), (0, 100), (0, -100)] {
            let after = encodedMean(render(input, texture: t, clarity: c, node: n))
            XCTAssertEqual(after, before, accuracy: 0.002,
                           "texture \(t) clarity \(c) moved the encoded mean")
        }
    }

    // MARK: - U5 (H1, H3, H4): no rim, no blur on a clean step

    func testCleanStepsGetNoRimAndNoBlur() {
        for stepEV in [0.5, 1.0] {
            let input = grey(2048, 8) { x, _ in
                0.18 * pow(2.0, x < 1024 ? -stepEV / 2 : stepEV / 2)
            }
            func profile(_ image: ImageBuffer) -> [Double] {
                let lum = image.luminancePlane(space: .rec2020)
                return (0..<2048).map { TransferFunction.srgb.encode(Num.saturate(lum[$0, 4])) }
            }
            let p0 = profile(input)
            let n = node(input)
            let step = p0[1100] - p0[900]
            for (t, c, bar) in [(100.0, 0.0, 0.06), (50, 0, 0.06), (-100, 0, 0.06),
                                (0, 100, 0.08), (0, 50, 0.08), (0, -100, 0.08)] {
                let p = profile(render(input, texture: t, clarity: c, node: n))
                var over = 0.0, under = 0.0
                for x in 1024..<2048 { over = Swift.max(over, p[x] - p0[x]) }
                for x in 0..<1024 { under = Swift.max(under, p0[x] - p[x]) }
                XCTAssertLessThanOrEqual(over / step, bar,
                                         "\(stepEV) EV step, t \(t) c \(c): over \(over / step)")
                XCTAssertLessThanOrEqual(under / step, bar,
                                         "\(stepEV) EV step, t \(t) c \(c): under \(under / step)")
            }
            func rise(_ p: [Double]) -> Int {
                let lo = p[800], hi = p[1250]
                let x10 = (900..<1150).first { (p[$0] - lo) / (hi - lo) > 0.1 } ?? 0
                let x90 = (900..<1150).first { (p[$0] - lo) / (hi - lo) > 0.9 } ?? 0
                return x90 - x10
            }
            let grown = rise(profile(render(input, texture: -100, node: n))) - rise(p0)
            XCTAssertLessThanOrEqual(grown, 1, "Texture -100 blurred a \(stepEV) EV step")
        }
    }

    // MARK: - U6 (Q1, H7): a soft blob stays soft and gets no ring

    func testASoftBlobGetsNoPlateauAndNoRing() {
        let cx = 1024, cy = 84, sigma = 20.0
        let input = grey(2048, 168) { x, y in
            let r2 = Double((x - cx) * (x - cx) + (y - cy) * (y - cy))
            return 0.18 * pow(2.0, exp(-r2 / (2 * sigma * sigma)))
        }
        let a = log2Y(input), b = log2Y(render(input, clarity: 100))
        let reach = Int(4 * sigma)
        let p0 = (0...reach).map { a[cx + $0, cy] }
        let p1 = (0...reach).map { b[cx + $0, cy] }
        var slope0 = 0.0, slope1 = 0.0
        for i in 0..<reach {
            slope0 = Swift.max(slope0, abs(p0[i + 1] - p0[i]))
            slope1 = Swift.max(slope1, abs(p1[i + 1] - p1[i]))
        }
        XCTAssertLessThanOrEqual(slope1 / slope0, 2.2, "Clarity +100 steepened a soft blob")
        var lowest = p1[0], ring = 0.0
        for v in p1 {
            lowest = Swift.min(lowest, v)
            ring = Swift.max(ring, v - lowest)
        }
        XCTAssertLessThanOrEqual(ring / (p0[0] - p0[reach]), 0.03,
                                 "Clarity +100 put a ring round a soft blob")
    }

    // MARK: - U7 (Q2, Q3): smooth over tone, no global range dependence

    func testClarityIsSmoothOverToneAndIgnoresOneBlackPixel() {
        let width = 1024, height = 64
        // Mid-scale texture (box-smoothed noise, 0.1 EV) on a -5…+3 EV log ramp.
        var noise = LCGNoise(state: 7)
        var raw = Plane(width: width, height: height)
        for i in raw.values.indices { raw.values[i] = Float(noise.gaussian()) }
        let smooth = SpatialOps.boxBlur(SpatialOps.boxBlur(raw, radius: 3), radius: 3)
        var sd = 0.0
        for v in smooth.values { sd += Double(v) * Double(v) }
        sd = (sd / Double(smooth.values.count)).squareRoot()
        func ramp(_ x: Int) -> Double { -5 + 8 * Double(x) / Double(width - 1) }
        let input = grey(width, height) { x, y in
            0.18 * pow(2.0, ramp(x) + 0.1 * smooth[x, y] / sd)
        }
        var withBlack = input
        withBlack[0, 0] = RGB(gray: 0)

        func gains(_ source: ImageBuffer) -> [Double] {
            let a = log2Y(source), b = log2Y(render(source, clarity: 100))
            // The band: a difference of box means, regression per 1 EV window.
            let ha = SpatialOps.boxBlur(a, radius: 1).zip(SpatialOps.boxBlur(a, radius: 8)) { $0 - $1 }
            let hb = SpatialOps.boxBlur(b, radius: 1).zip(SpatialOps.boxBlur(b, radius: 8)) { $0 - $1 }
            var out: [Double] = []
            var ev = -3.0
            while ev < 2.0 {
                var num = 0.0, den = 0.0
                for x in 0..<width where ramp(x) >= ev && ramp(x) < ev + 1 {
                    for y in 12..<(height - 12) {
                        num += hb[x, y] * ha[x, y]
                        den += ha[x, y] * ha[x, y]
                    }
                }
                out.append(num / Swift.max(den, 1e-12))
                ev += 1
            }
            return out
        }
        let g = gains(input)
        XCTAssertGreaterThanOrEqual(g.min() ?? 0, 1.05, "Clarity +100 by tone: \(g)")
        XCTAssertLessThanOrEqual((g.max() ?? 0) / (g.min() ?? 1), 1.35, "Clarity +100 by tone: \(g)")
        let g0 = gains(withBlack)
        for (a, b) in zip(g, g0) {
            XCTAssertLessThanOrEqual(abs(a - b), 0.05,
                                     "one black pixel moved Clarity's gain: \(g) vs \(g0)")
        }
    }

    // MARK: - U8 (R1, R4): the preview shows what the export does

    func testHalfSizeRenderMatchesTheDownsampledFullSizeRender() {
        let field = pinkLog(4096, 64, std: 0.25, seed: 8)
        let big = grey(4096, 64) { x, y in 0.18 * pow(2.0, field[x, y]) }
        // 2x area downsample in linear light.
        let small = grey(2048, 32) { x, y in
            (big[2 * x, 2 * y].g + big[2 * x + 1, 2 * y].g
                + big[2 * x, 2 * y + 1].g + big[2 * x + 1, 2 * y + 1].g) / 4
        }
        func downsample(_ image: ImageBuffer) -> Plane {
            let l = image.luminancePlane(space: .rec2020)
            var out = Plane(width: 2048, height: 32)
            for y in 0..<32 {
                for x in 0..<2048 {
                    out[x, y] = (l[2 * x, 2 * y] + l[2 * x + 1, 2 * y]
                                 + l[2 * x, 2 * y + 1] + l[2 * x + 1, 2 * y + 1]) / 4
                }
            }
            return out
        }
        let bigId = downsample(big)
        let smallId = small.luminancePlane(space: .rec2020)
        let bigNode = node(big), smallNode = node(small)
        for (t, c, ratioBar, corrBar) in [(100.0, 0.0, 0.20, 0.85), (-100, 0, 0.20, 0.85),
                                          (0, 100, 0.15, 0.85), (0, -100, 0.15, 0.85)] {
            let bigOut = downsample(render(big, texture: t, clarity: c, node: bigNode))
            let smallOut = render(small, texture: t, clarity: c, node: smallNode)
                .luminancePlane(space: .rec2020)
            var es: [Double] = [], eb: [Double] = []
            for y in 4..<28 {
                for x in 8..<2040 {
                    es.append(log2(smallOut[x, y] / smallId[x, y]))
                    eb.append(log2(bigOut[x, y] / bigId[x, y]))
                }
            }
            func rms(_ a: [Double]) -> Double {
                let m = a.reduce(0, +) / Double(a.count)
                return (a.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(a.count)).squareRoot()
            }
            let ma = es.reduce(0, +) / Double(es.count), mb = eb.reduce(0, +) / Double(eb.count)
            var cov = 0.0
            for i in es.indices { cov += (es[i] - ma) * (eb[i] - mb) }
            cov /= Double(es.count)
            let ratio = rms(es) / rms(eb)
            let corr = cov / (rms(es) * rms(eb))
            XCTAssertEqual(ratio, 1, accuracy: ratioBar, "t \(t) c \(c): effect ratio \(ratio)")
            XCTAssertGreaterThanOrEqual(corr, corrBar, "t \(t) c \(c): effect correlation \(corr)")
        }
    }

    // MARK: - U9 (N1, N2): noise is not the band

    func testPixelNoiseIsNotAmplified() {
        var noise = LCGNoise(state: 9)
        let input = grey(6000, 16) { _, _ in 0.18 * (1 + 0.04 * noise.gaussian()) }
        func pixelLevel(_ image: ImageBuffer) -> Double {
            let l = image.luminancePlane(space: .rec2020).map {
                TransferFunction.srgb.encode(Num.saturate($0))
            }
            let m = SpatialOps.boxBlur(l, radius: 1)
            var s = 0.0, n = 0.0
            for y in 4..<12 {
                for x in 120..<5880 {
                    let d = l[x, y] - m[x, y]
                    s += d * d
                    n += 1
                }
            }
            return (s / n).squareRoot()
        }
        let base = pixelLevel(input)
        let n = node(input)
        XCTAssertLessThanOrEqual(pixelLevel(render(input, texture: 100, node: n)) / base, 1.35)
        XCTAssertLessThanOrEqual(pixelLevel(render(input, clarity: 100, node: n)) / base, 1.15)
    }

    // MARK: - U10 (K1, K3): -Texture smooths pores and keeps a lash

    func testNegativeTextureSmoothsPoresAndKeepsALine() {
        let width = 6000, height = 32
        var noise = LCGNoise(state: 10)
        var logField = Plane(width: width, height: height)
        // Pores: σ 1.5 px, −0.25 EV dips, one per ~36 px², away from the line.
        for _ in 0..<(width * height / 36) {
            let px = Int((noise.next() + 0.5) * Double(width - 1))
            let py = Int((noise.next() + 0.5) * Double(height - 1))
            if abs(px - 4000) < 30 { continue }
            for dy in -4...4 {
                for dx in -4...4 {
                    let x = px + dx, y = py + dy
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    let w = exp(-Double(dx * dx + dy * dy) / (2 * 1.5 * 1.5))
                    logField[x, y] = logField[x, y] - 0.25 * w
                }
            }
        }
        let input = grey(width, height) { x, y in
            let line = (x >= 3999 && x <= 4001) ? -1.5 : 0
            return 0.18 * pow(2.0, logField[x, y] + line)
        }
        let a = log2Y(input), b = log2Y(render(input, texture: -100))
        func fineEnergy(_ p: Plane) -> Double {
            let lp = SpatialOps.boxBlur(SpatialOps.boxBlur(SpatialOps.boxBlur(p, radius: 2),
                                                           radius: 2), radius: 2)
            var s = 0.0, n = 0.0
            for y in 8..<(height - 8) {
                for x in 200..<3800 {
                    let d = p[x, y] - lp[x, y]
                    s += d * d
                    n += 1
                }
            }
            return (s / n).squareRoot()
        }
        XCTAssertLessThanOrEqual(fineEnergy(b) / fineEnergy(a), 0.6,
                                 "Texture -100 left the pore-scale detail")
        func depth(_ p: Plane) -> Double {
            var line = 0.0, background = 0.0
            for y in 8..<(height - 8) {
                line += p[4000, y]
                background += 0.5 * (p[3980, y] + p[4020, y])
            }
            return (background - line) / Double(height - 16)
        }
        XCTAssertGreaterThanOrEqual(depth(b) / depth(a), 0.9, "Texture -100 faded the line")
    }

    // MARK: - U12 (S9): oriented fine detail at normal contrast keeps the slider

    func testOrientedHairLinesKeepTheWholeSlider() {
        // ±15 % (≈0.2 EV) lines at a 3 px period, all parallel — a perfectly coherent
        // pattern — on a strip whose long edge puts them inside Texture's band
        // (2048 / 3 = 683 cycles per image long edge).
        let width = 2048, height = 24
        let input = grey(width, height) { _, y in
            0.30 * (1.0 + 0.15 * sin(Double(y) * Double.pi / 1.5))
        }
        let n = node(input)
        let a = log2Y(input)
        func gain(_ texture: Double) -> Double {
            let b = log2Y(render(input, texture: texture, node: n))
            var ma = 0.0, mb = 0.0, count = 0.0
            for y in 6..<(height - 6) {
                for x in 64..<(width - 64) { ma += a[x, y]; mb += b[x, y]; count += 1 }
            }
            ma /= count
            mb /= count
            var num = 0.0, den = 0.0
            for y in 6..<(height - 6) {
                for x in 64..<(width - 64) {
                    num += (b[x, y] - mb) * (a[x, y] - ma)
                    den += (a[x, y] - ma) * (a[x, y] - ma)
                }
            }
            return num / Swift.max(den, 1e-12)
        }
        let up = gain(100), down = gain(-100)
        XCTAssertGreaterThanOrEqual(up, 1.4, "Texture +100 on oriented hair lines: \(up)")
        XCTAssertLessThanOrEqual(down, 0.6, "Texture -100 on oriented hair lines: \(down)")
    }
}

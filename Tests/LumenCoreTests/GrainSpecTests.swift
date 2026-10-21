// GrainSpecTests.swift
// WS-40: the grain is per-pixel procedural film grain (`GrainField`), not a tiled plate.
//
// The measurable lines of docs/quality/lanes/WS-40/SPEC.md that can be pinned at field
// level, cheaply, on Linux. `run_spec.sh` measures every line on real renders; these keep
// the properties from regressing between runs of it:
//   · 3e  Amount 0 is an exact identity (float level);
//   · 11  deterministic, and a different seed is a different, uncorrelated pattern;
//   · 1   no period: no correlation at long lags, stationary across the cell grid;
//   · 2a  the hash that draws the grains has no lattice in it (the defect the first
//         prototype had at Size 0) — and it is exact in float32, which is what lets
//         the GPU draw the same grains as this CPU reference;
//   · 6   Size is monotone with the SPEC's correlation lengths at a 6000 px frame;
//   · 7   Roughness changes character (kurtosis, clumping), not strength;
//   · 8   the pixel aperture makes a preview the export downsampled (std);
//   · 10a creative grain is luminance-only: R, G and B move by one factor.

import XCTest
@testable import LumenCore

final class GrainSpecTests: XCTestCase {

    // MARK: Helpers

    private static func flat(_ w: Int, _ h: Int, _ level: Double = 0.18) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { _, _ in RGB(gray: level) }
    }

    private static func render(_ recipe: Recipe, _ frame: ImageBuffer) -> ImageBuffer {
        ReferenceRenderer.render(frame, plan: RenderPlan(recipe: recipe))
    }

    private static func creativeField(size: Double, roughness: Double = 50,
                                      longEdge: Int,
                                      seed: UInt64 = FilmGrainProfile.defaultPlateSeed)
        -> GrainField {
        GrainPlan.creative(CreativeGrain(amount: 100, size: size, roughness: roughness),
                           monochrome: false).field(longEdge: longEdge, seed: seed)
    }

    private static func stats(_ v: [Float]) -> (mean: Double, sd: Double) {
        var s = 0.0, s2 = 0.0
        for x in v { s += Double(x); s2 += Double(x) * Double(x) }
        let n = Double(v.count)
        let m = s / n
        return (m, Swift.max(s2 / n - m * m, 0).squareRoot())
    }

    /// Autocorrelation of a row-major field at lag (dx, dy), normalised by the variance.
    private static func acf(_ v: [Float], _ w: Int, _ h: Int, _ dx: Int, _ dy: Int)
        -> Double {
        let st = stats(v)
        var acc = 0.0
        var n = 0
        for y in 0..<(h - dy) {
            for x in 0..<(w - dx) {
                acc += (Double(v[y * w + x]) - st.mean)
                    * (Double(v[(y + dy) * w + x + dx]) - st.mean)
                n += 1
            }
        }
        return acc / Double(n) / (st.sd * st.sd)
    }

    /// The 1/e correlation length, mean of x and y — `grain_metrics.py`'s `cl`.
    private static func correlationLength(_ v: [Float], _ w: Int, _ h: Int) -> Double {
        func along(_ x: Bool) -> Double {
            let t = exp(-1.0)
            var prev = 1.0
            for lag in 1..<64 {
                let r = x ? acf(v, w, h, lag, 0) : acf(v, w, h, 0, lag)
                if r < t { return Double(lag - 1) + (prev - t) / (prev - r) }
                prev = r
            }
            return 64
        }
        return 0.5 * (along(true) + along(false))
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Double {
        let sa = stats(a), sb = stats(b)
        var acc = 0.0
        for i in 0..<a.count {
            acc += (Double(a[i]) - sa.mean) * (Double(b[i]) - sb.mean)
        }
        return acc / Double(a.count) / (sa.sd * sb.sd)
    }

    // MARK: 3e — Amount 0 is an exact identity

    func testAmountZeroIsExactIdentity() {
        let frame = Self.flat(64, 48)
        // Creative grain at Amount 0, with Size and Roughness moved off their defaults.
        var creative = Recipe()
        creative.look.grain = CreativeGrain(amount: 0, size: 80, roughness: 10)
        XCTAssertNil(RenderPlan(recipe: creative).grain,
                     "Amount 0 must not even build a grain stage")
        let plain = Self.render(Recipe(), frame)
        XCTAssertEqual(Self.render(creative, frame).pixels, plain.pixels,
                       "creative grain at Amount 0 moved a float")

        // A stock whose grain is at 0: identical to the same stock with no grain at all,
        // whatever its grain Size says.
        var stock = Recipe()
        stock.look.filmLab = FilmChain.defaultRecipe(for: FilmStock.portra400)
        stock.look.filmLab?.grain = FilmGrain(size: 1.0, amount: 0)
        var stockMoved = stock
        stockMoved.look.filmLab?.grain = FilmGrain(size: 1.8, amount: 0)
        XCTAssertNil(RenderPlan(recipe: stock).grain)
        XCTAssertEqual(Self.render(stock, frame).pixels, Self.render(stockMoved, frame).pixels,
                       "a stock at grain 0 is not the stock without grain")

        // And the stage itself, handed a plan with nothing to lay, is the identity.
        let zero = GrainPlan(profile: GrainPlan.creative(CreativeGrain(amount: 50),
                                                         monochrome: false).profile,
                             amount: 0, dMax: 4, printLongEdgeInches: 10, isCreative: true)
        XCTAssertEqual(ReferenceRenderer.applyGrain(frame, grain: zero, seed: 1,
                                                    longEdge: 64).pixels,
                       frame.pixels)
    }

    // MARK: 11 — deterministic; the seed is the pattern

    func testDeterministic() {
        let field = Self.creativeField(size: 30, longEdge: 2000)
        XCTAssertEqual(field.evaluate(width: 97, height: 61),
                       field.evaluate(width: 97, height: 61))
        var recipe = Recipe()
        recipe.look.grain = CreativeGrain(amount: 70, size: 40, roughness: 80)
        let frame = Self.flat(80, 53)
        XCTAssertEqual(Self.render(recipe, frame).pixels, Self.render(recipe, frame).pixels)
        var film = Recipe()
        film.look.filmLab = FilmChain.defaultRecipe(for: FilmStock.portra400)
        film.look.filmLab?.grain = FilmGrain(size: 1.0, amount: 100)
        XCTAssertEqual(Self.render(film, frame).pixels, Self.render(film, frame).pixels)
    }

    func testSeedChangesPattern() {
        let a = Self.creativeField(size: 50, longEdge: 6000, seed: 1)
            .evaluate(width: 256, height: 256)[0]
        let b = Self.creativeField(size: 50, longEdge: 6000, seed: 0xDEADBEEF)
            .evaluate(width: 256, height: 256)[0]
        XCTAssertNotEqual(a, b)
        let r = Self.correlation(a, b)
        XCTAssertLessThan(abs(r), 0.05, "two seeds draw correlated grain (r = \(r))")
        // The three layers of a colour stock are independent too (the luma/own mix's
        // premise), and so is each grain layer from its own clump layer.
        let stock = GrainPlan.film(FilmChain(FilmChain.defaultRecipe(for: .portra400),
                                             displayWhite: 1.0))
        let layers = stock.field(longEdge: 6000).evaluate(width: 192, height: 192)
        XCTAssertEqual(layers.count, 3)
        for (i, j) in [(0, 1), (0, 2), (1, 2)] {
            let rr = Self.correlation(layers[i], layers[j])
            XCTAssertLessThan(abs(rr), 0.05, "stock layers \(i) and \(j): r = \(rr)")
        }
    }

    // MARK: 1 — no period, no grid

    func testNoPeriodAndNoCellGrid() {
        for (size, rough) in [(0.0, 50.0), (50.0, 0.0), (100.0, 100.0)] {
            let field = Self.creativeField(size: size, roughness: rough, longEdge: 6000)
            let w = 640, h = 640
            let v = field.evaluate(width: w, height: h)[0]
            let cl = Self.correlationLength(v, w, h)
            for lag in [64, 128, 256] {
                XCTAssertLessThan(abs(Self.acf(v, w, h, lag, 0)), 0.05,
                                  "Size \(size) R \(rough): acf_x(\(lag))")
                XCTAssertLessThan(abs(Self.acf(v, w, h, 0, lag)), 0.05,
                                  "Size \(size) R \(rough): acf_y(\(lag))")
            }
            // Beyond 3 cl nothing is correlated, along either axis or the diagonal.
            let l0 = Int((3 * cl).rounded(.up))
            for lag in l0..<(l0 + 8) {
                XCTAssertLessThan(abs(Self.acf(v, w, h, lag, lag)), 0.05)
            }
            // Stationary across the CELL grid: the variance does not depend on where in
            // its cell a pixel sits (a lattice would put a grid in the variance).
            let cell = field.channels[0][0].cell
            var sum = [Double](repeating: 0, count: 16), cnt = [Double](repeating: 0, count: 16)
            let m = Self.stats(v).mean
            for y in 0..<h {
                for x in 0..<w {
                    let fx = (Double(x) + 0.5) / cell, fy = (Double(y) + 0.5) / cell
                    let bx = Int((fx - fx.rounded(.down)) * 4), by = Int((fy - fy.rounded(.down)) * 4)
                    let d = Double(v[y * w + x]) - m
                    sum[by * 4 + bx] += d * d
                    cnt[by * 4 + bx] += 1
                }
            }
            let vars = zip(sum, cnt).filter { $0.1 > 500 }.map { $0.0 / $0.1 }
            let ratio = vars.max()! / vars.min()!
            XCTAssertLessThan(ratio, 1.2, "Size \(size): the variance follows the cell "
                                  + "grid (max/min over cell phase \(ratio))")
        }
    }

    // MARK: 2a — the hash has no lattice in it, and is exact in float32

    /// The defect the lead's prototype had: its cell hash mixed cx and cy almost
    /// linearly, so the grain drew a diagonal lattice (period 2.53 px) at Size 0. Each of
    /// the 24 per-cell streams is checked over a 128² block of cells: no neighbour
    /// correlation, no correlation between streams, and a flat 2D spectrum (peak / mean
    /// of the periodogram at white-noise level — about ln(N) ≈ 10, the old hash ~95).
    func testTheCellHashHasNoLattice() {
        let n = 128
        for (ox, oy, seed) in [(0, 0, UInt64(7)), (-64, 3000, UInt64(123_456_789)),
                               (9000, -2, FilmGrainProfile.defaultPlateSeed)] {
            let base = GrainField.seedBase(seed)
            let sa = GrainField.cubeA(base.a), sb = GrainField.cubeB(base.b)
            var streams = [[Double]](repeating: [Double](repeating: 0, count: n * n),
                                     count: 2 * GrainField.maxGrains * 2)
            for y in 0..<n {
                for x in 0..<n {
                    let st = GrainField.cellState(Double(x + ox), Double(y + oy), sa, sb)
                    for t in 0..<(2 * GrainField.maxGrains) {
                        let u = GrainField.stream(st.a, st.b, Double(t + 1))
                        streams[2 * t][y * n + x] = u.0
                        streams[2 * t + 1][y * n + x] = u.1
                    }
                }
            }
            func corr(_ a: [Double], _ b: [Double]) -> Double {
                let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
                var c = 0.0, va = 0.0, vb = 0.0
                for i in 0..<a.count {
                    c += (a[i] - ma) * (b[i] - mb); va += (a[i] - ma) * (a[i] - ma)
                    vb += (b[i] - mb) * (b[i] - mb)
                }
                return c / (va * vb).squareRoot()
            }
            for s in streams {
                let mean = s.reduce(0, +) / Double(s.count)
                XCTAssertEqual(mean, 0.5, accuracy: 0.01)
                // neighbours: right, down, both diagonals
                var right = [Double](), rightB = [Double]()
                var down = [Double](), downB = [Double]()
                var diag = [Double](), diagB = [Double]()
                for y in 0..<(n - 1) {
                    for x in 0..<(n - 1) {
                        right.append(s[y * n + x]); rightB.append(s[y * n + x + 1])
                        down.append(s[y * n + x]); downB.append(s[(y + 1) * n + x])
                        diag.append(s[y * n + x]); diagB.append(s[(y + 1) * n + x + 1])
                    }
                }
                XCTAssertLessThan(abs(corr(right, rightB)), 0.04)
                XCTAssertLessThan(abs(corr(down, downB)), 0.04)
                XCTAssertLessThan(abs(corr(diag, diagB)), 0.04)
            }
            for i in 0..<streams.count {
                for j in (i + 1)..<streams.count {
                    XCTAssertLessThan(abs(corr(streams[i], streams[j])), 0.04,
                                      "streams \(i) and \(j) are correlated")
                }
            }
            // A flat 2D spectrum, by direct DFT along the diagonal family the old hash
            // failed on and along the axes: |F(k)|² / mean over a grid of frequencies.
            let s = streams[0]
            let mean = s.reduce(0, +) / Double(s.count)
            var powers = [Double]()
            for ky in stride(from: 0, to: n / 2, by: 3) {
                for kx in stride(from: 0, to: n / 2, by: 3) where kx + ky > 0 {
                    var re = 0.0, im = 0.0
                    for y in 0..<n {
                        for x in 0..<n {
                            let ph = 2 * Double.pi * Double(kx * x + ky * y) / Double(n)
                            let d = s[y * n + x] - mean
                            re += d * cos(ph); im += d * sin(ph)
                        }
                    }
                    powers.append(re * re + im * im)
                }
            }
            let peak = powers.max()! / (powers.reduce(0, +) / Double(powers.count))
            XCTAssertLessThan(peak, 14, "the cell hash has a spectral line (\(peak))")
        }
    }

    /// The GPU evaluates the hash in float32. Every intermediate is an integer below
    /// 2^24, so float32 and Double agree EXACTLY — checked here by running the same
    /// arithmetic in `Float`, including a floor that lands one off (which the fix-ups
    /// absorb), over cells with negative and large coordinates.
    func testTheHashIsExactInFloat32() {
        func modF(_ x: Float, _ n: Float, skew: Float) -> Float {
            // `skew` nudges x·(1/n) across an integer, as a GPU's rounding may.
            var r = x - (x * (1 / n) + skew).rounded(.down) * n
            if r >= n { r -= n }
            if r < 0 { r += n }
            return r
        }
        func cube(_ x: Float, _ n: Float, _ skew: Float) -> Float {
            let y = modF(x, n, skew: skew)
            let y2 = modF(y * y, n, skew: skew)
            XCTAssertLessThan(y2 * y, 16_777_216)
            return modF(y2 * y, n, skew: skew)
        }
        let pa = Float(GrainField.primeA), pb = Float(GrainField.primeB)
        for skew: Float in [0, 1e-4, -1e-4] {
            for (cx, cy) in [(-1, -1), (0, 0), (4090, 4078), (4091, 4079), (-4092, 12_345),
                             (30_000, -30_000), (517, 2)] {
                let sa = GrainField.cubeA(1234), sb = GrainField.cubeB(77)
                let d = GrainField.cellState(Double(cx), Double(cy), sa, sb)
                let fx = Float(cx), fy = Float(cy)
                let lx = modF(fx, pa, skew: skew)
                let hx = modF(((fx - lx) * (1 / pa) + 0.5).rounded(.down), pa, skew: skew)
                let ly = modF(fy, pb, skew: skew)
                let hy = modF(((fy - ly) * (1 / pb) + 0.5).rounded(.down), pb, skew: skew)
                var a = cube(Float(sa) + lx, pa, skew)
                var b = cube(Float(sb) + ly, pb, skew)
                a = cube(a + ly + hy, pa, skew)
                b = cube(b + lx + hx, pb, skew)
                a = cube(a + b, pa, skew)
                b = cube(b + a, pb, skew)
                XCTAssertEqual(Double(a), d.a, "lane A differs in float32 at (\(cx), \(cy))")
                XCTAssertEqual(Double(b), d.b, "lane B differs in float32 at (\(cx), \(cy))")
                for t in 1...12 {
                    let tt = Float(t)
                    let a1 = cube(a + tt, pa, skew)
                    let b1 = cube(b + a1 + 3 * tt, pb, skew)
                    let a2 = cube(a1 + b1, pa, skew)
                    let b2 = cube(b1 + a2, pb, skew)
                    let u = GrainField.stream(d.a, d.b, Double(t))
                    XCTAssertEqual(Double((a2 + 0.5) * (1 / pa)), u.0, accuracy: 1e-6)
                    XCTAssertEqual(Double((b2 + 0.5) * (1 / pb)), u.1, accuracy: 1e-6)
                }
            }
        }
    }

    /// The CPU's banded gather (`evaluate`) is the same function as the plain
    /// definition the kernel transcribes (`layerValue`).
    func testTheGatherIsTheDefinition() {
        for (size, rough) in [(0.0, 0.0), (60.0, 100.0)] {
            let field = Self.creativeField(size: size, roughness: rough, longEdge: 3000)
            let w = 53, h = 37
            let v = field.evaluate(width: w, height: h)[0]
            var worst = 0.0
            for y in 0..<h {
                for x in 0..<w {
                    var direct = 0.0
                    for layer in field.channels[0] {
                        direct += GrainField.layerValue(layer, x: Double(x) + 0.5,
                                                        y: Double(y) + 0.5)
                    }
                    worst = Swift.max(worst, abs(direct - Double(v[y * w + x])))
                }
            }
            XCTAssertLessThan(worst, 1e-5)
        }
    }

    /// A hand-edited sidecar can say anything: a Roughness or a radius that is not a
    /// number, or far outside the slider, is clamped into the model rather than trusted
    /// (a count of 0 grains or a negative spread is not grain).
    func testAnAbsurdRoughnessOrRadiusIsClamped() {
        for rough in [Double.nan, -5, 500, Double.infinity] {
            let field = GrainField(radii: [1.5], roughness: rough, seed: 3)
            for layer in field.channels[0] {
                XCTAssertTrue(layer.count >= 1 && layer.count <= Double(GrainField.maxGrains))
                XCTAssertTrue(layer.spread >= 0 && layer.spread.isFinite)
                XCTAssertTrue(layer.gain.isFinite && layer.gain > 0)
            }
            let v = field.evaluate(width: 32, height: 32)[0]
            XCTAssertTrue(v.allSatisfy { $0.isFinite }, "roughness \(rough)")
        }
        for radius in [0.0, -1, Double.nan] {
            let v = GrainField(radii: [radius], roughness: 0.5, seed: 3)
                .evaluate(width: 16, height: 16)[0]
            XCTAssertTrue(v.allSatisfy { $0.isFinite }, "radius \(radius)")
        }
    }

    // MARK: 6 — Size is monotone, with the SPEC's correlation lengths

    func testSizeIsMonotoneAtTheSpecLengths() {
        var previous = 0.0
        let bands: [Double: ClosedRange<Double>] = [0: 0.6...0.9, 25: 1.0...1.5,
                                                    50: 1.6...2.5, 100: 4.0...5.5]
        for size in [0.0, 25.0, 50.0, 75.0, 100.0] {
            let w = size >= 75 ? 384 : 256
            let v = Self.creativeField(size: size, longEdge: 6000)
                .evaluate(width: w, height: w)[0]
            let cl = Self.correlationLength(v, w, w)
            if previous > 0 {
                XCTAssertGreaterThan(cl / previous, 1.15, "Size \(size) is not coarser")
            }
            if let band = bands[size] {
                XCTAssertTrue(band.contains(cl), "Size \(size): cl \(cl) px outside \(band)")
            }
            previous = cl
        }
    }

    // MARK: 7 — Roughness is character, not strength

    func testRoughnessChangesCharacterNotStrength() {
        let w = 512
        var sds = [Double](), kurt = [Double](), cv = [Double]()
        for rough in [0.0, 50.0, 100.0] {
            let v = Self.creativeField(size: 50, roughness: rough, longEdge: 6000)
                .evaluate(width: w, height: w)[0]
            let st = Self.stats(v)
            var m4 = 0.0
            for x in v { let d = Double(x) - st.mean; m4 += d * d * d * d }
            kurt.append(m4 / Double(v.count) / pow(st.sd, 4))
            sds.append(st.sd)
            // local energy of 8 x 8 blocks
            var e = [Double]()
            for by in 0..<(w / 8) {
                for bx in 0..<(w / 8) {
                    var s = 0.0
                    for y in 0..<8 {
                        for x in 0..<8 {
                            let d = Double(v[(by * 8 + y) * w + bx * 8 + x]) - st.mean
                            s += d * d
                        }
                    }
                    e.append(s / 64)
                }
            }
            let em = e.reduce(0, +) / Double(e.count)
            let ev = e.map { ($0 - em) * ($0 - em) }.reduce(0, +) / Double(e.count)
            cv.append(ev.squareRoot() / em)
        }
        for sd in sds {
            XCTAssertEqual(sd / sds[1], 1, accuracy: 0.15, "Roughness changed the strength")
        }
        XCTAssertGreaterThan(kurt[2] - kurt[0], 0.25, "kurtosis \(kurt)")
        XCTAssertLessThanOrEqual(kurt[0], kurt[1] + 0.02)
        XCTAssertLessThanOrEqual(kurt[1], kurt[2] + 0.02)
        XCTAssertGreaterThan(cv[2] / cv[0], 1.2, "local energy CV \(cv)")
    }

    // MARK: 8 — preview = export, downsampled

    func testAPreviewIsTheExportDownsampled() {
        for size in [0.0, 50.0, 100.0] {
            let small = Self.creativeField(size: size, longEdge: 1024)
                .evaluate(width: 192, height: 192)[0]
            let big = Self.creativeField(size: size, longEdge: 2048, seed: 99)
                .evaluate(width: 384, height: 384)[0]
            var down = [Float](repeating: 0, count: 192 * 192)
            for y in 0..<192 {
                for x in 0..<192 {
                    down[y * 192 + x] = (big[(2 * y) * 384 + 2 * x] + big[(2 * y) * 384 + 2 * x + 1]
                        + big[(2 * y + 1) * 384 + 2 * x] + big[(2 * y + 1) * 384 + 2 * x + 1]) / 4
                }
            }
            let ratio = Self.stats(down).sd / Self.stats(small).sd
            XCTAssertEqual(ratio, 1, accuracy: 0.1, "Size \(size): export ↓2 / preview σ")
        }
    }

    // MARK: 10a — creative grain is luminance only

    func testCreativeGrainMovesRGBByOneFactor() {
        let frame = ImageBuffer(width: 40, height: 30) { u, v in
            RGB(0.05 + 0.6 * u, 0.3 * v + 0.02, 0.4)
        }
        let plan = GrainPlan.creative(CreativeGrain(amount: 100, size: 100), monochrome: false)
        let out = ReferenceRenderer.applyGrain(frame, grain: plan, seed: 5, longEdge: 400)
        var moved = 0.0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let a = frame[x, y], b = out[x, y]
                let f = b.g / a.g
                moved = Swift.max(moved, abs(f - 1))
                XCTAssertEqual(b.r / a.r, f, accuracy: 1e-5)
                XCTAssertEqual(b.b / a.b, f, accuracy: 1e-5)
            }
        }
        XCTAssertGreaterThan(moved, 0.05, "the grain did nothing")
    }
}

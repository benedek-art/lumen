// WS-04 Exposure & the S6 fused matrix: the acceptance spec in
// docs/quality/lanes/WS-04/SPEC.md, one test per measurable line.
//
// Probe conventions are the audit harness's (docs/quality/lanes/WS-04/audit/
// harness_main.swift.txt): a `RenderPlan` at as-shot 6503.7072 K / +9.77, LUT 33, a
// 1-row `ImageBuffer` through `ReferenceRenderer.render`, and a "code" is the
// pre-rounding sRGB value (Rec.2020 → sRGB, clamp to [0, 1], sRGB encode, ×255, no
// dither). "exact" is `RenderPlan.exactColor`, which bypasses the finish table.
//
// Every test prints its measured number on one `WS-04` line, so a CI log is the
// BUILD-NOTES table.
import XCTest
@testable import LumenCore

final class ExposureQualityTests: XCTestCase {

    // MARK: - Harness

    private static let asShotKelvin = 6503.7072
    private static let asShotTint = 9.77
    private static let toSRGB = RGBColorSpace.rec2020.matrix(to: .srgb)

    private static func row(_ values: [RGB]) -> ImageBuffer {
        var image = ImageBuffer(width: values.count, height: 1)
        for (i, v) in values.enumerated() { image[i, 0] = v }
        return image
    }

    private static func plan(_ recipe: Recipe, lut: Int = 33) -> RenderPlan {
        RenderPlan(recipe: recipe, asShotKelvin: asShotKelvin, asShotTint: asShotTint,
                   lutSize: lut)
    }

    private static func render(_ values: [RGB], _ recipe: Recipe, lut: Int = 33) -> [RGB] {
        let out = ReferenceRenderer.render(row(values), plan: plan(recipe, lut: lut))
        return (0..<values.count).map { out[$0, 0] }
    }

    private static func exact(_ values: [RGB], _ recipe: Recipe) -> [RGB] {
        let p = RenderPlan(recipe: recipe, asShotKelvin: asShotKelvin, asShotTint: asShotTint)
        return values.map { p.exactColor($0, space: .rec2020) }
    }

    private static func encode(_ x: Double) -> Double {
        TransferFunction.srgb.encode(Swift.max(0, Swift.min(1, x)))
    }

    /// Pre-rounding sRGB code of a display-linear Rec.2020 value.
    private static func code(_ c: RGB) -> RGB {
        let s = toSRGB.apply(c)
        return RGB(encode(s.r) * 255, encode(s.g) * 255, encode(s.b) * 255)
    }

    private static func ev(_ k: Double, _ base: Recipe = Recipe()) -> Recipe {
        var r = base
        r.develop.tone.exposure = k
        return r
    }

    /// The audit's 403-pixel ramp: ±10 EV of neutral, blue, warm and red, then a
    /// negative, black and a (100, 90, 80) highlight.
    private static let ramp: [RGB] = {
        var ramp: [RGB] = []
        for i in 0..<400 {
            let e = -10 + 20 * Double(i) / 399
            let v = 0.18 * pow(2, e)
            ramp.append([RGB(v, v, v), RGB(v * 0.3, v * 0.6, v * 1.9),
                         RGB(v * 2.2, v * 1.3, v * 0.8), RGB(v * 1.5, v * 0.2, v * 0.1)][i % 4])
        }
        ramp.append(RGB(-0.02, 0.01, 0.05))
        ramp.append(RGB(0, 0, 0))
        ramp.append(RGB(100, 90, 80))
        return ramp
    }()

    private static func maxCodeDiff(_ a: [RGB], _ b: [RGB]) -> Double {
        zip(a, b).reduce(0) { worst, pair in
            let ca = code(pair.0), cb = code(pair.1)
            return Swift.max(worst, abs(ca.r - cb.r), abs(ca.g - cb.g), abs(ca.b - cb.b))
        }
    }

    private static func bits(_ image: ImageBuffer) -> [UInt32] { image.pixels.map(\.bitPattern) }

    private static func report(_ line: String) { print("WS-04 \(line)") }

    // MARK: - 1. S6 matrix is exactly 2^EV · M(0)

    func testS6MatrixIsExactPowerOfTwoGain() {
        var worst = 0.0
        for wb in [nil, 3200.0, 9000.0] as [Double?] {
            for pl in [0, 3] {
                var base = Recipe()
                base.develop.raw.temp = wb
                base.develop.raw.tint = wb == nil ? nil : 5
                base.look.printerLights = PrinterLights(master: 0, r: pl, g: 0, b: -pl)
                let m0 = RenderPlan(recipe: base, asShotKelvin: 5000, asShotTint: 0).linear.matrix
                for k in [-10.0, -5, -3, -1, 1, 2, 3, 5, 10] {
                    let mk = RenderPlan(recipe: Self.ev(k, base), asShotKelvin: 5000,
                                        asShotTint: 0).linear.matrix
                    for i in 0..<3 {
                        for j in 0..<3 {
                            let want = m0.m[i][j] * pow(2, k), got = mk.m[i][j]
                            if want != 0 || got != 0 {
                                worst = Swift.max(worst, abs(want - got)
                                                  / Swift.max(abs(want), 1e-300))
                            }
                        }
                    }
                }
            }
        }
        Self.report("L1 max rel err M(EV) vs 2^EV·M(0) = \(worst)")
        XCTAssertLessThanOrEqual(worst, 1e-15)
    }

    // MARK: - 2. LinearStage.apply is exactly 2^EV, sign kept

    func testS6GainExactAcrossRangeAndSigns() {
        let magnitudes: [Double] = [1e-4, 1e-3, 0.18, 1, 5.76, 64, 1000, 6e4]
        let values = [0] + magnitudes + magnitudes.map { -$0 }
        var probes: [RGB] = []
        for v in values {
            probes.append(RGB(gray: v))
            probes.append(RGB(v, 0.5 * v, -0.3 * v))
        }
        var worst = 0.0, checked = 0
        for wb in [nil, 3200.0, 9000.0] as [Double?] {
            for pl in [0, 3] {
                var base = Recipe()
                base.develop.raw.temp = wb
                base.develop.raw.tint = wb == nil ? nil : 5
                base.look.printerLights = PrinterLights(master: 0, r: pl, g: 0, b: -pl)
                let s0 = RenderPlan(recipe: base, asShotKelvin: 5000, asShotTint: 0).linear
                for k in [-10.0, -5, -3, -1, 1, 2, 3, 5, 10] {
                    let sk = RenderPlan(recipe: Self.ev(k, base), asShotKelvin: 5000,
                                        asShotTint: 0).linear
                    for c in probes {
                        let ref = s0.matrix.apply(c) * pow(2, k)
                        // The claim holds wherever the product is inside the fp16
                        // limit; beyond it line 13's clamp is the contract.
                        guard Swift.max(abs(ref.r), abs(ref.g), abs(ref.b))
                                <= LinearStage.outputLimit else { continue }
                        let got = sk.apply(c)
                        for (x, y) in [(ref.r, got.r), (ref.g, got.g), (ref.b, got.b)] {
                            if x == 0 {
                                XCTAssertEqual(y, 0, accuracy: 1e-300)
                                continue
                            }
                            XCTAssertEqual(x.sign, y.sign, "sign of \(c) at EV \(k)")
                            worst = Swift.max(worst, abs(y / x - 1))
                            checked += 1
                        }
                    }
                }
            }
        }
        Self.report("L2 max rel err apply vs 2^EV over \(checked) channels = \(worst)")
        XCTAssertGreaterThan(checked, 1000)
        XCTAssertLessThanOrEqual(worst, 1e-12)
        // Negatives are kept, not clamped: EV +1 on a negative doubles it.
        let one = RenderPlan(recipe: Self.ev(1)).linear
        XCTAssertLessThan(one.apply(RGB(-0.3, -0.01, -1e-4)).r, -0.59)
    }

    // MARK: - 3. Pure-gain equivalence across recipes

    func testExposureIsPureSceneGainAcrossRecipes() {
        var recipes: [(String, Recipe)] = [("default", Recipe())]
        var r = Recipe()
        r.develop.tone.contrast = 40; r.develop.tone.highlights = -60
        r.develop.tone.shadows = 50; r.develop.tone.whites = 30; r.develop.tone.blacks = -20
        recipes.append(("tone stack", r))
        r = Recipe(); r.develop.zones.mid.ev = 0.5; r.develop.zones.bright.ev = -0.7
        recipes.append(("zones", r))
        r = Recipe(); r.develop.color.saturation = 40; r.develop.color.vibrance = 30
        recipes.append(("sat/vib", r))
        r = Recipe()
        r.look.wheels.high = Wheel(hue: 40, sat: 0.4, lum: 0.2)
        r.look.wheels.shadows = Wheel(hue: 220, sat: 0.3, lum: -0.1)
        recipes.append(("grade wheels", r))
        r = Recipe(); r.look.render.preset = "Punchy"; recipes.append(("Punchy", r))
        r = Recipe(); r.look.render.preset = "Linear"; recipes.append(("Linear", r))
        r = Recipe(); r.look.vignette = -50; recipes.append(("vignette", r))
        r = Recipe(); r.develop.detail.clarity = 40; r.develop.detail.dehaze = 30
        recipes.append(("clarity+dehaze", r))
        r = Recipe(); r.look.filmLab = FilmLab(stock: "lumen/portra400")
        recipes.append(("film portra400", r))
        r = Recipe(); r.develop.raw.temp = 4200; r.develop.raw.tint = 8
        recipes.append(("WB 4200/+8", r))

        var overall = 0.0
        for (name, base) in recipes {
            var worst = 0.0
            for k in [-2.0, 1, 3] {
                let a = Self.render(Self.ramp, Self.ev(k, base))
                let b = Self.render(Self.ramp.map { $0 * pow(2, k) }, base)
                worst = Swift.max(worst, Self.maxCodeDiff(a, b))
            }
            Self.report("L3 \(name): max |code diff| = \(worst)")
            XCTAssertLessThanOrEqual(worst, 1e-9, name)
            overall = Swift.max(overall, worst)
        }
        Self.report("L3 overall max |code diff| = \(overall)")
    }

    // MARK: - 4. EV 0 is the identity

    func testEVZeroIsBitExactIdentity() {
        XCTAssertEqual(ToneEngine(tone: Tone()).exposureGain, 1)
        var negZero = Tone(); negZero.exposure = -0.0
        XCTAssertEqual(ToneEngine(tone: negZero).exposureGain, 1)
        XCTAssertTrue(Self.plan(Recipe()).linear.isIdentity)
        XCTAssertTrue(Self.plan(Self.ev(-0.0)).linear.isIdentity)

        let frame = Self.row(Self.ramp)
        let none = Self.bits(ReferenceRenderer.render(frame, plan: Self.plan(Recipe())))
        let zero = Self.bits(ReferenceRenderer.render(frame, plan: Self.plan(Self.ev(0))))
        let neg = Self.bits(ReferenceRenderer.render(frame, plan: Self.plan(Self.ev(-0.0))))
        let differing = zip(none, zero).filter { $0 != $1 }.count
            + zip(none, neg).filter { $0 != $1 }.count
        Self.report("L4 EV0 / -0.0 differing floats vs no key = \(differing)")
        XCTAssertEqual(none, zero)
        XCTAssertEqual(none, neg)
    }

    // MARK: - 5, 6, 6a. Mid-grey placement and ladder

    func testMidGreyPlacementAtEVZero() {
        let c = Self.code(Self.render([RGB(gray: 0.18)], Recipe())[0]).g
        Self.report("L5 code(0.18 @ EV0) = \(c)")
        XCTAssertEqual(c, 117.65, accuracy: 0.5)
    }

    func testMidGreyLadderMinus3ToPlus3() {
        let audited: [Double] = [20.32, 41.29, 72.72, 117.65, 168.74, 207.17, 234.51]
        var measured: [Double] = [], worstEq = 0.0
        for (i, k) in (-3...3).enumerated() {
            let atEV = Self.code(Self.render([RGB(gray: 0.18)], Self.ev(Double(k)))[0]).g
            let prescaled = Self.code(Self.render([RGB(gray: 0.18 * pow(2, Double(k)))],
                                                  Recipe())[0]).g
            measured.append(atEV)
            worstEq = Swift.max(worstEq, abs(atEV - prescaled))
            XCTAssertEqual(atEV, audited[i], accuracy: 0.5, "EV \(k)")
        }
        Self.report("L6 LUT33 ladder = \(measured.map { String(format: "%.2f", $0) }) "
                    + "max |EV k − prescaled| = \(worstEq)")
        XCTAssertLessThanOrEqual(worstEq, 1e-9)
    }

    func testMidGreyLadderExactPath() {
        let audited: [Double] = [20.32, 39.44, 70.41, 117.65, 168.58, 207.45, 234.51]
        var measured: [Double] = []
        for (i, k) in (-3...3).enumerated() {
            let c = Self.code(Self.exact([RGB(gray: 0.18)], Self.ev(Double(k)))[0]).g
            measured.append(c)
            XCTAssertEqual(c, audited[i], accuracy: 0.5, "EV \(k)")
        }
        Self.report("L6a exact ladder = \(measured.map { String(format: "%.2f", $0) })")
    }

    // MARK: - 7, 8, 9. The 0.01-EV sweep

    private static let sweepLevels: [Double] = [0.001, 0.01, 0.05, 0.18, 0.5, 1, 2, 4, 8, 64]
    private static let sweepEVs: [Double] = (0...1000).map { Double($0 - 500) / 100 }

    /// `[mode][ev index][level index]` → green code. Mode 0 is LUT33, 1 is exact.
    private static let sweep: [[[Double]]] = {
        let neutrals = sweepLevels.map { RGB(gray: $0) }
        let lut = sweepEVs.map { k in render(neutrals, ev(k)).map { code($0).g } }
        let exactCodes = sweepEVs.map { k in exact(neutrals, ev(k)).map { code($0).g } }
        return [lut, exactCodes]
    }()

    func testMonotonicInEVAtHundredthStops() {
        for (mode, label) in ["LUT33", "exact"].enumerated() {
            let table = Self.sweep[mode]
            var falls = 0
            for j in Self.sweepLevels.indices {
                for i in 1..<table.count where table[i][j] - table[i - 1][j] < -1e-9 {
                    falls += 1
                }
            }
            Self.report("L7 \(label) non-monotonic steps = \(falls)")
            XCTAssertEqual(falls, 0, label)
        }
    }

    func testNoStepLargerThanThresholdPerHundredthEV() {
        for (mode, (label, limit)) in [("LUT33", 0.70), ("exact", 0.62)].enumerated() {
            let table = Self.sweep[mode]
            var biggest = 0.0, at = (0.0, 0.0)
            for j in Self.sweepLevels.indices {
                for i in 1..<table.count {
                    let a = table[i - 1][j], b = table[i][j]
                    if a <= 1.0 && b <= 1.0 { continue }   // the black floor
                    let step = abs(b - a)
                    if step > biggest { biggest = step; at = (Self.sweepLevels[j], Self.sweepEVs[i]) }
                }
            }
            Self.report("L8 \(label) max step per 0.01 EV = \(biggest) "
                        + "(scene \(at.0) at EV \(at.1)); limit \(limit)")
            XCTAssertLessThanOrEqual(biggest, limit, label)
        }
    }

    func testSmallestStepMovesGrey() {
        let grey = [RGB(gray: 0.18)]
        let lut = Self.code(Self.render(grey, Self.ev(0.01))[0]).g
            - Self.code(Self.render(grey, Recipe())[0]).g
        let ex = Self.code(Self.exact(grey, Self.ev(0.01))[0]).g
            - Self.code(Self.exact(grey, Recipe())[0]).g
        Self.report("L9 grey move for +0.01 EV: LUT33 \(lut), exact \(ex)")
        XCTAssertGreaterThanOrEqual(abs(lut), 0.3)
        XCTAssertGreaterThanOrEqual(abs(ex), 0.3)
    }

    // MARK: - 10. Hard clamp at ±10

    func testHardClampAtTenStops() {
        func gain(_ x: Double) -> Double {
            var t = Tone(); t.exposure = x
            return ToneEngine(tone: t).exposureGain
        }
        for x in [10.0, 11, 12, 1e6] { XCTAssertEqual(gain(x), 1024, "\(x)") }
        for x in [-10.0, -12, -1e6] { XCTAssertEqual(gain(x), 1.0 / 1024, "\(x)") }
        let frame = Self.row(Self.ramp)
        func rendered(_ k: Double) -> [UInt32] {
            Self.bits(ReferenceRenderer.render(frame, plan: Self.plan(Self.ev(k))))
        }
        XCTAssertEqual(rendered(12), rendered(10))
        XCTAssertEqual(rendered(-12), rendered(-10))
        Self.report("L10 gains 10/11/12/1e6 = \([10.0, 11, 12, 1e6].map(gain)), "
                    + "−10/−12/−1e6 = \([-10.0, -12, -1e6].map(gain)); renders bit-equal")
    }

    // MARK: - 12. Non-finite Exposure

    func testNonFiniteExposureIsIdentityOrClamped() {
        func gain(_ x: Double) -> Double {
            var t = Tone(); t.exposure = x
            return ToneEngine(tone: t).exposureGain
        }
        let g = (gain(.nan), gain(.infinity), gain(-.infinity))
        XCTAssertEqual(g.0, 1)
        XCTAssertEqual(g.1, 1024)
        XCTAssertEqual(g.2, 1.0 / 1024)
        XCTAssertTrue(Self.plan(Self.ev(.nan)).linear.isIdentity)

        let frame = Self.row(Self.ramp)
        let nanRender = ReferenceRenderer.render(frame, plan: Self.plan(Self.ev(.nan)))
        let zero = ReferenceRenderer.render(frame, plan: Self.plan(Recipe()))
        let nanPixels = nanRender.pixels.filter { $0.isNaN }.count
        Self.report("L12 gains NaN/+inf/−inf = \(g); NaN pixels = \(nanPixels)")
        XCTAssertEqual(nanPixels, 0)
        XCTAssertEqual(Self.bits(nanRender), Self.bits(zero))
    }

    // MARK: - 13. S6 output limited to the half-float maximum

    func testS6OutputClampedToHalfFloatMax() {
        XCTAssertEqual(LinearStage.outputLimit, 65504)
        var t = Tone(); t.exposure = 10
        let gain = ToneEngine(tone: t).exposureGain
        let stage = LinearStage(matrix: Mat3.diagonal(RGB(gray: gain)))
        let over = stage.apply(RGB(64, 1e3, 1e4))
        XCTAssertEqual(over.r, 65504); XCTAssertEqual(over.g, 65504); XCTAssertEqual(over.b, 65504)
        let under = stage.apply(RGB(-1e4, -1e3, -64))
        XCTAssertEqual(under.r, -65504); XCTAssertEqual(under.g, -65504)
        XCTAssertEqual(under.b, -65504)
        let grey = stage.apply(RGB(gray: 0.18))
        XCTAssertEqual(grey.r, 0.18 * 1024); XCTAssertEqual(grey.g, 0.18 * 1024)
        XCTAssertEqual(grey.b, 0.18 * 1024)
        // Finite for every finite input up to 1e30 (an infinite input is not a scene
        // value: 0 · inf in the matrix product is NaN, which passes through as NaN).
        for v in [1e5, 1e10, 1e20, 1e30, -1e30] {
            let o = stage.apply(RGB(v, v * 0.5, -v))
            XCTAssertTrue(o.r.isFinite && o.g.isFinite && o.b.isFinite, "\(v)")
            XCTAssertLessThanOrEqual(Swift.max(abs(o.r), abs(o.g), abs(o.b)), 65504)
        }
        // The real plan's stage at EV +10 (with its as-shot WB) clamps the same way.
        let planStage = Self.plan(Self.ev(10)).linear
        let p = planStage.apply(RGB(1e4, 1e4, 1e4))
        XCTAssertEqual(Swift.max(p.r, p.g, p.b), 65504)
        // No-op in range: an in-range product is the bare matrix product, bit for bit,
        // including the CreativeLUT `displayToWorking` matrix the GPU twin also serves.
        let lutStage = LinearStage(matrix: CreativeLUTStage.displayToWorking)
        for c in [RGB(0.2, 0.5, 0.9), RGB(1, 1, 1), RGB(0, 0, 0), RGB(-0.1, 0.4, 2)] {
            let a = lutStage.apply(c), b = CreativeLUTStage.displayToWorking.apply(c)
            XCTAssertEqual(a.r.bitPattern, b.r.bitPattern)
            XCTAssertEqual(a.g.bitPattern, b.g.bitPattern)
            XCTAssertEqual(a.b.bitPattern, b.b.bitPattern)
        }
        // And the identity skip is unchanged: the identity stage returns its input.
        let id = LinearStage(matrix: .identity)
        XCTAssertTrue(id.isIdentity)
        XCTAssertEqual(id.apply(RGB(1e6, -1e6, 3)).r, 1e6)
        Self.report("L13 EV+10 apply(64,1e3,1e4) = \(over), apply(−1e4,…) = \(under), "
                    + "apply(0.18) = \(grey.r) (= 0.18·1024)")
    }

    // MARK: - 14. End-to-end finite and white at +10

    func testReferenceFiniteAtTenStopsOverHalfMax() {
        let scene = [RGB(64, 64, 64), RGB(1e4, 1e4, 1e4), RGB(1e4, 50, 20)]
        let out = Self.render(scene, Self.ev(10))
        for (i, c) in out.enumerated() {
            XCTAssertTrue(c.r.isFinite && c.g.isFinite && c.b.isFinite, "pixel \(i): \(c)")
        }
        let neutralCodes = out.prefix(2).map { Self.code($0) }
        let minNeutral = neutralCodes.reduce(255.0) { Swift.min($0, $1.r, $1.g, $1.b) }
        Self.report("L14 EV+10 outputs = \(out); min neutral code = \(minNeutral)")
        XCTAssertGreaterThanOrEqual(minNeutral, 254.5)
    }
}

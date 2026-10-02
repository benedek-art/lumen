// ExactColorStageTests.swift
// The exact S9 stage (AI-03) against its independent oracle, on the Linux lane.
//
// The oracle is `ColorEngine.apply` in Double — the original CPU arithmetic, never a
// table and never the shader. The implementation under test is `ExactColorStage`: the
// resolved Float32 uniforms and the operation-for-operation twin of the four GPU
// kernels. The macOS suite (`ExactColorStageGPUTests`) runs the kernels themselves
// against the same oracle and the same bound.

import XCTest
@testable import LumenCore

final class ExactColorStageTests: XCTestCase {

    // MARK: - Corpus

    /// Float32-quantized, like every pixel the stage ever sees: neutrals from −20 to +12
    /// EV, a hue × chroma × exposure grid, the two AI-03 inputs, signed/HDR sentinels and
    /// seeded signed randoms.
    static let corpus: [RGB] = {
        func q(_ c: RGB) -> RGB { RGB(Double(Float(c.r)), Double(Float(c.g)), Double(Float(c.b))) }
        var out: [RGB] = [ColorTableAccuracyLinuxTests.aquaInput,
                          ColorTableAccuracyLinuxTests.saturationInput,
                          RGB(0, 0, 0), RGB(-0.05, 0.2, 0.4), RGB(3.283846139907837,
                          0.6904295086860657, -0.6745206713676453), RGB(40, 2, 0.5),
                          RGB(0.2, 0.4, 0.6)]
        for ev in stride(from: -20.0, through: 12.0, by: 0.5) {
            out.append(RGB(gray: 0.18 * pow(2, ev)))
        }
        let context = OKLabTransform.working
        for hue in stride(from: 0.0, to: 360.0, by: 7.5) {
            for chroma in [0.01, 0.03, 0.05, 0.09, 0.15, 0.25] {
                for L in [0.15, 0.4, 0.62, 0.85, 1.3] {
                    out.append(context.toRGB(OKLCh(L: L, C: chroma, h: hue)))
                }
            }
        }
        // Exactly on and beside every band seam and chroma gate.
        for centre in ColorEngine.bandHueCentres {
            for offset in [-22.5, -22.4999, 22.5, 22.5001] {
                for chroma in [0.02, 0.0200001, 0.06, 0.0599999] {
                    out.append(context.toRGB(OKLCh(L: 0.6, C: chroma,
                                                   h: Num.wrapHue(centre + offset))))
                }
            }
        }
        var state: UInt64 = 774_123
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / 9007199254740992
        }
        for _ in 0..<300 {
            out.append(RGB(next() * 1.4 - 0.2, next() * 1.4 - 0.2, next() * 1.4 - 0.2))
        }
        return out.map(q)
    }()

    // MARK: - Recipes: every family, both endpoints, and the combinations

    static func recipes() -> [(String, Recipe)] {
        var list: [(String, Recipe)] = []
        func add(_ name: String, _ edit: (inout Recipe) -> Void) {
            var r = Recipe()
            edit(&r)
            list.append((name, r))
        }
        for band in 0..<ColorEngine.bandCount {
            for v in [-100.0, 100] {
                add("mixer\(band).hue\(v)") { $0.develop.mixer.bands[band].hue = v }
                add("mixer\(band).sat\(v)") { $0.develop.mixer.bands[band].sat = v }
                add("mixer\(band).lum\(v)") { $0.develop.mixer.bands[band].lum = v }
            }
        }
        add("mixer.customArcs") {
            $0.develop.mixer.bands[4].lum = -100
            $0.develop.mixer.bands[4].core = [5, 44]
            $0.develop.mixer.bands[4].feather = [2, 60]
            $0.develop.mixer.bands[5].hue = 60
            $0.develop.mixer.bands[5].core = [44, 5]
        }
        add("uniformity100") { $0.develop.mixer.uniformity = 100 }
        add("uniformity60.withHue") {
            $0.develop.mixer.uniformity = 60
            $0.develop.mixer.bands[0].hue = 40
        }
        for (name, set) in [("rHue", \Primaries.rHue), ("gHue", \Primaries.gHue),
                            ("bHue", \Primaries.bHue), ("rPurity", \Primaries.rPurity),
                            ("gPurity", \Primaries.gPurity), ("bPurity", \Primaries.bPurity),
                            ("tintHue", \Primaries.tintHue),
                            ("tintPurity", \Primaries.tintPurity)] as [(String, WritableKeyPath<Primaries, Double>)] {
            for v in [-100.0, 100] {
                add("primaries.\(name)\(v)") { $0.look.primaries[keyPath: set] = v }
            }
        }
        let sky = PointColor(sample: [0.2, 0.4, 0.6], range: 0, variance: 0,
                             shift: HSLShift(h: 0, s: 0, l: -100))
        add("point.narrow") { $0.develop.pointColors = [sky] }
        add("point.overlap+variance") {
            $0.develop.pointColors = [
                PointColor(sample: [0.2, 0.4, 0.6], range: 100, variance: -100,
                           shift: HSLShift(h: 30, s: 50, l: 20)),
                PointColor(sample: [0.25, 0.42, 0.55], range: 60, variance: 100,
                           shift: HSLShift(h: -60, s: -100, l: -40)),
                PointColor(sample: [0.8, 0.5, 0.2], range: 50, variance: 0,
                           shift: HSLShift(h: 10, s: 100, l: 100)),
            ]
            // Moves the pixel before the swatches, so the fixed pre-Mixer reference
            // and the moving pixel are different numbers.
            $0.develop.mixer.bands[4].hue = 70
            $0.develop.mixer.bands[5].lum = -60
        }
        for v in [-100.0, 100] {
            add("vibrance\(v)") { $0.develop.color.vibrance = v }
            add("saturation\(v)") { $0.develop.color.saturation = v }
        }
        add("saturation100.density100.noSkin") {
            $0.develop.color.saturation = 100
            $0.develop.color.density = 100
            $0.develop.color.protectSkin = 0
        }
        add("vibrance60.saturation-40") {
            $0.develop.color.vibrance = 60
            $0.develop.color.saturation = -40
        }
        for band in 0..<ColorEngine.bandCount {
            for v in [-100.0, 100] {
                add("bw\(band).\(v)") {
                    var bw = BlackAndWhite()
                    bw.bands[band] = v
                    $0.look.bw = bw
                }
            }
        }
        add("bw.afterSaturation-100") {
            var bw = BlackAndWhite()
            bw.bands[4] = -80
            $0.look.bw = bw
            $0.develop.color.saturation = -100
        }
        add("everything") {
            $0.develop.mixer.bands[1].hue = 40
            $0.develop.mixer.bands[4].lum = -70
            $0.develop.mixer.uniformity = 30
            $0.look.primaries.rHue = 50
            $0.look.primaries.bPurity = -60
            $0.look.primaries.tintHue = 40
            $0.develop.pointColors = [sky]
            $0.develop.color.vibrance = 35
            $0.develop.color.saturation = 45
            $0.develop.color.density = 80
            var bw = BlackAndWhite()
            bw.bands[5] = -50
            $0.look.bw = bw
        }
        return list
    }

    static func engine(_ r: Recipe, bandMeanHues: [Double]? = nil) -> ColorEngine {
        ColorEngine(mixer: r.develop.mixer, pointColors: r.develop.pointColors,
                    color: r.develop.color, primaries: r.look.primaries, bw: r.look.bw,
                    bandMeanHues: bandMeanHues)
    }

    /// How much the ORACLE itself moves per unit input at `c` — the condition number a
    /// Float32 implementation cannot beat, measured by finite differences in Double.
    static func conditionNumber(_ e: ColorEngine, at c: RGB, scale: Double) -> Double {
        let base = e.apply(c)
        let step = 1e-6 * scale
        var worst = 0.0
        for k in 0..<3 {
            var p = c
            if k == 0 { p.r += step } else if k == 1 { p.g += step } else { p.b += step }
            worst = Swift.max(worst, e.apply(p).maxAbsDifference(base) / step)
        }
        return worst
    }

    /// The Float32 gate EXECUTION-05 set for the GPU raw stage,
    /// `|twin − oracle| ≤ 3e-5 · max(1, |input|, |expected|)`, plus the part no Float32
    /// arithmetic can avoid: the oracle's own condition number κ times eight ulps of
    /// input-equivalent rounding (5e-7). On a well-conditioned point κ ≈ 1 and the gate is
    /// the original 3e-5. Measured: the only corpus point that needs the κ term sits
    /// after a Mixer move inside three overlapping Variance swatches, κ ≈ 65, error
    /// 3.2e-5 (about 0.01 code). Returns the worst ratio error / gate.
    static func worstGateRatio(_ e: ColorEngine) -> (ratio: Double, error: Double, at: RGB) {
        let stage = e.exactStage
        var worst = (ratio: 0.0, error: 0.0, at: RGB(0, 0, 0))
        for c in corpus {
            let expected = e.apply(c)
            let actual = stage.apply(c)
            let scale = Swift.max(1, Swift.max(abs(c.r), abs(c.g), abs(c.b)),
                                  Swift.max(abs(expected.r), abs(expected.g), abs(expected.b)))
            let error = actual.maxAbsDifference(expected) / scale
            var gate = 3e-5
            if error > gate {
                gate += conditionNumber(e, at: c, scale: scale) * 5e-7
            }
            let ratio = error / gate
            if !(ratio <= worst.ratio) { worst = (ratio, error, c) }
        }
        return worst
    }

    func testTheTwinMatchesTheIndependentEngineOnEveryFamilyEndpoint() {
        var failures: [String] = []
        var overall = 0.0
        var overallError = 0.0
        var cases = Self.recipes().map { ($0.0, Self.engine($0.1)) }
        // Uniformity with a MEASURED target, which is a different code path from the
        // core-arc fallback.
        var r = Recipe()
        r.develop.mixer.uniformity = 100
        cases.append(("uniformity.measured",
                      Self.engine(r, bandMeanHues: ColorEngine.bandHueCentres.map {
                          Num.wrapHue($0 + 9) })))
        for (name, engine) in cases {
            XCTAssertFalse(engine.isIdentity, name)
            let worst = Self.worstGateRatio(engine)
            overall = Swift.max(overall, worst.ratio)
            overallError = Swift.max(overallError, worst.error)
            if !(worst.ratio <= 1) {
                failures.append("\(name): \(worst.error) at \(worst.at), \(worst.ratio)× its gate")
            }
        }
        print("EXACT_STAGE twin-vs-oracle worst normalized error \(overallError), worst "
              + "gate ratio \(overall), over \(Self.corpus.count) inputs × \(cases.count) recipes")
        XCTAssertEqual(failures, [])
    }

    // MARK: - Identity is exact, and identity is the engine's

    func testAnUntouchedStageIsAnExactNoOpWithNoPasses() {
        var off = Recipe()
        var bw = BlackAndWhite()
        bw.bands[4] = -80
        bw.enabled = false
        off.look.bw = bw
        off.develop.pointColors = [PointColor(sample: [0.2, 0.4, 0.6])]   // no shift
        for recipe in [Recipe(), off] {
            let engine = Self.engine(recipe)
            let stage = engine.exactStage
            XCTAssertTrue(engine.isIdentity)
            XCTAssertTrue(stage.isIdentity)
            XCTAssertEqual(stage.passes, [])
            for c in Self.corpus { XCTAssertEqual(stage.apply(c), c) }
            XCTAssertTrue(RenderPlan(recipe: recipe).colorStage.isIdentity)
        }
    }

    /// The finish pass is always last and always present on a live stage — it carries
    /// `ColorEngine.apply`'s non-finite fallback — and the other passes appear exactly
    /// when their family is live, in the engine's order.
    func testPassesAppearExactlyWhenTheirFamilyIsLiveInPipelineOrder() {
        func kinds(_ edit: (inout Recipe) -> Void) -> [ExactColorStage.Pass.Kernel] {
            var r = Recipe()
            edit(&r)
            return Self.engine(r).exactStage.passes.map(\.kernel)
        }
        XCTAssertEqual(kinds { $0.develop.color.saturation = 1 }, [.finish])
        XCTAssertEqual(kinds { $0.look.primaries.gHue = 1 }, [.primaries, .finish])
        XCTAssertEqual(kinds { $0.look.primaries.tintPurity = -1 }, [.primaries, .finish])
        XCTAssertEqual(kinds { $0.develop.mixer.uniformity = 1 }, [.mixer, .finish])
        XCTAssertEqual(kinds {
            $0.look.primaries.rHue = 5
            $0.develop.mixer.bands[3].hue = 5
            $0.develop.pointColors = Array(repeating: PointColor(
                sample: [0.2, 0.4, 0.6], shift: HSLShift(h: 5, s: 0, l: 0)), count: 11)
            var bw = BlackAndWhite()
            bw.bands[0] = 1
            $0.look.bw = bw
        }, [.primaries, .mixer] + Array(repeating: .point, count: 11) + [.finish],
           "every valid swatch gets its own pass — the recipe does not cap them at eight")
    }

    // MARK: - The membership floor that lets the kernel drop the fallback

    /// `bandWeights`' all-zero fallback is a hard edge; the kernel does not carry it.
    /// That is only sound if no arcs the sanitizer can produce reach it. Sweep every
    /// corner of the handle ranges, each band on its own and all at once.
    func testNoSanitizedArcsCanEmptyThePartition() {
        let lo = ColorEngine.bandCoreMinDegrees
        let hi = ColorEngine.bandCoreMaxDegrees
        let fLo = ColorEngine.bandFeatherMinDegrees
        let fHi = ColorEngine.bandFeatherMaxDegrees
        var worst = Float.infinity
        for core in [[lo, lo], [lo, hi], [hi, lo], [hi, hi]] {
            for feather in [[fLo, fLo], [fLo, fHi], [fHi, fLo], [fHi, fHi]] {
                var band = MixerBand()
                band.lum = -100
                band.core = core
                band.feather = feather
                let mixer = Mixer(bands: Array(repeating: band, count: ColorEngine.bandCount))
                let stage = ColorEngine(mixer: mixer, pointColors: [], color: ColorAdjust(),
                                        primaries: Primaries(), bw: nil).exactStage
                let u = stage.passes[0].uniforms
                for tenth in 0..<3600 {
                    let h = Float(tenth) / 10
                    var total: Float = 0
                    for i in 0..<8 { total += ExactColorTwin.membership(h, ExactColorTwin.e(u, 36 + i), u[11 + i]) }
                    worst = Swift.min(worst, total)
                }
            }
        }
        XCTAssertGreaterThan(worst, 1e-3,
                             "the partition can empty, so the kernel needs the fallback")
    }

    // MARK: - The kernels' declared signatures match what the graph will pass

    /// Linux cannot compile the kernels, but it can hold their SIGNATURES to the uniform
    /// lists the graph passes: a count mismatch is a kernel that fails at apply time on
    /// the Mac. And the argument budget: the Mixer is the widest pass at 29, the most
    /// the EXECUTION-05 exact-Mixer kernel (since retired) was qualified with on device.
    func testEveryKernelSignatureMatchesItsPassAndStaysInBudget() throws {
        var r = Recipe()
        r.look.primaries.rHue = 5
        r.look.primaries.tintHue = 5
        r.develop.mixer.bands[3].hue = 5
        r.develop.pointColors = [PointColor(sample: [0.2, 0.4, 0.6], variance: -40,
                                            shift: HSLShift(h: 5, s: 0, l: 0))]
        r.develop.color.saturation = 10
        r.look.bw = BlackAndWhite()
        let passes = Self.engine(r).exactStage.passes
        XCTAssertEqual(Set(passes.map(\.kernel)), Set(ExactColorStage.Pass.Kernel.allCases))
        for pass in passes {
            let source = ExactColorKernelSource.source(for: pass.kernel)
            let start = try XCTUnwrap(source.range(of: "kernel vec4 "))
            let open = try XCTUnwrap(source[start.upperBound...].firstIndex(of: "("))
            let close = try XCTUnwrap(source[open...].firstIndex(of: ")"))
            let parameters = source[source.index(after: open)..<close]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let samples = parameters.filter { $0.hasPrefix("__sample ") }.count
            let vectors = parameters.filter { $0.hasPrefix("vec4 ") }.count
            XCTAssertEqual(samples + vectors, parameters.count, "\(pass.kernel): \(parameters)")
            XCTAssertEqual(samples, pass.kernel == .point || pass.kernel == .finish ? 2 : 1,
                           "\(pass.kernel)")
            XCTAssertEqual(vectors, pass.uniforms.count, "\(pass.kernel)")
            XCTAssertLessThanOrEqual(parameters.count, 29, "\(pass.kernel)")
        }
    }

    // MARK: - No discontinuity when any control moves by 0.001

    /// EXECUTION-05's acceptance gate, and the reason the split is by stage: a route
    /// that changed with the recipe turned a 0.001 move into a 50-code jump. Every
    /// colour-stage control (and the grade, whose table appears at its first non-zero
    /// value) is nudged by 0.001 from three bases — neutral, the Aqua regression, and a
    /// many-control edit — through the CPU render path at the interactive cube size.
    /// The render path may move by no more than the exact operations move, plus 0.25
    /// code (EXECUTION-05's ordinary limit).
    func testNoControlJumpsWhenItMovesByAThousandth() {
        let inputs = Array(Self.corpus.filter {
            $0.minComponent > 0.005 && $0.maxComponent < 4
        }.prefix(400))
        func encoded(_ c: RGB) -> RGB { TransferFunction.srgb.encode(c) }
        func jump(_ a: Recipe, _ b: Recipe) -> (render: Double, exact: Double) {
            let pa = RenderPlan(recipe: a, lutSize: LUT3D.interactiveSize)
            let pb = RenderPlan(recipe: b, lutSize: LUT3D.interactiveSize)
            var render = 0.0, exact = 0.0
            for c in inputs {
                render = Swift.max(render, 255 * encoded(pa.referenceColor(c))
                    .maxAbsDifference(encoded(pb.referenceColor(c))))
                exact = Swift.max(exact, 255 * encoded(pa.exactColor(c))
                    .maxAbsDifference(encoded(pb.exactColor(c))))
            }
            return (render, exact)
        }
        var aqua = Recipe()
        aqua.develop.mixer.bands[4].lum = -100
        let many = Self.recipes().first { $0.0 == "everything" }!.1
        let d = 0.001
        var nudges: [(String, (inout Recipe) -> Void)] = [
            ("uniformity", { $0.develop.mixer.uniformity += d }),
            ("vibrance", { $0.develop.color.vibrance += d }),
            ("saturation", { $0.develop.color.saturation += d }),
            ("density", { $0.develop.color.density += d }),
            ("protectSkin", { $0.develop.color.protectSkin -= d }),
            ("rHue", { $0.look.primaries.rHue += d }),
            ("gPurity", { $0.look.primaries.gPurity += d }),
            ("bHue", { $0.look.primaries.bHue -= d }),
            ("tintHue", { $0.look.primaries.tintHue += d }),
            ("tintPurity", { $0.look.primaries.tintPurity += d }),
            ("new swatch", { $0.develop.pointColors.append(PointColor(
                sample: [0.6, 0.3, 0.2], shift: HSLShift(h: d, s: 0, l: 0))) }),
            // A swatch with no shift and no Variance compiles away; giving one 0.001 of
            // Variance is the smallest move that brings a swatch pass into being.
            ("new variance-only swatch", { $0.develop.pointColors.append(PointColor(
                sample: [0.2, 0.4, 0.6], variance: d)) }),
            ("existing swatch variance", {
                if $0.develop.pointColors.isEmpty {
                    $0.develop.pointColors = [PointColor(sample: [0.2, 0.4, 0.6], variance: d)]
                } else {
                    $0.develop.pointColors[0].variance += d
                }
            }),
            // B&W switched OFF with a mix kept: moving a band must not move a pixel, and
            // where the treatment is on (the "many" base) it moves by 0.001 of a band.
            ("B&W band", {
                if $0.look.bw == nil { $0.look.bw = BlackAndWhite(enabled: false) }
                $0.look.bw!.bands[2] += d }),
            ("grade global sat", { $0.look.wheels.global.sat += d }),
            ("grade shadows sat", { $0.look.wheels.shadows.sat += d }),
            ("grade brilliance", { $0.look.wheels.colorBalance.brilliance.global += d }),
        ]
        for band in [0, 4, 6] {
            nudges.append(("mixer\(band).hue", { $0.develop.mixer.bands[band].hue += d }))
            nudges.append(("mixer\(band).sat", { $0.develop.mixer.bands[band].sat -= d }))
            nudges.append(("mixer\(band).lum", { $0.develop.mixer.bands[band].lum += d }))
        }
        var failures: [String] = []
        var worstExcess = -Double.infinity
        for (baseName, base) in [("neutral", Recipe()), ("aqua", aqua), ("many", many)] {
            for (name, nudge) in nudges {
                var moved = base
                nudge(&moved)
                let j = jump(base, moved)
                worstExcess = Swift.max(worstExcess, j.render - j.exact)
                if !(j.render <= j.exact + 0.25) {
                    failures.append("\(baseName) + \(name): render jumped \(j.render) codes, "
                                    + "the exact operations \(j.exact)")
                }
            }
        }
        print("EXACT_STAGE continuity: worst render-minus-exact jump \(worstExcess) codes "
              + "over \(nudges.count * 3) nudges × \(inputs.count) inputs")
        XCTAssertEqual(failures, [])
    }
}

#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// The exact colour stage's four kernels on the actual GPU (AI-03), against the
/// independent oracle `ColorEngine.apply` and against their own Swift twin.
///
/// Ordinary assertions only. A kernel that does not compile is a failure, never a skip:
/// the stage is on the core roster, and the CPU fallback it would trigger is not what
/// this suite measures. The Linux suite (`ExactColorStageTests`) holds the twin to the
/// same oracle and the same gate on every family endpoint; this one closes the last gap,
/// the GPU's own transcendental approximations.
final class ExactColorStageGPUTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    private func engine(_ r: Recipe, hues: [Double]? = nil) -> ColorEngine {
        ColorEngine(mixer: r.develop.mixer, pointColors: r.develop.pointColors,
                    color: r.develop.color, primaries: r.look.primaries, bw: r.look.bw,
                    bandMeanHues: hues)
    }

    private func image(_ colours: [RGB]) -> CIImage {
        let bytes = colours.flatMap { [Float($0.r), Float($0.g), Float($0.b), Float(1)] }
        return CIImage(bitmapData: bytes.withUnsafeBufferPointer { Data(buffer: $0) },
                       bytesPerRow: colours.count * 16,
                       size: CGSize(width: colours.count, height: 1), format: .RGBAf,
                       colorSpace: space)
    }

    private func read(_ image: CIImage, format: CIFormat = .RGBAf) -> [RGB] {
        let context = CIContext(options: [.workingColorSpace: space,
                                          .workingFormat: format, .cacheIntermediates: false])
        let count = Int(image.extent.width)
        if format == .RGBAh {
            var bits = [UInt16](repeating: 0, count: count * 4)
            context.render(image, toBitmap: &bits, rowBytes: count * 8, bounds: image.extent,
                           format: .RGBAh, colorSpace: space)
            return (0..<count).map { i in
                RGB(Double(Float16(bitPattern: bits[i * 4])),
                    Double(Float16(bitPattern: bits[i * 4 + 1])),
                    Double(Float16(bitPattern: bits[i * 4 + 2])))
            }
        }
        var bytes = [Float](repeating: 0, count: count * 4)
        context.render(image, toBitmap: &bytes, rowBytes: count * 16, bounds: image.extent,
                       format: .RGBAf, colorSpace: space)
        return (0..<count).map { i in
            RGB(Double(bytes[i * 4]), Double(bytes[i * 4 + 1]), Double(bytes[i * 4 + 2]))
        }
    }

    /// Float32-quantized: neutrals, a hue × chroma × lightness grid, seams and gates,
    /// the AI-03 inputs, signed/HDR sentinels and seeded signed randoms.
    private func samples() -> [RGB] {
        let context = OKLabTransform.working
        var out: [RGB] = [RGB(0.38413364324424248, 0.59591710513566343, 0.64828909901873966),
                          RGB(0.78994447795661316, 0.51750730037644888, 0.21031789665386302),
                          RGB(-0.05, 0.2, 0.4), RGB(40, 2, 0.5), RGB(-2, -0.5, 3), .zero,
                          RGB(3.283846139907837, 0.6904295086860657, -0.6745206713676453)]
        for ev in stride(from: -20.0, through: 12.0, by: 0.5) {
            out.append(RGB(gray: 0.18 * pow(2, ev)))
        }
        for hue in stride(from: 0.0, to: 360.0, by: 7.5) {
            for chroma in [0.01, 0.03, 0.05, 0.09, 0.15, 0.25] {
                for L in [0.15, 0.4, 0.62, 0.85, 1.3] {
                    out.append(context.toRGB(OKLCh(L: L, C: chroma, h: hue)))
                }
            }
        }
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
        for _ in 0..<300 { out.append(RGB(next() * 1.4 - 0.2, next() * 1.4 - 0.2, next() * 1.4 - 0.2)) }
        return out.map { RGB(Double(Float($0.r)), Double(Float($0.g)), Double(Float($0.b))) }
    }

    private func recipes() -> [(String, Recipe)] {
        var list: [(String, Recipe)] = []
        func add(_ name: String, _ edit: (inout Recipe) -> Void) {
            var r = Recipe()
            edit(&r)
            list.append((name, r))
        }
        for band in 0..<ColorEngine.bandCount {
            for v in [-100.0, 100] {
                add("mixer\(band).hsl\(v)") {
                    $0.develop.mixer.bands[band].hue = v
                    $0.develop.mixer.bands[(band + 3) % 8].sat = v
                    $0.develop.mixer.bands[(band + 5) % 8].lum = v
                }
            }
        }
        add("uniformity100") { $0.develop.mixer.uniformity = 100 }
        for v in [-100.0, 100] {
            add("primaries\(v)") {
                $0.look.primaries.rHue = v
                $0.look.primaries.gPurity = v
                $0.look.primaries.bHue = -v
            }
            add("tint\(v)") {
                $0.look.primaries.tintHue = v
                $0.look.primaries.tintPurity = -v
            }
            add("vibrance\(v)") { $0.develop.color.vibrance = v }
            add("saturation\(v)") { $0.develop.color.saturation = v }
        }
        add("saturation.density") {
            $0.develop.color.saturation = 100
            $0.develop.color.density = 100
            $0.develop.color.protectSkin = 0
        }
        add("points") {
            $0.develop.mixer.bands[4].hue = 70
            $0.develop.pointColors = [
                PointColor(sample: [0.2, 0.4, 0.6], range: 100, variance: -100,
                           shift: HSLShift(h: 30, s: 50, l: 20)),
                PointColor(sample: [0.25, 0.42, 0.55], range: 0, variance: 100,
                           shift: HSLShift(h: -60, s: -100, l: -40)),
            ]
        }
        add("bw.afterSaturation") {
            var bw = BlackAndWhite()
            bw.bands = [80, -60, 40, -100, 100, -80, 60, -40]
            $0.look.bw = bw
            $0.develop.color.saturation = -100
        }
        return list
    }

    private func compare(_ e: ColorEngine, _ name: String, format: CIFormat = .RGBAf,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let input = samples()
        let stage = e.exactStage
        XCTAssertFalse(stage.isIdentity, name, file: file, line: line)
        let gpu = read(RenderGraph.applyColorStage(image(input), stage), format: format)
        var worst = 0.0
        var worstAt = ""
        for (c, actual) in zip(input, gpu) {
            XCTAssertTrue(actual.isFinite, "\(name) \(c)", file: file, line: line)
            let expected = e.apply(c)
            let scale = max(1, max(abs(c.r), abs(c.g), abs(c.b)),
                            max(abs(expected.r), abs(expected.g), abs(expected.b)))
            // The Linux gate (EXECUTION-05's float32 bound, plus the oracle's own
            // condition number times eight ulps — see `ExactColorStageTests`), or the
            // half-float bound EXECUTION-05 set for a real RGBAh destination.
            var gate = format == .RGBAh ? 0.003 : 3e-5
            let error = actual.maxAbsDifference(expected) / scale
            if error > gate { gate += conditionNumber(e, at: c, scale: scale) * 5e-7 }
            let ratio = error / gate
            if ratio > worst {
                worst = ratio
                worstAt = "\(c): GPU \(actual) oracle \(expected) twin \(stage.apply(c))"
            }
        }
        print("EXACT_STAGE_GPU \(name) format=\(format) worst gate ratio \(worst) at \(worstAt)")
        XCTAssertLessThan(worst, 1, "\(name): \(worstAt)", file: file, line: line)
        return worst
    }

    private func conditionNumber(_ e: ColorEngine, at c: RGB, scale: Double) -> Double {
        let base = e.apply(c)
        let step = 1e-6 * scale
        var worst = 0.0
        for k in 0..<3 {
            var p = c
            if k == 0 { p.r += step } else if k == 1 { p.g += step } else { p.b += step }
            worst = max(worst, e.apply(p).maxAbsDifference(base) / step)
        }
        return worst
    }

    func testEveryColourKernelCompiles() {
        for kind in ExactColorStage.Pass.Kernel.allCases {
            XCTAssertNotNil(KernelLibrary.colourKernel(kind), "\(kind) did not compile")
        }
    }

    func testTheKernelsMatchTheIndependentEngineOnEveryFamily() throws {
        for (name, recipe) in recipes() { _ = try compare(engine(recipe), name) }
        var r = Recipe()
        r.develop.mixer.uniformity = 100
        _ = try compare(engine(r, hues: ColorEngine.bandHueCentres.map { Num.wrapHue($0 + 9) }),
                        "uniformity.measured")
    }

    func testAHalfFloatDestinationStaysInsideTheHalfFloatBound() throws {
        for (name, recipe) in recipes().prefix(6) {
            _ = try compare(engine(recipe), name, format: .RGBAh)
        }
    }

    /// Alpha rides through every pass untouched.
    func testAlphaIsPreserved() throws {
        var r = Recipe()
        r.develop.mixer.bands[4].lum = -60
        r.develop.color.saturation = 40
        let bytes: [Float] = [0.3, 0.5, 0.6, 0.25]
        let source = CIImage(bitmapData: bytes.withUnsafeBufferPointer { Data(buffer: $0) },
                             bytesPerRow: 16, size: CGSize(width: 1, height: 1),
                             format: .RGBAf, colorSpace: space)
        let out = RenderGraph.applyColorStage(source, engine(r).exactStage)
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        var px = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 16, bounds: source.extent,
                       format: .RGBAf, colorSpace: space)
        XCTAssertEqual(px[3], 0.25, accuracy: 1e-6)
    }
}
#endif

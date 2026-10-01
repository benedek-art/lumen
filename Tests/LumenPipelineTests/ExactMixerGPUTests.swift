#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class ExactMixerGPUTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    private func engine(_ recipe: Recipe) -> ColorEngine {
        ColorEngine(mixer: recipe.develop.mixer, pointColors: recipe.develop.pointColors,
                    color: recipe.develop.color, primaries: recipe.look.primaries,
                    bw: recipe.look.bw)
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
            // Force a real half-float destination. Merely asking for a half
            // working context can still fuse this one-kernel graph into f32 output.
            var bits = [UInt16](repeating: 0, count: count * 4)
            context.render(image, toBitmap: &bits, rowBytes: count * 8, bounds: image.extent,
                           format: .RGBAh, colorSpace: space)
            return (0..<count).map { i in
                RGB(Double(Float16(bitPattern: bits[i*4])),
                    Double(Float16(bitPattern: bits[i*4+1])),
                    Double(Float16(bitPattern: bits[i*4+2])))
            }
        }
        var bytes = [Float](repeating: 0, count: count * 4)
        context.render(image, toBitmap: &bytes, rowBytes: count * 16, bounds: image.extent,
                       format: .RGBAf, colorSpace: space)
        return (0..<count).map { i in RGB(Double(bytes[i*4]), Double(bytes[i*4+1]),
                                         Double(bytes[i*4+2])) }
    }

    private func samples() -> [RGB] {
        var out: [RGB] = [RGB(0.38413364324424248, 0.59591710513566343, 0.64828909901873966),
                          RGB(-0.05, 0.2, 0.4), RGB(4, 2, 0.5), RGB(-2, -0.5, 3), .zero]
        for ev in stride(from: -20.0, through: 12.0, by: 0.5) {
            out.append(RGB(gray: 0.18 * pow(2, ev)))
        }
        for ev in [-12.0, -6, 0, 3, 8, 12] {
            for h in stride(from: 0.0, to: 360, by: 7.5) {
                for ratio in [0.01, 0.05, 0.25, 0.75] {
                    let l = cbrt(0.18 * pow(2, ev))
                    out.append(OKLabTransform.working.toRGB(OKLCh(L: l, C: l*ratio, h: h)))
                }
            }
        }
        // Exact seams and chroma-gate boundaries, including a small neighbourhood.
        for c in [0.019999, 0.02, 0.020001, 0.039999, 0.04, 0.059999, 0.06, 0.060001] {
            for h in [-0.0001, 0, 0.0001, 29.23, 51.73, 359.9999] {
                out.append(OKLabTransform.working.toRGB(OKLCh(L: 0.6, C: c, h: h)))
            }
        }
        var state: UInt64 = 774123
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / 9007199254740992
        }
        for _ in 0..<300 { out.append(RGB(random()*1.4-0.2, random()*1.4-0.2, random()*1.4-0.2)) }
        // Match the f32 source's actual input, avoiding an oracle disagreement caused
        // by input storage rather than by the colour operation.
        return out.map { $0.map { Double(Float($0)) } }
    }

    private func compare(_ recipe: Recipe, samples: [RGB], format: CIFormat = .RGBAf,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let mixer = try XCTUnwrap(engine(recipe).exactMixer, file: file, line: line)
        XCTAssertNotNil(ExactMixerGPU.kernel, "Kernel must compile, never skip parity", file: file, line: line)
        let rendered = try XCTUnwrap(ExactMixerGPU.apply(mixer, to: image(samples)), file: file, line: line)
        let actual = read(rendered, format: format)
        let oracle = engine(recipe)
        var worst = 0.0
        var worstAt = ""
        for (input, output) in zip(samples, actual) {
            let expected = oracle.apply(input)
            XCTAssertTrue(output.isFinite, "\(input)", file: file, line: line)
            let scale = max(1, input.maxAbsDifference(.zero), expected.maxAbsDifference(.zero))
            let bound = (format == .RGBAh ? 0.003 : 0.00003) * scale
            let error = output.maxAbsDifference(expected) / bound
            if error > worst { worst = error; worstAt = "\(input) GPU \(output) CPU \(expected)" }
        }
        print("EXACT_MIXER samples=\(samples.count) format=\(format) normalizedError=\(worst)")
        XCTAssertLessThan(worst, 1, "raw-stage normalized error \(worst) at \(worstAt)", file: file, line: line)
    }

    func testEveryBandEveryHSLEndpointMatchesTheIndependentEngine() throws {
        let colours = samples()
        for band in 0..<8 {
            for axis in 0..<3 {
                for amount in [-100.0, 100] {
                    var recipe = Recipe()
                    if axis == 0 { recipe.develop.mixer.bands[band].hue = amount }
                    if axis == 1 { recipe.develop.mixer.bands[band].sat = amount }
                    if axis == 2 { recipe.develop.mixer.bands[band].lum = amount }
                    try compare(recipe, samples: colours)
                }
            }
        }
    }

    func testCustomArcsOverlappingMovesAndHalfFloatRendering() throws {
        var r = Recipe()
        for i in 0..<8 {
            r.develop.mixer.bands[i] = MixerBand(hue: i % 2 == 0 ? -100 : 100,
                sat: Double(i)*25-100, lum: i % 2 == 0 ? 100 : -100,
                core: [i % 2 == 0 ? 5 : 44, i % 3 == 0 ? 44 : 5],
                feather: [i % 2 == 0 ? 2 : 60, i % 3 == 0 ? 60 : 2])
        }
        try compare(r, samples: samples())
        try compare(r, samples: samples(), format: .RGBAh)
    }

    func testOriginalAquaRegressionPassesAsAnIsolatedPrimitive() throws {
        var r = Recipe()
        r.develop.mixer.bands[4].lum = -100
        let value = samples()[0]
        let reference = engine(r)
        let output = read(try XCTUnwrap(ExactMixerGPU.apply(
            try XCTUnwrap(reference.exactMixer), to: image([value]))))[0]
        let expected = reference.apply(value)
        XCTAssertGreaterThan(value.minComponent, 0)
        XCTAssertGreaterThan(expected.minComponent, 0)
        XCTAssertTrue(output.isFinite)
        XCTAssertGreaterThan(output.maxComponent, 0.01)
        let error = 255 * TransferFunction.srgb.encode(output)
            .maxAbsDifference(TransferFunction.srgb.encode(expected))
        print("EXACT_MIXER_ORIGINAL_AQUA codeError=\(error)")
        XCTAssertLessThan(error, 3)
    }

    func testSignedConeCancellationDoesNotAmplifyMatrixLiteralRounding() throws {
        var r = Recipe()
        r.develop.mixer.bands[2].hue = 100
        // Already exactly representable as f32. The blue cone response is only
        // 4.45038678e-5 after cancellation. Source-literal matrices lost several
        // ULPs and failed this gate; the CPU matrices must arrive as uniforms.
        try compare(r, samples: [RGB(3.283846139907837, 0.6904295086860657,
                                     -0.6745206713676453)])
    }

    func testTheResolvedConversionContextIsNotSilentlyReplaced() throws {
        var r = Recipe()
        r.develop.mixer.bands[1].sat = -100
        let reference = ColorEngine(mixer: r.develop.mixer, pointColors: [],
            color: r.develop.color, primaries: r.look.primaries, bw: nil,
            context: OKLabTransform.Context(space: .srgb))
        let values = samples()
        let output = read(try XCTUnwrap(ExactMixerGPU.apply(
            try XCTUnwrap(reference.exactMixer), to: image(values))))
        for (input, actual) in zip(values, output) {
            let expected = reference.apply(input)
            let scale = max(1, input.maxAbsDifference(.zero), expected.maxAbsDifference(.zero))
            XCTAssertTrue(actual.isFinite)
            XCTAssertLessThan(actual.maxAbsDifference(expected), 0.00003 * scale)
        }
    }

    func testNeutralSignedHighlightsAndUnaffectedColoursAreNotClipped() throws {
        var r = Recipe()
        r.develop.mixer.bands[4].lum = -100
        let values = [RGB(gray: -0.2), RGB(gray: 0), RGB(gray: 2e-7), RGB(gray: 737.28),
                      RGB(-0.05, 0.2, 0.4), RGB(8, 4, 0.5)]
        let output = read(try XCTUnwrap(ExactMixerGPU.apply(try XCTUnwrap(engine(r).exactMixer),
                                                         to: image(values))))
        for i in 0..<4 { XCTAssertLessThan(output[i].maxAbsDifference(values[i]), 0.0001) }
        XCTAssertLessThan(output[4].minComponent, 0)
        XCTAssertGreaterThan(output[5].maxComponent, 1)
        try compare(r, samples: values)
    }

    func testPrimitiveComposesAfterTheExistingWBExposureAndPrinterLightStage() throws {
        var r = Recipe()
        r.develop.denoise.mode = .off
        r.develop.mixer.bands[4].lum = -100
        r.develop.mixer.bands[0].hue = 72
        r.develop.raw.temp = 4200
        r.develop.raw.tint = 15
        r.develop.tone.exposure = 1.25
        r.look.printerLights.master = 3
        let values = samples()
        for size in [17, 33, 65] {
            let plan = RenderPlan(recipe: r, lutSize: size)
            let prefix = RenderGraph().colorStageInput(image(values), plan: plan,
                options: .init(longEdge: values.count, lutSize: size))
            let output = read(try XCTUnwrap(ExactMixerGPU.apply(
                try XCTUnwrap(engine(r).exactMixer), to: prefix)))
            let colour = engine(r)
            var worst = 0.0
            for (input, actual) in zip(values, output) {
                let expected = colour.apply(plan.linear.apply(input))
                let scale = max(1, expected.maxAbsDifference(.zero))
                worst = max(worst, actual.maxAbsDifference(expected) / scale)
            }
            XCTAssertLessThan(worst, 0.0001)
        }
    }

    func testIneligibleCombinationAndUniformityKeepTheExistingFusedRoute() throws {
        for uniformity in [false, true] {
            var r = Recipe()
            r.develop.denoise.mode = .off
            r.develop.mixer.bands[4].lum = -100
            if uniformity { r.develop.mixer.uniformity = 40 }
            else { r.develop.color.saturation = 20 }
            let plan = RenderPlan(recipe: r, bandMeanHues: ColorEngine.bandHueCentres.map { $0+5 })
            XCTAssertNil(engine(r).exactMixer)
            let source = image(samples())
            let actual = RenderGraph().localStageInput(source, plan: plan,
                options: .init(longEdge: Int(source.extent.width)))
            let legacy = try XCTUnwrap(RenderGraph.throughShaper(source) {
                ColorCube.filter(plan.colorGradeLUT, image: $0)
            })
            for (a,b) in zip(read(actual),read(legacy)) {
                XCTAssertEqual(a.r, b.r, accuracy: 1e-6)
                XCTAssertEqual(a.g, b.g, accuracy: 1e-6)
                XCTAssertEqual(a.b, b.b, accuracy: 1e-6)
            }
        }
    }

    /// An exact operation cannot be enabled by a recipe-family switch that exposes
    /// the old LUT error as a large discontinuity. The experimental Mixer-only
    /// dispatch failed this by 50.18/36.91 codes at 33/65; keeping this gate prevents
    /// accidentally shipping that dispatch while its isolated kernel tests pass.
    func testShippingGraphHasNoNewMixerEligibilityBoundaryJump() throws {
        let colour = RGB(0.38413364324424248, 0.59591710513566343, 0.64828909901873966)
        var base = Recipe()
        base.develop.denoise.mode = .off
        base.develop.mixer.bands[4].lum = -100
        let changes: [(inout Recipe) -> Void] = [
            { $0.develop.color.saturation = 0.001 },
            { $0.develop.color.vibrance = 0.001 },
            { $0.develop.mixer.uniformity = 0.001 },
            { $0.look.primaries.rHue = 0.001 },
            { $0.look.primaries.tintHue = 0.001 },
            { $0.look.wheels.colorBalance.hueShift = 0.001 },
        ]
        for size in [33, 65] {
            func evaluate(_ r: Recipe) -> RGB {
                let plan = RenderPlan(recipe: r, lutSize: size)
                return read(RenderGraph().build(image([colour]), plan: plan,
                    options: .init(longEdge: 1, lutSize: size)))[0]
            }
            let before = TransferFunction.srgb.encode(evaluate(base))
            XCTAssertGreaterThan(before.maxComponent, 0.01)
            for change in changes {
                var recipe = base
                change(&recipe)
                let after = TransferFunction.srgb.encode(evaluate(recipe))
                XCTAssertTrue(after.isFinite)
                XCTAssertLessThan(255 * before.maxAbsDifference(after), 0.25,
                                  "A tiny legal move must not reveal a different rendering algorithm")
            }
        }
    }
}
#endif

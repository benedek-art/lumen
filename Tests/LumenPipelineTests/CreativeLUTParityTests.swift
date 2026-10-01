#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// The creative-LUT stage on the GPU against its reference (`CreativeLUTStage.apply`).
///
/// The comparison isolates the STAGE. Each case renders the graph twice — with the LUT
/// and without — and checks that the GPU's with-LUT pixel is the reference stage applied
/// to the GPU's own without-LUT pixel (display tap), or the GPU's without-LUT render of
/// the reference-premapped input (log tap). Everything else in the graph is common to
/// both renders, so whatever gap the rest of the graph has to the CPU reference cannot
/// leak into this measurement in either direction.
///
/// Two cubes. The red-inverting 2³ cube is AFFINE, where trilinear and tetrahedral
/// interpolation agree exactly, so it pins the plumbing — matrices, clamp, transfer
/// curves, blend — to float precision. The 17³ cube is a contrasty cross-channel
/// function, where Core Image's trilinear fetch and `LUT3D.sample`'s tetrahedral one
/// legitimately differ; its bound is in 8-bit sRGB code values.
final class CreativeLUTParityTests: XCTestCase {

    static let ref = "blob:xxh64:00000000000000aa"

    static let redInverting: LUT3D = {
        LUT3D.fromCubeFile("""
            LUT_3D_SIZE 2
            1 0 0
            0 0 0
            1 1 0
            0 1 0
            1 0 1
            0 0 1
            1 1 1
            0 1 1
            """)!
    }()

    /// A film-ish look: an S-curve per channel plus a little green into red.
    static let crossChannel = LUT3D(size: 17) { c in
        func s(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        return RGB(s(0.85 * c.r + 0.15 * c.g), s(c.g), 0.9 * s(c.b) + 0.05)
    }

    /// Scene-linear inputs spanning shadows to over-white, in and out of sRGB gamut.
    static let inputs: [RGB] = [
        RGB(0.01, 0.01, 0.01), RGB(0.18, 0.18, 0.18), RGB(0.6, 0.3, 0.1),
        RGB(0.05, 0.4, 0.7), RGB(1.2, 0.9, 0.4), RGB(0.02, 0.5, 0.03),
    ]

    private func render(_ recipe: Recipe, inputs: [RGB], library: CreativeLUTLibrary)
        throws -> [RGB] {
        var recipe = recipe
        recipe.develop.denoise.mode = .off
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let context = CIContext(options: [.workingColorSpace: space,
                                          .workingFormat: CIFormat.RGBAf,
                                          .cacheIntermediates: false])
        let width = inputs.count
        let source = inputs.flatMap { [Float($0.r), Float($0.g), Float($0.b), 1] }
        let data = source.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: 16 * width,
                            size: CGSize(width: width, height: 1), format: .RGBAf,
                            colorSpace: space)
        var graph = RenderGraph()
        graph.creativeLUTs = library
        let output = graph.build(image, plan: RenderPlan(recipe: recipe),
                                 options: RenderGraph.Options(longEdge: width))
        var bytes = [Float](repeating: 0, count: 4 * width)
        context.render(output, toBitmap: &bytes, rowBytes: 16 * width, bounds: image.extent,
                       format: .RGBAf, colorSpace: space)
        return (0..<width).map {
            RGB(Double(bytes[4 * $0]), Double(bytes[4 * $0 + 1]), Double(bytes[4 * $0 + 2]))
        }
    }

    private func recipe(_ tap: LUTReference.Tap, amount: Double) -> Recipe {
        var recipe = Recipe()
        recipe.look.lut = LUTReference(ref: Self.ref, name: "probe", tap: tap, amount: amount)
        return recipe
    }

    private func codeError(_ a: RGB, _ b: RGB) -> Double {
        let toDisplay = CreativeLUTStage.workingToDisplay
        let ea = TransferFunction.srgb.encode(toDisplay.apply(a).map(Num.saturate))
        let eb = TransferFunction.srgb.encode(toDisplay.apply(b).map(Num.saturate))
        return 255 * ea.maxAbsDifference(eb)
    }

    private func checkDisplayTap(_ cube: LUT3D, amount: Double, bound: Double) throws {
        let library = CreativeLUTLibrary()
        library.register(cube, for: Self.ref)
        let without = try render(Recipe(), inputs: Self.inputs, library: library)
        let with = try render(recipe(.display, amount: amount), inputs: Self.inputs,
                              library: library)
        let stage = CreativeLUTStage(tap: .display, amount: amount, cube: cube)
        var moved = 0.0
        for (gpu, base) in zip(with, without) {
            XCTAssertTrue(gpu.isFinite)
            let expected = stage.apply(base)
            moved = max(moved, codeError(base, expected))
            let error = codeError(gpu, expected)
            print("LUT_PARITY display amount=\(amount) base=\(base) gpu=\(gpu) "
                  + "ref=\(expected) codeError=\(error)")
            XCTAssertLessThan(error, bound, "display tap: GPU against the reference stage")
        }
        XCTAssertGreaterThan(moved, 5, "the cube barely moves these pixels; the bound proves nothing")
    }

    func testTheDisplayTapMatchesTheReferenceOnAnAffineCube() throws {
        try checkDisplayTap(Self.redInverting, amount: 100, bound: 0.05)
        try checkDisplayTap(Self.redInverting, amount: 35, bound: 0.05)
    }

    func testTheDisplayTapMatchesTheReferenceOnACurvedCube() throws {
        try checkDisplayTap(Self.crossChannel, amount: 100, bound: 1.0)
        try checkDisplayTap(Self.crossChannel, amount: 60, bound: 1.0)
    }

    func testTheLogTapMatchesTheReference() throws {
        let library = CreativeLUTLibrary()
        library.register(Self.redInverting, for: Self.ref)
        for amount in [100.0, 40.0] {
            let stage = CreativeLUTStage(tap: .log, amount: amount, cube: Self.redInverting)
            let with = try render(recipe(.log, amount: amount), inputs: Self.inputs,
                                  library: library)
            let premapped = try render(Recipe(), inputs: Self.inputs.map(stage.apply),
                                       library: library)
            for (gpu, expected) in zip(with, premapped) {
                let error = codeError(gpu, expected)
                print("LUT_PARITY log amount=\(amount) gpu=\(gpu) ref=\(expected) codeError=\(error)")
                XCTAssertLessThan(error, 0.5, "log tap: GPU against the reference stage")
            }
        }
    }

    /// No LUT, Amount 0 and a ref this machine has no bytes for all build the SAME
    /// graph: the stage is skipped outright, so the pixels are bit-identical.
    func testAnInertLUTLeavesTheGraphBitIdentical() throws {
        let library = CreativeLUTLibrary()
        library.register(Self.crossChannel, for: Self.ref)
        let baseline = try render(Recipe(), inputs: Self.inputs, library: library)
        var missing = recipe(.display, amount: 100)
        missing.look.lut?.ref = "blob:xxh64:00000000000000bb"
        for inert in [recipe(.display, amount: 0), recipe(.log, amount: 0), missing] {
            XCTAssertEqual(try render(inert, inputs: Self.inputs, library: library), baseline)
        }
    }
}
#endif

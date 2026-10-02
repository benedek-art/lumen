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
/// function, where the graph's trilinear fetch (`KernelLibrary.cubeLookup`, float) and
/// `LUT3D.sample`'s tetrahedral one legitimately differ; its bound is in 8-bit sRGB code
/// values. Restated on Linux, that gap on these inputs is at most 0.18 code (the darkest
/// one) and under 0.012 code everywhere else, so 1.0 leaves room for the GPU's float
/// arithmetic and nothing else.
final class CreativeLUTParityTests: XCTestCase {

    /// ONE REF PER CUBE. `CreativeLUTCubes` caches the uploaded bytes per ref for the
    /// whole process, which is right for a content-addressed ref (the same name is the
    /// same bytes) and wrong for a test that registers two different cubes under one
    /// name: whichever test ran second was handed the first one's cube. Each cube here
    /// is named for itself, as a real import would name it.
    static let affineRef = "blob:xxh64:00000000000000aa"
    static let curvedRef = "blob:xxh64:00000000000000cc"

    struct DeadRender: Error, CustomStringConvertible {
        let description: String
    }

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

    /// Rows in the rendered frame. Every row carries the same inputs, so the frame is
    /// row-invariant and the y convention cannot matter.
    static let rows = 4

    /// The graph's output, one value per input. The frame is built and read the way the
    /// whole-graph goldens build and read theirs (`KernelGoldenTests`,
    /// `ToneShippingGoldenTests`): untagged float RGBA, several rows, read back
    /// untagged in a linear Rec.2020 working space.
    ///
    /// A DEAD RENDER FAILS HERE. The first macOS run read back exactly zero for every
    /// pixel of every render this file made — with the LUT and without, at both taps.
    /// The display cases then reported 159 and 255 code values "off" (the reference
    /// stage applied to a black that was never rendered), while the log-tap and inert
    /// cases passed on `0 == 0`. Every input here renders well clear of black (the
    /// darkest is 0.0025 display-linear on the reference), so an all-zero pixel is a
    /// render that did not happen, never a measurement.
    private func render(_ recipe: Recipe, inputs: [RGB], library: CreativeLUTLibrary)
        throws -> [RGB] {
        var recipe = recipe
        recipe.develop.denoise.mode = .off
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let context = CIContext(options: [.workingColorSpace: space,
                                          .workingFormat: CIFormat.RGBAf,
                                          .cacheIntermediates: false])
        let width = inputs.count
        let height = Self.rows
        let row = inputs.flatMap { [Float($0.r), Float($0.g), Float($0.b), Float(1)] }
        let source = Array([[Float]](repeating: row, count: height).joined())
        let data = source.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: 16 * width,
                            size: CGSize(width: width, height: height), format: .RGBAf,
                            colorSpace: nil)
        var graph = RenderGraph()
        graph.creativeLUTs = library
        let output = graph.build(image, plan: RenderPlan(recipe: recipe),
                                 options: RenderGraph.Options(longEdge: width))
        XCTAssertEqual(output.extent, image.extent, "the graph moved the frame")
        var pixels = [Float](repeating: 0, count: 4 * width * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(output, toBitmap: base, rowBytes: 16 * width,
                           bounds: image.extent, format: .RGBAf, colorSpace: nil)
        }
        func pixel(_ x: Int, _ y: Int) -> RGB {
            let i = 4 * (y * width + x)
            return RGB(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
        return try (0..<width).map { (x: Int) throws -> RGB in
            let value = pixel(x, 0)
            for y in 0..<height {
                let other = pixel(x, y)
                guard other.isFinite, other.maxComponent > 1e-5 else {
                    throw DeadRender(description: "dead render: pixel (\(x), \(y)) read back "
                                     + "\(other) for input \(inputs[x]); nothing is measured")
                }
                XCTAssertLessThan(other.maxAbsDifference(value), 1e-6,
                                  "column \(x) is not row-invariant")
            }
            return value
        }
    }

    private func recipe(_ tap: LUTReference.Tap, amount: Double,
                        ref: String = CreativeLUTParityTests.curvedRef) -> Recipe {
        var recipe = Recipe()
        recipe.look.lut = LUTReference(ref: ref, name: "probe", tap: tap, amount: amount)
        return recipe
    }

    private func codeError(_ a: RGB, _ b: RGB) -> Double {
        let toDisplay = CreativeLUTStage.workingToDisplay
        let ea = TransferFunction.srgb.encode(toDisplay.apply(a).map(Num.saturate))
        let eb = TransferFunction.srgb.encode(toDisplay.apply(b).map(Num.saturate))
        return 255 * ea.maxAbsDifference(eb)
    }

    private func checkDisplayTap(_ cube: LUT3D, ref: String, amount: Double,
                                 bound: Double) throws {
        let library = CreativeLUTLibrary()
        library.register(cube, for: ref)
        let without = try render(Recipe(), inputs: Self.inputs, library: library)
        let with = try render(recipe(.display, amount: amount, ref: ref),
                              inputs: Self.inputs, library: library)
        let stage = CreativeLUTStage(tap: .display, amount: amount, cube: cube)
        var moved = 0.0
        var gpuMoved = 0.0
        for (gpu, base) in zip(with, without) {
            XCTAssertTrue(gpu.isFinite)
            let expected = stage.apply(base)
            moved = max(moved, codeError(base, expected))
            gpuMoved = max(gpuMoved, codeError(base, gpu))
            let error = codeError(gpu, expected)
            print("LUT_PARITY display amount=\(amount) base=\(base) gpu=\(gpu) "
                  + "ref=\(expected) codeError=\(error)")
            XCTAssertLessThan(error, bound, "display tap: GPU against the reference stage")
        }
        XCTAssertGreaterThan(moved, 5, "the cube barely moves these pixels; the bound proves nothing")
        XCTAssertGreaterThan(gpuMoved, 5, "the GPU stage did not run")
    }

    func testTheDisplayTapMatchesTheReferenceOnAnAffineCube() throws {
        try checkDisplayTap(Self.redInverting, ref: Self.affineRef, amount: 100, bound: 0.05)
        try checkDisplayTap(Self.redInverting, ref: Self.affineRef, amount: 35, bound: 0.05)
    }

    func testTheDisplayTapMatchesTheReferenceOnACurvedCube() throws {
        try checkDisplayTap(Self.crossChannel, ref: Self.curvedRef, amount: 100, bound: 1.0)
        try checkDisplayTap(Self.crossChannel, ref: Self.curvedRef, amount: 60, bound: 1.0)
    }

    func testTheLogTapMatchesTheReference() throws {
        let library = CreativeLUTLibrary()
        library.register(Self.redInverting, for: Self.affineRef)
        for amount in [100.0, 40.0] {
            let stage = CreativeLUTStage(tap: .log, amount: amount, cube: Self.redInverting)
            let with = try render(recipe(.log, amount: amount, ref: Self.affineRef),
                                  inputs: Self.inputs, library: library)
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
        library.register(Self.crossChannel, for: Self.curvedRef)
        let baseline = try render(Recipe(), inputs: Self.inputs, library: library)
        var missing = recipe(.display, amount: 100)
        missing.look.lut?.ref = "blob:xxh64:00000000000000bb"
        for inert in [recipe(.display, amount: 0), recipe(.log, amount: 0), missing] {
            XCTAssertEqual(try render(inert, inputs: Self.inputs, library: library), baseline)
        }
    }
}
#endif

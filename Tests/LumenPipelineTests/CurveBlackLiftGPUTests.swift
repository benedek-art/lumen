// AI-04 on the real GPU: a luma curve that lifts black, `[[0, .2], [1, 1]]`, over a
// neutral near-black grey ramp, rendered through `RenderGraph` — whose finish stage is
// Core Image's trilinear `CIColorCube` — at both production cube sizes.
//
// The audit measured scene 1e−8 coming out `[.027359, .006368, .067010]` at 33 and
// `[.048389, .011588, .117056]` at 65 where the exact answer is neutral .033596. The
// Linux twin, `CurveBlackLiftTests`, restates the trilinear filter over the same table;
// this one asks the GPU itself.

#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class CurveBlackLiftGPUTests: XCTestCase {

    func testANeutralNearBlackStaysNeutralOnTheGPUUnderALiftedLumaBlack() throws {
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.develop.curve = CurveSet(luma: [[0, 0.2], [1, 1]])
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let context = CIContext(options: [.workingColorSpace: space,
                                          .workingFormat: CIFormat.RGBAf,
                                          .cacheIntermediates: false])
        var failures: [String] = []
        for size in [LUT3D.interactiveSize, LUT3D.exportSize] {
            let plan = RenderPlan(recipe: recipe, lutSize: size)
            for scene in [1e-8, 1e-6, 1e-4, 1e-3] {
                let bytesIn: [Float] = [Float(scene), Float(scene), Float(scene), 1]
                let data = bytesIn.withUnsafeBufferPointer { Data(buffer: $0) }
                let source = CIImage(bitmapData: data, bytesPerRow: 16,
                                     size: CGSize(width: 1, height: 1), format: .RGBAf,
                                     colorSpace: space)
                let output = RenderGraph().build(source, plan: plan,
                                                 options: RenderGraph.Options(longEdge: 1))
                var bytes = [Float](repeating: 0, count: 4)
                context.render(output, toBitmap: &bytes, rowBytes: 16,
                               bounds: source.extent, format: .RGBAf, colorSpace: space)
                let actual = RGB(Double(bytes[0]), Double(bytes[1]), Double(bytes[2]))
                let exact = plan.exactColor(RGB(scene, scene, scene))
                XCTAssertTrue(actual.isFinite)
                // The lift alone is 0.0336 linear; an output under a third of that is an
                // unavailable GPU, not a measurement.
                XCTAssertGreaterThan(actual.maxComponent, 0.01, "Detect an unavailable GPU")
                let spread = actual.maxComponent - actual.minComponent
                if spread > 0.02 * actual.maxComponent {
                    failures.append("size \(size), scene \(scene): \(actual) is not "
                                    + "neutral (exact \(exact))")
                }
                if abs(actual.g - exact.g) > 0.02 * Swift.max(exact.g, 1e-6) {
                    failures.append("size \(size), scene \(scene): GPU \(actual) against "
                                    + "exact \(exact)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures: \(failures)")
    }
}
#endif

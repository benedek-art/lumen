#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Independent pixel-permutation oracle. Quarter turns, a horizontal reflection and
/// integer crops need no interpolation or copy of geometryRects/CropGeometry math.
/// This checks mask pixels and pointer coordinates in the same displayed frame;
/// CPU/GPU alpha agreement alone cannot detect a shared wrong orientation.
final class MaskGeometryOracleTests: XCTestCase {
    private let width = 96
    private let height = 64
    private let context = CIContext(options: [.workingColorSpace: NSNull(),
                                              .outputColorSpace: NSNull(),
                                              .workingFormat: CIFormat.RGBAf])

    private struct Placement {
        let angle: Double
        let flip: Bool
        let turn: Int
    }

    private let placements = [
        Placement(angle: 0, flip: false, turn: 0),
        Placement(angle: 90, flip: false, turn: 1),
        Placement(angle: -90, flip: false, turn: -1),
        Placement(angle: 180, flip: false, turn: 2),
        Placement(angle: 0, flip: true, turn: 0),
    ]

    /// Invert explicit array permutations, not the production transform. The crop
    /// removes exactly one eighth of each oriented dimension on every side.
    private func sourcePixel(x: Int, y: Int, placement p: Placement) -> (Int, Int) {
        let swapsAxes = abs(p.turn) == 1
        let orientedWidth = swapsAxes ? height : width
        let orientedHeight = swapsAxes ? width : height
        let u = x + orientedWidth / 8
        let v = y + orientedHeight / 8
        switch p.turn {
        case 1: return (v, height - 1 - u)
        case -1: return (width - 1 - v, u)
        case 2: return (width - 1 - u, height - 1 - v)
        default: return (p.flip ? width - 1 - u : u, v)
        }
    }

    private func geometry(_ p: Placement) -> Geometry {
        Geometry(crop: Crop(x: 0.125, y: 0.125, w: 0.75, h: 0.75),
                 angle: p.angle, flipH: p.flip)
    }

    private func squaredEllipseDistance(x: Int, y: Int) -> Double {
        let dx = ((Double(x) + 0.5) / Double(width) - 0.31) / 0.18
        let dy = ((Double(y) + 0.5) / Double(height) - 0.29) / 0.12
        return dx * dx + dy * dy
    }

    func testMaskPixelsFollowIndependentCropReflectionAndQuarterTurnOracle() throws {
        try XCTSkipUnless(KernelLibrary.parametricMasksAvailable, "mask kernels unavailable")
        var radial = MaskComponent(op: .add, kind: .radial)
        radial.center = [0.31, 0.29]
        radial.radii = [0.18, 0.12]
        radial.feather = 0
        let mask = Mask(id: "asymmetric-geometry-oracle", components: [radial])
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let cpu = MaskRaster.combine(mask: mask, size: (width: width, height: height))
        let cpuImage = try XCTUnwrap(PipelineRenderer.image(from: cpu, targetExtent: extent))
        let gpuImage = try XCTUnwrap(MaskGPU.alpha(for: mask, extent: extent))
        for p in placements {
            var recipe = Recipe()
            recipe.develop.geometry = geometry(p)
            for (name, alpha) in [("CPU bitmap bridge", cpuImage), ("GPU parametric", gpuImage)] {
                let displayed = PipelineRenderer.applyGeometry(alpha, recipe: recipe)
                let pixels = try XCTUnwrap(PipelineRenderer.buffer(from: displayed, context: context))
                let swapsAxes = abs(p.turn) == 1
                XCTAssertEqual(pixels.width, (swapsAxes ? height : width) * 3 / 4)
                XCTAssertEqual(pixels.height, (swapsAxes ? width : height) * 3 / 4)
                var inside = 0, outside = 0, wrongVerticalDisagreements = 0
                for y in 0..<pixels.height {
                    for x in 0..<pixels.width {
                        let (sx, sy) = sourcePixel(x: x, y: y, placement: p)
                        let d2 = squaredEllipseDistance(x: sx, y: sy)
                        // Deliberately exclude the edge: this is an orientation proof,
                        // not a new antialiasing or feather-quality tolerance.
                        guard d2 < 0.5 || d2 > 1.5 else { continue }
                        let expected = d2 < 0.5 ? 1.0 : 0.0
                        if expected == 1 { inside += 1 } else { outside += 1 }
                        XCTAssertEqual(pixels[x, y].r, expected, accuracy: 1e-4,
                                       "\(name), angle \(p.angle), flip \(p.flip), pixel \(x),\(y)")
                        let wrongD2 = squaredEllipseDistance(x: sx, y: height - 1 - sy)
                        if (expected == 1 && wrongD2 > 1.5) || (expected == 0 && wrongD2 < 0.5) {
                            wrongVerticalDisagreements += 1
                        }
                    }
                }
                XCTAssertGreaterThan(inside, 50, "fixture must contain a selected interior")
                XCTAssertGreaterThan(outside, 100, "fixture must contain an unselected exterior")
                XCTAssertGreaterThan(wrongVerticalDisagreements, 50,
                                     "a vertically mirrored mask must fail this oracle")
            }
        }
    }

    func testPointerCoordinatesFollowIndependentPixelPermutationOracle() {
        for p in placements {
            let swapsAxes = abs(p.turn) == 1
            let outputWidth = (swapsAxes ? height : width) * 3 / 4
            let outputHeight = (swapsAxes ? width : height) * 3 / 4
            for y in stride(from: 3, to: outputHeight, by: 7) {
                for x in stride(from: 2, to: outputWidth, by: 9) {
                    let u = (Double(x) + 0.5) / Double(outputWidth)
                    let v = (Double(y) + 0.5) / Double(outputHeight)
                    let (sx, sy) = sourcePixel(x: x, y: y, placement: p)
                    let expectedX = (Double(sx) + 0.5) / Double(width)
                    let expectedY = (Double(sy) + 0.5) / Double(height)
                    let source = PipelineRenderer.sourceNormalized(
                        displayedX: u, displayedY: v, geometry: geometry(p),
                        sourceSize: CGSize(width: width, height: height))
                    XCTAssertEqual(Double(source.x), expectedX, accuracy: 1e-12)
                    XCTAssertEqual(Double(source.y), expectedY, accuracy: 1e-12)
                    let displayed = PipelineRenderer.displayedNormalized(
                        sourceX: expectedX, sourceY: expectedY, geometry: geometry(p),
                        sourceSize: CGSize(width: width, height: height))
                    XCTAssertEqual(Double(displayed.x), u, accuracy: 1e-12)
                    XCTAssertEqual(Double(displayed.y), v, accuracy: 1e-12)
                }
            }
        }
    }
}
#endif

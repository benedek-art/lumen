#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Shipping Core Image geometry, not ReferenceRenderer. Expected placement is an
/// explicit array turn, reflection and crop; it never calls production geometry
/// arithmetic. Tests intentionally combine operations absent from the older oracle.
final class MaskGeometryCompositionOracleTests: XCTestCase {
    private let width = 96
    private let height = 64
    private let context = CIContext(options: [.workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])

    private struct Pixel {
        let x: Int
        let y: Int
    }
    private struct Mismatches {
        var count = 0
        var maximumError = 0.0
        var first: String?
        mutating func check(_ actual: Double, _ expected: Double, tolerance: Double,
                            at location: String) {
            let error = actual.isFinite && expected.isFinite ? abs(actual - expected) : .infinity
            guard error > tolerance else { return }
            count += 1
            maximumError = max(maximumError, error)
            if first == nil { first = "\(location): actual=\(actual), expected=\(expected)" }
        }
        var description: String { "mismatches=\(count), maxError=\(maximumError), first=\(first ?? "none")" }
    }
    private enum Reflection: String, CaseIterable { case none, horizontal, vertical }
    private struct Case {
        let turn: Int
        let reflection: Reflection
        var description: String { "turn=\(turn), reflection=\(reflection.rawValue)" }
        var geometry: Geometry {
            // The schema has H only. H after an additional half-turn is V after
            // the original turn: F·R(a+180)=V·R(a). Wrap into [-180,180].
            var degrees = turn * 90 + (reflection == .vertical ? 180 : 0)
            if degrees > 180 { degrees -= 360 }
            return Geometry(crop: Crop(x: 0.125, y: 0.125, w: 0.625, h: 0.5),
                            angle: Double(degrees), flipH: reflection != .none)
        }
    }
    private var cases: [Case] {
        [-1, 1, 2].flatMap { turn in Reflection.allCases.map { Case(turn: turn, reflection: $0) } }
    }

    private func clockwise(_ input: [[Pixel]]) -> [[Pixel]] {
        // Walk old rows bottom-to-top, appending each cell to its new row.
        var rows = Array(repeating: [Pixel](), count: input[0].count)
        for row in input.reversed() {
            for (column, pixel) in row.enumerated() { rows[column].append(pixel) }
        }
        return rows
    }

    private func expected(_ placement: Case) -> [[Pixel]] {
        var rows = (0..<height).map { y in (0..<width).map { Pixel(x: $0, y: y) } }
        switch placement.turn {
        case 1: rows = clockwise(rows)
        case -1: rows = clockwise(clockwise(clockwise(rows)))
        case 2: rows = rows.reversed().map { Array($0.reversed()) }
        default: preconditionFailure("unsupported independent permutation")
        }
        switch placement.reflection {
        case .horizontal: rows = rows.map { Array($0.reversed()) }
        case .vertical: rows.reverse()
        case .none: break
        }
        let left = rows[0].count / 8
        let top = rows.count / 8
        let cropWidth = rows[0].count * 5 / 8
        let cropHeight = rows.count / 2
        return rows[top..<(top + cropHeight)].map { Array($0[left..<(left + cropWidth)]) }
    }

    private func labeled(_ pixel: Pixel) -> RGB {
        RGB(Double(pixel.x) / Double(width - 1),
            Double(pixel.y) / Double(height - 1),
            Double(pixel.y * width + pixel.x) / Double(width * height - 1))
    }

    func testShippingGeometryMatchesCombinedArrayPermutationAtEveryPixel() throws {
        var source = ImageBuffer(width: width, height: height)
        for y in 0..<height { for x in 0..<width { source[x, y] = labeled(Pixel(x: x, y: y)) } }
        let data = source.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data,
            bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
        for placement in cases {
            var recipe = Recipe(); recipe.develop.geometry = placement.geometry
            let delivered = PipelineRenderer.applyGeometry(image, recipe: recipe)
            let pixels = try XCTUnwrap(PipelineRenderer.buffer(from: delivered, context: context))
            let oracle = expected(placement)
            XCTAssertEqual(pixels.width, oracle[0].count, placement.description)
            XCTAssertEqual(pixels.height, oracle.count, placement.description)
            guard pixels.width == oracle[0].count, pixels.height == oracle.count else { continue }
            var errors = Mismatches()
            for y in oracle.indices { for x in oracle[y].indices {
                let value = labeled(oracle[y][x])
                errors.check(pixels[x, y].r, value.r, tolerance: 1e-4, at: "\(x),\(y).r")
                errors.check(pixels[x, y].g, value.g, tolerance: 1e-4, at: "\(x),\(y).g")
                errors.check(pixels[x, y].b, value.b, tolerance: 1e-4, at: "\(x),\(y).b")
            } }
            XCTAssertEqual(errors.count, 0, "\(placement.description): \(errors.description)")
        }
    }

    func testInversePointerAndStoredEndpointUseTheSameIndependentSourcePixels() {
        for placement in cases {
            let oracle = expected(placement)
            var errors = Mismatches()
            for y in oracle.indices { for x in oracle[y].indices {
                // Includes the four retained corner pixel centers and every row's
                // endpoints; these can be stored brush release points. No GUI claim.
                let u = (Double(x) + 0.5) / Double(oracle[y].count)
                let v = (Double(y) + 0.5) / Double(oracle.count)
                let original = oracle[y][x]
                let nx = (Double(original.x) + 0.5) / Double(width)
                let ny = (Double(original.y) + 0.5) / Double(height)
                let source = PipelineRenderer.sourceNormalized(displayedX: u, displayedY: v,
                    geometry: placement.geometry, sourceSize: CGSize(width: width, height: height))
                errors.check(Double(source.x), nx, tolerance: 1e-12, at: "\(x),\(y).sourceX")
                errors.check(Double(source.y), ny, tolerance: 1e-12, at: "\(x),\(y).sourceY")
                let display = PipelineRenderer.displayedNormalized(sourceX: nx, sourceY: ny,
                    geometry: placement.geometry, sourceSize: CGSize(width: width, height: height))
                errors.check(Double(display.x), u, tolerance: 1e-12, at: "\(x),\(y).displayX")
                errors.check(Double(display.y), v, tolerance: 1e-12, at: "\(x),\(y).displayY")
            } }
            XCTAssertEqual(errors.count, 0, "\(placement.description): \(errors.description)")
        }
    }

    func testMaskInteriorAndExteriorFollowCombinedPermutation() throws {
        try XCTSkipUnless(KernelLibrary.parametricMasksAvailable, "mask kernels unavailable")
        var radial = MaskComponent(op: .add, kind: .radial)
        radial.center = [0.41, 0.43]; radial.radii = [0.18, 0.12]; radial.feather = 0
        let mask = Mask(id: "combined-geometry-oracle", components: [radial])
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let cpu = MaskRaster.combine(mask: mask, size: (width: width, height: height))
        let bitmap = try XCTUnwrap(PipelineRenderer.image(from: cpu, targetExtent: extent))
        let gpu = try XCTUnwrap(MaskGPU.alpha(for: mask, extent: extent))
        for placement in cases {
            let oracle = expected(placement)
            for (name, image) in [("CPU raster bridge", bitmap), ("GPU parametric", gpu)] {
                var recipe = Recipe(); recipe.develop.geometry = placement.geometry
                let displayed = PipelineRenderer.applyGeometry(image, recipe: recipe)
                let pixels = try XCTUnwrap(PipelineRenderer.buffer(from: displayed, context: context))
                XCTAssertEqual(pixels.width, oracle[0].count, placement.description)
                XCTAssertEqual(pixels.height, oracle.count, placement.description)
                guard pixels.width == oracle[0].count, pixels.height == oracle.count else { continue }
                var inside = 0, outside = 0
                var errors = Mismatches()
                for y in oracle.indices { for x in oracle[y].indices {
                    let original = oracle[y][x]
                    let dx = ((Double(original.x) + 0.5) / Double(width) - 0.41) / 0.18
                    let dy = ((Double(original.y) + 0.5) / Double(height) - 0.43) / 0.12
                    let d2 = dx * dx + dy * dy
                    // Same edge exclusion and tolerance as MaskGeometryOracleTests:
                    // orientation qualification, not new feather/AA acceptance.
                    guard d2 < 0.5 || d2 > 1.5 else { continue }
                    let alpha = d2 < 0.5 ? 1.0 : 0.0
                    if alpha == 1 { inside += 1 } else { outside += 1 }
                    errors.check(pixels[x, y].r, alpha, tolerance: 1e-4, at: "\(x),\(y).alpha")
                } }
                XCTAssertEqual(errors.count, 0, "\(name), \(placement.description): \(errors.description)")
                XCTAssertGreaterThan(inside, 30, placement.description)
                XCTAssertGreaterThan(outside, 100, placement.description)
            }
        }
    }
}
#endif

// WS-29 SPEC S6: the shipped looks are ordinary looks — they decode through the catalog's
// path, carry only Look fields, apply and blend through `applied(to:)`, and render a
// finite picture that does not clip what the plain render keeps.

import Foundation
import XCTest
@testable import LumenCore

final class BuiltInLooksTests: XCTestCase {

    static let frame = ImageBuffer(width: 48, height: 24) { u, v in
        RGB(0.004 + 0.7 * u * u, 0.01 + 0.4 * v, 0.03 + 0.25 * (1 - u) * v)
    }

    func testS6EightLooksWithDistinctNamesThatDecode() throws {
        XCTAssertEqual(BuiltInLooks.all.count, 8)
        XCTAssertEqual(Set(BuiltInLooks.all.map { $0.name.lowercased() }).count, 8)
        for look in BuiltInLooks.all {
            let subset = try look.subset()
            XCTAssertNotEqual(subset.look, Look(), "\(look.name) decodes to no look")
            XCTAssertEqual(subset.amount, LookSubset.fullAmount)
            XCTAssertNil(subset.look.lut, "\(look.name): built-ins carry no LUT")
            XCTAssertEqual(LookSubset.normalizedName(look.name), look.name)
            XCTAssertLessThan(look.row(index: 0).id, 0)
        }
    }

    /// Every look renders finite, moves the picture, keeps develop untouched, clips at
    /// most 0.5% more of the frame to white than the plain render, and at 50% lands
    /// between the frame and the look.
    func testS6EveryLookAppliesRendersAndBlends() throws {
        func render(_ r: Recipe) -> ImageBuffer {
            var r = r
            r.develop.denoise.mode = .off
            return ReferenceRenderer.render(Self.frame, plan: RenderPlan(recipe: r))
        }
        func clipped(_ image: ImageBuffer) -> Double {
            var n = 0
            for i in stride(from: 0, to: image.pixels.count, by: 4)
            where max(image.pixels[i], image.pixels[i + 1], image.pixels[i + 2]) >= 0.999 { n += 1 }
            return Double(n) / Double(image.pixels.count / 4)
        }
        func distance(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
            zip(a.pixels, b.pixels).reduce(0) { $0 + abs(Double($1.0) - Double($1.1)) }
                / Double(a.pixels.count)
        }
        var target = Recipe()
        target.develop.tone.exposure = 0.3
        let base = render(target)
        for look in BuiltInLooks.all {
            var subset = try look.subset()
            let full = subset.applied(to: target)
            XCTAssertEqual(full.develop, target.develop, look.name)
            let picture = render(full)
            XCTAssertTrue(picture.pixels.allSatisfy { $0.isFinite }, look.name)
            let d = distance(picture, base)
            XCTAssertGreaterThan(d, 1e-3, "\(look.name) barely changes the picture")
            XCTAssertLessThan(clipped(picture), clipped(base) + 0.005, "\(look.name) clips")
            subset.amount = 50
            let half = distance(render(subset.applied(to: target)), base)
            XCTAssertGreaterThan(half, 0.15 * d, look.name)
            // Strictly short of the look, not "near half": a preset change or the B&W
            // switch lands whole at any Amount (`LookSubset.blendedTreatment`), so the
            // looks built on one sit at 87–92% of their distance at 50%.
            // Cool Cinema sits at 100.01%: its Film Base curve is the whole move, and
            // its faint wheels partly cancel that curve's cast. 1% is the slack.
            XCTAssertLessThan(half, 1.01 * d, look.name)
        }
    }
}

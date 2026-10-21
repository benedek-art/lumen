// VignetteCropFieldTests.swift
// WS-41 SPEC lines 22-23: the vignette's coordinate field is laid out on the delivered
// crop, with straighten and flip, and the reference renderer uses it.
//
// The expected values are written INDEPENDENTLY of `VignetteField`: the orientation as a
// rotation and a mirror of a y-up point, the delivered rectangle from the crop's own
// fractions of the inscribed frame, and u, v exactly as the macOS
// `VignetteGeometryContractTests.check` takes them from the delivered extent.

import XCTest
@testable import LumenCore

final class VignetteCropFieldTests: XCTestCase {

    /// The delivered-frame u, v of the source pixel (column, row) for this geometry.
    private func delivered(_ geo: Geometry, w: Double, h: Double,
                           column: Int, row: Int) -> (u: Double, v: Double) {
        // Core Image's point for the pixel centre: y up.
        let x = Double(column) + 0.5, y = h - Double(row) - 0.5
        // geometryRects' orientation: rotate by −angle (counter-clockwise positive), then
        // mirror x when flipped.
        let theta = -geo.angle * .pi / 180
        func orient(_ px: Double, _ py: Double) -> (Double, Double) {
            let rx = px * cos(theta) - py * sin(theta)
            let ry = px * sin(theta) + py * cos(theta)
            return geo.flipH ? (-rx, ry) : (rx, ry)
        }
        let p = orient(x, y)
        // The rotated picture keeps its centre; the usable frame is centred on it and the
        // crop is a fraction of that frame from its TOP-left.
        let c = orient(w / 2, h / 2)
        let usable = CropGeometry.usableSize(width: w, height: h, degrees: geo.angle)
        let crop = CropGeometry.normalized(geo.crop)
        let left = c.0 - usable.width / 2 + crop.x * usable.width
        let top = c.1 + usable.height / 2 - crop.y * usable.height
        let right = left + crop.w * usable.width
        let bottom = top - crop.h * usable.height
        // The integral delivered rectangle.
        let x0 = left.rounded(.down), x1 = right.rounded(.up)
        let y0 = bottom.rounded(.down), y1 = top.rounded(.up)
        // VignetteGeometryContractTests.check's u, v.
        let u = 2 * (p.0 - x0) / (x1 - x0) - 1
        let v = 2 * (p.1 - y0) / (y1 - y0) - 1
        return (u, v)
    }

    private func rho(_ u: Double, _ v: Double) -> Double { sqrt((u * u + v * v) / 2) }

    func testTheSharedFieldIsTheDeliveredFrame() {
        let (w, h) = (640.0, 480.0)
        var geometries: [Geometry] = []
        for angle in [-13.0, 13, 90, -90, 0, -7] {
            for flip in [false, true] {
                geometries.append(Geometry(crop: Crop(x: 0.08, y: 0.21, w: 0.64, h: 0.33),
                                           angle: angle, flipH: flip))
            }
        }
        geometries.append(Geometry(crop: Crop(x: 0.1, y: 0.1, w: 0.35, h: 0.7)))
        geometries.append(Geometry(crop: Crop(x: 0.125, y: 0.125, w: 0.375, h: 0.75),
                                   flipH: true))
        for geo in geometries {
            let field = VignetteField(geometry: geo, sourceWidth: w, sourceHeight: h)
            var worst = 0.0
            for row in stride(from: 0, to: 480, by: 7) {
                for column in stride(from: 0, to: 640, by: 7) {
                    let got = field.uv(column: column, row: row)
                    let want = delivered(geo, w: w, h: h, column: column, row: row)
                    worst = max(worst, abs(rho(got.u, got.v) - rho(want.u, want.v)))
                }
            }
            XCTAssertLessThanOrEqual(worst, 1e-9, "geometry \(geo)")
        }
    }

    /// The reference renderer lays the vignette out on the recipe's crop: its output is
    /// `DetailEngine.vignette` with the plan's geometry, and a crop moves the picture.
    func testTheReferenceRendererPassesTheGeometry() {
        let frame = ImageBuffer(width: 96, height: 64) { _, _ in RGB(gray: 0.18) }
        var recipe = Recipe()
        recipe.look.vignette = -2
        recipe.look.vignetteMidpoint = 30
        recipe.develop.geometry = Geometry(crop: Crop(x: 0.125, y: 0.125, w: 0.375, h: 0.75),
                                           angle: 4, flipH: true)
        let plan = RenderPlan(recipe: recipe)
        var uncropped = recipe
        uncropped.develop.geometry = Geometry()
        let rendered = ReferenceRenderer.render(frame, plan: plan)
        let other = ReferenceRenderer.render(frame, plan: RenderPlan(recipe: uncropped))
        XCTAssertNotEqual(rendered.pixels, other.pixels, "the crop did not reach the vignette")
        // And the stage itself, called with the plan's geometry, is what moved.
        let staged = DetailEngine.vignette(frame, plan.vignette,
                                           geometry: plan.recipe.develop.geometry)
        let flat = DetailEngine.vignette(frame, plan.vignette, geometry: Geometry())
        XCTAssertNotEqual(staged.pixels, flat.pixels)
        XCTAssertEqual(staged[60, 32].g, 0.18 * pow(2, -2.0 * DetailEngine.vignetteProfile(
            radius: { () -> Double in
                let f = VignetteField(geometry: plan.recipe.develop.geometry,
                                      sourceWidth: 96, sourceHeight: 64)
                let p = f.uv(column: 60, row: 32)
                return DetailEngine.vignetteRadius(u: p.u, v: p.v, exponent: 2, weight: 1)
            }(),
            lower: DetailEngine.vignetteEdges(midpoint: 30, feather: 50,
                                              pixelHalfDiagonal: 1).lower,
            upper: DetailEngine.vignetteEdges(midpoint: 30, feather: 50,
                                              pixelHalfDiagonal: 1).upper)),
            accuracy: 1e-6)
    }

    /// Line 22's claim on the analytic field: the crop rectangle of an uncropped frame
    /// carries exactly the vignette of a frame the crop's own size.
    func testTheCropCarriesTheVignetteOfAFrameItsOwnSize() {
        let geo = Geometry(crop: Crop(x: 0.125, y: 0.125, w: 0.375, h: 0.75))
        let big = VignetteField(geometry: geo, sourceWidth: 768, sourceHeight: 512)
        let small = VignetteField(sourceWidth: 288, sourceHeight: 384)
        for row in stride(from: 0, to: 384, by: 5) {
            for column in stride(from: 0, to: 288, by: 5) {
                let a = big.uv(column: column + 96, row: row + 64)
                let b = small.uv(column: column, row: row)
                XCTAssertEqual(a.u, b.u, accuracy: 1e-12)
                XCTAssertEqual(a.v, b.v, accuracy: 1e-12)
            }
        }
    }
}

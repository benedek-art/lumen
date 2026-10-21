// WS-29 acceptance (docs/quality/lanes/WS-29/SPEC.md): a saved look applies, blends and
// travels reliably — measured on rendered pictures, not only on recipe fields.

import Foundation
import XCTest
@testable import LumenCore

final class SavedLookReliabilityTests: XCTestCase {

    /// A look that touches every blendable family at once: wheels (with a hue across
    /// red's 0/360 seam), the advanced grid, printer lights, primaries, vignette, grain
    /// and the display-transform overrides.
    static var busyLook: Look {
        var look = Look()
        look.wheels.shadows = Wheel(hue: 205, sat: 0.3, lum: -0.1)
        look.wheels.high = Wheel(hue: 350, sat: 0.25, lum: 0.05)
        look.wheels.colorBalance.vibrance = 20
        look.printerLights = PrinterLights(master: 2, r: 3, g: 0, b: -2)
        look.primaries = Primaries(rHue: 15, rPurity: -10, bHue: -10)
        look.vignette = -0.6
        look.render.contrast = 1.3
        return look
    }

    static let frame = ImageBuffer(width: 48, height: 24) { u, v in
        RGB(0.01 + 0.9 * u * u, 0.02 + 0.5 * v, 0.05 + 0.3 * (1 - u) * v)
    }

    private func render(_ recipe: Recipe) -> ImageBuffer {
        var recipe = recipe
        recipe.develop.denoise.mode = .off
        return ReferenceRenderer.render(Self.frame, plan: RenderPlan(recipe: recipe))
    }

    private func meanDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var sum = 0.0
        for (x, y) in zip(a.pixels, b.pixels) { sum += abs(Double(x) - Double(y)) }
        return sum / Double(a.pixels.count)
    }

    /// SPEC S1. At 100% the frame renders exactly what the look's own frame renders
    /// (same Look, same pixels); develop and masks are untouched.
    func testS1AtFullAmountTheLookLandsExactly() {
        var source = Recipe()
        source.look = Self.busyLook
        var target = Recipe()
        target.develop.tone.exposure = 0.4
        let subset = LookSubset.extracted(from: source)
        let applied = subset.applied(to: target)
        XCTAssertEqual(applied.look, source.look)
        XCTAssertEqual(applied.develop, target.develop)
        var expected = target
        expected.look = source.look
        XCTAssertEqual(render(applied).pixels, render(expected).pixels)
    }

    /// SPEC S2. The blend is monotone and has no dead range: the rendered distance from
    /// the frame's own picture grows with every 10% step, 0% is the frame bit for bit,
    /// and 50% lands between 30% and 70% of the full distance.
    func testS2TheBlendIsMonotoneOnThePicture() {
        var own = Recipe()
        own.look.wheels.mid = Wheel(hue: 60, sat: 0.1)
        let base = render(own)
        let full = meanDifference(render(LookSubset(look: Self.busyLook).applied(to: own)), base)
        XCTAssertGreaterThan(full, 1e-3)
        var previous = -1.0
        for step in 0...10 {
            let amount = Double(step) * 10
            let picture = render(LookSubset(look: Self.busyLook, amount: amount).applied(to: own))
            let d = meanDifference(picture, base)
            if step == 0 { XCTAssertEqual(picture.pixels, base.pixels) }
            XCTAssertGreaterThan(d, previous, "amount \(amount) did not move further")
            if step == 5 {
                XCTAssertGreaterThan(d, 0.3 * full)
                XCTAssertLessThan(d, 0.7 * full)
            }
            previous = d
        }
    }

    /// SPEC S3. A look survives the catalog's wire form: saved as canonical JSON, read
    /// back and applied, it renders the identical picture to applying it in memory —
    /// at 100% and at 40%.
    func testS3ALookSurvivesTheCatalogAndAppliesIdentically() throws {
        var source = Recipe()
        source.look = Self.busyLook
        let subset = LookSubset.extracted(from: source)
        let json = try CanonicalJSON.canonicalLookJSON(subset)
        var stored = try CanonicalJSON.decodeLookSubset(from: Data(json.utf8))
        let target = Recipe()
        for amount in [100.0, 40] {
            var direct = subset
            direct.amount = amount
            stored.amount = amount
            XCTAssertEqual(stored.applied(to: target), direct.applied(to: target), "\(amount)")
            XCTAssertEqual(render(stored.applied(to: target)).pixels,
                           render(direct.applied(to: target)).pixels, "\(amount)")
        }
    }

    /// SPEC S4. Re-applying is idempotent at 100% and a look applied to a frame that
    /// already wears it changes nothing at any amount.
    func testS4ReapplyingTheSameLookIsANoOp() {
        let subset = LookSubset(look: Self.busyLook)
        let once = subset.applied(to: Recipe())
        XCTAssertEqual(subset.applied(to: once), once)
        for amount in [10.0, 55, 90] {
            var partial = subset
            partial.amount = amount
            XCTAssertEqual(render(partial.applied(to: once)).pixels, render(once).pixels,
                           "\(amount)")
        }
    }

    /// SPEC S2, across registers. A look saved off a delivered JPEG (Linear, no contrast
    /// override) applied to a RAW on Punchy with Contrast 1.6: the RAW keeps Punchy, so
    /// the walk must end on Punchy's 2.1 — continuous into 100%, not 1.6 → 1.5 and a
    /// jump (measured before the fix: distance .00888 at 99%, .02601 at 100%).
    func testS2TheCurveWalkEndsOnThePresetTheFrameKeeps() {
        var look = Look()
        look.render.preset = LookSubset.linearPresetName
        look.vignette = -0.3
        var raw = Recipe()
        raw.look.render.preset = "Punchy"
        raw.look.render.contrast = 1.6
        let at99 = render(LookSubset(look: look, amount: 99).applied(to: raw))
        let at100 = render(LookSubset(look: look).applied(to: raw))
        XCTAssertLessThan(meanDifference(at99, at100), 2e-3)
        XCTAssertEqual(LookSubset(look: look, amount: 99).applied(to: raw).look.render.contrast!,
                       2.1 - 0.01 * 0.5, accuracy: 1e-9)
    }
}

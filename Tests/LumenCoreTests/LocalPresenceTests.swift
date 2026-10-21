// LocalPresenceTests.swift
// Local Sharpness, both signs, and the identity every mask starts at (WS-53, SPEC 2, 3
// and 6), on the reference renderer.
//
// Positive Sharpness used to sharpen with `ManualSharpen(amount:)` and every other field
// at its default, so a mask ignored the photographer's Radius, Detail, Masking and Halo
// and a full-frame mask at 100 differed from global Amount 100 by up to 50 codes on a
// real frame. Negative Sharpness had a linear radius that spent its first quarter at a
// sub-pixel σ the Gaussian cannot express, so −10 moved the picture by 0.003 codes.

import XCTest
@testable import LumenCore

final class LocalPresenceTests: XCTestCase {

    private let space = RGBColorSpace.rec2020

    /// Fine, mixed-scale structure: a fine sinusoid, a coarser one and a hard step, so
    /// sharpening's Radius, Detail and Masking each have something different to read.
    private static func plate(width: Int, height: Int) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, v in
            let x = u * Double(width)
            let y = v * Double(height)
            let fine = 0.06 * sin(2 * .pi * x / 3.7) * cos(2 * .pi * y / 5.3)
            let coarse = 0.10 * sin(2 * .pi * x / 23)
            let step = u < 0.5 ? 0.0 : 0.15
            let g = 0.18 + fine + coarse + step
            return RGB(g * 1.1, g, g * 0.9)
        }
    }

    private static func maxDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var worst = 0.0
        for i in 0..<a.pixels.count {
            worst = Swift.max(worst, abs(Double(a.pixels[i] - b.pixels[i])))
        }
        return worst
    }

    private static func meanDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var sum = 0.0
        for y in 0..<a.height {
            for x in 0..<a.width {
                let p = a[x, y], q = b[x, y]
                sum += (abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b)) / 3
            }
        }
        return sum / Double(a.width * a.height)
    }

    private func applyFull(_ image: ImageBuffer, mask: Mask,
                           plan: RenderPlan) -> ImageBuffer {
        let alpha = Plane(width: image.width, height: image.height, fill: 1)
        return ReferenceRenderer.applyMasks(image, plan: plan, alphas: [(mask, alpha)],
                                            space: space)
    }

    // MARK: - SPEC 2

    func testLocalSharpnessUsesTheGlobalSharpenSettings() {
        let image = Self.plate(width: 96, height: 64)
        var recipe = Recipe()
        recipe.develop.detail.sharpen = ManualSharpen(amount: 0, radius: 2, detail: 60,
                                                      masking: 60, haloSuppression: 40)
        let plan = RenderPlan(recipe: recipe)
        let radius = Swift.max(Int(Double(Swift.max(image.width, image.height)) * 0.02), 3)
        let node = DetailEngine.Decomposition(image: image, workingRadius: radius,
                                              space: space)
        for v in [50.0, 100] {
            var mask = Mask(id: "m", name: "sharpen")
            mask.adjust.sharpness = v
            let local = applyFull(image, mask: mask, plan: plan)

            var global = recipe.develop.detail.sharpen
            global.amount = v
            let expected = DetailEngine.applySharpen(image, params: global,
                                                     decomposition: node)
            XCTAssertLessThanOrEqual(Self.maxDifference(local, expected), 1e-5,
                                     "local Sharpness \(v) is not global Amount \(v) at "
                                         + "the photographer's Radius/Detail/Masking/Halo")

            // And the settings are not a no-op on this plate, or the comparison above
            // would pass for the old defaults too.
            let defaults = DetailEngine.applySharpen(image, params: ManualSharpen(amount: v),
                                                     decomposition: node)
            XCTAssertGreaterThan(Self.maxDifference(expected, defaults), 1e-3)
        }
    }

    func testLocalSharpnessClampsAtTheGlobalAmountCeiling() {
        let plan = RenderPlan(recipe: Recipe())
        XCTAssertEqual(ReferenceRenderer.localSharpen(200, plan: plan).amount, 150)
        XCTAssertEqual(ReferenceRenderer.localSharpen(-5, plan: plan).amount, 0)
        XCTAssertEqual(ReferenceRenderer.localSharpen(80, plan: plan).radius,
                       plan.detail.sharpen.radius)
    }

    // MARK: - SPEC 3

    func testNegativeSharpnessRespondsFromTheFirstStep() {
        // At the 2560 px reference, so the frame-denominated radius is the radius
        // itself; eight rows keep it cheap.
        let image = Self.plate(width: 2560, height: 8)
        let plan = RenderPlan(recipe: Recipe())
        var m: [Double: Double] = [:]
        for s in [-10.0, -25, -50, -75, -100] {
            var mask = Mask(id: "m", name: "soften")
            mask.adjust.sharpness = s
            m[s] = Self.meanDifference(applyFull(image, mask: mask, plan: plan), image)
        }
        let full = m[-100]!
        XCTAssertGreaterThan(full, 0)
        XCTAssertGreaterThanOrEqual(m[-10]!, 0.15 * full, "−10 is still a dead step: \(m)")
        XCTAssertGreaterThanOrEqual(m[-25]!, 0.35 * full, "−25 is still nearly dead: \(m)")
        let order = [-10.0, -25, -50, -75, -100]
        for (a, b) in zip(order, order.dropFirst()) {
            XCTAssertGreaterThan(m[b]!, m[a]!, "\(b) is not softer than \(a): \(m)")
        }
    }

    func testSofteningRadiusKeepsItsEnds() {
        XCTAssertEqual(ReferenceRenderer.localSofteningRadius(0), 0)
        XCTAssertEqual(ReferenceRenderer.localSofteningRadius(-100), 2.5, accuracy: 1e-12)
        XCTAssertEqual(ReferenceRenderer.localSofteningRadius(-200), 2.5, accuracy: 1e-12)
        XCTAssertEqual(ReferenceRenderer.localSofteningRadius(30), 0)
        XCTAssertEqual(ReferenceRenderer.localSofteningRadius(.nan), 0)
    }

    // MARK: - SPEC 6

    func testDefaultLocalAdjustIsAnExactIdentity() {
        let image = Self.plate(width: 48, height: 32)
        // A recipe with global noise reduction and sharpening ON, so a local stage that
        // wrongly inherited the global AMOUNTS (not just the shaping sliders) would show.
        var recipe = Recipe()
        recipe.develop.denoise.mode = .classic
        recipe.develop.denoise.classic.luma = 40
        recipe.develop.denoise.classic.chroma = 40
        recipe.develop.detail.sharpen.amount = 60
        let plan = RenderPlan(recipe: recipe, captureISO: 3200)
        let untouched = ReferenceRenderer.applyMasks(image, plan: plan, alphas: [],
                                                     space: space)
        XCTAssertEqual(untouched.pixels, image.pixels)

        // Every field at its default — the new Noise rows included — at full Amount.
        let fresh = applyFull(image, mask: Mask(id: "m", name: "fresh"), plan: plan)
        XCTAssertEqual(fresh.pixels, image.pixels, "a default mask moved a pixel")

        // Every presence/detail field moved, Amount 0: still nothing.
        var mask = Mask(id: "m", name: "amount zero", amount: 0)
        mask.adjust.texture = 60
        mask.adjust.clarity = -40
        mask.adjust.dehaze = 30
        mask.adjust.sharpness = -70
        mask.adjust.noise = 80
        mask.adjust.noiseChroma = 80
        let zero = applyFull(image, mask: mask, plan: plan)
        XCTAssertEqual(zero.pixels, image.pixels, "Amount 0 moved a pixel")
    }
}

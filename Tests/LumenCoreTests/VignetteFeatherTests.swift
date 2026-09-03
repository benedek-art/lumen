// VignetteFeatherTests.swift
// docs/32 Stream E item 4 — the vignette's ONE new parameter, Feather, end to end on
// the LumenCore side: recipe field, plan, reference renderer, and the compatibility
// promise that makes it safe to add — the default IS the fixed geometry every existing
// recipe has always rendered with, byte for byte, and an untouched recipe's canonical
// JSON (and therefore its fingerprint) does not change.
//
// The GPU half (RenderGraph's kernel argument) is Stream F's file; until it lands the
// graph reads `DetailEngine.vignetteInnerRadius`, which this file pins to the
// default-feather answer so the two paths agree at the default.

import XCTest
@testable import LumenCore

final class VignetteFeatherTests: XCTestCase {

    private func flatFrame(_ size: Int = 64, level: Double = 0.18) -> ImageBuffer {
        ImageBuffer(width: size, height: size) { _, _ in RGB(gray: level) }
    }

    // MARK: - The compatibility promise

    /// The default feather reproduces the fixed geometry EXACTLY: inner radius 0.375,
    /// the number both renderers carried as a constant (midpoint 0.5, feather 0.5 in
    /// the old spelling), and the number the GPU graph still derives its kernel
    /// argument from.
    func testTheDefaultFeatherIsTheFixedGeometry() {
        XCTAssertEqual(DetailEngine.vignetteInnerRadius(feather: Look.vignetteFeatherDefault),
                       0.375, accuracy: 0,
                       "the default must be BIT-identical to the old constant — every "
                           + "existing recipe renders through it")
        XCTAssertEqual(DetailEngine.vignetteInnerRadius, 0.375, accuracy: 0,
                       "the parameterless constant the GPU graph reads until Stream F "
                           + "lands must be the default-feather answer")
    }

    /// A recipe written before the field existed decodes to the default — so an old
    /// sidecar keeps yesterday's pixels — and renders byte-identically to one that
    /// says feather 50 explicitly.
    func testAnOldSidecarDecodesToTheDefaultAndRendersIdentically() throws {
        let old = try CanonicalJSON.decodeRecipe(
            from: Data(#"{"look":{"vignette":-2},"pipelineVersion":2}"#.utf8))
        XCTAssertEqual(old.look.vignetteFeather, Look.vignetteFeatherDefault,
                       "an absent key must read as the fixed geometry, not as zero")

        var explicit = Recipe()
        explicit.look.vignette = -2
        explicit.look.vignetteFeather = Look.vignetteFeatherDefault
        let frame = flatFrame()
        let a = ReferenceRenderer.render(frame, plan: RenderPlan(recipe: old))
        let b = ReferenceRenderer.render(frame, plan: RenderPlan(recipe: explicit))
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                XCTAssertEqual(a[x, y].r, b[x, y].r, accuracy: 0,
                               "byte-identity broke at (\(x), \(y))")
                XCTAssertEqual(a[x, y].g, b[x, y].g, accuracy: 0)
                XCTAssertEqual(a[x, y].b, b[x, y].b, accuracy: 0)
            }
        }
    }

    /// An untouched recipe's canonical JSON does not mention the field, and a recipe
    /// whose only vignette edit is the Amount doesn't either — so no fingerprint in
    /// any existing catalog moves. Only a MOVED feather serializes.
    func testTheFingerprintOfUntouchedRecipesDoesNotMove() throws {
        let untouched = try CanonicalJSON.canonicalRecipeJSON(Recipe())
        XCTAssertFalse(untouched.contains("vignetteFeather"),
                       "a defaulted field must be pruned by the sparse serializer")

        var amountOnly = Recipe()
        amountOnly.look.vignette = -1.5
        let amountJSON = try CanonicalJSON.canonicalRecipeJSON(amountOnly)
        XCTAssertFalse(amountJSON.contains("vignetteFeather"),
                       "an untouched feather must not ride along with an Amount edit")

        var feathered = amountOnly
        feathered.look.vignetteFeather = 80
        let featherJSON = try CanonicalJSON.canonicalRecipeJSON(feathered)
        XCTAssertTrue(featherJSON.contains("\"vignetteFeather\":80"),
                      "a moved feather is an edit and must serialize")
        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(feathered),
                          try RecipeFingerprint.fingerprint(amountOnly),
                          "two recipes that render differently must not hash the same")

        let roundTripped = try CanonicalJSON.decodeRecipe(from: Data(featherJSON.utf8))
        XCTAssertEqual(roundTripped.look.vignetteFeather, 80,
                       "the field must survive its own round trip")
    }

    // MARK: - The geometry

    /// The mapping is monotone — more feather, earlier falloff — spans the whole
    /// frame's radius, and stays inside its clamp.
    func testInnerRadiusIsMonotoneAndBounded() {
        var previous = Double.infinity
        for feather in stride(from: 0.0, through: 100.0, by: 5.0) {
            let inner = DetailEngine.vignetteInnerRadius(feather: feather)
            XCTAssertLessThan(inner, previous,
                              "inner radius must fall as feather rises (feather \(feather))")
            XCTAssertTrue(inner >= 0 && inner <= 0.98, "clamp broke at \(feather)")
            previous = inner
        }
        XCTAssertEqual(DetailEngine.vignetteInnerRadius(feather: 0), 0.75, accuracy: 1e-12)
        XCTAssertEqual(DetailEngine.vignetteInnerRadius(feather: 100), 0, accuracy: 1e-12)
    }

    /// At every feather: the centre is untouched, the corner takes the full stated EV
    /// (on data below the highlight-protection threshold), and a mid-frame pixel
    /// darkens MORE as feather rises — which is what the slider claims to do.
    func testFeatherShapesTheFalloffWithoutMovingItsEnds() {
        let size = 65 // odd, so there is an exact centre pixel
        let frame = flatFrame(size)
        let level = Double(frame[size / 2, size / 2].g) // the Float-stored input level
        var previousMid = Double.infinity
        for feather in [0.0, 25.0, 50.0, 75.0, 100.0] {
            let out = DetailEngine.vignette(frame, ev: -2, feather: feather)
            let centre = out[size / 2, size / 2].g
            XCTAssertEqual(centre, level, accuracy: 0,
                           "the centre must be untouched at feather \(feather)")
            let corner = out[0, 0].g
            // The corner pixel's own centre sits just inside r = 1; at −2 EV the gain
            // there is within a hair of 0.25× at every feather.
            XCTAssertEqual(corner / level, 0.25, accuracy: 0.02,
                           "the corner must take the full burn at feather \(feather)")
            // r ≈ 0.74 here: inside feather 0's untouched zone, and progressively
            // deeper into the falloff as feather rises.
            let mid = out[size / 8, size / 8].g
            XCTAssertLessThan(mid, previousMid,
                              "more feather must reach further into the frame "
                                  + "(feather \(feather))")
            previousMid = mid
        }
    }

    /// Feather without Amount renders nothing — the slider's help says so — and the
    /// reference path's gate agrees: a feather-only recipe is a byte-identical render.
    func testFeatherAloneChangesNoPixels() {
        var recipe = Recipe()
        recipe.look.vignetteFeather = 100
        let frame = flatFrame()
        let a = ReferenceRenderer.render(frame, plan: RenderPlan(recipe: Recipe()))
        let b = ReferenceRenderer.render(frame, plan: RenderPlan(recipe: recipe))
        for y in 0..<frame.height {
            for x in 0..<frame.width where a[x, y] != b[x, y] {
                return XCTFail("feather with Amount 0 moved pixel (\(x), \(y))")
            }
        }
    }

    // MARK: - The shipping trace (house defect: built but unwired)

    /// The plan carries the recipe's feather and the reference renderer applies it:
    /// two renders of the same Amount at different feathers must differ. This is the
    /// test that fails while the field exists and nothing reads it.
    func testTheRecipeFieldReachesRenderedPixels() {
        var tight = Recipe()
        tight.look.vignette = -2
        tight.look.vignetteFeather = 0
        var soft = tight
        soft.look.vignetteFeather = 100

        XCTAssertEqual(RenderPlan(recipe: tight).vignetteFeather, 0)
        XCTAssertEqual(RenderPlan(recipe: soft).vignetteFeather, 100)

        let frame = flatFrame()
        let a = ReferenceRenderer.render(frame, plan: RenderPlan(recipe: tight))
        let b = ReferenceRenderer.render(frame, plan: RenderPlan(recipe: soft))
        var moved = 0
        for y in 0..<frame.height {
            for x in 0..<frame.width where a[x, y] != b[x, y] { moved += 1 }
        }
        XCTAssertGreaterThan(moved, frame.width * frame.height / 8,
                             "feather 0 and feather 100 rendered near-identical "
                                 + "frames — the field is not reaching the renderer")
    }

    // MARK: - The panel's section state

    /// The Effects dot lights for a moved feather — even at Amount 0, where it renders
    /// nothing but the recipe differs from its defaults — and the section's Reset puts
    /// it back. `EffectsPanel.isVignetteModified` states the same rule and the two
    /// must agree.
    func testTheEffectsSectionSeesAndResetsTheFeather() {
        var recipe = Recipe()
        recipe.look.vignetteFeather = 80
        XCTAssertTrue(WorkspaceSection.nonDefault(in: recipe).contains(.effects),
                      "a moved feather is an edit the header must admit to")
        WorkspaceSection.effects.reset(&recipe)
        XCTAssertEqual(recipe.look.vignetteFeather, Look.vignetteFeatherDefault,
                       "Reset must restore the default feather")
        XCTAssertFalse(WorkspaceSection.nonDefault(in: recipe).contains(.effects),
                       "after Reset the section must read clean")
    }

    /// A look carries the feather: it is part of the vignette, the vignette travels,
    /// and a saved look that dropped the shape while keeping the Amount would apply a
    /// different picture than it saved.
    func testASavedLookCarriesTheFeather() {
        var recipe = Recipe()
        recipe.look.vignette = -1
        recipe.look.vignetteFeather = 90
        let subset = LookSubset.extracted(from: recipe)
        let applied = subset.applied(to: Recipe())
        XCTAssertEqual(applied.look.vignetteFeather, 90)
    }
}

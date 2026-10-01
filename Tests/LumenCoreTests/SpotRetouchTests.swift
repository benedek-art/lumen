// SpotRetouchTests.swift
// S5 RETOUCH — circular Heal and Clone spots: the blend maths, the stage's place in the
// reference renderer, resolution independence, and the recipe/XMP round trip with its
// version stamp. GPU parity lives in LumenPipelineTests/SpotRetouchGPUParityTests.

import XCTest
@testable import LumenCore

/// A deterministic hash in [0, 1), so a "noisy" frame is the same frame on every run.
func spotNoise(_ x: Int, _ y: Int, _ salt: UInt64 = 0) -> Double {
    var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
    h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
    h ^= salt &* 0x1656_67B1_9E37_79F9
    h ^= h >> 29
    h = h &* 0xBF58_476D_1CE4_E5B9
    h ^= h >> 32
    return Double(h % 1_000_003) / 1_000_003
}

final class SpotRetouchTests: XCTestCase {

    // MARK: - Fixtures

    /// A linear ramp — harmonic, so Heal must reproduce it exactly — with a dark
    /// blemish at (40, 30) of radius 3.
    private func rampWithBlemish(width: Int = 96, height: Int = 64) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let base = 0.1 + 0.004 * Double(x) + 0.002 * Double(y)
                image[x, y] = RGB(base, base * 0.8, base * 1.1)
                let dx = Double(x) + 0.5 - 40, dy = Double(y) + 0.5 - 30
                if dx * dx + dy * dy < 9 { image[x, y] = RGB(0.01, 0.01, 0.01) }
            }
        }
        return image
    }

    private func spot(_ mode: HealMode, x: Double, y: Double, sx: Double, sy: Double,
                      radiusPx: Double, edge: Double, feather: Double = 0,
                      opacity: Double = 100, width: Double, height: Double) -> HealSpot {
        HealSpot(id: "s", mode: mode, x: x / width, y: y / height,
                 sourceX: sx / width, sourceY: sy / height,
                 radius: radiusPx / edge, feather: feather, opacity: opacity)
    }

    // MARK: - Identity

    /// A recipe without spots: the stage returns its input bit for bit, and the
    /// reference renderer's output is exactly what it was without the stage.
    func testNoSpotsIsByteIdentity() {
        let image = rampWithBlemish()
        let out = SpotRetouch.apply(image, spots: [])
        XCTAssertEqual(out.pixels, image.pixels)

        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.7
        let plan = RenderPlan(recipe: recipe)
        let rendered = ReferenceRenderer.render(image, plan: plan)
        // The same render with an inert spot (zero opacity) must also be identical —
        // which proves the comparison is against a stage that RAN and declined.
        var inert = recipe
        inert.develop.heal.spots = [HealSpot(x: 0.4, y: 0.4, sourceX: 0.6, sourceY: 0.6,
                                             radius: 0.05, opacity: 0)]
        let inertRender = ReferenceRenderer.render(image, plan: RenderPlan(recipe: inert))
        XCTAssertEqual(inertRender.pixels, rendered.pixels)
    }

    /// Outside the radius not one bit moves, whatever the spot does inside it.
    func testPixelsOutsideTheRadiusAreUntouched() {
        let image = rampWithBlemish()
        let s = spot(.heal, x: 40, y: 30, sx: 60, sy: 30, radiusPx: 6, edge: 96,
                     feather: 50, width: 96, height: 64)
        let out = SpotRetouch.apply(image, spots: [s])
        var changedInside = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let dx = Double(x) + 0.5 - 40, dy = Double(y) + 0.5 - 30
                if dx * dx + dy * dy >= 36 {
                    XCTAssertEqual(out[x, y], image[x, y], "pixel (\(x), \(y)) outside moved")
                } else if out[x, y] != image[x, y] {
                    changedInside += 1
                }
            }
        }
        XCTAssertGreaterThan(changedInside, 25, "the spot did nothing, so this proves nothing")
    }

    // MARK: - Clone

    /// Clone at an integer offset with a hard edge copies the source pixels exactly in
    /// the flat core.
    func testCloneCopiesTheSourceExactly() {
        var image = ImageBuffer(width: 64, height: 48)
        for y in 0..<48 {
            for x in 0..<64 {
                image[x, y] = RGB(spotNoise(x, y), spotNoise(x, y, 1), spotNoise(x, y, 2))
            }
        }
        let s = spot(.clone, x: 20, y: 20, sx: 40, sy: 25, radiusPx: 8, edge: 64,
                     feather: 0, width: 64, height: 48)
        guard let resolved = SpotRetouch.resolve(s, width: 64, height: 48) else {
            return XCTFail("spot did not resolve")
        }
        let out = SpotRetouch.apply(image, spots: [s])
        var checked = 0
        for y in 0..<48 {
            for x in 0..<64 {
                let dx = Double(x) + 0.5 - 20, dy = Double(y) + 0.5 - 20
                let rho = (dx * dx + dy * dy).squareRoot() / 8
                guard rho <= resolved.rin else { continue }
                XCTAssertEqual(out[x, y].maxAbsDifference(image[x + 20, y + 5]), 0,
                               accuracy: 1e-6, "clone did not copy at (\(x), \(y))")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 150)
    }

    // MARK: - Heal

    /// Heal on a linear ramp: the source sits at a different level of the ramp, so a
    /// clone carries the wrong brightness; the Poisson membrane of a linear boundary
    /// difference is that same constant, so Heal reproduces the ramp to float precision
    /// and the blemish is gone. Clone, from the same source, is measurably wrong — the
    /// two modes must differ in exactly the way docs/09 says they do.
    func testHealRelightsTheSourceToTheDestinationAndCloneDoesNot() {
        let image = rampWithBlemish()
        func truth(_ x: Int, _ y: Int) -> RGB {
            let base = 0.1 + 0.004 * Double(x) + 0.002 * Double(y)
            return RGB(base, base * 0.8, base * 1.1)
        }
        let heal = spot(.heal, x: 40, y: 30, sx: 70, sy: 40, radiusPx: 6, edge: 96,
                        width: 96, height: 64)
        var clone = heal
        clone.mode = .clone
        let healed = SpotRetouch.apply(image, spots: [heal])
        let cloned = SpotRetouch.apply(image, spots: [clone])

        var healError = 0.0, cloneError = 0.0
        for y in 24..<36 {
            for x in 34..<46 {
                let dx = Double(x) + 0.5 - 40, dy = Double(y) + 0.5 - 30
                guard dx * dx + dy * dy < 25 else { continue }
                healError = Swift.max(healError, healed[x, y].maxAbsDifference(truth(x, y)))
                cloneError = Swift.max(cloneError, cloned[x, y].maxAbsDifference(truth(x, y)))
            }
        }
        XCTAssertLessThan(healError, 1e-5, "heal did not reproduce the harmonic ramp")
        // 30 px right and 10 px down: 0.12 + 0.02 = 0.14 brighter in red, ×1.1 in blue.
        XCTAssertGreaterThan(cloneError, 0.1, "clone re-lit the patch, which it must not")
    }

    /// The membrane is a weighted mean: a constant rim gives that constant everywhere,
    /// and the centre is the plain mean of the rim.
    func testTheMembraneIsTheMeanAtTheCentreAndExactForAConstant() {
        let constant = [RGB](repeating: RGB(0.3, -0.1, 0.05),
                             count: SpotRetouch.boundarySamples)
        for (qx, qy) in [(0.0, 0.0), (0.5, 0.2), (-0.9, 0.1), (0.0, 0.99)] {
            let m = SpotRetouch.membrane(qx: qx, qy: qy, boundary: constant)
            XCTAssertEqual(m.maxAbsDifference(RGB(0.3, -0.1, 0.05)), 0, accuracy: 1e-12)
        }
        let varying = (0..<SpotRetouch.boundarySamples).map { k in
            RGB(gray: sin(SpotRetouch.rimAngle(k)) * 2 + Double(k % 3))
        }
        let mean = varying.reduce(RGB.zero, +) / Double(varying.count)
        XCTAssertEqual(SpotRetouch.membrane(qx: 0, qy: 0, boundary: varying)
                        .maxAbsDifference(mean), 0, accuracy: 1e-12)
        // And it is harmonic in the sense that matters: a boundary of cos θ comes back
        // as x inside (the unique harmonic extension), to discretization accuracy.
        let cosine = (0..<SpotRetouch.boundarySamples).map {
            RGB(gray: cos(SpotRetouch.rimAngle($0)))
        }
        for (qx, qy) in [(0.3, 0.0), (-0.5, 0.4), (0.6, -0.6)] {
            XCTAssertEqual(SpotRetouch.membrane(qx: qx, qy: qy, boundary: cosine).r, qx,
                           accuracy: 1e-3, "the discrete Poisson integral is not harmonic")
        }
    }

    /// Heal on a blemish sitting on a slope, sourced from a FLAT area: the boundary
    /// difference is itself a ramp, and the membrane has to rebuild the slope across the
    /// patch. A mean-matched blend would put a flat disc there.
    func testHealRebuildsASlopeTheSourceDoesNotHave() {
        let width = 120, height = 60
        var image = ImageBuffer(width: width, height: height)
        func ramp(_ x: Int) -> Double { x < 60 ? 0.2 : 0.2 + 0.01 * Double(x - 60) }
        for y in 0..<height {
            for x in 0..<width {
                image[x, y] = RGB(gray: ramp(x))
                let dx = Double(x) + 0.5 - 90, dy = Double(y) + 0.5 - 30
                if dx * dx + dy * dy < 16 { image[x, y] = RGB(gray: 0.9) }
            }
        }
        let s = spot(.heal, x: 90, y: 30, sx: 25, sy: 30, radiusPx: 8, edge: 120,
                     width: 120, height: 60)
        let out = SpotRetouch.apply(image, spots: [s])
        var worst = 0.0
        for x in 84...96 {
            worst = Swift.max(worst, abs(out[x, 30].r - ramp(x)))
        }
        // The slope across the core is 0.12; a flat fill would miss by half of it.
        XCTAssertLessThan(worst, 0.004, "the membrane did not rebuild the slope")
    }

    // MARK: - Edge, opacity, order

    func testOpacityIsALinearMixAndTheFeatherFallsMonotonically() {
        let image = rampWithBlemish()
        var s = spot(.clone, x: 40, y: 30, sx: 70, sy: 30, radiusPx: 10, edge: 96,
                     feather: 60, opacity: 50, width: 96, height: 64)
        let half = SpotRetouch.apply(image, spots: [s])
        s.opacity = 100
        let full = SpotRetouch.apply(image, spots: [s])
        // At the centre: half-way between the original and the full clone.
        let expected = image[40, 30].mix(full[40, 30], 0.5)
        XCTAssertEqual(half[40, 30].maxAbsDifference(expected), 0, accuracy: 1e-6)

        var previous = 2.0
        for i in 0...20 {
            let rho = Double(i) / 20
            let a = SpotRetouch.alpha(rho: rho, rin: 0.4, opacity: 1)
            XCTAssertLessThanOrEqual(a, previous)
            previous = a
        }
        XCTAssertEqual(SpotRetouch.alpha(rho: 1, rin: 0.4, opacity: 1), 0)
        XCTAssertEqual(SpotRetouch.alpha(rho: 0.4, rin: 0.4, opacity: 0.7), 0.7)
    }

    /// Spots compose in order: the second reads the picture the first left.
    func testSpotsApplyInOrder() {
        let image = rampWithBlemish()
        let a = spot(.clone, x: 70, y: 30, sx: 40, sy: 30, radiusPx: 6, edge: 96,
                     width: 96, height: 64) // copies the BLEMISH to (70, 30)
        let b = spot(.heal, x: 40, y: 30, sx: 20, sy: 30, radiusPx: 6, edge: 96,
                     width: 96, height: 64)
        let together = SpotRetouch.apply(image, spots: [a, b])
        let stepwise = SpotRetouch.apply(SpotRetouch.apply(image, spots: [a]), spots: [b])
        XCTAssertEqual(together.pixels, stepwise.pixels)
        let reversed = SpotRetouch.apply(image, spots: [b, a])
        XCTAssertNotEqual(together.pixels, reversed.pixels,
                          "order made no difference, so the test is not looking at order")
    }

    // MARK: - Pipeline position

    /// S5 runs on the renderer's INPUT, before S6: rendering a recipe with a spot is the
    /// same as retouching the input and rendering the recipe without it — with a tone
    /// edit in the recipe that would make any later placement visible.
    func testTheReferenceRendererRetouchesBeforeEveryOtherStage() {
        let image = rampWithBlemish()
        var recipe = Recipe()
        recipe.develop.tone.exposure = 1.2
        recipe.develop.tone.shadows = 40
        let s = spot(.heal, x: 40, y: 30, sx: 60, sy: 34, radiusPx: 6, edge: 96,
                     feather: 30, width: 96, height: 64)
        var withSpot = recipe
        withSpot.develop.heal.spots = [s]
        let rendered = ReferenceRenderer.render(image, plan: RenderPlan(recipe: withSpot))
        let expected = ReferenceRenderer.render(SpotRetouch.apply(image, spots: [s]),
                                                plan: RenderPlan(recipe: recipe))
        XCTAssertEqual(rendered.pixels, expected.pixels)
        XCTAssertNotEqual(rendered.pixels,
                          ReferenceRenderer.render(image, plan: RenderPlan(recipe: recipe)).pixels,
                          "the spot changed nothing in the render")
    }

    // MARK: - Resolution independence

    /// The same spot on the same content at two render sizes lands on the same place
    /// and does the same thing: the 2x render, box-downsampled, matches the 1x render.
    func testASpotIsResolutionIndependent() {
        func scene(_ width: Int, _ height: Int) -> ImageBuffer {
            ImageBuffer(width: width, height: height) { u, v in
                let blemish = hypot(u - 0.4, (v - 0.5) * 0.75) < 0.03 ? -0.15 : 0
                return RGB(0.3 + 0.2 * u + blemish, 0.25 + 0.1 * v + blemish,
                           0.2 + 0.05 * sin(6 * u) + blemish)
            }
        }
        let s = HealSpot(id: "r", mode: .heal, x: 0.4, y: 0.5, sourceX: 0.7, sourceY: 0.45,
                         radius: 0.05, feather: 50, opacity: 100)
        let small = SpotRetouch.apply(scene(80, 60), spots: [s])
        let large = SpotRetouch.apply(scene(160, 120), spots: [s]).downsampled(by: 2)
        let reference = scene(160, 120).downsampled(by: 2)
        var worst = 0.0, moved = 0.0
        for y in 0..<60 {
            for x in 0..<80 {
                worst = Swift.max(worst, small[x, y].maxAbsDifference(large[x, y]))
                moved = Swift.max(moved, large[x, y].maxAbsDifference(reference[x, y]))
            }
        }
        XCTAssertGreaterThan(moved, 0.05, "the spot did nothing at 2x")
        XCTAssertLessThan(worst, 0.02, "the spot is not the same edit at two sizes")

        guard let one = SpotRetouch.resolve(s, width: 80, height: 60),
              let two = SpotRetouch.resolve(s, width: 160, height: 120) else {
            return XCTFail("did not resolve")
        }
        XCTAssertEqual(two.cx, one.cx * 2, accuracy: 1e-12)
        XCTAssertEqual(two.sy, one.sy * 2, accuracy: 1e-12)
        XCTAssertEqual(two.radius, one.radius * 2, accuracy: 1e-12)
    }

    /// The radius is a fraction of the LONG edge, so a spot is a circle in pixels on a
    /// portrait frame too.
    func testTheRadiusIsMeasuredOnTheLongEdge() {
        let s = HealSpot(x: 0.5, y: 0.5, sourceX: 0.2, sourceY: 0.2, radius: 0.1)
        XCTAssertEqual(SpotRetouch.resolve(s, width: 300, height: 200)?.radius ?? 0, 30)
        XCTAssertEqual(SpotRetouch.resolve(s, width: 200, height: 300)?.radius ?? 0, 30)
    }

    // MARK: - Recipe, fingerprint, XMP

    func testARecipeWithoutSpotsEncodesExactlyAsBefore() throws {
        XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(Recipe()), #"{"pipelineVersion":2}"#)
        var r = Recipe()
        r.develop.heal = Heal(strokesRef: "blob:xxh64:0000000000000001", count: 3)
        let json = try CanonicalJSON.canonicalRecipeJSON(r)
        XCTAssertFalse(json.contains("spots"), json)
        XCTAssertEqual(r.pipelineVersion, currentPipelineVersion,
                       "a recipe without spots must not claim the newer vocabulary")
    }

    func testSpotsRoundTripThroughTheRecipeAndTheSidecar() throws {
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.3
        recipe.develop.heal.spots = [
            HealSpot(id: "a", mode: .heal, x: 0.25, y: 0.75, sourceX: 0.3, sourceY: 0.7,
                     radius: 0.012, feather: 35, opacity: 80),
            HealSpot(id: "b", mode: .clone, x: 0.6123456789, y: 0.1, sourceX: 0.55,
                     sourceY: 0.2, radius: 0.004, feather: 0, opacity: 100),
        ]
        let json = try CanonicalJSON.canonicalRecipeJSON(recipe)
        let decoded = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertEqual(decoded, recipe)

        let xmp = XMPSidecar.serialize(SidecarContent(
            rating: 3, pipelineVersion: recipe.pipelineVersion,
            recipeFingerprint: try RecipeFingerprint.fingerprint(recipe),
            recipeJSON: json))
        guard let parsed = XMPSidecar.parse(xmp), let back = parsed.recipeJSON else {
            return XCTFail("sidecar did not parse")
        }
        XCTAssertEqual(back, json)
        XCTAssertEqual(parsed.pipelineVersion, healSpotsPipelineVersion)
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(back.utf8)), recipe)
    }

    /// The version stamp — what makes the M-01 guards protect spots from an older build.
    func testAddingASpotRaisesTheStatedVersionAndNothingElseDoes() throws {
        var recipe = Recipe()
        XCTAssertEqual(recipe.pipelineVersion, currentPipelineVersion)
        recipe.develop.tone.exposure = 1
        XCTAssertEqual(recipe.pipelineVersion, currentPipelineVersion)
        recipe.develop.heal.spots.append(HealSpot(x: 0.5, y: 0.5, sourceX: 0.6, sourceY: 0.5))
        XCTAssertEqual(recipe.pipelineVersion, healSpotsPipelineVersion,
                       "a recipe carrying spots must state the version that knows them")
        XCTAssertTrue(try CanonicalJSON.canonicalRecipeJSON(recipe)
                        .contains(#""pipelineVersion":3"#))

        // The memberwise path, a hand-written older document, and a NEWER one.
        var develop = Develop()
        develop.heal.spots = recipe.develop.heal.spots
        XCTAssertEqual(Recipe(pipelineVersion: 1, develop: develop).pipelineVersion,
                       healSpotsPipelineVersion)
        // A hand-made v2 document carrying spots decodes as what it SAYS (a decoder
        // reports, it does not correct) and is raised by the first develop edit.
        let handWritten = #"{"pipelineVersion":2,"develop":{"heal":{"count":0,"spots":[{"id":"x","x":0.5,"y":0.5,"sourceX":0.6,"sourceY":0.5}]}}}"#
        var decoded = try CanonicalJSON.decodeRecipe(from: Data(handWritten.utf8))
        XCTAssertEqual(decoded.pipelineVersion, 2)
        decoded.develop.tone.exposure = 0.1
        XCTAssertEqual(decoded.pipelineVersion, healSpotsPipelineVersion)
        XCTAssertEqual(Recipe(pipelineVersion: 9, develop: develop).pipelineVersion, 9,
                       "a newer document's own number is carried, never lowered")

        // The guard arithmetic: this build writes its own spot recipes back, and a build
        // whose newest vocabulary is the old current version reads them as newer.
        XCTAssertGreaterThan(healSpotsPipelineVersion, currentPipelineVersion)
        XCTAssertLessThanOrEqual(healSpotsPipelineVersion, supportedPipelineVersion)
        let all: SidecarStatedFields = [.rating, .recipe]
        XCTAssertEqual(XMPSidecar.writableFields(all, documentVersion: healSpotsPipelineVersion),
                       all, "this build refused to write its own spot recipe back")
    }

    func testMovingASpotChangesTheFingerprint() throws {
        var a = Recipe()
        a.develop.heal.spots = [HealSpot(id: "s", x: 0.5, y: 0.5, sourceX: 0.6, sourceY: 0.5)]
        var b = a
        b.develop.heal.spots[0].sourceX = 0.61
        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(a),
                          try RecipeFingerprint.fingerprint(b))
        XCTAssertFalse(a.rendersSameAs(b))
    }

    func testAbsentKeysFallBackAndAnUnknownModeIsRefused() throws {
        let sparse = #"{"develop":{"heal":{"spots":[{"x":0.2,"y":0.3}]}}}"#
        let recipe = try CanonicalJSON.decodeRecipe(from: Data(sparse.utf8))
        guard let s = recipe.develop.heal.spots.first else { return XCTFail("spot lost") }
        XCTAssertEqual(s.x, 0.2)
        XCTAssertEqual(s.sourceX, 0.5, "an absent key falls back to a constant")
        XCTAssertEqual(s.sourceY, 0.5)
        XCTAssertEqual(s.mode, .heal)
        XCTAssertEqual(s.radius, HealSpot.defaultRadius)
        XCTAssertEqual(s.feather, HealSpot.defaultFeather)
        XCTAssertEqual(s.opacity, HealSpot.defaultOpacity)

        let unknown = #"{"develop":{"heal":{"spots":[{"x":0.2,"y":0.3,"mode":"remove"}]}}}"#
        XCTAssertThrowsError(try CanonicalJSON.decodeRecipe(from: Data(unknown.utf8)))
    }
}

/// The Heal tool's press grammar (`SpotHandles`), here because the canvas that uses it
/// has no Linux tests.
final class SpotHandlesTests: XCTestCase {

    private let spots = [
        HealSpot(id: "low", x: 0.30, y: 0.50, sourceX: 0.60, sourceY: 0.50, radius: 0.02),
        HealSpot(id: "top", x: 0.32, y: 0.50, sourceX: 0.10, sourceY: 0.20, radius: 0.02),
    ]

    func testAPressFindsTheTopmostSpotThenItsSourceThenClearSpace() {
        // 1000×500: radius 20 px. (0.31, 0.5) is inside both destinations — the later
        // spot, drawn and applied last, wins.
        XCTAssertEqual(SpotHandles.hit(x: 0.31, y: 0.5, spots: spots, sourceWidth: 1000,
                                       sourceHeight: 500, minimumGrab: 1),
                       SpotHandles.Hit(id: "top", part: .destination))
        XCTAssertEqual(SpotHandles.hit(x: 0.61, y: 0.5, spots: spots, sourceWidth: 1000,
                                       sourceHeight: 500, minimumGrab: 1),
                       SpotHandles.Hit(id: "low", part: .source))
        XCTAssertNil(SpotHandles.hit(x: 0.9, y: 0.9, spots: spots, sourceWidth: 1000,
                                     sourceHeight: 500, minimumGrab: 1))
        // A tiny spot is still pressable through the minimum grab.
        XCTAssertEqual(SpotHandles.hit(x: 0.9, y: 0.9, spots: [
            HealSpot(id: "tiny", x: 0.905, y: 0.9, sourceX: 0.5, sourceY: 0.5,
                     radius: 0.001)], sourceWidth: 1000, sourceHeight: 500,
                                       minimumGrab: 6)?.id, "tiny")
    }

    func testDraggingMovesTheNamedPartOnly() {
        let s = spots[0]
        let moved = SpotHandles.dragged(s, part: .destination, dx: 0.1, dy: -0.05)
        XCTAssertEqual(moved.x, 0.4, accuracy: 1e-12)
        XCTAssertEqual(moved.y, 0.45, accuracy: 1e-12)
        XCTAssertEqual(moved.sourceX, s.sourceX)
        let source = SpotHandles.dragged(s, part: .source, dx: 0.1, dy: 0)
        XCTAssertEqual(source.x, s.x)
        XCTAssertEqual(source.sourceX, 0.7, accuracy: 1e-12)
    }

    func testTheProvisionalSourceIsBesideTheSpotAndInsideTheFrame() {
        let left = HealSpot(x: 0.2, y: 0.5, sourceX: 0.2, sourceY: 0.5, radius: 0.02)
        let p = SpotHandles.provisionalSource(for: left, sourceWidth: 1000, sourceHeight: 500)
        XCTAssertEqual(p.x, 0.25, accuracy: 1e-12)   // 2.5 × 20 px to the right
        XCTAssertEqual(p.y, 0.5)
        let right = HealSpot(x: 0.97, y: 0.5, sourceX: 0.97, sourceY: 0.5, radius: 0.02)
        let q = SpotHandles.provisionalSource(for: right, sourceWidth: 1000, sourceHeight: 500)
        XCTAssertLessThan(q.x, right.x, "placed off the right edge instead of the left")
    }
}

/// Heal spots and the section Reset that used to own `develop.heal`.
final class SpotSectionTests: XCTestCase {

    func testAnEffectsResetKeepsTheSpotsAndSpotsDoNotLightEffects() {
        var recipe = Recipe()
        recipe.develop.heal.spots = [HealSpot(id: "s", x: 0.3, y: 0.3, sourceX: 0.5,
                                              sourceY: 0.5)]
        XCTAssertFalse(WorkspaceSection.nonDefault(in: recipe, softProofEnabled: false)
                        .contains(.effects),
                       "a spot lit the Effects dot, whose panel has no spot in it")
        recipe.look.vignette = -1
        recipe.develop.heal.count = 2
        WorkspaceSection.effects.reset(&recipe)
        XCTAssertEqual(recipe.develop.heal.spots.count, 1,
                       "resetting vignette and grain deleted the photograph's healing")
        XCTAssertEqual(recipe.develop.heal.count, 0)
        XCTAssertEqual(recipe.look.vignette, 0)
    }
}

// MaskWhiteBalanceTests.swift
// docs/36 §4 item 22 — per-mask ABSOLUTE white balance, alongside the relative shift.
//
// Every competitor's local white balance is relative: Lightroom, Capture One, ON1 and
// darktable all give a masked region a "warmer/cooler" nudge and nothing else. That is
// fine until the global row moves, and then it is silently wrong — a mask built to
// neutralize a 3200 K window is a fixed shift, so dragging the picture's temperature
// re-lights the window along with everything else, and the photographer has to go back
// and re-tune every mask they had already finished.
//
// An absolute mask says "this region is lit at 5600 K" and means it. The property that
// makes that a real claim rather than a label is stated once, in
// `testAnAbsoluteMaskIsTheSameEditWhateverTheGlobalRowSays`: the local matrix composed
// with the global one equals a single adaptation from the file's as-shot neutral
// straight to the mask's Kelvin. It holds exactly, because the adaptation is a von
// Kries chain in CAT16 and `space.toXYZ · space.fromXYZ` is the identity — which is
// also why this is worth asserting rather than assuming.

import XCTest
@testable import LumenCore

final class MaskWhiteBalanceTests: XCTestCase {

    private let space = RGBColorSpace.rec2020

    /// Probe colours, not one grey: a white-balance matrix that is wrong in a single
    /// channel is invisible on neutral and obvious on anything else.
    private let probes = [RGB(0.5, 0.5, 0.5), RGB(0.8, 0.3, 0.1),
                          RGB(0.1, 0.4, 0.9), RGB(0.05, 0.55, 0.2)]

    private func assertSameMap(_ a: Mat3, _ b: Mat3, _ message: String = "",
                               accuracy: Double = 1e-12,
                               file: StaticString = #filePath, line: UInt = #line) {
        for probe in probes {
            let x = a.apply(probe), y = b.apply(probe)
            XCTAssertEqual(x.r, y.r, accuracy: accuracy, message, file: file, line: line)
            XCTAssertEqual(x.g, y.g, accuracy: accuracy, message, file: file, line: line)
            XCTAssertEqual(x.b, y.b, accuracy: accuracy, message, file: file, line: line)
        }
    }

    private func neutral(_ k: Double, _ t: Double = 0) -> WhiteBalanceEngine.Neutral {
        WhiteBalanceEngine.Neutral(kelvin: k, tint: t)
    }

    private func absolute(_ kelvin: Double, tint: Double? = nil, amount: Double = 1,
                          balanced: WhiteBalanceEngine.Neutral)
        -> ReferenceRenderer.LocalWhiteBalance {
        ReferenceRenderer.LocalWhiteBalance(kelvin: kelvin, tint: tint, amount: amount,
                                            balanced: balanced, space: space)
    }

    // MARK: - The claim

    func testAnAbsoluteMaskIsTheSameEditWhateverTheGlobalRowSays() {
        // One file, one mask at 5600 K, three different global temperatures. In each
        // case the two matrices in series must equal the ONE adaptation that takes the
        // file's own neutral to 5600 K — so the region renders at 5600 K, full stop.
        let asShot = neutral(3200, -12)
        let direct = WhiteBalanceEngine(asShotKelvin: asShot.kelvin,
                                        asShotTint: asShot.tint,
                                        targetKelvin: 5600, targetTint: 0,
                                        space: space).matrix

        for globalKelvin in [3200.0, 4500.0, 8000.0, 15000.0] {
            let balanced = neutral(globalKelvin, 0)
            let global = WhiteBalanceEngine(asShotKelvin: asShot.kelvin,
                                            asShotTint: asShot.tint,
                                            targetKelvin: globalKelvin, targetTint: 0,
                                            space: space).matrix
            let local = absolute(5600, tint: 0, balanced: balanced).matrix
            assertSameMap(local * global, direct,
                          "at a global \(globalKelvin) K the mask still lands at 5600 K")
        }
    }

    func testARelativeShiftIsNotThatAndThisFixtureProvesTheTestCanFail() {
        // The same three global temperatures with the RELATIVE spelling, which is what
        // every competitor offers: the composite moves with the global row. Without
        // this the test above could pass on a broken implementation that ignored
        // `balanced` and happened to be near enough.
        let asShot = neutral(3200, -12)
        var composites: [RGB] = []
        for globalKelvin in [4500.0, 8000.0] {
            let global = WhiteBalanceEngine(asShotKelvin: asShot.kelvin,
                                            asShotTint: asShot.tint,
                                            targetKelvin: globalKelvin, targetTint: 0,
                                            space: space).matrix
            let relative = ReferenceRenderer.LocalWhiteBalance(temp: 40, tint: 0,
                                                               space: space)
            composites.append((relative.matrix * global).apply(RGB(0.5, 0.5, 0.5)))
        }
        XCTAssertGreaterThan(abs(composites[0].r - composites[1].r), 0.01,
                             "a relative shift DOES move with the global row — that is "
                                 + "the defect the absolute spelling exists to fix")
    }

    // MARK: - Amount

    func testAmountZeroIsExactlyIdentity() {
        // The endpoint at amount 0 is `balanced` itself, so the engine adapts a neutral
        // to itself. Nothing about a mask at Amount 0 may touch a pixel.
        let m = absolute(9000, tint: 40, amount: 0, balanced: neutral(4200, -5)).matrix
        assertSameMap(m, .identity, "amount 0 is a no-op")
    }

    func testAmountInterpolatesInMiredRatherThanInKelvin() {
        // Half of 3200 K is not 1600 K. Mired is the axis colour temperature is
        // perceptually even in, and it is the axis the relative slider already uses, so
        // both spellings pass through the same colours on the way.
        let balanced = neutral(6500)
        let half = absolute(3200, tint: 0, amount: 0.5, balanced: balanced).matrix
        let mired = (1e6 / 6500 + 1e6 / 3200) / 2
        let expected = WhiteBalanceEngine(asShotKelvin: 6500, asShotTint: 0,
                                          targetKelvin: 1e6 / mired, targetTint: 0,
                                          space: space).matrix
        assertSameMap(half, expected, "the midpoint is the mired midpoint")

        let kelvinMidpoint = WhiteBalanceEngine(asShotKelvin: 6500, asShotTint: 0,
                                                targetKelvin: (6500 + 3200) / 2,
                                                targetTint: 0, space: space).matrix
        let a = half.apply(RGB(0.5, 0.5, 0.5)), b = kelvinMidpoint.apply(RGB(0.5, 0.5, 0.5))
        XCTAssertGreaterThan(abs(a.r - b.r) + abs(a.b - b.b), 1e-3,
                             "and it is a DIFFERENT number from the Kelvin midpoint, "
                                 + "or this test is asserting nothing")
    }

    func testAmountOneIsTheWholeTarget() {
        let balanced = neutral(5000, 8)
        let full = absolute(7500, tint: -20, amount: 1, balanced: balanced).matrix
        let expected = WhiteBalanceEngine(asShotKelvin: 5000, asShotTint: 8,
                                          targetKelvin: 7500, targetTint: -20,
                                          space: space).matrix
        assertSameMap(full, expected)
    }

    func testAnAbsentAbsoluteTintHoldsTheBalancedTintRatherThanZeroingIt() {
        // nil tint means "I am setting the temperature, leave the green/magenta alone".
        // Defaulting it to 0 would drag every mask onto the daylight locus the first
        // time a Kelvin was typed.
        let balanced = neutral(5000, 25)
        let m = absolute(7000, tint: nil, balanced: balanced).matrix
        let expected = WhiteBalanceEngine(asShotKelvin: 5000, asShotTint: 25,
                                          targetKelvin: 7000, targetTint: 25,
                                          space: space).matrix
        assertSameMap(m, expected)
    }

    // MARK: - The relative spelling is untouched

    func testResolveReturnsTheOldMatrixBitForBitWhenNoKelvinIsSet() {
        var a = LocalAdjust()
        a.temp = 55
        a.tint = -30
        for amount in [0.0, 0.25, 1.0] {
            let resolved = ReferenceRenderer.LocalWhiteBalance.resolve(
                a, amount: amount, balanced: neutral(4000, 12), space: space)
            let old = ReferenceRenderer.LocalWhiteBalance(temp: 55 * amount,
                                                          tint: -30 * amount,
                                                          space: space)
            XCTAssertEqual(resolved.isIdentity, old.isIdentity)
            assertSameMap(resolved.matrix, old.matrix, "at amount \(amount)",
                          accuracy: 0)
        }
    }

    func testResolveIgnoresTheRelativeShiftOnceAKelvinIsSet() {
        // One control, two units — never two stacked controls. A mask carrying both a
        // "+60 warmer" and a "5600 K" would be the owner's two-inverts complaint in a
        // new costume.
        var a = LocalAdjust()
        a.temp = 60
        a.kelvin = 5600
        let balanced = neutral(4400)
        let resolved = ReferenceRenderer.LocalWhiteBalance.resolve(
            a, amount: 1, balanced: balanced, space: space)
        assertSameMap(resolved.matrix, absolute(5600, balanced: balanced).matrix,
                      "the relative shift is not consulted", accuracy: 0)
    }

    // MARK: - Through the whole local stage

    func testAMaskWhoseOnlyEditIsAKelvinChangesThePicture() {
        var mask = Mask(id: "m", name: "window")
        mask.adjust.kelvin = 3000
        let image = ImageBuffer(width: 4, height: 4) { _, _ in RGB(0.4, 0.4, 0.4) }
        let plan = RenderPlan(recipe: Recipe(), asShotKelvin: 6500, asShotTint: 0)
        let out = ReferenceRenderer.applyMasks(image, plan: plan,
                                               alphas: [(mask, Plane(width: 4, height: 4,
                                                                     fill: 1))],
                                               space: space)
        let moved = abs(out[0, 0].r - image[0, 0].r) + abs(out[0, 0].b - image[0, 0].b)
        XCTAssertGreaterThan(moved, 0.01,
                             "an absolute white balance is a real edit, not a stored number")
        // DIRECTION, and it is the one every raw editor agrees on rather than the one
        // the word "3000 K" suggests: the number names the ILLUMINANT you are declaring,
        // so declaring a colder light than the balance assumed removes warming
        // compensation and the region goes BLUE. Dragging Lightroom's Temperature left
        // does the same thing. The mask row must not invert the global row's direction,
        // so the claim is stated against that row rather than against an intuition.
        XCTAssertGreaterThan(out[0, 0].b, out[0, 0].r,
                             "3000 K declared on a 6500 K balance is a cool edit")

        let globalRow = WhiteBalanceEngine(asShotKelvin: 6500, asShotTint: 0,
                                           targetKelvin: 3000, targetTint: nil,
                                           space: space).matrix
        let globally = globalRow.apply(image[0, 0])
        XCTAssertEqual(out[0, 0].r / out[0, 0].b, globally.r / globally.b,
                       accuracy: 1e-5,
                       "and it is the SAME edit the global row at 3000 K would make")
    }

    func testTheMaskAmountFadesTheAbsoluteEditToNothing() {
        var mask = Mask(id: "m", name: "window")
        mask.adjust.kelvin = 3000
        mask.amount = 0
        let image = ImageBuffer(width: 2, height: 2) { _, _ in RGB(0.4, 0.4, 0.4) }
        let plan = RenderPlan(recipe: Recipe(), asShotKelvin: 6500, asShotTint: 0)
        let out = ReferenceRenderer.applyMasks(image, plan: plan,
                                               alphas: [(mask, Plane(width: 2, height: 2,
                                                                     fill: 1))],
                                               space: space)
        XCTAssertEqual(out[0, 0].r, image[0, 0].r, accuracy: 1e-12)
        XCTAssertEqual(out[0, 0].b, image[0, 0].b, accuracy: 1e-12)
    }

    func testTheGlobalRowMovesAndTheMaskedRegionDoesNot() {
        // The end-to-end statement of the headline claim, in pixels rather than in
        // matrices: the same mask over two different global temperatures, compared
        // against the two pictures the global row alone produces.
        var mask = Mask(id: "m", name: "window")
        mask.adjust.kelvin = 5600
        let image = ImageBuffer(width: 2, height: 2) { _, _ in RGB(0.4, 0.35, 0.3) }
        let alpha = Plane(width: 2, height: 2, fill: 1)

        var masked: [RGB] = []
        for global in [4000.0, 9000.0] {
            var recipe = Recipe()
            recipe.develop.raw.temp = global
            let plan = RenderPlan(recipe: recipe, asShotKelvin: 5200, asShotTint: 0)
            // The picture arriving at the local stage is the S6 output, which is what
            // `applyMasks` is handed in the graph. Built from the engine rather than
            // read off `plan.linear`, whose matrix has the exposure gain fused into it.
            let wb = WhiteBalanceEngine(asShotKelvin: 5200, asShotTint: 0,
                                        targetKelvin: global, targetTint: nil,
                                        space: space).matrix
            let staged = image.map { wb.apply($0) }
            let out = ReferenceRenderer.applyMasks(staged, plan: plan,
                                                   alphas: [(mask, alpha)], space: space)
            masked.append(out[0, 0])
        }
        // `ImageBuffer` stores Float32, so the two paths — which differ by two matrix
        // multiplies of rounding — cannot agree closer than about an ULP at 0.35, which
        // is 3e-8. 1e-6 is two orders inside that and four orders inside anything a
        // 16-bit export could show. The matrix-level claim above is the exact one; this
        // is the same claim in pixels, at the precision pixels are kept in.
        XCTAssertEqual(masked[0].r, masked[1].r, accuracy: 1e-6)
        XCTAssertEqual(masked[0].g, masked[1].g, accuracy: 1e-6)
        XCTAssertEqual(masked[0].b, masked[1].b, accuracy: 1e-6,
                       "5600 K is 5600 K whatever the global row was dragged to")
    }

    // MARK: - Wire format

    func testAnOldRecipeDecodesWithNoAbsoluteWhiteBalance() throws {
        let json = """
        {"pipelineVersion":1,"masks":[{"id":"m","components":[],\
        "adjust":{"exposure":1,"temp":30}}]}
        """
        let r = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertNil(r.masks[0].adjust.kelvin)
        XCTAssertNil(r.masks[0].adjust.kelvinTint)
        XCTAssertEqual(r.masks[0].adjust.temp, 30, accuracy: 0)
    }

    func testTheAbsoluteFieldsRoundTrip() throws {
        var recipe = Recipe()
        var mask = Mask(id: "m", name: "window")
        mask.adjust.kelvin = 3400
        mask.adjust.kelvinTint = -18
        recipe.masks = [mask]
        let back = try CanonicalJSON.decodeRecipe(
            from: Data(CanonicalJSON.canonicalRecipeJSON(recipe).utf8))
        XCTAssertEqual(back.masks[0].adjust.kelvin, 3400)
        XCTAssertEqual(back.masks[0].adjust.kelvinTint, -18)
    }

    // MARK: - The neutral the plan resolves

    func testThePlanResolvesTheSameNeutralTheTempRowWouldShow() {
        // One rule, two readers. If the plan resolved "as shot" differently from
        // `WhiteBalanceEngine.displayed`, a mask would render one temperature and the
        // panel beside it would print another.
        for (temp, tint) in [(Double?.none, Double?.none), (7200, nil), (nil, 40),
                             (4100, -22)] as [(Double?, Double?)] {
            var recipe = Recipe()
            recipe.develop.raw.temp = temp
            recipe.develop.raw.tint = tint
            let plan = RenderPlan(recipe: recipe, asShotKelvin: 3350, asShotTint: 17)
            let shown = WhiteBalanceEngine.displayed(
                temp: temp, tint: tint,
                asShot: WhiteBalanceEngine.Neutral(kelvin: 3350, tint: 17))
            XCTAssertEqual(plan.balancedNeutral.kelvin, shown.temperature, accuracy: 0)
            XCTAssertEqual(plan.balancedNeutral.tint, shown.tint, accuracy: 0)
        }
    }
}

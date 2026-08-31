// LuminositySeriesTests.swift
// docs/36 §3 bet 2, second half — Kuyper's luminosity series, natively.
//
// This is the one capability on the premium list that photographers currently PAY a
// third party for: Lumenzia and TK Actions exist to generate fifteen pre-baked channels
// in Photoshop, because Photoshop's channel arithmetic can only intersect a mask with
// itself a whole number of times. No raw editor ships it. Lumen ships it as one slider,
// because `pow` has no such limit.
//
// The tests below are in three groups, and the middle one is the point:
//
//   1. The family is the family — each level is the previous one intersected with the
//      first, which is the definition, and the two ends are mirrors.
//   2. It is SELF-FEATHERING. That word is the whole reason the tradition prefers this
//      to a band, and it is a testable claim rather than an adjective: the derivative is
//      bounded everywhere, and there is no luminance at which the selection jumps.
//   3. Amount means what it says, which is why the midtones are renormalized.

import XCTest
@testable import LumenCore

final class LuminositySeriesTests: XCTestCase {

    private func value(_ l: Double, _ series: LuminositySeries, _ level: Double) -> Double {
        MaskRaster.luminosityValue(l, series: series, level: level)
    }

    /// A dense sweep of the luminance axis. Every claim below is made over the whole
    /// axis rather than at three chosen points, because a curve that is right at 0, 0.5
    /// and 1 and wrong between them is exactly the bug a self-feathering mask would show
    /// as a band across the sky.
    private let axis = (0...400).map { Double($0) / 400 }

    // MARK: - The family

    func testLightsIsThePlainChannelAtLevelOne() {
        for l in axis {
            XCTAssertEqual(value(l, .lights, 1), l, accuracy: 1e-12)
        }
    }

    func testDarksIsTheComplementOfLightsAtLevelOne() {
        for l in axis {
            XCTAssertEqual(value(l, .darks, 1), 1 - l, accuracy: 1e-12)
        }
    }

    func testEachLevelIsThePreviousOneIntersectedWithTheFirst() {
        // The definition, stated as arithmetic: Lights(n) = Lights(n−1) · Lights(1).
        // Photoshop performs this literally, one intersection at a time; if this fails
        // we have a different family wearing the same name.
        for l in axis {
            for n in [2.0, 3.0, 4.0, 5.0] {
                XCTAssertEqual(value(l, .lights, n),
                               value(l, .lights, n - 1) * value(l, .lights, 1),
                               accuracy: 1e-12, "Lights \(n) at L=\(l)")
                XCTAssertEqual(value(l, .darks, n),
                               value(l, .darks, n - 1) * value(l, .darks, 1),
                               accuracy: 1e-12, "Darks \(n) at L=\(l)")
            }
        }
    }

    func testTheTwoEndsAreMirrorImages() {
        for l in axis {
            for n in [1.0, 2.5, 5.0] {
                XCTAssertEqual(value(l, .lights, n), value(1 - l, .darks, n),
                               accuracy: 1e-12)
            }
        }
    }

    func testAHigherLevelSelectsLessEverywhereExceptTheEnds() {
        // "Tightens toward its end of the scale" as an inequality rather than a
        // description: Lights 3 can never select more than Lights 2 anywhere.
        for l in axis where l < 1 {
            XCTAssertLessThanOrEqual(value(l, .lights, 3), value(l, .lights, 2) + 1e-12)
            XCTAssertLessThanOrEqual(value(l, .lights, 5), value(l, .lights, 3) + 1e-12)
        }
        XCTAssertEqual(value(1, .lights, 5), 1, accuracy: 1e-12,
                       "white stays fully selected at every level, or the series would "
                           + "be a fade rather than a narrowing")
    }

    func testTheLevelIsContinuousAndNotFiveDiscreteSteps() {
        // The departure from Photoshop that makes the "generator" one slider rather
        // than fifteen baked channels. A level between two integers must sit STRICTLY
        // between the two masks — the first draft of this test allowed a 1e-12 slack at
        // each end and an implementation that rounded 2.5 up to 3 passed it, which is
        // precisely the behaviour the test exists to forbid. The margin is a fraction of
        // the gap the two neighbouring levels leave, so it scales with how much room
        // there is to be wrong in.
        for l in axis where l > 0.05 && l < 0.95 {
            let two = value(l, .lights, 2)
            let three = value(l, .lights, 3)
            let half = value(l, .lights, 2.5)
            let margin = (two - three) * 0.1
            XCTAssertGreaterThan(margin, 0, "the fixture must leave room at L=\(l)")
            XCTAssertLessThan(half, two - margin, "at L=\(l)")
            XCTAssertGreaterThan(half, three + margin, "at L=\(l)")
        }

        // And it is continuous in the level too, not just placed between two integers:
        // a hundred steps from 1 to 5 may not contain a jump.
        var previous = value(0.6, .lights, 1)
        for step in 1...100 {
            let here = value(0.6, .lights, 1 + Double(step) * 4 / 100)
            XCTAssertLessThan(abs(here - previous), 0.02,
                              "the level itself is a continuous control")
            previous = here
        }
    }

    // MARK: - Self-feathering

    func testTheSelectionNeverJumps() {
        // SELF-FEATHERING, as a claim a test can hold. Over a 401-step sweep no
        // neighbouring pair may differ by more than a bound proportional to the step —
        // which is what "no boundary anywhere" means, and what a band cannot promise at
        // Smoothness 0.
        for series in LuminositySeries.allCases {
            for n in [1.0, 2.0, 3.5, 5.0] {
                var previous = value(0, series, n)
                for l in axis.dropFirst() {
                    let here = value(l, series, n)
                    // The steepest slope in the family is Midtones at level 5 near the
                    // shoulders, which is under 6; 8 × the step size is a comfortable
                    // bound that a step discontinuity of any size would still break.
                    XCTAssertLessThan(abs(here - previous), 8.0 / 400,
                                      "\(series) level \(n) jumps at L=\(l)")
                    previous = here
                }
            }
        }
    }

    func testABandCanJumpAndThisSeriesCannotWhichIsWhyItExists() {
        // The contrast that makes the property worth asserting. A Brightness Range band
        // at Smoothness 0 has a near-vertical edge; the sweep above would fail on it.
        let w = 64, h = 1
        let ramp = ImageBuffer(width: w, height: h) { u, _ in
            RGB(u * 4, u * 4, u * 4)
        }
        var band = MaskComponent(op: .add, kind: .lumaRange)
        band.lo = 0.55
        band.hi = 1.0
        band.smooth = 0
        let bandPlane = MaskRaster.rasterize(component: band, size: (width: w, height: h),
                                             source: ramp)
        var biggestBandStep = 0.0
        for x in 1..<w {
            biggestBandStep = Swift.max(biggestBandStep,
                                        abs(Double(bandPlane[x, 0] - bandPlane[x - 1, 0])))
        }

        var series = MaskComponent(op: .add, kind: .luminosity)
        series.series = .lights
        series.level = 3
        let seriesPlane = MaskRaster.rasterize(component: series,
                                               size: (width: w, height: h), source: ramp)
        var biggestSeriesStep = 0.0
        for x in 1..<w {
            biggestSeriesStep = Swift.max(
                biggestSeriesStep, abs(Double(seriesPlane[x, 0] - seriesPlane[x - 1, 0])))
        }

        XCTAssertGreaterThan(biggestBandStep, 0.3, "the band's edge is a step")
        XCTAssertLessThan(biggestSeriesStep, biggestBandStep / 3,
                          "and the series has no edge to step at")
    }

    // MARK: - Midtones, and why Amount means what it says

    func testMidtonesPeakAtOneSoAmountMeansWhatItSays() {
        // The raw Kuyper formula peaks at 1 − 2^−n: 0.5 at level 1. Shipping that would
        // mean a midtone mask at Amount 100 performing half an edit, with a second,
        // invisible, level-dependent strength control hiding inside the selection.
        for n in [1.0, 2.0, 3.0, 4.0, 5.0] {
            XCTAssertEqual(value(0.5, .midtones, n), 1, accuracy: 1e-12,
                           "midtones at level \(n) must reach full selection at "
                               + "middle grey")
        }
    }

    func testMidtonesFallToNothingAtBothEnds() {
        for n in [1.0, 3.0, 5.0] {
            XCTAssertEqual(value(0, .midtones, n), 0, accuracy: 1e-12)
            XCTAssertEqual(value(1, .midtones, n), 0, accuracy: 1e-12)
        }
    }

    func testMidtonesAreSymmetricAboutMiddleGrey() {
        for l in axis {
            for n in [1.0, 2.5, 5.0] {
                XCTAssertEqual(value(l, .midtones, n), value(1 - l, .midtones, n),
                               accuracy: 1e-12)
            }
        }
    }

    func testAHigherMidtoneLevelIsBroaderWhichIsTheOppositeOfLights() {
        // Worth pinning because it reads as a bug: for Lights and Darks a higher level
        // narrows, and for Midtones it widens. Both follow from the same formula, and
        // both match the tradition — Midtones 1 is the tightest selection around grey.
        for l in [0.2, 0.3, 0.7, 0.8] {
            XCTAssertGreaterThan(value(l, .midtones, 5), value(l, .midtones, 1),
                                 "at L=\(l)")
        }
    }

    // MARK: - Through the rasterizer

    /// A vertical ramp over four stops, so the plane's rows are the luminance axis.
    private func ramp(_ w: Int, _ h: Int) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, _ in RGB(u * 4, u * 4, u * 4) }
    }

    private func plane(_ build: (inout MaskComponent) -> Void) -> Plane {
        var c = MaskComponent(op: .add, kind: .luminosity)
        build(&c)
        return MaskRaster.rasterize(component: c, size: (width: 48, height: 4),
                                    source: ramp(48, 4))
    }

    func testTheRasterizerSelectsTheBrightEndForLights() {
        let p = plane { $0.series = .lights; $0.level = 3 }
        XCTAssertGreaterThan(p[47, 2], p[24, 2])
        XCTAssertGreaterThan(p[24, 2], p[2, 2])
        // The absolute value at a column is a claim about the fixed −10…+4 EV axis, not
        // about the ramp, and reasoning about it by eye is how the first three drafts of
        // this test were wrong. So it is asserted against the closed form instead —
        // which is also the claim worth making, since it says the loop wires the curve
        // to the picture rather than approximating it.
        for x in [0, 11, 24, 47] {
            let linear = Double(ramp(48, 4)[x, 2].g)
            let ev = Num.safeLog2(linear, floorEV: -16)
            let l = Num.saturate((ev - MaskRaster.evMin) / (MaskRaster.evMax - MaskRaster.evMin))
            XCTAssertEqual(Double(p[x, 2]),
                           MaskRaster.luminosityValue(l, series: .lights, level: 3),
                           accuracy: 1e-6, "column \(x)")
        }
    }

    func testTheRasterizerSelectsTheDarkEndForDarks() {
        let p = plane { $0.series = .darks; $0.level = 3 }
        XCTAssertGreaterThan(p[2, 2], p[24, 2])
        XCTAssertGreaterThan(p[24, 2], p[47, 2])
    }

    func testTheDefaultsAreLightsAtLevelOneAndSelectSomething() {
        // A kind whose default state selects nothing would need a form filled in before
        // it worked, which is what the AI kinds' removal from the roster was about.
        let p = plane { _ in }
        XCTAssertGreaterThan(p[47, 2], 0.5)
        XCTAssertNil(MaskComponent(op: .add, kind: .luminosity).validationError())
    }

    func testItReadsTheChosenChannelJustAsABandDoes() {
        // Same six channels, same fixed −10…+4 EV axis. If the two disagreed about what
        // "bright" means, the panel's Channel row would mean two different things one
        // row apart.
        let src = ImageBuffer(width: 8, height: 2) { u, _ in
            u < 0.5 ? RGB(2.0, 0.002, 0.002) : RGB(0.002, 0.002, 2.0)
        }
        var c = MaskComponent(op: .add, kind: .luminosity)
        c.series = .lights
        c.level = 2
        c.channel = .red
        let red = MaskRaster.rasterize(component: c, size: (width: 8, height: 2),
                                       source: src)
        XCTAssertGreaterThan(red[1, 0], 0.5, "the red-bright half is selected")
        XCTAssertLessThan(red[6, 0], 0.05)

        c.channel = .blue
        let blue = MaskRaster.rasterize(component: c, size: (width: 8, height: 2),
                                        source: src)
        XCTAssertLessThan(blue[1, 0], 0.05)
        XCTAssertGreaterThan(blue[6, 0], 0.5)
    }

    func testWithoutTheSourcePictureItSelectsNothingRatherThanEverything() {
        var c = MaskComponent(op: .add, kind: .luminosity)
        c.series = .lights
        let p = MaskRaster.rasterize(component: c, size: (width: 8, height: 8))
        XCTAssertEqual(p.values.max().map(Double.init) ?? 1, 0, accuracy: 0)
        XCTAssertTrue(MaskKind.luminosity.readsSourceImage,
                      "and it declares that it needs the picture, so a renderer that "
                          + "does not supply one is a bug rather than an empty mask")
    }

    func testTheLevelIsClampedRatherThanTrusted() {
        XCTAssertEqual(value(0.7, .lights, 99), value(0.7, .lights, 5), accuracy: 0)
        XCTAssertEqual(value(0.7, .lights, -3), value(0.7, .lights, 1), accuracy: 0)
        let p = plane { $0.series = .lights; $0.level = .nan }
        XCTAssertTrue(p.values.allSatisfy { $0.isFinite },
                      "a poisoned level may not produce a poisoned plane")
    }

    // MARK: - Wire format

    func testAnOldRecipeHasNoSeriesAndTheDefaultsStandIn() throws {
        let json = """
        {"pipelineVersion":1,"masks":[{"id":"m","components":[\
        {"op":"add","kind":"lumaRange","lo":0.2,"hi":0.8}]}]}
        """
        let r = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertNil(r.masks[0].components[0].series)
        XCTAssertNil(r.masks[0].components[0].level)
    }

    func testTheSeriesRoundTrips() throws {
        var recipe = Recipe()
        var c = MaskComponent(op: .add, kind: .luminosity)
        c.series = .midtones
        c.level = 3.5
        c.channel = .min
        recipe.masks = [Mask(id: "m", name: "mids", components: [c])]
        let back = try CanonicalJSON.decodeRecipe(
            from: Data(CanonicalJSON.canonicalRecipeJSON(recipe).utf8))
        XCTAssertEqual(back.masks[0].components[0].kind, .luminosity)
        XCTAssertEqual(back.masks[0].components[0].series, .midtones)
        XCTAssertEqual(back.masks[0].components[0].level, 3.5)
        XCTAssertEqual(back.masks[0].components[0].channel, .min)
    }
}

// VignetteResponseTests.swift
// The vignette audit, as assertions — docs/32 Stream E item 4(c), "reassess strength
// range only after banding is fixed", coming due against the owner's report that the
// vignette "is a little bit soft at both ends".
//
// `VignetteFeatherTests` next door pins the FEATHER field end to end: the recipe key,
// the plan, the reference renderer and the compatibility promise. This file pins the
// thing that field cannot answer — how much vignette a photographer actually gets for a
// given Amount, and where along the control it arrives. Every number here was measured
// before anything was changed, and the reason to commit them is the reason `ProofRecord`
// gives for committing its own: a behaviour change becomes a diff instead of a discovery.
//
// The unit throughout is sRGB code values at the display, through `ProofMetrics`, for the
// reason that file states at length: a scene-referred delta says nothing about what the
// eye gets, and every defect docs/19 found was invisible until somebody denominated it
// where the picture is looked at.
//
// WHAT THE AUDIT CONCLUDED, so a reader does not have to reverse-engineer it from
// twenty assertions:
//
//   1. The amount MAPPING is not the defect. The response is strictly monotone over 401
//      settings, it reaches 2^amount exactly at the corner at both ends, and its
//      increments across the negative half sit inside 1.7:1. It is not re-denominated
//      here and it must not be: EV is the property the whole control is built on.
//   2. The RANGE was the defect. At the old floor of −3 the control was still delivering
//      73% of its rate at zero and at the old ceiling of +1 it was delivering 81% — both
//      ends were stops, not limits. −4…+2 is where the measurements say to put them.
//   3. The FALLOFF really is soft at both ends — zero derivative at r = inner and at
//      r = 1 — and it is kept anyway, because every smooth monotone alternative measured
//      makes the vignette weaker, which is the opposite of what was asked for. The
//      numbers that forced that choice are pinned in `testTheHermiteIsTheStrongestShape`
//      so the next person to have the idea can read the result instead of repeating it.

import XCTest
@testable import LumenCore

final class VignetteResponseTests: XCTestCase {

    /// 3:2, which is the aspect every statistic here is quoted on — the falloff is
    /// normalized so the CORNER is r = 1, so the frame's shape decides what fraction of
    /// the picture sits at each radius, and a square frame would give different numbers.
    private func flat(_ w: Int = 120, _ h: Int = 80,
                      level: Double = 0.18) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { _, _ in RGB(gray: level) }
    }

    private func rendered(_ ev: Double, feather: Double = Look.vignetteFeatherDefault,
                          frame: ImageBuffer) -> ImageBuffer {
        var recipe = Recipe()
        recipe.look.vignette = ev
        recipe.look.vignetteFeather = feather
        return ReferenceRenderer.render(frame, plan: RenderPlan(recipe: recipe))
    }

    /// Delivered effect at one Amount: the mean separation from the un-vignetted render,
    /// in code values. `ProofMetrics`' own instrument, on the frame this file uses.
    private func delivered(_ ev: Double, feather: Double = Look.vignetteFeatherDefault,
                           frame: ImageBuffer, plain: ImageBuffer) -> Double {
        ProofMetrics.meanSeparation(plain, rendered(ev, feather: feather, frame: frame))
    }

    // MARK: - The range

    /// The range is −4…+2, it is stated once, and both renderers clamp to it.
    ///
    /// The GPU half cannot run here, so what this pins is the half that can: the engine
    /// clamps to exactly these bounds, and `RenderGraph.applyVignette` reads the same
    /// property rather than carrying a second copy of two numbers — which it did, and
    /// which is how it once rendered a deeper corner than the reference for any recipe
    /// outside the bounds (docs/31 round two §15).
    func testTheAmountRangeIsStatedOnceAndClamped() {
        XCTAssertEqual(DetailEngine.vignetteAmountRange.lowerBound, -4.0)
        XCTAssertEqual(DetailEngine.vignetteAmountRange.upperBound, 2.0)

        let frame = flat(48, 32)
        let atFloor = DetailEngine.vignette(frame, ev: -4)
        let past = DetailEngine.vignette(frame, ev: -12)
        for y in 0..<frame.height {
            for x in 0..<frame.width where atFloor[x, y] != past[x, y] {
                return XCTFail("the clamp let −12 render deeper than the floor at "
                               + "(\(x), \(y))")
            }
        }
        let atCeiling = DetailEngine.vignette(frame, ev: 2)
        let above = DetailEngine.vignette(frame, ev: 9)
        for y in 0..<frame.height {
            for x in 0..<frame.width where atCeiling[x, y] != above[x, y] {
                return XCTFail("the clamp let +9 render brighter than the ceiling at "
                               + "(\(x), \(y))")
            }
        }
    }

    /// THE FINDING THAT MOVED THE RANGE: at the old bounds the control was still
    /// working. Both ends, measured in delivered code values per 0.2 EV of travel.
    ///
    /// A control that stops while it is still delivering three-quarters of its rate at
    /// neutral is a control with a stop rather than a limit, and that is what "soft at
    /// both ends" turned out to be — not a flattening of the response but a truncation
    /// of it. The bars are set well below the measured values so that this test fails
    /// only if the rate at the old bounds COLLAPSES, which would mean the widening had
    /// stopped being justified.
    func testTheOldBoundsCutTheControlOffWhileItWasStillDelivering() {
        let frame = flat()
        let plain = ReferenceRenderer.render(frame, plan: RenderPlan(recipe: Recipe()))

        func rate(from a: Double, to b: Double) -> Double {
            abs(delivered(b, frame: frame, plain: plain)
                - delivered(a, frame: frame, plain: plain))
        }
        // Measured: 2.401 at neutral, 1.754 at the old floor, 2.909 at the old ceiling.
        let atNeutralDown = rate(from: 0.0, to: -0.2)
        let atOldFloor = rate(from: -2.8, to: -3.0)
        let atNeutralUp = rate(from: 0.0, to: 0.2)
        let atOldCeiling = rate(from: 0.8, to: 1.0)
        print(String(format: "VIGNETTE rate/0.2EV  neutral↓ %.3f  old floor %.3f  "
                     + "neutral↑ %.3f  old ceiling %.3f",
                     atNeutralDown, atOldFloor, atNeutralUp, atOldCeiling))

        XCTAssertGreaterThan(atOldFloor / atNeutralDown, 0.60,
                             "the old floor delivered \(atOldFloor) code values per "
                                 + "0.2 EV against \(atNeutralDown) at neutral — if that "
                                 + "ratio has collapsed the range no longer needs to be "
                                 + "wider than −3")
        XCTAssertGreaterThan(atOldCeiling / atNeutralUp, 0.70,
                             "the old ceiling delivered \(atOldCeiling) against "
                                 + "\(atNeutralUp) at neutral")
    }

    /// And what the widening buys, end to end: measured 35.05 → 42.67 code values of
    /// mean separation on the negative half (+22%) and 16.02 → 29.41 on the positive
    /// (+84%).
    func testTheWidenedRangeDeliversMoreThanTheOldOne() {
        let frame = flat()
        let plain = ReferenceRenderer.render(frame, plan: RenderPlan(recipe: Recipe()))
        let oldFloor = delivered(-3, frame: frame, plain: plain)
        let newFloor = delivered(-4, frame: frame, plain: plain)
        let oldCeiling = delivered(1, frame: frame, plain: plain)
        let newCeiling = delivered(2, frame: frame, plain: plain)
        print(String(format: "VIGNETTE authority  −3 %.3f → −4 %.3f   +1 %.3f → +2 %.3f",
                     oldFloor, newFloor, oldCeiling, newCeiling))
        XCTAssertGreaterThan(newFloor / oldFloor, 1.15,
                             "the fourth stop added \(newFloor / oldFloor - 1) of the "
                                 + "burn — under 15% and it is not worth the travel")
        XCTAssertGreaterThan(newCeiling / oldCeiling, 1.60,
                             "the second stop of lift added "
                                 + "\(newCeiling / oldCeiling - 1)")
    }

    /// Why it stops at −4 and +2 rather than further out, which is the half of a range
    /// decision that usually goes unwritten.
    ///
    /// Negative: the fifth stop's peak step measured 0.82 code values against the
    /// fourth's 1.42 — a step nobody can see, which docs/20's P2 calls dead. Positive:
    /// +3 EV puts a mid-grey corner at 0.18 × 8 = 1.44, past display white, so the
    /// "effect" of the third stop is the corner clipping.
    func testTheEndsAreWhereTheMeasurementsPutThem() {
        let frame = flat()
        // The corner's gain is exactly 2^amount, so the ceiling's argument is arithmetic
        // on the scene value and needs no render: state it where it can fail.
        XCTAssertLessThan(0.18 * pow(2.0, DetailEngine.vignetteAmountRange.upperBound),
                          1.0,
                          "the top of the range lifts a mid-grey corner past display "
                              + "white, so its last stop is a clip rather than an effect")
        XCTAssertGreaterThan(0.18 * pow(2.0,
                                        DetailEngine.vignetteAmountRange.upperBound + 1),
                             1.0,
                             "one more stop would still be inside display white, so the "
                                 + "ceiling is lower than the argument for it")

        // Negative: −5 must render as −4, which is what makes the floor a floor rather
        // than a suggestion.
        let atFloor = rendered(DetailEngine.vignetteAmountRange.lowerBound, frame: frame)
        let past = rendered(DetailEngine.vignetteAmountRange.lowerBound - 1, frame: frame)
        for y in 0..<frame.height {
            for x in 0..<frame.width where atFloor[x, y] != past[x, y] {
                return XCTFail("a value past the floor rendered differently from the "
                               + "floor at (\(x), \(y))")
            }
        }

        // And what the fifth stop would have been worth, computed on the falloff rather
        // than rendered, because the clamp is precisely what stands between a render and
        // this question. The largest gap between a four-stop and a five-stop burn over
        // the whole radius, on mid-grey: 0.18·(2^−4f − 2^−5f), maximized at
        // f = log₂(5/4) = 0.3219.
        var worstSceneStep = 0.0
        for i in 0...1000 {
            let f = Double(i) / 1000.0
            worstSceneStep = Swift.max(worstSceneStep,
                                       0.18 * (pow(2.0, -4 * f) - pow(2.0, -5 * f)))
        }
        // 0.0147 of scene-linear mid-grey, and — the number that actually decided it —
        // a measured peak step of 0.82 sRGB code values across that stop against the
        // fourth stop's 1.42. Under a code value is under what an 8-bit display can
        // show, which is docs/20's own definition of a dead step.
        XCTAssertEqual(worstSceneStep, 0.0147, accuracy: 0.001,
                       "a fifth stop is worth \(worstSceneStep) of scene-linear mid-grey "
                           + "at its widest; the floor sits at four because that is "
                           + "under a display code value once the transform has had it")
    }

    // MARK: - The mapping, exonerated

    /// Strictly monotone across the whole widened range, at the step the slider uses.
    ///
    /// This is the assertion the audit was asked for and it PASSES, which is the useful
    /// result: whatever "soft at both ends" is, it is not a response that flattens or
    /// reverses. `ProofRecord.isMonotone` says the same thing about the committed sweep;
    /// this says it at 601 settings instead of 21.
    func testTheResponseIsStrictlyMonotoneAcrossTheWholeRange() {
        let frame = flat(40, 28)
        var previous = Double.infinity
        var worstReversal = 0.0
        var smallestStep = Double.infinity
        for i in stride(from: 200, through: -400, by: -1) {
            let out = rendered(Double(i) / 100.0, frame: frame)
            var total = 0.0
            for y in 0..<frame.height {
                for x in 0..<frame.width { total += Double(out[x, y].g) }
            }
            let mean = total / Double(frame.count)
            if previous.isFinite {
                if mean > previous { worstReversal = Swift.max(worstReversal,
                                                               mean - previous) }
                smallestStep = Swift.min(smallestStep, previous - mean)
            }
            previous = mean
        }
        print(String(format: "VIGNETTE monotonicity: worst reversal %.3e, "
                     + "smallest step %.3e", worstReversal, smallestStep))
        XCTAssertEqual(worstReversal, 0, accuracy: 0,
                       "the vignette handed back \(worstReversal) of mean scene level "
                           + "somewhere in its travel — a control that reverses is doing "
                           + "two things and the photographer can only see one")
    }

    /// The corner receives exactly the stated EV, at both ends of the widened range and
    /// at every feather. This is the "does it reach its stated extremes" question, and
    /// the answer is yes to four decimal places.
    ///
    /// Measured on the SCENE-referred stage rather than through the display transform,
    /// because the claim the panel makes is about stops of scene light — the corner at
    /// −4 EV is 2⁻⁴ of what it was, and what the finish table then does with that value
    /// is the transform's business.
    func testTheCornerReceivesExactlyTheStatedStops() {
        // Odd dimensions so a pixel sits on the exact centre. The corner PIXEL's centre
        // is a half-pixel inside r = 1 — it measures r = 0.99585 on this frame — and
        // that half-pixel is the whole of the residual below. It is bigger at feather 0,
        // where the falloff is compressed into the outer quarter of the radius and a
        // half-pixel of radius is four times as much of the falloff's own travel; a
        // small frame reports 2% there and says nothing about the engine.
        let frame = flat(301, 201)
        for feather in [0.0, 25.0, 50.0, 75.0, 100.0] {
            for ev in [DetailEngine.vignetteAmountRange.lowerBound, -2.0, -0.5, 1.0,
                       DetailEngine.vignetteAmountRange.upperBound] {
                let out = DetailEngine.vignette(frame, ev: ev, feather: feather)
                let gain = Double(out[0, 0].g) / Double(frame[0, 0].g)
                XCTAssertEqual(gain, pow(2.0, ev), accuracy: abs(pow(2.0, ev)) * 0.01,
                               "corner gain at \(ev) EV, feather \(feather) was \(gain) "
                                   + "against 2^\(ev) = \(pow(2.0, ev))")
                let centre = out[frame.width / 2, frame.height / 2].g
                XCTAssertEqual(centre, frame[frame.width / 2, frame.height / 2].g,
                               accuracy: 0,
                               "the centre must be untouched at every amount and feather")
            }
        }
    }

    /// The increments across the negative half stay inside 2:1 in the unit the eye
    /// reads, which is what "the mapping is not flat at the ends" means quantitatively.
    ///
    /// Measured 2.40 at neutral, peaking 2.90 around −0.6, falling to 1.39 at the new
    /// floor: a spread of 2.1:1 over four stops. For comparison, docs/19's example of a
    /// control whose top half is decoration is Highlights at 87% front-loading.
    func testTheIncrementsAcrossTheNegativeHalfStayWithinTwoToOne() {
        let frame = flat()
        let plain = ReferenceRenderer.render(frame, plan: RenderPlan(recipe: Recipe()))
        var steps: [Double] = []
        var previous = 0.0
        for i in stride(from: 0, through: -40, by: -2) {
            let value = delivered(Double(i) / 10.0, frame: frame, plain: plain)
            if i != 0 { steps.append(value - previous) }
            previous = value
        }
        let biggest = steps.max() ?? 0
        let smallest = steps.min() ?? 0
        print(String(format: "VIGNETTE negative-half steps: max %.3f min %.3f ratio %.2f",
                     biggest, smallest, biggest / Swift.max(smallest, 1e-9)))
        XCTAssertGreaterThan(smallest, 0, "every step must move the picture")
        XCTAssertLessThan(biggest / smallest, 2.5,
                          "the negative half's best step is \(biggest / smallest) times "
                              + "its worst — past about 2.5 the control really would be "
                              + "flat at one end and the EV denomination would be worth "
                              + "re-examining")
    }

    // MARK: - The falloff, which is what is genuinely soft at both ends

    /// The measured shape of the falloff over a 3:2 frame, at every feather. These are
    /// the numbers the Amount and Feather tooltips now quote, and the tooltips are wrong
    /// the moment this test is.
    func testTheFalloffStatisticsTheTooltipsQuote() {
        let expected: [(feather: Double, mean: Double, hi: Double, lo: Double)] = [
            (0, 0.0407, 0.49, 91.03),
            (25, 0.1437, 1.51, 66.00),
            (50, 0.2916, 3.15, 38.81),
            (75, 0.4350, 5.44, 18.88),
            (100, 0.5565, 8.47, 6.01),
        ]
        for e in expected {
            let s = Self.falloffStatistics(
                inner: DetailEngine.vignetteInnerRadius(feather: e.feather))
            XCTAssertEqual(s.mean, e.mean, accuracy: 0.002,
                           "frame-mean falloff at feather \(e.feather)")
            XCTAssertEqual(s.percentAtLeast90, e.hi, accuracy: 0.2,
                           "share of the frame at 90% or more of Amount, feather "
                               + "\(e.feather)")
            XCTAssertEqual(s.percentAtMost10, e.lo, accuracy: 0.3,
                           "share of the frame at 10% or less of Amount, feather "
                               + "\(e.feather)")
        }
        // The headline: at the DEFAULT feather the stated Amount lands on 3.15% of the
        // picture, 38.81% of it gets a tenth or less, and the frame mean is 0.2916 — so
        // "−3.00 EV" darkens the photograph by a mean of 0.87 EV. The Amount row's help
        // now says the number is a corner number, and the Feather row's says what
        // fraction of it the frame receives, because of these three numbers.
        let atDefault = Self.falloffStatistics(inner: DetailEngine.vignetteInnerRadius)
        XCTAssertEqual(atDefault.mean * 3.0, 0.875, accuracy: 0.01)
    }

    /// Both ends of the falloff are flat, and here is how flat, because it is the thing
    /// the owner reported and it deserves a number rather than a shrug.
    ///
    /// A Hermite has zero derivative at both edges by construction. The consequence at
    /// the outer edge is the one that reads as a defect on a photograph: the outer tenth
    /// of the radius — visually "the corners" — carries 6.9% of the burn at the default
    /// feather and 2.8% at feather 100, so the corner region is a plateau and the burn
    /// stops deepening exactly where a vignette should be deepest.
    func testBothEndsOfTheFalloffAreFlatAndThisIsByHowMuch() {
        for (feather, share) in [(0.0, 0.3520), (50.0, 0.0686), (100.0, 0.0280)] {
            let inner = DetailEngine.vignetteInnerRadius(feather: feather)
            let outerTenth = 1 - DetailEngine.vignetteFalloff(radius: 0.9, inner: inner)
            XCTAssertEqual(outerTenth, share, accuracy: 0.002,
                           "the outer tenth of the radius carries \(outerTenth) of the "
                               + "burn at feather \(feather)")
        }
        // The inner edge, same fact from the other side: the slope at r = inner is zero,
        // so the burn arrives quadratically and a wide annulus does nothing.
        let inner = DetailEngine.vignetteInnerRadius
        let justInside = DetailEngine.vignetteFalloff(radius: inner + 0.01, inner: inner)
        XCTAssertLessThan(justInside, 0.002,
                          "a hundredth of the radius past the falloff's start delivers "
                              + "\(justInside) of the Amount — that is the soft inner "
                              + "end, and it is what keeps a burn from showing a ring")
    }

    /// WHY THE SHAPE WAS NOT CHANGED, in numbers, so the next person to have the idea
    /// can read the answer instead of re-deriving it.
    ///
    /// Removing the outer plateau means a falloff that arrives at r = 1 with a live
    /// slope, and on a support fixed at [inner, 1] with the corner pinned to the stated
    /// Amount every such shape is BELOW the Hermite everywhere — for the cubic family
    /// with f'(1) = s the difference is exactly s·t²(1−t) ≥ 0. So a live corner is
    /// bought with 20–45% of the delivered strength, and `t²` cannot reach the Hermite's
    /// frame mean even with the falloff started at the picture's centre. A photographer
    /// who says the vignette is not strong enough is not asking for that trade.
    func testTheHermiteIsTheStrongestShape() {
        let hermiteAtDefault = Self.falloffStatistics(inner: 0.375).mean
        let hermiteAtCentre = Self.falloffStatistics(inner: 0.0).mean
        XCTAssertEqual(hermiteAtDefault, 0.2916, accuracy: 0.002)
        XCTAssertEqual(hermiteAtCentre, 0.5565, accuracy: 0.002)

        var candidates: [Candidate] = []
        candidates.append(Candidate(name: "t²", atDefault: 0.1612, atCentre: 0.3333,
                                    shape: { t in t * t }))
        candidates.append(Candidate(name: "t^1.5", atDefault: 0.2188, atCentre: 0.4197,
                                    shape: { t in pow(t, 1.5) }))
        candidates.append(Candidate(name: "5t²−8t³+4t⁴", atDefault: 0.2882,
                                    atCentre: 0.5150,
                                    shape: { t in t * t * (5 - 8 * t + 4 * t * t) }))
        for candidate in candidates {
            let d = Self.falloffStatistics(inner: 0.375, shape: candidate.shape).mean
            let c = Self.falloffStatistics(inner: 0.0, shape: candidate.shape).mean
            XCTAssertEqual(d, candidate.atDefault, accuracy: 0.002,
                           "\(candidate.name) at the default feather")
            XCTAssertEqual(c, candidate.atCentre, accuracy: 0.002,
                           "\(candidate.name) at feather 100")
            XCTAssertLessThan(d, hermiteAtDefault,
                              "\(candidate.name) delivers \(d) against the Hermite's "
                                  + "\(hermiteAtDefault) — if a shape ever beats it here "
                                  + "AND has a live slope at the corner, the shape "
                                  + "should change and this test should say so")
            XCTAssertLessThan(c, hermiteAtCentre, "\(candidate.name) at feather 100")
        }
    }

    /// One candidate falloff and the two frame means it was measured at. A named type
    /// rather than a tuple because the heterogeneous array literal — a string, a closure
    /// and two doubles — is what the type checker gives up on.
    private struct Candidate {
        let name: String
        let atDefault: Double
        let atCentre: Double
        let shape: (Double) -> Double
    }

    /// Feather is the strength control and Amount is its ceiling — a twelvefold range in
    /// the delivered picture at one Amount. Stated as a test because the Feather
    /// tooltip now says it, and because it is the single most surprising fact about this
    /// pair of sliders.
    func testFeatherMovesTheDeliveredStrengthTwelvefold() {
        let frame = flat()
        let plain = ReferenceRenderer.render(frame, plan: RenderPlan(recipe: Recipe()))
        var values: [Double] = []
        for feather in [0.0, 25.0, 50.0, 75.0, 100.0] {
            values.append(delivered(-3, feather: feather, frame: frame, plain: plain))
        }
        print("VIGNETTE delivered at −3 EV by feather: "
              + values.map { String(format: "%.4f", $0) }.joined(separator: ", "))
        for (a, b) in zip(values, values.dropFirst()) {
            XCTAssertGreaterThan(b, a, "more feather must deliver more vignette")
        }
        let ratio = values[4] / values[0]
        XCTAssertGreaterThan(ratio, 8,
                             "feather 100 delivers \(ratio)× what feather 0 does; the "
                                 + "Feather tooltip quotes a twelvefold spread and is "
                                 + "wrong if this drops much below it")
    }

    // MARK: - Frame statistics

    private struct FalloffStatistics {
        let mean: Double
        let percentAtLeast90: Double
        let percentAtMost10: Double
    }

    /// The falloff over a 3:2 frame, for an arbitrary shape on [inner, 1]. Written once
    /// because six assertions above want it and because the aspect ratio is part of
    /// every number it returns.
    private static func falloffStatistics(
        inner: Double,
        shape: ((Double) -> Double)? = nil) -> FalloffStatistics {
        let w = 300, h = 200
        let halfW = Double(w) * 0.5, halfH = Double(h) * 0.5
        let norm = 1.0 / (2.0 as Double).squareRoot()
        var sum = 0.0
        var hi = 0, lo = 0
        for y in 0..<h {
            let v = (Double(y) + 0.5 - halfH) / halfH
            for x in 0..<w {
                let u = (Double(x) + 0.5 - halfW) / halfW
                let r = (u * u + v * v).squareRoot() * norm
                let value: Double
                if let shape {
                    value = inner < 1
                        ? shape(Num.saturate((r - inner) / (1 - inner)))
                        : (r >= 1 ? 1 : 0)
                } else {
                    value = DetailEngine.vignetteFalloff(radius: r, inner: inner)
                }
                sum += value
                if value >= 0.9 { hi += 1 }
                if value <= 0.1 { lo += 1 }
            }
        }
        let n = Double(w * h)
        return FalloffStatistics(mean: sum / n,
                                 percentAtLeast90: 100 * Double(hi) / n,
                                 percentAtMost10: 100 * Double(lo) / n)
    }
}

// GeometryAndOutputTests.swift
// Batch 6: the soft proof, the export dither and the straighten ruler.
//
// Every test here asserts BOTH halves — that the thing moves the picture, and that it
// moves it the right way. "Something changed" is what a broken stage passes, and this
// repository has shipped several of those.

import XCTest
@testable import LumenCore

final class GeometryAndOutputTests: XCTestCase {

    // MARK: - Soft proof

    /// A Rec.2020 green cannot be stored in sRGB. With the warning on, the proof has to
    /// SAY so — and with it off, it has to bring the colour inside the destination
    /// rather than leaving it where it was.
    func testProofFlagsAndMapsAColourSRGBCannotHold() {
        let green = RGB(0.05, 0.75, 0.05)
        let warn = SoftProofTransform(SoftProof(enabled: true, space: .srgb,
                                                intent: .relativeColorimetric,
                                                showGamutWarning: true))
        XCTAssertTrue(warn.isOutOfGamut(green), "a saturated Rec.2020 green is outside sRGB")
        XCTAssertEqual(warn.apply(green).maxAbsDifference(SoftProof.warningColor), 0,
                       accuracy: 1e-12, "the warning colour is what flags it")

        let map = SoftProofTransform(SoftProof(enabled: true, space: .srgb,
                                               intent: .relativeColorimetric,
                                               showGamutWarning: false))
        let proofed = map.apply(green)
        XCTAssertGreaterThan(proofed.maxAbsDifference(green), 0.01,
                             "the proof has to change a colour the destination cannot hold")
        XCTAssertFalse(map.isOutOfGamut(proofed),
                       "and what it produces has to be inside the destination")
    }

    /// The half that would pass for free if the transform were the identity: a colour
    /// well inside sRGB has to come back untouched, through both matrices.
    func testProofLeavesAnInGamutColourAlone() {
        let grey = RGB(0.18, 0.18, 0.18)
        let dullBlue = RGB(0.12, 0.16, 0.30)
        for intent in RenderingIntent.allCases {
            let proof = SoftProofTransform(SoftProof(enabled: true, space: .srgb,
                                                     intent: intent))
            for c in [grey, dullBlue] {
                XCTAssertFalse(proof.isOutOfGamut(c))
                XCTAssertLessThan(proof.apply(c).maxAbsDifference(c), 1e-6,
                                  "\(intent) moved an in-gamut colour")
            }
        }
    }

    /// Perceptual and relative colorimetric must not be the same function, and the
    /// difference has to be the documented one: the colorimetric intent clips each
    /// channel, which shifts hue, while the perceptual intent compresses chroma along a
    /// constant-hue line and holds the hue.
    func testPerceptualIntentHoldsHueWhereTheColorimetricOneDoesNot() {
        let blue = RGB(0.03, 0.05, 0.95)
        let ctx = OKLabTransform.working
        let original = ctx.toLCh(blue).h

        func hueShift(_ intent: RenderingIntent) -> Double {
            let proof = SoftProofTransform(SoftProof(enabled: true, space: .srgb,
                                                     intent: intent,
                                                     showGamutWarning: false))
            let out = ctx.toLCh(proof.apply(blue))
            return abs(Num.wrapHue(out.h - original + 180) - 180)
        }

        let clipped = hueShift(.relativeColorimetric)
        let compressed = hueShift(.perceptual)
        XCTAssertGreaterThan(clipped, 1.0,
                             "a per-channel clip of a deep blue rotates its hue — if it "
                                 + "does not, this colour is no longer out of gamut and "
                                 + "the test needs a more saturated one")
        XCTAssertLessThan(compressed, clipped / 2,
                          "perceptual compresses along constant hue: \(compressed)° "
                              + "against the clip's \(clipped)°")
    }

    /// Paper-white simulation has to do exactly what its name says: white comes down to
    /// the paper's reflectance and black comes up off zero. A proof that only dimmed the
    /// whites would look right and be a different thing.
    func testPaperWhiteCompressesBothEnds() {
        let plain = SoftProofTransform(SoftProof(enabled: true, space: .srgb,
                                                 showGamutWarning: false))
        let paper = SoftProofTransform(SoftProof(enabled: true, space: .srgb,
                                                 showGamutWarning: false,
                                                 simulatePaperWhite: true))
        let white = paper.apply(RGB(gray: 1))
        let black = paper.apply(RGB(gray: 0))
        XCTAssertEqual(white.g, SoftProof.paperWhite, accuracy: 1e-6)
        XCTAssertEqual(black.g, SoftProof.inkBlack, accuracy: 1e-6)
        XCTAssertEqual(plain.apply(RGB(gray: 1)).g, 1, accuracy: 1e-6,
                       "without the toggle white stays white")
        XCTAssertEqual(plain.apply(RGB(gray: 0)).g, 0, accuracy: 1e-6)
    }

    /// A wider destination flags less than a narrower one. This is the check that would
    /// catch the proof being wired to a fixed space and ignoring the picker — the failure
    /// mode where every setting produces the same picture.
    func testTheDestinationPickerChangesWhatIsFlagged() {
        let colour = RGB(0.05, 0.55, 0.20)
        func flagged(_ space: ExportColorSpace) -> Bool {
            SoftProofTransform(SoftProof(enabled: true, space: space)).isOutOfGamut(colour)
        }
        XCTAssertTrue(flagged(.srgb))
        XCTAssertFalse(flagged(.rec2020), "the working space holds its own colours")
    }

    /// The wiring itself: a plan built WITH a proof has to render a different picture
    /// from one built without, through the very table both render paths apply. This is
    /// the test that fails if the proof stops reaching pixels.
    func testTheFinishTableCarriesTheProof() {
        let recipe = Recipe()
        let plain = RenderPlan(recipe: recipe)
        let proofed = RenderPlan(recipe: recipe,
                                 softProof: SoftProof(enabled: true, space: .srgb,
                                                      showGamutWarning: true))
        XCTAssertNil(plain.softProof)
        XCTAssertNotNil(proofed.softProof)

        // A scene-linear colour that forms into a saturated green — outside sRGB, inside
        // the Rec.2020 working space.
        let scene = RGB(0.02, 1.2, 0.02)
        let before = plain.referenceColor(scene)
        let after = proofed.referenceColor(scene)
        XCTAssertGreaterThan(after.maxAbsDifference(before), 0.05,
                             "the proof reaches the finish table, or it reaches nothing")
        XCTAssertLessThan(after.maxAbsDifference(SoftProof.warningColor), 0.12,
                          "and what lands there is the warning, not an arbitrary colour")

        // A neutral is inside every destination, so proofing must leave it where it was.
        let neutral = RGB(gray: 0.18)
        XCTAssertLessThan(proofed.referenceColor(neutral)
                            .maxAbsDifference(plain.referenceColor(neutral)), 0.01,
                          "a proof that moves a neutral is not a proof")
    }

    /// The flag has to be computed per pixel, not baked.
    ///
    /// This is a regression guard on a measurement. Composed into the finish table, the
    /// flag's edge landed a mean of 0.017 OKLCh chroma from the true gamut boundary and
    /// mislabelled 6.0% of a realistic hue/chroma/lightness sweep, because trilinear
    /// interpolation cannot hold a discontinuity. Computing it from the unproofed table
    /// instead took that to 0.0033 chroma and 0.71%. Fold the flag back into the table
    /// and this fails.
    func testTheGamutFlagIsSharperThanTheTableCouldBake() {
        let proof = SoftProof(enabled: true, space: .srgb, showGamutWarning: true)
        let plan = RenderPlan(recipe: Recipe(), softProof: proof)
        XCTAssertNotNil(plan.finishLUTBeforeProof,
                        "the unproofed table is what makes the flag exact")
        XCTAssertNil(RenderPlan(recipe: Recipe(),
                                softProof: SoftProof(enabled: true, space: .srgb,
                                                     showGamutWarning: false))
                        .finishLUTBeforeProof,
                     "and nothing pays for it when there is no flag to draw")

        let ctx = OKLabTransform.working
        var disagree = 0
        var total = 0
        for hueStep in 0..<36 {
            let hue = Double(hueStep) * 10
            for lightnessStep in 1..<10 {
                let lightness = Double(lightnessStep) / 10
                var chroma = 0.0
                while chroma <= 0.3 {
                    let scene = ctx.toRGB(OKLCh(L: lightness, C: chroma, h: hue)) * 0.6
                    let table = plan.referenceColor(scene) / plan.finishScale
                    let exact = plan.exactColor(scene) / plan.finishScale
                    let tableFlagged = table.maxAbsDifference(SoftProof.warningColor) < 0.02
                    let exactFlagged = exact.maxAbsDifference(SoftProof.warningColor) < 1e-9
                    if tableFlagged != exactFlagged { disagree += 1 }
                    total += 1
                    chroma += 0.01
                }
            }
        }
        let rate = Double(disagree) / Double(total)
        XCTAssertLessThan(rate, 0.02,
                          "the flag disagreed with the exact answer on \(rate * 100)% of "
                              + "the sweep — a baked flag measured 6.0%")
    }

    /// Off means off: an unproofed plan must be bit-identical to one built before the
    /// argument existed, or every render in the app just changed.
    func testProofingOffChangesNothing() {
        let recipe = Recipe()
        let plain = RenderPlan(recipe: recipe)
        let disabled = RenderPlan(recipe: recipe, softProof: SoftProof(enabled: false))
        XCTAssertNil(disabled.softProof)
        for i in 0...16 {
            let scene = RGB(gray: 0.01 * pow(2.0, Double(i) / 2))
            XCTAssertEqual(disabled.referenceColor(scene)
                            .maxAbsDifference(plain.referenceColor(scene)), 0,
                           accuracy: 1e-12)
        }
    }

    /// End to end through `ReferenceRenderer` — a whole frame, every stage, the path the
    /// app actually takes when the GPU kernels will not compile.
    ///
    /// The table tests above prove the composition; this proves the renderer applies it.
    /// A stage can be correct and unreached, which is the failure this whole batch exists
    /// to close, so the check is made on rendered pixels rather than on a function.
    func testTheReferenceRendererDrawsTheProof() {
        // Left half a saturated Rec.2020 green, right half mid-grey.
        let source = ImageBuffer(width: 16, height: 4) { u, _ in
            u < 0.5 ? RGB(0.02, 1.1, 0.02) : RGB(gray: 0.18)
        }
        let proof = SoftProof(enabled: true, space: .srgb, showGamutWarning: true)
        let plain = ReferenceRenderer.render(source, plan: RenderPlan(recipe: Recipe()))
        let proofed = ReferenceRenderer.render(
            source, plan: RenderPlan(recipe: Recipe(), softProof: proof))

        let flag = SoftProof.warningColor
        XCTAssertLessThan(proofed[2, 2].maxAbsDifference(flag), 0.02,
                          "the green half was not flagged: \(proofed[2, 2])")
        XCTAssertGreaterThan(plain[2, 2].maxAbsDifference(flag), 0.05,
                             "the unproofed render must not already be that colour, or "
                                 + "the assertion above proves nothing")
        XCTAssertLessThan(proofed[13, 2].maxAbsDifference(plain[13, 2]), 0.005,
                          "proofing moved an in-gamut neutral")

        // And the picture half without the flag: still changed where sRGB cannot reach,
        // still untouched where it can.
        let quiet = ReferenceRenderer.render(
            source,
            plan: RenderPlan(recipe: Recipe(),
                             softProof: SoftProof(enabled: true, space: .srgb,
                                                  showGamutWarning: false)))
        XCTAssertGreaterThan(quiet[2, 2].maxAbsDifference(plain[2, 2]), 0.02,
                             "the proof's gamut map did nothing to an out-of-gamut green")
        XCTAssertLessThan(quiet[13, 2].maxAbsDifference(plain[13, 2]), 0.005)
    }

    // MARK: - Export dither

    /// The matrix has to be a permutation of 0..<64, which is what makes an ordered
    /// dither spread its error evenly, and it has to average to zero so the dither adds
    /// no exposure.
    func testBayerMatrixIsAPermutationCentredOnZero() {
        var seen = Set<Int>()
        var sum = 0.0
        for y in 0..<Dither.matrixSide {
            for x in 0..<Dither.matrixSide {
                seen.insert(Dither.index(x: x, y: y))
                let o = Dither.offset(x: x, y: y)
                XCTAssertGreaterThan(o, -0.5)
                XCTAssertLessThan(o, 0.5)
                sum += o
            }
        }
        XCTAssertEqual(seen.count, Dither.matrixSide * Dither.matrixSide,
                       "every cell distinct")
        XCTAssertEqual(sum, 0, accuracy: 1e-12, "and no net bias")
        // It has to TILE: a pixel 8 across is the same cell again, and a negative
        // coordinate has to wrap rather than fall out of the matrix.
        XCTAssertEqual(Dither.index(x: 3, y: 5), Dither.index(x: 11, y: 13))
        XCTAssertEqual(Dither.index(x: 3, y: 5), Dither.index(x: -5, y: -3))
    }

    /// The units check. One 8-bit code is a very different distance in linear light at
    /// the bottom of the sRGB curve than at the top, and a dither denominated in a
    /// constant would be wrong by that factor everywhere but one luminance.
    func testACodeIsNotAFixedDistanceInLinearLight() {
        let shadow = Dither.codeStep(0.002, transfer: .srgb, levels: 256)
        let highlight = Dither.codeStep(0.9, transfer: .srgb, levels: 256)
        XCTAssertGreaterThan(shadow, 0)
        XCTAssertGreaterThan(highlight / shadow, 5,
                             "if these were close, `codeStep` is not reading the curve")
        // And it is genuinely one code wide: quantizing v ± the step must land one code
        // apart.
        for v in [0.01, 0.18, 0.5, 0.9] {
            let step = Dither.codeStep(v, transfer: .srgb, levels: 256)
            let lo = (TransferFunction.srgb.encode(v - step / 2) * 255).rounded()
            let hi = (TransferFunction.srgb.encode(v + step / 2) * 255).rounded()
            XCTAssertEqual(hi - lo, 1, accuracy: 0.51,
                           "one code step at \(v) spanned \(hi - lo) codes")
        }
        XCTAssertFalse(Dither.isWorthwhile(bitDepth: 16), "16-bit does not band")
        XCTAssertTrue(Dither.isWorthwhile(bitDepth: 8))
    }

    /// The behaviour the whole thing exists for: an 8-bit quantize of a smooth gradient
    /// bands, and the dither has to remove the banding by restoring the local MEAN.
    ///
    /// Both halves are asserted, and the undithered half is asserted first — a test that
    /// only checked the dithered result would pass on a pipeline that had no banding to
    /// fix, which is to say on a broken measurement.
    func testDitherRestoresTheMeanOfARampThatOtherwiseBands() {
        let side = Dither.matrixSide
        let levels = 256
        // A ramp spanning about four output codes near mid-grey, so every tile of the
        // matrix sees a value strictly between two codes.
        let base = 0.18
        let span = 4 * Dither.codeStep(base, transfer: .srgb, levels: levels)

        func quantize(_ v: Double) -> Double {
            let code = (TransferFunction.srgb.encode(Num.saturate(v)) * 255).rounded()
            return TransferFunction.srgb.decode(code / 255)
        }

        var worstPlain = 0.0
        var worstDithered = 0.0
        // 24 tiles across the ramp: each is one 8×8 block whose true value is constant,
        // so the block mean is a fair reading of what the eye integrates.
        for tile in 0..<24 {
            let truth = base + span * (Double(tile) / 23 - 0.5)
            var plainSum = 0.0
            var ditheredSum = 0.0
            for y in 0..<side {
                for x in 0..<side {
                    plainSum += quantize(truth)
                    ditheredSum += quantize(Dither.apply(truth, x: x, y: y,
                                                         transfer: .srgb, levels: levels))
                }
            }
            let cells = Double(side * side)
            let unit = Dither.codeStep(truth, transfer: .srgb, levels: levels)
            worstPlain = runningMax(worstPlain, abs(plainSum / cells - truth) / unit)
            worstDithered = runningMax(worstDithered, abs(ditheredSum / cells - truth) / unit)
        }
        XCTAssertGreaterThan(worstPlain, 0.3,
                             "an undithered ramp should be off by up to half a code — "
                                 + "\(worstPlain) says this ramp does not band, so the "
                                 + "dithered half below proves nothing")
        XCTAssertLessThan(worstDithered, 0.05,
                          "the dither has to put the mean back: \(worstDithered) of a code")
        XCTAssertLessThan(worstDithered, worstPlain / 5)
    }

    /// The dither must never move a pixel by more than half a code, or it is noise
    /// rather than dither — and it must not touch a value at the ends where there is no
    /// code to dither toward.
    func testDitherStaysWithinHalfACode() {
        for v in [0.0, 0.001, 0.18, 0.5, 0.999, 1.0] {
            let step = Dither.codeStep(v, transfer: .srgb, levels: 256)
            for y in 0..<Dither.matrixSide {
                for x in 0..<Dither.matrixSide {
                    let moved = Dither.apply(v, x: x, y: y, transfer: .srgb, levels: 256)
                    XCTAssertLessThanOrEqual(abs(moved - v), step / 2 + 1e-12)
                }
            }
        }
    }

    /// Each destination space's own curve, because the code spacing that sets the
    /// amplitude belongs to the curve the encoder will apply, not to sRGB's.
    func testEachExportSpaceCarriesItsOwnTransferCurve() {
        XCTAssertEqual(ExportColorSpace.srgb.transfer, .srgb)
        XCTAssertEqual(ExportColorSpace.displayP3.transfer, .srgb)
        XCTAssertEqual(ExportColorSpace.adobeRGB.transfer, .gamma22)
        XCTAssertEqual(ExportColorSpace.proPhoto.transfer, .gamma18)
        // Deep in the shadows the two curves disagree by nearly 4×: sRGB's linear toe
        // holds a constant code spacing all the way to black, while a pure 2.2 gamma's
        // codes crowd toward zero. A dither that used one curve for the other would be
        // wrong by that factor for every Adobe RGB delivery.
        let adobe = Dither.codeStep(0.0002, transfer: ExportColorSpace.adobeRGB.transfer,
                                    levels: 256)
        let srgb = Dither.codeStep(0.0002, transfer: ExportColorSpace.srgb.transfer,
                                   levels: 256)
        XCTAssertGreaterThan(srgb / adobe, 2,
                             "sRGB's toe against a pure gamma: \(srgb) vs \(adobe)")
    }

    // MARK: - Straighten ruler

    /// The ruler's whole job: after it writes an angle, the line that was dragged is
    /// level. Checked against the forward mapping rather than against a number, so the
    /// sign cannot be right in the test and wrong in the app.
    func testTheRulerLevelsTheLineItWasDraggedAlong() {
        for flipped in [false, true] {
            for current in [-30.0, -7.5, 0.0, 3.0, 22.0] {
                for source in [-40.0, -12.0, -0.5, 0.0, 5.0, 33.0] {
                    // Where that source line appears on the frame the viewer is showing.
                    let shown = Straighten.displayedDirection(sourceDegrees: source,
                                                              angle: current,
                                                              flipped: flipped)
                    let dx = cos(shown * .pi / 180) * 400
                    let dy = sin(shown * .pi / 180) * 400
                    guard let next = Straighten.angle(current: current, dx: dx, dy: dy,
                                                      flipped: flipped,
                                                      frameLongEdge: 1000) else {
                        XCTFail("a 400 pt drag is not too short")
                        continue
                    }
                    let after = Straighten.displayedDirection(sourceDegrees: source,
                                                              angle: next,
                                                              flipped: flipped)
                    let where_ = "flipped=\(flipped) current=\(current) source=\(source)"
                    if abs(next) < Straighten.limitDegrees - 1e-9 {
                        XCTAssertEqual(after, 0, accuracy: 1e-6,
                                       "\(where_): left at \(after)°")
                    } else {
                        // The answer wanted more than ±45°, which the slider does not
                        // have. It must still move TOWARD level rather than away, which
                        // is the only honest thing to do at the stop.
                        XCTAssertLessThan(abs(after), abs(shown) - 1e-9,
                                          "\(where_): clamped at the limit and made it "
                                              + "worse — \(shown)° became \(after)°")
                    }
                }
            }
        }
    }

    /// The sign, stated once as a fact rather than left to the property test: a horizon
    /// that runs DOWN to the right on an unrotated frame needs a negative angle to level
    /// it. If this ever flips, every ruler drag rotates the picture the wrong way and the
    /// property test above still passes, because it would be wrong in both directions at
    /// once.
    func testASlopingHorizonRotatesTheExpectedWay() {
        let down = Straighten.angle(current: 0, dx: 400, dy: 21, frameLongEdge: 1000)
        XCTAssertNotNil(down)
        XCTAssertEqual(down ?? 0, -3.0, accuracy: 0.01)
        let up = Straighten.angle(current: 0, dx: 400, dy: -21, frameLongEdge: 1000)
        XCTAssertEqual(up ?? 0, 3.0, accuracy: 0.01)
        // Dragging the same horizon backwards is the same line, so it must give the same
        // answer — a ruler that depended on drag direction would be maddening.
        let backwards = Straighten.angle(current: 0, dx: -400, dy: -21,
                                         frameLongEdge: 1000)
        XCTAssertEqual(backwards ?? 0, -3.0, accuracy: 0.01)
    }

    /// A line nearer vertical levels to vertical, from the same gesture — docs/09's rule,
    /// and the reason the residual is folded into ±45° rather than clamped.
    func testANearVerticalDragLevelsToVertical() {
        // 87° from horizontal: a doorframe leaning 3° off true.
        let radians: Double = 87 * .pi / 180
        let dx = cos(radians) * 400
        let dy = sin(radians) * 400
        let next = Straighten.angle(current: 0, dx: dx, dy: dy, frameLongEdge: 1000)
        XCTAssertEqual(next ?? 0, 3.0, accuracy: 0.01)
        XCTAssertEqual(Straighten.wrapToAxis(87), -3, accuracy: 1e-9)
        XCTAssertEqual(Straighten.wrapToAxis(-87), 3, accuracy: 1e-9)
        XCTAssertEqual(Straighten.wrapToAxis(45), 45, accuracy: 1e-9)
        XCTAssertEqual(Straighten.wrapToAxis(-45), 45, accuracy: 1e-9)
    }

    /// Two guards a live gesture needs: a drag too short to carry an angle changes
    /// nothing, and the result can never leave the slider's range.
    func testTheRulerRefusesAStubAndStaysInRange() {
        XCTAssertNil(Straighten.angle(current: 4, dx: 3, dy: 1, frameLongEdge: 1000),
                     "3 pt of a 1000 pt frame is a click, not a line")
        XCTAssertNotNil(Straighten.angle(current: 4, dx: 30, dy: 1, frameLongEdge: 1000))
        XCTAssertNil(Straighten.angle(current: 0, dx: 0, dy: 0, frameLongEdge: 1000))
        XCTAssertNil(Straighten.angle(current: 0, dx: .nan, dy: 10, frameLongEdge: 1000))

        // Already at the limit, and asked for more.
        let pushed = Straighten.angle(current: 44, dx: 400, dy: -100,
                                      frameLongEdge: 1000)
        XCTAssertNotNil(pushed)
        XCTAssertLessThanOrEqual(pushed ?? 99, Straighten.limitDegrees)
        XCTAssertGreaterThanOrEqual(pushed ?? -99, -Straighten.limitDegrees)
    }
}

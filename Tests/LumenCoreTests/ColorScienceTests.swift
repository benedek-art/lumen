// ColorScienceTests.swift
// Invariant tests for the colour foundation. These are not fixture comparisons —
// they assert the properties the rest of the engine is allowed to assume, which is
// what makes them useful when a refactor changes the numbers but must not change the
// physics.

import XCTest
@testable import LumenCore

final class ColorScienceTests: XCTestCase {

    // MARK: - Matrices

    func testSRGBMatrixMatchesPublishedValues() {
        // The published sRGB D65 RGB→XYZ matrix. Deriving it from chromaticities and
        // getting these numbers back is the check that the derivation is right.
        let expected = Mat3(0.4124, 0.3576, 0.1805,
                            0.2126, 0.7152, 0.0722,
                            0.0193, 0.1192, 0.9505)
        // 5e-5, not 1e-3: the published values are quoted to four decimals, so a
        // tolerance of 1e-3 is looser than the data it checks against. An error of 9e-4
        // in the 0.2126 luminance coefficient is a 0.4% luminance error, which shows as
        // a cast. The derivation from chromaticities lands within 3.9e-5.
        XCTAssertLessThan(RGBColorSpace.srgb.toXYZ.maxAbsDifference(expected), 5e-5)
    }

    func testRec2020LuminanceWeights() {
        let w = RGBColorSpace.rec2020.luminanceWeights
        // Same reasoning: derived from the chromaticities, these land within 2e-6 of
        // the published figures, so 1e-3 was three orders looser than the truth.
        XCTAssertEqual(w.r, 0.2627, accuracy: 1e-5)
        XCTAssertEqual(w.g, 0.6780, accuracy: 1e-5)
        XCTAssertEqual(w.b, 0.0593, accuracy: 1e-5)
        XCTAssertEqual(w.sum, 1.0, accuracy: 1e-9)
    }

    func testEverySpaceMapsWhiteToUnitLuminance() {
        for space in [RGBColorSpace.srgb, .rec2020, .displayP3, .adobeRGB, .proPhoto] {
            XCTAssertEqual(space.luminance(RGB.one), 1.0, accuracy: 1e-9, space.name)
        }
    }

    func testMatrixInverseRoundTrip() {
        let m = RGBColorSpace.rec2020.toXYZ
        let identity = m * m.inverse
        XCTAssertLessThan(identity.maxAbsDifference(.identity), 1e-12)
    }

    func testCrossSpaceConversionRoundTrip() {
        let toP3 = RGBColorSpace.rec2020.matrix(to: .displayP3)
        let back = RGBColorSpace.displayP3.matrix(to: .rec2020)
        for c in [RGB(0.2, 0.5, 0.9), RGB(1, 1, 1), RGB(0.03, 0.02, 0.01)] {
            let round = back.apply(toP3.apply(c))
            XCTAssertLessThan(round.maxAbsDifference(c), 1e-9)
        }
    }

    /// A round trip is satisfied by a pair of identity matrices, so on its own it says
    /// nothing about whether the conversion converts. These are the two things that
    /// distinguish a real gamut change from a no-op: white is the fixed point every
    /// same-white-point conversion must have, and a primary is what must move.
    func testCrossSpaceConversionActuallyConverts() {
        let toSRGB = RGBColorSpace.rec2020.matrix(to: .srgb)

        // Both spaces are D65, so white maps to white exactly.
        XCTAssertLessThan(toSRGB.apply(RGB.one).maxAbsDifference(RGB.one), 1e-9,
                          "white did not survive a same-white-point conversion")

        // Rec.2020 green is far outside sRGB — it lands at roughly
        // (−0.588, 1.133, −0.101), which is what "wider gamut" means numerically.
        // `testSoftProofFlagsOutOfGamutColours` already depends on this being true.
        let green = toSRGB.apply(RGB(0, 1, 0))
        XCTAssertLessThan(green.r, -0.3, "Rec.2020 green did not leave the sRGB gamut")
        XCTAssertGreaterThan(green.g, 1.05, "Rec.2020 green did not exceed sRGB green")
        XCTAssertLessThan(green.b, -0.05, "Rec.2020 green did not leave the sRGB gamut")
    }

    func testAdaptationToSameWhiteIsIdentity() {
        let m = ChromaticAdaptation.cat16(from: WhitePoint.d65, to: WhitePoint.d65)
        XCTAssertLessThan(m.maxAbsDifference(.identity), 1e-9)
    }

    func testAdaptationMovesWhiteExactly() {
        let m = ChromaticAdaptation.cat16(from: WhitePoint.d50, to: WhitePoint.d65)
        let moved = m.apply(WhitePoint.d50.xyz())
        XCTAssertLessThan(moved.maxAbsDifference(WhitePoint.d65.xyz()), 1e-9)
    }

    // MARK: - Transfer functions

    func testTransferFunctionRoundTrips() {
        for tf in TransferFunction.allCases {
            for i in 0...20 {
                let x = Double(i) / 20
                XCTAssertEqual(tf.decode(tf.encode(x)), x, accuracy: 1e-6,
                               "\(tf.rawValue) at \(x)")
            }
        }
    }

    /// A round trip is satisfied by an identity `encode`/`decode` pair, so every case
    /// but sRGB was anchored to nothing. These are external reference points, not
    /// numbers read back out of this implementation.
    func testEveryTransferFunctionHitsItsKnownPoints() {
        // Endpoints first: every curve in the set maps 0→0 and 1→1, except PQ, whose
        // floor is genuinely not zero — `(c1)^m2` is about 1e-6, which is the standard's
        // behaviour and not a bug.
        for tf in TransferFunction.allCases {
            // HLG gets its own bound, and only at white. Its white point is exact only
            // to the precision of BT.2100's published `a`: the standard gives
            // 0.17883277 to eight places, while the value that makes
            // a·ln(11+4a) − a·ln(4a) + 0.5 come to exactly 1 is 0.178832772656…, so
            // with the published constant OETF(1) = 1 − 4.93e-9. Reproduced to the last
            // bit outside this implementation, which is how it was established to be
            // the standard's rounding rather than an error here. 1e-9 was asking for
            // more precision than BT.2100 defines; every other curve still holds it.
            let whiteTolerance = tf == .hlg ? 1e-8 : 1e-9
            XCTAssertEqual(tf.encode(1), 1, accuracy: whiteTolerance,
                           "\(tf.rawValue) at white")
            XCTAssertEqual(tf.encode(0), 0, accuracy: 1e-5, "\(tf.rawValue) at black")
        }

        // Mid-grey through each display curve. The sRGB figure is the one every
        // photographer's intuition is built on; the rest are its siblings.
        XCTAssertEqual(TransferFunction.srgb.encode(0.18), 0.4613, accuracy: 1e-3)
        XCTAssertEqual(TransferFunction.rec709.encode(0.18), 0.4090, accuracy: 1e-3)
        XCTAssertEqual(TransferFunction.gamma22.encode(0.18), 0.4587, accuracy: 1e-3)
        XCTAssertEqual(TransferFunction.gamma18.encode(0.18), 0.3857, accuracy: 1e-3)
        XCTAssertEqual(TransferFunction.linear.encode(0.18), 0.18, accuracy: 1e-12)

        // HLG's toe meets its log segment at exactly 0.5 by construction — the
        // constants `a`, `b`, `c` are chosen for it, so this checks all three at once.
        XCTAssertEqual(TransferFunction.hlg.encode(1.0 / 12), 0.5, accuracy: 1e-9,
                       "HLG's toe/log junction is not at half the code range")

        // PQ is absolute: 1.0 linear is the standard's 10000 cd/m² peak, so 100 cd/m²
        // — SDR reference white — is 0.01 linear and lands near half the code range.
        XCTAssertEqual(TransferFunction.pq.encode(0.01), 0.5081, accuracy: 1e-3,
                       "PQ did not put 100 nits at its usual code value")

        // The two HDR curves spend far more code range on the deep shadows than the SDR
        // ones do, which is the property that makes them worth the trouble. At 0.001
        // linear, sRGB gives 0.0129 while HLG gives 0.0548 (4.2×) and PQ 0.2997 (23×).
        let deepSRGB = TransferFunction.srgb.encode(0.001)
        XCTAssertGreaterThan(TransferFunction.pq.encode(0.001), deepSRGB * 10)
        XCTAssertGreaterThan(TransferFunction.hlg.encode(0.001), deepSRGB * 3)
    }

    func testSRGBKnownPoints() {
        XCTAssertEqual(TransferFunction.srgb.encode(0), 0, accuracy: 1e-9)
        XCTAssertEqual(TransferFunction.srgb.encode(1), 1, accuracy: 1e-9)
        // 18% grey encodes near the middle of the code range — the fact every
        // photographer's intuition is built on.
        XCTAssertEqual(TransferFunction.srgb.encode(0.18), 0.4613, accuracy: 1e-3)
    }

    // MARK: - Colour temperature

    func testLocusIsMonotoneInX() {
        // Cooler light sits lower in x. A non-monotone locus would make the slider
        // reverse direction somewhere in the middle, which is a very confusing bug.
        var previous = Double.infinity
        var kelvin = 2000.0
        while kelvin <= 25000 {
            let x = ColorTemperature.locus(kelvin: kelvin).x
            XCTAssertLessThan(x, previous + 1e-6, "locus reversed at \(kelvin) K")
            previous = x
            kelvin += 250
        }
    }

    /// The locus, against published chromaticities rather than against itself.
    ///
    /// Everything else here is an inverse pair — `chromaticity` then
    /// `temperatureAndTint` — which a locus that is entirely wrong round-trips through
    /// perfectly. These are the only assertions in the suite that say where the white
    /// balance slider's 5000 K and 6500 K actually are, and getting them wrong is a
    /// visible cast on every photo.
    func testTheLocusPassesThroughTheStandardIlluminants() {
        // D65: the sRGB / Rec.2020 white point, and where the Temp slider's neutral
        // sits. Derived here from the daylight locus, so this is a real cross-check.
        let d65 = ColorTemperature.locus(kelvin: 6500)
        XCTAssertEqual(d65.x, 0.3127, accuracy: 1e-3, "6500 K is not at D65")
        XCTAssertEqual(d65.y, 0.3290, accuracy: 1e-3, "6500 K is not at D65")

        // D50: the ICC profile connection space's white, and what a print viewing
        // booth is built around.
        let d50 = ColorTemperature.locus(kelvin: 5000)
        XCTAssertEqual(d50.x, 0.34567, accuracy: 1e-3, "5000 K is not at D50")
        XCTAssertEqual(d50.y, 0.35850, accuracy: 1e-3, "5000 K is not at D50")
    }

    func testTemperatureRoundTrip() {
        for kelvin in [2500.0, 3200, 5000, 5500, 6500, 9000, 15000] {
            for tint in [-80.0, 0, 60] {
                let chroma = ColorTemperature.chromaticity(kelvin: kelvin, tint: tint)
                let back = ColorTemperature.temperatureAndTint(for: chroma)
                XCTAssertEqual(back.kelvin, kelvin, accuracy: kelvin * 0.03,
                               "K round trip at \(kelvin)/\(tint)")
                XCTAssertEqual(back.tint, tint, accuracy: 8,
                               "tint round trip at \(kelvin)/\(tint)")
            }
        }
    }

    // MARK: - Perceptual

    func testOKLabRoundTrip() {
        let ctx = OKLabTransform.working
        for c in [RGB(0.18, 0.18, 0.18), RGB(0.8, 0.2, 0.1), RGB(0.05, 0.3, 0.7),
                  RGB(1.4, 0.9, 0.2)] {
            let back = ctx.toRGB(ctx.toLab(c))
            XCTAssertLessThan(back.maxAbsDifference(c), 1e-8, "\(c)")
        }
    }

    func testNeutralHasZeroChroma() {
        let lch = OKLabTransform.working.toLCh(RGB(gray: 0.42))
        XCTAssertLessThan(lch.C, 1e-6)
    }

    func testUCSRoundTrip() {
        for c in [RGB(0.2, 0.4, 0.6), RGB(0.9, 0.1, 0.05), RGB(gray: 0.5)] {
            let back = LumenUCS.toRGB(LumenUCS.fromRGB(c))
            XCTAssertLessThan(back.maxAbsDifference(c), 1e-7, "\(c)")
        }
    }

    func testHKFactorIsUnityForNeutrals() {
        XCTAssertEqual(HelmholtzKohlrausch.brightnessFactor(chroma: 0, hue: 0), 1,
                       accuracy: 1e-12)
        XCTAssertEqual(HelmholtzKohlrausch.brightnessFactor(chroma: 0, hue: 210), 1,
                       accuracy: 1e-12)
    }

    /// The invariant docs/14 §5.4 makes every colour kernel promise: a chroma move
    /// holds perceived brightness. This is what naive HSL cannot do.
    func testChromaMovePreservesPerceivedBrightness() {
        for c in [RGB(0.5, 0.2, 0.1), RGB(0.1, 0.4, 0.7), RGB(0.6, 0.6, 0.15)] {
            let before = LumenUCS.fromRGB(c)
            let scaled = LumenUCS.scaleChroma(c, by: 1.6)
            let after = LumenUCS.fromRGB(scaled)
            XCTAssertEqual(after.J, before.J, accuracy: 1e-6, "\(c)")
            XCTAssertEqual(after.h, before.h, accuracy: 1e-4, "\(c)")
            XCTAssertGreaterThan(after.C, before.C)
        }
    }

    /// And the converse: a luminance move keeps the chroma ratio, so the LR
    /// "luminance slider desaturates" artefact cannot occur.
    func testBrightnessMovePreservesHue() {
        for c in [RGB(0.5, 0.2, 0.1), RGB(0.1, 0.4, 0.7)] {
            let before = LumenUCS.fromRGB(c)
            let after = LumenUCS.fromRGB(LumenUCS.scaleBrightness(c, by: 1.3))
            XCTAssertEqual(after.h, before.h, accuracy: 1e-3, "\(c)")
            XCTAssertGreaterThan(after.J, before.J)
        }
    }

    // MARK: - Gamut

    func testInGamutColoursAreUntouchedBySoftClip() {
        let boundary = Gamut.Boundary(hueSteps: 24, lightnessSteps: 9)
        for c in [RGB(0.3, 0.3, 0.32), RGB(0.5, 0.48, 0.45)] {
            let out = Gamut.softClip(c, boundary: boundary)
            XCTAssertLessThan(out.maxAbsDifference(c), 1e-6, "\(c)")
        }
    }

    func testSoftClipReducesExcessChroma() {
        let boundary = Gamut.Boundary(hueSteps: 24, lightnessSteps: 9)
        let ctx = OKLabTransform.working
        // A colour well outside the working gamut at its lightness.
        let wild = ctx.toRGB(OKLCh(L: 0.5, C: 0.45, h: 30))
        let clipped = Gamut.softClip(wild, boundary: boundary)
        let before = ctx.toLCh(wild)
        let after = ctx.toLCh(clipped)
        XCTAssertLessThan(after.C, before.C)
        XCTAssertEqual(after.h, before.h, accuracy: 1e-3)
        XCTAssertEqual(after.L, before.L, accuracy: 1e-3)
    }

    // MARK: - Shaper and LUTs

    func testLogEncodeRoundTrip() {
        for x in [0.0, 1e-5, 0.001, 0.18, 1.0, 12.0, 400.0] {
            let round = LumenLog.decode(LumenLog.encode(x))
            XCTAssertEqual(round, x, accuracy: Swift.max(abs(x) * 1e-6, 1e-9), "\(x)")
        }
    }

    func testLogEncodeIsMonotoneAndBounded() {
        var previous = -Double.infinity
        var x = 0.0
        while x < 500 {
            let y = LumenLog.encode(x)
            XCTAssertGreaterThan(y, previous - 1e-12)
            previous = y
            x = x < 1e-4 ? x + 1e-5 : x * 1.1
        }
        XCTAssertEqual(LumenLog.encode(0.18), 0.5, accuracy: 1e-9)
        // Zero must land just inside the domain, not below it: everything under the
        // crossover would otherwise be clamped to index 0 by the cube stages.
        XCTAssertGreaterThan(LumenLog.encode(0), 0)
        XCTAssertLessThan(LumenLog.encode(0), 0.01)
        // And the toe must MEET the log branch — no step at the crossover.
        let cut = LumenLog.linearCut
        XCTAssertEqual(LumenLog.encode(cut * (1 - 1e-9)), LumenLog.encode(cut),
                       accuracy: 1e-6, "the shaper is discontinuous at its crossover")
    }

    func testLUT1DEvaluatesAndBakes() {
        let lut = LUT1D(size: 256) { $0 * $0 }
        XCTAssertEqual(lut.evaluate(0.5), 0.25, accuracy: 1e-4)
        XCTAssertEqual(lut.evaluate(0), 0, accuracy: 1e-12)
        XCTAssertEqual(lut.evaluate(1), 1, accuracy: 1e-12)
        XCTAssertFalse(lut.isIdentity())
        XCTAssertTrue(LUT1D(size: 64) { $0 }.isIdentity())
    }

    func testLUT3DIdentitySamplesExactly() {
        let lut = LUT3D.identity(size: 17)
        for c in [RGB(0.1, 0.5, 0.9), RGB(0, 0, 0), RGB(1, 1, 1), RGB(0.33, 0.66, 0.5)] {
            XCTAssertLessThan(lut.sample(c).maxAbsDifference(c), 1e-6, "\(c)")
        }
    }

    func testLUT3DCubeFileRoundTrip() {
        let lut = LUT3D(size: 5) { RGB($0.g, $0.b, $0.r) }
        let text = lut.cubeFileContents(title: "swap")
        guard let parsed = LUT3D.fromCubeFile(text) else {
            return XCTFail("cube file did not parse")
        }
        XCTAssertEqual(parsed.size, 5)
        XCTAssertLessThan(parsed.maxAbsDifference(lut), 1e-5)
    }

    func testMalformedCubeFileIsRejected() {
        XCTAssertNil(LUT3D.fromCubeFile("LUT_3D_SIZE 4\n0.1 0.2\n"))
        XCTAssertNil(LUT3D.fromCubeFile("not a lut at all"))
    }

    // MARK: - Numeric helpers

    func testSignedPowerPreservesSign() {
        XCTAssertEqual(Num.spow(-0.25, 0.5), -0.5, accuracy: 1e-12)
        XCTAssertEqual(Num.spow(0.25, 0.5), 0.5, accuracy: 1e-12)
    }

    func testAnchorInterpolationClampsAtEnds() {
        let anchors: [(x: Double, y: Double)] = [(100, 0), (800, 10), (6400, 40)]
        XCTAssertEqual(Num.interpolateAnchors(anchors, at: 50), 0, accuracy: 1e-12)
        XCTAssertEqual(Num.interpolateAnchors(anchors, at: 100_000), 40, accuracy: 1e-12)
        XCTAssertEqual(Num.interpolateAnchors(anchors, at: 450), 5, accuracy: 1e-9)
    }

    func testHueDeltaTakesTheShortWay() {
        XCTAssertEqual(Num.hueDelta(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(Num.hueDelta(10, 350), -20, accuracy: 1e-9)
    }
    // MARK: - The skin line must actually be on skin

    /// sRGB swatches spanning the range of human skin, as 0–255 triples.
    private static let skinSwatches: [(name: String, rgb: (Int, Int, Int))] = [
        ("very light", (247, 214, 193)),
        ("light",      (233, 190, 164)),
        ("medium",     (209, 163, 127)),
        ("tan",        (172, 130,  92)),
        ("brown",      (140, 100,  70)),
        ("dark",       ( 95,  65,  47)),
        ("Macbeth light skin", (200, 148, 127)),
    ]

    private func working(_ rgb8: (Int, Int, Int)) -> RGB {
        let encoded = RGB(Double(rgb8.0) / 255, Double(rgb8.1) / 255, Double(rgb8.2) / 255)
        let linear = TransferFunction.srgb.decode(encoded)
        return RGBColorSpace.srgb.matrix(to: .rec2020).apply(linear)
    }

    /// The property `skinLineDegrees` exists to deliver, pinned instead of its value —
    /// so re-deriving the constant later is checked against what it is FOR.
    ///
    /// At the old 33° every one of these scored zero: the constant was the I-bar
    /// measured from +b while both consumers read it from +a. `Protect Skin` therefore
    /// attenuated reds and left faces at full strength, which is the exact inverse of
    /// what the control says it does — and it is on by default at 70.
    func testSkinWeightActuallyScoresSkin() {
        for (name, rgb8) in Self.skinSwatches {
            let weight = ColorEngine.skinWeight(working(rgb8))
            // 0.2 rather than something higher because the Macbeth light-skin patch
            // sits at ~43°, which is outside the nominal ±10° half-width and scores
            // ~0.23 in the band's rolloff. That is a fact about the band WIDTH, not the
            // line — the other six swatches score 0.51 to 1.0 — and widening the band
            // to flatter this test would be tuning the instrument to the measurement.
            XCTAssertGreaterThan(weight, 0.2,
                                 "\(name) skin scored \(weight) on the skin line — "
                                     + "Protect Skin would not protect it")
        }
    }

    /// The discrimination, which is the part that actually matters and which no single
    /// threshold captures: every skin tone must outscore every saturated red by a clear
    /// margin. At the old constant this was inverted — brick scored 1.000 and every
    /// skin tone scored 0.000.
    func testEverySkinToneOutscoresEverySaturatedRed() {
        let reds = [("pure red", (255, 0, 0)), ("fire engine", (206, 32, 41)),
                    ("brick", (178, 74, 56))]
        for (skinName, skinRGB) in Self.skinSwatches {
            let skin = ColorEngine.skinWeight(working(skinRGB))
            for (redName, redRGB) in reds {
                let red = ColorEngine.skinWeight(working(redRGB))
                XCTAssertGreaterThan(skin, red + 0.15,
                                     "\(skinName) scored \(skin) but \(redName) "
                                         + "scored \(red) — the skin line is not on skin")
            }
        }
    }

    /// The other half of the contract: saturated reds and oranges are not skin. Without
    /// this, moving the line to satisfy the test above could be done by widening the
    /// band until it covers everything.
    func testSkinWeightRejectsSaturatedReds() {
        for (name, rgb8) in [("pure red", (255, 0, 0)),
                             ("fire engine", (206, 32, 41)),
                             ("brick", (178, 74, 56))] {
            let weight = ColorEngine.skinWeight(working(rgb8))
            XCTAssertLessThan(weight, 0.2,
                              "\(name) scored \(weight) as skin")
        }
    }

    /// A neutral has no hue to be on any line, whatever the line is.
    func testSkinWeightIgnoresNeutrals() {
        for grey in [0.05, 0.18, 0.5, 0.9] {
            XCTAssertEqual(ColorEngine.skinWeight(RGB(gray: grey)), 0, accuracy: 1e-9)
        }
    }

}

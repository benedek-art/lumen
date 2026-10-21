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
    /// perfectly. These are the assertions that say where the white balance slider's
    /// 5000 K and 6500 K actually are.
    ///
    /// Rewritten for WS-03: Temp/Tint are the Adobe/DNG pair now, so tint 0 is the
    /// BLACKBODY line (checked against Kim's independent Planckian fit) and the
    /// D-illuminants sit at their Adobe pairs, about +10 tint above it — D65 is
    /// 6503.7 / +9.77 and D50 5000.7 / +9.56. The old form put D65 at 6500 / 0, which
    /// was Lumen's private locus convention, not the one the camera's as-shot pair
    /// and Lightroom's numbers are in (AUDIT.md finding 1).
    func testTheLocusPassesThroughTheStandardIlluminants() {
        let d65 = ColorTemperature.chromaticity(kelvin: 6503.70718479529, tint: 9.769990121404899)
        XCTAssertEqual(d65.x, 0.3127, accuracy: 1e-5, "6504 K / +9.77 is not at D65")
        XCTAssertEqual(d65.y, 0.3290, accuracy: 1e-5, "6504 K / +9.77 is not at D65")

        let d50 = ColorTemperature.chromaticity(kelvin: 5000.706605070579, tint: 9.562965495510433)
        XCTAssertEqual(d50.x, 0.3457, accuracy: 1e-4, "5001 K / +9.56 is not at D50")
        XCTAssertEqual(d50.y, 0.3585, accuracy: 1e-4, "5001 K / +9.56 is not at D50")

        // Tint 0 is the blackbody: within 1e-3 of an independent Planckian fit.
        for kelvin in [2000.0, 2856, 3200, 4000, 5000, 6500, 10000] {
            let robertson = ColorTemperature.locus(kelvin: kelvin)
            let kim = ColorTemperature.planckianLocus(kelvin)
            XCTAssertEqual(robertson.x, kim.x, accuracy: 1e-3, "\(kelvin) K off the blackbody")
            XCTAssertEqual(robertson.y, kim.y, accuracy: 1e-3, "\(kelvin) K off the blackbody")
        }
    }

    /// The round trip is against the tint the RENDER USES, not the tint that was asked
    /// for — which is what `temperatureAndTint` documents itself as returning: "a
    /// colour sampled from beyond that bound reports the tint the render would actually
    /// use rather than one it would silently pull in."
    ///
    /// It used to compare against the asked-for value and passed only by luck. Every
    /// sampled pair was inside the bound except 2500 K / +60, where the bound was
    /// +56.80 and the ±8 tolerance swallowed the 3.2 of clamping. When the magenta
    /// bound tightened to +30.00 at 2500 K — see `ColorTemperature.magentaMonotoneLimit`
    /// — the same lucky pass became a 30-unit failure, and the test was measuring the
    /// bound rather than the round trip the whole time. Asking `clampedTint` what the
    /// render will do makes it measure the round trip at every pair, INCLUDING the
    /// clamped ones, which is strictly more than it checked before.
    func testTemperatureRoundTrip() {
        for kelvin in [2500.0, 3200, 5000, 5500, 6500, 9000, 15000] {
            for tint in [-80.0, 0, 60] {
                let chroma = ColorTemperature.chromaticity(kelvin: kelvin, tint: tint)
                let back = ColorTemperature.temperatureAndTint(for: chroma)
                let rendered = ColorTemperature.clampedTint(kelvin: kelvin, tint: tint)
                XCTAssertEqual(back.kelvin, kelvin, accuracy: kelvin * 0.03,
                               "K round trip at \(kelvin)/\(tint)")
                XCTAssertEqual(back.tint, rendered, accuracy: 8,
                               "tint round trip at \(kelvin)/\(tint), which renders as \(rendered)")
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

    /// Nayatani's q(θ) (Color Res. Appl. 22(6), 1997; colour-science's
    /// `coefficient_q_Nayatani1997`) is nine published coefficients. The cos 3θ term had
    /// been transcribed as −0.04256 instead of −0.02667, in the reference and in both
    /// copies the exact colour stage carries (its Float twin and the kernel prelude).
    /// At θ = 0 every sine vanishes and q is the sum of the cosine terms, −0.12120; at
    /// θ = 60° cos 3θ = −1 and the sine series is live, so the published value there pins
    /// the corrected term alongside the sines; θ = 90°, where cos 3θ vanishes, must not
    /// move (0.19168). The twin and the kernel string must say the same.
    func testNayataniQCarriesThePublishedCoefficients() {
        XCTAssertEqual(HelmholtzKohlrausch.q(hueDegrees: 0), -0.12120, accuracy: 1e-9)
        XCTAssertEqual(HelmholtzKohlrausch.q(hueDegrees: 90), 0.19168, accuracy: 1e-9)
        XCTAssertEqual(HelmholtzKohlrausch.q(hueDegrees: 60),
                       -0.01585 - 0.03017 * 0.5 + 0.04556 * 0.5 + 0.02667 - 0.00295 * -0.5
                           + (0.14592 + 0.05084 - 0.00764 * -1) * 3.0.squareRoot() / 2,
                       accuracy: 1e-9)
        for hue in stride(from: 0.0, to: 360.0, by: 7.5) {
            let reference = HelmholtzKohlrausch.brightnessFactor(chroma: 0.3, hue: hue)
            let twin = ExactColorTwin.hkFactor(0.3, Float(hue),
                                               Float(HelmholtzKohlrausch.kBr))
            XCTAssertEqual(Double(twin), reference, accuracy: 1e-6, "hue \(hue)")
        }
        XCTAssertTrue(ExactColorKernelSource.prelude.contains("- 0.02667 * cos(3.0 * t)"),
                      "the kernel's lumenHK must carry the published cos 3θ coefficient")
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

    // MARK: - Protect Skin, where it is applied rather than where it is scored

    /// A colour on the skin line at full skin weight, so `protection` is exactly
    /// `1 − protectSkin/100` and the arithmetic under test is not diluted by the score.
    /// L 0.6, C 0.065 rather than C 0.10 (WS-16): C/L 0.108 is a colour real skin has,
    /// and full weight for both `skinWeight` and Protect Skin's own band. At C/L 0.18
    /// the old probe was as colourful as ColorChecker orange, which Protect Skin now
    /// deliberately leaves unprotected (SPEC SKIN-3).
    private func skinLineColour(L: Double = 0.6, C: Double = 0.065) -> RGB {
        OKLabTransform.working.toRGB(
            OKLCh(L: L, C: C, h: ColorEngine.skinLineDegrees))
    }

    /// The same chroma and lightness, well off the skin line: the control colour that
    /// makes "skin was spared" mean something rather than "nothing happened".
    private func offLineColour(L: Double = 0.6, C: Double = 0.065) -> RGB {
        OKLabTransform.working.toRGB(
            OKLCh(L: L, C: C, h: ColorEngine.skinLineDegrees + 180))
    }

    private func chroma(_ c: RGB) -> Double { LumenUCS.fromRGB(c).C }

    private func engine(_ adjust: ColorAdjust) -> ColorEngine {
        ColorEngine(mixer: Mixer(), pointColors: [], color: adjust,
                    primaries: Primaries(), bw: nil)
    }

    /// Saturation −100 reaches true black and white, ON SKIN, at the shipped default.
    ///
    /// `protection` multiplied the negative saturation amount as well as the positive
    /// one, so at the default Protect Skin of 70 a full desaturation left every
    /// skin-hued pixel at 30% of its chroma: a face still in colour inside a frame the
    /// photographer had taken to black and white. The wire format says "−100 reaches
    /// true B&W", the engine's own comment said it, and neither was true.
    func testSaturationMinus100ReachesTrueBlackAndWhiteOnSkin() {
        var adjust = ColorAdjust()          // density 50, protectSkin 70 — the defaults
        adjust.saturation = -100
        let e = engine(adjust)

        for (name, rgb8) in Self.skinSwatches {
            let input = working(rgb8)
            XCTAssertGreaterThan(ColorEngine.skinWeight(input), 0.2,
                                 "INVALID PROBE: \(name) does not score as skin")
            XCTAssertLessThan(chroma(e.apply(input)), 1e-9,
                              "\(name) kept \(chroma(e.apply(input))) of chroma at "
                                  + "Saturation −100 — Protect Skin blocked the pull")
        }

        // Including the worst case the score can produce: full weight, full protection.
        var full = ColorAdjust(protectSkin: 100)
        full.saturation = -100
        let onLine = skinLineColour()
        XCTAssertEqual(ColorEngine.skinWeight(onLine), 1, accuracy: 1e-9,
                       "INVALID PROBE: the probe colour is not at full skin weight")
        XCTAssertLessThan(chroma(engine(full).apply(onLine)), 1e-9,
                          "Protect Skin at 100 held colour in a black-and-white frame")
    }

    /// What Saturation −100 holds is H-K perceived brightness, not luminance.
    ///
    /// The engine comment on the negative branch said "exactly luminance-preserving".
    /// It never was: the walk runs in Lumen UCS and holds J = OKLab L · f_HK, so at
    /// C = 0 (f_HK = 1) the grey's OKLab L equals the input's J. That is the D21 design
    /// and it is pinned here as the contract, so the comment and the code cannot drift
    /// apart again. The second half documents the consequence instead of hiding it:
    /// on a saturated blue the −100 grey sits well above the Rec.2020 luminance that the
    /// Black & White panel mixes by, so the two "monochromes" are different greys. The
    /// bound is loose on purpose (0.25 EV against a measured ≈0.42): OKLab L³ alone
    /// already exceeds Y for blue, so an H-K recalibration cannot flip it.
    func testSaturationMinus100HoldsHKBrightnessNotLuminance() {
        var adjust = ColorAdjust()
        adjust.saturation = -100
        let e = engine(adjust)
        let lumaWeights = RGBColorSpace.rec2020.luminanceWeights

        let probes: [(String, (Int, Int, Int))] = [
            ("sRGB blue", (0, 0, 255)), ("sRGB red", (255, 0, 0)),
            ("sRGB green", (0, 255, 0)), ("sky", (124, 160, 231)),
        ]
        for (name, rgb8) in probes {
            let input = working(rgb8)
            let out = e.apply(input)
            XCTAssertLessThan(chroma(out), 1e-9, "\(name): −100 is not neutral")
            let jIn = LumenUCS.fromRGB(input).J
            let lOut = OKLabTransform.working.toLCh(out).L
            XCTAssertEqual(lOut, jIn, accuracy: 1e-9,
                           "\(name): the −100 grey's OKLab L \(lOut) is not the input's "
                               + "H-K brightness J \(jIn) — Saturation stopped holding J")
        }

        let blue = working((0, 0, 255))
        let yIn = lumaWeights.r * blue.r + lumaWeights.g * blue.g + lumaWeights.b * blue.b
        let grey = e.apply(blue)
        let yOut = lumaWeights.r * grey.r + lumaWeights.g * grey.g + lumaWeights.b * grey.b
        XCTAssertGreaterThan(log2(yOut / yIn), 0.25,
                             "Saturation −100 on blue now lands at its luminance "
                                 + "(\(log2(yOut / yIn)) EV) — if that is a design change, "
                                 + "the engine comment and docs/24 §3 must say so")
    }

    /// The other half, and the half that had no test at all: the attenuation itself.
    ///
    /// Both fixture tests zero `protectSkin`, so deleting `* protection` from the engine
    /// left the whole suite green — the same shape as the 33° skin-line constant that
    /// shipped wrong for months behind passing tests. This drives the multiplication on
    /// both sliders and in both directions.
    func testProtectSkinAttenuatesTheMovesItSaysItDoes() {
        let onLine = skinLineColour()
        let offLine = offLineColour()
        XCTAssertEqual(ColorEngine.skinWeight(onLine), 1, accuracy: 1e-9,
                       "INVALID PROBE: on-line colour is not at full skin weight")
        XCTAssertEqual(ColorEngine.skinWeight(offLine), 0, accuracy: 1e-9,
                       "INVALID PROBE: the control colour scores as skin")

        // Saturation, pushing. Protection 100 leaves skin exactly alone; protection 0
        // pushes it as hard as anything else.
        var pushed = ColorAdjust(protectSkin: 0)
        pushed.saturation = 100
        var protected = ColorAdjust(protectSkin: 100)
        protected.saturation = 100
        XCTAssertGreaterThan(chroma(engine(pushed).apply(onLine)), chroma(onLine) * 1.1,
                             "Saturation +100 did not push an unprotected skin tone")
        XCTAssertEqual(chroma(engine(protected).apply(onLine)), chroma(onLine),
                       accuracy: chroma(onLine) * 1e-9,
                       "Protect Skin at 100 did not spare skin from a Saturation push")
        XCTAssertGreaterThan(chroma(engine(protected).apply(offLine)),
                             chroma(offLine) * 1.1,
                             "Protect Skin at 100 attenuated a colour that is not skin")

        // Vibrance is protected on the PUSH. It used to be protected at both signs, and
        // at Vibrance −100 that left the skin hues in colour while every other hue was
        // muted — a colour-splash wedge (WS-16 VIB-7). A pull is now the same uniform
        // mute on skin as on anything else, so Protect Skin must not change it.
        var vibrance = ColorAdjust(protectSkin: 100)
        vibrance.vibrance = 100
        XCTAssertEqual(chroma(engine(vibrance).apply(onLine)), chroma(onLine),
                       accuracy: chroma(onLine) * 1e-9,
                       "Protect Skin at 100 did not spare skin from Vibrance +100")
        var unprotected = ColorAdjust(protectSkin: 0)
        unprotected.vibrance = 100
        XCTAssertNotEqual(chroma(engine(unprotected).apply(onLine)), chroma(onLine),
                          accuracy: chroma(onLine) * 1e-3,
                          "INVALID PROBE: Vibrance +100 does nothing here even "
                              + "unprotected, so protection cannot be measured")
        var pullProtected = ColorAdjust(protectSkin: 100)
        pullProtected.vibrance = -100
        var pullUnprotected = ColorAdjust(protectSkin: 0)
        pullUnprotected.vibrance = -100
        XCTAssertLessThan(chroma(engine(pullProtected).apply(onLine)), chroma(onLine) * 0.9,
                          "Vibrance −100 did not mute skin")
        XCTAssertEqual(chroma(engine(pullProtected).apply(onLine)),
                       chroma(engine(pullUnprotected).apply(onLine)),
                       accuracy: chroma(onLine) * 1e-12,
                       "Protect Skin changed a Vibrance pull: the skin hues would stay "
                           + "coloured inside a muted frame")

        // And the default is a partial attenuation, not a switch: 70 spares 70% of the
        // push on a full-weight skin tone rather than all or none of it.
        var half = ColorAdjust(protectSkin: 70)
        half.saturation = 100
        let none = chroma(engine(pushed).apply(onLine)) - chroma(onLine)
        let some = chroma(engine(half).apply(onLine)) - chroma(onLine)
        XCTAssertGreaterThan(some, 0, "Protect Skin 70 blocked the push entirely")
        XCTAssertLessThan(some, none * 0.6,
                          "Protect Skin 70 barely attenuated the push: \(some) of \(none)")
    }

    // MARK: - Density

    /// Density is inert wherever Saturation is not pushing, and the recipe says so.
    ///
    /// The subtractive branch is a per-channel gamma above 1 — it densifies a colour as
    /// it intensifies — and there is nothing to blend on the way down, so `ColorEngine`
    /// guards it on `satAmount > 0`. That guard is right. What was wrong is that nothing
    /// said so: the panel drew a live bipolar dial across half of Saturation's range
    /// where it did exactly nothing.
    ///
    /// This test is what stops `ColorAdjust.densityIsLive` — the predicate the panel now
    /// disables the row on — from drifting away from the engine's own guard, in either
    /// direction: it fails if the flag claims a live dial that moves nothing, and it
    /// fails if the flag claims a dead one that does.
    func testDensityIsLiveExactlyWhereItChangesThePicture() {
        // Ordinary saturated colours at ordinary brightness, none of them on the skin
        // line, so neither the rolloff nor the protection can stand in for the guard.
        let probes = [RGB(0.30, 0.10, 0.08), RGB(0.08, 0.22, 0.30),
                      RGB(0.12, 0.28, 0.09), RGB(0.26, 0.09, 0.28)]

        for saturation in [-100.0, -50.0, -1.0, 0.0, 1.0, 25.0, 100.0] {
            let low = engine(ColorAdjust(saturation: saturation,
                                         density: 0, protectSkin: 0))
            let high = engine(ColorAdjust(saturation: saturation,
                                          density: 100, protectSkin: 0))
            let moved = probes.contains {
                low.apply($0).maxAbsDifference(high.apply($0)) > 1e-9
            }
            let claimed = ColorAdjust(saturation: saturation).densityIsLive
            XCTAssertEqual(moved, claimed,
                           "at Saturation \(saturation) the Density dial "
                               + (moved ? "moves" : "does not move")
                               + " the picture but the panel is told it is "
                               + (claimed ? "live" : "dead"))
        }
    }

    // MARK: - The advanced grading grid (D15)
    //
    // `ColorBalanceGrid` was written, tested for its own arithmetic, and referenced by
    // nothing: no wire format, no panel, no stage. These tests are the ones that can
    // fail if the wiring is removed again — they assert that the grid reaches a pixel
    // through the stage the renderer actually bakes, not that its algebra is correct.

    private func grade(_ mutate: (inout ColorBalanceParams) -> Void) -> GradeEngine {
        var wheels = GradingWheels()
        mutate(&wheels.colorBalance)
        return GradeEngine(wheels: wheels, printerLights: PrinterLights())
    }

    func testColorBalanceGridReachesPixelsThroughTheGrade() {
        let colour = RGB(0.30, 0.14, 0.10)

        let flat = GradeEngine(wheels: GradingWheels(), printerLights: PrinterLights())
        XCTAssertTrue(flat.isIdentity)
        XCTAssertEqual(flat.apply(colour).maxAbsDifference(colour), 0, accuracy: 0,
                       "an untouched grade is not a bit-exact no-op")

        let pushed = grade { $0.chroma.global = 60 }
        XCTAssertFalse(pushed.isIdentity,
                       "a grade whose only move is the grid declared itself identity — "
                           + "RenderPlan would swap a two-point identity cube in for it")
        XCTAssertGreaterThan(pushed.apply(colour).maxAbsDifference(colour), 1e-3,
                             "the grid did not reach the pixel")
    }

    /// Through `RenderPlan`, which is what the shipping path actually evaluates: the
    /// baked S10 table and the exact reference must both carry the grid.
    func testColorBalanceGridSurvivesTheBake() {
        var recipe = Recipe()
        recipe.look.wheels.colorBalance.brilliance.global = 35
        let plan = RenderPlan(recipe: recipe)
        XCTAssertFalse(plan.gradeIsIdentity,
                       "the grade table was swapped for an identity cube")

        let scene = RGB(0.22, 0.12, 0.30)
        let base = RenderPlan(recipe: Recipe())
        XCTAssertGreaterThan(plan.exactColor(scene).maxAbsDifference(base.exactColor(scene)),
                             1e-3, "the exact path ignores the grid")
        XCTAssertGreaterThan(
            plan.referenceColor(scene).maxAbsDifference(base.referenceColor(scene)),
            1e-3, "the baked table ignores the grid")
    }

    /// `referenceColor` and `exactColor` are twins, and both take the space the plan
    /// was built with. referenceColor hardcoded rec2020 for the tone stage's
    /// luminance while its twin used the parameter (docs/23 audit queue item 9), so
    /// on a plan built for another working space the two disagreed about how bright
    /// a saturated colour is BEFORE either table was sampled — a real divergence
    /// silently charged to "interpolation error" in every golden comparing them.
    ///
    /// Exact, not tolerance-bounded: with an identity colour/grade stack,
    /// referenceColor IS finishedColor over the tone-gained linear value, so the
    /// expectation reproduces its own code path and the only degree of freedom is
    /// which space weighed the luminance.
    func testReferenceColorWeighsLuminanceInTheSpaceItIsAskedAbout() {
        var recipe = Recipe()
        recipe.develop.tone.shadows = 80
        let plan = RenderPlan(recipe: recipe, space: .displayP3)
        // Blue: the weight rec2020 and P3 disagree on most (0.0593 vs 0.0793 —
        // 0.42 EV apart on a pure-blue pixel), deep in the shadows where +80
        // Shadows makes the gain steep.
        let scene = RGB(0.01, 0.01, 0.5)

        let c = plan.linear.apply(scene)
        let lum = Swift.max(RGBColorSpace.displayP3.luminance(c), 0)
        let expected = plan.finishedColor(encoded: LumenLog.encode(
            c * plan.tone.gain(at: Num.safeLog2(lum / 0.18))))

        let got = plan.referenceColor(scene, space: .displayP3)
        XCTAssertEqual(got.maxAbsDifference(expected), 0, accuracy: 1e-12,
                       "the tone stage weighed luminance in a different space "
                           + "than the one it was asked about")

        // And the default stays the default: no space argument means rec2020,
        // bit-for-bit, so every existing golden keeps measuring what it measured.
        XCTAssertEqual(plan.referenceColor(scene)
                        .maxAbsDifference(plan.referenceColor(scene, space: .rec2020)),
                       0)
    }

    /// The grid grades ZONES, and the zones are the ones the strip above the wheels
    /// draws. A shadow-only push must leave a highlight alone.
    func testGridAxesAreZoneSelective() {
        // Placed by tonal position, not by eye: the default pivots sit at 0.33/0.67 on
        // a −9…+5 EV axis, so these land squarely inside the shadow and highlight
        // windows rather than in a crossfade.
        let shadow = RGB(0.0016, 0.0014, 0.0019)     // ≈ −6.9 EV
        let highlight = RGB(1.40, 1.30, 1.50)        // ≈ +2.9 EV
        let engine = grade { $0.brilliance.shadows = 60 }

        func relativeMove(_ c: RGB) -> Double {
            engine.apply(c).maxAbsDifference(c) / Swift.max(c.maxComponent, 1e-9)
        }
        XCTAssertGreaterThan(relativeMove(shadow), 0.1, "the shadow zone was not graded")
        XCTAssertLessThan(relativeMove(highlight), 1e-6,
                          "a shadow-only Brilliance push reached the highlights")
    }

    /// Three intents, not three volumes of one. A naive HSL model collapses chroma,
    /// saturation and brilliance into a single chroma multiply; this is the test that
    /// the H-K solves in `ColorBalanceGrid` are still doing their separate jobs.
    func testChromaSaturationAndBrillianceAreThreeDifferentMoves() {
        // A saturated red rather than a muted one: chroma and saturation differ by the
        // lightness the ratio move carries with it, so the gap is proportional to C/L
        // and a near-neutral would make the test pass on float noise.
        let colour = RGB(0.90, 0.10, 0.05)
        func out(_ path: WritableKeyPath<ColorBalanceParams, ColorBalanceAxis>) -> RGB {
            var wheels = GradingWheels()
            wheels.colorBalance[keyPath: path].global = 40
            return GradeEngine(wheels: wheels,
                               printerLights: PrinterLights()).apply(colour)
        }
        let chroma = out(\ColorBalanceParams.chroma)
        let saturation = out(\ColorBalanceParams.saturation)
        let brilliance = out(\ColorBalanceParams.brilliance)
        XCTAssertGreaterThan(chroma.maxAbsDifference(saturation), 1e-3)
        XCTAssertGreaterThan(chroma.maxAbsDifference(brilliance), 1e-3)
        XCTAssertGreaterThan(saturation.maxAbsDifference(brilliance), 1e-3)
    }

    /// A mask's Amount scales the grid, including its hue shift. Without this a mask at
    /// Amount 0 would fade every other local adjustment to nothing and leave its grid
    /// pushing at full strength — the bug `PointColor.scalingShift` exists to fix, one
    /// disclosure lower down.
    func testMaskAmountScalesTheGrid() {
        var wheels = GradingWheels()
        wheels.colorBalance.chroma.global = 80
        wheels.colorBalance.hueShift = 40
        let colour = RGB(0.30, 0.14, 0.10)

        let off = GradeEngine(wheels: wheels.scalingShift(by: 0),
                              printerLights: PrinterLights())
        XCTAssertTrue(off.isIdentity, "a mask at Amount 0 still carried a live grid")
        XCTAssertEqual(off.apply(colour).maxAbsDifference(colour), 0, accuracy: 0)

        let half = GradeEngine(wheels: wheels.scalingShift(by: 0.5),
                               printerLights: PrinterLights())
        let full = GradeEngine(wheels: wheels, printerLights: PrinterLights())
        XCTAssertLessThan(half.apply(colour).maxAbsDifference(colour),
                          full.apply(colour).maxAbsDifference(colour),
                          "Amount 0.5 was not weaker than Amount 1")
    }

    func testGridOnlyGradeIsNotNeutral() {
        var wheels = GradingWheels()
        XCTAssertTrue(wheels.isNeutral)
        wheels.colorBalance.vibrance = 25
        XCTAssertFalse(wheels.isNeutral,
                       "LocalPlan would give this mask a two-point identity table")
    }

    // MARK: - Band geometry: the four ring handles (D13)

    private static func flatBands(core: [Double], feather: [Double]) -> [MixerBand] {
        var bands = [MixerBand](repeating: MixerBand(), count: ColorEngine.bandCount)
        for i in bands.indices {
            bands[i].core = core
            bands[i].feather = feather
        }
        return bands
    }

    /// The default geometry must be exactly what the canonical band model always was —
    /// adding handles is not allowed to change a single existing recipe's rendering.
    func testDefaultGeometryReproducesTheCanonicalBands() {
        let arcs = ColorEngine.bandArcs(
            [MixerBand](repeating: MixerBand(), count: ColorEngine.bandCount))
        XCTAssertEqual(arcs, ColorEngine.canonicalArcs)
        for step in 0..<720 {
            let hue = Double(step) / 2
            let canonical = ColorEngine.bandWeights(hue: hue)
            let viaArcs = ColorEngine.bandWeights(hue: hue, arcs: arcs)
            for i in 0..<ColorEngine.bandCount {
                XCTAssertEqual(canonical[i], viaArcs[i], accuracy: 1e-15,
                               "band \(i) at \(hue)°")
            }
        }
    }

    func testWireDefaultsMatchTheEngineGeometry() {
        XCTAssertEqual(MixerBand.defaultCore,
                       [ColorEngine.bandCoreDegrees, ColorEngine.bandCoreDegrees])
        XCTAssertEqual(MixerBand.defaultFeather,
                       [ColorEngine.bandFeatherDegrees, ColorEngine.bandFeatherDegrees])
    }

    /// Anything a decoded file can say resolves to a legal arc. `bandArcs` is the only
    /// place this is enforced, and everything downstream assumes it.
    func testBandArcsSanitizeAnythingAFileCanSay() {
        var bands = [MixerBand](repeating: MixerBand(), count: ColorEngine.bandCount)
        bands[0].core = [0, 0]
        bands[0].feather = [0, 0]
        bands[1].core = [1000, .nan]
        bands[1].feather = [.infinity, -5]
        bands[2].core = []
        bands[2].feather = [7]
        for arc in ColorEngine.bandArcs(bands) {
            for core in [arc.coreBelow, arc.coreAbove] {
                XCTAssertGreaterThanOrEqual(core, ColorEngine.bandCoreMinDegrees)
                XCTAssertLessThanOrEqual(core, ColorEngine.bandCoreMaxDegrees)
            }
            XCTAssertGreaterThanOrEqual(arc.coreBelow + arc.featherBelow,
                                        ColorEngine.bandMinReachDegrees - 1e-9)
            XCTAssertGreaterThanOrEqual(arc.coreAbove + arc.featherAbove,
                                        ColorEngine.bandMinReachDegrees - 1e-9)
        }
    }

    /// The invariant the min-reach clamp exists for: `bandWeights` has a degenerate
    /// branch that hands one band the entire weight, and that branch is a hard edge —
    /// the one artifact this band model is built not to have. With every band shrunk to
    /// its legal minimum, adjacent bands must still overlap at every midpoint, so the
    /// branch stays unreachable from the ring.
    func testShrunkBandsStillOverlapEverywhere() {
        let arcs = ColorEngine.bandArcs(
            Self.flatBands(core: [ColorEngine.bandCoreMinDegrees,
                                  ColorEngine.bandCoreMinDegrees],
                           feather: [ColorEngine.bandFeatherMinDegrees,
                                     ColorEngine.bandFeatherMinDegrees]))
        for i in 0..<ColorEngine.bandCount {
            let midpoint = ColorEngine.bandHueCentres[i]
                + ColorEngine.bandSpacingDegrees / 2
            let w = ColorEngine.bandWeights(hue: midpoint, arcs: arcs)
            let next = (i + 1) % ColorEngine.bandCount
            XCTAssertGreaterThan(w[i], 0, "band \(i) fell off its own midpoint")
            XCTAssertGreaterThan(w[next], 0, "band \(next) fell off the midpoint below it")
            XCTAssertEqual(w.reduce(0, +), 1, accuracy: 1e-12)
        }
    }

    func testCoreCentreIsTheMidpointOfTheInnerHandles() {
        var bands = [MixerBand](repeating: MixerBand(), count: ColorEngine.bandCount)
        bands[5].core = [5, 40]
        let arc = ColorEngine.bandArcs(bands)[5]
        XCTAssertEqual(Num.hueDelta(ColorEngine.bandHueCentres[5], arc.coreCentre),
                       17.5, accuracy: 1e-9)
    }

    // MARK: - Uniformity: the target, and the neighbourhood

    /// A saturated colour at a chosen hue, for driving the Mixer.
    private func swatch(hue: Double, C: Double = 0.10, L: Double = 0.55) -> RGB {
        OKLabTransform.working.toRGB(OKLCh(L: L, C: C, h: hue))
    }

    private func hue(of c: RGB) -> Double { OKLabTransform.working.toLCh(c).h }

    private func uniformityEngine(_ mixer: Mixer,
                                  means: [Double]? = nil) -> ColorEngine {
        ColorEngine(mixer: mixer, pointColors: [], color: ColorAdjust(),
                    primaries: Primaries(), bw: nil, bandMeanHues: means)
    }

    /// `bandTargetHue`'s fallback used to be a hard-coded band centre, which made
    /// Uniformity a pull toward eight fixed hues that no control could move. It is now
    /// the midpoint of the band's own core arc — the same number at the default
    /// geometry, and a user-writable one after that.
    func testUniformityConvergesOnTheCoreArcNotAFixedCentre() {
        let centre = ColorEngine.bandHueCentres[5]           // Blue
        let colour = swatch(hue: centre)

        var mixer = Mixer()
        mixer.uniformity = 100
        let plain = uniformityEngine(mixer)
        XCTAssertEqual(Num.hueDelta(centre, hue(of: plain.apply(colour))), 0,
                       accuracy: 0.5,
                       "a colour already at the band's target was moved anyway")

        var reshaped = mixer
        reshaped.bands[5].core = [5, 40]                     // core midpoint +17.5°
        let engine = uniformityEngine(reshaped)
        let moved = Num.hueDelta(centre, hue(of: engine.apply(colour)))
        XCTAssertEqual(moved, 17.5, accuracy: 1.5,
                       "Uniformity ignored the band's own core arc")
    }

    /// The wiring docs/23 audit queue item 12 asked for, at the plan level: a
    /// measurement handed to `RenderPlan(bandMeanHues:)` must reach the colour stage
    /// every shipping pixel goes through. It used to reach a cached TABLE, and the
    /// sharp edge was that table's key: build the measured plan first and the
    /// unmeasured one second, and a key without the hues would hand photo B photo A's
    /// convergence field. The colour stage is exact now (AI-03) and is never cached,
    /// so that door is gone — the order below still checks it stays gone.
    func testRenderPlanThreadsMeasuredHuesIntoTheTableAndItsKey() {
        PlanTableCache.clear()
        defer { PlanTableCache.clear() }

        var recipe = Recipe()
        recipe.develop.mixer.uniformity = 100
        let centre = ColorEngine.bandHueCentres[5]
        var means = ColorEngine.bandHueCentres
        means[5] = Num.wrapHue(centre + 20)

        // Measured FIRST, so a hues-blind cache key would poison the nil plan below.
        let measured = RenderPlan(recipe: recipe, bandMeanHues: means)
        let unmeasured = RenderPlan(recipe: recipe)

        let colour = swatch(hue: centre)
        let measuredHue = hue(of: measured.colorGraded(colour))
        let unmeasuredHue = hue(of: unmeasured.colorGraded(colour))

        XCTAssertEqual(Num.hueDelta(centre, unmeasuredHue), 0, accuracy: 1.0,
                       "with no measurement, a pixel on the band centre should rest")
        // The FULL 20° now. Through the 33³ table this measured 14.2° and the
        // assertion here could only ask for "more than 10": the table could not
        // hold the rotation. The exact stage reproduces the engine-direct result.
        XCTAssertEqual(Num.hueDelta(centre, measuredHue), 20, accuracy: 1.5,
                       "the measured mean never reached the shipping colour stage")

        // And a rebuild carries the measured plan's own stage.
        let again = RenderPlan(recipe: recipe, bandMeanHues: means)
        XCTAssertEqual(again.colorStage, measured.colorStage)
        XCTAssertNotEqual(unmeasured.colorStage, measured.colorStage)
    }

    /// The writer `bandMeanHues` never had. Before this the field was read at
    /// `bandTargetHue` and assigned `nil` in `init`, so these two engines were the same
    /// engine and no measurement could change a pixel.
    func testMeasuredMeanHueDrivesUniformity() {
        let centre = ColorEngine.bandHueCentres[5]
        let colour = swatch(hue: centre)
        var mixer = Mixer()
        mixer.uniformity = 100

        let unmeasured = uniformityEngine(mixer)
        var means = ColorEngine.bandHueCentres
        means[5] = Num.wrapHue(centre + 20)
        let measured = uniformityEngine(mixer, means: means)

        XCTAssertEqual(Num.hueDelta(centre, hue(of: unmeasured.apply(colour))), 0,
                       accuracy: 0.5)
        XCTAssertEqual(Num.hueDelta(centre, hue(of: measured.apply(colour))), 20,
                       accuracy: 1.5,
                       "the measured mean hue is still not read by anything")
    }

    /// Hue wraps, and an arithmetic mean of 350° and 10° is 180° — the opposite colour.
    /// The measurement is a chroma-weighted CIRCULAR mean for exactly this reason.
    func testMeasuredMeanHueIsCircular() {
        let colours = [swatch(hue: 350), swatch(hue: 10)]
        guard let means = ColorEngine.measureBandMeanHues(colours) else {
            return XCTFail("measured nothing from two saturated colours")
        }
        let magenta = means[7]        // the band whose core spans the 0° wrap
        XCTAssertLessThan(abs(Num.hueDelta(0, magenta)), 10,
                          "the mean of 350° and 10° landed at \(magenta)°")
        XCTAssertGreaterThan(abs(Num.hueDelta(180, magenta)), 90,
                             "the mean wrapped to the opposite colour")
    }

    /// The measurement is chroma-weighted, so a frame that is mostly grey does not drag
    /// a band's mean anywhere: a near-neutral pixel's hue is numerically noise.
    func testMeasuredMeanHueIgnoresNeutrals() {
        var colours: [RGB] = []
        for i in 0..<80 {
            colours.append(swatch(hue: 225 + Double(i % 9) - 4))
        }
        for i in 0..<2000 { colours.append(RGB(gray: 0.05 + Double(i % 20) / 40)) }
        guard let means = ColorEngine.measureBandMeanHues(colours) else {
            return XCTFail("measured nothing")
        }
        XCTAssertLessThan(abs(Num.hueDelta(225, means[5])), 3,
                          "two thousand greys moved the blue band's mean to \(means[5])°")
    }

    /// Nothing to measure is `nil`, not "measured as grey" — the caller has to be able
    /// to tell the difference or it will converge a frame onto an invented hue.
    func testMeasuringAnAchromaticFrameReportsNothing() {
        let greys = (0..<50).map { RGB(gray: 0.02 + Double($0) / 50) }
        XCTAssertNil(ColorEngine.measureBandMeanHues(greys))
    }

    /// The whole intended wiring, end to end: measure an image, build the stage with the
    /// measurement, render a pixel. This is the shape `RenderPlan` has to adopt, and the
    /// test that fails if it adopts it wrongly — the image overload is the one a renderer
    /// would call, so it is exercised here rather than left to be discovered later.
    func testMeasuringAnImageDrivesUniformityOnThatImage() {
        // A sky-like frame: one band's worth of blues scattered ±5°, over a tonal ramp,
        // with the rest of the frame near-neutral. The scattered mean lands 10° off the
        // band's canonical centre, which is exactly the case the constant fallback got
        // wrong. Ten and not twenty on purpose: past about 15° the neighbouring band
        // starts pulling the other way and the two cancel, which would make the test
        // pass for the wrong reason.
        let centre = ColorEngine.bandHueCentres[5]
        let target = Num.wrapHue(centre + 10)
        let image = ImageBuffer(width: 64, height: 64) { u, v in
            guard v < 0.75 else { return RGB(gray: 0.05 + 0.4 * u) }
            let jitter = (u - 0.5) * 10
            return OKLabTransform.working.toRGB(
                OKLCh(L: 0.45 + 0.25 * v, C: 0.11, h: Num.wrapHue(target + jitter)))
        }
        guard let means = ColorEngine.measureBandMeanHues(image) else {
            return XCTFail("measured nothing from a frame that is mostly sky")
        }
        XCTAssertLessThan(abs(Num.hueDelta(target, means[5])), 3,
                          "measured \(means[5])° for a band whose members average "
                              + "\(target)°")

        var mixer = Mixer()
        mixer.uniformity = 100
        let colour = swatch(hue: target)
        let unmeasured = uniformityEngine(mixer).apply(colour)
        let measured = uniformityEngine(mixer, means: means).apply(colour)
        // Unmeasured drags a pixel already sitting on the frame's own mean hue back
        // toward the fixed band centre; measured leaves it where it is.
        XCTAssertGreaterThan(abs(Num.hueDelta(target, hue(of: unmeasured))), 4,
                             "the constant fallback did not misconverge, so this test "
                                 + "cannot tell the measurement apart from it")
        XCTAssertLessThan(abs(Num.hueDelta(target, hue(of: measured))), 1,
                          "the measured mean did not hold the frame's own hue")
    }

    /// The local-mean seam. `apply(_:)` is the flat-neighbourhood case and must stay
    /// bit-exact; handing the kernel a real neighbourhood must change the answer, which
    /// is what proves the parameter is read rather than stored.
    func testVarianceKernelReadsTheLocalMeanItIsGiven() {
        let centre = ColorEngine.bandHueCentres[5]
        let colour = swatch(hue: centre)
        var mixer = Mixer()
        mixer.uniformity = 100
        let engine = uniformityEngine(mixer)

        XCTAssertEqual(engine.apply(colour).maxAbsDifference(
                           engine.apply(colour, localMean: colour)),
                       0, accuracy: 0,
                       "the one-argument apply is not the flat-neighbourhood case")

        // A neighbourhood sitting 20° off the pixel: compressing toward the band's
        // target now moves the pixel by the NEIGHBOURHOOD's deviation, not its own,
        // which is the whole difference between evening out a blotch and flattening a
        // texture.
        let neighbourhood = swatch(hue: centre + 20)
        let out = engine.apply(colour, localMean: neighbourhood)
        XCTAssertEqual(Num.hueDelta(centre, hue(of: out)), -20, accuracy: 1.5,
                       "the local mean was ignored")
    }

    // MARK: - The black-and-white treatment reads its own flag (COLOR-20)

    /// `look.bw` being present is no longer the treatment being on, and the stage that
    /// paints the pixels has to agree — otherwise a mix kept for later renders every
    /// photo it is kept on in black and white.
    ///
    /// Asserted on `RenderPlan`, which is what the shipping bake and the export path
    /// both build, rather than on `ColorEngine` alone.
    func testAStoredButSwitchedOffMixRendersInColour() {
        let mix: [Double] = [0, 0, 0, 0, -40, -65, 0, 0]
        let colour = RGB(0.22, 0.31, 0.55)     // a blue the mix has real authority over

        var off = Recipe()
        off.look.bw = BlackAndWhite(bands: mix, enabled: false)
        var on = off
        on.look.bw?.enabled = true

        let plain = RenderPlan(recipe: Recipe()).exactColor(colour)
        let kept = RenderPlan(recipe: off).exactColor(colour)
        let treated = RenderPlan(recipe: on).exactColor(colour)

        XCTAssertLessThan(kept.maxAbsDifference(plain), 1e-12,
                          "a mix the user switched off is still painting the picture")
        XCTAssertTrue(RenderPlan(recipe: off).colorStage.isIdentity,
                      "the switched-off mix is still running a colour stage")

        // The other direction, so the assertion above cannot pass by the stage being
        // dead: switched on, the same mix must reach a true neutral.
        XCTAssertGreaterThan(treated.maxAbsDifference(plain), 0.02,
                             "the treatment did nothing when switched on")
        XCTAssertLessThan(Swift.max(abs(treated.r - treated.g), abs(treated.g - treated.b)),
                          1e-6, "the treatment did not produce a neutral")
    }

}

// EngineMathFixtureTests.swift
// Replays `Fixtures/enginemath.json`, which `scripts/gen-fixtures.py` generates by
// EXECUTING an independent implementation of the same mathematics.
//
// Why this exists. The Linux lane runs that mirror on every push and asserts a long
// list of properties on it — the shaper's branches meet, the display transform hits
// its four anchors, saturation −100 reaches zero chroma, the tone response never
// inverts. Those assertions are worth exactly as much as the mirror's fidelity to the
// Swift, and nothing tied the two together: the Python could stay green while the
// Swift drifted underneath it, which turns a check into a reassurance.
//
// So the mirror also emits its own outputs, and this replays them. A failure here
// means the two implementations have diverged. Fix whichever is wrong — and say which
// one in the commit, because "regenerated the fixture" hides exactly the class of
// mistake this is here to catch.
//
// Tolerances are loose enough to absorb the difference between two languages' libm
// and tight enough that no behavioural change survives.

import XCTest
@testable import LumenCore

final class EngineMathFixtureTests: XCTestCase {

    private func fixture() throws -> [String: Any] {
        try Fixtures.json(named: "enginemath")
    }

    private func rows(_ f: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let rows = f[key] as? [[String: Any]] else {
            throw MissingFixture(name: "enginemath.\(key)")
        }
        XCTAssertFalse(rows.isEmpty, "\(key) is empty")
        return rows
    }

    private func double(_ row: [String: Any], _ key: String) -> Double {
        (row[key] as? NSNumber)?.doubleValue ?? .nan
    }

    // MARK: - The shaper

    func testShaperMatchesTheReference() throws {
        for row in try rows(fixture(), "shaper") {
            let x = double(row, "x")
            XCTAssertEqual(LumenLog.encode(x), double(row, "y"), accuracy: 1e-12,
                           "shaper diverged at \(x)")
        }
    }

    // MARK: - Saturation rolloff

    func testSaturationRolloffMatchesTheReference() throws {
        for row in try rows(fixture(), "saturationRolloff") {
            let b = double(row, "brightness")
            XCTAssertEqual(ColorEngine.lumSatRolloff(b), double(row, "value"),
                           accuracy: 1e-12, "rolloff diverged at brightness \(b)")
        }
    }

    // MARK: - Contrast

    func testContrastMappingMatchesTheReference() throws {
        for row in try rows(fixture(), "contrast") {
            let c = double(row, "contrast")
            let t = double(row, "t")
            let engine = ToneEngine(tone: Tone(contrast: c))
            XCTAssertEqual(engine.contrastMapped(t), double(row, "mapped"),
                           accuracy: 1e-12, "contrast \(c) diverged at \(t) EV")
        }
    }

    // MARK: - The display transform

    func testDisplayTransformMatchesTheReference() throws {
        for row in try rows(fixture(), "displayTransform") {
            var params = DisplayTransformParams()
            params.contrast = double(row, "contrast")
            params.skew = double(row, "skew")
            params.whiteTarget = double(row, "whiteTarget")
            let transform = DisplayTransform(params)
            let ev = double(row, "ev")
            let scene = DisplayTransform.midGrey * pow(2.0, ev)
            XCTAssertEqual(transform.tone(scene), double(row, "out"), accuracy: 1e-9,
                           "display transform diverged at \(ev) EV "
                               + "(contrast \(params.contrast), skew \(params.skew), "
                               + "peak \(params.whiteTarget))")
        }
    }

    // MARK: - Tone

    func testToneStopsAndZonalScaleMatchTheReference() throws {
        for row in try rows(fixture(), "tone") {
            let tone = Tone(contrast: double(row, "contrast"),
                            highlights: double(row, "highlights"),
                            shadows: double(row, "shadows"))
            let engine = ToneEngine(tone: tone)
            let label = "hi \(tone.highlights) sh \(tone.shadows) contrast \(tone.contrast)"

            // The monotonicity solve is the interesting one: it is a numerical
            // search, so a mismatch means the two searches disagree rather than
            // that one arithmetic expression was mistyped.
            XCTAssertEqual(engine.zonalScale, double(row, "zonalScale"), accuracy: 1e-9,
                           "zonal scale diverged for \(label)")

            guard let stops = row["stops"] as? [[String: Any]] else {
                return XCTFail("tone row carried no stops for \(label)")
            }
            for sample in stops {
                let t = double(sample, "t")
                XCTAssertEqual(engine.stops(at: t), double(sample, "value"),
                               accuracy: 1e-9, "stops diverged at \(t) EV for \(label)")
            }
        }
    }

    // MARK: - Chroma scaling

    func testShapedChromaScaleMatchesTheReference() throws {
        for row in try rows(fixture(), "shapedChromaScale") {
            guard let rgb = row["rgb"] as? [NSNumber], rgb.count == 3,
                  let want = row["out"] as? [NSNumber], want.count == 3 else {
                return XCTFail("malformed shapedChromaScale row")
            }
            let input = RGB(rgb[0].doubleValue, rgb[1].doubleValue, rgb[2].doubleValue)
            let gain = double(row, "gain")

            // Driven through the public surface: Saturation is what a gain means.
            var adjust = ColorAdjust(density: 0, protectSkin: 0)
            adjust.saturation = (gain - 1) * 100
            let engine = ColorEngine(mixer: Mixer(), pointColors: [], color: adjust,
                                     primaries: Primaries(), bw: nil)
            let expected = RGB(want[0].doubleValue, want[1].doubleValue,
                               want[2].doubleValue)
            // The rolloff attenuates a push, so only the non-positive side is a
            // like-for-like comparison with the bare chroma scale. The positive side
            // is covered by `testSaturationThroughThePublicPathMatchesTheReference`,
            // which drives the mirror through the same rolloff — before that existed,
            // these rows were skipped in silence and the test reported success.
            guard gain <= 1 else { continue }
            XCTAssertLessThan(engine.apply(input).maxAbsDifference(expected), 1e-9,
                              "chroma scale diverged for \(input) at gain \(gain)")
        }
    }

    /// Saturation as the panel exposes it, at both signs.
    ///
    /// This is where `satCompress`'s knee and ceiling actually get compared against the
    /// reference: a push is the only direction that reaches them, and it was the
    /// direction the bare-chroma-scale rows had to skip.
    func testSaturationThroughThePublicPathMatchesTheReference() throws {
        var compared = 0
        for row in try rows(fixture(), "shapedChromaScalePush") {
            guard let rgb = row["rgb"] as? [NSNumber], rgb.count == 3,
                  let want = row["out"] as? [NSNumber], want.count == 3 else {
                return XCTFail("malformed shapedChromaScalePush row")
            }
            let input = RGB(rgb[0].doubleValue, rgb[1].doubleValue, rgb[2].doubleValue)
            let saturation = double(row, "saturation")

            // Density 0 keeps the subtractive blend out of it, matching the mirror.
            var adjust = ColorAdjust(density: 0, protectSkin: 0)
            adjust.saturation = saturation
            let engine = ColorEngine(mixer: Mixer(), pointColors: [], color: adjust,
                                     primaries: Primaries(), bw: nil)
            let expected = RGB(want[0].doubleValue, want[1].doubleValue,
                               want[2].doubleValue)
            XCTAssertLessThan(engine.apply(input).maxAbsDifference(expected), 1e-9,
                              "saturation \(saturation) diverged for \(input)")
            compared += 1
        }
        XCTAssertEqual(compared, 30,
                       "the push fixture changed size — every row must be compared, "
                           + "not skipped")
    }

    // MARK: - White balance

    func testWhiteBalanceMatchesTheReference() throws {
        for row in try rows(fixture(), "whiteBalance") {
            let kelvin = double(row, "kelvin")
            let tint = double(row, "tint")
            let chroma = ColorTemperature.chromaticity(kelvin: kelvin, tint: tint)
            XCTAssertEqual(chroma.x, double(row, "x"), accuracy: 1e-12,
                           "locus x diverged at \(kelvin) K / \(tint)")
            XCTAssertEqual(chroma.y, double(row, "y"), accuracy: 1e-12,
                           "locus y diverged at \(kelvin) K / \(tint)")

            let back = ColorTemperature.temperatureAndTint(for: chroma)
            XCTAssertEqual(back.kelvin, double(row, "recoveredKelvin"),
                           accuracy: Swift.max(kelvin * 1e-6, 1e-6),
                           "eyedropper diverged at \(kelvin) K / \(tint)")
            XCTAssertEqual(back.tint, double(row, "recoveredTint"), accuracy: 1e-6,
                           "eyedropper tint diverged at \(kelvin) K / \(tint)")
        }
    }

    // MARK: - Grading zones

    /// Zone geometry and the grade's monotonicity solve.
    ///
    /// `solveLumScale` is the sibling of ToneEngine's zonal solve — the same failure,
    /// the same closed form — and it was wrong twice before it was right: once for
    /// missing the coupling entirely, once for sampling the axis on a fixed step that
    /// walked straight over the narrow crossfade whose slope it existed to measure.
    /// The tone solve has been tied to the mirror since this file was written; this
    /// gives the grade solve the same tie, so a third mistake in it cannot pass by
    /// agreeing with nothing.
    func testGradeZonesAndLumScaleMatchTheReference() throws {
        for row in try rows(fixture(), "grade") {
            var wheels = GradingWheels()
            wheels.blending = double(row, "blending")
            wheels.balance = double(row, "balance")
            wheels.shadows.lum = double(row, "shadowsLum")
            wheels.mid.lum = double(row, "midLum")
            wheels.high.lum = double(row, "highLum")
            let engine = GradeEngine(wheels: wheels, printerLights: PrinterLights())
            let label = "blending \(wheels.blending) balance \(wheels.balance) "
                + "wheels \(wheels.shadows.lum)/\(wheels.mid.lum)/\(wheels.high.lum)"

            XCTAssertEqual(engine.windows.shadowHalfWidth, double(row, "halfWidth"),
                           accuracy: 1e-12, "half width diverged for \(label)")
            XCTAssertEqual(engine.windows.shadowPivot, double(row, "shadowPivot"),
                           accuracy: 1e-12, "shadow pivot diverged for \(label)")
            XCTAssertEqual(engine.windows.highlightPivot,
                           double(row, "highlightPivot"), accuracy: 1e-12,
                           "highlight pivot diverged for \(label)")
            XCTAssertEqual(engine.lumScale, double(row, "lumScale"), accuracy: 1e-9,
                           "lum scale diverged for \(label)")

            guard let weights = row["weights"] as? [[String: Any]] else {
                return XCTFail("grade row carried no weights for \(label)")
            }
            for sample in weights {
                let x = double(sample, "x")
                let w = engine.windows.weights(atNormalized: x)
                XCTAssertEqual(w.shadows, double(sample, "shadows"), accuracy: 1e-12,
                               "shadow weight diverged at x=\(x) for \(label)")
                XCTAssertEqual(w.mid, double(sample, "mid"), accuracy: 1e-12,
                               "mid weight diverged at x=\(x) for \(label)")
                XCTAssertEqual(w.high, double(sample, "high"), accuracy: 1e-12,
                               "highlight weight diverged at x=\(x) for \(label)")
            }
        }
    }

    // MARK: - Radial masks

    /// The radial mask on a 3:2 frame at five rotations — the shape the long-edge-units
    /// fix was made for, and the shape the Swift-side test could not see, because it
    /// uses a square frame at rotation 0 where the bug is arithmetically absent.
    func testRadialMaskMatchesTheReference() throws {
        for row in try rows(fixture(), "radialAlpha") {
            let width = Int(double(row, "width"))
            let height = Int(double(row, "height"))
            guard let centre = row["center"] as? [NSNumber],
                  let radii = row["radii"] as? [NSNumber],
                  let samples = row["samples"] as? [[String: Any]] else {
                return XCTFail("malformed radialAlpha row")
            }
            var component = MaskComponent(op: .add, kind: .radial)
            component.center = centre.map(\.doubleValue)
            component.radii = radii.map(\.doubleValue)
            component.rotation = double(row, "rotation")
            component.feather = double(row, "feather")
            let plane = MaskRaster.rasterize(component: component,
                                             size: (width: width, height: height))
            let label = "rotation \(component.rotation ?? 0) "
                + "feather \(component.feather ?? 0)"
            for sample in samples {
                let x = Int(double(sample, "x"))
                let y = Int(double(sample, "y"))
                XCTAssertEqual(plane[x, y], double(sample, "alpha"), accuracy: 1e-6,
                               "radial mask diverged at (\(x), \(y)) for \(label)")
            }
        }
    }

    // MARK: - The film chain

    /// The grey ramp through every stock, against the mirror that walks it for
    /// inversions on the Linux lane.
    ///
    /// At Strength 100 `apply` is the chain and nothing else — the mix against the
    /// neutral rendering has weight 1 — so this compares like with like without the
    /// mirror needing a display transform of its own.
    func testFilmChainMatchesTheReference() throws {
        for row in try rows(fixture(), "film") {
            guard let id = row["stock"] as? String, let stock = FilmStock.named(id) else {
                return XCTFail("fixture names a stock that does not exist: "
                                   + String(describing: row["stock"]))
            }
            var recipe = FilmChain.defaultRecipe(for: stock)
            recipe.amount = 100
            recipe.pushPull = double(row, "push")
            let chain = FilmChain(recipe, displayWhite: 1.0)

            guard let samples = row["samples"] as? [[String: Any]] else {
                return XCTFail("film row for \(id) carried no samples")
            }
            for sample in samples {
                guard let want = sample["out"] as? [NSNumber], want.count == 3 else {
                    return XCTFail("malformed film sample for \(id)")
                }
                let ev = double(sample, "ev")
                let out = chain.apply(RGB(gray: 0.18 * pow(2, ev)))
                let expected = RGB(want[0].doubleValue, want[1].doubleValue,
                                   want[2].doubleValue)
                // Looser than the algebraic surfaces above on purpose: the calibration
                // gain is found by bisection, so the two implementations agree to the
                // search's own resolution rather than to the arithmetic's.
                XCTAssertLessThan(out.maxAbsDifference(expected), 1e-7,
                                  "film chain diverged for \(id) at push "
                                      + "\(recipe.pushPull), \(ev) EV: "
                                      + "\(out) vs \(expected)")
            }
        }
    }

    // MARK: - OKLab

    func testPerceptualMatchesTheReference() throws {
        for row in try rows(fixture(), "perceptual") {
            guard let rgb = row["rgb"] as? [NSNumber], rgb.count == 3 else {
                return XCTFail("malformed perceptual row")
            }
            let c = RGB(rgb[0].doubleValue, rgb[1].doubleValue, rgb[2].doubleValue)
            let lch = OKLabTransform.working.toLCh(c)
            XCTAssertEqual(lch.L, double(row, "L"), accuracy: 1e-12, "L diverged for \(c)")
            XCTAssertEqual(lch.C, double(row, "C"), accuracy: 1e-12, "C diverged for \(c)")
            if lch.C > 1e-9 {
                XCTAssertEqual(lch.h, double(row, "h"), accuracy: 1e-9,
                               "hue diverged for \(c)")
            }
        }
    }
}

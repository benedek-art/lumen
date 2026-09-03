// TintGuardTests.swift
// The magenta half of the tint slider, and the pole that used to sit inside it.
//
// The report this arbitrates: "if I try to tint it blue, it goes from slightly blue to
// an entirely full blue visual, so it's very bad." That is not a description of a
// slider being too strong. It is a description of a discontinuity, and there was one:
// `ChromaticAdaptation.adapt` divides by the cone response of the illuminant it adapts
// from, the S response of a far-magenta chromaticity falls through zero, and the blue
// gain comes out the far side NEGATIVE.
//
// Measured before the guard, adapting a 0.18 neutral at 2750 K with tint +80:
//
//     RGB(-0.040, -3.101, 33.579)
//
// Negative luminance, and a blue channel 186× the neutral it started from. These tests
// pin that no (Kelvin, tint) pair the app can ask for does that any more, and — just as
// important — that the guard is invisible to ordinary editing.

import Foundation
import XCTest
@testable import LumenCore

final class TintGuardTests: XCTestCase {

    private let neutral = RGB(0.18, 0.18, 0.18)

    /// Every temperature the slider can reach, at a spacing fine enough to catch a
    /// pole rather than step over it.
    private var temperatures: [Double] {
        stride(from: ColorTemperature.minKelvin, through: ColorTemperature.maxKelvin,
               by: 250).map { $0 }
    }

    // MARK: - The defect

    func testNoTintTheSliderCanReachInvertsThePicture() {
        for kelvin in temperatures {
            for tint in stride(from: -300.0, through: 300.0, by: 5) {
                let engine = WhiteBalanceEngine(asShotKelvin: kelvin, asShotTint: 0,
                                                targetKelvin: kelvin, targetTint: tint)
                let out = engine.apply(neutral)
                XCTAssertTrue(out.r.isFinite && out.g.isFinite && out.b.isFinite,
                              "\(kelvin) K tint \(tint) produced a non-finite neutral")
                XCTAssertGreaterThanOrEqual(out.r, 0, "\(kelvin) K tint \(tint): red went negative")
                XCTAssertGreaterThanOrEqual(out.g, 0, "\(kelvin) K tint \(tint): green went negative")
                XCTAssertGreaterThanOrEqual(out.b, 0, "\(kelvin) K tint \(tint): blue went negative")
            }
        }
    }

    func testTheCaseFromTheReportIsAStrongPushRatherThanAnInversion() {
        let engine = WhiteBalanceEngine(asShotKelvin: 2750, asShotTint: 0,
                                        targetKelvin: 2750, targetTint: 80)
        let out = engine.apply(neutral)
        // Was RGB(-0.040, -3.101, 33.579).
        XCTAssertGreaterThan(out.g, 0, "green was -3.101 before the guard")
        XCTAssertLessThan(out.b, 2.0, "blue was 33.579 before the guard")
        // It should still be a firmly magenta result — guarding is not neutralising.
        XCTAssertGreaterThan(out.b, out.g, "a magenta tint should still lift blue over green")
    }

    func testTheBlueGainIsBoundedByTheFloorItIsDefinedFrom() {
        // The guard's real content: the blue multiplier never exceeds 1/tintConeFloor.
        // A little headroom for the working-space mix, which is not diagonal.
        let ceiling = 1.5 / ColorTemperature.tintConeFloor
        for kelvin in temperatures {
            for tint in stride(from: 0.0, through: 300.0, by: 5) {
                let engine = WhiteBalanceEngine(asShotKelvin: kelvin, asShotTint: 0,
                                                targetKelvin: kelvin, targetTint: tint)
                let gain = engine.apply(neutral).b / neutral.b
                XCTAssertLessThan(gain, ceiling,
                                  "\(kelvin) K tint \(tint) multiplied blue by \(gain)")
            }
        }
    }

    // MARK: - The guard must not be felt where nothing was wrong

    func testGreenTintIsNeverClamped() {
        // Only magenta leaves the physical region; green moves toward the interior of
        // the plane, where every cone response grows.
        for kelvin in temperatures {
            for tint in stride(from: -300.0, through: 0.0, by: 5) {
                XCTAssertEqual(ColorTemperature.clampedTint(kelvin: kelvin, tint: tint), tint,
                               accuracy: 1e-12, "green tint \(tint) clamped at \(kelvin) K")
            }
        }
    }

    func testDaylightEditingIsUntouched() {
        // At and above 5500 K the whole shipped soft range is admissible, so no recipe
        // a photographer already has renders differently than it did.
        for kelvin in stride(from: 5500.0, through: ColorTemperature.maxKelvin, by: 250) {
            XCTAssertGreaterThanOrEqual(ColorTemperature.tintLimit(kelvin: kelvin), 150,
                                        "\(kelvin) K clamps inside the soft range")
        }
    }

    func testTheLimitTightensAsTheFrameGetsWarmer() {
        // The pole moved with temperature, so the guard has to as well. A fixed tint
        // limit would either not save 2000 K or would gut 5500 K.
        let sampled = [2000.0, 2750, 3200, 4000, 5500, 10000]
        let limits = sampled.map { ColorTemperature.tintLimit(kelvin: $0) }
        for i in 1..<limits.count {
            XCTAssertGreaterThan(limits[i], limits[i - 1],
                                 "limit did not rise from \(sampled[i - 1]) to \(sampled[i]) K")
        }
        XCTAssertLessThan(limits[0], 50, "2000 K should be tightly bounded")
    }

    // MARK: - The guard has to hold everywhere the numbers enter

    func testTheEyedropperReportsATintTheRenderWillActuallyUse() {
        // Sampling a colour past the bound used to hand back a number that the
        // chromaticity function would then silently pull in, so the panel disagreed
        // with the picture.
        for kelvin in [2000.0, 2750, 3500, 5500] {
            let asked = ColorTemperature.chromaticity(kelvin: kelvin, tint: 280)
            let (recoveredK, recoveredTint) = ColorTemperature.temperatureAndTint(for: asked)
            XCTAssertEqual(recoveredK, kelvin, accuracy: 60,
                           "temperature was not recovered at \(kelvin) K")
            XCTAssertLessThanOrEqual(recoveredTint,
                                     ColorTemperature.tintLimit(kelvin: kelvin) + 1,
                                     "reported a tint beyond the bound at \(kelvin) K")
            // And the round trip is stable: what it reports renders what was sampled.
            let again = ColorTemperature.chromaticity(kelvin: recoveredK, tint: recoveredTint)
            XCTAssertEqual(again.x, asked.x, accuracy: 2e-3)
            XCTAssertEqual(again.y, asked.y, accuracy: 2e-3)
        }
    }

    func testAsShotTintIsGuardedToo() {
        // A file whose recorded neutral is itself past the bound must not invert the
        // picture before the photographer has touched anything.
        let engine = WhiteBalanceEngine(asShotKelvin: 2400, asShotTint: 250,
                                        targetKelvin: nil, targetTint: nil)
        XCTAssertTrue(engine.isIdentity, "an untouched file should render as shot")

        let moved = WhiteBalanceEngine(asShotKelvin: 2400, asShotTint: 250,
                                       targetKelvin: 5500, targetTint: 0)
        let out = moved.apply(neutral)
        XCTAssertTrue(out.r.isFinite && out.g.isFinite && out.b.isFinite)
        // NOT "no channel is negative", which is a law this cannot have and should not
        // claim. Adapting a strongly magenta neutral to daylight means removing
        // magenta, and the result is a colour more saturated than Rec.2020's green
        // primary — legitimately outside the working space, and it lands at
        // b = -0.0039 here, about 2% of the input. What the guard owes is that the
        // result stays a picture: luminance positive, magnitudes sane. Before it, the
        // same shape of case reached RGB(-0.040, -3.101, 33.579).
        XCTAssertGreaterThan(out.g, 0, "luminance must not invert")
        XCTAssertGreaterThan(out.r, 0)
        XCTAssertGreaterThan(out.b, -0.05, "a small out-of-gamut excursion, not an inversion")
        XCTAssertLessThan(Swift.max(out.r, out.g, out.b), 2.0)
    }

    // MARK: - What "slightly blue to entirely full blue" actually was

    func testOneUnitOfTintIsNeverWorthMoreThanTheWholeSlider() {
        // The pole's signature, and the closest thing to the owner's own words that can
        // be written as an assertion. A control that inverts does not merely reach a
        // wrong value — it JUMPS there, and the jump is between two adjacent settings
        // the slider steps through one at a time.
        //
        // Measured across every temperature a camera can report, stepping tint by its
        // own unit through the whole hard range: the largest single-step change in the
        // adapted neutral was **4212.58** before the guard, against 0.0012 for a step
        // in the middle of the range. One click of the slider was worth three and a
        // half million ordinary clicks. It is now 0.1477 at worst.
        var worst = 0.0
        var worstAt = (kelvin: 0.0, tint: 0.0)
        for kelvin in stride(from: 2000.0, through: 15000.0, by: 250) {
            var previous: RGB?
            for tint in stride(from: -300.0, through: 300.0, by: 1) {
                let out = WhiteBalanceEngine(asShotKelvin: kelvin, asShotTint: 0,
                                             targetKelvin: kelvin, targetTint: tint)
                    .apply(neutral)
                if let previous {
                    let step = Swift.max(abs(out.r - previous.r),
                                         Swift.max(abs(out.g - previous.g),
                                                   abs(out.b - previous.b)))
                    if step > worst {
                        worst = step
                        worstAt = (kelvin, tint)
                    }
                }
                previous = out
            }
        }
        XCTAssertLessThan(worst, 0.5,
                          "one unit of tint moved the neutral by \(worst) at "
                              + "\(worstAt.kelvin) K / tint \(worstAt.tint)")
    }

    // MARK: - Tint honesty (docs/23 M2: tintLimit surfaced; eyedropper cheap again)

    /// The memo is not allowed to change an answer, only how often one is derived.
    func testTheTintLimitCacheServesTheBisectionsAnswer() {
        // Kelvins nothing else in the suite is likely to have asked about, so the
        // first pass genuinely computes.
        let kelvins = [2111.0, 3222.0, 4333.0, 5444.0, 12345.0]
        let first = kelvins.map { ColorTemperature.tintLimit(kelvin: $0) }
        let computed = ColorTemperature.tintLimitComputationCount
        let second = kelvins.map { ColorTemperature.tintLimit(kelvin: $0) }
        XCTAssertEqual(first, second, "the cache changed a limit")
        XCTAssertEqual(ColorTemperature.tintLimitComputationCount, computed,
                       "a repeated kelvin re-ran the bisection")
    }

    /// The reason the memo exists: `neutralizing` probes a few thousand
    /// (kelvin, tint) candidates and each used to pay a 40-step bisection. The
    /// kelvins repeat across tints, so a click's bisection count must be on the
    /// order of the DISTINCT kelvins (~140), never the candidates (~3000).
    func testTheEyedropperDoesNotPayABisectionPerCandidate() {
        let current = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                         targetKelvin: nil, targetTint: nil)
        let before = ColorTemperature.tintLimitComputationCount
        _ = WhiteBalanceEngine.neutralizing(sample: RGB(0.45, 0.5, 0.62),
                                            asShotKelvin: 5500, asShotTint: 0,
                                            current: current)
        let cost = ColorTemperature.tintLimitComputationCount - before
        XCTAssertLessThan(cost, 300,
                          "one eyedropper click ran \(cost) bisections — the kelvin "
                              + "memo is not being hit")
    }

    /// `effectiveTint`, surfaced like `effectiveHighlights`: the engine has bounded
    /// magenta correctly since the guard landed and told nobody, so on a warm frame
    /// the slider's last stretch moved a number and no pixel with nothing on screen
    /// to say why. The panel badges when this diverges from the slider's value.
    func testEffectiveTintReportsTheBoundedMagentaAndOnlyThat() {
        let warm = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                      targetKelvin: 2000, targetTint: 150)
        XCTAssertLessThan(warm.effectiveTint, 150,
                          "a +150 magenta at 2000 K is past the physical bound and "
                              + "must report as less")
        XCTAssertEqual(warm.effectiveTint,
                       ColorTemperature.clampedTint(kelvin: 2000, tint: 150))

        let daylight = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                          targetKelvin: 5500, targetTint: 40)
        XCTAssertEqual(daylight.effectiveTint, 40, "ordinary daylight work is untouched")

        let green = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                       targetKelvin: 2000, targetTint: -150)
        XCTAssertEqual(green.effectiveTint, -150, "green is never clamped")
    }
}

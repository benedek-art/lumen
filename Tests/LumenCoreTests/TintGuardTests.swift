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
        XCTAssertGreaterThanOrEqual(min(out.r, out.g, out.b), 0)
    }
}

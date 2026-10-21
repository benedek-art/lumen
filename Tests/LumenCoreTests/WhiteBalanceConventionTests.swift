// WhiteBalanceConventionTests.swift
// WS-03: Temp/Tint speak the Adobe / DNG SDK convention, for the target pair and the
// as-shot pair alike (docs/quality/lanes/WS-03/SPEC.md lines 2, 3, 4, 7 and 9).

import XCTest
@testable import LumenCore

final class WhiteBalanceConventionTests: XCTestCase {

    private let space = RGBColorSpace.rec2020

    /// A Y = 0.18 neutral lit by `illuminant` (Adobe K / tint) and decoded at `asShot`:
    /// the decode modelled as CAT16 from the as-shot white to the working white (D65),
    /// the same model `tools/wbmodel.py` (`decoded_grey`) measures with.
    private func decodedGrey(lit illuminant: (Double, Double),
                             asShot: (Double, Double)) -> RGB {
        let from = DNGTemperature.chromaticity(kelvin: asShot.0, tint: asShot.1).xyz()
        let decode = ChromaticAdaptation.adapt(from: from, to: WhitePoint.d65.xyz(),
                                               cone: ChromaticAdaptation.cat16)
        let lit = DNGTemperature.chromaticity(kelvin: illuminant.0, tint: illuminant.1)
            .xyz(Y: 0.18)
        return space.fromXYZ.apply(decode.apply(lit))
    }

    private func spread(_ c: RGB) -> Double {
        let mean = (c.r + c.g + c.b) / 3
        return Swift.max(abs(c.r - mean), abs(c.g - mean), abs(c.b - mean)) / mean
    }

    // MARK: - SPEC 2: one convention

    /// Below the magenta guard `ColorTemperature.chromaticity` IS
    /// `DNGTemperature.chromaticity`, over 2000–50000 K in 5-mired steps × ±150 tint.
    func testChromaticityIsTheDNGConventionBelowTheGuard() {
        var worst = 0.0
        var compared = 0
        for mired in stride(from: 20.0, through: 500.0, by: 5) {
            let kelvin = 1e6 / mired
            let limit = ColorTemperature.tintLimit(kelvin: kelvin)
            for tint in stride(from: -150.0, through: 150.0, by: 2.5) where tint <= limit {
                let lumen = ColorTemperature.chromaticity(kelvin: kelvin, tint: tint)
                let adobe = DNGTemperature.chromaticity(kelvin: kelvin, tint: tint)
                worst = Swift.max(worst, abs(lumen.x - adobe.x), abs(lumen.y - adobe.y))
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 10000)
        XCTAssertLessThanOrEqual(worst, 1e-9, "max xy difference \(worst)")
    }

    /// The as-shot pair is read in the same convention: the engine's matrix is CAT16
    /// from the DNG chromaticity of the target to the DNG chromaticity of the as-shot.
    func testTheAsShotPairIsReadInTheSameConvention() {
        for (asShot, target) in [((6503.7072, 9.77), (5500.0, 10.0)),
                                 ((4708.0, 48.2), (3200.0, 0.0)),
                                 ((9365.0, 16.4), (12000.0, -20.0)),
                                 ((2850.0, 0.0), (6500.0, 10.0))] {
            let engine = WhiteBalanceEngine(asShotKelvin: asShot.0, asShotTint: asShot.1,
                                            targetKelvin: target.0, targetTint: target.1)
            let expected = space.fromXYZ * ChromaticAdaptation.adapt(
                from: DNGTemperature.chromaticity(kelvin: target.0, tint: target.1).xyz(),
                to: DNGTemperature.chromaticity(kelvin: asShot.0, tint: asShot.1).xyz(),
                cone: ChromaticAdaptation.cat16) * space.toXYZ
            XCTAssertLessThan(engine.matrix.maxAbsDifference(expected), 1e-12,
                              "\(asShot) → \(target)")
        }
    }

    /// Round trip through `ColorTemperature.temperatureAndTint` returns the pair within
    /// 0.01 mired and 0.01 tint (it is exact to ~1e-9). The SDK's own inverse,
    /// `DNGTemperature.temperatureAndTint`, is NOT an exact inverse by design (it
    /// interpolates by distance to two non-parallel isotherms; pinned in
    /// DNGTemperatureTests) and is held to its measured bound here: 0.033 mired.
    func testTheRoundTripReturnsThePair() {
        var worstMired = 0.0, worstTint = 0.0, sdkMired = 0.0, sdkTint = 0.0
        for mired in stride(from: 20.0, through: 500.0, by: 5) {
            let kelvin = 1e6 / mired
            let limit = ColorTemperature.tintLimit(kelvin: kelvin)
            for tint in stride(from: -150.0, through: 150.0, by: 2.5) where tint <= limit {
                let chroma = ColorTemperature.chromaticity(kelvin: kelvin, tint: tint)
                let back = ColorTemperature.temperatureAndTint(for: chroma)
                worstMired = Swift.max(worstMired, abs(1e6 / back.kelvin - mired))
                worstTint = Swift.max(worstTint, abs(back.tint - tint))
                let sdk = DNGTemperature.temperatureAndTint(for: chroma)
                sdkMired = Swift.max(sdkMired, abs(1e6 / sdk.kelvin - mired))
                sdkTint = Swift.max(sdkTint, abs(sdk.tint - tint))
            }
        }
        XCTAssertLessThanOrEqual(worstMired, 0.01, "round trip moved \(worstMired) mired")
        XCTAssertLessThanOrEqual(worstTint, 0.01, "round trip moved tint \(worstTint)")
        XCTAssertLessThan(sdkMired, 0.035, "SDK inverse moved \(sdkMired) mired")
        XCTAssertLessThan(sdkTint, 0.002, "SDK inverse moved tint \(sdkTint)")
    }

    // MARK: - SPEC 3 and 9: the numbers neutralise their light

    private let asShots: [(Double, Double)] = [
        (2850, 0), (3200, 0), (4000, 5), (4708, 48.2), (5000, 8), (5500, 10),
        (6503.7072, 9.77), (7500, 10), (9365, 16.4), (5500, -15),
    ]

    /// A grey lit by L and decoded at as-shot A comes out neutral when Temp/Tint are
    /// L's Adobe numbers — 10 as-shots × 10 Kelvins × 5 tints. Exact by construction
    /// (diagonal CAT16 steps compose); asserted to 1e-9 relative.
    func testTypingTheLightsAdobeNumbersNeutralisesItsGrey() {
        var worst = 0.0
        for asShot in asShots {
            for kelvin in [2500.0, 2850, 3200, 3800, 4500, 5500, 6500, 7500, 10000, 15000] {
                for tint in [-20.0, -10, 0, 10, 21] {
                    let grey = decodedGrey(lit: (kelvin, tint), asShot: asShot)
                    let engine = WhiteBalanceEngine(asShotKelvin: asShot.0, asShotTint: asShot.1,
                                                    targetKelvin: kelvin, targetTint: tint)
                    worst = Swift.max(worst, spread(engine.apply(grey)))
                }
            }
        }
        XCTAssertLessThan(worst, 1e-9, "worst relative channel spread \(worst)")
    }

    func testEachPresetNeutralisesItsOwnAdobeLight() {
        XCTAssertEqual(WhiteBalanceEngine.presets.map { "\($0.name) \($0.kelvin) \($0.tint)" },
                       ["Daylight 5500.0 10.0", "Cloudy 6500.0 10.0", "Shade 7500.0 10.0",
                        "Tungsten 2850.0 0.0", "Fluorescent 3800.0 21.0", "Flash 5500.0 0.0"])
        for preset in WhiteBalanceEngine.presets {
            for asShot in asShots {
                let grey = decodedGrey(lit: (preset.kelvin, preset.tint), asShot: asShot)
                let engine = WhiteBalanceEngine(asShotKelvin: asShot.0, asShotTint: asShot.1,
                                                targetKelvin: preset.kelvin,
                                                targetTint: preset.tint)
                XCTAssertLessThan(spread(engine.apply(grey)), 1e-9,
                                  "\(preset.name) from as-shot \(asShot)")
            }
        }
    }

    // MARK: - SPEC 4: the tint axis is the isotherm

    /// At as-shot D65 (6503.7 / +9.77) a tint-only move renders green one way and
    /// magenta the other: OKLab hue 145–160° for −tint and 318–330° for +tint (Adobe's
    /// 152.6° / 325.7° at ∓75), not the old 112° yellow-green / 289° blue-violet.
    func testTheTintAxisRunsGreenToMagenta() {
        let lab = OKLabTransform.working
        for (tint, range) in [(-75.0, 145.0...160.0), (-150.0, 145.0...160.0),
                              (85.0, 318.0...330.0), (160.0, 318.0...330.0)] {
            let engine = WhiteBalanceEngine(asShotKelvin: 6503.7072, asShotTint: 9.77,
                                            targetKelvin: 6503.7072, targetTint: tint)
            let c = lab.toLab(engine.apply(RGB(gray: 0.18)))
            var hue = atan2(c.b, c.a) * 180 / .pi
            if hue < 0 { hue += 360 }
            XCTAssertTrue(range.contains(hue), "tint \(tint) rendered hue \(hue)")
        }
    }

    // MARK: - SPEC 7: the eyedropper returns the light's Adobe numbers

    func testTheEyedropperReturnsTheIlluminantsAdobeNumbers() {
        let asShots: [(Double, Double)] = [(6503.7072, 9.77), (5000, 5), (3000, 0), (4708, 48.2)]
        let lights: [(Double, Double)] = [(2856, 0), (3800, 21), (4000, 0), (5002, 9.6),
                                          (6504, 9.8), (7506, 9.6), (9992, 9.3)]
        var worstMired = 0.0, worstTint = 0.0
        for asShot in asShots {
            let current = WhiteBalanceEngine(asShotKelvin: asShot.0, asShotTint: asShot.1,
                                             targetKelvin: nil, targetTint: nil)
            for light in lights {
                let grey = decodedGrey(lit: light, asShot: asShot)
                let solved = WhiteBalanceEngine.neutralizing(
                    sample: current.apply(grey), asShotKelvin: asShot.0,
                    asShotTint: asShot.1, current: current)
                let dm = abs(1e6 / solved.kelvin - 1e6 / light.0)
                let dt = abs(solved.tint - light.1)
                worstMired = Swift.max(worstMired, dm)
                worstTint = Swift.max(worstTint, dt)
                XCTAssertLessThanOrEqual(dm, 0.1, "as-shot \(asShot), light \(light): \(solved)")
                XCTAssertLessThanOrEqual(dt, 0.3, "as-shot \(asShot), light \(light): \(solved)")
            }
        }
        print("WS-03 SPEC 7: max |dMired| \(worstMired), max |dTint| \(worstTint)")
    }
}

// AutoWhiteBalanceTests.swift
// WS-03 SPEC lines 12, 16 and 17 on synthetic frames. The corpus measurements (13–15,
// 17c) are `docs/quality/lanes/WS-03/tools/auto_eval.py` through `lumen-render autowb`.

import XCTest
@testable import LumenCore

final class AutoWhiteBalanceTests: XCTestCase {

    private let space = RGBColorSpace.rec2020

    /// A colour of reflectance `rgb` under D65, lit instead by `light` and decoded at
    /// `asShot` (decode modelled as CAT16 from the as-shot white to D65).
    private func decoded(_ rgb: RGB, lit light: (Double, Double),
                         asShot: (Double, Double)) -> RGB {
        let illuminate = ChromaticAdaptation.adapt(
            from: WhitePoint.d65.xyz(),
            to: DNGTemperature.chromaticity(kelvin: light.0, tint: light.1).xyz(),
            cone: ChromaticAdaptation.cat16)
        let decode = ChromaticAdaptation.adapt(
            from: DNGTemperature.chromaticity(kelvin: asShot.0, tint: asShot.1).xyz(),
            to: WhitePoint.d65.xyz(), cone: ChromaticAdaptation.cat16)
        return space.fromXYZ.apply(decode.apply(illuminate.apply(space.toXYZ.apply(rgb))))
    }

    /// A scene of grey steps and a few colours, lit by `light`, decoded at `asShot`.
    private func scene(lit light: (Double, Double), asShot: (Double, Double)) -> ImageBuffer {
        let patches: [RGB] = [RGB(gray: 0.05), RGB(gray: 0.1), RGB(gray: 0.18),
                              RGB(gray: 0.3), RGB(gray: 0.5), RGB(0.12, 0.25, 0.08),
                              RGB(0.3, 0.12, 0.08), RGB(0.08, 0.12, 0.3), RGB(gray: 0.18)]
        let lit = patches.map { decoded($0, lit: light, asShot: asShot) }
        return ImageBuffer(width: 900, height: 600) { u, v in
            lit[Swift.min(8, Int(u * 3) + 3 * Int(v * 3))]
        }
    }

    func testANeutralFrameReturnsTheAsShotPairExactly() {
        let flat = ImageBuffer(width: 256, height: 256) { _, _ in RGB(gray: 0.18) }
        let estimate = AutoWhiteBalance.estimate(flat, asShot: .init(kelvin: 4000, tint: 5))
        XCTAssertEqual(estimate.kelvin, 4000)
        XCTAssertEqual(estimate.tint, 5)
    }

    /// Greys lit by a light near the as-shot: Auto closes at least half the gap.
    /// (A WARM cast of more than about 20 mired puts the greys inside the skin wedge
    /// in log-chroma and Auto deliberately stays near as-shot there — the skin-safe
    /// trade, recorded in BUILD-NOTES.)
    func testItMovesTowardTheLightThatLitTheGreys() {
        let asShot = (5500.0, 10.0)
        for light in [(5200.0, 4.0), (6000.0, 12.0)] {
            let estimate = AutoWhiteBalance.estimate(scene(lit: light, asShot: asShot),
                                                     asShot: .init(kelvin: asShot.0, tint: asShot.1))
            let asShotError = abs(1e6 / asShot.0 - 1e6 / light.0)
            let autoError = abs(1e6 / estimate.kelvin - 1e6 / light.0)
            XCTAssertGreaterThan(estimate.confidence, 0.3, "\(light)")
            XCTAssertLessThan(autoError, asShotError * 0.5,
                              "auto \(estimate) did not close half the gap to \(light)")
            XCTAssertLessThan(abs(estimate.tint - light.1), abs(asShot.1 - light.1) + 1)
        }
    }

    func testAnExcludedRegionIsIgnored() {
        // Left half: greys under 4000 K; right half: the same greys at as-shot. With
        // the left half excluded, the frame is already neutral.
        let asShot = (5500.0, 10.0)
        let shifted = decoded(RGB(gray: 0.18), lit: (4000, 5), asShot: asShot)
        let image = ImageBuffer(width: 800, height: 400) { u, _ in
            u < 0.5 ? shifted : RGB(gray: 0.18)
        }
        let estimate = AutoWhiteBalance.estimate(
            image, asShot: .init(kelvin: asShot.0, tint: asShot.1),
            excluding: [.init(x: 0, y: 0, width: 400, height: 400)])
        XCTAssertEqual(estimate.kelvin, asShot.0, accuracy: 1e-6)
        XCTAssertEqual(estimate.tint, asShot.1, accuracy: 1e-6)
    }

    /// A frame of nothing but skin (Monk 2–8 and the two ColorChecker skins, no
    /// neutral) is not greyed: it stays within 12 mired / 6 tint of as-shot.
    func testAFrameOfSkinIsNotGreyed() {
        let skins: [RGB] = [RGB(0.856136, 0.804786, 0.719441), RGB(0.881805, 0.82802, 0.652565),
                            RGB(0.768348, 0.707123, 0.514949), RGB(0.607124, 0.518357, 0.329072),
                            RGB(0.293284, 0.217197, 0.107468), RGB(0.177726, 0.114474, 0.063347),
                            RGB(0.092281, 0.05708, 0.037324), RGB(0.138062, 0.088105, 0.060869),
                            RGB(0.462423, 0.310898, 0.230638)]
        let image = ImageBuffer(width: 600, height: 600) { u, v in
            skins[Swift.min(8, Int(u * 3) + 3 * Int(v * 3))]
        }
        let estimate = AutoWhiteBalance.estimate(image,
                                                 asShot: .init(kelvin: 6503.7072, tint: 9.77))
        XCTAssertLessThanOrEqual(abs(1e6 / estimate.kelvin - 1e6 / 6503.7072), 12)
        XCTAssertLessThanOrEqual(abs(estimate.tint - 9.77), 6)
    }

    func testItIsDeterministic() {
        let image = scene(lit: (4500, 0), asShot: (5200, 8))
        let first = AutoWhiteBalance.estimate(image, asShot: .init(kelvin: 5200, tint: 8))
        for _ in 0..<4 {
            XCTAssertEqual(AutoWhiteBalance.estimate(image, asShot: .init(kelvin: 5200, tint: 8)),
                           first)
        }
    }

    /// The closed-form neutral target agrees with the eyedropper's search.
    func testTheNeutralTargetAgreesWithTheEyedropper() {
        let asShot = (5000.0, 5.0)
        let grey = decoded(RGB(gray: 0.18), lit: (3800, 21), asShot: asShot)
        let closed = AutoWhiteBalance.neutralTarget(decodedNeutral: grey, asShot: asShot)!
        XCTAssertEqual(1e6 / closed.kelvin, 1e6 / 3800, accuracy: 1e-6)
        XCTAssertEqual(closed.tint, 21, accuracy: 1e-6)
    }
}

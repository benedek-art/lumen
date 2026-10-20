// LocalHueStrengthLimitTests.swift
// A mask's Strength above 100% never turns its Hue shift round the other way.
//
// Strength (mask Amount, 0–200) multiplies the whole local adjustment set, and the
// panel promises "Individual limits remain": every slider is scaled, none is pushed
// past its own range. The local Hue slider runs −180…+180°, and both render paths
// rotated by `hue · scale` with no limit, so anything past ±180° wrapped. Hue +120 at
// Strength 200 rotated by 240°, which on the wheel is −120°: the picture rendered as if
// the user had dragged Hue the OTHER way. Hue +180 at Strength 150 rotated by 270°,
// i.e. −90°, so raising Strength from 100 to 150 brought the colour back towards where
// it started. For every |Hue| above 90° the effect stopped being monotone in Strength.
//
// The rotation now saturates at the slider's own limit, ±180°: the furthest a hue can
// be from where it began. Every shift that stayed inside that range renders as before.

import XCTest
@testable import LumenCore

final class LocalHueStrengthLimitTests: XCTestCase {

    private let space = OKLabTransform.working

    /// The signed hue turn, in degrees, that a mask with this Hue at this Strength
    /// applies to a saturated orange patch, measured against the same patch rendered
    /// with no hue shift at all.
    private func hueTurn(hue: Double, strength: Double) -> Double {
        let plan = RenderPlan(recipe: Recipe(), lutSize: 17)
        let input = ImageBuffer(width: 1, height: 1) { _, _ in RGB(0.40, 0.10, 0.05) }
        var neutral = Mask(id: "hue", amount: strength)
        neutral.adjust.hue = 0
        var shifted = neutral
        shifted.adjust.hue = hue
        let before = ReferenceRenderer.applyLocalAdjust(input, mask: neutral, plan: plan,
                                                        space: .rec2020)[0, 0]
        let after = ReferenceRenderer.applyLocalAdjust(input, mask: shifted, plan: plan,
                                                       space: .rec2020)[0, 0]
        return Num.hueDelta(space.toLCh(before).h, space.toLCh(after).h)
    }

    func testMoreMaskStrengthNeverTurnsTheLocalHueBackTheOtherWay() {
        for hue in [120.0, -120, 180, -180, 150, -100] {
            var previous = 0.0
            for strength in stride(from: 0.0, through: 200, by: 25) {
                let turn = hueTurn(hue: hue, strength: strength)
                // Measured with the sign of the slider, so "further round the way the
                // user dragged" is always "larger".
                // The half turn reads as +180° or −180° alike, so there it counts as 180.
                let along = abs(turn) > 179.5 ? abs(turn) : (hue > 0 ? turn : -turn)
                XCTAssertGreaterThanOrEqual(
                    along, previous - 0.5,
                    "Hue \(hue)° at Strength \(strength)% turned \(turn)°, less far than "
                        + "\(previous)° at the Strength below it")
                previous = Swift.max(previous, along)
            }
        }
    }

    func testAStrongMaskStopsAtTheHueSlidersOwnHalfTurn() {
        // +120° at 200% asks for 240°; it must land at the half turn, not at −120°.
        let turn = hueTurn(hue: 120, strength: 200)
        XCTAssertEqual(abs(turn), 180, accuracy: 1,
                       "Hue +120° at Strength 200% turned \(turn)°")
        // Inside the slider's range Strength still scales the rotation exactly.
        XCTAssertEqual(hueTurn(hue: 60, strength: 200), 120, accuracy: 1)
        XCTAssertEqual(hueTurn(hue: -60, strength: 150), -90, accuracy: 1)
    }
}

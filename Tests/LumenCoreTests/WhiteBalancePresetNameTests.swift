// WhiteBalancePresetNameTests.swift
// The white-balance preset menu names the pair the render adapts to.
//
// The menu's title is a claim about the picture: "As Shot" says no override is in force,
// a preset's name says Temp/Tint sit on that illuminant, "Custom" says they sit anywhere
// else (docs/04 §2.1, "any manual move flips to Custom"). The rule lived in BasicPanel,
// where no test could reach it, and it read the recipe's two optionals instead of the
// pair `WhiteBalanceEngine.displayed` resolves them to: a nil Temp meant "As Shot" no
// matter what Tint said, and a nil Tint meant 0 no matter what the file was shot at.
//
// These run on Linux: the rule is in LumenCore now and the panel only calls it.

import XCTest
@testable import LumenCore

final class WhiteBalancePresetNameTests: XCTestCase {

    private typealias Neutral = WhiteBalanceEngine.Neutral

    private func name(temp: Double?, tint: Double?, shot: Neutral) -> String {
        WhiteBalanceEngine.presetName(temp: temp, tint: tint, asShot: shot)
    }

    /// Only a recipe with neither override reads As Shot.
    func testAnUntouchedRecipeReadsAsShot() {
        XCTAssertEqual(name(temp: nil, tint: nil, shot: Neutral(kelvin: 5137, tint: 3)), "As Shot")
        XCTAssertEqual(name(temp: nil, tint: nil, shot: .reference), "As Shot")
    }

    /// Dragging Tint alone writes only `raw.tint`; the render moves to (as-shot K, +40)
    /// and turns magenta, so the menu must stop claiming As Shot.
    func testATintOnlyMoveReadsCustomRatherThanAsShot() {
        let shot = Neutral(kelvin: 5137, tint: 3)
        XCTAssertEqual(name(temp: nil, tint: 40, shot: shot), "Custom",
                       "Tint +40 with Temp as shot renders 5137/+40 — that is not As Shot")
    }

    /// A Tint-only move that lands the pair on a preset names that preset: a frame shot
    /// at 5500 K with Tint pinned to +10 renders exactly Daylight.
    func testATintOnlyMoveOntoAPresetNamesThatPreset() {
        XCTAssertEqual(name(temp: nil, tint: 10, shot: Neutral(kelvin: 5500, tint: -4)), "Daylight")
    }

    /// Temp typed to 5500 leaves `raw.tint` nil, and the render keeps the AS-SHOT tint.
    /// Shot at +10 that is 5500/+10, which is Daylight — not Flash (5500/0).
    func testANilTintMeansTheAsShotTintNotZero() {
        XCTAssertEqual(name(temp: 5500, tint: nil, shot: Neutral(kelvin: 5137, tint: 10)), "Daylight",
                       "5500 K on a frame shot at tint +10 renders 5500/+10 — Daylight")
        XCTAssertEqual(name(temp: 5500, tint: nil, shot: Neutral(kelvin: 5137, tint: 3)), "Custom",
                       "5500 K on a frame shot at tint +3 renders 5500/+3 — no preset")
        XCTAssertEqual(name(temp: 5500, tint: nil, shot: Neutral(kelvin: 5137, tint: 0)), "Flash")
    }

    /// Picking a preset writes both numbers, and the menu reads that preset back for
    /// every one of them, whatever the file was shot at. Daylight wins its tie with
    /// Flash only where the numbers say Daylight.
    func testEveryPresetReadsBackAsItself() {
        for shot in [Neutral(kelvin: 3200, tint: -7), .reference, Neutral(kelvin: 6100, tint: 21)] {
            for preset in WhiteBalanceEngine.presets {
                XCTAssertEqual(name(temp: preset.kelvin, tint: preset.tint, shot: shot), preset.name)
            }
        }
    }

    /// A file with no camera neutral adapts from `Neutral.reference` (5500/0), so there
    /// a Temp-only 5500 genuinely is Flash — the panel passes the reference while the
    /// neutral is unknown, the same stand-in its Temp/Tint rows use.
    func testTheReferenceNeutralKeepsAZeroTintFallback() {
        XCTAssertEqual(name(temp: 5500, tint: nil, shot: .reference), "Flash")
        XCTAssertEqual(name(temp: nil, tint: 10, shot: .reference), "Daylight")
    }

    /// The nil field stands for the CLAMPED as-shot neutral, which is what the render
    /// adapts from and what the Tint row shows: a file reporting tint +500 renders +300.
    func testTheFallbackIsTheClampedNeutralTheRowsShow() {
        let shot = Neutral(kelvin: 4000, tint: 500)
        let shown = WhiteBalanceEngine.displayed(temp: 5500, tint: nil, asShot: shot)
        XCTAssertEqual(shown.tint, 300)
        XCTAssertEqual(name(temp: 5500, tint: nil, shot: shot), "Custom")
        let custom = [WhiteBalanceEngine.Preset(name: "Clamped", kelvin: 5500, tint: 300)]
        XCTAssertEqual(WhiteBalanceEngine.presetName(temp: 5500, tint: nil, asShot: shot,
                                                     presets: custom), "Clamped")
    }
}

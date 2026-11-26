// DraftWarmupTests.swift

import XCTest
@testable import LumenCore

final class DraftWarmupTests: XCTestCase {

    func testADefaultRecipeWarmsEveryControlEachMovedAlone() {
        let base = Recipe()
        let warm = DraftWarmup.recipes(from: base)
        XCTAssertEqual(warm.count, DraftWarmup.nudges.count)
        for recipe in warm {
            XCTAssertNotEqual(recipe, base, "a warm that moves nothing compiles nothing")
            XCTAssertEqual(recipe.decodeInputs, base.decodeInputs,
                           "a warm must never pay a RAW decode")
            XCTAssertEqual(recipe.develop.raw, base.develop.raw)
        }
    }

    func testAMovedControlIsNotWarmedAgain() {
        var moved = Recipe()
        moved.develop.tone.exposure = 1.2
        moved.develop.mixer.bands[3].hue = -10
        let names = DraftWarmup.signature(of: moved).split(separator: ",").map(String.init)
        XCTAssertFalse(names.contains("exposure"))
        XCTAssertFalse(names.contains("mixer.hue"))
        XCTAssertTrue(names.contains("saturation"))
        XCTAssertEqual(DraftWarmup.recipes(from: moved).count, DraftWarmup.nudges.count - 2)
    }

    func testTheSignatureFollowsWhatIsAtDefault() {
        var recipe = Recipe()
        let before = DraftWarmup.signature(of: recipe)
        recipe.develop.color.saturation = 30
        XCTAssertNotEqual(DraftWarmup.signature(of: recipe), before)
    }
}

// RetouchPasteTests.swift
// Paste Settings must not carry one photograph's blemish fixes onto another unless the
// photographer asks — and when it does not carry them, the target's own retouching and
// its exact bytes survive.

import XCTest
@testable import LumenCore

final class RetouchPasteTests: XCTestCase {

    private func spotted() -> Recipe {
        var recipe = Recipe()
        recipe.develop.tone.exposure = 1.25
        recipe.develop.heal.spots = [
            HealSpot(id: "a", x: 0.3, y: 0.4, sourceX: 0.35, sourceY: 0.4),
        ]
        recipe.develop.heal.strokesRef = "blob:xxh64:0123456789abcdef"
        recipe.develop.heal.count = 1
        return recipe
    }

    /// The default: the source's develop arrives, its spots and strokes do not, and a
    /// target without retouching encodes exactly as if the source had none.
    func testRetouchStaysBehindByDefault() throws {
        let source = spotted()
        var target = Recipe()
        target.develop = RetouchPaste.develop(source.develop, onto: target.develop,
                                              includingRetouch: false)
        XCTAssertEqual(target.develop.tone.exposure, 1.25, "the settings did not paste")
        XCTAssertTrue(target.develop.heal.spots.isEmpty, "a spot pasted onto another frame")
        XCTAssertNil(target.develop.heal.strokesRef, "a heal stroke pasted onto another frame")
        XCTAssertEqual(target.pipelineVersion, currentPipelineVersion,
                       "a spot-free target was stamped as a spot recipe")

        var expected = Recipe()
        expected.develop.tone.exposure = 1.25
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(target), try encoder.encode(expected))
    }

    /// Not carried also means not DELETED: the target's own dust work survives a paste
    /// that was about white balance.
    func testTheTargetKeepsItsOwnRetouching() {
        let source = spotted()
        var target = Recipe()
        let own = HealSpot(id: "own", x: 0.7, y: 0.2, sourceX: 0.72, sourceY: 0.25)
        target.develop.heal.spots = [own]
        target.develop = RetouchPaste.develop(source.develop, onto: target.develop,
                                              includingRetouch: false)
        XCTAssertEqual(target.develop.heal.spots, [own])
        XCTAssertNil(target.develop.heal.strokesRef)
        XCTAssertEqual(target.develop.tone.exposure, 1.25)
    }

    /// Opted in, retouching travels whole, and the stamp follows it.
    func testOptingInCarriesSpotsAndStrokes() {
        let source = spotted()
        var target = Recipe()
        target.develop = RetouchPaste.develop(source.develop, onto: target.develop,
                                              includingRetouch: true)
        XCTAssertEqual(target.develop.heal, source.develop.heal)
        XCTAssertEqual(target.pipelineVersion, healSpotsPipelineVersion)
    }
}

// PasteSettingsTests.swift
// Paste Settings raises the target's vocabulary with what it pastes (M-06), and keeps
// doing everything the two menu commands did before the rule moved here.

import XCTest
@testable import LumenCore

final class PasteSettingsTests: XCTestCase {

    private func source() -> Recipe {
        var source = Recipe(pipelineVersion: 2)
        source.develop.tone.exposure = 0.7
        source.look.bw = BlackAndWhite(bands: [0, 0, 0, 0, -40, -65, 0, 0], enabled: false)
        source.look.render.preset = "Portra Print"
        source.masks = [Mask(id: "m1", name: "Sky")]
        return source
    }

    func testPastingASettingsSetRaisesTheTargetsVocabulary() {
        let target = Recipe(pipelineVersion: 1)
        for includingMasks in [true, false] {
            let out = target.adoptingSettings(from: source(), includingMasks: includingMasks)
            XCTAssertEqual(out.pipelineVersion, 2,
                           "a recipe holding a switched-off B&W mix is stamped with a "
                               + "version whose readers render it as black and white")
            XCTAssertEqual(out.look.bw?.enabled, false)
        }
        // And never LOWERS a newer target's stamp.
        let newer = Recipe(pipelineVersion: 3)
        XCTAssertEqual(newer.adoptingSettings(from: source(), includingMasks: true)
                        .pipelineVersion, 3)
    }

    func testItDoesWhatTheTwoCommandsDid() {
        var target = Recipe(pipelineVersion: 1)
        target.look.render.preset = "Linear"
        target.masks = [Mask(id: "own", name: "Face")]
        let src = source()

        let all = target.adoptingSettings(from: src, includingMasks: true)
        XCTAssertEqual(all.develop, src.develop)
        XCTAssertEqual(all.masks, src.masks)
        XCTAssertEqual(all.maskGroups, src.maskGroups)
        XCTAssertEqual(all.look.render.preset,
                       LookSubset.carriedRenderPreset("Portra Print", onto: "Linear"),
                       "the target's register must be read BEFORE the look is replaced")
        XCTAssertEqual(all.look.render.preset, "Linear")

        let withoutMasks = target.adoptingSettings(from: src, includingMasks: false)
        XCTAssertEqual(withoutMasks.develop, src.develop)
        XCTAssertEqual(withoutMasks.masks, target.masks,
                       "Paste Settings Without Masks replaced this photograph's masks")
    }

    /// The two menu commands go through the rule rather than restating it.
    func testBothMenuCommandsUseTheRule() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/AppState.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = source.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.hasPrefix("//") }
        XCTAssertTrue(lines.contains(
            "recipe = recipe.adoptingSettings(from: source, includingMasks: true)"))
        XCTAssertTrue(lines.contains(
            "recipe = recipe.adoptingSettings(from: source, includingMasks: false)"))
    }
}

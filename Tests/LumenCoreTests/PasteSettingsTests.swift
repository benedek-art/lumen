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
            let out = target.adoptingSettings(from: source(), includingMasks: includingMasks,
                                              includingRetouch: false)
            XCTAssertEqual(out.pipelineVersion, 2,
                           "a recipe holding a switched-off B&W mix is stamped with a "
                               + "version whose readers render it as black and white")
            XCTAssertEqual(out.look.bw?.enabled, false)
        }
        // And never LOWERS a newer target's stamp.
        let newer = Recipe(pipelineVersion: 3)
        XCTAssertEqual(newer.adoptingSettings(from: source(), includingMasks: true,
                                              includingRetouch: false)
                        .pipelineVersion, 3)
    }

    func testItDoesWhatTheTwoCommandsDid() {
        var target = Recipe(pipelineVersion: 1)
        target.look.render.preset = "Linear"
        target.masks = [Mask(id: "own", name: "Face")]
        let src = source()

        let all = target.adoptingSettings(from: src, includingMasks: true,
                                          includingRetouch: false)
        XCTAssertEqual(all.develop, src.develop)
        XCTAssertEqual(all.masks, src.masks)
        XCTAssertEqual(all.maskGroups, src.maskGroups)
        XCTAssertEqual(all.look.render.preset,
                       LookSubset.carriedRenderPreset("Portra Print", onto: "Linear"),
                       "the target's register must be read BEFORE the look is replaced")
        XCTAssertEqual(all.look.render.preset, "Linear")

        let withoutMasks = target.adoptingSettings(from: src, includingMasks: false,
                                                   includingRetouch: false)
        XCTAssertEqual(withoutMasks.develop, src.develop)
        XCTAssertEqual(withoutMasks.masks, target.masks,
                       "Paste Settings Without Masks replaced this photograph's masks")
    }

    private func spotted() -> Recipe {
        var source = source()
        source.develop.heal.spots = [
            HealSpot(id: "a", x: 0.3, y: 0.4, sourceX: 0.35, sourceY: 0.4),
        ]
        source.develop.heal.strokesRef = "blob:xxh64:0123456789abcdef"
        source.develop.heal.count = 1
        return source
    }

    /// The retouch rule lives inside the paste rule: by default the source's spots and
    /// strokes stay behind, the target keeps its own, and - the place the two rules
    /// meet - the stamp is NOT raised to the spot version by spots that did not travel.
    /// The M-06 raise for everything else the source expresses still happens.
    func testRetouchStaysBehindAndDoesNotStampTheTarget() throws {
        let src = spotted()
        XCTAssertEqual(src.pipelineVersion, healSpotsPipelineVersion)
        for includingMasks in [true, false] {
            let out = Recipe(pipelineVersion: 1)
                .adoptingSettings(from: src, includingMasks: includingMasks,
                                  includingRetouch: false)
            XCTAssertEqual(out.develop.tone.exposure, 0.7, "the settings did not paste")
            XCTAssertTrue(out.develop.heal.spots.isEmpty, "a spot pasted onto another frame")
            XCTAssertNil(out.develop.heal.strokesRef, "a stroke pasted onto another frame")
            XCTAssertEqual(out.pipelineVersion, healSpotsPipelineVersion - 1,
                           "a spot-free target was stamped as a spot recipe, or the "
                               + "B&W vocabulary it did receive was not stamped (M-06)")
        }
        // Not carried also means not deleted: the target's own spots survive, and so
        // does the stamp they need.
        var target = Recipe(pipelineVersion: 1)
        let own = HealSpot(id: "own", x: 0.7, y: 0.2, sourceX: 0.72, sourceY: 0.25)
        target.develop.heal.spots = [own]
        let kept = target.adoptingSettings(from: src, includingMasks: true,
                                           includingRetouch: false)
        XCTAssertEqual(kept.develop.heal.spots, [own])
        XCTAssertNil(kept.develop.heal.strokesRef)
        XCTAssertEqual(kept.pipelineVersion, healSpotsPipelineVersion)
        // A newer build's stamp above the spot version is carried as it is.
        var future = spotted()
        future.pipelineVersion = healSpotsPipelineVersion + 1
        XCTAssertEqual(Recipe(pipelineVersion: 1)
                        .adoptingSettings(from: future, includingMasks: false,
                                          includingRetouch: false).pipelineVersion,
                       healSpotsPipelineVersion + 1)
    }

    /// Opted in, retouching travels whole, replacing the target's, and the stamp follows.
    func testOptingInCarriesRetouchAndItsStamp() {
        let src = spotted()
        var target = Recipe(pipelineVersion: 1)
        target.develop.heal.spots = [
            HealSpot(id: "own", x: 0.7, y: 0.2, sourceX: 0.72, sourceY: 0.25),
        ]
        for includingMasks in [true, false] {
            let out = target.adoptingSettings(from: src, includingMasks: includingMasks,
                                              includingRetouch: true)
            XCTAssertEqual(out.develop, src.develop)
            XCTAssertEqual(out.develop.heal, src.develop.heal)
            XCTAssertEqual(out.pipelineVersion, healSpotsPipelineVersion)
        }
    }

    /// The two menu commands go through the rule rather than restating it, and both
    /// hand it the session's retouch opt-in.
    func testBothMenuCommandsUseTheRule() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/AppState.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = source.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.hasPrefix("//") }
        let joined = lines.joined(separator: " ")
        XCTAssertTrue(joined.contains(
            "recipe = recipe.adoptingSettings(from: source, includingMasks: true, "
                + "includingRetouch: retouch)"))
        XCTAssertTrue(joined.contains(
            "recipe = recipe.adoptingSettings(from: source, includingMasks: false, "
                + "includingRetouch: retouch)"))
        XCTAssertEqual(lines.filter { $0 == "let retouch = pasteIncludesRetouch" }.count, 2)
    }
}

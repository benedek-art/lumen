// MaskEditTargetTests.swift
// Mask edits land on the photograph being edited, not on the whole selection.

#if os(macOS)

import XCTest
import LumenCore
@testable import LumenApp

final class MaskEditTargetTests: XCTestCase {

    @MainActor
    private func withState(_ run: (AppState, PhotoItem, PhotoItem) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-mask-targets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        defer {
            state.prepareToQuit()
            try? FileManager.default.removeItem(at: root)
        }
        let active = PhotoItem(id: root.appendingPathComponent("a.arw"), iso: 400)
        let other = PhotoItem(id: root.appendingPathComponent("b.arw"), iso: 400)
        state.primarySelection = active
        state.selection = [active.id, other.id]
        try run(state, active, other)
    }

    @MainActor
    func testAMaskEditWithTwoPhotosSelectedChangesOnlyTheActiveOne() throws {
        try withState { state, active, other in
            XCTAssertEqual(state.maskEditTargets.map(\.id), [active.id])
            let mask = Mask(name: "Sky", components: [])
            state.updateMasks { $0.masks.append(mask) }
            XCTAssertEqual(state.recipe(for: active).masks.map(\.id), [mask.id])
            XCTAssertTrue(state.recipe(for: other).masks.isEmpty,
                          "a mask made with two photos selected landed on both")

            state.updateMasks(coalescingKey: "mask.Exposure.\(mask.id)") { recipe in
                recipe.masks[0].adjust.exposure = 1
            }
            XCTAssertEqual(state.recipe(for: active).masks.first?.adjust.exposure, 1)

            state.undo()
            XCTAssertEqual(state.recipe(for: active).masks.first?.adjust.exposure, 0)
            state.undo()
            XCTAssertTrue(state.recipe(for: active).masks.isEmpty)
            XCTAssertTrue(state.recipe(for: other).masks.isEmpty)
        }
    }

    /// Every recipe write in the mask panel goes through `updateMasks`. A bare
    /// `updateRecipe` there writes `editTargets`, the whole selection.
    func testTheMaskPanelWritesOnlyThroughUpdateMasks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/LumenApp/MaskPanel.swift"), encoding: .utf8)
        let code = blankingComments(in: source)
        XCTAssertFalse(code.contains("updateRecipe("),
                       "MaskPanel writes a recipe through updateRecipe, which edits the "
                           + "whole selection")
        XCTAssertTrue(code.contains("state.updateMasks("))
    }
}

#endif

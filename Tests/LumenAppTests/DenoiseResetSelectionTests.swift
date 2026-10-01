// DenoiseResetSelectionTests.swift
// Double-clicking a Noise Reduction row on a selection of several photographs
// (W2/E1-01, the K-028 row that moved from the header Reset onto the rows).
//
// The panel resolved the reset value ONCE, from the primary selection's ISO, and wrote
// it through `binder.edit`, whose closure cannot see the photo — so every selected frame
// got the primary's number. An ISO 25600 frame in a selection led by an ISO 400 one came
// back at Luminance 0 instead of 40, with its user-set bit cleared so the recipe then
// claimed the ISO table had chosen it. The value is now resolved per photograph by
// `AppState.resetDenoise`, through the photo-aware `updateRecipe`.
//
// THE SUBSTITUTION THIS GOES RED UNDER: implement `resetDenoise` the way the panel did —
// `updateRecipe(coalescingKey:) { recipe in recipe.resetDenoise(row, from: <the
// primary's or the first target's file>) }` — and the ISO 25600 frame lands on 0.
#if os(macOS)

import XCTest
import LumenCore
@testable import LumenApp

final class DenoiseResetSelectionTests: XCTestCase {

    @MainActor
    private func withState(_ run: (AppState, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-denoise-reset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        defer {
            state.prepareToQuit()
            try? FileManager.default.removeItem(at: root)
        }
        try run(state, root)
    }

    @MainActor
    func testEachSelectedPhotoResetsToItsOwnISO() throws {
        try withState { state, root in
            let low = PhotoItem(id: root.appendingPathComponent("a.arw"), iso: 400)
            let high = PhotoItem(id: root.appendingPathComponent("b.arw"), iso: 25600)
            let both = [low, high]

            state.updateRecipe(targets: both) { _, recipe in
                recipe.develop.denoise.classic.luma = 77
                recipe.develop.denoise.classic.lumaUserSet = true
                recipe.develop.denoise.classic.colorSmoothness = 3
            }
            XCTAssertEqual(state.recipe(for: high).develop.denoise.classic.luma, 77,
                           "the fixture must actually have moved both frames")

            // `low` first, the way a selection led by the ISO 400 frame orders them.
            state.resetDenoise(.luma, targets: both)
            state.resetDenoise(.colorSmoothness, targets: both)

            let a = state.recipe(for: low).develop.denoise.classic
            let b = state.recipe(for: high).develop.denoise.classic
            let wantB = ISODefaults.startingDenoise(forISO: 25600).classic
            XCTAssertEqual(a.luma, 0)
            XCTAssertEqual(b.luma, 40,
                           "the ISO 25600 frame was reset to the ISO 400 frame's value")
            XCTAssertEqual(b.colorSmoothness, wantB.colorSmoothness, accuracy: 1e-9)
            XCTAssertNotEqual(a.colorSmoothness, b.colorSmoothness,
                              "two ISOs, two smoothness defaults — one number for both "
                                  + "is the defect")
            XCTAssertFalse(b.lumaUserSet)
        }
    }

    /// A drag and the double-click that undoes it are two decisions: one ⌘Z after the
    /// reset must give back the dragged value, not the value from before the drag.
    @MainActor
    func testTheResetIsItsOwnUndoStep() throws {
        try withState { state, root in
            let raw = PhotoItem(id: root.appendingPathComponent("c.arw"), iso: 6400)
            state.updateRecipe(coalescingKey: "denoise.classic.luma",
                               targets: [raw]) { _, recipe in
                recipe.develop.denoise.classic.luma = 61
            }
            state.resetDenoise(.luma, targets: [raw])
            state.undo()
            XCTAssertEqual(state.recipe(for: raw).develop.denoise.classic.luma, 61,
                           "the reset folded into the drag's undo step")
        }
    }
}

#endif

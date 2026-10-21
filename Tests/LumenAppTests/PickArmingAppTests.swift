// PickArmingAppTests.swift — an armed pick is bound to the photo it was armed on, and is
// never armed where the loupe draws no catcher (docs/quality/lanes/WS-02/SPEC.md C2, G1).

#if os(macOS)

import XCTest
import LumenCore
@testable import LumenApp

final class PickArmingAppTests: XCTestCase {

    @MainActor
    private func withState(_ run: (AppState, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-pick-arming-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        // The viewer singletons outlive the state; start from, and leave, the ordinary
        // loupe so no other test inherits a crop or a split.
        let viewport = LoupeViewport.shared
        func reset() {
            viewport.showCrop = false
            viewport.beforeMode = .off
            PanelLayout.shared.setMasking(false)
            PanelLayout.shared.select(.develop)
        }
        reset()
        defer {
            reset()
            state.prepareToQuit()
            try? FileManager.default.removeItem(at: root)
        }
        try await run(state, root)
    }

    @MainActor
    private func select(_ photo: PhotoItem, in state: AppState) {
        state.primarySelection = photo
        state.selection = [photo.id]
    }

    @MainActor
    func testAPickArmedOnOnePhotoNeverWritesAnother() async throws {
        try await withState { state, root in
            let a = PhotoItem(id: root.appendingPathComponent("A.arw"), iso: 400)
            let b = PhotoItem(id: root.appendingPathComponent("B.arw"), iso: 400)
            select(a, in: state)
            state.beginPick(.newPointColor)
            XCTAssertEqual(state.pickTarget, .newPointColor)

            select(b, in: state)
            let before = try CanonicalJSON.canonicalRecipeJSON(state.recipe(for: b))
            state.resolvePick(on: b, sourceX: 0.5, sourceY: 0.5, radius: 2)
            XCTAssertEqual(state.statusMessage, PickArming.Rejection.anotherPhoto.message)
            XCTAssertNil(state.pickTarget, "a refused pick stays disarmed")
            // Nothing is in flight either: give a stray Task the time it would need.
            try await Task.sleep(nanoseconds: 300_000_000)
            let after = try CanonicalJSON.canonicalRecipeJSON(state.recipe(for: b))
            XCTAssertEqual(after, before, "a pick armed on A wrote into B's recipe")
        }
    }

    /// With the crop tool armed, or a two-pane before/after up, the loupe mounts no
    /// catcher — so a pick must either be refused or have left that mode.
    @MainActor
    func testNoPickIsArmedWithoutAClickTarget() async throws {
        try await withState { state, root in
            let a = PhotoItem(id: root.appendingPathComponent("A.arw"), iso: 400)
            select(a, in: state)
            let viewport = LoupeViewport.shared

            // The crop tool, armed in its workspace.
            PanelLayout.shared.select(.crop)
            viewport.showCrop = true
            state.beginPick(.neutral)
            let cropOff = !(viewport.showCrop && PanelLayout.shared.layout.workspace == .crop)
            XCTAssertTrue(state.pickTarget == nil || cropOff,
                          "a pick armed over the crop canvas, which has no catcher")
            if state.pickTarget == nil {
                XCTAssertNotNil(state.statusMessage, "the refusal says why")
            }
            state.cancelPick()
            viewport.showCrop = false
            PanelLayout.shared.select(.develop)

            // A two-pane compare.
            viewport.beforeMode = .sideBySide
            state.beginPick(.neutral)
            XCTAssertTrue(state.pickTarget == nil || !viewport.beforeMode.isTwoPane,
                          "a pick armed over the before/after pair, which has no catcher")
            if state.pickTarget == nil {
                XCTAssertNotNil(state.statusMessage, "the refusal says why")
            }
            state.cancelPick()
            viewport.beforeMode = .off

            // And the ordinary loupe still arms.
            state.beginPick(.neutral)
            XCTAssertEqual(state.pickTarget, .neutral)
            XCTAssertEqual(state.statusMessage, PickTarget.neutral.prompt)
            state.cancelPick()
        }
    }
}

#endif

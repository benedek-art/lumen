// Four state defects that each act on the wrong photograph, plus the cost of the mask
// thumbnail key on the drag path.
//
//   · ⌘-click to DESELECT used to make the deselected photo the cursor, so P flagged
//     the photo just removed.
//   · `primaryStack` / `primaryKeywords` kept the previous photo's values until the
//     catalog reads landed, so ⇧⌘G dissolved the previous photo's stack.
//   · A folder scan's `stored` snapshot predates edits made on the still-visible old
//     roll, and `applyScan` used to install it over them.
//   · Auto Tone landing after a folder switch wrote a photo that had left the roll as
//     its bare starting recipe plus Auto's tone.
//   · The mask thumbnail key — a dozen JSON round trips — was built on the main actor
//     on every mouse event, before the debounce that throws it away.
#if os(macOS)
import AppKit
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

@MainActor
final class AppStateCursorAndScanTests: XCTestCase {

    // MARK: Harness (the shape `AuditStateSafetyTests` and
    // `SelectionMembershipWorkflowTests` use)

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(predicate(), "isolated AppState workflow did not settle")
    }

    private func withState(quitInBody: Bool = false,
                           _ run: (AppState, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-cursor-scan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let remembered = keys.map { UserDefaults.standard.object(forKey: $0) }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        defer {
            if !quitInBody { state.prepareToQuit() }
            for (key, value) in zip(keys, remembered) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        try await run(state, root)
    }

    private func png(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<6 { for x in 0..<8 { bitmap.setColor(.gray, atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
    }

    /// A folder of `count` frames, opened and scanned.
    private func openRoll(_ state: AppState, root: URL, name: String, count: Int) async throws -> [PhotoItem] {
        let folder = root.appendingPathComponent(name)
        for index in 0..<count {
            try png(folder.appendingPathComponent(String(format: "\(name)%02d.png", index)))
        }
        state.openFolder(folder)
        try await waitUntil { !state.isScanning && state.allPhotos.count == count }
        return state.allPhotos
    }

    // MARK: ⌘-click deselect

    func testNearestSelectedIndexPrefersTheFollowingFrameOnATie() {
        XCTAssertEqual(AppState.nearestSelectedIndex(to: 5, count: 10) { [3, 7].contains($0) }, 7)
        XCTAssertEqual(AppState.nearestSelectedIndex(to: 5, count: 10) { [4, 7].contains($0) }, 4)
        XCTAssertEqual(AppState.nearestSelectedIndex(to: 0, count: 3) { $0 == 2 }, 2)
        XCTAssertEqual(AppState.nearestSelectedIndex(to: 2, count: 3) { $0 == 0 }, 0)
        XCTAssertNil(AppState.nearestSelectedIndex(to: 5, count: 10) { $0 == 5 },
                     "the deselected frame itself is never the answer")
        XCTAssertNil(AppState.nearestSelectedIndex(to: 0, count: 1) { _ in true })
    }

    func testCommandClickingTheCursorOffMovesTheCursorToAStillSelectedPhoto() async throws {
        try await withState { state, root in
            let items = try await openRoll(state, root: root, name: "roll", count: 4)
            let a = items[0], b = items[1]
            state.select(a)
            state.select(b, toggling: true)
            XCTAssertEqual(state.selection, [a.id, b.id])
            state.select(b, toggling: true)
            XCTAssertEqual(state.selection, [a.id])
            XCTAssertEqual(state.primarySelection?.id, a.id,
                           "the photo just deselected became the cursor")
            XCTAssertEqual(state.editTargets.map(\.id), [a.id],
                           "a cull key would act on the photo just removed")
        }
    }

    func testCommandClickingTheOnlySelectedPhotoOffLeavesNothingToEdit() async throws {
        try await withState { state, root in
            let items = try await openRoll(state, root: root, name: "roll", count: 3)
            state.select(items[1])
            state.select(items[1], toggling: true)
            XCTAssertTrue(state.selection.isEmpty)
            XCTAssertNil(state.primarySelection,
                         "the photo just deselected stayed the cursor")
            XCTAssertTrue(state.editTargets.isEmpty,
                          "a cull key would act on the photo just removed")
        }
    }

    func testCommandClickingAnotherPhotoOffLeavesTheCursorAlone() async throws {
        try await withState { state, root in
            let items = try await openRoll(state, root: root, name: "roll", count: 4)
            let a = items[0], b = items[1], c = items[2]
            state.select(a)
            state.select(b, toggling: true)
            state.select(c, toggling: true)
            XCTAssertEqual(state.primarySelection?.id, c.id)
            state.select(a, toggling: true)
            XCTAssertEqual(state.selection, [b.id, c.id])
            XCTAssertEqual(state.primarySelection?.id, c.id)
            XCTAssertEqual(Set(state.editTargets.map(\.id)), [b.id, c.id])
        }
    }

    // MARK: The sidebar's stack follows the cursor at once

    func testPrimaryStackClearsOnASelectionChangeBeforeTheCatalogAnswers() async throws {
        try await withState { state, root in
            let items = try await openRoll(state, root: root, name: "burst", count: 3)
            state.select(items[0])
            state.select(items[1], toggling: true)
            state.stackSelection()
            try await waitUntil { state.primaryStack != nil }
            let stacked = try XCTUnwrap(items[1].catalogID ?? state.primarySelection?.catalogID)

            state.select(items[2])
            XCTAssertNil(state.primaryStack,
                         "the previous photo's stack is still the one ⇧⌘G would dissolve")
            state.unstackSelection()
            XCTAssertEqual(state.statusMessage, "That photo is not in a stack")
            let catalog = try XCTUnwrap(state.catalog)
            let stack = await catalog.stack(containing: stacked)
            XCTAssertNotNil(stack, "another photo's stack was dissolved")

            // And once the reads for the new photo land, it is still not in one.
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertNil(state.primaryStack)
        }
    }

    // MARK: Edits made while a scan is in flight

    func testScanWindowEditsAreLaidOverTheScansSnapshot() {
        let a = URL(fileURLWithPath: "/roll/a.png")
        let b = URL(fileURLWithPath: "/roll/b.png")
        let c = URL(fileURLWithPath: "/roll/c.png")
        let stale = CatalogService.StoredState(catalogID: 1, flag: .unflagged, rating: 0,
                                               label: nil, recipe: Recipe(), iso: nil)
        let stored: [URL: CatalogService.StoredState] = [a: stale, b: stale]
        var edited = Recipe()
        edited.develop.tone.exposure = 1.5
        let roll = [PhotoItem(id: a, catalogID: 1, flag: .pick, rating: 3),
                    PhotoItem(id: b, catalogID: 2, flag: .reject, rating: 1),
                    PhotoItem(id: c, catalogID: 3, flag: .pick, rating: 5)]

        let out = AppState.carryingScanWindowEdits(stored, edited: [a, c], roll: roll,
                                                   recipes: [a: edited, b: edited])
        XCTAssertEqual(out[a]?.flag, .pick)
        XCTAssertEqual(out[a]?.rating, 3)
        XCTAssertEqual(out[a]?.recipe?.develop.tone.exposure, 1.5,
                       "the edit made during the scan was replaced by the scan's snapshot")
        XCTAssertEqual(out[b]?.flag, .unflagged, "an unedited photo keeps what the scan read")
        XCTAssertEqual(out[b]?.recipe?.develop.tone.exposure, 0)
        XCTAssertNil(out[c], "a photo the scan did not find is not invented")
        XCTAssertEqual(AppState.carryingScanWindowEdits(stored, edited: [], roll: roll,
                                                        recipes: [a: edited])[a]?.flag,
                       .unflagged)
    }

    // MARK: Auto Tone landing after a folder switch

    func testAutoToneForAPhotoThatLeftTheRollWritesNothing() async throws {
        try await withState(quitInBody: true) { state, root in
            let first = try await openRoll(state, root: root, name: "a", count: 1)
            let photo = try XCTUnwrap(first.first)
            state.select(photo)
            state.updateRecipe { $0.develop.tone.exposure = 1 }
            _ = try await openRoll(state, root: root, name: "b", count: 1)

            var auto = Tone()
            auto.exposure = 3
            state.applyAutoToneSuggestions([photo.id: auto])
            XCTAssertNil(state.recipes[photo.id],
                         "Auto installed a recipe for a photo that is no longer open")
            state.prepareToQuit()
            let sidecar = try XCTUnwrap(XMPSidecar.parse(
                Data(contentsOf: photo.id.appendingPathExtension("xmp"))))
            let json = try XCTUnwrap(sidecar.recipeJSON)
            XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(json.utf8)).develop.tone.exposure,
                           1, "the old folder's sidecar was overwritten by default + Auto")
        }
    }

    // MARK: Mask thumbnails

    /// The key is built after the quiet period, off the main actor — not on every call.
    func testTheThumbnailKeyIsBuiltAfterTheDebounceNotPerCall() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let code = blankingComments(in: try String(
            contentsOf: root.appendingPathComponent("Sources/LumenApp/AppState.swift"),
            encoding: .utf8))
        let start = try XCTUnwrap(code.range(of: "func refreshMaskThumbnails() {"))
        let end = try XCTUnwrap(code.range(of: "nonisolated static func maskThumbnailKey(",
                                           range: start.upperBound..<code.endIndex))
        let body = String(code[start.upperBound..<end.lowerBound])
        let sleep = try XCTUnwrap(body.range(of: "Task.sleep("))
        let key = try XCTUnwrap(body.range(of: "AppState.maskThumbnailKey("))
        XCTAssertLessThan(sleep.lowerBound, key.lowerBound,
                          "the key is computed on every mouse event, before the debounce")
        XCTAssertTrue(body.contains("Task.detached"), "the key is built on the main actor")
    }

    func testThumbnailsStillLandWhenRefreshedRepeatedly() async throws {
        try await withState { state, root in
            let items = try await openRoll(state, root: root, name: "masked", count: 1)
            let photo = try XCTUnwrap(items.first)
            state.select(photo)
            state.updateRecipe {
                $0.masks = [Mask(id: "spot", components: [MaskComponent(op: .add, kind: .radial)])]
            }
            // Same key every time: a re-arm must not leave the thumbnails unbuilt.
            for _ in 0..<5 { state.refreshMaskThumbnails() }
            try await waitUntil { state.maskThumbnails["spot"] != nil }
        }
    }
}
#endif

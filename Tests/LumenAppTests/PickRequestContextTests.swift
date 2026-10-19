#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenApp

private actor PickSamplePause {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func stop() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForEntry() async -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !entered && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return entered
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class PickRequestContextTests: XCTestCase {
    private enum NoCatalog: Error { case fixture }

    private func withState(_ body: (AppState, [PhotoItem]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-pick-context-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        for name in ["first.PNG", "second.PNG"] {
            let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL,
                "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(writer))
        }
        let state = AppState(catalogDirectory: { throw NoCatalog.fixture }, previewDirectory: { nil })
        defer { state.prepareToQuit() }
        state.openFolder(root)
        let deadline = Date().addingTimeInterval(30)
        while state.isScanning && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(state.isScanning)
        XCTAssertEqual(state.allPhotos.count, 2)
        let photos = state.allPhotos
        state.primarySelection = try XCTUnwrap(photos.first)
        state.selection = [photos[0].id]
        try await body(state, photos)
    }

    private func suspendedPick(_ state: AppState, photo: PhotoItem, target: PickTarget)
        async throws -> (PickSamplePause, Task<Void, Never>) {
        let pause = PickSamplePause()
        state.pickResolutionBarrier = { await pause.stop() }
        state.beginPick(target)
        state.resolvePick(on: photo, sourceX: 0.5, sourceY: 0.5)
        let task = try XCTUnwrap(state.pickResolutionTask)
        let entered = await pause.waitForEntry()
        XCTAssertTrue(entered, "real renderer did not reach the post-sample barrier")
        return (pause, task)
    }

    func testUnchangedRequestStillAppliesAndOwnDisarmDoesNotInvalidateIt() async throws {
        try await withState { state, photos in
            for photo in photos { state.recipes[photo.id] = Recipe() }
            state.selection = Set(photos.map(\.id))
            let (pause, task) = try await self.suspendedPick(state, photo: photos[0], target: .newPointColor)
            XCTAssertNil(state.pickTarget)
            await pause.release(); await task.value
            for photo in photos {
                XCTAssertEqual(state.recipe(for: photo).develop.pointColors.count, 1,
                               "unchanged batch semantics must remain intact")
            }
        }
    }

    func testSamePhotoRecipeChangeCannotApplyAnOldSampleToAReorderedSwatch() async throws {
        try await withState { state, photos in
            let photo = photos[0]
            var recipe = Recipe()
            recipe.develop.pointColors = [PointColor(sample: [0.9, 0.1, 0.1]),
                                           PointColor(sample: [0.1, 0.9, 0.1])]
            state.recipes[photo.id] = recipe
            let (pause, task) = try await self.suspendedPick(state, photo: photo, target: .pointColor(index: 0))
            recipe.develop.pointColors.reverse()
            state.recipes[photo.id] = recipe
            await pause.release(); await task.value
            XCTAssertEqual(state.recipe(for: photo), recipe)
            XCTAssertTrue(state.statusMessage?.contains("Pick discarded") == true)
        }
    }

    func testSamePhotoMaskComponentReplacementCannotReceiveTheOldSample() async throws {
        try await withState { state, photos in
            let photo = photos[0]
            var recipe = Recipe()
            recipe.masks = [Mask(id: "target-mask", components: [MaskComponent(op: .add, kind: .colorRange)])]
            state.recipes[photo.id] = recipe
            state.activeMaskID = "target-mask"; state.activeComponentIndex = 0
            let (pause, task) = try await self.suspendedPick(state, photo: photo,
                target: .maskSample(maskID: "target-mask", component: 0))
            recipe.masks[0].components[0] = MaskComponent(op: .add, kind: .radial)
            state.recipes[photo.id] = recipe
            await pause.release(); await task.value
            XCTAssertEqual(state.recipe(for: photo), recipe)
        }
    }

    func testChangedBatchOrAnotherBatchMembersRecipeInvalidatesTheWholeRequest() async throws {
        for changeAnotherRecipe in [false, true] {
            try await withState { state, photos in
                for photo in photos { state.recipes[photo.id] = Recipe() }
                if changeAnotherRecipe { state.selection = Set(photos.map(\.id)) }
                let (pause, task) = try await self.suspendedPick(state, photo: photos[0], target: .newPointColor)
                if changeAnotherRecipe {
                    var other = state.recipe(for: photos[1]); other.develop.tone.exposure = 1
                    state.recipes[photos[1].id] = other
                } else {
                    state.selection = Set(photos.map(\.id))
                }
                let before = state.recipes
                await pause.release(); await task.value
                XCTAssertEqual(state.recipes, before)
            }
        }
    }

    func testNewArmOrCancellationInvalidatesOlderWorkWithoutOverwritingItsPrompt() async throws {
        for cancel in [false, true] {
            try await withState { state, photos in
                state.recipes[photos[0].id] = Recipe()
                let before = state.recipes
                let (pause, task) = try await self.suspendedPick(state, photo: photos[0], target: .newPointColor)
                if cancel { state.cancelPick() } else { state.beginPick(.mixerBand) }
                let prompt = state.statusMessage
                await pause.release(); await task.value
                XCTAssertEqual(state.recipes, before)
                XCTAssertEqual(state.statusMessage, prompt)
                XCTAssertEqual(state.pickTarget, cancel ? nil : .mixerBand)
            }
        }
    }

    func testMaskSelectionChangeInvalidatesThePendingMaskPick() async throws {
        try await withState { state, photos in
            let photo = photos[0]
            var recipe = Recipe()
            recipe.masks = [Mask(id: "target-mask", components: [MaskComponent(op: .add, kind: .colorRange)])]
            state.recipes[photo.id] = recipe
            state.activeMaskID = "target-mask"; state.activeComponentIndex = 0
            let (pause, task) = try await self.suspendedPick(state, photo: photo,
                target: .maskSample(maskID: "target-mask", component: 0))
            state.activeMaskID = "another-mask"
            await pause.release(); await task.value
            XCTAssertEqual(state.recipe(for: photo), recipe)
        }
    }
}
#endif

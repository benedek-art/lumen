#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

/// Actual guarded-apply regressions, with verbatim old callback negative controls.
/// Old-expression witnesses demonstrate the former routing defect, not acceptance.
final class HealCanvasTargetIntegrityTests: XCTestCase {
    @MainActor
    private func fixture(_ run: (AppState, PhotoItem, PhotoItem, HealSpot) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heal-target-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = [root.appendingPathComponent("a.NEF"), root.appendingPathComponent("b.NEF")]
        for url in urls { try Data([1, 2, 3, 4]).write(to: url) }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        let tool = HealTool.shared
        let selectedSpot = tool.selectedSpotID, selectedStroke = tool.selectedStrokeIndex
        let mode = tool.mode, radius = tool.radius, feather = tool.feather, opacity = tool.opacity
        let brush = tool.brush
        defer {
            state.prepareToQuit()
            tool.selectedSpotID = selectedSpot; tool.selectedStrokeIndex = selectedStroke
            tool.mode = mode; tool.radius = radius; tool.feather = feather
            tool.opacity = opacity; tool.brush = brush
            try? FileManager.default.removeItem(at: root)
        }
        let loaded = try XCTUnwrap(state.catalog).registerAndLoad(folder: root, files: urls)
        let photos = try urls.map { url -> PhotoItem in
            var photo = PhotoItem(id: url)
            photo.catalogID = try XCTUnwrap(loaded[url]?.catalogID)
            photo.sourceIdentity = SourceFileIdentity.read(url)
            return photo
        }
        let component = HealSpot(id: "shared-spot", mode: .clone, x: 0.2, y: 0.3,
                                 sourceX: 0.7, sourceY: 0.6, radius: 0.05)
        var recipe = Recipe()
        recipe.develop.heal.spots = [component]
        for photo in photos { state.recipes[photo.id] = recipe }
        state.selection = Set(urls)
        state.primarySelection = photos[0]
        try run(state, photos[0], photos[1], component)
    }


    @MainActor
    func testOldDragCallbackRetargetsCopiedSpotUUIDOnNewPrimary() throws {
        try fixture { state, a, b, original in
            var dragged = original; dragged.x = 0.4; dragged.radius = 0.09
            var bSpot = original; bSpot.y = 0.8; bSpot.radius = 0.02
            state.recipes[b.id]!.develop.heal.spots = [bSpot]
            let beforeA = state.recipe(for: a)
            let bytesA = try Data(contentsOf: a.id), bytesB = try Data(contentsOf: b.id)
            // The press/Grab was on A, but the next callback runs after selecting B.
            state.primarySelection = b
            state.updateSpot(id: dragged.id, coalescingKey: "heal.drag.\(dragged.id)",
                             label: "Move Spot") { $0 = dragged }
            XCTAssertEqual(state.recipe(for: a), beforeA)
            XCTAssertEqual(state.recipe(for: b).develop.heal.spots, [dragged])
            XCTAssertNotEqual(state.recipe(for: b).develop.heal.spots, [bSpot])
            XCTAssertEqual(Set(state.history.steps.last!.after.keys), Set([b.id]))
            XCTAssertEqual(try Data(contentsOf: a.id), bytesA)
            XCTAssertEqual(try Data(contentsOf: b.id), bytesB)
            print("HEAL-OLD-CALLBACK wrongPhotoSpotOverwrite=true sourceBytesPreserved=true")
        }
    }

    @MainActor
    func testOldBrushReleasePublishesOldPhotoPointsOnNewPrimary() throws {
        try fixture { state, a, b, _ in
            let pointsFromA = [BrushPoint(x: 0.2, y: 0.4), BrushPoint(x: 0.3, y: 0.5)]
            let beforeA = state.recipe(for: a)
            let blobs = try XCTUnwrap(state.catalog).blobs.directory
            let beforeBlobs = try FileManager.default.contentsOfDirectory(atPath: blobs.path).count
            state.primarySelection = b
            // Verbatim body of Loupe's old paint closure, with the completed A points.
            state.addHealStroke(points: pointsFromA)
            XCTAssertEqual(state.recipe(for: a), beforeA)
            let ref = try XCTUnwrap(state.recipe(for: b).develop.heal.strokesRef)
            let stored = try XCTUnwrap(state.strokeSet(ref: ref))
            XCTAssertEqual(stored.strokes.last?.points, pointsFromA)
            XCTAssertGreaterThan(try FileManager.default.contentsOfDirectory(atPath: blobs.path).count,
                                 beforeBlobs)
            XCTAssertEqual(Set(state.history.steps.last!.after.keys), Set([b.id]))
            print("HEAL-OLD-CALLBACK wrongPhotoStrokePublication=true")
        }
    }
    @MainActor
    private func refused(_ edit: HealCanvasEdit, _ context: HealCanvasEditContext,
                         _ state: AppState, _ photos: [PhotoItem],
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let recipes = photos.map { state.recipe(for: $0) }
        let sources = try photos.map { try Data(contentsOf: $0.id) }
        let blobs = try XCTUnwrap(state.catalog).blobs.directory
        let names = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        let before = state.history.steps.map(\.before), after = state.history.steps.map(\.after)
        let position = state.history.position
        XCTAssertNil(state.applyHealCanvasEdit(edit, context: context), file: file, line: line)
        XCTAssertEqual(photos.map { state.recipe(for: $0) }, recipes, file: file, line: line)
        XCTAssertEqual(try photos.map { try Data(contentsOf: $0.id) }, sources, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted(), names,
                       file: file, line: line)
        XCTAssertEqual(state.history.steps.map(\.before), before, file: file, line: line)
        XCTAssertEqual(state.history.steps.map(\.after), after, file: file, line: line)
        XCTAssertEqual(state.history.position, position, file: file, line: line)
    }

    @MainActor
    func testGuardedMovePaintAndAddCannotRetargetAnotherPrimary() throws {
        try fixture { state, a, b, spot in
            let context = HealCanvasEditContext(photo: a, recipe: state.recipe(for: a))
            state.primarySelection = b
            var moved = spot; moved.x = 0.4
            state.statusMessage = "A newer operation needs attention"
            try refused(.move(moved), context, state, [a, b])
            // No colliding spot UUID is required for either new-content path.
            state.recipes[b.id]!.develop.heal.spots = []
            try refused(.paint([BrushPoint(x: 0.2, y: 0.4)]), context, state, [a, b])
            try refused(.add(x: 0.3, y: 0.6), context, state, [a, b])
            XCTAssertEqual(state.statusMessage, "A newer operation needs attention")
        }
    }

    @MainActor
    func testUndoReplacementGeometrySourceAndMissingPayloadRefuseBeforeWrites() throws {
        try fixture { state, a, b, spot in
            let original = state.recipe(for: a)
            let context = HealCanvasEditContext(photo: a, recipe: original)
            var moved = spot; moved.x = 0.4
            state.recipes[a.id]!.develop.heal.spots = []
            try refused(.move(moved), context, state, [a, b])
            state.recipes[a.id] = original
            state.recipes[a.id]!.develop.heal.spots[0].radius = 0.12
            try refused(.move(moved), context, state, [a, b])
            state.recipes[a.id] = original
            state.recipes[a.id]!.develop.geometry.angle = 2
            try refused(.paint([BrushPoint(x: 0.2, y: 0.4)]), context, state, [a, b])
            state.recipes[a.id] = original
            state.recipes[a.id]!.develop.heal.strokesRef = "blob:xxh64:0123456789abcdef"
            let missingPayload = HealCanvasEditContext(photo: a, recipe: state.recipe(for: a))
            try refused(.paint([BrushPoint(x: 0.2, y: 0.4)]), missingPayload, state, [a, b])
            state.recipes[a.id] = original
            try refused(.paint([BrushPoint(x: .nan, y: 0.4)]), context, state, [a, b])
            try Data([5, 6, 7, 8]).write(to: a.id, options: .atomic)
            XCTAssertNotEqual(SourceFileIdentity.read(a.id), context.source)
            try refused(.move(moved), context, state, [a, b])
            XCTAssertFalse(context.isCurrent(in: state), "async refinement shares this source guard")
        }
    }

    @MainActor
    func testVerifiedMoveACKStreamAndPaintPreserveOtherSelectedPhoto() throws {
        try fixture { state, a, b, spot in
            var context = HealCanvasEditContext(photo: a, recipe: state.recipe(for: a))
            let originalB = state.recipe(for: b)
            let historyCount = state.history.steps.count
            XCTAssertNotNil(state.applyHealCanvasEdit(.move(spot), context: context))
            XCTAssertEqual(state.history.steps.count, historyCount, "no-op ACK adds no history")
            state.sliderGesture(active: true)
            var moved = spot
            for x in [0.3, 0.4, 0.5] {
                moved.x = x
                context.expected = try XCTUnwrap(state.applyHealCanvasEdit(.move(moved), context: context))
            }
            state.sliderGesture(active: false)
            XCTAssertEqual(state.history.steps.count, historyCount + 1)
            XCTAssertEqual(state.recipe(for: a).develop.heal.spots, [moved])
            let points = [BrushPoint(x: 0.2, y: 0.4), BrushPoint(x: 0.3, y: 0.5)]
            context.expected = try XCTUnwrap(state.applyHealCanvasEdit(.paint(points), context: context))
            let ref = try XCTUnwrap(context.expected.strokesRef)
            XCTAssertEqual(state.strokeSet(ref: ref)?.strokes.last?.points, points)
            XCTAssertEqual(state.recipe(for: b), originalB)
            context.expected = try XCTUnwrap(state.applyHealCanvasEdit(.add(x: 0.25, y: 0.45), context: context))
            XCTAssertEqual(context.expected.spots.count, 2)
            XCTAssertEqual(context.expected.spots.last?.x, 0.25)
            XCTAssertEqual(context.expected.spots.last?.y, 0.45)
            XCTAssertEqual(state.recipe(for: b), originalB)
            // A tool-mode change during a physical press cannot turn paint into add.
            HealTool.shared.brush.toggle()
            try refused(.add(x: 0.3, y: 0.5), context, state, [a, b])
        }
    }

    @MainActor
    func testSearchContextRefusesMovedDonorStateAndGeometryBeforeRefinement() throws {
        try fixture { state, a, _, _ in
            let recipe = state.recipe(for: a)
            let context = HealCanvasEditContext(photo: a, recipe: recipe)
            XCTAssertTrue(context.isCurrent(in: state))
            state.recipes[a.id]!.develop.heal.spots[0].x = 0.7
            XCTAssertFalse(context.isCurrent(in: state))
            state.recipes[a.id] = recipe
            state.recipes[a.id]!.develop.geometry.angle = 2
            XCTAssertFalse(context.isCurrent(in: state))
        }
    }

    @MainActor
    func testMoveRefusesNonfiniteFieldsWithoutAddingCreativeRangeClamps() throws {
        try fixture { state, a, b, original in
            let context = HealCanvasEditContext(photo: a, recipe: state.recipe(for: a))
            let fields: [WritableKeyPath<HealSpot, Double>] = [
                \.x, \.y, \.sourceX, \.sourceY, \.radius, \.feather, \.opacity]
            for field in fields {
                for bad in [Double.nan, Double.infinity, -Double.infinity] {
                    var spot = original
                    spot[keyPath: field] = bad
                    try refused(.move(spot), context, state, [a, b])
                }
            }
            // Finite saved values outside current UI soft ranges stay editable.
            var saved = original
            saved.radius = 0.4
            saved.opacity = 125
            state.recipes[a.id]!.develop.heal.spots = [saved]
            let savedContext = HealCanvasEditContext(photo: a, recipe: state.recipe(for: a))
            saved.x = 1.2
            let applied = try XCTUnwrap(state.applyHealCanvasEdit(.move(saved), context: savedContext))
            XCTAssertEqual(applied.spots, [saved])
            XCTAssertEqual(state.recipe(for: b).develop.heal.spots, [original])
        }
    }

    func testCapturedMappingRejectsChangedBasisBeforeLifecycleObservation() {
        let rect = CGRect(x: 13, y: 17, width: 500, height: 300)
        let source = CGSize(width: 6000, height: 4000)
        let mapping = HealCanvasMapping(imageRect: rect, sourceSize: source)
        XCTAssertTrue(mapping.accepts(imageRect: rect, sourceSize: source))
        XCTAssertFalse(mapping.accepts(imageRect: rect.offsetBy(dx: 1, dy: 0), sourceSize: source))
        XCTAssertFalse(mapping.accepts(imageRect: CGRect(x: 13, y: 17, width: 501, height: 300),
                                       sourceSize: source))
        XCTAssertFalse(mapping.accepts(imageRect: rect, sourceSize: CGSize(width: 6000, height: 4001)))
        XCTAssertFalse(mapping.accepts(imageRect: rect, sourceSize: CGSize(width: 4000, height: 6000)))
        // No onChange/onDisappear callback or event-loop turn is involved.
        XCTAssertTrue(mapping.accepts(imageRect: rect, sourceSize: source))
    }

}
#endif

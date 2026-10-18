#if os(macOS)
import Foundation
import Dispatch
import XCTest
import LumenCore
@testable import LumenApp

final class MaskCanvasTargetIntegrityTests: XCTestCase {
    @MainActor
    private func fixture(_ run: (AppState, PhotoItem, PhotoItem, MaskComponent) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mask-target-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let urls = [root.appendingPathComponent("a.NEF"), root.appendingPathComponent("b.NEF")]
        for url in urls { try Data([1, 2, 3, 4]).write(to: url) }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        defer { state.prepareToQuit(); try? FileManager.default.removeItem(at: root) }
        let loaded = try XCTUnwrap(state.catalog).registerAndLoad(folder: root, files: urls)
        let photos = try urls.map { url -> PhotoItem in
            var photo = PhotoItem(id: url)
            photo.catalogID = try XCTUnwrap(loaded[url]?.catalogID)
            photo.sourceIdentity = SourceFileIdentity.read(url)
            return photo
        }
        var component = MaskComponent(op: .add, kind: .brush)
        component.amount = 87
        var recipe = Recipe()
        // The same UUID/index on a copied recipe is intentional and realistic.
        recipe.masks = [Mask(id: "shared-mask", components: [component])]
        for photo in photos { state.recipes[photo.id] = recipe }
        state.selection = Set(urls)
        state.primarySelection = photos[0]
        state.activeMaskID = "shared-mask"
        state.activeComponentIndex = 0
        try run(state, photos[0], photos[1], component)
    }

    @MainActor
    private func context(_ state: AppState, _ photo: PhotoItem, _ component: MaskComponent) -> MaskCanvasEditContext {
        MaskCanvasEditContext(photo: photo, geometry: state.recipe(for: photo).develop.geometry,
                              maskID: "shared-mask", index: 0, component: component)
    }

    private func painting() throws -> MaskCanvasEdit {
        let set = BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.2, y: 0.7)], size: 0.13)])
        let payload = try set.encode()
        return .strokes(maskID: "shared-mask", index: 0, strokes: set,
                        ref: BrushStrokeSet.blobRef(for: payload), payload: payload)
    }

    @MainActor
    private func refused(_ edit: MaskCanvasEdit, _ context: MaskCanvasEditContext,
                         _ state: AppState, _ photos: [PhotoItem],
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let recipes = photos.map { state.recipe(for: $0) }
        let bytes = try photos.map { try Data(contentsOf: $0.id) }
        let blobs = try XCTUnwrap(state.catalog).blobs.directory
        let blobNames = try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted()
        let before = state.history.steps.map(\.before)
        let after = state.history.steps.map(\.after)
        let position = state.history.position
        XCTAssertFalse(MaskCanvas.apply(edit, context: context, in: state), file: file, line: line)
        XCTAssertEqual(photos.map { state.recipe(for: $0) }, recipes, file: file, line: line)
        XCTAssertEqual(try photos.map { try Data(contentsOf: $0.id) }, bytes, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blobs.path).sorted(), blobNames,
                       file: file, line: line)
        XCTAssertEqual(state.history.steps.map(\.before), before, file: file, line: line)
        XCTAssertEqual(state.history.steps.map(\.after), after, file: file, line: line)
        XCTAssertEqual(state.history.position, position, file: file, line: line)
    }

    @MainActor
    func testStaleSameUUIDPhotoCannotRetargetOrPublishBrushBlob() throws {
        try fixture { state, a, b, component in
            let press = context(state, a, component)
            state.primarySelection = b
            state.statusMessage = nil
            try refused(painting(), press, state, [a, b])
            XCTAssertEqual(state.statusMessage, "Mask gesture cancelled because its photograph changed")
            state.statusMessage = "A newer operation needs attention"
            var changed = component; changed.amount = 12
            try refused(.component(maskID: "shared-mask", index: 0, component: changed,
                                   coalescingKey: "mask-drag"), press, state, [a, b])
            XCTAssertEqual(state.statusMessage, "A newer operation needs attention")
        }
    }

    @MainActor
    func testRemovedAndReplacedComponentRefuseBeforeBlobAndHistory() throws {
        try fixture { state, a, b, component in
            let press = context(state, a, component)
            state.recipes[a.id]!.masks[0].components = []
            try refused(painting(), press, state, [a, b])
            var replacement = component; replacement.kind = .radial
            state.recipes[a.id]!.masks[0].components = [replacement]
            try refused(painting(), press, state, [a, b])
        }
    }

    @MainActor
    func testGeometrySourceAndSelectedComponentChangesRefuse() throws {
        try fixture { state, a, b, component in
            let press = context(state, a, component)
            state.activeComponentIndex = 1
            try refused(painting(), press, state, [a, b])
            state.activeComponentIndex = 0
            let original = state.recipes[a.id]!
            state.recipes[a.id]!.develop.geometry.angle = 2
            try refused(painting(), press, state, [a, b])
            state.recipes[a.id] = original
            // Atomic replacement changes the cheap source-generation token.
            try Data([5, 6, 7, 8]).write(to: a.id, options: .atomic)
            XCTAssertNotEqual(SourceFileIdentity.read(a.id), press.source)
            try refused(painting(), press, state, [a, b])
        }
    }

    @MainActor
    func testAcknowledgedStreamAdvancesExpectedComponentAndOnlyPrimaryChanges() throws {
        try fixture { state, a, b, component in
            var press = context(state, a, component)
            var next = component; next.amount = 51
            let first = MaskCanvasEdit.component(maskID: "shared-mask", index: 0, component: next,
                                                 coalescingKey: "mask-drag")
            XCTAssertTrue(MaskCanvas.apply(first, context: press, in: state))
            press.acknowledge(first)
            next.amount = 37
            let second = MaskCanvasEdit.component(maskID: "shared-mask", index: 0, component: next,
                                                  coalescingKey: "mask-drag")
            XCTAssertTrue(MaskCanvas.apply(second, context: press, in: state))
            press.acknowledge(second)
            XCTAssertEqual(state.recipe(for: a).masks[0].components[0], next)
            XCTAssertEqual(state.recipe(for: b).masks[0].components[0], component)
            // An edit from elsewhere must not be mistaken for our acknowledged stream.
            state.recipes[a.id]!.masks[0].components[0].amount = 63
            try refused(painting(), press, state, [a, b])
            press = context(state, a, state.recipe(for: a).masks[0].components[0])
            let edit = try painting()
            XCTAssertTrue(MaskCanvas.apply(edit, context: press, in: state))
            press.acknowledge(edit)
            XCTAssertEqual(state.recipe(for: a).masks[0].components[0], press.expected)
            XCTAssertEqual(state.recipe(for: b).masks[0].components[0], component)
        }
    }
    @MainActor
    func testGeneratedGradientStreamAcknowledges120EventsWithOneHistoryStep() throws {
        try fixture { state, a, b, original in
            var component = original
            component.kind = .linear
            component.line = [0.1, 0.2, 0.9, 0.2]
            state.recipes[a.id]!.masks[0].components[0] = component
            var press = context(state, a, component)
            let historyCount = state.history.steps.count
            // A real no-op is a successful ACK without a new history entry.
            let noOp = MaskCanvasEdit.component(maskID: "shared-mask", index: 0,
                component: component, coalescingKey: "generated-gradient")
            XCTAssertTrue(MaskCanvas.apply(noOp, context: press, in: state))
            XCTAssertEqual(state.history.steps.count, historyCount)
            let beforeB = state.recipe(for: b)
            let bytes = try Data(contentsOf: a.id)
            var milliseconds: [Double] = []
            var accepted = 0
            state.sliderGesture(active: true)
            for sample in 1...120 {
                component.line = [0.1, 0.2 + Double(sample) / 1000, 0.9, 0.2]
                let edit = MaskCanvasEdit.component(maskID: "shared-mask", index: 0,
                    component: component, coalescingKey: "generated-gradient")
                let start = DispatchTime.now().uptimeNanoseconds
                if MaskCanvas.apply(edit, context: press, in: state) {
                    press.acknowledge(edit)
                    accepted += 1
                }
                milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            state.sliderGesture(active: false)
            XCTAssertEqual(accepted, 120)
            XCTAssertEqual(state.history.steps.count, historyCount + 1)
            XCTAssertEqual(state.recipe(for: a).masks[0].components[0], component)
            XCTAssertEqual(state.recipe(for: b), beforeB)
            XCTAssertEqual(try Data(contentsOf: a.id), bytes)
            let sorted = milliseconds.sorted()
            let report: [String] = ["MASK-CANVAS-STREAM", "events=120", "accepted=\(accepted)",
                "p50Ms=\(sorted[59])", "p95Ms=\(sorted[113])", "maxMs=\(sorted[119])",
                "scope=generated-local-file-apply-and-ack", "releaseFlushExcluded=true"]
            print(report.joined(separator: " "))
        }
    }

    func testCapturedMaskMappingRefusesChangedBasisWithoutLifecycleCallbacks() {
        let rect = CGRect(x: 13, y: 17, width: 500, height: 300)
        let source = CGSize(width: 6000, height: 4000)
        let mapping = MaskCanvasMapping(imageRect: rect, sourceSize: source)
        XCTAssertTrue(mapping.accepts(imageRect: rect, sourceSize: source))
        XCTAssertFalse(mapping.accepts(imageRect: rect.offsetBy(dx: 0, dy: 1), sourceSize: source))
        XCTAssertFalse(mapping.accepts(imageRect: CGRect(x: 13, y: 17, width: 500, height: 301),
                                       sourceSize: source))
        XCTAssertFalse(mapping.accepts(imageRect: rect, sourceSize: CGSize(width: 6001, height: 4000)))
        XCTAssertFalse(mapping.accepts(imageRect: rect, sourceSize: CGSize(width: 4000, height: 6000)))
        XCTAssertTrue(mapping.accepts(imageRect: rect, sourceSize: source))
    }

    /// Source wiring contract, not native event delivery acceptance. The actual
    /// mapping method above is the mathematical comparison this wiring must invoke.
    func testChangedEndedAndCommitCallbacksCheckCapturedMaskMappingSynchronously() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/LumenApp/MaskCanvas.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("pressMapping?.accepts(imageRect: imageRect, sourceSize: sourceSize) == true"))
        XCTAssertTrue(source.contains("pressMapping = MaskCanvasMapping(imageRect: imageRect, sourceSize: sourceSize)"))
        XCTAssertTrue(source.contains(".onChanged { value in\n                guard continuePress() else { return }"))
        XCTAssertTrue(source.contains(".onEnded { value in\n                defer { finishPress() }\n                guard continuePress() else { return }"))
        XCTAssertTrue(source.contains("guard continuePress(), var context = pressContext else { return }"))
    }

}
#endif

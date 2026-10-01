#if os(macOS)
import XCTest
@testable import LumenCore
@testable import LumenApp

/// The mask rows' thumbnails are keyed on what they are a picture of. Two terms were
/// missing: the file's identity (a same-path replacement kept every stale thumbnail
/// until the next mask edit) and which stroke sets had loaded (a brush mask rendered
/// before its blob arrived stayed an empty picture).
final class MaskThumbnailKeyTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/lumen-thumbnail-key.tif")

    private func recipe() -> Recipe {
        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "blob:thumbnail-key"
        var r = Recipe()
        r.masks = [Mask(id: "painted", components: [brush])]
        return r
    }

    func testAReplacedFileIsADifferentThumbnail() {
        let before = AppState.maskThumbnailKey(url: url, recipe: recipe(),
                                               sourceIdentity: SourceFileIdentity(token: "1:2:300:4:5:6:7"),
                                               strokeSets: [:])
        let after = AppState.maskThumbnailKey(url: url, recipe: recipe(),
                                              sourceIdentity: SourceFileIdentity(token: "1:2:300:4:5:6:9"),
                                              strokeSets: [:])
        XCTAssertNotEqual(before, after, "same path, same recipe, new bytes")
        let again = AppState.maskThumbnailKey(url: url, recipe: recipe(),
                                              sourceIdentity: SourceFileIdentity(token: "1:2:300:4:5:6:9"),
                                              strokeSets: [:])
        XCTAssertEqual(after, again, "an unchanged file must keep hitting")
    }

    func testStrokesArrivingIsADifferentThumbnail() {
        let identity = SourceFileIdentity(token: "1:2:300:4:5:6:7")
        let empty = AppState.maskThumbnailKey(url: url, recipe: recipe(),
                                              sourceIdentity: identity, strokeSets: [:])
        let set = BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.5, y: 0.5)],
                                                       size: 0.1, feather: 50, flow: 100,
                                                       density: 100, automask: false)])
        let loaded = AppState.maskThumbnailKey(url: url, recipe: recipe(),
                                               sourceIdentity: identity,
                                               strokeSets: ["blob:thumbnail-key": set])
        XCTAssertNotEqual(empty, loaded, "the blob arriving must re-render the row")
    }

    func testRenamingAMaskIsTheSameThumbnail() {
        let identity = SourceFileIdentity(token: "1:2:300:4:5:6:7")
        var renamed = recipe()
        renamed.masks[0].name = "Sky"
        XCTAssertEqual(AppState.maskThumbnailKey(url: url, recipe: recipe(),
                                                 sourceIdentity: identity, strokeSets: [:]),
                       AppState.maskThumbnailKey(url: url, recipe: renamed,
                                                 sourceIdentity: identity, strokeSets: [:]))
    }
}
#endif

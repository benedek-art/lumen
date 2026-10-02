#if os(macOS)
import XCTest
@testable import LumenCore
@testable import LumenApp

/// The loupe overlay's non-recipe inputs, keyed the way `MaskThumbnailKeyTests` keys the
/// thumbnails: a same-path replacement and a stroke blob arriving must each be a
/// different key, and nothing else that stays the same may be.
final class MaskOverlaySourceKeyTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/lumen-overlay-key.tif")

    private func recipe() -> Recipe {
        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "blob:overlay-key"
        var r = Recipe()
        r.masks = [Mask(id: "painted", components: [brush])]
        return r
    }

    private func key(_ token: String, strokes: [String: BrushStrokeSet] = [:],
                     mask: String = "painted") -> String {
        AppState.maskOverlaySourceKey(url: url, maskID: mask, recipe: recipe(),
                                      sourceIdentity: SourceFileIdentity(token: token),
                                      strokeSets: strokes)
    }

    func testAReplacedFileIsADifferentOverlay() {
        XCTAssertNotEqual(key("1:2:300:4:5:6:7"), key("1:2:300:4:5:6:9"),
                          "same path, same recipe, new bytes")
        XCTAssertEqual(key("1:2:300:4:5:6:9"), key("1:2:300:4:5:6:9"),
                       "an unchanged file must not re-rasterize")
    }

    func testStrokesArrivingIsADifferentOverlay() {
        let set = BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.5, y: 0.5)],
                                                       size: 0.1, feather: 50, flow: 100,
                                                       density: 100, automask: false)])
        XCTAssertNotEqual(key("1:2:300:4:5:6:7"),
                          key("1:2:300:4:5:6:7", strokes: ["blob:overlay-key": set]),
                          "the blob arriving must re-rasterize the overlay")
    }

    func testAnotherMaskIsADifferentOverlay() {
        XCTAssertNotEqual(key("1:2:300:4:5:6:7", mask: "painted"),
                          key("1:2:300:4:5:6:7", mask: "other"))
    }
}
#endif

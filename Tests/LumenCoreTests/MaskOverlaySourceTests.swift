// The loupe's mask overlay had the same same-path staleness 151d6d5 fixed for the mask
// thumbnails: `refreshMaskOverlay` runs on every edit and selection change, and on
// nothing else, so a photograph replaced at the same path (noticed by a rescan) and a
// brush mask whose stroke blob arrived after the first raster both kept showing the old
// selection until the next edit. Both triggers now ask `refreshMaskOverlayIfSourceChanged`,
// which compares a key of the overlay's non-recipe inputs against the one the last
// raster was asked for.
//
// `AppState` is LumenApp and compiles only on macOS; the key's semantics are tested in
// LumenAppTests (`MaskOverlaySourceKeyTests`). This pins the wiring on every lane.
import XCTest

final class MaskOverlaySourceTests: XCTestCase {

    func testARescanAndAStrokeArrivalBothReconsiderTheOverlay() throws {
        let code = try ShellSource.code("Sources/LumenApp/AppState.swift")
        let scan = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "private func applyScan(", in: code),
            "applyScan is gone or renamed; re-point this pin"))
        XCTAssertTrue(scan.contains("refreshMaskOverlayIfSourceChanged()"),
                      "a rescan that notices new bytes at the same path leaves the overlay "
                          + "showing the old file's selection")
        let strokes = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "func loadStrokeSets(for recipe: Recipe)", in: code),
            "loadStrokeSets is gone or renamed; re-point this pin"))
        XCTAssertTrue(strokes.contains("refreshMaskOverlayIfSourceChanged()"),
                      "a stroke blob arriving after the first raster leaves a brush mask's "
                          + "overlay empty")
    }

    /// The check compares against what the last raster was asked FOR, so the refresh
    /// itself must record it, and the check must refresh only on a difference.
    func testTheCheckComparesAgainstWhatTheLastRefreshRecorded() throws {
        let code = try ShellSource.code("Sources/LumenApp/AppState.swift")
        let refresh = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "func refreshMaskOverlay()", in: code)))
        XCTAssertTrue(refresh.contains("maskOverlaySource = Self.maskOverlaySourceKey("),
                      "the refresh must record the key it rasterized from")
        XCTAssertTrue(refresh.contains("maskOverlaySource = nil"),
                      "no overlay up, nothing recorded")
        let check = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "func refreshMaskOverlayIfSourceChanged()", in: code)))
        XCTAssertTrue(check.contains("sourceIdentity: SourceFileIdentity.read(photo.id)"))
        XCTAssertTrue(check.contains("strokeSets: strokeSets(for: recipe)"))
        XCTAssertTrue(check.contains("guard key != maskOverlaySource else { return }"),
                      "an unchanged file and unchanged strokes must cost no raster")
        XCTAssertTrue(check.contains("refreshMaskOverlay()"))
    }
}

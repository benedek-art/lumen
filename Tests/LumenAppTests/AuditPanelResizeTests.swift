#if os(macOS)
import XCTest
@testable import LumenApp

final class AuditPanelResizeTests: XCTestCase {
    func testCumulativeTranslationDoesNotAccumulateAcrossEvents() {
        var drag = PanelResizeDrag()
        var width: CGFloat = 400
        let translations: [CGFloat] = [-10, -20, -20, -30]
        for translation in translations {
            width = drag.width(current: width, translation: translation, minimum: 320, maximum: 600)
            XCTAssertEqual(width, 400 - translation)
        }
        width = drag.width(current: width, translation: 0, minimum: 320, maximum: 600)
        XCTAssertEqual(width, 400, "Returning the pointer to the start restores the starting width")
    }

    func testLimitDoesNotChangeOriginAndNextGestureStartsFresh() {
        var drag = PanelResizeDrag()
        var width = drag.width(current: 400, translation: -400, minimum: 320, maximum: 600)
        XCTAssertEqual(width, 600)
        width = drag.width(current: width, translation: -10, minimum: 320, maximum: 600)
        XCTAssertEqual(width, 410)
        drag.end()
        width = drag.width(current: 500, translation: 20, minimum: 320, maximum: 600)
        XCTAssertEqual(width, 480)
        drag.end()
        XCTAssertEqual(drag.width(current: 400, translation: 200, minimum: 320, maximum: 600), 320)
    }

    /// The anchored arithmetic is only right in a frame that does not move with the
    /// handle. In the handle's local space the reported translation is the pointer's
    /// travel minus the handle's own displacement, so a held pointer alternates.
    func testAnchoredWidthInTheHandlesLocalSpaceOscillates() {
        var drag = PanelResizeDrag()
        var width: CGFloat = 400
        var widths: [CGFloat] = []
        for _ in 0..<4 {
            // Pointer held 10 pt left of where it started; the handle has moved left
            // by (width - 400), so local translation = -10 + (width - 400).
            let local = -10 + (width - 400)
            width = drag.width(current: width, translation: local, minimum: 320, maximum: 600)
            widths.append(width)
        }
        XCTAssertEqual(widths, [410, 400, 410, 400],
                       "documents why the gesture must be measured in a fixed space")
    }

    func testResizeGestureIsMeasuredInAFixedCoordinateSpace() throws {
        let source = try LayoutSource.read("Sources/LumenApp/ContentView.swift")
            .replacingOccurrences(of: "(?m)^\\s*//[^\\n]*", with: "", options: .regularExpression)
        let start = try XCTUnwrap(source.range(of: "private var columnResizer"))
        let end = try XCTUnwrap(source.range(of: "panelResizeDrag.width(", range: start.upperBound..<source.endIndex))
        let resizer = source[start.upperBound..<end.lowerBound]
        XCTAssertTrue(resizer.contains("DragGesture(minimumDistance: 0, coordinateSpace: .global)"),
                      "UX-02: a start-anchored resize measured in the moving handle's local space oscillates")
    }
}
#endif

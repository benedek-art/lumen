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
}
#endif

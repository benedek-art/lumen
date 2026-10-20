// The split and the `\` flip draw the before frame at the after frame's extent. A
// before still carrying an older crop or straighten must not be drawn there, or it is
// stretched non-uniformly until its own re-render lands.
#if os(macOS)

import CoreGraphics
import XCTest
@testable import LumenApp

final class BeforePlateTests: XCTestCase {

    func testABeforeOfTheOldFramingIsNotDrawnIntoACroppedAfter() {
        // 3:2 uncropped before, 4:5 cropped after.
        XCTAssertFalse(BeforePlate.isPresentable(before: CGSize(width: 1536, height: 1024),
                                                 afterFrame: CGSize(width: 1024, height: 1280)))
        // A straighten's crop-to-fit changes the aspect by a few percent.
        XCTAssertFalse(BeforePlate.isPresentable(before: CGSize(width: 1536, height: 1024),
                                                 afterFrame: CGSize(width: 1536, height: 1080)))
    }

    func testTheSameFramingAtADifferentSizeIsPresentable() {
        XCTAssertTrue(BeforePlate.isPresentable(before: CGSize(width: 1536, height: 1024),
                                                afterFrame: CGSize(width: 4608, height: 3072)))
        // Pixel rounding of two renders at different long edges.
        XCTAssertTrue(BeforePlate.isPresentable(before: CGSize(width: 512, height: 341),
                                                afterFrame: CGSize(width: 6000, height: 4000)))
    }

    func testAnEmptyExtentIsNeverPresentable() {
        XCTAssertFalse(BeforePlate.isPresentable(before: .zero,
                                                 afterFrame: CGSize(width: 10, height: 10)))
        XCTAssertFalse(BeforePlate.isPresentable(before: CGSize(width: 10, height: 10),
                                                 afterFrame: CGSize(width: 10, height: 0)))
    }
}
#endif

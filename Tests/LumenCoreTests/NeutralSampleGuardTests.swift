import XCTest
@testable import LumenCore

/// The neutral eyedropper's refusal of samples it cannot solve honestly
/// (docs/quality/lanes/WS-02/SPEC.md E1): too dark to be anything but noise, or clipped.
final class NeutralSampleGuardTests: XCTestCase {

    /// A grey whose Rec.2020 luminance is exactly `y` (R = G = B, and the weights sum to 1).
    private func grey(_ y: Double) -> RGB { RGB(y, y, y) }

    func testDarkFloor() {
        XCTAssertEqual(WhiteBalanceEngine.neutralSampleRefusal(mean: grey(0.0019),
                                                               windowMax: grey(0.0025)),
                       .tooDark)
        XCTAssertNil(WhiteBalanceEngine.neutralSampleRefusal(mean: grey(0.0021),
                                                             windowMax: grey(0.0025)))
    }

    func testClipLevel() {
        XCTAssertEqual(WhiteBalanceEngine.neutralSampleRefusal(mean: grey(0.5),
                                                               windowMax: RGB(0.2, 0.951, 0.3)),
                       .clipped)
        XCTAssertNil(WhiteBalanceEngine.neutralSampleRefusal(mean: grey(0.5),
                                                             windowMax: RGB(0.949, 0.949, 0.949)))
        XCTAssertEqual(WhiteBalanceEngine.neutralSampleRefusal(mean: grey(0.5),
                                                               windowMax: RGB(1.9, 0.5, 0.5),
                                                               clipLevel: 2.0),
                       .clipped)
        // Clipped wins over dark: a dark window with one blown speck is still clipped.
        XCTAssertEqual(WhiteBalanceEngine.neutralSampleRefusal(mean: grey(0.001),
                                                               windowMax: grey(0.99)),
                       .clipped)
    }

    func testZeroOrNegativeChannelIsTooDark() {
        for mean in [RGB(0, 0.4, 0.4), RGB(0.4, 0, 0.4), RGB(0.4, 0.4, 0),
                     RGB(-0.01, 0.4, 0.4), RGB(0.4, 0.4, -0.2), RGB(0, 0, 0)] {
            XCTAssertEqual(WhiteBalanceEngine.neutralSampleRefusal(mean: mean,
                                                                   windowMax: grey(0.5)),
                           .tooDark, "\(mean)")
        }
    }

    func testAGreyCardIsAccepted() {
        XCTAssertNil(WhiteBalanceEngine.neutralSampleRefusal(mean: grey(0.18),
                                                             windowMax: grey(0.2)))
        XCTAssertNil(WhiteBalanceEngine.neutralSampleRefusal(mean: RGB(0.2, 0.18, 0.15),
                                                             windowMax: RGB(0.22, 0.2, 0.17)))
    }

    func testTheTwoMessagesDiffer() {
        let messages = NeutralSampleRefusal.allCases.map(\.message)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(Set(messages).count, 2)
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    }
}

#if os(macOS)
import XCTest
import LumenCore
@testable import LumenApp

final class MaskWhiteBalanceAvailabilityTests: XCTestCase {
    func testUnknownAsShotCannotSeedAbsoluteModeFromFabricatedReference() {
        XCTAssertFalse(MaskPanel.canSeedAbsoluteWhiteBalance(temp: nil, tint: nil, asShot: nil))
    }

    func testKnownAsShotCanSeedAbsoluteMode() {
        XCTAssertTrue(MaskPanel.canSeedAbsoluteWhiteBalance(
            temp: nil, tint: nil, asShot: .init(kelvin: 3200, tint: -12)))
    }

    func testOnlyCompleteGlobalOverrideCanSeedBeforeAsShotArrives() {
        XCTAssertFalse(MaskPanel.canSeedAbsoluteWhiteBalance(temp: 4500, tint: nil, asShot: nil))
        XCTAssertFalse(MaskPanel.canSeedAbsoluteWhiteBalance(temp: nil, tint: 8, asShot: nil))
        XCTAssertTrue(MaskPanel.canSeedAbsoluteWhiteBalance(temp: 4500, tint: 8, asShot: nil))
    }
}
#endif

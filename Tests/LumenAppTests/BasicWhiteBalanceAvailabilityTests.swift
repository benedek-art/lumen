#if os(macOS)
import XCTest
import LumenCore
@testable import LumenApp

final class BasicWhiteBalanceAvailabilityTests: XCTestCase {
    func testEachDimensionNeedsItsOverrideOrKnownCameraNeutral() {
        XCTAssertFalse(BasicPanel.whiteBalanceDimensionIsAvailable(value: nil, asShot: nil))
        XCTAssertTrue(BasicPanel.whiteBalanceDimensionIsAvailable(value: 4500, asShot: nil))
        XCTAssertTrue(BasicPanel.whiteBalanceDimensionIsAvailable(
            value: nil, asShot: .init(kelvin: 3200, tint: -12)))
    }

    func testPartialOverridesDoNotAuthorizeTheOtherDimension() {
        let temperature: Double? = 4500
        let tint: Double? = nil
        XCTAssertTrue(BasicPanel.whiteBalanceDimensionIsAvailable(value: temperature, asShot: nil))
        XCTAssertFalse(BasicPanel.whiteBalanceDimensionIsAvailable(value: tint, asShot: nil))
        XCTAssertFalse(BasicPanel.whiteBalanceDimensionIsAvailable(value: nil, asShot: nil))
        XCTAssertTrue(BasicPanel.whiteBalanceDimensionIsAvailable(value: 8, asShot: nil))
    }

    func testBindingRechecksAvailabilityAtWriteInsteadOfTrustingDrawTime() {
        var current: Double? = 4500
        var asShot: WhiteBalanceEngine.Neutral? = nil
        var writes: [Double] = []
        let binding = BasicPanel.guardedWhiteBalanceBinding(
            current: { current }, asShot: { asShot }, displayed: { asShot?.kelvin ?? 5500 },
            write: { writes.append($0) })
        current = nil
        binding.wrappedValue = 5550
        XCTAssertTrue(writes.isEmpty, "A stale row must not write its fabricated reference value")
        asShot = .init(kelvin: 3200, tint: -12)
        binding.wrappedValue = 3250
        XCTAssertEqual(writes, [3250])
        asShot = nil
        current = 4500
        binding.wrappedValue = 4550
        XCTAssertEqual(writes, [3250, 4550])
    }

    func testExistingBindingReadsFreshCameraNeutralWithoutRowReconstruction() {
        var current: Double? = nil
        var asShot: WhiteBalanceEngine.Neutral? = nil
        let binding = BasicPanel.guardedWhiteBalanceBinding(
            current: { current }, asShot: { asShot },
            displayed: { asShot?.kelvin ?? 5500 }, write: { _ in })
        XCTAssertEqual(binding.wrappedValue, 5500)
        asShot = .init(kelvin: 3200, tint: -12)
        XCTAssertEqual(binding.wrappedValue, 3200,
                       "Metadata must replace the old reference fallback on the same binding")
        current = 4500
        XCTAssertEqual(binding.wrappedValue, 4500)
        asShot = .init(kelvin: 4200, tint: 6)
        XCTAssertEqual(binding.wrappedValue, 4500, "Explicit overrides keep priority")
    }

    func testExistingTintBindingReadsFreshCameraTint() {
        var asShot: WhiteBalanceEngine.Neutral? = nil
        let binding = BasicPanel.guardedWhiteBalanceBinding(
            current: { nil }, asShot: { asShot },
            displayed: { asShot?.tint ?? 0 }, write: { _ in })
        XCTAssertEqual(binding.wrappedValue, 0)
        asShot = .init(kelvin: 3200, tint: -12)
        XCTAssertEqual(binding.wrappedValue, -12)
    }

}
#endif

#if os(macOS)
import Foundation
import XCTest
@testable import LumenApp

final class SliderNumericEntrySessionTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/fixture/a.raw")
    private let b = URL(fileURLWithPath: "/fixture/b.raw")

    func testSwitchingPhotosWithIdenticalDisplayedValuesCannotSubmitOldEntry() {
        let from = SliderEditContext(primary: a, selection: [a])
        let to = SliderEditContext(primary: b, selection: [b])
        let pending = SliderNumericEntrySession(context: from, initialValue: 0)
        XCTAssertEqual(pending.resolved("2", context: from, currentValue: 0, range: -5...5), 2)
        XCTAssertNil(pending.resolved("2", context: to, currentValue: 0, range: -5...5))
    }

    func testChangingBatchTargetsWithSamePrimaryCannotReceivePendingEntry() {
        let from = SliderEditContext(primary: a, selection: [a])
        let pending = SliderNumericEntrySession(context: from, initialValue: 0)
        XCTAssertNil(pending.resolved("1", context: SliderEditContext(primary: a, selection: [a, b]),
                                      currentValue: 0, range: -5...5))
    }

    func testSwitchingMasksOrComponentsOrSwatchesRejectsSameValueEntry() {
        let from = SliderEditContext(primary: a, selection: [a], maskID: "mask-a",
                                     componentIndex: 0, swatchIndex: 0)
        let pending = SliderNumericEntrySession(context: from, initialValue: 0)
        var changedMask = from; changedMask.maskID = "mask-b"
        var changedComponent = from; changedComponent.componentIndex = 1
        var changedSwatch = from; changedSwatch.swatchIndex = 1
        for changed in [changedMask, changedComponent, changedSwatch] {
            XCTAssertNil(pending.resolved("25", context: changed, currentValue: 0, range: -100...100))
        }
        XCTAssertEqual(pending.resolved("25", context: from, currentValue: 0, range: -100...100), 25)
    }

    func testSwitchingMixerBandOrAllBandsRejectsSameValueEntry() {
        let from = SliderEditContext(primary: a, selection: [a],
                                     mixerBand: 0, mixerAllBands: false)
        let pending = SliderNumericEntrySession(context: from, initialValue: 0)
        var anotherBand = from; anotherBand.mixerBand = 1
        var allBands = from; allBands.mixerAllBands = true
        for changed in [anotherBand, allBands] {
            XCTAssertNil(pending.resolved("25", context: changed, currentValue: 0,
                                          range: -100...100))
        }
        XCTAssertEqual(pending.resolved("25", context: from, currentValue: 0,
                                        range: -100...100), 25)
    }

    func testSwitchingWheelRoleRejectsPendingLightnessAtIdenticalValue() {
        let from = SliderEditContext(primary: a, selection: [a], wheelRole: "Shadows")
        var to = from; to.wheelRole = "Highlights"
        let pending = SliderNumericEntrySession(context: from, initialValue: 0)
        XCTAssertNil(pending.resolved("0.25", context: to, currentValue: 0, range: -1...1))
        XCTAssertEqual(pending.resolved("0.25", context: from, currentValue: 0, range: -1...1), 0.25)
    }

    func testUntouchedRoundedReadoutPreservesStoredPrecision() {
        let context = SliderEditContext(primary: a, selection: [a])
        let pending = SliderNumericEntrySession(context: context, initialValue: 1.234,
                                                initialText: "1")
        XCTAssertEqual(pending.resolved("1", context: context, currentValue: 1.234,
                                        range: -5...5), 1.234)
        XCTAssertEqual(pending.resolved("2", context: context, currentValue: 1.234,
                                        range: -5...5), 2)
        XCTAssertEqual(pending.resolved("+= 1", context: context, currentValue: 1.234,
                                        range: -5...5), 2.234)
        XCTAssertNil(pending.resolved("1", context: SliderEditContext(primary: b, selection: [b]),
                                      currentValue: 1.234, range: -5...5))
        XCTAssertNil(pending.resolved("1", context: context, currentValue: 2, range: -5...5))
    }

    func testUntouchedReadoutDoesNotNormalizeExistingOutOfRangeValue() {
        let context = SliderEditContext(primary: a, selection: [a])
        let pending = SliderNumericEntrySession(context: context, initialValue: 6.234,
                                                initialText: "6")
        XCTAssertEqual(pending.resolved("6", context: context, currentValue: 6.234,
                                        range: -5...5), 6.234)
        XCTAssertEqual(pending.resolved("7", context: context, currentValue: 6.234,
                                        range: -5...5), 5)
    }

    func testConcurrentValueChangeRejectsStaleArithmeticAndNormalEntryStillClamps() {
        let context = SliderEditContext(primary: a, selection: [a])
        let pending = SliderNumericEntrySession(context: context, initialValue: 1)
        XCTAssertNil(pending.resolved("+= 1", context: context, currentValue: 3, range: -5...5))
        XCTAssertEqual(pending.resolved("+= 1", context: context, currentValue: 1, range: -5...5), 2)
        XCTAssertEqual(pending.resolved("100", context: context, currentValue: 1, range: -5...5), 5)
        XCTAssertNil(pending.resolved("nan", context: context, currentValue: 1, range: -5...5))
    }
}
#endif

import XCTest
@testable import LumenCore

final class ScalarDragSessionTests: XCTestCase {
    private let track = SliderTrack(width: 100, lowerBound: -100, upperBound: 100, step: 1)

    func testEqualValuedTargetSwitchCannotReceiveOldPressOrRelease() {
        let session = ScalarDragSession<String>()
        var photoA = 0.0, photoB = 0.0
        XCTAssertTrue(session.begin(context: "A", value: photoA, mapping: track))
        if session.accepts(context: "A", value: photoA, mapping: track) {
            photoA = 20; session.recordWrittenValue(photoA)
        }
        // B happens to have the same scalar as the last sample on A. Value-only
        // checking cannot distinguish the targets; the context must do it.
        photoB = 20
        if session.accepts(context: "B", value: photoB, mapping: track) { photoB = 75 }
        else { XCTAssertTrue(session.cancel()) }
        XCTAssertEqual(photoB, 20)
        XCTAssertFalse(session.accepts(context: "B", value: photoB, mapping: track))
        XCTAssertFalse(session.finish(), "cancellation already closed the edit")
    }

    func testExternalValueChangeCancelsRatherThanOverwritingIt() {
        let session = ScalarDragSession<String>()
        XCTAssertTrue(session.begin(context: "A", value: 10, mapping: track))
        XCTAssertFalse(session.accepts(context: "A", value: 30, mapping: track))
        XCTAssertTrue(session.cancel())
        XCTAssertFalse(session.cancel())
        XCTAssertFalse(session.finish())
    }

    func testMappingChangeRefusesRangeStepScaleAndWidth() {
        let mappings = [
            SliderTrack(width: 101, lowerBound: -100, upperBound: 100, step: 1),
            SliderTrack(width: 100, lowerBound: -100, upperBound: 200, step: 1),
            SliderTrack(width: 100, lowerBound: -100, upperBound: 100, step: 2),
            SliderTrack(width: 100, lowerBound: -100, upperBound: 100, step: 1, scale: .reciprocal)
        ]
        for changed in mappings {
            let session = ScalarDragSession<String>()
            session.begin(context: "A", value: 10, mapping: track)
            XCTAssertFalse(session.accepts(context: "A", value: 10, mapping: changed))
            XCTAssertTrue(session.cancel())
        }
    }

    func testCancelledContextExcursionDoesNotResumeSamePress() {
        let session = ScalarDragSession<String>()
        session.begin(context: "A", value: 10, mapping: track)
        XCTAssertTrue(session.cancel(), "observed context change closes the gesture")
        XCTAssertFalse(session.begin(context: "A", value: 10, mapping: track))
        XCTAssertFalse(session.accepts(context: "A", value: 10, mapping: track))
        XCTAssertFalse(session.finish())
        XCTAssertTrue(session.begin(context: "A", value: 10, mapping: track))
        XCTAssertTrue(session.accepts(context: "A", value: 10, mapping: track))
        XCTAssertTrue(session.finish())
        XCTAssertFalse(session.finish())
    }

    func testActualQuantizedBindingValueBecomesNextExpectedValue() {
        let session = ScalarDragSession<String>()
        session.begin(context: "A", value: 10, mapping: track)
        var stored = 10.0
        for proposed in [10.4, 10.8, 11.3] {
            XCTAssertTrue(session.accepts(context: "A", value: stored, mapping: track))
            stored = proposed.rounded()
            session.recordWrittenValue(stored)
        }
        XCTAssertEqual(stored, 11)
        XCTAssertTrue(session.finish())
    }
    func testFineDragFinalSampleIsWrittenBeforeTheSingleEnd() {
        let session = ScalarDragSession<String>()
        var gearbox = FineDrag(startValue: 0)
        var stored = 0.0
        var valuesAtEnd: [Double] = []
        session.begin(context: "A", value: stored, mapping: track)
        for sample in [(10.0, false), (20.0, true)] {
            XCTAssertTrue(session.accepts(context: "A", value: stored, mapping: track))
            let result = gearbox.resolving(track: track, travelled: sample.0, fine: sample.1)
            if let changed = result.changedGear { gearbox = changed }
            stored = result.value
            session.recordWrittenValue(stored)
        }
        XCTAssertTrue(session.accepts(context: "A", value: stored, mapping: track))
        stored = gearbox.resolving(track: track, travelled: 40, fine: true).value
        session.recordWrittenValue(stored)
        if session.finish() { valuesAtEnd.append(stored) }
        if session.finish() { valuesAtEnd.append(stored) }
        XCTAssertEqual(valuesAtEnd, [50], "40 coarse units at the gear switch plus 20 fine points worth 10 units")
    }

    func testInvalidatedActivePressStillClosesExactlyOnceAtRecovery() {
        let session = ScalarDragSession<String>()
        session.begin(context: "A", value: 10, mapping: track)
        XCTAssertFalse(session.accepts(context: "B", value: 10, mapping: track))
        // A lifecycle recovery can arrive before the caller's explicit cancel.
        XCTAssertTrue(session.finish())
        XCTAssertFalse(session.finish())
        XCTAssertFalse(session.cancel())
        XCTAssertTrue(session.begin(context: "B", value: 10, mapping: track))
        XCTAssertTrue(session.accepts(context: "B", value: 10, mapping: track))
    }

}

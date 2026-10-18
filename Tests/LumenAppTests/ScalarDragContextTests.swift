#if os(macOS)
import Foundation
import SwiftUI
import XCTest
import LumenCore
@testable import LumenApp

final class ScalarDragContextTests: XCTestCase {
    private let mapping = SliderTrack(width: 100, lowerBound: -100, upperBound: 100, step: 1)

    @MainActor
    func testActualBindingDoesNotReceiveAnotherTargetsReleaseAndClosesOnce() {
        let a = URL(fileURLWithPath: "/fixture/a.ARW"), b = URL(fileURLWithPath: "/fixture/b.ARW")
        var current = SliderEditContext(primary: a, selection: [a])
        var stored = 10.0
        let binding = Binding<Double>(get: { stored }, set: { stored = $0.rounded() })
        let session = ScalarDragSession<SliderEditContext>()
        var events: [String] = []
        session.begin(context: current, value: binding.wrappedValue, mapping: self.mapping)
        events.append("begin")
        XCTAssertTrue(session.accepts(context: current, value: binding.wrappedValue, mapping: self.mapping))
        binding.wrappedValue = 10.6
        session.recordWrittenValue(binding.wrappedValue)
        XCTAssertEqual(stored, 11)
        XCTAssertTrue(session.accepts(context: current, value: binding.wrappedValue, mapping: self.mapping),
                      "the next expected value is the actual quantized binding")
        current.primary = b; current.selection = [b]
        stored = 11 // B has exactly A's latest value.
        if session.accepts(context: current, value: binding.wrappedValue, mapping: self.mapping) {
            binding.wrappedValue = 75
        } else if session.cancel() { events.append("end") }
        XCTAssertEqual(stored, 11)
        if session.finish() { events.append("end") }
        XCTAssertEqual(events, ["begin", "end"])
    }

    func testEverySubtargetRoleInvalidatesAnEqualValuedPress() {
        let photo = URL(fileURLWithPath: "/fixture/a.ARW")
        let initial = SliderEditContext(primary: photo, selection: [photo], maskID: "mask-A",
            componentIndex: 0, swatchIndex: 0, mixerBand: 0, mixerAllBands: false)
        let mutations: [(inout SliderEditContext) -> Void] = [
            { $0.selection.insert(URL(fileURLWithPath: "/fixture/b.ARW")) },
            { $0.maskID = "mask-B" }, { $0.componentIndex = 1 },
            { $0.swatchIndex = 1 }, { $0.mixerBand = 1 }, { $0.mixerAllBands = true }
        ]
        for mutate in mutations {
            let session = ScalarDragSession<SliderEditContext>()
            session.begin(context: initial, value: 10, mapping: self.mapping)
            var changed = initial; mutate(&changed)
            XCTAssertFalse(session.accepts(context: changed, value: 10, mapping: self.mapping))
            XCTAssertTrue(session.cancel())
            XCTAssertFalse(session.finish())
        }
    }

    func testControlWiresContextValueGeometryAndDisappearanceCancellation() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/LumenControls.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "struct LumenSlider: View"))
        let end = try XCTUnwrap(text.range(of: "// MARK: - Section header", range: start.upperBound..<text.endIndex))
        let slider = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(slider.contains(".onChange(of: sliderEditContext)"))
        XCTAssertTrue(slider.contains(".onChange(of: value)"))
        XCTAssertTrue(slider.contains(".onChange(of: scrubTrack)"))
        XCTAssertTrue(slider.contains(".onChange(of: geometryOfDrag)"))
        XCTAssertTrue(slider.contains(".onAppear { recoverScalarDragsIfReleased() }"))
        let recovery = try XCTUnwrap(slider.range(of: "private func recoverScalarDragsIfReleased()"))
        let cancellation = try XCTUnwrap(slider.range(of: "private func cancelTrackDrag()", range: recovery.upperBound..<slider.endIndex))
        let recoveryBody = slider[recovery.lowerBound..<cancellation.lowerBound]
        let buttonGuard = try XCTUnwrap(recoveryBody.range(of: "guard NSEvent.pressedMouseButtons == 0 else { return }"))
        for action in ["finishTrackDrag()", "finishScrubDrag()", "pressWasReset = false"] {
            let actionRange = try XCTUnwrap(recoveryBody.range(of: action))
            XCTAssertLessThan(buttonGuard.lowerBound, actionRange.lowerBound,
                              "a held physical button must retain the cancelled press")
        }
        let disappeared = try XCTUnwrap(slider.range(of: ".onDisappear {"))
        let key = try XCTUnwrap(slider.range(of: ".onKeyPress(.leftArrow)", range: disappeared.upperBound..<slider.endIndex))
        XCTAssertTrue(slider[disappeared.lowerBound..<key.lowerBound].contains("cancelScalarDrags()"))
        XCTAssertGreaterThanOrEqual(slider.components(separatedBy: "trackDragSession.accepts").count - 1, 3)
        XCTAssertGreaterThanOrEqual(slider.components(separatedBy: "scrubDragSession.accepts").count - 1, 3)
    }
}
#endif

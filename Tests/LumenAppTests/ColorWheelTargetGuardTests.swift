#if os(macOS)
import Foundation
import CoreGraphics
import XCTest
@testable import LumenApp

final class ColorWheelTargetGuardTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/fixture/a.raw")
    private let b = URL(fileURLWithPath: "/fixture/b.raw")
    private var context: ColorWheelTargetContext {
        ColorWheelTargetContext(primary: a, selection: [a], wheelRole: "Shadows",
                                selectedRole: "Shadows")
    }

    func testLateReleaseCannotApplyToNewPhotoEvenWhenLastValuesMatch() {
        var session = ColorWheelDragSession()
        var hue = 0.0, saturation = 0.5
        var closes = 0
        let write: (Double, Double) -> Void = { hue = $0; saturation = $1 }
        session.changed(location: CGPoint(x: 75, y: 50), diameter: 100, clickCount: 1,
                        context: context, write: write, reset: {}, editingChanged: { _ in })
        // The newly selected photo has identical values. The release would change
        // hue to 90 without the target guard, so value-equality cannot hide this bug.
        var photoB = context; photoB.primary = b; photoB.selection = [b]
        session.ended(location: CGPoint(x: 50, y: 75), diameter: 100, context: photoB,
                      write: write, editingChanged: { if !$0 { closes += 1 } })
        XCTAssertEqual(hue, 0)
        XCTAssertEqual(saturation, 0.5)
        XCTAssertEqual(closes, 1)
    }

    func testBatchMaskAndWheelRoleChangesRejectBothMotionAndRelease() {
        var batch = context; batch.selection = [a, b]
        var mask = context; mask.targetMaskID = "mask-b"; mask.activeMaskID = "mask-b"
        var activeMask = context; activeMask.activeMaskID = "mask-b"
        var role = context; role.wheelRole = "Highlights"; role.selectedRole = "Highlights"
        for changed in [batch, mask, activeMask, role] {
            var session = ColorWheelDragSession()
            var writes = 0
            var closes = 0
            session.changed(location: CGPoint(x: 75, y: 50), diameter: 100, clickCount: 1,
                            context: context, write: { _, _ in }, reset: {}, editingChanged: { _ in })
            session.changed(location: CGPoint(x: 50, y: 75), diameter: 100, clickCount: 1,
                            context: changed, write: { _, _ in writes += 1 }, reset: {},
                            editingChanged: { _ in })
            session.ended(location: CGPoint(x: 50, y: 25), diameter: 100, context: changed,
                          write: { _, _ in writes += 1 },
                          editingChanged: { if !$0 { closes += 1 } })
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(closes, 1)
        }
    }

    func testChangedTargetAndReturnCannotReviveGesture() {
        var session = ColorWheelDragSession()
        var writes = 0
        session.changed(location: CGPoint(x: 75, y: 50), diameter: 100, clickCount: 1,
                        context: context, write: { _, _ in }, reset: {}, editingChanged: { _ in })
        var other = context; other.primary = b
        session.changed(location: .zero, diameter: 100, clickCount: 1, context: other,
                        write: { _, _ in writes += 1 }, reset: {}, editingChanged: { _ in })
        session.ended(location: CGPoint(x: 50, y: 75), diameter: 100, context: context,
                      write: { _, _ in writes += 1 }, editingChanged: { _ in })
        XCTAssertEqual(writes, 0)
    }

    func testObservedExcursionInvalidatesWithoutPointerMotion() {
        var session = ColorWheelDragSession()
        session.changed(location: CGPoint(x: 75, y: 50), diameter: 100, clickCount: 1,
                        context: context, write: { _, _ in }, reset: {}, editingChanged: { _ in })
        session.invalidate()
        var wrote = false
        var closed = false
        session.ended(location: CGPoint(x: 50, y: 75), diameter: 100, context: context,
                      write: { _, _ in wrote = true }, editingChanged: { if !$0 { closed = true } })
        XCTAssertFalse(wrote)
        XCTAssertTrue(closed)
    }

    func testDiameterChangeRejectsFinalSampleInDifferentCoordinateBasis() {
        var session = ColorWheelDragSession()
        session.changed(location: CGPoint(x: 75, y: 50), diameter: 100, clickCount: 1,
                        context: context, write: { _, _ in }, reset: {}, editingChanged: { _ in })
        var wrote = false
        var closed = false
        session.ended(location: CGPoint(x: 50, y: 75), diameter: 150, context: context,
                      write: { _, _ in wrote = true }, editingChanged: { if !$0 { closed = true } })
        XCTAssertFalse(wrote)
        XCTAssertTrue(closed)
    }

    func testStaleRoleOrInactiveMaskCannotStartEvenDoubleClickReset() {
        var role = context; role.selectedRole = "Highlights"
        var mask = context; mask.targetMaskID = "mask-a"; mask.activeMaskID = "mask-b"
        for stale in [role, mask] {
            var session = ColorWheelDragSession()
            var writes = 0
            var resets = 0
            session.changed(location: .zero, diameter: 100, clickCount: 2, context: stale,
                            write: { _, _ in writes += 1 }, reset: { resets += 1 },
                            editingChanged: { _ in })
            session.ended(location: .zero, diameter: 100, context: stale,
                          write: { _, _ in writes += 1 }, editingChanged: { _ in })
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(resets, 0)
        }
    }

    func testDisappearanceClosesOrdinaryGestureWithoutFinalWriteAndAllowsNextPress() {
        var session = ColorWheelDragSession()
        var events: [Bool] = []
        session.changed(location: CGPoint(x: 75, y: 50), diameter: 100, clickCount: 1,
                        context: context, write: { _, _ in }, reset: {},
                        editingChanged: { events.append($0) })
        session.cancelled(editingChanged: { events.append($0) })
        XCTAssertEqual(events, [true, false])
        var wrote = false
        session.changed(location: CGPoint(x: 75, y: 50), diameter: 100, clickCount: 1,
                        context: context, write: { _, _ in wrote = true }, reset: {},
                        editingChanged: { _ in })
        XCTAssertTrue(wrote)
    }

    func testReleaseWithoutPressCannotWriteButStillCloses() {
        var session = ColorWheelDragSession()
        var wrote = false
        var closed = false
        session.ended(location: CGPoint(x: 50, y: 75), diameter: 100, context: context,
                      write: { _, _ in wrote = true }, editingChanged: { if !$0 { closed = true } })
        XCTAssertFalse(wrote)
        XCTAssertTrue(closed)
    }

    func testLightnessContextPreservesEveryInheritedSubtarget() {
        let inherited = SliderEditContext(primary: a, selection: [a], maskID: "mask-a",
                                           componentIndex: 2, swatchIndex: 3,
                                           mixerBand: 4, mixerAllBands: false)
        var live = context
        live.primary = b
        live.selection = [a, b]
        live.selectedRole = "Highlights"
        var expected = inherited
        expected.primary = b
        expected.selection = [a, b]
        expected.wheelRole = "Highlights"
        XCTAssertEqual(live.numericEntryContext(inheriting: inherited), expected)
        live.selectedRole = nil
        expected.wheelRole = "Shadows"
        XCTAssertEqual(live.numericEntryContext(inheriting: inherited), expected)
    }

    func testActualLightnessBarInstallsTheFreshContextMapping() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/LumenApp/LumenControls.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var lightnessBar:"))
        let end = try XCTUnwrap(source.range(of: "private var puck:", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains(#".environment(\.sliderEditContext,"#))
        XCTAssertTrue(body.contains("dragContext().numericEntryContext(inheriting: inheritedSliderEditContext)"))
    }

}
#endif

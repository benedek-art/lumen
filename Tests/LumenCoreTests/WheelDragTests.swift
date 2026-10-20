// WheelDragTests.swift
// The grading wheel's drag law (`WheelDrag`): a press on the puck picks it up where it
// is, ⇧ fines the drag without moving the puck, and a press alone writes nothing.
//
// The rules are LumenCore and run here. The wiring is `LumenColorWheel`, which compiles
// only on macOS, so it is pinned by a source contract in the style of
// `MixerRingPressTests`, line comments stripped.

import XCTest
@testable import LumenCore

final class WheelDragTests: XCTestCase {

    private static let wheelRadius: Double = 34     // the 68-point four-up wheel

    /// The reading is the arithmetic the wheel always used, unchanged.
    func testTheReadingIsTheWheelsOldArithmetic() throws {
        for x in stride(from: -40.0, through: 40, by: 7.5) {
            for y in stride(from: -40.0, through: 40, by: 6.25) {
                let got = try XCTUnwrap(WheelDrag.reading(WheelPoint(x: x, y: y),
                                                          radius: Self.wheelRadius))
                let r = min((x * x + y * y).squareRoot() / Self.wheelRadius, 1)
                let hue = (atan2(y, x) * 180 / .pi + 360)
                    .truncatingRemainder(dividingBy: 360)
                XCTAssertEqual(got.saturation, r)
                XCTAssertEqual(got.hue, hue)
            }
        }
        XCTAssertNil(WheelDrag.reading(WheelPoint(x: .nan, y: 0), radius: Self.wheelRadius))
        XCTAssertNil(WheelDrag.reading(.zero, radius: 0))
    }

    /// The scenario: pressing the rim of the puck to nudge it. Before the hand moves the
    /// puck must not move, however far off its centre the press landed.
    func testAPressOnThePuckRimMovesNothing() throws {
        let hue = 40.0, sat = 0.3
        let puck = WheelDrag.puckOffset(hue: hue, saturation: sat, radius: Self.wheelRadius)
        for (dx, dy) in [(4.5, 0.0), (0.0, -4.5), (-3.2, 3.2), (6.9, 0.0)] {
            let drag = WheelDrag(press: WheelPoint(x: puck.x + dx, y: puck.y + dy),
                                 puck: puck)
            XCTAssertTrue(drag.grabbedPuck)
            let at = drag.resolving(travelled: .zero, fine: false).offset
            let read = try XCTUnwrap(WheelDrag.reading(at, radius: Self.wheelRadius))
            XCTAssertEqual(read.saturation, sat, accuracy: 1e-12)
            XCTAssertEqual(read.hue, hue, accuracy: 1e-9)
        }
    }

    /// A press on bare disc is a placement: its anchor is the press itself, which is the
    /// absolute behaviour the wheel always had.
    func testAPressOffThePuckPlacesItUnderThePointer() {
        let puck = WheelDrag.puckOffset(hue: 0, saturation: 0, radius: Self.wheelRadius)
        let press = WheelPoint(x: 20, y: -10)
        let drag = WheelDrag(press: press, puck: puck)
        XCTAssertFalse(drag.grabbedPuck)
        XCTAssertEqual(drag.resolving(travelled: .zero, fine: false).offset, press)
        XCTAssertEqual(drag.resolving(travelled: WheelPoint(x: 3, y: 4), fine: false).offset,
                       WheelPoint(x: 23, y: -6))
    }

    /// A grabbed drag is relative: the puck moves by the hand's travel, not to the
    /// pointer.
    func testAGrabbedDragMovesByTheTravel() {
        let puck = WheelPoint(x: 10, y: 5)
        let drag = WheelDrag(press: WheelPoint(x: 13, y: 7), puck: puck)
        XCTAssertEqual(drag.resolving(travelled: WheelPoint(x: 4, y: -2), fine: false).offset,
                       WheelPoint(x: 14, y: 3))
    }

    /// ⇧ scales the travel by `FineDrag.scale`, and changing gear mid-drag moves nothing.
    func testShiftFinesTheDragWithoutAJump() throws {
        let puck = WheelPoint(x: 0, y: 0)
        var drag = WheelDrag(press: puck, puck: puck)
        let coarse = drag.resolving(travelled: WheelPoint(x: 8, y: 0), fine: false)
        XCTAssertNil(coarse.changedGear)
        XCTAssertEqual(coarse.offset, WheelPoint(x: 8, y: 0))

        let shifted = drag.resolving(travelled: WheelPoint(x: 8, y: 0), fine: true)
        XCTAssertEqual(shifted.offset, WheelPoint(x: 8, y: 0), "⇧ going down moved the puck")
        drag = try XCTUnwrap(shifted.changedGear)
        let fine = drag.resolving(travelled: WheelPoint(x: 16, y: 4), fine: true)
        XCTAssertNil(fine.changedGear)
        XCTAssertEqual(fine.offset, WheelPoint(x: 8 + 8 * FineDrag.scale, y: 4 * FineDrag.scale))

        let released = drag.resolving(travelled: WheelPoint(x: 16, y: 4), fine: false)
        XCTAssertEqual(released.offset, fine.offset, "⇧ coming up moved the puck")
    }

    func testANonFiniteTravelHoldsTheAnchor() {
        let puck = WheelPoint(x: 3, y: 3)
        let drag = WheelDrag(press: puck, puck: puck)
        XCTAssertEqual(drag.resolving(travelled: WheelPoint(x: .nan, y: 1), fine: false).offset,
                       puck)
        XCTAssertFalse(WheelDrag.grabsPuck(press: WheelPoint(x: .infinity, y: 0), puck: puck))
    }

    // MARK: The wiring

    private static func wheelSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/LumenControls.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[..<r.lowerBound])
            }
            .joined(separator: "\n")
        let start = try XCTUnwrap(code.range(of: "struct LumenColorWheel: View {"))
        let rest = code[start.upperBound...]
        let end = rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// B3-05 on the wheel: the first click of a double-click must write nothing and open
    /// no gesture before the pointer has travelled, or one ⌘Z lands on a tint nobody
    /// made.
    func testAWheelPressThatHasNotMovedWritesNothing() throws {
        let wheel = try Self.wheelSource()
        let changed = try XCTUnwrap(wheel.range(of: ".onChanged { drag in"))
        let ended = try XCTUnwrap(wheel.range(of: ".onEnded {",
                                              range: changed.upperBound..<wheel.endIndex))
        let path = String(wheel[changed.upperBound..<ended.lowerBound])
        let reset = try XCTUnwrap(path.range(of: "if pressWasReset { return }"))
        let tail = String(path[reset.upperBound...])
        let still = try XCTUnwrap(tail.range(of: "guard drag.translation != .zero else { return }"),
                                  "a press with no travel writes the puck again")
        let opens = try XCTUnwrap(tail.range(of: "sliderGestureChanged(true)"))
        XCTAssertLessThan(still.lowerBound, opens.lowerBound)
        XCTAssertFalse(tail.contains("hue ="), "the drag path writes hue directly again")
        XCTAssertTrue(tail.contains("follow(drag)"))
    }

    /// Saturation is written before hue, so a click-to-place's undo step carries the key
    /// a double-click's reset writes first, and the two fold into one step.
    func testThePuckWritesSaturationBeforeHue() throws {
        let wheel = try Self.wheelSource()
        let write = try XCTUnwrap(wheel.range(of: "private func write(_ offset: WheelPoint) {"))
        let body = String(wheel[write.upperBound...].prefix(400))
        let sat = try XCTUnwrap(body.range(of: "sat = puck.saturation"))
        let hue = try XCTUnwrap(body.range(of: "hue = puck.hue"))
        XCTAssertLessThan(sat.lowerBound, hue.lowerBound)
        XCTAssertTrue(wheel.contains("WheelDrag(\n"), "the wheel no longer opens a WheelDrag")
        XCTAssertTrue(wheel.contains("fine: Self.shiftIsDown"))
    }
}

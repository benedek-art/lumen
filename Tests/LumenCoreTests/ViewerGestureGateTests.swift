// V7 D3: the double-click zoom was the only loupe gesture with no guard, so it zoomed
// under an armed Crop (a canvas that ignores zoom) and toggled the zoom under a mask
// tool or a pick. One rule in LumenCore now, and every gesture goes through it.
import XCTest
@testable import LumenCore

final class ViewerGestureGateTests: XCTestCase {

    private func gate(crop: Bool = false, masking: Bool = false,
                      picking: Bool = false) -> ViewerGestureGate {
        ViewerGestureGate(cropArmed: crop, masking: masking, picking: picking)
    }

    func testNothingArmedLetsEveryGestureThrough() {
        XCTAssertTrue(gate().continuous)
        XCTAssertTrue(gate().doubleClickZoom)
    }

    /// The defect: Crop armed, double-click. Refused, as the drag, pinch and wheel are.
    func testCropArmedRefusesEveryGestureIncludingTheDoubleClick() {
        for masking in [false, true] {
            for picking in [false, true] {
                let g = gate(crop: true, masking: masking, picking: picking)
                XCTAssertFalse(g.doubleClickZoom,
                               "a double-click under an armed Crop zooms a canvas that "
                                   + "ignores zoom; the picture jumps when the tool is put away")
                XCTAssertFalse(g.continuous)
            }
        }
    }

    /// While a click is the instrument, two of them must not also toggle the zoom.
    /// Panning and pinching in to place a handle stay available.
    func testMaskingAndPickingRefuseOnlyTheDoubleClick() {
        XCTAssertFalse(gate(masking: true).doubleClickZoom)
        XCTAssertFalse(gate(picking: true).doubleClickZoom)
        XCTAssertTrue(gate(masking: true).continuous)
        XCTAssertTrue(gate(picking: true).continuous)
    }

    // MARK: - Every gesture in the loupe goes through the gate

    private static let loupe = "Sources/LumenApp/LoupeView.swift"

    /// The double-click's own closure guards on the gate before it zooms.
    func testTheDoubleClickClosureIsGated() throws {
        let code = try ShellSource.code(Self.loupe)
        let closure = try XCTUnwrap(
            ShellSource.body(after: "SpatialTapGesture(count: 2)", in: code),
            "the loupe's double-click gesture is gone or renamed; re-point this pin")
        let flat = ShellSource.squashed(closure)
        guard let guardAt = flat.range(of: "guard gestureGate.doubleClickZoom else { return }"),
              let zoomAt = flat.range(of: "viewport.toggleZoom(") else {
            return XCTFail("the double-click zooms without asking ViewerGestureGate: \(flat)")
        }
        XCTAssertLessThan(guardAt.lowerBound, zoomAt.lowerBound,
                          "the guard must come before the zoom")
    }

    /// The drag, the pinch and the wheel use the same gate.
    func testTheContinuousGesturesAreGated() throws {
        let code = try ShellSource.code(Self.loupe)
        for marker in ["private func dragGesture(container: CGSize)",
                       "private func magnifyGesture(container: CGSize)",
                       "private func applyScroll(_ verb: ViewerScroll.Verb, container: CGSize)"] {
            let body = try XCTUnwrap(ShellSource.body(after: marker, in: code),
                                     "\(marker) is gone; re-point this pin")
            XCTAssertTrue(ShellSource.squashed(body)
                            .contains("guard gestureGate.continuous else { return }"),
                          "\(marker) no longer asks ViewerGestureGate")
        }
        // And the gate is built from the three facts, not a constant.
        let gateBody = try XCTUnwrap(ShellSource.body(after: "private var gestureGate: ViewerGestureGate",
                                                      in: code))
        let flat = ShellSource.squashed(gateBody)
        XCTAssertTrue(flat.contains("cropArmed: cropArmed"))
        XCTAssertTrue(flat.contains("masking: panel.layout.isMasking"))
        XCTAssertTrue(flat.contains("picking: state.pickTarget != nil"))
    }
}

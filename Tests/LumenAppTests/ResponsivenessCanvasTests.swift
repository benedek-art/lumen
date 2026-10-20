// ResponsivenessCanvasTests.swift
// The arithmetic the on-image drags lean on to stay cheap and to close cleanly.
//
// Two contracts, both relied on by the canvases rather than tested through them (a
// SwiftUI drag cannot be driven from a machine with no window server):
//
//   · A CANCELLED drag closes its gesture. The crop overlay, mask canvas, heal canvas
//     and compare pane each hold a `@GestureState` that SwiftUI resets on cancel, and
//     their cleanup calls `sliderGestureChanged(false)` — deferred, and possibly after
//     the release already closed it. So a second close must be a no-op, and the close
//     must be what separates the dead drag's undo step from the next gesture's.
//
//   · An event that changes nothing writes nothing. The crop move/resize and the
//     straighten drag compare the value they computed with the one already applied and
//     skip the write when equal; that only saves anything if pushing past a bound
//     really does produce an EQUAL value, which is what the geometry tests pin.

#if os(macOS)

import XCTest
import LumenCore
@testable import LumenApp

final class ResponsivenessCanvasTests: XCTestCase {

    @MainActor
    private func withState(_ run: (AppState) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-canvas-resp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        defer {
            state.prepareToQuit()
            try? FileManager.default.removeItem(at: root)
        }
        try run(state)
    }

    /// The deferred cancel cleanup may run after the release already closed the latch.
    @MainActor
    func testClosingAClosedGestureIsANoOp() throws {
        try withState { state in
            state.sliderGesture(active: true)
            state.sliderGesture(active: false)
            let epoch = state.gestureEpoch
            let tick = state.settleTick
            state.sliderGesture(active: false)
            XCTAssertFalse(state.sliderGestureActive)
            XCTAssertEqual(state.gestureEpoch, epoch)
            XCTAssertEqual(state.settleTick, tick, "a second close must not re-settle")
        }
    }

    /// Without the close, the next drag reuses the dead drag's epoch — one undo step for
    /// two gestures. With it, each gets its own.
    @MainActor
    func testACancelledDragClosedByItsCleanupIsItsOwnUndoStep() throws {
        try withState { state in
            state.sliderGesture(active: true)
            let dead = state.gestureEpoch
            // No release: the latch is still open, so a new drag would share the epoch.
            state.sliderGesture(active: true)
            XCTAssertEqual(state.gestureEpoch, dead)
            // The cancel cleanup's close, then the next gesture.
            state.sliderGesture(active: false)
            state.sliderGesture(active: true)
            XCTAssertNotEqual(state.gestureEpoch, dead)
            state.sliderGesture(active: false)
        }
    }

    /// A move held against the frame's edge yields the SAME crop per event, so the
    /// overlay's `next != crop` guard skips it.
    func testAMovePushedPastTheEdgeIsTheSameCrop() {
        let origin = Crop(x: 0.2, y: 0.2, w: 0.5, h: 0.5)
        let a = CropGeometry.move(origin, dx: 0.6, dy: -0.4)
        let b = CropGeometry.move(origin, dx: 0.9, dy: -0.9)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(a.y, 0, accuracy: 1e-12)
    }

    /// A straighten drag pinned at the limit produces the angle it already applied, so
    /// the overlay's `next != drag.degrees` guard skips the framing pass.
    func testARotationPinnedAtTheLimitRepeatsItsAngle() {
        let limit = Straighten.limitDegrees
        XCTAssertEqual(CropGeometry.rotationAngle(from: limit, sweep: 3), limit)
        XCTAssertEqual(CropGeometry.rotationAngle(from: -limit, sweep: 3, flipped: true),
                       -limit)
        XCTAssertEqual(CropGeometry.rotationAngle(from: 7, sweep: 0), 7)
    }
}

#endif

#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

final class CurvePointerSessionTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/fixture/a.raw")
    private let b = URL(fileURLWithPath: "/fixture/b.raw")

    private var context: CurvePointerContext {
        CurvePointerContext(primary: a, selection: [a], targetMaskID: nil,
                            activeMaskID: nil, channel: "red")
    }

    func testReleaseDeliversFinalPointAfterLastMotionWasEarlier() {
        let session = CurvePointerSession(context: context)
        var points = [[0.0, 0.0], [0.5, 0.5], [1.0, 1.0]]
        var closes = 0
        let apply: (CGPoint) -> Void = { point in
            points = CurveEditing.moved(points, index: 1,
                                         toX: Double(point.x / 300),
                                         toY: 1 - Double(point.y / 300))
        }
        session.changed(at: CGPoint(x: 180, y: 120), context: context, apply: apply)
        XCTAssertEqual(points[1][0], 0.6, accuracy: 1e-12)
        XCTAssertEqual(points[1][1], 0.6, accuracy: 1e-12)
        session.ended(at: CGPoint(x: 210, y: 90), context: context,
                      apply: apply, finish: { closes += 1 })
        XCTAssertEqual(points[1][0], 0.7, accuracy: 1e-12)
        XCTAssertEqual(points[1][1], 0.7, accuracy: 1e-12)
        XCTAssertEqual(closes, 1)
        session.changed(at: .zero, context: context, apply: apply)
        XCTAssertEqual(points[1][0], 0.7, accuracy: 1e-12,
                       "A completed session cannot keep writing")
    }

    func testRailReleaseUsesFinalCoordinateAndPreservesGrabOffset() {
        var target = context; target.channel = "parametric"
        let session = CurvePointerSession(context: target)
        var split = 0.5
        let apply: (CGPoint) -> Void = { point in
            split = CurveEditing.clampedSplit(Double((point.x - 2) / 300))
        }
        session.changed(at: CGPoint(x: 182, y: 0), context: target, apply: apply)
        XCTAssertEqual(split, 0.6, accuracy: 1e-12)
        session.ended(at: CGPoint(x: 212, y: 0), context: target, apply: apply, finish: {})
        XCTAssertEqual(split, 0.7, accuracy: 1e-12)
    }

    func testFinalDeliveryStillUsesExistingNeighborAndEndpointClamps() {
        let session = CurvePointerSession(context: context)
        var points = [[0.0, 0.0], [0.5, 0.5], [0.75, 0.8], [1.0, 1.0]]
        session.ended(at: CGPoint(x: 300, y: 300), context: context, apply: { point in
            points = CurveEditing.moved(points, index: 1,
                                         toX: Double(point.x / 300),
                                         toY: 1 - Double(point.y / 300))
        }, finish: {})
        XCTAssertEqual(points[1][0], 0.746, accuracy: 1e-12)
        XCTAssertEqual(points[1][1], 0)
        XCTAssertEqual(points.count, 4)
        XCTAssertNil(CurveEditing.deleting(points, at: 0), "The black anchor stays permanent")
        XCTAssertNotNil(CurveEditing.deleting(points, at: 1), "Interior deletion stays available")
    }

    func testReleaseIsEnoughWithoutIntermediateMotionSamples() {
        let session = CurvePointerSession(context: context)
        var delivered: CGPoint?
        session.ended(at: CGPoint(x: 210, y: 90), context: context,
                      apply: { delivered = $0 }, finish: {})
        XCTAssertEqual(delivered, CGPoint(x: 210, y: 90))
    }

    func testPhotoBatchMaskAndChannelRetargetingRejectBothMotionAndRelease() {
        var photo = context; photo.primary = b; photo.selection = [b]
        var batch = context; batch.selection = [a, b]
        var mask = context; mask.targetMaskID = "another-mask"
        var activeMask = context; activeMask.activeMaskID = "another-mask"
        var channel = context; channel.channel = "blue"
        for changed in [photo, batch, mask, activeMask, channel] {
            let session = CurvePointerSession(context: context)
            var writes = 0
            var closes = 0
            session.changed(at: .zero, context: changed, apply: { _ in writes += 1 })
            session.ended(at: CGPoint(x: 210, y: 90), context: changed,
                          apply: { _ in writes += 1 }, finish: { closes += 1 })
            XCTAssertEqual(writes, 0, "Identical curve values do not authorize a different target")
            XCTAssertEqual(closes, 1)
        }
    }

    func testRetargetingThenReturningCannotReviveThePendingGesture() {
        let session = CurvePointerSession(context: context)
        var other = context; other.primary = b
        var writes = 0
        session.changed(at: .zero, context: other, apply: { _ in writes += 1 })
        session.ended(at: CGPoint(x: 210, y: 90), context: context,
                      apply: { _ in writes += 1 }, finish: {})
        XCTAssertEqual(writes, 0)
    }

    func testObservedTargetExcursionInvalidatesBeforeNextPointerSample() {
        let session = CurvePointerSession(context: context)
        session.invalidate() // The view's target onChange, including A -> B -> A.
        var wrote = false
        var closed = false
        session.ended(at: CGPoint(x: 210, y: 90), context: context,
                      apply: { _ in wrote = true }, finish: { closed = true })
        XCTAssertFalse(wrote)
        XCTAssertTrue(closed)
    }
}
#endif

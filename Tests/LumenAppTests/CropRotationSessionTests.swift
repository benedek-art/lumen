#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

final class CropRotationSessionTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/fixture/a.raw")
    private let b = URL(fileURLWithPath: "/fixture/b.raw")
    private let pivot = CGPoint(x: 100, y: 100)
    private let start = CGPoint(x: 200, y: 100)
    private var context: CropRotationContext {
        CropRotationContext(photoID: a, primaryID: a, targetIDs: [a],
                            sourceSize: CGSize(width: 6000, height: 4000), flipH: false)
    }

    private func point(_ degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: 100 + 100 * cos(radians), y: 100 + 100 * sin(radians))
    }

    private func preparedSession(flipped: Bool = false) throws -> (CropRotationSession, CropRotationContext, Double) {
        var target = context; target.flipH = flipped
        let session = try XCTUnwrap(CropRotationSession(context: target, pivot: pivot, start: start, angle: 0))
        var angle = 0.0
        session.changed(location: point(10), context: target, currentAngle: angle,
                        gear: 1, apply: { angle = $0 })
        XCTAssertEqual(angle, flipped ? -10 : 10, accuracy: 1e-12)
        session.changed(location: point(20), context: target, currentAngle: angle,
                        gear: 0.2, apply: { angle = $0 })
        XCTAssertEqual(angle, flipped ? -12 : 12, accuracy: 1e-12)
        return (session, target, angle)
    }

    func testReleaseWithShiftReleasedIntegratesOnlyTheFinalSweepIncrementBeforeClosing() throws {
        let (session, target, previous) = try preparedSession()
        var angle = previous
        var closed = false
        session.ended(location: point(30), context: target, currentAngle: angle, gear: 1,
                      apply: { angle = $0 },
                      finish: { XCTAssertEqual(angle, 22, accuracy: 1e-12); closed = true })
        XCTAssertEqual(angle, 22, accuracy: 1e-12)
        XCTAssertTrue(closed)
    }

    func testReleaseWithShiftHeldKeepsFineGear() throws {
        let (session, target, previous) = try preparedSession()
        var angle = previous
        session.ended(location: point(30), context: target, currentAngle: angle, gear: 0.2,
                      apply: { angle = $0 }, finish: {})
        XCTAssertEqual(angle, 14, accuracy: 1e-12)
    }

    func testMirroredReleaseUsesTheExistingOppositeRotationDirection() throws {
        let (session, target, previous) = try preparedSession(flipped: true)
        var angle = previous
        session.ended(location: point(30), context: target, currentAngle: angle, gear: 1,
                      apply: { angle = $0 }, finish: {})
        XCTAssertEqual(angle, -22, accuracy: 1e-12)
    }

    func testChangingGearWithoutPointerTravelCannotRetroactivelyScaleEarlierTravel() throws {
        let (session, target, previous) = try preparedSession()
        var angle = previous
        session.ended(location: point(20), context: target, currentAngle: angle, gear: 1,
                      apply: { angle = $0 }, finish: {})
        XCTAssertEqual(angle, 12, accuracy: 1e-12)
    }

    func testPhotoBatchFlipAndSourceChangesRejectMotionAndReleaseButStillClose() throws {
        var photo = context; photo.primaryID = b
        var batch = context; batch.targetIDs = [a, b]
        var flip = context; flip.flipH = true
        var source = context; source.sourceSize = CGSize(width: 4000, height: 6000)
        for changed in [photo, batch, flip, source] {
            let session = try XCTUnwrap(CropRotationSession(context: context, pivot: pivot, start: start, angle: 0))
            var writes = 0
            var closes = 0
            session.changed(location: point(10), context: changed, currentAngle: 0,
                            gear: 1, apply: { _ in writes += 1 })
            session.ended(location: point(30), context: changed, currentAngle: 0,
                          gear: 1, apply: { _ in writes += 1 }, finish: { closes += 1 })
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(closes, 1)
        }
    }

    func testUnrelatedAngleEditCannotBeOverwrittenOrReviveWhenAngleReturns() throws {
        let session = try XCTUnwrap(CropRotationSession(context: context, pivot: pivot, start: start, angle: 0))
        var writes = 0
        session.changed(location: point(10), context: context, currentAngle: 5,
                        gear: 1, apply: { _ in writes += 1 })
        session.ended(location: point(30), context: context, currentAngle: 0,
                      gear: 1, apply: { _ in writes += 1 }, finish: {})
        XCTAssertEqual(writes, 0)
    }

    func testObservedTargetExcursionStaysInvalidOnReturn() throws {
        let session = try XCTUnwrap(CropRotationSession(context: context, pivot: pivot, start: start, angle: 0))
        session.invalidate()
        var wrote = false
        var closed = false
        session.ended(location: point(30), context: context, currentAngle: 0,
                      gear: 1, apply: { _ in wrote = true }, finish: { closed = true })
        XCTAssertFalse(wrote)
        XCTAssertTrue(closed)
    }

    func testInvalidRadiusKeepsTheLastGoodSweepAndTheReleaseStillCloses() throws {
        let (session, target, previous) = try preparedSession()
        var angle = previous
        var closed = false
        session.ended(location: pivot, context: target, currentAngle: angle, gear: 1,
                      apply: { angle = $0 }, finish: { closed = true })
        XCTAssertEqual(angle, previous)
        XCTAssertTrue(closed)
        XCTAssertEqual(session.rawSweep, 20, accuracy: 1e-12)
    }

    func testReleaseWithoutIntermediateMotionStillUsesExistingAngleClamp() throws {
        let session = try XCTUnwrap(CropRotationSession(context: context, pivot: pivot, start: start, angle: 0))
        var angle = 0.0
        session.ended(location: point(60), context: context, currentAngle: angle, gear: 1,
                      apply: { angle = $0 }, finish: {})
        XCTAssertEqual(angle, 45)
    }

    func testBothSweepBoundariesKeepTheExistingClampInsteadOfJumpingToTheOppositeLimit() throws {
        for direction in [-1.0, 1.0] {
            let session = try XCTUnwrap(CropRotationSession(context: context, pivot: pivot, start: start, angle: 0))
            var angle = 0.0
            for degrees in [90.0, 179.0] {
                session.changed(location: point(direction * degrees), context: context,
                                currentAngle: angle, gear: 1, apply: { angle = $0 })
            }
            XCTAssertEqual(angle, direction * 45)
            session.ended(location: point(direction * -179), context: context,
                          currentAngle: angle, gear: 1, apply: { angle = $0 }, finish: {})
            XCTAssertEqual(angle, direction * 45)
        }
    }

    func testFineGearBoundaryCrossingAndBacktrackingPreserveTwoDegreeTravel() throws {
        for direction in [-1.0, 1.0] {
            let session = try XCTUnwrap(CropRotationSession(context: context, pivot: pivot, start: start,
                                                         angle: direction * -40))
            var angle = direction * -40
            for degrees in [90.0, 179.0, -179.0] {
                session.changed(location: point(direction * degrees), context: context,
                                currentAngle: angle, gear: 0.2, apply: { angle = $0 })
            }
            // 181 degrees of forward travel at one fifth gear, starting at -40.
            XCTAssertEqual(angle, direction * -3.8, accuracy: 1e-12)
            session.ended(location: point(direction * 179), context: context,
                          currentAngle: angle, gear: 0.2, apply: { angle = $0 }, finish: {})
            XCTAssertEqual(angle, direction * -4.2, accuracy: 1e-12)
        }
    }

    func testMirroredBoundaryCrossingRetainsOppositeDirectionAtCurrentGear() throws {
        var target = context; target.flipH = true
        let session = try XCTUnwrap(CropRotationSession(context: target, pivot: pivot, start: start, angle: 40))
        var angle = 40.0
        for degrees in [90.0, 179.0] {
            session.changed(location: point(degrees), context: target, currentAngle: angle,
                            gear: 0.2, apply: { angle = $0 })
        }
        XCTAssertEqual(angle, 4.2, accuracy: 1e-12)
        session.ended(location: point(-179), context: target, currentAngle: angle,
                      gear: 1, apply: { angle = $0 }, finish: {})
        XCTAssertEqual(angle, 2.2, accuracy: 1e-12)
    }

    func testStalePrimaryOrPressInsideMinimumRadiusCannotStart() {
        var target = context; target.primaryID = b
        XCTAssertNil(CropRotationSession(context: target, pivot: pivot, start: start, angle: 0))
        XCTAssertNil(CropRotationSession(context: context, pivot: pivot, start: pivot, angle: 0))
    }
}
#endif

#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

final class StraightenDrawSessionTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/fixture/a.raw")
    private let b = URL(fileURLWithPath: "/fixture/b.raw")
    private let size = CGSize(width: 300, height: 200)
    private var context: StraightenDrawContext {
        StraightenDrawContext(photoID: a, primaryID: a, targetIDs: [a],
                              sourceSize: CGSize(width: 6000, height: 4000), sourceRevision: 0, angle: 0, flipped: false)
    }
    private func make(_ target: StraightenDrawContext) throws -> StraightenDrawSession {
        try XCTUnwrap(StraightenDrawSession(context: target, displayedAngle: target.angle,
            displayedFlip: target.flipped, displayedSource: target.sourceSize,
            frameSize: size, start: CGPoint(x: 20, y: 30)))
    }

    func testFinalPointUsesIndependentLineAngleAndMirrorBeforeFinishing() throws {
        for flipped in [false, true] {
            var target = context; target.flipped = flipped
            let session = try make(target)
            XCTAssertTrue(session.changed(context: target, frameSize: size))
            // Last motion is flat; the coalesced release rises20 over200points.
            XCTAssertEqual(try XCTUnwrap(session.preview(to: CGPoint(x: 220, y: 30))), 0)
            var received: [Double] = []
            var closes = 0
            let oracle = atan(0.1) * 180 / Double.pi * (flipped ? 1 : -1)
            session.ended(to: CGPoint(x: 220, y: 50), context: target, frameSize: size,
                apply: { received.append($0) }, finish: {
                    XCTAssertEqual(received.count, 1)
                    closes += 1
                })
            XCTAssertEqual(try XCTUnwrap(received.first), oracle, accuracy: 1e-12)
            XCTAssertEqual(closes, 1)
        }
    }

    func testChangedPhotoBatchFlipSourceAngleAndFrameRejectReleaseButCloseOnce() throws {
        var photo = context; photo.primaryID = b
        var batch = context; batch.targetIDs = [a, b]
        var flip = context; flip.flipped = true
        var source = context; source.sourceSize.width = 4000
        var revision = context; revision.sourceRevision = 1
        var angle = context; angle.angle = 8
        for target in [photo, batch, flip, source, revision, angle, context] {
            let session = try make(context)
            let frame = target == context ? CGSize(width: 301, height: 200) : size
            var writes = 0
            var closes = 0
            session.ended(to: CGPoint(x: 220, y: 50), context: target, frameSize: frame,
                          apply: { _ in writes += 1 }, finish: { closes += 1 })
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(closes, 1)
        }
    }

    func testObservedContextExcursionCannotReviveOnReturn() throws {
        let session = try make(context)
        var changed = context; changed.targetIDs = [a, b]
        XCTAssertFalse(session.changed(context: changed, frameSize: size))
        var writes = 0
        var closes = 0
        session.ended(to: CGPoint(x: 220, y: 50), context: context, frameSize: size,
                      apply: { _ in writes += 1 }, finish: { closes += 1 })
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(closes, 1)
    }

    func testExplicitInvalidationAndShortLineDoNotWriteButClose() throws {
        for invalidated in [false, true] {
            let session = try make(context)
            if invalidated { session.invalidate() }
            var writes = 0
            var closes = 0
            session.ended(to: invalidated ? CGPoint(x: 220, y: 50) : CGPoint(x: 20.1, y: 30),
                          context: context, frameSize: size,
                          apply: { _ in writes += 1 }, finish: { closes += 1 })
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(closes, 1)
        }
    }

    func testStaleDisplayedGeometryCannotStart() {
        var changed = context; changed.primaryID = b
        XCTAssertNil(StraightenDrawSession(context: changed, displayedAngle: 0, displayedFlip: false,
            displayedSource: context.sourceSize, frameSize: size, start: .zero))
        XCTAssertNil(StraightenDrawSession(context: context, displayedAngle: 8, displayedFlip: false,
            displayedSource: context.sourceSize, frameSize: size, start: .zero))
        XCTAssertNil(StraightenDrawSession(context: context, displayedAngle: 0, displayedFlip: true,
            displayedSource: context.sourceSize, frameSize: size, start: .zero))
        XCTAssertNil(StraightenDrawSession(context: context, displayedAngle: 0, displayedFlip: false,
            displayedSource: CGSize(width: 1, height: 1), frameSize: size, start: .zero))
    }
}
#endif

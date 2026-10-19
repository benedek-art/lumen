#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

final class CropRectangleSessionTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/fixture/a.raw")
    private let b = URL(fileURLWithPath: "/fixture/b.raw")
    private let frame = CGSize(width: 1000, height: 1000)
    private let origin = Crop(x: 0.1, y: 0.1, w: 0.5, h: 0.5)
    private var context: CropRectangleContext {
        CropRectangleContext(photoID: a, primaryID: a,
                             sourceSize: CGSize(width: 6000, height: 6000), angle: 0,
                             flipH: false, frameAspect: 1, requestedAspect: nil)
    }

    func testMoveReleaseCommitsFinalTranslationBeforeClosing() throws {
        let session = try XCTUnwrap(CropRectangleSession(context: context, origin: origin,
                                                         operation: .move, frameSize: frame))
        var crop = origin
        var closed = false
        session.changed(translation: CGSize(width: 100, height: 0), context: context,
                        currentCrop: crop, frameSize: frame, apply: { crop = $0 })
        XCTAssertEqual(crop.x, 0.2, accuracy: 1e-12)
        session.ended(translation: CGSize(width: 200, height: 0), context: context,
                      currentCrop: crop, frameSize: frame, apply: { crop = $0 },
                      finish: { XCTAssertEqual(crop.x, 0.3, accuracy: 1e-12); closed = true })
        XCTAssertEqual(crop.y, origin.y)
        XCTAssertEqual(crop.w, origin.w)
        XCTAssertEqual(crop.h, origin.h)
        XCTAssertTrue(closed)
    }

    func testResizeReleaseCommitsFinalWidth() throws {
        let session = try XCTUnwrap(CropRectangleSession(context: context, origin: origin,
                                                 operation: .resizeHandle(.right), frameSize: frame))
        var crop = origin
        session.changed(translation: CGSize(width: 100, height: 0), context: context,
                        currentCrop: crop, frameSize: frame, apply: { crop = $0 })
        XCTAssertEqual(crop.w, 0.6, accuracy: 1e-12)
        session.ended(translation: CGSize(width: 200, height: 0), context: context,
                      currentCrop: crop, frameSize: frame, apply: { crop = $0 }, finish: {})
        XCTAssertEqual(crop.w, 0.7, accuracy: 1e-12)
        XCTAssertEqual(crop.x, 0.1)
        XCTAssertEqual(crop.h, origin.h)
    }

    func testFinalResizePreservesTheFrozenPixelAspect() throws {
        var target = context; target.requestedAspect = 1
        let session = try XCTUnwrap(CropRectangleSession(context: target, origin: origin,
                                             operation: .resizeHandle(.bottomRight), frameSize: frame))
        var crop = origin
        session.ended(translation: CGSize(width: 200, height: 0), context: target,
                      currentCrop: crop, frameSize: frame, apply: { crop = $0 }, finish: {})
        XCTAssertEqual(crop.w, 0.7, accuracy: 1e-12)
        XCTAssertEqual(crop.h, 0.7, accuracy: 1e-12)
        XCTAssertEqual(crop.w / crop.h * target.frameAspect, 1, accuracy: 1e-12)
    }

    func testPhotoGeometrySourceAndRatioChangesRejectMotionAndRelease() throws {
        var photo = context; photo.primaryID = b
        var source = context; source.sourceSize.width = 5000
        var angle = context; angle.angle = 5
        var flip = context; flip.flipH = true
        var aspect = context; aspect.frameAspect = 1.5
        var ratio = context; ratio.requestedAspect = 1
        for changed in [photo, source, angle, flip, aspect, ratio] {
            let session = try XCTUnwrap(CropRectangleSession(context: context, origin: origin,
                                                         operation: .move, frameSize: frame))
            var writes = 0
            var closes = 0
            session.changed(translation: CGSize(width: 100, height: 0), context: changed,
                            currentCrop: origin, frameSize: frame, apply: { _ in writes += 1 })
            session.ended(translation: CGSize(width: 200, height: 0), context: changed,
                          currentCrop: origin, frameSize: frame,
                          apply: { _ in writes += 1 }, finish: { closes += 1 })
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(closes, 1)
        }
    }

    func testConcurrentCropEditCannotBeOverwrittenOrReviveAfterReturning() throws {
        let session = try XCTUnwrap(CropRectangleSession(context: context, origin: origin,
                                                         operation: .move, frameSize: frame))
        var external = origin; external.x = 0.2
        var writes = 0
        session.changed(translation: CGSize(width: 100, height: 0), context: context,
                        currentCrop: external, frameSize: frame, apply: { _ in writes += 1 })
        session.ended(translation: CGSize(width: 200, height: 0), context: context,
                      currentCrop: origin, frameSize: frame, apply: { _ in writes += 1 }, finish: {})
        XCTAssertEqual(writes, 0)
    }

    func testChangedDisplaySizeRejectsTheOldTranslationBasis() throws {
        let session = try XCTUnwrap(CropRectangleSession(context: context, origin: origin,
                                                         operation: .move, frameSize: frame))
        var wrote = false
        var closed = false
        session.ended(translation: CGSize(width: 200, height: 0), context: context,
                      currentCrop: origin, frameSize: CGSize(width: 1200, height: 1000),
                      apply: { _ in wrote = true }, finish: { closed = true })
        XCTAssertFalse(wrote)
        XCTAssertTrue(closed)
    }

    func testObservedTargetExcursionStaysInvalidOnReturn() throws {
        let session = try XCTUnwrap(CropRectangleSession(context: context, origin: origin,
                                                         operation: .move, frameSize: frame))
        session.invalidate()
        var wrote = false
        session.ended(translation: CGSize(width: 200, height: 0), context: context,
                      currentCrop: origin, frameSize: frame, apply: { _ in wrote = true }, finish: {})
        XCTAssertFalse(wrote)
    }

    func testStalePhotoAndDegenerateFrameCannotStartSession() {
        var stale = context; stale.primaryID = b
        XCTAssertNil(CropRectangleSession(context: stale, origin: origin,
                                          operation: .move, frameSize: frame))
        XCTAssertNil(CropRectangleSession(context: context, origin: origin,
                                          operation: .move, frameSize: .zero))
    }

    func testReleaseOnlyUsesExistingFrameBoundaryClamps() throws {
        let session = try XCTUnwrap(CropRectangleSession(context: context, origin: origin,
                                                         operation: .move, frameSize: frame))
        var crop = origin
        session.ended(translation: CGSize(width: 2000, height: -2000), context: context,
                      currentCrop: crop, frameSize: frame, apply: { crop = $0 }, finish: {})
        XCTAssertEqual(crop.x, 0.5)
        XCTAssertEqual(crop.y, 0)
        XCTAssertEqual(crop.w, 0.5)
        XCTAssertEqual(crop.h, 0.5)
    }
}
#endif

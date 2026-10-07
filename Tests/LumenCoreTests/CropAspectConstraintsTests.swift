import XCTest
@testable import LumenCore

final class CropAspectConstraintsTests: XCTestCase {
    func testAuditExtremeRatiosAreRejectedRatherThanSilentlyClamped() {
        XCTAssertEqual(CropGeometry.aspect(fromText: "60:1"), 60)
        XCTAssertEqual(CropGeometry.aspect(fromText: "1:60"), 1.0 / 60)
        for aspect in [60.0, 1.0 / 60] {
            let legacy = CropGeometry.refit(Crop(), aspect: aspect, sourceWidth: 6000,
                                            sourceHeight: 4000, degrees: 0)
            XCTAssertEqual(CropGeometry.displayedAspect(legacy, sourceWidth: 6000,
                                                       sourceHeight: 4000, degrees: 0)!,
                           aspect == 60 ? 30 : 0.075, accuracy: 1e-12)
            XCTAssertNil(CropGeometry.refitIfRepresentable(Crop(), aspect: aspect,
                         sourceWidth: 6000, sourceHeight: 4000, degrees: 0))
        }
    }

    func testFeasibleEndpointsAndNormalRatiosKeepTheirActualAspect() throws {
        for (w, h) in [(6000.0, 4000.0), (4000, 6000), (5000, 5000), (12000, 1000)] {
            for angle in [0.0, 7, -11, 30, 45, 90] {
                let range = try XCTUnwrap(CropGeometry.representableAspectRange(
                    sourceWidth: w, sourceHeight: h, degrees: angle))
                for ratio in [range.lowerBound, range.upperBound, 1, 1.5, 16.0 / 9]
                    where range.contains(ratio) {
                    let crop = try XCTUnwrap(CropGeometry.refitIfRepresentable(
                        Crop(x: 0.2, y: 0.3, w: 0.1, h: 0.1), aspect: ratio,
                        sourceWidth: w, sourceHeight: h, degrees: angle))
                    XCTAssertGreaterThanOrEqual(crop.w, 0.05)
                    XCTAssertGreaterThanOrEqual(crop.h, 0.05)
                    XCTAssertLessThanOrEqual(crop.x + crop.w, 1.0000000001)
                    XCTAssertLessThanOrEqual(crop.y + crop.h, 1.0000000001)
                    XCTAssertEqual(CropGeometry.displayedAspect(crop, sourceWidth: w,
                        sourceHeight: h, degrees: angle)!, ratio, accuracy: ratio * 1e-10)
                }
                for ratio in [range.lowerBound.nextDown, range.upperBound.nextUp] {
                    XCTAssertNil(CropGeometry.refitIfRepresentable(Crop(), aspect: ratio,
                        sourceWidth: w, sourceHeight: h, degrees: angle))
                }
            }
        }
    }

    func testExtremeTextRatiosRemainUsableOnSourcesThatCanRepresentThem() {
        XCTAssertNotNil(CropGeometry.refitIfRepresentable(Crop(), aspect: 60,
                        sourceWidth: 12000, sourceHeight: 1000, degrees: 0))
        XCTAssertNotNil(CropGeometry.refitIfRepresentable(Crop(), aspect: 1.0 / 60,
                        sourceWidth: 1000, sourceHeight: 12000, degrees: 0))
        XCTAssertNil(CropGeometry.refitIfRepresentable(Crop(), aspect: 60,
                     sourceWidth: 12000, sourceHeight: 1000, degrees: 45))
    }

    func testMissingInvalidDimensionsAndAngleCannotAuthorizeANewLock() {
        for (w, h, angle) in [(0.0, 4000.0, 0.0), (6000, 0, 0), (-1, 4, 0),
                              (.infinity, 4, 0), (6, .nan, 0), (6, 4, .nan)] {
            XCTAssertNil(CropGeometry.representableAspectRange(sourceWidth: w,
                                                              sourceHeight: h, degrees: angle))
            XCTAssertNil(CropGeometry.refitIfRepresentable(Crop(), aspect: 1.5,
                         sourceWidth: w, sourceHeight: h, degrees: angle))
            XCTAssertNil(CropGeometry.swapIfRepresentable(Crop(), sourceWidth: w,
                                                         sourceHeight: h, degrees: angle))
        }
    }

    func testImpossibleSwapIsRejectedAndOrdinarySwapKeepsLegacyFraming() {
        let extreme = Crop(w: 1, h: 0.05)
        XCTAssertNil(CropGeometry.swapIfRepresentable(extreme, sourceWidth: 6000,
                                                     sourceHeight: 4000, degrees: 0))
        let ordinary = Crop(x: 0.2, y: 0.1, w: 0.5, h: 0.7)
        XCTAssertEqual(CropGeometry.swapIfRepresentable(ordinary, sourceWidth: 6000,
                                                        sourceHeight: 4000, degrees: 7),
                       CropGeometry.swappingOrientation(ordinary, sourceWidth: 6000,
                                                         sourceHeight: 4000, degrees: 7))
    }

    func testOldInvalidOrMismatchedLocksAreInactiveWithoutRewritingTheCrop() {
        let crop = Crop(x: 0.1, y: 0.2, w: 0.5, h: 0.5)
        XCTAssertEqual(CropGeometry.effectiveLockedAspect(1.5, crop: crop, frameAspect: 1.5), 1.5)
        for requested in [60.0, 1.0 / 60, 2, .nan, .infinity, -1, 0] {
            XCTAssertNil(CropGeometry.effectiveLockedAspect(requested, crop: crop, frameAspect: 1.5))
        }
        XCTAssertNil(CropGeometry.effectiveLockedAspect(1.5, crop: crop, frameAspect: 0))
        XCTAssertNil(CropGeometry.effectiveLockedAspect(1.5, crop: crop, frameAspect: 2.0 / 3))
        XCTAssertEqual(crop, Crop(x: 0.1, y: 0.2, w: 0.5, h: 0.5))
    }

    func testStraighteningCanDeactivateAnExtremeLockButKeepsOrdinaryLocks() throws {
        for aspect in [1.5, 60] {
            let original = try XCTUnwrap(CropGeometry.refitIfRepresentable(Crop(), aspect: aspect,
                sourceWidth: 12000, sourceHeight: 1000, degrees: 0))
            let rotated = CropGeometry.reangled(original, sourceWidth: 12000, sourceHeight: 1000,
                                                from: 0, to: 45)
            let usable = CropGeometry.usableSize(width: 12000, height: 1000, degrees: 45)
            let eligible = CropGeometry.effectiveLockedAspect(aspect, crop: rotated,
                                                              frameAspect: usable.width / usable.height)
            if aspect == 60 { XCTAssertNil(eligible) } else { XCTAssertEqual(eligible, aspect) }
            XCTAssertEqual(CropGeometry.displayedAspect(original, sourceWidth: 12000,
                sourceHeight: 1000, degrees: 0)!, aspect, accuracy: 1e-10,
                "Inspection did not refit the old crop")
        }
    }
}

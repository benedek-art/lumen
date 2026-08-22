import XCTest
@testable import LumenCore

/// The crop rectangle's arithmetic, which lived in `#if os(macOS)` code with no test of
/// any kind until this file existed.
final class CropGeometryTests: XCTestCase {

    // MARK: - The inscribed rectangle

    func testAnUnrotatedFrameIsItsOwnUsableFrame() {
        for (w, h) in [(6000.0, 4000.0), (4000.0, 6000.0), (5000.0, 5000.0)] {
            let usable = CropGeometry.usableSize(width: w, height: h, degrees: 0)
            XCTAssertEqual(usable.width, w, accuracy: 1e-9)
            XCTAssertEqual(usable.height, h, accuracy: 1e-9)
        }
    }

    /// The one case with a closed form anybody can check by hand: a square at 45°
    /// contains a square of side `s/√2`, and it is also exactly where the formula's two
    /// branches meet. If the join were a fudge this is where it would show.
    func testASquareAtFortyFiveDegrees() {
        let usable = CropGeometry.usableSize(width: 1000, height: 1000, degrees: 45)
        XCTAssertEqual(usable.width, 1000 / 2.0.squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(usable.height, 1000 / 2.0.squareRoot(), accuracy: 1e-6)
    }

    func testNinetyDegreesSwapsTheSides() {
        let usable = CropGeometry.usableSize(width: 6000, height: 4000, degrees: 90)
        XCTAssertEqual(usable.width, 4000, accuracy: 1e-6)
        XCTAssertEqual(usable.height, 6000, accuracy: 1e-6)
    }

    func testTheUsableFrameOnlyEverShrinks() {
        for (w, h) in [(6000.0, 4000.0), (4000.0, 6000.0), (5000.0, 5000.0), (7000.0, 1000.0)] {
            var previousArea = w * h
            var degrees = 0.0
            while degrees <= 45 {
                let usable = CropGeometry.usableSize(width: w, height: h, degrees: degrees)
                let area = usable.width * usable.height
                XCTAssertLessThanOrEqual(area, previousArea + 1e-6,
                                         "\(w)x\(h) at \(degrees)° inscribes more area "
                                             + "than at \(degrees - 0.5)°")
                previousArea = area
                degrees += 0.5
            }
        }
    }

    func testTheSignOfTheAngleDoesNotChangeTheSize() {
        for degrees in stride(from: 0.5, through: 45, by: 0.5) {
            let plus = CropGeometry.usableSize(width: 6000, height: 4000, degrees: degrees)
            let minus = CropGeometry.usableSize(width: 6000, height: 4000, degrees: -degrees)
            XCTAssertEqual(plus.width, minus.width, accuracy: 1e-9)
            XCTAssertEqual(plus.height, minus.height, accuracy: 1e-9)
        }
    }

    // MARK: - The invariant this whole file exists for

    /// Every corner of the resolved crop lies inside the source picture, at every angle
    /// the straighten slider can produce and for every crop.
    ///
    /// This is what "no transparent corners" means, asserted directly rather than by
    /// checking a formula against itself: the corner is rotated BACK into the source's
    /// own axes and compared with the source's half-extents.
    ///
    /// The construction it replaced took the crop as a fraction of the rotated frame's
    /// axis-aligned BOUNDING BOX, which is strictly larger than the picture — 12% larger
    /// in area for a 3:2 frame at 5° — so the default crop of the whole frame put all
    /// four corners in the empty wedges.
    func testEveryResolvedCornerIsInsideThePicture() {
        let crops: [Crop] = [
            Crop(),
            Crop(x: 0, y: 0, w: 1, h: 1),
            Crop(x: 0, y: 0, w: 0.5, h: 0.5),
            Crop(x: 0.5, y: 0.5, w: 0.5, h: 0.5),
            Crop(x: 0.25, y: 0.1, w: 0.7, h: 0.85),
            Crop(x: 0.9, y: 0.9, w: 0.1, h: 0.1),
        ]
        for (w, h) in [(6000.0, 4000.0), (4000.0, 6000.0), (5000.0, 5000.0)] {
            for degrees in stride(from: -45.0, through: 45.0, by: 1.5) {
                for crop in crops {
                    var geometry = Geometry()
                    geometry.angle = degrees
                    geometry.crop = crop
                    let r = CropGeometry.resolve(sourceWidth: w, sourceHeight: h,
                                                 geometry: geometry)
                    for (cx, cy) in [(r.x, r.y), (r.x + r.width, r.y),
                                     (r.x, r.y + r.height),
                                     (r.x + r.width, r.y + r.height)] {
                        XCTAssertTrue(
                            CropGeometry.containsInSource(x: cx, y: cy,
                                                          sourceWidth: w, sourceHeight: h,
                                                          degrees: degrees),
                            "\(w)x\(h) at \(degrees)°, crop \(crop): corner "
                                + "(\(cx), \(cy)) falls outside the picture")
                    }
                }
            }
        }
    }

    /// And the corner check itself can fail, or the test above proves nothing. The
    /// bounding box of a rotated frame is what the old code used; its corners must be
    /// outside.
    func testTheCornerCheckRejectsTheOldBoundingBox() {
        let w = 6000.0, h = 4000.0, degrees = 8.0
        let radians = degrees * .pi / 180
        let boxW = w * abs(cos(radians)) + h * abs(sin(radians))
        let boxH = w * abs(sin(radians)) + h * abs(cos(radians))
        let usable = CropGeometry.usableSize(width: w, height: h, degrees: degrees)
        XCTAssertGreaterThan(boxW * boxH, usable.width * usable.height * 1.2,
                             "the bounding box should be much larger than the inscribed "
                                 + "rectangle, or this test is not testing the old bug")
        // Its top-left corner, expressed in the usable frame's coordinates.
        let cx = (usable.width - boxW) / 2
        let cy = (usable.height - boxH) / 2
        XCTAssertFalse(CropGeometry.containsInSource(x: cx, y: cy, sourceWidth: w,
                                                     sourceHeight: h, degrees: degrees),
                       "the bounding box's corner reads as inside the picture, so the "
                           + "invariant above cannot fail")
    }

    // MARK: - Normalization

    func testAnUntrustedCropIsPulledBackInsideRatherThanShrunk() {
        // Off the right edge: the POSITION is wrong, and shrinking it would change the
        // composition instead of moving it.
        let out = CropGeometry.normalized(Crop(x: 0.8, y: 0.1, w: 0.5, h: 0.5))
        XCTAssertEqual(out.w, 0.5, accuracy: 1e-12, "the width was shrunk, not moved")
        XCTAssertEqual(out.x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(out.y, 0.1, accuracy: 1e-12)
    }

    func testNonFiniteAndDegenerateCropsSurvive() {
        for crop in [Crop(x: .nan, y: 0, w: 1, h: 1),
                     Crop(x: 0, y: 0, w: 0, h: 0),
                     Crop(x: 0, y: 0, w: .infinity, h: 1),
                     Crop(x: -5, y: -5, w: 20, h: 20)] {
            let out = CropGeometry.normalized(crop)
            XCTAssertTrue(out.x.isFinite && out.y.isFinite && out.w.isFinite && out.h.isFinite)
            XCTAssertGreaterThanOrEqual(out.w, CropGeometry.minimumCropFraction)
            XCTAssertGreaterThanOrEqual(out.h, CropGeometry.minimumCropFraction)
            XCTAssertLessThanOrEqual(out.x + out.w, 1 + 1e-12)
            XCTAssertLessThanOrEqual(out.y + out.h, 1 + 1e-12)
        }
    }

    func testADegenerateSourceDoesNotTrap() {
        for (w, h) in [(0.0, 100.0), (100.0, 0.0), (-10.0, 10.0), (Double.nan, 100.0)] {
            let usable = CropGeometry.usableSize(width: w, height: h, degrees: 12)
            XCTAssertTrue(usable.width.isFinite && usable.height.isFinite)
        }
    }

    // MARK: - Output size

    func testTargetLongEdgeScalesTheCropNotTheSource() {
        var geometry = Geometry()
        geometry.crop = Crop(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
        let r = CropGeometry.resolve(sourceWidth: 6000, sourceHeight: 4000,
                                     geometry: geometry, targetLongEdge: 1500)
        // The crop is 3000x2000; the long edge of the OUTPUT is what the target names.
        XCTAssertEqual(r.outputWidth, 1500)
        XCTAssertEqual(r.outputHeight, 1000)
    }

    func testUpscaleIsRefusedUnlessAskedFor() {
        var geometry = Geometry()
        geometry.crop = Crop(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        let source = (w: 6000.0, h: 4000.0)
        let refused = CropGeometry.resolve(sourceWidth: source.w, sourceHeight: source.h,
                                           geometry: geometry, targetLongEdge: 4000)
        XCTAssertEqual(refused.scale, 1, accuracy: 1e-12)
        XCTAssertEqual(refused.outputWidth, 1200)

        let allowed = CropGeometry.resolve(sourceWidth: source.w, sourceHeight: source.h,
                                           geometry: geometry, targetLongEdge: 4000,
                                           allowUpscale: true)
        XCTAssertEqual(allowed.outputWidth, 4000)
    }

    func testAFullFrameCropAtZeroAngleIsTheWholeSource() {
        let r = CropGeometry.resolve(sourceWidth: 8256, sourceHeight: 5504,
                                     geometry: Geometry())
        XCTAssertEqual(r.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0, accuracy: 1e-9)
        XCTAssertEqual(r.outputWidth, 8256)
        XCTAssertEqual(r.outputHeight, 5504)
    }
}

/// Dragging: eight handles, an aspect lock that survives the clamp, and a floor.
final class CropDragTests: XCTestCase {

    /// 3:2 source, so a normalized ratio and a pixel ratio are never accidentally equal
    /// and a conversion error cannot pass unnoticed.
    private let frameAspect = 1.5

    private func pixelAspect(_ c: Crop) -> Double { (c.w * frameAspect) / c.h }

    // MARK: Free dragging

    func testACornerDragMovesOnlyThatCorner() {
        let start = Crop(x: 0.2, y: 0.2, w: 0.6, h: 0.6)
        let out = CropGeometry.resize(start, handle: .topLeft, dx: 0.1, dy: 0.05)
        XCTAssertEqual(out.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(out.y, 0.25, accuracy: 1e-12)
        // The opposite corner is the anchor and must not have moved.
        XCTAssertEqual(out.x + out.w, 0.8, accuracy: 1e-12)
        XCTAssertEqual(out.y + out.h, 0.8, accuracy: 1e-12)
    }

    func testAnEdgeDragMovesOnlyThatEdge() {
        let start = Crop(x: 0.2, y: 0.2, w: 0.6, h: 0.6)
        for (handle, dx, dy) in [(CropGeometry.Handle.top, 0.0, 0.1),
                                 (.bottom, 0.0, -0.1),
                                 (.left, 0.1, 0.0),
                                 (.right, -0.1, 0.0)] {
            let out = CropGeometry.resize(start, handle: handle, dx: dx, dy: dy)
            if handle == .top || handle == .bottom {
                XCTAssertEqual(out.x, start.x, accuracy: 1e-12, "\(handle) moved x")
                XCTAssertEqual(out.w, start.w, accuracy: 1e-12, "\(handle) changed width")
            } else {
                XCTAssertEqual(out.y, start.y, accuracy: 1e-12, "\(handle) moved y")
                XCTAssertEqual(out.h, start.h, accuracy: 1e-12, "\(handle) changed height")
            }
        }
    }

    func testEveryHandleStaysInsideTheFrameAndAboveTheFloor() {
        let start = Crop(x: 0.3, y: 0.3, w: 0.4, h: 0.4)
        for handle in CropGeometry.Handle.allCases {
            for d in stride(from: -2.0, through: 2.0, by: 0.13) {
                for locked in [nil, 1.0, 16.0 / 9.0] as [Double?] {
                    let out = CropGeometry.resize(start, handle: handle, dx: d, dy: d,
                                                  lockedAspect: locked,
                                                  frameAspect: frameAspect)
                    XCTAssertGreaterThanOrEqual(out.x, -1e-12, "\(handle) d\(d)")
                    XCTAssertGreaterThanOrEqual(out.y, -1e-12, "\(handle) d\(d)")
                    XCTAssertLessThanOrEqual(out.x + out.w, 1 + 1e-9, "\(handle) d\(d)")
                    XCTAssertLessThanOrEqual(out.y + out.h, 1 + 1e-9, "\(handle) d\(d)")
                    XCTAssertGreaterThanOrEqual(out.w, CropGeometry.minimumCropFraction - 1e-12)
                    XCTAssertGreaterThanOrEqual(out.h, CropGeometry.minimumCropFraction - 1e-12)
                }
            }
        }
    }

    // MARK: The lock

    /// The defect this exists for: pick 3:2 from the menu, drag a corner, and the crop
    /// silently became free-form — the menu then read the rectangle back and reported
    /// "Custom".
    func testALockedDragKeepsThePixelAspect() {
        let start = CropGeometry.centred(aspect: 1.5, sourceWidth: 6000,
                                         sourceHeight: 4000, degrees: 0)
        for handle in CropGeometry.Handle.allCases {
            for d in stride(from: -0.5, through: 0.5, by: 0.05) {
                let out = CropGeometry.resize(start, handle: handle, dx: d, dy: d * 0.6,
                                              lockedAspect: 1.5, frameAspect: frameAspect)
                XCTAssertEqual(pixelAspect(out), 1.5, accuracy: 1e-6,
                               "\(handle) at \(d) drifted to \(pixelAspect(out))")
            }
        }
    }

    /// And through the CLAMP, which is the half that is easy to miss: pushing a locked
    /// crop into a corner has to shrink both axes. Clamping the offending edge alone is
    /// exactly how a lock becomes "Custom" the moment it touches the frame.
    func testALockedDragKeepsTheAspectAgainstTheFrameEdge() {
        let start = Crop(x: 0.05, y: 0.05, w: 0.3, h: 0.3)
        for aspect in [1.0, 1.5, 16.0 / 9.0, 2.0 / 3.0] {
            for handle in CropGeometry.Handle.allCases {
                let out = CropGeometry.resize(start, handle: handle, dx: -3, dy: -3,
                                              lockedAspect: aspect,
                                              frameAspect: frameAspect)
                XCTAssertEqual(pixelAspect(out), aspect, accuracy: 1e-6,
                               "\(handle) at aspect \(aspect) drifted against the edge")
                XCTAssertLessThanOrEqual(out.x + out.w, 1 + 1e-9)
                XCTAssertLessThanOrEqual(out.y + out.h, 1 + 1e-9)
            }
        }
    }

    func testALockedEdgeDragGrowsAboutTheOppositeEdgesMidpoint() {
        let start = Crop(x: 0.2, y: 0.3, w: 0.4, h: 0.4)
        let out = CropGeometry.resize(start, handle: .right, dx: 0.1,
                                      lockedAspect: 1.0, frameAspect: frameAspect)
        // The left edge is the anchor and holds.
        XCTAssertEqual(out.x, start.x, accuracy: 1e-12)
        // The height follows the lock, centred on where it was — not walking upward.
        XCTAssertEqual(out.y + out.h / 2, start.y + start.h / 2, accuracy: 1e-12)
        XCTAssertEqual(pixelAspect(out), 1.0, accuracy: 1e-9)
    }

    // MARK: The ratio menu

    func testTheMenuReadsBackWhatItWrote() {
        for aspect in [1.0, 1.5, 16.0 / 9.0, 4.0 / 5.0, 2.0 / 3.0] {
            for (w, h) in [(6000.0, 4000.0), (4000.0, 6000.0), (5000.0, 5000.0)] {
                for degrees in [0.0, 3.5, -12.0] {
                    let crop = CropGeometry.centred(aspect: aspect, sourceWidth: w,
                                                    sourceHeight: h, degrees: degrees)
                    let read = CropGeometry.displayedAspect(crop, sourceWidth: w,
                                                            sourceHeight: h,
                                                            degrees: degrees)
                    XCTAssertEqual(read ?? 0, aspect, accuracy: 1e-6,
                                   "\(w)x\(h) at \(degrees)° wrote \(aspect) and read "
                                       + "back \(read ?? 0)")
                }
            }
        }
    }

    /// The menu's ratio is read against the USABLE frame. Reading it against the source's
    /// aspect instead is the same class of error that once made "1:1" produce an 8:9
    /// rectangle on a 4:3 body — it just needs a straighten angle to show up.
    func testTheMenusRatioIsAgainstTheUsableFrameNotTheSource() {
        let w = 6000.0, h = 4000.0, degrees = 20.0
        let crop = CropGeometry.centred(aspect: 1.0, sourceWidth: w, sourceHeight: h,
                                        degrees: degrees)
        let usable = CropGeometry.usableSize(width: w, height: h, degrees: degrees)
        let naive = (crop.w * (w / h)) / crop.h
        XCTAssertNotEqual(naive, 1.0, accuracy: 0.05,
                          "the source-aspect reading happens to agree here, so this "
                              + "test cannot show the difference")
        XCTAssertEqual(CropGeometry.displayedAspect(crop, sourceWidth: w, sourceHeight: h,
                                                    degrees: degrees) ?? 0,
                       1.0, accuracy: 1e-6)
        XCTAssertNotEqual(usable.width / usable.height, w / h, accuracy: 0.01)
    }

    func testCentredCropsAreCentredAndMaximal() {
        for aspect in [1.0, 1.5, 16.0 / 9.0, 0.5] {
            let crop = CropGeometry.centred(aspect: aspect, sourceWidth: 6000,
                                            sourceHeight: 4000, degrees: 0)
            XCTAssertEqual(crop.x + crop.w / 2, 0.5, accuracy: 1e-9)
            XCTAssertEqual(crop.y + crop.h / 2, 0.5, accuracy: 1e-9)
            // One axis must be flush with the frame, or it is not the largest that fits.
            XCTAssertTrue(abs(crop.w - 1) < 1e-9 || abs(crop.h - 1) < 1e-9,
                          "aspect \(aspect) left slack on both axes: \(crop)")
        }
    }

    // MARK: Moving

    func testMovingNeverResizes() {
        let start = Crop(x: 0.2, y: 0.2, w: 0.5, h: 0.5)
        for d in stride(from: -2.0, through: 2.0, by: 0.17) {
            let out = CropGeometry.move(start, dx: d, dy: -d)
            XCTAssertEqual(out.w, start.w, accuracy: 1e-12)
            XCTAssertEqual(out.h, start.h, accuracy: 1e-12)
            XCTAssertGreaterThanOrEqual(out.x, -1e-12)
            XCTAssertLessThanOrEqual(out.x + out.w, 1 + 1e-12)
        }
    }
}

import XCTest
@testable import LumenCore

/// The crop tool's hands (lane C1, SPEC M1–M5): ⌥-drag about the centre, dragging the
/// picture, the arrow nudge, constrain-to-image through a rotation, and the largest
/// rectangle at a locked ratio.
final class CropInteractionTests: XCTestCase {

    private struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private func centre(_ c: Crop) -> (Double, Double) { (c.x + c.w / 2, c.y + c.h / 2) }

    // MARK: M1 — ⌥-drag

    func testAltResizeIsAboutTheCentre() {
        let start = Crop(x: 0.3, y: 0.3, w: 0.4, h: 0.3)
        for handle in CropGeometry.Handle.allCases {
            for (dx, dy) in [(0.05, 0.03), (-0.08, -0.04), (0.01, -0.02)] {
                let out = CropGeometry.resizeAboutCentre(start, handle: handle, dx: dx, dy: dy)
                let (cx, cy) = centre(out)
                XCTAssertEqual(cx, 0.5, accuracy: 1e-9, "\(handle)")
                XCTAssertEqual(cy, 0.45, accuracy: 1e-9, "\(handle)")
            }
        }
        // A corner moving right by dx widens the crop by 2·dx.
        let wider = CropGeometry.resizeAboutCentre(start, handle: .bottomRight, dx: 0.05, dy: 0)
        XCTAssertEqual(wider.w, 0.5, accuracy: 1e-9)
        XCTAssertEqual(wider.h, 0.3, accuracy: 1e-9)
        // An edge moves one axis only.
        let taller = CropGeometry.resizeAboutCentre(start, handle: .top, dx: 0.2, dy: -0.05)
        XCTAssertEqual(taller.w, 0.4, accuracy: 1e-9)
        XCTAssertEqual(taller.h, 0.4, accuracy: 1e-9)
    }

    func testAltResizeStopsAtTheNearerEdge() {
        // Centre at x = 0.3: the room is 2 × 0.3 = 0.6 wide, whatever the drag asks.
        let start = Crop(x: 0.2, y: 0.4, w: 0.2, h: 0.2)
        let out = CropGeometry.resizeAboutCentre(start, handle: .right, dx: 0.9)
        XCTAssertEqual(out.w, 0.6, accuracy: 1e-9)
        XCTAssertEqual(centre(out).0, 0.3, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(out.x, 0)
    }

    func testAltResizeLockedKeepsRatio() {
        let frameAspect = 1.5
        let locked = 16.0 / 9.0
        let start = CropGeometry.centred(aspect: locked, sourceWidth: 3000, sourceHeight: 2000,
                                         degrees: 0)
        let small = CropGeometry.resizeAboutCentre(start, handle: .topLeft, dx: 0.2, dy: 0.1,
                                                   lockedAspect: locked,
                                                   frameAspect: frameAspect)
        for handle in CropGeometry.Handle.allCases {
            for (dx, dy) in [(0.3, 0.2), (-0.1, -0.1), (-0.6, 0.4), (0.05, -0.3)] {
                let out = CropGeometry.resizeAboutCentre(small, handle: handle, dx: dx, dy: dy,
                                                         lockedAspect: locked,
                                                         frameAspect: frameAspect)
                XCTAssertEqual(out.w / out.h * frameAspect, locked, accuracy: 1e-9,
                               "\(handle) \(dx) \(dy)")
                XCTAssertEqual(centre(out).0, centre(small).0, accuracy: 1e-9)
                XCTAssertEqual(centre(out).1, centre(small).1, accuracy: 1e-9)
                XCTAssertLessThanOrEqual(out.x + out.w, 1 + 1e-12)
                XCTAssertLessThanOrEqual(out.y + out.h, 1 + 1e-12)
                XCTAssertGreaterThanOrEqual(out.x, -1e-12)
                XCTAssertGreaterThanOrEqual(out.y, -1e-12)
            }
        }
    }

    // MARK: M2 — dragging the picture

    func testPanImageMovesCropOppositeAndClampsAtTheEdge() {
        let start = Crop(x: 0.2, y: 0.3, w: 0.5, h: 0.4)
        let pan = CropGeometry.panImage(start, dx: 0.1, dy: -0.05)
        // Picture right by 0.1 = crop left by 0.1 over it.
        XCTAssertEqual(pan.crop.x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(pan.crop.y, 0.35, accuracy: 1e-12)
        XCTAssertEqual(pan.dx, 0.1, accuracy: 1e-12)
        XCTAssertEqual(pan.dy, -0.05, accuracy: 1e-12)
        XCTAssertEqual(pan.crop.w, 0.5)
        XCTAssertEqual(pan.crop.h, 0.4)

        // Far past the edge: the crop stops at x = 0 and the picture stops following.
        let far = CropGeometry.panImage(start, dx: 0.9, dy: -0.9)
        XCTAssertEqual(far.crop.x, 0, accuracy: 1e-12)
        XCTAssertEqual(far.crop.y, 0.6, accuracy: 1e-12)
        XCTAssertEqual(far.dx, 0.2, accuracy: 1e-12)
        XCTAssertEqual(far.dy, -0.3, accuracy: 1e-12)

        let nan = CropGeometry.panImage(start, dx: .nan, dy: 0)
        XCTAssertEqual(nan.crop, start)
        XCTAssertEqual(nan.dx, 0)
    }

    // MARK: M3 — arrow keys

    func testNudgeClampsAndKeepsSize() {
        var c = Crop(x: 0.1, y: 0.1, w: 0.6, h: 0.5)
        c = CropGeometry.nudge(c, stepsX: 1, stepsY: 0)
        XCTAssertEqual(c.x, 0.1 + CropGeometry.nudgeStep, accuracy: 1e-12)
        c = CropGeometry.nudge(c, stepsX: 0, stepsY: -1, shift: true)
        XCTAssertEqual(c.y, 0.1 - CropGeometry.nudgeStep * 10, accuracy: 1e-12)
        for _ in 0..<1000 { c = CropGeometry.nudge(c, stepsX: 1, stepsY: 1, shift: true) }
        XCTAssertEqual(c.x, 0.4, accuracy: 1e-12)
        XCTAssertEqual(c.y, 0.5, accuracy: 1e-12)
        XCTAssertEqual(c.w, 0.6, accuracy: 1e-12)
        XCTAssertEqual(c.h, 0.5, accuracy: 1e-12)
    }

    // MARK: M4 — constrain to image through a rotation

    /// Rotate by θ, carry the crop through `reangled`, and the rectangle must still be
    /// entirely picture: no transparent corner at any angle, for any crop.
    func testReangledCropNeverLeavesTheRotatedPicture() {
        var rng = Rng(state: 0xC1C1)
        let frames: [(Double, Double)] = [(6000, 4000), (4000, 6000), (5000, 5000), (7000, 1000)]
        for (w, h) in frames {
            for _ in 0..<10 {
                let cw = 0.1 + 0.9 * rng.next()
                let ch = 0.1 + 0.9 * rng.next()
                var crop = Crop(x: rng.next() * (1 - cw), y: rng.next() * (1 - ch), w: cw, h: ch)
                var angle = 0.0
                var theta = -45.0
                while theta <= 45 {
                    crop = CropGeometry.reangled(crop, sourceWidth: w, sourceHeight: h,
                                                 from: angle, to: theta)
                    angle = theta
                    XCTAssertTrue(CropGeometry.cropIsInsidePicture(crop, sourceWidth: w,
                                                                    sourceHeight: h,
                                                                    degrees: theta),
                                  "\(w)×\(h) at \(theta)°: \(crop)")
                    theta += 0.5
                }
            }
        }
    }

    /// A locked ratio survives the turn: the carried crop keeps its pixel aspect.
    func testReangledKeepsALockedPixelRatio() {
        let start = CropGeometry.centred(aspect: 16.0 / 9, sourceWidth: 6000, sourceHeight: 4000,
                                         degrees: 0)
        var crop = start
        var angle = 0.0
        for theta in stride(from: 0.0, through: 12, by: 0.5) {
            crop = CropGeometry.reangled(crop, sourceWidth: 6000, sourceHeight: 4000,
                                         from: angle, to: theta)
            angle = theta
            let aspect = CropGeometry.displayedAspect(crop, sourceWidth: 6000, sourceHeight: 4000,
                                                      degrees: theta)!
            XCTAssertEqual(aspect, 16.0 / 9, accuracy: 1e-9, "at \(theta)°")
        }
    }

    // MARK: M5 — the largest rectangle at a ratio

    /// Brute force: every rectangle at the ratio, at 200 sizes × 200 offsets, that fits
    /// the usable frame. `largestRect` must be within 0.5 % of the best area found.
    func testLargestRectAtAspectBeatsBruteForceInTheUsableFrame() {
        for (w, h) in [(6000.0, 4000.0), (4000.0, 6000.0)] {
            for degrees in [0.0, 3, 10, 25] {
                for aspect in [1.0, 4.0 / 5, 16.0 / 9, 3.0] {
                    let usable = CropGeometry.usableSize(width: w, height: h, degrees: degrees)
                    let rect = CropGeometry.largestRect(aspect: aspect, sourceWidth: w,
                                                        sourceHeight: h, degrees: degrees)
                    let area = rect.w * usable.width * rect.h * usable.height
                    var best = 0.0
                    for i in 1...200 {
                        let rw = usable.width * Double(i) / 200
                        let rh = rw / aspect
                        guard rh <= usable.height else { break }
                        for j in 0...20 {
                            let ox = (usable.width - rw) * Double(j) / 20
                            let oy = (usable.height - rh) * Double(j) / 20
                            let crop = Crop(x: ox / usable.width, y: oy / usable.height,
                                            w: rw / usable.width, h: rh / usable.height)
                            if CropGeometry.cropIsInsidePicture(crop, sourceWidth: w,
                                                                sourceHeight: h,
                                                                degrees: degrees) {
                                best = Swift.max(best, rw * rh)
                            }
                        }
                    }
                    XCTAssertGreaterThanOrEqual(area, best * 0.995,
                                                "\(w)×\(h) \(degrees)° \(aspect)")
                    XCTAssertTrue(CropGeometry.cropIsInsidePicture(rect, sourceWidth: w,
                                                                   sourceHeight: h,
                                                                   degrees: degrees))
                    let pixel = rect.w * usable.width / (rect.h * usable.height)
                    XCTAssertEqual(pixel, aspect, accuracy: 1e-9)
                }
            }
        }
    }

    /// The true Constrain-to-Image optimum, against a brute-force search over the turned
    /// picture itself: centred and offset boxes alike, the closed form is never beaten.
    func testLargestInRotatedImageMatchesBruteForce() {
        for (w, h) in [(6000.0, 4000.0), (3000.0, 3000.0)] {
            for degrees in [0.0, 5, 10, 30, -12] {
                for aspect in [1.0, 1.5, 0.8, 2.5] {
                    let best = CropGeometry.largestInRotatedImage(aspect: aspect, width: w,
                                                                  height: h, degrees: degrees)
                    let r = degrees * .pi / 180
                    let c = cos(r), s = sin(r)
                    func fits(_ bw: Double, _ bh: Double, _ ox: Double, _ oy: Double) -> Bool {
                        for (px, py) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
                            let x = ox + px * bw / 2, y = oy + py * bh / 2
                            let sx = x * c + y * s, sy = -x * s + y * c
                            if abs(sx) > w / 2 + 1e-6 || abs(sy) > h / 2 + 1e-6 { return false }
                        }
                        return true
                    }
                    XCTAssertTrue(fits(best.width, best.height, 0, 0))
                    XCTAssertFalse(fits(best.width * 1.001, best.height * 1.001, 0, 0))
                    // No offset box at the ratio is larger than the centred one.
                    for k in 0..<50 {
                        let ox = (Double(k % 7) - 3) * w * 0.02
                        let oy = (Double(k / 7) - 3) * h * 0.02
                        XCTAssertFalse(fits(best.width * 1.002, best.height * 1.002, ox, oy))
                    }
                }
            }
        }
    }

    /// Records, rather than hides, what the usable-frame model gives up against
    /// Lightroom's bound: at 10° on a 3:2 frame a 3:2 crop gets 92.1 % of the area
    /// Lightroom would allow and a 1:1 crop 79.7 % (REPORT.md, NEEDS.md). At angle 0
    /// the two agree.
    func testUsableFrameModelGapIsWhatTheReportSays() {
        func fraction(_ aspect: Double, _ degrees: Double) -> Double {
            let usable = CropGeometry.usableSize(width: 3000, height: 2000, degrees: degrees)
            let c = CropGeometry.largestRect(aspect: aspect, sourceWidth: 3000,
                                             sourceHeight: 2000, degrees: degrees)
            let ours = c.w * usable.width * c.h * usable.height
            let lr = CropGeometry.largestInRotatedImage(aspect: aspect, width: 3000,
                                                        height: 2000, degrees: degrees)
            return ours / (lr.width * lr.height)
        }
        XCTAssertEqual(fraction(1.0, 0), 1, accuracy: 1e-9)
        XCTAssertEqual(fraction(1.5, 0), 1, accuracy: 1e-9)
        XCTAssertEqual(fraction(1.5, 2), 0.997, accuracy: 0.001)
        XCTAssertEqual(fraction(1.5, 10), 0.921, accuracy: 0.001)
        XCTAssertEqual(fraction(1.0, 10), 0.797, accuracy: 0.001)
    }

    // MARK: Swap

    func testSwapIsAnInvolutionInPixels() {
        let crop = Crop(x: 0.25, y: 0.3, w: 0.3, h: 0.4)
        let once = CropGeometry.swappingOrientation(crop, sourceWidth: 6000, sourceHeight: 4000,
                                                    degrees: 0)
        let a0 = CropGeometry.displayedAspect(crop, sourceWidth: 6000, sourceHeight: 4000,
                                              degrees: 0)!
        let a1 = CropGeometry.displayedAspect(once, sourceWidth: 6000, sourceHeight: 4000,
                                              degrees: 0)!
        XCTAssertEqual(a1, 1 / a0, accuracy: 1e-9)
        let twice = CropGeometry.swappingOrientation(once, sourceWidth: 6000, sourceHeight: 4000,
                                                     degrees: 0)
        XCTAssertEqual(twice.w, crop.w, accuracy: 1e-9)
        XCTAssertEqual(twice.h, crop.h, accuracy: 1e-9)
        XCTAssertEqual(twice.x, crop.x, accuracy: 1e-9)
        XCTAssertEqual(twice.y, crop.y, accuracy: 1e-9)
    }
}

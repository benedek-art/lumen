// RadialFrameTests.swift
// The drawn ellipse must be the rendered ellipse.
//
// `MaskRaster.radialPlane` used to rotate in per-axis normalized space. That was fixed —
// pixels are square and normalized coordinates are not, so on a 3:2 frame a 45° ellipse
// rendered at 33.7° with the wrong eccentricity — and the fix converts to long-edge units
// before rotating. `MaskCanvas` was not brought along, and its own comment went on
// asserting "the rotation convention is the rasterizer's" for months after that stopped
// being true.
//
// The cost, on a 6000×4000 frame with a radial turned to 45°: the drawn rim, all four
// resize dots, the feather ring and the rotate stalk sat about 283 source pixels away
// from the mask that was rendering — roughly 85 screen points, against an 11 pt grab
// radius. The outline did not match the effect, and pressing the drawn rim could miss the
// real one and be read as "draw a new ellipse here", which throws the shape away.
//
// So the assertion that matters is not "the maths is self-consistent". It is **the point
// the handles draw is on the boundary the rasterizer paints** — checked against the
// rasterizer's actual output, not against a second copy of its formula.

import XCTest
@testable import LumenCore

final class RadialFrameTests: XCTestCase {

    private func radial(centre: [Double], radii: [Double], rotation: Double,
                        feather: Double = 0) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = centre
        c.radii = radii
        c.rotation = rotation
        c.feather = feather
        return c
    }

    // MARK: - Against the rasterizer

    /// The handle positions land on the rendered boundary, on a non-square frame, at
    /// every angle. This is the test the shipped code fails.
    ///
    /// Feather 0 makes the plane a hard step, so "on the boundary" is checkable: a sample
    /// just inside the reported rim must be selected and one just outside must not.
    func testTheMajorAxisHandleSitsOnTheRenderedRim() {
        let w = 300, h = 200                       // 3:2, the case that exposed it
        let centre = [0.5, 0.5], radii = [0.20, 0.20]

        for rotation in stride(from: 0.0, to: 180.0, by: 15.0) {
            let c = radial(centre: centre, radii: radii, rotation: rotation)
            let plane = MaskRaster.radialPlane(c, w, h)

            for (name, unit) in [("major", (x: 1.0, y: 0.0)), ("minor", (x: 0.0, y: 1.0))] {
                let r = name == "major" ? radii[0] : radii[1]
                // Just inside and just outside the rim, along the ellipse's own axis.
                for (scale, wanted) in [(0.90, true), (1.10, false)] {
                    let off = MaskRaster.radialOffset(
                        (x: unit.x * r * scale, y: unit.y * r * scale),
                        rotation: rotation, width: w, height: h)
                    let nx = centre[0] + off.x, ny = centre[1] + off.y
                    let px = Int(nx * Double(w)), py = Int(ny * Double(h))
                    guard px >= 0, px < w, py >= 0, py < h else {
                        XCTFail("\(name) handle at \(rotation)° left the frame")
                        continue
                    }
                    let selected = plane[px, py] > 0.5
                    XCTAssertEqual(selected, wanted,
                                   "\(name) axis at \(rotation)°, scale \(scale): "
                                       + "handle says \(wanted ? "inside" : "outside"), "
                                       + "the render says \(selected ? "inside" : "outside")")
                }
            }
        }
    }

    /// The specific number from the audit, as a regression pin.
    ///
    /// Per-axis rotation of `(0.20, 0)` by 45° on a 3:2 frame gives an offset of
    /// (0.1414, 0.1414); the correct long-edge rotation gives (0.1414, 0.2121). The
    /// difference in y is 0.0707 of the frame — 283 pixels on a 4000 px height. Writing
    /// it down means a future change back to the wrong convention fails by name.
    func testTheWrongConventionIsMeasurablyDifferent() {
        let w = 300, h = 200
        let correct = MaskRaster.radialOffset((x: 0.20, y: 0), rotation: 45,
                                              width: w, height: h)
        let wrongY = 0.20 * sin(45 * Double.pi / 180)   // the per-axis answer
        XCTAssertEqual(correct.x, 0.1414, accuracy: 1e-3)
        XCTAssertEqual(correct.y, 0.2121, accuracy: 1e-3,
                       "long-edge rotation must stretch y by the aspect ratio")
        XCTAssertEqual(abs(correct.y - wrongY), 0.0707, accuracy: 1e-3,
                       "the error the drawn handles used to carry")
    }

    // MARK: - Shape

    /// A square frame has nothing to correct, so the two conventions agree there — which
    /// is exactly why this shipped: every square test image passed.
    func testOnASquareFrameItIsAPlainRotation() {
        for rotation in stride(from: 0.0, through: 360.0, by: 30.0) {
            let got = MaskRaster.radialOffset((x: 0.3, y: 0), rotation: rotation,
                                              width: 256, height: 256)
            let a = rotation * Double.pi / 180
            XCTAssertEqual(got.x, 0.3 * cos(a), accuracy: 1e-12)
            XCTAssertEqual(got.y, 0.3 * sin(a), accuracy: 1e-12)
        }
    }

    /// At rotation 0 it is the identity on any frame — so an unrotated ellipse, which is
    /// most of them, is untouched by this whole conversion.
    func testRotationZeroIsIdentity() {
        for (w, h) in [(300, 200), (200, 300), (256, 256), (6000, 4000)] {
            let got = MaskRaster.radialOffset((x: 0.17, y: -0.09), rotation: 0,
                                              width: w, height: h)
            XCTAssertEqual(got.x, 0.17, accuracy: 1e-12)
            XCTAssertEqual(got.y, -0.09, accuracy: 1e-12)
        }
    }

    /// `radialLocal` inverts `radialOffset`. A resize drag reads through one and writes
    /// through the other, so a mismatch would make the shape move under the hand.
    func testTheLocalFrameIsTheExactInverse() {
        for (w, h) in [(300, 200), (200, 300), (4000, 6000)] {
            for rotation in stride(from: -180.0, through: 180.0, by: 22.5) {
                for delta in [(x: 0.2, y: 0.0), (x: 0.0, y: 0.15), (x: -0.13, y: 0.07)] {
                    let out = MaskRaster.radialOffset(delta, rotation: rotation,
                                                      width: w, height: h)
                    let back = MaskRaster.radialLocal(out, rotation: rotation,
                                                      width: w, height: h)
                    XCTAssertEqual(back.x, delta.x, accuracy: 1e-12,
                                   "round trip at \(rotation)° on \(w)×\(h)")
                    XCTAssertEqual(back.y, delta.y, accuracy: 1e-12,
                                   "round trip at \(rotation)° on \(w)×\(h)")
                }
            }
        }
    }

    /// A portrait frame is the same correction the other way round — the bug was not
    /// specific to landscape, and a fix that only handled `w > h` would pass every
    /// landscape test.
    func testPortraitIsCorrectedToo() {
        let w = 200, h = 300
        let got = MaskRaster.radialOffset((x: 0.20, y: 0), rotation: 90,
                                          width: w, height: h)
        // Rotating the major axis onto y: the x extent is normalised by the SHORT edge
        // and y by the long one, so the per-axis y shrinks by w/h.
        XCTAssertEqual(got.x, 0, accuracy: 1e-12)
        XCTAssertEqual(got.y, 0.20 * (Double(w) / Double(h)), accuracy: 1e-12)
    }

    /// Degenerate frames return the offset untouched rather than dividing by zero. A
    /// canvas asked to draw before it knows the image size must not produce NaN — a NaN
    /// centre puts every handle at the origin and the shape becomes ungrabbable.
    func testADegenerateFrameIsSafe() {
        for (w, h) in [(0, 0), (0, 100), (100, 0), (-4, 10)] {
            let got = MaskRaster.radialOffset((x: 0.2, y: 0.1), rotation: 30,
                                              width: w, height: h)
            XCTAssertTrue(got.x.isFinite && got.y.isFinite, "\(w)×\(h) produced NaN")
        }
    }
}

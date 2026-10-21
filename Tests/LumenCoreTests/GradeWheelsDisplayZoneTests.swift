// Lane K1 (WS-35): what the grading wheels promise a photographer, pinned at engine level.
//
// The zones are defined on DISPLAY LEVEL (0 = display black, 1 = display white) since
// lane K1. Before, they sat on scene EV normalised over −9…+5 EV and the default
// "Shadows" zone ended at display level 0.035 — the last ten code values above black.
// docs/quality/lanes/WS-35/SPEC.md has the end-to-end measurements; these are the
// engine-side halves of the same claims.
import XCTest
@testable import LumenCore

final class GradeWheelsDisplayZoneTests: XCTestCase {

    private func grade(_ configure: (inout GradingWheels) -> Void) -> GradeEngine {
        var wheels = GradingWheels()
        configure(&wheels)
        return GradeEngine(wheels: wheels, printerLights: PrinterLights())
    }

    /// SPEC 2: at the defaults the shadow and highlight weights cross 0.5 at a third and
    /// two thirds of display level, and the strip's pivots are those levels.
    func testTheDefaultZonesSitAtThirdsOfDisplayLevel() {
        let w = ZoneWindows()
        XCTAssertEqual(w.weights(atLevel: 0.33).shadows, 0.5, accuracy: 1e-9)
        XCTAssertEqual(w.weights(atLevel: 0.67).high, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(w.weights(atLevel: 0.5).mid, 0.8)
        // And a display level is what the scene tone renders at: mid-grey (0 EV) is in
        // the midtones, −3 EV is shadow, +2 EV is highlight.
        XCTAssertGreaterThan(w.weights(at: 0).mid, 0.75)
        XCTAssertGreaterThan(w.weights(at: -3).shadows, 0.9)
        XCTAssertGreaterThan(w.weights(at: 2).high, 0.75)
    }

    /// SPEC 9, engine side: Blending 0 is as hard an edge as the 33-cube preview table
    /// holds (10→90 % within 0.1 of display level; `ZoneWindows.minimumHalfWidth`),
    /// Blending 100 a broad overlap, and it widens monotonically.
    func testBlendingSpansHardToBroad() {
        func width(_ blending: Double) -> Double {
            let w = ZoneWindows(blending: blending)
            var u = 0.0, u90 = 0.0, u10 = 1.0
            while u <= 1 {
                let s = w.weights(atLevel: u).shadows
                if s >= 0.9 { u90 = u }
                if s <= 0.1 && u10 == 1.0 { u10 = u }
                u += 0.0005
            }
            return u10 - u90
        }
        let hard = width(0), soft = width(50), broad = width(100)
        XCTAssertLessThan(hard, 0.1)
        XCTAssertLessThan(hard, soft)
        XCTAssertLessThan(soft, broad)
        XCTAssertGreaterThan(broad, 0.5)
    }

    /// Partition of unity, never negative, at every Blending and Balance.
    func testTheWeightsArePartitionsOfUnityEverywhere() {
        for blending in [0.0, 30, 50, 100] {
            for balance in [-100.0, 0, 100] {
                let w = ZoneWindows(blending: blending, balance: balance)
                var u = -0.1
                while u <= 1.1 {
                    let z = w.weights(atLevel: u)
                    XCTAssertGreaterThanOrEqual(Swift.min(z.shadows, z.mid, z.high), 0)
                    XCTAssertEqual(z.shadows + z.mid + z.high, 1, accuracy: 1e-12)
                    u += 0.01
                }
            }
        }
    }

    /// The display-level table and its inverse agree.
    func testEVAtLevelInvertsTheDisplayLevel() {
        let w = ZoneWindows()
        for u in stride(from: 0.05, through: 0.95, by: 0.05) {
            XCTAssertEqual(w.displayLevel(at: w.ev(atLevel: u)), u, accuracy: 1e-9)
        }
    }

    /// SPEC 4: black stays black. A full Shadows tint does not touch a pixel that
    /// renders at display black, and fades in over the bottom of the range.
    func testAFullShadowTintLeavesBlackAlone() {
        let engine = grade { $0.shadows = Wheel(hue: 210, sat: 1, lum: 0) }
        let black = RGB(gray: 0.18 * pow(2.0, -12))
        let out = engine.apply(black)
        XCTAssertEqual(out.r, black.r, accuracy: 1e-15)
        XCTAssertEqual(out.g, black.g, accuracy: 1e-15)
        XCTAssertEqual(out.b, black.b, accuracy: 1e-15)
        // …and a visible shadow is tinted.
        let shadow = RGB(gray: 0.18 * pow(2.0, -3))
        let tinted = OKLabTransform.working.toLCh(engine.apply(shadow))
        XCTAssertGreaterThan(tinted.C, 0.05)
        XCTAssertEqual(tinted.h, 210, accuracy: 0.5)
    }

    /// SPEC 3: a Shadows tint leaves highlights alone and vice versa.
    func testZoneTintsStayInTheirZones() {
        let shadows = grade { $0.shadows = Wheel(hue: 210, sat: 1, lum: 0) }
        let highs = grade { $0.high = Wheel(hue: 40, sat: 1, lum: 0) }
        let bright = RGB(gray: 0.18 * 4)
        let dark = RGB(gray: 0.18 / 8)
        XCTAssertLessThan(OKLabTransform.working.toLCh(shadows.apply(bright)).C, 1e-6)
        XCTAssertLessThan(OKLabTransform.working.toLCh(highs.apply(dark)).C, 1e-6)
    }

    /// No tint pushes a colour through grey. A teal shadow tint on a dark skin tone
    /// keeps it warm; the same tint on a neutral of the same lightness lands at the
    /// wheel's hue at full strength.
    func testATintDoesNotDriveAnOpposedColourThroughGrey() {
        let engine = grade { $0.shadows = Wheel(hue: 205, sat: 0.6, lum: 0) }
        let ctx = OKLabTransform.working
        let skin = ctx.toRGB(OKLCh(L: 0.42, C: 0.06, h: 55))
        let out = ctx.toLCh(engine.apply(skin))
        XCTAssertLessThan(abs(((out.h - 55 + 540).truncatingRemainder(dividingBy: 360)) - 180),
                          90, "the skin tone crossed grey to the far side of the wheel: "
                              + "hue \(out.h)")
        let grey = ctx.toRGB(OKLCh(L: 0.42, C: 0, h: 0))
        let tinted = ctx.toLCh(engine.apply(grey))
        XCTAssertEqual(tinted.h, 205, accuracy: 0.5)
        // Along the colour's own hue, the tint is not eased at all.
        let warm = grade { $0.shadows = Wheel(hue: 55, sat: 0.6, lum: 0) }
        let pushed = ctx.toLCh(warm.apply(skin)).C - 0.06
        let onGrey = ctx.toLCh(warm.apply(grey)).C
        XCTAssertEqual(pushed, onGrey, accuracy: 0.004)
    }

    /// SPEC 8, engine side: a wheel's Luminance holds the hue of what it brightens, in
    /// the working space (the end-to-end number also carries the display shoulder).
    func testLuminanceHoldsHue() {
        let ctx = OKLabTransform.working
        for lum in [-1.0, 1.0] {
            for zone in 0..<4 {
                let engine = grade {
                    let w = Wheel(hue: 0, sat: 0, lum: lum)
                    switch zone {
                    case 0: $0.shadows = w
                    case 1: $0.mid = w
                    case 2: $0.high = w
                    default: $0.global = w
                    }
                }
                for h in stride(from: 0.0, to: 360, by: 30) {
                    for L in [0.35, 0.55, 0.75] {
                        let c = ctx.toRGB(OKLCh(L: L, C: 0.08, h: h))
                        let out = ctx.toLCh(engine.apply(c))
                        let d = abs(((out.h - h + 540).truncatingRemainder(dividingBy: 360))
                                    - 180)
                        XCTAssertLessThan(d, 1.0, "lum \(lum) zone \(zone) hue \(h) L \(L)")
                    }
                }
            }
        }
    }

    /// SPEC 1: every default is an exact identity.
    func testDefaultsAreIdentity() {
        XCTAssertTrue(GradeEngine(wheels: GradingWheels(), printerLights: PrinterLights())
                        .isIdentity)
    }
}

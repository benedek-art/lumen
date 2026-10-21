// WS-37 acceptance (docs/quality/lanes/WS-37/SPEC.md): printer lights behave like a
// lab's. A point is a twelfth of a stop of printing exposure on one channel, the three
// trims together are the master, and a trim on a neutral moves every tone toward one hue.

import Foundation
import XCTest
@testable import LumenCore

final class PrinterLightsLabTests: XCTestCase {

    private func gains(_ lights: PrinterLights) -> RGB {
        GradeEngine(wheels: GradingWheels(), printerLights: lights).printerLightGains
    }

    private func plan(_ lights: PrinterLights, exposure: Double = 0) -> RenderPlan {
        var recipe = Recipe()
        recipe.look.printerLights = lights
        recipe.develop.tone.exposure = exposure
        return RenderPlan(recipe: recipe)
    }

    /// SPEC P1. Twelve points is exactly one stop, bit for bit, on the master and on
    /// each trim; one point is 2^(1/12); the steps are equal in log at every count.
    func testP1APointIsExactlyATwelfthOfAStop() {
        XCTAssertEqual(gains(PrinterLights(master: 12)), RGB(2, 2, 2))
        XCTAssertEqual(gains(PrinterLights(master: -12)), RGB(0.5, 0.5, 0.5))
        XCTAssertEqual(gains(PrinterLights(r: 12)).r, 2)
        XCTAssertEqual(gains(PrinterLights(b: -24)).b, 0.25)
        for points in -48...47 {
            let step = log2(gains(PrinterLights(master: points + 1)).g)
                - log2(gains(PrinterLights(master: points)).g)
            XCTAssertEqual(step, 1.0 / 12, accuracy: 1e-12, "step at \(points)")
        }
    }

    /// SPEC P2. Equal trims ARE the master: the S6 matrix is bit-identical, so a neutral
    /// stays neutral and the panel's four dials have one meaning between them.
    func testP2EqualTrimsAreTheMasterBitForBit() {
        for k in -24...24 {
            XCTAssertEqual(plan(PrinterLights(r: k, g: k, b: k)).linear.matrix.m,
                           plan(PrinterLights(master: k)).linear.matrix.m, "k = \(k)")
        }
    }

    /// SPEC P3. The master is printing exposure: +12 points is the same S6 matrix as
    /// Exposure +1 EV, bit for bit, and so the same picture.
    func testP3TwelveMasterPointsAreOneStopOfExposure() {
        XCTAssertEqual(plan(PrinterLights(master: 12)).linear.matrix.m,
                       plan(PrinterLights(), exposure: 1).linear.matrix.m)
        XCTAssertEqual(plan(PrinterLights(master: -30)).linear.matrix.m,
                       plan(PrinterLights(), exposure: -2.5).linear.matrix.m)
    }

    /// SPEC P4. A trim on a neutral ramp, through the whole pipeline, moves every tone
    /// from deep shadow to near white toward ONE hue (OKLab, ±5°), and the shift is
    /// largest in the mid-tones and smaller toward white, as a print's paper curve gives.
    func testP4ATrimMovesEveryToneOfANeutralTowardOneHue() {
        let ramp = ImageBuffer(width: 64, height: 2) { u, _ in
            RGB(gray: 0.18 * pow(2, -6 + 9 * u))
        }
        let base = ReferenceRenderer.render(ramp, plan: plan(PrinterLights()))
        for (lights, name) in [(PrinterLights(r: 6), "R+6"), (PrinterLights(b: -6), "B-6"),
                               (PrinterLights(g: 4), "G+4")] {
            let out = ReferenceRenderer.render(ramp, plan: plan(lights))
            var hues: [Double] = []
            var chroma: [(l: Double, c: Double)] = []
            for x in 0..<64 {
                let a = Self.oklab(Self.displayPixel(base, x))
                let b = Self.oklab(Self.displayPixel(out, x))
                guard a.l > 0.15, a.l < 0.95 else { continue }
                let da = b.a - a.a, db = b.b - a.b
                hues.append(atan2(db, da) * 180 / .pi)
                chroma.append((a.l, (da * da + db * db).squareRoot()))
            }
            let mean = atan2(hues.map { sin($0 * .pi / 180) }.reduce(0, +),
                             hues.map { cos($0 * .pi / 180) }.reduce(0, +)) * 180 / .pi
            for h in hues {
                var d = h - mean
                d -= 360 * (d / 360).rounded()
                XCTAssertLessThan(abs(d), 5, "\(name): a tone's shift is \(d)° off the mean")
            }
            let peak = chroma.max { $0.c < $1.c }!
            XCTAssertGreaterThan(peak.l, 0.3, "\(name): the shift peaks in the shadows")
            XCTAssertLessThan(chroma.last!.c, peak.c, "\(name): no roll-off toward white")
        }
    }

    /// SPEC P5. The dials stop where the panel says: ±48 master, ±24 trims, and a
    /// hand-edited value past them renders as the limit.
    func testP5TheLimitsHold() {
        XCTAssertEqual(gains(PrinterLights(master: 100)), gains(PrinterLights(master: 48)))
        XCTAssertEqual(gains(PrinterLights(r: -100)), gains(PrinterLights(r: -24)))
        XCTAssertEqual(GradeEngine.masterPointLimit, 48)
        XCTAssertEqual(GradeEngine.trimPointLimit, 24)
    }

    // MARK: - Helpers

    static let toSRGB = RGBColorSpace.rec2020.matrix(to: .srgb)

    static func displayPixel(_ image: ImageBuffer, _ x: Int) -> RGB {
        let i = 4 * x
        return toSRGB.apply(RGB(Double(image.pixels[i]), Double(image.pixels[i + 1]),
                                Double(image.pixels[i + 2]))).clamped()
    }

    /// Björn Ottosson's OKLab from linear sRGB.
    static func oklab(_ c: RGB) -> (l: Double, a: Double, b: Double) {
        let l = cbrt(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b)
        let m = cbrt(0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b)
        let s = cbrt(0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}

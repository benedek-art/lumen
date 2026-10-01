// ColorBalanceContractTests.swift
// The three colour-balance axes keep the invariants their names promise (K-081).
//
// docs/27 §4 owed these as "Colour Balance semantic contracts" and blamed the missing
// engine entry; the entry has been reachable for a while (`ColorBalanceGrid.apply`).
// `ColorScienceTests.testChromaSaturationAndBrillianceAreThreeDifferentMoves` only
// asserts the three outputs DIFFER from each other — any three distinct wrong moves
// pass it. These assert what each one HOLDS:
//
//   · Chroma       — colourfulness at constant lightness and hue: L and h unchanged.
//   · Saturation   — the C/L ratio, at constant H-K brightness: B = L·(1 + m·C) held.
//   · Brilliance   — H-K brightness, at constant ratio: C/L and h held, B scaled by
//                    exactly the axis gain.
//
// Measured on in-gamut colours across the hue circle through the engine's own OKLab
// context, with the global component only, so the zone windows play no part.

import XCTest
@testable import LumenCore

final class ColorBalanceContractTests: XCTestCase {

    private let context = OKLabTransform.working

    /// Colours spread round the hue circle at moderate chroma, well inside the working
    /// gamut, plus a dark and a bright one.
    private var colours: [RGB] {
        [RGB(0.60, 0.20, 0.15), RGB(0.55, 0.45, 0.10), RGB(0.15, 0.50, 0.20),
         RGB(0.10, 0.35, 0.55), RGB(0.40, 0.15, 0.55), RGB(0.05, 0.03, 0.02),
         RGB(1.10, 0.80, 0.60)]
    }

    private func brightness(_ lch: OKLCh) -> Double {
        lch.L * HelmholtzKohlrausch.brightnessFactor(chroma: lch.C, hue: lch.h)
    }

    private func grid(_ edit: (inout ColorBalanceParams) -> Void) -> ColorBalanceGrid {
        var params = ColorBalanceParams()
        edit(&params)
        return ColorBalanceGrid(params: params)
    }

    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return Swift.min(d, 360 - d)
    }

    func testChromaHoldsLightnessAndHue() {
        for value in [-60.0, 40.0] {
            let g = grid { $0.chroma.global = value }
            for c in colours {
                let before = context.toLCh(c)
                let after = context.toLCh(g.apply(c, at: 0))
                XCTAssertEqual(after.L, before.L, accuracy: 1e-9,
                               "Chroma \(value) moved lightness on \(c)")
                XCTAssertLessThan(hueDistance(after.h, before.h), 1e-6,
                                  "Chroma \(value) turned the hue of \(c)")
                XCTAssertEqual(after.C, before.C * (1 + value / 100), accuracy: 1e-9)
            }
        }
    }

    func testSaturationHoldsHKBrightness() {
        for value in [-60.0, 40.0] {
            let g = grid { $0.saturation.global = value }
            for c in colours {
                let before = context.toLCh(c)
                let after = context.toLCh(g.apply(c, at: 0))
                XCTAssertEqual(brightness(after), brightness(before), accuracy: 1e-9,
                               "Saturation \(value) changed the perceived brightness of \(c)")
                XCTAssertEqual(after.C / after.L, (before.C / before.L) * (1 + value / 100),
                               accuracy: 1e-9, "Saturation is not a ratio move on \(c)")
                XCTAssertLessThan(hueDistance(after.h, before.h), 1e-6)
            }
        }
    }

    func testBrillianceHoldsTheRatioAndScalesBrightness() {
        for value in [-40.0, 30.0] {
            let g = grid { $0.brilliance.global = value }
            for c in colours {
                let before = context.toLCh(c)
                let after = context.toLCh(g.apply(c, at: 0))
                XCTAssertEqual(after.C / after.L, before.C / before.L, accuracy: 1e-9,
                               "Brilliance \(value) changed the colour's ratio on \(c)")
                XCTAssertEqual(brightness(after), brightness(before) * (1 + value / 100),
                               accuracy: 1e-9,
                               "Brilliance \(value) did not scale H-K brightness on \(c)")
                XCTAssertLessThan(hueDistance(after.h, before.h), 1e-6)
            }
        }
    }
}

// VignetteLegacyIdentityTests.swift
// WS-41 SPEC line 4: the new vignette at its defaults is the old one, to the bit.
//
// A frozen copy of `DetailEngine.vignette` as it stood before WS-41 lives below, and the
// new function is compared against it at ≥ 50 random Amounts across the clamp (plus
// both clamp ends, ±1e-3 and values outside the range), feather 50, every other control
// at its default, on a frame whose luminance runs from 0.01 to 8 — so the legacy
// half-strength highlight protection above scene Y 2.88 is exercised too.

import XCTest
@testable import LumenCore

final class VignetteLegacyIdentityTests: XCTestCase {

    /// `DetailEngine.vignette` at commit de61270, verbatim except for the name.
    private static func frozenVignette(_ image: ImageBuffer, ev: Double,
                                       feather: Double = 50) -> ImageBuffer {
        let amount = Num.clamp(ev, -4.0, 2.0)
        guard amount != 0 else { return image }
        let w = image.width
        let h = image.height
        let space = RGBColorSpace.rec2020
        let protection = 0.5
        let f = Num.clamp(feather, 0, 100) / 100
        let inner = Num.clamp(1.5 * 0.5 * (1 - f), 0, 0.98)
        let highlightThreshold = 0.18 * pow(2.0, 5.0) / 2.0
        let halfW = Double(w) * 0.5
        let halfH = Double(h) * 0.5
        let norm = 1.0 / (2.0 as Double).squareRoot()
        var out = image
        for y in 0..<h {
            let v = (Double(y) + 0.5 - halfH) / Swift.max(halfH, 1e-6)
            for x in 0..<w {
                let u = (Double(x) + 0.5 - halfW) / Swift.max(halfW, 1e-6)
                let r = (u * u + v * v).squareRoot() * norm
                let falloff = Num.smoothstep(inner, 1.0, r)
                if falloff <= 0 { continue }
                let c = image[x, y]
                let lum = space.luminance(c)
                let protect = protection * Num.smoothstep(highlightThreshold,
                                                          highlightThreshold * 2, lum)
                let stops = amount * falloff * (1 - protect)
                if stops == 0 { continue }
                out[x, y] = c * pow(2.0, stops)
            }
        }
        return out
    }

    /// Y from 0.01 to 8, log-spaced along x, with colour along y — through the legacy
    /// protection's whole span at every radius.
    private func frame(_ w: Int = 96, _ h: Int = 64) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, v in
            let y = 0.01 * pow(800.0, u)
            return RGB(y * (0.8 + 0.4 * v), y, y * (1.2 - 0.4 * v))
        }
    }

    func testTheDefaultsAreTheFrozenLegacyFunctionBitForBit() {
        var rng = SystemRandomNumberGenerator()
        var amounts: [Double] = [-4, 2, -1e-3, 1e-3, -4.5, 2.5, -2, 0.6]
        for _ in 0..<56 { amounts.append(Double.random(in: -4...2, using: &rng)) }
        for (index, size) in [(96, 64), (65, 65), (40, 71)].enumerated() {
            let source = frame(size.0, size.1)
            for ev in amounts where index == 0 || ev.magnitude > 0.5 {
                let old = Self.frozenVignette(source, ev: ev)
                let viaLegacyEntry = DetailEngine.vignette(source, ev: ev)
                let viaSettings = DetailEngine.vignette(
                    source, VignetteSettings(amount: ev), geometry: Geometry())
                var plain = Recipe()
                plain.look.vignette = ev
                let plan = RenderPlan(recipe: plain)
                let viaPlan = DetailEngine.vignette(source, plan.vignette,
                                                    geometry: plan.recipe.develop.geometry)
                XCTAssertEqual(old.pixels, viaLegacyEntry.pixels, "ev \(ev) size \(size)")
                XCTAssertEqual(old.pixels, viaSettings.pixels, "ev \(ev) size \(size)")
                XCTAssertEqual(old.pixels, viaPlan.pixels, "ev \(ev) size \(size)")
            }
        }
    }

    /// The legacy protection is really exercised by the frame: above 2.88 the frozen
    /// function differs from an unprotected burn.
    func testTheFrameReachesTheLegacyProtection() {
        let source = frame()
        let old = Self.frozenVignette(source, ev: -3)
        XCTAssertNotEqual(source[95, 0], old[95, 0])
        let lum = RGBColorSpace.rec2020.luminance(source[95, 0])
        XCTAssertGreaterThan(lum, 2.88 * 2)
        let stops = log2(old[95, 0].g / source[95, 0].g)
        XCTAssertEqual(stops / -3, 0.5, accuracy: 0.01,
                       "the corner pixel above 5.76 must take half the burn")
    }
}

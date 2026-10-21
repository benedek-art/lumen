// LocalGlobalParityTests.swift
// WS-51/52 — a mask's light, white balance and colour sliders, inside a mask that covers
// the whole frame, render exactly what the global slider of the same name renders.
//
// Measured end to end through `ReferenceRenderer.render`, on a photograph that is NOT
// balanced at 5500 K / 0: that is where the relative Temp/Tint used to come apart from
// the global row (docs/quality/lanes/WS-51-52/REPORT.md).

import XCTest
@testable import LumenCore

final class LocalGlobalParityTests: XCTestCase {

    private let asShot = (kelvin: 4711.0, tint: 6.0)

    /// Skin, foliage, sky, a saturated red, a neutral ramp and a highlight.
    private lazy var frame: ImageBuffer = {
        let colours: [RGB] = [RGB(0.40, 0.24, 0.16), RGB(0.08, 0.14, 0.04),
                              RGB(0.10, 0.20, 0.45), RGB(0.55, 0.05, 0.04),
                              RGB(0.02, 0.02, 0.02), RGB(0.18, 0.18, 0.18),
                              RGB(0.60, 0.60, 0.60), RGB(2.0, 1.8, 1.5)]
        return ImageBuffer(width: 32, height: 8) { u, v in
            let x = Int(u * 32), y = Int(v * 8)
            return colours[(x / 4 + y) % colours.count] * (0.6 + 0.1 * Double(y % 5))
        }
    }()

    private func fullFrameMask(_ adjust: LocalAdjust) -> Mask {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [0.5, 0.5]
        c.radii = [5, 5]
        c.feather = 0
        var mask = Mask(id: "full", name: "full")
        mask.components = [c]
        mask.adjust = adjust
        return mask
    }

    private func render(_ recipe: Recipe) -> ImageBuffer {
        ReferenceRenderer.render(frame, plan: RenderPlan(recipe: recipe,
                                                         asShotKelvin: asShot.kelvin,
                                                         asShotTint: asShot.tint))
    }

    private func maxDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var worst = 0.0
        for y in 0..<a.height {
            for x in 0..<a.width { worst = Swift.max(worst, a[x, y].maxAbsDifference(b[x, y])) }
        }
        return worst
    }

    private func assertParity(_ name: String, base: Recipe = Recipe(),
                              global: (inout Recipe) -> Void,
                              local: (inout LocalAdjust) -> Void,
                              file: StaticString = #filePath, line: UInt = #line) {
        var g = base
        global(&g)
        var adjust = LocalAdjust()
        local(&adjust)
        var l = base
        l.masks = [fullFrameMask(adjust)]
        let globally = render(g), locally = render(l), untouched = render(base)
        // The control has to move the picture, or parity is trivially true.
        XCTAssertGreaterThan(maxDifference(globally, untouched), 0.01,
                             "\(name): the global control did nothing", file: file, line: line)
        // Display-linear, Float32 storage: 2e-5 is under a tenth of one 16-bit code.
        XCTAssertLessThan(maxDifference(globally, locally), 2e-5,
                          "\(name): local inside a full mask is not the global control",
                          file: file, line: line)
    }

    func testExposureInsideAFullMaskIsGlobalExposure() {
        for ev in [1.0, -1.5] {
            assertParity("Exposure \(ev)", global: { $0.develop.tone.exposure = ev },
                         local: { $0.exposure = ev })
        }
    }

    func testTempAndTintInsideAFullMaskAreTheGlobalRowShifted() {
        // Temp ±100 = ±50 mired, Tint ±100 = ±150, from the balanced neutral.
        for (temp, tint) in [(100.0, 0.0), (-100, 0), (0, 100), (0, -60), (40, -30)] {
            for globalTemp in [Double?.none, 6200] {
                var base = Recipe()
                base.develop.raw.temp = globalTemp
                let kelvin = globalTemp ?? asShot.kelvin
                assertParity("Temp \(temp) Tint \(tint) over \(kelvin) K", base: base,
                             global: {
                                 $0.develop.raw.temp = 1e6 / (1e6 / kelvin - temp * 0.5)
                                 $0.develop.raw.tint = self.asShot.tint + tint * 1.5
                             },
                             local: { $0.temp = temp; $0.tint = tint })
            }
        }
    }

    func testAKelvinInsideAFullMaskIsTheGlobalKelvin() {
        assertParity("Kelvin 3800", global: { $0.develop.raw.temp = 3800 },
                     local: { $0.kelvin = 3800 })
    }

    func testSaturationAndVibranceInsideAFullMaskAreTheGlobalSliders() {
        for v in [50.0, -100] {
            assertParity("Saturation \(v)", global: { $0.develop.color.saturation = v },
                         local: { $0.sat = v })
        }
        assertParity("Vibrance 60", global: { $0.develop.color.vibrance = 60 },
                     local: { $0.vibrance = 60 })
    }
}

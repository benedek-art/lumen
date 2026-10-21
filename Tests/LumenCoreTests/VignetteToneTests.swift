// VignetteToneTests.swift
// WS-41 SPEC lines 13-16 in scene-linear: what each style does to a pixel's level, and
// that no setting of any style can make a brighter input come out darker.

import XCTest
@testable import LumenCore

final class VignetteToneTests: XCTestCase {

    private let field = VignetteField(sourceWidth: 768, sourceHeight: 512)

    private func uniforms(_ amount: Double, style: VignetteStyle = .highlightPriority,
                          highlights: Double = 0) -> DetailEngine.VignetteUniforms {
        DetailEngine.vignetteUniforms(
            VignetteSettings(amount: amount, highlights: highlights, style: style),
            field: field)
    }

    /// The output of a neutral of scene level `y` receiving `falloff` of the profile.
    private func out(_ y: Double, _ k: DetailEngine.VignetteUniforms,
                     falloff: Double = 1) -> RGB {
        DetailEngine.vignetteApply(RGB(gray: y), falloff: falloff, k) ?? RGB(gray: y)
    }

    private let levels: [Double] = (0..<2000).map { 0.001 * pow(16000.0, Double($0) / 1999) }

    /// Line 16: d(out)/dY ≥ 0 over Y ∈ [0.001, 16] at 2000 levels, for every style ×
    /// Highlights {0, 50, 100} × Amount {−4, −1, +1, +2}, at the corner and at a partial
    /// falloff. The single exemption is the one the lead accepted (spec note 1): HP at
    /// Highlights 0 with a positive Amount keeps the legacy curve bytewise, and it dips
    /// above Y 2.88, where no corpus photograph has a pixel.
    func testNoStyleInvertsToneAtAnySetting() {
        for style in VignetteStyle.allCases {
            for h in [0.0, 50, 100] {
                for a in [-4.0, -1, 1, 2] {
                    let k = uniforms(a, style: style, highlights: h)
                    for falloff in [1.0, 0.5] {
                        var previous = -Double.infinity
                        var previousY = 0.0
                        for y in levels {
                            let o = out(y, k, falloff: falloff).g
                            let exempt = style == .highlightPriority && a > 0 && y > 2.88
                            if !exempt {
                                XCTAssertGreaterThanOrEqual(
                                    o, previous,
                                    "\(style) H\(h) a\(a) f\(falloff): \(previousY)→\(y)")
                            }
                            previous = o
                            previousY = y
                        }
                    }
                }
            }
        }
    }

    /// Line 16 for colour: Color Priority's chroma handling keeps each channel of a
    /// chromatic input monotone in level, so a brighter coloured patch is never darker
    /// in any channel.
    func testColorPriorityKeepsChromaticRampsMonotone() {
        let tints = [RGB(1.6, 0.4, 0.25), RGB(0.5, 0.9, 1.7), RGB(0.6, 1.4, 0.5),
                     RGB(1.3, 0.95, 0.7)]
        for a in [-4.0, -1, 1, 2] {
            let k = uniforms(a, style: .colorPriority, highlights: 100)
            for tint in tints {
                var previous = RGB(gray: -1)
                for y in levels {
                    let c = tint * y
                    let o = DetailEngine.vignetteApply(c, falloff: 1, k) ?? c
                    let lum = RGBColorSpace.rec2020.luminance(o)
                    XCTAssertGreaterThanOrEqual(lum, RGBColorSpace.rec2020.luminance(previous)
                                                - 1e-12, "a \(a) tint \(tint) y \(y)")
                    previous = o
                }
            }
        }
    }

    /// Line 15(c) and the "acts only for a < 0 in HP and CP" model clause: Highlights
    /// changes nothing at a positive Amount, nor in Paint Overlay at all.
    func testHighlightsIsGated() {
        for y in levels {
            for (a, style) in [(1.5, VignetteStyle.highlightPriority), (1.5, .colorPriority),
                               (1.5, .paintOverlay), (-2, .paintOverlay)] {
                XCTAssertEqual(out(y, uniforms(a, style: style, highlights: 0)),
                               out(y, uniforms(a, style: style, highlights: 100)))
            }
        }
    }

    /// Lines 14 and 15: Highlights holds bright content back, monotonically in H and Y,
    /// continuously from the legacy curve at H 0, and leaves darks burning.
    func testHighlightsHoldBrightAreasAndNeverInvertTone() {
        let legacy = uniforms(-4)
        for y in levels {
            // H 0 is exactly the legacy protection.
            XCTAssertEqual(DetailEngine.vignetteProtection(luminance: y, legacy),
                           0.5 * Num.smoothstep(2.88, 5.76, y), accuracy: 0)
            // Nondecreasing in H, and continuous at H 0.
            var previous = -1.0
            for h in stride(from: 0.0, through: 100.0, by: 10.0) {
                let p = DetailEngine.vignetteProtection(luminance: y, uniforms(-4, highlights: h))
                XCTAssertGreaterThanOrEqual(p, previous)
                previous = p
            }
            let p1 = DetailEngine.vignetteProtection(luminance: y, uniforms(-4, highlights: 1))
            XCTAssertLessThan(abs(p1 - DetailEngine.vignetteProtection(luminance: y, legacy)),
                              0.011, "jump at H 0 → 1, Y \(y)")
        }
        let full = uniforms(-4, highlights: 100)
        func keptBurn(_ y: Double) -> Double {
            DetailEngine.vignetteStops(luminance: y, falloff: 1, full) / -4
        }
        XCTAssertGreaterThanOrEqual(keptBurn(0.09), 0.95, "a dark corner keeps its burn")
        XCTAssertGreaterThanOrEqual(keptBurn(0.18), 0.75, "a mid-grey corner keeps 3 EV")
        XCTAssertLessThanOrEqual(keptBurn(0.6), 0.10, "snow is held")
        XCTAssertLessThanOrEqual(keptBurn(1.5), 0.01, "a white wall is held")
        XCTAssertLessThanOrEqual(keptBurn(0.52), 0.25, "a bright sky is mostly held")
        // CP holds the same highlights as HP on a neutral.
        let cp = uniforms(-4, style: .colorPriority, highlights: 100)
        for y in levels {
            XCTAssertEqual(out(y, full).g, out(y, cp).g, accuracy: 1e-9 * y)
        }
    }

    /// Line 13: on neutrals Color Priority is Highlight Priority (it changes chroma only),
    /// and Paint Overlay lands mid-grey exactly where HP does, so Amount names the same
    /// corner in every style.
    func testAmountMeansTheSameMidGreyCornerInEveryStyle() {
        for a in stride(from: -4.0, through: 2.0, by: 0.5) where a != 0 {
            let hp = out(0.18, uniforms(a)).g
            XCTAssertEqual(out(0.18, uniforms(a, style: .colorPriority)).g, hp,
                           accuracy: 1e-9)
            XCTAssertEqual(out(0.18, uniforms(a, style: .paintOverlay)).g, hp,
                           accuracy: 1e-9)
            XCTAssertEqual(hp, 0.18 * pow(2, a), accuracy: 1e-9)
        }
    }

    /// Paint Overlay reduces corner contrast in stops (line 19's mechanism): a 2-stop
    /// pair keeps less than 2 stops apart after the burn and after the lift.
    func testPaintOverlayFlattensTheCorner() {
        for a in [-2.0, 1.5] {
            let k = uniforms(a, style: .paintOverlay)
            let spread = log2(out(0.36, k).g / out(0.09, k).g)
            XCTAssertLessThan(spread, 2 - 0.1 * abs(a), "amount \(a)")
            XCTAssertGreaterThan(spread, 0)
        }
    }

    /// Color Priority keeps OKLab hue in scene-linear while it scales chroma.
    func testColorPriorityHoldsSceneHue() {
        let ctx = OKLabTransform.working
        for a in [-4.0, -2, 1.5, 2] {
            let k = uniforms(a, style: .colorPriority)
            for c in [RGB(0.30, 0.08, 0.05), RGB(0.08, 0.16, 0.40), RGB(0.30, 0.22, 0.15)] {
                guard let o = DetailEngine.vignetteApply(c, falloff: 1, k) else {
                    return XCTFail("no change")
                }
                let h0 = ctx.toLCh(c).h, h1 = ctx.toLCh(o).h
                XCTAssertLessThan(abs(Num.hueDelta(h0, h1)), 0.01, "a \(a) c \(c)")
            }
        }
    }
}

// ProtectSkinChromaOrderTests.swift
// "A more colourful skin tone never comes out LESS colourful" — Vibrance and
// Saturation with Protect Skin keep chroma order along every ray of constant hue and
// lightness, including the stretch where the protection fades in.
//
// `HuePreservationTests` proves the colour sliders monotone over a grid, but its
// skin-hued samples sit at chroma ~0.02 and ~0.06 — exactly the two ends of the chroma
// gate, never inside it. Protection was `1 − P · skinWeight`, and `skinWeight` carries
// `chromaGate = smoothstep(0.02, 0.06, C)`: the protection switched from nothing to
// full across a chroma span of 0.04. The output chroma is C · G(p(C)), and when the
// gain G is large the falling gain outran the rising input. At Vibrance and Saturation
// +100 and Protect Skin 100, a skin-hued input at C 0.040 left at 0.088 while one at
// C 0.054 left at 0.061: the more saturated pixel came out flatter, which on a pale
// face gradient is a chroma contour. At the shipped Protect 70 the fold was 0.011.
//
// No gate that rises 0 → 1 inside 0.02…0.06 can avoid it: at full gain the protection
// may fall no faster than d ln C · (1 − g/2), which needs at least ln 4 of log-chroma
// even with the ideal ramp shape. The protection fades in over log chroma instead —
// 0.006 → 0.06 at first; since WS-16, 0.002 → 0.015 (Vibrance and Saturation
// compounding at full gain need a factor of about seven), so it reaches Monk MST 1 — while
// `skinWeight`, the shared definition of "skin" the Skin tools and the scope read, is
// left alone.

import XCTest
@testable import LumenCore

final class ProtectSkinChromaOrderTests: XCTestCase {

    private static let space = OKLabTransform.working

    private func engine(vibrance: Double, saturation: Double, protectSkin: Double) -> ColorEngine {
        var color = ColorAdjust(protectSkin: protectSkin)
        color.vibrance = vibrance
        color.saturation = saturation
        return ColorEngine(mixer: Mixer(), pointColors: [], color: color,
                           primaries: Primaries(), bw: nil)
    }

    private func chroma(_ c: RGB) -> Double { Self.space.toLCh(c).C }

    /// Walk every skin-hued ray from grey out to C 0.1 and report the deepest place the
    /// output chroma falls below the running maximum of everything less colourful.
    private func deepestFold(_ apply: (RGB) -> RGB) -> (depth: Double, at: String) {
        var worst = (depth: 0.0, at: "nowhere")
        for hStep in 0...20 {
            let h = 36 + Double(hStep) * 2
            for L in [0.40, 0.55, 0.70, 0.85] {
                var runningMax = 0.0
                for step in 0...200 {
                    let C = Double(step) * 0.0005
                    let out = chroma(apply(Self.space.toRGB(OKLCh(L: L, C: C, h: h))))
                    let fold = runningMax - out
                    if fold > worst.depth {
                        worst = (fold, "h \(h), L \(L), input C \(C) (output \(out), "
                                    + "a less colourful input reached \(runningMax))")
                    }
                    runningMax = Swift.max(runningMax, out)
                }
            }
        }
        return worst
    }

    private static let settings: [(v: Double, s: Double, p: Double)] = [
        (100, 100, 100), (100, 100, 70), (100, 0, 100), (0, 100, 100),
        (75, 75, 70), (100, 50, 70),
    ]

    func testVibranceAndSaturationKeepSkinChromaOrderedAlongARay() {
        for (v, s, p) in Self.settings {
            let e = engine(vibrance: v, saturation: s, protectSkin: p)
            let fold = deepestFold { e.apply($0) }
            XCTAssertLessThanOrEqual(
                fold.depth, 1e-6,
                "Vibrance \(v), Saturation \(s), Protect Skin \(p): output chroma folded "
                + "by \(fold.depth) at \(fold.at)")
        }
    }

    /// The GPU's Swift twin (and through it the GLSL kernel it mirrors) must agree.
    func testTheExactStageTwinAlsoKeepsSkinChromaOrderedAlongARay() {
        for (v, s, p) in Self.settings {
            let stage = engine(vibrance: v, saturation: s, protectSkin: p).exactStage
            let fold = deepestFold { stage.apply($0) }
            XCTAssertLessThanOrEqual(
                fold.depth, 1e-5,
                "exact stage, Vibrance \(v), Saturation \(s), Protect Skin \(p): output "
                + "chroma folded by \(fold.depth) at \(fold.at)")
        }
    }

    /// What must NOT move: the shared skin membership. And Protect Skin 100 spares skin
    /// completely across the whole range real skin occupies.
    ///
    /// This used to check C 0.06/0.08/0.10 — "full protection above the old gate". At
    /// L 0.6, C 0.08 and 0.10 are C/L 0.13 and 0.17, more colourful than any skin patch
    /// measured (≤ 0.118) and on the way to ColorChecker orange (0.22), which WS-16's
    /// plausibility deliberately stops protecting (SPEC SKIN-3). So the range is now the
    /// skin one: from MST 1's chroma (0.015) to C/L 0.117.
    func testTheSharedSkinWeightAndFullProtectionAboveTheOldGateAreUnchanged() {
        let nearGrey = Self.space.toRGB(OKLCh(L: 0.6, C: 0.015, h: ColorEngine.skinLineDegrees))
        XCTAssertEqual(ColorEngine.skinWeight(nearGrey), 0, accuracy: 1e-12,
                       "skinWeight, shared with the Skin tools, changed below the gate")
        let e = engine(vibrance: 100, saturation: 100, protectSkin: 100)
        for C in [0.015, 0.03, 0.06, 0.07] {
            let skin = Self.space.toRGB(OKLCh(L: 0.6, C: C, h: ColorEngine.skinLineDegrees))
            XCTAssertEqual(chroma(e.apply(skin)), C, accuracy: 1e-9,
                           "Protect Skin 100 no longer fully spares skin at C \(C)")
        }
    }
}

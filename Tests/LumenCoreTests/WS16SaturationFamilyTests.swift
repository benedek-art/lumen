// WS16SaturationFamilyTests.swift
// The WS-16 acceptance lines (docs/quality/lanes/WS-16/SPEC.md) that live at the S9
// stage: Saturation, Vibrance, Density, Protect Skin and the Black & White mix, each
// asserted at the spec's threshold on the Float twin the renderers run
// (`ExactColorStage`) and, where the line is about the definition, on the Double
// `ColorEngine` too. Test names carry `WS16_<ID>` so the spec's TEST-1 check finds them.
//
// Inputs are OKLCh in the working context (Rec.2020 linear, `OKLabTransform.working`),
// the measure the spec quotes its skin and ColorChecker numbers in. "In gamut" means no
// negative working-space channel.

import XCTest
@testable import LumenCore

final class WS16SaturationFamilyTests: XCTestCase {

    private static let ctx = OKLabTransform.working
    private static let defaultDensity = ColorAdjust().density
    private static let defaultProtect = ColorAdjust().protectSkin

    // MARK: - Helpers

    private struct WS16Probe {
        let engine: ColorEngine
        let stage: ExactColorStage
    }

    private func probe(vib: Double = 0, sat: Double = 0,
                       density: Double = WS16SaturationFamilyTests.defaultDensity,
                       protect: Double = WS16SaturationFamilyTests.defaultProtect,
                       bw: [Double]? = nil) -> WS16Probe {
        var color = ColorAdjust()
        color.vibrance = vib
        color.saturation = sat
        color.density = density
        color.protectSkin = protect
        let engine = ColorEngine(mixer: Mixer(), pointColors: [], color: color,
                                 primaries: Primaries(),
                                 bw: bw.map { BlackAndWhite(bands: $0, enabled: true) })
        return WS16Probe(engine: engine, stage: engine.exactStage)
    }

    private static func rgb(_ L: Double, _ C: Double, _ h: Double) -> RGB {
        ctx.toRGB(OKLCh(L: L, C: C, h: h))
    }

    private static func lch(_ c: RGB) -> OKLCh { ctx.toLCh(c) }

    private static func inGamut(_ c: RGB) -> Bool { Swift.min(c.r, Swift.min(c.g, c.b)) >= 0 }

    private static func hueDelta(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    private struct WS16Sample {
        let L: Double
        let C: Double
        let h: Double
        let rgb: RGB
    }

    /// The spec's standard grid, in-gamut samples only.
    private static let grid: [WS16Sample] = {
        var out: [WS16Sample] = []
        for L in [0.3, 0.45, 0.6, 0.75, 0.9] {
            for C in [0.01, 0.02, 0.03, 0.04, 0.06, 0.08, 0.1, 0.13, 0.16, 0.2, 0.25, 0.3] {
                for h in stride(from: 0.0, to: 360.0, by: 5.0) {
                    let c = rgb(L, C, h)
                    if inGamut(c) { out.append(WS16Sample(L: L, C: C, h: h, rgb: c)) }
                }
            }
        }
        return out
    }()

    /// Largest chroma inside Rec.2020 at (L, h), bisected on the input lightness
    /// (the spec's `boundary_chroma`, capped at 0.6).
    private static func boundaryChroma(_ L: Double, _ h: Double) -> Double {
        if inGamut(rgb(L, 0.6, h)) { return 0.6 }
        var lo = 0.0, hi = 0.6
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if inGamut(rgb(L, mid, h)) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Working-space OKLCh of the skin patches (ColorChecker light/dark skin, Monk MST
    /// 1–9) and of the ColorChecker colours that share skin hues, as the spec measured.
    private static let skin: [(String, Double, Double, Double)] = [
        ("light skin", 0.708, 0.068, 40.7), ("dark skin", 0.468, 0.052, 42.3),
        ("MST 1", 0.951, 0.015, 67.6), ("MST 2", 0.934, 0.021, 67.6),
        ("MST 3", 0.941, 0.037, 84.6), ("MST 4", 0.893, 0.046, 84.6),
        ("MST 5", 0.811, 0.060, 77.8), ("MST 6", 0.616, 0.070, 70.5),
        ("MST 7", 0.509, 0.062, 54.2), ("MST 8", 0.407, 0.048, 43.6),
        ("MST 9", 0.321, 0.018, 60.0),
    ]
    private static let skinHuedColours: [(String, Double, Double, Double)] = [
        ("orange", 0.685, 0.152, 53.6), ("orange yellow", 0.759, 0.149, 75.8),
        ("yellow", 0.838, 0.169, 93.9), ("red", 0.516, 0.167, 22.1),
        ("moderate red", 0.593, 0.149, 15.0), ("foliage", 0.504, 0.068, 127.0),
    ]

    private func chromaGain(_ p: WS16Probe, _ c: RGB) -> Double {
        Self.lch(p.stage.apply(c)).C / Self.lch(c).C
    }

    // MARK: - Identity

    func testWS16_ID2_DefaultColourAdjustIsAnIdentityStageWithNoPass() {
        let p = probe()
        XCTAssertTrue(p.engine.isIdentity)
        XCTAssertTrue(p.stage.isIdentity)
        XCTAssertTrue(p.stage.passes.isEmpty)
        XCTAssertEqual(ColorAdjust().density, 0, "Density defaults to 0 (SPEC decision 4)")
    }

    // MARK: - Hue and Saturation

    func testWS16_HUE1_SaturationAndVibranceHoldHue() {
        var worst = 0.0, at = ""
        for key in ["sat", "vib"] {
            for v in [-100.0, -50, -25, 25, 50, 100] {
                for d in [0.0, 100.0] {
                    for pr in [0.0, Self.defaultProtect, 100.0] {
                        let p = key == "sat" ? probe(sat: v, density: d, protect: pr)
                            : probe(vib: v, density: d, protect: pr)
                        for s in Self.grid where s.C > 0.02 {
                            let out = Self.lch(p.stage.apply(s.rgb))
                            guard out.C > 0.005 else { continue }
                            let dh = abs(Self.hueDelta(Self.lch(s.rgb).h, out.h))
                            if dh > worst { worst = dh; at = "\(key) \(v) D\(d) P\(pr)" }
                        }
                    }
                }
            }
        }
        XCTAssertLessThanOrEqual(worst, 0.1, "hue drift \(worst)° at \(at)")
    }

    func testWS16_SAT1_PullsAreAUniformChromaScale() {
        for s in [-25.0, -50, -75] {
            let p = probe(sat: s)
            for x in Self.grid where x.C > 0.02 {
                let ratio = chromaGain(p, x.rgb)
                XCTAssertEqual(ratio, 1 + s / 100, accuracy: 0.005,
                               "Sat \(s) at L \(x.L) C \(x.C) h \(x.h)")
            }
        }
    }

    func testWS16_SAT2_PushesAreUniformWellInsideTheGamut() {
        var worst = 1.0, at = ""
        for s in [25.0, 50, 100] {
            let p = probe(sat: s, protect: 0)
            for x in Self.grid where x.C > 0.02 && x.L <= 0.75 {
                guard (1 + s / 100) * x.C <= 0.6 * Self.boundaryChroma(x.L, x.h) else { continue }
                let rel = chromaGain(p, x.rgb) / (1 + s / 100)
                if rel < worst { worst = rel; at = "Sat \(s) L \(x.L) C \(x.C) h \(x.h)" }
            }
        }
        XCTAssertGreaterThanOrEqual(worst, 0.95, "push compressed to \(worst) at \(at)")
    }

    func testWS16_SAT3a_SaturationMinus100IsMonochromeWhateverProtectAndVibranceSay() {
        for pr in [0.0, Self.defaultProtect, 100] {
            for vib in [0.0, 100, -100] {
                let p = probe(vib: vib, sat: -100, protect: pr)
                for x in Self.grid {
                    XCTAssertLessThanOrEqual(Self.lch(p.stage.apply(x.rgb)).C, 1e-5,
                                             "P\(pr) V\(vib) at L \(x.L) C \(x.C) h \(x.h)")
                    XCTAssertLessThanOrEqual(Self.lch(p.engine.apply(x.rgb)).C, 1e-9)
                }
            }
        }
    }

    func testWS16_SAT4_PushesNeverLeaveTheWorkingGamut() {
        let settings: [(Double, Double)] = [(0, 25), (0, 50), (0, 100), (50, 0), (100, 0),
                                            (100, 100)]
        for (v, s) in settings {
            for d in [0.0, 50, 100] {
                let p = probe(vib: v, sat: s, density: d, protect: 0)
                for x in Self.grid {
                    let t = p.stage.apply(x.rgb), e = p.engine.apply(x.rgb)
                    XCTAssertGreaterThanOrEqual(Swift.min(t.r, Swift.min(t.g, t.b)), -1e-4,
                                                "V\(v) S\(s) D\(d) L \(x.L) C \(x.C) h \(x.h)")
                    XCTAssertGreaterThanOrEqual(Swift.min(e.r, Swift.min(e.g, e.b)), -1e-9)
                }
            }
        }
    }

    func testWS16_SAT5_NoGamutPlateauOutputChromaKeepsRising() {
        let settings: [(v: Double, s: Double, p: Double, d: Double)] = [
            (0, 100, 0, 0), (0, 100, Self.defaultProtect, 0), (0, 100, 0, 100),
            (100, 0, 0, 0), (100, 0, Self.defaultProtect, 0), (100, 100, 0, 0),
        ]
        let chromas = (0..<200).map { 0.002 + Double($0) * (0.398 / 199) }
        var worst = Double.infinity, at = ""
        for st in settings {
            let p = probe(vib: st.v, sat: st.s, density: st.d, protect: st.p)
            for L in [0.3, 0.45, 0.6, 0.75, 0.9] {
                for h in stride(from: 0.0, to: 360.0, by: 5.0) {
                    var prev: (C: Double, out: Double)?
                    for C in chromas {
                        let c = Self.rgb(L, C, h)
                        guard Self.inGamut(c) else { prev = nil; continue }
                        let out = Self.lch(p.stage.apply(c)).C
                        if let q = prev {
                            let slope = (out - q.out) / (C - q.C)
                            if slope < worst { worst = slope; at = "\(st) L \(L) h \(h) C \(C)" }
                        }
                        prev = (C, out)
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(worst, 0.3, "output chroma slope \(worst) at \(at)")
    }

    /// No dead upper range (LANE-BRIEF §4; verifier round 1). On every in-gamut grid
    /// sample with C > 0.02, the +50…+100 half of Saturation delivers at least 25% of
    /// the +100 push, and so does Vibrance wherever its +100 push is non-zero. The first
    /// compression eased into a fixed share of the room and stopped responding: CC orange
    /// gained ×1.152 by +25 and ×1.153 at +100.
    func testWS16_NoDeadUpperRangeForSaturationOrVibrance() {
        for protect in [0.0, Self.defaultProtect] {
            for key in ["sat", "vib"] {
                let p50 = key == "sat" ? probe(sat: 50, protect: protect) : probe(vib: 50, protect: protect)
                let p100 = key == "sat" ? probe(sat: 100, protect: protect) : probe(vib: 100, protect: protect)
                var worst = 1.0, at = ""
                for x in Self.grid where x.C > 0.02 {
                    let c50 = Self.lch(p50.stage.apply(x.rgb)).C
                    let c100 = Self.lch(p100.stage.apply(x.rgb)).C
                    let whole = c100 - x.C
                    guard whole > 1e-5 * x.C + 1e-7 else { continue }
                    let share = (c100 - c50) / whole
                    if share < worst { worst = share; at = "L \(x.L) C \(x.C) h \(x.h)" }
                }
                XCTAssertGreaterThanOrEqual(worst, 0.25,
                                            "\(key) P\(protect): top half delivers \(worst) of the push at \(at)")
            }
        }
    }

    // MARK: - Vibrance

    func testWS16_VIB1_VibranceGivesLowChromaPriority() {
        let chromas = stride(from: 0.02, through: 0.3001, by: 0.005).map { $0 }
        for v in [50.0, 100] {
            let p = probe(vib: v, protect: 0)
            for L in [0.45, 0.6, 0.75] {
                for h in [0.0, 150, 200, 250, 300] {
                    var prev: Double?
                    var g3: Double?, g20: Double?
                    for C in chromas {
                        let c = Self.rgb(L, C, h)
                        guard Self.inGamut(c) else { continue }
                        let g = chromaGain(p, c)
                        if let q = prev {
                            XCTAssertLessThanOrEqual(g - q, 1e-3, "gain rose at V\(v) L \(L) h \(h) C \(C)")
                        }
                        prev = g
                        if abs(C - 0.03) < 1e-9 { g3 = g }
                        if abs(C - 0.20) < 1e-9 { g20 = g }
                    }
                    if let a = g3, let b = g20 {
                        XCTAssertGreaterThanOrEqual((a - 1) / Swift.max(b - 1, 1e-9), 2.5,
                                                    "priority at V\(v) L \(L) h \(h)")
                    }
                }
            }
        }
    }

    /// Vibrance is as strong on a muted colour in shadow as in a mid-tone (verifier
    /// round 2). It weighs absolute chroma, not gamut fill; a fill weight counted every
    /// dark colour as "near the edge" and left Vibrance +100 at ×1.13 at L 0.2 against
    /// ×1.59 at L 0.6. Hues whose gamut leaves room for the push at L 0.2 (C/L reach
    /// ≥ 0.4); the narrow yellows are bounded by the gamut itself, as they should be.
    func testWS16_VibranceKeepsItsStrengthOnDarkMutedColours() {
        let p = probe(vib: 100, protect: 0)
        for h in [0.0, 30, 150, 200, 250, 300] {
            let dark = chromaGain(p, Self.rgb(0.2, 0.03, h))
            let mid = chromaGain(p, Self.rgb(0.6, 0.03, h))
            XCTAssertGreaterThanOrEqual(mid, 1.5, "Vibrance +100 at C 0.03, L 0.6, h \(h): ×\(mid)")
            XCTAssertGreaterThanOrEqual(dark, 0.85 * mid,
                                        "h \(h): ×\(dark) at L 0.2 against ×\(mid) at L 0.6")
        }
    }

    func testWS16_VIB2_VibranceIsGentlerThanSaturation() {
        let vib = probe(vib: 100, density: 0, protect: 0)
        let sat = probe(sat: 100, density: 0, protect: 0)
        for x in Self.grid where x.C > 0.02 {
            let gv = chromaGain(vib, x.rgb), gs = chromaGain(sat, x.rgb)
            XCTAssertLessThanOrEqual(gv - gs, 0.01, "Vib above Sat at L \(x.L) C \(x.C) h \(x.h)")
            if x.C >= 0.12 && abs(Self.hueDelta(x.h, 62)) > 45 {
                XCTAssertLessThanOrEqual((gv - 1) / Swift.max(gs - 1, 1e-9), 0.5,
                                         "Vib not gentle at L \(x.L) C \(x.C) h \(x.h)")
            }
        }
    }

    func testWS16_VIB5a_VibranceSparesSkinAtTheDefaultProtect() {
        let p = probe(vib: 100)
        for (name, L, C, h) in Self.skin {
            let g = chromaGain(p, Self.rgb(L, C, h))
            let ref = Swift.min(chromaGain(p, Self.rgb(L, C, 150)), chromaGain(p, Self.rgb(L, C, 250)))
            XCTAssertLessThanOrEqual((g - 1) / Swift.max(ref - 1, 1e-9), 0.35,
                                     "\(name): skin gain \(g) vs reference \(ref)")
        }
    }

    func testWS16_VIB7_VibranceMinus100HasNoHueWedge() {
        let p = probe(vib: -100)
        for C in [0.06, 0.10] {
            var gains: [Double] = []
            var prev: Double?
            for h in stride(from: 0.0, to: 360.0, by: 0.5) {
                let c = Self.rgb(0.6, C, h)
                guard Self.inGamut(c) else { prev = nil; continue }
                let g = chromaGain(p, c)
                if let q = prev { XCTAssertLessThanOrEqual(abs(g - q) / 0.5, 0.01, "C \(C) h \(h)") }
                prev = g
                gains.append(g)
            }
            XCTAssertLessThanOrEqual(gains.max()! - gains.min()!, 0.15, "gain range at C \(C)")
        }
    }

    // MARK: - Protect Skin

    private func skinIncrementRatio(protect: Double, _ L: Double, _ C: Double, _ h: Double) -> Double {
        let c = Self.rgb(L, C, h)
        let g = chromaGain(probe(sat: 100, protect: protect), c)
        let g0 = chromaGain(probe(sat: 100, protect: 0), c)
        return (g - 1) / Swift.max(g0 - 1, 1e-9)
    }

    func testWS16_SKIN1_DefaultProtectSparesEverySkinPatch() {
        for (name, L, C, h) in Self.skin {
            XCTAssertLessThanOrEqual(skinIncrementRatio(protect: Self.defaultProtect, L, C, h),
                                     0.45, name)
        }
    }

    func testWS16_SKIN2_Protect100SparesEverySkinPatch() {
        for (name, L, C, h) in Self.skin {
            XCTAssertLessThanOrEqual(skinIncrementRatio(protect: 100, L, C, h), 0.15, name)
        }
    }

    func testWS16_SKIN3_SkinHuedColoursThatAreNotSkinAreNotProtected() {
        for (name, L, C, h) in Self.skinHuedColours {
            XCTAssertGreaterThanOrEqual(skinIncrementRatio(protect: Self.defaultProtect, L, C, h),
                                        0.8, name)
        }
    }

    private func worstHueSlope(protect: Double) -> (Double, String) {
        var worst = 0.0, at = ""
        for (v, s) in [(0.0, 100.0), (100.0, 0.0)] {
            let p = probe(vib: v, sat: s, protect: protect)
            for L in [0.5, 0.7] {
                for C in [0.03, 0.06, 0.10] {
                    var prev: Double?
                    for h in stride(from: 0.0, to: 360.0, by: 0.5) {
                        let c = Self.rgb(L, C, h)
                        guard Self.inGamut(c) else { prev = nil; continue }
                        let g = chromaGain(p, c)
                        if let q = prev, abs(g - q) / 0.5 > worst {
                            worst = abs(g - q) / 0.5; at = "V\(v) S\(s) L \(L) C \(C) h \(h)"
                        }
                        prev = g
                    }
                }
            }
        }
        return (worst, at)
    }

    func testWS16_SKIN4a_ProtectionHasNoHueSeamAtTheDefault() {
        let (worst, at) = worstHueSlope(protect: Self.defaultProtect)
        XCTAssertLessThanOrEqual(worst, 0.04, "gain slope \(worst)/deg at \(at)")
    }

    func testWS16_SKIN5_ProtectionHasNoChromaSeamAndKeepsChromaOrder() {
        let chromas = stride(from: 0.01, through: 0.2001, by: 0.0025).map { $0 }
        for pr in [Self.defaultProtect, 100] {
            for (v, s) in [(0.0, 100.0), (100.0, 0.0)] {
                let p = probe(vib: v, sat: s, protect: pr)
                for L in [0.6, 0.75] {
                    for h in [40.0, 55, 70, 85] {
                        var prev: (C: Double, g: Double, out: Double)?
                        for C in chromas {
                            let c = Self.rgb(L, C, h)
                            guard Self.inGamut(c) else { prev = nil; continue }
                            let out = Self.lch(p.stage.apply(c)).C
                            let g = out / C
                            if let q = prev {
                                XCTAssertGreaterThanOrEqual(out - q.out, -1e-6,
                                                            "chroma order P\(pr) L \(L) h \(h) C \(C)")
                                if q.C >= 0.03 {
                                    XCTAssertLessThanOrEqual(abs(g - q.g) / 0.25, 0.3,
                                                             "chroma seam P\(pr) V\(v) S\(s) L \(L) h \(h) C \(C)")
                                }
                            }
                            prev = (C, g, out)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Density

    private func medianEV(_ p: WS16Probe) -> Double {
        let y = ColorEngine.workingSpace.luminanceWeights
        func Y(_ c: RGB) -> Double { y.r * c.r + y.g * c.g + y.b * c.b }
        var evs: [Double] = []
        for x in Self.grid where x.C > 0.02 {
            evs.append(log2(Swift.max(Y(p.stage.apply(x.rgb)), 1e-12) / Y(x.rgb)))
        }
        evs.sort()
        return evs[evs.count / 2]
    }

    func testWS16_DEN1a_SaturationAtTheDefaultDensityDoesNotDarken() {
        XCTAssertGreaterThanOrEqual(medianEV(probe(sat: 100)), -0.06)
    }

    func testWS16_DEN2_APositiveSaturationNeverLowersChroma() {
        for s in [25.0, 50, 100] {
            for d in [0.0, 25, 50, 75, 100] {
                let p = probe(sat: s, density: d)
                for x in Self.grid where x.C > 0.02 {
                    XCTAssertGreaterThanOrEqual(chromaGain(p, x.rgb), 1 - 1e-4,
                                                "S\(s) D\(d) L \(x.L) C \(x.C) h \(x.h)")
                    XCTAssertGreaterThanOrEqual(Self.lch(p.engine.apply(x.rgb)).C / x.C, 1 - 1e-9)
                }
            }
        }
    }

    func testWS16_DEN4_DensityDarkensMonotonically() {
        let meds = [0.0, 25, 50, 75, 100].map { medianEV(probe(sat: 100, density: $0)) }
        for (a, b) in zip(meds, meds.dropFirst()) { XCTAssertLessThanOrEqual(b, a + 1e-4, "\(meds)") }
        XCTAssertLessThanOrEqual(meds.last!, meds.first! - 0.1, "\(meds)")
    }

    // MARK: - Black & White

    private func band(_ i: Int, _ v: Double) -> [Double] {
        var b = [Double](repeating: 0, count: 8); b[i] = v; return b
    }

    /// EV of each colour's grey against the default (all-zero) mix, on the twin.
    private func ev(_ colours: [RGB], _ bands: [Double]) -> [Double] {
        let zero = probe(bw: [Double](repeating: 0, count: 8)).stage
        let mixed = probe(bw: bands).stage
        return colours.map { log2(Swift.max(mixed.apply($0).g, 1e-30) / Swift.max(zero.apply($0).g, 1e-30)) }
    }

    private func centreSamples() -> [(Int, RGB)] {
        var out: [(Int, RGB)] = []
        for (i, h) in ColorEngine.bandHueCentres.enumerated() {
            for C in [0.10, 0.15] where Self.inGamut(Self.rgb(0.6, C, h)) {
                out.append((i, Self.rgb(0.6, C, h)))
            }
        }
        return out
    }

    func testWS16_BW1_ABandAtFullTravelMovesItsColourByOneToTwoAndAHalfStops() {
        for (i, c) in centreSamples() {
            let down = ev([c], band(i, -100))[0], up = ev([c], band(i, 100))[0]
            XCTAssertTrue((-2.5)...(-1.0) ~= down, "band \(i) −100: \(down) EV")
            XCTAssertTrue(1.0...2.5 ~= up, "band \(i) +100: \(up) EV")
        }
    }

    func testWS16_BW2_TheResponseIsSymmetricAndLinearInEV() {
        for (i, c) in centreSamples() {
            let m = ev([c], band(i, -100))[0], p = ev([c], band(i, 100))[0]
            let m50 = ev([c], band(i, -50))[0], p50 = ev([c], band(i, 50))[0]
            XCTAssertLessThanOrEqual(abs(p + m), 0.1, "band \(i)")
            XCTAssertLessThanOrEqual(abs(m50 / m - 0.5), 0.1, "band \(i)")
            XCTAssertLessThanOrEqual(abs(p50 / p - 0.5), 0.1, "band \(i)")
        }
    }

    func testWS16_BW3a_NoMixTakesAColourMoreThanThreeStopsDown() {
        let y = ColorEngine.workingSpace.luminanceWeights
        let colours = Self.grid.map(\.rgb).filter { y.r * $0.r + y.g * $0.g + y.b * $0.b > 1e-4 }
        for bands in (0..<8).map({ band($0, -100) }) + [[Double](repeating: -100, count: 8)] {
            XCTAssertGreaterThanOrEqual(ev(colours, bands).min()!, -3.0, "\(bands)")
        }
    }

    func testWS16_BW4_TheChromaGateIsSoft() {
        let chromas = stride(from: 0.0, through: 0.2001, by: 0.005).map { $0 }
        for (i, h) in ColorEngine.bandHueCentres.enumerated() {
            var prev: Double?
            var e4 = 0.0, e12: Double?
            for C in chromas {
                let c = Self.rgb(0.6, C, h)
                guard Self.inGamut(c) else { prev = nil; continue }
                let e = ev([c], band(i, -100))[0]
                if let q = prev { XCTAssertLessThanOrEqual(abs(e - q) / 0.5, 0.3, "band \(i) C \(C)") }
                prev = e
                if abs(C - 0.04) < 1e-9 { e4 = e }
                if abs(C - 0.12) < 1e-9 { e12 = e }
            }
            if let b = e12 { XCTAssertLessThanOrEqual(e4 / b, 0.75, "band \(i)") }
        }
    }

    func testWS16_BW5_TheMixIsSmoothAcrossHueWithNoNotch() {
        let hs = stride(from: 0.0, to: 360.0, by: 0.5).map { $0 }
        let colours = hs.map { Self.rgb(0.6, 0.10, $0) }
        let ok = colours.map(Self.inGamut)
        func slopeAndSpread(_ bands: [Double], within: (Double) -> Bool = { _ in true })
            -> (Double, Double) {
            let e = ev(colours, bands)
            var slope = 0.0, lo = Double.infinity, hi = -Double.infinity
            for k in 0..<hs.count where ok[k] {
                if k > 0, ok[k - 1] { slope = Swift.max(slope, abs(e[k] - e[k - 1]) / 0.5) }
                if within(hs[k]) { lo = Swift.min(lo, e[k]); hi = Swift.max(hi, e[k]) }
            }
            return (slope, hi - lo)
        }
        for i in 0..<8 {
            for v in [-100.0, 100] {
                XCTAssertLessThanOrEqual(slopeAndSpread(band(i, v)).0, 0.08, "band \(i) \(v)")
            }
        }
        XCTAssertLessThanOrEqual(slopeAndSpread([Double](repeating: -100, count: 8)).1, 0.05)
        let centres = ColorEngine.bandHueCentres
        for i in 0..<8 {
            let j = (i + 1) % 8
            var bands = [Double](repeating: 0, count: 8); bands[i] = -100; bands[j] = -100
            let a = centres[i], span = Self.hueDelta(a, centres[j])
            let spread = slopeAndSpread(bands) { h in
                let d = Self.hueDelta(a, h); return d >= 0 && d <= span
            }.1
            XCTAssertLessThanOrEqual(spread, 0.1, "bands \(i)+\(j)")
        }
    }

    func testWS16_BW6a_NeutralsAreFixedExactly() {
        var settings = (0..<8).flatMap { i in [band(i, -100), band(i, 100)] }
        settings += [[Double](repeating: -100, count: 8), [Double](repeating: 100, count: 8),
                     [50, -50, 100, -100, 30, -70, 0, 20]]
        for bands in settings {
            let p = probe(bw: bands)
            for v in [0.001, 0.01, 0.05, 0.18, 0.5, 1.0, 4.0] {
                let t = p.stage.apply(RGB(gray: v)), e = p.engine.apply(RGB(gray: v))
                for x in [t.r, t.g, t.b] { XCTAssertEqual(x, v, accuracy: v * 1e-6, "\(bands)") }
                for x in [e.r, e.g, e.b] { XCTAssertEqual(x, v, accuracy: v * 1e-12, "\(bands)") }
            }
        }
    }

    func testWS16_BW7_TheDefaultMixIsRec2020Luminance() {
        let y = ColorEngine.workingSpace.luminanceWeights
        let p = probe(bw: [Double](repeating: 0, count: 8))
        for x in Self.grid {
            let Y = y.r * x.rgb.r + y.g * x.rgb.g + y.b * x.rgb.b
            guard Y > 1e-4 else { continue }
            XCTAssertEqual(p.stage.apply(x.rgb).g, Y, accuracy: Y * 1e-5)
            XCTAssertEqual(p.engine.apply(x.rgb).g, Y, accuracy: Y * 1e-12)
        }
    }

    // MARK: - Parity

    func testWS16_PAR1_TheFloatTwinMatchesTheDoubleEngine() {
        var colours: [RGB] = [0.001, 0.05, 0.18, 1.0, 4.0].map { RGB(gray: $0) }
        for L in [0.3, 0.45, 0.6, 0.75, 0.9] {
            for C in [0.005, 0.01, 0.02, 0.03, 0.05, 0.08, 0.12, 0.16, 0.2, 0.25, 0.3] {
                for h in stride(from: 0.0, to: 360.0, by: 3.0) {
                    let c = Self.rgb(L, C, h)
                    if Self.inGamut(c) { colours.append(c) }
                }
            }
        }
        let z = [Double](repeating: 0, count: 8)
        let settings: [WS16Probe] = [-100.0, -50, -25, 25, 50, 100].map { probe(sat: $0) }
            + [-100.0, -50, 50, 100].map { probe(vib: $0) }
            + [probe(sat: 100, density: 0), probe(sat: 100, density: 100),
               probe(vib: 60, sat: 60, protect: 0), probe(vib: 100, protect: 100),
               probe(sat: 100, protect: 100), probe(vib: 80, sat: -40, density: 25, protect: 40),
               probe(bw: z), probe(bw: band(0, -100)), probe(bw: [50, -50, 100, -100, 30, -70, 0, 20]),
               probe(bw: [Double](repeating: -100, count: 8)),
               probe(bw: [Double](repeating: 100, count: 8)),
               probe(sat: 100, bw: band(5, -100))]
        for (k, p) in settings.enumerated() {
            var worst = 0.0
            for c in colours {
                let e = p.engine.apply(c), t = p.stage.apply(c)
                for (a, b) in [(e.r, t.r), (e.g, t.g), (e.b, t.b)] {
                    worst = Swift.max(worst, abs(a - b) / Swift.max(1, abs(a)))
                }
            }
            XCTAssertLessThanOrEqual(worst, 1e-4, "setting \(k)")
        }
    }
}

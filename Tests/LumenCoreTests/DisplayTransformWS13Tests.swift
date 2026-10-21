// DisplayTransformWS13Tests.swift
// The measurable lines of docs/quality/lanes/WS-13/SPEC.md, on the exact transform
// (`DisplayTransform.apply` / `tone`, no table, no 8-bit encode):
//   · scene mid-grey renders at display mid-grey on every curved preset, at every peak
//     (the split constants; 1.1's lift to 0.25 is deferred to WS-05's white anchor)
//   · a +3 EV white anchor puts sensor white near white and still rolls off (2.1, 2.2)
//   · the outset undoes the inset rotation, so skies and LED blue keep their hue (3.1, 3.2)
//   · the path to white keeps hue: blues and a full hue ring, chroma falling to white from
//     the +1.5 EV onset (3.6-3.9)
//   · ColorChecker chroma lands at 1.05…1.20 of truth on Neutral, Soft < Neutral < Punchy (4.1, 4.2)
//   · the whole Skew slider is live and monotone (5.1); Black target's range is all live (6.1, 6.2)

import XCTest
@testable import LumenCore

final class DisplayTransformWS13Tests: XCTestCase {

    private let curved = ["Neutral", "Soft", "Punchy", "Film Base"]
    private let ok = OKLabTransform.working
    private let srgbToWorking = RGBColorSpace.srgb.matrix(to: .rec2020)
    private let workingToSRGB = RGBColorSpace.rec2020.matrix(to: .srgb)

    private func transform(_ preset: String,
                           _ edit: (inout DisplayTransformParams) -> Void = { _ in }) -> DisplayTransform {
        var p = DisplayTransformParams.preset(named: preset)
        edit(&p)
        return DisplayTransform(p)
    }

    private func hueDelta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// An sRGB 8-bit colour in the working space, scaled to luminance `y`.
    private func srgb8(_ r: Double, _ g: Double, _ b: Double, luminance y: Double) -> RGB {
        let lin = RGB(TransferFunction.srgb.decode(r / 255),
                      TransferFunction.srgb.decode(g / 255),
                      TransferFunction.srgb.decode(b / 255))
        let w = srgbToWorking.apply(lin)
        return w * (y / RGBColorSpace.rec2020.luminance(w))
    }

    private func code(_ displayLinear: Double) -> Double {
        255 * TransferFunction.srgb.encode(Num.clamp(displayLinear, 0, 1))
    }

    // MARK: 1. Density

    func testSceneMidGreyLandsOnDisplayMidGreyAtEveryPeak() {
        XCTAssertEqual(DisplayTransform.sceneMidGrey, 0.18)
        let display = DisplayTransform.displayMidGrey
        for preset in curved {
            for peak in [100.0, 400, 1600] {
                let t = transform(preset) { $0.whiteTarget = peak }
                XCTAssertEqual(t.tone(0.18), display, accuracy: 1e-9, "\(preset) at \(peak) %")
                let grey = t.apply(RGB(gray: 0.18))
                for i in 0..<3 {
                    XCTAssertEqual(grey[i], display, accuracy: 1e-9, "\(preset) at \(peak) %, channel \(i)")
                }
            }
        }
        // Linear is the escape hatch, not a curved preset: identity, untouched.
        XCTAssertEqual(transform("Linear").tone(0.18), 0.18, accuracy: 1e-12)
    }

    // MARK: 2. A lower white anchor (in-lane, unit level)

    func testSensorWhiteNearsWhiteWithTheAnchorAtThreeEV() {
        let t = transform("Neutral") { $0.whiteAnchorEV = 3 }
        // Sensor white, scene 1.0 = +2.47 EV over 0.18.
        XCTAssertGreaterThanOrEqual(code(t.tone(1.0)), 240,
                                    "sensor white renders at code \(code(t.tone(1.0)))")
        func slope(_ ev: Double, _ h: Double = 0.005) -> Double {
            (log2(t.tone(0.18 * exp2(ev + h))) - log2(t.tone(0.18 * exp2(ev - h)))) / (2 * h)
        }
        var previous = Double.infinity
        var ev = 1.0
        while ev <= 3 - 0.05 + 1e-9 {
            let s = slope(ev)
            XCTAssertLessThan(s, previous, "log-log slope rose at +\(ev) EV: a hard edge, not a shoulder")
            previous = s
            ev += 0.05
        }
        XCTAssertLessThan(slope(3 - 0.05), 0.3)
        XCTAssertEqual(t.tone(0.18 * exp2(3)), t.white, accuracy: 1e-9)
    }

    // MARK: 3. Hue: the outset undoes the rotation; the path to white keeps hue

    func testTheOutsetUndoesTheInsetRotationInFull() {
        // Rotation only, purity fully restored, hue-stable: a midtone colour must come
        // back with exactly its own chromaticity (the old blend kept 60 % of the turn).
        let t = transform("Neutral") {
            $0.attenuation = RGB(0, 0, 0)
            $0.purityRestore = 1
            $0.chromaGain = 1   // isolate the matrices from the constant-hue gain
        }
        for c in [srgb8(74, 127, 192, luminance: 0.09), srgb8(20, 30, 255, luminance: 0.02),
                  srgb8(200, 60, 40, luminance: 0.06), srgb8(60, 160, 70, luminance: 0.08)] {
            let out = t.apply(c)
            let a = ok.toLCh(c), b = ok.toLCh(out)
            XCTAssertEqual(hueDelta(b.h, a.h), 0, accuracy: 0.01, "\(c)")
        }
    }

    func testSkiesAndLEDBlueKeepTheirHue() {
        let lMid = ok.toLab(RGB(gray: 0.18)).L
        let skies: [(String, RGB)] = [
            ("#4A7FC0", srgb8(74, 127, 192, luminance: 0.18)),
            ("CC blue sky", RGB(0.143878, 0.191049, 0.31574) * (0.18 / 0.186051)),
            ("hue 240", ok.toRGB(OKLCh(L: lMid, C: 0.08, h: 240))),
            ("hue 270", ok.toRGB(OKLCh(L: lMid, C: 0.08, h: 270))),
        ]
        for preset in curved {
            let t = transform(preset)
            for (name, c) in skies {
                let hin = ok.toLCh(c).h
                for ev in stride(from: -3.0, through: 2.0, by: 0.5) {
                    let out = ok.toLCh(t.apply(c * exp2(ev), gamut: Gamut.sharedBoundary))
                    guard out.C >= 0.02 else { continue }
                    XCTAssertLessThanOrEqual(abs(hueDelta(out.h, hin)), 3,
                                             "\(preset) \(name) at \(ev) EV")
                }
            }
            let led = srgb8(0, 0, 255, luminance: 0.18)
            let dh = hueDelta(ok.toLCh(t.apply(led, gamut: Gamut.sharedBoundary)).h, ok.toLCh(led).h)
            XCTAssertLessThanOrEqual(abs(dh), 15, "\(preset) LED blue at 0 EV")
        }
    }

    /// SPEC 3.6 probes: sRGB blue, deep sky, azure, mid sky, pale sky, CC blue sky.
    private func blueProbes(luminance y: Double) -> [(String, RGB)] {
        [("sRGB blue", srgb8(20, 30, 255, luminance: y)),
         ("deep sky", srgb8(40, 90, 190, luminance: y)),
         ("azure", srgb8(30, 120, 220, luminance: y)),
         ("mid sky", srgb8(90, 140, 200, luminance: y)),
         ("pale sky", srgb8(170, 200, 230, luminance: y)),
         ("CC blue sky", RGB(0.143878, 0.191049, 0.31574) * (y / 0.186051))]
    }

    /// SPEC 3.7 ring: 24 hues at the mid-grey lightness, C 0.08 and 75 % of the
    /// working gamut's maximum.
    private func ringProbes() -> [(String, RGB)] {
        let lMid = ok.toLab(RGB(gray: 0.18)).L
        var out: [(String, RGB)] = []
        for k in 0..<24 {
            let h = Double(k) * 15
            out.append(("hue \(h) C0.08", ok.toRGB(OKLCh(L: lMid, C: 0.08, h: h))))
            let cmax = Gamut.maxChroma(L: lMid, hue: h)
            out.append(("hue \(h) 75%", ok.toRGB(OKLCh(L: lMid, C: 0.75 * cmax, h: h))))
        }
        return out
    }

    private let srgbContext = OKLabTransform.Context(space: .srgb)
    private lazy var srgbBoundary = Gamut.Boundary(context: srgbContext)

    /// Output hue through the working gamut map, and through an sRGB display's.
    private func outputHues(_ t: DisplayTransform, _ c: RGB) -> [(hue: Double, chroma: Double)] {
        let out = t.apply(c, gamut: nil)
        let a = ok.toLCh(out)
        let inSRGB = workingToSRGB.apply(out)
        let mapped = Gamut.softClip(inSRGB, boundary: srgbBoundary, context: srgbContext)
        let b = srgbContext.toLCh(mapped)
        return [(a.h, a.C), (b.h, b.C)]
    }

    func testBluesHoldHueOnTheWayToWhite() {
        for preset in curved {
            let t = transform(preset)
            let limit = t.params.huePreservation >= 100 ? 5.0 : 12.0
            var worst = 0.0
            var worstAt = ""
            for ev in stride(from: -2.0, through: 3.0, by: 0.25) {
                for (name, c) in blueProbes(luminance: 0.18 * exp2(ev)) {
                    let hin = ok.toLCh(c).h
                    for o in outputHues(t, c) where o.chroma >= 0.02 {
                        let d = abs(hueDelta(o.hue, hin))
                        if d > worst { worst = d; worstAt = "\(name) at \(ev) EV" }
                    }
                }
            }
            XCTAssertLessThanOrEqual(worst, limit, "\(preset): \(worst)° at \(worstAt)")
        }
    }

    func testTheHueRingHoldsHueOnTheWayToWhite() {
        for preset in ["Neutral", "Soft", "Punchy"] {
            let t = transform(preset)
            var drifts: [Double] = []
            var worstAt = ""
            var worst = 0.0
            for (name, c) in ringProbes() {
                let hin = ok.toLCh(c).h
                for ev in stride(from: -2.0, through: 3.0, by: 0.25) {
                    for o in outputHues(t, c * exp2(ev)) where o.chroma >= 0.02 {
                        let d = abs(hueDelta(o.hue, hin))
                        drifts.append(d)
                        if d > worst { worst = d; worstAt = "\(name) at \(ev) EV" }
                    }
                }
            }
            drifts.sort()
            let p95 = drifts[Int(Double(drifts.count - 1) * 0.95)]
            XCTAssertLessThanOrEqual(worst, 6, "\(preset): \(worst)° at \(worstAt)")
            XCTAssertLessThanOrEqual(p95, 4, "\(preset): p95 \(p95)°")
        }
    }

    func testTheRollOffStillReachesWhite() {
        for preset in curved {
            let t = transform(preset)
            let anchor = t.params.whiteAnchorEV
            let probes: [(String, (Double) -> RGB)] =
                blueProbes(luminance: 0.18).map { name, c in (name, { c * exp2($0) }) }
                + ringProbes().map { name, c in (name, { c * exp2($0) }) }
            for (name, at) in probes {
                var previousC = Double.infinity
                var previousY = -Double.infinity
                for ev in stride(from: 1.0, through: anchor, by: 0.125) {
                    let out = t.apply(at(ev), gamut: Gamut.sharedBoundary)
                    let c = ok.toLCh(out).C
                    let y = RGBColorSpace.rec2020.luminance(out)
                    // SPEC 3.8 (amended, round 3): chroma non-increasing from the
                    // bleach onset, +1.5 EV; luminance monotone from +1 EV.
                    if ev > 1.5 {
                        XCTAssertLessThanOrEqual(c, previousC + 1e-6,
                                                 "\(preset) \(name): chroma rose at +\(ev) EV")
                    }
                    XCTAssertGreaterThanOrEqual(y, previousY - 1e-9,
                                                "\(preset) \(name): luminance fell at +\(ev) EV")
                    previousC = c
                    previousY = y
                }
                let atAnchor = ok.toLCh(t.apply(at(anchor), gamut: Gamut.sharedBoundary)).C
                XCTAssertLessThanOrEqual(atAnchor, 0.02, "\(preset) \(name) at the white anchor")
            }
        }
    }

    /// SPEC 3.9 on the exact transform: a fine disk of colours at the mid-grey
    /// lightness, exposure 0 and +2. Neighbours 0.5° apart in hue (and one radial step
    /// apart) must stay within 2° of each other in output hue at p99.9: a fold or a
    /// crease shows up as a jump.
    func testNoHueFoldsAcrossTheWheel() {
        let lMid = ok.toLab(RGB(gray: 0.18)).L
        let hueSteps = 720
        let radii = 24
        for preset in curved {
            let t = transform(preset)
            for ev in [0.0, 2.0] {
                var grid = [[(h: Double, c: Double)]](repeating: [], count: radii)
                for r in 0..<radii {
                    for k in 0..<hueSteps {
                        let h = Double(k) * 360 / Double(hueSteps)
                        let cmax = Gamut.maxChroma(L: lMid, hue: h)
                        let cin = cmax * (0.15 + 0.8 * Double(r) / Double(radii - 1))
                        let c = ok.toRGB(OKLCh(L: lMid, C: cin, h: h)) * exp2(ev)
                        let o = ok.toLCh(t.apply(c, gamut: Gamut.sharedBoundary))
                        grid[r].append((o.h, o.C))
                    }
                }
                var jumps: [Double] = []
                for r in 0..<radii {
                    for k in 0..<hueSteps {
                        let a = grid[r][k], b = grid[r][(k + 1) % hueSteps]
                        if a.c >= 0.03 && b.c >= 0.03 { jumps.append(abs(hueDelta(a.h, b.h))) }
                        if r + 1 < radii {
                            let d = grid[r + 1][k]
                            if a.c >= 0.03 && d.c >= 0.03 { jumps.append(abs(hueDelta(a.h, d.h))) }
                        }
                    }
                }
                jumps.sort()
                let p999 = jumps[Int(Double(jumps.count - 1) * 0.999)]
                XCTAssertLessThanOrEqual(p999, 2, "\(preset) at +\(ev) EV: hue jump p99.9 \(p999)°")
            }
        }
    }

    // MARK: 4. Saturation

    /// The 18 chromatic ColorChecker patches (C* > 8): working-space scene value and
    /// D65 XYZ truth, from corpus/synthetic/colorchecker.json.
    private let checker: [(RGB, RGB)] = [
        (RGB(0.138062, 0.088105, 0.060869), RGB(0.110961, 0.099614, 0.067054)),
        (RGB(0.462423, 0.310898, 0.230638), RGB(0.378456, 0.345944, 0.253432)),
        (RGB(0.143878, 0.191049, 0.31574), RGB(0.172595, 0.186051, 0.340359)),
        (RGB(0.115025, 0.144549, 0.061241), RGB(0.104513, 0.131853, 0.069033)),
        (RGB(0.228926, 0.218727, 0.411861), RGB(0.247003, 0.232859, 0.443118)),
        (RGB(0.25502, 0.485138, 0.416603), RGB(0.302952, 0.420622, 0.455628)),
        (RGB(0.536219, 0.236452, 0.055065), RGB(0.385043, 0.304444, 0.065061)),
        (RGB(0.088202, 0.105261, 0.371083), RGB(0.134072, 0.116544, 0.396668)),
        (RGB(0.388547, 0.117995, 0.123905), RGB(0.285478, 0.18942, 0.134774)),
        (RGB(0.089764, 0.048197, 0.133545), RGB(0.086699, 0.064178, 0.143042)),
        (RGB(0.386398, 0.492222, 0.094727), RGB(0.3333, 0.44085, 0.114322)),
        (RGB(0.617819, 0.38565, 0.063047), RGB(0.459944, 0.42751, 0.077719)),
        (RGB(0.039919, 0.05068, 0.266393), RGB(0.077745, 0.060645, 0.284062)),
        (RGB(0.136939, 0.280704, 0.088882), RGB(0.14283, 0.231562, 0.102182)),
        (RGB(0.297793, 0.059863, 0.046736), RGB(0.206232, 0.121589, 0.051267)),
        (RGB(0.725137, 0.581232, 0.070158), RGB(0.557787, 0.588729, 0.090753)),
        (RGB(0.377236, 0.121841, 0.291941), RGB(0.307207, 0.199021, 0.313165)),
        (RGB(0.075184, 0.229084, 0.379727), RGB(0.145147, 0.197588, 0.409316)),
    ]

    private func cielabChroma(xyz: RGB) -> Double {
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(xyz.r / 0.95047), fy = f(xyz.g), fz = f(xyz.b / 1.08883)
        return hypot(500 * (fx - fy), 200 * (fy - fz))
    }

    /// Mean CIELAB chroma of the rendered patches over their truth, through an sRGB
    /// display's clip (what `ws13_checks.py cc` reads off the PNG).
    private func checkerChromaRatio(_ preset: String) -> Double {
        let t = transform(preset)
        let srgbToXYZ = RGBColorSpace.srgb.toXYZ
        var sum = 0.0
        for (scene, truth) in checker {
            let out = t.apply(scene, gamut: Gamut.sharedBoundary)
            let s = workingToSRGB.apply(out).clamped(0, 1)
            sum += cielabChroma(xyz: srgbToXYZ.apply(s)) / cielabChroma(xyz: truth)
        }
        return sum / Double(checker.count)
    }

    func testColorCheckerChromaIsRestoredAndOrdered() {
        let soft = checkerChromaRatio("Soft")
        let neutral = checkerChromaRatio("Neutral")
        let punchy = checkerChromaRatio("Punchy")
        XCTAssertGreaterThanOrEqual(neutral, 1.05)
        XCTAssertLessThanOrEqual(neutral, 1.20)
        XCTAssertLessThan(soft, neutral)
        XCTAssertLessThan(neutral, punchy)
    }

    // MARK: 5-6. Skew and Black target

    func testTheWholeSkewRangeIsLiveAndMonotone() {
        var previous: (toe: Double, shoulder: Double)?
        for k in 0...8 {
            let skew = -1 + Double(k) * 0.25
            let t = transform("Neutral") { $0.skew = skew }
            let toe = code(t.tone(0.18 * exp2(-4)))
            let shoulder = code(t.tone(0.18 * exp2(2)))
            if let p = previous {
                XCTAssertGreaterThanOrEqual(toe, p.toe - 1e-9, "toe fell at skew \(skew)")
                XCTAssertGreaterThanOrEqual(shoulder, p.shoulder - 1e-9, "shoulder fell at skew \(skew)")
                XCTAssertGreaterThanOrEqual(max(toe - p.toe, shoulder - p.shoulder), 0.5,
                                            "skew \(skew - 0.25)…\(skew) is dead")
            }
            previous = (toe, shoulder)
            XCTAssertNil(t.firstNonMonotonicX(), "skew \(skew)")
        }
        // Skew 0 is the identity of the default.
        let zero = transform("Neutral") { $0.skew = 0 }
        for ev in stride(from: -9.0, through: 5.0, by: 0.5) {
            XCTAssertEqual(zero.tone(0.18 * exp2(ev)), transform("Neutral").tone(0.18 * exp2(ev)))
        }
    }

    func testEveryBlackTargetInTheRangeIsLive() {
        let range = DisplayTransformParams.blackTargetRange
        XCTAssertEqual(range.upperBound, DisplayTransform.displayMidGrey * 50, accuracy: 1e-12)
        var seen: [Double] = []
        for v in Int(range.lowerBound)...Int(range.upperBound) {
            let t = transform("Neutral") { $0.blackTarget = Double(v) }
            XCTAssertEqual(t.black, Double(v) / 100, accuracy: 1e-12, "black target \(v)")
            XCTAssertEqual(t.tone(0.18 * exp2(-9)), t.black, accuracy: 1e-9)
            XCTAssertEqual(t.tone(0.18), DisplayTransform.displayMidGrey, accuracy: 1e-9,
                           "black target \(v) moved mid-grey")
            XCTAssertNil(t.firstNonMonotonicX(), "black target \(v)")
            XCTAssertFalse(seen.contains(t.black))
            seen.append(t.black)
        }
        XCTAssertEqual(transform("Neutral") { $0.blackTarget = 40 }.black, range.upperBound / 100)
    }
}

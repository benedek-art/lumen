// WS15DehazeSpecTests.swift
//
// The unit-test half of the WS-15 Dehaze acceptance spec
// (docs/quality/lanes/WS-15/SPEC.md, lines U1-U11). Each test is a synthetic frame with
// known ground truth, run through `DetailEngine.Decomposition` / `applyDehaze` directly,
// in scene-linear Rec.2020 — no display transform — so a failure points at the stage.
//
// The test names are binding: `tools/check_spec.py --swift` reports them by name.

import Foundation
import XCTest
@testable import LumenCore

final class WS15DehazeSpecTests: XCTestCase {

    // MARK: - Helpers

    static func node(_ image: ImageBuffer) -> DetailEngine.Decomposition {
        let radius = Swift.max(Int(Double(Swift.max(image.width, image.height)) * 0.02), 3)
        return DetailEngine.Decomposition(image: image, workingRadius: radius)
    }

    static func dehaze(_ image: ImageBuffer, _ amount: Double,
                       node: DetailEngine.Decomposition? = nil) -> ImageBuffer {
        DetailEngine.applyDehaze(image, amount: amount, decomposition: node ?? Self.node(image))
    }

    static func lab(_ c: RGB) -> OKLab { OKLabTransform.working.toLab(c) }

    /// Mean OKLab over a fractional box [x0, y0, x1, y1].
    static func meanLab(_ image: ImageBuffer, _ box: [Double]) -> OKLab {
        var L = 0.0, a = 0.0, b = 0.0, n = 0.0
        forEach(image, box) { c in
            let l = lab(c); L += l.L; a += l.a; b += l.b; n += 1
        }
        return OKLab(L: L / n, a: a / n, b: b / n)
    }

    static func forEach(_ image: ImageBuffer, _ box: [Double], _ body: (RGB) -> Void) {
        let x0 = Int(box[0] * Double(image.width)), x1 = Int(box[2] * Double(image.width))
        let y0 = Int(box[1] * Double(image.height)), y1 = Int(box[3] * Double(image.height))
        for y in y0..<Swift.max(y1, y0 + 1) { for x in x0..<Swift.max(x1, x0 + 1) { body(image[x, y]) } }
    }

    static func luma(_ c: RGB) -> Double { RGBColorSpace.rec2020.luminance(c) }

    static func fill(_ image: inout ImageBuffer, _ box: [Double], _ colour: RGB) {
        let x0 = Int(box[0] * Double(image.width)), x1 = Int(box[2] * Double(image.width))
        let y0 = Int(box[1] * Double(image.height)), y1 = Int(box[3] * Double(image.height))
        for y in y0..<y1 { for x in x0..<x1 { image[x, y] = colour } }
    }

    static func chromaticity(_ c: RGB) -> (Double, Double) {
        let s = c.r + c.g + c.b
        return (c.r / s, c.g / s)
    }

    /// Share of the airlight selection inside a fractional box.
    static func selectionShare(_ sel: Plane, inside box: [Double]) -> Double {
        var inBox = 0.0, total = 0.0
        for y in 0..<sel.height {
            for x in 0..<sel.width where sel[x, y] > 0.5 {
                total += 1
                let u = (Double(x) + 0.5) / Double(sel.width), v = (Double(y) + 0.5) / Double(sel.height)
                if u >= box[0] && u < box[2] && v >= box[1] && v < box[3] { inBox += 1 }
            }
        }
        return total > 0 ? inBox / total : 1
    }

    /// CIEDE2000 between two scene-linear Rec.2020 colours (D65 white = Y 1).
    static func deltaE2000(_ p: RGB, _ q: RGB) -> Double {
        func cielab(_ c: RGB) -> (Double, Double, Double) {
            let x = 0.636958 * c.r + 0.144617 * c.g + 0.168881 * c.b
            let y = 0.262700 * c.r + 0.677998 * c.g + 0.059302 * c.b
            let z = 0.000000 * c.r + 0.028073 * c.g + 1.060985 * c.b
            func f(_ t: Double) -> Double {
                t > pow(6.0 / 29, 3) ? cbrt(t) : t / (3 * pow(6.0 / 29, 2)) + 4.0 / 29
            }
            let fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883)
            return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
        }
        let (L1, a1, b1) = cielab(p), (L2, a2, b2) = cielab(q)
        let C1 = hypot(a1, b1), C2 = hypot(a2, b2), Cb = (C1 + C2) / 2
        let G = 0.5 * (1 - sqrt(pow(Cb, 7) / (pow(Cb, 7) + pow(25.0, 7))))
        let a1p = (1 + G) * a1, a2p = (1 + G) * a2
        let C1p = hypot(a1p, b1), C2p = hypot(a2p, b2)
        func hue(_ b: Double, _ a: Double) -> Double {
            var h = atan2(b, a) * 180 / .pi; if h < 0 { h += 360 }; return h
        }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = L2 - L1, dCp = C2p - C1p
        var dh = h2p - h1p
        if C1p * C2p == 0 { dh = 0 } else if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        let dHp = 2 * sqrt(C1p * C2p) * sin(dh * .pi / 360)
        let Lbp = (L1 + L2) / 2, Cbp = (C1p + C2p) / 2
        var hbp = h1p + h2p
        if C1p * C2p != 0 {
            if abs(h1p - h2p) <= 180 { hbp /= 2 } else { hbp = hbp < 360 ? (hbp + 360) / 2 : (hbp - 360) / 2 }
        }
        let r = Double.pi / 180
        let T = 1 - 0.17 * cos((hbp - 30) * r) + 0.24 * cos(2 * hbp * r)
            + 0.32 * cos((3 * hbp + 6) * r) - 0.20 * cos((4 * hbp - 63) * r)
        let dTheta = 30 * exp(-pow((hbp - 275) / 25, 2))
        let Rc = 2 * sqrt(pow(Cbp, 7) / (pow(Cbp, 7) + pow(25.0, 7)))
        let Sl = 1 + 0.015 * pow(Lbp - 50, 2) / sqrt(20 + pow(Lbp - 50, 2))
        let Sc = 1 + 0.045 * Cbp, Sh = 1 + 0.015 * Cbp * T
        let Rt = -sin(2 * dTheta * r) * Rc
        let tL = dLp / Sl, tC = dCp / Sc, tH = dHp / Sh
        return sqrt(tL * tL + tC * tC + tH * tH + Rt * tC * tH)
    }

    static func meanDeltaE(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var s = 0.0
        for y in 0..<a.height { for x in 0..<a.width { s += deltaE2000(a[x, y], b[x, y]) } }
        return s / Double(a.count)
    }

    /// RMS of log2 luminance (contrast) in a fractional box.
    static func logContrast(_ image: ImageBuffer, _ box: [Double]) -> Double {
        var v = [Double]()
        forEach(image, box) { v.append(log2(Swift.max(luma($0), 1e-6))) }
        let m = v.reduce(0, +) / Double(v.count)
        return sqrt(v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count))
    }

    static let sky = [0.0, 0.0, 1.0, 0.55]
    static let ground = [0.0, 0.65, 1.0, 1.0]

    // MARK: - U1

    func testIdentityAtZero() {
        let frame = ProofFrames.hazySky()
        let out = Self.dehaze(frame, 0)
        XCTAssertEqual(out.pixels, frame.pixels, "Dehaze 0 is not a bit-exact identity")
    }

    // MARK: - U2

    func testPositiveRestoresSkyChromaAndGroundContrast() {
        let frame = ProofFrames.hazySky()
        let out = Self.dehaze(frame, 100)

        let c0 = Self.meanLab(frame, Self.sky).chroma, c1 = Self.meanLab(out, Self.sky).chroma
        XCTAssertGreaterThanOrEqual(c1 / c0, 1.0, "sky chroma fell: \(c0) -> \(c1)")

        let g0 = Self.logContrast(frame, Self.ground), g1 = Self.logContrast(out, Self.ground)
        XCTAssertGreaterThanOrEqual(g1 / g0, 1.3, "ground contrast x\(g1 / g0)")

        // The clear scene is known: the recovered sky is nearer to it than the input is.
        var dIn = 0.0, dOut = 0.0, n = 0.0
        for y in 0..<Int(0.55 * Double(frame.height)) {
            let v = (Double(y) + 0.5) / Double(frame.height)   // ImageBuffer generator's v
            let clear = RGB(0.10 + 0.05 * v, 0.16 + 0.08 * v, 0.34 + 0.10 * v)
            for x in 0..<frame.width {
                dIn += Self.deltaE2000(frame[x, y], clear)
                dOut += Self.deltaE2000(out[x, y], clear)
                n += 1
            }
        }
        print(String(format: "WS15 U2 sky chroma x%.3f  ground contrast x%.3f  dE to clear sky %.2f -> %.2f",
                     c1 / c0, g1 / g0, dIn / n, dOut / n))
        XCTAssertLessThan(dOut, dIn, "the recovered sky is not closer to the clear sky")
    }

    // MARK: - U3

    func testPositiveExposureDriftBounded() {
        let frame = ProofFrames.hazySky()
        let out = Self.dehaze(frame, 100)
        var y0 = 0.0, y1 = 0.0, negatives = 0
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                y0 += Self.luma(frame[x, y]); y1 += Self.luma(out[x, y])
                if out[x, y].minComponent < 0 { negatives += 1 }
            }
        }
        let ev = log2(y1 / y0)
        print(String(format: "WS15 U3 mean drift %.3f EV, negatives %d", ev, negatives))
        XCTAssertGreaterThanOrEqual(ev, -0.7)
        XCTAssertEqual(negatives, 0)
    }

    // MARK: - U4

    static let card = [0.3, 0.7, 0.7, 0.95]   // lower 40 %, 10 % of the area

    func testAirlightIgnoresWhiteCard() {
        var frame = ProofFrames.hazySky()
        Self.fill(&frame, Self.card, RGB(gray: 0.9))
        let field = Self.node(frame).dehazeField()
        let a = Self.chromaticity(field.airlight), t = Self.chromaticity(ProofFrames.hazySkyAirlight)
        let dist = hypot(a.0 - t.0, a.1 - t.1)
        let share = Self.selectionShare(field.selection, inside: Self.card)
        print(String(format: "WS15 U4 airlight chroma dist %.4f, card share %.3f", dist, share))
        XCTAssertLessThanOrEqual(dist, 0.02)
        XCTAssertLessThanOrEqual(share, 0.05)
    }

    // MARK: - U5

    func testAirlightIgnoresMagentaObject() {
        var frame = ProofFrames.hazySky()
        Self.fill(&frame, [0.55, 0.72, 0.85, 0.92], RGB(0.6, 0.35, 0.6))
        let node = Self.node(frame)
        let a = node.airlight()
        let g = a.g / (a.r + a.g + a.b)
        XCTAssertGreaterThanOrEqual(g, 0.315, "airlight \(a) is magenta")
        let out = Self.dehaze(frame, -100, node: node)
        let ground = [0.0, 0.65, 0.5, 1.0]   // away from the patch
        let da = Self.meanLab(out, ground).a - Self.meanLab(frame, ground).a
        print(String(format: "WS15 U5 airlight g share %.4f, ground veil da %+.4f", g, da))
        XCTAssertLessThanOrEqual(da, 0.003)
    }

    // MARK: - U6

    func testNeutralPatchKeepsLightnessAndTint() {
        var frame = ProofFrames.hazySky()
        let card = [0.35, 0.72, 0.6, 0.94]
        Self.fill(&frame, card, RGB(gray: 0.45))
        let out = Self.dehaze(frame, 100)
        let centre = [0.42, 0.78, 0.53, 0.88]
        let l0 = Self.meanLab(frame, centre), l1 = Self.meanLab(out, centre)
        XCTAssertGreaterThanOrEqual(l1.L - l0.L, -0.05, "grey card darkened")
        XCTAssertLessThanOrEqual(abs(l1.a - l0.a), 0.003)
        XCTAssertLessThanOrEqual(abs(l1.b - l0.b), 0.003)
        // Rim: a one-pixel-inset ring just inside the card.
        let w = Double(frame.width), h = Double(frame.height)
        let px = 1.0 / w, py = 1.0 / h
        var rim0 = 0.0, rim1 = 0.0, n = 0.0
        for box in [[card[0] + px, card[1] + py, card[2] - px, card[1] + 3 * py],
                    [card[0] + px, card[3] - 3 * py, card[2] - px, card[3] - py],
                    [card[0] + px, card[1] + 3 * py, card[0] + 3 * px, card[3] - 3 * py],
                    [card[2] - 3 * px, card[1] + 3 * py, card[2] - px, card[3] - 3 * py]] {
            Self.forEach(frame, box) { rim0 += Self.lab($0).L; n += 1 }
            Self.forEach(out, box) { rim1 += Self.lab($0).L }
        }
        let split = (rim1 / n - l1.L) - (rim0 / n - l0.L)
        print(String(format: "WS15 U6 dL %+.4f da %+.4f db %+.4f split %+.4f",
                     l1.L - l0.L, l1.a - l0.a, l1.b - l0.b, split))
        XCTAssertLessThanOrEqual(abs(split), 0.02, "rim/centre split")
    }

    // MARK: - U7

    func testNegativeVeilFarExceedsNear() {
        let frame = ProofFrames.hazySky()
        let out = Self.dehaze(frame, -100)
        let top = [0.0, 0.0, 1.0, 1.0 / 3], bottom = [0.0, 2.0 / 3, 1.0, 1.0]
        let liftTop = Self.meanLab(out, top).L - Self.meanLab(frame, top).L
        let liftBottom = Self.meanLab(out, bottom).L - Self.meanLab(frame, bottom).L
        XCTAssertGreaterThan(liftBottom, 0, "the near field was not veiled at all")
        XCTAssertGreaterThanOrEqual(liftTop, 1.2 * liftBottom, "far \(liftTop) vs near \(liftBottom)")

        // The veil laid over the scene points toward the airlight's hue: measured on the
        // ground, where the veil is the only thing that changes the colour.
        let g0 = Self.meanLab(frame, bottom), g1 = Self.meanLab(out, bottom)
        let veilHue = atan2(g1.b - g0.b, g1.a - g0.a) * 180 / .pi
        let airHue = Self.lab(ProofFrames.hazySkyAirlight).hue
        var d = abs(Num.wrapHue(veilHue) - airHue); if d > 180 { d = 360 - d }
        print(String(format: "WS15 U7 lift far %.4f near %.4f (x%.2f), veil hue %.1f vs airlight %.1f",
                     liftTop, liftBottom, liftTop / liftBottom, Num.wrapHue(veilHue), airHue))
        XCTAssertLessThanOrEqual(d, 30, "veil hue \(veilHue) vs airlight \(airHue)")
    }

    // MARK: - U8

    func testNoHaloAtSkyTreelineStep() {
        let n = 256
        let air = ProofFrames.hazySkyAirlight
        let frame = ImageBuffer(width: n, height: n) { u, v in
            if v < 0.5 {
                let clear = RGB(0.10, 0.16, 0.34), t = 0.3
                return clear * t + air * (1 - t)
            }
            let tex = 1 + 0.3 * sin(2 * Double.pi * u * 23) * sin(2 * Double.pi * v * 17)
            let clear = RGB(0.03, 0.04, 0.025) * tex, t = 0.75
            return clear * t + air * (1 - t)
        }
        let out = Self.dehaze(frame, 100)
        // Column-averaged log2(out/in) along y; the edge sits between rows n/2-1 and n/2.
        var ratio = [Double](repeating: 0, count: n)
        for y in 0..<n {
            var s = 0.0
            for x in 0..<n {
                s += log2(Swift.max(Self.luma(out[x, y]), 1e-6) / Swift.max(Self.luma(frame[x, y]), 1e-6))
            }
            ratio[y] = s / Double(n)
        }
        let limitPx = Int(0.02 * Double(n))
        for (name, side) in [("sky", Array(ratio[0..<(n / 2)].reversed())),
                             ("ground", Array(ratio[(n / 2)...]))] {
            let far = side[Int(Double(side.count) * 0.6)...].sorted()
            let plateau = far[far.count / 2]
            let dev = side.map { $0 - plateau }
            let near = dev[0..<Int(Double(side.count) * 0.4)]
            let worst = near.map { abs($0) }.max() ?? 0
            let width = dev.firstIndex { abs($0) <= 0.1 } ?? dev.count
            print(String(format: "WS15 U8 %@ plateau %.3f EV worst near dev %.3f EV width %d px",
                         name, plateau, worst, width))
            XCTAssertLessThanOrEqual(worst, 0.3, "\(name) halo \(worst) EV")
            XCTAssertLessThanOrEqual(width, limitPx, "\(name) halo band \(width) px")
        }
    }

    // MARK: - U9

    func testScaleStableAirlightAndOutput() {
        var big = ProofFrames.hazySky(width: 512, height: 512)
        Self.fill(&big, Self.card, RGB(gray: 0.9))
        let small = DetailEngine.dehazeAreaDownsample(big, width: 128, height: 128)
        let nb = Self.node(big), ns = Self.node(small)
        let ab = nb.airlight(), asm = ns.airlight()
        let cb = Self.chromaticity(ab), cs = Self.chromaticity(asm)
        let dist = hypot(cb.0 - cs.0, cb.1 - cs.1)
        let lum = Self.luma(asm) / Self.luma(ab)
        XCTAssertLessThanOrEqual(dist, 0.01)
        XCTAssertEqual(lum, 1, accuracy: 0.1)

        for amount in [60.0, -60.0] {
            let ob = DetailEngine.dehazeAreaDownsample(Self.dehaze(big, amount, node: nb),
                                                       width: 128, height: 128)
            let os = Self.dehaze(small, amount, node: ns)
            let excess = Self.meanDeltaE(ob, os) - Self.meanDeltaE(small, small)
            print(String(format: "WS15 U9 %+.0f airlight dist %.4f lum %.3f excess dE %.3f",
                         amount, dist, lum, excess))
            XCTAssertLessThanOrEqual(excess, 0.4, "preview and full size disagree at \(amount)")
        }
    }

    // MARK: - U11

    func testMonotoneBothSides() {
        let frame = ProofFrames.hazySky()
        let node = Self.node(frame)
        func meanAbs(_ amount: Double) -> Double {
            let out = Self.dehaze(frame, amount, node: node)
            var s = 0.0
            for i in stride(from: 0, to: out.pixels.count, by: 4) {
                for c in 0..<3 { s += abs(Double(out.pixels[i + c] - frame.pixels[i + c])) }
            }
            return s / Double(frame.count * 3)
        }
        for sign in [1.0, -1.0] {
            let values = stride(from: 0.0, through: 100.0, by: 10.0).map { meanAbs(sign * $0) }
            let steps = zip(values.dropFirst(), values).map { $0 - $1 }
            XCTAssertTrue(steps.allSatisfy { $0 > 0 }, "not monotone on the \(sign) side: \(values)")
            let median = steps.sorted()[steps.count / 2]
            let front = steps[0] / median
            print(String(format: "WS15 U11 side %+.0f first/median %.3f", sign, front))
            XCTAssertGreaterThanOrEqual(front, 0.5)
            XCTAssertLessThanOrEqual(front, 1.5)
        }
    }
}

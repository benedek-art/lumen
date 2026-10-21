// WS-30 acceptance (docs/quality/lanes/WS-30/SPEC.md): the creative-LUT stage against
// cubes generated here from closed-form functions, measured in CIEDE2000 on the sRGB code
// a viewer sees. The independent numpy twin of these checks, with a second interpolant,
// is docs/quality/lanes/WS-30/tools/lutref.py.
//
// The reference in this file is written from the declared spaces, not by calling the
// stage's own helpers: the analytic function the cube samples, applied in the encoding
// the tap declares, blended by Amount in that encoding, with the out-of-domain residual
// handed back. A perfect cube at infinite resolution renders exactly this; the bounds
// below are what a 33-point cube's interpolation is allowed to cost.

import Foundation
import XCTest
@testable import LumenCore

final class CreativeLUTAccuracyTests: XCTestCase {

    // MARK: - Cubes from functions

    /// The cube file's own text, red fastest — so the parse path is part of what is
    /// measured, the way a user's file arrives.
    static func cubeText(size n: Int, _ f: (RGB) -> RGB) -> String {
        var s = "TITLE \"generated\"\nLUT_3D_SIZE \(n)\n"
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let d = Double(n - 1)
                    let v = f(RGB(Double(r) / d, Double(g) / d, Double(b) / d))
                    s += String(format: "%.9f %.9f %.9f\n", v.r, v.g, v.b)
                }
            }
        }
        return s
    }

    static func cube(size: Int, _ f: (RGB) -> RGB) -> LUT3D {
        LUT3D.fromCubeFile(cubeText(size: size, f))!
    }

    /// A known Rec.709 contrast LUT: a normalised logistic S-curve (k = 6, pivot 0.5) per
    /// channel on the encoded value, then a 15% pull toward Rec.709 luma — cross-channel,
    /// so the interpolant's off-diagonal cells are exercised.
    static func contrast709(_ v: RGB) -> RGB {
        func s(_ x: Double) -> Double { 1 / (1 + exp(-6 * (x - 0.5))) }
        func curve(_ x: Double) -> Double { (s(x) - s(0)) / (s(1) - s(0)) }
        let y = v.map(curve)
        let luma = 0.2126 * y.r + 0.7152 * y.g + 0.0722 * y.b
        return y + (RGB(gray: luma) - y) * 0.15
    }

    /// A log-domain grade: 1.25× contrast about mid-grey's `LumenLog` code, warm offset.
    static func logContrast(_ v: RGB) -> RGB {
        let grey = LumenLog.encode(0.18)
        return RGB(gray: grey) + (v - RGB(gray: grey)) * 1.25 + RGB(0.01, 0, -0.01)
    }

    // MARK: - The reference, from the declared spaces

    static let w2d = RGBColorSpace.rec2020.matrix(to: .srgb)
    static let d2w = RGBColorSpace.srgb.matrix(to: .rec2020)

    static func reference(_ x: RGB, tap: LUTReference.Tap, amount: Double,
                          _ f: (RGB) -> RGB) -> RGB {
        let a = amount / 100
        switch tap {
        case .display:
            let d = w2d.apply(x)
            let u = d.clamped()
            let e = TransferFunction.srgb.encode(u)
            let b = (e + (f(e) - e) * a).map { max($0, 0) }
            return d2w.apply(TransferFunction.srgb.decode(b) + (d - u))
        case .log:
            let e = LumenLog.encode(x)
            let u = e.clamped()
            return LumenLog.decode(e + (f(u) - u) * a)
        }
    }

    // MARK: - Samples

    /// Display-linear working values: the sRGB cube, Rec.2020 values well outside sRGB,
    /// EDR headroom to 3× white, and a 256-step neutral ramp.
    static let displaySamples: [RGB] = {
        var rng = SplitMix(seed: 7)
        var out: [RGB] = []
        for _ in 0..<1500 {
            let srgb = RGB(pow(rng.next(), 2.2), pow(rng.next(), 2.2), pow(rng.next(), 2.2))
            out.append(d2w.apply(srgb))
        }
        for _ in 0..<400 { out.append(RGB(pow(rng.next(), 2.2), pow(rng.next(), 2.2),
                                          pow(rng.next(), 2.2))) }
        for _ in 0..<200 { out.append(RGB(3 * rng.next(), 3 * rng.next(), 3 * rng.next())) }
        for i in 0..<256 { out.append(RGB(gray: Double(i) / 255)) }
        return out
    }()

    /// Scene-linear values from 10 stops under to 8 over mid-grey, a ramp, and black.
    static let sceneSamples: [RGB] = {
        var rng = SplitMix(seed: 11)
        var out: [RGB] = []
        for _ in 0..<1500 {
            out.append(RGB(0.18 * pow(2, -10 + 18 * rng.next()),
                           0.18 * pow(2, -10 + 18 * rng.next()),
                           0.18 * pow(2, -10 + 18 * rng.next())))
        }
        for i in 0..<256 { out.append(RGB(gray: 0.18 * pow(2, -10 + 18 * Double(i) / 255))) }
        out.append(.zero)
        return out
    }()

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }

    // MARK: - What a viewer sees, in CIELAB

    /// Display-linear working → the sRGB preview's code, clipped → CIELAB (D65).
    static func viewerLab(_ working: RGB) -> (Double, Double, Double) {
        let srgbLinear = w2d.apply(working).clamped()
        let xyz = RGBColorSpace.srgb.toXYZ.apply(srgbLinear)
        let white = RGBColorSpace.srgb.toXYZ.apply(.one)
        func f(_ t: Double) -> Double {
            let d = 6.0 / 29.0
            return t > d * d * d ? cbrt(t) : t / (3 * d * d) + 4.0 / 29.0
        }
        let fx = f(xyz.r / white.r), fy = f(xyz.g / white.g), fz = f(xyz.b / white.b)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// The log tap is followed by the display transform in the app; a fixed Reinhard
    /// view `x/(x+0.18)` stands in for it so scene values compare as pictures.
    static func sceneLab(_ scene: RGB) -> (Double, Double, Double) {
        let v = scene.map { max($0, 0) }.map { $0 / ($0 + 0.18) }
        return viewerLab(d2w.apply(v))
    }

    /// CIEDE2000 (Sharma, Wu & Dalal 2005), kL = kC = kH = 1.
    static func deltaE2000(_ p: (Double, Double, Double), _ q: (Double, Double, Double)) -> Double {
        let (l1, a1, b1) = p, (l2, a2, b2) = q
        let rad = Double.pi / 180
        let c1 = (a1 * a1 + b1 * b1).squareRoot(), c2 = (a2 * a2 + b2 * b2).squareRoot()
        let c7 = pow((c1 + c2) / 2, 7)
        let g = 0.5 * (1 - (c7 / (c7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot(), c2p = (a2p * a2p + b2 * b2).squareRoot()
        func hp(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / rad
            return h < 0 ? h + 360 : h
        }
        let h1p = hp(b1, a1p), h2p = hp(b2, a2p)
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp / 2 * rad)
        let lBar = (l1 + l2) / 2, cBar = (c1p + c2p) / 2
        var hBar = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 { hBar /= 2 }
            else if h1p + h2p < 360 { hBar = (hBar + 360) / 2 }
            else { hBar = (hBar - 360) / 2 }
        }
        let t = 1 - 0.17 * cos((hBar - 30) * rad) + 0.24 * cos(2 * hBar * rad)
            + 0.32 * cos((3 * hBar + 6) * rad) - 0.20 * cos((4 * hBar - 63) * rad)
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let c7b = pow(cBar, 7)
        let rc = 2 * (c7b / (c7b + pow(25, 7))).squareRoot()
        let l50 = (lBar - 50) * (lBar - 50)
        let sl = 1 + 0.015 * l50 / (20 + l50).squareRoot()
        let sc = 1 + 0.045 * cBar, sh = 1 + 0.015 * cBar * t
        let rt = -sin(2 * dTheta * rad) * rc
        let x = (l2 - l1) / sl, y = (c2p - c1p) / sc, z = dHp / sh
        return (x * x + y * y + z * z + rt * y * z).squareRoot()
    }

    // MARK: - L1 identity is exact

    /// SPEC L1. An identity cube of any common size, at either tap and any Amount, is the
    /// identity on every value — wide gamut and EDR headroom included — to 1e-6 linear
    /// (a 16-bit code is 1.5e-5), and to 1e-12 for every size whose knots i/(N−1) are
    /// exact binary fractions. 32 is in the list because its knots i/31 are not exact in
    /// Float, the one place an identity file cannot be bit-exact on disk.
    func testL1AnIdentityCubeIsTheIdentityOnEveryValueAtEitherTapAndAnyAmount() {
        for size in [17, 32, 33, 65] {
            let cube = Self.cube(size: size) { $0 }
            for amount in [37.0, 100, 200] {
                for (tap, inputs) in [(LUTReference.Tap.display, Self.displaySamples),
                                      (.log, Self.sceneSamples)] {
                    let stage = CreativeLUTStage(tap: tap, amount: amount, cube: cube)
                    // The log tap is measured in its own code: 1e-6 of `LumenLog` is
                    // 2.4e-5 stops at any exposure, where linear error grows with value.
                    let worst = inputs.map { x -> Double in
                        tap == .display ? stage.apply(x).maxAbsDifference(x)
                            : LumenLog.encode(stage.apply(x)).maxAbsDifference(LumenLog.encode(x))
                    }.max()!
                    XCTAssertLessThan(worst, 1e-6, "size \(size) \(tap) amount \(amount)")
                    if size != 32 {
                        XCTAssertLessThan(worst, 1e-12, "size \(size) \(tap): exact knots")
                    }
                }
            }
        }
    }

    // MARK: - L2 the contrast LUT against the reference

    /// SPEC L2. The Rec.709 contrast cube at 33 points, display tap, Amount 0…200: within
    /// ΔE2000 0.5 of the analytic reference on every sample.
    func testL2TheRec709ContrastCubeMatchesTheReferenceAcrossAmount() {
        let cube = Self.cube(size: 33, Self.contrast709)
        for amount in [0.0, 25, 50, 100, 150, 200] {
            let stage = CreativeLUTStage(tap: .display, amount: amount, cube: cube)
            var worst = 0.0
            for x in Self.displaySamples {
                let got = Self.viewerLab(stage.apply(x))
                let want = Self.viewerLab(Self.reference(x, tap: .display, amount: amount,
                                                         Self.contrast709))
                worst = max(worst, Self.deltaE2000(got, want))
            }
            XCTAssertLessThan(worst, 0.5, "amount \(amount): ΔE2000 \(worst)")
        }
    }

    /// SPEC L3. A log-domain cube at the log tap, Amount 0…200: within ΔE2000 0.5 of the
    /// reference, viewed through a fixed tone map.
    func testL3ALogDomainCubeMatchesTheReferenceAtTheLogTap() {
        let cube = Self.cube(size: 33, Self.logContrast)
        for amount in [0.0, 50, 100, 150, 200] {
            let stage = CreativeLUTStage(tap: .log, amount: amount, cube: cube)
            var worst = 0.0
            for x in Self.sceneSamples {
                let got = Self.sceneLab(stage.apply(x))
                let want = Self.sceneLab(Self.reference(x, tap: .log, amount: amount,
                                                        Self.logContrast))
                worst = max(worst, Self.deltaE2000(got, want))
            }
            XCTAssertLessThan(worst, 0.5, "amount \(amount): ΔE2000 \(worst)")
        }
    }

    // MARK: - L4 Amount

    /// SPEC L4. Amount 0…200: 100 is the file, 200 is twice the file's departure in its
    /// own encoding, the ends of the range clamp, and the response is monotone and
    /// linear in the encoding (equal steps of Amount move a code by equal steps).
    func testL4AmountIsLinearInTheCubesEncodingFrom0To200() {
        let cube = Self.cube(size: 33, Self.contrast709)
        let x = Self.d2w.apply(RGB(0.02, 0.35, 0.8))
        let e = TransferFunction.srgb.encode(Self.w2d.apply(x))
        func code(_ amount: Double) -> RGB {
            TransferFunction.srgb.encode(Self.w2d.apply(
                CreativeLUTStage(tap: .display, amount: amount, cube: cube).apply(x)))
        }
        let full = code(100) - e
        XCTAssertGreaterThan(full.maxAbsDifference(.zero), 0.05, "the probe barely moves")
        for amount in stride(from: 0.0, through: 200, by: 10) {
            let want = e + full * (amount / 100)
            XCTAssertLessThan(code(amount).maxAbsDifference(want), 1e-9, "amount \(amount)")
        }
        XCTAssertEqual(CreativeLUTStage(tap: .log, amount: 250, cube: cube).amount, 2)
        XCTAssertEqual(CreativeLUTStage(tap: .log, amount: -5, cube: cube).amount, 0)
        XCTAssertEqual(CreativeLUTStage(tap: .log, amount: .nan, cube: cube).amount, 0)
    }

    /// SPEC L4, the far end. 200% of a strong cube stays finite and non-negative: the
    /// extrapolation is floored at code 0, never a negative light.
    func testL4TwoHundredPercentNeverGoesBelowBlackOrNonFinite() {
        let crush = Self.cube(size: 17) { $0.map { pow($0, 1.8) } }
        let stage = CreativeLUTStage(tap: .display, amount: 200, cube: crush)
        for x in Self.displaySamples {
            let out = Self.w2d.apply(stage.apply(x)) - (Self.w2d.apply(x) - Self.w2d.apply(x).clamped())
            XCTAssertTrue(out.isFinite)
            XCTAssertGreaterThanOrEqual(min(out.r, out.g, out.b), -1e-12, "\(x)")
        }
    }

    // MARK: - L5 interpolation

    /// SPEC L5. The stage is TETRAHEDRAL: on a coarse cube whose corners differ, a point
    /// inside the r ≥ g ≥ b tetrahedron reads exactly the barycentric mix of its four
    /// corners, and NOT the trilinear mix of eight.
    func testL5TheInterpolantIsTetrahedral() {
        // size 2, every corner a distinct colour: tetrahedral and trilinear differ.
        let cube = Self.cube(size: 2) { v in RGB(v.r * v.g, v.g * v.b + 0.1 * v.r, v.b * v.r) }
        let p = RGB(0.7, 0.4, 0.2)
        let c000 = RGB(0, 0, 0), c100 = RGB(0, 0.1, 0), c110 = RGB(1, 0.1, 0), c111 = RGB(1, 1.1, 1)
        let tetra = c000 * (1 - p.r) + c100 * (p.r - p.g) + c110 * (p.g - p.b) + c111 * p.b
        XCTAssertLessThan(cube.sample(p).maxAbsDifference(tetra), 1e-7)
        let trilinear = RGB(p.r * p.g, p.g * p.b + 0.1 * p.r, p.b * p.r)   // bilinear corners
        XCTAssertGreaterThan(cube.sample(p).maxAbsDifference(trilinear), 0.01)
    }

    // MARK: - L6 the residual

    /// SPEC L6. What the cube cannot see comes back: a P3 red outside sRGB and an EDR
    /// highlight at 2.5× white keep their out-of-domain part through a creative cube, and
    /// the cube's change to them is the change it makes at the nearest value it can see.
    func testL6OutOfDomainValuesKeepTheirResidualThroughACreativeCube() {
        let cube = Self.cube(size: 33, Self.contrast709)
        let stage = CreativeLUTStage(tap: .display, amount: 100, cube: cube)
        for x in [RGB(0.6, 0.05, 0.02), RGB(gray: 2.5), RGB(0.02, 0.5, 0.01)] {
            let d = Self.w2d.apply(x)
            let u = d.clamped()
            let edge = Self.d2w.apply(u)
            let changeAtEdge = Self.w2d.apply(stage.apply(edge)) - u
            let change = Self.w2d.apply(stage.apply(x)) - d
            XCTAssertLessThan(change.maxAbsDifference(changeAtEdge), 1e-9, "\(x)")
        }
    }

    // MARK: - L9 robustness

    /// SPEC L9. A NaN or infinite channel comes out finite at either tap and any Amount,
    /// as it did before the residual existed.
    func testL9NonFiniteInputComesOutFinite() {
        let cube = Self.cube(size: 17, Self.contrast709)
        for tap in [LUTReference.Tap.display, .log] {
            for amount in [50.0, 100, 200] {
                let stage = CreativeLUTStage(tap: tap, amount: amount, cube: cube)
                for x in [RGB(.nan, 0.2, 0.3), RGB(.infinity, 0.2, 0.3),
                          RGB(0.1, -.infinity, 0.3), RGB(.nan, .nan, .nan)] {
                    XCTAssertTrue(stage.apply(x).isFinite, "\(tap) \(amount)% \(x)")
                }
            }
        }
    }

    /// SPEC L9. A cube whose DOMAIN is wider than [0,1] is read on its own lattice at the
    /// log tap, not clamped to the unit cube first.
    func testL9ANonUnitDomainIsReadAtTheLogTap() {
        let text = Self.cubeText(size: 9) { $0 * 2 * 0.9 }   // over [0,2]: f(e) = 0.9·e
            .replacingOccurrences(of: "LUT_3D_SIZE 9\n",
                                  with: "LUT_3D_SIZE 9\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 2 2 2\n")
        let cube = LUT3D.fromCubeFile(text)!
        let stage = CreativeLUTStage(tap: .log, amount: 100, cube: cube)
        let e = RGB(gray: 1.5)
        let out = LumenLog.encode(stage.apply(LumenLog.decode(e)))
        XCTAssertLessThan(out.maxAbsDifference(RGB(gray: 1.35)), 1e-6)
    }

    /// SPEC L9. One NaN channel at the display tap does not black out the pixel: the
    /// other two channels come through an identity cube unchanged.
    func testL9OneNaNChannelLeavesTheOtherTwo() {
        let stage = CreativeLUTStage(tap: .display, amount: 100, cube: Self.cube(size: 17) { $0 })
        let out = stage.apply(RGB(.nan, 0.18, 0.4))
        XCTAssertLessThan(out.maxAbsDifference(RGB(0, 0.18, 0.4)), 1e-9)
    }

    /// SPEC L9. The display tap honours a cube's DOMAIN: an identity cube over [0.1, 0.9]
    /// or [0, 1.5] (sRGB code) is still the identity on every value.
    func testL9TheDisplayTapHonoursTheCubesDomain() {
        for (lo, hi) in [(0.1, 0.9), (0.0, 1.5)] {
            let text = Self.cubeText(size: 9) { $0 * (hi - lo) + RGB(gray: lo) }
                .replacingOccurrences(of: "LUT_3D_SIZE 9\n", with: "LUT_3D_SIZE 9\n"
                    + "DOMAIN_MIN \(lo) \(lo) \(lo)\nDOMAIN_MAX \(hi) \(hi) \(hi)\n")
            let stage = CreativeLUTStage(tap: .display, amount: 100,
                                         cube: LUT3D.fromCubeFile(text)!)
            let worst = Self.displaySamples.map { stage.apply($0).maxAbsDifference($0) }.max()!
            XCTAssertLessThan(worst, 1e-6, "domain [\(lo), \(hi)]")
        }
    }
}

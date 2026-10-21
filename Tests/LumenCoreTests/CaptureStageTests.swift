import Foundation
import XCTest
@testable import LumenCore

/// S4 capture sharpening (`CaptureStage`, WS-17): the measurable lines of
/// docs/quality/lanes/WS-18/SPEC.md that a unit test can hold. Frames are small and
/// synthetic so the debug build runs them in seconds; the full-size numbers are in the
/// lane's REPORT, measured with `docs/quality/lanes/WS-18/measure.py`.
final class CaptureStageTests: XCTestCase {

    // MARK: Frames

    /// A 5° slanted step from `lo` to `hi`, 8× supersampled, then blurred by σ `blur`
    /// (the optics and the demosaic the stage exists to undo).
    private func slantedEdge(size: Int = 96, lo: Double = 0.05, hi: Double = 0.4,
                             blur: Double = 1.0) -> ImageBuffer {
        let t = 5.0 * Double.pi / 180
        var plane = Plane(width: size, height: size)
        for y in 0..<size {
            for x in 0..<size {
                var acc = 0.0
                for sy in 0..<8 {
                    for sx in 0..<8 {
                        let px = Double(x) + (Double(sx) + 0.5) / 8 - Double(size) / 2
                        let py = Double(y) + (Double(sy) + 0.5) / 8 - Double(size) / 2
                        acc += (px * cos(t) + py * sin(t)) > 0 ? hi : lo
                    }
                }
                plane[x, y] = acc / 64
            }
        }
        if blur > 0 { plane = SpatialOps.gaussianBlur(plane, sigma: blur) }
        return ImageBuffer(width: size, height: size) { u, v in
            RGB(gray: plane[Swift.min(Int(u * Double(size)), size - 1),
                            Swift.min(Int(v * Double(size)), size - 1)])
        }
    }

    /// Edge spread function across the slanted edge, 4× binned along the normal.
    private func esf(_ image: ImageBuffer) -> [Double] {
        let n = image.width
        let t = 5.0 * Double.pi / 180
        var sums = [Double](repeating: 0, count: 4 * 2 * 20 + 1)
        var counts = sums
        for y in (n / 5)..<(4 * n / 5) {
            for x in 0..<n {
                let u = (Double(x) + 0.5 - Double(n) / 2) * cos(t)
                    + (Double(y) + 0.5 - Double(n) / 2) * sin(t)
                guard abs(u) < 20 else { continue }
                let bin = Int(((u + 20) * 4).rounded())
                sums[bin] += RGBColorSpace.rec2020.luminance(image[x, y])
                counts[bin] += 1
            }
        }
        return zip(sums, counts).compactMap { $1 > 0 ? $0 / $1 : nil }
    }

    /// 10–90 % rise distance in pixels (smaller is sharper).
    private func rise(_ e: [Double]) -> Double {
        let lo = e.prefix(8).reduce(0, +) / 8
        let hi = e.suffix(8).reduce(0, +) / 8
        func crossing(_ level: Double) -> Double {
            guard let i = e.firstIndex(where: { $0 >= level }), i > 0 else { return 0 }
            return Double(i - 1) + (level - e[i - 1]) / Swift.max(e[i] - e[i - 1], 1e-12)
        }
        return (crossing(lo + 0.9 * (hi - lo)) - crossing(lo + 0.1 * (hi - lo))) / 4
    }

    /// (overshoot, undershoot) as fractions of the step.
    private func overshoot(_ e: [Double], lo: Double, hi: Double) -> (Double, Double) {
        ((e.max()! - hi) / (hi - lo), (lo - e.min()!) / (hi - lo))
    }

    private func stage(amount: Double? = nil, radius: Double? = nil,
                       iso: Double = 100) -> CaptureStage {
        CaptureStage(capture: CaptureSharpen(auto: true, radius: radius, amount: amount),
                     captureISO: iso)
    }

    // MARK: Identity

    func testOffIsTheExactIdentity() {
        let frame = slantedEdge()
        let off = CaptureStage(capture: CaptureSharpen(auto: false, radius: 1.2),
                               captureISO: 100)
        XCTAssertTrue(off.isIdentity)
        XCTAssertEqual(off.apply(frame).pixels, frame.pixels)
        XCTAssertEqual(stage(amount: 0).apply(frame).pixels, frame.pixels,
                       "Amount 0 must be the identity")
    }

    func testARenderedFileGetsNoCaptureStage() {
        let plan = RenderPlan(recipe: Recipe(), captureISO: nil)
        XCTAssertTrue(plan.capture.isIdentity,
                      "no capture ISO is a rendered file: it was sharpened in camera")
        let raw = RenderPlan(recipe: Recipe(), captureISO: 400)
        XCTAssertFalse(raw.capture.isIdentity, "a RAW is capture-sharpened by default")
    }

    // MARK: Spec lines

    /// SPEC C1: on a σ 1.0 blurred edge the default stage shortens the 10–90 rise by
    /// at least 20 % (MTF50 is the spec's number; the rise is its cheap proxy here).
    func testItRestoresABlurredEdge() {
        let frame = slantedEdge()
        let before = rise(esf(frame))
        let after = rise(esf(stage().apply(frame)))
        XCTAssertLessThan(after, before * 0.8, "rise \(before) → \(after)")
    }

    /// SPEC C2: no halo. Overshoot and undershoot stay under 0.5 % of the step on a
    /// blurred edge AND on an already-sharp one (the over-deconvolution case), at the
    /// top of the Amount range.
    func testItDoesNotHalo() {
        for blur in [1.0, 0.0] {
            let frame = slantedEdge(blur: blur)
            let out = stage(amount: 150).apply(frame)
            let (over, under) = overshoot(esf(out), lo: 0.05, hi: 0.4)
            XCTAssertLessThan(over, 0.005, "blur \(blur): overshoot \(over)")
            XCTAssertLessThan(under, 0.005, "blur \(blur): undershoot \(under)")
        }
    }

    /// SPEC C3: flat noise at the profile's own level is not amplified.
    func testItDoesNotSharpenNoiseOnAFlatField() {
        let profile = NoiseProfile.forISO(6400)
        let sd = profile.sigma(at: 0.18)
        var rng = SplitMix(seed: 7)
        let n = 96
        let frame = ImageBuffer(width: n, height: n) { _, _ in
            RGB(gray: 0.18 + sd * rng.gaussian())
        }
        let out = stage(iso: 6400).apply(frame)
        func std(_ b: ImageBuffer) -> Double {
            let p = b.luminancePlane(space: .rec2020)
            let m = p.mean
            return (p.values.reduce(0) { $0 + (Double($1) - m) * (Double($1) - m) }
                / Double(p.values.count)).squareRoot()
        }
        XCTAssertLessThan(std(out) / std(frame), 1.01)
    }

    /// SPEC C4: texture keeps its gain — the edge clamp must not flatten ridges. A
    /// blurred 4 px-period grating gains ≥ 20 % modulation.
    func testItRestoresFineTexture() {
        let n = 64
        var plane = Plane(width: n, height: n) { u, _ in
            0.18 * (1 + 0.5 * cos(2 * Double.pi * u * Double(n) / 4))
        }
        plane = SpatialOps.gaussianBlur(plane, sigma: 1.0)
        let frame = ImageBuffer(width: n, height: n) { u, v in
            RGB(gray: plane[Swift.min(Int(u * Double(n)), n - 1),
                            Swift.min(Int(v * Double(n)), n - 1)])
        }
        func modulation(_ b: ImageBuffer) -> Double {
            let row = (8..<(n - 8)).map { b[$0, n / 2].g }
            return (row.max()! - row.min()!) / (row.max()! + row.min()!)
        }
        XCTAssertGreaterThan(modulation(stage().apply(frame)), modulation(frame) * 1.2)
    }

    /// SPEC C5: Amount and Radius are live and monotone.
    func testAmountAndRadiusAreLiveAndMonotone() {
        let frame = slantedEdge()
        let amounts = [25.0, 50, 100, 150].map { rise(esf(stage(amount: $0).apply(frame))) }
        for (a, b) in zip(amounts, amounts.dropFirst()) {
            XCTAssertLessThan(b, a, "Amount must sharpen more as it rises: \(amounts)")
        }
        let radii = [0.5, 0.8, 1.2].map { rise(esf(stage(radius: $0).apply(frame))) }
        for (a, b) in zip(radii, radii.dropFirst()) {
            XCTAssertLessThan(b, a, "a wider PSF deconvolves more: \(radii)")
        }
    }

    /// The colour is untouched: recombination is a luminance ratio.
    func testItCannotShiftHue() {
        let base = slantedEdge()
        let tinted = base.map { RGB($0.r * 1.3, $0.g, $0.b * 0.6) }
        let out = stage(amount: 150).apply(tinted)
        for y in stride(from: 0, to: out.height, by: 7) {
            for x in stride(from: 0, to: out.width, by: 7) {
                let i = tinted[x, y]
                let o = out[x, y]
                XCTAssertEqual(o.r / o.g, i.r / i.g, accuracy: 1e-5)
                XCTAssertEqual(o.b / o.g, i.b / i.g, accuracy: 1e-5)
            }
        }
    }

    // MARK: Scale

    func testScaleShrinksTheBlurAndTheNoise() {
        let s = stage(radius: 1.0, iso: 1600)
        let half = s.scaled(decodeScale: 0.5)
        XCTAssertEqual(half.sigma, 0.5, accuracy: 1e-12)
        XCTAssertEqual(half.profile.a, s.profile.a * 0.25, accuracy: 1e-15)
        XCTAssertFalse(half.isIdentity)
        XCTAssertTrue(s.scaled(decodeScale: 0.25).isIdentity,
                      "at a quarter scale the downsample removed more blur than S4 can")
        XCTAssertEqual(s.scaled(decodeScale: 1), s)
    }

    func testTheTapsAreANormalizedGaussian() {
        for sigma in [0.3, 0.8, 2.0] {
            let w = CaptureStage.gaussianTaps(sigma: sigma)
            XCTAssertEqual(w.count, CaptureStage.tapRadius + 1)
            let total = Double(w[0]) + 2 * w.dropFirst().reduce(0) { $0 + Double($1) }
            XCTAssertEqual(total, 1, accuracy: 1e-6)
        }
    }

    func testTheDeadRadiusFieldIsLive() {
        XCTAssertEqual(stage(radius: 1.3).sigma, 1.3, accuracy: 1e-12)
        XCTAssertEqual(stage().sigma, CaptureStage.defaultRadius, accuracy: 1e-12)
        XCTAssertEqual(stage(radius: 9).sigma, SpatialOps.maxPSFSigma, accuracy: 1e-12)
        XCTAssertEqual(stage(radius: .nan).sigma, CaptureStage.defaultRadius,
                       accuracy: 1e-12)
    }
}

/// Deterministic Gaussian noise for the flat-field test.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u1 = Swift.max(uniform(), 1e-12)
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * uniform())
    }
}

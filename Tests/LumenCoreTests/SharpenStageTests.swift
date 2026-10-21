import Foundation
import XCTest
@testable import LumenCore

/// S12 creative sharpening (`SharpenStage`, WS-18): the unit-test twins of the S lines
/// in docs/quality/lanes/WS-18/SPEC.md. Full-size numbers come from
/// `docs/quality/lanes/WS-18/measure.py`.
final class SharpenStageTests: XCTestCase {

    // MARK: Frames

    /// A 5° slanted step `lo` → `hi`, 8× supersampled, blurred by σ `blur`.
    private func edge(size: Int = 96, lo: Double = 0.09, hi: Double = 0.36,
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
        return buffer(plane)
    }

    private func buffer(_ p: Plane) -> ImageBuffer {
        ImageBuffer(width: p.width, height: p.height) { u, v in
            RGB(gray: p[Swift.min(Int(u * Double(p.width)), p.width - 1),
                        Swift.min(Int(v * Double(p.height)), p.height - 1)])
        }
    }

    private func esf(_ image: ImageBuffer) -> [Double] {
        let n = image.width
        let t = 5.0 * Double.pi / 180
        var sums = [Double](repeating: 0, count: 161)
        var counts = sums
        for y in (n / 5)..<(4 * n / 5) {
            for x in 0..<n {
                let u = (Double(x) + 0.5 - Double(n) / 2) * cos(t)
                    + (Double(y) + 0.5 - Double(n) / 2) * sin(t)
                guard abs(u) < 20 else { continue }
                let bin = Int(((u + 20) * 4).rounded())
                sums[bin] += image[x, y].g
                counts[bin] += 1
            }
        }
        return zip(sums, counts).compactMap { $1 > 0 ? $0 / $1 : nil }
    }

    private func rise(_ e: [Double]) -> Double {
        let lo = e.prefix(8).reduce(0, +) / 8
        let hi = e.suffix(8).reduce(0, +) / 8
        func crossing(_ level: Double) -> Double {
            guard let i = e.firstIndex(where: { $0 >= level }), i > 0 else { return 0 }
            return Double(i - 1) + (level - e[i - 1]) / Swift.max(e[i] - e[i - 1], 1e-12)
        }
        return (crossing(lo + 0.9 * (hi - lo)) - crossing(lo + 0.1 * (hi - lo))) / 4
    }

    /// (bright overshoot, dark undershoot) as fractions of the step.
    private func halo(_ image: ImageBuffer, lo: Double = 0.09,
                      hi: Double = 0.36) -> (Double, Double) {
        let e = esf(image)
        return ((e.max()! - hi) / (hi - lo), (lo - e.min()!) / (hi - lo))
    }

    private func noise(_ n: Int, sigma: Double, seed: UInt64 = 11) -> ImageBuffer {
        var state = seed
        func uniform() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        return ImageBuffer(width: n, height: n) { _, _ in
            let g = (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
            return RGB(gray: 0.18 + sigma * g)
        }
    }

    private func std(_ b: ImageBuffer) -> Double {
        let p = b.luminancePlane(space: .rec2020)
        let m = p.mean
        return (p.values.reduce(0) { $0 + (Double($1) - m) * (Double($1) - m) }
            / Double(p.values.count)).squareRoot()
    }

    private func sharpen(_ f: ImageBuffer, amount: Double = 70, radius: Double = 1,
                         detail: Double = 25, masking: Double = 0,
                         halo: Double = 0) -> ImageBuffer {
        DetailEngine.applySharpen(f, params: ManualSharpen(
            amount: amount, radius: radius, detail: detail, masking: masking,
            haloSuppression: halo))
    }

    // MARK: S1 identity

    func testAmountZeroIsTheExactIdentity() {
        let f = edge()
        XCTAssertEqual(sharpen(f, amount: 0).pixels, f.pixels)
        XCTAssertTrue(SharpenStage(ManualSharpen(), decodeScale: 1).isIdentity,
                      "the default recipe has no creative sharpening")
    }

    // MARK: S2 it sharpens, monotonically in Amount

    func testItSharpensABlurredEdgeMonotonicallyInAmount() {
        let f = edge()
        let base = rise(esf(f))
        let rises = [40.0, 70, 100, 150].map { rise(esf(sharpen(f, amount: $0))) }
        XCTAssertLessThan(rises[1], base * 0.9, "Amount 70: rise \(base) → \(rises[1])")
        for (a, b) in zip(rises, rises.dropFirst()) {
            XCTAssertLessThan(b, a, "rise must fall as Amount rises: \(rises)")
        }
    }

    // MARK: S3 no halo at normal settings

    func testNoHaloAtNormalSettings() {
        let (bright, dark) = halo(sharpen(edge()))
        XCTAssertLessThan(bright, 0.015, "bright rim \(bright) at 70/1/25/0")
        XCTAssertLessThan(dark, 0.015, "dark rim \(dark) at 70/1/25/0")
    }

    // MARK: S4 Detail is halo suppression, monotone

    func testDetailZeroIsHaloFreeAndDetailIsMonotone() {
        let f = edge()
        let d0 = halo(sharpen(f, amount: 150, detail: 0))
        XCTAssertLessThan(d0.0, 0.005)
        XCTAssertLessThan(d0.1, 0.005)
        let overs = [0.0, 50, 100].map { d -> Double in
            let h = halo(sharpen(f, amount: 150, detail: d))
            return h.0 + h.1
        }
        XCTAssertLessThan(overs[0], overs[1])
        XCTAssertLessThan(overs[1], overs[2])
    }

    // MARK: S5 Halo Damping damps the bright rim, never the dark side

    func testHaloDampingTakesTheBrightRimAndLeavesTheDarkSide() {
        let f = edge()
        let free = halo(sharpen(f, amount: 150, detail: 100))
        let damped = halo(sharpen(f, amount: 150, detail: 100, halo: 100))
        XCTAssertGreaterThan(free.0, 0.01, "the fixture has no bright rim to damp")
        XCTAssertLessThan(damped.0, free.0 * 0.25, "rim \(free.0) → \(damped.0)")
        XCTAssertEqual(damped.1, free.1, accuracy: 1e-9, "the dark side moved")
    }

    // MARK: S6 Masking

    func testMaskingFiftyLeavesFlatNoiseAloneAndKeepsEdges() {
        let flat = noise(96, sigma: 0.012)
        XCTAssertGreaterThan(std(sharpen(flat, masking: 0)) / std(flat), 1.2,
                             "unmasked sharpening should raise noise — fixture check")
        XCTAssertLessThan(std(sharpen(flat, masking: 50)) / std(flat), 1.02)

        let f = edge()
        let open = rise(esf(f)) - rise(esf(sharpen(f, masking: 0)))
        let masked = rise(esf(f)) - rise(esf(sharpen(f, masking: 50)))
        XCTAssertGreaterThan(masked, open * 0.8, "Masking 50 gutted a 2 EV edge")
    }

    func testMaskingZeroIsExactlyUnmasked() {
        let mask = SharpenStage.maskPlane(edgeMeasure: Plane(width: 8, height: 8), masking: 0)
        XCTAssertTrue(mask.values.allSatisfy { $0 == 1 })
    }

    /// The ⌥-drag view: a flat noisy field reads black at 50, an edge reads white.
    func testTheMaskPreviewShowsEdgesWhiteAndFlatBlack() {
        let n = 64
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        var state: UInt64 = 3
        for y in 0..<n {
            for x in 0..<n {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                let jitter = Int(state >> 61) - 4   // ±4 codes of noise
                let v = (x < n / 2 ? 90 : 170) + jitter
                for c in 0..<3 { bytes[(y * n + x) * 4 + c] = UInt8(v) }
            }
        }
        let mask = SharpenStage.maskPreview(sRGB: bytes, width: n, height: n, masking: 0.5)
        XCTAssertEqual(mask.count, n * n)
        XCTAssertEqual(mask[(n / 2) * n + n / 2], 255, "the edge is not white")
        XCTAssertLessThan(mask[(n / 2) * n + 8], 32, "flat noise is not black")
    }

    // MARK: S7 no brightening

    /// The stage ran in log2 and applied 2^Δ, whose mean is above 1: +0.094 EV over
    /// the native A7 IV frame at Amount 100 (measured, base build). In the cube-root
    /// domain the same convexity is a third as strong: +0.013 EV on that frame (REPORT).
    /// Any perceptual domain keeps a residue on pure noise — E[(p+δ)³] grows with the
    /// variance of δ — so this fixture is the worst case: a flat field at 17 % noise,
    /// unmasked, Amount 100, where the gain is smallest: +0.030 EV against the old
    /// stage's +0.048 (`log2Reference`). On real frames most of the old brightening was
    /// halo, which the bound removes; that is where the 7× comes from.
    func testItDoesNotBrightenThePicture() {
        let f = noise(96, sigma: 0.03)
        let out = sharpen(f, amount: 100)
        let ev = log2(out.luminancePlane(space: .rec2020).mean
                      / f.luminancePlane(space: .rec2020).mean)
        XCTAssertLessThan(abs(ev), 0.035, "mean moved \(ev) EV")
        XCTAssertLessThan(abs(ev), log2Reference(f) * 0.75,
                          "no better than the old log2 stage's brightening")
    }

    /// The old stage's arithmetic on the same field, for the comparison above: an
    /// unsharp mask on log2 luminance at σ 1, applied as 2^(amount·Δ).
    private func log2Reference(_ f: ImageBuffer) -> Double {
        let l = f.luminancePlane(space: .rec2020).map { log2(Swift.max($0, 1e-6)) }
        let b = SpatialOps.gaussianBlur(l, sigma: 1.0)
        var sum = 0.0
        var base = 0.0
        for i in 0..<l.values.count {
            let y = exp2(Double(l.values[i]))
            base += y
            sum += y * exp2(Num.clamp(Double(l.values[i] - b.values[i]), -2, 2))
        }
        return log2(sum / base)
    }

    // MARK: S8 no hue shift

    func testItCannotShiftHue() {
        let tinted = edge().map { RGB($0.r * 1.4, $0.g, $0.b * 0.5) }
        let out = sharpen(tinted, amount: 150, detail: 100)
        for y in stride(from: 0, to: out.height, by: 5) {
            for x in stride(from: 0, to: out.width, by: 5) {
                XCTAssertEqual(out[x, y].r / out[x, y].g, tinted[x, y].r / tinted[x, y].g,
                               accuracy: 1e-5)
            }
        }
    }
}

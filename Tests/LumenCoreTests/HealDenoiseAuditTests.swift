// HealDenoiseAuditTests.swift
// Measured properties of S5 heal and S3 classical denoise on synthetic frames with a
// known truth: residual noise against signal level, bias, monotonicity, ringing,
// identity at zero, and the heal seam at the rim, at the frame edge and off it.

import XCTest
@testable import LumenCore

final class HealDenoiseAuditTests: XCTestCase {

    // MARK: - Deterministic noise

    private static func mix(_ v: UInt64) -> UInt64 {
        var z = v &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    private struct Rng {
        var state: UInt64
        mutating func uniform() -> Double {
            state = HealDenoiseAuditTests.mix(state)
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func normal() -> Double {
            let u1 = Swift.max(uniform(), 1e-300), u2 = uniform()
            return (-2 * Foundation.log(u1)).squareRoot() * cos(2 * Double.pi * u2)
        }
        mutating func poisson(_ lambda: Double) -> Double {
            if lambda > 60 { return Swift.max((lambda + lambda.squareRoot() * normal()).rounded(), 0) }
            let limit = exp(-lambda)
            var k = 0.0, p = 1.0
            repeat { k += 1; p *= uniform() } while p > limit
            return k - 1
        }
    }

    /// Photon-and-read noise exactly matching `var = a·x + b`: `a·Poisson(x/a) + N(0, b)`.
    private func poissonGaussian(_ x: Double, _ profile: NoiseProfile, _ rng: inout Rng) -> Double {
        profile.a * rng.poisson(x / profile.a) + profile.b.squareRoot() * rng.normal()
    }

    private func flatField(level: Double, profile: NoiseProfile, size: Int = 96,
                           seed: UInt64) -> ImageBuffer {
        var rng = Rng(state: seed)
        var out = ImageBuffer(width: size, height: size)
        for y in 0..<size {
            for x in 0..<size {
                out[x, y] = RGB(poissonGaussian(level, profile, &rng),
                                poissonGaussian(level, profile, &rng),
                                poissonGaussian(level, profile, &rng))
            }
        }
        return out
    }

    private func stats(_ values: [Double]) -> (mean: Double, sigma: Double) {
        let mean = values.reduce(0, +) / Double(values.count)
        let v = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return (mean, v.squareRoot())
    }

    private func greenStats(_ image: ImageBuffer, inset: Int = 16) -> (mean: Double, sigma: Double) {
        var values: [Double] = []
        for y in inset..<(image.height - inset) {
            for x in inset..<(image.width - inset) { values.append(image[x, y].g) }
        }
        return stats(values)
    }

    // MARK: - Denoise

    func testDenoiseAtZeroIsBitIdentityEvenWithSubSlidersSet() {
        let profile = NoiseProfile.forISO(12800)
        var frame = flatField(level: 0.05, profile: profile, size: 48, seed: 7)
        frame[3, 3] = RGB(-0.02, 1.5, 40)
        let engine = ClassicalDenoise(
            ClassicNR(luma: 0, chroma: 0, hotPixels: 0, lumaDetail: 90, lumaContrast: 80,
                      colorDetail: 10, colorSmoothness: 100),
            profile: profile)
        XCTAssertTrue(engine.isIdentity)
        let out = engine.apply(frame)
        XCTAssertEqual(out.pixels, frame.pixels, "strength 0 moved a pixel")
    }

    func testTheForwardTransformStabilisesPoissonGaussianNoise() {
        let profile = NoiseProfile.forISO(6400)
        var report: [String] = []
        for level in [0.001, 0.004, 0.02, 0.1, 0.4, 1.0] {
            var rng = Rng(state: 0xA11CE &+ UInt64(level * 1e6))
            var values: [Double] = []
            for _ in 0..<20_000 {
                values.append(VST.forward(poissonGaussian(level, profile, &rng), profile: profile))
            }
            let s = stats(values).sigma
            report.append(String(format: "%.3f→%.3f", level, s))
            XCTAssertEqual(s, 1, accuracy: 0.12, "VST σ at signal \(level) is \(s)")
        }
        print("VST sigma by level:", report.joined(separator: " "))
    }

    /// After denoise, the fraction of noise kept and the brightness shift should not
    /// depend on how bright the patch is — that is what stabilising the variance buys.
    func testResidualNoiseAndBiasDoNotDependOnSignalLevel() {
        let profile = NoiseProfile.forISO(6400)
        let engine = ClassicalDenoise(ClassicNR(luma: 60, chroma: 60, hotPixels: 0),
                                      profile: profile)
        var kept: [Double] = []
        var report: [String] = []
        for (i, level) in [0.003, 0.01, 0.03, 0.1, 0.3, 0.8].enumerated() {
            let frame = flatField(level: level, profile: profile, seed: 100 + UInt64(i))
            let before = greenStats(frame)
            let after = greenStats(engine.apply(frame))
            let ratio = after.sigma / before.sigma
            let bias = (after.mean - before.mean) / before.sigma
            kept.append(ratio)
            report.append(String(format: "x=%.3f kept=%.3f bias=%+.3fσ", level, ratio, bias))
            XCTAssertLessThan(abs(bias), 0.25, "denoise shifted a flat patch at \(level) "
                              + "by \(bias) σ")
        }
        print("residual by level:", report.joined(separator: " | "))
        let spread = kept.max()! / kept.min()!
        XCTAssertLessThan(spread, 1.6, "kept noise varies \(spread)× across signal level")
    }

    /// Deep shadow at ISO 102400, every master setting: the patch keeps its brightness.
    func testDeepShadowsKeepTheirLevelAtEverySetting() {
        let profile = NoiseProfile.forISO(102_400)
        var report: [String] = []
        for (i, level) in [0.0, 0.0005, 0.002, 0.01].enumerated() {
            let frame = flatField(level: level, profile: profile, seed: 300 + UInt64(i))
            let before = greenStats(frame)
            for (l, c) in [(1.0, 0.0), (0, 1), (10, 0), (0, 10), (25, 25), (60, 60), (100, 100)] {
                let after = greenStats(ClassicalDenoise(ClassicNR(luma: l, chroma: c, hotPixels: 0),
                                                        profile: profile).apply(frame))
                let bias = (after.mean - before.mean) / profile.sigma(at: level)
                report.append(String(format: "x=%.4f L%.0f/C%.0f:%+.3f", level, l, c, bias))
                XCTAssertLessThan(abs(bias), 0.25, "x=\(level) L\(l) C\(c) shifted by \(bias) σ")
            }
        }
        print("shadow bias:", report.joined(separator: " "))
    }

    func testMoreLuminanceNeverKeepsMoreNoise() {
        let profile = NoiseProfile.forISO(6400)
        let frame = flatField(level: 0.08, profile: profile, seed: 42)
        var previous = Double.infinity
        var report: [String] = []
        for slider in stride(from: 0.0, through: 100.0, by: 10.0) {
            let engine = ClassicalDenoise(ClassicNR(luma: slider, chroma: 0, hotPixels: 0),
                                          profile: profile)
            let s = greenStats(engine.apply(frame)).sigma
            report.append(String(format: "%.0f:%.5f", slider, s))
            XCTAssertLessThanOrEqual(s, previous * 1.0001, "Luminance \(slider) kept more noise")
            previous = s
        }
        for k in stride(from: 0.0, through: 99.0, by: 1.0) {
            XCTAssertLessThanOrEqual(ClassicalDenoise.lumaK(k), ClassicalDenoise.lumaK(k + 1))
            XCTAssertLessThanOrEqual(ClassicalDenoise.chromaK(k), ClassicalDenoise.chromaK(k + 1))
        }
        print("luma sweep:", report.joined(separator: " "))
    }

    /// A clean grey step at full strength: no overshoot past either plateau and no
    /// colour appearing on a neutral edge.
    func testAGreyStepNeitherRingsNorPicksUpColour() {
        let profile = NoiseProfile.forISO(6400)
        var frame = ImageBuffer(width: 96, height: 64)
        var rng = Rng(state: 9)
        for y in 0..<64 {
            for x in 0..<96 {
                let level = x < 48 ? 0.02 : 0.5
                let g = poissonGaussian(level, profile, &rng)
                frame[x, y] = RGB(g, g, g)  // luma-only noise: any chroma out is made here
            }
        }
        let engine = ClassicalDenoise(ClassicNR(luma: 100, chroma: 100, hotPixels: 0,
                                                colorSmoothness: 100),
                                      profile: profile)
        let out = engine.apply(frame)
        var lowSide: [Double] = [], highSide: [Double] = []
        var chroma = 0.0
        for y in 8..<56 {
            for x in 30..<66 {
                let c = out[x, y]
                let m = (c.r + c.g + c.b) / 3
                chroma = Swift.max(chroma, Swift.max(abs(c.r - m), Swift.max(abs(c.g - m), abs(c.b - m))))
            }
            lowSide.append(out[44, y].g); highSide.append(out[51, y].g)
        }
        let lowMean = stats(lowSide).mean, highMean = stats(highSide).mean
        print(String(format: "step: near-low %.4f near-high %.4f maxChroma %.5f", lowMean,
                     highMean, chroma))
        XCTAssertEqual(lowMean, 0.02, accuracy: 0.02 * 0.5, "undershoot/overshoot on dark side")
        XCTAssertEqual(highMean, 0.5, accuracy: 0.5 * 0.05, "overshoot on bright side")
        XCTAssertLessThan(chroma, 0.01, "colour appeared on a neutral edge")
    }

    /// Low-frequency chroma (blotches: the 8×8 block means of U and V) on a flat grey
    /// field must go down, never up, at every Colour setting.
    func testColourNeverRaisesBlotches() {
        let profile = NoiseProfile.forISO(12800)
        let flat = flatField(level: 0.1, profile: profile, size: 128, seed: 5)
        func blotch(_ img: ImageBuffer) -> Double {
            let rot = ClassicalDenoise.toY0U0V0
            var acc = 0.0, n = 0.0
            for by in stride(from: 16, to: 112, by: 8) { for bx in stride(from: 16, to: 112, by: 8) {
                var m = RGB.zero
                for y in by..<(by + 8) { for x in bx..<(bx + 8) { m = m + rot.apply(img[x, y]) } }
                m = m / 64
                acc += m.g * m.g + m.b * m.b; n += 1 } }
            return (acc / n).squareRoot()
        }
        let before = blotch(flat)
        var report = [String(format: "0:%.6f", before)]
        for c in [10.0, 25, 50, 75, 100] {
            for smooth in [0.0, 50, 100] {
                let out = ClassicalDenoise(ClassicNR(luma: 0, chroma: c, hotPixels: 0,
                                                     colorSmoothness: smooth),
                                           profile: profile).apply(flat)
                let b = blotch(out)
                report.append(String(format: "c%.0f/s%.0f:%.6f", c, smooth, b))
                XCTAssertLessThan(b, before, "Colour \(c) smoothness \(smooth) raised blotches")
            }
        }
        print("blotch:", report.joined(separator: " "))
    }

    // MARK: - Heal

    /// A slope with fine texture; the clean truth for any heal.
    private func texturedSlope(width: Int = 160, height: Int = 120) -> ImageBuffer {
        var out = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let base = 0.1 + 0.3 * Double(x) / Double(width) + 0.1 * Double(y) / Double(height)
                let t = 0.01 * sin(Double(x) * 1.3) * cos(Double(y) * 1.1)
                out[x, y] = RGB(base + t, base * 0.9 + t, base * 0.7 + t)
            }
        }
        return out
    }

    private func withBlemish(_ image: ImageBuffer, cx: Double, cy: Double, r: Double) -> ImageBuffer {
        var out = image
        for y in 0..<image.height {
            for x in 0..<image.width where hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy) < r {
                out[x, y] = RGB(0.9, 0.2, 0.2)
            }
        }
        return out
    }

    /// RMS error to the truth over the in-frame pixels of the disc.
    private func discError(_ out: ImageBuffer, _ truth: ImageBuffer, cx: Double, cy: Double,
                           r: Double, from rho0: Double = 0, to rho1: Double = 1) -> Double {
        var acc = 0.0, n = 0.0
        for y in 0..<out.height {
            for x in 0..<out.width {
                let rho = hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy) / r
                guard rho >= rho0, rho < rho1 else { continue }
                let d = out[x, y] - truth[x, y]
                acc += (d.r * d.r + d.g * d.g + d.b * d.b) / 3
                n += 1
            }
        }
        return n > 0 ? (acc / n).squareRoot() : 0
    }

    /// The seam: error in the outer band of the disc, where the patch meets the
    /// destination, relative to the texture's own amplitude (0.01).
    func testHealMeetsTheDestinationAtTheRim() {
        let truth = texturedSlope()
        let w = 160.0, h = 120.0
        let cx = 70.0, cy = 60.0, r = 12.0
        let blemished = withBlemish(truth, cx: cx, cy: cy, r: r * 0.6)
        let spot = HealSpot(mode: .heal, x: cx / w, y: cy / h, sourceX: (cx + 40) / w,
                            sourceY: cy / h, radius: r / w, feather: 30, opacity: 100)
        let out = SpotRetouch.apply(blemished, spots: [spot])
        let seam = discError(out, truth, cx: cx, cy: cy, r: r, from: 0.8, to: 1.0)
        let core = discError(out, truth, cx: cx, cy: cy, r: r, from: 0, to: 0.8)
        print(String(format: "heal interior: seam %.5f core %.5f", seam, core))
        XCTAssertLessThan(seam, 0.012, "the healed patch does not meet its surroundings")
        XCTAssertLessThan(core, 0.02, "the healed patch is not re-lit to the slope")
    }

    /// A source dragged past the frame's left edge. Before: the render pasted the
    /// frame's edge column, stretched, into 10 columns of the disc.
    func testASourceDraggedOffTheFrameStopsAtTheEdge() {
        let truth = texturedSlope()
        let w = 160.0, h = 120.0
        let cx = 60.0, cy = 60.0, r = 12.0
        let spot = HealSpot(mode: .clone, x: cx / w, y: cy / h, sourceX: 30 / w,
                            sourceY: cy / h, radius: r / w, feather: 0, opacity: 100)
        let moved = SpotHandles.dragged(spot, part: .source, dx: -28 / w, dy: -200 / h,
                                        sourceWidth: 160, sourceHeight: 120)
        XCTAssertEqual(moved.sourceX * w, r, accuracy: 1e-9)
        XCTAssertEqual(moved.sourceY * h, r, accuracy: 1e-9)
        XCTAssertEqual(SpotHandles.dragged(spot, part: .destination, dx: -0.5, dy: 0,
                                           sourceWidth: 160, sourceHeight: 120).x,
                       spot.x - 0.5, "the destination may leave the frame")
        let out = SpotRetouch.apply(truth, spots: [moved])
        var stretched = 0
        for y in Int(cy - r)..<Int(cy + r) {
            var run = 0
            for x in Int(cx - r)..<Int(cx + r) where out[x, y] == out[x + 1, y] { run += 1 }
            stretched = Swift.max(stretched, run)
        }
        print("clone after drag off-frame: longest run of repeated pixels", stretched)
        XCTAssertEqual(stretched, 0, "the edge column is pasted stretched")
    }

    /// A spot too large for any search candidate keeps its provisional source, so that
    /// is what renders. Before: radius 0.25 at the centre put the source disc at
    /// x = -0.125 (more than half off the frame) and 0.2 at x = 0.0 (half off).
    func testTheProvisionalSourceStaysInsideTheFrameForALargeSpot() {
        var frame = ImageBuffer(width: 300, height: 200)
        for y in 0..<200 { for x in 0..<300 { frame[x, y] = RGB(gray: 0.1 + 0.001 * Double(x)) } }
        let big = HealSpot(mode: .clone, x: 0.5, y: 0.5, sourceX: 0.5, sourceY: 0.5,
                           radius: 0.2, feather: 0, opacity: 100)
        XCTAssertNil(SpotSourceSearch.autoSource(for: big, in: frame),
                     "the search found a source, so the provisional one never renders")
        for (x, y, radius) in [(0.5, 0.5, 0.25), (0.5, 0.5, 0.2), (0.5, 0.5, 0.15),
                               (0.3, 0.4, 0.15), (0.7, 0.6, 0.15), (0.05, 0.9, 0.1)] {
            for (w, h) in [(3000, 2000), (2000, 3000)] {
                let spot = HealSpot(mode: .heal, x: x, y: y, sourceX: x, sourceY: y,
                                    radius: radius, feather: 50, opacity: 100)
                let p = SpotHandles.provisionalSource(for: spot, sourceWidth: w, sourceHeight: h)
                let edge = Double(Swift.max(w, h))
                let rx = radius * edge / Double(w), ry = radius * edge / Double(h)
                XCTAssertTrue(p.x - rx >= -1e-9 && p.x + rx <= 1 + 1e-9
                              && p.y - ry >= -1e-9 && p.y + ry <= 1 + 1e-9,
                              "\(w)x\(h) spot (\(x), \(y)) r=\(radius): source \(p) leaves the frame")
                XCTAssertGreaterThan(hypot((p.x - x) * Double(w), (p.y - y) * Double(h)), 0)
            }
        }
        // The render with it: no column of the disc is the frame's edge column stretched.
        var placed = big
        let p = SpotHandles.provisionalSource(for: big, sourceWidth: 300, sourceHeight: 200)
        placed.sourceX = p.x
        placed.sourceY = p.y
        let out = SpotRetouch.apply(frame, spots: [placed])
        var stretched = 0
        for x in 90..<210 where abs(out[x, 100].g - frame[0, 100].g) < 1e-12
            || abs(out[x, 100].g - frame[299, 100].g) < 1e-12 { stretched += 1 }
        print("provisional render: stretched columns", stretched)
        XCTAssertLessThanOrEqual(stretched, 1, "one column maps to the edge column; more is a stretch")
    }

    func testTheAutoSourceNearACornerIsInsideTheFrameAndOffTheSpot() {
        let truth = texturedSlope()
        let spot = HealSpot(mode: .heal, x: 6 / 160, y: 6 / 120, sourceX: 0, sourceY: 0,
                            radius: 8 / 160, feather: 50, opacity: 100)
        guard let s = SpotSourceSearch.autoSource(for: spot, in: truth) else {
            return XCTFail("no source near a corner")
        }
        let sx = s.x * 160, sy = s.y * 120
        XCTAssertGreaterThanOrEqual(sx - 8, 0); XCTAssertGreaterThanOrEqual(sy - 8, 0)
        XCTAssertGreaterThanOrEqual(hypot(sx - 6, sy - 6), 16)
    }
}


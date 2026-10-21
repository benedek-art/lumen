import XCTest
@testable import LumenCore

/// WS-28: lateral CA, Defringe, the Sony embedded vignetting record. Each test is a
/// measurable line of docs/quality/lanes/WS-28/SPEC.md.
final class LensStageTests: XCTestCase {

    // MARK: Synthetic optics

    /// A soft checker scene (edges in every direction, 2-3 px wide), seen through a lens
    /// that magnifies red by `mr(r)` and blue by `mb(r)` relative to green.
    static func scene(width: Int = 1800, height: Int = 1200, period: Double = 37,
                      mr: @escaping (Double) -> Double = { _ in 1 },
                      mb: @escaping (Double) -> Double = { _ in 1 },
                      tint: RGB = RGB(1, 1, 1),
                      dark: RGB? = nil, bright: RGB? = nil) -> ImageBuffer {
        let cx = Double(width) / 2, cy = Double(height) / 2
        let norm = 0.5 * (Double(width * width + height * height)).squareRoot()
        func t(_ x: Double, _ y: Double) -> Double {
            let s = sin(.pi * x / period) * sin(.pi * y / period)
            let t = Swift.max(0, Swift.min(1, 0.5 + 2.5 * s))
            return t * t * (3 - 2 * t)
        }
        // Each channel blends its own dark and bright surface colour: a two-colour edge.
        let lo = dark ?? RGB(gray: 0.03), hi = bright ?? RGB(gray: 0.53)
        func f(_ x: Double, _ y: Double, _ c: Int) -> Double {
            lo[c] + (hi[c] - lo[c]) * t(x, y)
        }
        var img = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let dx = px - cx, dy = py - cy
                let r = (dx * dx + dy * dy).squareRoot() / norm
                let sr = mr(r), sb = mb(r)
                img[x, y] = RGB(tint.r * f(cx + dx / sr, cy + dy / sr, 0),
                                tint.g * f(px, py, 1),
                                tint.b * f(cx + dx / sb, cy + dy / sb, 2))
            }
        }
        return img
    }

    // SPEC 2.1: a known constant magnification is recovered.
    func testEstimatorRecoversConstantMagnification() throws {
        let img = Self.scene(mr: { _ in 1.0006 }, mb: { _ in 0.99945 })
        let model = try XCTUnwrap(LateralCAEstimator.estimate(img))
        // Model scale s(r) = 1 + k0 + k2 r² must equal the magnification across r.
        for r in [0.3, 0.6, 0.9] {
            XCTAssertEqual(model.red.scale(r2: r * r), 1.0006, accuracy: 6e-5, "red at r=\(r)")
            XCTAssertEqual(model.blue.scale(r2: r * r), 0.99945, accuracy: 6e-5, "blue at r=\(r)")
        }
    }

    // SPEC 2.1: a radius-dependent magnification is recovered.
    func testEstimatorRecoversCubicMagnification() throws {
        let img = Self.scene(mr: { r in 1 + 0.0009 * r * r }, mb: { r in 1 - 0.0003 - 0.0004 * r * r })
        let model = try XCTUnwrap(LateralCAEstimator.estimate(img))
        for r in [0.3, 0.6, 0.9] {
            XCTAssertEqual(model.red.scale(r2: r * r), 1 + 0.0009 * r * r, accuracy: 7e-5)
            XCTAssertEqual(model.blue.scale(r2: r * r), 1 - 0.0003 - 0.0004 * r * r, accuracy: 7e-5)
        }
    }

    // SPEC 2.1b: edges between two differently coloured surfaces (dark brown branch,
    // blue sky) — the case a gain-locked fit reads as a shift.
    func testEstimatorIsNotFooledBySurfaceColour() throws {
        let img = Self.scene(mr: { _ in 1.0006 }, mb: { _ in 0.99945 },
                             dark: RGB(0.05, 0.03, 0.015), bright: RGB(0.45, 0.6, 0.95))
        let model = try XCTUnwrap(LateralCAEstimator.estimate(img))
        for r in [0.3, 0.6, 0.9] {
            XCTAssertEqual(model.red.scale(r2: r * r), 1.0006, accuracy: 6e-5, "red at r=\(r)")
            XCTAssertEqual(model.blue.scale(r2: r * r), 0.99945, accuracy: 6e-5, "blue at r=\(r)")
        }
        // And with no CA at all, that scene yields no model.
        XCTAssertNil(LateralCAEstimator.estimate(
            Self.scene(dark: RGB(0.05, 0.03, 0.015), bright: RGB(0.45, 0.6, 0.95))))
    }

    // SPEC 2.2: after correction the systematic misregistration is under 0.05 px
    // everywhere, and the corrected frame no longer yields a significant model.
    func testCorrectionLeavesUnderAFifthOfATenthOfAPixel() throws {
        let img = Self.scene(mr: { _ in 1.0008 }, mb: { _ in 0.9993 })
        let model = try XCTUnwrap(LateralCAEstimator.estimate(img))
        let corrected = LensStage.apply(img, lens: LensCorrections(profile: false, removeCA: true),
                                        inputs: LensInputs(lateralCA: model))
        let half = 0.5 * (1800.0 * 1800 + 1200 * 1200).squareRoot()
        let before = try XCTUnwrap(LateralCAEstimator.measure(img))
        let after = try XCTUnwrap(LateralCAEstimator.measure(corrected))
        func median(_ s: [LateralCAEstimator.Sample], _ k: KeyPath<LateralCAEstimator.Sample, Double>) -> Double {
            let v = s.filter { $0.r > 0.6 }.map { $0[keyPath: k] * half }.sorted()
            return v[v.count / 2]
        }
        XCTAssertGreaterThan(abs(median(before, \.redShift)), 0.4)
        XCTAssertGreaterThan(abs(median(before, \.blueShift)), 0.4)
        XCTAssertLessThan(abs(median(after, \.redShift)), 0.05)
        XCTAssertLessThan(abs(median(after, \.blueShift)), 0.05)
        XCTAssertNil(LateralCAEstimator.estimate(corrected))
    }

    // SPEC 2.3: no CA in the frame → no model, and the stage is bit-identical.
    func testCAFreeFrameIsAnExactIdentity() {
        let img = Self.scene(tint: RGB(0.8, 1, 1.2))
        XCTAssertNil(LateralCAEstimator.estimate(img))
        let out = LensStage.apply(img, lens: LensCorrections(), inputs: .none)
        XCTAssertEqual(out.pixels, img.pixels)
    }

    // SPEC 2.4: Remove CA off is an exact identity even with a model.
    func testRemoveCAOffIsIdentity() {
        let img = Self.scene(mr: { _ in 1.001 })
        let model = LateralCAModel(red: .init(k0: 0.001), blue: .init())
        let out = LensStage.apply(img, lens: LensCorrections(profile: false, removeCA: false),
                                  inputs: LensInputs(lateralCA: model))
        XCTAssertEqual(out.pixels, img.pixels)
    }

    // SPEC 2.5: a coloured edge (no lens CA, a real colour change) does not invent a model.
    func testColourEdgesDoNotInventCA() {
        // Left half reddish, right half bluish, sharp checker on both.
        var img = Self.scene()
        for y in 0..<img.height {
            for x in 0..<img.width {
                var c = img[x, y]
                if (x / 150 + y / 150) % 2 == 0 { c.r *= 1.6; c.b *= 0.5 } else { c.b *= 1.5 }
                img[x, y] = c
            }
        }
        XCTAssertNil(LateralCAEstimator.estimate(img))
    }

    // MARK: Defringe

    /// A dark branch-like bar on bright sky with a purple fringe on its dark side, a
    /// green fringe on the other side, and a purple object far from any edge.
    static func fringeFrame() -> (ImageBuffer, fringe: (Int, Int), green: (Int, Int), object: (Int, Int)) {
        var img = ImageBuffer(width: 400, height: 200)
        for y in 0..<200 {
            for x in 0..<400 {
                var c = RGB(0.8, 0.85, 0.95)           // sky
                if x >= 100, x < 140 { c = RGB(0.02, 0.02, 0.02) }   // branch
                if x == 100 || x == 101 { c = RGB(0.12, 0.03, 0.16) } // purple fringe
                if x == 139 { c = RGB(0.05, 0.12, 0.06) }             // green fringe
                if x >= 260, x < 340, y >= 40, y < 160 { c = RGB(0.10, 0.04, 0.14) } // purple object
                img[x, y] = c
            }
        }
        return (img, (100, 100), (139, 100), (300, 100))
    }

    func oklabChroma(_ c: RGB) -> Double {
        let m = DefringeStage.toLMS, m2 = DefringeStage.m2
        func cb(_ v: Double) -> Double { v < 0 ? -pow(-v, 1.0 / 3) : pow(v, 1.0 / 3) }
        let l = cb(m[0][0] * c.r + m[0][1] * c.g + m[0][2] * c.b)
        let mm = cb(m[1][0] * c.r + m[1][1] * c.g + m[1][2] * c.b)
        let s = cb(m[2][0] * c.r + m[2][1] * c.g + m[2][2] * c.b)
        let a = m2[1][0] * l + m2[1][1] * mm + m2[1][2] * s
        let b = m2[2][0] * l + m2[2][1] * mm + m2[2][2] * s
        return (a * a + b * b).squareRoot()
    }

    // SPEC 3.1: amount 0 is an exact identity.
    func testDefringeZeroIsIdentity() {
        let (img, _, _, _) = Self.fringeFrame()
        let out = LensStage.apply(img, lens: LensCorrections(profile: false, removeCA: false,
                                                             defringe: Defringe()),
                                  inputs: .none)
        XCTAssertEqual(out.pixels, img.pixels)
    }

    // SPEC 3.2: purple fringe chroma falls with amount, monotonically; Y is preserved.
    func testPurpleFringeRemovedMonotonically() {
        let (img, fringe, green, object) = Self.fringeFrame()
        let before = oklabChroma(img[fringe.0, fringe.1])
        var last = before
        for amount in [1.0, 2, 5, 10, 20] {
            let out = LensStage.apply(img, lens: LensCorrections(
                profile: false, removeCA: false, defringe: Defringe(purpleAmount: amount)),
                inputs: .none)
            let c = oklabChroma(out[fringe.0, fringe.1])
            XCTAssertLessThan(c, last, "amount \(amount)")
            last = c
            let y0 = RGBColorSpace.rec2020.luminance(img[fringe.0, fringe.1])
            let y1 = RGBColorSpace.rec2020.luminance(out[fringe.0, fringe.1])
            XCTAssertEqual(y1, y0, accuracy: 1e-6 * y0)
            // Purple-only: the green fringe and the purple object are untouched.
            XCTAssertEqual(out[green.0, green.1], img[green.0, green.1])
            XCTAssertEqual(out[object.0, object.1], img[object.0, object.1])
            if amount == 20 { XCTAssertLessThan(c, 0.05 * before) }
        }
    }

    // SPEC 3.3: green fringe removed by Green Amount, purple untouched.
    func testGreenFringe() {
        let (img, fringe, green, _) = Self.fringeFrame()
        let out = LensStage.apply(img, lens: LensCorrections(
            profile: false, removeCA: false, defringe: Defringe(greenAmount: 10)), inputs: .none)
        XCTAssertLessThan(oklabChroma(out[green.0, green.1]),
                          0.15 * oklabChroma(img[green.0, green.1]))
        XCTAssertEqual(out[fringe.0, fringe.1], img[fringe.0, fringe.1])
    }

    // SPEC 3.4: the hue range selects — a range that excludes the fringe's hue leaves it.
    func testHueRangeExcludes() {
        let (img, fringe, _, _) = Self.fringeFrame()
        var d = Defringe(purpleAmount: 20)
        d.purpleHueLo = 0
        d.purpleHueHi = 10      // blue end only
        let out = LensStage.apply(img, lens: LensCorrections(profile: false, removeCA: false,
                                                             defringe: d), inputs: .none)
        XCTAssertEqual(out[fringe.0, fringe.1], img[fringe.0, fringe.1])
    }

    // MARK: Sony embedded profile

    /// A minimal little-endian TIFF: IFD0 with Make and a SubIFD carrying 0x7032/0x7035/0x7037,
    /// with the A7 IV corpus file's (6929) own values.
    static func sonyTIFF() -> Data {
        var b = [UInt8]()
        func u16(_ v: Int) { b += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        func u32(_ v: Int) { u16(v & 0xffff); u16(v >> 16) }
        let vig = [16, 0, 0, 128, 416, 800, 1248, 1760, 2304, 2848, 3424, 4000, 4544, 5312, 6496, 8288, 9856]
        let ca = [32, -128, -128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 128, -128, -128, -128,
                  -128, 0, 0, 0, 0, 0, 0, 0, 0, -128, -128, -128, -384]
        let dist = [16, -2, 0, 3, 5, 9, 13, 17, 22, 26, 30, 33, 35, 37, 37, 37, 36]
        b += [0x49, 0x49]; u16(42); u32(8)
        // IFD0 at 8: 2 entries (Make, SubIFDs), next 0.
        let ifd0 = 8, ifd0Size = 2 + 2 * 12 + 4
        let makeAt = ifd0 + ifd0Size
        let make = Array("SONY".utf8) + [0, 0, 0, 0]
        let subAt = makeAt + make.count
        u16(2)
        u16(0x010F); u16(2); u32(make.count); u32(makeAt)
        u16(0x014A); u16(4); u32(1); u32(subAt)
        u32(0)
        b += make
        let subSize = 2 + 3 * 12 + 4
        var dataAt = subAt + subSize
        var blobs: [[Int]] = []
        u16(3)
        for (tag, values) in [(0x7032, vig), (0x7035, ca), (0x7037, dist)] {
            u16(tag); u16(8); u32(values.count); u32(dataAt)
            dataAt += values.count * 2
            blobs.append(values)
        }
        u32(0)
        for values in blobs { for v in values { u16(v & 0xffff) } }
        return Data(b)
    }

    // SPEC 4.1: the record is read, and the corner fall-off is the 0.65 EV it encodes.
    func testSonyRecordIsRead() throws {
        let p = try XCTUnwrap(EmbeddedLensProfile.read(data: Self.sonyTIFF()))
        XCTAssertEqual(p.vignetting.count, 16)
        XCTAssertEqual(p.vignetting[0], 1, accuracy: 1e-12)
        XCTAssertEqual(log2(p.falloff(at: 1)), -0.651, accuracy: 0.002)
        XCTAssertEqual(p.caRed.count, 16)
        XCTAssertEqual(p.distortion.count, 16)
        // A non-Sony file reads as nothing.
        var other = [UInt8](Self.sonyTIFF())
        if let i = other.firstIndex(of: UInt8(ascii: "S")) { other[i] = UInt8(ascii: "X") }
        XCTAssertNil(EmbeddedLensProfile.read(data: Data(other)))
    }

    // SPEC 4.2: the kernel's polynomial tracks 1/falloff within 1 % from centre to corner.
    func testVignettePolynomialTracksKnots() throws {
        let p = try XCTUnwrap(EmbeddedLensProfile.read(data: Self.sonyTIFF()))
        let poly = try XCTUnwrap(p.gainPolynomial)
        for i in 0...50 {
            let r = Double(i) / 50
            XCTAssertEqual(poly.gain(r2: r * r) * p.falloff(at: r), 1, accuracy: 0.01, "r=\(r)")
        }
    }

    // SPEC 4.3: profile on flattens the encoded fall-off; profile off is identity.
    func testVignetteGainFlattensFalloff() throws {
        let p = try XCTUnwrap(EmbeddedLensProfile.read(data: Self.sonyTIFF()))
        let w = 600, h = 400
        let norm = 0.5 * (Double(w * w + h * h)).squareRoot()
        let img = ImageBuffer(width: w, height: h) { u, v in
            let dx = (u - 0.5) * Double(w), dy = (v - 0.5) * Double(h)
            return RGB(gray: 0.18 * p.falloff(at: (dx * dx + dy * dy).squareRoot() / norm))
        }
        let inputs = LensInputs(vignette: p.gainPolynomial)
        let on = LensStage.apply(img, lens: LensCorrections(profile: true, removeCA: true), inputs: inputs)
        for (x, y) in [(0, 0), (w - 1, h - 1), (w / 2, h / 2), (w / 4, h / 3)] {
            XCTAssertEqual(on[x, y].g, 0.18, accuracy: 0.18 * 0.01)
        }
        let off = LensStage.apply(img, lens: LensCorrections(profile: false, removeCA: true), inputs: inputs)
        XCTAssertEqual(off.pixels, img.pixels)
    }

    // The kernel sources carry the twins' constants (a drift guard; parity itself is
    // the macOS goldens' job).
    func testKernelSourcesCarryTwinConstants() {
        XCTAssertTrue(LensKernelSource.defringeApply.contains("\(DefringeStage.edgeStops.lo)"))
        XCTAssertTrue(LensKernelSource.defringeApply.contains("\(DefringeStage.m2[1][1])"))
        XCTAssertTrue(LensKernelSource.defringeLogLuma.contains("\(LensKernelSource.defringeFloor)"))
    }
}

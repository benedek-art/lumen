// ScopeHonestyTests.swift
// W2/H2-01 and H2-02: what the Develop histogram's clipping readout is allowed to claim.
//
// H2-01. The clipped percentage was counted on a proxy box-averaged to a 512 px long
// edge. Box averaging is a low-pass filter, so a blown region smaller than one box does
// not get smaller — it disappears. On a 45 MP frame that box is 16×16 source pixels, and
// an unaligned 16×16 blown square reported 0.00000 % against a truth of 0.00057 %.
//
// H2-02. `ScopeData.measure` hard-coded `.srgb255` four times and never saw
// `state.readoutSpace`. The picker offered three spaces and moved nothing.
//
// The fix lives in `Sources/LumenApp/ScopeData.swift`, which has no test target on this
// lane (K-102), so this file is in two halves:
//
//   · the ARITHMETIC, run for real against LumenCore — the same `Histogram.compute`,
//     `Histogram.clipEpsilon`, `ImageBuffer.downsampled` and `ScopeProxy` the app calls.
//     Every claim the app's new code makes about 8-bit sRGB taps is derived and checked
//     here, because that derivation is the part a `swiftc -parse` cannot see;
//   · a TEXT SCAN of `ScopeData.swift` with comments stripped, because a doc comment
//     naming a symbol would otherwise let the scan pass its own substitution proof.

import XCTest
@testable import LumenCore

final class ScopeHonestyTests: XCTestCase {

    // MARK: - H2-01, materialized: a box average erases a small blown region

    /// A frame with a KNOWN blown patch, measured two ways: over every pixel, and over
    /// the box-averaged proxy the app used to count on.
    ///
    /// THE TOLERANCE IS THE FINDING.
    ///  · counted over every pixel: exact. 9 pixels of 65 536 is 0.013733 %, and the
    ///    assertion allows 1e-12 of it.
    ///  · counted over the proxy: 0.000000 %. Not "within a tolerance" of 0.013733 % —
    ///    a hundred percent short, which is why a caption could not have rescued it.
    func testABlownPatchSmallerThanOneProxyBoxIsCountedAsZero() {
        let side = 256
        let factor = 4                      // 256 → 64, the shipped 4:1 reduction shape
        let patch = 3                       // smaller than the 4×4 box, and unaligned
        let frame = Self.frame(side: side, blownOrigin: 5, blownSide: patch)

        let truth = Double(patch * patch) / Double(side * side) * 100
        XCTAssertEqual(truth, 0.013732910156250, accuracy: 1e-12)

        let exact = Histogram.compute(frame, bins: 256, readout: .srgb255)
        XCTAssertEqual(exact.clippedPercent(.red, end: .high), truth, accuracy: 1e-12,
                       "counted over every pixel the frame has, the number is the truth")
        XCTAssertEqual(exact.clippedPercent(.luma, end: .high), truth, accuracy: 1e-12)

        let proxy = Histogram.compute(frame.downsampled(by: factor), bins: 256,
                                      readout: .srgb255)
        XCTAssertEqual(proxy.clippedPercent(.red, end: .high), 0, accuracy: 1e-12,
                       "H2-01: every blown pixel averaged away — the readout says the "
                       + "frame is clean while three by three pixels of it are gone")
    }

    /// The same machinery, on a patch big enough to survive: the defect is about SIZE,
    /// not about the binner being broken. A 32×32 patch under a 4×4 box keeps 49 of its
    /// 64 blocks, so the proxy reports 76.6 % of the truth — an under-report, still,
    /// and the reason the exact count is worth its pass.
    func testALargeBlownRegionSurvivesTheBoxButStillReadsLow() {
        let side = 256
        let frame = Self.frame(side: side, blownOrigin: 5, blownSide: 32)

        let truth = Double(32 * 32) / Double(side * side) * 100
        let exact = Histogram.compute(frame, bins: 256, readout: .srgb255)
        XCTAssertEqual(exact.clippedPercent(.red, end: .high), truth, accuracy: 1e-12)

        let proxy = Histogram.compute(frame.downsampled(by: 4), bins: 256,
                                      readout: .srgb255)
        let reported = proxy.clippedPercent(.red, end: .high)
        XCTAssertGreaterThan(reported, 0, "a large region does reach the proxy")
        XCTAssertLessThan(reported, truth, "and still reads low, by the partial blocks")
        XCTAssertEqual(reported / truth, 49.0 / 64.0, accuracy: 1e-9,
                       "76.6 % of the truth — the fully covered blocks and no others")
    }

    // MARK: - H2-01, at the scale the owner shoots

    /// The audit's table, re-derived here rather than quoted, so the numbers in the
    /// finding stay falsifiable after the fix. A 45 MP frame reduced to a 512 px long
    /// edge is a 16×16 box; an unaligned square of side `s` leaves
    /// `floor((s − 15) / 16)²` fully covered blocks and every other block short of the
    /// ceiling.
    func testTheFortyFiveMegapixelBoxArithmeticReproduces() {
        let w = 8192, h = 5464
        let proxyW = 512
        let proxyH = Int((Double(h) * Double(proxyW) / Double(w)).rounded())
        XCTAssertEqual(proxyH, 342)
        let samples = proxyW * proxyH
        let box = w / proxyW
        XCTAssertEqual(box, 16, "each proxy sample is the mean of 256 source pixels")

        func reported(_ side: Int) -> Double {
            let perAxis = Swift.max((side - (box - 1)) / box, 0)
            return Double(perAxis * perAxis) / Double(samples) * 100
        }
        func truth(_ side: Int) -> Double {
            Double(side * side) / Double(w * h) * 100
        }

        // Invisible: the specular on a wet rock, the sun through leaves.
        XCTAssertEqual(truth(8), 0.00014, accuracy: 0.000005)
        XCTAssertEqual(reported(8), 0, accuracy: 1e-12)
        XCTAssertEqual(truth(16), 0.00057, accuracy: 0.000005)
        XCTAssertEqual(reported(16), 0, accuracy: 1e-12)
        // Present, and a quarter of itself.
        XCTAssertEqual(truth(32), 0.00229, accuracy: 0.000005)
        XCTAssertEqual(reported(32) / truth(32), 0.25, accuracy: 0.01)
        XCTAssertEqual(reported(64) / truth(64), 0.56, accuracy: 0.01)
        XCTAssertEqual(reported(256) / truth(256), 0.88, accuracy: 0.01)
    }

    /// And why raising the proxy is not the fix on its own. `ScopeProxy`'s ~1 MP budget
    /// — the one this codebase already defines, and docs/04:502 specifies — is still a
    /// 7×7 box on the same frame, so everything below 7×7 still vanishes. It buys a
    /// 5.2× finer floor, not a measurement.
    func testTheOneMegapixelProxyMovesTheFloorWithoutRemovingIt() {
        let factor = ScopeProxy.factor(width: 8192, height: 5464)
        XCTAssertEqual(factor, 7)
        XCTAssertEqual((8192 / factor) * (5464 / factor), 912_600)
        XCTAssertLessThanOrEqual((8192 / factor) * (5464 / factor),
                                 ScopeProxy.targetPixels)
        XCTAssertGreaterThan(factor, 1,
                             "still an average, so an isolated blown pixel still dies")

        // A 6×6 blown square is smaller than one box and still reports nothing.
        let frame = Self.frame(side: 256, blownOrigin: 5, blownSide: 6)
        let proxy = Histogram.compute(frame.downsampled(by: factor), bins: 256,
                                      readout: .srgb255)
        XCTAssertEqual(proxy.clippedPercent(.red, end: .high), 0, accuracy: 1e-12)
    }

    /// The long edge the grid path now commissions, pinned to the constant it is
    /// derived from rather than to the number it happens to produce.
    func testTheMeasurementProxyIsTheOneTheCodebaseAlreadyDefines() {
        let longEdge = Int((1.5 * Double(ScopeProxy.targetPixels)).squareRoot().rounded())
        XCTAssertEqual(longEdge, 1225)
        let pixels = longEdge * Int((Double(longEdge) / 1.5).rounded())
        XCTAssertEqual(Double(pixels) / Double(ScopeProxy.targetPixels), 1.0,
                       accuracy: 0.005, "a 3:2 frame at this long edge is ~1 MP")
        XCTAssertGreaterThan(longEdge, 512, "and more than twice the old ask per axis")
    }

    // MARK: - The tap's arithmetic, which the app now performs on bytes

    /// The two clipping codes, DERIVED the way `AppState.clipCounts(in:)` derives them
    /// and checked against the binner that will consume them.
    ///
    /// A 256×1 ramp carries every 8-bit code exactly once, so the counts ARE the answer
    /// to "which codes clip": one at each end, and nothing in between.
    func testOnlyCode255ClipsHighAndOnlyCode0ClipsLowOnAnEightBitSRGBTap() {
        let ramp = Self.rampOfEveryCode()
        let histogram = Histogram.compute(ramp, bins: 256, readout: .srgb255)
        XCTAssertEqual(histogram.sampleCount, 256)
        for channel in Histogram.Channel.allCases {
            XCTAssertEqual(histogram.clippedHighCounts[channel.rawValue], 1,
                           "\(channel): code 255 and nothing below it")
            XCTAssertEqual(histogram.clippedLowCounts[channel.rawValue], 1,
                           "\(channel): code 0 and nothing above it")
        }

        // The margins, so the thresholds are pinned rather than merely satisfied.
        XCTAssertEqual(TransferFunction.srgb.decode(254.0 / 255), 0.991102, accuracy: 1e-6)
        XCTAssertLessThan(TransferFunction.srgb.decode(254.0 / 255),
                          1 - Histogram.clipEpsilon)
        XCTAssertEqual(TransferFunction.srgb.decode(1.0 / 255), 0.000303527, accuracy: 1e-9)
        XCTAssertGreaterThan(TransferFunction.srgb.decode(1.0 / 255),
                             Histogram.clipEpsilon)
    }

    /// The luma channel, off the tap's own linear channels.
    ///
    /// `Histogram.compute` bins `w · (M · x)` into channel 3, for working weights `w`
    /// and the sRGB→working matrix `M`. The app counts luma clipping on bytes as
    /// `(wᵀM) · x`, three weighted decode tables and two adds per pixel. Those are the
    /// same number, and this is where that is checked rather than asserted: if the
    /// weight vector were wrong — Rec.709 weights on Rec.2020 data, say — the two
    /// disagree here.
    func testTheTapsLumaWeightVectorIsTheBinnersLumaChannel() {
        let toWorking = RGBColorSpace.srgb.matrix(to: .rec2020)
        let w = RGBColorSpace.rec2020.luminanceWeights
        let m = toWorking.m
        let u = RGB(w.r * m[0][0] + w.g * m[1][0] + w.b * m[2][0],
                    w.r * m[0][1] + w.g * m[1][1] + w.b * m[2][1],
                    w.r * m[0][2] + w.g * m[1][2] + w.b * m[2][2])

        // Luminance is the Y row of the XYZ matrix and both spaces are D65, so the
        // derived vector is sRGB's own weights. Stated as a consequence, not an input.
        let srgbWeights = RGBColorSpace.srgb.luminanceWeights
        XCTAssertEqual(u.r, srgbWeights.r, accuracy: 1e-12)
        XCTAssertEqual(u.g, srgbWeights.g, accuracy: 1e-12)
        XCTAssertEqual(u.b, srgbWeights.b, accuracy: 1e-12)

        // And it agrees with the binner on real codes, clipped ones included.
        let codes: [(Int, Int, Int)] = [(255, 255, 255), (255, 255, 254), (255, 0, 0),
                                        (0, 0, 0), (1, 0, 0), (2, 2, 2), (128, 64, 200)]
        var buffer = ImageBuffer(width: codes.count, height: 1)
        for (x, code) in codes.enumerated() {
            buffer[x, 0] = Self.working(code)
        }
        let histogram = Histogram.compute(buffer, bins: 256, readout: .srgb255)

        var high = 0, low = 0
        for code in codes {
            let y = u.r * TransferFunction.srgb.decode(Double(code.0) / 255)
                + u.g * TransferFunction.srgb.decode(Double(code.1) / 255)
                + u.b * TransferFunction.srgb.decode(Double(code.2) / 255)
            if y >= 1 - Histogram.clipEpsilon { high += 1 }
            if y <= Histogram.clipEpsilon { low += 1 }
        }
        XCTAssertEqual(high, histogram.clippedHighCounts[Histogram.Channel.luma.rawValue])
        XCTAssertEqual(low, histogram.clippedLowCounts[Histogram.Channel.luma.rawValue])
        XCTAssertEqual(high, 1, "only the all-255 pixel; (255,255,254) is not luma-clipped")
        XCTAssertEqual(low, 2, "black, and (1,0,0), whose luminance is still under ε")
    }

    /// Re-denominating the traces' bins in the frame's own pixels leaves every ratio
    /// the panel reads exactly where it was, which is what makes the two-resolution
    /// measurement safe. `Histogram`'s public initializer is the seam the app uses.
    func testRescalingTheBinsMovesTheDenominatorAndNothingElse() {
        let frame = Self.frame(side: 128, blownOrigin: 5, blownSide: 3)
        let proxy = Histogram.compute(frame.downsampled(by: 4), bins: 256,
                                      readout: .srgb255)
        let tapSamples = 128 * 128
        let blown = 9

        let k = Double(tapSamples) / Double(proxy.sampleCount)
        var scaled = proxy.counts
        for i in 0..<scaled.count { scaled[i] = Int((Double(scaled[i]) * k).rounded()) }
        let fixed = Histogram(bins: proxy.bins, counts: scaled, sampleCount: tapSamples,
                              transform: proxy.transform,
                              clippedLowCounts: [0, 0, 0, 0],
                              clippedHighCounts: [blown, blown, blown, blown])

        XCTAssertEqual(fixed.clippedPercent(.red, end: .high),
                       Double(blown) / Double(tapSamples) * 100, accuracy: 1e-12,
                       "the clipping number is now the frame's, not the proxy's")
        XCTAssertEqual(proxy.clippedPercent(.red, end: .high), 0, accuracy: 1e-12)

        let zone = Histogram.zoneBoundaries()[2]
        XCTAssertEqual(fixed.fraction(in: zone, channel: .luma),
                       proxy.fraction(in: zone, channel: .luma), accuracy: 1e-4,
                       "the zone hover's share of pixels is unmoved")
        let before = proxy.normalized(.luma), after = fixed.normalized(.luma)
        XCTAssertEqual(before.count, after.count)
        for i in 0..<before.count {
            XCTAssertEqual(before[i], after[i], accuracy: 1e-6,
                           "the drawn trace is unmoved at bin \(i)")
        }
    }

    // MARK: - H2-02, measured: why the other two spaces are refused

    /// The picker's other two spaces cannot be answered off an 8-bit sRGB tap, and
    /// honouring them would not be neutral — it would make the clipping readout WORSE.
    ///
    /// A pixel the working space genuinely blew, Rec.2020 linear (1.0, 0.2, 0.2), leaves
    /// the encoder clamped into the sRGB gamut. Reconstructed from those 8 bits it reads
    /// 0.669 in working red — not clipped — while in sRGB it reads code 255, which is
    /// clipped, and true of the frame. Binning in the requested space would replace a
    /// correct answer with a systematic under-report of every saturated clip: H2-01's
    /// failure class, one space over.
    func testWorkingSpaceClippingCannotBeReadBackOffAnSRGBTap() {
        let blownInWorking = RGB(1.0, 0.2, 0.2)
        XCTAssertGreaterThanOrEqual(blownInWorking.r, 1 - Histogram.clipEpsilon)

        // What the encoder does to it: to sRGB linear, clamp, quantize to 8 bits.
        let toSRGB = RGBColorSpace.rec2020.matrix(to: .srgb)
        let srgbLinear = toSRGB.apply(blownInWorking)
        XCTAssertGreaterThan(srgbLinear.r, 1.0, "out of the sRGB gamut before the clamp")
        let encoded = TransferFunction.srgb.encode(
            RGB(Num.saturate(srgbLinear.r), Num.saturate(srgbLinear.g),
                Num.saturate(srgbLinear.b)))
        let codes = (Int((encoded.r * 255).rounded()), Int((encoded.g * 255).rounded()),
                     Int((encoded.b * 255).rounded()))
        XCTAssertEqual(codes.0, 255, "red pinned at the ceiling of the delivered frame")

        var tap = ImageBuffer(width: 1, height: 1)
        tap[0, 0] = Self.working(codes)

        let inSRGB = Histogram.compute(tap, bins: 256, readout: .srgb255)
        XCTAssertEqual(inSRGB.clippedFraction(.red, end: .high), 1.0, accuracy: 1e-12,
                       "the space the tap is in answers correctly")

        let inWorking = Histogram.compute(tap, bins: 256, readout: .working)
        XCTAssertEqual(inWorking.clippedFraction(.red, end: .high), 0.0, accuracy: 1e-12,
                       "H2-02: honouring the picker here reports a blown pixel as clean")

        // The reconstructed working value, so the size of the lie is on the record.
        XCTAssertEqual(tap[0, 0].r, 0.6685, accuracy: 0.002)
    }

    /// And the same for a wider export target: pushing sRGB-clamped data into ProPhoto
    /// answers "will this export clip?" with a confident no, built out of the values the
    /// clamp already threw away.
    func testAWiderOutputProfileTurnsAClippedPixelIntoACleanOne() {
        var tap = ImageBuffer(width: 1, height: 1)
        tap[0, 0] = Self.working((255, 0, 0))

        let inSRGB = Histogram.compute(tap, bins: 256, readout: .srgb255)
        XCTAssertEqual(inSRGB.clippedFraction(.red, end: .high), 1.0, accuracy: 1e-12)

        let wide = ReadoutTransform(space: .outputProfile, working: .rec2020,
                                    output: .proPhoto, outputTransfer: .gamma18)
        let inWide = Histogram.compute(tap, bins: 256, transform: wide)
        XCTAssertEqual(inWide.clippedFraction(.red, end: .high), 0.0, accuracy: 1e-12,
                       "reported clean, on data that was clamped two stages earlier")
    }

    // MARK: - The shipped file has to take these paths

    /// `Sources/LumenApp/ScopeData.swift` is in LumenApp, which has no test target on
    /// this lane, so this reads it as text — comments stripped, because the doc comments
    /// in that file name every symbol below and would let the scan pass its own
    /// substitution proof.
    func testTheClippingCountsComeOffTheFramesOwnPixels() throws {
        let source = Self.stripped(try Self.appSource("ScopeData.swift"))

        XCTAssertTrue(source.contains("func clipCounts(in tap: ScopeTap)"),
                      "the counts need a counter that walks the frame")
        XCTAssertTrue(source.contains("func scopeTap(from image: CGImage)"))

        // The tap must not be downsampled on the way in — that is the whole defect.
        let tapAt = try XCTUnwrap(
            source.range(of: "func scopeTap(from image: CGImage)")).upperBound
        let tapBody = String(source[tapAt...].prefix(1200))
        XCTAssertTrue(tapBody.contains("width: width, height: height"),
                      "the tap is drawn 1:1; a resample here reintroduces H2-01")
        XCTAssertFalse(tapBody.contains("targetLongEdge"),
                       "no long-edge reduction may stand between the frame and the count")

        // And the measurement must actually use it, on both feeds.
        let measureAt = try XCTUnwrap(
            source.range(of: "func measure(_ buffer: ImageBuffer")).upperBound
        let measureBody = String(source[measureAt...].prefix(1400))
        XCTAssertTrue(measureBody.contains("clipCounts(in: tap"),
                      "measure has to prefer the exact counts over the proxy's")
        XCTAssertTrue(measureBody.contains("redenominated("),
                      "and re-denominate the bins in the pixels they were counted over")
        XCTAssertTrue(source.contains("tap: AppState.scopeTap(from: image)"),
                      "the loupe feed passes its frame")
        XCTAssertTrue(source.contains("tap: AppState.scopeTap(from: result.image)"),
                      "and so does the grid feed")
    }

    /// H2-02's half: the readout space has to reach the binner as a decision, not as a
    /// constant. Four `readout: .srgb255` literals used to sit inside `measure`.
    func testTheReadoutSpaceReachesTheBinner() throws {
        let source = Self.stripped(try Self.appSource("ScopeData.swift"))

        XCTAssertTrue(source.contains("readout: ReadoutSpace"),
                      "measure must take the picker's choice")
        XCTAssertTrue(source.contains("scopeTransform(requested: readout)"),
                      "and resolve it, rather than ignoring it")
        XCTAssertTrue(source.contains("let space = readoutSpace"),
                      "both feeds read state.readoutSpace on the main actor")

        let measureAt = try XCTUnwrap(
            source.range(of: "func measure(_ buffer: ImageBuffer")).upperBound
        let measureBody = String(source[measureAt...].prefix(1400))
        XCTAssertFalse(measureBody.contains("readout: ."),
                       "no hard-coded space may survive inside measure — that literal "
                       + "IS H2-02")
    }

    /// The grid feed commissions a proxy sized by the constant this codebase already
    /// defines, so `ScopeProxy` stops being dead code and the number it produces is
    /// counted over ~1 MP rather than over 512 px of a 45 MP file.
    func testTheGridFeedAsksForTheProxyTheSpecNames() throws {
        let source = Self.stripped(try Self.appSource("ScopeData.swift"))
        XCTAssertTrue(source.contains("ScopeProxy.targetPixels"),
                      "the ~1 MP budget is read, not re-invented")
        XCTAssertTrue(source.contains("maxLongEdge: AppState.scopeMeasureLongEdge"),
                      "and it is what the one-shot render is asked for")
        XCTAssertFalse(source.contains("maxLongEdge: AppState.scopeProxyLongEdge"),
                       "512 px was the resolution that could not answer the question")
    }

    // MARK: - helpers

    /// A mid-grey frame with one blown square. Values are working-space linear, which is
    /// what `AppState.buffer(from:)` hands the binner.
    private static func frame(side: Int, blownOrigin: Int, blownSide: Int) -> ImageBuffer {
        var buffer = ImageBuffer(width: side, height: side)
        for y in 0..<side {
            for x in 0..<side {
                let blown = x >= blownOrigin && x < blownOrigin + blownSide
                    && y >= blownOrigin && y < blownOrigin + blownSide
                buffer[x, y] = blown ? RGB(gray: 1.0) : RGB(gray: 0.18)
            }
        }
        return buffer
    }

    /// Every 8-bit code once, as neutral working-space values.
    private static func rampOfEveryCode() -> ImageBuffer {
        var buffer = ImageBuffer(width: 256, height: 1)
        for c in 0..<256 { buffer[c, 0] = working((c, c, c)) }
        return buffer
    }

    /// One 8-bit sRGB triple, decoded into the working space exactly as
    /// `AppState.buffer(from:)` decodes the tap.
    private static func working(_ code: (Int, Int, Int)) -> RGB {
        let encoded = RGB(Double(code.0) / 255, Double(code.1) / 255,
                          Double(code.2) / 255)
        return RGBColorSpace.srgb.matrix(to: .rec2020)
            .apply(TransferFunction.srgb.decode(encoded))
    }

    private static func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private static func stripped(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        var block = false
        while i < source.endIndex {
            let rest = source[i...]
            if block {
                if rest.hasPrefix("*/") { block = false; i = source.index(i, offsetBy: 2) }
                else { i = source.index(after: i) }
                continue
            }
            if rest.hasPrefix("/*") { block = true; i = source.index(i, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while i < source.endIndex, source[i] != "\n" { i = source.index(after: i) }
                continue
            }
            out.append(source[i]); i = source.index(after: i)
        }
        return out
    }
}

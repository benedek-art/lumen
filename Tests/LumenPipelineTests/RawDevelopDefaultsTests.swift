#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import XCTest
import LumenCore
@testable import LumenPipeline

/// What `CIRAWFilter` does to a real camera file at the settings `AppleRawSource`
/// leaves alone, and whether the one setting it re-asserts on every decode is inert.
///
/// `AppleRawSource.decode` pins the display-referred controls (boost, shadow boost,
/// local tone map, gamut mapping, contrast, exposure) and leaves four develop-stage
/// controls at Apple's per-camera defaults: `baselineExposure`, `shadowBias`,
/// `moireReductionAmount` and `detailAmount`. Those four decide the as-shot look the
/// Exposure slider starts from (Lightroom's zero includes the camera's baseline
/// exposure, +0.35 EV on the A7 IV), whether the scene-linear plane is still linear
/// near black (`shadowBias` is a black offset), and how much false colour the demosaic
/// leaves on fine detail. Nothing in this repository had ever read their values.
///
/// THE ONE ASSERTION: re-setting `neutralTemperature`/`neutralTint` to exactly the
/// values the filter reported must not move the decode. `AppleRawSource` does that on
/// every decode ("camera reference, always"), and the as-shot neutral is a camera-space
/// chromaticity, not a temperature: if Apple's temperature/tint → neutral inverse is
/// not exact for a file, every Lumen render of it is white-balanced away from the
/// camera's as-shot neutral before Lumen's own CAT16 runs. Everything else is logged,
/// one `raw-defaults-file:` line per file per test, so the next change to these
/// settings is made from measurements rather than guesses.
///
/// Runs through LUMEN_AUDIT_RAW_DIR, the same opt-in as `AuditRawAccuracyTests`; it
/// skips everywhere else.
final class RawDevelopDefaultsTests: XCTestCase {

    struct Fixture {
        let url: URL
        let name: String
    }

    private static let comma = ","
    private static let dash = "-"

    private func fixtures() throws -> [Fixture] {
        let raw = ProcessInfo.processInfo.environment["LUMEN_AUDIT_RAW_DIR"] ?? ""
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw XCTSkip("LUMEN_AUDIT_RAW_DIR unset; real-file RAW tests are opt-in")
        }
        let root = URL(fileURLWithPath: path)
        let manifest = root.appendingPathComponent("corpus.tsv")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw XCTSkip("no corpus.tsv under LUMEN_AUDIT_RAW_DIR")
        }
        let text = try String(contentsOf: manifest, encoding: .utf8)
        var result: [Fixture] = []
        for line in text.split(separator: "\n") where line.contains(";") {
            let fields = line.split(separator: ";", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 7, !fields[0].isEmpty, !fields[1].isEmpty else { continue }
            if fields[6].contains("negative") { continue }
            result.append(Fixture(url: root.appendingPathComponent(fields[1]),
                                  name: "corpus" + fields[0]))
        }
        XCTAssertFalse(result.isEmpty, "corpus.tsv lists no positive files")
        return result
    }

    private static func emit(_ line: String) {
        fputs("\n" + line + "\n", stdout)
        fflush(stdout)
    }

    private func eachFixture(_ test: String, _ body: (Fixture) throws -> String) throws {
        for fixture in try fixtures() {
            var verdict = "error"
            autoreleasepool {
                do {
                    verdict = try body(fixture)
                } catch {
                    XCTFail("\(fixture.name): \(error)")
                }
            }
            Self.emit("raw-defaults-file: " + test + " " + fixture.name + " " + verdict)
        }
    }

    private static func fmt(_ value: Double, _ digits: Int = 4) -> String {
        value.isFinite ? String(format: "%.\(digits)f", value) : "nan"
    }

    private let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    private lazy var context = CIContext(options: [
        // Extended-linear sRGB working space: the evaluation contract RAW9 needs and
        // decoder 8 tolerates. Every comparison below is A against B in this context.
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
    ])

    /// A fresh filter at AppleRawSource's flat settings with a quiet recipe (no
    /// denoise, no capture sharpening, no lens profile) — except the neutral, which is
    /// left as opened unless `reassertNeutral`.
    private func flatFilter(_ url: URL, scale: Float, reassertNeutral: Bool) -> CIRAWFilter? {
        guard let filter = CIRAWFilter(imageURL: url),
              RawParams.selectsRawDecoder(filter.decoderVersion.rawValue),
              filter.nativeSize.width >= 1 else { return nil }
        filter.scaleFactor = scale
        filter.isDraftModeEnabled = false
        if reassertNeutral {
            let temperature = filter.neutralTemperature
            let tint = filter.neutralTint
            filter.neutralTemperature = temperature
            filter.neutralTint = tint
        }
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        filter.localToneMapAmount = 0
        filter.isGamutMappingEnabled = false
        filter.contrastAmount = 0
        filter.exposure = 0
        filter.extendedDynamicRangeAmount = 1
        filter.sharpnessAmount = 0
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.isLensCorrectionEnabled = false
        return filter
    }

    private func pixels(_ image: CIImage) -> (values: [Float], count: Int)? {
        let bounds = image.extent.integral
        guard !bounds.isNull, !bounds.isInfinite, bounds.width >= 1, bounds.height >= 1
        else { return nil }
        let width = Int(bounds.width), height = Int(bounds.height)
        var result = [Float](repeating: 0, count: width * height * 4)
        result.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: working)
        }
        return (result, width * height)
    }

    /// Per-channel means over finite samples.
    private static func means(_ px: [Float], count: Int) -> [Double] {
        var sum = [0.0, 0.0, 0.0]
        var n = 0
        for i in 0..<count {
            let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
            guard r.isFinite, g.isFinite, b.isFinite else { continue }
            sum[0] += r; sum[1] += g; sum[2] += b
            n += 1
        }
        return sum.map { n > 0 ? $0 / Double(n) : .nan }
    }

    private static let decodeScale: Float = 0.1

    func testFlatDecodeDefaultsAreRecorded() throws {
        try eachFixture("defaults") { fixture in
            guard let filter = CIRAWFilter(imageURL: fixture.url),
                  RawParams.selectsRawDecoder(filter.decoderVersion.rawValue) else {
                return "refused"
            }
            let chroma = filter.neutralChromaticity
            return "decoder=" + filter.decoderVersion.rawValue
                + " baselineExposure=" + Self.fmt(Double(filter.baselineExposure))
                + " shadowBias=" + Self.fmt(Double(filter.shadowBias))
                + " moire=" + Self.fmt(Double(filter.moireReductionAmount))
                + " moireSupported=" + String(filter.isMoireReductionSupported)
                + " detail=" + Self.fmt(Double(filter.detailAmount))
                + " detailSupported=" + String(filter.isDetailSupported)
                + " colorNR=" + Self.fmt(Double(filter.colorNoiseReductionAmount))
                + " lumaNR=" + Self.fmt(Double(filter.luminanceNoiseReductionAmount))
                + " sharpness=" + Self.fmt(Double(filter.sharpnessAmount))
                + " lensSupported=" + String(filter.isLensCorrectionSupported)
                + " neutralK=" + Self.fmt(Double(filter.neutralTemperature), 1)
                + " neutralTint=" + Self.fmt(Double(filter.neutralTint), 2)
                + " neutralXY=" + Self.fmt(Double(chroma.x), 5) + Self.comma
                + Self.fmt(Double(chroma.y), 5)
                + " native=" + Self.fmt(Double(filter.nativeSize.width), 0) + "x"
                + Self.fmt(Double(filter.nativeSize.height), 0)
        }
    }

    /// AppleRawSource re-asserts the as-shot neutral as temperature/tint on every
    /// decode. That must be an identity on the pixels.
    func testReassertingTheReportedAsShotNeutralDoesNotMoveTheDecode() throws {
        try eachFixture("neutral-identity") { fixture in
            guard let untouched = flatFilter(fixture.url, scale: Self.decodeScale,
                                             reassertNeutral: false),
                  let reasserted = flatFilter(fixture.url, scale: Self.decodeScale,
                                              reassertNeutral: true),
                  let a = untouched.outputImage, let b = reasserted.outputImage,
                  let pa = pixels(a), let pb = pixels(b) else { return "refused" }
            XCTAssertEqual(pa.count, pb.count, "\(fixture.name): extents differ")
            guard pa.count == pb.count else { return "extent-mismatch" }
            let ma = Self.means(pa.values, count: pa.count)
            let mb = Self.means(pb.values, count: pb.count)
            var worst = 0.0
            for c in 0..<3 where ma[c].isFinite && mb[c].isFinite && abs(ma[c]) > 1e-6 {
                worst = max(worst, abs(mb[c] / ma[c] - 1))
            }
            // A channel ratio, so 1e-3 is a tenth of a percent: far below a visible
            // cast and far above float noise from evaluating the same graph twice.
            XCTAssertLessThanOrEqual(worst, 1e-3,
                                     "\(fixture.name): re-setting the as-shot neutral "
                                         + "as temperature/tint moved the channel means by "
                                         + Self.fmt(worst * 100, 3) + "%")
            return "worst-channel-ratio=" + Self.fmt(worst, 6)
                + " untouched=" + ma.map { Self.fmt($0, 5) }.joined(separator: Self.comma)
                + " reasserted=" + mb.map { Self.fmt($0, 5) }.joined(separator: Self.comma)
        }
    }

    /// What `baselineExposure` and `shadowBias` contribute, and where the flat decode's
    /// highlights and shadows land. Logged, not asserted: these are the numbers the
    /// next change to either setting has to be made from.
    func testHighlightAndShadowEnvelopeIsRecorded() throws {
        try eachFixture("envelope") { fixture in
            guard let base = flatFilter(fixture.url, scale: Self.decodeScale,
                                        reassertNeutral: false),
                  let image = base.outputImage, let px = pixels(image) else { return "refused" }
            var maxima = [-Double.infinity, -Double.infinity, -Double.infinity]
            var negatives = 0, aboveOne = 0, finite = 0
            for i in 0..<px.count {
                var ok = true
                for c in 0..<3 {
                    let v = Double(px.values[i * 4 + c])
                    if !v.isFinite { ok = false; continue }
                    maxima[c] = max(maxima[c], v)
                }
                guard ok else { continue }
                finite += 1
                let r = px.values[i * 4], g = px.values[i * 4 + 1], b = px.values[i * 4 + 2]
                if r < 0 || g < 0 || b < 0 { negatives += 1 }
                if r >= 1 || g >= 1 || b >= 1 { aboveOne += 1 }
            }
            let baseMeans = Self.means(px.values, count: px.count)
            let baseG = baseMeans[1]

            // Baseline exposure zeroed: the ratio of green means is 2^baselineExposure
            // if Apple applies it as a pure gain.
            var beRatio = Double.nan
            if let f = flatFilter(fixture.url, scale: Self.decodeScale, reassertNeutral: false) {
                f.baselineExposure = 0
                if let im = f.outputImage, let p = pixels(im) {
                    let g = Self.means(p.values, count: p.count)[1]
                    if g.isFinite, abs(g) > 1e-9 { beRatio = baseG / g }
                }
            }
            // Shadow bias zeroed: a pure black offset shows as a mean shift.
            var sbShift = Double.nan
            if let f = flatFilter(fixture.url, scale: Self.decodeScale, reassertNeutral: false) {
                f.shadowBias = 0
                if let im = f.outputImage, let p = pixels(im) {
                    sbShift = Self.means(p.values, count: p.count)[1] - baseG
                }
            }
            let denom = Double(max(finite, 1))
            return "baselineExposure=" + Self.fmt(Double(base.baselineExposure))
                + " gainFromBaseline=" + Self.fmt(beRatio)
                + " log2=" + Self.fmt(beRatio > 0 ? log2(beRatio) : .nan)
                + " shadowBias=" + Self.fmt(Double(base.shadowBias))
                + " greenShiftWithoutBias=" + Self.fmt(sbShift, 6)
                + " max=" + maxima.map { Self.fmt($0) }.joined(separator: Self.comma)
                + " pctAnyNegative=" + Self.fmt(Double(negatives) * 100 / denom, 3)
                + " pctAnyAtOrAboveOne=" + Self.fmt(Double(aboveOne) * 100 / denom, 3)
                + " means=" + baseMeans.map { Self.fmt($0, 5) }.joined(separator: Self.comma)
        }
    }
}
#endif

#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import XCTest
import LumenCore
@testable import LumenPipeline

/// Decoder selection, RAW9 colour and native-dimension checks against real camera files.
///
/// TWO WAYS TO RUN IT, both through LUMEN_AUDIT_RAW_DIR:
///   - A PRIVATE directory of copies. Never commit photographs, sidecars or local paths.
///     Logs name such files by ordinal (`fixture3`), never by filename.
///   - The PUBLIC CC0 corpus that `.github/workflows/raw-corpus.yml` fetches. A directory
///     holding `corpus.tsv` is read through that manifest: its rows are the files, the
///     lane's synthetic negatives (flag `negative`) are left to `RawCorpusTests` R-9, and
///     logs name files by manifest id (`corpus2349`). This is the lane that makes these
///     checks able to fail on CI; before it, every one of them skipped everywhere.
///
/// EVERY FILE IS REPORTED, per test, as one `audit-raw-file:` line at line start, and
/// the lane fails when a test reports fewer lines than the manifest has files. An
/// environment variable that does not arrive reads exactly like a passing run.
///
/// WHAT GENERALISES FROM THE THREE SONY FILES THESE WERE WRITTEN FOR, AND WHAT DOES NOT.
/// The assertions compare Lumen's decode with an independent `CIRAWFilter` configured
/// the same way. That is a property of any file Apple decodes, so it is asserted for
/// every file. What is per file is stated per file rather than loosened for all:
///   - A file Apple's own filter will not open, or will not form an image from with
///     these settings, must be refused by Lumen as well (and is logged as refused).
///     Lumen fabricating a picture Apple's decoder cannot make is a failure.
///   - The delivered size of a non-draft decode must be scale x native long edge (AI-15).
///     Where a fresh platform filter does not deliver that for the file either, the
///     file is logged with both numbers and Lumen is held to the platform's own size.
///   - RAW9 runs only where the OS offers RAW9 for the file. The two RAW9-only tests
///     still report every file they examined and skip, visibly, when none had it.
///   - A file whose default decoder carries no number has no pin to switch away from;
///     every requested pin must then render the default.
final class AuditRawAccuracyTests: XCTestCase {

    struct Fixture {
        let url: URL
        /// What logs call the file: a manifest id or an ordinal, never a filename.
        let name: String
    }

    private func fixtures() throws -> [Fixture] {
        let raw = ProcessInfo.processInfo.environment["LUMEN_AUDIT_RAW_DIR"] ?? ""
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty is refused as well as absent: GitHub sets an unset expression to "".
        guard !path.isEmpty else {
            throw XCTSkip("LUMEN_AUDIT_RAW_DIR unset; private RAW tests are opt-in")
        }
        let root = URL(fileURLWithPath: path)
        let manifest = root.appendingPathComponent("corpus.tsv")
        if FileManager.default.fileExists(atPath: manifest.path) {
            return try manifestFixtures(manifest, root: root)
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
            .filter { Self.rawExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty, "Configured corpus must contain RAW files")
        return urls.enumerated().map { Fixture(url: $1, name: "fixture\($0 + 1)") }
    }

    /// The containers the public corpus carries, plus the private set's.
    private static let rawExtensions: Set<String> = [
        "arw", "nef", "cr3", "dng", "raf", "cr2", "rw2", "orf", "pef", "iiq", "x3f", "gpr",
    ]

    /// `id;local;sha256;bytes;make;orient;flags;licence;label;url`, as raw-corpus.yml
    /// writes it. Only id, local and flags are read here.
    private func manifestFixtures(_ manifest: URL, root: URL) throws -> [Fixture] {
        let text = try String(contentsOf: manifest, encoding: .utf8)
        var result: [Fixture] = []
        for line in text.split(separator: "\n") where line.contains(";") {
            let fields = line.split(separator: ";", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 7, !fields[0].isEmpty, !fields[1].isEmpty else {
                XCTFail("Unparseable corpus.tsv row: \(line)")
                continue
            }
            if fields[6].contains("negative") { continue }
            let url = root.appendingPathComponent(fields[1])
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "corpus.tsv names \(fields[1]) and it is not on disk")
            result.append(Fixture(url: url, name: "corpus" + fields[0]))
        }
        XCTAssertFalse(result.isEmpty, "corpus.tsv lists no positive files")
        return result
    }

    /// One whole line at line start, flushed, so the lane's grep cannot miss it behind
    /// a pipe-buffered stdout (same reasoning as `RawCorpusTests.emit`).
    private static func emit(_ line: String) {
        fputs("\n" + line + "\n", stdout)
        fflush(stdout)
    }

    private static func report(_ test: String, _ fixture: Fixture, _ verdict: String) {
        emit("audit-raw-file: " + test + " " + fixture.name + " " + verdict)
    }

    /// Every file is examined even when an earlier one throws: one bad file must not
    /// hide the rest, and a file that threw is reported as such.
    private func eachFixture(_ test: String,
                             _ body: (Fixture) throws -> String) throws {
        for fixture in try fixtures() {
            var verdict = "error"
            autoreleasepool {
                do {
                    verdict = try body(fixture)
                } catch {
                    XCTFail("\(fixture.name): \(error)")
                }
            }
            Self.report(test, fixture, verdict)
        }
    }

    private var quietRecipe: Recipe {
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.develop.detail.capture.auto = false
        recipe.develop.geometry.lens.profile = false
        return recipe
    }

    private let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    private lazy var consumer = CIContext(options: [
        .workingColorSpace: working, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
    ])
    private let raw9Context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
    ])
    // Match the pre-existing decoder8 evaluation contract, not a different Apple
    // float-intermediate demosaic (which changes some highlight pixels). This is
    // an independent context, not the materializer under test. RAW9 remains f32.
    private let legacyOracleContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
        .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false,
    ])

    /// What this OS offers for the file, for the evidence log. Whether any corpus file
    /// has a default that is NOT its last supported version decides whether a return
    /// to forcing `.last` is visible on this runner at all; the log says which.
    private static func describe(_ apple: CIRAWFilter) -> String {
        let supported = apple.supportedDecoderVersions.map(\.rawValue)
            .joined(separator: Self.comma)
        let last = apple.supportedDecoderVersions.last?.rawValue ?? Self.dash
        let marker = last == apple.decoderVersion.rawValue ? "default-is-last" : "default-is-not-last"
        return "default=" + apple.decoderVersion.rawValue + " supported=" + supported
            + " " + marker
    }

    // Separators as constants: the surface checker misreads a quote nested inside a
    // string interpolation (see RawCorpusTests).
    private static let comma = ","
    private static let dash = "-"

    func testUnpinnedSourceUsesTheDecoderAppleSelectedForTheFile() throws {
        try eachFixture("unpinned") { fixture in
            guard let apple = CIRAWFilter(imageURL: fixture.url) else {
                XCTAssertThrowsError(try AppleRawSource(url: fixture.url),
                                     "\(fixture.name): Apple's filter will not open this file "
                                         + "and Lumen claims to")
                return "refused-at-open"
            }
            if let refused = Self.refusedWithoutDecoder(apple, fixture) { return refused }
            let decoders = Self.describe(apple)
            let expected = RawParams.decoderNumber(apple.decoderVersion.rawValue)
            let source = try AppleRawSource(url: fixture.url)
            XCTAssertEqual(source.pinnedDecoderVersion, expected,
                           "\(fixture.name): an advertised version is not necessarily "
                               + "Apple's selected default (\(decoders))")
            let reference = try oracle(fixture.url, source: source, version: nil, scale: 0.08)
            let actual = source.decode(recipe: quietRecipe, draft: false, scaleFactor: 0.08)
            guard let reference else {
                XCTAssertNil(actual, "\(fixture.name): Apple's filter forms no image with "
                                 + "these settings and Lumen delivered one anyway")
                return "refused-at-decode " + decoders
            }
            try assertPixels(try XCTUnwrap(actual, "\(fixture.name): Lumen refused a file "
                                               + "Apple's filter decodes"),
                             reference: reference, label: "default " + fixture.name)
            return "decoded " + decoders
        }
    }

    func testNativeDimensionsDoNotDependOnDecoderScaleDraftOrCache() throws {
        try eachFixture("native-dimensions") { fixture in
            guard let apple = CIRAWFilter(imageURL: fixture.url) else {
                XCTAssertThrowsError(try AppleRawSource(url: fixture.url))
                return "refused-at-open"
            }
            if let refused = Self.refusedWithoutDecoder(apple, fixture) { return refused }
            var versions = [apple.decoderVersion]
            if let raw9 = apple.supportedDecoderVersions.first(where: AppleRawSource.needsRaw9Boundary),
               raw9 != apple.decoderVersion { versions.append(raw9) }
            var verdict = "decoded"
            for version in versions {
                let isDefault = version == apple.decoderVersion
                let source = try AppleRawSource(url: fixture.url)
                let size = source.nativePixelSize
                let longEdge = Double(max(size.width, size.height))
                XCTAssertGreaterThan(longEdge, 0)
                var recipe = quietRecipe
                recipe.develop.raw.decoderVersion = RawParams.decoderNumber(version.rawValue)
                for (scale, draft) in [(0.12, false), (0.25, true), (0.08, false), (0.12, false)] {
                    guard let image = source.decode(recipe: recipe, draft: draft,
                                                    scaleFactor: scale) else {
                        // Refusing is only honest where the platform refuses too.
                        let platform = try oracle(
                            fixture.url, source: source,
                            version: isDefault ? nil : RawParams.decoderNumber(version.rawValue),
                            scale: Float(scale))
                        XCTAssertNil(platform, "\(fixture.name) v\(version.rawValue) at \(scale): "
                                         + "Lumen refused a decode Apple's filter makes")
                        verdict = "refused-at-decode"
                        continue
                    }
                    XCTAssertGreaterThan(image.extent.width, 0)
                    XCTAssertEqual(source.nativePixelSize.width, size.width)
                    XCTAssertEqual(source.nativePixelSize.height, size.height)
                    XCTAssertEqual(source.nativeLongEdge, longEdge)
                    XCTAssertEqual(source.captureMetadata.pixelSize.width, size.width)
                    XCTAssertEqual(source.captureMetadata.pixelSize.height, size.height)
                    guard !draft else { continue }
                    // AI-15's symptom was in the DELIVERED size, not the metadata: a
                    // 2560 ask came back 5120 once RAW9 had shrunk `nativeSize`. The
                    // checks above would pass on that frame.
                    let delivered = Double(max(image.extent.width, image.extent.height))
                    let asked = scale * longEdge
                    let platform = try oracle(
                        fixture.url, source: source,
                        version: isDefault ? nil : RawParams.decoderNumber(version.rawValue),
                        scale: Float(scale))?.image.extent
                    let platformLong = platform.map { Double(max($0.width, $0.height)) }
                    if let platformLong, abs(platformLong - asked) > 2 {
                        // This file's decoder does not deliver scale x native even from
                        // a fresh filter. Lumen is held to what the platform delivers.
                        Self.emit("audit-raw-scale-note: \(fixture.name) v\(version.rawValue) "
                            + "scale=\(scale) native=\(longEdge) asked=\(asked) "
                            + "platform=\(platformLong) lumen=\(delivered)")
                        XCTAssertEqual(delivered, platformLong, accuracy: 2,
                                       "\(fixture.name) v\(version.rawValue) at \(scale): Lumen "
                                           + "delivered \(delivered), a fresh filter \(platformLong)")
                        verdict = "decoded-platform-scale"
                    } else {
                        XCTAssertEqual(delivered, asked, accuracy: 2,
                                       "\(fixture.name) v\(version.rawValue) at \(scale): asked "
                                           + "for \(asked) px of a \(longEdge) px frame, delivered "
                                           + "\(delivered) (AI-15)")
                    }
                }
                source.releaseDecodes()
                XCTAssertEqual(source.nativeLongEdge, longEdge)
            }
            let checked = versions.map(\.rawValue).joined(separator: Self.comma)
            return verdict + " versions=" + checked
        }
    }

    func testExplicitRaw9PreviewAndCachePixelsAgreeWithIndependentDecode() throws {
        var tested = 0
        try eachFixture("raw9-preview") { fixture in
            guard supportsRaw9(fixture.url) else { return "no-raw9" }
            let source = try AppleRawSource(url: fixture.url)
            var recipe = quietRecipe
            recipe.develop.raw.decoderVersion = RawParams.raw9DecoderNumber
            let reference = try XCTUnwrap(try oracle(fixture.url, source: source,
                                                     version: RawParams.raw9DecoderNumber,
                                                     scale: 0.08))
            for pass in 0..<2 {
                let actual = try XCTUnwrap(source.decode(
                    recipe: recipe, draft: false, scaleFactor: 0.08))
                try assertPixels(actual, reference: reference,
                                 label: "RAW9 preview \(fixture.name) pass\(pass)")
            }
            tested += 1
            return "decoded"
        }
        try XCTSkipUnless(tested > 0, "No RAW9 support in this corpus/OS")
    }

    /// Fresh source, FIRST native decode, then cache hit: a preview-only fix fails.
    /// Distributed real pixel tiles also prevent opposite errors cancelling in a mean.
    func testFirstNativeRaw9DecodeAndCacheHitHaveCorrectPixels() throws {
        var tested = 0
        try eachFixture("raw9-native") { fixture in
            guard supportsRaw9(fixture.url) else { return "no-raw9" }
            let source = try AppleRawSource(url: fixture.url)
            var recipe = quietRecipe
            recipe.develop.raw.decoderVersion = RawParams.raw9DecoderNumber
            let reference = try XCTUnwrap(try oracle(fixture.url, source: source,
                                                     version: RawParams.raw9DecoderNumber,
                                                     scale: 1))
            XCTAssertEqual(source.heldDecodeBytes, 0)
            for pass in 0..<2 {
                let actual = try XCTUnwrap(source.decode(recipe: recipe, draft: false, scaleFactor: 1))
                for fraction in [0.25, 0.5, 0.75] {
                    let bounds = CGRect(
                        x: (actual.extent.minX + actual.extent.width * fraction).rounded(),
                        y: (actual.extent.minY + actual.extent.height * fraction).rounded(),
                        width: 32, height: 32)
                    try assertPixels(actual, reference: reference, bounds: bounds,
                                     label: "RAW9 native \(fixture.name) pass\(pass) tile\(fraction)")
                }
            }
            XCTAssertGreaterThan(source.releaseInspectionDecodes(), 0)
            XCTAssertEqual(source.heldDecodeBytes, 0)
            tested += 1
            return "decoded"
        }
        try XCTSkipUnless(tested > 0, "No RAW9 support in this corpus/OS")
    }

    /// Stage isolation for the first-native discrepancy. This deliberately measures
    /// scene-linear pixels before RenderPlan, display mapping or dithering. A raw
    /// difference is evidence, not a relaxed display-identity acceptance threshold.
    func testNativeCachePromotionPrecisionEvidence() throws {
        try eachFixture("native-precision") { fixture in
            guard let apple = CIRAWFilter(imageURL: fixture.url) else { return "refused-at-open" }
            if let refused = Self.refusedWithoutDecoder(apple, fixture) { return refused }
            let source = try AppleRawSource(url: fixture.url)
            let first = try XCTUnwrap(source.decode(recipe: quietRecipe, draft: false, scaleFactor: 1))
            let rect = CGRect(x: (first.extent.midX - 32).rounded(),
                              y: (first.extent.midY - 32).rounded(), width: 64, height: 64)
            let before = pixels(first, context: consumer, bounds: rect)
            let repeatedLazy = pixels(first, context: consumer, bounds: rect)
            let explicit = try XCTUnwrap(DecodeMaterializer.materialize(first))
            let explicitPixels = pixels(explicit.image, context: consumer, bounds: rect)
            let cached = try XCTUnwrap(source.decode(recipe: quietRecipe, draft: false, scaleFactor: 1))
            let promoted = pixels(cached, context: consumer, bounds: rect)
            let repeatedCache = pixels(cached, context: consumer, bounds: rect)
            for values in [before, repeatedLazy, explicitPixels, promoted, repeatedCache] {
                XCTAssertTrue(values.allSatisfy { $0.isFinite }, fixture.name)
            }
            func maximumDelta(_ a: [Float], _ b: [Float]) -> Float {
                zip(a, b).map { abs($0 - $1) }.max() ?? 0
            }
            Self.emit("native-precision: " + fixture.name
                + " decoder=\(source.pinnedDecoderVersion ?? -1)"
                + " lazy-repeat=\(maximumDelta(before, repeatedLazy))"
                + " explicit-materialization=\(maximumDelta(before, explicitPixels))"
                + " first-cache=\(maximumDelta(before, promoted))"
                + " materialized-cache=\(maximumDelta(explicitPixels, promoted))"
                + " cache-repeat=\(maximumDelta(promoted, repeatedCache))"
                + " held-bytes=\(source.heldDecodeBytes)")
            // These compare repeated evaluation of the SAME graph, not lazy versus
            // half-float precision. DisplayedDenoiseQualificationTests retains the
            // separate exact-zero displayed acceptance check.
            XCTAssertEqual(before, repeatedLazy, fixture.name + " unstable lazy evaluation")
            XCTAssertEqual(promoted, repeatedCache, fixture.name + " unstable cached evaluation")
            return "measured"
        }
    }

    /// Holds the decoder result fixed while the real plan, graph and deterministic
    /// display dither execute. No production cache state can change this image.
    private final class FrozenNativeSource: ImageSource {
        let base: AppleRawSource
        let image: CIImage
        init(_ base: AppleRawSource, _ image: CIImage) { self.base = base; self.image = image }
        var url: URL { base.url }
        var nativeLongEdge: Double { base.nativeLongEdge }
        var nativePixelSize: (width: Int, height: Int) { base.nativePixelSize }
        var asShotTemperature: Double { base.asShotTemperature }
        var asShotTint: Double { base.asShotTint }
        var captureMetadata: CaptureMetadata { base.captureMetadata }
        var statisticsProvenance: RawStatistics.Provenance { base.statisticsProvenance }
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? {
            image
        }
    }

    /// Causal matrix, deliberately separate from the full denoise response sweep.
    /// Each pair uses the SAME native ROI. Exact displayed identity stays mandatory;
    /// all stage measurements are emitted before reporting any pair failures.
    func testNativeFirstCacheDisplayedCausalMatrix() throws {
        try eachFixture("native-causal") { fixture in
            guard let apple = CIRAWFilter(imageURL: fixture.url) else { return "refused-at-open" }
            if let refused = Self.refusedWithoutDecoder(apple, fixture) { return refused }
            var off = quietRecipe
            off.develop.denoise = Denoise(mode: .off)
            var aiZero = off
            aiZero.develop.denoise = Denoise(mode: .ai, amount: 0)
            let roi = CGRect(x: 0.4825, y: 0.4825, width: 0.035, height: 0.035)
            var failures: [String] = []
            func render(_ source: any ImageSource, _ recipe: Recipe,
                        _ renderer: PipelineRenderer) throws -> Data {
                let delivery = try renderer.renderPreviewDelivery(source: source, recipe: recipe,
                    maxLongEdge: Int(source.nativeLongEdge.rounded(.up)),
                    draft: false, coarseDecode: false, region: roi)
                XCTAssertNotNil(delivery.regionUnit, fixture.name + " expected bounded native ROI")
                let image = delivery.image
                // Canonical tightly packed RGBA avoids comparing provider row padding.
                var bytes = Data(count: image.width * image.height * 4)
                try bytes.withUnsafeMutableBytes { raw in
                    let context = try XCTUnwrap(CGContext(data: raw.baseAddress,
                        width: image.width, height: image.height, bitsPerComponent: 8,
                        bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0,
                        width: image.width, height: image.height))
                }
                return bytes
            }
            func compare(_ label: String, _ a: Data, _ b: Data) {
                let differences = zip(a, b).map { abs(Int($0) - Int($1)) }
                let changed = differences.filter { $0 != 0 }.count
                let largest = differences.max() ?? 0
                Self.emit("native-causal: " + fixture.name + " " + label
                    + " changedBytes=\(changed) maxCode=\(largest) bytes=\(a.count)/\(b.count)")
                if a != b { failures.append(label + " maxCode=\(largest) changedBytes=\(changed)") }
            }
            // Same-mode first/repeat cannot be attributed to a denoise-mode change.
            try autoreleasepool {
                let source = try AppleRawSource(url: fixture.url)
                let renderer = PipelineRenderer()
                let a = try render(source, off, renderer)
                let firstBytes = source.heldDecodeBytes
                let b = try render(source, off, renderer)
                Self.emit("native-causal-branch: " + fixture.name
                    + " edge=\(source.nativeLongEdge) firstHeld=\(firstBytes) repeatedHeld=\(source.heldDecodeBytes)")
                compare("off-first-vs-off-repeat", a, b)
                compare("off-repeat-vs-ai0", b, try render(source, aiZero, renderer))
            }
            // Reverse the mode order on a fresh decoder and renderer.
            try autoreleasepool {
                let source = try AppleRawSource(url: fixture.url)
                let renderer = PipelineRenderer()
                let a = try render(source, aiZero, renderer)
                compare("ai0-first-vs-off-repeat", a, try render(source, off, renderer))
            }
            try autoreleasepool {
                let source = try AppleRawSource(url: fixture.url)
                let lazy = try XCTUnwrap(source.decode(recipe: off, draft: false, scaleFactor: 1))
                let frozenLazy = FrozenNativeSource(source, lazy)
                let renderer = PipelineRenderer()
                let a = try render(frozenLazy, off, renderer)
                compare("fixed-lazy-same-renderer-repeat", a, try render(frozenLazy, off, renderer))
                compare("fixed-lazy-mode-change", a, try render(frozenLazy, aiZero, renderer))
                compare("fixed-lazy-fresh-renderer", a, try render(frozenLazy, off, PipelineRenderer()))
                let plane = try XCTUnwrap(DecodeMaterializer.materialize(lazy))
                let frozenPlane = FrozenNativeSource(source, plane.image)
                let b = try render(frozenPlane, off, renderer)
                compare("fixed-lazy-vs-explicit-plane", a, b)
                compare("fixed-plane-repeat", b, try render(frozenPlane, off, renderer))
                compare("fixed-plane-mode-change", b, try render(frozenPlane, aiZero, renderer))
                compare("fixed-plane-fresh-renderer", b, try render(frozenPlane, off, PipelineRenderer()))
            }
            for failure in failures {
                XCTFail(fixture.name + " exact displayed identity failed: " + failure)
            }
            return "measured pairs=10 failures=\(failures.count)"
        }
    }

    /// D50's honouring half, on every file and not only where RAW9 exists: each other
    /// decoder this OS offers for the file is pinned, switched away from and back (a
    /// cache hit), and an unavailable pin must render Apple's per-file default. Pixel
    /// comparisons prove the decoder, not just a label.
    func testExplicitPinsSurviveSwitchesAndUnsupportedPinUsesDefault() throws {
        try eachFixture("pins") { fixture in
            guard let apple = CIRAWFilter(imageURL: fixture.url) else {
                XCTAssertThrowsError(try AppleRawSource(url: fixture.url))
                return "refused-at-open"
            }
            if let refused = Self.refusedWithoutDecoder(apple, fixture) { return refused }
            let fallback = RawParams.decoderNumber(apple.decoderVersion.rawValue)
            var others: [Int] = []
            for version in apple.supportedDecoderVersions {
                guard let number = RawParams.decoderNumber(version.rawValue),
                      number != fallback, !others.contains(number) else { continue }
                others.append(number)
            }
            var requestedPins = others
            if let fallback { requestedPins.append(fallback) }
            requestedPins += others.prefix(1)
            requestedPins.append(999_999)
            let source = try AppleRawSource(url: fixture.url)
            for requested in requestedPins {
                var recipe = quietRecipe
                recipe.develop.raw.decoderVersion = requested
                // A pin this OS offers is honoured. The default, an unavailable pin, and
                // an offered decoder that forms no image on this file all render
                // Apple's per-file default (AppleRawSource.decode's fallback).
                let honoured = try others.contains(requested)
                    ? oracle(fixture.url, source: source, version: requested, scale: 0.04)
                    : nil
                let actual = source.decode(recipe: recipe, draft: false, scaleFactor: 0.04)
                guard let reference = try honoured
                        ?? oracle(fixture.url, source: source, version: nil, scale: 0.04) else {
                    XCTAssertNil(actual, "\(fixture.name) pin\(requested): Apple's filter forms "
                                     + "no image and Lumen delivered one")
                    return "refused-at-decode"
                }
                try assertPixels(try XCTUnwrap(actual, "\(fixture.name) pin\(requested): "
                                                   + "Lumen refused a decode Apple's filter makes"),
                                 reference: reference,
                                 label: "pin\(requested) \(fixture.name)")
            }
            let pins = requestedPins.map(String.init).joined(separator: Self.comma)
            return "decoded pins=" + pins
        }
    }

    /// A file Apple's filter opens but selects no RAW decoder for (default "",
    /// supported ["None"]: on the lane, the IIQ, X3F, GPR and that OS's X-H2 RAF) is not
    /// a RAW decode, and Lumen refuses it at open (`RawParams.selectsRawDecoder`).
    /// Asserted here so the refusal is checked rather than thrown into `eachFixture`.
    private static func refusedWithoutDecoder(_ apple: CIRAWFilter,
                                              _ fixture: Fixture) -> String? {
        guard !RawParams.selectsRawDecoder(apple.decoderVersion.rawValue) else { return nil }
        XCTAssertThrowsError(try AppleRawSource(url: fixture.url),
                             "\(fixture.name): Apple's filter selects no RAW decoder for "
                                 + "this file and Lumen opened it anyway")
        let supported = apple.supportedDecoderVersions.map(\.rawValue)
            .joined(separator: Self.comma)
        return "refused-no-decoder supported=" + supported
    }

    private func supportsRaw9(_ url: URL) -> Bool {
        CIRAWFilter(imageURL: url)?
            .supportedDecoderVersions.contains(where: AppleRawSource.needsRaw9Boundary) ?? false
    }

    /// Independent platform filter/context, never the materializer under test.
    /// `version` nil is Apple's per-file default. Nil result: the platform will not
    /// open the file, or forms no image from it with these settings.
    private func oracle(_ url: URL, source: AppleRawSource, version: Int?, scale: Float)
        throws -> (image: CIImage, context: CIContext)? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        // Read before any scaled decode: RAW9 can rewrite `nativeSize` afterwards.
        let openedNativeSize = filter.nativeSize
        if let version {
            filter.decoderVersion = try XCTUnwrap(filter.supportedDecoderVersions.first {
                RawParams.decoderNumber($0.rawValue) == version
            })
        }
        filter.scaleFactor = scale
        filter.isDraftModeEnabled = false
        filter.neutralTemperature = Float(source.asShotTemperature)
        filter.neutralTint = Float(source.asShotTint)
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
        // R-2: an outputImage with a null extent from a file opened at 0 x 0 (the
        // corpus's X3F) is the platform forming NO image, which Lumen must refuse too.
        guard let image = filter.outputImage,
              RawDecodeAcceptance.accepts(extent: image.extent,
                                          nativeSize: openedNativeSize) else { return nil }
        return (image,
                AppleRawSource.needsRaw9Boundary(filter.decoderVersion) ? raw9Context : legacyOracleContext)
    }

    private func pixels(_ image: CIImage, context: CIContext, bounds: CGRect) -> [Float] {
        let width = Int(bounds.width), height = Int(bounds.height)
        var result = [Float](repeating: 0, count: width * height * 4)
        result.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: working)
        }
        return result
    }

    private func assertPixels(_ actual: CIImage, reference: (image: CIImage, context: CIContext),
                              bounds: CGRect? = nil, label: String,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.extent, reference.image.extent, label, file: file, line: line)
        let rect = bounds ?? reference.image.extent
        let want = pixels(reference.image, context: reference.context, bounds: rect)
        let got = pixels(actual, context: consumer, bounds: rect)
        XCTAssertEqual(got.count, want.count, file: file, line: line)
        var worst = 0.0, worstAbsolute = 0.0, nonFinite = 0
        for (a, e) in zip(got, want) {
            guard a.isFinite, e.isFinite else { nonFinite += 1; continue }
            let delta = abs(Double(a) - Double(e))
            // Half-float quantization and explicit colour conversion. Alpha is
            // included, so a sandbox/renderer returning all zero cannot pass.
            worst = max(worst, delta / (0.0015 + 0.002 * abs(Double(e))))
            worstAbsolute = max(worstAbsolute, delta)
        }
        XCTAssertEqual(nonFinite, 0, label, file: file, line: line)
        XCTAssertLessThanOrEqual(worst, 1, label + " max absolute error \(worstAbsolute)",
                                 file: file, line: line)
        Self.emit("raw-pixel-check: \(label) samples=\(got.count) maxAbsolute=\(worstAbsolute) normalized=\(worst)")
    }
}
#endif

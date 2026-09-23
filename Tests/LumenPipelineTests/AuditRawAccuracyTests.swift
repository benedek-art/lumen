#if os(macOS)
import CoreGraphics
import CoreImage
import Foundation
import XCTest
import LumenCore
@testable import LumenPipeline

/// Private, opt-in camera corpus. Never commit photographs, sidecars or local paths.
/// Run with LUMEN_AUDIT_RAW_DIR pointing to copies. Logs use ordinal fixture IDs.
final class AuditRawAccuracyTests: XCTestCase {
    private func files() throws -> [URL] {
        guard let path = ProcessInfo.processInfo.environment["LUMEN_AUDIT_RAW_DIR"], !path.isEmpty else {
            throw XCTSkip("LUMEN_AUDIT_RAW_DIR unset — private RAW tests are opt-in")
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { ["arw", "nef", "cr3", "dng", "raf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty, "Configured corpus must contain RAW files")
        return urls
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

    func testUnpinnedSourceUsesTheDecoderAppleSelectedForTheFile() throws {
        for (index, url) in try files().enumerated() {
            try autoreleasepool {
                let apple = try XCTUnwrap(CIRAWFilter(imageURL: url))
                let expected = Int(apple.decoderVersion.rawValue.filter(\.isNumber))
                let source = try AppleRawSource(url: url)
                XCTAssertEqual(source.pinnedDecoderVersion, expected,
                               "An advertised version is not necessarily Apple's selected default")
                let reference = try oracle(url, source: source, version: nil, scale: 0.08)
                let actual = try XCTUnwrap(source.decode(
                    recipe: quietRecipe, draft: false, scaleFactor: 0.08))
                try assertPixels(actual, reference: reference, label: "default fixture\(index + 1)")
            }
        }
    }

    func testNativeDimensionsDoNotDependOnDecoderScaleDraftOrCache() throws {
        for url in try files() {
            let apple = try XCTUnwrap(CIRAWFilter(imageURL: url))
            var versions = [apple.decoderVersion]
            if let raw9 = apple.supportedDecoderVersions.first(where: { $0.rawValue == "9" }),
               raw9 != apple.decoderVersion { versions.append(raw9) }
            for version in versions {
                try autoreleasepool {
                    let source = try AppleRawSource(url: url)
                    let size = source.nativePixelSize
                    let longEdge = Double(max(size.width, size.height))
                    XCTAssertGreaterThan(longEdge, 0)
                    var recipe = quietRecipe
                    recipe.develop.raw.decoderVersion = Int(version.rawValue.filter(\.isNumber))
                    for (scale, draft) in [(0.12, false), (0.25, true), (0.08, false), (0.12, false)] {
                        let image = try XCTUnwrap(source.decode(
                            recipe: recipe, draft: draft, scaleFactor: scale))
                        XCTAssertGreaterThan(image.extent.width, 0)
                        XCTAssertEqual(source.nativePixelSize.width, size.width)
                        XCTAssertEqual(source.nativePixelSize.height, size.height)
                        XCTAssertEqual(source.nativeLongEdge, longEdge)
                        XCTAssertEqual(source.captureMetadata.pixelSize.width, size.width)
                        XCTAssertEqual(source.captureMetadata.pixelSize.height, size.height)
                    }
                    source.releaseDecodes()
                    XCTAssertEqual(source.nativeLongEdge, longEdge)
                }
            }
        }
    }

    func testExplicitRaw9PreviewAndCachePixelsAgreeWithIndependentDecode() throws {
        var tested = 0
        for (index, url) in try files().enumerated() {
            try autoreleasepool {
                guard try supportsRaw9(url) else { return }
                let source = try AppleRawSource(url: url)
                var recipe = quietRecipe
                recipe.develop.raw.decoderVersion = 9
                let reference = try oracle(url, source: source, version: 9, scale: 0.08)
                for pass in 0..<2 {
                    let actual = try XCTUnwrap(source.decode(
                        recipe: recipe, draft: false, scaleFactor: 0.08))
                    try assertPixels(actual, reference: reference,
                                     label: "RAW9 preview fixture\(index + 1) pass\(pass)")
                }
                tested += 1
            }
        }
        try XCTSkipUnless(tested > 0, "No RAW9 support in this corpus/OS")
    }

    /// Fresh source, FIRST native decode, then cache hit: a preview-only fix fails.
    /// Distributed real pixel tiles also prevent opposite errors cancelling in a mean.
    func testFirstNativeRaw9DecodeAndCacheHitHaveCorrectPixels() throws {
        var tested = 0
        for (index, url) in try files().enumerated() {
            try autoreleasepool {
                guard try supportsRaw9(url) else { return }
                let source = try AppleRawSource(url: url)
                var recipe = quietRecipe
                recipe.develop.raw.decoderVersion = 9
                let reference = try oracle(url, source: source, version: 9, scale: 1)
                XCTAssertEqual(source.heldDecodeBytes, 0)
                for pass in 0..<2 {
                    let actual = try XCTUnwrap(source.decode(recipe: recipe, draft: false, scaleFactor: 1))
                    for fraction in [0.25, 0.5, 0.75] {
                        let bounds = CGRect(
                            x: (actual.extent.minX + actual.extent.width * fraction).rounded(),
                            y: (actual.extent.minY + actual.extent.height * fraction).rounded(),
                            width: 32, height: 32)
                        try assertPixels(actual, reference: reference, bounds: bounds,
                                         label: "RAW9 native fixture\(index + 1) pass\(pass) tile\(fraction)")
                    }
                }
                XCTAssertGreaterThan(source.releaseInspectionDecodes(), 0)
                XCTAssertEqual(source.heldDecodeBytes, 0)
                tested += 1
            }
        }
        try XCTSkipUnless(tested > 0, "No RAW9 support in this corpus/OS")
    }

    func testExplicitPinsSurviveSwitchesAndUnsupportedPinUsesDefault() throws {
        var tested = 0
        for (index, url) in try files().enumerated() {
            try autoreleasepool {
                guard try supportsRaw9(url) else { return }
                let apple = try XCTUnwrap(CIRAWFilter(imageURL: url))
                let fallback = try XCTUnwrap(Int(apple.decoderVersion.rawValue.filter(\.isNumber)))
                let source = try AppleRawSource(url: url)
                // Includes explicit8 when supported, a cached9, and an
                // unavailable pin. Pixel comparisons prove the decoder, not just a label.
                var requestedPins = [9]
                if apple.supportedDecoderVersions.contains(where: { $0.rawValue == "8" }) {
                    requestedPins.append(8)
                }
                requestedPins += [fallback, 9, 999_999]
                for requested in requestedPins {
                    var recipe = quietRecipe
                    recipe.develop.raw.decoderVersion = requested
                    let reference = try oracle(url, source: source,
                                               version: requested == 999_999 ? fallback : requested,
                                               scale: 0.04)
                    let actual = try XCTUnwrap(source.decode(
                        recipe: recipe, draft: false, scaleFactor: 0.04))
                    try assertPixels(actual, reference: reference,
                                     label: "pin\(requested) fixture\(index + 1)")
                }
                tested += 1
            }
        }
        try XCTSkipUnless(tested > 0, "No RAW9 support in this corpus/OS")
    }

    private func supportsRaw9(_ url: URL) throws -> Bool {
        try XCTUnwrap(CIRAWFilter(imageURL: url))
            .supportedDecoderVersions.contains { $0.rawValue == "9" }
    }

    /// Independent platform filter/context, never the materializer under test.
    private func oracle(_ url: URL, source: AppleRawSource, version: Int?, scale: Float)
        throws -> (image: CIImage, context: CIContext) {
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
        if let version {
            filter.decoderVersion = try XCTUnwrap(filter.supportedDecoderVersions.first {
                Int($0.rawValue.filter(\.isNumber)) == version
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
        return (try XCTUnwrap(filter.outputImage),
                filter.decoderVersion.rawValue == "9" ? raw9Context : legacyOracleContext)
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
        XCTAssertEqual(actual.extent, reference.image.extent, file: file, line: line)
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
        print("raw-pixel-check: \(label) samples=\(got.count) maxAbsolute=\(worstAbsolute) normalized=\(worst)")
    }
}
#endif

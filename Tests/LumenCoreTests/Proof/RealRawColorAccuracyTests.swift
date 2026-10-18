#if os(macOS)
import Foundation
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Independently checks the shipping S9 math on actual camera sample distributions.
/// This is numeric fidelity to ColorEngine, not camera colorimetric calibration or
/// a claim that uncharted photographs provide known reflectance ground truth.
final class RealRawColorAccuracyTests: XCTestCase {
    func testRegisteredColourControlsAgainstIndependentOracleOnCameraSamples() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["LUMEN_REAL_RAW_DIR"], !input.isEmpty else {
            throw XCTSkip("Private RAW colour accuracy is opt-in")
        }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: input),
            includingPropertiesForKeys: nil).filter { ["arw", "rw2", "dng", "nef", "cr3", "raf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        for (ordinal, file) in files.enumerated() {
            try autoreleasepool {
                let source = try AppleRawSource(url: file)
                var quiet = Recipe(); quiet.develop.denoise.mode = .off
                quiet.develop.detail.capture.auto = false
                let decoded = try XCTUnwrap(source.decode(recipe: quiet, draft: false,
                    scaleFactor: min(1, 256 / source.nativeLongEdge)))
                let buffer = try XCTUnwrap(PipelineRenderer.buffer(from: decoded, context: context))
                XCTAssertTrue(buffer.pixels.allSatisfy(\.isFinite))
                let step = max(1, buffer.count / 256)
                let samples = stride(from: 0, to: buffer.count, by: step).prefix(256).map { index in
                    buffer[index % buffer.width, index / buffer.width]
                }
                let pixels = samples.flatMap { [Float($0.r), Float($0.g), Float($0.b), Float(1)] }
                let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
                let image = CIImage(bitmapData: data, bytesPerRow: pixels.count * 4,
                    size: CGSize(width: samples.count, height: 1), format: .RGBAf, colorSpace: nil)
                let hues = ColorEngine.measureBandMeanHues(buffer)
                var tested = 0, worstRatio = 0.0
                for spec in ProofRegistry.all {
                    for setting in [spec.low, (spec.low + spec.high) / 2, spec.high] {
                        var recipe = Recipe(); spec.apply(&recipe, setting)
                        let engine = ColorEngine(mixer: recipe.develop.mixer,
                            pointColors: recipe.develop.pointColors, color: recipe.develop.color,
                            primaries: recipe.look.primaries, bw: recipe.look.bw, bandMeanHues: hues)
                        guard !engine.isIdentity else { continue }
                        let actual = try XCTUnwrap(PipelineRenderer.buffer(from:
                            RenderGraph.applyColorStage(image, engine.exactStage), context: context))
                        XCTAssertTrue(actual.pixels.allSatisfy(\.isFinite), "photo\(ordinal + 1) \(spec.id)")
                        var worst = 0.0
                        for (i, color) in samples.enumerated() {
                            let expected = engine.apply(color)
                            let scale = max(1, abs(color.r), abs(color.g), abs(color.b),
                                abs(expected.r), abs(expected.g), abs(expected.b))
                            let error = actual[i, 0].maxAbsDifference(expected) / scale
                            // Identical contract to ExactColorStageGPUTests: base f32
                            // bound plus independently measured local conditioning.
                            var gate = 3e-5
                            if error > gate {
                                let epsilon = 1e-6 * scale
                                var condition = 0.0
                                for channel in 0..<3 {
                                    var perturbed = color
                                    if channel == 0 { perturbed.r += epsilon }
                                    else if channel == 1 { perturbed.g += epsilon }
                                    else { perturbed.b += epsilon }
                                    condition = max(condition, engine.apply(perturbed).maxAbsDifference(expected) / epsilon)
                                }
                                gate += condition * 5e-7
                            }
                            worst = max(worst, error / gate)
                        }
                        XCTAssertLessThan(worst, 1, "photo\(ordinal + 1) \(spec.id) \(setting) independent colour accuracy")
                        tested += 1; worstRatio = max(worstRatio, worst)
                    }
                }
                XCTAssertGreaterThan(tested, 100, "A camera test that did not exercise the colour registry proves little")
                print("real-raw-colour: photo\(ordinal + 1) settings=\(tested) samples=\(samples.count) worstGateRatio=\(worstRatio)")
                fflush(stdout)
            }
        }
    }
}
#endif

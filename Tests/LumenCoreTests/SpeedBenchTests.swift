// Benchmarks for the interactive path's CPU half, gated behind LUMEN_BENCH so CI never
// pays for them. The GPU half cannot be measured on the free lane; these are the stages
// that run on the CPU per render call and were never timed.
import XCTest
@testable import LumenCore

final class SpeedBenchTests: XCTestCase {

    private var enabled: Bool {
        guard let raw = ProcessInfo.processInfo.environment["LUMEN_BENCH"] else { return false }
        return !["", "0", "false", "no", "off"].contains(
            raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private func bench(_ name: String, iterations: Int = 20, _ body: () -> Void) {
        body()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(iterations)
        print(String(format: "BENCH %-44@ %9.3f ms", name as NSString, ms))
    }

    func testInteractiveCPUPath() throws {
        try XCTSkipUnless(enabled, "set LUMEN_BENCH=1")

        // A recipe shaped like the owner's: exposure moved, everything else default.
        var recipe = Recipe()
        recipe.develop.tone.exposure = 1.25

        bench("RenderPlan(recipe:) — default recipe") {
            _ = RenderPlan(recipe: Recipe())
        }
        bench("RenderPlan(recipe:) — exposure moved") {
            _ = RenderPlan(recipe: recipe)
        }

        // What a slider drag actually does: a new value every event.
        var i = 0.0
        bench("RenderPlan — a moving slider (cache miss each time)", iterations: 50) {
            i += 0.001
            var r = recipe
            r.develop.tone.exposure = 1.25 + i
            _ = RenderPlan(recipe: r)
        }

        // Colour work that a grade drag re-bakes.
        var graded = recipe
        graded.look.wheels.mid.lum = 0.3
        bench("RenderPlan — grade wheel moved (bakes the colour LUT)") {
            _ = RenderPlan(recipe: graded)
        }

        var vignetted = recipe
        vignetted.look.vignette = -2.0
        bench("RenderPlan — vignette moved") {
            _ = RenderPlan(recipe: vignetted)
        }

        var curved = recipe
        curved.develop.curve.parametric.lights = 20
        bench("RenderPlan — parametric curve moved") {
            _ = RenderPlan(recipe: curved)
        }

        // The denoise plan the GPU stage reads, per frame, at two scales.
        let nr = ClassicalDenoise(ClassicNR(), profile: NoiseProfile.forISO(800))
        bench("ClassicalDenoise.gpuPlan @3212", iterations: 200) {
            _ = nr.gpuPlan(width: 3212, height: 2141, noiseScale: 1)
        }
        bench("ClassicalDenoise.gpuPlan @4096", iterations: 200) {
            _ = nr.gpuPlan(width: 4096, height: 2731, noiseScale: 1)
        }
    }
}

/// The scale gate on S3 (docs/34 §2): the classical bands stop running once the decode's
/// own downsample has taken more of the noise than they would.
final class DenoiseScaleGateTests: XCTestCase {

    private let nr = ClassicalDenoise(ClassicNR(), profile: NoiseProfile.forISO(1600))

    /// At 1:1 and on export nothing changes — this is the promise the gate rests on.
    func testFullScaleIsUntouched() {
        let full = nr.scaled(noiseScale: 1)
        XCTAssertEqual(full.luma, nr.luma)
        XCTAssertEqual(full.chroma, nr.chroma)
        let plan = full.gpuPlan(width: 7008, height: 4672, noiseScale: 1)
        XCTAssertTrue(plan.chromaThresholds.contains { $0 > 0 },
                      "an inspection render must still be denoised")
    }

    /// A fit view of a 33 MP frame on a laptop: scale ≈ 0.46, noiseScale ≈ 0.21. The
    /// owner could not see Off from Classic here, and the downsample is why.
    func testAFitViewDoesNotRunTheBands() {
        let s = 3212.0 / 7008.0
        let scaled = nr.scaled(noiseScale: s * s)
        XCTAssertEqual(scaled.luma, 0)
        XCTAssertEqual(scaled.chroma, 0)
        let plan = nr.gpuPlan(width: 3212, height: 2141, noiseScale: s * s)
        XCTAssertFalse(plan.lumaThresholds.contains { $0 > 0 },
                       "a zero threshold is what makes RenderGraph skip the stage")
        XCTAssertFalse(plan.chromaThresholds.contains { $0 > 0 })
    }

    /// The gate is a scale rule, not a resolution rule: the same pixel count denoises or
    /// does not depending on how much of the sensor it represents.
    func testTheGateFollowsScaleNotPixelCount() {
        let big = nr.scaled(noiseScale: 0.9)      // a near-1:1 crop
        XCTAssertGreaterThan(big.chroma, 0)
        let small = nr.scaled(noiseScale: 0.2)    // the same pixels, whole frame
        XCTAssertEqual(small.chroma, 0)
    }

    /// Hot pixels are single-sample defects, not a band, and they survive the gate.
    func testHotPixelsSurvive() {
        var params = ClassicNR()
        params.hotPixels = 60
        let engine = ClassicalDenoise(params, profile: NoiseProfile.forISO(1600))
        XCTAssertEqual(engine.scaled(noiseScale: 0.2).hotPixels, 60)
    }

    /// The boundary is the named constant, and it is inclusive on the skipping side.
    func testTheBoundaryIsTheNamedConstant() {
        XCTAssertEqual(nr.scaled(
            noiseScale: ClassicalDenoise.contributingNoiseScale).chroma, 0)
        XCTAssertGreaterThan(nr.scaled(
            noiseScale: ClassicalDenoise.contributingNoiseScale + 0.01).chroma, 0)
    }
}

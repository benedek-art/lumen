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

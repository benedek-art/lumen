import XCTest
@testable import LumenCore

/// Editing on a fit preview and saving the full-megapixel file has to produce the same
/// picture. Every stage whose size is a fraction of the long edge holds that; a stage
/// with a fixed-pixel radius cannot.
///
/// This renders the same recipe at two resolutions, box-averages the larger down to the
/// smaller, and compares. Anything that diverges is a stage whose strength depends on
/// how many pixels it was handed rather than on the picture.
final class ScaleHonestyTests: XCTestCase {

    /// Structure at several scales, so a stage tuned to any one of them has something to
    /// act on. Built from the normalized coordinate so the scene is the SAME PICTURE at
    /// every resolution — a scene defined in pixels would diverge on its own and the
    /// test would be measuring the fixture.
    func scene(longEdge: Int) -> ImageBuffer {
        let w = longEdge, h = longEdge * 2 / 3
        return ImageBuffer(width: w, height: h) { u, v in
            let ev = -4.0 + 7.0 * u
            // Coarse, mid and fine modulation as fractions of the frame.
            let coarse = 0.18 * cos(u * 2 * .pi * 3) * cos(v * 2 * .pi * 2)
            let mid = 0.08 * cos(u * 2 * .pi * 14) * cos(v * 2 * .pi * 9)
            let fine = 0.03 * cos(u * 2 * .pi * 48) * cos(v * 2 * .pi * 32)
            let m = 1 + coarse + mid + fine
            // Not neutral: a colour scene exercises the mixer and the wheels too.
            let tint = RGB(1.0 + 0.25 * cos(v * 2 * .pi),
                           1.0,
                           1.0 - 0.25 * cos(v * 2 * .pi))
            return tint * (0.18 * pow(2, ev) * Swift.max(m, 0.02))
        }
    }

    /// Box-average `image` down by an integer factor. Exact, so the comparison measures
    /// the pipeline rather than a resampler.
    func downsample(_ image: ImageBuffer, by factor: Int) -> ImageBuffer {
        let w = image.width / factor, h = image.height / factor
        var out = ImageBuffer(width: w, height: h)
        let n = Double(factor * factor)
        for y in 0..<h {
            for x in 0..<w {
                var acc = RGB(0, 0, 0)
                for dy in 0..<factor {
                    for dx in 0..<factor { acc = acc + image[x * factor + dx, y * factor + dy] }
                }
                out[x, y] = acc * (1 / n)
            }
        }
        return out
    }

    /// Worst per-pixel divergence in sRGB code values, ignoring a one-pixel border where
    /// the two resolutions' edge handling legitimately differs.
    func divergence(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        var worst = 0.0
        for y in 2..<(Swift.min(a.height, b.height) - 2) {
            for x in 2..<(Swift.min(a.width, b.width) - 2) {
                for ch in 0..<3 {
                    let ca = Num.saturate(TransferFunction.srgb.encode(Num.saturate(a[x, y][ch])))
                    let cb = Num.saturate(TransferFunction.srgb.encode(Num.saturate(b[x, y][ch])))
                    worst = Swift.max(worst, abs(ca - cb) * 255)
                }
            }
        }
        return worst
    }

    func measureStage(_ mutate: (inout Recipe) -> Void) -> Double {
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        mutate(&recipe)
        let plan = RenderPlan(recipe: recipe)
        let small = ReferenceRenderer.render(scene(longEdge: 300), plan: plan)
        let large = ReferenceRenderer.render(scene(longEdge: 1200), plan: plan)
        return divergence(small, downsample(large, by: 4))
    }

    /// The colour and tone stages are per-pixel functions, so they are scale-honest by
    /// construction. This is the control: if it drifts, the harness is wrong and every
    /// number below it is meaningless.
    func testThePerPixelStagesAreExactAcrossAFourfoldScaleChange() {
        let baseline = measureStage { _ in }
        print(String(format: "  PERPIXEL %-18@ %.4f", "baseline", baseline))
        XCTAssertLessThan(baseline, 1.0,
                          "a default recipe diverges by \(baseline) code values between "
                              + "300 px and 1200 px — the harness itself is not sound")

        for (name, mutate) in [
            ("exposure + tone", { (r: inout Recipe) in
                r.develop.tone.exposure = 0.6
                r.develop.tone.contrast = 35
                r.develop.tone.highlights = -40
                r.develop.tone.shadows = 30
                r.develop.tone.whites = 15
                r.develop.tone.blacks = -20 }),
            ("colour", { r in
                r.develop.color.vibrance = 40
                r.develop.color.saturation = -15
                r.develop.mixer.bands[0].hue = 30
                r.develop.mixer.bands[5].sat = -50 }),
            ("grading", { r in
                r.look.wheels.shadows = Wheel(hue: 210, sat: 0.5, lum: 0.2)
                r.look.wheels.high = Wheel(hue: 40, sat: 0.4, lum: -0.1)
                r.look.printerLights = PrinterLights(master: 2, r: -1, g: 0, b: 1) }),
            ("curve", { r in
                r.develop.curve.parametric.darks = -40
                r.develop.curve.parametric.lights = 35 }),
            ("vignette", { r in r.look.vignette = -1.2 }),
        ] {
            let d = measureStage(mutate)
            print(String(format: "  PERPIXEL %-18@ %.4f", name, d))
            // Measured 0.39–0.52 against a resample floor of 0.37, so the bar is
            // roughly twice the worst reading and well under anything visible.
            XCTAssertLessThan(d, 1.0,
                              "\(name) diverges by \(d) code values between a 300 px "
                                  + "preview and a 1200 px render — a per-pixel stage "
                                  + "must not depend on how many pixels it was handed")
        }
    }

    /// The spatial stages size themselves off the long edge on purpose, so the same
    /// setting means the same amount of the picture at every resolution. Looser than the
    /// per-pixel bar because a band-limited operator genuinely cannot survive a 4x
    /// resample exactly — but a stage with a FIXED pixel radius would be far worse, and
    /// that is what this catches.
    func testTheSpatialStagesTrackTheFrameRatherThanThePixelCount() {
        for (name, mutate) in [
            ("texture", { (r: inout Recipe) in r.develop.detail.texture = 60 }),
            ("clarity", { r in r.develop.detail.clarity = 50 }),
            ("dehaze", { r in r.develop.detail.dehaze = 45 }),
        ] {
            let d = measureStage(mutate)
            print(String(format: "  SPATIAL  %-18@ %.4f", name, d))
            // Measured: texture 2.77, clarity 1.90, dehaze 3.27. Clarity was 7.38
            // before its pyramid depth started tracking the long edge.
            XCTAssertLessThan(d, 5,
                              "\(name) diverges by \(d) code values across a 4x scale "
                                  + "change — its radius is not tracking the long edge")
        }
    }

    /// Clarity's pyramid depth tracks the frame: one level per doubling, so the local
    /// Laplacian reaches the same FRACTION of the picture at every resolution.
    func testTheClarityPyramidTracksTheLongEdge() {
        // One level per doubling, over the range a real file spans.
        XCTAssertEqual(DetailEngine.pyramidLevels(longEdge: 2560),
                       DetailEngine.basePyramidLevels)
        XCTAssertEqual(DetailEngine.pyramidLevels(longEdge: 5120),
                       DetailEngine.basePyramidLevels + 1)
        XCTAssertEqual(DetailEngine.pyramidLevels(longEdge: 1280),
                       DetailEngine.basePyramidLevels - 1)

        // Monotone, and never deep enough to ask for a pyramid the image cannot carry
        // or shallow enough to leave the stage with nothing to remap.
        var previous = 0
        for longEdge in [1, 64, 256, 640, 1280, 2560, 5120, 11648, 40000] {
            let levels = DetailEngine.pyramidLevels(longEdge: longEdge)
            XCTAssertGreaterThanOrEqual(levels, 2, "\(longEdge) px")
            XCTAssertLessThanOrEqual(levels, 9, "\(longEdge) px")
            XCTAssertGreaterThanOrEqual(levels, previous, "\(longEdge) px went shallower")
            previous = levels
        }
        XCTAssertEqual(DetailEngine.pyramidLevels(longEdge: 0),
                       DetailEngine.pyramidLevels(longEdge: 1),
                       "a zero long edge must not produce a different answer to one pixel")
    }

    /// What the whole thing is for: a full edit, made once, rendering as the same picture
    /// at both sizes.
    func testACompleteEditSurvivesAFourfoldScaleChange() {
        let d = measureStage { r in
            r.develop.tone.exposure = 0.4
            r.develop.tone.contrast = 25
            r.develop.tone.highlights = -45
            r.develop.tone.shadows = 35
            r.develop.tone.whites = 15
            r.develop.tone.blacks = -15
            r.develop.color.vibrance = 30
            r.develop.curve.parametric.darks = -25
            r.develop.curve.parametric.lights = 20
            r.develop.detail.texture = 40
            r.develop.detail.clarity = 25
            r.look.wheels.shadows = Wheel(hue: 220, sat: 0.35, lum: 0.1)
            r.look.vignette = -0.8
            r.develop.geometry.crop = Crop(x: 0.05, y: 0.08, w: 0.86, h: 0.8)
            r.develop.geometry.angle = 2.5
        }
        print(String(format: "  COMPLETE EDIT %.4f", d))
        // Measured 2.13, down from 3.98 before the Clarity fix.
        XCTAssertLessThan(d, 4,
                          "a complete edit diverges by \(d) code values between a 300 px "
                              + "preview and a 1200 px render")
    }
}

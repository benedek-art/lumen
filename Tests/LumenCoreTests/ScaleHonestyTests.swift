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
            // S12 was missing from this list for its whole life, and it was the one
            // stage on it that failed. The omission was half of E2-04: this is the
            // exact harness for "a fixed pixel radius", `RenderGraph.swift` names
            // SHARPENING in its own doctrine sentence as a stage that sizes itself off
            // the long edge, and nothing here ever asked whether it did.
            // `testACompleteEditSurvivesAFourfoldScaleChange` sets fourteen fields and
            // not `detail.sharpen.amount` either, so the whole file went green with S12
            // denominated in render pixels and a 7008 px export receiving 7% of what
            // the fit preview was judged on.
            //
            // THE ENTRY CARRIES A RADIUS AT THE TOP OF ITS TRAVEL, and the number that
            // settled it was measured HERE rather than borrowed. E2-04's own entry was
            // specified as Radius 2.0 on the strength of 6.07 code values — a figure
            // taken on S12 ALONE, sRGB-encoded, with the display transform left out.
            // Through this file's actual metric the same setting reads 4.7001, which is
            // UNDER the bar of 5: the roster entry the audit prescribed would have gone
            // green on the defect it was written to catch. Measured on the unwired
            // engine, this harness, both sizes:
            //
            //     radius      1.0     2.0     2.5     3.0
            //     Amount 100  3.10    4.70    5.25    5.80
            //     Amount 150  4.45    6.93    7.87    8.74
            //
            // 3.0 at Amount 100 is the mildest setting that reads the defect (5.80),
            // and it is the right one on the merits rather than by elimination: the
            // radius is the control that sets the SIZE, so a scale-honesty entry has to
            // push THAT and not the amount of a radius it left where the reading hides.
            // Wired, the same setting reads PENDING_WIRED.
            //
            // A number taken on a stage in isolation is not the number a roster entry
            // will read, and the difference here is the whole distance between catching
            // a 14x defect and shipping past it.
            ("sharpen", { r in
                r.develop.detail.sharpen.amount = 100
                r.develop.detail.sharpen.radius = 3.0
            }),
        ] {
            let d = measureStage(mutate)
            print(String(format: "  SPATIAL  %-18@ %.4f", name, d))
            // Measured, through this metric: texture 2.74, clarity 1.84, dehaze 3.29,
            // sharpen PENDING_WIRED. Clarity was 7.38 before its pyramid depth started tracking
            // the long edge; sharpen was 5.80 before its radius did, on the same run of
            // the same file, which is the entry above doing its job.
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

    /// Sharpening's radius tracks the frame on the same reference and by the same rule
    /// Clarity's pyramid and Texture's band do — and its fine band does not JUMP as the
    /// preview ladder steps, which is the one place the three conventions differ.
    func testTheSharpenRadiusTracksTheLongEdgeWithoutSteppingAtALadderRung() {
        XCTAssertEqual(SpatialOps.spatialReferenceLongEdge,
                       DetailEngine.pyramidReferenceLongEdge,
                       "the presence stages and sharpening quote their sizes at "
                           + "different reference frames, so one setting means two "
                           + "different fractions of the same picture")

        // At the reference the fix is the identity: a 2560 px render is exactly what
        // every one of these stages was tuned at, and must not have moved.
        XCTAssertEqual(SpatialOps.frameDenominatedSigma(radius: 1.5, longEdge: 2560),
                       1.5, accuracy: 1e-12)
        // One doubling of the frame is one doubling of the radius, unclamped in both
        // directions: a sigma has no rungs to run out of (see `frameScale`).
        XCTAssertEqual(SpatialOps.frameDenominatedSigma(radius: 1.0, longEdge: 5120),
                       2.0, accuracy: 1e-12)
        XCTAssertEqual(SpatialOps.frameDenominatedSigma(radius: 1.0, longEdge: 320),
                       0.125, accuracy: 1e-12)
        XCTAssertEqual(SpatialOps.frameDenominatedSigma(radius: 1.0, longEdge: 0),
                       SpatialOps.frameDenominatedSigma(radius: 1.0, longEdge: 1),
                       accuracy: 1e-12,
                       "a zero long edge must not produce a different answer to one pixel")

        // The band index is continuous and monotone, floors at the finest scale a
        // sampled image has, and tops out where `DetailEngine.bandCenter`'s own
        // `clamp(log2(longEdge/2560), -1, 2)` does — 10240 px.
        let levels = DetailEngine.waveletLevels
        XCTAssertEqual(SpatialOps.fineBandLevel(longEdge: 2560, levels: levels), 0,
                       accuracy: 1e-12)
        XCTAssertEqual(SpatialOps.fineBandLevel(longEdge: 5120, levels: levels), 1,
                       accuracy: 1e-12)
        XCTAssertEqual(SpatialOps.fineBandLevel(longEdge: 10240, levels: levels), 2,
                       accuracy: 1e-12)
        XCTAssertEqual(SpatialOps.fineBandLevel(longEdge: 40000, levels: levels), 2,
                       accuracy: 1e-12, "the band left the stack it indexes into")
        var previous = -1.0
        for longEdge in [1, 64, 640, 1280, 2560, 3619, 3621, 5120, 11648, 40000] {
            let level = SpatialOps.fineBandLevel(longEdge: longEdge, levels: levels)
            XCTAssertGreaterThanOrEqual(level, previous, "\(longEdge) px went finer")
            XCTAssertLessThanOrEqual(level, Double(levels - 2), "\(longEdge) px")
            previous = level
        }

        // The rung that matters. `pyramidLevels` may round because one pyramid level of
        // Clarity is barely visible; a rounded sharpening band puts a whole octave step
        // at 2560·√2, and measured on `fractionalTexture` at Radius 2.0 the rounded form
        // jumps 7.20 -> 8.75 code values (+21.6%) between these two sizes. Blended, both
        // read 7.977 — and the level difference below is the 0.0008 the sizes ask for.
        let below = SpatialOps.fineBandLevel(longEdge: 3619, levels: levels)
        let above = SpatialOps.fineBandLevel(longEdge: 3621, levels: levels)
        XCTAssertEqual(above - below, 0.0008, accuracy: 0.0005,
                       "the fine band moved by \(above - below) of a level across two "
                           + "pixels of render size — it has been rounded to an octave "
                           + "and the picture now steps as the preview ladder does")
    }

    // MARK: - S12 sharpening

    /// A texture whose feature size is a fixed FRACTION of the picture — a sinusoid of
    /// period `longEdge / 200`, so the same photograph is in front of the stage at every
    /// render size and the only thing that changes is how densely it is sampled.
    ///
    /// **Why not `ProofFrames.stepEdge`, which is what three of the five sharpen proof
    /// records are taken on: a hard step cannot express a scale-dependent sharpener,
    /// because a step has no scale.** `lum − G_σ(lum)` at an ideal edge peaks at a
    /// fraction of the step height that does not depend on σ at all: widening the blur
    /// widens the rim without raising it, so the amplitude a rim metric reads is the
    /// same number at any radius and at any resolution. Measured, at Amount 30 (below
    /// the clip, see the next paragraph), the bright rim is 27.1733 code values at 128,
    /// 1600, 4096 and 7008 px — identical to four decimals.
    ///
    /// On that frame at the settings the records actually sweep it is worse than
    /// scale-free, it is saturated. The step's bright side is `0.18 · 2² = 0.72`, which
    /// is sRGB code 220.586; any Amount at or above **38** pushes the rim past 1.0, so
    /// the reading pins at `255 − 220.586 = 34.414` — the same 34.414 at 128, 1600, 4096
    /// and 7008 px, and the same 34.414 at Amount 40 and at Amount 150. It is a property
    /// of the white point, not of the photograph. A frame answers the question it can
    /// express; this one was answering "where is white" while the harness read it as
    /// "how much did the stage do", which is how a 14x defect sat under five green
    /// records for the life of the file.
    func fractionalTexture(longEdge: Int) -> ImageBuffer {
        let period = Double(longEdge) / 200.0
        return ImageBuffer(width: longEdge, height: 32) { u, _ in
            RGB(gray: 0.18 * (1 + 0.20 * sin(2 * .pi * u * Double(longEdge) / period)))
        }
    }

    /// Peak-to-peak sRGB contrast across the middle row, away from the border.
    func rowContrast(_ image: ImageBuffer) -> Double {
        let y = image.height / 2
        var lo = Double.infinity, hi = -Double.infinity
        for x in 16..<(image.width - 16) {
            let c = Num.saturate(TransferFunction.srgb.encode(Num.saturate(image[x, y].g)))
            lo = Swift.min(lo, c)
            hi = Swift.max(hi, c)
        }
        return (hi - lo) * 255
    }

    /// The contrast S12 ADDS to a feature that is 1/200 of the picture wide, in sRGB
    /// code values, at one render size. The stage alone — no display transform — so the
    /// number is the sharpener and nothing else.
    func sharpeningAdded(longEdge: Int, radius: Double) -> Double {
        let frame = fractionalTexture(longEdge: longEdge)
        let node = DetailEngine.Decomposition(
            image: frame,
            workingRadius: Swift.max(Int(Double(longEdge) * 0.02), 3))
        let sharpened = DetailEngine.applySharpen(
            frame, params: ManualSharpen(amount: 100, radius: radius), decomposition: node)
        return rowContrast(sharpened) - rowContrast(frame)
    }

    /// Sharpening set on a fit preview has to arrive in the delivered file.
    ///
    /// This is the measurement E2-04 was found by and the one the roster entry above
    /// cannot make: the roster compares a 300 px render against a 1200 px one, and BOTH
    /// of those sit below the 2560 px reference the frame-denominated stages are quoted
    /// at, so a stage could pin at the reference floor at both sizes and pass. Here the
    /// two sizes straddle it — 1600 px is a fit preview and 6400 px is a delivered file
    /// — and the assertion is on the RATIO, pinned to the number it measures rather than
    /// to its direction, because "the export got more than the preview" was true of the
    /// broken stage too.
    ///
    /// Measured, Amount 100 / Radius 2.0 / Detail 25:
    ///
    ///     added contrast      1600 px    6400 px    ratio
    ///     render pixels       13.583      1.537     0.113
    ///     the picture          8.592      7.880     0.917
    ///
    /// The denomination itself lives in `SpatialOps.frameDenominatedSigma` and
    /// `SpatialOps.fineDetailBand`, and `DetailEngine.applySharpen` reads them at two
    /// call sites — the `gaussianBlur` sigma and the `d.details[0] + 0.5 * d.details[1]`
    /// band. Both paths have to read them or this reads 0.113; `RenderGraph.applySharpen`
    /// is the GPU twin and takes the same two changes, which it now has.
    ///
    /// The bound is on the RATIO and it is two-sided, which is the whole point: "the
    /// export got more than the preview" was true of the broken stage too, so a
    /// one-sided assertion would have passed on the defect. A frame-denominated stage
    /// lands near 1 from whichever side the resampling puts it on.
    func testSharpeningMeansTheSameFractionOfThePictureAtEitherRenderSize() {
        let preview = sharpeningAdded(longEdge: 1600, radius: 2.0)
        let delivered = sharpeningAdded(longEdge: 6400, radius: 2.0)
        print(String(format: "  SHARPEN  1600 px %.4f  6400 px %.4f  ratio %.4f",
                     preview, delivered, delivered / preview))
        // The stage has to have DONE something at the preview size, or the ratio below
        // is one small number over another and means nothing.
        XCTAssertGreaterThan(preview, 2.9,
                             "S12 added \(preview) code values at 1600 px, which is "
                                 + "under the floor docs/20 calls invisible — this "
                                 + "measures nothing")
        XCTAssertEqual(delivered / preview, 0.92, accuracy: 0.10,
                       "sharpening set on a 1600 px fit preview arrives in a 6400 px "
                           + "delivered file at \(delivered / preview) of its strength "
                           + "(\(preview) code values against \(delivered)). Denominated "
                           + "in render pixels this reads 0.113 — the radius and the "
                           + "fine band are sized off the buffer instead of off the "
                           + "picture, so the photographer set sharpening on a "
                           + "photograph and got it on a grid")
    }

    /// Masks are normalized to the frame, so a gradient placed on a fit preview has to
    /// select the same part of the picture in the full-resolution export.
    ///
    /// This is the half of "edit on a preview, save the full file" that a slider sweep
    /// cannot reach: the adjustment can be perfectly scale-honest and still land in the
    /// wrong place if the SELECTION moves.
    func testAMaskSelectsTheSamePartOfThePictureAtEitherResolution() {
        func masked(_ kind: MaskKind, _ configure: (inout MaskComponent) -> Void) -> Double {
            var component = MaskComponent(op: .add, kind: kind)
            configure(&component)
            var adjust = LocalAdjust()
            adjust.exposure = 1.2
            adjust.sat = -60
            let mask = Mask(name: "m", components: [component], adjust: adjust)
            let d = measureStage { $0.masks = [mask] }
            print(String(format: "  MASK     %-18@ %.4f", kind.rawValue, d))
            return d
        }

        let linear = masked(.linear) { $0.line = [0.2, 0.15, 0.75, 0.85] }
        // Measured 0.43, 0.62 and 0.41 against a resample floor of 0.37 — masks are
        // normalized, so they sit essentially at the floor. The bar is twice the worst.
        XCTAssertLessThan(linear, 1.5,
                          "a linear gradient mask lands \(linear) code values apart "
                              + "between a 300 px preview and a 1200 px render")

        let radial = masked(.radial) {
            $0.center = [0.45, 0.55]
            $0.radii = [0.3, 0.22]
            $0.rotation = 20
            $0.feather = 40
        }
        XCTAssertLessThan(radial, 1.5,
                          "a radial mask lands \(radial) code values apart across a 4x "
                              + "scale change")

        let luma = masked(.lumaRange) { $0.lo = 0.15; $0.hi = 0.6 }
        XCTAssertLessThan(luma, 1.5,
                          "a luminance-range mask lands \(luma) code values apart "
                              + "across a 4x scale change")
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

    /// Film grain has the same amplitude at every render size — and a resample after
    /// the fact does NOT take much of it away, which is the measurement FILM-08's
    /// premise needed and never had.
    ///
    /// This file swept tone, colour, grade, curve, presence and vignette and touched
    /// film nowhere, so nothing here ever looked at grain across a scale change. The
    /// audit's reading was that `PipelineRenderer.export` grained at decode resolution
    /// and then resampled to the target, so a 6000 px render delivered at 2048
    /// "averages roughly 9 grain samples per output pixel, cutting grain sigma about
    /// 3x". Measured here, on the reference path, that estimate is wrong by an order of
    /// magnitude, for two reasons the estimate did not account for:
    ///
    ///   - `plateScale` anchors the grain's footprint to the render's own long edge, so
    ///     the 6000 px render's grain is already about 3x coarser IN PIXELS. Resampling
    ///     by 3 lands the same structure at the same relative size rather than
    ///     averaging independent samples.
    ///   - the plate is four octaves of value noise with amplitudes 1, ½, ¼, ⅛
    ///     (`FilmGrainProfile.plate`), so most of its energy is in its COARSEST octave,
    ///     which a box average barely touches.
    ///
    /// Measured σ ratios of "render at k·N, average down to N" against "render at N",
    /// flat field, Portra 400, grain 100:
    ///
    ///     k                        2       3       4       6
    ///     plate at the 0.5 floor  0.966   0.926   0.859   0.780
    ///     plate scaling freely    0.99 at k = 3 (scale 1.600 -> 0.533)
    ///
    /// So the loss is 1% where the plate scales freely — the common export — and up to
    /// 22% where the render's own grain has hit the half-pixel floor and the average
    /// eats the finest octaves. Real, worth removing, and not the "visibly less grain"
    /// the audit expected. The reason the export ordering was still changed is that
    /// σ is not the only thing that has to match: at the floor the delivered PATTERN
    /// lands at a different spatial frequency from the preview's, which the assertions
    /// here cannot see. That is `testGrainIsAppliedOnTheGridThatIsDelivered` in the
    /// macOS suite.
    func testFilmGrainHasTheSameAmplitudeAtEveryRenderSize() {
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        // Grain size 2.0 — the top of the panel's range — so the plate scales freely at
        // 1200 px (0.800) rather than sitting on the half-pixel floor at both sizes,
        // which would make the comparison below true by construction.
        recipe.look.filmLab = FilmLab(stock: "lumen/portra400", amount: 100,
                                      grain: FilmGrain(size: 2.0, amount: 100))
        let plan = RenderPlan(recipe: recipe)
        guard let chain = plan.filmChain else {
            return XCTFail("no film chain, so every number below is measuring an "
                               + "ungrained picture against another ungrained picture")
        }

        // FLAT, so all the variance in the output is grain and nothing else.
        func flat(longEdge: Int) -> ImageBuffer {
            ImageBuffer(width: longEdge, height: longEdge * 2 / 3) { _, _ in
                RGB(gray: 0.18)
            }
        }
        /// Mean and standard deviation of the green channel, away from the border where
        /// the box average has less to average.
        func statistics(_ image: ImageBuffer) -> (mean: Double, sigma: Double) {
            let inset = 4
            var sum = 0.0, sumSquares = 0.0, count = 0.0
            for y in inset..<(image.height - inset) {
                for x in inset..<(image.width - inset) {
                    let v = image[x, y].g
                    sum += v
                    sumSquares += v * v
                    count += 1
                }
            }
            guard count > 1 else { return (0, 0) }
            let mean = sum / count
            return (mean, Swift.max(sumSquares / count - mean * mean, 0).squareRoot())
        }

        let small = statistics(ReferenceRenderer.render(flat(longEdge: 400), plan: plan))
        let large = ReferenceRenderer.render(flat(longEdge: 1200), plan: plan)
        let big = statistics(large)
        let resampled = statistics(downsample(large, by: 3))
        let scaleSmall = chain.grain.plateScale(longEdgePixels: 400,
                                                printSizeInches: chain.printLongEdgeInches)
        let scaleLarge = chain.grain.plateScale(longEdgePixels: 1200,
                                                printSizeInches: chain.printLongEdgeInches)
        print(String(format: "  GRAIN sigma 400 %.5f (plate %.3f)  1200 %.5f (plate "
                         + "%.3f)  1200->400 %.5f  mean %.4f",
                     small.sigma, scaleSmall, big.sigma, scaleLarge, resampled.sigma,
                     small.mean))

        // The two sizes must not have landed on the same plate scale, or the first
        // assertion below is comparing a number with itself.
        XCTAssertGreaterThan(scaleLarge, scaleSmall * 1.2,
                             "both renders scaled the plate by \(scaleSmall) — this "
                                 + "test proves nothing until they differ")
        // Grain has to be DOING something, or every comparison below is between a pair
        // of zeros: the shape of the green test `testWhatCIGaussianBlurRadiusMeans` is.
        XCTAssertGreaterThan(small.sigma, 0.02 * small.mean,
                             "grain moved \(small.sigma) on a mean of \(small.mean) — "
                                 + "under 2% of the level is not a film grain, and "
                                 + "nothing below this line means anything")

        // The amplitude does not depend on how many pixels the render has. Measured
        // 0.02392 at 400 px and 0.02377 at 1200 px, 0.6% apart across a 1.5x change in
        // plate scale.
        XCTAssertEqual(big.sigma, small.sigma, accuracy: 0.10 * small.sigma,
                       "grain measured \(big.sigma) at 1200 px against \(small.sigma) "
                           + "at 400 px — the amplitude has picked up a dependence on "
                           + "the render's pixel count, and the whole print-anchored "
                           + "grain model rests on it not having one")

        // And the resample keeps most of it: 0.02394 -> 0.02307, a ratio of 0.964
        // where the audit expected 0.33. Two-sided on purpose: the floor catches a
        // plate that has stopped being fractal or a `plateScale` that has stopped
        // tracking the long edge — either would make independent samples of it average
        // away toward 1/3 here — and the ceiling catches a resampler that has stopped
        // averaging at all, which would mean the harness is not measuring what it says.
        let ratio = resampled.sigma / small.sigma
        XCTAssertGreaterThan(ratio, 0.6,
                             "a 3x average took grain from \(small.sigma) to "
                                 + "\(resampled.sigma) — far more than the 0.964 "
                                 + "measured when this was written")
        XCTAssertLessThan(ratio, 1.02,
                          "a 3x average did not attenuate grain at all (\(ratio)), so "
                              + "this harness is not averaging anything")
    }
}

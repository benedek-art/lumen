// KernelGoldenTests.swift
// The tests that make the GPU path trustworthy from a machine that has no GPU.
//
// Every custom kernel has a Swift twin in LumenCore. These tests compile the kernels,
// render synthetic frames through the real Core Image graph, pull the pixels back, and
// compare against the reference implementation. That is the whole verification story
// for the shader surface: if a kernel stops matching its reference, this suite says so
// on the next push, not after a shoot.
//
// The tolerances are stage-declared (docs/14 §8.1). Where a table is involved they
// also bound its interpolation error, which is the honest cost of the bake-and-fetch
// architecture and should be measured rather than assumed.

#if os(macOS)

import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class KernelGoldenTests: XCTestCase {

    /// Working-space context: everything renders in extended linear Rec.2020, and
    /// pixels come back as raw floats with no colour conversion in the way.
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) as Any,
        .workingFormat: CIFormat.RGBAf,
    ])

    // MARK: - Dehaze must not repaint the sky

    /// Dehaze scales the colour, it does not repaint it.
    ///
    /// The shipping kernel used to recombine per channel — `(I − A)/t + A` — which is a
    /// different scale factor per channel and therefore a hue rotation. Measured
    /// outside this suite on a veiled blue sky under a warm veil, that form moved the
    /// hue by 13.4°, which is the magenta cast docs/06 calls impossible by
    /// construction. It was impossible only on `ReferenceRenderer`, which renders no
    /// user pixels; this is the path every preview and every export takes.
    ///
    /// A single luminance ratio is a pure multiply, so hue survives exactly. The bar is
    /// 1° rather than 0 because the read-back is f32 through a GPU and the input hues
    /// are computed in double.
    func testDehazeDoesNotRotateHue() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 32, height = 32
        // A veiled blue with a gradient, so the dark channel is not constant and the
        // transmission map has something to vary over.
        let source = ImageBuffer(width: width, height: height) { u, v in
            RGB(0.26 + 0.10 * u, 0.34 + 0.06 * v, 0.52 + 0.06 * u)
        }
        let input = ciImage(from: source)
        let output = RenderGraph.applyDehaze(input, amount: 60, longEdge: width)

        guard let before = readBack(input, width: width, height: height),
              let after = readBack(output, width: width, height: height)
        else { return XCTFail("dehaze render failed") }

        var worstShift = 0.0
        var moved = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let a = before[x, y], b = after[x, y]
                moved = Swift.max(moved, a.maxAbsDifference(b))
                let ha = OKLabTransform.working.toLCh(a).h
                let hb = OKLabTransform.working.toLCh(b).h
                var delta = abs(hb - ha)
                if delta > 180 { delta = 360 - delta }
                worstShift = Swift.max(worstShift, delta)
            }
        }
        // It has to have DONE something, or hue preservation is trivially true.
        XCTAssertGreaterThan(moved, 0.01,
                             "dehaze changed nothing, so this proves nothing")
        XCTAssertLessThan(worstShift, 1.0,
                          "dehaze rotated hue by \(worstShift)° — the recombination is "
                              + "per-channel again, not a luminance ratio")
    }

    // MARK: - The GPU grain plate carries three layers, not one grey one

    /// Pearson correlation, for the plate tests below.
    private func correlation(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(Swift.min(a.count, b.count))
        guard n > 1 else { return 0 }
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<Int(n) {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        let den = (da * db).squareRoot()
        return den > 1e-18 ? num / den : 0
    }

    private func plateChannels(_ image: CIImage, width: Int, height: Int)
        -> [[Double]]? {
        guard let buffer = readBack(image, width: width, height: height) else { return nil }
        var out: [[Double]] = [[], [], []]
        for y in 0..<height {
            for x in 0..<width {
                let c = buffer[x, y]
                out[0].append(Double(c.r)); out[1].append(Double(c.g))
                out[2].append(Double(c.b))
            }
        }
        return out
    }

    /// The plate the GPU samples must carry three independent layers on a colour stock.
    ///
    /// `lumenGrain` already reads `noise.rgb` per channel — it was being handed a plate
    /// with the same value written into all three. This is the GPU twin of
    /// `EngineIntegrationTests.testColourStockGrainsEachLayerIndependently`, and it
    /// exists because there was no GPU grain golden at all: the reference path could be
    /// fixed and the shipping path left grey with nothing failing.
    func testGrainPlateCarriesThreeLayersOnAColourStock() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 192, height = 192
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let chain = FilmChain(FilmChain.defaultRecipe(for: FilmStock.portra400),
                              displayWhite: 1.0)
        guard let plate = PipelineRenderer.grainPlate(film: chain, extent: extent),
              let channels = plateChannels(plate, width: width, height: height)
        else { return XCTFail("no grain plate") }

        // Each channel has to carry real noise before its independence means anything.
        for c in 0..<3 {
            let mean = channels[c].reduce(0, +) / Double(channels[c].count)
            let variance = channels[c].map { ($0 - mean) * ($0 - mean) }
                .reduce(0, +) / Double(channels[c].count)
            XCTAssertGreaterThan(variance.squareRoot(), 1e-4,
                                 "plate channel \(c) is flat, so this proves nothing")
        }
        for (i, j) in [(0, 1), (0, 2), (1, 2)] {
            let r = correlation(channels[i], channels[j])
            XCTAssertLessThan(abs(r), 0.6,
                              "plate channels \(i) and \(j) correlate at \(r) — the GPU "
                                  + "is still packing one noise field into all three "
                                  + "layers")
        }
    }

    /// And exactly one layer on a monochrome stock: no dye layers, no coloured speckle.
    func testGrainPlateIsGreyOnAMonochromeStock() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 128, height = 128
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        XCTAssertTrue(FilmStock.triX400.monochrome, "this test needs a monochrome stock")
        let chain = FilmChain(FilmChain.defaultRecipe(for: FilmStock.triX400),
                              displayWhite: 1.0)
        guard let plate = PipelineRenderer.grainPlate(film: chain, extent: extent),
              let channels = plateChannels(plate, width: width, height: height)
        else { return XCTFail("no grain plate") }

        var worst = 0.0
        for i in 0..<channels[0].count {
            worst = Swift.max(worst, abs(channels[0][i] - channels[1][i]))
            worst = Swift.max(worst, abs(channels[0][i] - channels[2][i]))
        }
        XCTAssertLessThan(worst, 1e-5,
                          "a monochrome stock's plate differs between channels by "
                              + "\(worst) — its grain would be coloured")
        let mean = channels[0].reduce(0, +) / Double(channels[0].count)
        let variance = channels[0].map { ($0 - mean) * ($0 - mean) }
            .reduce(0, +) / Double(channels[0].count)
        XCTAssertGreaterThan(variance.squareRoot(), 1e-4,
                             "the monochrome plate is flat, so this proves nothing")
    }

    // MARK: - A mask, through the graph that ships

    /// The shipping path's local stages, with a real mask, against the reference.
    ///
    /// An independent audit found that NOTHING in this suite put a mask through
    /// `RenderGraph`. `applyLocal`, `applyLocalCurves`, `LocalCurvePlan`, `maskImages`
    /// and the orientation of a mask raster in Core Image's y-up space were
    /// collectively unasserted: delete the local-curve call in the graph and the whole
    /// suite stayed green while every preview and every export silently lost the second
    /// tap. Whole-mask invert escaped only because it lives in `MaskRaster.combine`,
    /// which the CPU tests cover — which is why it scored 70 and the curve did not.
    ///
    /// This is the missing test. A linear gradient mask so the alpha varies across the
    /// frame — a uniform one would pass for a mask that selects everything, which is a
    /// failure this project has shipped — carrying both a scene-referred exposure lift
    /// and a display-referred point curve, which are the two taps that run at different
    /// stages and could not be told apart by a single-tap test.
    func testAMaskReachesPixelsThroughTheGraph() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 64, height = 32
        let source = texturedTestImage(width: width, height: height)

        func maskedRender(exposure: Double, curve: CurveSet?)
            -> (gpu: ImageBuffer, reference: ImageBuffer)? {
            var mask = Mask(id: "m1", name: "grad")
            var component = MaskComponent(op: .add, kind: .linear)
            // VERTICAL, deliberately. `texturedTestImage` is a horizontal ramp of about
            // twenty stops and is constant down each column, so a left-to-right mask put
            // its selected end exactly where the picture is already in the highlight
            // rolloff — a full +1 EV under alpha 1 moved the output by 0.0059, and the
            // test read that as "the local stages are not reaching pixels" when what it
            // had actually built was a mask whose bright end the display transform
            // flattens. Running the gradient down the frame instead means any
            // difference between two rows of ONE column is the mask and nothing else.
            component.line = [0.5, 0, 0.5, 1]
            mask.components = [component]
            mask.adjust.exposure = exposure
            mask.adjust.curve = curve

            var recipe = Recipe()
            recipe.masks = [mask]
            // `Recipe()` denoises — chroma defaults to 25 — and the graph runs S3 while
            // `ReferenceRenderer.render` starts at S6. Comparing them on a default
            // recipe measures a stage this test is not about.
            recipe.develop.denoise.mode = .off
            let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)

            let alpha = MaskRaster.combine(mask: mask,
                                           size: (width: width, height: height))
            guard let alphaImage = PipelineRenderer.image(
                from: alpha,
                targetExtent: CGRect(x: 0, y: 0, width: width, height: height))
            else { return nil }
            var graph = RenderGraph()
            graph.maskImages[mask.id] = alphaImage
            let output = graph.build(ciImage(from: source), plan: plan,
                                     options: RenderGraph.Options(longEdge: width))
            guard let gpu = readBack(output, width: width, height: height) else {
                return nil
            }
            return (gpu, ReferenceRenderer.render(source, plan: plan))
        }

        // ---- Tap one: the scene-referred exposure lift, in S11. ----
        //
        // Asserted exactly, because nothing here is baked: the graph and the reference
        // both multiply by the same gain under the same alpha, so a divergence means
        // the mask is not reaching S11, or is reaching it upside down.
        guard let lift = maskedRender(exposure: 1.0, curve: nil) else {
            return XCTFail("masked render failed")
        }
        var worst = 0.0
        var worstAt = (0, 0)
        for y in 0..<height {
            for x in 0..<width {
                let d = lift.reference[x, y].maxAbsDifference(lift.gpu[x, y])
                if d > worst { worst = d; worstAt = (x, y) }
            }
        }
        XCTAssertLessThan(worst, 0.02,
                          "a masked exposure lift diverged from the reference by "
                              + "\(worst) at \(worstAt)")

        // The mask must have a GRADIENT: one that selects everything, or nothing,
        // renders the same wrong picture on both paths and passes the check above.
        var plainRecipe = Recipe()
        plainRecipe.develop.denoise.mode = .off
        let plainPlan = RenderPlan(recipe: plainRecipe, lutSize: LUT3D.exportSize)
        guard let plain = readBack(
            RenderGraph().build(ciImage(from: source), plan: plainPlan,
                                options: RenderGraph.Options(longEdge: width)),
            width: width, height: height) else { return XCTFail("plain render failed") }
        // Column 44 of 64, NOT the middle. `testImage` maps `ev = -14 + u * 20`, so the
        // middle column sits at -3.8 EV — nearly four stops below middle grey, where the
        // display transform has so little slope that a full +1 EV under alpha 0.99 moves
        // the output by 0.006. Measured against the reference renderer, per column:
        //
        //   col 20  ev -7.6  selected 0.0001      col 44  ev -0.1  selected 0.2066
        //   col 32  ev -3.8  selected 0.0061      col 48  ev +1.2  selected 0.2235
        //   col 40  ev -1.3  selected 0.0918      col 56  ev +3.7  selected 0.0276
        //
        // Both earlier versions of this test sampled where the picture cannot move: the
        // first put the mask's selected end at +5.2 EV in the highlight rolloff, the
        // second at -3.8 EV in the shadows. Each time the assertion was right and the
        // geometry was wrong, and each cost a nine-minute round trip to find out. 44 is
        // -0.1 EV, and the selected end moves 138x the unselected one there.
        let column = (width * 11) / 16
        let unselected = plain[column, 1].maxAbsDifference(lift.gpu[column, 1])
        let selected = plain[column, height - 2].maxAbsDifference(lift.gpu[column, height - 2])
        XCTAssertGreaterThan(selected, 0.02,
                             "the selected end moved by \(selected) — the local "
                                 + "stages are not reaching pixels through the graph")
        XCTAssertGreaterThan(selected, unselected * 3,
                             "the unselected end moved \(unselected) against "
                                 + "\(selected) at the selected end — the alpha is "
                                 + "flat, or upside down, or the raster is mirrored")

        // ---- Tap two: the display-referred point curve, after picture formation. ----
        //
        // Deliberately NOT compared pixel-for-pixel against the reference. The graph
        // bakes the local curve into a `LocalCurvePlan` table and the reference
        // evaluates it exactly, so the gap here is the table's own interpolation error
        // on a steep curve — a real number worth characterising, but not evidence that
        // the tap is wired wrong, which is what this test exists to catch. What IS
        // asserted is that the curve reaches pixels through the graph and does so
        // under the mask: delete the `applyLocalCurves` call and both of these fail.
        let curve = CurveSet(point: [[0, 0], [0.5, 0.68], [1, 1]])
        guard let curved = maskedRender(exposure: 0, curve: curve) else {
            return XCTFail("curved render failed")
        }
        guard let plainCurve = maskedRender(exposure: 0, curve: nil) else {
            return XCTFail("baseline render failed")
        }
        let curveSelected = plainCurve.gpu[column, height - 2]
            .maxAbsDifference(curved.gpu[column, height - 2])
        let curveUnselected = plainCurve.gpu[column, 1]
            .maxAbsDifference(curved.gpu[column, 1])
        XCTAssertGreaterThan(curveSelected, 0.02,
                             "the local point curve moved the selected end by "
                                 + "\(curveSelected) — `applyLocalCurves` is not "
                                 + "running on the shipping path")
        XCTAssertGreaterThan(curveSelected, curveUnselected * 3,
                             "the local curve moved the unselected end "
                                 + "\(curveUnselected) against \(curveSelected) "
                                 + "selected — it is not gated by the mask at all")

        var curveWorst = 0.0
        for y in 0..<height {
            for x in 0..<width {
                curveWorst = Swift.max(
                    curveWorst, curved.reference[x, y].maxAbsDifference(curved.gpu[x, y]))
            }
        }
        print("LOCAL CURVE table-vs-exact worst: \(curveWorst)")
    }

    // MARK: - A mask's colour table is baked for the render it is in

    /// A masked colour edit must be baked at the size the RENDER asked for, not at the
    /// preview's.
    ///
    /// `LocalPlan` hardcoded `LUT3D.interactiveSize`, so every masked contrast, temp,
    /// tint, hue, saturation, vibrance, point colour and grading wheel in a DELIVERED
    /// file came out of a 33-cube while the global colour/grade table, the finish table
    /// and the local point curve two stages later all came out of a 65. The curve was
    /// the tell: it has taken `options.lutSize` since it was written, sitting six lines
    /// from a table that did not.
    ///
    /// Two assertions, because either alone can be satisfied by the wrong code. The
    /// first says `LocalPlan` bakes what it is handed — it fails the moment a size is
    /// hardcoded again. The second says the size REACHES PIXELS through the shipping
    /// graph, which is the proof the first one cannot give: a plan built at 65 that
    /// nothing hands 65 to is exactly the defect this replaces.
    func testAMaskedColourEditIsBakedAtTheRendersOwnTableSize() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")

        // A colour-only local set. Exposure is deliberately absent: it is a matrix
        // multiply upstream of the table and would move pixels whatever the table size
        // is, which would let the second half of this test pass on the broken code.
        var adjust = LocalAdjust()
        adjust.contrast = 45
        adjust.temp = 30
        adjust.sat = 35
        adjust.vibrance = 20

        // ---- The table is the size it was asked for. ----
        let anchors = RenderPlan(recipe: Recipe()).tone
        for size in [LUT3D.interactiveSize, LUT3D.exportSize] {
            let local = LocalPlan(adjust: adjust, scale: 1,
                                  whiteAnchorEV: anchors.whiteAnchorEV,
                                  blackAnchorEV: anchors.blackAnchorEV, size: size,
                                  globalColor: ColorAdjust(),
                                  globalWheels: GradingWheels())
            XCTAssertFalse(local.isIdentity,
                           "a mask with contrast, temp, saturation and vibrance "
                               + "declared itself identity, so this test measures "
                               + "a two-point cube and proves nothing")
            XCTAssertEqual(local.lut.size, size,
                           "LocalPlan baked \(local.lut.size) when the render asked "
                               + "for \(size)")
        }

        // ---- The size reaches pixels through the graph that ships. ----
        let width = 64, height = 32
        let source = texturedTestImage(width: width, height: height)

        // Vertical, for the reason the mask golden above states: the frame is constant
        // down each column, so any difference between two ROWS of one column is the
        // mask and nothing else.
        var mask = Mask(id: "m1", name: "grad")
        var component = MaskComponent(op: .add, kind: .linear)
        component.line = [0.5, 0, 0.5, 1]
        mask.components = [component]
        mask.adjust = adjust

        var recipe = Recipe()
        recipe.masks = [mask]
        recipe.develop.denoise.mode = .off
        // ONE plan for both renders, at export size, so the global colour/grade and
        // finish tables are bit-identical across the pair and the only thing that can
        // differ is the local table.
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)

        let alpha = MaskRaster.combine(mask: mask,
                                       size: (width: width, height: height))
        guard let alphaImage = PipelineRenderer.image(
            from: alpha,
            targetExtent: CGRect(x: 0, y: 0, width: width, height: height))
        else { return XCTFail("mask raster failed") }
        var graph = RenderGraph()
        graph.maskImages[mask.id] = alphaImage

        func render(lutSize: Int) -> ImageBuffer? {
            let out = graph.build(ciImage(from: source), plan: plan,
                                  options: RenderGraph.Options(longEdge: width,
                                                               lutSize: lutSize))
            return readBack(out, width: width, height: height)
        }
        guard let interactive = render(lutSize: LUT3D.interactiveSize),
              let exported = render(lutSize: LUT3D.exportSize)
        else { return XCTFail("masked render failed") }

        // The blend is `mix(original, adjusted, alpha)`, so the gap between the two
        // table sizes is scaled by alpha at every pixel: it must be largest where the
        // mask selects and vanish where it does not. That split is what separates "the
        // local table changed" from "something global changed".
        var selected = 0.0
        var unselected = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let d = interactive[x, y].maxAbsDifference(exported[x, y])
                if y >= height / 2 {
                    selected = Swift.max(selected, d)
                } else {
                    unselected = Swift.max(unselected, d)
                }
            }
        }
        XCTAssertGreaterThan(selected, 0,
                             "the two table sizes rendered identical pixels — "
                                 + "`options.lutSize` does not reach the masked "
                                 + "colour table, so an export bakes it at preview "
                                 + "precision")
        XCTAssertGreaterThan(selected, unselected,
                             "the table size moved the unselected end by \(unselected) "
                                 + "against \(selected) selected — what changed is not "
                                 + "the mask's own table")
        print(String(format: "LOCAL TABLE 33-vs-65 worst under the mask: %.6f", selected))
    }

    // MARK: - Presence must not put a rim on an edge

    /// Clarity and Texture must not trench the dark side of an edge.
    ///
    /// A guided filter's ε is a contrast threshold squared, and these ran on a
    /// `LumenLog`-encoded plane with values that meant 0.68 EV and 1.52 EV rather than
    /// the reference's 0.1. A one-and-a-half stop edge was therefore inside the
    /// threshold and the base blurred straight across it — measured, 50.6% of a 3 EV
    /// step — so the band contained the edge and a gain on the band put a rim either
    /// side. On a clean step, Clarity at +100 left 0.72 EV of trench against the
    /// reference local Laplacian's 0.066.
    ///
    /// A clean step with texture only on the flat sides is the classic test, and it has
    /// to be clean: on a noisy edge the rim hides inside the noise, which is why this
    /// went unnoticed while every other test passed.
    func testPresenceDoesNotRimAHardEdge() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 128, height = 64
        // 0.09 linear on the left, 0.72 on the right: three stops, hard. Fine texture
        // on both flats and none within 12 px of the step.
        let source = ImageBuffer(width: width, height: height) { u, _ in
            let x = u * Double(width)
            let base = x < Double(width) / 2 ? 0.09 : 0.72
            let away = abs(x - Double(width) / 2) > 12
            let texture = away ? 1.0 + 0.08 * sin(x / 2.0) : 1.0
            return RGB(gray: base * texture)
        }
        let input = ciImage(from: source)

        for (name, detail) in [("clarity", { () -> Detail in
                                    var d = Detail(); d.clarity = 100; return d }()),
                               ("texture", { () -> Detail in
                                    var d = Detail(); d.texture = 100; return d }())] {
            let output = RenderGraph.applyPresence(input, detail: detail, longEdge: 1600)
            guard let before = readBack(input, width: width, height: height),
                  let after = readBack(output, width: width, height: height)
            else { return XCTFail("\(name) render failed") }

            let row = height / 2
            // The dark plateau's own maximum, away from the step.
            var plateau = 0.0
            for x in 20..<50 { plateau = Swift.max(plateau, Double(before[x, row].g)) }
            // How far BELOW that the output dips in the eight pixels before the step.
            var trench = 0.0
            for x in (width / 2 - 8)..<(width / 2) {
                trench = Swift.max(trench, plateau - Double(after[x, row].g))
            }
            // In stops, so the bar means the same thing at any exposure.
            let trenchEV = trench > 0 ? log2((plateau + 1e-9) / Swift.max(plateau - trench, 1e-9))
                                      : 0
            XCTAssertLessThan(trenchEV, 0.30,
                              "\(name) at +100 dug a \(trenchEV) EV trench on the dark "
                                  + "side of a clean edge — the guided base is smoothing "
                                  + "across the step, so the band carries the edge")

            // And it still has to DO something, or a stage that returns its input passes.
            var moved = 0.0
            for x in 20..<50 {
                moved = Swift.max(moved, before[x, row].maxAbsDifference(after[x, row]))
            }
            XCTAssertGreaterThan(moved, 1e-4,
                                 "\(name) at +100 changed nothing on textured flat "
                                     + "ground, so this proves nothing")
        }
    }

    /// Dehaze must not drive scene-linear pixels below zero.
    ///
    /// The transmission divides the recombination, so a transmission that reads too
    /// high subtracts too much airlight and lands the result under black. The shipping
    /// path took its dark channel off the un-normalised image and divided by the
    /// airlight's scalar MEAN, where the reference normalises per channel — a
    /// difference that only exists when the veil has a colour, which is every veil
    /// worth a Dehaze slider. Measured against the reference under a blue-cyan airlight
    /// of (0.55, 0.68, 0.85): the transmission came out 0.060 high on average, 0.149 at
    /// worst, and 9.2% of recovered pixels went negative where the reference produces
    /// none.
    ///
    /// A frame this stage cannot make negative is the assertion, rather than a
    /// tolerance against the reference: negative scene-linear values are the thing that
    /// actually reaches the picture, as crushed black or as a channel clipping on its
    /// own and taking the hue with it.
    func testDehazeKeepsPixelsAboveBlack() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 48, height = 48
        // A scene under a distinctly blue-cyan veil, with the veil thickening down the
        // frame so the transmission varies. Colour in the airlight is the whole point:
        // a neutral veil hides the bug, because then the per-channel normalisation and
        // the scalar mean agree.
        let air = RGB(0.55, 0.68, 0.85)
        let source = ImageBuffer(width: width, height: height) { u, v in
            let scene = RGB(0.05 + 0.50 * u, 0.08 + 0.35 * u + 0.10 * v,
                            0.06 + 0.20 * u + 0.05 * v)
            let t = 0.25 + 0.60 * (1 - v)
            return RGB(scene.r * t + air.r * (1 - t),
                       scene.g * t + air.g * (1 - t),
                       scene.b * t + air.b * (1 - t))
        }
        let input = ciImage(from: source)

        for amount in [40.0, 80.0, 100.0] {
            let output = RenderGraph.applyDehaze(input, amount: amount, longEdge: width)
            guard let after = readBack(output, width: width, height: height),
                  let before = readBack(input, width: width, height: height)
            else { return XCTFail("dehaze render failed at \(amount)") }

            var worstNegative = 0.0
            var moved = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let c = after[x, y]
                    moved = Swift.max(moved, before[x, y].maxAbsDifference(c))
                    worstNegative = Swift.min(worstNegative,
                                              Swift.min(Double(c.r),
                                                        Swift.min(Double(c.g), Double(c.b))))
                }
            }
            XCTAssertGreaterThan(moved, 0.01,
                                 "dehaze at \(amount) changed nothing, so this proves "
                                     + "nothing")
            // A hair under zero is float noise; a fifth of a stop under is the bug.
            XCTAssertGreaterThan(worstNegative, -1e-3,
                                 "dehaze at \(amount) drove a channel to \(worstNegative) "
                                     + "— the transmission is too high, which is what a "
                                     + "scalar-mean normalisation does to a coloured veil")
        }
    }

    // MARK: - Sharpening: Masking, Detail, and the structure the gate reads

    /// A frame with three regions a sharpening mask has to tell apart: a hard vertical
    /// edge, isotropic fine texture, and a smooth low-contrast ramp.
    private func structureTestFrame(width: Int, height: Int) -> ImageBuffer {
        var noise = [Double](repeating: 0, count: width * height)
        // Deterministic, so a failure is reproducible rather than a coin flip.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<noise.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noise[i] = Double(seed >> 40) / Double(1 << 24) - 0.5
        }
        return ImageBuffer(width: width, height: height) { u, v in
            let x = Int(u * Double(width)), y = Int(v * Double(height))
            var value: Double
            if v < 0.5 {
                // Top half: an edge down the middle, with fine texture over it.
                value = u < 0.5 ? 0.09 : 0.52
                value *= 1.0 + 0.06 * noise[Swift.min(y * width + x, noise.count - 1)]
            } else {
                // Bottom half: a smooth ramp — a cheek or a clear sky.
                value = 0.13 + 0.08 * v
            }
            return RGB(gray: value)
        }
    }

    /// Masking must protect flat areas WITHOUT gutting the edges it exists to keep.
    ///
    /// The shipping gate read a raw per-pixel Sobel magnitude where the reference reads
    /// √λ₁ of a box-smoothed structure tensor. Those are the same quantity only when the
    /// smoothing radius is zero: an unsmoothed tensor is rank-1, so the mask came out
    /// one pixel wide where the reference's is a band. Measured against the reference on
    /// a synthetic frame, Masking then kept 17.8% of the sharpening delta on a genuine
    /// edge against the reference's 73.7% — the slider was not protecting skin so much
    /// as deleting the sharpening everywhere, and because a per-pixel gradient scales
    /// with resolution it deleted a different amount in the loupe than in the export.
    ///
    /// Both halves are asserted. "Flat is protected" alone passes for a gate that
    /// returns zero everywhere, which is exactly the bug this test was written for.
    func testMaskingProtectsFlatAreasWithoutGuttingEdges() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 64, height = 64
        let source = structureTestFrame(width: width, height: height)
        let input = ciImage(from: source)
        let longEdge = 1600   // a realistic frame, so the tensor radius is the real one

        let open = RenderGraph.applySharpen(
            input, ManualSharpen(amount: 100, masking: 0), longEdge: longEdge)
        let gated = RenderGraph.applySharpen(
            input, ManualSharpen(amount: 100, masking: 80), longEdge: longEdge)

        guard let before = readBack(input, width: width, height: height),
              let ungated = readBack(open, width: width, height: height),
              let masked = readBack(gated, width: width, height: height)
        else { return XCTFail("sharpen render failed") }

        func meanChange(_ image: ImageBuffer, xs: Range<Int>, ys: Range<Int>) -> Double {
            var total = 0.0, count = 0
            for y in ys {
                for x in xs {
                    total += abs(Double(image[x, y].g) - Double(before[x, y].g))
                    count += 1
                }
            }
            return count > 0 ? total / Double(count) : 0
        }

        // Columns 30…34 straddle the edge; 4…20 is texture well away from it.
        let edgeOpen = meanChange(ungated, xs: 30..<34, ys: 4..<28)
        let edgeMasked = meanChange(masked, xs: 30..<34, ys: 4..<28)
        let flatOpen = meanChange(ungated, xs: 4..<20, ys: 4..<28)
        let flatMasked = meanChange(masked, xs: 4..<20, ys: 4..<28)

        XCTAssertGreaterThan(edgeOpen, 1e-4,
                             "sharpening moved nothing on an edge, so this proves nothing")

        // Flat areas: the gate has to actually close.
        XCTAssertLessThan(flatMasked, flatOpen * 0.5,
                          "Masking at 80 left \(flatMasked / Swift.max(flatOpen, 1e-12)) "
                              + "of the sharpening in a flat area — the gate is not closing")

        // Edges: and it has to stay open where the detail is. Before the structure
        // tensor landed this ratio was 0.18.
        let kept = edgeMasked / Swift.max(edgeOpen, 1e-12)
        XCTAssertGreaterThan(kept, 0.5,
                             "Masking at 80 kept only \(kept) of the sharpening on an "
                                 + "edge — the gate is reading a per-pixel gradient, not "
                                 + "a smoothed structure tensor")
    }

    /// The Detail slider has to reach pixels.
    ///
    /// It has twice been a no-op on this path: once because `CIUnsharpMask` had nowhere
    /// to put it, and once because the fine band was blurred at a fixed sigma that
    /// equalled the working radius at its default, making the two components of the
    /// cross-fade bit-identical. Both times every test in the suite passed.
    /// What `CIGaussianBlur.radius` actually means, measured rather than assumed — and
    /// ASSERTED, which for one round it was not.
    ///
    /// This test blurred an impulse, measured the second moment of the response (which
    /// IS sigma by definition), and `print`ed it. Zero assertions. `RenderGraph`'s own
    /// header records the answer as measured fact — 2.0→2.0, 6.0→6.01, 8.95→9.0, so
    /// the parameter is the standard deviation and not a support radius — and the
    /// correction that followed landed in `RenderGraph.gaussianBlur` and MISSED
    /// `applyHalation`, which had built its own `CIFilter.gaussianBlur()` with the old
    /// `sigma * 3` in it. Every shipping preview and export rendered the glow three
    /// times wider than the 65 µm the profile derives, and this test, whose entire
    /// subject is that conversion, could not go red — nor could it have gone red for
    /// the original bug it was written to investigate. A measurement nobody compares
    /// against anything is a diagnostic, not a test.
    ///
    /// The bar is now the measurement itself: the helper must return the sigma it was
    /// asked for. `sigma * 3` fails every row by a factor of three.
    ///
    /// The a-trous smooths the sharpen stage cross-fades against are asserted as a
    /// RATIO rather than against absolute numbers. Doubling the tap spacing doubles the
    /// standard deviation whatever the kernel's normalization is, so the ratio is the
    /// part of the claim that is structural; the step-1 band is given a wide window
    /// around the B3-spline's unit variance.
    func testWhatCIGaussianBlurRadiusMeans() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let side = 129

        /// The standard deviation of the central row of an impulse response. The
        /// marginal of an isotropic 2-D Gaussian is a 1-D Gaussian of the same sigma,
        /// and the mean sits at the impulse by symmetry, so this is sigma with no fit.
        func measuredSigma(_ image: CIImage) -> Double? {
            guard let got = readBack(image, width: side, height: side) else { return nil }
            var sum = 0.0, second = 0.0
            for x in 0..<side {
                let v = Double(got[x, side / 2].r)
                let d = Double(x - side / 2)
                sum += v
                second += v * d * d
            }
            guard sum > 0 else { return nil }
            return (second / sum).squareRoot()
        }

        func impulseImage() -> CIImage {
            var impulse = Plane(width: side, height: side)
            impulse[side / 2, side / 2] = 1.0
            return ciImage(from: broadcast(impulse))
        }

        // 9.0 is the widest row the runner's recorded measurement covers, and three
        // sigmas of it still sit 37 px inside a 129 px frame, so nothing here is
        // measuring truncation.
        for askedSigma in [1.0, 2.0, 4.0, 6.0, 9.0] {
            guard let blurred = RenderGraph.gaussianBlur(impulseImage(),
                                                         sigma: askedSigma) else {
                return XCTFail("gaussianBlur returned nothing at sigma \(askedSigma)")
            }
            guard let measured = measuredSigma(blurred) else {
                return XCTFail("blurred impulse read back empty at sigma \(askedSigma)")
            }
            print(String(format: "GAUSSIAN asked sigma %.1f -> measured sigma %.3f",
                         askedSigma, measured))
            // 5% of the request, floored so the narrowest row is not held to a
            // sub-pixel bar on a filter that works in pixels.
            XCTAssertEqual(measured, askedSigma,
                           accuracy: Swift.max(0.12, askedSigma * 0.05),
                           "`CIGaussianBlur.radius` is not the standard deviation: "
                               + "asked \(askedSigma), measured \(measured). A ratio "
                               + "near 3 means a support-radius conversion has come "
                               + "back somewhere in the graph")
        }

        // And the a-trous smooths the sharpen stage cross-fades against.
        var atrous: [Double] = []
        for step in [1, 2] {
            guard let smoothed = RenderGraph.bSplinePass(impulseImage(), step: step),
                  let measured = measuredSigma(smoothed) else {
                return XCTFail("a-trous step \(step) produced nothing")
            }
            print(String(format: "ATROUS step %d -> measured sigma %.3f", step, measured))
            atrous.append(measured)
        }
        guard atrous.count == 2 else { return XCTFail("a-trous measurement incomplete") }
        XCTAssertEqual(atrous[0], 1.0, accuracy: 0.25,
                       "the step-1 B3-spline smooth measured \(atrous[0]); its variance "
                           + "is 1 by construction")
        XCTAssertEqual(atrous[1] / Swift.max(atrous[0], 1e-9), 2.0, accuracy: 0.2,
                       "doubling the a-trous tap spacing must double the standard "
                           + "deviation; measured \(atrous[1]) against \(atrous[0])")
    }

    // MARK: - Halation

    /// One clipped highlight, both paths, and the width of the glow it throws.
    ///
    /// The halation stage kept a private `CIFilter.gaussianBlur()` with
    /// `radius = sigma * 3` in it long after the shared helper had been corrected, so
    /// every preview and every export rendered the glow three times wider than the
    /// 65 µm first bounce the profile derives, while `ReferenceRenderer.applyHalation`
    /// rendered it at one. Nothing could see it: the only halation tests were on the
    /// reference path, and a grep of this whole directory for "halation" returned
    /// nothing at all.
    ///
    /// What is measured is the second moment of the glow field about the highlight,
    /// which for a sum of Gaussians against a small uniform source is `2·Σwσ²/Σw` plus
    /// the source's own variance — the first derived here from the profile the two
    /// stages share rather than written down, so the bar moves with the model instead
    /// of pinning today's numbers. A support-radius conversion multiplies it by NINE.
    ///
    /// The frame is 128 px and the render's long edge is declared as 2215, which is
    /// what puts the first bounce at 4 px: halation is denominated at the gate, so on a
    /// literal 128 px frame the whole glow would be a third of a pixel wide and this
    /// would be measuring quantization. Nothing else in `applyHalation` reads the long
    /// edge.
    func testHalationGlowIsAsWideAsTheProfileSays() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let side = 128
        let longEdge = 2215
        let block = 4
        // The block straddles the frame's centre EVENLY, so it is its own mirror image
        // about `centre` under a vertical flip. `ciImage(from:)` and `readBack` are the
        // two halves of a bitmap bridge whose row order this file pins only
        // transitively, and a second moment taken about a centre that is one pixel off
        // is inflated by exactly one. Making the frame symmetric costs nothing and
        // takes the question off the table.
        let centre = Double(side) / 2 - 0.5
        let low = side / 2 - block / 2
        let film = FilmChain(FilmLab(stock: FilmStock.portra400.id, amount: 100,
                                     halation: 100),
                             filmExposure: 0, displayWhite: 1.0)
        let profile = film.halation(longEdgePixels: longEdge)

        // Two stops over the clip, on a background four and a half stops BELOW the
        // reconstruction's onset — so both the reference's smoothstep and the shader's
        // pedestal read exactly zero everywhere but the block, and the two energy
        // fields differ in amplitude only, never in footprint.
        var source = ImageBuffer(width: side, height: side) { _, _ in RGB(gray: 0.02) }
        for y in low..<(low + block) {
            for x in low..<(low + block) { source[x, y] = RGB(gray: 4.0) }
        }

        let input = ciImage(from: source)
        guard let before = readBack(input, width: side, height: side) else { return }
        let glowed = RenderGraph().applyHalation(input, film: film, longEdge: longEdge)
        guard let gpu = readBack(glowed, width: side, height: side) else { return }
        let reference = ReferenceRenderer.applyHalation(source, film: film,
                                                        longEdge: longEdge)

        /// Total glow in one channel, and its second moment about the highlight.
        func glow(_ after: ImageBuffer, _ start: ImageBuffer, channel: Int)
            -> (mass: Double, spread: Double) {
            var mass = 0.0, second = 0.0
            for y in 0..<side {
                for x in 0..<side {
                    let delta = after[x, y][channel] - start[x, y][channel]
                    guard delta > 0 else { continue }
                    let dx = Double(x) - centre, dy = Double(y) - centre
                    mass += delta
                    second += delta * (dx * dx + dy * dy)
                }
            }
            return (mass, mass > 0 ? second / mass : 0)
        }

        // The model's own prediction, from the profile the two stages share: variances
        // add, so the glow's is the weighted mean of the bounces' plus the block's.
        var weightSum = 0.0, varianceSum = 0.0
        for (sigma, weight) in zip(profile.sigmasInPixels, profile.weights) {
            weightSum += weight
            varianceSum += weight * sigma * sigma
        }
        XCTAssertGreaterThan(weightSum, 0, "the halation profile carries no bounces")
        // A uniform w x w source has variance (w² − 1)/12 per axis, and variances add.
        let blockVariance = 2 * (Double(block) * Double(block) - 1) / 12.0
        let predicted = 2 * varianceSum / Swift.max(weightSum, 1e-12) + blockVariance

        let gpuGlow = glow(gpu, before, channel: 0)
        let referenceGlow = glow(reference, source, channel: 0)
        print(String(format: "HALATION predicted spread %.2f  gpu %.2f  reference %.2f  "
                             + "(mass gpu %.4f reference %.4f)",
                     predicted, gpuGlow.spread, referenceGlow.spread,
                     gpuGlow.mass, referenceGlow.mass))

        XCTAssertGreaterThan(gpuGlow.mass, 1e-4,
                             "the graph's halation stage added no light at all")
        XCTAssertGreaterThan(referenceGlow.mass, 1e-4,
                             "the reference's halation stage added no light at all")
        // 12%: the measurement is a discrete second moment of an f32 read-back, and the
        // two paths' reconstruction ramps differ in amplitude. A support-radius
        // conversion is 900%.
        XCTAssertEqual(gpuGlow.spread, predicted, accuracy: predicted * 0.12,
                       "the graph blurred halation at a spread of \(gpuGlow.spread) "
                           + "where the profile says \(predicted). A ratio near 9 is "
                           + "`sigma * 3` back in the stage")
        XCTAssertEqual(referenceGlow.spread, predicted, accuracy: predicted * 0.12,
                       "the reference blurred halation at a spread of "
                           + "\(referenceGlow.spread) where the profile says "
                           + "\(predicted)")
        XCTAssertEqual(gpuGlow.spread, referenceGlow.spread,
                       accuracy: referenceGlow.spread * 0.10,
                       "the two paths disagree about how wide the glow is: "
                           + "\(gpuGlow.spread) against \(referenceGlow.spread)")

        // The energy divergence the engine has claimed is "matched at the half-power
        // point" and never measured: the shader reconstructs highlights with a hard
        // pedestal and the reference with a C¹ smoothstep. Recorded as a number with a
        // bound on it, so a change in either ramp shows up here rather than in a
        // photograph.
        XCTAssertEqual(gpuGlow.mass, referenceGlow.mass,
                       accuracy: referenceGlow.mass * 0.30,
                       "the pedestal and the smoothstep now disagree about total glow "
                           + "energy by more than 30%: \(gpuGlow.mass) against "
                           + "\(referenceGlow.mass)")

        // Halation is red because the stock's measured strengths are, and Portra's blue
        // strength is exactly zero. A glow that is not red is a glow through the wrong
        // gain.
        let blue = glow(gpu, before, channel: 2)
        XCTAssertLessThan(blue.mass, gpuGlow.mass * 0.02,
                          "the glow carried \(blue.mass) of blue against "
                              + "\(gpuGlow.mass) of red, and this stock's blue halation "
                              + "strength is zero")
    }

    /// Halation has to reach pixels THROUGH `RenderGraph.build`.
    ///
    /// Every halation test in the repository ran on the reference path or called the
    /// stage directly, so deleting the call to it from `build` left the whole suite
    /// green while every preview and every export lost the glow. This is the same hole
    /// that was closed for masks and is still open for grain.
    ///
    /// Halation is a spatial stage and never enters the baked finish table, so the only
    /// difference between these two renders is the stage itself — which is also why the
    /// far corner is asserted to stay put: a table that had somehow started reading
    /// Amount would move the whole frame, and that is a different defect wearing this
    /// one's result.
    func testHalationReachesPixelsThroughTheGraph() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let side = 128
        let longEdge = 2215
        let block = 4
        let centre = Double(side) / 2 - 0.5
        let low = side / 2 - block / 2

        var source = ImageBuffer(width: side, height: side) { _, _ in RGB(gray: 0.02) }
        for y in low..<(low + block) {
            for x in low..<(low + block) { source[x, y] = RGB(gray: 4.0) }
        }

        func render(halation: Double) -> ImageBuffer? {
            var recipe = Recipe()
            // `Recipe()` denoises; S3 is not what this is about.
            recipe.develop.denoise.mode = .off
            recipe.look.filmLab = FilmLab(stock: FilmStock.portra400.id, amount: 100,
                                          halation: halation)
            let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
            let output = RenderGraph().build(
                ciImage(from: source), plan: plan,
                options: RenderGraph.Options(longEdge: longEdge))
            return readBack(output, width: side, height: side)
        }

        guard let off = render(halation: 0), let on = render(halation: 100) else {
            return XCTFail("film render failed")
        }

        // An annulus four to ten pixels out: clear of the block, whose farthest pixel
        // sits 2.1 from the centre, and well inside the first bounce's four-pixel
        // sigma.
        var ring = 0.0
        var ringCount = 0
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) - centre, dy = Double(y) - centre
                let radius = (dx * dx + dy * dy).squareRoot()
                guard radius >= 4, radius <= 10 else { continue }
                ring += on[x, y].maxAbsDifference(off[x, y])
                ringCount += 1
            }
        }
        ring = ringCount > 0 ? ring / Double(ringCount) : 0
        let corner = on[2, 2].maxAbsDifference(off[2, 2])

        print(String(format: "HALATION through the graph: ring %.5f corner %.5f",
                     ring, corner))
        // The floor is a noise floor and says so: with the call deleted this difference
        // is identically zero to f32, not merely small. The substance of the test is
        // the pair — something moved, and it moved AT the highlight.
        XCTAssertGreaterThan(ring, 1e-3,
                             "turning Halation to 100 moved the pixels beside a clipped "
                                 + "highlight by \(ring) — the stage is not running in "
                                 + "`RenderGraph.build`")
        XCTAssertLessThan(corner, ring / 4,
                          "the far corner moved \(corner) against \(ring) at the "
                              + "highlight, so whatever changed is not a local glow")
    }

    func testDetailSliderMovesThePicture() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 64, height = 64
        let source = structureTestFrame(width: width, height: height)
        let input = ciImage(from: source)

        let low = RenderGraph.applySharpen(
            input, ManualSharpen(amount: 100, detail: 0), longEdge: 1600)
        let high = RenderGraph.applySharpen(
            input, ManualSharpen(amount: 100, detail: 100), longEdge: 1600)

        guard let a = readBack(low, width: width, height: height),
              let b = readBack(high, width: width, height: height)
        else { return XCTFail("sharpen render failed") }

        var worst = 0.0
        for y in 0..<height {
            for x in 0..<width { worst = Swift.max(worst, a[x, y].maxAbsDifference(b[x, y])) }
        }
        XCTAssertGreaterThan(worst, 1e-4,
                             "Detail moved the frame by \(worst) across its whole range "
                                 + "— the slider reaches no pixels")

        // DIRECTION, not just difference.
        //
        // The assertion above passed for eighteen months while the slider ran
        // backwards: `mix(usm, fine, detail)` with a `fine` band smaller in amplitude
        // than `usm` is a monotone attenuator, so Detail 100 was measurably different
        // from Detail 0 and also nearly off. Measured gain against the unsharpened
        // frame at a 2 px period was 1.99 at Detail 0 and 1.16 at Detail 100. "They
        // differ" is satisfied perfectly by a sign inversion, which is why a test that
        // only asserts a difference is worth so much less than it looks.
        //
        // Detail's job is to weight the sharpening toward the finest scales, so raising
        // it must not REDUCE the excursion around an edge.
        guard let plain = readBack(input, width: width, height: height) else { return }
        func excursion(_ frame: ImageBuffer) -> Double {
            var total = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    total += abs(Double(frame[x, y].g) - Double(plain[x, y].g))
                }
            }
            return total
        }
        let lowEnergy = excursion(a)
        let highEnergy = excursion(b)
        XCTAssertGreaterThan(highEnergy, lowEnergy * 0.95,
                             "Detail 100 sharpened LESS than Detail 0 "
                                 + "(\(highEnergy) vs \(lowEnergy)) — the slider runs "
                                 + "backwards, which is what happens when the fine band "
                                 + "is a narrower high-pass than the unsharp term")
    }

    /// Negative Texture must smooth isotropic texture harder than it smooths an edge.
    ///
    /// That asymmetry is the entire difference between a skin smoother and a negative
    /// Clarity, and the coherence gate is what produces it. The shipping kernel had it
    /// close to backwards: it squared the eigenvalue ratio, which the reference does
    /// not, and it omitted the reference's strength gate, so a smooth low-contrast ramp
    /// — a cheek, a sky — has a tiny gradient pointing consistently one way and read as
    /// a coherent edge to be protected. Against the reference on the same frame:
    /// isotropic texture 0.596 where the reference says 0.000, a smooth ramp 0.715
    /// against 0.000, and a real edge protected LESS, 0.503 against 0.611.
    func testNegativeTextureSmoothsTextureMoreThanEdges() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 64, height = 64
        let source = structureTestFrame(width: width, height: height)
        let input = ciImage(from: source)

        var detail = Detail()
        detail.texture = -100
        let output = RenderGraph.applyPresence(input, detail: detail, longEdge: 1600)

        guard let before = readBack(input, width: width, height: height),
              let after = readBack(output, width: width, height: height)
        else { return XCTFail("presence render failed") }

        func meanChange(xs: Range<Int>, ys: Range<Int>) -> Double {
            var total = 0.0, count = 0
            for y in ys {
                for x in xs {
                    total += abs(Double(after[x, y].g) - Double(before[x, y].g))
                        / Swift.max(Double(before[x, y].g), 1e-6)
                    count += 1
                }
            }
            return count > 0 ? total / Double(count) : 0
        }

        let texture = meanChange(xs: 4..<20, ys: 4..<28)   // isotropic fine detail
        let edge = meanChange(xs: 30..<34, ys: 4..<28)     // the coherent edge

        XCTAssertGreaterThan(texture, 1e-5,
                             "negative Texture smoothed nothing, so this proves nothing")
        XCTAssertGreaterThan(texture, edge,
                             "negative Texture moved the edge by \(edge) and the texture "
                                 + "by \(texture) — the coherence gate is not "
                                 + "distinguishing them, which is what makes it a skin "
                                 + "smoother rather than a glow")
    }

    // MARK: - The eyedropper's probe

    /// A source that hands back a known picture, so the probe can be asked whether it
    /// reads the pixel it was pointed at.
    private final class StubSource: ImageSource {
        let url = URL(fileURLWithPath: "/dev/null")
        let asShotTemperature: Double = 5500
        let asShotTint: Double = 0
        // `.unspecified`, not `.sceneLinearDecode`. The stub hands back a CIImage it was
        // given with NO DECODER BEHIND IT, and `.sceneLinearDecode` means something
        // specific — CIRAWFilter at Lumen's flat settings, read before every Lumen stage.
        // Claiming it here would put a decoder's label on numbers no decoder produced,
        // which is precisely the failure the protocol requirement was added to prevent.
        // `.unspecified` is documented as "numbers of unknown origin", which is what
        // these are.
        let statisticsProvenance: RawStatistics.Provenance = .unspecified
        private let image: CIImage
        init(_ image: CIImage) { self.image = image }
        var nativePixelSize: (width: Int, height: Int) {
            (Int(image.extent.width), Int(image.extent.height))
        }
        var nativeLongEdge: Double { Double(max(image.extent.width, image.extent.height)) }
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? { image }
        var captureMetadata: CaptureMetadata {
            CaptureMetadata(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                            decoderVersion: nil, pixelSize: nativePixelSize)
        }
    }

    /// The probe must read the pixel it was pointed at.
    ///
    /// Asserted against `readBack` rather than against an absolute idea of "top",
    /// deliberately. Core Image extents are bottom-up while the UI hands down a
    /// top-down fraction, and `CIImage(bitmapData:)`'s row order is a third convention
    /// again — a probe with the flip missing returns a perfectly plausible colour, just
    /// the one mirrored about the centre line, which on a photograph reads as "the
    /// eyedropper is a bit inaccurate" rather than as a bug. Comparing against the same
    /// read-back path every golden in this file already trusts pins the probe to the
    /// convention the renderer actually uses, instead of to one I asserted.
    func testTheSceneProbeReadsThePointItWasGiven() throws {
        // Every pixel distinct in both axes, so a swap or a flip cannot coincide.
        let width = 16, height = 16
        let source = ImageBuffer(width: width, height: height) { u, v in
            RGB(0.1 + 0.8 * u, 0.5, 0.1 + 0.8 * v)
        }
        let stub = StubSource(ciImage(from: source))
        let renderer = PipelineRenderer()
        guard let expected = readBack(ciImage(from: source), width: width, height: height)
        else { return XCTFail("read-back failed") }

        for (px, py) in [(3, 2), (12, 4), (8, 8), (2, 13), (14, 15)] {
            let u = (Double(px) + 0.5) / Double(width)
            let v = (Double(py) + 0.5) / Double(height)
            guard let sample = renderer.sampleSceneLinear(source: stub, recipe: Recipe(),
                                                          sourceX: u, sourceY: v,
                                                          radius: 0)
            else { return XCTFail("no sample at \(px),\(py)") }
            let want = expected[px, py]
            XCTAssertEqual(sample.r, want.r, accuracy: 0.02,
                           "probe read the wrong COLUMN at \(px),\(py): "
                               + "got \(sample) want \(want)")
            XCTAssertEqual(sample.b, want.b, accuracy: 0.02,
                           "probe read the wrong ROW at \(px),\(py) — the vertical "
                               + "flip is wrong: got \(sample) want \(want)")
        }
    }

    /// Out-of-frame requests clamp; they do not crash and do not return garbage.
    func testTheSceneProbeSurvivesTheCorners() throws {
        let source = ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0.25) }
        let stub = StubSource(ciImage(from: source))
        let renderer = PipelineRenderer()
        for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, 0.0), (-1.0, 2.0)] {
            guard let sample = renderer.sampleSceneLinear(source: stub, recipe: Recipe(),
                                                          sourceX: x, sourceY: y)
            else { return XCTFail("no sample at \(x),\(y)") }
            XCTAssertTrue(sample.isFinite, "non-finite sample at \(x),\(y)")
            XCTAssertEqual(sample.g, 0.25, accuracy: 0.02, "wrong value at \(x),\(y)")
        }
    }

    // MARK: - Grain lands on the grid that is delivered

    /// Two exports of the same picture at the same delivered size must contain the same
    /// grain, whether or not the export had to resize to get there.
    ///
    /// `export` applied grain inside `build`, at DECODE resolution, and then resampled
    /// to the target — so a 900 px file delivered at 300 px carried a grain pattern
    /// three times finer than the one a 300 px render of the same recipe produces, and
    /// three times finer than the preview the photographer approved. σ is a poor
    /// instrument for that: measured on the reference path, a 3x average costs the
    /// amplitude only about 4% (`testFilmGrainHasTheSameAmplitudeAtEveryRenderSize`),
    /// which is why this compares the PICTURES and not their standard deviations. Two
    /// uncorrelated grain fields of the same σ differ by √2·σ; the same field twice
    /// differs by nothing.
    ///
    /// A flat field, so every difference between the two files is grain. Denoise off,
    /// output sharpening off, no watermark: each of those would put structure into the
    /// comparison that is not the thing being measured.
    ///
    /// Uncropped, deliberately. A crop is the case where the delivered pixel count is
    /// NOT the long edge the plate must be scaled for, and that arithmetic is pinned
    /// where it can actually be run:
    /// `testAGrainPlateIsScaledForPixelsPerGateAndNotForPixelCount` in LumenCore.
    func testGrainIsAppliedOnTheGridThatIsDelivered() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")

        let delivered = 300
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.look.filmLab = FilmLab(stock: "lumen/portra400", amount: 100,
                                      grain: FilmGrain(size: 1, amount: 100))
        let exportRecipe = ExportRecipe(name: "grain", format: .png, bitDepth: 16,
                                        colorSpace: .srgb, resizeMode: .longEdge,
                                        resizeValue: Double(delivered))
        let renderer = PipelineRenderer()

        func delivery(sourceLongEdge: Int) throws -> ImageBuffer {
            let w = sourceLongEdge, h = sourceLongEdge * 2 / 3
            let flat = ImageBuffer(width: w, height: h) { _, _ in RGB(gray: 0.18) }
            let image = try renderer.exportedImage(source: StubSource(ciImage(from: flat)),
                                                   recipe: recipe, using: exportRecipe)
            let ow = Int(image.extent.width.rounded())
            let oh = Int(image.extent.height.rounded())
            XCTAssertEqual(ow, delivered,
                           "a \(sourceLongEdge) px source delivered \(ow) px")
            guard let pixels = readBack(image, width: ow, height: oh) else {
                throw RenderError.renderFailed
            }
            return pixels
        }

        // Native: 300 px in, 300 px out, no resize anywhere in the path.
        let native = try delivery(sourceLongEdge: delivered)
        // Downsized: the same picture, three times larger, delivered at the same size.
        let downsized = try delivery(sourceLongEdge: delivered * 3)

        // Inset by two pixels, down from six. Six existed to dodge the darkened
        // Lanczos rim `scaled()` used to produce on every resized export (docs/31
        // round one §12) — a defect this comparison was stepping around instead of
        // failing on. With the edge clamp in `scaled()` the borders of a flat
        // field survive the resample, and `testAResizedExportHasNoDarkenedRim`
        // pins that directly; what remains is the honest half-pixel phase
        // difference of resampled-vs-native at the outermost rows, which two
        // pixels covers.
        let inset = 2
        var sum = 0.0, sumSquares = 0.0, difference = 0.0, count = 0.0
        for y in inset..<(native.height - inset) {
            for x in inset..<(native.width - inset) {
                let a = native[x, y].g
                sum += a
                sumSquares += a * a
                difference += (a - downsized[x, y].g) * (a - downsized[x, y].g)
                count += 1
            }
        }
        let mean = sum / Swift.max(count, 1)
        let sigma = Swift.max(sumSquares / Swift.max(count, 1) - mean * mean, 0)
            .squareRoot()
        let rms = (difference / Swift.max(count, 1)).squareRoot()
        print(String(format: "EXPORT GRAIN mean %.4f  sigma %.5f  rms difference %.5f",
                     mean, sigma, rms))

        // Grain has to be present, or the comparison below is between two flat fields
        // and passes for a pipeline that dropped the stage entirely.
        XCTAssertGreaterThan(sigma, 0.02 * mean,
                             "the delivered file varies by \(sigma) on a mean of "
                                 + "\(mean) — under 2% of the level is not a grain, so "
                                 + "the comparison below proves nothing")
        // The two deliveries are the same plate, at the same scale, over the same flat
        // picture, so they should agree to the resampler's own error. Grain applied
        // before the resize instead puts two UNCORRELATED fields side by side, which
        // lands near √2·σ — a factor of ten above this bar.
        XCTAssertLessThan(rms, 0.15 * sigma,
                          "two exports of the same picture at the same delivered size "
                              + "differ by \(rms) against a grain σ of \(sigma) — the "
                              + "resized one is not carrying the grain of the size it "
                              + "was delivered at")
    }

    // MARK: - The AI matte ledger

    /// The matte ledger answers per KIND, and it says what it threw away.
    ///
    /// Two shipped defects, one ledger, and no kernel involved in either — which is why
    /// this test needs no GPU and would have caught both on any Mac.
    ///
    /// It was per FILE. "Has a pass run for this photograph" is the wrong question:
    /// add a Subject mask, the pass runs for `{aiSubject}` and the file is marked done;
    /// add a People mask afterwards and every guard on both the preview and the export
    /// path short-circuits, so the People matte is never generated at all — and the
    /// panel then prints "Vision found no person in this frame" about a request nobody
    /// issued.
    ///
    /// And the renderer's cache is bounded at twelve files while the app's copy of the
    /// same facts was never trimmed. Browse thirteen photographs carrying Vision masks,
    /// return to the first, and the app skipped the regeneration while the render read
    /// an empty matte and the panel still said READY. `storeMattes` now returns what it
    /// evicted, so the only place that can drop a matte is the only place that reports
    /// one — the two cannot drift apart the way two independent ledgers did.
    func testTheMatteLedgerIsPerKindAndReportsWhatItEvicts() {
        let renderer = PipelineRenderer()
        let first = URL(fileURLWithPath: "/tmp/lumen-matte-ledger-first.raw")
        let subject = MaskKind.aiSubject.rawValue
        let person = MaskKind.aiPerson.rawValue
        let plane = Plane(width: 2, height: 2)

        // A pass that looked for Subject and found one.
        XCTAssertTrue(renderer.storeMattes([subject: plane], requested: [subject],
                                           for: first).isEmpty,
                      "the first store of thirteen evicted something")
        XCTAssertEqual(renderer.matteKinds(for: first), [subject])
        XCTAssertEqual(renderer.attemptedMatteKinds(for: first), [subject])

        // The whole of the first defect: People has not been looked for, on a file that
        // HAS been looked at.
        XCTAssertFalse(renderer.attemptedMatteKinds(for: first).contains(person),
                       "the ledger says People was attempted because Subject was — "
                           + "which is the per-file answer to a per-kind question, and "
                           + "it is what stopped the second Vision mask ever being "
                           + "computed")

        // A pass that looked for People and found nobody. Recorded as attempted, so it
        // is not re-segmented on every edit; NOT recorded as available, so the panel
        // can still tell "found nothing" from "not asked".
        renderer.storeMattes([:], requested: [person], for: first)
        XCTAssertTrue(renderer.attemptedMatteKinds(for: first).contains(person))
        XCTAssertFalse(renderer.matteKinds(for: first).contains(person),
                       "a kind that produced no plane is being reported as available")
        XCTAssertTrue(renderer.matteKinds(for: first).contains(subject),
                      "the second pass overwrote the first one's matte")

        // Twelve more files push the first out of a twelve-file cache, and the store
        // has to SAY so — a caller holding a copy has no other way to find out.
        var evicted: [URL] = []
        for i in 0..<12 {
            let other = URL(fileURLWithPath: "/tmp/lumen-matte-ledger-\(i).raw")
            evicted += renderer.storeMattes([subject: plane], requested: [subject],
                                            for: other)
        }
        XCTAssertEqual(evicted, [first],
                       "the cache dropped \(evicted) on its way past twelve files; the "
                           + "file it dropped is the one whose ledger entry elsewhere "
                           + "is now a lie")
        XCTAssertTrue(renderer.matteKinds(for: first).isEmpty,
                      "the evicted file still reports a matte")
        XCTAssertTrue(renderer.attemptedMatteKinds(for: first).isEmpty,
                      "the file's mattes went and its attempt ledger stayed — the two "
                          + "dictionaries that used to disagree, now in one value so "
                          + "that they cannot")
    }

    // MARK: - An export is a promise

    /// A picture the GPU cannot form must not be delivered as though it were the edit.
    ///
    /// The preview path has checked `coreAvailable` and fallen back to the reference
    /// since it was written. Export had no equivalent: it built the graph
    /// unconditionally, every `KernelLibrary.apply(...) ?? image` no-opped a missing
    /// stage into the file, and `AppState.export` recorded a failure only when
    /// something threw — so with the core four missing it wrote the fallback-tone
    /// approximation and the status line said "Exported 1 file".
    ///
    /// `KernelLibrary`'s kernels are `static let` and compile once, so on a healthy
    /// runner they cannot be made to fail and this behaviour could not be tested at
    /// all. `PipelineRenderer.availability` is the seam that makes it testable, and
    /// these two tests are the only reason it exists.
    func testAnExportRefusesToDeliverAPictureTheGPUCannotForm() {
        let renderer = PipelineRenderer()
        renderer.availability = KernelAvailability(
            coreAvailable: false, unavailable: ["logEncode", "logDecode", "multiply"])
        let flat = ImageBuffer(width: 32, height: 24) { _, _ in RGB(gray: 0.18) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-out15-refused-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            _ = try renderer.export(source: StubSource(ciImage(from: flat)),
                                    recipe: Recipe(), to: destination,
                                    using: ExportRecipe(name: "t", format: .png))
            XCTFail("export delivered a file with the core colour kernels missing")
        } catch RenderError.kernelsUnavailable(let missing) {
            XCTAssertEqual(missing, ["logEncode", "logDecode", "multiply"],
                           "the refusal did not carry the names the caller has to "
                               + "report")
        } catch {
            XCTFail("export threw \(error) rather than naming the kernels that were "
                        + "not there")
        }
        // Refusing has to mean nothing was written. A truncated or half-written
        // delivery is the failure this replaces, wearing an error message.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a refused export left a file on disk anyway")
    }

    /// A file written with one stage absent is not a failure and is not clean either,
    /// and the caller has to be told which stage.
    func testAnExportNamesTheStagesThatSilentlyDidNothing() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let renderer = PipelineRenderer()
        let flat = ImageBuffer(width: 32, height: 24) { _, _ in RGB(gray: 0.18) }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-out15-reduced-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: destination) }

        // A healthy build reports nothing missing, and the file is clean.
        let clean = try renderer.export(source: StubSource(ciImage(from: flat)),
                                        recipe: Recipe(), to: destination,
                                        using: ExportRecipe(name: "t", format: .png))
        XCTAssertEqual(clean, [],
                       "this runner compiled every kernel and the export still "
                           + "reported \(clean) missing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path),
                      "a clean export wrote nothing")

        // A non-core kernel missing still delivers — grain, vignette and the presence
        // stages degrade individually — but the list has to come back so the status
        // line can name them instead of counting the file as clean.
        renderer.availability = KernelAvailability(coreAvailable: true,
                                                   unavailable: ["grain", "vignette"])
        let reduced = try renderer.export(source: StubSource(ciImage(from: flat)),
                                          recipe: Recipe(), to: destination,
                                          using: ExportRecipe(name: "t", format: .png))
        XCTAssertEqual(reduced, ["grain", "vignette"],
                       "a reduced export reported \(reduced) — `AppState.export` has "
                           + "nothing to put in the status line and counts the file "
                           + "as clean, which is the defect")
    }

    // MARK: - Availability

    /// The load-bearing environment check. If this fails, the app still renders — via
    /// the CPU reference — but the failure must be loud, because everything below it
    /// is measuring something that is not running.
    func testEveryKernelCompiles() {
        XCTAssertTrue(KernelLibrary.isAvailable,
                      "kernels failed to compile: \(KernelLibrary.unavailableKernels)")
    }

    // MARK: - Helpers

    /// A synthetic scene-referred frame: a log-spaced luminance ramp crossed with a
    /// hue sweep, covering 20 stops and the saturated corners where colour maths
    /// misbehaves.
    ///
    /// Deliberately ROW-INVARIANT — every row is identical. Core Image's origin is
    /// bottom-left and ImageBuffer's is top-left, and rather than encode a guess about
    /// where the flip lands into a dozen numeric comparisons, the comparisons are made
    /// immune to it. `testCropUsesImageCoordinates` is the single place the convention
    /// is asserted, and it asserts it directly.
    private func testImage(width: Int = 64, height: Int = 8) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, _ in
            let ev = -14 + u * 20
            let level = 0.18 * pow(2.0, ev)
            let hue = u * 720
            let lch = OKLCh(L: 0.5, C: 0.12, h: hue)
            let tint = OKLabTransform.working.toRGB(lch)
            let normalized = tint / Swift.max(tint.maxComponent, 1e-6)
            return normalized * level
        }
    }

    /// `testImage` with fine detail added, for the stages that exist to act on detail.
    ///
    /// The modulation is a two-pixel-period ripple of about 0.09 stops, small enough
    /// that a guided base at the reference's 0.1 EV threshold treats it as texture to be
    /// separated rather than as an edge to be preserved, and short enough in period to
    /// live in the fine band rather than the mid one.
    private func texturedTestImage(width: Int = 64, height: Int = 32) -> ImageBuffer {
        let base = testImage(width: width, height: height)
        return ImageBuffer(width: width, height: height) { u, v in
            let x = Int(u * Double(width)), y = Int(v * Double(height))
            let c = base[Swift.min(x, width - 1), Swift.min(y, height - 1)]
            // `cos`, not `sin`. `sin(x * .pi)` is ZERO at every integer x — measured,
            // 1.22e-16 — so this function added no texture whatsoever and every test
            // built on it has been running against a plain ramp while its comments
            // claimed otherwise. `cos(x * .pi)` alternates +1/-1, which is fine detail
            // at the Nyquist limit and exactly what the fine band exists to see.
            //
            // Measured against the reference renderer, Texture +40 with Clarity +30
            // moves the frame 0.0076 on the old image and 0.0253 on this one. The old
            // 0.0076 was the guided filter finding structure in the RAMP, not in any
            // texture — the control was being tested on the one thing it is designed
            // not to touch.
            let ripple = 1.0 + 0.06 * cos(Double(x) * .pi) * cos(Double(y) * .pi * 0.5)
            return c * ripple
        }
    }

    /// The same ramp with MID-scale structure: a 12 px period, which is what Clarity
    /// acts on. `texturedTestImage`'s ripple is `cos(x·π)` — Nyquist, deliberately, so
    /// the FINE band can see it — and Clarity's band, built at radius 3 on this frame,
    /// cannot. Asserting that Clarity moved that frame was asking the mid band about a
    /// picture built to contain nothing it responds to; it measured 0.00098 against a
    /// bar of 0.001 and the real number it was reporting was the ramp leaking through.
    private func midScaleTestImage(width: Int = 64, height: Int = 32) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, v in
            let x = Int(u * Double(width)), y = Int(v * Double(height))
            let ev = -3.0 + 6.0 * Double(x) / Double(width - 1)
            let m = 1.0 + 0.25 * cos(Double(x) * 2 * .pi / 12) * cos(Double(y) * 2 * .pi / 12)
            return RGB(gray: 0.18 * pow(2, ev) * m)
        }
    }

    private func ciImage(from buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data,
                       bytesPerRow: buffer.width * 16,
                       size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf,
                       colorSpace: nil)
    }

    private func readBack(_ image: CIImage, width: Int, height: Int) -> ImageBuffer? {
        // A stage that changed the extent must fail loudly rather than have this read
        // some arbitrary corner of it.
        XCTAssertEqual(image.extent.width, CGFloat(width), accuracy: 0.5)
        XCTAssertEqual(image.extent.height, CGFloat(height), accuracy: 0.5)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let bounds = CGRect(x: image.extent.origin.x, y: image.extent.origin.y,
                            width: CGFloat(width), height: CGFloat(height))
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: nil)
        }
        // A render that wrote nothing — a kernel silently unavailable, a colour-space
        // mismatch, an extent CI decided was empty — leaves this buffer exactly as it
        // was allocated. Every downstream assertion in this file is a comparison, and
        // an all-zero frame satisfies a surprising number of them: "grey stays grey"
        // reads 0 == 0 == 0 and passes at every pixel. This declares `-> ImageBuffer?`
        // and never returned nil, so the `guard let` at each call site could not catch
        // it either. One check here protects every test in the file.
        //
        // Alpha is excluded: `ImageBuffer.init(width:height:)` fills it with 1, but a
        // render that wrote nothing into THIS buffer leaves alpha at 0 too, so a frame
        // whose colour channels are all zero is either black-and-opaque (which no test
        // here produces, since every source is a grey ramp or a step) or a dead read.
        let wroteSomething = stride(from: 0, to: pixels.count, by: 4).contains {
            pixels[$0] != 0 || pixels[$0 + 1] != 0 || pixels[$0 + 2] != 0
        }
        guard wroteSomething else {
            XCTFail("the render produced an all-zero frame — the kernel wrote nothing, "
                        + "and comparing against it would pass by accident")
            return nil
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    /// Compare two buffers pixel for pixel. Safe against the origin convention only
    /// because every test frame here is row-invariant; see `testImage`.
    private func compare(_ a: ImageBuffer, _ b: ImageBuffer,
                         tolerance: Double, label: String) {
        XCTAssertEqual(a.width, b.width, label)
        XCTAssertEqual(a.height, b.height, label)
        guard a.width == b.width, a.height == b.height else { return }
        var worst = 0.0
        var worstAt = (0, 0)
        for y in 0..<a.height {
            for x in 0..<a.width {
                let d = a[x, y].maxAbsDifference(b[x, y])
                if d > worst { worst = d; worstAt = (x, y) }
            }
        }
        XCTAssertLessThan(worst, tolerance,
                          "\(label): worst difference \(worst) at \(worstAt)")
    }

    // MARK: - Shaper

    func testLogEncodeKernelMatchesReference() throws {
        try XCTSkipUnless(KernelLibrary.logEncode != nil, "kernel unavailable")
        let source = testImage()
        let input = ciImage(from: source)
        guard let encoded = KernelLibrary.apply(KernelLibrary.logEncode,
                                                extent: input.extent, [input]),
              let result = readBack(encoded, width: source.width, height: source.height)
        else { return XCTFail("render failed") }

        let expected = source.map { LumenLog.encode($0) }
        compare(expected, result, tolerance: 2e-4, label: "logEncode")
    }

    func testLogRoundTripThroughBothKernels() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let source = testImage()
        let input = ciImage(from: source)
        guard let encoded = KernelLibrary.apply(KernelLibrary.logEncode,
                                                extent: input.extent, [input]),
              let decoded = KernelLibrary.apply(KernelLibrary.logDecode,
                                                extent: input.extent, [encoded]),
              let result = readBack(decoded, width: source.width, height: source.height)
        else { return XCTFail("render failed") }

        // A relative comparison: the domain spans 20 stops, so an absolute tolerance
        // would be meaningless at both ends of it.
        var worstRelative = 0.0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let a = source[x, y]
                let b = result[x, y]
                for channel in 0..<3 {
                    let reference = abs(a[channel])
                    guard reference > 1e-5 else { continue }
                    worstRelative = Swift.max(worstRelative,
                                              abs(a[channel] - b[channel]) / reference)
                }
            }
        }
        XCTAssertLessThan(worstRelative, 0.02,
                          "shaper round trip drifted by \(worstRelative * 100)%")
    }

    // MARK: - Tables

    func testColorCubeMatchesTheBakedTable() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        // A table with real structure in all three channels, so a transposed or
        // mis-strided upload cannot pass by symmetry.
        let lut = LUT3D(size: 17) { c in
            RGB(Num.saturate(c.r * 0.8 + 0.1),
                Num.saturate(c.g * c.g),
                Num.saturate(1 - c.b))
        }
        // Row-invariant, but with three independent functions of u so a transposed or
        // mis-strided upload cannot pass by symmetry.
        let source = ImageBuffer(width: 64, height: 4) { u, _ in
            RGB(u, u * u, 1 - u)
        }
        let input = ciImage(from: source)
        guard let mapped = ColorCube.filter(lut, image: input),
              let result = readBack(mapped, width: source.width, height: source.height)
        else { return XCTFail("cube filter failed") }

        let expected = source.map { lut.sample($0) }
        compare(expected, result, tolerance: 3e-3, label: "CIColorCube")
    }

    // MARK: - Multiply and blend

    func testMultiplyKernelIsUnclamped() throws {
        try XCTSkipUnless(KernelLibrary.multiply != nil, "kernel unavailable")
        let a = ImageBuffer(width: 8, height: 4) { _, _ in RGB(4, 2, 0.5) }
        let b = ImageBuffer(width: 8, height: 4) { _, _ in RGB(3, 3, 3) }
        guard let out = KernelLibrary.apply(KernelLibrary.multiply,
                                            extent: ciImage(from: a).extent,
                                            [ciImage(from: a), ciImage(from: b)]),
              let result = readBack(out, width: 8, height: 4) else {
            return XCTFail("render failed")
        }
        // 12 must survive: a clamping multiply would silently destroy every
        // scene-referred highlight in the app.
        XCTAssertEqual(result[0, 0].r, 12, accuracy: 0.05)
        XCTAssertEqual(result[0, 0].g, 6, accuracy: 0.05)
        XCTAssertEqual(result[0, 0].b, 1.5, accuracy: 0.02)
    }

    func testBlendMaskInterpolates() throws {
        try XCTSkipUnless(KernelLibrary.blendMask != nil, "kernel unavailable")
        let base = ImageBuffer(width: 8, height: 4) { _, _ in RGB(0, 0, 0) }
        let over = ImageBuffer(width: 8, height: 4) { _, _ in RGB(2, 2, 2) }
        let mask = ImageBuffer(width: 8, height: 4) { _, _ in RGB(0.25, 0.25, 0.25) }
        guard let out = KernelLibrary.apply(
            KernelLibrary.blendMask, extent: ciImage(from: base).extent,
            [ciImage(from: base), ciImage(from: over), ciImage(from: mask)]),
              let result = readBack(out, width: 8, height: 4) else {
            return XCTFail("render failed")
        }
        XCTAssertEqual(result[0, 0].r, 0.5, accuracy: 0.01)
    }

    // MARK: - Guided filter

    /// A hard edge with noise on both sides: a blur smears it, a guided filter keeps
    /// it. That difference is the entire reason the tone stage uses one.
    ///
    /// Measured as a ratio against the input, both directions, for the reason the CPU
    /// twin of this test carries at length: the absolute-level version passed on
    /// `guidedSelfFilter` returning its input unchanged, because a plane whose plateaus
    /// are already 0.2 and 0.8 with ±0.02 of noise satisfies "left < 0.35", "right >
    /// 0.65" and "variation < 0.02" before any filter runs.
    func testGuidedFilterSmoothsBelowItsThresholdAndKeepsDetailAbove() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let epsilon = 0.0008
        let threshold = epsilon.squareRoot()

        func step(amplitude: Double) -> ImageBuffer {
            var image = ImageBuffer(width: 64, height: 16)
            for y in 0..<16 {
                for x in 0..<64 {
                    let base = x < 32 ? 0.2 : 0.8
                    image[x, y] = RGB(gray: base
                                          + ((x + y) % 2 == 0 ? amplitude : -amplitude))
                }
            }
            return image
        }

        /// Largest excursion within either plateau, away from the borders and the step.
        func plateauSwing(_ image: ImageBuffer) -> Double {
            var swing = 0.0
            for range in [6..<26, 38..<58] {
                var lo = Double.infinity
                var hi = -Double.infinity
                for y in 4..<12 {
                    for x in range {
                        lo = Swift.min(lo, image[x, y].r)
                        hi = Swift.max(hi, image[x, y].r)
                    }
                }
                swing = Swift.max(swing, hi - lo)
            }
            return swing
        }

        func filtered(_ source: ImageBuffer) throws -> ImageBuffer {
            guard let out = RenderGraph.guidedSelfFilter(ciImage(from: source),
                                                         radius: 4, epsilon: epsilon),
                  let result = readBack(out, width: source.width, height: source.height)
            else { throw XCTSkip("guided filter produced no image") }
            return result
        }

        let quiet = step(amplitude: threshold / 4)
        let smoothed = try filtered(quiet)
        let quietRatio = plateauSwing(smoothed) / plateauSwing(quiet)
        XCTAssertLessThan(quietRatio, 0.45,
                          "noise well under √ε survived at \(quietRatio) of its input "
                              + "swing; an identity filter scores 1.0")

        let loud = step(amplitude: threshold * 3.5)
        let kept = try filtered(loud)
        let loudRatio = plateauSwing(kept) / plateauSwing(loud)
        XCTAssertGreaterThan(loudRatio, 0.4,
                             "detail well over √ε was smoothed away, surviving at only "
                                 + "\(loudRatio) of its input swing")

        // The edge is what neither pass may cost, measured as the difference of the
        // plateau means so the noise cancels out of it.
        for (label, image) in [("quiet", smoothed), ("loud", kept)] {
            var left = 0.0, right = 0.0, n = 0.0
            for y in 4..<12 {
                for x in 6..<26 { left += image[x, y].r }
                for x in 38..<58 { right += image[x, y].r }
                n += 20
            }
            XCTAssertGreaterThan(right / n - left / n, 0.45,
                                 "the \(label) pass smeared the step to "
                                     + "\(right / n - left / n) of 0.6")
        }
    }

    // MARK: - The whole graph

    /// Named for what it is: the colour path, in draft, on a recipe with three sliders
    /// moved. It is NOT neutral — the previous name would have had the next reader
    /// assume neutrality was covered here, which it is not.
    func testGraphMatchesTheReferenceRendererOnTheColourPath() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.5
        recipe.develop.tone.contrast = 25
        recipe.develop.color.saturation = 15
        // Off explicitly: a default recipe denoises, the reference has no S3, and
        // `draft: true` — which used to hide that gap by gating S3 out — is gone.
        recipe.develop.denoise.mode = .off

        let source = testImage(width: 48, height: 12)
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
        let graph = RenderGraph()
        let output = graph.build(ciImage(from: source), plan: plan,
                                 options: RenderGraph.Options(longEdge: 48))
        guard let gpu = readBack(output, width: source.width, height: source.height) else {
            return XCTFail("graph render failed")
        }

        // Presence is zero, sharpening is zero and denoise is forced off, so this
        // compares exactly the colour path: matrix, tone gain, tables.
        let reference = ReferenceRenderer.render(source, plan: plan)

        var worst = 0.0
        for y in 0..<source.height {
            for x in 0..<source.width {
                worst = Swift.max(worst, reference[x, y].maxAbsDifference(gpu[x, y]))
            }
        }
        // Display-referred output in 0…1. 2% was the declared tolerance and the real
        // figure is 2.8% — the two paths sample the same tables by different methods,
        // `CIColorCube`'s trilinear against the reference's tetrahedral, out of fp16
        // storage against doubles. Both are architectural costs of bake-and-fetch, not
        // defects to be found.
        //
        // It is pre-existing and it is stable: the same 0.028001785278320312, to every
        // digit, before and after the presence-epsilon rewrite and the plan-table cache.
        // A bound set from a measurement can hide a regression, so the thing that
        // guards against one here is that stability — a change in interpolation or
        // storage would move this number, and it has not moved.
        XCTAssertLessThan(worst, 0.035,
                          "GPU graph diverged from the reference by \(worst)")
    }

    func testNeutralRecipeLeavesAGreyRampNeutral() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let source = ImageBuffer(width: 32, height: 4) { u, _ in
            RGB(gray: 0.18 * pow(2, -8 + u * 12))
        }
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off   // a default recipe denoises; not the subject
        let plan = RenderPlan(recipe: recipe)
        let output = RenderGraph().build(ciImage(from: source), plan: plan,
                                         options: RenderGraph.Options(longEdge: 32))
        guard let result = readBack(output, width: source.width, height: source.height)
        else { return XCTFail("render failed") }

        // Assert it is a RAMP before asserting it is grey. `r == g == b` is true of
        // any uniform frame, so on its own this passed on a render that wrote nothing
        // — the `readBack` guard now catches that case, and this makes the test itself
        // discriminating rather than relying on the helper.
        XCTAssertGreaterThan(result[31, 2].g, result[0, 2].g * 8,
                             "a 12-stop ramp came back nearly flat")
        XCTAssertGreaterThan(result[16, 2].g, 0.01, "the ramp's middle is at black")

        for x in 0..<source.width {
            let c = result[x, 2]
            XCTAssertEqual(c.r, c.g, accuracy: 0.004, "grey picked up a cast at \(x)")
            XCTAssertEqual(c.g, c.b, accuracy: 0.004, "grey picked up a cast at \(x)")
        }
    }

    /// The spatial stages, compared against the reference at all.
    ///
    /// Every other graph comparison in this file passes `draft: true`, which skips the
    /// spatial stages on both sides — so the GPU denoise, texture, clarity, dehaze,
    /// capture sharpening, vignette and mask rasterization were compared to the
    /// reference renderer NEVER. This is the one that turns them on.
    ///
    /// The tolerance is a SMOKE-TEST BOUND, not a measurement. These stages are
    /// separable-kernel approximations of the reference's exact filters and I have no
    /// GPU to measure the real divergence on, so 0.25 is set to catch a stage wired to
    /// the wrong input, applied twice, or missing entirely — not to certify the last
    /// percent of a blur. Tighten it to the measured value on the first green run;
    /// leaving a number here that was guessed tight would just cost a red cycle.
    ///
    /// The second half of the test carries the real weight and needs no calibration:
    /// turning the spatial stages off must move the picture. Without that, this would
    /// be comparing two copies of the colour path and would pass with every spatial
    /// kernel unwired.
    func testGraphMatchesTheReferenceRendererWithTheSpatialStagesOn() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        var recipe = Recipe()
        recipe.develop.detail.texture = 40
        recipe.develop.detail.clarity = 30
        recipe.look.vignette = -1.0
        // Denoise OFF, and this is not a detail — it is the difference between this
        // golden testing what it claims and testing nothing.
        //
        // `Recipe()` denoises: `ClassicNR.chroma` defaults to 25, so `isIdentity` is
        // false and the graph runs S3 on a default recipe. `ReferenceRenderer.render`
        // starts at S6 and never denoises — the CPU path picks S3 up one level higher,
        // in `PipelineRenderer.renderReference`. So a golden that compares `build`
        // against `ReferenceRenderer.render` on a default recipe is comparing a
        // denoised picture with an undenoised one, and every difference it reports
        // belongs to a stage it is not testing.
        //
        // This passed until the denoise kernels started working. They were compiled as
        // colour kernels, the nine-argument hot-pixel kernel among them, and the stage
        // was quietly skipped; fixing the kernels turned S3 on for every recipe and
        // turned this golden red for a reason that had nothing to do with presence.
        // Denoise has its own goldens, which is where it belongs.
        recipe.develop.denoise.mode = .off

        // `testImage` is a pure horizontal ramp — 20 stops over 64 px and constant down
        // each column. There is no texture in it, so a correct Texture slider moves it
        // by exactly nothing, and this test asserted that it moved. It passed only while
        // the presence bases used an ε meaning a 0.68-stop threshold, which made them
        // blur across the ramp so the "texture" band contained the gradient itself —
        // the same oversized ε that put a 0.72 EV trench beside every hard edge. The
        // assertion was measuring Texture's ability to amplify a smooth gradient.
        //
        // So the frame gets texture: a fine modulation the fine band can see and the
        // mid band cannot, which is what the control is for.
        let source = texturedTestImage(width: 64, height: 32)
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
        let output = RenderGraph().build(ciImage(from: source), plan: plan,
                                         options: RenderGraph.Options(longEdge: 64))
        guard let gpu = readBack(output, width: source.width, height: source.height) else {
            return XCTFail("graph render failed")
        }
        let reference = ReferenceRenderer.render(source, plan: plan)

        var worst = 0.0
        var worstAt = (0, 0)
        for y in 0..<source.height {
            for x in 0..<source.width {
                let d = reference[x, y].maxAbsDifference(gpu[x, y])
                if d > worst { worst = d; worstAt = (x, y) }
            }
        }
        XCTAssertLessThan(worst, 0.25,
                          "the spatial path diverged by \(worst) at \(worstAt)")

        // And each stage actually ran — measured ONE AT A TIME.
        //
        // This used to turn all three on together and assert that something moved. The
        // −1 EV vignette alone cleared that bar by a wide margin, so texture and clarity
        // could be completely unwired and the assertion still passed. They were not
        // unwired, but they were computing their gain on the shaper's encoded plane
        // instead of in stops — a factor of twenty-four — and this is the test that was
        // supposed to notice. A check that a group of stages did *something* is not a
        // check on any one of them.
        func render(_ frame: ImageBuffer,
                    _ mutate: (inout Recipe) -> Void) throws -> ImageBuffer {
            var r = Recipe()
            mutate(&r)
            let p = RenderPlan(recipe: r, lutSize: LUT3D.exportSize)
            guard let out = readBack(
                RenderGraph().build(ciImage(from: frame), plan: p,
                                    options: RenderGraph.Options(longEdge: 64)),
                width: frame.width, height: frame.height) else {
                throw XCTSkip("render failed")
            }
            return out
        }

        /// Peak movement a slider produces on `frame`, GPU or reference.
        func movement(_ frame: ImageBuffer, _ a: ImageBuffer, _ b: ImageBuffer) -> Double {
            var moved = 0.0
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    moved = Swift.max(moved, a[x, y].maxAbsDifference(b[x, y]))
                }
            }
            return moved
        }
        let plain = try render(source) { _ in }

        // The bar is 0.001, and it is derived rather than picked. This 64x32 frame is
        // 20 EV across 64 columns, so its fine-detail band measures 9.9e-3 in the
        // shaper's encoded plane — 0.24 EV. The contract is a gain of 2^(0.36·ΔEV) per
        // stop, giving 2^0.086 = 1.061, about 6% of local contrast, which on the
        // mid-tone pixels this frame actually contains is worth ~0.004 of movement.
        //
        // 0.02 stood here first and was unreachable: it was written expecting the
        // 24x units fix to produce a large number, without measuring what the band on
        // this frame is worth. The three cases the bar has to separate are
        //   dead stage        exactly 0.0     (a radius CIBoxBlur ignores; this is
        //                                     what Texture was doing)
        //   gain in encoded   ~1.5e-4         (the 24x units bug)
        //   contract honoured ~4e-3
        // so 0.001 clears the second by 7x and sits 4x under the third. The measured
        // value is in the message either way, so a miss here is self-diagnosing.
        let texture = movement(source, plain,
                               try render(source) { $0.develop.detail.texture = 40 })
        XCTAssertGreaterThan(texture, 0.001,
                             "Texture +40 moved the frame by \(texture) — 0.0 means the "
                                 + "band collapsed, a few e-4 means the gain is being "
                                 + "computed in the shaper's encoded units, not stops")

        // Clarity gets its own frame, and its own bar, measured against the reference
        // on that frame rather than borrowed from Texture's derivation.
        //
        // A PRESENCE bar cannot catch what was wrong here. Clarity applied between
        // 1/2.6 and 1/48 of the gain `DetailEngine.applyClarity` specifies — on the old
        // frame, 0.00098 against the reference's 0.0096 — and a bar of 0.001 is one
        // measurement away from passing either way. So this compares the two paths
        // directly. They are different algorithms, a single-band remap against a local
        // Laplacian, and will not agree closely; a ratio is what pins how far apart
        // they are allowed to drift.
        var clarityRecipe = Recipe()
        clarityRecipe.develop.denoise.mode = .off
        let midFrame = midScaleTestImage()
        let midPlain = try render(midFrame) { $0.develop.denoise.mode = .off }
        let clarity = movement(midFrame, midPlain, try render(midFrame) {
            $0.develop.denoise.mode = .off
            $0.develop.detail.clarity = 30
        })
        let referencePlain = ReferenceRenderer.render(
            midFrame, plan: RenderPlan(recipe: clarityRecipe))
        clarityRecipe.develop.detail.clarity = 30
        let referenceClarity = movement(
            midFrame, referencePlain,
            ReferenceRenderer.render(midFrame,
                                     plan: RenderPlan(recipe: clarityRecipe)))
        XCTAssertGreaterThan(clarity, 0.001,
                             "Clarity +30 moved the frame by \(clarity)")
        XCTAssertGreaterThan(clarity / referenceClarity, 0.2,
                             "Clarity +30 moved the frame by \(clarity) where the "
                                 + "reference moves it \(referenceClarity) — the GPU is "
                                 + "applying \(referenceClarity / clarity)x less gain "
                                 + "than the stage it is supposed to implement")

        let vignette = movement(source, plain,
                                try render(source) { $0.look.vignette = -1.0 })
        XCTAssertGreaterThan(vignette, 0.05,
                             "a −1 EV vignette moved the frame by \(vignette)")
    }

    // MARK: - S3 denoise

    /// A flat field of profiled noise plus a hard edge and a one-pixel colour line. The
    /// noise is a deterministic hash, so a failure here is reproducible.
    private func noisyFrame(width: Int, height: Int, profile: NoiseProfile,
                            seed: UInt64 = 0x5EED) -> ImageBuffer {
        func mix(_ v: UInt64) -> UInt64 {
            var z = v &+ 0x9E3779B97F4A7C15
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        var buffer = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                var base = RGB(gray: u < 0.5 ? 0.08 : 0.42)
                if x == width - 3 { base = RGB(0.30, 0.16, 0.11) }
                for channel in 0..<3 {
                    let h = mix(seed &+ UInt64(bitPattern: Int64(x &* 73_856_093))
                                &+ UInt64(bitPattern: Int64(y &* 19_349_663))
                                &+ UInt64(channel &* 83_492_791))
                    let u1 = Double(h >> 11) / Double(1 << 53)
                    let u2 = Double(mix(h) >> 11) / Double(1 << 53)
                    let n = (-2 * Foundation.log(Swift.max(u1, 1e-12))).squareRoot()
                        * Foundation.cos(2 * Double.pi * u2)
                    base[channel] = Swift.max(base[channel]
                                              + n * profile.sigma(at: base[channel]), 0)
                }
                buffer[x, y] = base
            }
        }
        return buffer
    }

    private func denoisePlan(_ block: ClassicNR, iso: Double) -> RenderPlan {
        var recipe = Recipe()
        recipe.develop.denoise = Denoise(mode: .classic, classic: block)
        return RenderPlan(recipe: recipe, captureISO: iso)
    }

    /// A single-channel plane as a frame the graph can eat, and back again.
    private func broadcast(_ plane: Plane) -> ImageBuffer {
        var buffer = ImageBuffer(width: plane.width, height: plane.height)
        for y in 0..<plane.height {
            for x in 0..<plane.width { buffer[x, y] = RGB(gray: plane[x, y]) }
        }
        return buffer
    }

    /// A plane with a step, a one-pixel line and noise — every feature a five-tap
    /// filter can get wrong, including two that sit inside the deepest level's reach of
    /// the border.
    ///
    /// The magnitudes are the ones the stage actually works in, and that is not
    /// cosmetic. Written first with a 0.15…0.65 step — image-like numbers — the edge
    /// map came out identically ZERO, because its knees are denominated in the VST
    /// plane's own noise σ and that plane spans tens of units, not tenths. The
    /// comparison would then have been 0 == 0: green for a stage with no edge map at
    /// all. Measured on this plane the map runs the full 0.000…1.000 instead.
    private func testPlane(width: Int = 64, height: Int = 64) -> Plane {
        var plane = Plane(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                var v = x < width / 2 ? -10.0 : 20.0
                if x == width - 3 { v = 25.0 }
                if y == 2 { v += 6.0 }
                v += 0.8 * Foundation.sin(Double(x) * 1.9 + Double(y) * 2.7)
                plane[x, y] = v
            }
        }
        return plane
    }

    /// The plane's own span, so a tolerance can be stated as a fraction of the numbers
    /// being compared rather than as an absolute that means nothing without them.
    private func span(_ plane: Plane) -> Double {
        var lo = Double.infinity
        var hi = -Double.infinity
        for v in plane.values {
            lo = Swift.min(lo, Double(v))
            hi = Swift.max(hi, Double(v))
        }
        return hi - lo
    }

    private func worstDifference(_ got: ImageBuffer, _ expected: Plane) -> (Double, (Int, Int)) {
        var worst = 0.0
        var at = (0, 0)
        for y in 0..<expected.height {
            for x in 0..<expected.width {
                let d = abs(got[x, y].r - expected[x, y])
                if d > worst { worst = d; at = (x, y) }
            }
        }
        return (worst, at)
    }

    // MARK: The primitives S3 is built from, each against its own reference
    //
    // These exist because the first version of this stage failed its end-to-end golden
    // by 71% of the stage's effect and the golden could say nothing about WHERE. A max
    // over a five-level wavelet stack is not a diagnosis. Each of the three below has
    // exactly one reference function and fails on its own.

    /// One à-trous smoothing step, at every dilation the stack uses.
    ///
    /// This is the one that catches a tap landing in the wrong place. At step 16 the
    /// filter reaches 32 px, which on a 64 px frame is every pixel — so a border
    /// convention that disagrees with `Plane.clampedSample` shows up here immediately
    /// rather than as a number at the end of the chain.
    func testAtrousStepMatchesTheReference() throws {
        try XCTSkipUnless(KernelLibrary.bSpline5 != nil, "bSpline5 unavailable")
        let plane = testPlane()
        let input = ciImage(from: broadcast(plane))
        for step in [1, 2, 4, 8, 16] {
            guard let output = RenderGraph.bSplinePass(input, step: step) else {
                return XCTFail("step \(step): the à-trous pass produced nothing")
            }
            guard let got = readBack(output, width: plane.width, height: plane.height)
            else { return XCTFail("step \(step): render failed") }
            let expected = SpatialOps.atrousSmooth(plane, step: step)
            let (worst, at) = worstDifference(got, expected)
            // It must SMOOTH — a pass that returned its input would match nothing, but
            // a pass that returned its input and a reference that did too would match
            // everything, so the movement is asserted separately.
            var moved = 0.0
            for y in 0..<plane.height {
                for x in 0..<plane.width {
                    moved = Swift.max(moved, abs(expected[x, y] - plane[x, y]))
                }
            }
            XCTAssertGreaterThan(moved, span(plane) * 0.05,
                                 "step \(step): the reference barely smoothed anything")
            // 1e-6 of the plane's span. Float32 through this filter is worth about
            // 3e-6 of it; a tap in the wrong place is worth a tenth of it or more.
            XCTAssertLessThan(worst, span(plane) * 1e-5,
                              "step \(step): GPU and reference B3-spline differ by "
                                  + "\(worst) at \(at), on a plane spanning "
                                  + "\(span(plane))")
        }
    }

    /// The three radius-1 box passes the edge map's pre-blur is built from, against the
    /// reference's own three box passes.
    ///
    /// It compared them against `SpatialOps.gaussianBlur(_:sigma: 1.5)`, which was the
    /// same thing only while that function WAS the box approximation. It is exact below
    /// sigma 8 now — because Sharpen Radius, which reads it, was a seven-position switch
    /// otherwise — and the two differ by 0.498 on a plane spanning 42.55. That is the
    /// box approximation's own error against a real Gaussian, which it always had; the
    /// test was reading it as agreement because both sides were approximating
    /// identically.
    ///
    /// `boxApproximatedGaussian` is what the edge map calls and what this asserts. The
    /// bar stays at 1e-5 of the span, because the two sides are once again the same
    /// algorithm and nothing but f32 should separate them.
    func testEdgeBlurMatchesTheReferenceBoxApproximation() throws {
        try XCTSkipUnless(KernelLibrary.box3 != nil, "box3 unavailable")
        let plane = testPlane()
        var blurred = ciImage(from: broadcast(plane))
        for _ in 0..<3 {
            guard let horizontal = KernelLibrary.applyNeighbourhood(
                    KernelLibrary.box3, extent: blurred.extent, reach: 1,
                    [RenderGraph.clamped(blurred), CIVector(x: 1, y: 0)]),
                  let vertical = KernelLibrary.applyNeighbourhood(
                    KernelLibrary.box3, extent: blurred.extent, reach: 1,
                    [RenderGraph.clamped(horizontal), CIVector(x: 0, y: 1)])
            else { return XCTFail("box3 produced nothing") }
            blurred = vertical
        }
        guard let got = readBack(blurred, width: plane.width, height: plane.height)
        else { return XCTFail("blur render failed") }
        let expected = SpatialOps.boxApproximatedGaussian(
            plane, sigma: ClassicalDenoise.edgeBlurSigma)
        let (worst, at) = worstDifference(got, expected)
        XCTAssertLessThan(worst, span(plane) * 1e-5,
                          "the GPU's three box passes differ from the reference's by "
                              + "\(worst) at \(at), on a plane spanning \(span(plane))")

        // And the exact Gaussian is genuinely a DIFFERENT operator, so this test cannot
        // quietly go back to comparing the two by someone re-pointing it at
        // `gaussianBlur`.
        let exact = SpatialOps.gaussianBlur(plane, sigma: ClassicalDenoise.edgeBlurSigma)
        var operatorGap = 0.0
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                operatorGap = Swift.max(operatorGap, abs(expected[x, y] - exact[x, y]))
            }
        }
        XCTAssertGreaterThan(operatorGap, span(plane) * 1e-3,
                             "the box approximation and the exact Gaussian agree to "
                                 + "within 1e-3 of the span — one of them has changed")
    }

    /// The edge map, which is what decides how much of each band survives. A stage
    /// whose edge map is wrong denoises the right amount in the wrong places.
    func testEdgeMapMatchesTheReference() throws {
        try XCTSkipUnless(KernelLibrary.edgeMap != nil && KernelLibrary.box3 != nil,
                          "edge kernels unavailable")
        let plane = testPlane()
        // ISO 6400 needs no rescaling, so the plan's knees are the reference's own —
        // asserted, because a scale of anything but 1 would make this comparison a
        // different question.
        let denoise = ClassicalDenoise(ClassicNR(luma: 60, chroma: 0),
                                       profile: NoiseProfile.forISO(6400))
        let gpu = denoise.gpuPlan(width: plane.width, height: plane.height)
        XCTAssertEqual(gpu.encodedScale, 1, accuracy: 1e-12)

        guard let output = RenderGraph.edgePlane(ciImage(from: broadcast(plane)), gpu: gpu)
        else { return XCTFail("the edge map produced nothing") }
        guard let got = readBack(output, width: plane.width, height: plane.height)
        else { return XCTFail("edge map render failed") }
        let expected = ClassicalDenoise.edgeMap(plane,
                                                blurSigma: ClassicalDenoise.edgeBlurSigma,
                                                lo: ClassicalDenoise.edgeKneeLow,
                                                hi: ClassicalDenoise.edgeKneeHigh)
        let (worst, at) = worstDifference(got, expected)
        // The map must actually select: all-zero or all-one would match a broken
        // reference and would silently disable edge protection in the real stage.
        var low = 1.0
        var high = 0.0
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                low = Swift.min(low, expected[x, y])
                high = Swift.max(high, expected[x, y])
            }
        }
        XCTAssertLessThan(low, 0.1, "the reference edge map never opens")
        XCTAssertGreaterThan(high, 0.9, "the reference edge map never closes")
        XCTAssertLessThan(worst, 1e-4,
                          "GPU and reference edge maps differ by \(worst) at \(at)")
    }

    /// The cross-guided filter the chroma blotch pass runs on, against
    /// `SpatialOps.guidedFilter`.
    ///
    /// This is the one primitive in S3 that goes through a STOCK filter — `CIBoxBlur`,
    /// six times inside the guided filter — and it is the only place in this codebase
    /// where that filter sees signed data, because the chroma planes of a
    /// variance-stabilized image are centred on zero. Every other guided-filter use
    /// here runs on log luminance in [0,1]. If box blurring a signed plane is not what
    /// the reference does, this says so on its own rather than through the blotch
    /// golden three stages downstream.
    /// What `CIBoxBlur` actually computes, against the box the reference computes.
    ///
    /// `testCrossGuidedFilterOnSignedChroma` says the two guided filters disagree and
    /// blames the box blur, but it cannot tell a wrong WINDOW from wrong coefficient
    /// arithmetic downstream — both show up as one number at one pixel. This splits
    /// them: it compares the blur alone, on a plane with no signed values and no hard
    /// edge, where nothing but the window can differ.
    ///
    /// The reference is separable, `(2r+1)` wide, normalised by `2r+1` per axis, and
    /// clamps at the edge. If `CIBoxBlur.radius` is not that same half-width, this fails
    /// and prints the impulse response that names the real window — which is exactly the
    /// mistake this codebase already made once with `CIGaussianBlur.radius`, where the
    /// parameter is a SUPPORT radius and needed multiplying by three to mean sigma.
    func testCIBoxBlurUsesTheWindowTheReferenceUses() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let side = 65

        // MEASURE the mapping, do not assume it. The first run of this test answered
        // that `CIBoxBlur(radius: 8)` lights 7 pixels with a peak of 1/49 — a 7-wide
        // box where the reference uses 17 — so the parameter is not the half-width. One
        // data point is not a mapping, and Apple documents none, so probe a spread of
        // radii and print the implied width for each. Whatever `boxBlur` converts with
        // has to be right at every radius the app actually asks for: 2 and 3 on a
        // thumbnail, 8 for the blotch pass, ~51 for Clarity's mid band at 2560 px.
        var implied: [(asked: Int, width: Double)] = []
        for radius in [2, 3, 4, 6, 8, 12, 16, 24, 32] {
            var impulse = Plane(width: side, height: side)
            impulse[side / 2, side / 2] = 1.0
            guard let blurred = RenderGraph.boxBlurRaw(ciImage(from: broadcast(impulse)),
                                                    radius: radius),
                  let got = readBack(blurred, width: side, height: side)
            else { continue }
            var peak = 0.0
            for x in 0..<side { peak = Swift.max(peak, Double(got[x, side / 2].r)) }
            let width = peak > 0 ? (1.0 / peak).squareRoot() : 0
            implied.append((radius, width))
        }
        let table = implied
            .map { "CIBoxBlur(\($0.asked)) -> \(($0.width * 1000).rounded() / 1000) wide" }
            .joined(separator: ", ")
        print("BOX BLUR MAPPING: \(table)")

        // And the assertion that matters: `RenderGraph.boxBlur` must reproduce the
        // reference's window, whatever conversion it needs to get there.
        for radius in [2, 3, 8, 16] {
            var ramp = Plane(width: side, height: side)
            for y in 0..<side {
                for x in 0..<side { ramp[x, y] = Double(x) * 0.03 + Double(y) * 0.011 }
            }
            let expected = SpatialOps.boxBlur(ramp, radius: radius)
            guard let blurred = RenderGraph.boxBlur(ciImage(from: broadcast(ramp)),
                                                    radius: radius),
                  let got = readBack(blurred, width: side, height: side)
            else { return XCTFail("box blur produced nothing at radius \(radius)") }
            var worst = 0.0
            var at = (0, 0)
            for y in 0..<side {
                for x in 0..<side {
                    let d = abs(Double(got[x, y].r) - expected[x, y])
                    if d > worst { worst = d; at = (x, y) }
                }
            }
            XCTAssertLessThan(worst, 5e-3,
                              "at radius \(radius) the GPU box and the reference box "
                                  + "differ by \(worst) at \(at) on a plain ramp")
        }
    }

    func testCrossGuidedFilterOnSignedChroma() throws {
        try XCTSkipUnless(KernelLibrary.guidedCrossCoefficients != nil,
                          "guided kernels unavailable")
        let width = 64, height = 64
        var signal = Plane(width: width, height: height)
        var guide = Plane(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                // Chroma: signed, centred on zero, with a blob and a hard edge.
                let dx = Double(x) - 32, dy = Double(y) - 32
                let blob = Foundation.exp(-(dx * dx + dy * dy) / (2 * 100))
                signal[x, y] = (x < width / 2 ? -1.5 : 1.5) + 2.0 * blob
                    + 0.4 * Foundation.sin(Double(x) * 2.3 + Double(y) * 1.7)
                // Guide: linear luminance, strictly positive, with the same edge.
                guide[x, y] = x < width / 2 ? 0.06 : 0.40
            }
        }
        let expected = SpatialOps.guidedFilter(input: signal, guide: guide,
                                               radius: ClassicalDenoise.blotchRadius,
                                               epsilon: ClassicalDenoise.blotchEpsilon)
        guard let filtered = RenderGraph.crossGuidedFilter(
            input: ciImage(from: broadcast(signal)),
            guide: ciImage(from: broadcast(guide)),
            radius: ClassicalDenoise.blotchRadius,
            epsilon: ClassicalDenoise.blotchEpsilon)
        else { return XCTFail("the cross-guided filter produced nothing") }
        guard let got = readBack(filtered, width: width, height: height) else {
            return XCTFail("guided filter render failed")
        }
        let (worst, at) = worstDifference(got, expected)
        // It has to have SMOOTHED, or agreeing with the reference proves nothing.
        var moved = 0.0
        for y in 0..<height {
            for x in 0..<width {
                moved = Swift.max(moved, abs(expected[x, y] - signal[x, y]))
            }
        }
        XCTAssertGreaterThan(moved, 0.2,
                             "the reference guided filter barely moved the plane")
        XCTAssertLessThan(worst, span(signal) * 0.02,
                          "GPU and reference guided filters differ by \(worst) at "
                              + "\(at), on a plane spanning \(span(signal)) — "
                              + "CIBoxBlur and the reference's box blur disagree")
    }

    /// The whole S3 chain against `ClassicalDenoise.apply`.
    ///
    /// Nine kernels, five à-trous levels, two edge maps and an inverse transform have to
    /// add up to the same operator the reference defines. Modelled in double precision
    /// the two agree to 9e-16, and in float32 — which is what this context renders in —
    /// to 2e-7; the bar below is 2e-4, three orders looser, because the point is to
    /// catch a wrong kernel rather than to police the last bit.
    ///
    /// Every case also asserts the stage MOVED the frame. A denoise that returns its
    /// input matches nothing and would otherwise sail through a comparison against a
    /// reference that also did nothing.
    /// `applyGamutWarning` on its own, fed a value the CPU says must be flagged.
    ///
    /// `testSoftProofFlagsWhatSRGBCannotHold` renders the whole graph and reports that a
    /// Rec.2020 green comes back as the proofed picture rather than the warning colour.
    /// Everything the CPU can check about that is correct: `finishLUTBeforeProof` is
    /// populated, `finishScale` is 1.0, the table puts the green at
    /// `(0.0646, 0.7053, 0.0542)`, the proof matrix takes that to
    /// `(-0.311, 0.791, -0.012)`, and the excess is 0.3226 — comfortably past the
    /// 2.4e-4 epsilon. `isOutOfGamut` agrees. And `CIColorMatrix` keeps negatives, which
    /// the test above now pins.
    ///
    /// So the loss is inside this stage, and the whole-graph test cannot say where
    /// because eight nodes sit between its input and its assertion. This one hands the
    /// stage the exact display-domain value the table produces, as both the picture and
    /// the unproofed reference, and asks for the flag. Nothing upstream is involved.
    func testTheGamutFlagPaintsOnAKnownOutOfGamutValue() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let proof = SoftProof(enabled: true, space: .srgb,
                              intent: .relativeColorimetric, showGamutWarning: true)
        guard let transform = proof.transform(working: .rec2020) else {
            return XCTFail("no proof transform")
        }
        let width = 4, height = 4
        // The finish table's own output for a Rec.2020 green, measured on the CPU.
        let display = RGB(0.0646, 0.7053, 0.0542)
        let inProof = transform.workingToProof.apply(display)
        print("GAMUT PROBE display \(display) -> proof primaries \(inProof); "
              + "outOfGamut \(transform.isOutOfGamut(display))")

        let source = ImageBuffer(width: width, height: height) { _, _ in display }
        let image = ciImage(from: source)

        // Walk the stage's own chain, node by node, with the same helpers it uses.
        // Every kernel is present and `isAvailable` is true, so nothing is nil and the
        // gate is genuinely computing zero — which means one of these five nodes loses
        // the negative red that IS the entire out-of-gamut signal here. Printing each
        // one names it instead of narrowing by elimination for another round.
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // NOT `readBack`: it fails any all-zero frame, which is right for a render
        // whose output should carry a picture and wrong here, where `over` is
        // legitimately (0,0,0) — the green's positive excursion is 0.791, below the
        // threshold of one. Using it cost a round: the guard fired on a correct value
        // and reported "the kernel wrote nothing" about a kernel that had written
        // exactly the right answer.
        func peek(_ label: String, _ img: CIImage?) {
            guard let img else {
                print("GAMUT CHAIN \(label): nil")
                return
            }
            var pixels = [Float](repeating: -999, count: width * height * 4)
            pixels.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                context.render(img, toBitmap: base, rowBytes: width * 16,
                               bounds: CGRect(x: 0, y: 0, width: width, height: height),
                               format: .RGBAf, colorSpace: nil)
            }
            print("GAMUT CHAIN \(label): "
                  + "(\(pixels[4]), \(pixels[5]), \(pixels[6]))")
        }
        let inProofImage = RenderGraph.applyMatrix(image, transform.workingToProof)
        peek("inProof", inProofImage)
        let negatedImage = RenderGraph.applyMatrix(inProofImage,
                                                   Mat3.diagonal(RGB(gray: -1)))
        peek("negated", negatedImage)
        let overImage = KernelLibrary.apply(KernelLibrary.highlightEnergy,
                                            extent: extent,
                                            [inProofImage, Float(1.0), Float(1.0)])
        peek("over", overImage)
        let underImage = KernelLibrary.apply(KernelLibrary.highlightEnergy,
                                             extent: extent,
                                             [negatedImage, Float(0.0), Float(1.0)])
        peek("under", underImage)
        if let overImage, let underImage {
            let excessImage = KernelLibrary.apply(KernelLibrary.addGlow, extent: extent,
                                                  [overImage, underImage,
                                                   CIVector(x: 1, y: 1, z: 1)])
            peek("excess", excessImage)
            if let excessImage {
                peek("summed", KernelLibrary.apply(KernelLibrary.luminance,
                                                   extent: extent,
                                                   [excessImage,
                                                    CIVector(x: 1, y: 1, z: 1)]))
            }
        }

        let flagged = RenderGraph.applyGamutWarning(image, beforeProof: image,
                                                    proof: transform, finishScale: 1.0)
        guard let got = readBack(flagged, width: width, height: height) else { return }
        print("GAMUT PROBE stage returned \(got[1, 1])")

        // And the in-gamut control, which must NOT be painted.
        let grey = ImageBuffer(width: width, height: height) { _, _ in RGB(gray: 0.18) }
        let greyImage = ciImage(from: grey)
        let unflagged = RenderGraph.applyGamutWarning(greyImage, beforeProof: greyImage,
                                                      proof: transform, finishScale: 1.0)
        guard let leftAlone = readBack(unflagged, width: width, height: height) else {
            return
        }
        print("GAMUT PROBE in-gamut grey returned \(leftAlone[1, 1])")

        XCTAssertLessThan(got[1, 1].maxAbsDifference(SoftProof.warningColor), 0.02,
                          "the stage did not flag a value whose excess is 0.32: "
                              + "\(got[1, 1])")
        XCTAssertLessThan(leftAlone[1, 1].maxAbsDifference(RGB(gray: 0.18)), 0.01,
                          "the stage painted over an in-gamut neutral: \(leftAlone[1, 1])")
    }

    /// A colour matrix has to keep negatives and values above one.
    ///
    /// The whole pipeline assumes this. Scene-referred light runs past 1.0 by design,
    /// the Y0U0V0 rotation produces signed chroma, and the soft proof's gamut test is
    /// `Σ max(v−1,0) + max(−v,0)` in the destination's primaries — which is ZERO for
    /// any pixel whose out-of-gamut excursion is negative, if the matrix that got it
    /// there clamped.
    ///
    /// That is not hypothetical. `testSoftProofFlagsWhatSRGBCannotHold` fails on exactly
    /// four assertions, and the CPU arithmetic says why: a Rec.2020 green lands at
    /// `(-0.311, 0.791, -0.012)` in sRGB primaries. Its positive excursion is 0.791,
    /// BELOW one, so its entire out-of-gamut signal is the negative red. Clamp that and
    /// the excess is 0, the gate never lifts, and the greenest pixel sRGB cannot hold
    /// renders as though it were perfectly in gamut.
    ///
    /// So this asks the question directly, on the same `applyMatrix` every colour stage
    /// in the graph uses. If it passes, the clamp is elsewhere and this stays as the
    /// regression test that says so.
    /// A colour matrix must apply the matrix, not its transpose.
    ///
    /// `applyMatrix` applied the TRANSPOSE of everything handed to it, and not one test
    /// in the suite could see it. The reason is worth keeping: every test that touched
    /// a matrix used `Mat3.diagonal`, which is its own transpose, and the one test that
    /// used a real colour matrix — `testTheVSTAndRotationRoundTrip` — rotates into
    /// Y0U0V0 and straight back, where `(M^-1)^T M^T = (M M^-1)^T = I`. A transposed
    /// pair round trips perfectly. It measured 6e-8 while the basis in between was wrong.
    ///
    /// So this uses an ASYMMETRIC matrix with no special structure and checks the
    /// result against the CPU's own `Mat3.apply`, which is the definition. Transposing
    /// it changes the answer at every channel.
    func testAColourMatrixIsNotItsOwnTranspose() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 4, height = 4
        var m = Mat3.identity
        m.m = [[0.7, 0.2, 0.1],
               [0.05, 0.6, 0.35],
               [0.25, 0.15, 0.9]]
        let v = RGB(0.30, 0.55, 0.80)
        let expected = m.apply(v)
        var transposed = Mat3.identity
        for i in 0..<3 { for j in 0..<3 { transposed.m[i][j] = m.m[j][i] } }
        let wrong = transposed.apply(v)
        // The case has to distinguish the two, or it cannot fail for the bug it names.
        XCTAssertGreaterThan(expected.maxAbsDifference(wrong), 0.05,
                             "this matrix and its transpose agree too closely to tell "
                                 + "them apart")

        let source = ImageBuffer(width: width, height: height) { _, _ in v }
        let out = RenderGraph.applyMatrix(ciImage(from: source), m)
        guard let got = readBack(out, width: width, height: height) else { return }
        XCTAssertLessThan(got[1, 1].maxAbsDifference(expected), 1e-5,
                          "applyMatrix gave \(got[1, 1]); the matrix says \(expected) "
                              + "and its transpose says \(wrong)")
    }

    func testAColourMatrixKeepsNegativesAndValuesAboveOne() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 4, height = 4
        let source = ImageBuffer(width: width, height: height) { _, _ in
            RGB(-0.30, 0.75, 2.50)
        }
        // Identity: the values must survive a matrix that does nothing but exist.
        let through = RenderGraph.applyMatrix(ciImage(from: source),
                                              Mat3.diagonal(RGB(gray: 1.0)) )
        guard let kept = readBack(through, width: width, height: height) else { return }
        XCTAssertEqual(Double(kept[1, 1].r), -0.30, accuracy: 1e-4,
                       "a colour matrix clamped a negative to \(kept[1, 1].r) — every "
                           + "signed value in the pipeline dies here, including the "
                           + "soft proof's negative out-of-gamut excursions")
        XCTAssertEqual(Double(kept[1, 1].b), 2.50, accuracy: 1e-3,
                       "a colour matrix clamped \(kept[1, 1].b) to display white — "
                           + "scene-referred light runs past 1.0 by design")

        // And negation, which is what the gamut test uses to fold the under-zero side
        // into the same clamp as the over-one side.
        let negated = RenderGraph.applyMatrix(ciImage(from: source),
                                              Mat3.diagonal(RGB(gray: -1.0)))
        guard let flipped = readBack(negated, width: width, height: height) else { return }
        XCTAssertEqual(Double(flipped[1, 1].r), 0.30, accuracy: 1e-4,
                       "negating -0.30 gave \(flipped[1, 1].r)")
        XCTAssertEqual(Double(flipped[1, 1].g), -0.75, accuracy: 1e-4,
                       "negating 0.75 gave \(flipped[1, 1].g) — the negative side of "
                           + "the gamut test is being clamped away")
    }

    /// The variance-stabilizing transform and the Y0U0V0 rotation, round-tripped.
    ///
    /// Four primitive goldens now cover the a-trous step, the edge blur, the edge map
    /// and the cross guided filter, and all four PASS while
    /// `testDenoiseMatchesTheReferenceEngine` fails by 71% of the stage's own effect.
    /// Correct primitives inside a wrong stage means the fault is in the composition,
    /// and `grep` says the VST and the rotation have zero coverage of any kind — the
    /// only part of `applyDenoise` no test touches. Every defect found in this file
    /// today has been in exactly that position.
    ///
    /// A round trip is the sharpest thing to ask of them: forward, rotate, rotate back,
    /// inverse. It should return the input. The rotation carries SIGNED chroma, which is
    /// the value class this codebase keeps losing — `CISubtractBlendMode` clamped it,
    /// `CIBoxBlur` averaged the wrong window over it — so if `CIColorMatrix` clamps or
    /// the transform is not its own inverse, this says so without needing the reference
    /// engine at all.
    func testTheVSTAndRotationRoundTrip() throws {
        try XCTSkipUnless(KernelLibrary.denoiseAvailable, "denoise kernels unavailable")
        let iso = 6400.0
        let width = 64, height = 64
        let source = noisyFrame(width: width, height: height,
                                profile: NoiseProfile.forISO(iso))
        let plan = denoisePlan(ClassicNR(luma: 60, chroma: 50, colorSmoothness: 0),
                               iso: iso)
        let gpu = plan.classicalDenoise.gpuPlan(width: width, height: height,
                                                noiseScale: 1)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let shot = gpu.profile.a
        let offset = 0.375 * shot * shot + gpu.profile.b

        guard let forward = KernelLibrary.apply(
            KernelLibrary.denoiseForward, extent: extent,
            [ciImage(from: source), Float(shot), Float(offset),
             Float(gpu.pedestalSignal), Float(gpu.sqrtPedestal),
             Float(Swift.max(gpu.signalFloor, -1e30)), Float(gpu.encodedScale)])
        else { return XCTFail("forward VST produced nothing") }

        // The stabilized plane's magnitudes, which decide whether half-float can hold
        // it — the shipping context is RGBAh while this test's is RGBAf.
        if let stabilized = readBack(forward, width: width, height: height) {
            var lo = Double.infinity, hi = -Double.infinity
            for y in 0..<height {
                for x in 0..<width {
                    lo = Swift.min(lo, Double(stabilized[x, y].r))
                    hi = Swift.max(hi, Double(stabilized[x, y].r))
                }
            }
            // Half has a 10-bit mantissa, so its step near a value is
            // `2^(floor(log2 v) - 10)`. Printed because the SHIPPING context is RGBAh
            // while this test's is RGBAf: if the stabilized plane spans tens of units,
            // half cannot resolve the thresholds being compared against it, and every
            // preview and export would denoise differently from every golden.
            let halfStep = lo.isFinite && hi > 0
                ? pow(2.0, (log2(hi)).rounded(.down) - 10.0) : 0
            print("VST PLANE spans \(lo) ... \(hi); half-float step at the top is "
                  + "\(halfStep)")
        }

        let rotated = Self.roundTripRotate(forward)
        guard let restored = KernelLibrary.apply(
            KernelLibrary.denoiseInverse, extent: extent,
            [rotated, Float(shot), Float(gpu.pedestalSignal), Float(gpu.sqrtPedestal),
             Float(1.0 / gpu.encodedScale),
             Float(Swift.max(gpu.minimumForwardRelative, -1e30)),
             Float(gpu.referenceLevel), Float(gpu.unbiasedGain), Float(0)])
        else { return XCTFail("inverse VST produced nothing") }
        guard let got = readBack(restored, width: width, height: height) else { return }

        var worst = 0.0
        var at = (0, 0)
        var span = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let d = got[x, y].maxAbsDifference(source[x, y])
                if d > worst { worst = d; at = (x, y) }
                span = Swift.max(span, source[x, y].maxComponent)
            }
        }
        print("VST ROUND TRIP worst \(worst) at \(at) on a frame spanning \(span)")
        XCTAssertLessThan(worst, span * 0.01,
                          "forward -> rotate -> unrotate -> inverse lost \(worst) at "
                              + "\(at) on a frame spanning \(span) — the VST or the "
                              + "Y0U0V0 rotation is not its own inverse")
    }

    /// Rotate into Y0U0V0 and straight back out, through the same helper the stage uses.
    private static func roundTripRotate(_ image: CIImage) -> CIImage {
        let there = RenderGraph.applyMatrix(image, ClassicalDenoise.toY0U0V0)
        return RenderGraph.applyMatrix(there, ClassicalDenoise.fromY0U0V0)
    }

    func testDenoiseMatchesTheReferenceEngine() throws {
        try XCTSkipUnless(KernelLibrary.denoiseAvailable, "denoise kernels unavailable")
        let iso = 6400.0
        let profile = NoiseProfile.forISO(iso)
        let width = 64, height = 64
        let source = noisyFrame(width: width, height: height, profile: profile)
        let input = ciImage(from: source)

        // Colour Smoothness is 0 in every case here, which takes the guided-filter
        // blotch pass out: that pass runs through CIBoxBlur, whose border handling is
        // Core Image's rather than the reference's, and mixing it in would blur the
        // question this test is asking. It gets its own case below.
        let cases: [(String, ClassicNR)] = [
            ("luma only", ClassicNR(luma: 60, chroma: 0, colorSmoothness: 0)),
            ("colour only", ClassicNR(luma: 0, chroma: 50, colorSmoothness: 0)),
            ("both, LR defaults", ClassicNR(luma: 40, chroma: 40, colorSmoothness: 0)),
            ("detail and contrast", ClassicNR(luma: 80, chroma: 60, lumaDetail: 85,
                                              lumaContrast: 60, colorDetail: 90,
                                              colorSmoothness: 0)),
        ]
        for (name, block) in cases {
            let plan = denoisePlan(block, iso: iso)
            let expected = plan.classicalDenoise.apply(source)
            let output = RenderGraph().applyDenoise(
                input, plan: plan,
                options: RenderGraph.Options(longEdge: width))
            guard let got = readBack(output, width: width, height: height) else {
                return XCTFail("\(name): denoise render failed")
            }
            var moved = 0.0
            var worst = 0.0
            var worstAt = (0, 0)
            for y in 0..<height {
                for x in 0..<width {
                    moved = Swift.max(moved,
                                      expected[x, y].maxAbsDifference(source[x, y]))
                    let d = got[x, y].maxAbsDifference(expected[x, y])
                    if d > worst { worst = d; worstAt = (x, y) }
                }
            }
            XCTAssertGreaterThan(moved, 1e-3,
                                 "\(name): the reference moved the frame by \(moved), "
                                     + "so matching it proves nothing")
            XCTAssertLessThan(worst, 2e-4,
                              "\(name): GPU and reference differ by \(worst) at "
                                  + "\(worstAt), against a stage effect of \(moved)")
        }
    }

    /// The blotch pass, on its own, with a looser bar for the reason above: its guided
    /// filter runs on CIBoxBlur, and the reference's runs on its own box blur.
    func testDenoiseBlotchPassTracksTheReference() throws {
        try XCTSkipUnless(KernelLibrary.denoiseAvailable, "denoise kernels unavailable")
        let iso = 12800.0
        let profile = NoiseProfile.forISO(iso)
        let width = 64, height = 64
        var source = noisyFrame(width: width, height: height, profile: profile)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - 32, dy = Double(y) - 32
                let blob = Foundation.exp(-(dx * dx + dy * dy) / (2 * 100))
                var c = source[x, y]
                c.r += 0.02 * blob
                c.b -= 0.02 * blob
                source[x, y] = c
            }
        }
        let block = ClassicNR(luma: 0, chroma: 70, colorSmoothness: 100)
        let plan = denoisePlan(block, iso: iso)
        let expected = plan.classicalDenoise.apply(source)
        let output = RenderGraph().applyDenoise(
            ciImage(from: source), plan: plan,
            options: RenderGraph.Options(longEdge: width))
        guard let got = readBack(output, width: width, height: height) else {
            return XCTFail("blotch render failed")
        }
        var moved = 0.0
        var worst = 0.0
        for y in 0..<height {
            for x in 0..<width {
                moved = Swift.max(moved, expected[x, y].maxAbsDifference(source[x, y]))
                worst = Swift.max(worst, got[x, y].maxAbsDifference(expected[x, y]))
            }
        }
        XCTAssertGreaterThan(moved, 1e-3, "the reference blotch pass did nothing")
        XCTAssertLessThan(worst, moved * 0.25,
                          "the blotch pass differs from the reference by \(worst), a "
                              + "quarter or more of the \(moved) it is meant to remove")
    }

    /// Hot Pixels: the branchless sorting-network kernel against the branchy reference.
    /// Both halves — the spikes must go, and the one-pixel line must not.
    func testHotPixelKernelMatchesTheReference() throws {
        try XCTSkipUnless(KernelLibrary.hotPixel != nil, "hot pixel kernel unavailable")
        let iso = 3200.0
        let profile = NoiseProfile.forISO(iso)
        let width = 48, height = 48
        var source = noisyFrame(width: width, height: height, profile: profile)
        for y in 0..<height { source[24, y] = RGB(gray: 0.6) }
        source[8, 8] = RGB(gray: 0.95)
        source[30, 12] = RGB(gray: 0.0)

        let block = ClassicNR(luma: 0, chroma: 0, hotPixels: 60)
        let plan = denoisePlan(block, iso: iso)
        let expected = plan.classicalDenoise.hotPixelPass(source)
        let output = RenderGraph().applyDenoise(
            ciImage(from: source), plan: plan,
            options: RenderGraph.Options(longEdge: width))
        guard let got = readBack(output, width: width, height: height) else {
            return XCTFail("hot pixel render failed")
        }
        XCTAssertLessThan(expected[8, 8].g, 0.3, "the reference kept the bright spike")
        XCTAssertLessThan(got[8, 8].g, 0.3,
                          "the kernel kept the bright spike at \(got[8, 8].g)")
        XCTAssertGreaterThan(got[30, 12].g, 0.05,
                             "the kernel kept the dark spike at \(got[30, 12].g)")
        for y in [4, 20, 36, 44] {
            XCTAssertEqual(got[24, y].g, source[24, y].g, accuracy: 1e-4,
                           "the kernel ate the one-pixel line at row \(y)")
        }
        var worst = 0.0
        for y in 0..<height {
            for x in 0..<width {
                worst = Swift.max(worst, got[x, y].maxAbsDifference(expected[x, y]))
            }
        }
        XCTAssertLessThan(worst, 1e-4,
                          "the sorting network disagrees with the reference by \(worst)")
    }

    /// The trace that matters: the slider reaches the picture through `build`, which is
    /// what the loupe and the export both call — not through a stage a test poked
    /// directly.
    func testDenoiseReachesTheShippingGraph() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let iso = 6400.0
        let profile = NoiseProfile.forISO(iso)
        let width = 64, height = 64
        let source = noisyFrame(width: width, height: height, profile: profile)
        let input = ciImage(from: source)

        func render(_ denoise: Denoise) throws -> ImageBuffer {
            var recipe = Recipe()
            recipe.develop.denoise = denoise
            let plan = RenderPlan(recipe: recipe, captureISO: iso)
            let out = RenderGraph().build(
                input, plan: plan,
                options: RenderGraph.Options(longEdge: width))
            guard let buffer = readBack(out, width: width, height: height) else {
                throw RenderError.renderFailed
            }
            return buffer
        }

        func spread(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
            var worst = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    worst = Swift.max(worst, a[x, y].maxAbsDifference(b[x, y]))
                }
            }
            return worst
        }

        let strong = Denoise(mode: .classic, classic: ClassicNR(luma: 80, chroma: 80))
        let off = try render(Denoise(mode: .off))
        let on = try render(strong)
        XCTAssertGreaterThan(spread(off, on), 5e-3,
                             "the denoise sliders moved the shipping render by "
                                 + "\(spread(off, on))")

        // Off really is off: a recipe that says off must render what an untouched
        // Tier 1 renders, not merely something different from `on`.
        let quiet = try render(Denoise(mode: .classic,
                                       classic: ClassicNR(luma: 0, chroma: 0)))
        XCTAssertLessThan(spread(off, quiet), 1e-5,
                          "Off and an all-zero Classic block rendered differently")
    }

    func testMidGreyLandsWhereTheTransformPromises() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let source = ImageBuffer(width: 8, height: 4) { _, _ in RGB(gray: 0.18) }
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off   // a default recipe denoises; not the subject
        let plan = RenderPlan(recipe: recipe)
        let output = RenderGraph().build(ciImage(from: source), plan: plan,
                                         options: RenderGraph.Options(longEdge: 8))
        guard let result = readBack(output, width: 8, height: 4) else {
            return XCTFail("render failed")
        }
        XCTAssertEqual(result[4, 2].g, 0.18, accuracy: 0.006)
    }

    // MARK: - Geometry

    func testCropUsesImageCoordinates() {
        // A frame whose top half is white and bottom half is black. Cropping the top
        // quarter must return white — this is the y-flip that Core Image's bottom-up
        // extent makes so easy to get backwards.
        let source = ImageBuffer(width: 16, height: 16) { _, v in
            RGB(gray: v < 0.5 ? 1.0 : 0.0)
        }
        var recipe = Recipe()
        recipe.develop.geometry.crop = Crop(x: 0, y: 0, w: 1, h: 0.25)

        let cropped = PipelineRenderer.applyGeometry(ciImage(from: source), recipe: recipe)
        guard let result = readBack(cropped, width: 16, height: 4) else {
            return XCTFail("crop render failed")
        }
        var total = 0.0
        for y in 0..<result.height {
            for x in 0..<result.width { total += result[x, y].g }
        }
        let mean = total / Double(result.width * result.height)
        XCTAssertGreaterThan(mean, 0.9, "crop took the wrong end of the frame")
    }

    // MARK: - Soft proof

    /// A frame with a saturated Rec.2020 green in one half and a neutral in the other,
    /// proofed to sRGB with the warning on. Both halves are asserted: the green has to
    /// be flagged and the neutral has to be left exactly where it was.
    ///
    /// The flag is the one part of the proof that is NOT baked into the finish table —
    /// a trilinear table cannot hold a step — so it is a graph stage, and this is the
    /// only thing that can check that stage got the destination's primaries the right
    /// way round. Getting `workingToProof` backwards produces a plausible-looking
    /// picture that flags the wrong colours.
    func testSoftProofFlagsWhatSRGBCannotHold() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 32, height = 8
        let source = ImageBuffer(width: width, height: height) { u, _ in
            u < 0.5 ? RGB(0.02, 1.1, 0.02) : RGB(gray: 0.18)
        }
        let proof = SoftProof(enabled: true, space: .srgb,
                              intent: .relativeColorimetric, showGamutWarning: true)
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off   // a default recipe denoises; not the subject
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize,
                              softProof: proof)
        let options = RenderGraph.Options(longEdge: width)
        let output = RenderGraph().build(ciImage(from: source), plan: plan,
                                         options: options)
        guard let gpu = readBack(output, width: width, height: height) else {
            return XCTFail("proofed render failed")
        }

        let flag = SoftProof.warningColor
        XCTAssertLessThan(gpu[4, 4].maxAbsDifference(flag), 0.02,
                          "a Rec.2020 green was not flagged: \(gpu[4, 4])")
        XCTAssertGreaterThan(gpu[28, 4].maxAbsDifference(flag), 0.05,
                             "mid-grey is inside sRGB and must not be flagged")

        // And the neutral half has to survive proofing untouched, which is the half a
        // stage that tinted everything would still pass without.
        let plain = RenderGraph().build(ciImage(from: source),
                                        plan: RenderPlan(recipe: recipe,
                                                         lutSize: LUT3D.exportSize),
                                        options: options)
        guard let unproofed = readBack(plain, width: width, height: height) else {
            return XCTFail("unproofed render failed")
        }
        XCTAssertLessThan(gpu[28, 4].maxAbsDifference(unproofed[28, 4]), 0.01,
                          "the proof moved an in-gamut neutral")

        // The CPU reference has to agree about which pixels are flagged, or the two
        // paths are showing two different instruments.
        let reference = ReferenceRenderer.render(source, plan: plan)
        for x in [2, 8, 14, 20, 26, 30] {
            let gpuFlagged = gpu[x, 4].maxAbsDifference(flag) < 0.02
            let refFlagged = reference[x, 4].maxAbsDifference(flag) < 0.02
            XCTAssertEqual(gpuFlagged, refFlagged,
                           "graph and reference disagree about column \(x)")
        }
    }

    /// With the warning off the proof is pure table work, and it must still change a
    /// colour sRGB cannot hold while leaving one it can.
    func testSoftProofWithoutTheWarningStillMapsIntoTheDestination() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 16, height = 4
        let source = ImageBuffer(width: width, height: height) { u, _ in
            u < 0.5 ? RGB(0.02, 1.1, 0.02) : RGB(gray: 0.18)
        }
        let options = RenderGraph.Options(longEdge: width)
        var quietRecipe = Recipe()
        quietRecipe.develop.denoise.mode = .off   // a default recipe denoises
        let proof = SoftProof(enabled: true, space: .srgb,
                              intent: .relativeColorimetric, showGamutWarning: false)
        guard let proofed = readBack(
                RenderGraph().build(ciImage(from: source),
                                    plan: RenderPlan(recipe: quietRecipe,
                                                     lutSize: LUT3D.exportSize,
                                                     softProof: proof),
                                    options: options),
                width: width, height: height),
              let plain = readBack(
                RenderGraph().build(ciImage(from: source),
                                    plan: RenderPlan(recipe: quietRecipe,
                                                     lutSize: LUT3D.exportSize),
                                    options: options),
                width: width, height: height)
        else { return XCTFail("render failed") }

        XCTAssertGreaterThan(proofed[2, 2].maxAbsDifference(plain[2, 2]), 0.02,
                             "proofing did nothing to a colour sRGB cannot store")
        XCTAssertLessThan(proofed[13, 2].maxAbsDifference(plain[13, 2]), 0.01,
                          "proofing moved a neutral")
    }

    // MARK: - Export dither

    /// The dither has to move pixels, has to move them by less than one output code,
    /// and has to leave the tile's mean where it was. All three, because a stage that
    /// added a constant would pass the first, one that did nothing would pass the
    /// second and third, and one that added visible noise would pass the first and last.
    func testDitherMovesPixelsByUnderOneCodeWithoutMovingTheMean() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let side = Dither.matrixSide
        let level = 0.18
        let source = ImageBuffer(width: side, height: side) { _, _ in RGB(gray: level) }
        let input = ciImage(from: source)
        let dithered = PipelineRenderer.applyDither(input, colorSpace: .srgb, bitDepth: 8)
        guard let result = readBack(dithered, width: side, height: side) else {
            return XCTFail("dither render failed")
        }

        let step = Dither.codeStep(level, transfer: .srgb, levels: 256)
        var distinct = Set<Float>()
        var sum = 0.0
        var worst = 0.0
        for y in 0..<side {
            for x in 0..<side {
                let v = result[x, y].g
                distinct.insert(Float(v))
                sum += v
                worst = Swift.max(worst, abs(v - level))
            }
        }
        XCTAssertGreaterThan(distinct.count, 8,
                             "a flat patch came back flat — the dither did nothing")
        // Half a code, plus room for the fp16 the graph stores intermediates in.
        XCTAssertLessThan(worst, step * 0.5 + step * 0.1,
                          "the dither moved a pixel by \(worst / step) codes")
        XCTAssertEqual(sum / Double(side * side), level, accuracy: step * 0.05,
                       "the dither shifted the tile's mean, so it is a bias not a dither")
    }

    /// The two `ColorCube.filter` entry points are the SAME filter.
    ///
    /// This is the guarantee the cached-bytes overload rests on, and no other test in
    /// this file can see it: both paths set the same dimension and the same bytes on the
    /// same stock filter, so every golden passes either way and a divergence would show
    /// up only as a wrong picture in somebody's photographs. Asserted on a table with
    /// real structure per channel — an identity cube would agree even if the bytes were
    /// transposed.
    func testBakedCubeRendersIdenticallyToRebuildingItPerCall() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let lut = LUT3D(size: 17) { c in
            RGB(c.r * c.r, sqrt(c.g), 1 - c.b)
        }
        let side = 16
        let source = ImageBuffer(width: side, height: side) { x, y in
            RGB(Double(x) / Double(side - 1), Double(y) / Double(side - 1), 0.5)
        }
        let input = ciImage(from: source)
        guard let perCall = ColorCube.filter(lut, image: input),
              let cached = ColorCube.filter(ColorCube.Baked(lut), image: input),
              let a = readBack(perCall, width: side, height: side),
              let b = readBack(cached, width: side, height: side)
        else { return XCTFail("cube render failed") }

        for y in 0..<side {
            for x in 0..<side {
                XCTAssertEqual(a[x, y].maxAbsDifference(b[x, y]), 0,
                               "the cached cube changed the picture at \(x),\(y)")
            }
        }
    }

    /// The dither's step table is copied once, not once per frame.
    ///
    /// The defect this pins was invisible to every other test here, because the picture
    /// was always right: `ColorCube.filter` rebuilt a fresh 4 MB `Data` from the same
    /// `static let` table on every call, and `renderPreview` dithers every frame it
    /// shows. Only the storage identity can tell the fixed version from the broken one,
    /// so a revert — `forTransfer` handing back a `LUT3D` again — fails here rather than
    /// in a drag nobody is profiling.
    func testDitherStepTableIsCopiedOnceAndReusedAcrossFrames() {
        let first = DitherStepCube.forTransfer(.srgb)
        let second = DitherStepCube.forTransfer(.srgb)
        XCTAssertEqual(first.size, 64, "the step table's size is part of its accuracy")
        XCTAssertEqual(first.data.count, 64 * 64 * 64 * 4 * MemoryLayout<Float>.size)
        // `Data` compares equal by CONTENT, so equality would pass on two fresh copies
        // and prove nothing. The shared backing store is the whole claim.
        let shared = first.data.withUnsafeBytes { a in
            second.data.withUnsafeBytes { b in a.baseAddress == b.baseAddress }
        }
        XCTAssertTrue(shared, "the 4 MB dither table was copied again for this frame")
    }

    /// 16-bit does not band, and paying for a dither there would be noise for nothing.
    func testDitherLeaves16BitAlone() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let source = ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0.18) }
        let input = ciImage(from: source)
        let out = PipelineRenderer.applyDither(input, colorSpace: .srgb, bitDepth: 16)
        guard let result = readBack(out, width: 8, height: 8) else {
            return XCTFail("render failed")
        }
        for y in 0..<8 {
            for x in 0..<8 {
                XCTAssertEqual(result[x, y].g, 0.18, accuracy: 1e-4)
            }
        }
    }

    // MARK: - The log-luminance guide floors at zero (docs/31 round two §5)

    /// A negative-luminance pixel must encode the way the reference encodes it:
    /// floored at zero FIRST, so it lands at `LumenLog.encode(0)` ≈ +0.0024.
    ///
    /// Scene-linear luminance goes negative routinely after white balance, and the
    /// shaper's toe is linear and UNBOUNDED below — the GPU guide encoded −0.01 to
    /// −4.83 where `ReferenceRenderer.applyTone` (which guides on
    /// `LumenLog.encode(max(lum, 0))`) gives +0.0024. One such pixel drives the
    /// guided filter's `a` from 0.087 to 0.917 across a 103×103 patch: the
    /// edge-aware tone mask degenerates into the raw luminance around every deep
    /// saturated shadow. This pins the encode itself, which is the number
    /// everything downstream inherits.
    func testLogLuminanceFloorsANegativeLuminancePixelAtZero() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 8, height = 4
        // Left half: the audit's own probe value, −0.01 in every channel — a pixel
        // whose luminance is unambiguously negative. Right half: mid-grey, so the
        // floor provably does not touch positive luminance.
        let source = ImageBuffer(width: width, height: height) { u, _ in
            u < 0.5 ? RGB(-0.01, -0.01, -0.01) : RGB(gray: 0.18)
        }
        guard let lum = RenderGraph.logLuminance(ciImage(from: source)),
              let result = readBack(lum, width: width, height: height)
        else { return XCTFail("logLuminance render failed") }

        let floored = LumenLog.encode(0)
        let grey = LumenLog.encode(0.18)
        XCTAssertEqual(Double(result[1, 1].g), floored, accuracy: 2e-4,
                       "a −0.01 luminance encoded to \(result[1, 1].g) — the "
                           + "reference floors at zero first and gives \(floored); "
                           + "the unbounded toe gives −4.83, which is the "
                           + "guided-filter blowup of docs/31 round two §5")
        XCTAssertEqual(Double(result[6, 1].g), grey, accuracy: 2e-4,
                       "the floor moved a positive-luminance pixel")
    }

    // MARK: - Texture's gain carries the reference's ±4 EV limit (docs/31 R2 §15)

    /// The texture kernels' exponent clamps at ±4 EV, exactly where the reference
    /// clamps every presence excursion (`DetailEngine.applyLumaRatio(limit: 4)`).
    ///
    /// Driven at the kernel level, because that is where the limit lives: a band
    /// of 0.5 encoded units (12 EV) under Texture +100's own coefficient
    /// (0.9 · range = 21.6 per encoded unit) asks for 2^10.8 ≈ 1783× — the
    /// unbounded gain the GPU used to apply — and must get 2^4 = 16.
    func testTextureGainClampsAtFourEVLikeTheReference() throws {
        try XCTSkipUnless(KernelLibrary.detailGain != nil
                              && KernelLibrary.detailGainGated != nil,
                          "kernels unavailable")
        let width = 8, height = 4
        let hi = ciImage(from: ImageBuffer(width: width, height: height) { _, _ in
            RGB(gray: 0.75)
        })
        let lo = ciImage(from: ImageBuffer(width: width, height: height) { _, _ in
            RGB(gray: 0.25)
        })
        // A gate plane of zero coherence: fully open for both signs, so the clamp
        // — not the gate — is what bounds the result.
        let gate = ciImage(from: ImageBuffer(width: width, height: height) { _, _ in
            RGB(gray: 0)
        })
        let k = 100.0 / 100.0 * 0.9 * LumenLog.range

        guard let up = KernelLibrary.apply(KernelLibrary.detailGain,
                                           extent: hi.extent, [hi, lo, Float(k)]),
              let upPixels = readBack(up, width: width, height: height)
        else { return XCTFail("detailGain render failed") }
        XCTAssertEqual(Double(upPixels[2, 2].g), 16.0, accuracy: 0.5,
                       "a 12 EV band at Texture +100 produced a gain of "
                           + "\(upPixels[2, 2].g) — the reference clamps the "
                           + "excursion at +4 EV (gain 16); unbounded it is 2^10.8")

        guard let down = KernelLibrary.apply(KernelLibrary.detailGain,
                                             extent: hi.extent, [hi, lo, Float(-k)]),
              let downPixels = readBack(down, width: width, height: height)
        else { return XCTFail("detailGain render failed") }
        XCTAssertEqual(Double(downPixels[2, 2].g), 0.0625, accuracy: 0.002,
                       "the negative direction must clamp at −4 EV (gain 1/16), "
                           + "got \(downPixels[2, 2].g)")

        guard let gated = KernelLibrary.apply(
                KernelLibrary.detailGainGated, extent: hi.extent,
                [hi, lo, gate, Float(k), Float(0.0),
                 Float(DetailEngine.texturePositiveGateLo),
                 Float(DetailEngine.texturePositiveGateHi)]),
              let gatedPixels = readBack(gated, width: width, height: height)
        else { return XCTFail("detailGainGated render failed") }
        XCTAssertEqual(Double(gatedPixels[2, 2].g), 16.0, accuracy: 0.5,
                       "the gated kernel must carry the same ±4 EV clamp, got "
                           + "\(gatedPixels[2, 2].g)")
    }

    // MARK: - The vignette clamps its amount like the reference (docs/31 R2 §15)

    /// An out-of-range vignette amount renders the reference's picture, not a
    /// deeper one: `DetailEngine.vignette` opens with `clamp(ev, −3, +1)` and the
    /// GPU stage took the raw value, so a recipe carrying −5 (a foreign sidecar, a
    /// hand-edited file — the slider never leaves −3…+1) burned its corners 2^2
    /// darker on the GPU than on the reference path.
    func testTheVignetteClampsItsAmountLikeTheReference() throws {
        try XCTSkipUnless(KernelLibrary.vignette != nil, "kernel unavailable")
        let width = 64, height = 32
        // Uniform mid-grey: the vignette is then the only structure, and the frame
        // is symmetric about both axes, so the row-order convention cannot bite.
        let source = ImageBuffer(width: width, height: height) { _, _ in
            RGB(gray: 0.18)
        }
        let gpuImage = RenderGraph().applyVignette(ciImage(from: source), ev: -5,
                                                   feather: Look.vignetteFeatherDefault,
                                                   crop: Crop())
        guard let gpu = readBack(gpuImage, width: width, height: height) else {
            return XCTFail("vignette render failed")
        }
        let reference = DetailEngine.vignette(source, ev: -5)

        var worst = 0.0
        var worstAt = (0, 0)
        for y in 0..<height {
            for x in 0..<width {
                let d = reference[x, y].maxAbsDifference(gpu[x, y])
                if d > worst { worst = d; worstAt = (x, y) }
            }
        }
        // The corner at −3 (clamped) is 0.0225; unclamped −5 delivers 0.0056 — a
        // 0.017 gap this bar sits well under, while the kernel's own f16/f32 error
        // plus the exponent dither (±0.006 EV ≈ 0.4% of gain) sit an order of
        // magnitude below it.
        XCTAssertLessThan(worst, 0.005,
                          "vignette at −5 diverged from the reference by \(worst) "
                              + "at \(worstAt) — the GPU stage is missing the "
                              + "reference's clamp(ev, −3, +1)")
    }

    // MARK: - The vignette's feather agrees between the renderers (docs/32 E4)

    /// One recipe feather, two renderers, the same geometry — at every stop of the
    /// range. Both paths derive the inner radius through the ONE function
    /// (`DetailEngine.vignetteInnerRadius(feather:)`), and this golden is what makes
    /// re-deriving it in either place a red build instead of a drifted picture. The
    /// default-feather case doubles as the compatibility anchor: recipes without the
    /// field must render the geometry both renderers always drew (LumenCore pins
    /// `vignetteInnerRadius(feather: 50) == vignetteInnerRadius` on its side).
    func testTheVignetteFeatherAgreesBetweenTheRenderers() throws {
        try XCTSkipUnless(KernelLibrary.vignette != nil, "kernel unavailable")
        let width = 64, height = 32
        let source = ImageBuffer(width: width, height: height) { _, _ in
            RGB(gray: 0.18)
        }
        for feather in [0.0, 25.0, 50.0, 75.0, 100.0] {
            let gpuImage = RenderGraph().applyVignette(ciImage(from: source), ev: -2,
                                                       feather: feather, crop: Crop())
            guard let gpu = readBack(gpuImage, width: width, height: height) else {
                return XCTFail("vignette render failed at feather \(feather)")
            }
            let reference = DetailEngine.vignette(source, ev: -2, feather: feather)
            var worst = 0.0
            var worstAt = (0, 0)
            for y in 0..<height {
                for x in 0..<width {
                    let d = reference[x, y].maxAbsDifference(gpu[x, y])
                    if d > worst { worst = d; worstAt = (x, y) }
                }
            }
            // Same bar as the clamp golden above, and for the same reason: the
            // kernel's f16/f32 error plus the exponent dither sit an order of
            // magnitude under it, while a wrong inner radius moves mid-frame gain
            // by whole percents of 0.18.
            XCTAssertLessThan(worst, 0.005,
                              "vignette at feather \(feather) diverged from the "
                                  + "reference by \(worst) at \(worstAt) — the two "
                                  + "renderers are not deriving the inner radius "
                                  + "from the same function")
        }
    }

    // MARK: - A strong vignette must not band on the half-float plane (docs/31 R2 §7)

    /// The banding the owner reported at −3, as a NUMBER: when the log-encoded
    /// plane is materialized at the shipping context's working precision (RGBAh),
    /// the vignette's ramp must keep its local mean instead of stepping.
    ///
    /// Mechanism: the finish stage samples its cube on the log-encoded plane,
    /// which parks real pictures where one fp16 step is 2⁻¹¹ · 24 ≈ 0.0117 EV
    /// (`RenderGraph.encodedFP16QuantumEV`). A strong burn is a slow, noise-free
    /// synthetic gradient — exactly the signal that quantum turns into visible
    /// rings, and the 8-bit output dither cannot break bands born upstream of it.
    /// The fix dithers the vignette's own exponent by ±half a quantum, so the
    /// encoded plane's rounding preserves the ramp's local mean.
    ///
    /// The harness materializes the encoded plane EXPLICITLY (`insertingIntermediate`
    /// under an RGBAh working format), because whether the shipping graph buffers
    /// at that node is Core Image's scheduling decision — the golden pins the
    /// property that must hold whenever it does.
    ///
    /// The fixture and both bars are CALIBRATED, not guessed: the exact kernel
    /// arithmetic (LumenLog, the smoothstep falloff, IEEE fp16 round-to-nearest,
    /// Lumen's own Bayer matrix) was simulated in double for this very frame.
    /// Base grey 1.44 parks the burn's whole travel in encoded [0.5, 1), where the
    /// fp16 quantum is the full 0.0117 EV; each measurement point averages one
    /// Bayer period of rows about the midline (rows there share a radius, so a
    /// quantised staircase stays in phase — a full-height mean would average
    /// differently-phased staircases smooth and hide the defect) and the column's
    /// mirror twin (whose Bayer column is a DIFFERENT subset of the cell, which is
    /// what makes the dithered mean converge). Simulated numbers: worst
    /// adjacent-column step — quantised 0.0117 EV, dithered 0.0044, ideal ramp
    /// 0.0033; worst deviation from the f64 reference — quantised 0.0059,
    /// dithered 0.0013. The bars sit between the two populations with ≥1.5×
    /// margin each way.
    func testAStrongVignetteKeepsItsMeanThroughAHalfFloatEncodedPlane() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 3072, height = 512
        let baseGrey = 1.44
        let source = ImageBuffer(width: width, height: height) { _, _ in
            RGB(gray: baseGrey)
        }
        // The SHIPPING context's precision, not the test context's: this file's
        // `context` works in RGBAf precisely so goldens measure arithmetic, and
        // this one test exists to measure the fp16 plane the app renders on.
        let fp16 = CIContext(options: [
            .workingColorSpace: CGColorSpace(
                name: CGColorSpace.extendedLinearITUR_2020) as Any,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: true,
        ])

        let vignetted = RenderGraph().applyVignette(ciImage(from: source), ev: -3,
                                                    feather: Look.vignetteFeatherDefault,
                                                    crop: Crop())
        guard let encoded = KernelLibrary.apply(KernelLibrary.logEncode,
                                                extent: vignetted.extent, [vignetted])
        else { return XCTFail("encode failed") }
        let materialized = encoded.insertingIntermediate()
        guard let decoded = KernelLibrary.apply(KernelLibrary.logDecode,
                                                extent: vignetted.extent,
                                                [materialized])
        else { return XCTFail("decode failed") }

        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            fp16.render(decoded, toBitmap: base, rowBytes: width * 16,
                        bounds: CGRect(x: 0, y: 0, width: width, height: height),
                        format: .RGBAf, colorSpace: nil)
        }

        /// Mean EV at column `x`: one Bayer period of rows about the midline, in
        /// this column and its mirror twin (the vignette is symmetric, so the
        /// ideal values are identical and only the dither phase differs).
        func columnMeanEV(_ x: Int) -> Double {
            var sum = 0.0
            let mid = height / 2
            for y in (mid - 4)..<(mid + 4) {
                sum += Double(pixels[(y * width + x) * 4 + 1])
                sum += Double(pixels[(y * width + (width - 1 - x)) * 4 + 1])
            }
            return log2(Swift.max(sum / 16.0, 1e-9) / 0.18)
        }

        // The falloff region along the midline: from where the burn starts to the
        // frame's edge, staying 16 px off the border.
        let inner = Int(Double(width / 2)
                        * (1 + DetailEngine.vignetteInnerRadius * 2.0.squareRoot()))
        let reference = DetailEngine.vignette(source, ev: -3)
        func idealEV(_ x: Int) -> Double {
            log2(Swift.max(Double(reference[x, height / 2].g), 1e-9) / 0.18)
        }

        var worstStep = 0.0
        var worstDeviation = 0.0
        var idealStep = 0.0
        var previous = columnMeanEV(inner)
        var previousIdeal = idealEV(inner)
        for x in (inner + 1)..<(width - 16) {
            let ev = columnMeanEV(x)
            let ideal = idealEV(x)
            worstStep = Swift.max(worstStep, abs(ev - previous))
            worstDeviation = Swift.max(worstDeviation, abs(ev - ideal))
            idealStep = Swift.max(idealStep, abs(ideal - previousIdeal))
            previous = ev
            previousIdeal = ideal
        }
        print(String(format: "VIGNETTE BANDING worst step %.5f EV, worst deviation "
                         + "%.5f EV (ideal ramp step %.5f, fp16 quantum %.5f)",
                     worstStep, worstDeviation, idealStep,
                     RenderGraph.encodedFP16QuantumEV))
        XCTAssertLessThan(idealStep, 0.005,
                          "the fixture's ideal ramp steps \(idealStep) EV per "
                              + "column — too steep to tell a band from the ramp")
        XCTAssertLessThan(worstStep, 0.0065,
                          "the −3 EV burn steps \(worstStep) EV between adjacent "
                              + "columns (a quantised band edge costs the full "
                              + "0.0117) — the encoded plane is quantising the "
                              + "ramp into the rings the owner reported")
        XCTAssertLessThan(worstDeviation, 0.003,
                          "the burn's local mean sits \(worstDeviation) EV off the "
                              + "f64 reference — the staircase parks half a "
                              + "quantum (0.0059) away between band edges")
    }

    // MARK: - The gamut flag sits where the reference puts it: before grain

    /// A flagged pixel is GRAINED, because that is what the reference renders:
    /// `ReferenceRenderer.render` computes the flag inside `finishedColor` at
    /// S14/S15 and then runs the local curves and grain over it. The graph used to
    /// paint the flag LAST — a deliberate design the reference does not implement
    /// — so every flagged pixel under grain disagreed between the two renderers
    /// (docs/31 round two §15). The discriminator is variance: painted last, the
    /// flagged region is EXACTLY the constant warning colour; painted where the
    /// reference paints it, the grain modulates it like any other pixel.
    func testTheGamutFlagIsGrainedLikeTheReference() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let width = 64, height = 32
        // Left half: the Rec.2020 green sRGB cannot hold (the proof suite's own
        // fixture). Right half: mid-grey control.
        let source = ImageBuffer(width: width, height: height) { u, _ in
            u < 0.5 ? RGB(0.02, 1.1, 0.02) : RGB(gray: 0.18)
        }
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        recipe.look.filmLab = FilmLab(stock: "lumen/portra400", amount: 100,
                                      grain: FilmGrain(size: 1, amount: 100))
        let proof = SoftProof(enabled: true, space: .srgb,
                              intent: .relativeColorimetric, showGamutWarning: true)
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize,
                              softProof: proof)
        guard let film = plan.filmChain else {
            return XCTFail("the film lab did not build a chain")
        }
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let options = RenderGraph.Options(longEdge: width)

        // Control first, with NO plate, so `build` skips the grain stage: the
        // flagged half must be the exact warning colour. This is the self-check
        // that the film-formed green still leaves sRGB — if a stock change ever
        // pulls the fixture into gamut, the failure names the fixture instead of
        // the variance assertion passing on an unflagged region.
        guard let control = readBack(RenderGraph().build(ciImage(from: source),
                                                         plan: plan,
                                                         options: options),
                                     width: width, height: height) else {
            return XCTFail("control render failed")
        }
        let flag = SoftProof.warningColor
        let probe = control[width / 4, height / 2]
        XCTAssertLessThan(probe.maxAbsDifference(flag), 0.02,
                          "the fixture's green is no longer flagged through the "
                              + "film chain (\(probe) vs \(flag)) — grain over "
                              + "the flag cannot be judged on it")

        var graph = RenderGraph()
        graph.grainPlate = PipelineRenderer.grainPlate(film: film, extent: extent)
        XCTAssertNotNil(graph.grainPlate, "no grain plate — this test needs grain")
        let output = graph.build(ciImage(from: source), plan: plan, options: options)
        guard let gpu = readBack(output, width: width, height: height) else {
            return XCTFail("render failed")
        }

        // Grained, the same region must still read as the flag on average — and
        // must VARY, because the reference grains its flagged pixels like any
        // others.
        var mean = RGB(0, 0, 0)
        var lo = Double.infinity, hi = -Double.infinity
        var count = 0.0
        for y in 4..<(height - 4) {
            for x in 4..<(width / 2 - 4) {
                let c = gpu[x, y]
                mean = mean + c
                lo = Swift.min(lo, Double(c.g))
                hi = Swift.max(hi, Double(c.g))
                count += 1
            }
        }
        mean = mean / count
        XCTAssertLessThan(mean.maxAbsDifference(flag), 0.1,
                          "the grained flag drifted from the warning colour "
                              + "(\(mean) vs \(flag))")
        XCTAssertGreaterThan(hi - lo, 0.002,
                             "the flagged region is EXACTLY constant under grain "
                                 + "— the flag is painted after grain again, "
                                 + "which is the opposite of the reference's "
                                 + "placement")
    }

    // MARK: - A settle mask edge is resolved at the render, not at 1024 (R2 §3)

    /// The mask raster's resolution must track the render target on the settle
    /// path: a hard mask edge stays a couple of delivered pixels wide at EVERY
    /// render size, instead of widening with renderSize/1024.
    ///
    /// Every path used to rasterize at the 1024 proxy and upsample — on this
    /// fixture's 4096 px render that is a 4 px ramp; on a 45 MP export it is 8 px
    /// with the boundary quantised to 8 px (docs/31 round two §3). The mask is a
    /// linear ramp collapsed to a hard step by the levels remap (`hi ≤ lo` is the
    /// documented hard-step form), under a +2 EV exposure, so the delivered edge
    /// is unmissable; the transition count is measured in the delivered pixels.
    func testASettleMaskEdgeIsResolvedAtTheRendersOwnResolution() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        var mask = Mask(id: "m-edge", name: "step")
        var component = MaskComponent(op: .add, kind: .linear)
        component.line = [0.5, 0, 0.5, 1]
        mask.components = [component]
        mask.refine.levelsLo = 50
        mask.refine.levelsHi = 50
        mask.adjust.exposure = 2.0
        var recipe = Recipe()
        recipe.masks = [mask]
        recipe.develop.denoise.mode = .off
        let renderer = PipelineRenderer()

        func transitionRows(renderLongEdge: Int) throws -> Int {
            let w = renderLongEdge, h = renderLongEdge / 8
            let flat = ImageBuffer(width: w, height: h) { _, _ in RGB(gray: 0.18) }
            let cg = try renderer.renderPreview(source: StubSource(ciImage(from: flat)),
                                                recipe: recipe, maxLongEdge: w,
                                                draft: false, coarseDecode: false)
            guard let delivered = readBack(CIImage(cgImage: cg), width: w, height: h)
            else { throw RenderError.renderFailed }
            // Down one column: the step is horizontal, so rows strictly between
            // the two plateaus are the edge's ramp. The margin clears the output
            // dither by an order of magnitude.
            let x = w / 4
            let top = Double(delivered[x, 2].g)
            let bottom = Double(delivered[x, h - 3].g)
            let lo = Swift.min(top, bottom), hi = Swift.max(top, bottom)
            let margin = 0.12 * (hi - lo)
            var between = 0
            for y in 0..<h {
                let v = Double(delivered[x, y].g)
                if v > lo + margin && v < hi - margin { between += 1 }
            }
            XCTAssertGreaterThan(hi - lo, 0.05,
                                 "the masked +2 EV moved the plateaus by "
                                     + "\(hi - lo) — the mask is not reaching "
                                     + "pixels, so the edge width means nothing")
            return between
        }

        let small = try transitionRows(renderLongEdge: 1024)
        let large = try transitionRows(renderLongEdge: 4096)
        print("MASK EDGE transition rows: 1024 px \(small), 4096 px \(large)")
        XCTAssertLessThanOrEqual(small, 2,
                                 "a hard mask edge spans \(small) rows at a "
                                     + "1024 px render")
        XCTAssertLessThanOrEqual(large, 2,
                                 "a hard mask edge spans \(large) rows at a "
                                     + "4096 px render — the raster is still the "
                                     + "1024 proxy, upsampled, on the settle path")
    }

    // MARK: - "Don't resize" does not resample (docs/31 round one §11)

    /// `.none` must mean the resampler DOES NOT RUN — scale exactly 1 — even when
    /// the crop extent is fractional. The old path computed a target from the
    /// TRUNCATED crop extent and resampled the whole frame through Lanczos at
    /// ~0.9997×, landing a pixel short per axis and blending every pixel with its
    /// neighbours on the way.
    ///
    /// A one-pixel checkerboard is the instrument: with no resample the delivered
    /// values are bimodal; a 0.9977× Lanczos drifts up to ~0.7 px of phase across
    /// this frame and fills the gap between the modes with blends.
    func testDontResizeDoesNotResampleACroppedPhotograph() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let w = 300, h = 200
        let checker = ImageBuffer(width: w, height: h) { u, v in
            let x = Int((u * Double(w)).rounded(.down))
            let y = Int((v * Double(h)).rounded(.down))
            return RGB(gray: (x + y) % 2 == 0 ? 0.5 : 0.05)
        }
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        // A fractional crop extent: 0.999 × 300 = 299.7 px.
        recipe.develop.geometry.crop.w = 0.999
        let exportRecipe = ExportRecipe(name: "noresize", format: .png, bitDepth: 16,
                                        colorSpace: .srgb, resizeMode: .none)
        let renderer = PipelineRenderer()
        let image = try renderer.exportedImage(source: StubSource(ciImage(from: checker)),
                                               recipe: recipe, using: exportRecipe)

        let ow = Int(image.extent.width.rounded())
        let oh = Int(image.extent.height.rounded())
        guard let pixels = readBack(image, width: ow, height: oh) else {
            return XCTFail("export render failed")
        }
        // Interior only: the fractional crop's own last column is legitimately
        // partial, and the phase drift that betrays a resample is largest
        // mid-frame anyway.
        var lo = Double.infinity, hi = -Double.infinity
        for y in 20..<(oh - 20) {
            for x in 20..<(ow - 20) {
                let v = Double(pixels[x, y].g)
                lo = Swift.min(lo, v); hi = Swift.max(hi, v)
            }
        }
        let third = (hi - lo) / 3
        var blended = 0, counted = 0
        for y in 20..<(oh - 20) {
            for x in 20..<(ow - 20) {
                let v = Double(pixels[x, y].g)
                if v > lo + third && v < hi - third { blended += 1 }
                counted += 1
            }
        }
        print("DONT-RESIZE blended pixels \(blended) of \(counted), "
              + "delivered \(ow)×\(oh)")
        XCTAssertGreaterThan(hi - lo, 0.01,
                             "the checkerboard survived with no contrast — this "
                                 + "fixture proves nothing")
        XCTAssertLessThan(Double(blended), 0.01 * Double(counted),
                          "\(blended) of \(counted) delivered pixels sit between "
                              + "the checkerboard's modes — \"Don't resize\" ran "
                              + "the resampler anyway")
    }

    // MARK: - A resized export has no darkened rim (docs/31 round one §12)

    /// Every border pixel of a resized flat-field export matches the centre:
    /// Lanczos taps reach past the extent, and without the edge clamp they
    /// averaged real pixels with transparent black — a darkened, semi-transparent
    /// rim on every resized delivery.
    func testAResizedExportHasNoDarkenedRim() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let flat = ImageBuffer(width: 900, height: 600) { _, _ in RGB(gray: 0.5) }
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        let exportRecipe = ExportRecipe(name: "rim", format: .png, bitDepth: 16,
                                        colorSpace: .srgb, resizeMode: .longEdge,
                                        resizeValue: 300)
        let renderer = PipelineRenderer()
        let image = try renderer.exportedImage(source: StubSource(ciImage(from: flat)),
                                               recipe: recipe, using: exportRecipe)
        guard let pixels = readBack(image, width: 300, height: 200) else {
            return XCTFail("export render failed")
        }
        let centre = Double(pixels[150, 100].g)
        var worst = centre
        var worstAt = (0, 0)
        for y in 0..<200 {
            for x in 0..<300 where y < 3 || y >= 197 || x < 3 || x >= 297 {
                let v = Double(pixels[x, y].g)
                if v < worst { worst = v; worstAt = (x, y) }
            }
        }
        XCTAssertGreaterThan(centre, 0.05, "the flat field rendered black — "
                                 + "this fixture proves nothing")
        XCTAssertGreaterThan(worst, centre * 0.98,
                             "border pixel \(worstAt) delivered \(worst) against "
                                 + "a centre of \(centre) — the Lanczos rim is "
                                 + "back; `scaled()` has lost its edge clamp")
    }

    // MARK: - The metadata policy edits the SOURCE dictionary (docs/31 §13)

    /// The policy's base is the ORIGINAL file's properties, and the geometry
    /// fields are reconciled with the delivered pixels.
    ///
    /// The old code read `image.properties` off the RENDERED image — after ~40
    /// kernels — which is either empty (the whole policy a no-op: "EXIF: on"
    /// delivered no camera data at all) or the decode's dictionary verbatim (the
    /// source's orientation and pixel dimensions surviving onto a rotated,
    /// resized file). This drives the new seam directly with a fixture dictionary
    /// standing in for the source file's.
    func testTheMetadataPolicyEditsTheSourceDictionaryAndReconcilesGeometry() throws {
        let delivered = ciImage(from: ImageBuffer(width: 20, height: 10) { _, _ in
            RGB(gray: 0.18)
        })
        let fixture: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifISOSpeedRatings as String: [400],
                kCGImagePropertyExifPixelXDimension as String: 6000,
                kCGImagePropertyExifPixelYDimension as String: 4000,
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 37.33,
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFModel as String: "ILCE-7M4",
                kCGImagePropertyTIFFOrientation as String: 6,
            ],
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyPixelWidth as String: 6000,
            kCGImagePropertyPixelHeight as String: 4000,
        ]
        let policy = MetadataPolicy(includeEXIF: true, includeCameraSerial: false,
                                    includeGPS: false, includeKeywords: true)
        let out = PipelineRenderer.applyMetadataPolicy(delivered, policy,
                                                       resolutionPPI: 300,
                                                       sourceProperties: fixture)
        let props = out.properties

        // The whole point: with "EXIF: on", the camera data REACHES the output —
        // the rendered image's own dictionary is empty, so the old code delivered
        // nothing here.
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNotNil(exif, "EXIF on delivered no EXIF dictionary — the policy "
                            + "is editing the rendered image's empty properties, "
                            + "not the source's")
        XCTAssertNotNil(exif?[kCGImagePropertyExifISOSpeedRatings as String],
                        "the source's ISO did not survive an EXIF-on export")
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel as String] as? String,
                       "ILCE-7M4", "the camera model did not survive")

        // Strip GPS means stripped, from the dictionary that actually has it.
        XCTAssertNil(props[kCGImagePropertyGPSDictionary as String],
                     "Strip GPS left the source's coordinates in the output")

        // And the geometry is the DELIVERY's, not the source's: orientation 1
        // (the pixels are rendered upright) and this render's pixel dimensions.
        XCTAssertEqual(props[kCGImagePropertyOrientation as String] as? Int, 1,
                       "the source's orientation 6 survived onto rendered-upright "
                           + "pixels — viewers will rotate the delivery again")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFOrientation as String] as? Int, 1,
                       "the TIFF dictionary still carries the source's rotation")
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, 20,
                       "the delivered file claims the source's pixel width")
        XCTAssertEqual(exif?[kCGImagePropertyExifPixelXDimension as String] as? Int,
                       20, "EXIF still claims the source's pixel dimensions")
    }
}

#endif

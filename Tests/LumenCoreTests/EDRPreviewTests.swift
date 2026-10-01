// The HDR viewport's arithmetic (`EDRPreview`), and the claim the viewport makes: what
// the loupe shows with HDR preview on IS the rendition the gain-map export encodes, and
// a gain-map decoder handed that export reproduces it.
//
// Everything here runs on the free lane. The layer that draws the frame and the screen
// reads that feed these functions are macOS-only (`EDRImageView`, `EDRDisplay`), and
// the GPU half of the rendition claim is `EDRPreviewRenderTests` in LumenPipelineTests.

import Foundation
import XCTest
@testable import LumenCore

final class EDRPreviewTests: XCTestCase {

    // MARK: - Headroom mapping

    func testOffAndSDRDisplaysRenderNothingButTheSDRFrame() {
        let content = HDRSettings()
        // Off: nil whatever the display can do.
        XCTAssertNil(EDRPreview.whiteTarget(enabled: false, content: content,
                                            currentComponentValue: 16,
                                            potentialComponentValue: 16))
        // On, but the panel has no potential headroom — or a reading that is not a
        // number at all. The SDR frame, not an EDR pass at 100%.
        for potential in [1.0, 0.5, 1.05, .nan, .infinity, -.infinity, 0] {
            XCTAssertNil(EDRPreview.whiteTarget(enabled: true, content: content,
                                                currentComponentValue: potential,
                                                potentialComponentValue: potential),
                         "potential \(potential)")
            XCTAssertEqual(EDRPreview.status(enabled: true, content: content,
                                             currentComponentValue: potential,
                                             potentialComponentValue: potential),
                           .sdrDisplay, "potential \(potential)")
        }
        XCTAssertEqual(EDRPreview.status(enabled: false, content: content,
                                         currentComponentValue: 16,
                                         potentialComponentValue: 16), .off)
        XCTAssertNil(EDRPreview.Status.off.label)
    }

    /// With the headroom to show it, the preview's white target is the export's HDR
    /// white target — the same `Double`, for every headroom the export sheet offers.
    /// This is the line that makes "the same rendition the gain map encodes" true:
    /// `renderHDRPair` builds its HDR plan at `settings.whiteTargetPercent`.
    func testFullHeadroomIsExactlyTheExportsHDRWhiteTarget() {
        var ev = 0.0
        while ev <= 4.0 + 1e-9 {
            let content = HDRSettings(headroomEV: ev)
            for display in [pow(2, ev), pow(2, ev) * 1.01, 16, 64] {
                let target = EDRPreview.whiteTarget(enabled: true, content: content,
                                                    currentComponentValue: display,
                                                    potentialComponentValue: 16)
                XCTAssertEqual(target, content.whiteTargetPercent,
                               "content \(ev) EV on a \(display)× display")
            }
            ev += 0.1
        }
        // Past the sheet's own clamp the export clamps and so does the preview.
        let wild = HDRSettings(headroomEV: 9)
        XCTAssertEqual(EDRPreview.whiteTarget(enabled: true, content: wild,
                                              currentComponentValue: 1000,
                                              potentialComponentValue: 1000),
                       wild.whiteTargetPercent)
        XCTAssertEqual(wild.whiteTargetPercent, 1600)
    }

    /// Less headroom than the content: the display's own, rounded DOWN to an eighth
    /// of a stop — never above what the layer can show without clipping, never below
    /// SDR white, and monotone in the display.
    func testLimitedHeadroomNeverExceedsTheDisplay() {
        let content = HDRSettings(headroomEV: 3)
        var previous = 0.0
        var display = 1.0
        while display < 8.0 {
            guard let target = EDRPreview.whiteTarget(enabled: true, content: content,
                                                      currentComponentValue: display,
                                                      potentialComponentValue: 16)
            else { return XCTFail("a capable display returned no target at \(display)×") }
            XCTAssertLessThanOrEqual(target / 100, display * (1 + 1e-12),
                                     "target \(target)% above a \(display)× display")
            XCTAssertGreaterThanOrEqual(target, 100)
            XCTAssertGreaterThan(target / 100, display / pow(2, EDRPreview.stopsQuantum)
                                 * (1 - 1e-12),
                                 "more than one quantum below the display at \(display)×")
            XCTAssertGreaterThanOrEqual(target, previous, "not monotone at \(display)×")
            previous = target
            display *= 1.013
        }
        // Exact powers of two keep their whole stop — `log2(2)` must not lose a
        // quantum to float noise.
        XCTAssertEqual(EDRPreview.whiteTarget(enabled: true, content: content,
                                              currentComponentValue: 2,
                                              potentialComponentValue: 16), 200)
        XCTAssertEqual(EDRPreview.whiteTarget(enabled: true, content: content,
                                              currentComponentValue: 4,
                                              potentialComponentValue: 16), 400)
    }

    /// The OS moves headroom continuously; a render key per wobble would re-render
    /// the photograph on every ambient-light tick. Inside one quantum, one target.
    func testSmallHeadroomWobbleIsOneRenderKey() {
        let content = HDRSettings(headroomEV: 3)
        let base = pow(2.0, 1.5)
        let targets = Set(stride(from: 0.0, to: 0.12, by: 0.01).compactMap { wobble in
            EDRPreview.whiteTarget(enabled: true, content: content,
                                   currentComponentValue: base * pow(2, wobble),
                                   potentialComponentValue: 16)
        })
        XCTAssertEqual(targets.count, 1, "\(targets.sorted())")
    }

    /// Before the OS has raised the headroom (current 1.0 on a capable panel), the
    /// EDR pass still runs, at SDR white. That is what puts an EDR layer on screen,
    /// and the layer is what makes the OS raise the headroom.
    func testACapablePanelAtRestStillGetsTheEDRLayer() {
        XCTAssertEqual(EDRPreview.whiteTarget(enabled: true, content: HDRSettings(),
                                              currentComponentValue: 1,
                                              potentialComponentValue: 2.5), 100)
    }

    func testANaNHeadroomSettingRendersAtTheDefaultNotAtNaN() {
        let content = HDRSettings(headroomEV: .nan)
        XCTAssertEqual(EDRPreview.whiteTarget(enabled: true, content: content,
                                              currentComponentValue: 16,
                                              potentialComponentValue: 16),
                       HDRSettings().whiteTargetPercent)
    }

    // MARK: - Which export recipe

    func testContentSettingsComeFromTheEnabledGainMapRecipe() {
        let jpeg = ExportRecipe(name: "web", enabled: true, format: .jpeg)
        var offHDR = ExportRecipe(name: "off", enabled: false, format: .heif)
        offHDR.hdr = HDRSettings(headroomEV: 1)
        var onHDR = ExportRecipe(name: "on", enabled: true, format: .heif)
        onHDR.hdr = HDRSettings(headroomEV: 3)
        // TIFF cannot carry a gain map; its `hdr` would never be encoded as one.
        var tiff = ExportRecipe(name: "tiff", enabled: true, format: .tiff)
        tiff.hdr = HDRSettings(headroomEV: 4)

        XCTAssertEqual(EDRPreview.contentSettings(from: [jpeg, tiff, offHDR, onHDR]).headroomEV, 3)
        XCTAssertEqual(EDRPreview.contentSettings(from: [jpeg, tiff, offHDR]).headroomEV, 1)
        XCTAssertEqual(EDRPreview.contentSettings(from: [jpeg, tiff]), HDRSettings())
        XCTAssertEqual(EDRPreview.contentSettings(from: []), HDRSettings())
        // The shipped defaults have one: the HDR HEIC, off by default.
        XCTAssertEqual(EDRPreview.contentSettings(from: ExportRecipe.defaults),
                       ExportRecipe.defaults.first { $0.hdr != nil }?.hdr)
    }

    // MARK: - Indicator

    func testTheBadgeDescribesTheTargetActuallyRendered() {
        let content = HDRSettings(headroomEV: 2)
        XCTAssertEqual(EDRPreview.status(enabled: true, content: content,
                                         currentComponentValue: 8,
                                         potentialComponentValue: 16).label,
                       "HDR · +2.0 EV")
        // 2.5× is 1.32 stops: the pass renders at 1.25, and the badge says 1.25 of 2.
        let limited = EDRPreview.status(enabled: true, content: content,
                                        currentComponentValue: 2.5,
                                        potentialComponentValue: 16)
        XCTAssertEqual(limited, .rendering(displayStops: 1.25, contentStops: 2))
        XCTAssertEqual(limited.label, "HDR · +1.2 OF +2.0 EV")
        XCTAssertEqual(EDRPreview.status(enabled: true, content: content,
                                         currentComponentValue: 1,
                                         potentialComponentValue: 1).label,
                       "HDR · SDR DISPLAY")
        // Every rendering status's display figure is the rendered target's.
        for display in stride(from: 1.0, through: 20.0, by: 0.37) {
            let status = EDRPreview.status(enabled: true, content: content,
                                           currentComponentValue: display,
                                           potentialComponentValue: 20)
            let target = EDRPreview.whiteTarget(enabled: true, content: content,
                                                currentComponentValue: display,
                                                potentialComponentValue: 20)
            guard case .rendering(let shown, _) = status, let target else {
                return XCTFail("no rendering status at \(display)×")
            }
            XCTAssertEqual(shown, log2(target / 100), accuracy: 1e-12)
        }
    }

    // MARK: - Placement

    func testPlateRectFollowsScaleThenOffset() {
        let container = CGSize(width: 1000, height: 600)
        let drawn = CGSize(width: 800, height: 500)
        let fit = EDRPreview.plateRect(container: container, drawn: drawn, stretch: 1,
                                       offset: .zero, region: nil)
        XCTAssertEqual(fit, CGRect(x: 100, y: 50, width: 800, height: 500))
        // Stretch about the centre, then pan: the centre moves by the pan only.
        let moved = EDRPreview.plateRect(container: container, drawn: drawn, stretch: 2,
                                         offset: CGSize(width: 30, height: -20),
                                         region: nil)
        XCTAssertEqual(moved, CGRect(x: 500 + 30 - 800, y: 300 - 20 - 500,
                                     width: 1600, height: 1000))
        // A region is its share of the plate, top-left unit convention.
        let region = EDRPreview.plateRect(container: container, drawn: drawn, stretch: 1,
                                          offset: .zero,
                                          region: CGRect(x: 0.25, y: 0.5,
                                                         width: 0.5, height: 0.25))
        XCTAssertEqual(region, CGRect(x: 300, y: 300, width: 400, height: 125))
        // Degenerate stretch is no stretch, not a vanished plate.
        XCTAssertEqual(EDRPreview.plateRect(container: container, drawn: drawn,
                                            stretch: .nan, offset: .zero, region: nil), fit)
        // Into Core Image: device pixels, bottom-left origin.
        XCTAssertEqual(EDRPreview.coreImageRect(region, containerHeight: 600, scale: 2),
                       CGRect(x: 600, y: 350, width: 800, height: 250))
    }

    // MARK: - Off is the SDR path it always was

    /// Source text, `//` comments blanked so prose about the rule cannot satisfy it.
    private func code(_ path: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("\(path) not found — if it moved, move this scan with it")
            return ""
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// The text from `start` to the parenthesis that closes the first `(` after it.
    private func call(_ start: String, in text: String) -> String? {
        guard let head = text.range(of: start),
              let open = text.range(of: "(", range: head.lowerBound..<text.endIndex)
        else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return String(text[head.lowerBound...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The claim behind "no change at all to the SDR path when off", read where it
    /// lives (LumenApp and LumenPipeline do not build on this lane; the bytes are
    /// `EDRPreviewRenderTests` on macOS). The coordinator's SDR delivery is the same
    /// call with the same arguments — nothing EDR reaches it — and the EDR pass is
    /// reached only from inside `if let edrWhiteTarget`, AFTER it. The renderer's SDR
    /// function never mentions the EDR pass either: the EDR frame is a separate
    /// function rather than a mode of the SDR one.
    func testWithThePreviewOffTheSDRFrameIsTheCallItWas() {
        let coordinator = code("Sources/LumenApp/RenderCoordinator.swift")
        guard let produce = coordinator.range(of: "private func produce("),
              let sdr = call("renderer.renderPreviewDelivery(",
                             in: String(coordinator[produce.lowerBound...]))
        else { return XCTFail("produce no longer calls renderPreviewDelivery") }
        XCTAssertFalse(sdr.lowercased().contains("edr"),
                       "the SDR delivery call now carries an EDR argument: \(sdr)")
        let body = String(coordinator[produce.lowerBound...])
        guard let sdrAt = body.range(of: "renderer.renderPreviewDelivery("),
              let edrAt = body.range(of: "renderer.renderPreviewEDR("),
              let gate = body.range(of: "if let edrWhiteTarget")
        else { return XCTFail("the EDR pass is no longer behind `if let edrWhiteTarget`") }
        XCTAssertLessThan(sdrAt.lowerBound, gate.lowerBound,
                          "the EDR gate runs before the SDR frame is delivered")
        XCTAssertLessThan(gate.lowerBound, edrAt.lowerBound,
                          "the EDR pass is reachable without a white target")

        let renderer = code("Sources/LumenPipeline/PipelineRenderer.swift")
        guard let start = renderer.range(of: "public func renderPreviewDelivery("),
              let end = renderer.range(of: "static let edrIdentitySuffix")
        else { return XCTFail("renderPreviewDelivery or the EDR section moved") }
        let sdrFunction = String(renderer[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(sdrFunction.lowercased().contains("edr"),
                       "the SDR preview function now knows about the EDR pass")
        XCTAssertTrue(sdrFunction.contains("format: .RGBA8"),
                      "the SDR preview no longer rasterizes 8-bit")
    }

    // MARK: - The rendition, and the gain-map round trip

    /// A scene with something in every register: a −6…+5 EV ramp around mid-grey in
    /// three tints, all inside the working gamut so the gain map's clamp at zero is
    /// never what the comparison measures.
    private func scene() -> ImageBuffer {
        ImageBuffer(width: 96, height: 3) { u, v in
            let y = 0.18 * pow(2.0, -6 + u * 11)
            switch Int(v * 3) {
            case 0: return RGB(y, y, y)
            case 1: return RGB(y * 1.1, y, y * 0.85)
            default: return RGB(y * 0.9, y * 0.97, y * 1.12)
            }
        }
    }

    private func render(_ recipe: Recipe, white: Double?) -> ImageBuffer {
        ReferenceRenderer.render(scene(), plan: RenderPlan(recipe: recipe,
                                                           displayWhiteTarget: white))
    }

    private func pixels(_ b: ImageBuffer) -> [RGB] {
        var out: [RGB] = []
        for y in 0..<b.height { for x in 0..<b.width { out.append(b[x, y]) } }
        return out
    }

    /// The export's SDR base is rendered at white 100 (`renderHDRPair`), the loupe's
    /// SDR frame with no target at all. The same picture — so the HDR preview's "off"
    /// and the gain map's base are one rendition.
    func testTheSDRFrameIsTheGainMapsBase() {
        let recipe = Recipe()
        let preview = pixels(render(recipe, white: nil))
        let base = pixels(render(recipe, white: 100))
        XCTAssertEqual(preview.count, base.count)
        for (p, b) in zip(preview, base) {
            XCTAssertEqual(p.r, b.r, accuracy: 1e-6)
            XCTAssertEqual(p.g, b.g, accuracy: 1e-6)
            XCTAssertEqual(p.b, b.b, accuracy: 1e-6)
        }
    }

    /// Encode the export pair into a gain map the way ISO 21496-1 stores it — 8-bit,
    /// per channel, between the observed min and max log gain — and decode it the way
    /// a viewer does. At full headroom the decoder must hand back the frame the loupe
    /// showed; with no headroom, the SDR base; and the HDR preview must actually carry
    /// headroom, or the round trip would pass on two copies of the SDR picture.
    func testAGainMapDecoderReproducesThePreviewedRendition() {
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.5
        let settings = HDRSettings(headroomEV: 2)
        guard let previewWhite = EDRPreview.whiteTarget(enabled: true, content: settings,
                                                        currentComponentValue: 8,
                                                        potentialComponentValue: 8)
        else { return XCTFail("no preview target on an 8× display") }

        let sdr = pixels(render(recipe, white: 100))
        let previewed = pixels(render(recipe, white: previewWhite))
        let exported = pixels(render(recipe, white: settings.whiteTargetPercent))

        // The preview is the export's rendition, value for value.
        for (p, e) in zip(previewed, exported) {
            XCTAssertEqual(p.r, e.r, accuracy: 1e-9)
            XCTAssertEqual(p.g, e.g, accuracy: 1e-9)
            XCTAssertEqual(p.b, e.b, accuracy: 1e-9)
        }
        let peak = previewed.map { Swift.max($0.r, $0.g, $0.b) }.max() ?? 0
        XCTAssertGreaterThan(peak, 2.0,
            "the HDR rendition peaks at \(peak)× SDR white — no headroom to round-trip")
        XCTAssertLessThanOrEqual(peak, settings.whiteTargetPercent / 100 * 1.001)

        // Encode: per-channel log gain, stored 8-bit between the frame's extremes.
        let gains = zip(previewed, sdr).map { GainMap.logGain(hdr: $0, sdr: $1) }
        let all = gains.flatMap { [$0.r, $0.g, $0.b] }
        let lo = all.min() ?? 0, hi = all.max() ?? 0
        XCTAssertGreaterThan(hi - lo, 0.5, "a flat gain map round-trips trivially")
        func store(_ g: Double) -> Double {
            (GainMap.encode(g, min: lo, max: hi) * 255).rounded() / 255
        }
        let maps = gains.map { RGB(store($0.r), store($0.g), store($0.b)) }

        let content = EDRPreview.contentStops(settings)
        // One 8-bit step of the map is (hi−lo)/255 stops; half of it is the worst
        // rounding, and the decoder's offset makes the relative bound hold at black.
        let tolerance = pow(2, (hi - lo) / 510) - 1 + 1e-9
        for i in previewed.indices {
            let full = GainMap.reconstruct(sdr: sdr[i], encodedMap: maps[i], min: lo, max: hi,
                                           displayHeadroomEV: content,
                                           contentHeadroomEV: content)
            let none = GainMap.reconstruct(sdr: sdr[i], encodedMap: maps[i], min: lo, max: hi,
                                           displayHeadroomEV: 0, contentHeadroomEV: content)
            for (got, want, base, sdrWant) in [
                (full.r, previewed[i].r, none.r, sdr[i].r),
                (full.g, previewed[i].g, none.g, sdr[i].g),
                (full.b, previewed[i].b, none.b, sdr[i].b)] {
                let offset = 1.0 / 64.0
                XCTAssertEqual((got + offset) / (want + offset), 1, accuracy: tolerance,
                               "pixel \(i): decoded \(got), previewed \(want)")
                XCTAssertEqual(base, sdrWant, accuracy: 1e-12,
                               "pixel \(i): an SDR display must get the base back")
            }
        }
    }

    /// Short of the content's headroom the preview renders the SAME transform at the
    /// display's peak: nothing above what the layer can show (CAMetalLayer does not
    /// tone-map, so above means clipped), and diffuse white and mid-grey where the SDR
    /// frame has them — "the SDR picture with the highlights let out".
    func testALimitedDisplayGetsTheTransformAtItsOwnPeak() {
        var recipe = Recipe()
        recipe.develop.tone.exposure = 1
        let settings = HDRSettings(headroomEV: 3)
        let display = 2.6
        guard let white = EDRPreview.whiteTarget(enabled: true, content: settings,
                                                 currentComponentValue: display,
                                                 potentialComponentValue: 16)
        else { return XCTFail("no target") }
        XCTAssertLessThan(white, settings.whiteTargetPercent)

        let limited = pixels(render(recipe, white: white))
        let sdr = pixels(render(recipe, white: 100))
        let peak = limited.map { Swift.max($0.r, $0.g, $0.b) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, display,
            "the preview peaks at \(peak)× on a \(display)× display — it would clip")
        XCTAssertGreaterThan(peak, 1.5, "the limited preview is not using the headroom")

        // Mid-grey is anchored in absolute terms at every peak (DisplayTransform):
        // find the scene's mid-grey column on the neutral row and compare.
        let transformSDR = DisplayTransform.forRecipe(recipe, displayWhiteTarget: 100)
        let transformHDR = DisplayTransform.forRecipe(recipe, displayWhiteTarget: white)
        let midSDR = transformSDR.apply(RGB(0.18, 0.18, 0.18), gamut: RenderPlan.sharedGamutBoundary)
        let midHDR = transformHDR.apply(RGB(0.18, 0.18, 0.18), gamut: RenderPlan.sharedGamutBoundary)
        XCTAssertEqual(midHDR.g, midSDR.g, accuracy: 0.02 * midSDR.g)
        XCTAssertEqual(sdr.count, limited.count)
    }
}

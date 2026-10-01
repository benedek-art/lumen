// EDRPreview.swift
// The HDR viewport's arithmetic: which display white the loupe renders at when the HDR
// preview is on, what the headroom indicator says, and where the EDR layer draws the
// plate. Pure, so it is tested on the free lane; the layer and the screen reads that
// feed it are `EDRImageView`/`EDRDisplay` in the app.
//
// THE RENDITION IS THE EXPORT'S. docs/14 §7: "one pipeline, one transform,
// parameterized by display peak". `PipelineRenderer.renderHDRPair` renders the gain
// map's HDR side at `HDRSettings.whiteTargetPercent`, and when the display has at least
// that much headroom this returns that very number — the same `Double`, not a
// recomputation of it — so what the loupe shows is the plan the export renders, at the
// interactive table size.
//
// LESS HEADROOM THAN THE CONTENT ASKS FOR is docs/14 §7's rule, not a clip: the
// transform's white target becomes the display's own headroom, quantized DOWN to an
// eighth of a stop. Down, because a CAMetalLayer does no tone mapping — anything above
// the display's current maximum simply clips — so rounding up would clip the very
// speculars the mode exists to show. Quantized, because the OS steps headroom
// continuously (ambient light, brightness, EDR ramp-up) and every distinct target is a
// render key; an eighth of a stop is below what a highlight roll-off visibly changes by.
//
// NO HEADROOM AT ALL is not this file's to fake. A display whose POTENTIAL headroom is
// SDR returns nil: the loupe renders exactly the SDR frame it renders with the toggle
// off, and the indicator says why.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum EDRPreview {

    /// The step headroom is quantized to, in stops.
    public static let stopsQuantum: Double = 0.125

    /// Stops above SDR white for an EDR component value — AppKit's
    /// `maximumExtendedDynamicRangeColorComponentValue` family, where 1.0 is SDR white.
    /// Anything not finite or not above 1 is no headroom.
    public static func stops(componentValue: Double) -> Double {
        guard componentValue.isFinite, componentValue > 1 else { return 0 }
        return log2(componentValue)
    }

    /// `stops` rounded DOWN to the quantum — never more headroom than the display has.
    /// The epsilon keeps an exact power of two (2.0 → 1 stop, which `log2` returns as
    /// 0.9999999999999998 on some libms) from losing a whole quantum to float noise.
    public static func quantizedStops(_ stops: Double) -> Double {
        guard stops.isFinite, stops > 0 else { return 0 }
        return (stops / stopsQuantum + 1e-9).rounded(.down) * stopsQuantum
    }

    /// Whether a display can show anything above SDR white at all — judged on its
    /// POTENTIAL headroom, because the current value reads 1.0 on most panels until
    /// EDR content is on screen, and the EDR layer appearing is what makes the OS
    /// raise it.
    public static func displayCanShowHDR(potentialComponentValue: Double) -> Bool {
        quantizedStops(stops(componentValue: potentialComponentValue)) >= stopsQuantum
    }

    /// The content headroom the gain-map export would encode, in stops — the clamp
    /// `HDRSettings.whiteTargetPercent` applies, so the two cannot disagree. A
    /// non-finite setting is the default, as the tolerant decoder would have made it.
    public static func contentStops(_ content: HDRSettings) -> Double {
        let ev = content.headroomEV.isFinite ? content.headroomEV : HDRSettings().headroomEV
        return Num.clamp(ev, 0, 4)
    }

    /// The HDR settings the preview renders: the first ENABLED export recipe that
    /// writes a gain map, else the first that would, else the default +2 EV. The
    /// recipe the photographer is about to export is the rendition worth previewing;
    /// an HDR recipe that is switched off is still a better guess than a constant.
    public static func contentSettings(from recipes: [ExportRecipe]) -> HDRSettings {
        let hdrRecipes = recipes.filter { $0.hdr != nil && $0.format.supportsGainMap }
        let chosen = hdrRecipes.first(where: { $0.enabled }) ?? hdrRecipes.first
        return chosen?.hdr ?? HDRSettings()
    }

    /// The display white target (% of SDR white) the loupe's EDR pass renders at, or
    /// nil for "render SDR only" — the toggle is off, or the display cannot show HDR.
    ///
    /// When the display's current headroom covers the content's, this is
    /// `content.whiteTargetPercent`: the gain-map export's HDR rendition.
    /// Below that it is the display's own headroom, quantized down; and while the OS
    /// has not raised the headroom yet (current 1.0) it is 100 — SDR white through the
    /// EDR layer, which is the request that makes the OS raise it.
    public static func whiteTarget(enabled: Bool, content: HDRSettings,
                                   currentComponentValue: Double,
                                   potentialComponentValue: Double) -> Double? {
        guard enabled,
              displayCanShowHDR(potentialComponentValue: potentialComponentValue)
        else { return nil }
        let contentEV = contentStops(content)
        // Covered or not is judged on the display's RAW headroom: quantizing first
        // would drop a 3.1 EV recipe on a 3.1-stop panel to 3.0 and preview a
        // rendition the export never writes. The epsilon is `log2`'s noise at an exact
        // power of two.
        let rawEV = stops(componentValue: currentComponentValue)
        // `100 * pow(2, clamp(headroomEV, 0, 4))` — `whiteTargetPercent`'s own
        // expression over `contentStops`'s own clamp, so for any finite setting this
        // is that property bit for bit (the tests hold it to `==`), and a NaN setting
        // falls back to the default instead of rendering at a NaN white.
        if rawEV + 1e-9 >= contentEV { return 100 * pow(2, contentEV) }
        return 100 * pow(2, quantizedStops(rawEV))
    }

    /// What the loupe's headroom badge reports.
    public enum Status: Equatable, Sendable {
        /// The toggle is off — no badge at all.
        case off
        /// On, and the display has no headroom: the picture is the SDR frame.
        case sdrDisplay
        /// On and rendering. `displayStops` is what the EDR pass was given, so it is
        /// never more than `contentStops`.
        case rendering(displayStops: Double, contentStops: Double)

        /// The badge text, in the loupe's badge idiom (`CLIPPING · HIGHLIGHTS`).
        public var label: String? {
            switch self {
            case .off:
                return nil
            case .sdrDisplay:
                return "HDR · SDR DISPLAY"
            case .rendering(let display, let content):
                if display >= content {
                    return String(format: "HDR · +%.1f EV", content)
                }
                return String(format: "HDR · +%.1f OF +%.1f EV", display, content)
            }
        }
    }

    /// The status for the same inputs `whiteTarget` takes — derived from the target
    /// actually rendered, so the badge can only ever describe the picture.
    public static func status(enabled: Bool, content: HDRSettings,
                              currentComponentValue: Double,
                              potentialComponentValue: Double) -> Status {
        guard enabled else { return .off }
        guard let target = whiteTarget(enabled: enabled, content: content,
                                       currentComponentValue: currentComponentValue,
                                       potentialComponentValue: potentialComponentValue)
        else { return .sdrDisplay }
        let contentEV = contentStops(content)
        // The full target is `100 · 2^contentEV`, and `log2` of it need not return
        // `contentEV` to the last bit — which would print "+2.0 OF +2.0 EV".
        let shown = target == 100 * pow(2, contentEV) ? contentEV : log2(target / 100)
        return .rendering(displayStops: shown, contentStops: contentEV)
    }

    /// Where the plate sits inside the loupe's container, in points, top-left origin.
    ///
    /// The canvas lays the plate out at `drawn`, centred, scales it by `stretch` about
    /// its centre (`ZoomLayoutHold`'s pinch stretch) and THEN offsets it by the clamped
    /// pan — `.scaleEffect(stretch).offset(offset)`, in that order. A region frame
    /// covers `region` (top-left unit rect) of that plate. The EDR layer spans the
    /// container and draws the pixels here itself, so it never relies on SwiftUI
    /// clipping or transforming a hosted AppKit view.
    public static func plateRect(container: CGSize, drawn: CGSize, stretch: Double,
                                 offset: CGSize, region: CGRect?) -> CGRect {
        let s = stretch.isFinite && stretch > 0 ? CGFloat(stretch) : 1
        let width = drawn.width * s
        let height = drawn.height * s
        let full = CGRect(x: container.width / 2 + offset.width - width / 2,
                          y: container.height / 2 + offset.height - height / 2,
                          width: width, height: height)
        guard let region else { return full }
        return CGRect(x: full.minX + region.minX * full.width,
                      y: full.minY + region.minY * full.height,
                      width: region.width * full.width,
                      height: region.height * full.height)
    }

    /// The same rectangle in a Core Image destination: device pixels, origin at the
    /// BOTTOM left of a container `containerHeight` points tall.
    public static func coreImageRect(_ rect: CGRect, containerHeight: CGFloat,
                                     scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale,
               y: (containerHeight - rect.maxY) * scale,
               width: rect.width * scale,
               height: rect.height * scale)
    }
}

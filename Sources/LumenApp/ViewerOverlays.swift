// ViewerOverlays.swift
// The things the loupe draws on top of the photograph: before/after (flip, split with a
// draggable divider, and the two-pane side-by-side / top-bottom), the clipping-threshold
// overlay, the focus-peaking marks, the mask tint, the crop tool's rectangle and guides,
// the straighten ruler, and the on-image colour readout HUD.
//
// Each one is a small `View` the loupe composes at the drawn image's exact size, so a
// zoomed, panned canvas carries its overlays with it for free rather than each overlay
// re-deriving the viewport's arithmetic.
//
// Two rules the whole file obeys:
//   · Chrome is zero-chroma (docs/00 Law 7): dividers, handles, guides and HUD ground
//     come from the `Lumen` theme and nothing here introduces a new hue. The colours
//     that *are* chromatic — the clipping overlay's channel diagnosis, the readout
//     swatch and the peaking marks — are measurements of the picture, not decoration,
//     and they come straight from `LumenCore.ClippingOverlay`, the sampled pixel and
//     `LumenCore.FocusPeaking` respectively.
//   · An overlay reports what is on screen. The clipping overlay and the readout both
//     bin the displayed 8-bit proxy, and the HUD names the readout space it is in
//     (docs/04 D12: an unlabeled readout is the failure mode `ReadoutSpace` ends).

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import LumenCore
import LumenPipeline
import SwiftUI

// MARK: - Before / after

/// How the before state is presented (docs/12 §B8). `AppState.showBefore` is the `\`
/// flip; this is the `Y` / `⌥Y` / `⇧Y` family.
enum BeforeAfterMode: String, CaseIterable, Identifiable, Sendable {
    case off
    /// `⇧Y` — one canvas, one draggable divider, both recipes on the same tiles.
    case split
    /// `Y`
    case sideBySide
    /// `⌥Y`
    case topBottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .split: return "Split"
        case .sideBySide: return "Side by side"
        case .topBottom: return "Top / bottom"
        }
    }

    /// True when a before render is needed at all.
    var showsPair: Bool { self != .off }

    /// True for the modes that lay the two renditions out in their own panes rather
    /// than sharing the loupe's zoom and pan.
    var isTwoPane: Bool { self == .sideBySide || self == .topBottom }
}

/// The right-hand (or lower) portion of a rect, used to scissor the "after" plate over
/// the "before" one. A `Shape` rather than a mask so the clip is exact at any zoom.
struct SplitScissor: Shape {
    /// 0…1 across the width.
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let f = fraction.isFinite ? Swift.min(Swift.max(fraction, 0), 1) : 0.5
        let x = rect.minX + rect.width * CGFloat(f)
        var path = Path()
        path.addRect(CGRect(x: x, y: rect.minY,
                            width: Swift.max(rect.maxX - x, 0), height: rect.height))
        return path
    }
}

/// Split compare: both plates drawn at the same geometry, the "after" one scissored to
/// the right of a draggable divider. The flip between them is a compositor change, not
/// a re-render, which is what makes `\` and the divider feel like turning a print over.
struct BeforeAfterSplit<Before: View, After: View>: View {

    @Binding var split: Double
    let before: Before
    let after: After

    init(split: Binding<Double>,
         @ViewBuilder before: () -> Before,
         @ViewBuilder after: () -> After) {
        self._split = split
        self.before = before()
        self.after = after()
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clamped = split.isFinite ? Swift.min(Swift.max(split, 0), 1) : 0.5
            ZStack(alignment: .topLeading) {
                before
                    .frame(width: geometry.size.width, height: geometry.size.height)
                after
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(SplitScissor(fraction: clamped))

                Rectangle()
                    .fill(Lumen.primaryText.opacity(0.85))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .offset(x: width * CGFloat(clamped) - 0.5)

                handle
                    .position(x: width * CGFloat(clamped),
                              y: geometry.size.height / 2)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard width > 0 else { return }
                                let f = Double(value.location.x / width)
                                split = Swift.min(Swift.max(f, 0), 1)
                            }
                    )

                HStack {
                    LumenBadge(text: "BEFORE")
                    Spacer(minLength: 0)
                    LumenBadge(text: "AFTER")
                }
                .frame(width: geometry.size.width)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
            }
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: Lumen.swatchRadius(12))
            .fill(Lumen.controlBackground.opacity(0.95))
            .overlay {
                RoundedRectangle(cornerRadius: Lumen.swatchRadius(12)).strokeBorder(Lumen.separator)
            }
            .frame(width: 12, height: 34)
            .overlay {
                Image(systemName: "arrow.left.and.right")
                    .font(.lumenGlyphCaptionStrong)
                    .foregroundStyle(Lumen.primaryText)
            }
    }
}

/// Two-pane compare: each rendition fits its own half. Zoom and pan belong to the split
/// mode; these panes are the "show me both whole frames" answer.
struct BeforeAfterPair: View {

    let mode: BeforeAfterMode
    let before: CGImage
    let after: CGImage

    var body: some View {
        Group {
            if mode == .topBottom {
                VStack(spacing: 1) {
                    pane(before, label: "BEFORE")
                    pane(after, label: "AFTER")
                }
            } else {
                HStack(spacing: 1) {
                    pane(before, label: "BEFORE")
                    pane(after, label: "AFTER")
                }
            }
        }
        .background(Lumen.viewerBackground)
    }

    private func pane(_ image: CGImage, label: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            Lumen.viewerBackground
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
            LumenBadge(text: label)
                .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

// MARK: - Pixel sampling

/// A snapshot of the displayed render as 8-bit sRGB, so the readout HUD and the
/// clipping overlay can answer questions about the picture without going back to the
/// pipeline. Built off the main actor once per render (see `LoupeView.rebuildSampler`);
/// it is a value type of plain bytes, so it crosses actors freely.
///
/// It samples the *proxy that is on screen*, which is the honest thing for a viewer
/// overlay to do: it reports what you are looking at, at the resolution you are looking
/// at it. Scene-referred numbers come from the scopes (`LumenCore.Histogram`), not here.
struct PixelSampler: Sendable {

    /// Identity for `.task(id:)`, since two samplers can share width and height.
    let id: UUID = UUID()
    let width: Int
    let height: Int
    /// RGBA8, row-major, row 0 at the top, alpha byte unused.
    let bytes: [UInt8]

    /// Sampling above this costs more memory than it buys accuracy for a cursor
    /// readout; the render proxies are smaller than it in practice.
    static let maxLongEdge: Int = 4096

    static func make(from image: CGImage, maxLongEdge: Int = PixelSampler.maxLongEdge) -> PixelSampler? {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0, maxLongEdge > 0 else { return nil }
        let longEdge = Swift.max(sourceWidth, sourceHeight)
        let scale: Double = longEdge > maxLongEdge
            ? Double(maxLongEdge) / Double(longEdge)
            : 1
        let width = Swift.max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = Swift.max(1, Int((Double(sourceHeight) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drew: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: base, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return PixelSampler(width: width, height: height, bytes: buffer)
    }

    /// `u`, `v` in [0,1] with `v` measured from the top. Returns the sRGB bytes.
    func pixel(u: Double, v: Double) -> (r: Int, g: Int, b: Int)? {
        guard u.isFinite, v.isFinite, width > 0, height > 0 else { return nil }
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        let x = Swift.min(Swift.max(Int(u * Double(width)), 0), width - 1)
        let y = Swift.min(Swift.max(Int(v * Double(height)), 0), height - 1)
        let index = (y * width + x) * 4
        guard index + 2 < bytes.count else { return nil }
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    /// The sampled pixel expressed in the chosen readout space (D12).
    func readout(u: Double, v: Double, space: ReadoutSpace) -> ReadoutSample? {
        guard let raw = pixel(u: u, v: v) else { return nil }
        let encoded = RGB(Double(raw.r) / 255, Double(raw.g) / 255, Double(raw.b) / 255)
        let x = Swift.min(Swift.max(Int(u * Double(width)), 0), Swift.max(width - 1, 0))
        let y = Swift.min(Swift.max(Int(v * Double(height)), 0), Swift.max(height - 1, 0))

        switch space {
        case .srgb255:
            return ReadoutSample(space: space,
                                 r: Double(raw.r), g: Double(raw.g), b: Double(raw.b),
                                 x: x, y: y, caption: nil, swatch: encoded)
        case .working:
            // Display sRGB → linear sRGB → the pipeline's working primaries, reported
            // as a percentage of working full scale.
            let linear = TransferFunction.srgb.decode(encoded)
            let working = RGBColorSpace.srgb.matrix(to: .rec2020).apply(linear)
            return ReadoutSample(space: space,
                                 r: working.r * 100, g: working.g * 100, b: working.b * 100,
                                 x: x, y: y,
                                 caption: "measured off the displayed proxy",
                                 swatch: encoded)
        case .outputProfile:
            // No export recipe is focused in the viewer yet, so the numbers are the
            // display's. Say that rather than implying a profile we did not apply.
            return ReadoutSample(space: space,
                                 r: Double(raw.r), g: Double(raw.g), b: Double(raw.b),
                                 x: x, y: y,
                                 caption: "no export profile chosen — showing sRGB",
                                 swatch: encoded)
        }
    }
}

// MARK: - Readout HUD

/// One sampled pixel, in the readout space the user chose.
struct ReadoutSample: Equatable {
    let space: ReadoutSpace
    let r: Double
    let g: Double
    let b: Double
    /// Pixel coordinates in the sampled proxy.
    let x: Int
    let y: Int
    /// An honest caveat about what the numbers are, or nil when there is none.
    let caption: String?
    /// The sampled colour as displayed, for the swatch.
    let swatch: RGB

    var decimals: Int { space == .working ? 1 : 0 }
}

/// The on-image colour readout. Same dark HUD pill the Speed Edit ghost readout and the
/// TAT use (docs/12 §B14: one shared component), never wider than it needs to be.
struct ReadoutHUD: View {

    let sample: ReadoutSample

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: Lumen.swatchRadius(11))
                    .fill(swatchColor)
                    .frame(width: 11, height: 11)
                    .overlay {
                        RoundedRectangle(cornerRadius: Lumen.swatchRadius(11))
                            .strokeBorder(Lumen.separator, lineWidth: 0.5)
                    }
                Text(numbers)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Lumen.primaryText)
            }
            Text(sample.space.label)
                .font(.lumenCaption)
                .foregroundStyle(Lumen.secondaryText)
            if let caption = sample.caption {
                Text(caption)
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
            }
            Text("\(sample.x), \(sample.y) px")
                .font(.lumenCaptionNumeric)
                .foregroundStyle(Lumen.secondaryText)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: 190, alignment: .leading)
        // The shared material, and the hairline goes with it: an outline over a
        // photograph is a line drawn on somebody's picture, and the shadow separates
        // this from the frame behind it without one.
        .lumenHUD(radius: Lumen.radiusChip)
    }

    private var numbers: String {
        let format = "%.\(sample.decimals)f"
        return "R " + String(format: format, sample.r)
            + "  G " + String(format: format, sample.g)
            + "  B " + String(format: format, sample.b)
    }

    private var swatchColor: Color {
        Color(.sRGB,
              red: clamp01(sample.swatch.r),
              green: clamp01(sample.swatch.g),
              blue: clamp01(sample.swatch.b),
              opacity: 1)
    }

    private func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return Swift.min(Swift.max(v, 0), 1)
    }
}

// MARK: - Clipping overlay

/// The `J` clipping-threshold overlay. Clipped pixels are painted in the colour that
/// names exactly which channels went — R/G/B for one, yellow/magenta/cyan for two, and
/// the mode's saturated colour for all three — and everything else is left transparent
/// so the overlay reads against the photograph. `fullFrame` switches to the alt-drag
/// threshold view, which floods the unclipped pixels with the mode's flat ground.
///
/// The classification rule itself comes from `LumenCore.ClippingOverlay`, so the
/// overlay, the histogram's corner triangles and the goldens all share one definition
/// of "clipped".
struct ClippingOverlayView: View {

    let sampler: PixelSampler
    let mode: ClippingOverlay.Mode
    var fullFrame: Bool = false

    @State private var overlay: CGImage?

    private struct BuildKey: Equatable {
        let sampler: UUID
        let mode: ClippingOverlay.Mode
        let fullFrame: Bool
    }

    var body: some View {
        Group {
            if let overlay {
                Image(decorative: overlay, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .antialiased(false)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .task(id: BuildKey(sampler: sampler.id, mode: mode, fullFrame: fullFrame)) {
            await rebuild()
        }
    }

    /// Classification runs off the main actor; only the finished image is applied here.
    @MainActor
    private func rebuild() async {
        let source = sampler
        let wanted = mode
        let flood = fullFrame
        let built: CGImage? = await Task.detached(priority: .userInitiated) {
            ClippingOverlayView.build(sampler: source, mode: wanted, fullFrame: flood)
        }.value
        guard !Task.isCancelled else { return }
        overlay = built
    }

    /// One pass over the sampled proxy. The bytes are sRGB-encoded, and the encoding is
    /// monotone with 0↔0 and 1↔1, so "at the floor" and "at the ceiling" mean the same
    /// thing there as they do in readout-linear — which is all the classifier asks.
    nonisolated static func build(sampler: PixelSampler,
                                  mode: ClippingOverlay.Mode,
                                  fullFrame: Bool) -> CGImage? {
        let width = sampler.width
        let height = sampler.height
        guard width > 0, height > 0 else { return nil }
        let source = sampler.bytes
        let pixelCount = width * height
        guard source.count >= pixelCount * 4 else { return nil }

        var out = [UInt8](repeating: 0, count: pixelCount * 4)
        let background: RGB = mode.background
        let saturated: RGB = mode.saturatedColour

        var p: Int = 0
        while p < pixelCount {
            let i = p * 4
            let c = RGB(Double(source[i]) / 255,
                        Double(source[i + 1]) / 255,
                        Double(source[i + 2]) / 255)
            let painted: RGB? = ClippingOverlay.colour(
                mask: ClippingOverlay.mask(c, mode: mode), allChannels: saturated)
            if let painted {
                out[i] = byte(painted.r)
                out[i + 1] = byte(painted.g)
                out[i + 2] = byte(painted.b)
                out[i + 3] = 255
            } else if fullFrame {
                out[i] = byte(background.r)
                out[i + 1] = byte(background.g)
                out[i + 2] = byte(background.b)
                out[i + 3] = 255
            }
            p += 1
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    private nonisolated static func byte(_ v: Double) -> UInt8 {
        guard v.isFinite else { return 0 }
        let scaled = (Swift.min(Swift.max(v, 0), 1) * 255).rounded()
        return UInt8(Swift.min(Swift.max(scaled, 0), 255))
    }
}

// MARK: - Focus peaking

/// docs/10 gives peaking three colours — red, green and white, green by default.
///
/// The VALUES are `MaskOverlay.Tint`'s rather than three more literals. That type
/// already had to pick a red, a green and a white that survive being drawn over a
/// photograph at any exposure, and a second set chosen by a second author is how one
/// app ends up with two greens a shade apart. `black` is the one member not carried
/// across: a black mark on a defocused shadow is invisible, and finding the sharp
/// edges in the dark half of the frame is the case the engine's local-mean divide
/// exists for — offering a colour that throws that away would be offering a way to
/// break the instrument.
///
/// Law 7 (docs/00) is not breached by any of the three. Chrome is zero-chroma, and a
/// peaking mark is not chrome: like the clipping overlay's channel diagnosis it is a
/// reading OF the picture drawn ON the picture, and its whole job is to be a colour
/// the photograph is unlikely to supply.
///
/// TOP-LEVEL AND NOT NESTED AS `FocusPeakingSettings.Tint`, which is where it wants to
/// live, because a second `Tint` in this module costs a check: the surface script's
/// switch pass resolves a bare enum name across the whole tree, and two of them make
/// BOTH ambiguous — so nesting it here silently stopped `MaskOverlay.Tint`'s six
/// switches being checked for missing cases. A distinct name is cheaper than the
/// coverage.
enum PeakingColour: String, CaseIterable, Identifiable, Sendable {
    case green
    case red
    case white

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    /// The shared definition, mapped rather than copied, so a change to the overlay
    /// palette reaches the peaking marks too.
    var overlayTint: MaskOverlay.Tint {
        switch self {
        case .green: return .green
        case .red: return .red
        case .white: return .white
        }
    }

    var colour: RGB { overlayTint.colour }

    var next: PeakingColour {
        let all = PeakingColour.allCases
        guard let i = all.firstIndex(of: self) else { return .green }
        return all[(i + 1) % all.count]
    }
}

/// What the peaking overlay is set to — on or off, which edges it counts, and what
/// colour it marks them in. docs/10 §Focus peaking's whole control table, as one value.
///
/// ONE VALUE RATHER THAN THREE PROPERTIES, because the viewer holds this on `AppState`
/// and the key dispatcher writes it: three published properties would be three
/// broadcasts for one keystroke, and `DragBroadcastTests` exists because this app has
/// already been billed for exactly that.
struct FocusPeakingSettings: Equatable, Sendable {

    var isOn: Bool
    var sensitivity: FocusPeaking.Sensitivity
    var tint: PeakingColour

    init(isOn: Bool = false,
         sensitivity: FocusPeaking.Sensitivity = .normal,
         tint: PeakingColour = .green) {
        self.isOn = isOn
        self.sensitivity = sensitivity
        self.tint = tint
    }

    /// The resting state: off, at the sensitivity and colour docs/10's table defaults to.
    static let off = FocusPeakingSettings()

    /// The chord. Sensitivity and colour are deliberately NOT reset by it — docs/10's
    /// table says "state persists per session", and a photographer who set fine detail
    /// for a landscape roll should not have to set it again every time they look away
    /// from one frame.
    mutating func toggle() {
        isOn.toggle()
    }

    mutating func cycleSensitivity() {
        sensitivity = sensitivity.next
    }

    mutating func cycleTint() {
        tint = tint.next
    }
}

extension FocusPeaking.Sensitivity {

    /// The three, in the panel's voice rather than the wire format's. `fineDetail` reads
    /// "Fine detail" on screen and stays `fineDetail` in anything that ever stores it.
    var label: String {
        switch self {
        case .low: return "Low"
        case .normal: return "Normal"
        case .fineDetail: return "Fine detail"
        }
    }

    /// Strictest to loosest, wrapping — `allCases` order, which is the order docs/10
    /// lists them in, so the control walks the way the documentation reads.
    var next: FocusPeaking.Sensitivity {
        let all = FocusPeaking.Sensitivity.allCases
        guard let i = all.firstIndex(of: self) else { return .normal }
        return all[(i + 1) % all.count]
    }
}

/// The focus-peaking overlay (docs/10 §Focus peaking): thin marks on the edges that are
/// genuinely in focus, so a near-miss can be told from a keeper without zooming to 1:1.
/// It is the one control that makes culling a manual-focus or wide-open shoot possible
/// at all, because at grid size a sharp frame and a soft one are the same photograph.
///
/// `LumenCore.FocusPeaking` HAS BEEN IN THE TREE, FINISHED, WITH NO CALLER ANYWHERE —
/// not in `Sources/`, not in `Tests/`. The audit's H2 sheet lists it among eight
/// declared-and-unreachable scope symbols, and its gap table has it as the viewer's
/// top-five gap with the note "engine exists". It is real code and not a stub: the
/// response is `|centre − mean(8 neighbours)| / max(mean(3×3), floor)`, and run against
/// synthetic frames it gives nothing on a flat field, saturates on a 1 px step, gives
/// nothing on a 16 px ramp of the same contrast, marks the same texture equally at 0.60
/// and at 0.03 luminance, and separates its three thresholds on a texture whose response
/// lands between them. This view is what finally calls it.
///
/// DRAWN AS MARKS, NEVER AS A FILL, which the engine's own comment asks for. The output
/// is a confidence plane that is already zero everywhere except at an edge, so painting
/// the tint at `alpha = confidence` gives outlines by construction — and the alpha
/// carries the confidence rather than being flattened to 1, so a barely-passing edge
/// reads as a hint and a certain one reads as a line. Flattening it would turn the
/// sensitivity control into a switch.
struct FocusPeakingOverlayView: View {

    let sampler: PixelSampler
    var settings: FocusPeakingSettings

    @State private var overlay: CGImage?

    private struct BuildKey: Equatable {
        let sampler: UUID
        let sensitivity: FocusPeaking.Sensitivity
        let tint: PeakingColour
    }

    var body: some View {
        Group {
            if let overlay {
                Image(decorative: overlay, scale: 1, orientation: .up)
                    .resizable()
                    // `.none` and un-antialiased, exactly as the clipping overlay: a
                    // peaking mark is one pixel of evidence, and smoothing it into its
                    // neighbours is the overlay inventing sharpness it did not measure.
                    .interpolation(.none)
                    .antialiased(false)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .task(id: BuildKey(sampler: sampler.id,
                           sensitivity: settings.sensitivity,
                           tint: settings.tint)) {
            await rebuild()
        }
    }

    /// The engine runs off the main actor; only the finished image is applied here.
    @MainActor
    private func rebuild() async {
        let source = sampler
        let wanted = settings.sensitivity
        let colour = settings.tint
        let built: CGImage? = await Task.detached(priority: .userInitiated) {
            FocusPeakingOverlayView.build(sampler: source, sensitivity: wanted, tint: colour)
        }.value
        guard !Task.isCancelled else { return }
        overlay = built
    }

    /// The confidence plane the engine returns for the frame on screen, at the
    /// resolution it is on screen — which is what this file's header says an overlay
    /// owes: it reports what you are looking at, at the resolution you are looking at it.
    ///
    /// LINEARIZED FIRST, and this is the one place the peaking overlay must NOT copy the
    /// clipping overlay. That one reads the sRGB bytes directly and argues, correctly,
    /// that the encoding is monotone with 0↔0 and 1↔1 so "at the ceiling" survives it.
    /// Peaking asks a different question: its response is a RATIO of a local difference
    /// to a local mean, and a gamma curve rescales differences and means by different
    /// factors at different levels. Left encoded, the same texture would read as a
    /// different response in the shadows than in the highlights — which is precisely the
    /// failure the engine's divide-by-the-local-mean exists to remove, reintroduced one
    /// layer above it. So the bytes are decoded to display-linear and luminance is taken
    /// with the sRGB primaries' own weights, which give Y directly for values in that
    /// space.
    ///
    /// The decode is a 256-entry table built per call rather than a `pow` per channel per
    /// pixel: there are 256 possible byte values and up to sixteen million pixels, so the
    /// table costs 256 transcendentals against three per pixel without it. Built locally
    /// rather than cached in a static because 256 `pow`s is nothing beside the pass that
    /// follows, and a shared table would be shared mutable state for no gain.
    nonisolated static func confidence(sampler: PixelSampler,
                                       sensitivity: FocusPeaking.Sensitivity) -> Plane? {
        let width = sampler.width
        let height = sampler.height
        guard width > 0, height > 0 else { return nil }
        let pixelCount = width * height
        guard sampler.bytes.count >= pixelCount * 4 else { return nil }

        let linear: [Double] = (0...255).map {
            TransferFunction.srgb.decode(Double($0) / 255)
        }
        let weights = RGBColorSpace.srgb.luminanceWeights

        var luminance = [Float](repeating: 0, count: pixelCount)
        var p: Int = 0
        while p < pixelCount {
            let i = p * 4
            luminance[p] = Float(weights.r * linear[Int(sampler.bytes[i])]
                                 + weights.g * linear[Int(sampler.bytes[i + 1])]
                                 + weights.b * linear[Int(sampler.bytes[i + 2])])
            p += 1
        }

        return FocusPeaking.compute(Plane(width: width, height: height, values: luminance),
                                    threshold: sensitivity.threshold)
    }

    /// The confidence plane, painted in the chosen colour and transparent everywhere the
    /// engine found no edge.
    ///
    /// PREMULTIPLIED, because the `CGImage` below declares `premultipliedLast` and this
    /// is the first overlay in the file whose alpha is not 0 or 255. The clipping overlay
    /// writes straight colour under the same declaration and is right to: every pixel it
    /// paints is fully opaque, so premultiplying by 1 is the identity. Here it is not,
    /// and writing unpremultiplied bytes under that flag would draw the marks too bright
    /// and haloed — the classic version of this bug, shipped by everybody once.
    nonisolated static func build(sampler: PixelSampler,
                                  sensitivity: FocusPeaking.Sensitivity,
                                  tint: PeakingColour) -> CGImage? {
        guard let confidence = FocusPeakingOverlayView.confidence(sampler: sampler,
                                                                  sensitivity: sensitivity)
        else { return nil }
        let width = confidence.width
        let height = confidence.height
        let pixelCount = width * height
        let colour = tint.colour

        var out = [UInt8](repeating: 0, count: pixelCount * 4)
        var p: Int = 0
        while p < pixelCount {
            let raw = Double(confidence.values[p])
            let alpha = raw.isFinite ? Swift.min(Swift.max(raw, 0), 1) : 0
            if alpha > 0 {
                let i = p * 4
                out[i] = byte(colour.r * alpha)
                out[i + 1] = byte(colour.g * alpha)
                out[i + 2] = byte(colour.b * alpha)
                out[i + 3] = byte(alpha)
            }
            p += 1
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    private nonisolated static func byte(_ v: Double) -> UInt8 {
        guard v.isFinite else { return 0 }
        let scaled = (Swift.min(Swift.max(v, 0), 1) * 255).rounded()
        return UInt8(Swift.min(Swift.max(scaled, 0), 255))
    }
}

/// Peaking's toggle, and the only thing on screen that says peaking is on.
///
/// IT IS NOT A PANEL ROW ON PURPOSE. Peaking is a viewer instrument, like the clipping
/// overlay and the before/after: it answers a question about the photograph rather than
/// changing it, it belongs in the cull loop where there is no develop column open, and
/// docs/10 puts it in the loupe, survey and compare alike. A row in Detail would put a
/// judgement about focus inside the panel that CHANGES sharpening, which is the confusion
/// this app spends whole files avoiding.
///
/// The badge exists because a chord with no visible state is a trap: green speckle on a
/// frame, with nothing to name it, is indistinguishable from a rendering fault — and the
/// photographer who hit `⇧F` an hour ago has no way to find the thing to turn off. So it
/// names the mode, carries the two settings that change what the marks mean, and closes
/// itself. Everything it does is also reachable from the keyboard; nothing it does is
/// ONLY reachable here.
struct FocusPeakingHUD: View {

    @Binding var settings: FocusPeakingSettings

    /// False when the picture underneath is a stand-in rather than the file's own
    /// detail — a preview from the embedded JPEG, or a draft render that has not been
    /// refined yet.
    ///
    /// docs/10 asks for this by name: "peaking on a 1616×1080 preview is labeled with the
    /// shimmer badge because it cannot be trusted at pixel level". An edge measurement
    /// taken on a resampled stand-in is a measurement of the RESAMPLER, and a focus
    /// instrument that will not say when it is guessing is worse than no instrument,
    /// because a keeper gets deleted on its word. It defaults to true so a caller that
    /// has not worked out its own answer yet cannot silently claim the caveat is handled.
    var atPixelLevel: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Button {
                settings.cycleTint()
            } label: {
                Circle()
                    .fill(swatch)
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle().strokeBorder(Lumen.separator, lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .lumenClickCursor()
            .help("Peaking colour — \(settings.tint.label)")

            VStack(alignment: .leading, spacing: 1) {
                Text("Peaking")
                    .font(.lumenCaptionStrong)
                    .foregroundStyle(Lumen.primaryText)
                if !atPixelLevel {
                    // Named rather than hinted. "Preview" is the word the rest of the
                    // app uses for a stand-in rendition, and the second half is what the
                    // photographer actually needs to know: do not decide on this.
                    Text("preview — not a pixel-level read")
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.tertiaryText)
                }
            }

            Button {
                settings.cycleSensitivity()
            } label: {
                Text(settings.sensitivity.label)
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Lumen.controlSurface)
                    .clipShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .lumenInteractive(radius: Lumen.radiusChip)
            .help("Sensitivity — low, normal, fine detail")

            Button {
                settings.isOn = false
            } label: {
                Image(systemName: "xmark")
                    .font(.lumenGlyphCaption)
                    .foregroundStyle(Lumen.secondaryText)
            }
            .buttonStyle(.plain)
            .lumenClickCursor()
            .help("Turn peaking off (⇧F)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // The one material everything that floats over the photograph is made of. The
        // chip radius rather than the card's, because this is a strip of controls and
        // not a surface — the readout HUD two hundred lines up made the same call.
        .lumenHUD(radius: Lumen.radiusChip)
    }

    private var swatch: Color {
        let c = settings.tint.colour
        return Color(.sRGB,
                     red: Swift.min(Swift.max(c.r, 0), 1),
                     green: Swift.min(Swift.max(c.g, 0), 1),
                     blue: Swift.min(Swift.max(c.b, 0), 1),
                     opacity: 1)
    }
}

// MARK: - Mask overlay

/// The solo-mask overlay: all six of docs/08 §8.6's modes, over the pixels the loupe
/// is showing.
///
/// It draws an opaque layer computed by `MaskOverlay.composite`, exactly as
/// `ClippingOverlayView` does, rather than tinting through a SwiftUI `.mask`. Two
/// reasons: four of the six modes have to change the UNMASKED pixels (grey them,
/// black them, white them), which a tint layer cannot do; and the mask form was
/// silently broken anyway, because `.mask` reads the masking view's alpha channel and
/// the grey raster it was handed had none.
///
/// With no alpha yet — the raster is computed off the main actor — it draws nothing at
/// all. A flat wash while the numbers are in flight reads as "this mask selects
/// everything", which is the exact misreading this view exists to prevent.
struct MaskOverlayView: View {

    let alpha: Plane?
    let sampler: PixelSampler?
    /// The geometry the preview underneath has already been through, and the frame the
    /// alpha is expressed against. A mask raster is in SOURCE coordinates — uncropped
    /// and unrotated, because that is the invariant that lets a crop re-rasterize a
    /// mask instead of orphaning it — while the picture on screen has been cropped and
    /// straightened. Stretching one onto the other put the overlay somewhere other than
    /// the mask on any cropped photograph.
    var geometry: Geometry = Geometry()
    var sourceSize: CGSize = .zero
    var mode: MaskOverlay.Mode = .colorOverlay
    var tint: MaskOverlay.Tint = .red
    var strength: Double = MaskOverlay.defaultStrength

    @State private var overlay: CGImage?
    /// The composite in flight, so a superseded one can be told to stop.
    @State private var buildTask: Task<CGImage?, Never>?

    /// The longest edge the composite is built at.
    ///
    /// See `build`: the overlay is drawn resizable and interpolated into a pane rarely
    /// wider than 1400 points, over a mask raster whose own long edge is 1024, so
    /// compositing at the sampler's full 4096 was interpolating an interpolation at
    /// four times the cost. 2048 keeps a downscale on the way to the screen.
    static let compositeLongEdge = 2048

    private struct BuildKey: Equatable {
        let sampler: UUID?
        let width: Int
        let height: Int
        let checksum: Float
        let geometry: Geometry
        let mode: MaskOverlay.Mode
        let tint: MaskOverlay.Tint
        let strength: Double
    }

    var body: some View {
        Group {
            if let overlay {
                Image(decorative: overlay, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .task(id: buildKey) { await rebuild() }
    }

    /// The alpha plane is a value type with no identity, so the key carries its extent
    /// and the sum of its values — enough for "the mask changed" without hashing a
    /// megapixel on every layout pass.
    private var buildKey: BuildKey {
        var checksum: Float = 0
        if let alpha {
            var i = 0
            let stride = Swift.max(1, alpha.values.count / 4096)
            while i < alpha.values.count {
                checksum += alpha.values[i]
                i += stride
            }
        }
        return BuildKey(sampler: sampler?.id,
                        width: alpha?.width ?? 0, height: alpha?.height ?? 0,
                        checksum: checksum, geometry: geometry,
                        mode: mode, tint: tint, strength: strength)
    }

    @MainActor
    private func rebuild() async {
        // CANCEL THE ONE BEFORE IT, and hold the handle so that is possible at all.
        //
        // `Task.detached` is not a child task, so `.task(id:)` tearing down the previous
        // `rebuild` never reached the work it had started — and `await …value` on a
        // `Task<_, Never>` does not observe the parent's cancellation either. Every
        // superseded composite therefore ran to completion. During a drag that is one
        // full-frame composite per delivered frame, none of them cancelled, none of them
        // ever shown, each holding tens of megabytes while it ran; the queue only drained
        // when the hand stopped. That is the trail.
        //
        // Detached is still right — this is heavy CPU work and it must not inherit the
        // main actor — so the fix is an explicit handle rather than a child task.
        buildTask?.cancel()
        guard let alpha else {
            buildTask = nil
            overlay = nil
            return
        }
        let picture = sampler
        let wanted = mode
        let colour = tint
        let amount = strength
        let frame = geometry
        let native = sourceSize
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            MaskOverlayView.build(alpha: alpha, sampler: picture, geometry: frame,
                                  sourceSize: native, mode: wanted,
                                  tint: colour, strength: amount)
        }
        buildTask = task
        let built = await task.value
        guard !Task.isCancelled else { return }
        // A cancelled build returns nil, and nil means "draw nothing". Keeping the last
        // good overlay instead of blanking it is what stops the red flickering out on
        // every superseded frame of a drag.
        if let built { overlay = built }
    }

    /// Composited at the PICTURE's resolution when there is one, so the mask edge is
    /// drawn against the pixels it is judged against rather than against a 1024-px
    /// raster's staircase. The alpha is sampled bilinearly, which is what makes that
    /// legitimate: mask rasters are smooth by construction.
    nonisolated static func build(alpha: Plane, sampler: PixelSampler?,
                                  geometry: Geometry, sourceSize: CGSize,
                                  mode: MaskOverlay.Mode, tint: MaskOverlay.Tint,
                                  strength: Double) -> CGImage? {
        let needsPicture = mode.readsPicture
        // The sampler's ASPECT for every mode, including the Matte: the layer is drawn
        // over the DISPLAYED frame, so it has to carry the displayed frame's aspect. A
        // matte built at the source raster's aspect would be stretched on any crop.
        //
        // But not the sampler's SIZE. It is capped at 4096, so on a 5K pane this loop
        // ran 11.2 million times — measured at 823 ms — to produce an image that is then
        // drawn `.resizable()` with `.interpolation(.high)` into a pane rarely wider than
        // 1400 points. The mask raster underneath it is 1024 on its long edge and, in
        // this file's own words, "smooth by construction", so nothing above that carries
        // mask detail: the extra pixels were interpolating an interpolation.
        //
        // `compositeLongEdge` is the aspect-preserving bound. At 2048 a 3:2 frame is 2.8
        // megapixels against 11.2 — a straight 4× off the dominant term — and it is
        // still 1.5× the pane it lands in, so the resample on the way to the screen is a
        // downscale rather than a stretch.
        //
        // AND IT FOLLOWS THE ALPHA DOWN. `refreshMaskOverlay` rasterizes a DRAFT alpha
        // — half the long edge — while a gesture is running, and compositing a 512-px
        // alpha into a 2048-px layer is the same "interpolating an interpolation" this
        // comment already objects to, one level further in: the extra pixels cannot
        // carry mask detail the alpha does not have. Bounding the composite at twice
        // the alpha's own long edge ties the cost of the expensive loop to the quality
        // of its input, so a live drag pays a quarter of the pixels for a layer that
        // looks the same, and the settled pass gets the full 2048 back automatically
        // when the full-size alpha lands. Twice rather than exactly, because the
        // picture underneath IS sharp in the modes that read it.
        let rawWidth = sampler?.width ?? alpha.width
        let rawHeight = sampler?.height ?? alpha.height
        guard rawWidth > 0, rawHeight > 0 else { return nil }
        let cap = MaskOverlay.compositeLongEdge(
            alphaLongEdge: Swift.max(alpha.width, alpha.height),
            cap: compositeLongEdge)
        let longest = Swift.max(rawWidth, rawHeight)
        let shrink = longest > cap ? Double(cap) / Double(longest) : 1
        let width = Swift.max(1, Int((Double(rawWidth) * shrink).rounded()))
        let height = Swift.max(1, Int((Double(rawHeight) * shrink).rounded()))
        let bytes = sampler?.bytes
        let usable = needsPicture && bytes != nil
            && (bytes?.count ?? 0) >= width * height * 4
        // Five of the six modes are opaque layers built FROM the picture. Without the
        // picture they would paint a black frame with a tint on it, which is a worse
        // lie than drawing nothing, so they wait for the sampler instead.
        if needsPicture && !usable { return nil }

        // The alpha lives in source coordinates; the picture on screen has been cropped
        // and straightened. `sourceNormalized` is the exact inverse of the transform
        // the renderer applied — the same one `MaskCanvas` uses to place a gesture —
        // so the overlay lands on the pixels the mask selects. With no frame size
        // supplied there is nothing to invert and the plane is stretched, which is
        // right for an uncropped photograph and no worse than before for a cropped one.
        let reproject = sourceSize.width > 0 && sourceSize.height > 0

        // THE MAP IS AFFINE, so it is solved once instead of per pixel.
        //
        // `sourceNormalized` inverts a crop and a straighten — a translate, a scale and
        // a rotation, every one of them affine — but it was being called inside the
        // inner loop, and it walks `geometryRects` → `CropGeometry.resolve` →
        // `usableSize` on the way, which runs `sin` and `cos` unconditionally even at
        // angle 0. Measured at 4096×2731: 136 ms of the composite's 823 was this one
        // call, evaluated 11.2 million times to produce a mapping with six coefficients.
        //
        // Three probes give the coefficients; a fourth checks them. If the fourth
        // disagrees the map is not affine after all and the per-pixel path is used, so
        // this is an optimisation that cannot change what is drawn.
        var affine: (su: (Double, Double, Double), sv: (Double, Double, Double))?
        if reproject {
            func probe(_ u: Double, _ v: Double) -> (Double, Double) {
                let p = PipelineRenderer.sourceNormalized(displayedX: u, displayedY: v,
                                                          geometry: geometry,
                                                          sourceSize: sourceSize)
                return (Double(p.x), Double(p.y))
            }
            let o = probe(0, 0), du = probe(1, 0), dv = probe(0, 1)
            let candidate = (su: (o.0, du.0 - o.0, dv.0 - o.0),
                             sv: (o.1, du.1 - o.1, dv.1 - o.1))
            let check = probe(0.37, 0.63)
            let predictedU = candidate.su.0 + candidate.su.1 * 0.37 + candidate.su.2 * 0.63
            let predictedV = candidate.sv.0 + candidate.sv.1 * 0.37 + candidate.sv.2 * 0.63
            if abs(predictedU - check.0) < 1e-9, abs(predictedV - check.1) < 1e-9 {
                affine = candidate
            }
        }

        let aw = Double(alpha.width), ah = Double(alpha.height)
        let pictureWidth = sampler?.width ?? 0
        let pictureHeight = sampler?.height ?? 0
        // The picture is read at whatever resolution the sampler happens to be and the
        // composite is built at `width`×`height`, so the two are no longer required to
        // match — which is what lets the working resolution be bounded above.
        let sx = pictureWidth > 0 ? Double(pictureWidth) / Double(width) : 0
        let sy = pictureHeight > 0 ? Double(pictureHeight) / Double(height) : 0

        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<height {
                // A superseded composite used to run to completion — `Task.detached` is
                // not a child task, so `.task(id:)` cancelling the wrapper never reached
                // the loop, and a drag queued one full-frame composite per delivered
                // frame with nothing draining them. Checked per row rather than per
                // pixel: the check is cheap but not free, and a row is under a
                // millisecond.
                if Task.isCancelled { return }
                let v = (Double(y) + 0.5) / Double(height)
                let py = pictureHeight > 0
                    ? Swift.min(pictureHeight - 1, Swift.max(0, Int((Double(y) + 0.5) * sy)))
                    : 0
                for x in 0..<width {
                    let u = (Double(x) + 0.5) / Double(width)
                    var su = u
                    var sv = v
                    if let affine {
                        su = affine.su.0 + affine.su.1 * u + affine.su.2 * v
                        sv = affine.sv.0 + affine.sv.1 * u + affine.sv.2 * v
                    } else if reproject {
                        let point = PipelineRenderer.sourceNormalized(
                            displayedX: u, displayedY: v, geometry: geometry,
                            sourceSize: sourceSize)
                        su = Double(point.x)
                        sv = Double(point.y)
                    }
                    let a = alpha.bilinear(su * aw, sv * ah)
                    var picture = RGB.zero
                    if usable, let bytes, pictureWidth > 0 {
                        let px = Swift.min(pictureWidth - 1,
                                           Swift.max(0, Int((Double(x) + 0.5) * sx)))
                        let i = (py * pictureWidth + px) * 4
                        picture = RGB(Double(bytes[i]) / 255,
                                      Double(bytes[i + 1]) / 255,
                                      Double(bytes[i + 2]) / 255)
                    }
                    let c = MaskOverlay.composite(picture: picture, alpha: a, mode: mode,
                                                  tint: tint, strength: strength)
                    let i = (y * width + x) * 4
                    buffer[i] = byte(c.r)
                    buffer[i + 1] = byte(c.g)
                    buffer[i + 2] = byte(c.b)
                    buffer[i + 3] = 255
                }
            }
        }
        if Task.isCancelled { return nil }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    private nonisolated static func byte(_ v: Double) -> UInt8 {
        guard v.isFinite else { return 0 }
        let scaled = (Swift.min(Swift.max(v, 0), 1) * 255).rounded()
        return UInt8(Swift.min(Swift.max(scaled, 0), 255))
    }
}

// MARK: - Crop overlay

/// What the pointer is over, which is the same question as "what would a press here do".
///
/// One value rather than ten booleans, because the regions are mutually exclusive by
/// construction and the alternative — a hover flag on each target — cannot say which of
/// two overlapping regions won. `CropGeometry.Handle` carries all eight resize cases, so
/// this adds exactly the two the handles do not name.
private enum CropRegion: Equatable {
    /// Beside the rectangle, on the picture: a drag here turns the frame.
    case outside
    /// Within the rectangle: a drag here slides the crop.
    case inside
    /// On one of the eight resize targets.
    case handle(CropGeometry.Handle)
}

/// One corner's L, in the coordinate space of the square the corner sits at the centre of.
///
/// It is offset OUTWARD by half the stroke width, so the bracket's inner edge lands
/// exactly on the rectangle's boundary and the rest of it overhangs onto the dimmed side.
/// That is the whole reason a bracket reads as a handle: it is visibly attached to the
/// corner and visibly not part of the picture you are keeping.
private struct CropCornerBracket: Shape {
    /// Only the four corner cases are ever passed; an edge would draw the bottom-right L.
    let handle: CropGeometry.Handle
    let leg: CGFloat
    /// Half the light stroke's width — see the type comment.
    let offset: CGFloat

    func path(in rect: CGRect) -> Path {
        // Which way the legs run from the corner, in this view's y-down space.
        let sx: CGFloat = (handle == .topLeft || handle == .bottomLeft) ? 1 : -1
        let sy: CGFloat = (handle == .topLeft || handle == .topRight) ? 1 : -1
        let x = rect.midX - sx * offset
        let y = rect.midY - sy * offset
        var path = Path()
        path.move(to: CGPoint(x: x + sx * leg, y: y))
        path.addLine(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x, y: y + sy * leg))
        return path
    }
}

/// The crop rectangle over the drawn image: the area outside dimmed, guides inside, eight
/// resize handles, the interior to drag it by — and, outside it, the picture itself to
/// turn.
///
/// THE RECTANGLE IS NOT A FRACTION OF THIS VIEW, which is the whole reason the mapping
/// below goes through `PipelineRenderer`. `Crop` is normalized to the USABLE frame — the
/// largest axis-aligned rectangle inside the source rotated by `angle` — and what the
/// loupe is drawing is whatever `renderPreview` was asked for. Those coincide today
/// because the crop tool asks for the uncropped frame, and multiplying the crop by this
/// view's size worked for exactly that reason. It is the kind of correct that stops being
/// correct the day somebody changes what the loupe shows, silently and with the rectangle
/// still drawn plausibly, so the two conversions the mask tools already use do the work
/// instead: `sourceNormalized` out of the usable frame's coordinates and
/// `displayedNormalized` into the drawn one's.
///
/// ROTATION IS A DRAG, not a slider. docs/09: "the image moves under a fixed frame … drag
/// outside the frame to rotate (the angle readout ghosts next to the cursor)". Before
/// this there was no rotation affordance on the picture at all — a ±45 slider and a ruler
/// you had to arm with a button, neither of which is a hand on the photograph.
///
/// AND IT ALL HAD TO BE VISIBLE, which was the half that was still missing. The owner,
/// with every gesture below already built and correct: "Right now, I don't really know
/// how to edit it by hand. It's a little difficult for me to see."
///
/// He was not wrong about any of it, and the causes are measurable rather than a matter
/// of taste:
///
///   · A CORNER WAS A 7 pt WHITE SQUARE — `Lumen.primaryText`, which is white 0.92, with
///     nothing dark under it. Against a blown highlight that is about 1.17:1, and
///     `LumenSurface.swift` has already done the arithmetic on what the eye does with an
///     edge at 1.1:1: it does not find one. And even where it CAN be seen, a dot reads
///     as a blemish. Every serious crop tool — Lightroom, Capture One, Photos — draws an
///     L-shaped bracket that OVERHANGS the corner instead, because a bracket is a shape
///     you can imagine taking hold of and a dot is not.
///   · AN EDGE HANDLE WAS A 2 pt BAR, at the same 1.17:1 and half the width.
///   · NOTHING ANSWERED THE POINTER. No cursor changed anywhere in this overlay and no
///     handle lit up — the exact defect `LumenHover.swift` opens by naming ("zero
///     `NSCursor` changes anywhere in the application"), in the one surface of the app
///     where the controls are invisible by construction because they sit on a
///     photograph.
///   · AND THE ROTATE DRAG ADVERTISED ITSELF ONLY AFTER IT HAD STARTED. The readout
///     ghosts beside the cursor once the hand is already moving, which teaches nobody:
///     "drag outside the frame" is not a thing you try on a picture you are afraid of
///     damaging unless something told you first.
///
/// So: every mark on the picture is now drawn TWICE, a near-black stroke under a light
/// one, which is the standard trick for chrome that has to survive both a white sky and
/// a black shadow and costs one extra path per element. Zero chroma throughout (docs/00
/// Law 7 — this overlay sits ON the photograph, so it may not carry a hue at all); the
/// one exception is the transient rotation horizon, which was already `Lumen.accent` and
/// stays that way because it is a measurement in flight rather than chrome.
///
/// THE POINTER IS RESOLVED ONCE, ANALYTICALLY, rather than by hanging an `onHover` on
/// each of the ten targets. Overlapping `onHover` regions have no defined ordering
/// between them — a corner target straddles the interior and two edge strips — so the
/// cursor would have been whichever region happened to be told last, and the pushes and
/// pops would interleave. `onContinuousHover` on the container gives one point, `region`
/// turns it into one answer using the same precedence the targets are stacked in, and
/// exactly one `NSCursor` is ever pushed. The state is view-local `@State` and changes
/// only when the region CHANGES, not per mouse event: hover must never reach an
/// `ObservableObject` here — `LumenHover` states that rule and names the time this
/// application already paid for breaking it, and `PanelLayout` exists to publish as
/// rarely as its value actually changes.
struct CropOverlayView: View {

    @Binding var crop: Crop
    /// The recipe's geometry. Three things need it: the mapping needs the angle and the
    /// flip, the rotate gesture needs the angle it is starting from, and the flip decides
    /// which way a sweep turns the picture.
    let geometry: Geometry
    /// The SOURCE frame in pixels — the decoded size, not the preview's. Same reason
    /// `MaskCanvas` needs it: the preview has already been cropped and straightened.
    let sourceSize: CGSize
    /// Whether the picture underneath has already been cut to the crop. False while the
    /// tool is open, which is what `showingUncropped` at the render call site arranges.
    var viewShowsCrop: Bool = false
    /// The photograph being cropped, so the ratio lock is the one chosen for THIS frame
    /// rather than the one left behind by the last frame (`CropTool`).
    let photoID: URL
    /// Called with the angle a rotate-drag produces, per event, so the picture turns
    /// under the frame while the hand is still down.
    let onAngle: (Double) -> Void
    /// The usable frame's own width ÷ height in pixels. The crop is normalized to that
    /// frame, so it is what converts a pixel ratio into a normalized one.
    var frameAspect: Double = 1

    /// The gesture-in-flight signal every slider fires (docs/23 audit queue item 5):
    /// a crop drag writes the recipe through `cropBinding` per event.
    @Environment(\.sliderGestureChanged) private var sliderGestureChanged
    @ObservedObject private var tool: CropTool = CropTool.shared

    /// The invisible square a corner press has to land in.
    ///
    /// 24, up from 14. A 14 pt target is one you have to aim at, and what it was drawn
    /// around was a 7 pt dot — so a miss did not do nothing, it landed on the interior
    /// and MOVED the crop, which is the worst kind of wrong answer because it looks
    /// deliberate until you notice the framing has slid.
    private static let cornerTarget: CGFloat = 24
    /// The square a corner bracket is DRAWN inside, which is much larger than the target
    /// because the bracket overhangs the rectangle in both directions. It carries no hit
    /// testing of its own, so it costs nothing to make it roomy: it only has to be big
    /// enough that a leg and its stroke are never clipped by their own frame.
    private static let cornerBox: CGFloat = 52
    /// How far a bracket's legs run along the two edges that meet at the corner.
    ///
    /// 22 pt reads as "this corner" rather than as "this side" — long enough to be a
    /// shape at a glance, short enough that on a small crop the four brackets do not
    /// join up into a second rectangle inside the first one.
    private static let bracketLeg: CGFloat = 22
    /// The light stroke's weight, for both the brackets and the edge bars. The dark
    /// companion underneath is this plus two, so a full point of near-black shows on
    /// either side of it whatever the picture is doing.
    private static let markWeight: CGFloat = 3
    /// How far from an edge a drag still counts as that edge.
    private static let edgeThickness: CGFloat = 12

    /// The coordinate space the move and resize drags are measured in: the overlay's
    /// own root, which holds still while a rectangle drag is under way.
    ///
    /// THIS IS THE EDGE-DRAG GLITCH, so it gets stated in full. A `DragGesture`'s
    /// default `.local` space is the view the gesture is attached to — and the edge and
    /// corner hit targets are placed with `.position(…)` computed from the LIVE crop
    /// rect, so every `onChanged` that wrote the crop moved the gesture's own coordinate
    /// space by the delta it had just applied. The next event's `translation`
    /// (location − startLocation, both in that moving space) collapsed back toward
    /// zero, the rectangle snapped back, the event after that re-applied it — an
    /// oscillation between the press origin and the pointer at event rate, which is
    /// the owner's "spazzing out … it doesn't follow the cursor". The interior's move
    /// drag never glitched because its host is placed with `.offset(…)`, a render-time
    /// translation that leaves the layout frame — and with it the `.local` space —
    /// anchored; that asymmetry is why "moving the box is good" while the edges
    /// misbehaved. The rotate drag's comment below documents the same trap and dodges
    /// it with `.global`; these two now dodge it with a space that cannot move during
    /// the drags it measures. (The root's own size changes only with the ANGLE, which
    /// no move or resize drag touches.)
    private static let dragSpace = "crop.overlay"

    /// ⇧ gears a rotate drag down by this factor — a rotate is a slider whose track is
    /// an arc, and this is its fine drag.
    private static let fineRotationGear: Double = 0.2

    @State private var dragOrigin: Crop?
    @State private var rotation: RotationDrag?
    /// Which region the pointer is in, or nil when it is not over the overlay at all.
    ///
    /// VIEW-LOCAL AND COARSE. It drives the cursor, the handle under the pointer, and
    /// the rotate cue, and it is written only when the answer changes — so crossing from
    /// the interior onto a corner re-bodies this view once, and moving the mouse a
    /// hundred points inside the rectangle re-bodies it not at all.
    @State private var hover: CropRegion?
    /// True while this view owns the top of the `NSCursor` stack. Push and pop have to
    /// balance (`LumenHover`'s discipline), and the one thing that would unbalance them
    /// is the tool being put away while the pointer is still inside — hence the pop in
    /// `onDisappear` as well as on the way out.
    @State private var pushedCursor: Bool = false

    /// What a rotate-drag has to remember. The pivot is fixed at the press: recomputing
    /// it per event would measure each sweep against a frame the last sweep had already
    /// moved, which integrates its own rounding. `sweep` is the raw sweep the last
    /// event measured — always against the press point, so it carries no accumulation —
    /// and it is what lets the ⇧ fine gear be applied to each event's INCREMENT:
    /// pressing or releasing the modifier mid-drag changes the gearing without jumping
    /// the picture, the same contract `LumenSlider`'s gearbox keeps for a straight
    /// track.
    private struct RotationDrag {
        var pivot: CGPoint
        var degrees: Double
        var location: CGPoint
        var sweep: Double = 0
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = frameRect(in: size)
            let rect = pixelRect(in: frame)
            // Read here rather than inside the gesture: a `GeometryProxy` is only
            // documented to be good during the body pass that produced it, and what the
            // rotate-drag needs from it is one origin.
            let windowOrigin = proxy.frame(in: .global).origin
            // Built once and stroked twice. The dark companion and the light line are the
            // same path, so computing it here rather than inside each `.stroke` keeps the
            // doubling free — and guarantees the two can never be a pixel out of register.
            let guidePath = guides(in: rect)
            // The loupe draws the FULL frame under this overlay while the tool is armed,
            // turned in the view layer, and sizes the overlay to the usable frame — so
            // the picture's tilted corners stick out past these bounds. The dim and the
            // rotate catcher both reach that far, or the overhang would read as bright,
            // grabbable picture that neither dims nor turns.
            let overhang = plateOverhang(in: size)
            ZStack(alignment: .topLeading) {
                // FIRST, so everything below wins where they overlap: a press inside the
                // rectangle or on a handle belongs to that, and a press anywhere else is
                // a press on the picture, which is what turns it.
                Rectangle()
                    // Not `.clear`: a fully transparent shape is not hit-testable and the
                    // drag would fall through to the loupe's pan.
                    .fill(Lumen.accent.opacity(0.001))
                    // The hit SHAPE reaches over the plate's overhang; the layout frame
                    // does not, because a child larger than the GeometryReader's
                    // proposal would re-place the whole stack. The inset is the larger
                    // overhang on both axes, which over-reaches one of them slightly —
                    // harmless, because `startsOnThePicture` already declines a press
                    // that lands beside the picture rather than on it.
                    .contentShape(Rectangle().inset(
                        by: -Swift.max(overhang.width, overhang.height)))
                    .gesture(rotateGesture(in: size, windowOrigin: windowOrigin))
                    .help("Drag out here, outside the frame, to turn the picture under "
                          + "it — hold ⇧ to turn finely. The angle shows beside the "
                          + "cursor while you drag.")

                // STILL 0.5, and still even-odd. The brighter chrome does not want a
                // lighter shield: the marks that had to survive the picture now carry
                // their own dark companion, so the dim is back to doing only its own job
                // — telling you which part of the frame you are keeping — and half a stop
                // under is what makes that legible without pretending the discarded part
                // is gone.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size)
                        .insetBy(dx: -overhang.width - 2, dy: -overhang.height - 2))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // THE RECTANGLE, TWICE. A 3 pt near-black line centred on the boundary
                // with the 1 pt light line on top of it: one point of black shows on
                // either side, which is enough to hold the edge against a blown sky. The
                // outer half of the dark stroke lands on the dimmed side where it is
                // redundant, and that is fine — a stroke centred on the boundary is the
                // only version that cannot drift out of register with the light one.
                Group {
                    boundary(of: rect).stroke(Color.black.opacity(0.38), lineWidth: 3)
                    boundary(of: rect).stroke(Lumen.primaryText.opacity(0.95), lineWidth: 1)
                }
                .allowsHitTesting(false)

                // Same treatment at half the weight. A guide is meant to be felt rather
                // than read, so the light line stays at 0.5 pt and the companion is a
                // soft halo rather than an outline.
                Group {
                    guidePath.stroke(Color.black.opacity(0.25), lineWidth: 2)
                    guidePath.stroke(Lumen.primaryText.opacity(0.45), lineWidth: 0.5)
                }
                .allowsHitTesting(false)

                if let rotation {
                    horizon(in: rect)
                        .stroke(Lumen.accent.opacity(0.8),
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .allowsHitTesting(false)
                    readout(rotation)
                }

                rotateCueLayer(in: rect)

                // ONE `Group`, because a `ViewBuilder` takes ten children and nine of
                // this overlay's are the rectangle's own targets. The failure mode is
                // not "too many children" — see `KeyGrammarTests`' note on the same
                // limit in a `Commands` builder — so the grouping is deliberate rather
                // than incidental.
                Group {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .gesture(moveGesture(in: frame))
                        .help("Drag to slide the crop over the picture.")

                    // Edges before corners, so a corner's hit area wins where they
                    // overlap — the corner is the finer adjustment and the harder to hit.
                    // `region(at:rect:)` resolves the pointer in the same order, so the
                    // cursor can never promise a handle the press would not reach.
                    edge(.top, in: rect, frame: frame)
                    edge(.bottom, in: rect, frame: frame)
                    edge(.left, in: rect, frame: frame)
                    edge(.right, in: rect, frame: frame)

                    corner(.topLeft, at: CGPoint(x: rect.minX, y: rect.minY), frame: frame)
                    corner(.topRight, at: CGPoint(x: rect.maxX, y: rect.minY), frame: frame)
                    corner(.bottomLeft, at: CGPoint(x: rect.minX, y: rect.maxY), frame: frame)
                    corner(.bottomRight, at: CGPoint(x: rect.maxX, y: rect.maxY), frame: frame)
                }
            }
            // The stable frame the move and resize drags are measured in — see
            // `dragSpace` for the glitch this is the fix for.
            .coordinateSpace(name: CropOverlayView.dragSpace)
            // ONE hover reader for the whole overlay — see this type's header for why ten
            // of them could not have agreed with each other.
            //
            // The animations that follow a hover live on the individual pieces rather than
            // here, deliberately: an `.animation(value: hover)` on this stack would put
            // every change in the same transaction under an easing curve, and the change
            // that matters most in this view is the rectangle following a drag.
            .onContinuousHover(coordinateSpace: .local) { phase in
                // Frozen while a hand is down: the rectangle moves under the pointer
                // during a drag, and re-resolving the region per event would swap the
                // cursor mid-gesture to whatever the handle happened to slide past.
                guard dragOrigin == nil, rotation == nil else { return }
                if case .active(let point) = phase {
                    enter(region(at: point, rect: rect))
                } else {
                    leave()
                }
            }
        }
        // The tool can be put away with `R` — or by leaving the workspace — while the
        // pointer is still inside the rectangle, and a cursor pushed by a view that has
        // gone is a cursor nothing will ever pop.
        .onDisappear { leave() }
    }

    // MARK: Geometry

    /// Where the whole USABLE frame lands in this view's points.
    ///
    /// A point of the usable frame, stated as a fraction of it, is by definition a
    /// displayed point of the same geometry with no crop — so `sourceNormalized` against
    /// THAT geometry is the way out of the crop's coordinate system, and
    /// `displayedNormalized` against the geometry the loupe actually drew is the way into
    /// the view's. Both rectangles are axis-aligned in the same rotated space, so the
    /// composition is a scale and a translation and two corners pin it exactly.
    ///
    /// While the tool is armed the loupe SIZES THIS OVERLAY to the usable frame itself
    /// (`LoupeView.cropCanvas` — the full flip-only plate turns underneath in the view
    /// layer), so with `viewShowsCrop` false this mapping is the identity and the
    /// answer is the whole bounds. It is kept as the general mapping rather than
    /// shortcut to `bounds`, for the reason the header gives: the day the loupe draws
    /// something else, the rectangle must move with it rather than stay plausibly wrong.
    private func frameRect(in size: CGSize) -> CGRect {
        let whole = CGRect(origin: .zero, size: size)
        guard size.width > 0, size.height > 0,
              sourceSize.width > 0, sourceSize.height > 0 else { return whole }
        var uncropped = geometry
        uncropped.crop = Crop()
        let drawn = viewShowsCrop ? geometry : uncropped

        func point(_ u: Double, _ v: Double) -> CGPoint {
            let source = PipelineRenderer.sourceNormalized(displayedX: u, displayedY: v,
                                                           geometry: uncropped,
                                                           sourceSize: sourceSize)
            let displayed = PipelineRenderer.displayedNormalized(sourceX: Double(source.x),
                                                                 sourceY: Double(source.y),
                                                                 geometry: drawn,
                                                                 sourceSize: sourceSize)
            return CGPoint(x: displayed.x * size.width, y: displayed.y * size.height)
        }

        let topLeft = point(0, 0)
        let bottomRight = point(1, 1)
        let rect = CGRect(x: Swift.min(topLeft.x, bottomRight.x),
                          y: Swift.min(topLeft.y, bottomRight.y),
                          width: abs(bottomRight.x - topLeft.x),
                          height: abs(bottomRight.y - topLeft.y))
        return rect.width > 0.5 && rect.height > 0.5 ? rect : whole
    }

    private func pixelRect(in frame: CGRect) -> CGRect {
        // `CropGeometry.normalized` is the same guard the renderer runs, so the rectangle
        // drawn here and the rectangle rendered cannot disagree about a crop that arrived
        // from a sidecar with a NaN in it.
        let c = CropGeometry.normalized(crop)
        return CGRect(x: frame.minX + CGFloat(c.x) * frame.width,
                      y: frame.minY + CGFloat(c.y) * frame.height,
                      width: CGFloat(c.w) * frame.width,
                      height: CGFloat(c.h) * frame.height)
    }

    /// How far the picture underneath overhangs this overlay's own bounds, per axis.
    ///
    /// While the tool is armed the loupe draws the FULL frame — flip applied, angle
    /// left off — turned by the display tilt in the view layer, and sizes this overlay
    /// to the usable (inscribed) frame. The two share a centre, so the overhang is half
    /// the difference between the rotated plate's bounding box and these bounds: how
    /// far the dim shield and the rotate catcher have to reach past them to cover the
    /// picture's tilted corners. Zero at angle 0, where the plate IS the usable frame.
    private func plateOverhang(in size: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0,
              size.width > 0, size.height > 0 else { return .zero }
        let usable = CropGeometry.usableSize(width: Double(sourceSize.width),
                                             height: Double(sourceSize.height),
                                             degrees: geometry.angle)
        guard usable.width > 0, usable.height > 0 else { return .zero }
        let k = Double(size.width) / usable.width
        let plateW = Double(sourceSize.width) * k
        let plateH = Double(sourceSize.height) * k
        let radians = geometry.angle * .pi / 180
        let boxW = plateW * abs(cos(radians)) + plateH * abs(sin(radians))
        let boxH = plateW * abs(sin(radians)) + plateH * abs(cos(radians))
        return CGSize(width: CGFloat(Swift.max(0, (boxW - Double(size.width)) / 2)),
                      height: CGFloat(Swift.max(0, (boxH - Double(size.height)) / 2)))
    }

    // MARK: Guides

    /// The rectangle's own outline as a path, so it can be stroked twice.
    ///
    /// A path rather than `Rectangle().strokeBorder`, which is what this was: `strokeBorder`
    /// insets by half its line width, so a 3 pt companion and a 1 pt line drawn that way
    /// sit at different radii and the dark one ends up entirely INSIDE the crop, eating a
    /// point and a half of the picture you are framing. Centred strokes on one shared path
    /// are the only version where the two stay concentric at every weight.
    private func boundary(of rect: CGRect) -> Path {
        Path { $0.addRect(rect) }
    }

    /// The chosen overlay, drawn inside the rectangle — and the grid regardless while a
    /// rotation is in flight, because a picture turning under a frame with nothing
    /// straight in it is a rotation you cannot judge.
    private func guides(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        // A rotation with nothing straight on screen is a rotation you cannot judge,
        // so the grid stands in while the picture is turning.
        let style = (rotation != nil && tool.overlay == .off) ? CropOverlayStyle.grid
                                                              : tool.overlay

        if let divisions = style.divisions {
            for fraction in divisions {
                let x = rect.minX + rect.width * CGFloat(fraction)
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * CGFloat(fraction)
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        if style == .diagonals {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        return path
    }

    /// Where the picture's OWN horizontal is now pointing, through the middle of the
    /// rectangle.
    ///
    /// `Straighten.displayedDirection` is the forward half of the ruler's mapping and had
    /// no caller outside its tests. It is exactly the question a rotation raises — the
    /// crop box is square to the screen, so the only way to see how far the frame has
    /// turned is to draw something that turned with it.
    private func horizon(in rect: CGRect) -> Path {
        var path = Path()
        let tilt = Straighten.displayedDirection(sourceDegrees: 0, angle: geometry.angle,
                                                 flipped: geometry.flipH) * .pi / 180
        let half = CGFloat((rect.width * rect.width + rect.height * rect.height)
            .squareRoot()) / 2
        let dx = half * CGFloat(cos(tilt))
        let dy = half * CGFloat(sin(tilt))
        path.move(to: CGPoint(x: rect.midX - dx, y: rect.midY - dy))
        path.addLine(to: CGPoint(x: rect.midX + dx, y: rect.midY + dy))
        return path
    }

    /// The rotate cue: a short arc swinging past the bottom-right corner, out in the
    /// dimmed area, with an arrowhead at each end.
    ///
    /// AN ARC RATHER THAN A LABEL because the gesture is a sweep and an arc is a picture
    /// of a sweep — and because a word on a photograph is a word the eye has to stop and
    /// read. It is struck concentric with the rectangle's own centre, which is the pivot
    /// `rotateGesture` actually turns about, so the cue is a diagram of the mechanism
    /// rather than a decoration that happens to sit nearby.
    ///
    /// Past a CORNER rather than past an edge: a corner is the farthest point from the
    /// pivot, so it is where the same wrist movement buys the most angle, and it is the
    /// part of the dimmed area least likely to be under the pointer for some other reason.
    ///
    /// FADED IN RATHER THAN INSERTED. It stays in the hierarchy at zero opacity, which is
    /// what lets the crossfade be a plain `.animation(value:)` rather than a transition
    /// needing a `withAnimation` at whatever set `hover`. The cost of keeping it there is
    /// one six-segment path per body pass, which is less than the `if` would have saved.
    private func rotateCueLayer(in rect: CGRect) -> some View {
        // Withdrawn once the drag is under way: the horizon and the angle readout answer
        // "what is this doing" better than a diagram of what it was going to do.
        let visible = hover == CropRegion.outside && rotation == nil
        return Group {
            rotateCue(in: rect).stroke(Color.black.opacity(0.5), lineWidth: 3.5)
            rotateCue(in: rect).stroke(Lumen.primaryText.opacity(0.9), lineWidth: 1.5)
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
        .animation(Lumen.motionState, value: visible)
    }

    /// The arc itself, in this view's points — see `rotateCueLayer(in:)` above for what
    /// it is for and why it is drawn where it is.
    private func rotateCue(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 1, rect.height > 1 else { return path }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = CGFloat((rect.width * rect.width + rect.height * rect.height)
            .squareRoot()) / 2 + 15
        // The direction of the bottom-right corner, in this view's y-down space.
        let middle = atan2(Double(rect.height), Double(rect.width))
        let span = 16.0 * Double.pi / 180
        path.addArc(center: centre, radius: radius,
                    startAngle: Angle(radians: middle - span),
                    endAngle: Angle(radians: middle + span),
                    clockwise: false)
        for end in [middle - span, middle + span] {
            let tip = CGPoint(x: centre.x + radius * CGFloat(cos(end)),
                              y: centre.y + radius * CGFloat(sin(end)))
            // The tangent at this end, pointing away from the middle of the arc — which
            // is the direction the arrowhead has to open in for the pair to read as "this
            // turns both ways" rather than as two arrows chasing each other.
            let away = end + (end < middle ? -Double.pi / 2 : Double.pi / 2)
            for spread in [2.5, -2.5] {
                path.move(to: tip)
                path.addLine(to: CGPoint(x: tip.x + 7 * CGFloat(cos(away + spread)),
                                         y: tip.y + 7 * CGFloat(sin(away + spread))))
            }
        }
        return path
    }

    /// The angle, beside the cursor, while the drag is happening — docs/09's "the angle
    /// readout ghosts next to the cursor", and the same rule the ruler's own readout
    /// follows: the tool sets a visible number rather than hiding behind one.
    private func readout(_ drag: RotationDrag) -> some View {
        Text(String(format: "%+.1f°", drag.degrees))
            .font(.lumenNumeric)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(.white)
            .lumenHUD(radius: Lumen.radiusChip)
            .position(x: drag.location.x + 34, y: drag.location.y - 18)
            .allowsHitTesting(false)
    }

    // MARK: Handles

    /// A corner: an L-shaped bracket overhanging the corner it names, over an invisible
    /// square you can actually hit.
    ///
    /// THE BRACKET IS NOT THE TARGET, which is why it can be as big as it needs to be.
    /// The drawn shape spans `cornerBox` so its legs are never clipped by their own
    /// frame; the thing that takes the press is the `cornerTarget` square in the middle,
    /// and it is the only hit-testable child — the strokes are switched out of hit
    /// testing so a press on the far tip of a leg falls through to the edge strip or the
    /// interior underneath, exactly as it did when the tip was not drawn at all.
    ///
    /// Hover BRIGHTENS AND THICKENS rather than growing. `LumenHover` argues for a
    /// surface change over a scale because a control that grows moves the thing you were
    /// aiming at — and there is no surface on a photograph, so weight and value are the
    /// two channels left. The leg length is held fixed for the same reason the argument
    /// was made: the corner of the bracket must not move out from under the pointer.
    private func corner(_ handle: CropGeometry.Handle, at point: CGPoint,
                        frame: CGRect) -> some View {
        let hot = hover == CropRegion.handle(handle)
        let weight = CropOverlayView.markWeight + (hot ? 1 : 0)
        let bracket = CropCornerBracket(handle: handle,
                                        leg: CropOverlayView.bracketLeg,
                                        offset: weight / 2)
        return ZStack {
            Group {
                bracket.stroke(Color.black.opacity(0.55),
                               style: StrokeStyle(lineWidth: weight + 2, lineJoin: .miter))
                bracket.stroke(hot ? Color.white : Lumen.primaryText,
                               style: StrokeStyle(lineWidth: weight, lineJoin: .miter))
            }
            .allowsHitTesting(false)
            .animation(Lumen.motionState, value: hot)

            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: CropOverlayView.cornerTarget,
                       height: CropOverlayView.cornerTarget)
                .gesture(resizeGesture(handle, in: frame))
                .help("Drag to reframe from this corner.")
        }
        .frame(width: CropOverlayView.cornerBox, height: CropOverlayView.cornerBox)
        .position(point)
    }

    /// An edge handle: a thin grab strip along the whole side, drawn as a short thick bar
    /// at its midpoint so the target is discoverable without covering the picture.
    ///
    /// The overlay offered corners only, so the adjustment every crop ends with — "a
    /// little off the top" — meant dragging a corner and then fixing the width it had
    /// also changed.
    ///
    /// THE BAR WAS 2 pt, which on a Retina panel is four device pixels of `primaryText`
    /// with nothing behind it: at rest, against anything brighter than mid-grey, it was
    /// not there. It is 3 pt now with the same near-black companion the rectangle and the
    /// brackets carry, and a capsule rather than a 1 pt-radius rounded rectangle because
    /// at this weight the difference between the two is the difference between a bar and
    /// a scratch.
    private func edge(_ handle: CropGeometry.Handle, in rect: CGRect,
                      frame: CGRect) -> some View {
        let horizontal = handle == .top || handle == .bottom
        let length = horizontal ? rect.width : rect.height
        let bar = Swift.max(Swift.min(length * 0.28, 44), 10)
        let hot = hover == CropRegion.handle(handle)
        let weight = CropOverlayView.markWeight + (hot ? 1 : 0)
        let centre: CGPoint
        switch handle {
        case .top: centre = CGPoint(x: rect.midX, y: rect.minY)
        case .bottom: centre = CGPoint(x: rect.midX, y: rect.maxY)
        case .left: centre = CGPoint(x: rect.minX, y: rect.midY)
        default: centre = CGPoint(x: rect.maxX, y: rect.midY)
        }
        return ZStack {
            Group {
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: horizontal ? bar + 2 : weight + 2,
                           height: horizontal ? weight + 2 : bar + 2)
                Capsule()
                    .fill(hot ? Color.white : Lumen.primaryText)
                    .frame(width: horizontal ? bar : weight,
                           height: horizontal ? weight : bar)
            }
            .allowsHitTesting(false)
            .animation(Lumen.motionState, value: hot)

            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: horizontal ? length : CropOverlayView.edgeThickness,
                       height: horizontal ? CropOverlayView.edgeThickness : length)
                .gesture(resizeGesture(handle, in: frame))
                .help("Drag to move this edge on its own.")
        }
        .position(centre)
    }

    // MARK: The pointer

    /// Which region of the overlay a point is in.
    ///
    /// THE PRECEDENCE IS THE Z-ORDER'S, deliberately and by hand: corners, then edges,
    /// then the interior, then the picture outside. The targets in `body` are stacked in
    /// that same order — later is on top — so this function and the hit test agree about
    /// every square point of the overlay. They are two statements of one rule, and the
    /// day they disagree the cursor starts promising a handle the press cannot reach,
    /// which is worse than no cursor at all.
    private func region(at point: CGPoint, rect: CGRect) -> CropRegion {
        let half = CropOverlayView.cornerTarget / 2
        let corners: [(CropGeometry.Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
        for (handle, centre) in corners {
            if abs(point.x - centre.x) <= half && abs(point.y - centre.y) <= half {
                return .handle(handle)
            }
        }
        // The strips run the full length of their side and straddle it, which is what
        // `edge(_:in:frame:)` builds.
        let reach = CropOverlayView.edgeThickness / 2
        if point.x >= rect.minX && point.x <= rect.maxX {
            if abs(point.y - rect.minY) <= reach { return .handle(.top) }
            if abs(point.y - rect.maxY) <= reach { return .handle(.bottom) }
        }
        if point.y >= rect.minY && point.y <= rect.maxY {
            if abs(point.x - rect.minX) <= reach { return .handle(.left) }
            if abs(point.x - rect.maxX) <= reach { return .handle(.right) }
        }
        return rect.contains(point) ? .inside : .outside
    }

    /// The cursor a region is entitled to.
    ///
    /// NO DIAGONAL RESIZE CURSOR EXISTS IN PUBLIC APPKIT. The four that everybody wants
    /// here — `_windowResizeNorthWestSouthEastCursor` and its siblings — are private
    /// selectors, and an app that ships them is an app whose corners lose their cursor in
    /// whichever macOS release renames them. `.crosshair` is the honest substitute: it
    /// says "this point, precisely", which is exactly what a corner drag sets.
    private func cursor(for region: CropRegion) -> NSCursor {
        switch region {
        case .outside: return .crosshair
        case .inside: return .openHand
        case .handle(let handle):
            switch handle {
            case .top, .bottom: return .resizeUpDown
            case .left, .right: return .resizeLeftRight
            default: return .crosshair
            }
        }
    }

    /// Take up a region, pushing its cursor and dropping whichever one we pushed before.
    ///
    /// At most one push is ever outstanding, which is what keeps this balanced against
    /// whatever the window had underneath — the push/pop discipline `LumenHover` sets out,
    /// with the added rule that a region change is a pop AND a push rather than a second
    /// push on top of the first.
    private func enter(_ next: CropRegion) {
        guard hover != next else { return }
        hover = next
        if pushedCursor { NSCursor.pop() }
        cursor(for: next).push()
        pushedCursor = true
    }

    /// The pointer left, or the tool did.
    private func leave() {
        hover = nil
        guard pushedCursor else { return }
        pushedCursor = false
        NSCursor.pop()
    }

    // MARK: Gestures

    /// Measured in the overlay's named space, NOT the default `.local` — the interior
    /// host moves with the crop it is dragging, and `dragSpace`'s comment is the story
    /// of what a coordinate space that moves mid-gesture does to a translation.
    private func moveGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1,
                    coordinateSpace: .named(CropOverlayView.dragSpace))
            .onChanged { value in
                guard frame.width > 0, frame.height > 0 else { return }
                sliderGestureChanged(true)
                let origin = dragOrigin ?? crop
                if dragOrigin == nil { dragOrigin = origin }
                crop = CropGeometry.move(origin,
                                         dx: Double(value.translation.width / frame.width),
                                         dy: Double(value.translation.height / frame.height))
            }
            .onEnded { _ in
                dragOrigin = nil
                sliderGestureChanged(false)
            }
    }

    /// Every resize goes through `CropGeometry.resize`, which is in LumenCore and tested.
    ///
    /// The arithmetic used to live here, and it ignored the aspect entirely: picking 3:2
    /// from the menu and then dragging a corner silently made the crop free-form, after
    /// which the menu read the rectangle back and reported "Custom". A view cannot be
    /// tested from a machine with no renderer, which is why it moved rather than being
    /// patched in place.
    ///
    /// Measured in the overlay's named space, and this one is the drag that was
    /// glitching: its host views are `.position`ed off the live rect, so the default
    /// `.local` space moved under the pointer on every event — see `dragSpace`.
    private func resizeGesture(_ handle: CropGeometry.Handle,
                               in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1,
                    coordinateSpace: .named(CropOverlayView.dragSpace))
            .onChanged { value in
                guard frame.width > 0, frame.height > 0 else { return }
                sliderGestureChanged(true)
                let origin = dragOrigin ?? crop
                if dragOrigin == nil { dragOrigin = origin }
                crop = CropGeometry.resize(
                    origin, handle: handle,
                    dx: Double(value.translation.width / frame.width),
                    dy: Double(value.translation.height / frame.height),
                    lockedAspect: tool.lockedAspect(for: photoID), frameAspect: frameAspect)
            }
            .onEnded { _ in
                dragOrigin = nil
                sliderGestureChanged(false)
            }
    }

    /// Drag anywhere outside the rectangle and the picture turns under it.
    ///
    /// MEASURED IN GLOBAL POINTS, which is the one thing that is not obvious. Writing the
    /// angle per event re-renders the loupe, and the usable frame's shape changes with the
    /// angle, so this very view is resizing while the hand is down — a drag measured in
    /// its own coordinate space would compare a fresh location against a start location
    /// the resize had already invalidated, and the picture would creep. The window does
    /// not move, so global points hold still. The pivot is taken once, for the same
    /// reason.
    private func rotateGesture(in size: CGSize, windowOrigin: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let frame = frameRect(in: size)
                guard frame.width > 0, frame.height > 0 else { return }
                let drag: RotationDrag
                if let started = rotation {
                    drag = started
                } else {
                    let rect = pixelRect(in: frame)
                    let local = CGPoint(x: value.startLocation.x - windowOrigin.x,
                                        y: value.startLocation.y - windowOrigin.y)
                    guard startsOnThePicture(local, frame: frame) else { return }
                    drag = RotationDrag(
                        pivot: CGPoint(x: windowOrigin.x + rect.midX,
                                       y: windowOrigin.y + rect.midY),
                        degrees: geometry.angle,
                        location: local)
                    rotation = drag
                }
                guard let sweep = CropGeometry.rotationSweep(
                    centreX: Double(drag.pivot.x), centreY: Double(drag.pivot.y),
                    fromX: Double(value.startLocation.x), fromY: Double(value.startLocation.y),
                    toX: Double(value.location.x), toY: Double(value.location.y))
                else { return }
                // ⇧ gears the turn down, read at event time the way `LumenSlider` reads
                // its fine drag. Applied to the sweep's INCREMENT since the last event
                // and integrated, so the modifier can come and go mid-drag without the
                // picture jumping; at gear 1 the integration is exactly the absolute
                // sweep it replaced.
                let gear = NSEvent.modifierFlags.contains(.shift)
                    ? CropOverlayView.fineRotationGear : 1
                let next = CropGeometry.rotationAngle(from: drag.degrees,
                                                      sweep: (sweep - drag.sweep) * gear,
                                                      flipped: geometry.flipH)
                rotation?.sweep = sweep
                rotation?.degrees = next
                rotation?.location = CGPoint(x: value.location.x - windowOrigin.x,
                                             y: value.location.y - windowOrigin.y)
                sliderGestureChanged(true)
                onAngle(next)
            }
            .onEnded { _ in
                rotation = nil
                sliderGestureChanged(false)
            }
    }

    /// Whether a press landed on the photograph rather than beside it.
    ///
    /// `CropGeometry.containsInSource` is what "inside the picture" MEANS, and it is not
    /// the same question as "inside this view". The two coincide while the loupe is
    /// showing the whole inscribed frame, which is every use of this tool today; they
    /// part company the moment the drawn frame is the crop instead, where the usable
    /// frame runs off the edges of the view and a press near one is a press on nothing.
    private func startsOnThePicture(_ point: CGPoint, frame: CGRect) -> Bool {
        guard sourceSize.width > 0, sourceSize.height > 0,
              frame.width > 0, frame.height > 0 else { return true }
        let usable = CropGeometry.usableSize(width: Double(sourceSize.width),
                                             height: Double(sourceSize.height),
                                             degrees: geometry.angle)
        let u = Double((point.x - frame.minX) / frame.width)
        let v = Double((point.y - frame.minY) / frame.height)
        return CropGeometry.containsInSource(x: u * usable.width, y: v * usable.height,
                                             sourceWidth: Double(sourceSize.width),
                                             sourceHeight: Double(sourceSize.height),
                                             degrees: geometry.angle)
    }
}

// MARK: - Straighten ruler

/// Drag a line along a horizon or a doorframe; the frame levels to whichever axis that
/// line is closer to (docs/09 §Straighten / Level).
///
/// One of three ways to the same field, and the only one that takes its answer from the
/// picture: the Angle slider is a number with nothing to measure against, and the rotate
/// drag in `CropOverlayView` is a hand rather than a reference. All three write
/// `geometry.angle` through the same coalescing key, so whichever you reach for is one
/// undo step and not a new grammar.
///
/// The arithmetic is `Straighten` in `LumenCore`, not here, because the sign depends on
/// two things a view cannot check: the frame on screen has ALREADY been rotated by the
/// angle in the recipe, and a horizontal flip inverts the correction. Both are wrong in
/// a way that looks almost right — the first drag improves the picture and the second
/// makes it worse — so the mapping lives where a test can reach it.
struct StraightenOverlayView: View {

    /// The angle currently in the recipe: the drag is measured on the frame this has
    /// already been applied to, so it is part of the answer and not just context.
    let currentAngle: Double
    let isFlipped: Bool
    /// Called with the new angle once the drag ends. Nil means the drag was too short to
    /// carry one, and the right answer to that is to change nothing.
    let onAngle: (Double) -> Void
    /// Called when the gesture is over, armed or not, so the tool can put itself away.
    let onFinish: () -> Void

    @State private var start: CGPoint?
    @State private var end: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Rectangle()
                    // Not `.clear`: a fully transparent shape is not hit-testable and the
                    // drag would fall through to the crop rectangle underneath.
                    .fill(Lumen.accent.opacity(0.001))
                    .contentShape(Rectangle())
                    .gesture(drag(in: size))

                if let start, let end {
                    Path { path in
                        path.move(to: start)
                        path.addLine(to: end)
                    }
                    .stroke(Lumen.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .allowsHitTesting(false)

                    Text(readout(from: start, to: end, in: size))
                        .font(.lumenNumeric)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .foregroundStyle(.white)
                        .lumenHUD(radius: Lumen.radiusChip)
                        .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 16)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if start == nil { start = value.startLocation }
                end = value.location
            }
            .onEnded { value in
                defer {
                    start = nil
                    end = nil
                    onFinish()
                }
                if let next = resolvedAngle(from: value.startLocation,
                                            to: value.location, in: size) {
                    onAngle(next)
                }
            }
    }

    private func resolvedAngle(from a: CGPoint, to b: CGPoint,
                               in size: CGSize) -> Double? {
        Straighten.angle(current: currentAngle,
                         dx: Double(b.x - a.x), dy: Double(b.y - a.y),
                         flipped: isFlipped,
                         frameLongEdge: Double(Swift.max(size.width, size.height)))
    }

    /// What the drag would set, shown while it is happening — the ruler sets a visible
    /// number rather than hiding behind one (docs/09: "auto sets sliders, never hides
    /// behind them").
    ///
    /// Through the same call the commit uses, minimum-drag rule included, so the readout
    /// cannot promise an angle the release will decline to write.
    private func readout(from a: CGPoint, to b: CGPoint, in size: CGSize) -> String {
        guard let next = resolvedAngle(from: a, to: b, in: size) else { return "—" }
        return String(format: "%+.1f°", next)
    }
}

/// The eyedropper's catcher: a transparent sheet over the drawn image that turns one
/// click into a SOURCE-normalized point.
///
/// It exists only while a pick is actually in flight, which is the whole reason it can
/// be a full-bleed hit target — the rest of the time there is nothing here to eat a pan
/// or a click-to-zoom.
///
/// The conversion is the same inverse `MaskCanvas` uses, and for the same reason: the
/// picture on screen has already been cropped and straightened by the renderer, so a
/// point in view coordinates is not a point in the source frame. Sampling the displayed
/// position directly would read the wrong pixel on every cropped or rotated photo, and
/// read it plausibly enough that nobody would notice.
struct NeutralPickerOverlay: View {

    let sourceSize: CGSize
    let geometry: Geometry
    let onPick: (Double, Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                // Not `.clear`: a fully transparent shape is not hit-testable, and the
                // click would fall through to the pan gesture underneath.
                .fill(Lumen.accent.opacity(0.001))
                .overlay(
                    Rectangle()
                        .strokeBorder(Lumen.accent.opacity(0.7), lineWidth: 2)
                        .allowsHitTesting(false)
                )
                .contentShape(Rectangle())
                // The pointer is the instrument while a pick is armed, and the cursor
                // is how the picture says so (docs/32 Stream D item 3's "cursor
                // feedback while armed"). `lumenPickCursor` pops on disappear, which
                // matters here specifically: this overlay unmounts the moment the
                // pick resolves, with the pointer still inside it.
                .lumenPickCursor()
                .gesture(
                    // minimumDistance 0 so a plain click registers; `onEnded` rather
                    // than `onChanged` so a press that turns into a drag still resolves
                    // to one sample at the point it was released.
                    DragGesture(minimumDistance: 0).onEnded { value in
                        let size = proxy.size
                        guard size.width > 0, size.height > 0 else { return }
                        let u = Double(value.location.x / size.width)
                        let v = Double(value.location.y / size.height)
                        let source = PipelineRenderer.sourceNormalized(
                            displayedX: u, displayedY: v,
                            geometry: geometry, sourceSize: sourceSize)
                        onPick(Double(source.x), Double(source.y))
                    }
                )
        }
    }
}

#endif

// ViewerOverlays.swift
// The things the loupe draws on top of the photograph: before/after (flip, split with a
// draggable divider, and the two-pane side-by-side / top-bottom), the clipping-threshold
// overlay, the mask tint, the crop rectangle with its rule-of-thirds guides, and the
// on-image colour readout HUD.
//
// Each one is a small `View` the loupe composes at the drawn image's exact size, so a
// zoomed, panned canvas carries its overlays with it for free rather than each overlay
// re-deriving the viewport's arithmetic.
//
// Two rules the whole file obeys:
//   · Chrome is zero-chroma (docs/00 Law 7): dividers, handles, guides and HUD ground
//     come from the `Lumen` theme and nothing here introduces a new hue. The colours
//     that *are* chromatic — the clipping overlay's channel diagnosis and the readout
//     swatch — are measurements of the picture, not decoration, and they come straight
//     from `LumenCore.ClippingOverlay` and the sampled pixel respectively.
//   · An overlay reports what is on screen. The clipping overlay and the readout both
//     bin the displayed 8-bit proxy, and the HUD names the readout space it is in
//     (docs/04 D12: an unlabeled readout is the failure mode `ReadoutSpace` ends).

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import LumenCore
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
                .padding(8)
                .allowsHitTesting(false)
            }
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Lumen.controlBackground.opacity(0.95))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Lumen.separator))
            .frame(width: 12, height: 34)
            .overlay(
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Lumen.primaryText)
            )
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
                RoundedRectangle(cornerRadius: 2)
                    .fill(swatchColor)
                    .frame(width: 11, height: 11)
                    .overlay(RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Lumen.separator, lineWidth: 0.5))
                Text(numbers)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Lumen.primaryText)
            }
            Text(sample.space.label)
                .font(.system(size: 9))
                .foregroundStyle(Lumen.secondaryText)
            if let caption = sample.caption {
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(Lumen.secondaryText)
            }
            Text("\(sample.x), \(sample.y) px")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Lumen.secondaryText)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: 190, alignment: .leading)
        .background(Color.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Lumen.separator, lineWidth: 0.5))
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

// MARK: - Mask overlay

/// The solo-mask tint. When a rasterized alpha plane is available it tints exactly the
/// masked pixels; until the mask rasterizer is wired to the viewer it tints the frame
/// evenly and the loupe's badge names which mask is soloed, rather than implying a
/// coverage we have not computed.
struct MaskOverlayView: View {

    var raster: CGImage?
    var tint: Color = Lumen.accent
    var opacity: Double = 0.45

    var body: some View {
        Group {
            if let raster {
                tint.opacity(clampedOpacity)
                    .mask {
                        Image(decorative: raster, scale: 1, orientation: .up)
                            .resizable()
                            .interpolation(.high)
                    }
            } else {
                tint.opacity(clampedOpacity * 0.3)
            }
        }
        .allowsHitTesting(false)
    }

    private var clampedOpacity: Double {
        guard opacity.isFinite else { return 0.45 }
        return Swift.min(Swift.max(opacity, 0), 1)
    }
}

// MARK: - Crop overlay

/// The crop rectangle over the drawn image, with the rule-of-thirds guides inside it and
/// the area outside dimmed. The rect is `Recipe.Geometry.Crop`, normalized to the source
/// frame, so dragging it here writes the same value the crop panel does — one path into
/// the recipe, one undo grammar.
struct CropOverlayView: View {

    @Binding var crop: Crop
    var showsThirds: Bool = true
    var isInteractive: Bool = true

    /// Smallest crop a drag may produce, as a fraction of the frame.
    private static let minimumSize: Double = 0.05
    private static let handleSize: CGFloat = 14

    @State private var dragOrigin: Crop?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let rect = pixelRect(in: size)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle()
                    .strokeBorder(Lumen.primaryText.opacity(0.9), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)

                if showsThirds {
                    thirds(in: rect)
                        .stroke(Lumen.primaryText.opacity(0.35), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }

                if isInteractive {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .gesture(moveGesture(in: size))

                    corner(at: CGPoint(x: rect.minX, y: rect.minY), size: size, dx: -1, dy: -1)
                    corner(at: CGPoint(x: rect.maxX, y: rect.minY), size: size, dx: 1, dy: -1)
                    corner(at: CGPoint(x: rect.minX, y: rect.maxY), size: size, dx: -1, dy: 1)
                    corner(at: CGPoint(x: rect.maxX, y: rect.maxY), size: size, dx: 1, dy: 1)
                }
            }
        }
    }

    // MARK: Geometry

    private func pixelRect(in size: CGSize) -> CGRect {
        let x = clamp01(crop.x)
        let y = clamp01(crop.y)
        let w = Swift.min(Swift.max(crop.w.isFinite ? crop.w : 1, CropOverlayView.minimumSize), 1 - x)
        let h = Swift.min(Swift.max(crop.h.isFinite ? crop.h : 1, CropOverlayView.minimumSize), 1 - y)
        return CGRect(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height,
                      width: CGFloat(w) * size.width, height: CGFloat(h) * size.height)
    }

    private func thirds(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        for i in 1...2 {
            let fraction = CGFloat(i) / 3
            let x = rect.minX + rect.width * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }

    private func corner(at point: CGPoint, size: CGSize, dx: Int, dy: Int) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Lumen.primaryText)
            .frame(width: CropOverlayView.handleSize / 2, height: CropOverlayView.handleSize / 2)
            .frame(width: CropOverlayView.handleSize, height: CropOverlayView.handleSize)
            .contentShape(Rectangle())
            .position(point)
            .gesture(resizeGesture(in: size, dx: dx, dy: dy))
    }

    // MARK: Gestures

    private func moveGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                let origin = dragOrigin ?? crop
                if dragOrigin == nil { dragOrigin = origin }
                let dx = Double(value.translation.width / size.width)
                let dy = Double(value.translation.height / size.height)
                var next = origin
                next.x = Swift.min(Swift.max(origin.x + dx, 0), Swift.max(1 - origin.w, 0))
                next.y = Swift.min(Swift.max(origin.y + dy, 0), Swift.max(1 - origin.h, 0))
                crop = next
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func resizeGesture(in size: CGSize, dx: Int, dy: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                let origin = dragOrigin ?? crop
                if dragOrigin == nil { dragOrigin = origin }
                let mx = Double(value.translation.width / size.width)
                let my = Double(value.translation.height / size.height)

                var left = origin.x
                var top = origin.y
                var right = origin.x + origin.w
                var bottom = origin.y + origin.h
                if dx < 0 { left = origin.x + mx } else { right = origin.x + origin.w + mx }
                if dy < 0 { top = origin.y + my } else { bottom = origin.y + origin.h + my }

                left = clamp01(left)
                top = clamp01(top)
                right = clamp01(right)
                bottom = clamp01(bottom)
                let minimum = CropOverlayView.minimumSize
                if right - left < minimum {
                    if dx < 0 { left = Swift.max(right - minimum, 0) }
                    else { right = Swift.min(left + minimum, 1) }
                }
                if bottom - top < minimum {
                    if dy < 0 { top = Swift.max(bottom - minimum, 0) }
                    else { bottom = Swift.min(top + minimum, 1) }
                }

                var next = origin
                next.x = left
                next.y = top
                next.w = Swift.max(right - left, minimum)
                next.h = Swift.max(bottom - top, minimum)
                crop = next
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return Swift.min(Swift.max(v, 0), 1)
    }
}

#endif

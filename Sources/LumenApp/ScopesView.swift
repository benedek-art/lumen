// ScopesView.swift
// The three scopes (D22, docs/14 §5.9): luma waveform, RGB parade, and the OKLab
// vectorscope with its skin-tone graticule. One picker chooses which is on screen,
// because three scopes at once is a wall of green nobody reads.
//
// Three rules this file exists to enforce:
//   · The view measures nothing. It draws the `Waveform` / `Parade` / `Vectorscope`
//     values it is handed; nil means "not computed yet" and draws a labelled empty
//     frame rather than a crash or, worse, a plausible-looking zero.
//   · A trace is a bitmap, not ten thousand rectangles. Each scope is rasterized once
//     into a `CGImage` the size of its own bin grid and scaled by the compositor, so
//     the per-frame cost is proportional to the number of bins and independent of how
//     large the panel is.
//   · The scopes' own conventions are obeyed exactly as `Scopes.swift` states them:
//     waveform column 0 is image left and bin 0 is black (so the row index is flipped
//     for drawing); the vectorscope's `counts` is row-major with row 0 at +b, which is
//     already the orientation a bitmap wants.
//
// The trace is drawn achromatic — the vectorscope says where a colour is by *position*,
// and tinting the plot itself would put chroma in the chrome (Law 7). The one coloured
// marks are the parade's channel tints, which name which panel you are looking at, and
// the skin line, which is the instrument's whole point.

#if os(macOS)

import CoreGraphics
import Foundation
import LumenCore
import SwiftUI

struct ScopesView: View {

    // The whole feed, images included. This view used to rasterize 65k–197k pixels
    // inside `body` — waveform 256×256, parade three times that, vectorscope 192×192,
    // fresh byte arrays and CGImages every evaluation — and `DevelopPanel` re-bodies
    // on every publish, which during a drag is every mouse event. The rasters now ride
    // `ScopeData`, built once per measurement on the same detached task that binned
    // the pixels; this view just draws them.
    private let scopes: ScopeData?

    private var waveform: Waveform? { scopes?.waveform }
    private var parade: Parade? { scopes?.parade }
    private var vectorscope: Vectorscope? { scopes?.vectorscope }

    init(scopes: ScopeData?) {
        self.scopes = scopes
    }

    enum ScopeKind: String, CaseIterable, Hashable {
        case waveform
        case parade
        case vectorscope

        var label: String {
            switch self {
            case .waveform: return "Waveform"
            case .parade: return "Parade"
            case .vectorscope: return "Vector"
            }
        }
    }

    @State private var kind: ScopeKind = .waveform

    private static let panelHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LumenSegmented(options: kindOptions, selection: $kind)
            content
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Lumen.panelBackground)
        .foregroundStyle(Lumen.primaryText)
    }

    private var kindOptions: [(value: ScopeKind, label: String)] {
        ScopeKind.allCases.map { (value: $0, label: $0.label) }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .waveform: waveformPanel
        case .parade: paradePanel
        case .vectorscope: vectorscopePanel
        }
    }

    // MARK: Waveform

    @ViewBuilder
    private var waveformPanel: some View {
        if let image = scopes?.waveformImage {
            tracePlate {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.medium)
            }
        } else {
            emptyPlate("No waveform yet")
        }
    }

    // MARK: Parade

    @ViewBuilder
    private var paradePanel: some View {
        if let images = scopes?.paradeImages, images.count == 3 {
            HStack(spacing: 2) {
                paradeChannel(images[0])
                paradeChannel(images[1])
                paradeChannel(images[2])
            }
            .frame(height: ScopesView.panelHeight)
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            emptyPlate("No parade yet")
        }
    }

    @ViewBuilder
    private func paradeChannel(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Vectorscope

    @ViewBuilder
    private var vectorscopePanel: some View {
        if let vectorscope {
            let skin: [ScopePoint] = vectorscope.skinLinePoints(count: 2)
            let band: (low: [ScopePoint], high: [ScopePoint]) = vectorscope.skinBandPoints(count: 2)
            ZStack {
                if let image = scopes?.vectorscopeImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                }
                Canvas { context, size in
                    ScopesView.drawGraticule(context: &context, size: size,
                                             skin: skin, bandLow: band.low, bandHigh: band.high)
                }
            }
            .frame(width: ScopesView.panelHeight, height: ScopesView.panelHeight)
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: .infinity)
            .help("OKLab a/b chroma scatter. The line is the skin-tone axis — "
                  + "faces sit along it whatever the skin colour.")
        } else {
            emptyPlate("No vectorscope yet")
        }
    }

    // MARK: Plates

    private func tracePlate<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: ScopesView.panelHeight)
            .background(Color.black.opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func emptyPlate(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10))
            .foregroundStyle(Lumen.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: ScopesView.panelHeight)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var caption: String {
        switch kind {
        case .waveform:
            guard let waveform else { return "Waveform — luma, column by column" }
            return "Luma waveform · \(waveform.columns) columns × \(waveform.bins) bins · "
                + waveform.transform.space.label
        case .parade:
            guard let parade else { return "RGB parade" }
            return "RGB parade · \(parade.red.columns) columns × \(parade.red.bins) bins · "
                + parade.red.transform.space.label
        case .vectorscope:
            guard let vectorscope else { return "Vectorscope — OKLab a/b" }
            return "OKLab a/b · ±" + String(format: "%.2f", vectorscope.extent)
                + " chroma · skin line "
                + String(format: "%.0f", Vectorscope.skinToneLineDegrees) + "° ±"
                + String(format: "%.0f", Vectorscope.skinBandHalfWidthDegrees) + "°"
        }
    }

    // MARK: Rasterizing
    //
    // Lives in `ScopeRaster`, not on the view: the detached measurement task in
    // ScopeData.swift calls it once per refresh, so `body` never rasterizes anything.


    // MARK: Graticule

    private static func drawGraticule(context: inout GraphicsContext,
                                      size: CGSize,
                                      skin: [ScopePoint],
                                      bandLow: [ScopePoint],
                                      bandHigh: [ScopePoint]) {
        guard size.width > 1, size.height > 1 else { return }
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)

        // Rings at quarter fractions of the plot's half-width, plus the neutral cross.
        var rings = Path()
        var step: Int = 1
        while step <= 4 {
            let fraction: CGFloat = CGFloat(step) / 4
            let rect = CGRect(x: centre.x - size.width / 2 * fraction,
                              y: centre.y - size.height / 2 * fraction,
                              width: size.width * fraction,
                              height: size.height * fraction)
            rings.addEllipse(in: rect)
            step += 1
        }
        context.stroke(rings, with: .color(Lumen.separator.opacity(0.55)), lineWidth: 0.5)

        var cross = Path()
        cross.move(to: CGPoint(x: 0, y: centre.y))
        cross.addLine(to: CGPoint(x: size.width, y: centre.y))
        cross.move(to: CGPoint(x: centre.x, y: 0))
        cross.addLine(to: CGPoint(x: centre.x, y: size.height))
        context.stroke(cross, with: .color(Lumen.separator.opacity(0.45)), lineWidth: 0.5)

        // The skin band as a wedge, then the line itself through the middle of it.
        if let lowEnd = bandLow.last, let highEnd = bandHigh.last {
            var wedge = Path()
            wedge.move(to: point(bandLow.first ?? lowEnd, in: size))
            wedge.addLine(to: point(lowEnd, in: size))
            wedge.addLine(to: point(highEnd, in: size))
            wedge.closeSubpath()
            context.fill(wedge, with: .color(Lumen.accent.opacity(0.18)))
        }

        if skin.count >= 2, let start = skin.first, let end = skin.last {
            var line = Path()
            line.move(to: point(start, in: size))
            line.addLine(to: point(end, in: size))
            context.stroke(line, with: .color(Lumen.accent.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    /// Normalized plot coordinates — (0,0) top-left, (0.5,0.5) neutral — into the view.
    private static func point(_ p: ScopePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(clamp01(p.x)) * size.width,
                y: CGFloat(clamp01(p.y)) * size.height)
    }

    // MARK: Small helpers

    private static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return Swift.min(Swift.max(v, 0), 1)
    }

}

// MARK: - Trace tint

/// How a panel's trace is coloured. Waveform and vectorscope are achromatic; the
/// parade's three panels carry just enough tint to name themselves.

/// Rasterizes scope traces to CGImages, off the view. Called once per measurement by
/// ScopeData's detached task; ScopesView only draws the results.
enum ScopeRaster {

    /// A waveform panel. `counts` is column-major with bin 0 at black, so the bitmap
    /// row is `bins − 1 − bin`: the data never encodes a drawing convention, the
    /// renderer does.
    static func waveform(_ waveform: Waveform, peak: Int, tint: ScopeTint) -> CGImage? {
        let width: Int = waveform.columns
        let height: Int = waveform.bins
        guard width > 0, height > 0, peak > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let inverse: Double = 1.0 / Double(peak)
        for column in 0..<width {
            for bin in 0..<height {
                let count: Int = waveform.count(column: column, bin: bin)
                guard count > 0 else { continue }
                let value: Double = gamma(Double(count) * inverse)
                let row: Int = height - 1 - bin
                let offset: Int = (row * width + column) * 4
                guard offset >= 0, offset + 3 < bytes.count else { continue }
                bytes[offset] = byte(value * tint.r)
                bytes[offset + 1] = byte(value * tint.g)
                bytes[offset + 2] = byte(value * tint.b)
                bytes[offset + 3] = 255
            }
        }
        return image(bytes: bytes, width: width, height: height)
    }

    /// The vectorscope's grid is already row-major with row 0 at the top (+b), which is
    /// exactly a bitmap's layout — no flip.
    static func vectorscope(_ scope: Vectorscope) -> CGImage? {
        let n: Int = scope.resolution
        guard n > 0, scope.peak > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for row in 0..<n {
            for column in 0..<n {
                let value: Double = scope.intensity(column: column, row: row)
                guard value > 0 else { continue }
                let level: Double = gamma(value)
                let offset: Int = (row * n + column) * 4
                guard offset >= 0, offset + 3 < bytes.count else { continue }
                let grey: UInt8 = byte(level * ScopeTint.neutral.r)
                bytes[offset] = grey
                bytes[offset + 1] = grey
                bytes[offset + 2] = grey
                bytes[offset + 3] = 255
            }
        }
        return image(bytes: bytes, width: n, height: n)
    }

    /// A single sample must still be visible next to a thousand: the trace is shown
    /// through a strong gamma rather than linearly, which is what every hardware scope
    /// does and why they read as a glow instead of a histogram.
    private static func gamma(_ intensity: Double) -> Double {
        guard intensity.isFinite, intensity > 0 else { return 0 }
        return clamp01(pow(clamp01(intensity), 0.4))
    }

    private static func image(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, bytes.count == width * height * 4 else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// One normalization across all three channels: the parade is one instrument, and
    /// per-channel scaling would make a weak blue channel look full strength.
    static func parade(_ parade: Parade) -> [CGImage]? {
        let peak = parade.peak
        guard let r = waveform(parade.red, peak: peak, tint: ScopeTint.red),
              let g = waveform(parade.green, peak: peak, tint: ScopeTint.green),
              let b = waveform(parade.blue, peak: peak, tint: ScopeTint.blue) else {
            return nil
        }
        return [r, g, b]
    }

    private static func clamp01(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return Swift.min(Swift.max(v, 0), 1)
    }

    private static func byte(_ v: Double) -> UInt8 {
        guard v.isFinite else { return 0 }
        let scaled: Double = (Swift.min(Swift.max(v, 0), 1) * 255).rounded()
        return UInt8(Swift.min(Swift.max(scaled, 0), 255))
    }
}

struct ScopeTint {
    let r: Double
    let g: Double
    let b: Double

    static let neutral = ScopeTint(r: 0.92, g: 0.94, b: 0.94)
    static let red = ScopeTint(r: 1.0, g: 0.36, b: 0.34)
    static let green = ScopeTint(r: 0.38, g: 1.0, b: 0.44)
    static let blue = ScopeTint(r: 0.44, g: 0.62, b: 1.0)
}

#endif

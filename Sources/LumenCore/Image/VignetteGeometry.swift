// VignetteGeometry.swift
// The post-crop vignette's settings and its coordinate field, defined ONCE for both
// renderers (WS-41).
//
// `DetailEngine.vignette` (the CPU reference) and `RenderGraph.applyVignette` (the GPU
// twin) both read the vignette's position, size and orientation from `VignetteField`.
// Before this file the GPU laid the ellipse out on the crop (through
// `PipelineRenderer.geometryRects`) and the reference laid it out on the uncropped
// source, so every cropped recipe rendered a different vignette on the two paths —
// 1.98 EV apart at the crop corners of the contract test's geometry (WS-41 AUDIT F7).
// One definition in LumenCore is what makes that impossible to reintroduce: neither
// renderer can disagree with a function both of them call.
//
// The arithmetic is `PipelineRenderer.geometryRects` transcribed into plain Doubles,
// statement for statement, so it can run on a machine with no Core Graphics:
//   · the orientation is `identity.scaledBy(−1, 1)` when flipped, then `.rotated(by:
//     −angle)`, with CGAffineTransform's PREPEND semantics (the rotation acts first);
//   · the rotated source's bounding box is centred where the source was, the usable
//     (inscribed) frame is centred on it, and the crop is a fraction of the usable frame
//     measured from its TOP-left (`CropGeometry.resolve`), converted to the y-up frame;
//   · the vignette is centred on that crop rectangle's `integral` bounds, which is the
//     rectangle Core Image actually delivers.
// Coordinates are Core Image's: y UP, origin at the bottom-left of the source extent,
// pixel centres at +0.5. The CPU's top-down rows map to it through `uv(column:row:)`.

import Foundation

/// The three Lightroom post-crop vignette styles.
///
/// String-coded so a sidecar reads as words, and decoded TOLERANTLY: a style this build
/// does not know (written by a later one, or by hand) falls back to Highlight Priority,
/// the default, rather than refusing the whole recipe.
public enum VignetteStyle: String, Codable, CaseIterable, Sendable {
    /// An exposure-like multiply on scene-linear light — what the vignette always was —
    /// with the Highlights slider able to hold bright areas back from a burn.
    case highlightPriority
    /// The same luminance change with the colour held: a burn keeps its C/L through the
    /// display transform's toe, and a lift keeps its chroma instead of going pastel.
    case colorPriority
    /// Opaque paint toward black or white: the corner's contrast in stops is reduced as
    /// it is covered, the flat look Lightroom documents. Highlights does not apply.
    case paintOverlay

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VignetteStyle(rawValue: raw) ?? .highlightPriority
    }

    /// The kernel's style code. Read by `RenderGraph.applyVignette`; the CPU switches on
    /// the case itself.
    public var code: Double {
        switch self {
        case .highlightPriority: return 0
        case .colorPriority: return 1
        case .paintOverlay: return 2
        }
    }
}

/// Everything the vignette stage reads from a recipe, carried through the plan as one
/// value so both renderers' call lines name one thing.
public struct VignetteSettings: Equatable, Sendable {
    /// EV at the crop's corner, `DetailEngine.vignetteAmountRange`. 0 = off.
    public var amount: Double
    /// 0…100: the WIDTH of the transition around the midpoint. 0 is a hard edge.
    public var feather: Double
    /// 0…100: where the transition's 50 % point sits, centre (0) to corners (100).
    public var midpoint: Double
    /// −100…+100: rounded rectangle (−100), crop-aspect ellipse (0), circle (+100).
    public var roundness: Double
    /// 0…100: how much bright areas are held back from a burn (HP and CP, Amount < 0).
    public var highlights: Double
    public var style: VignetteStyle

    public init(amount: Double = 0,
                feather: Double = Look.vignetteFeatherDefault,
                midpoint: Double = Look.vignetteMidpointDefault,
                roundness: Double = Look.vignetteRoundnessDefault,
                highlights: Double = Look.vignetteHighlightsDefault,
                style: VignetteStyle = .highlightPriority) {
        self.amount = amount
        self.feather = feather
        self.midpoint = midpoint
        self.roundness = roundness
        self.highlights = highlights
        self.style = style
    }

    public init(look: Look) {
        self.init(amount: look.vignette, feather: look.vignetteFeather,
                  midpoint: look.vignetteMidpoint, roundness: look.vignetteRoundness,
                  highlights: look.vignetteHighlights, style: look.vignetteStyle)
    }
}

/// The vignette's coordinate field over one source frame: where each source pixel lands
/// in the DELIVERED (cropped, straightened, flipped) frame, normalized so the crop's
/// edges are at u, v = ±1.
public struct VignetteField: Equatable, Sendable {
    /// The orientation, Core Graphics layout: oriented = (a·x + c·y + tx, b·x + d·y + ty)
    /// for a y-up point (x, y) of the zero-origin source extent.
    public let a: Double
    public let b: Double
    public let c: Double
    public let d: Double
    public let tx: Double
    public let ty: Double
    /// The delivered crop rectangle's centre and half extents, in oriented pixels. Its
    /// bounds are integral: they are `CGRect.integral` of the resolved crop.
    public let centreX: Double
    public let centreY: Double
    public let halfWidth: Double
    public let halfHeight: Double
    /// The source extent the field was built for.
    public let sourceWidth: Double
    public let sourceHeight: Double

    /// The field of `geometry` over a zero-origin source of the given size.
    public init(geometry: Geometry, sourceWidth: Double, sourceHeight: Double) {
        // geometryRects: `var orientation = .identity; if flipH { scaledBy(-1, 1) };
        // if angle != 0 { rotated(by: -angle·π/180) }`.
        var t = Affine.identity
        if geometry.flipH { t = Affine.scale(-1, 1).concatenating(t) }
        if geometry.angle != 0 {
            t = Affine.rotation(-geometry.angle * .pi / 180).concatenating(t)
        }
        // `extent.applying(orientation)`: the transformed rectangle's bounding box.
        let corners = [(0.0, 0.0), (sourceWidth, 0.0), (0.0, sourceHeight),
                       (sourceWidth, sourceHeight)].map { t.apply($0.0, $0.1) }
        let minX = corners.map(\.x).min() ?? 0, maxX = corners.map(\.x).max() ?? 0
        let minY = corners.map(\.y).min() ?? 0, maxY = corners.map(\.y).max() ?? 0
        let rotatedMidX = minX + (maxX - minX) * 0.5
        let rotatedMidY = minY + (maxY - minY) * 0.5
        let resolved = CropGeometry.resolve(sourceWidth: sourceWidth,
                                            sourceHeight: sourceHeight,
                                            geometry: geometry)
        // The usable frame is centred on the rotated picture; `resolved` is
        // top-left-origin and Core Image is y-up.
        let usableX = rotatedMidX - resolved.usableWidth / 2
        let usableY = rotatedMidY - resolved.usableHeight / 2
        let usableMaxY = usableY + resolved.usableHeight
        let targetX = usableX + resolved.x
        let targetY = usableMaxY - resolved.y - resolved.height
        // `target.integral`: the smallest integral rectangle containing it.
        let x0 = (targetX).rounded(.down)
        let y0 = (targetY).rounded(.down)
        let x1 = (targetX + resolved.width).rounded(.up)
        let y1 = (targetY + resolved.height).rounded(.up)
        let width = x1 - x0, height = y1 - y0

        a = t.a; b = t.b; c = t.c; d = t.d; tx = t.tx; ty = t.ty
        centreX = x0 + width * 0.5
        centreY = y0 + height * 0.5
        halfWidth = width / 2
        halfHeight = height / 2
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
    }

    /// The field of a full-frame, unrotated, unflipped geometry — the layout every
    /// vignette had on the reference path before the crop was honoured.
    public init(sourceWidth: Double, sourceHeight: Double) {
        self.init(geometry: Geometry(), sourceWidth: sourceWidth,
                  sourceHeight: sourceHeight)
    }

    /// The delivered crop's half-diagonal in pixels — the length the feather-0 edge's
    /// anti-aliasing is denominated against (`DetailEngine.vignetteWidth`).
    public var pixelHalfDiagonal: Double {
        (halfWidth * halfWidth + halfHeight * halfHeight).squareRoot()
    }

    /// Normalized delivered coordinates of the source pixel at `column`, `row` — rows
    /// counted from the TOP, as `ImageBuffer` indexes them. ±1 at the crop's edges.
    ///
    /// Row r from the top is Core Image's y = height − r − 0.5 at its centre (the
    /// convention `KernelLibrary.maskLinearSource` documents), and the division is by the
    /// half extents rather than a multiply by their reciprocals so that the full-frame
    /// case reproduces the reference's historical arithmetic to the bit.
    @inline(__always)
    public func uv(column x: Int, row y: Int) -> (u: Double, v: Double) {
        let sx = Double(x) + 0.5
        let sy = sourceHeight - Double(y) - 0.5
        let ox = a * sx + c * sy + tx
        let oy = b * sx + d * sy + ty
        return ((ox - centreX) / Swift.max(halfWidth, 1e-6),
                (oy - centreY) / Swift.max(halfHeight, 1e-6))
    }

    /// A 2-D affine map with Core Graphics' layout and concatenation order.
    struct Affine: Equatable {
        var a: Double
        var b: Double
        var c: Double
        var d: Double
        var tx: Double
        var ty: Double

        static let identity = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

        static func scale(_ sx: Double, _ sy: Double) -> Affine {
            Affine(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
        }

        /// `CGAffineTransformMakeRotation`: counter-clockwise in a y-up frame.
        static func rotation(_ radians: Double) -> Affine {
            let cs = cos(radians), sn = sin(radians)
            return Affine(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0)
        }

        /// `CGAffineTransformConcat(self, other)`: `self` first, then `other`.
        func concatenating(_ o: Affine) -> Affine {
            Affine(a: a * o.a + b * o.c, b: a * o.b + b * o.d,
                   c: c * o.a + d * o.c, d: c * o.b + d * o.d,
                   tx: tx * o.a + ty * o.c + o.tx, ty: tx * o.b + ty * o.d + o.ty)
        }

        func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            (a * x + c * y + tx, b * x + d * y + ty)
        }
    }
}

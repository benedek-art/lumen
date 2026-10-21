// BrushLivePreview.swift
// What the brush shows WHILE the button is down: the stroke being drawn, rasterized by
// the same `BrushStrokeRaster` that will paint it on mouse-up, at the canvas's own
// resolution, as a tinted premultiplied RGBA patch the canvas can draw as an image.
//
// WHAT STOOD HERE. `MaskCanvas.drawBrush` stroked the recorded points as a hard
// white path one cursor-diameter wide, and nothing else happened until mouse-up. So the
// photographer painted with a hard-edged white line that was as wide as the OUTER ring,
// ignored Feather, Flow, Density, Erase and Auto Mask entirely, vanished on release,
// and was replaced some hundreds of milliseconds later by the real mask — narrower,
// softer, weaker, cut by Auto Mask. Two different brushes, one after the other, with a
// blank frame between them. That is most of what "glitchy" was.
//
// Now the live patch IS the committed stroke's coverage (`BrushRasterTests` pins that
// building it point by point equals painting it whole), drawn in the mask overlay's
// colour at its strength, so the edge, the falloff, the Flow level and the Auto Mask cut
// are visible as they are painted.
//
// Coordinates: pixels of the canvas raster (view points × scale). The stroke's points
// arrive in those pixels; `size` is the brush diameter in the same pixels. Auto Mask
// reads `picture`, the DISPLAYED preview at the same extent (sRGB RGBA8), linearized to
// the working space — an approximation of the stage input the committed stroke reads,
// close enough to show where the cut falls.

import Foundation

public struct BrushLivePreview {

    public let width: Int
    public let height: Int
    private var raster: BrushStrokeRaster
    /// Premultiplied RGBA8 over the whole extent, kept current in the dirty rects.
    public private(set) var rgba: [UInt8]
    private let tint: (Double, Double, Double)
    private let strength: Double

    /// - Parameters:
    ///   - stroke: brush parameters (`size` is ignored; `diameterPx` replaces it).
    ///   - diameterPx: brush diameter in canvas pixels.
    ///   - picture: the displayed image at `width × height`, sRGB RGBA8, row-major —
    ///     needed only for Auto Mask.
    ///   - tint: display-referred overlay colour; `strength` its opacity at coverage 1.
    public init(stroke: BrushStroke, width: Int, height: Int, diameterPx: Double,
                picture: [UInt8]? = nil,
                tint: (Double, Double, Double) = (0.90, 0.16, 0.16),
                strength: Double = 0.55) {
        let w = Swift.max(width, 1), h = Swift.max(height, 1)
        self.width = w
        self.height = h
        var s = stroke
        s.points = []
        let long = Double(Swift.max(w, h))
        s.size = diameterPx.isFinite ? Swift.max(diameterPx, 0) / long : 0
        var source: ImageBuffer? = nil
        if stroke.automask, let picture, picture.count >= w * h * 4 {
            source = BrushLivePreview.linearize(picture, width: w, height: h)
        }
        raster = BrushStrokeRaster(stroke: s, width: w, height: h, longEdge: long,
                                   source: source)
        rgba = [UInt8](repeating: 0, count: w * h * 4)
        self.tint = tint
        self.strength = Num.saturate(strength)
    }

    /// Add a point in canvas pixels. Returns the rect that changed.
    @discardableResult
    public mutating func append(x: Double, y: Double, pressure: Double = 1) -> BrushStrokeRaster.Rect {
        raster.append(BrushPoint(x: x / Double(width), y: y / Double(height), pressure: pressure))
        return refresh()
    }

    /// Draw the last pending segment (or the click's single dab).
    @discardableResult
    public mutating func finish() -> BrushStrokeRaster.Rect {
        raster.finish()
        return refresh()
    }

    /// Everything painted so far, in canvas pixels.
    public var touched: BrushStrokeRaster.Rect { raster.touched }

    /// The premultiplied RGBA8 rows of `rect` (clamped to the extent), packed.
    public func patch(_ rect: BrushStrokeRaster.Rect) -> [UInt8] {
        let r = rect.intersection(BrushStrokeRaster.Rect(x0: 0, y0: 0, x1: width, y1: height))
        guard !r.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: r.width * r.height * 4)
        let rowBytes = r.width * 4
        rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in r.y0..<r.y1 {
                    let from = src.baseAddress! + (y * width + r.x0) * 4
                    let to = dst.baseAddress! + (y - r.y0) * rowBytes
                    to.update(from: from, count: rowBytes)
                }
            }
        }
        return out
    }

    private mutating func refresh() -> BrushStrokeRaster.Rect {
        let d = raster.takeDirty()
        guard !d.isEmpty else { return d }
        let k = strength
        for y in d.y0..<d.y1 {
            for x in d.x0..<d.x1 {
                let a = Double(raster.value(x, y)) * k
                let i = (y * width + x) * 4
                rgba[i] = UInt8((tint.0 * a * 255).rounded())
                rgba[i + 1] = UInt8((tint.1 * a * 255).rounded())
                rgba[i + 2] = UInt8((tint.2 * a * 255).rounded())
                rgba[i + 3] = UInt8((a * 255).rounded())
            }
        }
        return d
    }

    /// sRGB RGBA8 → linear working-space (Rec.2020) RGB, the space Auto Mask compares in.
    static func linearize(_ bytes: [UInt8], width w: Int, height h: Int) -> ImageBuffer {
        var table = [Double](repeating: 0, count: 256)
        for v in 0..<256 {
            let c = Double(v) / 255
            table[v] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let m = RGBColorSpace.srgb.matrix(to: .rec2020)
        var img = ImageBuffer(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let lin = RGB(table[Int(bytes[i])], table[Int(bytes[i + 1])], table[Int(bytes[i + 2])])
                img[x, y] = m.apply(lin)
            }
        }
        return img
    }
}

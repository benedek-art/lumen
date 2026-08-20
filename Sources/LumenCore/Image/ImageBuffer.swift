// ImageBuffer.swift
// The CPU-side image type the reference implementations operate on.
//
// This is not the production render path — that is Core Image on the GPU. This is the
// f32 reference every GPU stage is measured against (docs/14 §1.4), the substrate for
// golden tests, and the fallback that lets headless tooling render without a display.
// Interleaved RGBA float, row-major, origin at the top-left (image convention, not
// Core Image's bottom-up one — conversions happen at the boundary, once).

import Foundation

public struct ImageBuffer: Sendable {
    public let width: Int
    public let height: Int
    /// width × height × 4, interleaved RGBA.
    public var pixels: [Float]

    /// A new buffer is opaque black, not transparent black. Photographs are opaque,
    /// and an alpha of zero is indistinguishable from correct until it reaches
    /// something that treats the data as premultiplied — at which point every colour
    /// silently becomes zero.
    public init(width: Int, height: Int) {
        precondition(width > 0 && height > 0, "ImageBuffer needs a non-empty extent")
        self.width = width
        self.height = height
        var p = [Float](repeating: 0, count: width * height * 4)
        var i = 3
        while i < p.count {
            p[i] = 1
            i += 4
        }
        self.pixels = p
    }

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(width > 0 && height > 0)
        precondition(pixels.count == width * height * 4, "pixel count mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Fill from a generator over normalized coordinates — how synthetic test frames
    /// (ramps, hue wheels, edges) are built.
    public init(width: Int, height: Int, generator: (Double, Double) -> RGB) {
        self.init(width: width, height: height)
        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                self[x, y] = generator(u, v)
            }
        }
    }

    public var count: Int { width * height }

    @inlinable public func index(_ x: Int, _ y: Int) -> Int {
        (y * width + x) * 4
    }

    @inlinable public subscript(x: Int, y: Int) -> RGB {
        get {
            let i = index(x, y)
            return RGB(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
        }
        set {
            let i = index(x, y)
            pixels[i] = Float(newValue.r)
            pixels[i + 1] = Float(newValue.g)
            pixels[i + 2] = Float(newValue.b)
        }
    }

    @inlinable public func alpha(_ x: Int, _ y: Int) -> Double {
        Double(pixels[index(x, y) + 3])
    }

    public mutating func setAlpha(_ a: Double, _ x: Int, _ y: Int) {
        pixels[index(x, y) + 3] = Float(a)
    }

    /// Clamped edge addressing — every spatial kernel here uses it, so a filter never
    /// invents darkness at the frame border.
    @inlinable public func clampedSample(_ x: Int, _ y: Int) -> RGB {
        self[Swift.min(Swift.max(x, 0), width - 1), Swift.min(Swift.max(y, 0), height - 1)]
    }

    /// Bilinear sample at continuous coordinates (pixel centres at +0.5).
    public func bilinear(_ x: Double, _ y: Double) -> RGB {
        let fx = x - 0.5, fy = y - 0.5
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let a = clampedSample(x0, y0).mix(clampedSample(x0 + 1, y0), tx)
        let b = clampedSample(x0, y0 + 1).mix(clampedSample(x0 + 1, y0 + 1), tx)
        return a.mix(b, ty)
    }

    public func map(_ f: (RGB) -> RGB) -> ImageBuffer {
        var out = self
        for y in 0..<height {
            for x in 0..<width { out[x, y] = f(self[x, y]) }
        }
        return out
    }

    /// Per-pixel combine with another buffer of the same extent.
    public func zip(_ other: ImageBuffer, _ f: (RGB, RGB) -> RGB) -> ImageBuffer {
        precondition(width == other.width && height == other.height, "extent mismatch")
        var out = self
        for y in 0..<height {
            for x in 0..<width { out[x, y] = f(self[x, y], other[x, y]) }
        }
        return out
    }

    public func luminancePlane(space: RGBColorSpace = .rec2020) -> Plane {
        var p = Plane(width: width, height: height)
        let w = space.luminanceWeights
        for y in 0..<height {
            for x in 0..<width {
                let c = self[x, y]
                p[x, y] = w.r * c.r + w.g * c.g + w.b * c.b
            }
        }
        return p
    }

    /// Largest per-channel difference against another buffer — the goldens' metric.
    public func maxAbsDifference(_ other: ImageBuffer) -> Double {
        guard width == other.width && height == other.height else { return .infinity }
        var d = 0.0
        for i in 0..<pixels.count {
            d = Swift.max(d, abs(Double(pixels[i] - other.pixels[i])))
        }
        return d
    }

    /// Box downsample by an integer factor — the working-resolution proxy builder.
    public func downsampled(by factor: Int) -> ImageBuffer {
        guard factor > 1 else { return self }
        let w = Swift.max(width / factor, 1)
        let h = Swift.max(height / factor, 1)
        var out = ImageBuffer(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = RGB.zero
                var n = 0.0
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        let sx = x * factor + dx, sy = y * factor + dy
                        if sx < width && sy < height {
                            acc = acc + self[sx, sy]
                            n += 1
                        }
                    }
                }
                out[x, y] = n > 0 ? acc / n : .zero
            }
        }
        return out
    }
}

// MARK: - Single-channel plane

/// A single-channel f32 plane: luminance, masks, transmission maps, guided-filter
/// intermediates. Masks are single-channel by design (docs/13 §4's memory budget).
public struct Plane: Sendable {
    public let width: Int
    public let height: Int
    public var values: [Float]

    public init(width: Int, height: Int, fill: Double = 0) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        self.values = [Float](repeating: Float(fill), count: width * height)
    }

    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height, "plane size mismatch")
        self.width = width
        self.height = height
        self.values = values
    }

    public init(width: Int, height: Int, generator: (Double, Double) -> Double) {
        self.init(width: width, height: height)
        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                self[x, y] = generator((Double(x) + 0.5) / Double(width), v)
            }
        }
    }

    @inlinable public subscript(x: Int, y: Int) -> Double {
        get { Double(values[y * width + x]) }
        set { values[y * width + x] = Float(newValue) }
    }

    @inlinable public func clampedSample(_ x: Int, _ y: Int) -> Double {
        self[Swift.min(Swift.max(x, 0), width - 1), Swift.min(Swift.max(y, 0), height - 1)]
    }

    public func bilinear(_ x: Double, _ y: Double) -> Double {
        let fx = x - 0.5, fy = y - 0.5
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let a = Num.mix(clampedSample(x0, y0), clampedSample(x0 + 1, y0), tx)
        let b = Num.mix(clampedSample(x0, y0 + 1), clampedSample(x0 + 1, y0 + 1), tx)
        return Num.mix(a, b, ty)
    }

    public func map(_ f: (Double) -> Double) -> Plane {
        var out = self
        for i in 0..<values.count { out.values[i] = Float(f(Double(values[i]))) }
        return out
    }

    public func zip(_ other: Plane, _ f: (Double, Double) -> Double) -> Plane {
        precondition(width == other.width && height == other.height, "extent mismatch")
        var out = self
        for i in 0..<values.count {
            out.values[i] = Float(f(Double(values[i]), Double(other.values[i])))
        }
        return out
    }

    public var mean: Double {
        guard !values.isEmpty else { return 0 }
        var s = 0.0
        for v in values { s += Double(v) }
        return s / Double(values.count)
    }

    public var range: (min: Double, max: Double) {
        var lo = Double.infinity, hi = -Double.infinity
        for v in values {
            let d = Double(v)
            lo = Swift.min(lo, d)
            hi = Swift.max(hi, d)
        }
        return values.isEmpty ? (0, 0) : (lo, hi)
    }

    /// Resample to a new extent with bilinear filtering — mask rasters live at a
    /// working resolution and get upsampled to the render target.
    public func resized(width newWidth: Int, height newHeight: Int) -> Plane {
        guard newWidth != width || newHeight != height else { return self }
        var out = Plane(width: newWidth, height: newHeight)
        let sx = Double(width) / Double(newWidth)
        let sy = Double(height) / Double(newHeight)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                out[x, y] = bilinear((Double(x) + 0.5) * sx, (Double(y) + 0.5) * sy)
            }
        }
        return out
    }
}

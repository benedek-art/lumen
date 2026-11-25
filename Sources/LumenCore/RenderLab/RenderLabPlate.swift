// RenderLabPlate.swift
// A decoded plate: the scene-linear working-space buffer Lumen's own stages start from
// (the RAW stage's output), written once on macOS so Linux can render real photographs
// through ReferenceRenderer.
//
// File layout: ASCII "LUMENPLATE1\n", UInt32 little-endian header length, UTF-8 JSON
// header, then width*height*3 Float32 little-endian (R, G, B), top row first.

import Foundation

public struct RenderLabPlate {

    public struct Header: Codable, Sendable {
        public var id: String
        public var width: Int
        public var height: Int
        /// Linear Rec.2020, mid-grey 0.18, unbounded.
        public var space: String = "linear Rec.2020 (Lumen working space), mid-grey 0.18"
        public var sourceFile: String
        public var decoder: String
        public var decoderVersion: Int?
        public var asShotTemperature: Double
        public var asShotTint: Double
        public var iso: Double?
        public var nativeWidth: Int
        public var nativeHeight: Int
        /// Decode scale relative to the native frame (1 for native crops).
        public var scale: Double
        /// For a crop: unit rectangle of the decoded (oriented) frame, top-left origin.
        public var crop: [Double]?
        /// EXIF orientation is applied by the RAW stage before this buffer.
        public var orientationApplied: Bool = true
        /// The recipe the decode stage read (capture sharpening, decoder NR, lens).
        public var decodeRecipe: RenderLabJSON?
        public var note: String?

        public init(id: String, width: Int, height: Int, sourceFile: String, decoder: String,
                    decoderVersion: Int?, asShotTemperature: Double, asShotTint: Double,
                    iso: Double?, nativeWidth: Int, nativeHeight: Int, scale: Double,
                    crop: [Double]?, decodeRecipe: RenderLabJSON?) {
            self.id = id
            self.width = width
            self.height = height
            self.sourceFile = sourceFile
            self.decoder = decoder
            self.decoderVersion = decoderVersion
            self.asShotTemperature = asShotTemperature
            self.asShotTint = asShotTint
            self.iso = iso
            self.nativeWidth = nativeWidth
            self.nativeHeight = nativeHeight
            self.scale = scale
            self.crop = crop
            self.decodeRecipe = decodeRecipe
        }
    }

    public var header: Header
    public var image: ImageBuffer

    public init(header: Header, image: ImageBuffer) {
        self.header = header
        self.image = image
    }

    static let magic = Data("LUMENPLATE1\n".utf8)

    public func encoded() throws -> Data {
        let json = try JSONEncoder().encode(header)
        var out = Self.magic
        var n = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        out.append(json)
        var floats = [Float](repeating: 0, count: image.width * image.height * 3)
        for i in 0..<(image.width * image.height) {
            floats[i * 3] = image.pixels[i * 4]
            floats[i * 3 + 1] = image.pixels[i * 4 + 1]
            floats[i * 3 + 2] = image.pixels[i * 4 + 2]
        }
        floats.withUnsafeBytes { out.append(contentsOf: $0) }
        return out
    }

    public static func readHeader(_ data: Data) throws -> (Header, Int) {
        guard data.count > magic.count + 4, data.prefix(magic.count) == magic else {
            throw RenderLabError.missingPhoto("not a Lumen plate")
        }
        let bytes = [UInt8](data[magic.count..<(magic.count + 4)])
        let n = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        let start = magic.count + 4
        guard data.count >= start + n else { throw RenderLabError.missingPhoto("truncated plate") }
        let header = try JSONDecoder().decode(Header.self, from: data[start..<(start + n)])
        return (header, start + n)
    }

    public init(data: Data) throws {
        let (header, offset) = try Self.readHeader(data)
        let count = header.width * header.height
        guard data.count - offset == count * 12 else {
            throw RenderLabError.missingPhoto("plate \(header.id): expected \(count * 12) pixel bytes, "
                + "found \(data.count - offset)")
        }
        var pixels = [Float](repeating: 1, count: count * 4)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: offset)
            for i in 0..<count {
                for c in 0..<3 {
                    var v: Float = 0
                    memcpy(&v, base.advanced(by: (i * 3 + c) * 4), 4)
                    pixels[i * 4 + c] = v
                }
            }
        }
        self.header = header
        self.image = ImageBuffer(width: header.width, height: header.height, pixels: pixels)
    }

    /// Area-average downscale of a float buffer to fit `longEdge`.
    public static func downscale(_ image: ImageBuffer, longEdge: Int) -> ImageBuffer {
        let s = Double(longEdge) / Double(Swift.max(image.width, image.height))
        guard s < 1 else { return image }
        let w = Swift.max(1, Int((Double(image.width) * s).rounded()))
        let h = Swift.max(1, Int((Double(image.height) * s).rounded()))
        var out = ImageBuffer(width: w, height: h)
        let sx = Double(image.width) / Double(w), sy = Double(image.height) / Double(h)
        for y in 0..<h {
            let y0 = Int(Double(y) * sy), y1 = Swift.max(y0 + 1, Swift.min(image.height, Int(Double(y + 1) * sy)))
            for x in 0..<w {
                let x0 = Int(Double(x) * sx), x1 = Swift.max(x0 + 1, Swift.min(image.width, Int(Double(x + 1) * sx)))
                var r: Float = 0, g: Float = 0, b: Float = 0
                for yy in y0..<y1 {
                    for xx in x0..<x1 {
                        let i = (yy * image.width + xx) * 4
                        r += image.pixels[i]; g += image.pixels[i + 1]; b += image.pixels[i + 2]
                    }
                }
                let n = Float((y1 - y0) * (x1 - x0))
                let o = (y * w + x) * 4
                out.pixels[o] = r / n
                out.pixels[o + 1] = g / n
                out.pixels[o + 2] = b / n
            }
        }
        return out
    }
}

// RenderLabSheet.swift
// Labelled contact sheets for the render lab, a 5x7 bitmap font to label them with,
// and a dependency-free PNG writer (stored deflate: large but portable).

import Foundation

public enum RenderLabSheet {

    public struct Cell {
        public var image: RenderLabImage
        public var lines: [String]
        public var histogram: [Int]?
        public init(image: RenderLabImage, lines: [String], histogram: [Int]? = nil) {
            self.image = image
            self.lines = lines
            self.histogram = histogram
        }
    }

    static let scale = 2
    static let lineHeight = 8 * scale + 4
    static let histogramHeight = 36
    static let pad = 8

    /// Lays cells out `columns` wide, each tile fit inside `tile`×`tile`.
    public static func compose(title: [String], cells: [Cell], columns: Int,
                               tile: Int) -> RenderLabImage {
        let cols = Swift.max(1, Swift.min(columns, cells.count))
        let rows = (cells.count + cols - 1) / cols
        let maxLines = cells.map(\.lines.count).max() ?? 0
        let hasHist = cells.contains { $0.histogram != nil }
        let tileW = tile
        let tileH = cells.map { c -> Int in
            let s = fit(c.image, tile)
            return s.h
        }.max() ?? tile
        let cellW = tileW + pad
        let cellH = tileH + pad / 2 + maxLines * lineHeight + (hasHist ? histogramHeight + 4 : 0) + pad
        let headerH = pad + title.count * lineHeight + pad / 2
        let widthForTitle = (title.map(\.count).max() ?? 0) * 6 * scale + 2 * pad
        let width = Swift.max(cols * cellW + pad, widthForTitle)
        let height = headerH + rows * cellH
        var sheet = RenderLabImage(width: width, height: height, fill: 28)
        for (i, line) in title.enumerated() {
            drawText(line, into: &sheet, x: pad, y: pad + i * lineHeight,
                     color: i == 0 ? (255, 214, 120) : (220, 220, 220))
        }
        for (k, cell) in cells.enumerated() {
            let cx = pad + (k % cols) * cellW
            let cy = headerH + (k / cols) * cellH
            let s = fit(cell.image, tile)
            let small = downscale(cell.image, to: s.w, s.h)
            blit(small, into: &sheet, x: cx + (tileW - s.w) / 2, y: cy)
            var ty = cy + tileH + pad / 2
            for line in cell.lines {
                drawText(line, into: &sheet, x: cx, y: ty, color: (235, 235, 235),
                         maxWidth: tileW)
                ty += lineHeight
            }
            if let hist = cell.histogram {
                drawHistogram(hist, into: &sheet, x: cx, y: ty, w: tileW, h: histogramHeight)
            }
        }
        return sheet
    }

    static func fit(_ image: RenderLabImage, _ tile: Int) -> (w: Int, h: Int) {
        let s = Double(tile) / Double(Swift.max(image.width, image.height))
        if s >= 1 { return (image.width, image.height) }
        return (Swift.max(1, Int((Double(image.width) * s).rounded())),
                Swift.max(1, Int((Double(image.height) * s).rounded())))
    }

    /// Area-average downscale.
    public static func downscale(_ image: RenderLabImage, to w: Int, _ h: Int) -> RenderLabImage {
        if w == image.width && h == image.height { return image }
        var out = RenderLabImage(width: w, height: h, fill: 0)
        let sx = Double(image.width) / Double(w), sy = Double(image.height) / Double(h)
        for y in 0..<h {
            let y0 = Int(Double(y) * sy), y1 = Swift.max(y0 + 1, Swift.min(image.height, Int(Double(y + 1) * sy)))
            for x in 0..<w {
                let x0 = Int(Double(x) * sx), x1 = Swift.max(x0 + 1, Swift.min(image.width, Int(Double(x + 1) * sx)))
                var acc = (0, 0, 0), n = 0
                for yy in y0..<y1 {
                    var i = (yy * image.width + x0) * 4
                    for _ in x0..<x1 {
                        acc.0 += Int(image.rgba[i]); acc.1 += Int(image.rgba[i + 1])
                        acc.2 += Int(image.rgba[i + 2])
                        n += 1
                        i += 4
                    }
                }
                let o = (y * w + x) * 4
                out.rgba[o] = UInt8(acc.0 / n)
                out.rgba[o + 1] = UInt8(acc.1 / n)
                out.rgba[o + 2] = UInt8(acc.2 / n)
                out.rgba[o + 3] = 255
            }
        }
        return out
    }

    static func blit(_ src: RenderLabImage, into dst: inout RenderLabImage, x: Int, y: Int) {
        for row in 0..<src.height where y + row >= 0 && y + row < dst.height {
            for col in 0..<src.width where x + col >= 0 && x + col < dst.width {
                let s = (row * src.width + col) * 4
                let d = ((y + row) * dst.width + x + col) * 4
                dst.rgba[d] = src.rgba[s]
                dst.rgba[d + 1] = src.rgba[s + 1]
                dst.rgba[d + 2] = src.rgba[s + 2]
            }
        }
    }

    static func put(_ img: inout RenderLabImage, _ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        guard x >= 0, y >= 0, x < img.width, y < img.height else { return }
        let i = (y * img.width + x) * 4
        img.rgba[i] = c.0
        img.rgba[i + 1] = c.1
        img.rgba[i + 2] = c.2
    }

    /// Luma histogram on a log-ish scale, with the 0 and 255 bins marked red when hit.
    static func drawHistogram(_ hist: [Int], into img: inout RenderLabImage,
                              x: Int, y: Int, w: Int, h: Int) {
        for yy in 0..<h { for xx in 0..<w { put(&img, x + xx, y + yy, (12, 12, 12)) } }
        let peak = Double(hist.dropFirst().dropLast().max() ?? 1)
        guard peak > 0 else { return }
        for xx in 0..<w {
            let b0 = xx * 256 / w, b1 = Swift.max(b0 + 1, (xx + 1) * 256 / w)
            let v = Double(hist[b0..<Swift.min(256, b1)].max() ?? 0)
            let bar = Int((Swift.min(1, (v / peak).squareRoot()) * Double(h - 2)).rounded())
            let clipped = (b0 == 0 && hist[0] > 0) || (b1 >= 256 && hist[255] > 0)
            for k in 0..<bar {
                put(&img, x + xx, y + h - 1 - k, clipped ? (230, 60, 60) : (190, 190, 190))
            }
        }
    }

    public static func drawText(_ text: String, into img: inout RenderLabImage, x: Int, y: Int,
                                color: (UInt8, UInt8, UInt8), maxWidth: Int? = nil) {
        var cx = x
        let advance = 6 * scale
        for ch in text.uppercased() {
            if let maxWidth, cx + advance - x > maxWidth { break }
            let rows = glyphs[ch] ?? glyphs["?"]!
            for (r, bits) in rows.enumerated() {
                for c in 0..<5 where bits & (1 << (4 - c)) != 0 {
                    for dy in 0..<scale {
                        for dx in 0..<scale {
                            put(&img, cx + c * scale + dx, y + r * scale + dy, color)
                        }
                    }
                }
            }
            cx += advance
        }
    }

    // MARK: - Font (5x7; each row is 5 bits, MSB = leftmost column)

    static let glyphs: [Character: [Int]] = {
        let src: [Character: String] = [
            " ": "00000 00000 00000 00000 00000 00000 00000",
            "0": "01110 10001 10011 10101 11001 10001 01110",
            "1": "00100 01100 00100 00100 00100 00100 01110",
            "2": "01110 10001 00001 00010 00100 01000 11111",
            "3": "11111 00010 00100 00010 00001 10001 01110",
            "4": "00010 00110 01010 10010 11111 00010 00010",
            "5": "11111 10000 11110 00001 00001 10001 01110",
            "6": "00110 01000 10000 11110 10001 10001 01110",
            "7": "11111 00001 00010 00100 01000 01000 01000",
            "8": "01110 10001 10001 01110 10001 10001 01110",
            "9": "01110 10001 10001 01111 00001 00010 01100",
            "A": "01110 10001 10001 11111 10001 10001 10001",
            "B": "11110 10001 10001 11110 10001 10001 11110",
            "C": "01110 10001 10000 10000 10000 10001 01110",
            "D": "11100 10010 10001 10001 10001 10010 11100",
            "E": "11111 10000 10000 11110 10000 10000 11111",
            "F": "11111 10000 10000 11110 10000 10000 10000",
            "G": "01110 10001 10000 10111 10001 10001 01111",
            "H": "10001 10001 10001 11111 10001 10001 10001",
            "I": "01110 00100 00100 00100 00100 00100 01110",
            "J": "00111 00010 00010 00010 00010 10010 01100",
            "K": "10001 10010 10100 11000 10100 10010 10001",
            "L": "10000 10000 10000 10000 10000 10000 11111",
            "M": "10001 11011 10101 10101 10001 10001 10001",
            "N": "10001 10001 11001 10101 10011 10001 10001",
            "O": "01110 10001 10001 10001 10001 10001 01110",
            "P": "11110 10001 10001 11110 10000 10000 10000",
            "Q": "01110 10001 10001 10001 10101 10010 01101",
            "R": "11110 10001 10001 11110 10100 10010 10001",
            "S": "01111 10000 10000 01110 00001 00001 11110",
            "T": "11111 00100 00100 00100 00100 00100 00100",
            "U": "10001 10001 10001 10001 10001 10001 01110",
            "V": "10001 10001 10001 10001 10001 01010 00100",
            "W": "10001 10001 10001 10101 10101 10101 01010",
            "X": "10001 10001 01010 00100 01010 10001 10001",
            "Y": "10001 10001 10001 01010 00100 00100 00100",
            "Z": "11111 00001 00010 00100 01000 10000 11111",
            ".": "00000 00000 00000 00000 00000 01100 01100",
            ",": "00000 00000 00000 00000 01100 00100 01000",
            ":": "00000 01100 01100 00000 01100 01100 00000",
            ";": "00000 01100 01100 00000 01100 00100 01000",
            "-": "00000 00000 00000 11111 00000 00000 00000",
            "+": "00000 00100 00100 11111 00100 00100 00000",
            "=": "00000 00000 11111 00000 11111 00000 00000",
            "/": "00000 00001 00010 00100 01000 10000 00000",
            "_": "00000 00000 00000 00000 00000 00000 11111",
            "%": "11000 11001 00010 00100 01000 10011 00011",
            "(": "00010 00100 01000 01000 01000 00100 00010",
            ")": "01000 00100 00010 00010 00010 00100 01000",
            "[": "01110 01000 01000 01000 01000 01000 01110",
            "]": "01110 00010 00010 00010 00010 00010 01110",
            "<": "00010 00100 01000 10000 01000 00100 00010",
            ">": "01000 00100 00010 00001 00010 00100 01000",
            "!": "00100 00100 00100 00100 00100 00000 00100",
            "?": "01110 10001 00001 00010 00100 00000 00100",
            "'": "01100 00100 01000 00000 00000 00000 00000",
            "\"": "01010 01010 01010 00000 00000 00000 00000",
            "*": "00000 00100 10101 01110 10101 00100 00000",
            "#": "01010 01010 11111 01010 11111 01010 01010",
            "|": "00100 00100 00100 00100 00100 00100 00100",
            "@": "01110 10001 00001 01101 10101 10101 01110",
            "~": "00000 00000 01000 10101 00010 00000 00000",
            "×": "00000 10001 01010 00100 01010 10001 00000",
            "°": "01100 10010 10010 01100 00000 00000 00000",
            "Δ": "00100 00100 01010 01010 10001 10001 11111",
        ]
        var out: [Character: [Int]] = [:]
        for (k, v) in src {
            out[k] = v.split(separator: " ").map { Int($0, radix: 2)! }
        }
        return out
    }()

    // MARK: - PNG

    /// RGB 8-bit PNG with stored (uncompressed) deflate blocks.
    public static func encodePNG(_ image: RenderLabImage) -> Data {
        var raw = Data(capacity: (image.width * 3 + 1) * image.height)
        for y in 0..<image.height {
            raw.append(0)
            var i = y * image.width * 4
            for _ in 0..<image.width {
                raw.append(image.rgba[i]); raw.append(image.rgba[i + 1]); raw.append(image.rgba[i + 2])
                i += 4
            }
        }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(be32(UInt32(image.width)))
        ihdr.append(be32(UInt32(image.height)))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        png.append(chunk("IHDR", ihdr))
        png.append(chunk("IDAT", zlibStored(raw)))
        png.append(chunk("IEND", Data()))
        return png
    }

    static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    static func chunk(_ type: String, _ payload: Data) -> Data {
        var out = be32(UInt32(payload.count))
        let body = Data(type.utf8) + payload
        out.append(body)
        out.append(be32(crc32(body)))
        return out
    }

    static func zlibStored(_ raw: Data) -> Data {
        var out = Data([0x78, 0x01])
        var offset = 0
        let bytes = [UInt8](raw)
        repeat {
            let n = Swift.min(65535, bytes.count - offset)
            let final: UInt8 = offset + n >= bytes.count ? 1 : 0
            out.append(final)
            out.append(contentsOf: [UInt8(n & 0xff), UInt8(n >> 8), UInt8(~n & 0xff), UInt8((~n >> 8) & 0xff)])
            out.append(contentsOf: bytes[offset..<offset + n])
            offset += n
        } while offset < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        out.append(be32(b << 16 | a))
        return out
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffffffff
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffffffff
    }
}

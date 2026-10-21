// InputImage.swift — reading `.lfi` / `.pfm`, the built-in synthetic frame, and the
// area-average downsample that runs before any render. Format and colour convention are
// documented in main.swift's header.

import Foundation
import LumenCore

enum InputError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): return m }
    }
}

enum InputImage {

    static func load(path: String) throws -> ImageBuffer {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw InputError.message("cannot read input '\(path)'")
        }
        let lower = path.lowercased()
        if lower.hasSuffix(".pfm") { return try decodePFM(data, path: path) }
        if lower.hasSuffix(".tif") || lower.hasSuffix(".tiff") {
            throw InputError.message("TIFF input is not supported; convert to .lfi "
                + "(see scripts/proof/make_test_lfi.py for the writer)")
        }
        return try decodeLFI(data, path: path)
    }

    // MARK: LFI

    static func decodeLFI(_ data: Data, path: String) throws -> ImageBuffer {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0] == 0x4C, bytes[1] == 0x46, bytes[2] == 0x49,
              bytes[3] == 0x31 else {
            throw InputError.message("'\(path)' is not an LFI1 file (bad magic)")
        }
        func u32(_ o: Int) -> Int {
            Int(UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16
                | UInt32(bytes[o + 3]) << 24)
        }
        let width = u32(4), height = u32(8), channels = u32(12)
        guard width > 0, height > 0 else {
            throw InputError.message("'\(path)': empty extent \(width)x\(height)")
        }
        guard channels == 3 else {
            throw InputError.message("'\(path)': channels = \(channels), LFI1 requires 3")
        }
        let need = 16 + width * height * 3 * 4
        guard bytes.count >= need else {
            throw InputError.message("'\(path)': truncated (\(bytes.count) bytes, "
                + "need \(need) for \(width)x\(height))")
        }
        var pixels = [Float](repeating: 1, count: width * height * 4)
        bytes.withUnsafeBufferPointer { raw in
            var o = 16
            for i in 0..<(width * height) {
                for c in 0..<3 {
                    let bits = UInt32(raw[o]) | UInt32(raw[o + 1]) << 8
                        | UInt32(raw[o + 2]) << 16 | UInt32(raw[o + 3]) << 24
                    pixels[i * 4 + c] = Float(bitPattern: bits)
                    o += 4
                }
            }
        }
        return ImageBuffer(width: width, height: height, pixels: sanitized(pixels))
    }

    static func encodeLFI(_ image: ImageBuffer) -> Data {
        var out = Data("LFI1".utf8)
        func put(_ v: UInt32) {
            out.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                                    UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }
        put(UInt32(image.width)); put(UInt32(image.height)); put(3)
        out.reserveCapacity(16 + image.count * 12)
        for i in 0..<image.count {
            for c in 0..<3 { put(image.pixels[i * 4 + c].bitPattern) }
        }
        return out
    }

    // MARK: PFM

    static func decodePFM(_ data: Data, path: String) throws -> ImageBuffer {
        let bytes = [UInt8](data)
        var cursor = 0
        func token() -> String {
            while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x0A
                    || bytes[cursor] == 0x0D || bytes[cursor] == 0x09 { cursor += 1 }
            let start = cursor
            while cursor < bytes.count, !(bytes[cursor] == 0x20 || bytes[cursor] == 0x0A
                    || bytes[cursor] == 0x0D || bytes[cursor] == 0x09) { cursor += 1 }
            return String(decoding: bytes[start..<cursor], as: UTF8.self)
        }
        guard token() == "PF" else {
            throw InputError.message("'\(path)': only colour PFM (\"PF\") is supported")
        }
        guard let width = Int(token()), let height = Int(token()),
              let scale = Double(token()), width > 0, height > 0 else {
            throw InputError.message("'\(path)': malformed PFM header")
        }
        cursor += 1   // the single whitespace byte after the scale
        let little = scale < 0
        guard bytes.count >= cursor + width * height * 12 else {
            throw InputError.message("'\(path)': truncated PFM")
        }
        var pixels = [Float](repeating: 1, count: width * height * 4)
        var o = cursor
        for row in 0..<height {
            let y = height - 1 - row          // PFM stores bottom row first
            for x in 0..<width {
                for c in 0..<3 {
                    let b0 = UInt32(bytes[o]), b1 = UInt32(bytes[o + 1])
                    let b2 = UInt32(bytes[o + 2]), b3 = UInt32(bytes[o + 3])
                    let bits = little ? (b0 | b1 << 8 | b2 << 16 | b3 << 24)
                                      : (b3 | b2 << 8 | b1 << 16 | b0 << 24)
                    pixels[(y * width + x) * 4 + c] = Float(bitPattern: bits)
                    o += 4
                }
            }
        }
        return ImageBuffer(width: width, height: height, pixels: sanitized(pixels))
    }

    /// A NaN or infinity in the input is a broken file, not a colour; zero it rather
    /// than let it poison every spatial stage it touches.
    private static func sanitized(_ p: [Float]) -> [Float] {
        var out = p
        for i in 0..<out.count where !out[i].isFinite { out[i] = 0 }
        return out
    }

    // MARK: Downsample

    /// Exact area-average resample to `longEdge` (never upsamples). Separable: each
    /// output pixel is the coverage-weighted mean of the input pixels its footprint
    /// overlaps, so a non-integer ratio does not alias the way point sampling would and
    /// does not blur the way bilinear would.
    static func downsample(_ image: ImageBuffer, longEdge: Int) -> ImageBuffer {
        let long = Swift.max(image.width, image.height)
        guard longEdge > 0, long > longEdge else { return image }
        let s = Double(longEdge) / Double(long)
        let w = Swift.max(1, Int((Double(image.width) * s).rounded()))
        let h = Swift.max(1, Int((Double(image.height) * s).rounded()))
        let horizontal = resampleAxis(image.pixels, width: image.width,
                                      height: image.height, newLength: w, alongX: true)
        let both = resampleAxis(horizontal, width: w, height: image.height,
                                newLength: h, alongX: false)
        return ImageBuffer(width: w, height: h, pixels: both)
    }

    private static func weights(from n: Int, to m: Int) -> [[(Int, Float)]] {
        let ratio = Double(n) / Double(m)
        return (0..<m).map { i in
            let a = Double(i) * ratio, b = Double(i + 1) * ratio
            var taps: [(Int, Float)] = []
            var j = Int(a.rounded(.down))
            while Double(j) < b && j < n {
                let lo = Swift.max(a, Double(j)), hi = Swift.min(b, Double(j + 1))
                if hi > lo { taps.append((j, Float((hi - lo) / ratio))) }
                j += 1
            }
            return taps
        }
    }

    private static func resampleAxis(_ src: [Float], width: Int, height: Int,
                                     newLength: Int, alongX: Bool) -> [Float] {
        let n = alongX ? width : height
        let taps = weights(from: n, to: newLength)
        let outW = alongX ? newLength : width
        let outH = alongX ? height : newLength
        var out = [Float](repeating: 1, count: outW * outH * 4)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                let dp = d.baseAddress!
                DispatchQueue.concurrentPerform(iterations: outH) { y in
                    for x in 0..<outW {
                        var r: Float = 0, g: Float = 0, b: Float = 0
                        for (j, wgt) in taps[alongX ? x : y] {
                            let si = alongX ? (y * width + j) * 4 : (j * width + x) * 4
                            r += s[si] * wgt; g += s[si + 1] * wgt; b += s[si + 2] * wgt
                        }
                        let di = (y * outW + x) * 4
                        dp[di] = r; dp[di + 1] = g; dp[di + 2] = b; dp[di + 3] = 1
                    }
                }
            }
        }
        return out
    }

    // MARK: Synthetic test frame

    /// The frame scripts/proof/make_test_lfi.py writes, for a machine without numpy:
    /// a smooth log ramp −10…+4 EV about mid-grey (top 30%), 15 one-stop grey steps
    /// (next 15%), and a 6×4 ColorChecker-like patch chart in the remainder. Values are
    /// scene-linear Rec.2020 at camera-reference white balance (neutrals neutral).
    static func synth(width: Int = 960, height: Int = 540) -> ImageBuffer {
        let toWorking = RGBColorSpace.srgb.matrix(to: .rec2020)
        func srgbDecode(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let checker: [(Double, Double, Double)] = [
            (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67),
            (133, 128, 177), (103, 189, 170), (214, 126, 44), (80, 91, 166),
            (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
            (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31),
            (187, 86, 149), (8, 133, 161), (243, 243, 242), (200, 200, 200),
            (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
        ]
        let rampEnd = Int(Double(height) * 0.30)
        let stepEnd = Int(Double(height) * 0.45)
        var img = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                let c: RGB
                if y < rampEnd {
                    c = RGB(gray: 0.18 * pow(2, -10 + 14 * u))
                } else if y < stepEnd {
                    let step = Swift.min(Int(u * 15), 14)
                    c = RGB(gray: 0.18 * pow(2, Double(step - 10)))
                } else {
                    let v = Double(y - stepEnd) / Double(height - stepEnd)
                    let col = Swift.min(Int(u * 6), 5), row = Swift.min(Int(v * 4), 3)
                    let fx = u * 6 - Double(col), fy = v * 4 - Double(row)
                    if fx < 0.06 || fx > 0.94 || fy < 0.06 || fy > 0.94 {
                        c = RGB(gray: 0.02)
                    } else {
                        let p = checker[row * 6 + col]
                        let lin = RGB(srgbDecode(p.0 / 255), srgbDecode(p.1 / 255),
                                      srgbDecode(p.2 / 255))
                        // Exposed so the chart's 18% grey lands on scene mid-grey.
                        c = toWorking.apply(lin) * (0.18 / srgbDecode(122.0 / 255))
                    }
                }
                img[x, y] = c
            }
        }
        return img
    }
}

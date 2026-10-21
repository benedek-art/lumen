// OutputEncode.swift — display-linear (working primaries) → the 8-bit file the app
// writes, and a PNG encoder that needs nothing but Foundation.
//
// The encode is `PipelineRenderer.cgImage(from:)` (primaries matrix, clamp, sRGB
// transfer, round(v·255)) preceded by `PipelineRenderer.applyDither`'s ordered dither
// (one output code of 8×8 Bayer, added in the WORKING primaries before the encoder's
// conversion, which is the approximation that function states). Display P3 shares
// sRGB's transfer curve and differs only in the matrix and the tag.

import Foundation
import LumenCore

enum OutputSpace: String {
    case srgb, p3

    var space: RGBColorSpace { self == .srgb ? .srgb : .displayP3 }
    var displayName: String { self == .srgb ? "sRGB" : "Display P3" }
}

/// One rendered tile, encoded, with the undithered display-linear output-space values
/// the metrics are computed from.
struct EncodedImage {
    let width: Int
    let height: Int
    /// RGB8 interleaved, what goes into the PNG.
    var bytes: [UInt8]
    /// Clamped display-linear RGB in the OUTPUT space, undithered, interleaved.
    let linear: [Float]
    /// Undithered 8-bit codes (for clip/crush counting), interleaved RGB.
    let codes: [UInt8]
}

enum OutputEncode {

    static func encode(_ image: ImageBuffer, space: OutputSpace,
                       dither: Bool) -> EncodedImage {
        let m = RGBColorSpace.rec2020.matrix(to: space.space).m
        let m00 = Float(m[0][0]), m01 = Float(m[0][1]), m02 = Float(m[0][2])
        let m10 = Float(m[1][0]), m11 = Float(m[1][1]), m12 = Float(m[1][2])
        let m20 = Float(m[2][0]), m21 = Float(m[2][1]), m22 = Float(m[2][2])
        let n = image.count
        var bytes = [UInt8](repeating: 0, count: n * 3)
        var codes = [UInt8](repeating: 0, count: n * 3)
        var linear = [Float](repeating: 0, count: n * 3)
        let w = image.width
        // The Bayer cell's offsets, once.
        let side = Dither.matrixSide
        var offsets = [Double](repeating: 0, count: side * side)
        for y in 0..<side { for x in 0..<side { offsets[y * side + x] = Dither.offset(x: x, y: y) } }

        image.pixels.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBufferPointer { bp in
                codes.withUnsafeMutableBufferPointer { cp in
                    linear.withUnsafeMutableBufferPointer { lp in
                        let b = bp.baseAddress!, c = cp.baseAddress!, l = lp.baseAddress!
                        DispatchQueue.concurrentPerform(iterations: image.height) { y in
                            for x in 0..<w {
                                let i = y * w + x
                                let r0 = src[i * 4], g0 = src[i * 4 + 1], b0 = src[i * 4 + 2]
                                // Undithered path: the metrics' values.
                                let (lr, lg, lb) = convert(r0, g0, b0, m00, m01, m02, m10,
                                                           m11, m12, m20, m21, m22)
                                l[i * 3] = lr; l[i * 3 + 1] = lg; l[i * 3 + 2] = lb
                                c[i * 3] = code(lr); c[i * 3 + 1] = code(lg)
                                c[i * 3 + 2] = code(lb)
                                if dither {
                                    let o = offsets[(y % side) * side + (x % side)]
                                    func d(_ v: Float) -> Float {
                                        let dv = Double(v)
                                        guard dv.isFinite else { return v }
                                        let step = Dither.codeStep(dv, transfer: .srgb,
                                                                   levels: 256)
                                        return Float(dv + o * step)
                                    }
                                    let (dr, dg, db) = convert(d(r0), d(g0), d(b0), m00, m01,
                                                               m02, m10, m11, m12, m20, m21,
                                                               m22)
                                    b[i * 3] = code(dr); b[i * 3 + 1] = code(dg)
                                    b[i * 3 + 2] = code(db)
                                } else {
                                    b[i * 3] = c[i * 3]; b[i * 3 + 1] = c[i * 3 + 1]
                                    b[i * 3 + 2] = c[i * 3 + 2]
                                }
                            }
                        }
                    }
                }
            }
        }
        return EncodedImage(width: image.width, height: image.height, bytes: bytes,
                            linear: linear, codes: codes)
    }

    @inline(__always)
    private static func convert(_ r: Float, _ g: Float, _ b: Float,
                                _ m00: Float, _ m01: Float, _ m02: Float,
                                _ m10: Float, _ m11: Float, _ m12: Float,
                                _ m20: Float, _ m21: Float, _ m22: Float)
        -> (Float, Float, Float) {
        func sat(_ v: Float) -> Float { v.isFinite ? Swift.min(Swift.max(v, 0), 1) : 0 }
        return (sat(m00 * r + m01 * g + m02 * b),
                sat(m10 * r + m11 * g + m12 * b),
                sat(m20 * r + m21 * g + m22 * b))
    }

    /// sRGB encode + round(v·255), the IEC quantiser `PipelineRenderer.byte` uses.
    /// The transfer function is evaluated, not tabulated: a table is not exact in the toe.
    @inline(__always)
    static func code(_ linear: Float) -> UInt8 {
        let e = TransferFunction.srgb.encode(Double(linear))
        guard e.isFinite else { return 0 }
        return UInt8(Swift.min(Swift.max((e * 255).rounded(), 0), 255))
    }
}

// MARK: - PNG

/// PNG writer: adaptive per-row filter, zlib stream of LZ77 + fixed-Huffman DEFLATE.
/// Written here because Foundation on Linux exposes no compressor, and the stored-block
/// writer the proof tests use makes a 1600 px render 5 MB — too heavy for an agent's
/// image viewer to open in bulk.
enum PNG {

    static func encode(width: Int, height: Int, rgb: [UInt8], space: OutputSpace) -> Data {
        let stride = width * 3
        var raw = [UInt8]()
        raw.reserveCapacity(height * (stride + 1))
        var prev = [UInt8](repeating: 0, count: stride)
        var cur = [UInt8](repeating: 0, count: stride)
        var candidates = [[UInt8]](repeating: [UInt8](repeating: 0, count: stride), count: 5)
        for y in 0..<height {
            for i in 0..<stride { cur[i] = rgb[y * stride + i] }
            var best = 0, bestCost = Int.max
            for f in 0..<5 {
                var cost = 0
                for i in 0..<stride {
                    let a = i >= 3 ? Int(cur[i - 3]) : 0
                    let b = Int(prev[i])
                    let c = i >= 3 ? Int(prev[i - 3]) : 0
                    let x = Int(cur[i])
                    let pred: Int
                    switch f {
                    case 0: pred = 0
                    case 1: pred = a
                    case 2: pred = b
                    case 3: pred = (a + b) / 2
                    default:
                        let p = a + b - c
                        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                        pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                    }
                    let v = UInt8(truncatingIfNeeded: x - pred)
                    candidates[f][i] = v
                    cost += v < 128 ? Int(v) : 256 - Int(v)
                }
                if cost < bestCost { bestCost = cost; best = f }
            }
            raw.append(UInt8(best))
            raw.append(contentsOf: candidates[best])
            swap(&prev, &cur)
        }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(be32(UInt32(width)))
        ihdr.append(be32(UInt32(height)))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])
        png.append(chunk("IHDR", ihdr))
        switch space {
        case .srgb:
            png.append(chunk("sRGB", Data([0])))              // perceptual intent
        case .p3:
            // cICP (PNG 3rd edition): primaries 12 = P3-D65, transfer 13 = sRGB,
            // matrix 0 (RGB), full range.
            png.append(chunk("cICP", Data([12, 13, 0, 1])))
        }
        png.append(chunk("IDAT", Data(zlib(raw))))
        png.append(chunk("IEND", Data()))
        return png
    }

    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
              UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
    }

    private static func chunk(_ type: String, _ payload: Data) -> Data {
        var out = be32(UInt32(payload.count))
        let body = Data(type.utf8) + payload
        out.append(body)
        out.append(be32(crc32(body)))
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < data.count {
            let end = Swift.min(i + 5552, data.count)
            while i < end { a &+= UInt32(data[i]); b &+= a; i += 1 }
            a %= 65521; b %= 65521
        }
        return (b << 16) | a
    }

    // MARK: DEFLATE (fixed Huffman, LZ77 with hash chains)

    private struct BitWriter {
        var out: [UInt8] = []
        var acc: UInt64 = 0
        var count = 0
        mutating func put(_ bits: UInt32, _ n: Int) {      // LSB-first
            acc |= UInt64(bits) << UInt64(count)
            count += n
            while count >= 8 { out.append(UInt8(acc & 0xFF)); acc >>= 8; count -= 8 }
        }
        mutating func putHuffman(_ code: UInt32, _ n: Int) {   // MSB-first code
            var rev: UInt32 = 0
            for i in 0..<n where code & (1 << UInt32(i)) != 0 { rev |= 1 << UInt32(n - 1 - i) }
            put(rev, n)
        }
        mutating func flush() { if count > 0 { out.append(UInt8(acc & 0xFF)); acc = 0; count = 0 } }
    }

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23,
                                            27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131,
                                            163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                             3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97,
                                          129, 193, 257, 385, 513, 769, 1025, 1537, 2049,
                                          3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                           7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    /// length → (symbol index 0…28), precomputed.
    private static let lengthSymbol: [Int] = {
        var t = [Int](repeating: 0, count: 259)
        for len in 3...258 {
            var s = 28
            while lengthBase[s] > len { s -= 1 }
            t[len] = s
        }
        return t
    }()

    private static func literal(_ w: inout BitWriter, _ v: Int) {
        if v < 144 { w.putHuffman(UInt32(0x30 + v), 8) }
        else if v < 256 { w.putHuffman(UInt32(0x190 + v - 144), 9) }
        else if v < 280 { w.putHuffman(UInt32(v - 256), 7) }
        else { w.putHuffman(UInt32(0xC0 + v - 280), 8) }
    }

    static func deflate(_ data: [UInt8]) -> [UInt8] {
        var w = BitWriter()
        w.out.reserveCapacity(data.count / 3)
        w.put(1, 1)          // BFINAL
        w.put(1, 2)          // BTYPE = 01, fixed Huffman
        let n = data.count
        let window = 32768
        let hashBits = 15
        let hashSize = 1 << hashBits
        var head = [Int32](repeating: -1, count: hashSize)
        var prev = [Int32](repeating: -1, count: window)
        let maxChain = 48
        func hash(_ i: Int) -> Int {
            let h = (UInt32(data[i]) << 10) ^ (UInt32(data[i + 1]) << 5) ^ UInt32(data[i + 2])
            return Int((h &* 2654435761) >> UInt32(32 - hashBits))
        }
        func insert(_ i: Int) {
            guard i + 2 < n else { return }
            let h = hash(i)
            prev[i & (window - 1)] = head[h]
            head[h] = Int32(i)
        }
        var i = 0
        data.withUnsafeBufferPointer { d in
            while i < n {
                var bestLen = 0, bestDist = 0
                if i + 2 < n {
                    var cand = Int(head[hash(i)])
                    var chain = 0
                    let limit = Swift.min(258, n - i)
                    while cand >= 0 && i - cand <= window - 1 && chain < maxChain {
                        if d[cand + bestLen] == d[i + bestLen] || bestLen == 0 {
                            var l = 0
                            while l < limit && d[cand + l] == d[i + l] { l += 1 }
                            if l > bestLen { bestLen = l; bestDist = i - cand; if l == limit { break } }
                        }
                        let next = Int(prev[cand & (window - 1)])
                        if next >= cand { break }
                        cand = next
                        chain += 1
                    }
                }
                if bestLen >= 3 {
                    let s = lengthSymbol[bestLen]
                    literal(&w, 257 + s)
                    if lengthExtra[s] > 0 { w.put(UInt32(bestLen - lengthBase[s]), lengthExtra[s]) }
                    var ds = 29
                    while distBase[ds] > bestDist { ds -= 1 }
                    w.putHuffman(UInt32(ds), 5)
                    if distExtra[ds] > 0 { w.put(UInt32(bestDist - distBase[ds]), distExtra[ds]) }
                    for k in 0..<bestLen { insert(i + k) }
                    i += bestLen
                } else {
                    literal(&w, Int(d[i]))
                    insert(i)
                    i += 1
                }
            }
        }
        literal(&w, 256)     // end of block
        w.flush()
        return w.out
    }

    static func zlib(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        out.append(contentsOf: deflate(raw))
        let a = adler32(raw)
        out.append(contentsOf: [UInt8(a >> 24), UInt8((a >> 16) & 0xFF),
                                UInt8((a >> 8) & 0xFF), UInt8(a & 0xFF)])
        return out
    }
}

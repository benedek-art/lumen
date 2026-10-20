// RawDenoisePacking.swift
// The CFA <-> packed-Bayer layout and the DN normalization the AI raw denoiser was
// trained on — a byte-for-byte port of Denoise/lumen_denoise/raw.py (`load`'s
// normalization, `pack`, `unpack`), prepare.py (`to_rggb`, `from_rggb`) and the
// re-quantization in infer.py `Engine.denoise_file`.
//
// Why exact: the network only ever saw RGGB-ordered planes at (dn - black)/(white -
// mean black). A plane swapped on a BGGR body, or a black level subtracted per colour
// instead of per 2x2 position, is not a small error — the model would denoise the red
// plane with green statistics. Tests/LumenCoreTests/RawDenoisePackingTests.swift pins
// every pattern against literals printed by Denoise/scripts/gen_swift_fixtures_packing.py,
// which calls the real Python functions.
//
// Layouts: a CFA is row-major `height * width`. Packed planes are planar channel-major
// `4 * (height/2) * (width/2)`, channel order R, G1, G2, B after reordering (the same
// convention RawDenoiseStdMap and RawDenoiseTiler consume). "Tile order" means the 2x2
// positions (0,0), (0,1), (1,0), (1,1) of the CFA's top-left quad, as raw.py uses it.

import Foundation

/// The colour of the CFA's top-left 2x2 quad, read row by row (raw.py's `pattern`).
public enum CFAPattern: String, Sendable, Codable, CaseIterable {
    case rggb, bggr, grbg, gbrg

    /// Accepts raw.py's spelling ("RGGB") as well as the lowercase wire form.
    public init?(string: String) {
        self.init(rawValue: string.lowercased())
    }

    /// prepare.py `_TO_RGGB`: RGGB plane `i` is tile-order plane `toRGGB[i]`.
    var toRGGB: [Int] {
        switch self {
        case .rggb: return [0, 1, 2, 3]
        case .bggr: return [3, 1, 2, 0]
        case .grbg: return [1, 0, 3, 2]
        case .gbrg: return [2, 0, 3, 1]
        }
    }
}

public enum RawDenoisePacking {

    /// raw.pack then prepare.to_rggb. An odd trailing row/column is dropped (the
    /// network needs whole 2x2 quads); `unpack` leaves those pixels untouched.
    public static func pack(cfa: [Float], width: Int, height: Int,
                            pattern: CFAPattern) -> (planes: [Float], width: Int, height: Int) {
        precondition(cfa.count == width * height, "cfa must be height*width")
        let pw = width / 2, ph = height / 2
        let plane = pw * ph
        var planes = [Float](repeating: 0, count: 4 * plane)
        for (dst, src) in pattern.toRGGB.enumerated() {
            let dy = src >> 1, dx = src & 1
            for y in 0..<ph {
                let row = (2 * y + dy) * width + dx
                let out = dst * plane + y * pw
                for x in 0..<pw { planes[out + x] = cfa[row + 2 * x] }
            }
        }
        return (planes, pw, ph)
    }

    /// prepare.from_rggb then raw.unpack, written into `cfa` the way infer.py does
    /// (`cfa[:h2, :w2] = ...`): only the even-cropped `2*height x 2*width` region is
    /// overwritten, so an odd sensor's last row/column keeps its original samples.
    public static func unpack(planes: [Float], width: Int, height: Int, pattern: CFAPattern,
                              into cfa: inout [Float], cfaWidth: Int, cfaHeight: Int) {
        let plane = width * height
        precondition(planes.count == 4 * plane, "planes must be 4*height*width")
        precondition(cfa.count == cfaWidth * cfaHeight, "cfa must be cfaHeight*cfaWidth")
        precondition(2 * width <= cfaWidth && 2 * height <= cfaHeight, "packed larger than CFA")
        for (src, pos) in pattern.toRGGB.enumerated() {
            let dy = pos >> 1, dx = pos & 1
            for y in 0..<height {
                let row = (2 * y + dy) * cfaWidth + dx
                let inp = src * plane + y * width
                for x in 0..<width { cfa[row + 2 * x] = planes[inp + x] }
            }
        }
    }

    /// Convenience: unpack into a fresh `2*height x 2*width` CFA.
    public static func unpack(planes: [Float], width: Int, height: Int,
                              pattern: CFAPattern) -> [Float] {
        var cfa = [Float](repeating: 0, count: 4 * width * height)
        unpack(planes: planes, width: width, height: height, pattern: pattern,
               into: &cfa, cfaWidth: 2 * width, cfaHeight: 2 * height)
        return cfa
    }

    /// raw.load's normalization: `(dn - black[pos]) / (white - mean(black))`, in Float32
    /// like numpy. `blackPerTile` is per 2x2 POSITION (tile order), not per colour —
    /// two greens may carry different blacks. One shared scale, not one per position:
    /// that is what the model was trained on. Values go slightly negative below black
    /// and are deliberately not clamped (clipping would bias the shadows' noise mean).
    public static func normalize(raw: [UInt16], width: Int, height: Int,
                                 blackPerTile: [Float], whiteLevel: Float) -> [Float] {
        precondition(raw.count == width * height && blackPerTile.count == 4)
        let scale = whiteLevel - meanBlack(blackPerTile)
        var out = [Float](repeating: 0, count: raw.count)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                out[i] = (Float(raw[i]) - blackPerTile[(y & 1) * 2 + (x & 1)]) / scale
            }
        }
        return out
    }

    /// infer.py's inverse: `clip(round(cfa * scale + black), 0, white)` as UInt16, with
    /// round-half-to-even like np.round. Evaluated in Double: `scale` there is a numpy
    /// float64, which under NumPy 2 promotion lifts the whole expression to float64.
    public static func denormalize(cfa: [Float], width: Int, height: Int,
                                   blackPerTile: [Float], whiteLevel: Float) -> [UInt16] {
        precondition(cfa.count == width * height && blackPerTile.count == 4)
        let white = Double(whiteLevel)
        let scale = white - blackPerTile.reduce(0.0) { $0 + Double($1) } / 4
        var out = [UInt16](repeating: 0, count: cfa.count)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let v = (Double(cfa[i]) * scale + Double(blackPerTile[(y & 1) * 2 + (x & 1)]))
                    .rounded(.toNearestOrEven)
                // NaN would trap the UInt16 conversion; numpy casts it to 0 in practice.
                out[i] = v.isNaN ? 0 : UInt16(min(max(v, 0), white))
            }
        }
        return out
    }

    /// np.mean over a float32 array of 4: summed and divided in Float32.
    private static func meanBlack(_ b: [Float]) -> Float {
        (b[0] + b[1] + b[2] + b[3]) / 4
    }
}

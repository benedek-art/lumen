// RawDenoiseStdMap.swift
// The per-pixel noise-std map the raw denoiser is conditioned on: a port of
// Denoise/lumen_denoise/train.py `std_map`:
//
//     sig = F.avg_pool2d(noisy.mean(1, keepdim=True).clamp(min=0), 3, 1, 1)
//     return torch.sqrt(K * sig + r)
//
// Two details that are easy to "fix" and must not be:
//  - The signal estimate comes from the NOISY image itself, because that is all inference
//    has; training did the same, so the network learned to expect that bias.
//  - avg_pool2d's default count_include_pad=True: border windows are zero-padded and still
//    divided by 9, so the map dips at the image (and tile) edges. infer.py computes the
//    map on each reflect-padded tile, and the model saw exactly that dip in training.
//
// Precision: this matches train.py's std_map in Float32, the precision the model was
// trained with — NOT infer.py, which builds the map under `.half()`. At ISO <= 100 the
// fp16 map lands in fp16 subnormals and reads ~5-8% low (ILCE-7M4 ISO 50, flat 0.001
// tile: 3.45e-4 fp16 vs 3.66e-4 fp32). Lumen deliberately follows the training
// precision, so do not "match infer.py" by rounding through Float16.
//
// Accumulates in Double and rounds once to Float; torch sums in float32, and the
// difference is far inside the 1e-6 test tolerance.

import Foundation

public enum RawDenoiseStdMap {

    /// `packed`: planar, channel-major `4·height·width` (the RGGB planes, normalised).
    /// Returns `height·width` std values.
    public static func compute(packed: [Float], width: Int, height: Int,
                               params: RawDenoiseNoiseParams) -> [Float] {
        let plane = width * height
        precondition(width >= 0 && height >= 0 && packed.count == 4 * plane,
                     "packed must hold 4·height·width values")
        if plane == 0 { return [] }

        // Channel mean, clamped at zero (black-level noise makes means negative).
        var sig = [Double](repeating: 0, count: plane)
        for i in 0..<plane {
            let m = (Double(packed[i]) + Double(packed[plane + i])
                     + Double(packed[2 * plane + i]) + Double(packed[3 * plane + i])) / 4
            sig[i] = Swift.max(m, 0)
        }

        // Separable 3x3 box sum with zero padding, then /9 everywhere (border included).
        var rows = [Double](repeating: 0, count: plane)
        for y in 0..<height {
            let r = y * width
            for x in 0..<width {
                var s = sig[r + x]
                if x > 0 { s += sig[r + x - 1] }
                if x + 1 < width { s += sig[r + x + 1] }
                rows[r + x] = s
            }
        }
        var out = [Float](repeating: 0, count: plane)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                var s = rows[i]
                if y > 0 { s += rows[i - width] }
                if y + 1 < height { s += rows[i + width] }
                out[i] = Float((params.k * (s / 9) + params.readVar).squareRoot())
            }
        }
        return out
    }
}

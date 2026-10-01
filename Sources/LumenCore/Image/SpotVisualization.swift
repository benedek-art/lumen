// SpotVisualization.swift
// Visualize Spots (docs/09 §Dust Removal: "High-contrast inverted-edge view that makes
// dust jump out — LR's diagnostic, cloned"). While the Heal tool is armed the loupe can
// swap the photograph for this view, so sensor dust — a soft, low-contrast blob that is
// invisible in a blue sky at fit size — reads as a black ring on white.
//
// A WAY OF LOOKING, NOT AN EDIT. It is computed from the bytes the loupe is already
// showing (the display proxy, sRGB-encoded) and drawn as an overlay, exactly like the
// clipping overlay. Nothing here is in the recipe, the render graph or the export path,
// and `SpotVisualizationTests` scans the renderers to keep it that way: a diagnostic
// that leaked into a file would be a defect nobody could see until it was printed.
//
// THE FILTER is a band-pass on luma: the difference of two box means, a fine one
// (`fineRadius`) that suppresses pixel noise and a coarse one (`coarseRadius`) that
// stands in for the local background. Its magnitude is what is drawn, inverted —
// white where the picture is locally flat, black where something stands off its
// surroundings. A smooth gradient (sky, vignetting) has equal box means at every scale,
// so it vanishes; a dust bunny does not.
//
// Luma is taken on the ENCODED values, so a difference means about the same thing to
// the eye in shadow and in highlight — which is the scale a speck is judged on.
//
// THE THRESHOLD (0…100, default 50) sets how faint a difference turns fully black:
// higher shows fainter dust. The mapping is geometric — `cutoff = 0.06 · 0.03^t` — so
// each step of the slider is the same RATIO of contrast, from 0.06 (only plain
// structure) at 0 to 0.0018 (the faintest dust, and the noise beside it) at 100. At the
// default, a soft speck 2% darker than the sky around it turns black.

import Foundation

public enum SpotVisualization {

    public static let defaultThreshold: Double = 50
    /// Box radii, in pixels of the buffer the view is computed on.
    public static let fineRadius = 1
    public static let coarseRadius = 6

    /// The band-pass magnitude that turns fully black at `threshold`.
    public static func cutoff(threshold: Double) -> Double {
        let t = Num.clamp(threshold.isFinite ? threshold : defaultThreshold, 0, 100) / 100
        return 0.06 * pow(0.03, t)
    }

    /// Luma of sRGB-encoded RGBA bytes, row-major, top-down — the layout `PixelSampler`
    /// holds. Nil when the bytes do not cover the frame.
    public static func luma(rgba bytes: [UInt8], width: Int, height: Int) -> [Double]? {
        guard width > 0, height > 0, bytes.count >= width * height * 4 else { return nil }
        var out = [Double](repeating: 0, count: width * height)
        for p in 0..<(width * height) {
            let i = p * 4
            out[p] = (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1])
                      + 0.0722 * Double(bytes[i + 2])) / 255
        }
        return out
    }

    /// The view: one grey byte per pixel, 255 where the picture is locally flat, 0 where
    /// its band-pass contrast reaches the threshold's cutoff.
    public static func render(luma: [Double], width: Int, height: Int,
                              threshold: Double = defaultThreshold) -> [UInt8] {
        guard width > 0, height > 0, luma.count >= width * height else { return [] }
        let fine = boxMean(luma, width: width, height: height, radius: fineRadius)
        let coarse = boxMean(luma, width: width, height: height, radius: coarseRadius)
        let limit = cutoff(threshold: threshold)
        var out = [UInt8](repeating: 255, count: width * height)
        for p in 0..<(width * height) {
            let contrast = Swift.min(abs(fine[p] - coarse[p]) / limit, 1)
            out[p] = UInt8(((1 - contrast) * 255).rounded())
        }
        return out
    }

    /// The mean over a (2r+1)² window, the window clamped to the frame (so it shrinks at
    /// an edge rather than inventing pixels). A summed-area table: O(1) per pixel at any
    /// radius.
    static func boxMean(_ values: [Double], width: Int, height: Int, radius: Int) -> [Double] {
        let stride = width + 1
        var table = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var row = 0.0
            for x in 0..<width {
                row += values[y * width + x]
                table[(y + 1) * stride + x + 1] = table[y * stride + x + 1] + row
            }
        }
        var out = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let y0 = Swift.max(y - radius, 0), y1 = Swift.min(y + radius + 1, height)
            for x in 0..<width {
                let x0 = Swift.max(x - radius, 0), x1 = Swift.min(x + radius + 1, width)
                let sum = table[y1 * stride + x1] - table[y0 * stride + x1]
                    - table[y1 * stride + x0] + table[y0 * stride + x0]
                out[y * width + x] = sum / Double((x1 - x0) * (y1 - y0))
            }
        }
        return out
    }
}

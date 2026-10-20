// RawDenoiseTiling.swift
// The tile walk, reflect padding, feathered seams and strength blend that wrap the raw
// denoiser's network — a line-for-line port of `Engine.denoise_packed` and the strength
// step of `denoise_file` in Denoise/lumen_denoise/infer.py.
//
// Why a port and not "a reasonable tiler": the model was trained and its quality judged
// through exactly that Python loop. A Swift tiler that steps, clamps or feathers
// differently produces a different picture from the same network — seams in other
// places, different weighting at the frame edge — and then "Lumen matches the standalone
// engine" stops being a statement anyone can check. So the quirks are kept on purpose and
// pinned by golden fixtures generated from the REAL Python function
// (Denoise/scripts/gen_swift_fixtures_tiling.py):
//   · the loop runs `range(0, max(n - 2·ov, 1), tile - 2·ov)` and then CLAMPS the origin
//     to `n - tile`, so the last two tiles can overlap by far more than `ov` (both are
//     accumulated; normalising by Σweight makes that harmless);
//   · the feather ramp is applied only to a FULL-size tile; a tile cut short by the image
//     gets flat weight, and any side touching the image border gets weight 1 over `ov`;
//   · padding to a multiple of 16 is numpy `mode="reflect"` (mirror without repeating the
//     edge sample), bottom/right only, and the network sees the padded tile — which is
//     why the body below receives the padded tile and computes its own std map on it.
//
// Pure Swift, no platform framework: the Core ML runner in LumenPipeline supplies the
// body; everything else is testable on Linux.

import Foundation

/// The tiles `infer.py` visits for an image, in its visiting order (row-major: y outer,
/// x inner).
public struct RawDenoiseTilePlan: Sendable, Equatable {

    public struct Tile: Sendable, Equatable {
        /// Origin of the tile in the packed (half-resolution) image.
        public var y0: Int
        public var x0: Int
        /// Size of the un-padded tile: `min(tile, n - origin)`, numpy slice semantics.
        public var height: Int
        public var width: Int
        /// Reflect padding added bottom/right so the network sees multiples of 16 (the
        /// UNet downsamples four times).
        public var padBottom: Int
        public var padRight: Int

        public init(y0: Int, x0: Int, height: Int, width: Int, padBottom: Int, padRight: Int) {
            self.y0 = y0; self.x0 = x0
            self.height = height; self.width = width
            self.padBottom = padBottom; self.padRight = padRight
        }

        public var paddedHeight: Int { height + padBottom }
        public var paddedWidth: Int { width + padRight }
    }

    public let width: Int
    public let height: Int
    public let tileSize: Int
    public let overlap: Int
    public let tiles: [Tile]

    /// - Precondition: `overlap >= 1` and `tile > 2 * overlap`. Python divides by zero for
    ///   ov = 0 and raises on a zero `range` step (or silently visits nothing for a
    ///   negative one); failing loudly here is that contract, stated.
    public init(width: Int, height: Int, tile: Int = 1024, overlap: Int = 64) {
        precondition(overlap >= 1 && tile > 2 * overlap, "tile must exceed 2·overlap, overlap ≥ 1")
        precondition(width >= 0 && height >= 0)
        self.width = width; self.height = height
        self.tileSize = tile; self.overlap = overlap
        guard width > 0, height > 0 else { tiles = []; return }

        let step = tile - 2 * overlap
        var tiles: [Tile] = []
        // `stride(from:to:by:)` is Python's `range` for a positive step.
        for y in stride(from: 0, to: max(height - 2 * overlap, 1), by: step) {
            for x in stride(from: 0, to: max(width - 2 * overlap, 1), by: step) {
                let y0 = min(y, max(height - tile, 0))
                let x0 = min(x, max(width - tile, 0))
                let th = min(tile, height - y0)
                let tw = min(tile, width - x0)
                tiles.append(Tile(y0: y0, x0: x0, height: th, width: tw,
                                  padBottom: RawDenoiseTiler.padToMultiple(th),
                                  padRight: RawDenoiseTiler.padToMultiple(tw)))
            }
        }
        self.tiles = tiles
    }
}

public enum RawDenoiseTiler {

    /// The network's spatial granularity: four 2× downsamples.
    public static let alignment = 16

    /// Python's `(-n) % 16`.
    static func padToMultiple(_ n: Int) -> Int {
        (alignment - n % alignment) % alignment
    }

    // MARK: - Feathering

    /// Per-row and per-column blend weights for one tile, exactly as `infer.py` builds
    /// them; the tile's 2-D weight is their outer product.
    ///
    /// The ramp is `min(i + 1, ov) / ov`, so it never reaches zero — every covered pixel
    /// has a positive Σweight and the final division never leans on the 1e-6 floor.
    public static func featherWeights(tile: RawDenoiseTilePlan.Tile,
                                      imageWidth: Int, imageHeight: Int,
                                      tileSize: Int, overlap: Int) -> (wy: [Float], wx: [Float]) {
        func axis(origin: Int, length: Int, extent: Int) -> [Float] {
            var w: [Float]
            if length == tileSize {
                // min(ramp[i], ramp[::-1][i]) with ramp[i] = min(i+1, ov)/ov.
                w = (0..<length).map { i in
                    min(Float(min(i + 1, overlap)) / Float(overlap),
                        Float(min(length - i, overlap)) / Float(overlap))
                }
            } else {
                w = [Float](repeating: 1, count: length)
            }
            // Image borders get full weight: there is no neighbouring tile to blend with.
            // The bounds clamp like numpy `[:ov]` / `[-ov:]` when ov exceeds the length.
            if origin == 0 {
                for i in 0..<min(overlap, length) { w[i] = 1 }
            }
            if origin + length >= extent {
                for i in max(length - overlap, 0)..<length { w[i] = 1 }
            }
            return w
        }
        return (axis(origin: tile.y0, length: tile.height, extent: imageHeight),
                axis(origin: tile.x0, length: tile.width, extent: imageWidth))
    }

    // MARK: - Padding

    /// Bottom/right padding of channel-major planes with numpy `mode="reflect"`: the
    /// mirror excludes the edge sample (…c b a | b c…), and a pad longer than the axis
    /// keeps reflecting, i.e. the source index is periodic with period `2(n − 1)`. A
    /// length-1 axis repeats its only sample, as numpy does.
    public static func reflectPad(planes: [Float], channels: Int, height: Int, width: Int,
                                  padBottom: Int, padRight: Int) -> [Float] {
        precondition(planes.count == channels * height * width, "planes size mismatch")
        precondition(padBottom >= 0 && padRight >= 0)
        if padBottom == 0 && padRight == 0 { return planes }
        precondition(height > 0 && width > 0, "cannot reflect-pad an empty axis")
        let ph = height + padBottom, pw = width + padRight
        let rowIndex = (0..<ph).map { reflectIndex($0, count: height) }
        let colIndex = (0..<pw).map { reflectIndex($0, count: width) }
        var out = [Float](repeating: 0, count: channels * ph * pw)
        planes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for c in 0..<channels {
                    let sBase = c * height * width, dBase = c * ph * pw
                    for y in 0..<ph {
                        let sRow = sBase + rowIndex[y] * width
                        let dRow = dBase + y * pw
                        for x in 0..<pw { dst[dRow + x] = src[sRow + colIndex[x]] }
                    }
                }
            }
        }
        return out
    }

    static func reflectIndex(_ i: Int, count n: Int) -> Int {
        if i < n { return i }
        if n == 1 { return 0 }
        let period = 2 * (n - 1)
        let m = i % period
        return m < n ? m : period - m
    }

    // MARK: - Tiled run

    /// Runs `body` over every tile in plan order and blends the results — the Swift
    /// `denoise_packed`.
    ///
    /// `packed` is channel-major `channels × height × width` (the RGGB planes, so 4); the
    /// channel count is inferred from its size. `body` receives the reflect-padded tile
    /// (same layout, `paddedHeight × paddedWidth`) and must return as many values; only
    /// the top-left un-padded region of its output is used. The std map is the body's
    /// business because `infer.py` computes it on the PADDED tile. Only WHERE it is
    /// computed follows infer.py: its values must come from `RawDenoiseStdMap` in Float32
    /// (train.py's precision), not infer.py's fp16 map, which reads ~5-8% low at ISO <= 100.
    ///
    /// Accumulation is Float32 in numpy's order (weight = wy·wx, then o·weight, then
    /// ÷ max(Σweight, 1e-6)), so a deterministic body reproduces the Python output to a
    /// few ulps.
    public static func run(packed: [Float], width: Int, height: Int,
                           tile: Int = 1024, overlap: Int = 64,
                           body: ([Float], Int, Int) throws -> [Float]) rethrows -> [Float] {
        let plane = width * height
        guard plane > 0 else { return [] }
        precondition(packed.count % plane == 0 && packed.count > 0,
                     "packed size is not channels × height × width")
        let channels = packed.count / plane
        let plan = RawDenoiseTilePlan(width: width, height: height, tile: tile, overlap: overlap)

        var out = [Float](repeating: 0, count: packed.count)
        var wsum = [Float](repeating: 0, count: plane)

        for t in plan.tiles {
            // numpy `p[:, y0:y0+tile, x0:x0+tile]`.
            var cut = [Float](repeating: 0, count: channels * t.height * t.width)
            packed.withUnsafeBufferPointer { src in
                cut.withUnsafeMutableBufferPointer { dst in
                    for c in 0..<channels {
                        for y in 0..<t.height {
                            let s = c * plane + (t.y0 + y) * width + t.x0
                            let d = (c * t.height + y) * t.width
                            for x in 0..<t.width { dst[d + x] = src[s + x] }
                        }
                    }
                }
            }
            let padded = reflectPad(planes: cut, channels: channels, height: t.height, width: t.width,
                                    padBottom: t.padBottom, padRight: t.padRight)
            let ph = t.paddedHeight, pw = t.paddedWidth
            let result = try body(padded, ph, pw)
            precondition(result.count == channels * ph * pw,
                         "body returned \(result.count) values, expected \(channels * ph * pw)")

            let (wy, wx) = featherWeights(tile: t, imageWidth: width, imageHeight: height,
                                          tileSize: tile, overlap: overlap)
            result.withUnsafeBufferPointer { o in
                out.withUnsafeMutableBufferPointer { acc in
                    wsum.withUnsafeMutableBufferPointer { ws in
                        for y in 0..<t.height {
                            for x in 0..<t.width {
                                let wt = wy[y] * wx[x]
                                let gi = (t.y0 + y) * width + t.x0 + x
                                ws[gi] += wt
                                for c in 0..<channels {
                                    acc[c * plane + gi] += o[(c * ph + y) * pw + x] * wt
                                }
                            }
                        }
                    }
                }
            }
        }

        out.withUnsafeMutableBufferPointer { acc in
            wsum.withUnsafeBufferPointer { ws in
                for i in 0..<plane {
                    let d = max(ws[i], 1e-6)
                    for c in 0..<channels { acc[c * plane + i] /= d }
                }
            }
        }
        return out
    }

    // MARK: - Strength

    /// `strength · denoised + (1 − strength) · original`, element-wise — `denoise_file`'s
    /// blend. `1 − strength` is formed in Double before rounding, as Python forms it from
    /// a float before numpy casts it to float32. Not clamped: 0…1 is the caller's range
    /// (recipe 0…100 ÷ 100), and Python does not clamp either.
    public static func blend(denoised: [Float], original: [Float], strength: Float) -> [Float] {
        precondition(denoised.count == original.count, "blend size mismatch")
        let a = strength
        let b = Float(1 - Double(strength))
        var out = [Float](repeating: 0, count: denoised.count)
        for i in 0..<out.count { out[i] = a * denoised[i] + b * original[i] }
        return out
    }
}

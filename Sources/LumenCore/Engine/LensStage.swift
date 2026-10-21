// LensStage.swift
// Lens corrections that Apple's RAW decode does not make (WS-28): lateral chromatic
// aberration, Defringe, and the vignetting a Sony body writes into its own raw file.
//
// The stage runs on the scene-linear decode, after S3 and before S5, because all three
// are statements about the optics: lateral CA is a per-channel magnification of the
// image the lens formed, vignetting is a fall-off of the light that reached the sensor,
// and the fringes Defringe targets are the lens's axial CA blurred into the pixels
// beside a hard edge. A heal or a mask should see the corrected picture.
//
// What Apple already does (measured, not assumed: `corpus-lens:` lines of the RAW
// corpus lane, run 39478505162, and `LensProfileRawCorpusTests`): with
// `isLensCorrectionEnabled` the A7 IV and GX85 decodes are re-warped (distortion), and
// the corner/centre luminance ratio moves by 0.1 % (A7 IV) and 0.9 % (GX85) — so the
// vignetting the A7 IV records (0.65 EV at the corner on the FE 50 F2.5) is NOT
// corrected. This stage reads it from the file and applies it.
//
// Every pixel operation here has a Core Image twin in `LensKernelSource`, generated
// from the same constants so the two cannot drift.

import Foundation

// MARK: - Lateral chromatic aberration

/// Per-channel radial magnification relative to green: channel c is resampled at
/// `centre + (p − centre) · s_c(r)`, `s_c(r) = 1 + k0 + k2·r²`, with r the distance from
/// the frame centre over the half-diagonal. Normalised, so the same model applies to a
/// decode at any scale.
public struct LateralCAModel: Equatable, Sendable, Codable {
    public var red: Coefficients
    public var blue: Coefficients

    public struct Coefficients: Equatable, Sendable, Codable {
        public var k0: Double
        public var k2: Double
        public init(k0: Double = 0, k2: Double = 0) {
            self.k0 = k0
            self.k2 = k2
        }
        @inlinable public func scale(r2: Double) -> Double { 1 + k0 + k2 * r2 }
        /// Radial shift, in half-diagonals, at radius r.
        public func shift(at r: Double) -> Double { r * (k0 + k2 * r * r) }
    }

    public init(red: Coefficients = .init(), blue: Coefficients = .init()) {
        self.red = red
        self.blue = blue
    }

    public var isIdentity: Bool {
        red.k0 == 0 && red.k2 == 0 && blue.k0 == 0 && blue.k2 == 0
    }

    /// The largest misregistration the model corrects anywhere in a frame whose
    /// half-diagonal is `halfDiagonal` px, in px.
    public func maxShiftPixels(halfDiagonal: Double) -> Double {
        var worst = 0.0
        for i in 0...20 {
            let r = Double(i) / 20
            worst = Swift.max(worst, abs(red.shift(at: r)), abs(blue.shift(at: r)))
        }
        return worst * halfDiagonal
    }
}

public enum LateralCAEstimator {

    /// Below this misregistration (native px, anywhere in the frame) the estimate is
    /// indistinguishable from noise and the stage stays an exact identity. 0.12: the A7 IV
    /// frame (6929), whose lens shows no lateral CA, measures a sign-flipping 0.09–0.10
    /// px of noise, and a 0.1 px colour misregistration is not visible at 100 %.
    public static let significancePixels = 0.12

    public struct Sample: Sendable {
        public var r: Double
        public var redShift: Double     // half-diagonals
        public var blueShift: Double
        public var weight: Double
    }

    /// Estimate the model from the photograph itself — Lightroom's Remove CA is the same
    /// kind of thing: automatic, profile-free. Nil when the frame has too little
    /// radial structure to say anything, or when what it says is below
    /// `significancePixels`.
    public static func estimate(_ image: ImageBuffer) -> LateralCAModel? {
        estimate(samples: measure(image),
                 halfDiagonal: 0.5 * (Double(image.width * image.width
                                             + image.height * image.height)).squareRoot())
    }

    /// The same, measuring native-resolution tiles fetched on demand (`measure(nativeWidth:…)`).
    public static func estimate(nativeWidth: Int, nativeHeight: Int, preview: ImageBuffer,
                                fetch: TileFetch) -> LateralCAModel? {
        estimate(samples: measure(nativeWidth: nativeWidth, nativeHeight: nativeHeight,
                                  preview: preview, fetch: fetch),
                 halfDiagonal: 0.5 * (Double(nativeWidth * nativeWidth
                                             + nativeHeight * nativeHeight)).squareRoot())
    }

    /// Radial bands the model is fitted through, as (lower, upper) in half-diagonals.
    static let fitBands: [(Double, Double)] = stride(from: 0.2, to: 1.0, by: 0.1)
        .map { ($0, $0 + 0.1 + ($0 > 0.85 ? 0.05 : 0)) }
    /// A band speaks only with this many tiles in it.
    static let minimumBandTiles = 6

    /// The model from per-tile samples, through three gates the verifier's round-one
    /// failures set (docs/quality/lanes/WS-28/REPORT.md):
    ///
    ///  - it is fitted to per-band MEDIANS rather than to tiles, so colour texture
    ///    (foliage, a red roof) that reads as a shift in a minority of tiles cannot
    ///    move it;
    ///  - a channel whose bands disagree in sign (GX85 blue: −0.19, +0.16, +0.18,
    ///    −0.20 px) has no lens CA to correct and is left alone;
    ///  - no model at all without a measured band past r = 0.65: the corners are where
    ///    the correction matters most and an extrapolation into them is a guess (6001:
    ///    no tile past r = 0.8, and 0.74 px of blue correction invented there).
    static func estimate(samples: [Sample]?, halfDiagonal: Double) -> LateralCAModel? {
        guard let samples else { return nil }
        struct Band { var r: Double; var red: Double; var blue: Double; var n: Int }
        var bands: [Band] = []
        for (lo, hi) in fitBands {
            let inBand = samples.filter { $0.r >= lo && $0.r < hi }
            guard inBand.count >= minimumBandTiles else { continue }
            let red = inBand.map(\.redShift).sorted(), blue = inBand.map(\.blueShift).sorted()
            let r = inBand.map(\.r).reduce(0, +) / Double(inBand.count)
            bands.append(Band(r: r, red: red[red.count / 2], blue: blue[blue.count / 2],
                              n: inBand.count))
        }
        guard bands.count >= 3, let outer = bands.map(\.r).max(), outer >= 0.65 else { return nil }
        let cubic = bands.filter { $0.r >= 0.6 }.count >= 2

        func channel(_ value: KeyPath<Band, Double>) -> LateralCAModel.Coefficients {
            // Sign gate, on bands whose median clears the noise floor.
            let floor = significancePixels * 0.75 / halfDiagonal
            let signs = Set(bands.map { $0[keyPath: value] }.filter { abs($0) >= floor }.map { $0 > 0 })
            guard signs.count <= 1 else { return .init() }
            var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0
            for band in bands {
                let w = Double(band.n).squareRoot()
                let f1 = band.r, f2 = band.r * band.r * band.r, y = band[keyPath: value]
                a11 += w * f1 * f1; a12 += w * f1 * f2; a22 += w * f2 * f2
                b1 += w * f1 * y; b2 += w * f2 * y
            }
            if cubic {
                let det = a11 * a22 - a12 * a12
                if det > 1e-18 * a11 * a22 {
                    return .init(k0: (b1 * a22 - b2 * a12) / det, k2: (a11 * b2 - a12 * b1) / det)
                }
            }
            return .init(k0: a11 > 0 ? b1 / a11 : 0, k2: 0)
        }
        let model = LateralCAModel(red: channel(\.red), blue: channel(\.blue))
        guard model.maxShiftPixels(halfDiagonal: halfDiagonal) >= significancePixels else { return nil }
        return model
    }

    /// Per-tile radial misregistration of R and of B against G. Exposed for the
    /// diagnostics and for the macOS probe that asks whether Apple's decode already
    /// removed it.
    /// Tuning knobs, fixed in production (WS-28 REPORT records how they were chosen).
    nonisolated(unsafe) static var tileCap = 48
    nonisolated(unsafe) static var correlationGate = 0.85

    public typealias TileFetch = (_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> ImageBuffer?

    public static func measure(_ image: ImageBuffer, maxTiles: Int = 600) -> [Sample]? {
        measure(nativeWidth: image.width, nativeHeight: image.height, preview: image,
                maxTiles: maxTiles) { x, y, w, h in
            var tile = ImageBuffer(width: w, height: h)
            for yy in 0..<h {
                let src = ((y + yy) * image.width + x) * 4
                let dst = yy * w * 4
                for k in 0..<(w * 4) { tile.pixels[dst + k] = image.pixels[src + k] }
            }
            return tile
        }
    }

    /// Tiles are RANKED on `preview` (any downscale of the frame, the same picture) and
    /// MEASURED on native-resolution pixels from `fetch`, so a caller holding a small
    /// decode and a lazy full-size one pays for a few hundred 60 px tiles rather than a
    /// full-frame readback — and measures at the scale where the estimate is right
    /// (1840: 0.48 px native, 0.81 px measured on a 2560 px decode).
    public static func measure(nativeWidth w: Int, nativeHeight h: Int, preview: ImageBuffer,
                               maxTiles: Int = 600, fetch: TileFetch) -> [Sample]? {
        guard w >= 64, h >= 64 else { return nil }
        let pv = LogPlanes(preview, origin: (0, 0), peak: nil)
        let peak = pv.peak
        let s = Double(preview.width) / Double(w)
        let cx = Double(w) / 2, cy = Double(h) / 2
        let norm = 0.5 * (Double(w * w + h * h)).squareRoot()
        let tile = Swift.min(tileCap, Swift.max(16, Swift.max(w, h) / 60))
        let margin = 6
        let border = margin

        // Pass 1, on the preview: radial-gradient energy of each tile, to keep only the
        // tiles with something to measure. A ranking, not a number.
        struct Candidate { var x0: Int; var y0: Int; var r: Double; var energy: Double }
        var candidates: [Candidate] = []
        let step = Swift.max(1, Int((Double(tile) * s / 12).rounded()))
        var y0 = border
        while y0 + tile <= h - border {
            var x0 = border
            while x0 + tile <= w - border {
                let tcx = Double(x0) + Double(tile) / 2 - cx
                let tcy = Double(y0) + Double(tile) / 2 - cy
                let rt = (tcx * tcx + tcy * tcy).squareRoot() / norm
                if rt >= 0.2 {
                    let ux = tcx / (rt * norm), uy = tcy / (rt * norm)
                    var e = 0.0
                    var clipped = 0, seen = 0
                    let px0 = Int(Double(x0) * s), py0 = Int(Double(y0) * s)
                    let pn = Swift.max(2, Int(Double(tile) * s))
                    var y = py0
                    while y < Swift.min(py0 + pn, pv.h) {
                        var x = px0
                        while x < Swift.min(px0 + pn, pv.w) {
                            if pv.clipped[y * pv.w + x] { clipped += 1 }
                            seen += 1
                            let g = pv.radialGradient(pv.g, x, y, ux, uy)
                            e += g * g
                            x += step
                        }
                        y += step
                    }
                    if clipped * 2 < seen, e > 0 {
                        candidates.append(Candidate(x0: x0, y0: y0, r: rt, energy: e))
                    }
                }
                x0 += tile
            }
            y0 += tile
        }
        guard candidates.count >= 12 else { return nil }
        // Stratified by radius: the strongest tiles of a photograph sit on its
        // in-focus subject, usually central, and a fit fed only those extrapolates into
        // corners it never saw. Each radial band keeps its own strongest tiles.
        let bands = [0.2, 0.35, 0.5, 0.65, 0.8, 2.0]
        var kept: [Candidate] = []
        for k in 0..<(bands.count - 1) {
            let inBand = candidates.filter { $0.r >= bands[k] && $0.r < bands[k + 1] }
                .sorted { $0.energy > $1.energy }
            kept += inBand.prefix(maxTiles / (bands.count - 1))
        }

        // Pass 2, on native pixels.
        var samples: [Sample] = []
        for c in kept {
            let fx = c.x0 - margin, fy = c.y0 - margin, fs = tile + 2 * margin
            guard let buffer = fetch(fx, fy, fs, fs), buffer.width == fs, buffer.height == fs
            else { continue }
            let planes = LogPlanes(buffer, origin: (fx, fy), peak: peak)
            let tcx = Double(c.x0) + Double(tile) / 2 - cx
            let tcy = Double(c.y0) + Double(tile) / 2 - cy
            let rpx = (tcx * tcx + tcy * tcy).squareRoot()
            let ux = tcx / rpx, uy = tcy / rpx
            guard let red = planes.registration(planes.r, x0: c.x0, y0: c.y0, size: tile,
                                                ux: ux, uy: uy),
                  let blue = planes.registration(planes.b, x0: c.x0, y0: c.y0, size: tile,
                                                 ux: ux, uy: uy)
            else { continue }
            let weight = Swift.min(red.weight, blue.weight)
            samples.append(Sample(r: rpx / norm, redShift: red.shift / norm,
                                  blueShift: blue.shift / norm, weight: weight))
        }
        return samples.count >= 12 ? samples : nil
    }

    /// Weighted least squares of shift = k0·r + k2·r³, iteratively reweighted (Tukey's
    /// biweight on the residual) so that colour edges — a red flower on a green leaf,
    /// which register as a "shift" no lens made — fall out.
    public static func fit(_ samples: [Sample],
                           _ value: KeyPath<Sample, Double>) -> LateralCAModel.Coefficients? {
        // The cubic term is only fitted where the outer frame was measured; otherwise
        // the model is a plain magnification, which extrapolates linearly.
        let outer = samples.filter { $0.r >= 0.6 }.count
        let cubic = outer >= 24
        var robust = [Double](repeating: 1, count: samples.count)
        var k0 = 0.0, k2 = 0.0
        for _ in 0..<8 {
            var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0
            for (i, s) in samples.enumerated() {
                let wgt = s.weight * robust[i]
                let f1 = s.r, f2 = s.r * s.r * s.r
                a11 += wgt * f1 * f1
                a12 += wgt * f1 * f2
                a22 += wgt * f2 * f2
                b1 += wgt * f1 * s[keyPath: value]
                b2 += wgt * f2 * s[keyPath: value]
            }
            if cubic {
                let det = a11 * a22 - a12 * a12
                guard det > 1e-18 * Swift.max(a11 * a22, 1e-30) else { return nil }
                k0 = (b1 * a22 - b2 * a12) / det
                k2 = (a11 * b2 - a12 * b1) / det
            } else {
                guard a11 > 0 else { return nil }
                k0 = b1 / a11
                k2 = 0
            }
            // Residual scale: weighted median absolute deviation.
            let residuals = samples.map { $0[keyPath: value] - ($0.r * (k0 + k2 * $0.r * $0.r)) }
            let mad = weightedMedian(residuals.map(abs), samples.map(\.weight))
            let c = Swift.max(4.685 * 1.4826 * mad, 1e-7)
            for i in samples.indices {
                let u = residuals[i] / c
                robust[i] = abs(u) < 1 ? (1 - u * u) * (1 - u * u) : 0
            }
        }
        guard k0.isFinite, k2.isFinite else { return nil }
        return .init(k0: k0, k2: k2)
    }

    static func weightedMedian(_ values: [Double], _ weights: [Double]) -> Double {
        let order = values.indices.sorted { values[$0] < values[$1] }
        let total = weights.reduce(0, +)
        var acc = 0.0
        for i in order {
            acc += weights[i]
            if acc >= total / 2 { return values[i] }
        }
        return values.last ?? 0
    }

    /// The three channels in LINEAR light, plus the clip map. Linear, because the lens
    /// blurs light linearly: a blurred edge between two surfaces is, in every channel,
    /// the same profile scaled and offset, whatever the two colours are — so an affine
    /// fit C ≈ α·G + β per tile absorbs the colour of the surfaces and leaves only the
    /// shift. (A log-domain fit with unit gain read a colour step across an edge, blue
    /// sky beside a brown branch, as a shift; on 1840 that overshot the correction.)
    struct LogPlanes {
        let w: Int, h: Int
        /// Where this buffer's (0, 0) sits in the frame: tiles are addressed in frame
        /// coordinates.
        let ox: Int, oy: Int
        var r: [Float], g: [Float], b: [Float]
        var clipped: [Bool]
        let peak: (Float, Float, Float)

        init(_ image: ImageBuffer, origin: (Int, Int), peak given: (Float, Float, Float)?) {
            w = image.width
            h = image.height
            ox = origin.0
            oy = origin.1
            let n = w * h
            r = [Float](repeating: 0, count: n)
            g = r
            b = r
            clipped = [Bool](repeating: false, count: n)
            let px = image.pixels
            var top: (Float, Float, Float) = (0, 0, 0)
            if let given { top = given } else {
                for i in 0..<n {
                    top.0 = Swift.max(top.0, px[i * 4])
                    top.1 = Swift.max(top.1, px[i * 4 + 1])
                    top.2 = Swift.max(top.2, px[i * 4 + 2])
                }
            }
            peak = top
            for i in 0..<n {
                let rv = px[i * 4], gv = px[i * 4 + 1], bv = px[i * 4 + 2]
                clipped[i] = rv >= top.0 * 0.98 || gv >= top.1 * 0.98 || bv >= top.2 * 0.98
                r[i] = rv
                g[i] = gv
                b[i] = bv
            }
        }

        @inline(__always) func isClipped(_ x: Int, _ y: Int) -> Bool {
            clipped[Swift.min(Swift.max(y - oy, 0), h - 1) * w
                    + Swift.min(Swift.max(x - ox, 0), w - 1)]
        }

        @inline(__always) func at(_ p: [Float], _ x: Int, _ y: Int) -> Double {
            Double(p[Swift.min(Swift.max(y - oy, 0), h - 1) * w
                     + Swift.min(Swift.max(x - ox, 0), w - 1)])
        }

        /// Bilinear, pixel centres at +0.5 — `ImageBuffer.bilinear`'s convention. (A
        /// Catmull–Rom sampler here was tried: it moved 1840's native estimate away from
        /// the independent tool's zero-residual point, 0.63 against 0.46 px.)
        @inline(__always) func sample(_ p: [Float], _ x: Double, _ y: Double) -> Double {
            let fx = x - 0.5, fy = y - 0.5
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
            let tx = fx - Double(x0), ty = fy - Double(y0)
            let a = at(p, x0, y0) * (1 - tx) + at(p, x0 + 1, y0) * tx
            let c = at(p, x0, y0 + 1) * (1 - tx) + at(p, x0 + 1, y0 + 1) * tx
            return a * (1 - ty) + c * ty
        }

        func radialGradient(_ p: [Float], _ x: Int, _ y: Int, _ ux: Double, _ uy: Double) -> Double {
            let gx = (at(p, x + 1, y) - at(p, x - 1, y)) * 0.5
            let gy = (at(p, x, y + 1) - at(p, x, y - 1)) * 0.5
            return gx * ux + gy * uy
        }

        /// The radial shift d (px) that best registers `channel` to green over one tile:
        /// argmin Σ (C(x + d·u) − G(x) − β)², a coarse search then Gauss–Newton. Nil
        /// when the tile's edges are not shared by both channels (a colour edge, or
        /// texture in one channel only).
        func registration(_ channel: [Float], x0: Int, y0: Int, size: Int,
                          ux: Double, uy: Double) -> (shift: Double, weight: Double)? {
            var gs: [Double] = []
            var gradG: [Double] = []
            var pts: [(Double, Double)] = []
            gs.reserveCapacity(size * size)
            var meanG = 0.0
            for y in y0..<(y0 + size) {
                for x in x0..<(x0 + size) {
                    // A clipped pixel's channels say where the sensor stopped, not where
                    // the edge is: it takes no part in the fit.
                    if isClipped(x, y) { continue }
                    let v = at(g, x, y)
                    gs.append(v)
                    meanG += v
                    gradG.append(radialGradient(g, x, y, ux, uy))
                    pts.append((Double(x) + 0.5, Double(y) + 0.5))
                }
            }
            guard pts.count * 5 >= size * size * 2 else { return nil }
            let count = Double(pts.count)
            meanG /= count
            guard meanG > 0 else { return nil }
            var varG = 0.0
            for v in gs { varG += (v - meanG) * (v - meanG) }
            guard varG > 1e-12 else { return nil }

            // Radial coordinate within the tile, centred, in px.
            var rho = [Double](repeating: 0, count: pts.count)
            let tcx = Double(x0) + Double(size) / 2, tcy = Double(y0) + Double(size) / 2
            for i in pts.indices {
                rho[i] = (pts[i].0 - tcx) * ux + (pts[i].1 - tcy) * uy
            }
            // The four regressors: G, 1, ρ·G, ρ. The last two absorb colour shading — an
            // R/G ratio drifting radially across the tile (colour vignetting, a sky
            // gradient) — which a gain-only fit reads as a shift, and the more so the
            // larger the tile is relative to the frame (1840 read 0.47, 0.36, 0.27 px at
            // 1×, 2×, 3× down where a lens shift scales 1, ½, ⅓).
            let basis: [[Double]] = [gs, [Double](repeating: 1, count: pts.count),
                                     pts.indices.map { rho[$0] * gs[$0] }, rho]
            var normal = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
            for a in 0..<4 {
                for b in 0..<4 {
                    var acc = 0.0
                    for i in pts.indices { acc += basis[a][i] * basis[b][i] }
                    normal[a][b] = acc
                }
            }
            guard let normalInverse = invert4(normal) else { return nil }

            /// Least-squares C ≈ α·G + β + γ·ρG + δ·ρ over the tile; residuals and α.
            func affine(_ c: [Double]) -> (residual: [Double], alpha: Double) {
                var rhs = [Double](repeating: 0, count: 4)
                for a in 0..<4 {
                    var acc = 0.0
                    for i in c.indices { acc += basis[a][i] * c[i] }
                    rhs[a] = acc
                }
                var coef = [Double](repeating: 0, count: 4)
                for a in 0..<4 {
                    for b in 0..<4 { coef[a] += normalInverse[a][b] * rhs[b] }
                }
                return (c.indices.map { i in
                    c[i] - coef[0] * gs[i] - coef[1] - coef[2] * basis[2][i] - coef[3] * rho[i]
                }, coef[0])
            }
            func shifted(_ d: Double) -> [Double] {
                pts.map { sample(channel, $0.0 + d * ux, $0.1 + d * uy) }
            }
            func cost(_ d: Double) -> Double {
                affine(shifted(d)).residual.reduce(0) { $0 + $1 * $1 }
            }
            var best = 0.0
            var bestCost = cost(0)
            var d = -3.0
            while d <= 3.0 {
                let c = cost(d)
                if c < bestCost { bestCost = c; best = d }
                d += 0.5
            }
            // Gauss–Newton on the continuous shift, α and β re-fitted each step.
            var shift = best
            var alpha = 1.0
            for _ in 0..<8 {
                let values = shifted(shift)
                let fit = affine(values)
                alpha = fit.alpha
                var num = 0.0, den = 0.0
                for i in pts.indices {
                    let sx = pts[i].0 + shift * ux, sy = pts[i].1 + shift * uy
                    let grad = sample(channel, sx + 0.5 * ux, sy + 0.5 * uy)
                        - sample(channel, sx - 0.5 * ux, sy - 0.5 * uy)
                    num += grad * fit.residual[i]
                    den += grad * grad
                }
                guard den > 1e-18 else { return nil }
                let step = Swift.max(-0.5, Swift.min(0.5, num / den))
                shift -= step
                if abs(step) < 1e-4 { break }
            }
            guard abs(shift) <= 3.5, alpha > 0 else { return nil }

            // Agreement of the two channels' radial structure at the solution: a tile
            // whose edges are not the same edges in both channels says nothing about
            // the lens. Weight: green's radial-gradient energy relative to its level,
            // so a bright tile does not outvote a dark one for being bright.
            var sab = 0.0, saa = 0.0, sbb = 0.0
            for i in pts.indices {
                let sx = pts[i].0 + shift * ux, sy = pts[i].1 + shift * uy
                let gc = sample(channel, sx + 0.5 * ux, sy + 0.5 * uy)
                    - sample(channel, sx - 0.5 * ux, sy - 0.5 * uy)
                sab += gc * gradG[i]
                saa += gc * gc
                sbb += gradG[i] * gradG[i]
            }
            let corr = sab / Swift.max((saa * sbb).squareRoot(), 1e-18)
            guard corr > LateralCAEstimator.correlationGate else { return nil }
            return (shift, sbb / (meanG * meanG) * corr * corr)
        }
    }
}

// MARK: - Embedded lens profile (Sony)

/// The lens corrections a camera writes into its own raw file. Today: Sony's
/// 0x7031–0x7038 block in the raw SubIFD (every ARW from the A7 III/A7 IV generation
/// on). The knot encodings are darktable's reading of them (src/common/exif.cc,
/// src/iop/lens.cc): knot i sits at r = i/(n−1) of the half-diagonal, vignetting
/// knot v gives a fall-off of 2^(0.5 − 2^(v·2⁻¹³ − 1)), lateral CA knot v a scale of
/// 1 + v·2⁻²¹, distortion knot v a scale of 1 + v·2⁻¹⁴.
///
/// Panasonic writes DistortionInfo (0x0119) only, and Apple's decode already applies
/// distortion on the GX85 — there is no vignetting record in an RW2 to read.
public struct EmbeddedLensProfile: Equatable, Sendable {
    public var make: String
    public var vignetting: [Double]      // fall-off factor per knot, ≤ 1
    public var caRed: [Double]           // scale per knot
    public var caBlue: [Double]
    public var distortion: [Double]

    public init(make: String, vignetting: [Double], caRed: [Double] = [],
                caBlue: [Double] = [], distortion: [Double] = []) {
        self.make = make
        self.vignetting = vignetting
        self.caRed = caRed
        self.caBlue = caBlue
        self.distortion = distortion
    }

    /// Fall-off at radius r (half-diagonals), linear between knots.
    public func falloff(at r: Double) -> Double {
        Self.interpolate(vignetting, r) ?? 1
    }

    static func interpolate(_ knots: [Double], _ r: Double) -> Double? {
        guard knots.count >= 2 else { return nil }
        let t = Swift.max(0, Swift.min(1, r)) * Double(knots.count - 1)
        let i = Swift.min(Int(t), knots.count - 2)
        let f = t - Double(i)
        return knots[i] * (1 - f) + knots[i + 1] * f
    }

    /// The correction gain 1/falloff as the even polynomial the kernel evaluates,
    /// 1 + a·r² + b·r⁴ + c·r⁶, least-squares through 64 points of the knot curve.
    public var gainPolynomial: VignetteGain? {
        guard vignetting.count >= 2, vignetting.contains(where: { $0 != 1 }) else { return nil }
        var ata = [[Double]](repeating: [0, 0, 0], count: 3)
        var atb = [Double](repeating: 0, count: 3)
        for i in 0...64 {
            let r = Double(i) / 64
            let r2 = r * r
            let f = [r2, r2 * r2, r2 * r2 * r2]
            let y = 1 / Swift.max(falloff(at: r), 0.05) - 1
            for a in 0..<3 {
                for b in 0..<3 { ata[a][b] += f[a] * f[b] }
                atb[a] += f[a] * y
            }
        }
        guard let x = solve3(ata, atb) else { return nil }
        return VignetteGain(a: x[0], b: x[1], c: x[2])
    }

    // MARK: Reading

    public static func read(url: URL) -> EmbeddedLensProfile? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The tag block sits in the first IFDs; 4 MB covers every ARW layout seen, and
        // a lossless A7 IV file is 60–80 MB, so reading it whole would be waste.
        guard let data = try? handle.read(upToCount: 4 << 20) else { return nil }
        return read(data: data)
    }

    public static func read(data: Data) -> EmbeddedLensProfile? {
        let bytes = [UInt8](data)
        guard bytes.count > 16 else { return nil }
        let little: Bool
        if bytes[0] == 0x49, bytes[1] == 0x49 { little = true }
        else if bytes[0] == 0x4D, bytes[1] == 0x4D { little = false }
        else { return nil }
        var reader = TIFFWalker(bytes: bytes, little: little)
        guard let first = reader.u32(4) else { return nil }
        reader.walk(Int(first), depth: 0)
        guard reader.make.lowercased().hasPrefix("sony"),
              let vig = reader.int16s[0x7032], vig.count >= 3 else { return nil }
        func knots(_ values: ArraySlice<Int>, _ f: (Int) -> Double) -> [Double] {
            values.map(f)
        }
        let nv = Swift.min(vig[0], vig.count - 1)
        let vignetting = knots(vig[1...nv]) { v in
            pow(2, 0.5 - pow(2, Double(v) * pow(2, -13) - 1))
        }
        var caRed: [Double] = [], caBlue: [Double] = []
        if let ca = reader.int16s[0x7035], ca.count >= 3 {
            let half = Swift.min(ca[0], ca.count - 1) / 2
            caRed = knots(ca[1...half]) { 1 + Double($0) * pow(2, -21) }
            caBlue = knots(ca[(half + 1)...(2 * half)]) { 1 + Double($0) * pow(2, -21) }
        }
        var distortion: [Double] = []
        if let dist = reader.int16s[0x7037], dist.count >= 3 {
            let nd = Swift.min(dist[0], dist.count - 1)
            distortion = knots(dist[1...nd]) { 1 + Double($0) * pow(2, -14) }
        }
        return EmbeddedLensProfile(make: reader.make, vignetting: vignetting,
                                   caRed: caRed, caBlue: caBlue, distortion: distortion)
    }

    /// Just enough TIFF to find Make and the int16s tags, through IFD chains, SubIFDs
    /// and the Exif IFD. Bounded on every offset; a malformed file reads as nothing.
    struct TIFFWalker {
        let bytes: [UInt8]
        let little: Bool
        var make = ""
        var int16s: [Int: [Int]] = [:]
        var visited = Set<Int>()

        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= bytes.count else { return nil }
            return little ? Int(bytes[o]) | Int(bytes[o + 1]) << 8
                          : Int(bytes[o]) << 8 | Int(bytes[o + 1])
        }
        func u32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            let b = (UInt32(bytes[o]), UInt32(bytes[o + 1]), UInt32(bytes[o + 2]),
                     UInt32(bytes[o + 3]))
            return little ? b.0 | b.1 << 8 | b.2 << 16 | b.3 << 24
                          : b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3
        }

        mutating func walk(_ offset: Int, depth: Int) {
            guard depth < 8, offset > 0, !visited.contains(offset),
                  let count = u16(offset), count < 1000 else { return }
            visited.insert(offset)
            for i in 0..<count {
                let e = offset + 2 + 12 * i
                guard let tag = u16(e), let type = u16(e + 2),
                      let n32 = u32(e + 4) else { return }
                let n = Int(n32)
                let unit = [1: 1, 2: 1, 3: 2, 4: 4, 6: 1, 7: 1, 8: 2, 9: 4, 13: 4][type] ?? 0
                guard unit > 0, n < 1 << 20 else { continue }
                let size = unit * n
                let valueOffset = size <= 4 ? e + 8 : Int(u32(e + 8) ?? 0)
                guard valueOffset + size <= bytes.count else { continue }
                if tag == 0x010F, type == 2 {
                    let raw = bytes[valueOffset..<(valueOffset + size)]
                    make = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                } else if (type == 8 || type == 3), tag >= 0x7000, tag <= 0x70FF {
                    int16s[tag] = (0..<n).compactMap { k in
                        u16(valueOffset + 2 * k).map { type == 8 ? Int(Int16(truncatingIfNeeded: $0)) : $0 }
                    }
                } else if tag == 0x014A || tag == 0x8769, type == 4 || type == 13 {
                    for k in 0..<n {
                        if let sub = u32(valueOffset + 4 * k) { walk(Int(sub), depth: depth + 1) }
                    }
                }
            }
            if let next = u32(offset + 2 + 12 * count), next > 0 {
                walk(Int(next), depth: depth + 1)
            }
        }
    }
}

/// Radial gain 1 + a·r² + b·r⁴ + c·r⁶, r over the half-diagonal.
public struct VignetteGain: Equatable, Sendable, Codable {
    public var a: Double, b: Double, c: Double
    public init(a: Double, b: Double, c: Double) {
        self.a = a
        self.b = b
        self.c = c
    }
    @inlinable public func gain(r2: Double) -> Double { 1 + r2 * (a + r2 * (b + r2 * c)) }
}

/// Gauss–Jordan inverse of a 4×4, nil when singular.
func invert4(_ m: [[Double]]) -> [[Double]]? {
    var a = m
    var inv = (0..<4).map { i in (0..<4).map { j in i == j ? 1.0 : 0.0 } }
    let scale = m.flatMap { $0 }.map(abs).max() ?? 0
    guard scale > 0 else { return nil }
    for col in 0..<4 {
        var pivot = col
        for row in (col + 1)..<4 where abs(a[row][col]) > abs(a[pivot][col]) { pivot = row }
        guard abs(a[pivot][col]) > 1e-14 * scale else { return nil }
        a.swapAt(col, pivot)
        inv.swapAt(col, pivot)
        let p = a[col][col]
        for k in 0..<4 { a[col][k] /= p; inv[col][k] /= p }
        for row in 0..<4 where row != col {
            let f = a[row][col]
            for k in 0..<4 { a[row][k] -= f * a[col][k]; inv[row][k] -= f * inv[col][k] }
        }
    }
    return inv
}

func solve3(_ m: [[Double]], _ v: [Double]) -> [Double]? {
    var a = m
    var b = v
    for col in 0..<3 {
        var pivot = col
        for row in (col + 1)..<3 where abs(a[row][col]) > abs(a[pivot][col]) { pivot = row }
        guard abs(a[pivot][col]) > 1e-15 else { return nil }
        a.swapAt(col, pivot)
        b.swapAt(col, pivot)
        for row in 0..<3 where row != col {
            let f = a[row][col] / a[col][col]
            for k in 0..<3 { a[row][k] -= f * a[col][k] }
            b[row] -= f * b[col]
        }
    }
    return (0..<3).map { b[$0] / a[$0][$0] }
}

// MARK: - Defringe

/// Lightroom's Defringe, on its scales: Amount 0…20 per family, Hue a 0…100 range.
/// A pixel is pulled toward its own luminance (exactly — Y is preserved) by
/// `strength(amount) · hueWeight · chromaGate · edgeWeight`, where the edge weight says
/// "there is a hard edge within a few pixels" and the hue weight says "this pixel's
/// OKLab hue is inside the family's range". A purple object away from any edge is
/// never touched; a purple fringe beside a branch against the sky is.
public struct DefringeParams: Equatable, Sendable {
    /// OKLab hue (degrees, may exceed 360) of each family's slider ends. Adobe does not
    /// publish the 0…100 scale; these are the only numbers anyone has measured (a
    /// reverse-engineering fit, rawmakase PR #33: centres 315° purple and 166° green,
    /// 0…100 spanning 180°), so Lightroom's defaults land where Lightroom's do —
    /// purple 30/70 → 279°–351°, green 40/60 → 148°–184°.
    public static let purpleHueSpan = (lo: 225.0, hi: 405.0)
    public static let greenHueSpan = (lo: 76.0, hi: 256.0)
    /// Feather outside each range, degrees.
    public static let hueFeather = 10.0

    public var purpleStrength: Double
    public var purpleLo: Double, purpleHi: Double   // degrees
    public var greenStrength: Double
    public var greenLo: Double, greenHi: Double
    /// Edge search radius in px at this render's scale.
    public var radius: Int

    public init(_ d: Defringe, longEdge: Int) {
        purpleStrength = Self.strength(d.purpleAmount)
        greenStrength = Self.strength(d.greenAmount)
        let pLo = Swift.min(d.purpleHueLo, d.purpleHueHi), pHi = Swift.max(d.purpleHueLo, d.purpleHueHi)
        let gLo = Swift.min(d.greenHueLo, d.greenHueHi), gHi = Swift.max(d.greenHueLo, d.greenHueHi)
        let ps = Self.purpleHueSpan, gs = Self.greenHueSpan
        let (p0, p1) = Self.spanned(pLo, pHi), (g0, g1) = Self.spanned(gLo, gHi)
        purpleLo = ps.lo + (ps.hi - ps.lo) * p0 / 100
        purpleHi = ps.lo + (ps.hi - ps.lo) * p1 / 100
        greenLo = gs.lo + (gs.hi - gs.lo) * g0 / 100
        greenHi = gs.lo + (gs.hi - gs.lo) * g1 / 100
        radius = Self.radius(longEdge: longEdge)
    }

    /// Lightroom's minimum span: the two ends of a hue range stay at least 10 units
    /// apart, widened about their centre and kept inside 0…100.
    public static let minimumHueSpan = 10.0
    static func spanned(_ lo: Double, _ hi: Double) -> (Double, Double) {
        var a = Swift.max(0, Swift.min(100, lo.isFinite ? lo : 0))
        var b = Swift.max(0, Swift.min(100, hi.isFinite ? hi : 100))
        if b - a < minimumHueSpan {
            let centre = Swift.max(minimumHueSpan / 2, Swift.min(100 - minimumHueSpan / 2, (a + b) / 2))
            a = centre - minimumHueSpan / 2
            b = centre + minimumHueSpan / 2
        }
        return (a, b)
    }

    /// Amount → fraction of the fringe's chroma removed. 1 − e^(−a/4): 2 → 39 %, 5 →
    /// 71 %, 10 → 92 %, 20 → 99 %. Monotonic, smooth, exactly 0 at 0.
    public static func strength(_ amount: Double) -> Double {
        let a = Swift.max(0, Swift.min(20, amount.isFinite ? amount : 0))
        return 1 - exp(-a / 4)
    }

    /// 3 px at a 6000 px long edge — the width axial-CA fringes have on a 24–45 MP
    /// sensor — scaled with the render, never below 1 nor above 4.
    public static func radius(longEdge: Int) -> Int {
        Swift.max(1, Swift.min(4, Int((Double(longEdge) * 0.0005).rounded())))
    }

    public var isIdentity: Bool { purpleStrength == 0 && greenStrength == 0 }
}

public enum DefringeStage {

    /// Linear Rec.2020 → OKLab LMS (M1 · Rec.2020→XYZ), the matrix both twins use.
    public static let toLMS: [[Double]] = {
        let rec2020ToXYZ: [[Double]] = [
            [0.636958048301291, 0.144616903586208, 0.168880975164172],
            [0.262700212011267, 0.677998071518871, 0.059301716469862],
            [0.000000000000000, 0.028072693049087, 1.060985057710791],
        ]
        let m1: [[Double]] = [
            [0.8189330101, 0.3618667424, -0.1288597137],
            [0.0329845436, 0.9293118715, 0.0361456387],
            [0.0482003018, 0.2643662691, 0.6338517070],
        ]
        return (0..<3).map { i in
            (0..<3).map { j in (0..<3).reduce(0) { $0 + m1[i][$1] * rec2020ToXYZ[$1][j] } }
        }
    }()
    public static let m2: [[Double]] = [
        [0.2104542553, 0.7936177850, -0.0040720468],
        [1.9779984951, -2.4285922050, 0.4505937099],
        [0.0259040371, 0.7827717662, -0.8086757660],
    ]
    /// Rec.2020 luminance weights — the Y every pull preserves.
    public static let lumaWeights = (0.262700212011267, 0.677998071518871, 0.059301716469862)

    /// Edge weight: the log2 luminance range over the window, in stops.
    public static let edgeStops = (lo: 0.7, hi: 2.0)
    /// Relative-chroma gate C/(L + 0.02): neutral pixels are never touched.
    public static let chromaGate = (lo: 0.03, hi: 0.08)

    @inline(__always) static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = Swift.max(0, Swift.min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// 1 inside [lo, hi] (degrees, hue taken mod 360 into the band), feathered linearly
    /// over `hueFeather` either side.
    @inline(__always) static func hueWeight(_ h: Double, _ lo: Double, _ hi: Double) -> Double {
        let centre = (lo + hi) / 2
        var d = h - centre
        d -= 360 * (d / 360).rounded()
        let half = (hi - lo) / 2
        let outside = abs(d) - half
        return Swift.max(0, Swift.min(1, 1 - outside / DefringeParams.hueFeather))
    }

    /// The per-pixel pull, given the pixel and its window's luminance range in stops.
    public static func pull(_ c: RGB, rangeStops: Double, params p: DefringeParams) -> RGB {
        let edge = smoothstep(edgeStops.lo, edgeStops.hi, rangeStops)
        guard edge > 0 else { return c }
        let m = toLMS
        func cbrt(_ v: Double) -> Double { v < 0 ? -pow(-v, 1.0 / 3) : pow(v, 1.0 / 3) }
        let l = cbrt(m[0][0] * c.r + m[0][1] * c.g + m[0][2] * c.b)
        let mm = cbrt(m[1][0] * c.r + m[1][1] * c.g + m[1][2] * c.b)
        let s = cbrt(m[2][0] * c.r + m[2][1] * c.g + m[2][2] * c.b)
        let L = m2[0][0] * l + m2[0][1] * mm + m2[0][2] * s
        let a = m2[1][0] * l + m2[1][1] * mm + m2[1][2] * s
        let b = m2[2][0] * l + m2[2][1] * mm + m2[2][2] * s
        let chroma = (a * a + b * b).squareRoot()
        let gate = smoothstep(chromaGate.lo, chromaGate.hi, chroma / (Swift.max(L, 0) + 0.02))
        guard gate > 0 else { return c }
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        let w = Swift.max(p.purpleStrength * hueWeight(h, p.purpleLo, p.purpleHi),
                          p.greenStrength * hueWeight(h, p.greenLo, p.greenHi))
        let k = w * gate * edge
        guard k > 0 else { return c }
        let y = lumaWeights.0 * c.r + lumaWeights.1 * c.g + lumaWeights.2 * c.b
        return RGB(c.r + (y - c.r) * k, c.g + (y - c.g) * k, c.b + (y - c.b) * k)
    }

    public static func apply(_ image: ImageBuffer, params p: DefringeParams) -> ImageBuffer {
        guard !p.isIdentity else { return image }
        let w = image.width, h = image.height
        let lw = lumaWeights
        var logY = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let c = image[x, y]
                let lum = lw.0 * c.r + lw.1 * c.g + lw.2 * c.b
                logY[y * w + x] = log2(Swift.max(lum, LensKernelSource.defringeFloor))
            }
        }
        // Separable window max and min (square window), the GPU's two passes.
        let rad = p.radius
        func pass(_ src: [Double], horizontal: Bool, _ pick: (Double, Double) -> Double) -> [Double] {
            var out = src
            for y in 0..<h {
                for x in 0..<w {
                    var v = src[y * w + x]
                    for k in -rad...rad where k != 0 {
                        let sx = horizontal ? Swift.min(Swift.max(x + k, 0), w - 1) : x
                        let sy = horizontal ? y : Swift.min(Swift.max(y + k, 0), h - 1)
                        v = pick(v, src[sy * w + sx])
                    }
                    out[y * w + x] = v
                }
            }
            return out
        }
        let hi = pass(pass(logY, horizontal: true, Swift.max), horizontal: false, Swift.max)
        let lo = pass(pass(logY, horizontal: true, Swift.min), horizontal: false, Swift.min)
        var out = image
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                out[x, y] = pull(image[x, y], rangeStops: hi[i] - lo[i], params: p)
            }
        }
        return out
    }
}

// MARK: - The stage

/// What the lens stage needs that the recipe cannot hold: measured or read from the
/// file, once per photograph.
public struct LensInputs: Equatable, Sendable {
    public var lateralCA: LateralCAModel?
    public var vignette: VignetteGain?
    public init(lateralCA: LateralCAModel? = nil, vignette: VignetteGain? = nil) {
        self.lateralCA = lateralCA
        self.vignette = vignette
    }
    public static let none = LensInputs()
}

public enum LensStage {

    /// True when nothing the stage could do changes a pixel, so the caller skips it.
    public static func isIdentity(_ lens: LensCorrections, inputs: LensInputs) -> Bool {
        let ca = lens.removeCA && !(inputs.lateralCA?.isIdentity ?? true)
        let vig = lens.profile && inputs.vignette != nil
        let fringe = lens.defringe.map { !DefringeParams($0, longEdge: 1).isIdentity } ?? false
        return !ca && !vig && !fringe
    }

    public static func apply(_ image: ImageBuffer, lens: LensCorrections,
                             inputs: LensInputs) -> ImageBuffer {
        guard !isIdentity(lens, inputs: inputs) else { return image }
        var out = image
        let ca = lens.removeCA ? inputs.lateralCA.flatMap { $0.isIdentity ? nil : $0 } : nil
        let vig = lens.profile ? inputs.vignette : nil
        if ca != nil || vig != nil {
            out = warp(image, ca: ca ?? LateralCAModel(), vignette: vig)
        }
        if let d = lens.defringe {
            let p = DefringeParams(d, longEdge: Swift.max(image.width, image.height))
            if !p.isIdentity { out = DefringeStage.apply(out, params: p) }
        }
        return out
    }

    /// Catmull–Rom weights for fractional offset t, taps at −1, 0, 1, 2.
    @inline(__always) static func catmullRomWeights(_ t: Double) -> (Double, Double, Double, Double) {
        let t2 = t * t, t3 = t2 * t
        return (0.5 * (-t3 + 2 * t2 - t), 0.5 * (3 * t3 - 5 * t2 + 2),
                0.5 * (-3 * t3 + 4 * t2 + t), 0.5 * (t3 - t2))
    }

    /// One channel at (x, y), pixel centres at +0.5, edges clamped. Bicubic rather than
    /// bilinear because a lateral-CA shift is sub-pixel and bilinear softens the shifted
    /// channel by up to half a pixel at half-pixel phase — a red edge visibly blurrier
    /// than its green one is the defect the stage exists to remove.
    static func catmullRom(_ image: ImageBuffer, _ x: Double, _ y: Double, channel: Int) -> Double {
        let fx = x - 0.5, fy = y - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let wx = catmullRomWeights(fx - Double(x0)), wy = catmullRomWeights(fy - Double(y0))
        let wxs = [wx.0, wx.1, wx.2, wx.3], wys = [wy.0, wy.1, wy.2, wy.3]
        let w = image.width, h = image.height
        var acc = 0.0
        for j in 0..<4 {
            let sy = Swift.min(Swift.max(y0 - 1 + j, 0), h - 1)
            var row = 0.0
            for i in 0..<4 {
                let sx = Swift.min(Swift.max(x0 - 1 + i, 0), w - 1)
                row += wxs[i] * Double(image.pixels[(sy * w + sx) * 4 + channel])
            }
            acc += wys[j] * row
        }
        return acc
    }

    /// R and B resampled (Catmull–Rom) at their corrected radii, G untouched, then the
    /// vignetting gain. The twin of `LensKernelSource.lens`.
    public static func warp(_ image: ImageBuffer, ca: LateralCAModel,
                            vignette: VignetteGain?) -> ImageBuffer {
        let w = image.width, h = image.height
        let cx = Double(w) / 2, cy = Double(h) / 2
        let invNorm = 1 / (0.5 * (Double(w * w + h * h)).squareRoot())
        var out = image
        for y in 0..<h {
            for x in 0..<w {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let dx = px - cx, dy = py - cy
                let r2 = (dx * dx + dy * dy) * invNorm * invNorm
                let sr = ca.red.scale(r2: r2), sb = ca.blue.scale(r2: r2)
                var c = image[x, y]
                if sr != 1 { c.r = catmullRom(image, cx + dx * sr, cy + dy * sr, channel: 0) }
                if sb != 1 { c.b = catmullRom(image, cx + dx * sb, cy + dy * sb, channel: 2) }
                if let v = vignette {
                    let g = v.gain(r2: r2)
                    c = RGB(c.r * g, c.g * g, c.b * g)
                }
                out[x, y] = c
            }
        }
        return out
    }
}

// MARK: - Kernel sources (Core Image Kernel Language), beside their twins

public enum LensKernelSource {

    /// The log floor of the Defringe luminance window, both twins.
    public static let defringeFloor = 1e-5

    /// `LensStage.warp`. GENERAL: it samples away from the pixel it writes. Arguments:
    /// src (clamped to extent), centre, 1/half-diagonal, red (k0, k2), blue (k0, k2),
    /// vignette (a, b, c, enabled).
    public static let lens: String = {
        let comps = ["x", "y", "z", "w"]
        var taps: [String] = []
        for j in 0..<4 {
            for i in 0..<4 {
                taps.append("    acc += wx.\(comps[i]) * wy.\(comps[j]) * sample(src, "
                            + "samplerTransform(src, base + vec2(\(Double(i - 1)), \(Double(j - 1)))));")
            }
        }
        return """
    vec4 lumenLensWeights(float t) {
        float t2 = t * t;
        float t3 = t2 * t;
        return 0.5 * vec4(-t3 + 2.0 * t2 - t, 3.0 * t3 - 5.0 * t2 + 2.0,
                          -3.0 * t3 + 4.0 * t2 + t, t3 - t2);
    }
    vec4 lumenLensCatmullRom(sampler src, vec2 q) {
        vec2 f = q - 0.5;
        vec2 i0 = floor(f);
        vec2 t = f - i0;
        vec4 wx = lumenLensWeights(t.x);
        vec4 wy = lumenLensWeights(t.y);
        vec2 base = i0 + 0.5;
        vec4 acc = vec4(0.0);
    \(taps.joined(separator: "\n"))
        return acc;
    }
    kernel vec4 lumenLens(sampler src, vec2 centre, float invNorm, vec2 kr, vec2 kb, vec4 vig) {
        vec2 p = destCoord();
        vec2 d = p - centre;
        float r2 = dot(d, d) * invNorm * invNorm;
        float sr = 1.0 + kr.x + kr.y * r2;
        float sb = 1.0 + kb.x + kb.y * r2;
        vec4 c = sample(src, samplerTransform(src, p));
        float r = lumenLensCatmullRom(src, centre + d * sr).r;
        float b = lumenLensCatmullRom(src, centre + d * sb).b;
        vec3 rgb = vec3(r, c.g, b);
        float g = 1.0 + r2 * (vig.x + r2 * (vig.y + r2 * vig.z));
        rgb *= mix(1.0, g, vig.w);
        return vec4(rgb, c.a);
    }
    """
    }()

    /// log2 luminance with the floor, into all three channels — the window passes' input.
    public static let defringeLogLuma: String = {
        let w = DefringeStage.lumaWeights
        return """
        kernel vec4 lumenDefringeLogLuma(__sample s) {
            float y = dot(s.rgb, vec3(\(w.0), \(w.1), \(w.2)));
            float l = log2(max(y, \(defringeFloor)));
            return vec4(l, l, 1.0, 1.0);
        }
        """
    }()

    /// One separable pass of the window max (in r) and min (in g). `dir` is (1,0) or
    /// (0,1); `radius` ≤ 4, the loop bound fixed so every compiler accepts it.
    public static let defringeWindow = """
    kernel vec4 lumenDefringeWindow(sampler src, vec2 dir, float radius) {
        vec2 p = destCoord();
        vec4 c = sample(src, samplerTransform(src, p));
        float hi = c.r;
        float lo = c.g;
        for (int k = 1; k <= 4; k++) {
            float on = step(float(k), radius);
            vec4 a = sample(src, samplerTransform(src, p + dir * float(k)));
            vec4 b = sample(src, samplerTransform(src, p - dir * float(k)));
            hi = mix(hi, max(hi, max(a.r, b.r)), on);
            lo = mix(lo, min(lo, min(a.g, b.g)), on);
        }
        return vec4(hi, lo, 1.0, 1.0);
    }
    """

    /// `DefringeStage.pull`. `window` carries (max, min) log2 luminance.
    /// purple = (strength, lo°, hi°, _), green likewise.
    public static let defringeApply: String = {
        let m = DefringeStage.toLMS, m2 = DefringeStage.m2
        let w = DefringeStage.lumaWeights
        let e = DefringeStage.edgeStops, g = DefringeStage.chromaGate
        func row(_ r: [Double]) -> String { "vec3(\(r[0]), \(r[1]), \(r[2]))" }
        return """
        float lumenDefringeCbrt(float v) { return sign(v) * pow(abs(v), 1.0 / 3.0); }
        float lumenDefringeHueWeight(float h, float lo, float hi) {
            float centre = (lo + hi) * 0.5;
            float d = h - centre;
            d -= 360.0 * floor(d / 360.0 + 0.5);
            float outside = abs(d) - (hi - lo) * 0.5;
            return clamp(1.0 - outside / \(DefringeParams.hueFeather), 0.0, 1.0);
        }
        kernel vec4 lumenDefringeApply(__sample c, __sample window, vec4 purple, vec4 green) {
            float edge = smoothstep(\(e.lo), \(e.hi), window.r - window.g);
            vec3 rgb = c.rgb;
            float l = lumenDefringeCbrt(dot(\(row(m[0])), rgb));
            float m = lumenDefringeCbrt(dot(\(row(m[1])), rgb));
            float s = lumenDefringeCbrt(dot(\(row(m[2])), rgb));
            vec3 lms = vec3(l, m, s);
            float L = dot(\(row(m2[0])), lms);
            float a = dot(\(row(m2[1])), lms);
            float b = dot(\(row(m2[2])), lms);
            float chroma = sqrt(a * a + b * b);
            float gate = smoothstep(\(g.lo), \(g.hi), chroma / (max(L, 0.0) + 0.02));
            float h = degrees(atan(b, a));
            h += 360.0 * step(h, 0.0) * (1.0 - step(0.0, h));
            float wp = purple.x * lumenDefringeHueWeight(h, purple.y, purple.z);
            float wg = green.x * lumenDefringeHueWeight(h, green.y, green.z);
            float k = max(wp, wg) * gate * edge;
            float y = dot(rgb, vec3(\(w.0), \(w.1), \(w.2)));
            return vec4(rgb + (vec3(y) - rgb) * k, c.a);
        }
        """
    }()
}

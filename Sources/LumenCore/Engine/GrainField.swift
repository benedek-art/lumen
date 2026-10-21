// GrainField.swift
// The grain noise field (WS-40): per-pixel, stateless, procedural film grain.
//
// WHAT IT REPLACES. One 128 x 128 value-noise plate, scaled and tiled. Its period was
// 128 x scale px (64 px at a 1024 preview, 283 px at 4096), so the grain was a repeating
// wallpaper, and its coarse octave made soft blobs ten times larger than the stated
// pitch. The owner: "It looks nothing like actual grain... It looks like a print, a
// texture that I put on there."
//
// THE MODEL. Sparse convolution: the plane is cut into square cells of edge `cell`
// pixels; each cell holds a FIXED number of grains (`count`, fractional: the last one is
// weighted), each at a hashed position inside the cell with a hashed zero-mean height
// h ∈ (−1, 1) and a hashed radius. A grain lays the compact kernel
//
//     g · k(d),   k(d) = max(1 − d²/R², 0)²,   R² = r² + Rp²,   g = r² / R²
//
// where r is the grain's radius and Rp the pixel aperture (`pixelAperture`): the grain
// is seen through its pixel, so a grain much smaller than a pixel spreads to the
// pixel's size and loses amplitude in proportion (g, "ink conservation"). The kernel's
// largest support equals the cell edge, so the 3 x 3 cells around a pixel hold every
// grain that can reach it: the field is EXACT, with no tile and no lattice in it.
//
// Zero-mean independent heights with a fixed count per cell make the field exactly
// second-order stationary: its covariance depends on the lag only, with no trace of the
// cell grid in the mean or the variance (positive heights would need Poisson counts to
// get that, and a Poisson count needs a loop with no bound, which a shader cannot have).
//
// THE HASH, exact in float32 and in Double. Every value is an integer-valued float
// below 2^24, so the products, sums and floors are exact on the GPU and on the CPU and
// the two draw the same grains bit for bit. Two lanes, modulo the primes 4091 and 4079:
// both are ≡ 2 (mod 3), so the cube x ↦ x³ is a permutation of each residue ring, and
// 4090² < 2^24 keeps every product exact. The lanes are cross-mixed every round, so
// the state is the pair (a, b) — 16.7 M states — and each round's output depends on
// both coordinates. `GrainSpecTests` measures the cell streams: neighbour correlation,
// cross-stream correlation and the 2D spectrum of each stream are at white-noise level.
// (The lead's first prototype used the 289/251 rings with one cross-mix and drew a
// diagonal lattice at (±0.279, ±0.279) cyc/px at Size 0 — SPEC line 2a, 45-61 against a
// threshold of 60. This hash measures 12-20 on the rendered fields, white noise ~12.)
//
// ONE FORMULA, TWO IMPLEMENTATIONS. `KernelLibrary.grainFieldSource` (LumenPipeline) is
// the GPU twin of `GrainField.evaluate`; it interpolates every constant from this file,
// so neither side can carry a literal copy. KernelGoldenTests compares them on macOS CI.

import Foundation

/// The grain noise field for one render: one layer set per independent channel.
public struct GrainField: Sendable, Equatable {

    // MARK: Constants — shared by the CPU reference and the GPU kernel

    /// The two hash moduli. Primes ≡ 2 (mod 3), so cubing is a bijection; below 4096,
    /// so the square of a residue is an exact float32 integer.
    public static let primeA: Double = 4091
    public static let primeB: Double = 4079

    /// The most grains a cell holds — the kernel's constant loop bound.
    public static let maxGrains: Int = 6
    /// Grains per cell at Roughness 0, and how many Roughness 100 takes away (linear in
    /// between): 6 → 1.5. Fewer, sparser grains make a more impulsive field — distinct
    /// specks rather than an even texture (kurtosis 3.2 → 3.8, SPEC line 7b).
    public static let grainsAtRoughness0: Double = 6
    public static let grainsDroppedAtRoughness100: Double = 4.5
    /// The log2 spread of the grain radius at Roughness 100 (linear in between):
    /// r = R̄·2^(spread·(u − ½)), so ±0.8 stops of mixed speck sizes at 100.
    public static let radiusSpreadAtRoughness100: Double = 1.6
    /// The clump layer: a second field at `clumpScale` × the grain radius, mixed in at
    /// `clumpWeightAtRoughness100` × Roughness², so the middle of the slider stays close
    /// to plain grain (0.175 at 50) and the top end clumps visibly (0.7 at 100).
    /// Roughness 0 has no clump layer at all.
    public static let clumpScale: Double = 2.0
    public static let clumpWeightAtRoughness100: Double = 0.7

    /// The pixel aperture Rp, in render pixels — the radius of the kernel a pixel sees a
    /// point grain through, chosen so that the aperture behaves like the 1 px box an
    /// export's downsample averages with, which is what makes a preview equal the export
    /// box-downsampled (WS-40 SPEC line 8). The kernel (1 − d²/R²)² has the box's second
    /// moment (R²/8 = 1/12) at R = √(2/3) ≈ 0.816; its power spectrum matches the box's
    /// best over 0…0.25 cyc/px at R = 0.825, within 0.3% (numerically: the radial power
    /// of the box over that of the kernel, ten bins). The spectral match is the one SPEC
    /// line 8 measures, so it is the one used.
    public static let pixelAperture: Double = 0.825

    /// Seed offsets: per colour layer, and for the clump layer of the same channel.
    public static let channelSeedOffset: (a: Double, b: Double) = (37, 53)
    public static let clumpSeedOffset: (a: Double, b: Double) = (101, 57)

    // MARK: The field

    /// One sparse-convolution layer.
    public struct Layer: Sendable, Equatable {
        /// Cell edge in pixels: the largest kernel support at ANY roughness,
        /// √((R̄·2^(maxSpread/2))² + Rp²). It does not depend on the roughness, so the
        /// cells — and every grain's position and height — stay put while Roughness
        /// moves: dragging it morphs one pattern (grains fade out, radii spread, clumps
        /// fade in) instead of drawing a new one at every step.
        public let cell: Double
        /// Mean grain radius R̄, pixels.
        public let radius: Double
        /// log2 spread of the radius.
        public let spread: Double
        /// Grains per cell (fractional: grain j has weight clamp(count − j, 0, 1)).
        public let count: Double
        /// The hash lanes' seed states, integers in [0, primeA) and [0, primeB).
        public let seedA: Double
        public let seedB: Double
        /// What the layer's raw sum is multiplied by: the mix weight over the layer's
        /// RESOLVED standard deviation, so a pixel-resolved field is σ = 1.
        public let gain: Double

        public init(radius: Double, roughness: Double, seedA: Double, seedB: Double,
                    weight: Double) {
            let r = Num.clamp(roughness.isFinite ? roughness : 0.5, 0, 1)
            let rg = Swift.max(radius.isFinite ? radius : 0, 1e-4)
            let spread = GrainField.radiusSpreadAtRoughness100 * r
            let count = GrainField.grainsAtRoughness0
                - GrainField.grainsDroppedAtRoughness100 * r
            let rp = GrainField.pixelAperture
            let rMax = rg * pow(2, GrainField.radiusSpreadAtRoughness100 / 2)
            let cell = (rMax * rMax + rp * rp).squareRoot()
            self.cell = cell
            self.radius = rg
            self.spread = spread
            self.count = count
            self.seedA = seedA
            self.seedB = seedB
            // Resolved variance: λ·E[h²]·E[∫k_r²], with λ = Σwⱼ²/cell² grains per px²,
            // E[h²] = 1/3 for h uniform on (−1, 1), and ∫(1 − d²/r²)⁴ dA = πr²/5. The
            // aperture is left OUT on purpose: it is what lowers a sub-pixel grain's
            // per-pixel σ, exactly as averaging it into a larger pixel would.
            var w2 = 0.0
            for j in 0..<GrainField.maxGrains {
                let w = Num.clamp(count - Double(j), 0, 1)
                w2 += w * w
            }
            let er2 = spread > 0
                ? rg * rg * (pow(2, spread) - pow(2, -spread)) / (2 * spread * log(2.0))
                : rg * rg
            let variance = w2 / (cell * cell) / 3 * Double.pi * er2 / 5
            self.gain = variance > 0 ? weight / variance.squareRoot() : 0
        }
    }

    /// Per independent channel, its layers (a grain layer, plus a clump layer when the
    /// roughness asks for one). One channel means one field shared by R, G and B.
    public let channels: [[Layer]]

    /// - Parameters:
    ///   - radii: the mean grain radius, in pixels, of each independent channel.
    ///   - roughness: 0…1.
    ///   - seed: the photograph's grain seed.
    public init(radii: [Double], roughness: Double, seed: UInt64) {
        let r = Num.clamp(roughness.isFinite ? roughness : 0.5, 0, 1)
        let wc = GrainField.clumpWeightAtRoughness100 * r * r
        let norm = 1 / (1 + wc * wc).squareRoot()
        let base = GrainField.seedBase(seed)
        self.channels = radii.enumerated().map { c, radius in
            let ca = base.a + GrainField.channelSeedOffset.a * Double(c)
            let cb = base.b + GrainField.channelSeedOffset.b * Double(c)
            var layers = [Layer(radius: radius, roughness: r,
                                seedA: GrainField.cubeA(ca), seedB: GrainField.cubeB(cb),
                                weight: norm)]
            if wc > 0 {
                layers.append(Layer(
                    radius: radius * GrainField.clumpScale, roughness: r,
                    seedA: GrainField.cubeA(ca + GrainField.clumpSeedOffset.a),
                    seedB: GrainField.cubeB(cb + GrainField.clumpSeedOffset.b),
                    weight: wc * norm))
            }
            return layers
        }
    }

    /// The seed's two residues.
    public static func seedBase(_ seed: UInt64) -> (a: Double, b: Double) {
        let a = seed % UInt64(primeA)
        let b = (seed / UInt64(primeA)) % UInt64(primeB)
        return (Double(a), Double(b))
    }

    // MARK: The hash (the kernel's helpers are these, line for line)

    /// x mod n for an integer-valued x, by floor(x·(1/n)). The two fix-ups make a
    /// floor that is off by one — which a float32 x·(1/n) can be — harmless.
    @inline(__always)
    public static func mod(_ x: Double, _ n: Double) -> Double {
        var r = x - (x * (1 / n)).rounded(.down) * n
        if r >= n { r -= n }
        if r < 0 { r += n }
        return r
    }

    /// x³ mod primeA, a permutation of the residues.
    @inline(__always)
    public static func cubeA(_ x: Double) -> Double {
        let y = mod(x, primeA)
        return mod(mod(y * y, primeA) * y, primeA)
    }

    /// x³ mod primeB.
    @inline(__always)
    public static func cubeB(_ x: Double) -> Double {
        let y = mod(x, primeB)
        return mod(mod(y * y, primeB) * y, primeB)
    }

    /// The hash state of cell (cx, cy) in a layer seeded (sa, sb). Low and high digits
    /// of both coordinates enter, so the state is unique for |c| up to primeA·primeB
    /// cells, and every round crosses the two lanes.
    @inline(__always)
    public static func cellState(_ cx: Double, _ cy: Double, _ sa: Double, _ sb: Double)
        -> (a: Double, b: Double) {
        let lx = mod(cx, primeA)
        let hx = mod(((cx - lx) * (1 / primeA) + 0.5).rounded(.down), primeA)
        let ly = mod(cy, primeB)
        let hy = mod(((cy - ly) * (1 / primeB) + 0.5).rounded(.down), primeB)
        var a = cubeA(sa + lx)
        var b = cubeB(sb + ly)
        a = cubeA(a + ly + hy)
        b = cubeB(b + lx + hx)
        a = cubeA(a + b)
        b = cubeB(b + a)
        return (a, b)
    }

    /// Two uniforms in (0, 1) from a cell state and a stream index t (small integer).
    @inline(__always)
    public static func stream(_ a: Double, _ b: Double, _ t: Double) -> (Double, Double) {
        let a1 = cubeA(a + t)
        let b1 = cubeB(b + a1 + 3 * t)
        let a2 = cubeA(a1 + b1)
        let b2 = cubeB(b1 + a2)
        return ((a2 + 0.5) * (1 / primeA), (b2 + 0.5) * (1 / primeB))
    }

    /// Grain j of a cell: its position inside the cell (cell units, 0…1), its height
    /// (−1…1) and its radius factor's uniform. Streams 2j+1 and 2j+2.
    @inline(__always)
    public static func grain(_ state: (a: Double, b: Double), _ j: Int)
        -> (ux: Double, uy: Double, height: Double, uRadius: Double) {
        let p = stream(state.a, state.b, Double(2 * j + 1))
        let q = stream(state.a, state.b, Double(2 * j + 2))
        return (p.0, p.1, 2 * q.0 - 1, q.1)
    }

    // MARK: Evaluation (the CPU reference)

    /// The field over a `width × height` frame, one row-major, TOP-DOWN array per
    /// independent channel. Pixel (x, y) is evaluated at its centre (x + ½, y + ½).
    public func evaluate(width: Int, height: Int) -> [[Float]] {
        guard width > 0, height > 0 else { return channels.map { _ in [] } }
        return channels.map { layers in
            var out = [Float](repeating: 0, count: width * height)
            for layer in layers where layer.gain != 0 {
                GrainField.accumulate(layer, into: &out, width: width, height: height)
            }
            return out
        }
    }

    /// One layer's value at one point — the kernel's `lgLayer`, unoptimised. The tests
    /// use it to check `evaluate` and the kernel's arithmetic against one definition.
    public static func layerValue(_ layer: Layer, x: Double, y: Double) -> Double {
        let c = layer.cell
        let rp2 = pixelAperture * pixelAperture
        let bx = (x / c).rounded(.down), by = (y / c).rounded(.down)
        var acc = 0.0
        for dy in -1...1 {
            for dx in -1...1 {
                let cx = bx + Double(dx), cy = by + Double(dy)
                let st = cellState(cx, cy, layer.seedA, layer.seedB)
                for j in 0..<maxGrains {
                    let w = Num.clamp(layer.count - Double(j), 0, 1)
                    guard w > 0 else { continue }
                    let g = grain(st, j)
                    let ddx = x - (cx + g.ux) * c
                    let ddy = y - (cy + g.uy) * c
                    let rg = layer.radius * pow(2, layer.spread * (g.uRadius - 0.5))
                    let r2 = rg * rg + rp2
                    let k = Swift.max(1 - (ddx * ddx + ddy * ddy) / r2, 0)
                    acc += w * g.height * (rg * rg / r2) * k * k
                }
            }
        }
        return acc * layer.gain
    }

    /// Gather, in bands of rows run in parallel. Each band hashes the cell rows it
    /// touches once into a table of grains (absolute position, amplitude, 1/R²), then
    /// every pixel sums the grains of its 3 × 3 cells. Same arithmetic as `layerValue`.
    private static func accumulate(_ layer: Layer, into out: inout [Float],
                                   width: Int, height: Int) {
        let c = layer.cell
        let n = Int(Num.clamp(layer.count.rounded(.up), 0, Double(maxGrains)))
        guard n > 0 else { return }
        let rp2 = pixelAperture * pixelAperture
        var weights = [Double](repeating: 0, count: n)
        for j in 0..<n { weights[j] = Num.clamp(layer.count - Double(j), 0, 1) }
        // Cell columns −1 … colsMax + 1 cover every pixel's 3 × 3 neighbourhood.
        let cx0 = -1
        let cx1 = Int((Double(width) / c).rounded(.down)) + 1
        let cols = cx1 - cx0 + 1
        let bandRows = 16
        let bands = (height + bandRows - 1) / bandRows
        let gain = layer.gain
        out.withUnsafeMutableBufferPointer { buffer in
            let shared = UnsafeSendable(buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: bands) { band in
                let y0 = band * bandRows
                let y1 = Swift.min(height, y0 + bandRows)
                let cy0 = Int((Double(y0) + 0.5) / c) - 1
                let cy1 = Int((Double(y1) - 0.5) / c) + 1
                let rows = cy1 - cy0 + 1
                let base = shared.value
                // [row][col][grain] → (px, py, amplitude, 1/R²)
                var table = [Double](repeating: 0, count: rows * cols * n * 4)
                table.withUnsafeMutableBufferPointer { t in
                    for r in 0..<rows {
                        let cy = Double(cy0 + r)
                        for k in 0..<cols {
                            let cx = Double(cx0 + k)
                            let st = cellState(cx, cy, layer.seedA, layer.seedB)
                            for j in 0..<n {
                                let g = grain(st, j)
                                let rg = layer.radius
                                    * pow(2, layer.spread * (g.uRadius - 0.5))
                                let r2 = rg * rg + rp2
                                let o = ((r * cols + k) * n + j) * 4
                                t[o] = (cx + g.ux) * c
                                t[o + 1] = (cy + g.uy) * c
                                t[o + 2] = weights[j] * g.height * (rg * rg / r2)
                                t[o + 3] = 1 / r2
                            }
                        }
                    }
                    for y in y0..<y1 {
                        let py = Double(y) + 0.5
                        let by = Int((py / c).rounded(.down))
                        for x in 0..<width {
                            let px = Double(x) + 0.5
                            let bx = Int((px / c).rounded(.down))
                            var acc = 0.0
                            for dy in -1...1 {
                                let r = by + dy - cy0
                                for dx in -1...1 {
                                    let k = bx + dx - cx0
                                    var o = ((r * cols + k) * n) * 4
                                    for _ in 0..<n {
                                        let ddx = px - t[o], ddy = py - t[o + 1]
                                        let q = 1 - (ddx * ddx + ddy * ddy) * t[o + 3]
                                        if q > 0 { acc += t[o + 2] * q * q }
                                        o += 4
                                    }
                                }
                            }
                            base[y * width + x] += Float(acc * gain)
                        }
                    }
                }
            }
        }
    }

    private struct UnsafeSendable<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}

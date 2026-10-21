// CurveStage.swift
// S15, the tone curve, as its own stage: five 1-D tables and the luminance rule, instead
// of a passenger in the 3-D finish cube.
//
// WHY THIS EXISTS. The curve is baked into `RenderPlan.finishLUT` together with picture
// formation, and that cube's lattice is LumenLog-shaped: 24 stops over 32 cells, about
// eleven nodes across the whole visible range at the interactive size of 33. Any curve
// feature narrower than a cell is replaced by trilinear chords. Measured on grey_ramp,
// |rendered − drawn| in 8-bit codes (T2 audit, docs/quality/lanes/WS-12b):
//
//     curve                               cube 33    cube 65
//     S  [[0,0],[.25,.15],[.75,.85],[1,1]]     9          1
//     steep [[0,0],[.4,.1],[.6,.9],[1,1]]     33         19
//     dip [[0,0],[.3,.8],[.35,.2],[1,1]]     101         81
//     parametric H −100 / S +100               6          2
//
// and a steep curve on a blue sky turned 244°→272° in the preview while the exact curve
// held 258°→253°. The graph is the model, the editor says; through the cube it was not.
//
// The curve is a function of ONE encoded value per lookup — the luminance, or one
// channel — so it does not need a 3-D table at all. Five 1-D tables of `tableSize`
// samples, linearly interpolated, hold any curve the editor can draw to a small fraction
// of a code (`CurveStageTests`), and the luminance coupling is a handful of arithmetic
// operations per pixel. `run` below is `CurveStack.apply`'s own body with the curves
// handed in as table lookups, so the stage and the definition cannot drift.
//
// WIRED (WS-01). `RenderPlan` bakes the finish cube WITHOUT the curve and publishes this
// stage as `plan.curveStage` (memoized per curve set by `CurveStageMemo`, so a drag of any
// other slider pays nothing for it); `RenderPlan.finishedColor` runs it after the cube on
// the CPU, and `RenderGraph.applyCurveStage` runs `kernelSource` below after the same
// cube on the GPU. With a soft proof on the curve stays inside the cube, because the
// proof is composed onto the cube's end and must see the curved picture.

import Foundation

public struct CurveStage: Sendable {

    /// Samples per table. The steepest curve the point editor can make — two points
    /// `minimumPointGap` apart, a 0.9 rise across 0.004 — is the case that sets it: at
    /// 4096 it read up to 1.07 codes off, at 8192 a quarter of that (`CurveStageTests`).
    /// 32 KB a table, and well inside any GPU's 1-D texture limit.
    public static let tableSize: Int = 8192

    /// The five curves in `CurveStack.run`'s order — master, luma, R, G, B — each nil
    /// when it is the identity, so a stage with only a red curve runs one lookup.
    public let master: [Float]?
    public let luma: [Float]?
    public let channels: [[Float]?]
    public let masterBlack: Float
    public let lumaBlack: Float
    public let preserveLuminance: Bool
    public let encoding: TransferFunction
    public let isIdentity: Bool

    public init(_ stack: CurveStack, size: Int = CurveStage.tableSize) {
        let n = Swift.max(2, size)
        func table(_ f: (Double) -> Double) -> [Float] {
            (0..<n).map { Float(f(Double($0) / Double(n - 1))) }
        }
        let active = stack.activeCurves
        self.master = active.master ? table { stack.master($0) } : nil
        self.luma = active.luma ? table { stack.lumaCurve($0) } : nil
        self.channels = (0..<3).map { c in
            active.channels[c] ? table { stack.channelCurve($0, channel: c) } : nil
        }
        self.masterBlack = Float(stack.masterBlack)
        self.lumaBlack = Float(stack.lumaBlack)
        self.preserveLuminance = stack.set.preserveLuminance
        self.encoding = stack.encoding
        self.isIdentity = stack.isIdentity
    }

    /// One table read on the encoded axis: clamped to [0, 1] (the curves clamp their
    /// own input), linear between samples — the same read a GPU's linear sampler on a
    /// `tableSize`-wide texture makes with its half-texel offsets.
    public static func lookup(_ table: [Float], _ x: Double) -> Double {
        let n = table.count
        guard n > 1 else { return n == 1 ? Double(table[0]) : x }
        // NaN reads the black end rather than trapping in `Int(_:)`; the stage's job is
        // not to be the place a bad pixel takes the renderer down.
        guard !x.isNaN else { return Double(table[0]) }
        let t = Num.saturate(x) * Double(n - 1)
        let i = Swift.min(Int(t), n - 2)
        let f = t - Double(i)
        return Double(table[i]) + (Double(table[i + 1]) - Double(table[i])) * f
    }

    /// The stage on a display-linear colour — `CurveStack.apply`'s domain and contract.
    public func apply(_ c: RGB, white: Double = 1, space: RGBColorSpace = .rec2020) -> RGB {
        guard !isIdentity else { return c }
        func read(_ table: [Float]?) -> ((Double) -> Double)? {
            guard let table else { return nil }
            return { CurveStage.lookup(table, $0) }
        }
        return CurveStack.run(c, white: white, space: space, encoding: encoding,
                              preserveLuminance: preserveLuminance,
                              master: read(master), masterBlack: Double(masterBlack),
                              luma: read(luma), lumaBlack: Double(lumaBlack),
                              channels: channels.map(read))
    }
}

// MARK: - The GPU twin

extension CurveStage {

    /// Rows of the GPU's table image, in `CurveStack.run`'s order.
    public static let rows = 5

    /// The five tables as an RGBAf image's bytes, `tableSize` wide and `rows` tall:
    /// texel (i, k) holds row k's sample i in all three colour channels, alpha 1. An
    /// identity curve's row is the identity ramp (the kernel skips it anyway, by flag).
    /// Row 0 first, which `CIImage(bitmapData:)` puts at the TOP of the image, so the
    /// kernel reads row k at y = rows − 0.5 − k.
    public var atlasRGBA: [Float] {
        let n = master?.count ?? luma?.count ?? channels.compactMap { $0 }.first?.count
            ?? CurveStage.tableSize
        let ramp = (0..<n).map { Float(Double($0) / Double(Swift.max(n - 1, 1))) }
        let tables = [master, luma, channels[0], channels[1], channels[2]].map { $0 ?? ramp }
        var out = [Float](repeating: 1, count: n * CurveStage.rows * 4)
        for (k, table) in tables.enumerated() {
            for i in 0..<n {
                let v = table[i], o = (k * n + i) * 4
                out[o] = v; out[o + 1] = v; out[o + 2] = v
            }
        }
        return out
    }

    /// The samples per row of `atlasRGBA`.
    public var atlasWidth: Int {
        master?.count ?? luma?.count ?? channels.compactMap { $0 }.first?.count
            ?? CurveStage.tableSize
    }

    /// The uniforms `kernelSource` takes after its two images, in order:
    /// `n`, `on` = (master, luma, preserve luminance, any channel), `ch` = per-channel
    /// flags, `p` = (white, top, master black, luma black), `w` = luminance weights.
    /// `white` is the white of the pixels arriving (`finishScale`), exactly as
    /// `apply(_:white:space:)` takes it; `top` is `CurveStack.run`'s.
    public func kernelUniforms(white: Double, space: RGBColorSpace)
        -> (n: Double, on: [Double], ch: [Double], p: [Double], w: [Double]) {
        let w = Swift.max(white, 1e-6)
        let top = w <= 1 ? 1 : Swift.max(1, encoding.encode(w))
        let weights = space.luminanceWeights
        let flag: (Bool) -> Double = { $0 ? 1 : 0 }
        let anyChannel = channels.contains { $0 != nil }
        return (Double(atlasWidth),
                [flag(master != nil), flag(luma != nil), flag(preserveLuminance),
                 flag(anyChannel)],
                channels.map { flag($0 != nil) },
                [w, top, Double(masterBlack), Double(lumaBlack)],
                [weights.r, weights.g, weights.b])
    }

    /// `CurveStack.run`, line for line, as a Core Image kernel over `atlasRGBA`.
    /// sRGB encoding only — the one `RenderPlan` builds the stack with; the graph
    /// declines the stage (and the render goes to the CPU path) for any other.
    ///
    /// Every table read is `lookup` exactly: the input clamped to [0, 1], two texels,
    /// linear between them by hand rather than through the sampler's filter (whose
    /// weights are not promised to be float), plus `extended`'s unit-slope continuation
    /// above 1 — `f(clamp(x)) + max(min(x, top) − 1, 0)`, which is `f(x)` for x ≤ 1 and
    /// `f(1) + (min(x, top) − 1)` above. Written out per read because a kernel helper
    /// cannot take the sampler.
    public static let kernelSource: String = {
        func read(_ out: String, _ row: Int, _ x: String) -> String {
            let y = "\(Double(rows - 1 - row) + 0.5)"
            return """
                float \(out)T = clamp(\(x), 0.0, 1.0) * (n - 1.0);
                float \(out)I = min(floor(\(out)T), n - 2.0);
                float \(out)A = sample(tables, samplerTransform(tables, vec2(\(out)I + 0.5, \(y)))).r;
                float \(out)B = sample(tables, samplerTransform(tables, vec2(\(out)I + 1.5, \(y)))).r;
                float \(out) = \(out)A + (\(out)B - \(out)A) * (\(out)T - \(out)I)
                    + max(min(\(x), top) - 1.0, 0.0);

            """
        }
        // `CurveStack.liftedLuma` (row 0 or 1), on `e` with luminance `lum`, black `b`.
        func lifted(_ tag: String, _ row: Int, _ b: String) -> String {
            """
                float \(tag)L = max(lum, 1e-6);
            \(read("\(tag)F", row, "\(tag)L"))
                vec3 \(tag)Neutral = e * ((\(tag)F - \(b)) / \(tag)L) + vec3(\(b));
                if (lum > 1e-6) {
                    float \(tag)S = clamp(lum / \(b), 0.0, 1.0);
                    float \(tag)W = \(tag)S * \(tag)S * (3.0 - 2.0 * \(tag)S);
                    e = mix(\(tag)Neutral, e * (\(tag)F / \(tag)L), \(tag)W);
                } else {
                    e = \(tag)Neutral;
                }

            """
        }
        func perChannel(_ tag: String, _ rowFor: (Int) -> Int, guarded: Bool) -> String {
            var body = ""
            for (c, name) in ["r", "g", "b"].enumerated() {
                let r = read("\(tag)\(name.uppercased())", rowFor(c), "e.\(name)")
                if guarded {
                    body += "    if (ch.\(["x", "y", "z"][c]) > 0.5) {\n\(r)        e.\(name) = \(tag)\(name.uppercased());\n    }\n"
                } else {
                    body += "\(r)    e.\(name) = \(tag)\(name.uppercased());\n"
                }
            }
            return body
        }
        return """
        float lumenCurveEncode(float x) {
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(max(x, 0.0), 1.0 / 2.4) - 0.055;
        }
        float lumenCurveDecode(float x) {
            return x <= 0.04045 ? x / 12.92 : pow(max((x + 0.055) / 1.055, 0.0), 2.4);
        }
        kernel vec4 lumenCurveStage(sampler image, sampler tables, float n, vec4 on, vec3 ch,
                                    vec4 p, vec3 w) {
            vec4 s = sample(image, samplerCoord(image));
            float top = p.y;
            vec3 c = clamp(s.rgb, 0.0, p.x);
            vec3 e = vec3(lumenCurveEncode(c.r), lumenCurveEncode(c.g), lumenCurveEncode(c.b));
            float lum = 0.0;
            if (on.x > 0.5) {
                if (on.z > 0.5) {
                    lum = clamp(dot(e, w), 0.0, top);
                    if (p.z > 0.0) {
        \(lifted("m", 0, "p.z"))
                    } else if (lum > 1e-6) {
        \(read("mY", 0, "lum"))
                        e = e * (mY / lum);
                    } else {
        \(perChannel("mz", { _ in 0 }, guarded: false))
                    }
                } else {
        \(perChannel("mc", { _ in 0 }, guarded: false))
                }
            }
            if (on.y > 0.5) {
                lum = clamp(dot(e, w), 0.0, top);
                if (p.w > 0.0) {
        \(lifted("l", 1, "p.w"))
                } else if (lum > 1e-6) {
        \(read("lY", 1, "lum"))
                    e = e * (lY / lum);
                }
            }
            if (on.w > 0.5) {
        \(perChannel("k", { 2 + $0 }, guarded: true))
            }
            e = clamp(e, 0.0, top);
            return vec4(lumenCurveDecode(e.r), lumenCurveDecode(e.g), lumenCurveDecode(e.b), s.a);
        }
        """
    }()
}

// MARK: - The plan's cache

/// `CurveStage` per curve set, remembered across plans. Building one runs the
/// parametric bake and 40 960 curve evaluations — a few milliseconds that a plan pays
/// on every frame of every drag unless the stage is held — and the stage is a pure
/// function of the set, so a held one is the same stage. Four entries: a drag revisits
/// one set, and before/after or a second pane alternate between two.
public enum CurveStageMemo {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [(set: CurveSet, stage: CurveStage?)] = []
    static let capacity = 4

    /// The stage for `set`, or nil when its curve is the identity (no stage to run).
    public static func stage(for set: CurveSet) -> CurveStage? {
        lock.lock()
        if let i = entries.firstIndex(where: { $0.set == set }) {
            let hit = entries.remove(at: i)
            entries.append(hit)
            lock.unlock()
            return hit.stage
        }
        lock.unlock()
        let stack = CurveStack(set)
        let stage: CurveStage? = stack.isIdentity ? nil : CurveStage(stack)
        lock.lock()
        entries.removeAll { $0.set == set }
        entries.append((set, stage))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
        return stage
    }
}

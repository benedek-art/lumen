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
// NOT YET WIRED (docs/quality/lanes/WS-12b/NEEDS.md). The finish cube still bakes the
// curve; moving the curve out of `RenderPlan`'s `display` closure and running this after
// the cube, on the CPU reference and as a Core Image kernel on the GPU, belongs to the
// lane that owns `RenderPlan.init`, `ReferenceRenderer.render` and `RenderGraph`.

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

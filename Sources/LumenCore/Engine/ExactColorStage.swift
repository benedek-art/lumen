// ExactColorStage.swift
// S9 — the whole of `ColorEngine` — evaluated exactly, every time, with no table.
//
// WHY THIS EXISTS (AI-03). S9 used to be baked, together with S10, into one 33³/65³ cube
// over per-channel log RGB. The colour tools are hue- and chroma-selective, and a lattice
// with 0.75 EV between knots cannot hold a 0.02→0.06 chroma gate or a ±22.5° band edge:
// Aqua Luminance −100 rendered 51/37 code equivalents off the intended operation on the
// GPU (39.8/35.8 on the CPU's tetrahedral sampler), Saturation +100 14/31 (12.2/37.4).
// A bigger cube made one of those WORSE. EXECUTION-05 then showed that switching to an
// exact route only for "eligible" recipes is worse still: the cube's error becomes a
// 50-code jump the moment a second control moves by 0.001.
//
// So the split is by STAGE, never by recipe. S9 always runs here; only S10 (the grade)
// stays in a cube, baked and skipped exactly as before. A control crossing zero changes
// one exact operation by an exact amount, and no recipe ever changes route.
//
// SHAPE. The stage is a fixed sequence of four pass kinds, each one Core Image colour
// kernel (`LumenPipeline/Kernels.swift`) and each one a Swift twin below that executes
// the same operations, in the same order, on the same Float32 uniforms:
//
//     primaries  remap matrix + Shadows Tint          (absent when both are identity)
//     mixer      eight bands, H/S/L, Uniformity        (absent when the Mixer is flat)
//     point      ONE swatch, creation order, ×n        (one pass per live swatch)
//     finish     Vibrance/Saturation, then B&W, then the stage's non-finite fallback
//
// More than one kernel because of two hard limits, not taste: the recipe does not bound
// the number of Point Colour swatches (the panel stops at 8, a sidecar need not), and the
// Mixer alone needs 29 kernel arguments — the most the EXECUTION-05 exact-Mixer kernel
// (since retired) was qualified with on device. Core Image concatenates adjacent colour kernels into one program, so
// the chain costs no intermediate buffer where it is linear.
//
// THE TWIN IS NOT THE ORACLE. `ColorEngine.apply` (Double) stays the independent
// reference every test compares against; this file is the implementation under test, on
// both processors. The CPU renderers run the twin, not `ColorEngine.apply`, so the CPU
// fallback and the GPU graph execute one algorithm on one set of Float32 parameters —
// the only remaining difference is the GPU's own transcendental approximations, which
// the macOS suite bounds directly.
//
// Exactly-unreachable branch, stated: `ColorEngine.bandWeights` hands all the weight to
// the nearest band when every membership is under 1e-6. The sanitizer's minimum reach
// (27.5° against a 22.5° half-spacing) makes that impossible for any arcs the engine
// can hold, so the kernel does not carry it; `ExactColorStageTests` sweeps the
// extreme-arc corners to prove the floor.

import Foundation

public struct ExactColorStage: Sendable, Equatable {

    /// One pass of the stage: which kernel, and its uniform vectors in the order the
    /// kernel declares them (after its `__sample` arguments).
    public struct Pass: Sendable, Equatable {
        public enum Kernel: String, Sendable, CaseIterable {
            case primaries, mixer, point, finish
        }
        public let kernel: Kernel
        public let uniforms: [SIMD4<Float>]
        /// A `point` pass's second input: true when the swatch's Variance needs the
        /// fixed pre-Mixer reference (the image after `primaries`). When false the
        /// kernel ignores its second sample and the graph passes the current image, so
        /// no branch of the graph has to be kept alive for nothing.
        public let readsReference: Bool
    }

    /// True when the stage cannot move a pixel — exactly `ColorEngine.isIdentity`.
    public let isIdentity: Bool
    /// Empty when `isIdentity`; otherwise ends with exactly one `finish` pass.
    public let passes: [Pass]

    // MARK: - Resolution (from the engine's own sanitized state)

    /// Parameters as `ColorEngine` resolved them. Built only by `ColorEngine.exactStage`,
    /// so sanitization, clamps, measured band hues and the compiled swatch list are the
    /// engine's — there is no second interpretation of the recipe here.
    struct Resolved {
        var isIdentity: Bool
        var context: OKLabTransform.Context
        var remap: Mat3?
        var tint: (a: Double, b: Double)?
        var luma: RGB
        /// Per band: centre, coreBelow, coreAbove, featherBelow, featherAbove, hue°, sat, lum, target°.
        var mixer: (bands: [[Double]], q: Double)?
        /// Per swatch: L, C, h, σL, σC, σH, shiftH, shiftS, shiftL, q.
        var swatches: [[Double]]
        var vibranceSaturation: (vibrance: Double, saturation: Double,
                                 protectSkin: Double, density: Double)?
        /// Eight `band/100 · bwKappa` gains when the treatment is on.
        var blackAndWhite: [Double]?
    }

    init(_ r: Resolved) {
        isIdentity = r.isIdentity
        guard !r.isIdentity else {
            passes = []
            return
        }
        let conversion = Self.pack([r.context.rgbToLMS, OKLabTransform.lmsToLab,
                                    OKLabTransform.labToLMS, r.context.lmsToRGB]
            .flatMap { m in m.m.flatMap { $0 } })
        precondition(conversion.count == 9)
        let centres = Self.pack(ColorEngine.bandHueCentres)
        var out: [Pass] = []

        if r.remap != nil || r.tint != nil {
            var u = conversion
            let m = r.remap ?? .identity
            for row in m.m { u.append(Self.v(row[0], row[1], row[2], 0)) }
            u.append(Self.v(r.tint?.a ?? 0, r.tint?.b ?? 0,
                            r.remap == nil ? 0 : 1, r.tint == nil ? 0 : 1))
            u.append(Self.v(r.luma.r, r.luma.g, r.luma.b, 0))
            out.append(Pass(kernel: .primaries, uniforms: u, readsReference: false))
        }

        if let mixer = r.mixer {
            var u = conversion + centres
            for band in mixer.bands { u.append(Self.v(band[1], band[2], band[3], band[4])) }
            u += Self.pack(mixer.bands.flatMap { [$0[5], $0[6], $0[7]] })
            u += Self.pack(mixer.bands.map { $0[8] })
            u.append(Self.v(mixer.q, 0, 0, 0))
            precondition(u.count == 28, "the Mixer kernel's argument budget")
            out.append(Pass(kernel: .mixer, uniforms: u, readsReference: false))
        }

        for s in r.swatches {
            let u = conversion + [Self.v(s[0], s[1], s[2], s[3]),
                                  Self.v(s[4], s[5], s[6], s[7]),
                                  Self.v(s[8], s[9], 0, 0)]
            out.append(Pass(kernel: .point, uniforms: u, readsReference: s[9] != 0))
        }

        var u = conversion
        let vs = r.vibranceSaturation
        u.append(Self.v(vs?.vibrance ?? 0, vs?.saturation ?? 0,
                        vs?.protectSkin ?? 0, vs?.density ?? 0))
        u.append(Self.v(r.luma.r, r.luma.g, r.luma.b, HelmholtzKohlrausch.kBr))
        u.append(Self.v(vs == nil ? 0 : 1, r.blackAndWhite == nil ? 0 : 1, 0, 0))
        u += centres
        u += Self.pack(r.blackAndWhite ?? [Double](repeating: 0, count: 8))
        out.append(Pass(kernel: .finish, uniforms: u, readsReference: false))
        passes = out
    }

    private static func v(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> SIMD4<Float> {
        SIMD4<Float>(Float(x), Float(y), Float(z), Float(w))
    }

    private static func pack(_ values: [Double]) -> [SIMD4<Float>] {
        var padded = values
        while padded.count % 4 != 0 { padded.append(0) }
        var out: [SIMD4<Float>] = []
        var i = 0
        while i < padded.count {
            out.append(v(padded[i], padded[i + 1], padded[i + 2], padded[i + 3]))
            i += 4
        }
        return out
    }

    // MARK: - The CPU twin

    /// The stage at one pixel, through the same passes and uniforms the GPU runs.
    public func apply(_ c: RGB) -> RGB {
        guard !isIdentity else { return c }
        guard c.isFinite else { return c }
        let out = ExactColorTwin.run(passes, SIMD3<Float>(Float(c.r), Float(c.g), Float(c.b)))
        return RGB(Double(out.x), Double(out.y), Double(out.z))
    }

    /// The stage over a whole buffer, on its own Float32 pixels. Rows run concurrently:
    /// the per-pixel work is independent and the CPU fallback renders full-resolution
    /// exports through here. Alpha is untouched.
    public func apply(to image: ImageBuffer) -> ImageBuffer {
        guard !isIdentity else { return image }
        var out = image
        let width = image.width
        let passes = self.passes
        out.pixels.withUnsafeMutableBufferPointer { buffer in
            let pixels = UnsafeSendable(buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: image.height) { y in
                var i = y * width * 4
                for _ in 0..<width {
                    let c = SIMD3<Float>(pixels.value[i], pixels.value[i + 1], pixels.value[i + 2])
                    // `ColorEngine.apply`'s first guard: a non-finite pixel passes through.
                    if ExactColorTwin.finite(c) {
                        let o = ExactColorTwin.run(passes, c)
                        pixels.value[i] = o.x
                        pixels.value[i + 1] = o.y
                        pixels.value[i + 2] = o.z
                    }
                    i += 4
                }
            }
        }
        return out
    }

    private struct UnsafeSendable<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }
}

// MARK: - Twin arithmetic
//
// Every function below has a same-named counterpart in `KernelSource` and they must be
// read side by side: same operations, same order, same constants, Float32 throughout.
// Where the kernel language has no direct spelling (finiteness, `atan(0, 0)`), both
// sides spell it the same explicit way.

enum ExactColorTwin {
    typealias F3 = SIMD3<Float>
    typealias U = [SIMD4<Float>]

    static func run(_ passes: [ExactColorStage.Pass], _ input: F3) -> F3 {
        var image = input
        var reference = input
        for pass in passes {
            switch pass.kernel {
            case .primaries:
                image = primaries(image, pass.uniforms)
                reference = image
            case .mixer:
                image = mixer(image, pass.uniforms)
            case .point:
                image = point(image, pass.readsReference ? reference : image, pass.uniforms)
            case .finish:
                image = finish(image, input, pass.uniforms)
            }
        }
        return image
    }

    // ---- shared helpers ----

    @inline(__always) static func e(_ u: U, _ k: Int) -> Float { u[k >> 2][k & 3] }

    /// `vec3(dot-row …)` over nine packed elements starting at `k`.
    @inline(__always) static func mul(_ u: U, _ k: Int, _ v: F3) -> F3 {
        F3(e(u, k) * v.x + e(u, k + 1) * v.y + e(u, k + 2) * v.z,
           e(u, k + 3) * v.x + e(u, k + 4) * v.y + e(u, k + 5) * v.z,
           e(u, k + 6) * v.x + e(u, k + 7) * v.y + e(u, k + 8) * v.z)
    }

    @inline(__always) static func finite(_ v: F3) -> Bool {
        abs(v.x) < 3.0e38 && abs(v.y) < 3.0e38 && abs(v.z) < 3.0e38
    }

    @inline(__always) static func sgn(_ x: Float) -> Float { x > 0 ? 1 : (x < 0 ? -1 : 0) }

    @inline(__always) static func cbrt3(_ x: F3) -> F3 {
        // Signed root, then one Newton step: the kernel's `pow` is approximate and a cone
        // response near cancellation is amplified by the root (EXECUTION-05).
        func one(_ v: Float) -> Float {
            let n = sgn(v) * pow(abs(v), 0.333333333)
            return (2 * n + v / max(n * n, 1e-30)) / 3
        }
        return F3(one(x.x), one(x.y), one(x.z))
    }

    @inline(__always) static func toLab(_ c: F3, _ u: U) -> F3 {
        mul(u, 9, cbrt3(mul(u, 0, c)))
    }

    @inline(__always) static func toRGB(_ lab: F3, _ u: U) -> F3 {
        let n = mul(u, 18, lab)
        return mul(u, 27, n * n * n)
    }

    /// (L, C, h°) from Lab. `atan(0, 0)` is spelled out because the kernel language does
    /// not promise it.
    @inline(__always) static func lch(_ lab: F3) -> F3 {
        let C = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        var h: Float = C > 0 ? atan2(lab.z, lab.y) * 57.2957795 : 0
        if h < 0 { h += 360 }
        if h >= 360 { h = 0 }
        return F3(lab.x, C, h)
    }

    @inline(__always) static func lab(_ lch: F3) -> F3 {
        let r = lch.z * 0.0174532925
        return F3(lch.x, lch.y * cos(r), lch.y * sin(r))
    }

    @inline(__always) static func wrapHue(_ h: Float) -> Float {
        var x = h - 360 * (h / 360).rounded(.down)
        if x >= 360 { x = 0 }
        return x
    }

    /// Signed `b − a` on the circle, in (−180, 180] like `Num.hueDelta`.
    @inline(__always) static func hueDelta(_ a: Float, _ b: Float) -> Float {
        let d0 = b - a
        var d = d0 - 360 * ((d0 + 180) / 360).rounded(.down)
        if d <= -180 { d += 360 }
        return d
    }

    @inline(__always) static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always) static func gate(_ C: Float) -> Float { smoothstep(0.02, 0.06, C) }

    @inline(__always) static func lumShape(_ L: Float) -> Float {
        let t = min(max(L, 0), 0.5)
        return t * (1 - t)
    }

    /// One band's raised-cosine membership before normalization.
    @inline(__always) static func membership(_ h: Float, _ centre: Float, _ arc: SIMD4<Float>) -> Float {
        let d = hueDelta(centre, h)
        let below = max(0, -d - arc.x)
        let above = max(0, d - arc.y)
        let t = max(below / arc.z, above / arc.w)
        return 0.5 + 0.5 * cos(min(max(t, 0), 1) * 3.14159265)
    }

    // ---- primaries: remap, then Shadows Tint ----

    static func primaries(_ c: F3, _ u: U) -> F3 {
        guard finite(c) else { return c }
        let flags = u[12]
        var out = c
        if flags.z > 0.5 {
            out = F3(u[9].x * c.x + u[9].y * c.y + u[9].z * c.z,
                     u[10].x * c.x + u[10].y * c.y + u[10].z * c.z,
                     u[11].x * c.x + u[11].y * c.y + u[11].z * c.z)
        }
        if flags.w > 0.5 {
            let y = u[13].x * out.x + u[13].y * out.y + u[13].z * out.z
            let ev = y > 0 ? max(log2(y / 0.18), -20) : -20
            let s = (ev + 3) / 1.5
            let step: Float = s <= -1 ? 0 : (s >= 1 ? 1 : 0.5 * (1 - cos(3.14159265 * ((s + 1) / 2))))
            let w = 1 - step
            if w > 0 {
                var l = toLab(out, u)
                if finite(l) {
                    l.y += w * flags.x
                    l.z += w * flags.y
                    out = toRGB(l, u)
                }
            }
        }
        return out
    }

    // ---- mixer: eight bands, summed before applying, Uniformity on the flat path ----

    static func mixer(_ c: F3, _ u: U) -> F3 {
        let l = lch(toLab(c, u))
        guard finite(l) else { return c }
        let h = l.z
        var w = SIMD8<Float>()
        var total: Float = 0
        for i in 0..<8 {
            w[i] = membership(h, e(u, 36 + i), u[11 + i])
            total += w[i]
        }
        let g = gate(l.y)
        var hueSum: Float = 0, satSum: Float = 0, lumSum: Float = 0
        var tx: Float = 0, ty: Float = 0
        for i in 0..<8 {
            let weight = w[i] / total * g
            hueSum += weight * e(u, 76 + 3 * i)
            satSum += weight * e(u, 77 + 3 * i)
            lumSum += weight * e(u, 78 + 3 * i)
            let r = e(u, 100 + i) * 0.0174532925
            tx += weight * cos(r)
            ty += weight * sin(r)
        }
        let q = u[27].x
        var converge: Float = 0
        if q != 0 && g != 0 && tx * tx + ty * ty > 1e-12 {
            let blended = atan2(ty, tx) * 57.2957795
            let moved = wrapHue(h + q * g * hueDelta(blended, h))
            converge = hueDelta(h, moved)
        }
        let L = l.x + lumSum * lumShape(l.x)
        let C = l.y * max(0, 1 + satSum)
        return toRGB(lab(F3(L, C, wrapHue(h + hueSum + converge))), u)
    }

    // ---- point: one swatch against the fixed pre-Mixer reference ----

    static func point(_ c: F3, _ ref: F3, _ u: U) -> F3 {
        let l = lch(toLab(c, u))
        guard finite(l) else { return c }
        let t = u[9], s = u[10], k = u[11]
        let dL = l.x - t.x
        let dC = l.y - t.y
        let dh = hueDelta(t.z, l.z)
        let dH = gate(min(l.y, t.y)) * (abs(dh) / 180)
        let a = dL / t.w, b = dC / s.x, cc = dH / s.y
        let d = (a * a + b * b + cc * cc).squareRoot()
        guard d.isFinite else { return c }
        let weight = 1 - smoothstep(0.5, 1, d)
        guard weight > 0 else { return c }
        var L = l.x, C = l.y, h = l.z
        let g = gate(l.y)
        let q = k.y
        if q != 0 {
            var mu = lch(toLab(ref, u))
            if !finite(mu) { mu = l }
            h = wrapHue(h + q * (weight * g) * hueDelta(t.z, mu.z))
            C = C + q * weight * (mu.y - t.y)
            L = L + q * 0.5 * weight * (mu.x - t.x)
        }
        h += weight * g * s.z
        C = max(0, C * (1 + weight * s.w / 100))
        L += weight * (k.x / 100) * lumShape(L)
        return toRGB(lab(F3(L, C, wrapHue(h))), u)
    }

    // ---- finish: Vibrance/Saturation, B&W off the pre-Saturation colour, fallback ----

    @inline(__always) static func hkFactor(_ C: Float, _ h: Float, _ kBr: Float) -> Float {
        let t = wrapHue(h) * 0.0174532925
        let q: Float = -0.01585
            - 0.03017 * cos(t) - 0.04556 * cos(2 * t)
            - 0.04256 * cos(3 * t) - 0.00295 * cos(4 * t)
            + 0.14592 * sin(t) + 0.05084 * sin(2 * t)
            - 0.01900 * sin(3 * t) - 0.00764 * sin(4 * t)
        return 1 + (-0.1340 * q + 0.0872 * kBr) * (max(0, C) * 4) * 0.1
    }

    @inline(__always) static func satCompress(_ x: Float) -> Float {
        x > 0.18 ? 0.34 - 0.16 * exp(-(x - 0.18) / 0.16) : x
    }

    static func chromaScale(_ c: F3, _ gain: Float, _ u: U, _ kBr: Float) -> F3 {
        let l = lch(toLab(c, u))
        let J = l.x * hkFactor(l.y, l.z, kBr)
        guard finite(F3(J, l.y, 0)) else { return c }
        let base = max(0, l.y)
        let g = max(0, gain)
        let reference = satCompress(base)
        let C = reference > 1e-12 ? satCompress(base * g) * base / reference : base * g
        let f = hkFactor(C, l.z, kBr)
        let L = f == 0 ? J : J / f
        // As a DELTA between two round trips, not the round trip itself. The two are
        // equal in exact arithmetic (`toRGB(lab(l)) == c`), but in Float32 the round
        // trip is ~1e-7 off, and Density blends this against `subtractive`, which is
        // exact on a neutral — so a grey moved with Density at the round trip's error.
        // The delta cancels it: a colour whose chroma does not change comes back as
        // itself, bit for bit, as it does in `ColorEngine`'s Double arithmetic.
        let moved = toRGB(lab(F3(L, C, l.z)), u)
        let unmoved = toRGB(lab(l), u)
        let out = c + (moved - unmoved)
        return finite(out) ? out : c
    }

    static func subtractive(_ c: F3, _ amount: Float) -> F3 {
        let norm = max(c.x, max(c.y, c.z))
        guard norm > 1e-9, norm < 3.0e38 else { return c }
        let gamma = 1 + amount
        let r = c / norm
        let p = F3(sgn(r.x) * pow(max(abs(r.x), 1e-30), gamma),
                   sgn(r.y) * pow(max(abs(r.y), 1e-30), gamma),
                   sgn(r.z) * pow(max(abs(r.z), 1e-30), gamma))
        let out = p * norm
        return finite(out) ? out : c
    }

    static func vibranceSaturation(_ c: F3, _ u: U) -> F3 {
        let p = u[9]
        let kBr = u[10].w
        let l = lch(toLab(c, u))
        let J = l.x * hkFactor(l.y, l.z, kBr)
        guard finite(F3(J, l.y, 0)) else { return c }
        // Skin membership and the tonal rolloff read the stage input, never the output.
        var skin: Float = 0
        if finite(l) {
            let off = abs(hueDelta(56.4, l.z))
            let inBand = 1 - smoothstep(10, 15, off)
            if inBand > 0 {
                let plaus = min(max(smoothstep(0.05, 0.20, l.x) * (1 - smoothstep(0.85, 0.98, l.x))
                                    * (1 - smoothstep(0.16, 0.26, l.y)), 0), 1)
                skin = min(max(inBand * gate(l.y) * plaus, 0), 1)
            }
        }
        let protection = 1 - p.z * skin
        let u2 = max(0, J - 0.86) / 0.35
        let rolloff = smoothstep(0.02, 0.20, J) * (0.35 + 0.65 / (1 + u2 * u2))
        let low = 1 - smoothstep(0.05, 0.25, l.y)
        let vib = (p.x >= 0 ? p.x * rolloff : p.x) * low * protection
        let sat = p.y >= 0 ? p.y * rolloff * protection : p.y
        var mid = c
        if vib != 0 { mid = chromaScale(c, 1 + vib, u, kBr) }
        guard sat != 0 else { return mid }
        let additive = chromaScale(mid, 1 + sat, u, kBr)
        guard sat > 0, p.w > 0 else { return additive }
        let blended = additive + (subtractive(mid, sat) - additive) * p.w
        let source = lch(toLab(mid, u))
        let moved = lch(toLab(blended, u))
        guard finite(source), finite(moved) else { return blended }
        // `ColorEngine`'s hue hold: full from `gateLoChroma` (0.02) up, easing to 0 at
        // chroma 0 — not the 0.02…0.06 chroma gate (September audit B1-05).
        let weight = smoothstep(0, 0.02, source.y)
        guard weight > 0 else { return blended }
        let hue = wrapHue(moved.z + hueDelta(moved.z, source.z) * weight)
        let held = toRGB(lab(F3(moved.x, moved.y, hue)), u)
        return finite(held) ? held : blended
    }

    static func finish(_ c: F3, _ original: F3, _ u: U) -> F3 {
        let flags = u[11]
        var out = c
        if flags.x > 0.5 { out = vibranceSaturation(c, u) }
        if flags.y > 0.5 {
            let luma = u[10]
            let base = luma.x * out.x + luma.y * out.y + luma.z * out.z
            if abs(base) < 3.0e38 {
                var gain: Float = 1
                let l = lch(toLab(finite(c) ? c : out, u))
                if finite(l) {
                    var w = SIMD8<Float>()
                    var total: Float = 0
                    let canonical = SIMD4<Float>(22.5, 22.5, 15, 15)
                    for i in 0..<8 {
                        w[i] = membership(l.z, e(u, 48 + i), canonical)
                        total += w[i]
                    }
                    let g = gate(l.y)
                    for i in 0..<8 { gain += w[i] / total * g * e(u, 56 + i) }
                }
                let grey = max(0, base * max(0, gain))
                out = F3(grey, grey, grey)
            }
        }
        return finite(out) ? out : original
    }
}

// MARK: - Kernel source
//
// Generated once from the same constants the twin uses, and compiled by
// `LumenPipeline.KernelLibrary`. Uniform vectors are all `vec4` in the twin's order.

public enum ExactColorKernelSource {

    /// The nine conversion vectors, as kernel parameters.
    static let conversionParameters = (0..<9).map { "vec4 m\($0)" }.joined(separator: ", ")

    static func e(_ k: Int, prefix: String = "m") -> String {
        "\(prefix)\(k >> 2).\(["x", "y", "z", "w"][k & 3])"
    }

    static func mul(_ k: Int, _ v: String) -> String {
        "vec3(" + (0..<3).map { row in
            "\(e(k + 3 * row))*\(v).x + \(e(k + 3 * row + 1))*\(v).y + \(e(k + 3 * row + 2))*\(v).z"
        }.joined(separator: ", ") + ")"
    }

    /// Helpers that need no uniforms. Matrices are expanded inline at each use because a
    /// kernel-language helper cannot see the kernel's parameters.
    static let prelude = """
    float lumenSgn(float x) { return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0); }
    bool lumenFinite(vec3 v) { return abs(v.x) < 3.0e38 && abs(v.y) < 3.0e38 && abs(v.z) < 3.0e38; }
    float lumenCbrt1(float v) {
        float n = lumenSgn(v) * pow(abs(v), 0.333333333);
        return (2.0 * n + v / max(n * n, 1e-30)) / 3.0;
    }
    vec3 lumenCbrt(vec3 x) { return vec3(lumenCbrt1(x.x), lumenCbrt1(x.y), lumenCbrt1(x.z)); }
    vec3 lumenLCh(vec3 lab) {
        float C = sqrt(lab.y * lab.y + lab.z * lab.z);
        float h = C > 0.0 ? atan(lab.z, lab.y) * 57.2957795 : 0.0;
        if (h < 0.0) { h += 360.0; }
        if (h >= 360.0) { h = 0.0; }
        return vec3(lab.x, C, h);
    }
    vec3 lumenLab(vec3 lch) {
        float r = lch.z * 0.0174532925;
        return vec3(lch.x, lch.y * cos(r), lch.y * sin(r));
    }
    float lumenWrap(float h) {
        float x = h - 360.0 * floor(h / 360.0);
        if (x >= 360.0) { x = 0.0; }
        return x;
    }
    float lumenHueDelta(float a, float b) {
        float d0 = b - a;
        float d = d0 - 360.0 * floor((d0 + 180.0) / 360.0);
        if (d <= -180.0) { d += 360.0; }
        return d;
    }
    float lumenSmooth(float e0, float e1, float x) {
        float t = min(max((x - e0) / (e1 - e0), 0.0), 1.0);
        return t * t * (3.0 - 2.0 * t);
    }
    float lumenGate(float C) { return lumenSmooth(0.02, 0.06, C); }
    float lumenLumShape(float L) { float t = min(max(L, 0.0), 0.5); return t * (1.0 - t); }
    float lumenMembership(float h, float centre, vec4 arc) {
        float d = lumenHueDelta(centre, h);
        float below = max(0.0, -d - arc.x);
        float above = max(0.0, d - arc.y);
        float t = max(below / arc.z, above / arc.w);
        return 0.5 + 0.5 * cos(min(max(t, 0.0), 1.0) * 3.14159265);
    }
    float lumenHK(float C, float h, float kBr) {
        float t = lumenWrap(h) * 0.0174532925;
        float q = -0.01585
            - 0.03017 * cos(t) - 0.04556 * cos(2.0 * t)
            - 0.04256 * cos(3.0 * t) - 0.00295 * cos(4.0 * t)
            + 0.14592 * sin(t) + 0.05084 * sin(2.0 * t)
            - 0.01900 * sin(3.0 * t) - 0.00764 * sin(4.0 * t);
        return 1.0 + (-0.1340 * q + 0.0872 * kBr) * (max(0.0, C) * 4.0) * 0.1;
    }
    float lumenSatCompress(float x) { return x > 0.18 ? 0.34 - 0.16 * exp(-(x - 0.18) / 0.16) : x; }
    vec3 lumenSubtractive(vec3 c, float amount) {
        float norm = max(c.x, max(c.y, c.z));
        if (!(norm > 1e-9 && norm < 3.0e38)) { return c; }
        float gamma = 1.0 + amount;
        vec3 r = c / norm;
        vec3 p = vec3(lumenSgn(r.x) * pow(max(abs(r.x), 1e-30), gamma),
                      lumenSgn(r.y) * pow(max(abs(r.y), 1e-30), gamma),
                      lumenSgn(r.z) * pow(max(abs(r.z), 1e-30), gamma));
        vec3 o = p * norm;
        return lumenFinite(o) ? o : c;
    }
    """

    static func toLab(_ v: String) -> String { mul(9, "lumenCbrt(\(mul(0, v)))") }

    static func toRGB(_ lab: String, into name: String) -> String {
        """
        vec3 \(name)N = \(mul(18, lab));
                vec3 \(name)Q = \(name)N * \(name)N * \(name)N;
                vec3 \(name) = \(mul(27, "\(name)Q"));
        """
    }

    // ---- primaries ----

    public static let primaries: String = prelude + """

    kernel vec4 lumenColourPrimaries(__sample s, \(conversionParameters),
                                     vec4 r0, vec4 r1, vec4 r2, vec4 flags, vec4 luma) {
        vec3 c = s.rgb;
        if (!lumenFinite(c)) { return s; }
        vec3 res = c;
        if (flags.z > 0.5) {
            res = vec3(r0.x * c.x + r0.y * c.y + r0.z * c.z,
                       r1.x * c.x + r1.y * c.y + r1.z * c.z,
                       r2.x * c.x + r2.y * c.y + r2.z * c.z);
        }
        if (flags.w > 0.5) {
            float y = luma.x * res.x + luma.y * res.y + luma.z * res.z;
            float ev = y > 0.0 ? max(log2(y / 0.18), -20.0) : -20.0;
            float st = (ev + 3.0) / 1.5;
            float stepped = st <= -1.0 ? 0.0 : (st >= 1.0 ? 1.0
                : 0.5 * (1.0 - cos(3.14159265 * ((st + 1.0) / 2.0))));
            float w = 1.0 - stepped;
            if (w > 0.0) {
                vec3 l = \(toLab("res"));
                if (lumenFinite(l)) {
                    l.y += w * flags.x;
                    l.z += w * flags.y;
                    \(toRGB("l", into: "back"))
                    res = back;
                }
            }
        }
        return vec4(res, s.a);
    }
    """

    // ---- mixer ----

    public static let mixer: String = {
        let arcs = (0..<8).map { "vec4 a\($0)" }.joined(separator: ", ")
        let moves = (0..<6).map { "vec4 v\($0)" }.joined(separator: ", ")
        // Element k of the whole uniform list, as the twin's `e(u, k)` reads it.
        func u(_ k: Int) -> String {
            let vector = k >> 2
            let lane = ["x", "y", "z", "w"][k & 3]
            switch vector {
            case 0...8: return "m\(vector).\(lane)"
            case 9...10: return "c\(vector - 9).\(lane)"
            case 11...18: return "a\(vector - 11).\(lane)"
            case 19...24: return "v\(vector - 19).\(lane)"
            case 25...26: return "t\(vector - 25).\(lane)"
            default: return "q.\(lane)"
            }
        }
        var weights = ""
        for i in 0..<8 {
            weights += "        float w\(i) = lumenMembership(h, \(u(36 + i)), a\(i));\n"
        }
        let total = (0..<8).map { "w\($0)" }.joined(separator: " + ")
        var sums = ""
        for i in 0..<8 {
            sums += """
                    { float k = w\(i) / total * g;
                      hueSum += k * \(u(76 + 3 * i)); satSum += k * \(u(77 + 3 * i)); lumSum += k * \(u(78 + 3 * i));
                      float r = \(u(100 + i)) * 0.0174532925; tx += k * cos(r); ty += k * sin(r); }

            """
        }
        return prelude + """

        kernel vec4 lumenColourMixer(__sample s, \(conversionParameters), vec4 c0, vec4 c1,
                                     \(arcs), \(moves), vec4 t0, vec4 t1, vec4 q) {
            vec3 c = s.rgb;
            vec3 l = lumenLCh(\(toLab("c")));
            if (!lumenFinite(l)) { return s; }
            float h = l.z;
        \(weights)
            float total = \(total);
            float g = lumenGate(l.y);
            float hueSum = 0.0; float satSum = 0.0; float lumSum = 0.0;
            float tx = 0.0; float ty = 0.0;
        \(sums)
            float converge = 0.0;
            if (q.x != 0.0 && g != 0.0 && tx * tx + ty * ty > 1e-12) {
                float blended = atan(ty, tx) * 57.2957795;
                float moved = lumenWrap(h + q.x * g * lumenHueDelta(blended, h));
                converge = lumenHueDelta(h, moved);
            }
            float L = l.x + lumSum * lumenLumShape(l.x);
            float C = l.y * max(0.0, 1.0 + satSum);
            vec3 mapped = lumenLab(vec3(L, C, lumenWrap(h + hueSum + converge)));
            \(toRGB("mapped", into: "outRGB"))
            return vec4(outRGB, s.a);
        }
        """
    }()

    // ---- point ----

    public static let point: String = prelude + """

    kernel vec4 lumenColourPoint(__sample s, __sample ref, \(conversionParameters),
                                 vec4 t, vec4 sg, vec4 k) {
        vec3 c = s.rgb;
        vec3 l = lumenLCh(\(toLab("c")));
        if (!lumenFinite(l)) { return s; }
        float dL = l.x - t.x;
        float dC = l.y - t.y;
        float dh = lumenHueDelta(t.z, l.z);
        float dH = lumenGate(min(l.y, t.y)) * (abs(dh) / 180.0);
        float ea = dL / t.w; float eb = dC / sg.x; float ec = dH / sg.y;
        float d = sqrt(ea * ea + eb * eb + ec * ec);
        if (!(abs(d) < 3.0e38)) { return s; }
        float weight = 1.0 - lumenSmooth(0.5, 1.0, d);
        if (!(weight > 0.0)) { return s; }
        float L = l.x; float C = l.y; float h = l.z;
        float g = lumenGate(l.y);
        float qq = k.y;
        if (qq != 0.0) {
            vec3 rc = ref.rgb;
            vec3 mu = lumenLCh(\(toLab("rc")));
            if (!lumenFinite(mu)) { mu = l; }
            h = lumenWrap(h + qq * (weight * g) * lumenHueDelta(t.z, mu.z));
            C = C + qq * weight * (mu.y - t.y);
            L = L + qq * 0.5 * weight * (mu.x - t.x);
        }
        h += weight * g * sg.z;
        C = max(0.0, C * (1.0 + weight * sg.w / 100.0));
        L += weight * (k.x / 100.0) * lumenLumShape(L);
        vec3 mapped = lumenLab(vec3(L, C, lumenWrap(h)));
        \(toRGB("mapped", into: "outRGB"))
        return vec4(outRGB, s.a);
    }
    """

    // ---- finish ----

    public static let finish: String = {
        func u(_ k: Int) -> String {
            let vector = k >> 2
            let lane = ["x", "y", "z", "w"][k & 3]
            switch vector {
            case 12...13: return "c\(vector - 12).\(lane)"
            default: return "b\(vector - 14).\(lane)"
            }
        }
        var bwWeights = ""
        for i in 0..<8 {
            bwWeights += "            float w\(i) = lumenMembership(bl.z, \(u(48 + i)), vec4(22.5, 22.5, 15.0, 15.0));\n"
        }
        let total = (0..<8).map { "w\($0)" }.joined(separator: " + ")
        let gains = (0..<8).map { "w\($0) / total * g * \(u(56 + $0))" }
            .joined(separator: " + ")
        // `chromaScale` appears twice, so it is generated as a block over a named input.
        func chromaScale(_ input: String, _ gain: String, into name: String) -> String {
            """
            vec3 \(name) = \(input);
                    {
                        vec3 cl = lumenLCh(\(toLab(input)));
                        float J = cl.x * lumenHK(cl.y, cl.z, kBr);
                        if (lumenFinite(vec3(J, cl.y, 0.0))) {
                            float base = max(0.0, cl.y);
                            float gg = max(0.0, \(gain));
                            float reference = lumenSatCompress(base);
                            float CC = reference > 1e-12 ? lumenSatCompress(base * gg) * base / reference : base * gg;
                            float f = lumenHK(CC, cl.z, kBr);
                            float LL = f == 0.0 ? J : J / f;
                            vec3 mapped = lumenLab(vec3(LL, CC, cl.z));
                            \(toRGB("mapped", into: "moved"))
                            vec3 kept = lumenLab(cl);
                            \(toRGB("kept", into: "unmoved"))
                            vec3 scaled = \(input) + (moved - unmoved);
                            if (lumenFinite(scaled)) { \(name) = scaled; }
                        }
                    }
            """
        }
        return prelude + """

        kernel vec4 lumenColourFinish(__sample s, __sample original, \(conversionParameters),
                                      vec4 p, vec4 luma, vec4 flags, vec4 c0, vec4 c1,
                                      vec4 b0, vec4 b1) {
            vec3 c = s.rgb;
            vec3 res = c;
            float kBr = luma.w;
            if (flags.x > 0.5) {
                vec3 l = lumenLCh(\(toLab("c")));
                float J0 = l.x * lumenHK(l.y, l.z, kBr);
                if (lumenFinite(vec3(J0, l.y, 0.0))) {
                    float skin = 0.0;
                    if (lumenFinite(l)) {
                        float off = abs(lumenHueDelta(56.4, l.z));
                        float inBand = 1.0 - lumenSmooth(10.0, 15.0, off);
                        if (inBand > 0.0) {
                            float plaus = min(max(lumenSmooth(0.05, 0.20, l.x) * (1.0 - lumenSmooth(0.85, 0.98, l.x))
                                                  * (1.0 - lumenSmooth(0.16, 0.26, l.y)), 0.0), 1.0);
                            skin = min(max(inBand * lumenGate(l.y) * plaus, 0.0), 1.0);
                        }
                    }
                    float protection = 1.0 - p.z * skin;
                    float u2 = max(0.0, J0 - 0.86) / 0.35;
                    float rolloff = lumenSmooth(0.02, 0.20, J0) * (0.35 + 0.65 / (1.0 + u2 * u2));
                    float low = 1.0 - lumenSmooth(0.05, 0.25, l.y);
                    float vib = (p.x >= 0.0 ? p.x * rolloff : p.x) * low * protection;
                    float sat = p.y >= 0.0 ? p.y * rolloff * protection : p.y;
                    vec3 mid = c;
                    if (vib != 0.0) {
                        \(chromaScale("c", "1.0 + vib", into: "vibrant"))
                        mid = vibrant;
                    }
                    res = mid;
                    if (sat != 0.0) {
                        \(chromaScale("mid", "1.0 + sat", into: "additive"))
                        res = additive;
                        if (sat > 0.0 && p.w > 0.0) {
                            vec3 blended = additive + (lumenSubtractive(mid, sat) - additive) * p.w;
                            res = blended;
                            vec3 sl = lumenLCh(\(toLab("mid")));
                            vec3 ml = lumenLCh(\(toLab("blended")));
                            if (lumenFinite(sl) && lumenFinite(ml)) {
                                float weight = lumenSmooth(0.0, 0.02, sl.y);
                                if (weight > 0.0) {
                                    float hue = lumenWrap(ml.z + lumenHueDelta(ml.z, sl.z) * weight);
                                    vec3 held = lumenLab(vec3(ml.x, ml.y, hue));
                                    \(toRGB("held", into: "heldRGB"))
                                    if (lumenFinite(heldRGB)) { res = heldRGB; }
                                }
                            }
                        }
                    }
                }
            }
            if (flags.y > 0.5) {
                float base = luma.x * res.x + luma.y * res.y + luma.z * res.z;
                if (abs(base) < 3.0e38) {
                    float gain = 1.0;
                    vec3 src = lumenFinite(c) ? c : res;
                    vec3 bl = lumenLCh(\(toLab("src")));
                    if (lumenFinite(bl)) {
        \(bwWeights)
                        float total = \(total);
                        float g = lumenGate(bl.y);
                        gain += \(gains);
                    }
                    float grey = max(0.0, base * max(0.0, gain));
                    res = vec3(grey, grey, grey);
                }
            }
            return lumenFinite(res) ? vec4(res, s.a) : original;
        }
        """
    }()

    /// Every kernel the stage compiles, by pass kind.
    public static func source(for kernel: ExactColorStage.Pass.Kernel) -> String {
        switch kernel {
        case .primaries: return primaries
        case .mixer: return mixer
        case .point: return point
        case .finish: return finish
        }
    }
}

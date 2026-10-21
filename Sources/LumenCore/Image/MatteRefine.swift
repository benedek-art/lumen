// MatteRefine.swift
// Edge-aware upsampling of an AI matte against the photograph it was made from.
//
// A segmentation model sees a few hundred pixels. Vision's foreground request runs at
// its own internal size and scales the answer up bilinearly; the person request returns
// a buffer whose size is the model's, not the picture's. Either way the edge the model
// knows about is a ramp several picture-pixels wide that ignores where the picture's
// own edge is: a grey ring round hair, a blocky skyline, sky bleeding into a roofline.
// Stretching that further to the render target (what `MaskRaster.mattePlane` does on
// its own) only widens the ramp.
//
// The fix is the colour guided filter (He, Sun, Tang, "Guided Image Filtering", TPAMI
// 2013), run as the fast guided filter (He & Sun 2015): inside every window the refined
// matte is a linear function of the picture's RGB, q = a·I + b, fitted to the coarse
// matte by least squares. Where the window is all subject or all background the coarse
// matte is flat, the fit gives a = 0 and q is the matte unchanged. Where it straddles
// an edge, q follows the picture's edge rather than the model's. The coefficients are
// smooth, so they are fitted on a subsampled grid and bilinearly upsampled, and only the
// final `a·I + b` runs at full resolution.
//
// Lives in LumenCore, not next to Vision, so it can be measured on a machine that has
// no Vision: `MatteRefineTests` feeds it a synthetic "model matte" and the truth.

import Foundation

/// The picture a matte is refined against: display-encoded RGB in [0, 1], row 0 at
/// the top (the same convention as `Plane` and a CGImage).
///
/// Display-encoded on purpose. The guided filter's `epsilon` is a variance threshold
/// in the guide's units, and a perceptual encoding makes "an edge" mean the same
/// thing in a shadow as in a highlight. Scene-linear would make every shadow edge
/// invisible to it.
public struct MatteGuide: Sendable {
    public let width: Int
    public let height: Int
    public var r: [Float]
    public var g: [Float]
    public var b: [Float]

    public init(width: Int, height: Int, r: [Float], g: [Float], b: [Float]) {
        precondition(width > 0 && height > 0)
        precondition(r.count == width * height && g.count == r.count && b.count == r.count)
        self.width = width
        self.height = height
        self.r = r
        self.g = g
        self.b = b
    }

    /// From 8-bit interleaved pixels with `channels` components per pixel, RGB first
    /// (RGBA, RGBX). This is how a rendered CGImage arrives.
    public init(width: Int, height: Int, bytesPerRow: Int, channels: Int,
                bytes: UnsafeRawBufferPointer) {
        precondition(width > 0 && height > 0 && channels >= 3)
        let n = width * height
        var r = [Float](repeating: 0, count: n)
        var g = r
        var b = r
        let scale: Float = 1 / 255
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let o = row + x * channels
                let i = y * width + x
                r[i] = Float(bytes[o]) * scale
                g[i] = Float(bytes[o + 1]) * scale
                b[i] = Float(bytes[o + 2]) * scale
            }
        }
        self.init(width: width, height: height, r: r, g: g, b: b)
    }

    /// From an `ImageBuffer` whose values are already display-encoded (tests, and the
    /// Linux evidence harness). Clamped to [0, 1].
    public init(displayEncoded buffer: ImageBuffer) {
        let n = buffer.width * buffer.height
        var r = [Float](repeating: 0, count: n)
        var g = r
        var b = r
        for i in 0..<n {
            r[i] = Swift.min(Swift.max(buffer.pixels[i * 4], 0), 1)
            g[i] = Swift.min(Swift.max(buffer.pixels[i * 4 + 1], 0), 1)
            b[i] = Swift.min(Swift.max(buffer.pixels[i * 4 + 2], 0), 1)
        }
        self.init(width: buffer.width, height: buffer.height, r: r, g: g, b: b)
    }

    /// Area-average downsample by an integer factor (the last partial block averages
    /// what it has). Factor 1 is the identity.
    public func boxDownsampled(by factor: Int) -> MatteGuide {
        guard factor > 1 else { return self }
        let w = (width + factor - 1) / factor
        let h = (height + factor - 1) / factor
        return MatteGuide(width: w, height: h,
                          r: MatteRefine.boxDown(r, width, height, factor),
                          g: MatteRefine.boxDown(g, width, height, factor),
                          b: MatteRefine.boxDown(b, width, height, factor))
    }

    /// Area-average downsample to at most `longEdge` on the long side.
    public func downsampled(longEdge: Int) -> MatteGuide {
        let long = Swift.max(width, height)
        guard longEdge > 0, long > longEdge else { return self }
        return boxDownsampled(by: Int((Double(long) / Double(longEdge)).rounded(.up)))
    }

    /// Rec.709-weighted luma of the encoded values.
    public var luma: [Float] {
        var out = [Float](repeating: 0, count: r.count)
        for i in 0..<r.count {
            out[i] = 0.2126 * r[i] + 0.7152 * g[i] + 0.0722 * b[i]
        }
        return out
    }
}

public enum MatteRefine {

    /// Window radius as a fraction of the guide's long edge. 1/256 is 8 px at 2048: wide
    /// enough to span the ramp a ~512 px model leaves at that size (4 px), narrow enough
    /// that one window rarely holds two unrelated edges.
    public static let radiusFraction: Double = 1.0 / 256
    /// Variance regularization in the guide's units (display-encoded [0, 1]). Small, so a
    /// faint edge (hair against a similar wall) still steers the fit; large enough that
    /// sensor noise in a flat sky does not.
    public static let defaultEpsilon: Double = 1e-3
    /// Fast-guided-filter subsampling. Coefficients are smooth by construction; 4 keeps
    /// a 2048 px refine well under a second on one core.
    public static let defaultSubsample = 4
    /// The feathering window, as a fraction of the long edge: 2 px at 2048. Small on
    /// purpose; its job is anti-aliasing and partial alpha, not finding the edge.
    public static let featherFraction: Double = 1.0 / 1024

    /// Refine `matte` against `guide`, at the guide's resolution.
    ///
    /// `matte` may be any size; it is first bilinearly fitted over the whole frame
    /// (the convention every Vision buffer and `MaskRaster` share). The output is
    /// `guide.width × guide.height`, clamped to [0, 1], and exactly the input wherever
    /// the matte is constant over a window.
    ///
    /// `nativeLongEdge` is the resolution the model actually decided at, when the
    /// buffer handed in has already been scaled up (Vision's foreground request does
    /// that). The window has to be wider than the ramp that scaling left, or every
    /// window inside the ramp sees a flat picture and a sloping matte, the fit can only
    /// return the slope, and nothing sharpens. Nil means the buffer is native.
    public static func guidedUpsample(matte: Plane, guide: MatteGuide,
                                      nativeLongEdge: Int? = nil,
                                      radius: Double? = nil,
                                      epsilon: Double = defaultEpsilon,
                                      subsample: Int = defaultSubsample) -> Plane {
        let W = guide.width, H = guide.height
        let p = (matte.width == W && matte.height == H)
            ? matte : matte.resized(width: W, height: H)

        let native = Double(nativeLongEdge ?? Swift.max(matte.width, matte.height))
        let stretch = Double(Swift.max(W, H)) / Swift.max(native, 1)
        let rLocate = radius ?? Swift.max(2, Double(Swift.max(W, H)) * radiusFraction,
                                          1.5 * stretch)

        // Stage 1, LOCATE: a window wide enough to span the model's ramp moves the
        // transition onto the picture's edge. One guided pass narrows a ramp but does
        // not remove it (13 px → 8 px on the synthetic edge): inside the ramp the
        // matte slopes and the picture is flat, and a linear fit can only split the
        // difference.
        let located = guidedFilter(p, guide: guide, radius: rLocate, epsilon: epsilon,
                                   subsample: subsample)
        // Stage 2, DECIDE then FEATHER: push the located matte toward a decision, then
        // feather that decision against the picture with a window of a couple of
        // pixels. This is the guided filter's original matting use (a binary mask in,
        // hair-level alpha out): the decision says which side each pixel is on, the
        // small window restores the partial alpha wherever the picture itself is
        // mixed: hair, twigs, a defocused rim. The decision is a smoothstep, not a
        // threshold, so a matte the model was genuinely unsure about stays soft.
        var decided = located
        for i in 0..<decided.values.count {
            let t = Swift.min(Swift.max((located.values[i] - 0.25) / 0.5, 0), 1)
            decided.values[i] = t * t * (3 - 2 * t)
        }
        let rFeather = Swift.max(1.5, Double(Swift.max(W, H)) * featherFraction)
        var out = guidedFilter(decided, guide: guide, radius: rFeather,
                               epsilon: epsilon, subsample: 1)
        // Where the coarse matte is exactly 0 or 1 over the whole footprint, keep it
        // exactly: the guided fit can leave a faint wash far from any edge (b ≠ 0 from
        // a distant window), and a mask that is meant to be nothing must be nothing.
        let solid = solidMask(p.values, W, H, Int(rLocate.rounded(.up)) * 2 + 2)
        for i in 0..<(W * H) where solid[i] >= 0 {
            out.values[i] = solid[i]
        }
        return out
    }

    /// One colour guided filter of `p` (already at the guide's size), fast variant:
    /// coefficients fitted on a grid subsampled by up to `subsample`, bilinearly
    /// upsampled, applied at full resolution. Output clamped to [0, 1].
    static func guidedFilter(_ p: Plane, guide: MatteGuide, radius rFull: Double,
                             epsilon: Double, subsample: Int) -> Plane {
        let W = guide.width, H = guide.height
        let s = Swift.max(1, Swift.min(subsample, Int(rFull / 2)))
        let low = guide.boxDownsampled(by: s)
        let w = low.width, h = low.height
        let pl = boxDown(p.values, W, H, s)
        let r = Swift.max(1, Int((rFull / Double(s)).rounded()))

        // Window means of I, p, I·p and I·Iᵀ (six unique terms).
        let ir = low.r, ig = low.g, ib = low.b
        let n = w * h
        var prodRP = [Float](repeating: 0, count: n), prodGP = prodRP, prodBP = prodRP
        var rr = prodRP, rg = prodRP, rb = prodRP, gg = prodRP, gb = prodRP, bb = prodRP
        for i in 0..<n {
            let pv = pl[i]
            prodRP[i] = ir[i] * pv; prodGP[i] = ig[i] * pv; prodBP[i] = ib[i] * pv
            rr[i] = ir[i] * ir[i]; rg[i] = ir[i] * ig[i]; rb[i] = ir[i] * ib[i]
            gg[i] = ig[i] * ig[i]; gb[i] = ig[i] * ib[i]; bb[i] = ib[i] * ib[i]
        }
        let mR = boxMean(ir, w, h, r), mG = boxMean(ig, w, h, r), mB = boxMean(ib, w, h, r)
        let mP = boxMean(pl, w, h, r)
        let mRP = boxMean(prodRP, w, h, r), mGP = boxMean(prodGP, w, h, r)
        let mBP = boxMean(prodBP, w, h, r)
        let mRR = boxMean(rr, w, h, r), mRG = boxMean(rg, w, h, r)
        let mRB = boxMean(rb, w, h, r), mGG = boxMean(gg, w, h, r)
        let mGB = boxMean(gb, w, h, r), mBB = boxMean(bb, w, h, r)

        var aR = [Float](repeating: 0, count: n), aG = aR, aB = aR, bC = aR
        let eps = epsilon
        for i in 0..<n {
            let mr = Double(mR[i]), mg = Double(mG[i]), mb = Double(mB[i])
            let mp = Double(mP[i])
            let cr = Double(mRP[i]) - mr * mp
            let cg = Double(mGP[i]) - mg * mp
            let cb = Double(mBP[i]) - mb * mp
            // Σ + εU, symmetric.
            let s00 = Double(mRR[i]) - mr * mr + eps
            let s01 = Double(mRG[i]) - mr * mg
            let s02 = Double(mRB[i]) - mr * mb
            let s11 = Double(mGG[i]) - mg * mg + eps
            let s12 = Double(mGB[i]) - mg * mb
            let s22 = Double(mBB[i]) - mb * mb + eps
            // Inverse by cofactors.
            let c00 = s11 * s22 - s12 * s12
            let c01 = s02 * s12 - s01 * s22
            let c02 = s01 * s12 - s02 * s11
            let c11 = s00 * s22 - s02 * s02
            let c12 = s01 * s02 - s00 * s12
            let c22 = s00 * s11 - s01 * s01
            let det = s00 * c00 + s01 * c01 + s02 * c02
            var a0 = 0.0, a1 = 0.0, a2 = 0.0
            if det > 1e-18, det.isFinite {
                a0 = (c00 * cr + c01 * cg + c02 * cb) / det
                a1 = (c01 * cr + c11 * cg + c12 * cb) / det
                a2 = (c02 * cr + c12 * cg + c22 * cb) / det
            }
            aR[i] = Float(a0); aG[i] = Float(a1); aB[i] = Float(a2)
            bC[i] = Float(mp - a0 * mr - a1 * mg - a2 * mb)
        }
        let maR = boxMean(aR, w, h, r), maG = boxMean(aG, w, h, r)
        let maB = boxMean(aB, w, h, r), mbC = boxMean(bC, w, h, r)

        var out = Plane(width: W, height: H)
        // Bilinear upsample of the coefficients: low-res sample k covers full-res
        // pixels [k·s, (k+1)·s), so its centre sits at (k + 0.5)·s − 0.5.
        let inv = 1 / Double(s)
        for y in 0..<H {
            let fy = Swift.min(Swift.max((Double(y) + 0.5) * inv - 0.5, 0), Double(h - 1))
            let y0 = Int(fy), y1 = Swift.min(y0 + 1, h - 1)
            let ty = Float(fy - Double(y0))
            for x in 0..<W {
                let fx = Swift.min(Swift.max((Double(x) + 0.5) * inv - 0.5, 0), Double(w - 1))
                let x0 = Int(fx), x1 = Swift.min(x0 + 1, w - 1)
                let tx = Float(fx - Double(x0))
                @inline(__always) func lerp(_ a: [Float]) -> Float {
                    let top = a[y0 * w + x0] + (a[y0 * w + x1] - a[y0 * w + x0]) * tx
                    let bot = a[y1 * w + x0] + (a[y1 * w + x1] - a[y1 * w + x0]) * tx
                    return top + (bot - top) * ty
                }
                let i = y * W + x
                let pv = p.values[i]
                // Flat coarse matte in the whole support: nothing to refine. Exact, so
                // the deep interior and the far background stay bit-identical.
                let q: Float
                let ca = lerp(maR), cgv = lerp(maG), cbv = lerp(maB)
                if ca == 0 && cgv == 0 && cbv == 0 {
                    q = lerp(mbC)
                } else {
                    q = ca * guide.r[i] + cgv * guide.g[i] + cbv * guide.b[i] + lerp(mbC)
                }
                let v = q.isFinite ? Swift.min(Swift.max(q, 0), 1) : pv
                out.values[i] = v
            }
        }
        return out
    }

    // MARK: - Helpers (internal so the detector can reuse them)

    /// −1 where the plane is not constant within `radius` of the pixel; otherwise the
    /// constant (0 or 1 only — mid values are never "solid").
    static func solidMask(_ v: [Float], _ w: Int, _ h: Int, _ radius: Int) -> [Float] {
        var lo = [Float](repeating: 0, count: v.count), hi = lo
        for i in 0..<v.count {
            lo[i] = v[i] <= 0 ? 1 : 0
            hi[i] = v[i] >= 1 ? 1 : 0
        }
        let mLo = boxMean(lo, w, h, radius), mHi = boxMean(hi, w, h, radius)
        var out = [Float](repeating: -1, count: v.count)
        for i in 0..<v.count {
            if mLo[i] >= 1 - 1e-6 { out[i] = 0 } else if mHi[i] >= 1 - 1e-6 { out[i] = 1 }
        }
        return out
    }

    /// Mean over the (2r+1)² window, clipped at the frame (divides by the pixels it
    /// actually covers, so there is no dark border). Integral image in Double.
    static func boxMean(_ v: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        let sw = w + 1
        var sat = [Double](repeating: 0, count: sw * (h + 1))
        for y in 0..<h {
            var run = 0.0
            for x in 0..<w {
                run += Double(v[y * w + x])
                sat[(y + 1) * sw + x + 1] = sat[y * sw + x + 1] + run
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = Swift.max(0, y - r), y1 = Swift.min(h, y + r + 1)
            for x in 0..<w {
                let x0 = Swift.max(0, x - r), x1 = Swift.min(w, x + r + 1)
                let sum = sat[y1 * sw + x1] - sat[y0 * sw + x1]
                    - sat[y1 * sw + x0] + sat[y0 * sw + x0]
                out[y * w + x] = Float(sum / Double((y1 - y0) * (x1 - x0)))
            }
        }
        return out
    }

    /// Integer-factor area downsample of one channel.
    static func boxDown(_ v: [Float], _ w: Int, _ h: Int, _ f: Int) -> [Float] {
        guard f > 1 else { return v }
        let ow = (w + f - 1) / f, oh = (h + f - 1) / f
        var sum = [Float](repeating: 0, count: ow * oh)
        var count = [Float](repeating: 0, count: ow * oh)
        for y in 0..<h {
            let oy = y / f
            for x in 0..<w {
                let o = oy * ow + x / f
                sum[o] += v[y * w + x]
                count[o] += 1
            }
        }
        for i in 0..<sum.count { sum[i] /= Swift.max(count[i], 1) }
        return sum
    }
}

// SkyDetector.swift
// Select Sky without a model: a colour, smoothness and position prior, grown from the
// top of the frame, then snapped to the picture's own edges by the guided filter.
//
// Why classical at all. The good sky segmenters are ADE20K-trained (SegFormer,
// DeepLabV3+, Mask2Former), and the weights that are easy to get either carry a
// non-commercial licence (NVIDIA's SegFormer releases) or inherit ADE20K's
// research-only terms. `VisionMattes` loads such a model when the owner installs one
// (see `SkyModel` there); this is what runs when nothing is installed, and it has to
// be good on its own, because that is every install on day one.
//
// What sky is, for this detector, in the order the stages test it:
//
//   1. SMOOTH. Sky carries low-frequency gradients and soft cloud edges; foliage,
//      buildings and ground carry texture. Measured as gradient energy of OKLab at a
//      fixed working size, so the threshold means the same thing on every file.
//   2. CONNECTED TO THE TOP. Region growing from the top row through smooth,
//      colour-continuous pixels. A blue car, a pool or a white wall low in the frame
//      is not reachable without crossing texture.
//   3. SKY-COLOURED. The grown region must be bright, or blue, or both. A smooth dark
//      ceiling in an interior is reachable from the top too, and is not sky.
//   4. THE SAME SKY ELSEWHERE. A colour model fitted to the grown region (mean as a
//      linear function of height, because sky darkens and saturates upward) finds the
//      sky between branches and over a roofline, which growth alone cannot reach.
//      Below the lowest grown sky it fades out, so water reflecting the sky stays out.
//   5. EDGES FROM THE PICTURE. The low-resolution probability is upsampled with
//      `MatteRefine.guidedUpsample` against the full guide, which is where the
//      skyline, the branch silhouettes and the hair-thin twigs come back.
//
// Known limit, stated rather than hidden: a bright, smooth, featureless ceiling or wall
// that touches the top of the frame is indistinguishable from overcast sky to every
// test above. Lightroom's model mostly gets that right and this does not.

import Foundation

public enum SkyDetector {

    /// Working long edge for stages 1-4. Big enough that a gap between branches a
    /// photographer can see at fit-to-screen is a few pixels here.
    public static let workLongEdge = 384
    /// Gradient energy (OKLab units per working pixel) below which a pixel is smooth.
    static let smoothTau: Float = 0.022
    /// The largest OKLab step region growing will cross between neighbours.
    static let growStep: Float = 0.015
    /// A grown region must cover this much of the frame to count as a sky seed.
    static let minSeedFraction: Double = 0.015

    /// The sky colour model stage 4 fits: per OKLab channel, mean = α + β·y (y
    /// normalized to the frame height) with tolerance σ, valid down to `horizon`.
    public struct Model: Sendable {
        public var alpha: [Double]
        public var beta: [Double]
        public var sigma: [Double]
        /// The lowest sky row the seed reached, as a fraction of the frame height.
        public var horizon: Double

        /// Colour likelihood of an sRGB-encoded pixel at normalized height `y`.
        func colour(_ lab: (Float, Float, Float), y: Double, widen: Double = 1) -> Double {
            let c = [Double(lab.0), Double(lab.1), Double(lab.2)]
            var d2 = 0.0
            for k in 0..<3 {
                let d = (c[k] - (alpha[k] + beta[k] * y)) / (sigma[k] * widen)
                d2 += d * d
            }
            return exp(-d2 / 3)
        }
    }

    /// The sky matte at the guide's resolution, or nil when there is no sky.
    public static func detect(guide: MatteGuide) -> Plane? {
        guard let (low, model) = analyse(guide: guide) else { return nil }
        var out = MatteRefine.guidedUpsample(matte: low, guide: guide)
        canopyKey(&out, guide: guide, model: model)
        return out
    }

    /// Stages 1-4: the sky probability at the working size. Nil means no seed passed.
    public static func probability(guide: MatteGuide) -> Plane? {
        analyse(guide: guide)?.0
    }

    /// Stage 6, sky behind fine branches. At the working size a willow against the
    /// sky is a field of sky/branch mixtures that match neither, so stages 1-4 cannot
    /// see it; at full resolution the gaps are pure sky again. Above the seed's
    /// horizon, inside texture (open sky is already decided and is left alone), a
    /// pixel is keyed in when it matches the fitted sky colour AND is brighter than
    /// its surroundings: a gap in a canopy is a local maximum of brightness, a leaf
    /// that happens to be blue-grey is not.
    static func canopyKey(_ out: inout Plane, guide: MatteGuide, model: Model) {
        let W = guide.width, H = guide.height
        let luma = guide.luma
        let r = Swift.max(2, Swift.max(W, H) / 512)
        let localMean = MatteRefine.boxMean(luma, W, H, r)
        // Edge DENSITY, not variance: the share of pixels around this one that sit on
        // an edge. A canopy is edges everywhere (> 0.4); one strong edge — a window
        // frame, a roofline — is a thin line through a flat window (~0.1) and has
        // high variance all along it, which is how a variance gate keyed the bright
        // side of every edge on 983's lantern.
        var edge = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                let dx = abs(luma[Swift.min(x + 1, W - 1) + y * W] - luma[Swift.max(x - 1, 0) + y * W])
                let dy = abs(luma[x + Swift.min(y + 1, H - 1) * W] - luma[x + Swift.max(y - 1, 0) * W])
                edge[i] = dx + dy > 0.06 ? 1 : 0
            }
        }
        let density = MatteRefine.boxMean(edge, W, H, r * 4)
        let lastRow = Swift.min(Int(model.horizon * Double(H)), H)
        guard lastRow > 0 else { return }
        var raw = [Float](repeating: 0, count: W * H)
        for y in 0..<lastRow {
            let yn = Double(y) / Double(H)
            for x in 0..<W {
                let i = y * W + x
                guard density[i] > 0.4 else { continue }
                guard luma[i] > localMean[i] else { continue }
                // Twice the tolerance: a gap a few pixels across is still part twig
                // at its rim, and the brightness test is what guards against leaves.
                let c = model.colour(oklab(guide.r[i], guide.g[i], guide.b[i]), y: yn,
                                     widen: 2)
                guard c > 0.3 else { continue }
                let lift = Double(luma[i] - localMean[i]) / 0.03
                raw[i] = Float(smoothstep(0.3, 0.8, c) * Swift.min(1, lift))
            }
        }
        // Opening: keep a keyed pixel only where most of its 5×5 neighbourhood is keyed
        // too, then grow the survivors back over the keyed pixels they touch. A gap in
        // a canopy is a blob; a specular rim on a lantern, a window frame or a car
        // roof reflecting the sky is a line one or two pixels wide that matches the
        // sky's colour and is brighter than its surroundings, and it is not sky
        // (measured on 983: every lantern edge came out outlined without this).
        let support = MatteRefine.boxMean(raw.map { $0 > 0 ? 1 : 0 }, W, H, 2)
        var core = [Float](repeating: 0, count: W * H)
        for i in 0..<raw.count where support[i] >= 0.5 { core[i] = 1 }
        let near = MatteRefine.boxMean(core, W, H, 2)
        for i in 0..<raw.count where raw[i] > 0 && near[i] > 0 {
            if raw[i] > out.values[i] { out.values[i] = raw[i] }
        }
    }

    static func analyse(guide full: MatteGuide) -> (Plane, Model)? {
        let g = full.downsampled(longEdge: workLongEdge)
        let w = g.width, h = g.height, n = w * h
        guard w >= 8, h >= 8 else { return nil }

        // OKLab of the encoded guide (sRGB transfer assumed).
        var L = [Float](repeating: 0, count: n), A = L, B = L
        for i in 0..<n {
            let lab = oklab(g.r[i], g.g[i], g.b[i])
            L[i] = lab.0; A[i] = lab.1; B[i] = lab.2
        }

        // 1. Smoothness: Sobel magnitude over L, a, b, averaged over 3×3.
        var grad = [Float](repeating: 0, count: n)
        for y in 0..<h {
            for x in 0..<w {
                var e: Float = 0
                for (ch, weight) in [(L, Float(1)), (A, Float(1.5)), (B, Float(1.5))] {
                    func at(_ dx: Int, _ dy: Int) -> Float {
                        let xx = Swift.min(Swift.max(x + dx, 0), w - 1)
                        let yy = Swift.min(Swift.max(y + dy, 0), h - 1)
                        return ch[yy * w + xx]
                    }
                    let gx = (at(1, -1) + 2 * at(1, 0) + at(1, 1))
                        - (at(-1, -1) + 2 * at(-1, 0) + at(-1, 1))
                    let gy = (at(-1, 1) + 2 * at(0, 1) + at(1, 1))
                        - (at(-1, -1) + 2 * at(0, -1) + at(1, -1))
                    e += weight * weight * (gx * gx + gy * gy) / 64
                }
                grad[y * w + x] = e.squareRoot()
            }
        }
        let texture = MatteRefine.boxMean(grad, w, h, 1)
        // Wider texture: a smooth pixel inside foliage is still not sky.
        let context = MatteRefine.boxMean(grad, w, h, 3)

        // 2. Grow from the top row through smooth, continuous pixels.
        var label = [Int32](repeating: -1, count: n)
        var regions: [[Int]] = []
        func smooth(_ i: Int) -> Bool { texture[i] < smoothTau && context[i] < smoothTau * 2 }
        for x0 in 0..<w where label[x0] < 0 && smooth(x0) {
            let id = Int32(regions.count)
            var members: [Int] = [x0]
            label[x0] = id
            var head = 0
            while head < members.count {
                let i = members[head]; head += 1
                let x = i % w, y = i / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                    let j = yy * w + xx
                    guard label[j] < 0, smooth(j) else { continue }
                    let dL = L[j] - L[i], da = A[j] - A[i], db = B[j] - B[i]
                    guard (dL * dL + da * da + db * db).squareRoot() < growStep else { continue }
                    label[j] = id
                    members.append(j)
                }
            }
            regions.append(members)
        }

        // 3. Sky-coloured, big enough. Brightness is judged against the frame, not
        //    on an absolute scale: the segmenter sees a neutral rendition, and an
        //    overcast sky in a dark neutral render is mid-grey in absolute terms while
        //    still being the brightest broad thing in the picture.
        let sortedL = L.sorted()
        let frameMedian = sortedL[n / 2]
        let frameUpper = sortedL[Swift.min(n - 1, n * 3 / 4)]
        struct Candidate { var members: [Int]; var mL, mA, mB: Double }
        var candidates: [Candidate] = []
        for members in regions where Double(members.count) >= minSeedFraction * Double(n) {
            var sL = 0.0, sA = 0.0, sB = 0.0
            for i in members { sL += Double(L[i]); sA += Double(A[i]); sB += Double(B[i]) }
            let k = Double(members.count)
            let mL = sL / k, mA = sA / k, mB = sB / k
            let chroma = (mA * mA + mB * mB).squareRoot()
            let lifted = mL >= Double(frameUpper) || mL > Double(frameMedian) + 0.05
            let bright = lifted && mL > 0.3 && chroma < 0.12  // overcast, haze, cloud
            let blue = mB < -0.025 && mL > 0.3 && mL > Double(frameMedian)  // clear sky
            let warm = lifted && mL > 0.45 && chroma < 0.2     // sunset, golden haze
            guard bright || blue || warm else { continue }
            candidates.append(Candidate(members: members, mL: mL, mA: mA, mB: mB))
        }
        // The largest candidate is the sky; others join only if they are the same
        // sky. A bright snowfield or a white facade that reaches the top edge next to
        // blue sky is a second smooth bright region, and letting it into the colour
        // model would teach the model that white is sky, after which every white
        // thing in the frame qualifies.
        candidates.sort { $0.members.count > $1.members.count }
        var seed = [Bool](repeating: false, count: n)
        var seedCount = 0
        if let main = candidates.first {
            for c in candidates {
                let dL = c.mL - main.mL, da = c.mA - main.mA, db = c.mB - main.mB
                guard (dL * dL + da * da + db * db).squareRoot() < 0.08 else { continue }
                for i in c.members { seed[i] = true }
                seedCount += c.members.count
            }
        }
        guard seedCount > 0 else { return nil }

        // 4. Colour model: c(y) = α + β·y per channel, least squares over the seed.
        var sy = 0.0, syy = 0.0
        var sc = [0.0, 0.0, 0.0], syc = [0.0, 0.0, 0.0]
        var seedRows: [Int] = []
        seedRows.reserveCapacity(seedCount)
        for i in 0..<n where seed[i] {
            let y = Double(i / w) / Double(h)
            let c = [Double(L[i]), Double(A[i]), Double(B[i])]
            sy += y; syy += y * y
            for k in 0..<3 { sc[k] += c[k]; syc[k] += y * c[k] }
            seedRows.append(i / w)
        }
        let m = Double(seedCount)
        let denom = m * syy - sy * sy
        var alpha = [0.0, 0.0, 0.0], beta = [0.0, 0.0, 0.0]
        for k in 0..<3 {
            beta[k] = abs(denom) > 1e-9 ? (m * syc[k] - sy * sc[k]) / denom : 0
            alpha[k] = (sc[k] - beta[k] * sy) / m
        }
        var sse = [0.0, 0.0, 0.0]
        for i in 0..<n where seed[i] {
            let y = Double(i / w) / Double(h)
            let c = [Double(L[i]), Double(A[i]), Double(B[i])]
            for k in 0..<3 {
                let d = c[k] - (alpha[k] + beta[k] * y)
                sse[k] += d * d
            }
        }
        let floors = [0.035, 0.015, 0.015]
        let sigma = (0..<3).map { Swift.max((sse[$0] / m).squareRoot() * 2, floors[$0]) }
        seedRows.sort()
        let horizon = Double(seedRows[Swift.min(seedRows.count - 1,
                                                Int(Double(seedRows.count) * 0.98))])
        let fade = Swift.max(0.04 * Double(h), 2)

        var prob = Plane(width: w, height: h)
        for i in 0..<n {
            let y = i / w
            let yn = Double(y) / Double(h)
            var d2 = 0.0
            let c = [Double(L[i]), Double(A[i]), Double(B[i])]
            for k in 0..<3 {
                let d = (c[k] - (alpha[k] + beta[k] * yn)) / sigma[k]
                d2 += d * d
            }
            let colour = exp(-d2 / 3)
            // The pixel's own gradient, not the 3×3 average growth uses: a gap in a
            // canopy is a few working pixels across, and an averaged measure sees the
            // leaves around it from every pixel inside it.
            let t = Double(grad[i]) / Double(smoothTau * 3)
            let smoothness = exp(-t * t)
            let below = Double(y) - horizon
            let position = below <= 0 ? 1 : exp(-(below / fade) * (below / fade))
            var p = colour * smoothness.squareRoot() * position
            if seed[i] { p = Swift.max(p, Swift.min(1, colour * 1.5 + 0.5)) }
            prob.values[i] = Float(p)
        }

        // Keep what is connected to the seed, plus confident islands above the horizon
        // (sky through a canopy is islands at this size).
        let weak: Float = 0.25, strong: Float = 0.6
        var keep = [Bool](repeating: false, count: n)
        var visited = [Bool](repeating: false, count: n)
        for start in 0..<n where !visited[start] && prob.values[start] > weak {
            var members = [start]
            visited[start] = true
            var head = 0
            var touchesSeed = false
            var peak: Float = 0
            var rowSum = 0.0
            while head < members.count {
                let i = members[head]; head += 1
                if seed[i] { touchesSeed = true }
                peak = Swift.max(peak, prob.values[i])
                rowSum += Double(i / w)
                let x = i % w, y = i / w
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                        let j = yy * w + xx
                        guard !visited[j], prob.values[j] > weak else { continue }
                        visited[j] = true
                        members.append(j)
                    }
                }
            }
            let meanRow = rowSum / Double(members.count)
            if touchesSeed || (peak > strong && meanRow <= horizon) {
                for i in members { keep[i] = true }
            }
        }
        var decided = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = keep[i] ? prob.values[i] : 0
            decided[i] = Float(smoothstep(0.2, 0.7, Double(p)))
        }
        // Push the transition OUT by a working pixel, then soften it over one more.
        // The smoothness term rejects every sky pixel whose Sobel window touches the
        // ground, so the raw decision stops a pixel short of the true skyline, and a
        // transition that sits wholly on flat sky gives the guided filter nothing to
        // snap to: it can only smear the ramp (measured: an 8 px ramp above the
        // horizon at 512 px). Straddling the edge is what lets refinement find it.
        var grown = decided
        for y in 0..<h {
            for x in 0..<w {
                var m: Float = 0
                for yy in Swift.max(0, y - 1)...Swift.min(h - 1, y + 1) {
                    for xx in Swift.max(0, x - 1)...Swift.min(w - 1, x + 1) {
                        m = Swift.max(m, decided[yy * w + xx])
                    }
                }
                grown[y * w + x] = m
            }
        }
        prob.values = MatteRefine.boxMean(grown, w, h, 1)
        return (prob, Model(alpha: alpha, beta: beta, sigma: sigma,
                            horizon: (horizon + 1) / Double(h)))
    }

    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = Swift.min(Swift.max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// OKLab of an sRGB-encoded triple.
    static func oklab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        func lin(_ v: Float) -> Float {
            v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
        }
        let R = lin(r), G = lin(g), Bl = lin(b)
        let l = cbrtf(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * Bl)
        let m = cbrtf(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * Bl)
        let s = cbrtf(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * Bl)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}

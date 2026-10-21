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
        /// The lowest sky row the seed reached, as a fraction of the frame height,
        /// per working-size column (smoothed over a neighbourhood of columns).
        public var horizon: [Double]

        /// The horizon under column `x` of a frame `width` wide.
        func horizon(atColumn x: Int, width: Int) -> Double {
            guard !horizon.isEmpty, width > 0 else { return 0 }
            return horizon[Swift.min(horizon.count - 1, x * horizon.count / width)]
        }

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
                let dx = abs(luma[Swift.min(x + 1, W - 1) + y * W]
                             - luma[Swift.max(x - 1, 0) + y * W])
                let dy = abs(luma[x + Swift.min(y + 1, H - 1) * W]
                             - luma[x + Swift.max(y - 1, 0) * W])
                edge[i] = dx + dy > 0.06 ? 1 : 0
            }
        }
        let density = MatteRefine.boxMean(edge, W, H, r * 4)
        let lastRows = (0..<W).map {
            Swift.min(Int(model.horizon(atColumn: $0, width: W) * Double(H)), H)
        }
        guard let deepest = lastRows.max(), deepest > 0 else { return }
        var raw = [Float](repeating: 0, count: W * H)
        for y in 0..<deepest {
            let yn = Double(y) / Double(H)
            for x in 0..<W where y < lastRows[x] {
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
        let keyed = raw.map { $0 > 0 ? Float(1) : 0 }
        let support = MatteRefine.boxMean(keyed, W, H, 2)
        // And sky through a canopy comes in CLUSTERS: a canopy with sky behind it is
        // gaps over a wide area. A lone keyed blob in a window of stonework — lichen,
        // a pane of a rose window, a pale spire cap on 7301 — is not.
        let cluster = MatteRefine.boxMean(keyed, W, H, r * 12)
        var core = [Float](repeating: 0, count: W * H)
        for i in 0..<raw.count where support[i] >= 0.5 && cluster[i] >= 0.06 { core[i] = 1 }
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
            // A floor on every member, not only on the region's mean: smooth defocus
            // blur lets neighbour-to-neighbour steps walk from a bright top edge down
            // to near-black (1346: a dark olive bokeh background taken top to bottom,
            // verifier round 2). Sky is never near-black in a neutral render of a
            // daylight frame, and it does not darken by more than this below the row
            // it started on.
            let floor = L[x0] - 0.2
            // Absolute floors: a clear blue sky can be dark in a neutral render (983
            // is OKLab L ~0.35 at the top), anything grey, green or warm that dark is
            // not sky.
            func bright(_ j: Int) -> Bool {
                L[j] >= floor && L[j] >= (B[j] < -0.03 ? 0.3 : 0.4)
            }
            var head = 0
            while head < members.count {
                let i = members[head]; head += 1
                let x = i % w, y = i / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                    let j = yy * w + xx
                    guard label[j] < 0, smooth(j), bright(j) else { continue }
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
            // One sky, not a bright patch and a dark one joined by a smooth band: a
            // real sky's lightness gradient spreads about 0.09; 1346's white pole plus
            // dark bokeh spread far more and passed on the mean alone.
            var vL = 0.0
            for i in members { vL += (Double(L[i]) - mL) * (Double(L[i]) - mL) }
            guard (vL / k).squareRoot() < 0.13 else { continue }
            // Relative brightness, OR plainly bright: a snowfield or a beach can fill
            // half the frame and push the median above the sky (verifier round 1:
            // sky over 50% snow returned nothing). The region already had to be
            // smooth and reach the top edge; a blue one needs no brightness test
            // beyond not being night.
            let lifted = mL >= Double(frameUpper) || mL > Double(frameMedian) + 0.05
                || mL > 0.72
            let bright = lifted && mL > 0.3 && chroma < 0.12  // overcast, haze, cloud
            let blue = mB < -0.025 && mL > 0.3                 // clear sky
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

        // 3b. Clouds. Select Sky includes the clouds, and the seed stops at them: a
        //     cloud carries soft texture the seed's smoothness test refuses, and its
        //     grey or white is not the clear sky's colour, so the colour model below
        //     will not find it either. Grow on from the seed through bright,
        //     low-chroma pixels with a looser smoothness and step, stopping at the
        //     hard texture of anything solid. (7301: the cloudy lower sky beside the
        //     spire was cut off at 52% of the frame height.)
        var cloud = [Bool](repeating: false, count: n)
        do {
            let seedL = seedMeanL(seed, L)
            var queue: [Int] = []
            queue.reserveCapacity(seedCount)
            for i in 0..<n where seed[i] { queue.append(i) }
            var head = 0
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i % w, y = i / w
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                    let j = yy * w + xx
                    guard !seed[j], !cloud[j], texture[j] < smoothTau * 2.5 else { continue }
                    let chroma = (A[j] * A[j] + B[j] * B[j]).squareRoot()
                    guard chroma < 0.1, Double(L[j]) > Swift.max(0.35, seedL - 0.05)
                    else { continue }
                    let dL = L[j] - L[i], da = A[j] - A[i], db = B[j] - B[i]
                    guard (dL * dL + da * da + db * db).squareRoot() < growStep * 2
                    else { continue }
                    cloud[j] = true
                    queue.append(j)
                }
            }
            // Under a CLEAR BLUE sky a cloud is surrounded by blue. A bright region
            // that touches the blue only along one edge and is otherwise bordered by
            // trees, buildings or the frame is a snowfield or a sunlit facade (983's
            // defocused mountain), so under a blue seed each cloud component must have
            // most of its border on the seed. An overcast or pale seed (7301) is cloud
            // itself, and its lower cloud is bordered by the land by nature.
            if seedMeanB(seed, B) < -0.05 {
                var visited = [Bool](repeating: false, count: n)
                for start in 0..<n where cloud[start] && !visited[start] {
                    var members = [start]
                    visited[start] = true
                    var onSeed = 0, offSeed = 0
                    var k = 0
                    while k < members.count {
                        let i = members[k]; k += 1
                        let x = i % w, y = i / w
                        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                            let xx = x + dx, yy = y + dy
                            guard xx >= 0, xx < w, yy >= 0, yy < h else {
                                offSeed += 1
                                continue
                            }
                            let j = yy * w + xx
                            if cloud[j] {
                                if !visited[j] { visited[j] = true; members.append(j) }
                            } else if seed[j] {
                                onSeed += 1
                            } else {
                                offSeed += 1
                            }
                        }
                    }
                    if Double(onSeed) < 0.6 * Double(onSeed + offSeed) {
                        for i in members { cloud[i] = false }
                    }
                }
            }
        }

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
        // The horizon PER COLUMN: the lowest seed row within a neighbourhood of
        // columns. One frame-wide horizon (the 98th percentile of seed rows) drew a
        // straight line across open sky wherever the sky reached lower in a narrow
        // strip than across the rest of the frame — 7301, the church, cut at 52%
        // with the sky running to 75% beside the spire. Columns with no seed nearby
        // take the frame-wide value, which is what governs islands there.
        seedRows.sort()
        let global = Double(seedRows[Swift.min(seedRows.count - 1,
                                               Int(Double(seedRows.count) * 0.98))])
        var lowest = [Int](repeating: -1, count: w)
        for i in 0..<n where seed[i] || cloud[i] {
            lowest[i % w] = Swift.max(lowest[i % w], i / w)
        }
        let span = Swift.max(2, w / 24)
        var horizonCol = [Double](repeating: global, count: w)
        for x in 0..<w {
            var m = -1
            for xx in Swift.max(0, x - span)...Swift.min(w - 1, x + span) {
                m = Swift.max(m, lowest[xx])
            }
            if m >= 0 { horizonCol[x] = Double(m) }
        }
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
            let below = Double(y) - horizonCol[i % w]
            let position = below <= 0 ? 1 : exp(-(below / fade) * (below / fade))
            var p = colour * smoothness.squareRoot() * position
            if seed[i] { p = Swift.max(p, Swift.min(1, colour * 1.5 + 0.5)) }
            if cloud[i] { p = Swift.max(p, 0.9) }
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
            var rowSum = 0.0, colSum = 0.0
            while head < members.count {
                let i = members[head]; head += 1
                if seed[i] || cloud[i] { touchesSeed = true }
                peak = Swift.max(peak, prob.values[i])
                rowSum += Double(i / w)
                colSum += Double(i % w)
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
            let meanCol = Int(colSum / Double(members.count))
            if touchesSeed || (peak > strong && meanRow <= horizonCol[meanCol]) {
                for i in members { keep[i] = true }
            }
        }
        var decided = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = keep[i] ? prob.values[i] : 0
            decided[i] = Float(smoothstep(0.2, 0.7, Double(p)))
        }
        // Holes. A region the sky surrounds on every side — it touches no edge of the
        // frame — and that is small is part of the sky: a cumulus whose white is not
        // the blue's colour and whose edge is too steep for growth to cross, a bird,
        // a contrail. A tree crown, a spire, a lantern or a snow slope connects to the
        // land or to a frame edge and is never a hole.
        do {
            var visited = [Bool](repeating: false, count: n)
            let limit = Int(0.03 * Double(n))
            let speck = Swift.max(2, Int(0.0005 * Double(n)))
            let cloudFloor = seedMeanL(seed, L) - 0.05
            for start in 0..<n where decided[start] < 0.5 && !visited[start] {
                var members = [start]
                visited[start] = true
                var touchesEdge = false
                var k = 0
                while k < members.count {
                    let i = members[k]; k += 1
                    let x = i % w, y = i / w
                    if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesEdge = true }
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                        let j = yy * w + xx
                        guard !visited[j], decided[j] < 0.5 else { continue }
                        visited[j] = true
                        members.append(j)
                    }
                }
                guard !touchesEdge, members.count <= limit else { continue }
                // Only CLOUD-LIKE holes (bright, low chroma), or specks too small to
                // matter (a bird, a contrail segment). A balloon, a kite, a paraglider
                // is an object the photographer will want left out of a Sky
                // adjustment (verifier round 2: all were swallowed). The moon is bright
                // and grey, and is filled with the clouds: stated in REPORT.
                var sL = 0.0, sC = 0.0
                for i in members {
                    sL += Double(L[i])
                    sC += Double((A[i] * A[i] + B[i] * B[i]).squareRoot())
                }
                let size = Double(members.count)
                let cloudLike = sL / size > cloudFloor && sC / size < 0.08
                if cloudLike || members.count <= speck {
                    for i in members { decided[i] = 1 }
                }
            }
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
                            horizon: horizonCol.map { ($0 + 1) / Double(h) }))
    }

    static func seedMeanB(_ seed: [Bool], _ B: [Float]) -> Double { seedMeanL(seed, B) }

    static func seedMeanL(_ seed: [Bool], _ L: [Float]) -> Double {
        var s = 0.0, k = 0.0
        for i in 0..<seed.count where seed[i] { s += Double(L[i]); k += 1 }
        return k > 0 ? s / k : 0
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

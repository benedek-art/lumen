// CullingAssist.swift
// The arithmetic behind docs/10 §10.6 — evidence, never verdicts.
//
// Three measurements a culling pass can make from the picture the grid already has (the
// camera's embedded preview, or a rung of the preview cache) without decoding a raw:
//
//   · SHARPNESS — the variance of the Laplacian, read where the subject probably is, with
//     the noise floor taken off and the image brought to one analysis scale first. A score
//     in 0…1 that the soft-focus chip thresholds and the sharpness sort orders.
//   · A PERCEPTUAL HASH — 64 bits of the picture's low-frequency layout (DCT pHash), so two
//     frames of one burst can be told from two frames a second apart that show different
//     things.
//   · BURST GROUPING — capture-time proximity AND hash proximity, chained frame to frame,
//     per camera body.
//
// Plus one piece of geometry for the macOS face pass: the eye-aspect ratio of an eye
// contour, which is how an eyes-closed flag is derived from landmarks.
//
// None of it imports an Apple framework, so every rule here is pinned on the Linux lane
// (`CullingAssistTests`). The pixels arrive as a `Plane`; how they were decoded is the
// caller's business (ImageIO on macOS, a synthetic generator in the tests).
//
// THE CONTRACT (D37, D5): these numbers group, order, and badge. Nothing in this file —
// or anything that calls it — writes `photo.flag`. The scores live in `cache.frame_score`
// and `cache.face`, which are disposable and recomputed on a revision bump.

import Foundation

// MARK: - The plane

/// The pictures this file measures are `Plane`s (ImageBuffer.swift): single-channel f32,
/// row-major, origin top-left, holding LUMA in 0…1 — weighted gamma-encoded RGB, not scene
/// luminance. The input is a display-referred JPEG preview, and the edges a focus check
/// cares about are the ones on that preview. These are the conversions and resamplers the
/// culling pass needs on top of the type.
extension Plane {
    /// Rec. 709 luma from 8-bit RGBA/RGBX/BGRA bytes. `redOffset`/`blueOffset` locate the
    /// channels inside each pixel, so either byte order a CGContext hands back works.
    public init(rgba8 bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int,
                bytesPerPixel: Int = 4, redOffset: Int = 0, greenOffset: Int = 1,
                blueOffset: Int = 2) {
        precondition(bytes.count >= bytesPerRow * (height - 1) + width * bytesPerPixel)
        var v = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let p = row + x * bytesPerPixel
                let r = Float(bytes[p + redOffset])
                let g = Float(bytes[p + greenOffset])
                let b = Float(bytes[p + blueOffset])
                v[y * width + x] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            }
        }
        self.init(width: width, height: height, values: v)
    }

    /// 8-bit single-channel bytes.
    public init(gray8 bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int) {
        var v = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                v[y * width + x] = Float(bytes[y * bytesPerRow + x]) / 255
            }
        }
        self.init(width: width, height: height, values: v)
    }

    public var longEdge: Int { max(width, height) }

    /// Area-average resample to an exact size. Every source pixel contributes in
    /// proportion to the area it covers in the destination pixel, so a non-integer
    /// factor neither aliases nor drops rows — which matters here, because a point-sampled
    /// downscale manufactures exactly the high-frequency energy a focus measure counts.
    public func resampled(width newWidth: Int, height newHeight: Int) -> Plane {
        precondition(newWidth > 0 && newHeight > 0)
        if newWidth == width && newHeight == height { return self }
        let horizontal = Plane.areaWeights(source: width, destination: newWidth)
        let vertical = Plane.areaWeights(source: height, destination: newHeight)

        var rows = [Float](repeating: 0, count: newWidth * height)
        for y in 0..<height {
            let base = y * width
            for (dx, taps) in horizontal.enumerated() {
                var acc: Float = 0
                for tap in taps { acc += values[base + tap.index] * tap.weight }
                rows[y * newWidth + dx] = acc
            }
        }
        var out = [Float](repeating: 0, count: newWidth * newHeight)
        for (dy, taps) in vertical.enumerated() {
            for tap in taps {
                let src = tap.index * newWidth
                let dst = dy * newWidth
                for x in 0..<newWidth { out[dst + x] += rows[src + x] * tap.weight }
            }
        }
        return Plane(width: newWidth, height: newHeight, values: out)
    }

    /// Downscale so the long edge is at most `longEdge`, keeping the aspect ratio.
    /// Never upscales: interpolation cannot add detail, only invent it.
    public func fitted(longEdge target: Int) -> Plane {
        guard longEdge > target else { return self }
        let scale = Double(target) / Double(longEdge)
        let w = max(1, Int((Double(width) * scale).rounded()))
        let h = max(1, Int((Double(height) * scale).rounded()))
        return resampled(width: w, height: h)
    }

    /// A sub-rectangle in normalised coordinates, clamped to the plane.
    public func cropped(_ rect: NormalizedRect) -> Plane? {
        let x0 = max(0, min(width, Int((rect.x * Double(width)).rounded(.down))))
        let y0 = max(0, min(height, Int((rect.y * Double(height)).rounded(.down))))
        let x1 = max(0, min(width, Int(((rect.x + rect.width) * Double(width)).rounded(.up))))
        let y1 = max(0, min(height, Int(((rect.y + rect.height) * Double(height)).rounded(.up))))
        guard x1 - x0 >= 3, y1 - y0 >= 3 else { return nil }
        var v = [Float]()
        v.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { v.append(contentsOf: values[(y * width + x0)..<(y * width + x1)]) }
        return Plane(width: x1 - x0, height: y1 - y0, values: v)
    }

    private struct AreaTap {
        let index: Int
        let weight: Float
    }

    private static func areaWeights(source: Int, destination: Int) -> [[AreaTap]] {
        let scale = Double(source) / Double(destination)
        var result: [[AreaTap]] = []
        result.reserveCapacity(destination)
        for d in 0..<destination {
            let start = Double(d) * scale
            let end = Double(d + 1) * scale
            var taps: [AreaTap] = []
            var s = Int(start.rounded(.down))
            while Double(s) < end && s < source {
                let overlap = min(end, Double(s + 1)) - max(start, Double(s))
                if overlap > 1e-9 { taps.append(AreaTap(index: s, weight: Float(overlap / scale))) }
                s += 1
            }
            result.append(taps)
        }
        return result
    }
}

/// A rectangle in 0…1 image coordinates, origin top-left.
public struct NormalizedRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Sharpness

/// One focus reading of one picture (or one region of it).
public struct SharpnessMeasurement: Sendable, Equatable {
    /// 0…1, monotone in the noise-corrected Laplacian energy. The stored number: the
    /// soft-focus chip compares it with a threshold and the sharpness sort orders by it.
    public var score: Double
    /// RMS of the noise-corrected Laplacian at the analysis scale — the physical number
    /// behind `score`, for the hover readout ("show me why").
    public var laplacianRMS: Double
    /// The noise floor as an equivalent white-noise σ (0…1 luma) at the analysis scale —
    /// √(floor / 20), 20 being this Laplacian's gain on white noise. A readout, not an
    /// input: the subtraction uses the floor itself.
    public var noiseSigma: Double
    /// The long edge actually measured.
    public var analysedLongEdge: Int
    /// True when the input was smaller than `SharpnessScorer.analysisLongEdge`, so the
    /// number is on a finer scale than a full-size reading and reads high. A 160 px
    /// embedded thumbnail cannot answer a focus question, and the caller should know.
    public var resolutionLimited: Bool
}

/// Variance-of-Laplacian focus measure, made comparable across pictures.
///
/// Three normalisations, each of which a naive variance-of-Laplacian gets wrong:
///
///   · RESOLUTION. The Laplacian is a per-pixel operator, so the same scene measured at
///     6000 px and at 1600 px gives wildly different variances (an edge spans more pixels,
///     each with a smaller second difference). Everything is area-resampled to one long
///     edge first, so two previews of one frame — a 1616 px embedded JPEG and a 2048 px
///     cache rung — read the same.
///   · NOISE. A high-ISO frame's grain is high-frequency energy, and an uncorrected
///     measure ranks a blurred ISO 12800 frame above a sharp ISO 100 one. Two defences.
///     The Laplacian is taken of a 1 px Gaussian of the plane (see `prepared`), which
///     removes most grain energy before it is counted. And the residual noise floor
///     is measured from the picture itself, as a LOW QUANTILE of |Laplacian| over the
///     analysis plane: most of a photograph is smooth (sky, skin, out-of-focus
///     background), so the bottom quarter of the Laplacian's magnitudes is noise and
///     nothing else, while edges and texture live in the tail. Its variance is subtracted
///     from every tile. Measured on the SAME resampled plane the score is read from, so it
///     is right whatever correlation the camera's demosaic, noise reduction and the
///     resample have given the grain — a white-noise model (20σ² for this kernel)
///     under-subtracts as soon as the noise is not white, and after a 1.5× area resample
///     it is not. Measured rather than looked up from the ISO because an embedded JPEG has
///     had the camera's noise reduction applied and the ISO no longer says how much grain
///     is left.
///   · WHERE THE SUBJECT IS. Shallow depth of field is a choice; a portrait at f/1.4 has a
///     soft background on purpose. The frame is cut into tiles and the reading blends a
///     centre-weighted mean with the mean of the sharpest tenth of the tiles — the
///     in-focus subject wherever it sits — so a sharp off-centre subject on bokeh reads
///     sharp and a frame where nothing is in focus reads soft.
public enum SharpnessScorer {

    /// Bump when anything below changes what a stored score means. The catalog's
    /// backlog query treats a row at another revision as missing.
    public static let analyzerRevision = 1

    /// The scale every reading is taken at. Large enough that a missed focus by a few
    /// centimetres at a portrait distance still moves the number; small enough that a
    /// pass over a 2,000-frame card is seconds of background work, not minutes.
    public static let analysisLongEdge = 1024

    /// Tiles per side for the subject weighting.
    public static let tilesPerSide = 8

    /// The RMS Laplacian-of-Gaussian (0…1 luma, at the analysis scale) at which `score`
    /// reaches 1 − 1/e. Chosen on the synthetic fixture — sparse, moderate-contrast detail
    /// on a smooth ground, not a test chart — so that it reads ≈0.6 crisp and drops under
    /// the default soft-focus threshold (`PhotoQuery.softFocusThreshold`, 0.35) at about
    /// 3–4 px of Gaussian defocus at the 1024 px analysis edge. Deliberately conservative: a
    /// real, more detailed frame reads higher, so the chip under-flags rather than
    /// over-flags. Calibrating it on real shoots is an owner decision (F5 stream report).
    public static let scoreScale = 0.004

    /// The Gaussian applied before the Laplacian, in analysis pixels (see `prepared`).
    public static let presmoothSigma = 1.0

    /// For a zero-mean Gaussian, P(|x| < 0.31864 σ) = 0.25.
    static let lowerQuartileOfAbsNormal = 0.318_639

    /// The whole frame, subject-weighted. `analysisLongEdge` is a parameter only so the
    /// tests can run the identical arithmetic on small planes; production uses the
    /// default.
    public static func measure(_ luma: Plane,
                               analysisLongEdge edge: Int = analysisLongEdge) -> SharpnessMeasurement {
        let plane = prepared(luma, edge: edge)
        let floor = laplacianNoiseFloor(plane)
        let noise = (floor / 20).squareRoot()
        let grid = tileVariances(plane, perSide: tilesPerSide)
        let tiles = grid.values.map { max(0, $0 - floor) }
        guard !tiles.isEmpty else {
            return SharpnessMeasurement(score: 0, laplacianRMS: 0, noiseSigma: noise,
                                        analysedLongEdge: plane.longEdge,
                                        resolutionLimited: luma.longEdge < edge)
        }
        let energy = 0.5 * centreWeighted(tiles, columns: grid.columns)
            + 0.5 * topFraction(tiles, fraction: 0.1)
        let rms = energy.squareRoot()
        return SharpnessMeasurement(score: score(forRMS: rms), laplacianRMS: rms,
                                    noiseSigma: noise, analysedLongEdge: plane.longEdge,
                                    resolutionLimited: luma.longEdge < edge)
    }

    /// One region (a face), measured uniformly — the subject is already chosen.
    ///
    /// The region is read at the frame's analysis scale, so a face's focus number and the
    /// frame's are on the same footing. Nil for a region too small to hold a Laplacian.
    public static func measure(_ luma: Plane, region: NormalizedRect,
                               analysisLongEdge edge: Int = analysisLongEdge) -> SharpnessMeasurement? {
        let plane = prepared(luma, edge: edge)
        guard let crop = plane.cropped(region) else { return nil }
        // The floor from the whole frame: a face crop is mostly skin, which would make a
        // good floor, but a crop that is all eyelashes and hair would not.
        let floor = laplacianNoiseFloor(plane)
        let variance = max(0, laplacianVariance(crop) - floor)
        let rms = variance.squareRoot()
        return SharpnessMeasurement(score: score(forRMS: rms), laplacianRMS: rms,
                                    noiseSigma: (floor / 20).squareRoot(),
                                    analysedLongEdge: plane.longEdge,
                                    resolutionLimited: luma.longEdge < edge)
    }

    /// The monotone map from physical RMS to the stored 0…1 score.
    public static func score(forRMS rms: Double) -> Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        return 1 - exp(-rms / scoreScale)
    }

    // MARK: Pieces

    /// The analysis plane: resampled to the analysis edge, then smoothed by a σ = 1 px
    /// Gaussian, so the operator is a Laplacian-of-Gaussian rather than a bare Laplacian.
    ///
    /// The bare kernel's gain is highest at the Nyquist frequency, which is where grain
    /// lives and where a photograph has almost nothing: measured on the fixture, a σ 0.02
    /// grain left the floor-corrected bare Laplacian of a 5 px-defocused frame at 5.7× its
    /// clean value and above the crisp frame's. After the 1 px Gaussian the same grain moves
    /// the reading by under 10 %, and the floor subtraction only has a small residue to take
    /// off — so its tile-to-tile fluctuation no longer decides the answer.
    static func prepared(_ luma: Plane, edge: Int) -> Plane {
        let plane = luma.fitted(longEdge: edge)
        return SpatialOps.gaussianBlur(plane, sigma: presmoothSigma)
    }

    /// The variance the noise alone contributes to the Laplacian, estimated from the
    /// lower quartile of |Laplacian| as if the smooth quarter of the picture were pure
    /// Gaussian noise. Zero for a clean synthetic plane; for an 8-bit JPEG with flat
    /// areas, the quantisation makes it exactly zero, which is the right answer.
    public static func laplacianNoiseFloor(_ plane: Plane) -> Double {
        let w = plane.width, h = plane.height
        guard w >= 3, h >= 3 else { return 0 }
        // Histogram quantile: exact to 1/16384 of a luma unit, O(n) rather than a sort.
        let bins = 16_384
        let top: Float = 1
        var histogram = [Int](repeating: 0, count: bins + 1)
        var count = 0
        let v = plane.values
        for y in 1..<(h - 1) {
            let row = y * w
            for x in 1..<(w - 1) {
                let i = row + x
                let magnitude = abs(4 * v[i] - v[i - 1] - v[i + 1] - v[i - w] - v[i + w])
                let bin = magnitude >= top ? bins : Int(magnitude / top * Float(bins))
                histogram[bin] += 1
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let target = max(1, count / 4)
        var seen = 0
        for (bin, n) in histogram.enumerated() {
            seen += n
            if seen >= target {
                // Lower edge of the bin: a quantile that falls in bin 0 is "no noise",
                // not half a bin of it.
                let quartile = Double(bin) / Double(bins) * Double(top)
                let sigma = quartile / lowerQuartileOfAbsNormal
                return sigma * sigma
            }
        }
        return 0
    }

    /// Variance of the 4-neighbour Laplacian over the interior of a plane.
    static func laplacianVariance(_ plane: Plane) -> Double {
        let w = plane.width, h = plane.height
        guard w >= 3, h >= 3 else { return 0 }
        var sum = 0.0, sumSquares = 0.0
        let v = plane.values
        for y in 1..<(h - 1) {
            let row = y * w
            for x in 1..<(w - 1) {
                let i = row + x
                let l = Double(4 * v[i] - v[i - 1] - v[i + 1] - v[i - w] - v[i + w])
                sum += l
                sumSquares += l * l
            }
        }
        let n = Double((w - 2) * (h - 2))
        let mean = sum / n
        return max(0, sumSquares / n - mean * mean)
    }

    /// Laplacian variance per tile, row-major, `perSide` × `perSide` tiles (fewer when
    /// the plane is too small to give each tile a 3 × 3 interior).
    static func tileVariances(_ plane: Plane, perSide: Int) -> (values: [Double], columns: Int) {
        let w = plane.width, h = plane.height
        guard w >= 3, h >= 3 else { return ([], 0) }
        let tx = max(1, min(perSide, (w - 2) / 3))
        let ty = max(1, min(perSide, (h - 2) / 3))
        var sums = [Double](repeating: 0, count: tx * ty)
        var squares = [Double](repeating: 0, count: tx * ty)
        var counts = [Int](repeating: 0, count: tx * ty)
        let v = plane.values
        for y in 1..<(h - 1) {
            let row = y * w
            let tileY = min(ty - 1, (y - 1) * ty / (h - 2))
            for x in 1..<(w - 1) {
                let i = row + x
                let l = Double(4 * v[i] - v[i - 1] - v[i + 1] - v[i - w] - v[i + w])
                let tileX = min(tx - 1, (x - 1) * tx / (w - 2))
                let t = tileY * tx + tileX
                sums[t] += l
                squares[t] += l * l
                counts[t] += 1
            }
        }
        var result = [Double](repeating: 0, count: tx * ty)
        for t in 0..<(tx * ty) where counts[t] > 0 {
            let n = Double(counts[t])
            let mean = sums[t] / n
            result[t] = max(0, squares[t] / n - mean * mean)
        }
        return (result, tx)
    }

    /// Gaussian centre weighting (σ = a quarter of the frame) over a row-major tile grid.
    static func centreWeighted(_ tiles: [Double], columns: Int) -> Double {
        guard columns > 0, !tiles.isEmpty else { return 0 }
        let rowsCount = tiles.count / columns
        var acc = 0.0, weights = 0.0
        for (i, value) in tiles.enumerated() {
            let cx = (Double(i % columns) + 0.5) / Double(columns) - 0.5
            let cy = (Double(i / columns) + 0.5) / Double(rowsCount) - 0.5
            let weight = exp(-(cx * cx + cy * cy) / (2 * 0.25 * 0.25))
            acc += weight * value
            weights += weight
        }
        return weights > 0 ? acc / weights : 0
    }

    /// Mean of the highest `fraction` of values (at least one).
    static func topFraction(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let k = max(1, Int((Double(values.count) * fraction).rounded()))
        let sorted = values.sorted(by: >)
        return sorted.prefix(k).reduce(0, +) / Double(k)
    }
}

// MARK: - Perceptual hash

/// DCT perceptual hash (the "pHash" construction): 32 × 32 area-averaged luma, 2-D DCT-II,
/// the 8 × 8 lowest frequencies without the DC term, each bit set when its coefficient is
/// above the median of the 63. Robust to scale, mild exposure shifts and JPEG; changes
/// when the layout of the picture changes.
public enum PerceptualHash {

    public static let side = 32
    public static let lowFrequencies = 8

    public static func hash(_ luma: Plane) -> UInt64 {
        let small = luma.resampled(width: side, height: side)
        let n = side
        // Separable DCT-II, only the rows/columns we keep.
        var cosines = [Double](repeating: 0, count: lowFrequencies * n)
        for u in 0..<lowFrequencies {
            for x in 0..<n {
                cosines[u * n + x] = cos(Double.pi * Double(u) * (Double(x) + 0.5) / Double(n))
            }
        }
        // Rows: n × lowFrequencies.
        var rowPass = [Double](repeating: 0, count: n * lowFrequencies)
        for y in 0..<n {
            for u in 0..<lowFrequencies {
                var acc = 0.0
                for x in 0..<n { acc += Double(small.values[y * n + x]) * cosines[u * n + x] }
                rowPass[y * lowFrequencies + u] = acc
            }
        }
        var coefficients: [Double] = []
        coefficients.reserveCapacity(lowFrequencies * lowFrequencies)
        for v in 0..<lowFrequencies {
            for u in 0..<lowFrequencies {
                var acc = 0.0
                for y in 0..<n { acc += rowPass[y * lowFrequencies + u] * cosines[v * n + y] }
                coefficients.append(acc)
            }
        }
        let ac = Array(coefficients.dropFirst())          // 63 values, DC removed
        let median = ac.sorted()[ac.count / 2]
        var bits: UInt64 = 0
        for (i, c) in ac.enumerated() where c > median {
            bits |= (1 as UInt64) << UInt64(i)
        }
        return bits
    }

    /// Hamming distance between two hashes, 0…63 in practice.
    public static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}

// MARK: - Burst grouping

/// What the grouper needs to know about one frame.
public struct BurstCandidate: Sendable, Equatable {
    public var photoID: Int64
    /// Seconds, with the sub-second part folded in. Nil frames are never grouped: a
    /// burst is a statement about time, and "no time" is not "the same time".
    public var captureTime: Double?
    /// Which body shot it. Two shooters a second apart are not one burst.
    public var camera: String?
    public var hash: UInt64?
    /// The frame's sharpness score, for the within-group order. Nil sorts last.
    public var sharpness: Double?

    public init(photoID: Int64, captureTime: Double?, camera: String?,
                hash: UInt64?, sharpness: Double?) {
        self.photoID = photoID
        self.captureTime = captureTime
        self.camera = camera
        self.hash = hash
        self.sharpness = sharpness
    }
}

/// One group of near-duplicate frames.
public struct BurstGroup: Sendable, Equatable {
    /// Capture order.
    public var members: [Int64]
    /// Evidence order: sharpest first, unscored last, ties in capture order. The first
    /// entry is a SUGGESTION the compare view can seed from — never a pick.
    public var ranked: [Int64]

    public init(members: [Int64], ranked: [Int64]) {
        self.members = members
        self.ranked = ranked
    }

    /// The group's stable identity: its earliest frame. Survives a re-run as long as the
    /// first frame of the burst does.
    public var id: Int64 { members.first ?? 0 }
}

/// Burst / near-duplicate grouping (docs/10 §10.2 "Capture-gap ≤2 s AND …distance below
/// threshold").
///
/// CHAINED, not clustered: a frame joins the burst its body is in when it is within
/// `maxGap` of that burst's LAST frame and looks like that last frame. A slow pan where
/// frame 1 and frame 9 share nothing still groups, because each frame resembles the one
/// before it, which is what a burst is. Time decides first and the hash only splits —
/// so a photographer who turns from the bride to the cake in 0.3 s gets two groups.
public enum BurstGrouper {

    public static let maxGapSeconds = 2.0
    /// Out of 63 bits. Two frames of one burst typically differ by 0–8; unrelated
    /// pictures by ~32 (half the bits).
    public static let maxHashDistance = 12

    public static func group(_ candidates: [BurstCandidate],
                             maxGap: Double = maxGapSeconds,
                             maxDistance: Int = maxHashDistance) -> [BurstGroup] {
        let timed = candidates
            .filter { $0.captureTime != nil && $0.hash != nil }
            .sorted {
                ($0.captureTime!, $0.photoID) < ($1.captureTime!, $1.photoID)
            }
        var open: [String: [BurstCandidate]] = [:]
        var closed: [[BurstCandidate]] = []
        for frame in timed {
            let body = frame.camera ?? ""
            if let run = open[body], let last = run.last,
               frame.captureTime! - last.captureTime! <= maxGap,
               PerceptualHash.distance(frame.hash!, last.hash!) <= maxDistance {
                open[body]!.append(frame)
            } else {
                if let run = open[body] { closed.append(run) }
                open[body] = [frame]
            }
        }
        closed.append(contentsOf: open.values)
        return closed
            .filter { $0.count >= 2 }
            .map { run in
                let members = run.map(\.photoID)
                let ranked = run.enumerated().sorted { a, b in
                    switch (a.element.sharpness, b.element.sharpness) {
                    case let (x?, y?) where x != y: return x > y
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: return a.offset < b.offset
                    }
                }.map(\.element.photoID)
                return BurstGroup(members: members, ranked: ranked)
            }
            .sorted { $0.id < $1.id }
    }
}

// MARK: - Eyes

/// Eye openness from a landmark contour.
public enum EyeOpenness {

    /// Height over width of the eye, from its outline: 4·area / (π·width²), where width is
    /// the longest chord between contour points. For an ellipse that is exactly the ratio
    /// of its axes; it uses every point rather than the six of the classic EAR, and it does
    /// not care how the head is rolled. Points are in image pixels (NOT a face box's
    /// normalised coordinates, whose x and y scales differ). Nil for a degenerate outline.
    public static func axisRatio(of contour: [(x: Double, y: Double)]) -> Double? {
        guard contour.count >= 4 else { return nil }
        var width = 0.0
        for i in 0..<contour.count {
            for j in (i + 1)..<contour.count {
                let dx = contour[i].x - contour[j].x, dy = contour[i].y - contour[j].y
                width = max(width, (dx * dx + dy * dy).squareRoot())
            }
        }
        guard width > 0 else { return nil }
        var twiceArea = 0.0
        for i in 0..<contour.count {
            let a = contour[i], b = contour[(i + 1) % contour.count]
            twiceArea += a.x * b.y - b.x * a.y
        }
        let area = abs(twiceArea) / 2
        return 4 * area / (Double.pi * width * width)
    }

    /// Aspect ratio at or below which an eye reads fully closed, and at or above which it
    /// reads fully open. An open adult eye sits around 0.28–0.40, a blink below 0.12.
    public static let closedRatio = 0.10
    public static let openRatio = 0.30

    /// 0 (closed) … 1 (open), linear between the two ratios. This is what `cache.face.
    /// eyes_open` holds, so `PhotoQuery.closedEyesThreshold` (0.35) is "the more open
    /// eye of a face reads below about a third open".
    public static func openness(aspectRatio ratio: Double) -> Double {
        guard ratio.isFinite else { return 0 }
        return min(1, max(0, (ratio - closedRatio) / (openRatio - closedRatio)))
    }

    /// One face: the MORE open of the two eyes. A wink, a squint into the sun, or an eye
    /// the landmarker lost behind hair should not read as a blink; a blink closes both.
    public static func faceOpenness(left: Double?, right: Double?) -> Double? {
        switch (left, right) {
        case let (l?, r?): return max(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }
}

// MARK: - What the grid shows

/// The attention dot's state for one frame (docs/10 §10.2 "Attention dot": a pointer to
/// evidence, never a verdict).
///
/// Derived from the SAME thresholds the evidence chips query with, so a dot on a cell and
/// the chip that lists it cannot disagree: lighting "Soft focus" shows exactly the cells
/// that carry a soft-focus dot. Unscored frames have no attention at all — the dot is
/// silence until there is evidence, never a guess.
public struct CullingAttention: Equatable, Sendable {
    public var sharpness: Double?
    public var softFocus: Bool
    public var eyesClosed: Bool
    /// Frames in this frame's burst, nil when it is not in one.
    public var burstSize: Int?
    /// 1-based place in the burst's evidence order (sharpest first).
    public var burstRank: Int?

    public init(sharpness: Double?, softFocus: Bool, eyesClosed: Bool,
                burstSize: Int? = nil, burstRank: Int? = nil) {
        self.sharpness = sharpness
        self.softFocus = softFocus
        self.eyesClosed = eyesClosed
        self.burstSize = burstSize
        self.burstRank = burstRank
    }

    /// Whether the cell draws the dot. Burst membership alone is not attention: a burst
    /// is a grouping, and every frame of a 9 fps sequence wearing a dot would be the
    /// grid shouting.
    public var needsAttention: Bool { softFocus || eyesClosed }

    /// The hover text: the number behind the dot ("show me why, let me decide").
    public var explanation: String {
        var parts: [String] = []
        if softFocus, let sharpness {
            parts.append("Soft focus — sharpness \(Int((sharpness * 100).rounded())) of 100")
        }
        if eyesClosed { parts.append("A face reads with eyes closed") }
        if let burstSize, let burstRank {
            parts.append("Burst of \(burstSize), \(CullingAttention.ordinal(burstRank)) "
                         + "sharpest")
        }
        parts.append("Evidence, not a verdict")
        return parts.joined(separator: ". ")
    }

    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// Every scored frame's attention, keyed by photo id.
    ///
    /// `softFocusThreshold` is the query's (`PhotoQuery.softFocusThreshold`) and the
    /// comparison is the predicate's (`sharpness < threshold`, NULL never soft);
    /// `closedEyes` is the set the closed-eyes chip returns. Same numbers, same answer.
    public static func evidence(scores: [FrameScoreRow], closedEyes: Set<Int64>,
                                softFocusThreshold: Double = PhotoQuery().softFocusThreshold)
        -> [Int64: CullingAttention] {
        var burstSizes: [Int64: Int] = [:]
        for row in scores { if let burst = row.burstID { burstSizes[burst, default: 0] += 1 } }
        var result: [Int64: CullingAttention] = [:]
        result.reserveCapacity(scores.count)
        for row in scores {
            let soft = row.sharpness.map { $0 < softFocusThreshold } ?? false
            result[row.photoID] = CullingAttention(
                sharpness: row.sharpness, softFocus: soft,
                eyesClosed: closedEyes.contains(row.photoID),
                burstSize: row.burstID.flatMap { burstSizes[$0] },
                burstRank: row.burstID == nil ? nil : row.burstRank)
        }
        return result
    }
}

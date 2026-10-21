// DustDetection.swift
// Find sensor dust (docs/09 §Dust Removal), so one click can place a heal spot on every
// speck that Visualize Spots would show.
//
// WHAT DUST IS, TO A DETECTOR. A shadow of a particle on the sensor's cover glass: out
// of focus, so a soft ROUND blob with no texture of its own; MULTIPLICATIVE, so the same
// fraction darker whatever it lies on; and only worth finding where the picture around
// it is SMOOTH — on foliage a 10 % darker blob is texture, not a defect, and a spot put
// there would be a heal nobody asked for. So:
//
//   · log luma (`LumenLog.encode`), where a multiplicative darkening is a constant
//     depth at every brightness;
//   · at each of `scales`, the mean of a centre box against the mean of the square
//     annulus around it — a difference of boxes, with summed-area tables so every
//     scale costs the same;
//   · a candidate is a local minimum of that difference that is DEEPER than
//     `minimumDepth` and than `textureFactor` times the annulus's own standard
//     deviation, on a surround no rougher than `maximumSurroundSigma`, and darker
//     than each of the annulus's four quadrants by 60 % of its depth (round, not an
//     edge or a line), no deeper than `maximumDepth` and SOFT (`softness`): dust is
//     an out-of-focus shadow, and a dark thing with a hard rim is the photograph;
//   · candidates are kept best-first across scales, a weaker one dropped when it lies
//     within the stronger one's radius.
//
// The spot radius is the scale times `radiusPerScale`, measured (DustDetectionTests) so
// the circle covers a dust shadow's soft edge, as a photographer would size it.
//
// Coordinates: buffer pixels, top-down, centres +0.5, like every image in LumenCore.
// The app searches the S5 input in windows (`RenderCoordinator.dustCandidates`) and maps
// each answer back to source-normalized coordinates.

import Foundation

public enum DustDetection {

    public struct Speck: Sendable, Equatable {
        /// Centre, buffer pixels.
        public let x: Double
        public let y: Double
        /// The heal circle's radius, buffer pixels.
        public let radius: Double
        /// Depth in stops (positive: darker than the surround).
        public let depth: Double
        /// Depth over the detection threshold; ≥ 1.
        public let score: Double
    }

    /// Centre-box half-widths, in buffer pixels.
    public static let scales: [Int] = [2, 3, 5, 8, 12]
    /// The annulus is the box of `outer`·r less the box of `inner`·r.
    static let inner = 2, outer = 4
    /// The smallest darkening reported, in stops: 4 %.
    public static let minimumDepth: Double = 0.06
    /// The deepest: a dust shadow is out of focus and rarely takes more than 40 % of the
    /// light; a blob darker than this is a hole, a pit or a dark object, which is the
    /// photograph.
    public static let maximumDepth: Double = 0.75
    /// SOFTNESS: the steepest log-luma step inside the blob, per pixel, may be at most
    /// this times depth ÷ scale (plus the surround's noise). A shadow that fades over
    /// its whole radius is far under it; a pit or a speck of grit with a hard rim is not.
    public static let softness: Double = 1.2
    /// How far beyond the surround's own pixel variation a speck must reach.
    public static let textureFactor: Double = 3
    /// The roughest surround (standard deviation, stops) dust is looked for on: sky,
    /// skin, plaster. Beyond it the picture is texture, and a dark blob in texture is
    /// a leaf's shadow.
    public static let maximumSurroundSigma: Double = 0.08
    /// Heal radius per unit of the scale it was found at.
    public static let radiusPerScale: Double = 4
    /// At most this many specks, deepest-scored first.
    public static let maximumCount = 80

    /// The specks in a scene-linear buffer. `sensitivity` 0…100 (default 50) scales the
    /// thresholds: 100 halves them, 0 doubles them.
    public static func find(in image: ImageBuffer, sensitivity: Double = 50) -> [Speck] {
        let w = image.width, h = image.height
        guard w >= 16, h >= 16 else { return [] }
        var luma = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let c = image[x, y]
                let l = 0.2627 * c.r + 0.678 * c.g + 0.0593 * c.b
                // In stops: encode is 1/24 per stop.
                luma[y * w + x] = LumenLog.encode(l) * LumenLog.range
            }
        }
        let s = Num.clamp(sensitivity.isFinite ? sensitivity : 50, 0, 100) / 100
        let gain = pow(2, 1 - 2 * s)   // 2 at 0, 1 at 50, 0.5 at 100
        let sat = SummedArea(luma, w, h)

        var found: [Speck] = []
        for r in scales {
            let ro = outer * r, ri = inner * r
            guard 2 * ro + 1 < Swift.min(w, h) else { continue }
            var response = [Double](repeating: 0, count: w * h)
            var limit = [Double](repeating: .infinity, count: w * h)
            var sigmas = [Double](repeating: 0, count: w * h)
            for y in ro..<(h - ro) {
                for x in ro..<(w - ro) {
                    let centre = sat.mean(x - r, y - r, x + r, y + r)
                    let (outerSum, outerSq, outerN) = sat.sums(x - ro, y - ro, x + ro, y + ro)
                    let (innerSum, innerSq, innerN) = sat.sums(x - ri, y - ri, x + ri, y + ri)
                    let n = outerN - innerN
                    let mean = (outerSum - innerSum) / n
                    let variance = Swift.max((outerSq - innerSq) / n - mean * mean, 0)
                    response[y * w + x] = centre - mean
                    let sigma = variance.squareRoot()
                    guard sigma <= maximumSurroundSigma else { continue }
                    sigmas[y * w + x] = sigma
                    limit[y * w + x] = gain * Swift.max(minimumDepth, textureFactor * sigma)
                }
            }
            for y in (ro + 1)..<(h - ro - 1) {
                for x in (ro + 1)..<(w - ro - 1) {
                    let v = response[y * w + x]
                    let threshold = limit[y * w + x]
                    guard -v > threshold, -v <= maximumDepth else { continue }
                    var isMinimum = true
                    for dy in -1...1 where isMinimum {
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            if response[(y + dy) * w + x + dx] < v { isMinimum = false; break }
                        }
                    }
                    guard isMinimum else { continue }
                    // Round: every quadrant of the annulus brighter than the centre.
                    let centre = sat.mean(x - r, y - r, x + r, y + r)
                    let quadrants = [
                        sat.mean(x - ro, y - ro, x - ri - 1, y + ro),  // left
                        sat.mean(x + ri + 1, y - ro, x + ro, y + ro),  // right
                        sat.mean(x - ro, y - ro, x + ro, y - ri - 1),  // top
                        sat.mean(x - ro, y + ri + 1, x + ro, y + ro),  // bottom
                    ]
                    guard quadrants.allSatisfy({ $0 - centre > -0.6 * v }) else { continue }
                    // Soft: no hard rim anywhere in the blob.
                    let reachBlob = 2 * r
                    var steepest = 0.0
                    for yy in Swift.max(y - reachBlob, 1)...Swift.min(y + reachBlob, h - 2) {
                        for xx in Swift.max(x - reachBlob, 1)...Swift.min(x + reachBlob, w - 2) {
                            let gx = (luma[yy * w + xx + 1] - luma[yy * w + xx - 1]) / 2
                            let gy = (luma[(yy + 1) * w + xx] - luma[(yy - 1) * w + xx]) / 2
                            steepest = Swift.max(steepest, (gx * gx + gy * gy).squareRoot())
                        }
                    }
                    // The noise allowance: a central difference of two pixels of
                    // surround-σ noise reaches about 2σ.
                    guard steepest <= softness * -v / Double(r) + 2.5 * sigmas[y * w + x]
                    else { continue }
                    found.append(Speck(x: Double(x) + 0.5, y: Double(y) + 0.5,
                                       radius: radiusPerScale * Double(r),
                                       depth: -v, score: -v / threshold))
                }
            }
        }

        // Best first; a weaker detection inside a stronger one's circle is the same speck
        // seen at another scale, or its ring.
        found.sort { $0.score > $1.score || ($0.score == $1.score && $0.radius < $1.radius) }
        var kept: [Speck] = []
        for speck in found {
            guard kept.count < maximumCount else { break }
            let covered = kept.contains {
                hypot($0.x - speck.x, $0.y - speck.y) < Swift.max($0.radius, speck.radius)
            }
            if !covered { kept.append(speck) }
        }
        return kept
    }

    /// Summed-area tables of a plane and of its square.
    struct SummedArea {
        let w: Int
        let h: Int
        var sum: [Double]
        var square: [Double]

        init(_ v: [Double], _ w: Int, _ h: Int) {
            self.w = w
            self.h = h
            sum = [Double](repeating: 0, count: (w + 1) * (h + 1))
            square = sum
            for y in 0..<h {
                var row = 0.0, rowSq = 0.0
                for x in 0..<w {
                    let value = v[y * w + x]
                    row += value
                    rowSq += value * value
                    sum[(y + 1) * (w + 1) + x + 1] = sum[y * (w + 1) + x + 1] + row
                    square[(y + 1) * (w + 1) + x + 1] = square[y * (w + 1) + x + 1] + rowSq
                }
            }
        }

        /// Sum, sum of squares and count over the inclusive box, clamped to the plane.
        func sums(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> (Double, Double, Double) {
            let a = Swift.max(x0, 0), b = Swift.max(y0, 0)
            let c = Swift.min(x1, w - 1) + 1, d = Swift.min(y1, h - 1) + 1
            guard c > a, d > b else { return (0, 0, 0) }
            let stride = w + 1
            let s = sum[d * stride + c] - sum[b * stride + c] - sum[d * stride + a]
                + sum[b * stride + a]
            let q = square[d * stride + c] - square[b * stride + c] - square[d * stride + a]
                + square[b * stride + a]
            return (s, q, Double((c - a) * (d - b)))
        }

        func mean(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
            let (s, _, n) = sums(x0, y0, x1, y1)
            return n > 0 ? s / n : 0
        }
    }

    // MARK: Searching a frame in windows

    /// The windows a whole-frame search is cut into: a grid of
    /// `SpotSourceSearch.window`s, each named by the probe spot that produces it, at a
    /// scale that brings the frame's long edge to about `workingLongEdge` pixels. The
    /// app renders each probe's window with the heal search's own tap, so dust is found
    /// in exactly the S5 input a spot is sourced from.
    public static let workingLongEdge: Double = 1800

    public static func probes(sourceWidth: Int, sourceHeight: Int) -> [HealSpot] {
        guard sourceWidth > 0, sourceHeight > 0 else { return [] }
        let w = Double(sourceWidth), h = Double(sourceHeight), edge = Swift.max(w, h)
        // A window spans 2·reach·SpotSourceSearch.reach and is scaled by
        // workingRadius / reach: pick the reach that gives the working scale.
        let scale = Swift.min(1, workingLongEdge / edge)
        let reach = SpotSourceSearch.workingRadius / scale
        let radius = Num.clamp(reach / edge, HealSpot.radiusRange.lowerBound,
                               HealSpot.radiusRange.upperBound)
        let span = 2 * radius * edge * SpotSourceSearch.reach
        // Overlap a quarter, so a speck on one window's edge is whole in the next.
        let step = span * 0.75
        var probes: [HealSpot] = []
        var y = span / 2
        while true {
            var x = span / 2
            while true {
                probes.append(HealSpot(id: "dust-probe", x: Swift.min(x, w - span / 2) / w,
                                       y: Swift.min(y, h - span / 2) / h, sourceX: 0,
                                       sourceY: 0, radius: radius, feather: 0))
                if x + span / 2 >= w { break }
                x += step
            }
            if y + span / 2 >= h { break }
            y += step
        }
        return probes
    }

    /// Specks from every window, in source-normalized coordinates with a source-relative
    /// radius (`HealSpot.radius`'s unit), duplicates across window overlaps merged.
    public static func merge(_ windows: [(specks: [Speck], window: SpotSourceSearch.Window,
                                          bufferWidth: Int, bufferHeight: Int)],
                             sourceWidth: Int, sourceHeight: Int)
        -> [(x: Double, y: Double, radius: Double, score: Double)] {
        let w = Double(sourceWidth), h = Double(sourceHeight), edge = Swift.max(w, h)
        var all: [(x: Double, y: Double, r: Double, score: Double)] = []
        for entry in windows {
            let toX = Double(entry.window.width) / Double(Swift.max(entry.bufferWidth, 1))
            let toY = Double(entry.window.height) / Double(Swift.max(entry.bufferHeight, 1))
            for s in entry.specks {
                // A speck on a window's margin is half seen; the overlap shows it whole.
                let bx = s.x / Double(entry.bufferWidth), by = s.y / Double(entry.bufferHeight)
                let inner = bx > 0.08 && bx < 0.92 && by > 0.08 && by < 0.92
                let atFrameEdge = entry.window.x == 0 || entry.window.y == 0
                    || entry.window.x + entry.window.width >= sourceWidth
                    || entry.window.y + entry.window.height >= sourceHeight
                guard inner || atFrameEdge else { continue }
                all.append((Double(entry.window.x) + s.x * toX,
                            Double(entry.window.y) + s.y * toY,
                            s.radius * Swift.min(toX, toY), s.score))
            }
        }
        all.sort { $0.score > $1.score }
        var kept: [(x: Double, y: Double, r: Double, score: Double)] = []
        for s in all where !kept.contains(where: { hypot($0.x - s.x, $0.y - s.y) < Swift.max($0.r, s.r) }) {
            kept.append(s)
            if kept.count >= maximumCount { break }
        }
        return kept.map { ($0.x / w, $0.y / h, $0.r / edge, $0.score) }
    }
}

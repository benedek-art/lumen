// ExposureMatch.swift
// Match Total Exposures (Lightroom's Settings > Match Total Exposures): set each
// selected frame's Exposure slider so that what the camera captured plus what the
// slider adds comes out the same as on the reference frame.
//
// The camera's share is read from the capture settings alone. Image brightness for a
// fixed scene is proportional to t · ISO / N², so in stops
//
//     captured = log2(t · ISO / 100 / N²)
//     total    = captured + exposure slider
//
// and matching a frame to the reference is `exposure = ref.exposure + ref.captured −
// frame.captured`. A frame shot one stop brighter (twice the shutter, or one stop more
// ISO) gets one stop less on the slider.
//
// THE CAPTURE SETTINGS ARE NOT THE PICTURE, and the corpus pair proves it. 6929 and 6933
// are the same street a moment apart on the owner's A7 IV; EXIF says 6933 was captured
// 0.68 EV brighter, the registered pixels say 0.39 EV. Matched on EXIF alone, as
// Lightroom does, the pair came out 0.30 EV apart the OTHER way — worse than not
// matching. Overcast light moves, and so does a sensor's real gain against its ISO
// label.
//
// Nor is the whole-frame average the picture. The same pair measured frame-against-frame
// reads EQUAL (−1.156 against −1.159 EV) because 6929 holds more white wall and 6933 more
// foliage: composition, not exposure. So the measurement is taken where the two frames
// see the same thing. `measureOverlap` locates one frame inside the other on a small
// scene-EV grid (translation and a few zoom ratios, correlation of the log-luminance
// GRADIENT, so composition alone cannot match) and
// takes the median difference over the shared cells; on 6929/6933 that is the 0.39 EV
// the registered full-resolution decode gives. When the frames do not share a view
// (correlation under `overlapThreshold`) there is nothing to compare, the scene really
// did change, and the match falls back to the capture settings, which is Lightroom's
// rule and the right one for "the camera changed its mind".
//
// Pure arithmetic, so it lives here and is tested on Linux; the app reads the EXIF and
// writes the sliders (`AppStateMatchExposure.swift`).

import Foundation

public enum ExposureMatch {

    /// The three capture settings the match needs, as the file states them.
    public struct Capture: Equatable, Sendable {
        public var shutterSeconds: Double?
        public var aperture: Double?
        public var iso: Int?

        public init(shutterSeconds: Double? = nil, aperture: Double? = nil, iso: Int? = nil) {
            self.shutterSeconds = shutterSeconds
            self.aperture = aperture
            self.iso = iso
        }

        public init(metadata: PhotoMetadata) {
            self.init(shutterSeconds: metadata.shutterSeconds,
                      aperture: metadata.aperture, iso: metadata.iso)
        }

        /// Only positive, finite values count. EXIF writes 0 for "unknown" often enough
        /// (an adapted manual lens reports FNumber 0) that zero must read as absent.
        var shutter: Double? { Self.usable(shutterSeconds) }
        var fNumber: Double? { Self.usable(aperture) }
        var isoValue: Double? { Self.usable(iso.map(Double.init)) }

        private static func usable(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
    }

    /// The camera's contribution in stops, relative to 1 s at f/1 and ISO 100, or nil
    /// when shutter, aperture or ISO is missing. Higher is a brighter capture.
    public static func capturedStops(_ capture: Capture) -> Double? {
        guard let t = capture.shutter, let n = capture.fNumber, let iso = capture.isoValue
        else { return nil }
        return log2(t * iso / 100 / (n * n))
    }

    /// The stops `frame` was captured brighter than `reference`, or nil when the two
    /// cannot be compared.
    ///
    /// One allowance: an aperture missing on BOTH frames is taken to be the same
    /// aperture. A manual lens records none, and an astro session on one is the common
    /// case — every frame through the same glass at the same ring setting. Missing on
    /// only one side is still unknown, because then the frames came through different
    /// lenses or settings and nothing says how far apart.
    public static func stopsBrighter(_ frame: Capture, than reference: Capture) -> Double? {
        guard let t = frame.shutter, let iso = frame.isoValue,
              let refT = reference.shutter, let refISO = reference.isoValue
        else { return nil }
        var stops = log2(t / refT) + log2(iso / refISO)
        switch (frame.fNumber, reference.fNumber) {
        case let (n?, refN?): stops += 2 * log2(refN / n)
        case (nil, nil): break
        default: return nil
        }
        return stops
    }

    /// What happened to one frame.
    public enum Outcome: Equatable, Sendable {
        /// The reference itself: left alone, everything else is measured against it.
        case reference
        /// The new slider value. `clamped` is true when the match needed more than the
        /// slider allows, so this frame still differs from the reference.
        case set(exposure: Double, clamped: Bool)
        /// Shutter, aperture or ISO missing; the slider is left alone.
        case skipped
    }

    /// One selected frame going in: its capture settings and its current slider.
    public struct Frame<ID: Hashable & Sendable>: Sendable {
        public var id: ID
        public var capture: Capture
        public var exposure: Double
        /// Stops this frame is brighter than the reference, MEASURED on the content
        /// the two share with every tone slider at zero (`measureOverlap`), or nil when
        /// they were not measured or share no view.
        public var measuredStopsBrighter: Double?

        public init(id: ID, capture: Capture, exposure: Double,
                    measuredStopsBrighter: Double? = nil) {
            self.id = id
            self.capture = capture
            self.exposure = exposure
            self.measuredStopsBrighter = measuredStopsBrighter.flatMap { $0.isFinite ? $0 : nil }
        }

        /// Stops this frame is brighter than `reference` before either slider: measured
        /// when it was, else from the capture settings.
        func stopsBrighter(than reference: Frame) -> (stops: Double, measured: Bool)? {
            if let m = measuredStopsBrighter { return (m, true) }
            return ExposureMatch.stopsBrighter(capture, than: reference.capture).map { ($0, false) }
        }
    }

    /// The whole command's answer.
    public struct Plan<ID: Hashable & Sendable>: Sendable {
        /// Nil when the reference itself lacks the metadata, in which case nothing can
        /// be matched and every frame is left alone.
        public var outcomes: [ID: Outcome]?
        /// How many of the matched frames were matched on measured brightness rather
        /// than on capture settings.
        public var measuredCount: Int

        public init(outcomes: [ID: Outcome]?, measuredCount: Int = 0) {
            self.outcomes = outcomes
            self.measuredCount = measuredCount
        }

        /// The slider values to write, frames that need no change included.
        public var exposures: [ID: Double] {
            var out: [ID: Double] = [:]
            for (id, outcome) in outcomes ?? [:] {
                if case let .set(exposure, _) = outcome { out[id] = exposure }
            }
            return out
        }

        public var matchedCount: Int { exposures.count }
        public var skippedCount: Int {
            (outcomes ?? [:]).values.filter { $0 == .skipped }.count
        }
        public var clampedCount: Int {
            (outcomes ?? [:]).values.filter {
                if case .set(_, true) = $0 { return true } else { return false }
            }.count
        }
    }

    /// Lightroom's Exposure slider range, which is Develop's (`Tone`'s −5…+5).
    public static let sliderRange: ClosedRange<Double> = -5...5

    /// Match every frame to the one whose id is `referenceID`.
    ///
    /// Values are rounded to a hundredth of a stop, the precision the slider shows, so
    /// 1/250 against 1/500 lands on exactly −1.00 rather than −0.9999999.
    public static func plan<ID>(referenceID: ID, frames: [Frame<ID>],
                                range: ClosedRange<Double> = sliderRange) -> Plan<ID> {
        guard let reference = frames.first(where: { $0.id == referenceID }) else {
            return Plan(outcomes: nil)
        }
        // The reference needs its own settings, or some frame a measurement against
        // it; with neither, there is no total to match anything to. Aperture alone may
        // be absent (see `stopsBrighter`).
        guard (reference.capture.shutter != nil && reference.capture.isoValue != nil)
            || frames.contains(where: { $0.id != referenceID && $0.measuredStopsBrighter != nil })
        else {
            return Plan(outcomes: nil)
        }
        var outcomes: [ID: Outcome] = [:]
        var measured = 0
        for frame in frames {
            if frame.id == referenceID {
                outcomes[frame.id] = .reference
                continue
            }
            guard let (brighter, wasMeasured) = frame.stopsBrighter(than: reference) else {
                outcomes[frame.id] = .skipped
                continue
            }
            if wasMeasured { measured += 1 }
            let wanted = ((reference.exposure - brighter) * 100).rounded() / 100
            let clampedValue = min(max(wanted, range.lowerBound), range.upperBound)
            outcomes[frame.id] = .set(exposure: clampedValue, clamped: clampedValue != wanted)
        }
        return Plan(outcomes: outcomes, measuredCount: measured)
    }

    /// The status-bar line for a finished plan. `referenceName` is the reference's
    /// filename, so the photographer can see which frame everything was matched to.
    public static func summary<ID>(_ plan: Plan<ID>, referenceName: String) -> String {
        guard plan.outcomes != nil else {
            return "\(referenceName) has no shutter speed or ISO recorded — "
                + "nothing to match exposures to"
        }
        let matched = plan.matchedCount
        guard matched > 0 else {
            return "No frame could be matched — none records shutter, aperture and ISO"
        }
        var text = "Matched \(matched) photo" + (matched == 1 ? "" : "s")
            + " to \(referenceName)"
        if plan.measuredCount > 0 {
            text += plan.measuredCount == matched ? " by measured brightness"
                : " (\(plan.measuredCount) by measured brightness)"
        }
        let skipped = plan.skippedCount
        if skipped > 0 {
            text += " — \(skipped) skipped (no shutter, aperture or ISO)"
        }
        let clamped = plan.clampedCount
        if clamped > 0 {
            text += " — \(clamped) at the slider's limit"
        }
        return text
    }

    // MARK: - Measuring on the shared view

    /// A frame's scene brightness on a coarse grid: log2 scene luminance relative to
    /// mid-grey per cell, nil where the cell is censored (at the transform's anchors) or
    /// at the sensor's clip, so neither end can vote.
    public struct LumaGrid: Sendable {
        public let columns: Int
        public let rows: Int
        public var ev: [Double?]

        public init(columns: Int, rows: Int, ev: [Double?]) {
            precondition(ev.count == columns * rows)
            self.columns = columns
            self.rows = rows
            self.ev = ev
        }

        public subscript(x: Int, y: Int) -> Double? { ev[y * columns + x] }

        /// Built from an 8-bit sRGB proxy rendered through `transform` with the tone
        /// sliders at zero — the same proxy Auto Tone reads.
        public init(encodedSRGB bytes: [UInt8], width: Int, height: Int, channels: Int,
                    transform: DisplayTransform, displayWhite: Double, columns: Int = 64) {
            let cols = Swift.max(1, Swift.min(columns, width))
            let rows = Swift.max(1, Int((Double(height) / Double(width) * Double(cols)).rounded()))
            let inverse = AutoTone.SceneHistogram(transform: transform)
            let w = RGBColorSpace.srgb.luminanceWeights
            var decode = [Double](repeating: 0, count: 256)
            for i in 0..<256 { decode[i] = TransferFunction.srgb.decode(Double(i) / 255) }
            var sum = [Double](repeating: 0, count: cols * rows)
            var count = [Int](repeating: 0, count: cols * rows)
            var bad = [Int](repeating: 0, count: cols * rows)
            let lo = transform.params.blackAnchorEV + 0.25
            let hi = transform.params.whiteAnchorEV - 0.25
            for y in 0..<height {
                let cy = Swift.min(rows - 1, y * rows / height)
                for x in 0..<width {
                    let i = (y * width + x) * channels
                    guard i + 2 < bytes.count else { continue }
                    let cx = Swift.min(cols - 1, x * cols / width)
                    let c = cy * cols + cx
                    let lum = w.r * decode[Int(bytes[i])] + w.g * decode[Int(bytes[i + 1])]
                        + w.b * decode[Int(bytes[i + 2])]
                    let ev = inverse.sceneEV(displayLuminance: lum * displayWhite)
                    if ev <= lo || ev >= hi || Swift.max(bytes[i], bytes[i + 1], bytes[i + 2]) >= 254 {
                        bad[c] += 1
                    } else {
                        sum[c] += ev
                        count[c] += 1
                    }
                }
            }
            var out = [Double?](repeating: nil, count: cols * rows)
            for c in 0..<(cols * rows) where count[c] > 0 && bad[c] * 4 < count[c] {
                out[c] = sum[c] / Double(count[c])
            }
            self.init(columns: cols, rows: rows, ev: out)
        }

        /// The central `fraction` of the grid, both ways.
        func centre(_ fraction: Double) -> LumaGrid {
            let c = Swift.max(1, Int((Double(columns) * fraction).rounded()))
            let r = Swift.max(1, Int((Double(rows) * fraction).rounded()))
            let x0 = (columns - c) / 2, y0 = (rows - r) / 2
            var out: [Double?] = []
            out.reserveCapacity(c * r)
            for y in y0..<(y0 + r) { for x in x0..<(x0 + c) { out.append(self[x, y]) } }
            return LumaGrid(columns: c, rows: r, ev: out)
        }

        /// Box-resample to `columns` × `rows` (nil cells stay out of the average).
        func resampled(columns: Int, rows: Int) -> LumaGrid {
            var out = [Double?](repeating: nil, count: columns * rows)
            for y in 0..<rows {
                for x in 0..<columns {
                    let x0 = x * self.columns / columns
                    let x1 = Swift.max(x0 + 1, (x + 1) * self.columns / columns)
                    let y0 = y * self.rows / rows
                    let y1 = Swift.max(y0 + 1, (y + 1) * self.rows / rows)
                    var s = 0.0, n = 0
                    for yy in y0..<Swift.min(y1, self.rows) {
                        for xx in x0..<Swift.min(x1, self.columns) {
                            if let v = self[xx, yy] { s += v; n += 1 }
                        }
                    }
                    if n > 0 { out[y * columns + x] = s / Double(n) }
                }
            }
            return LumaGrid(columns: columns, rows: rows, ev: out)
        }
    }

    /// Below this correlation the two frames are not taken to show the same scene.
    ///
    /// The correlation is of the GRADIENT of log luminance (differences between
    /// neighbouring cells), not of the luminance itself. Level correlation is fooled by
    /// composition: almost every outdoor frame is bright above and dark below, and the
    /// best of ~1,500 placements of a field against a castle scored 0.87 on levels, so
    /// unrelated corpus frames got "measured" offsets of up to 1.8 EV. Gradients carry
    /// the edges, which two different scenes do not share, and it is taken per quadrant
    /// (see `overlap`) so one shared horizon cannot carry it. Over all 600 ordered corpus
    /// pairs that score is 0.79 for 6929/6933 and at most 0.19 for any unrelated pair;
    /// the threshold sits between them.
    public static let overlapThreshold: Double = 0.5
    /// The zoom ratios searched: the frame's field of view relative to the reference's,
    /// which covers an APS-C crop (1.5) and a modest zoom or step either way. Each is
    /// searched over every translation, and so is a pan at the same focal length (the
    /// central `panWindow` of the frame, placed anywhere in the reference).
    public static let overlapScales: [Double] = [1, 1.25, 1.5, 1.75, 2]
    public static let panWindow: Double = 0.7

    /// The result of locating one frame within another.
    public struct Overlap: Equatable, Sendable {
        /// Median of (frame − reference) scene EV over the shared cells.
        public var stopsBrighter: Double
        /// Gradient correlation at the chosen placement.
        public var correlation: Double
        public var sharedCells: Int
    }

    /// Stops `frame` is brighter than `reference` on the content they share, or nil when
    /// they share none. Either frame may hold the narrower view.
    public static func measureOverlap(reference: LumaGrid, frame: LumaGrid) -> Overlap? {
        var best: Overlap?
        func consider(wide: LumaGrid, narrow: LumaGrid, scale: Double, sign: Double) {
            let cols = Int((Double(wide.columns) / scale).rounded())
            let rows = Int((Double(narrow.rows) / Double(narrow.columns) * Double(cols)).rounded())
            guard cols >= 8, rows >= 6, cols <= wide.columns, rows <= wide.rows else { return }
            let small = narrow.resampled(columns: cols, rows: rows)
            for oy in 0...(wide.rows - rows) {
                for ox in 0...(wide.columns - cols) {
                    guard let o = overlap(wide: wide, small: small, ox: ox, oy: oy) else { continue }
                    if best == nil || o.ncc > best!.correlation {
                        best = Overlap(stopsBrighter: sign * o.diff, correlation: o.ncc,
                                       sharedCells: o.cells)
                    }
                }
            }
        }
        for scale in overlapScales {
            if scale == 1 {
                // Same focal length: a pan. The frame's centre, placed anywhere.
                consider(wide: reference, narrow: frame.centre(panWindow), scale: 1 / panWindow,
                         sign: 1)
                consider(wide: frame, narrow: reference.centre(panWindow), scale: 1 / panWindow,
                         sign: -1)
            } else {
                consider(wide: reference, narrow: frame, scale: scale, sign: 1)
                consider(wide: frame, narrow: reference, scale: scale, sign: -1)
            }
        }
        guard var answer = best, answer.correlation >= overlapThreshold else { return nil }
        answer.stopsBrighter = (answer.stopsBrighter * 1000).rounded() / 1000
        return answer
    }

    /// Gradient NCC of `small` placed at (ox, oy) in `wide`, and the median of
    /// small − wide over the cells both hold.
    ///
    /// The NCC is the LOWEST of the window's four quadrants that hold texture, not the
    /// whole window's: one strong shared edge — the horizon of two different landscapes —
    /// otherwise carries the whole correlation (a synthetic pair with a common horizon
    /// and unrelated texture scored 0.77). Two views of one scene correlate everywhere.
    private static func overlap(wide: LumaGrid, small: LumaGrid, ox: Int, oy: Int)
        -> (ncc: Double, diff: Double, cells: Int)? {
        var diffs: [Double] = []
        diffs.reserveCapacity(small.columns * small.rows)
        // Per quadrant: n, Σa, Σb, Σab, Σaa, Σbb.
        var q = [[Double]](repeating: [0, 0, 0, 0, 0, 0], count: 4)
        func add(_ quadrant: Int, _ a: Double, _ b: Double) {
            q[quadrant][0] += 1; q[quadrant][1] += a; q[quadrant][2] += b
            q[quadrant][3] += a * b; q[quadrant][4] += a * a; q[quadrant][5] += b * b
        }
        let halfX = small.columns / 2, halfY = small.rows / 2
        for y in 0..<small.rows {
            for x in 0..<small.columns {
                guard let s = small[x, y], let w = wide[ox + x, oy + y] else { continue }
                diffs.append(s - w)
                let quadrant = (x < halfX ? 0 : 1) + (y < halfY ? 0 : 2)
                if x + 1 < small.columns, let s2 = small[x + 1, y],
                   let w2 = wide[ox + x + 1, oy + y] {
                    add(quadrant, s2 - s, w2 - w)
                }
                if y + 1 < small.rows, let s2 = small[x, y + 1],
                   let w2 = wide[ox + x, oy + y + 1] {
                    add(quadrant, s2 - s, w2 - w)
                }
            }
        }
        // Half the window must be usable, or a few cells could correlate by accident.
        guard diffs.count * 2 >= small.columns * small.rows, diffs.count >= 24 else { return nil }
        var worst = Double.infinity
        var textured = 0
        for v in q where v[0] >= 12 {
            let n = v[0]
            let saa = v[4] - v[1] * v[1] / n, sbb = v[5] - v[2] * v[2] / n
            // A quadrant of flat sky has nothing to correlate; it neither passes nor
            // fails the window. 0.02 EV rms between neighbours is texture.
            guard saa / n > 4e-4, sbb / n > 4e-4 else { continue }
            let sab = v[3] - v[1] * v[2] / n
            worst = Swift.min(worst, sab / (saa * sbb).squareRoot())
            textured += 1
        }
        guard textured >= 2 else { return nil }
        diffs.sort()
        let median = diffs.count % 2 == 1 ? diffs[diffs.count / 2]
            : (diffs[diffs.count / 2 - 1] + diffs[diffs.count / 2]) / 2
        return (worst, median, diffs.count)
    }
}

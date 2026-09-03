// Scopes.swift
// The measurement instruments: the Develop histogram (docs/04 §8, D12), the cull-time
// raw-truth statistics (docs/10 §5, D36), and the scopes — waveform, RGB parade,
// vectorscope (docs/14 §5.9, docs/16 Phase 8, D22) — plus the two overlays that read
// off them (alt-drag clipping, focus peaking).
//
// This is the reference implementation, not the shipping path: the shipping path is a
// compute shader binning a ~1 MP proxy of the viewport composite in <1 ms per frame
// (docs/14 §5.9). Everything here is the definition that shader is measured against, so
// it is pure f64 arithmetic over `ImageBuffer` / `Plane` with no platform dependency —
// same numbers on any machine, which is what makes the goldens meaningful.
//
// Three rules the whole file obeys:
//  · Scopes bin a *proxy of the viewport composite, post-S16* — they describe the
//    picture you are looking at, including the crop. `ScopeProxy` builds that proxy.
//  · Cost is linear in pixel count and nothing allocates inside a per-pixel loop:
//    every accumulator is sized once, up front, and mutated in place.
//  · No `Int(x)` conversion is ever reached with a non-finite `x`. Scene-referred data
//    legitimately carries NaN/inf from upstream stages; a measurement instrument that
//    traps on the data it is measuring is not an instrument. Non-finite samples are
//    skipped and excluded from `sampleCount`.
//
// The raw-truth instrument (`RawStatistics`) is the odd one out: it does not bin the
// render at all. It bins decoded scene-linear data against the per-channel saturation
// level, because the embedded JPEG's histogram is post-WB, post-tone-curve and lies
// about 0.3–2 EV of real highlight headroom (docs/10 §10.5).

import Foundation

// MARK: - Readout space

/// Which numbers the instruments report (D12). LR computes Develop readouts in
/// ProPhoto-primaries/sRGB-curve percentages matching no export space anyone can name;
/// Lumen makes the choice explicit and labels it, and the same choice drives the
/// histogram, the cursor readouts, the curve coordinates and the scopes.
///
/// The mapping each case implies, applied to a working-space (linear Rec.2020) triple:
///
/// | case            | primaries          | transfer | axis full scale | reported as |
/// |-----------------|--------------------|----------|-----------------|-------------|
/// | `working`       | working (identity) | linear   | 1.0             | 0–100 %     |
/// | `srgb255`       | → sRGB             | sRGB     | 1.0             | 0–255       |
/// | `outputProfile` | → the export space | its TRC  | 1.0             | 0–255       |
///
/// In every case the *tonal axis* the bins sit on is the encoded value in [0,1];
/// only the number shown to the user changes scale.
public enum ReadoutSpace: String, Codable, Sendable, CaseIterable {
    case working
    case srgb255
    case outputProfile

    /// The label the UI must print next to any number in this space — an unlabeled
    /// readout is the failure mode this enum exists to end.
    public var label: String {
        switch self {
        case .working: return "Working (Rec.2020 linear, %)"
        case .srgb255: return "sRGB 0–255"
        case .outputProfile: return "Output profile 0–255"
        }
    }

    /// Full-scale value of the reported number (100 % or 255).
    public var fullScale: Double {
        switch self {
        case .working: return 100
        case .srgb255: return 255
        case .outputProfile: return 255
        }
    }
}

/// A `ReadoutSpace` resolved against actual colour spaces: the matrix and transfer the
/// instruments run per sample. Built once per histogram/scope, never per pixel.
public struct ReadoutTransform: Sendable {

    public let space: ReadoutSpace
    /// The space the incoming samples are in (the pipeline working space).
    public let working: RGBColorSpace
    /// working linear → readout linear. Identity for `.working`.
    public let primaries: Mat3
    /// Readout linear → the encoded tonal axis.
    public let transfer: TransferFunction
    /// Full scale of the reported number (100 or 255).
    public let fullScale: Double

    public init(space: ReadoutSpace,
                working: RGBColorSpace = .rec2020,
                output: RGBColorSpace = .srgb,
                outputTransfer: TransferFunction = .srgb) {
        self.space = space
        self.working = working
        self.fullScale = space.fullScale
        switch space {
        case .working:
            self.primaries = Mat3.identity
            self.transfer = .linear
        case .srgb255:
            self.primaries = working.matrix(to: .srgb)
            self.transfer = .srgb
        case .outputProfile:
            self.primaries = working.matrix(to: output)
            self.transfer = outputTransfer
        }
    }

    /// Working linear → readout linear. Clipping is judged here, where 0 and 1 mean
    /// "at the floor" and "at the ceiling" of the readout space.
    public func linearize(_ c: RGB) -> RGB { primaries.apply(c) }

    /// Working linear → position on the encoded tonal axis (nominally [0,1], not
    /// clamped: out-of-range values are real information).
    public func axis(_ c: RGB) -> RGB { transfer.encode(primaries.apply(c)) }

    /// Working linear → the numbers the UI prints (0–100 % or 0–255).
    public func readout(_ c: RGB) -> RGB { axis(c) * fullScale }

    /// Luminance of a working-space triple, in the working space's own weights.
    /// The histogram's luma channel and the waveform both ride on this: never
    /// Rec.709 weights on Rec.2020 data.
    public func luminance(_ c: RGB) -> Double { working.luminance(c) }
}

// MARK: - Proxy

/// Scopes bin a ~1 MP proxy of the viewport composite (docs/14 §5.9). darktable bumped
/// its preview pipe to 1440×900 in 5.6 precisely because scope fidelity at low proxy
/// resolution was hurting pickers; ~1 MP is that lesson applied from day 1.
public enum ScopeProxy {

    public static let targetPixels: Int = 1_000_000

    /// Integer box-downsample factor that brings `width × height` to at most `target`
    /// pixels. Always ≥ 1, capped so a pathological extent cannot spin the loop.
    public static func factor(width: Int, height: Int, target: Int = ScopeProxy.targetPixels) -> Int {
        guard width > 0, height > 0, target > 0 else { return 1 }
        if width * height <= target { return 1 }
        var f = 1
        while f < 256 {
            let w = Swift.max(width / f, 1)
            let h = Swift.max(height / f, 1)
            if w * h <= target { break }
            f += 1
        }
        return f
    }

    public static func proxy(_ image: ImageBuffer, target: Int = ScopeProxy.targetPixels) -> ImageBuffer {
        image.downsampled(by: factor(width: image.width, height: image.height, target: target))
    }
}

// MARK: - Histogram

/// The Develop histogram (D12): per-channel bins plus a luminance channel, on the
/// selected readout space's tonal axis, with the clipped fraction at both ends of every
/// channel (that is what makes the corner triangles channel-diagnostic) and the five
/// draggable zones that scrub Blacks / Shadows / Exposure / Highlights / Whites.
public struct Histogram: Sendable {

    public enum Channel: Int, CaseIterable, Sendable {
        case red = 0
        case green = 1
        case blue = 2
        /// Working-space luminance, encoded onto the same axis as the channels.
        case luma = 3
    }

    public enum End: Int, CaseIterable, Sendable {
        case low = 0
        case high = 1
    }

    /// Tolerance for "at the end of the scale", in readout-linear units. A rendered
    /// value one part in 4096 from the ceiling is clipped as far as any 12-bit output
    /// is concerned.
    public static let clipEpsilon: Double = 1.0 / 4096.0

    public static let channelCount: Int = 4
    public static let maxBins: Int = 4096

    public let bins: Int
    /// `channelCount × bins`, channel-major: `counts[channel * bins + bin]`.
    public let counts: [Int]
    /// Finite samples binned (non-finite pixels are excluded).
    public let sampleCount: Int
    public let transform: ReadoutTransform
    /// Per channel, samples at or below the floor of the readout space.
    public let clippedLowCounts: [Int]
    /// Per channel, samples at or above the ceiling of the readout space.
    public let clippedHighCounts: [Int]

    public init(bins: Int,
                counts: [Int],
                sampleCount: Int,
                transform: ReadoutTransform,
                clippedLowCounts: [Int],
                clippedHighCounts: [Int]) {
        let n: Int = Swift.max(1, bins)
        self.bins = n
        self.counts = counts.count == Histogram.channelCount * n
            ? counts
            : [Int](repeating: 0, count: Histogram.channelCount * n)
        self.sampleCount = Swift.max(0, sampleCount)
        self.transform = transform
        self.clippedLowCounts = clippedLowCounts.count == Histogram.channelCount
            ? clippedLowCounts
            : [Int](repeating: 0, count: Histogram.channelCount)
        self.clippedHighCounts = clippedHighCounts.count == Histogram.channelCount
            ? clippedHighCounts
            : [Int](repeating: 0, count: Histogram.channelCount)
    }

    // MARK: Compute

    /// Bin an image — in practice a `ScopeProxy.proxy` of the post-S16 composite.
    ///
    /// One pass, four accumulations per pixel, no allocation after the accumulators are
    /// sized. R/G/B are binned in the readout space's primaries and transfer; luma is
    /// the *working*-space luminance put through the same transfer, so the luma trace
    /// shares the channels' axis without inheriting the readout primaries' weights.
    public static func compute(_ image: ImageBuffer,
                               bins: Int = 256,
                               space: RGBColorSpace = .rec2020,
                               readout: ReadoutSpace = .srgb255) -> Histogram {
        return compute(image, bins: bins,
                       transform: ReadoutTransform(space: readout, working: space))
    }

    /// The form to call when the readout space is `.outputProfile` and the caller knows
    /// the actual export profile.
    public static func compute(_ image: ImageBuffer,
                               bins: Int,
                               transform: ReadoutTransform) -> Histogram {
        let n: Int = Swift.min(Swift.max(1, bins), Histogram.maxBins)
        var counts = [Int](repeating: 0, count: Histogram.channelCount * n)
        var low = [Int](repeating: 0, count: Histogram.channelCount)
        var high = [Int](repeating: 0, count: Histogram.channelCount)

        let m: Mat3 = transform.primaries
        let tf: TransferFunction = transform.transfer
        let w: RGB = transform.working.luminanceWeights
        let pixels: [Float] = image.pixels
        let total: Int = Swift.min(image.width * image.height, pixels.count / 4)
        var used: Int = 0

        var p: Int = 0
        while p < total {
            let i: Int = p * 4
            let r0 = Double(pixels[i])
            let g0 = Double(pixels[i + 1])
            let b0 = Double(pixels[i + 2])
            if r0.isFinite && g0.isFinite && b0.isFinite {
                let rr = m.m[0][0] * r0 + m.m[0][1] * g0 + m.m[0][2] * b0
                let gg = m.m[1][0] * r0 + m.m[1][1] * g0 + m.m[1][2] * b0
                let bb = m.m[2][0] * r0 + m.m[2][1] * g0 + m.m[2][2] * b0
                let yy = w.r * r0 + w.g * g0 + w.b * b0
                Histogram.accumulate(rr, channel: 0, bins: n, transfer: tf,
                                     counts: &counts, low: &low, high: &high)
                Histogram.accumulate(gg, channel: 1, bins: n, transfer: tf,
                                     counts: &counts, low: &low, high: &high)
                Histogram.accumulate(bb, channel: 2, bins: n, transfer: tf,
                                     counts: &counts, low: &low, high: &high)
                Histogram.accumulate(yy, channel: 3, bins: n, transfer: tf,
                                     counts: &counts, low: &low, high: &high)
                used += 1
            }
            p += 1
        }

        return Histogram(bins: n, counts: counts, sampleCount: used,
                         transform: transform,
                         clippedLowCounts: low, clippedHighCounts: high)
    }

    /// One channel of one sample. `inout` arrays, no allocation, provably in bounds.
    private static func accumulate(_ value: Double,
                                   channel: Int,
                                   bins: Int,
                                   transfer: TransferFunction,
                                   counts: inout [Int],
                                   low: inout [Int],
                                   high: inout [Int]) {
        guard value.isFinite else { return }
        if value <= Histogram.clipEpsilon { low[channel] += 1 }
        if value >= 1 - Histogram.clipEpsilon { high[channel] += 1 }
        let e: Double = transfer.encode(value)
        guard e.isFinite else { return }
        let t: Double = e < 0 ? 0 : (e > 1 ? 1 : e)
        var idx: Int = Int(t * Double(bins))
        if idx >= bins { idx = bins - 1 }
        if idx < 0 { idx = 0 }
        counts[channel * bins + idx] += 1
    }

    // MARK: Readout

    public func count(_ channel: Channel, bin: Int) -> Int {
        guard bin >= 0 && bin < bins else { return 0 }
        return counts[channel.rawValue * bins + bin]
    }

    public func channelCounts(_ channel: Channel) -> [Int] {
        let base: Int = channel.rawValue * bins
        var out = [Int](repeating: 0, count: bins)
        for i in 0..<bins { out[i] = counts[base + i] }
        return out
    }

    public func peak(_ channel: Channel) -> Int {
        let base: Int = channel.rawValue * bins
        var m: Int = 0
        for i in 0..<bins { m = Swift.max(m, counts[base + i]) }
        return m
    }

    /// Bin heights scaled to [0,1] for drawing — against a spike-resistant reference,
    /// not the raw peak. Peak normalization let one bin erase the whole graph: at
    /// +5 EV a third of the frame lands in the white bin and every other bin scaled
    /// against it into sub-pixel heights, an empty panel captioned "29.86% white"
    /// (owner session 2; docs/23 queue item 14). The reference is the
    /// 99th-percentile NONZERO bin height — of the occupied bins, so a sparse
    /// histogram keeps its exact proportions (the percentile of four bins is their
    /// tallest) — and anything above it saturates at 1.0, the way Lightroom draws
    /// its end spikes. `peak(_:)` still reports the true count.
    public func normalized(_ channel: Channel) -> [Double] {
        let base: Int = channel.rawValue * bins
        var occupied: [Int] = []
        occupied.reserveCapacity(bins)
        for i in 0..<bins where counts[base + i] > 0 { occupied.append(counts[base + i]) }
        var out = [Double](repeating: 0, count: bins)
        guard !occupied.isEmpty else { return out }
        occupied.sort()
        // Ceiling, not truncation: for up to a hundred occupied bins the index IS
        // the maximum, so only histograms wide enough for a percentile to mean
        // anything get clamped at all — a four-bin histogram must not scale to its
        // third-tallest bin.
        let reference: Int = occupied[Int((Double(occupied.count - 1) * 0.99).rounded(.up))]
        guard reference > 0 else { return out }
        let inv: Double = 1.0 / Double(reference)
        for i in 0..<bins { out[i] = Swift.min(Double(counts[base + i]) * inv, 1.0) }
        return out
    }

    /// Fraction of samples clipped at one end of one channel, in [0,1]. The corner
    /// triangles are channel-diagnostic off exactly this: dark = none, a channel colour
    /// = those channels clipping, white = all three.
    public func clippedFraction(_ channel: Channel, end: End) -> Double {
        guard sampleCount > 0 else { return 0 }
        let c: Int = end == .low
            ? clippedLowCounts[channel.rawValue]
            : clippedHighCounts[channel.rawValue]
        return Double(c) / Double(sampleCount)
    }

    /// Percentage form, for the `R 2.1% clipped` line.
    public func clippedPercent(_ channel: Channel, end: End) -> Double {
        clippedFraction(channel, end: end) * 100
    }

    /// Which of R/G/B are clipping at `end` beyond `threshold` — the triangle's colour
    /// is `ClippingOverlay.colour(mask:)` of this.
    public func clippingMask(end: End, threshold: Double = 0) -> Int {
        var mask: Int = 0
        if clippedFraction(.red, end: end) > threshold { mask |= 1 }
        if clippedFraction(.green, end: end) > threshold { mask |= 2 }
        if clippedFraction(.blue, end: end) > threshold { mask |= 4 }
        return mask
    }

    /// Centre of bin `index` on the normalized tonal axis, [0,1].
    public func binAxis(_ index: Int) -> Double {
        guard bins > 0 else { return 0 }
        let i: Int = Swift.min(Swift.max(index, 0), bins - 1)
        return (Double(i) + 0.5) / Double(bins)
    }

    /// Centre of bin `index` in readout units (0–100 % or 0–255).
    public func binReadout(_ index: Int) -> Double { binAxis(index) * transform.fullScale }

    /// Bin an axis position falls in.
    public func bin(atAxis x: Double) -> Int {
        guard x.isFinite else { return 0 }
        let t: Double = Num.saturate(x)
        var i: Int = Int(t * Double(bins))
        if i >= bins { i = bins - 1 }
        if i < 0 { i = 0 }
        return i
    }

    // MARK: Zones (D12 zone drag)

    /// The five draggable zones map to the six-slider tone panel, so the middle zone is
    /// **Exposure**, not "Mids" — the histogram drives that panel, not the Zones panel
    /// (docs/04 §8.1).
    public enum ZoneSlider: String, Codable, Sendable, CaseIterable {
        case blacks
        case shadows
        case exposure
        case highlights
        case whites

        public var displayName: String {
            switch self {
            case .blacks: return "Blacks"
            case .shadows: return "Shadows"
            case .exposure: return "Exposure"
            case .highlights: return "Highlights"
            case .whites: return "Whites"
            }
        }
    }

    /// A zone's window on the normalized tonal axis. `lower`/`upper` are the hover and
    /// drag hit region; `pivot` is the handle the Zones panel draws (docs/04 §5).
    public struct Zone: Equatable, Sendable {
        public let slider: ZoneSlider
        public let pivot: Double
        public let lower: Double
        public let upper: Double

        public init(slider: ZoneSlider, pivot: Double, lower: Double, upper: Double) {
            self.slider = slider
            self.pivot = pivot
            self.lower = lower
            self.upper = upper
        }

        public func contains(_ x: Double) -> Bool {
            guard x.isFinite else { return false }
            return x >= lower && x <= upper
        }

        public var width: Double { upper - lower }
    }

    /// Wire-format default from `Recipe.Zones.pivots` (docs/04 §5.6).
    public static let defaultZonePivots: [Double] = [0.08, 0.25, 0.5, 0.75, 0.92]

    /// The five zone windows over the tonal axis: boundaries fall at the midpoints
    /// between adjacent pivots, the outer zones run to the ends of the axis, and the
    /// windows tile [0,1] exactly with no gap and no overlap — a drag anywhere on the
    /// graph therefore lands in exactly one slider.
    ///
    /// `pivots` is sanitized: a wrong-length or non-finite list falls back to the
    /// defaults, and values are clamped and forced strictly ascending inside [0,1].
    public static func zoneBoundaries(pivots: [Double] = Histogram.defaultZonePivots) -> [Zone] {
        let sliders: [ZoneSlider] = ZoneSlider.allCases
        let n: Int = sliders.count
        var p = [Double](repeating: 0, count: n)
        let usable: Bool = pivots.count == n
        for i in 0..<n {
            let raw: Double = usable ? pivots[i] : Histogram.defaultZonePivots[i]
            p[i] = raw.isFinite ? Num.saturate(raw) : Histogram.defaultZonePivots[i]
        }
        let minGap: Double = 1.0 / 1024.0
        for i in 1..<n {
            if p[i] <= p[i - 1] { p[i] = Swift.min(1, p[i - 1] + minGap) }
        }
        var zones = [Zone]()
        zones.reserveCapacity(n)
        for i in 0..<n {
            let lower: Double = i == 0 ? 0 : (p[i - 1] + p[i]) / 2
            let upper: Double = i == n - 1 ? 1 : (p[i] + p[i + 1]) / 2
            zones.append(Zone(slider: sliders[i], pivot: p[i], lower: lower, upper: upper))
        }
        return zones
    }

    /// Instance form — same windows, on this histogram's axis.
    public func zoneBoundaries(pivots: [Double] = Histogram.defaultZonePivots) -> [Zone] {
        return Histogram.zoneBoundaries(pivots: pivots)
    }

    /// The zone an axis position lands in — the hit test behind hover-highlight and
    /// drag-to-scrub. Never nil: the windows tile the axis.
    public func zone(atAxis x: Double, pivots: [Double] = Histogram.defaultZonePivots) -> Zone {
        let zones: [Zone] = Histogram.zoneBoundaries(pivots: pivots)
        let t: Double = x.isFinite ? Num.saturate(x) : 0
        var i: Int = 0
        while i < zones.count - 1 && t > zones[i].upper { i += 1 }
        return zones[i]
    }

    /// Share of samples inside a zone's window, per channel — the live value the hover
    /// label reports next to the slider name.
    public func fraction(in zone: Zone, channel: Channel = .luma) -> Double {
        guard sampleCount > 0 else { return 0 }
        let base: Int = channel.rawValue * bins
        var total: Int = 0
        for i in 0..<bins {
            let x: Double = (Double(i) + 0.5) / Double(bins)
            if x >= zone.lower && x <= zone.upper { total += counts[base + i] }
        }
        return Double(total) / Double(sampleCount)
    }
}

// MARK: - Raw statistics (cull-time truth)

/// The raw-truth instrument (D36, docs/10 §10.5): 128 EV-spaced bins × 4 channels
/// binned from decoded scene-linear data against the per-channel saturation level, with
/// per-channel clipped-percent at both ends. This is what the cull HUD's `Shift+H` panel
/// and the `O` clipping overlay read, and it is cached in `cache.db.raw_stats` forever
/// (raw data never changes) at ~2 KB per photo, inside the ~4 KB budget.
///
/// Latency target: 150–400 ms per 45 MP file on one performance core at background QoS;
/// on-demand requests jump the queue and land ≤400 ms. That budget is why the default
/// `subsample` is 4 — every 4th site in each axis, i.e. 1/16 of the sensor.
///
/// Channel slot 3 is luminance when the source is decoded RGB. When the worker feeds
/// undemosaiced CFA values instead, the same slot carries the **second green (G2)** —
/// docs/10 §10.5 keeps the two greens separate, and the byte layout is identical either
/// way; `sourceIsCFA` records which reading applies.
///
/// **Every instance says where its numbers came from.** `Provenance` is not decoration:
/// the value of this instrument is entirely the claim that it measures something truer
/// than the rendered picture, and a set of bins that cannot say what it binned is a
/// claim with no evidence behind it. So `compute` requires it, it rides in the persisted
/// blob, and the panel prints its label. The one provenance docs/10 §10.5 actually
/// specifies — undemosaiced CFA — is declared here and produced by nothing, because
/// Lumen has no CFA reader; `RawTruth` states that gap in the words the reader sees.
public struct RawStatistics: Sendable {

    /// What the numbers were measured on, and therefore what "clipped" means in them.
    ///
    /// The whole point of a raw-truth instrument is that the embedded JPEG's histogram
    /// is post-WB, post-tone-curve and lies by 0.3–2 EV. An instrument that inherited
    /// that same vagueness about its own input would be the identical defect one layer
    /// up.
    public enum Provenance: UInt32, Sendable, CaseIterable {
        /// Written by a build that did not record provenance, or decoded from a blob
        /// that predates this field. The numbers are of unknown origin and the panel
        /// says so rather than implying sensor truth.
        case unspecified = 0
        /// Undemosaiced CFA site values, black-subtracted, binned against the
        /// per-channel saturation level from the file's metadata. This is what
        /// docs/10 §10.5 specifies and **nothing in this repository produces it** —
        /// there is no CFA or LibRaw reader in the pipeline. It is declared so the
        /// stored format is ready for one, and so the honest label already exists.
        case sensorCFA = 1
        /// Decoded scene-linear RGB: `CIRAWFilter` at Lumen's flat settings — Apple's
        /// tone curve, shadow boost, local tone mapping, gamut mapping and contrast all
        /// off, extended range kept — read before every Lumen stage and before the
        /// display transform. Post-demosaic, so it is not the sensor's mosaic; it is
        /// scene-referred and unclipped by the display transform, which is what makes
        /// it answer "is this highlight recoverable".
        case sceneLinearDecode = 2
        /// The rendered, display-encoded proxy: the histogram docs/10 §10.5 exists to
        /// beat. Declared so that a caller which measures the render has to say so.
        case renderedProxy = 3

        /// What the panel prints above the numbers. Never the bare word "raw".
        public var label: String {
            switch self {
            case .unspecified: return "Unrecorded source"
            case .sensorCFA: return "Sensor raw (CFA, pre-demosaic)"
            case .sceneLinearDecode: return "Scene-linear (post-demosaic)"
            case .renderedProxy: return "Rendered proxy"
            }
        }

        /// What 1.0 on the normalized axis means for this provenance — which is what
        /// the reported clipped percentage is a percentage *of*.
        public var ceilingMeaning: String {
            switch self {
            case .unspecified:
                return "an unrecorded reference level"
            case .sensorCFA:
                return "the per-channel saturation level from the file's metadata"
            case .sceneLinearDecode:
                return "scene-linear 1.0, the white level the RAW decode normalizes to"
            case .renderedProxy:
                return "the top of the display-encoded range"
            }
        }

        /// True only for the reading docs/10 §10.5 calls raw truth. Everything else is
        /// closer to the truth than the embedded JPEG and is still not the sensor.
        public var isSensorTruth: Bool { self == .sensorCFA }
    }

    public enum Channel: Int, CaseIterable, Sendable {
        case r = 0
        case g = 1
        case b = 2
        /// Luma for decoded RGB input; the second green (G2) for CFA input.
        case luma = 3
    }

    public enum End: Int, CaseIterable, Sendable {
        case low = 0
        case high = 1
    }

    public static let binCount: Int = 128
    public static let channelCount: Int = 4
    /// Bottom of the EV axis, relative to the saturation level. 14 stops covers every
    /// sensor's usable range with room for the black-level floor.
    public static let evFloor: Double = -14
    /// Top of the EV axis: saturation itself.
    public static let evCeiling: Double = 0
    /// "Within 0.25 EV of the limit" — docs/10 §10.5's near-clipping pair.
    public static let nearClipEV: Double = 0.25
    /// Bumped whenever the binning changes, so `raw_stats.analyzer_rev` invalidates.
    public static let currentAnalyzerRevision: UInt16 = 1

    /// `channelCount × binCount`, channel-major: `bins[channel * 128 + bin]`.
    public let bins: [UInt32]
    /// Per channel, % of samples at or beyond saturation.
    public let clippedHighPercent: [Double]
    /// Per channel, % of samples within 0.25 EV of saturation.
    public let nearClippedHighPercent: [Double]
    /// Per channel, % of samples at or below the black-level floor.
    public let clippedLowPercent: [Double]
    /// Per channel, % of samples within 0.25 EV of the EV floor.
    public let nearClippedLowPercent: [Double]
    public let sampleCount: Int
    /// Site stride in each axis: 4 → 1/16 of sites (docs/10 §10.5).
    public let subsample: Int
    public let blackLevel: Double
    /// Per-channel saturation level from metadata, in the same units as the input.
    public let saturation: [Double]
    public let analyzerRevision: UInt16
    /// Where these numbers came from. Stored rather than derived, because the whole
    /// instrument is a claim about its own input.
    public let provenance: Provenance
    /// True when slot 3 is G2 rather than luma — which is exactly the CFA reading, so
    /// this is now a view of `provenance` rather than a second, independently settable
    /// fact that could disagree with it.
    public var sourceIsCFA: Bool { provenance == .sensorCFA }

    /// `provenance` defaults to nil rather than to a case, so that the legacy
    /// `sourceIsCFA` spelling keeps its exact meaning — CFA or *unrecorded*, never a
    /// silent upgrade to a claim the caller did not make.
    public init(bins: [UInt32],
                clippedHighPercent: [Double],
                nearClippedHighPercent: [Double],
                clippedLowPercent: [Double],
                nearClippedLowPercent: [Double],
                sampleCount: Int,
                subsample: Int,
                blackLevel: Double,
                saturation: [Double],
                analyzerRevision: UInt16,
                sourceIsCFA: Bool,
                provenance: Provenance? = nil) {
        let n: Int = RawStatistics.channelCount * RawStatistics.binCount
        self.bins = bins.count == n ? bins : [UInt32](repeating: 0, count: n)
        self.clippedHighPercent = RawStatistics.four(clippedHighPercent)
        self.nearClippedHighPercent = RawStatistics.four(nearClippedHighPercent)
        self.clippedLowPercent = RawStatistics.four(clippedLowPercent)
        self.nearClippedLowPercent = RawStatistics.four(nearClippedLowPercent)
        self.sampleCount = Swift.max(0, sampleCount)
        self.subsample = Swift.max(1, subsample)
        self.blackLevel = blackLevel.isFinite ? blackLevel : 0
        self.saturation = RawStatistics.four(saturation, fill: 1)
        self.analyzerRevision = analyzerRevision
        self.provenance = provenance ?? (sourceIsCFA ? .sensorCFA : .unspecified)
    }

    private static func four(_ v: [Double], fill: Double = 0) -> [Double] {
        if v.count == RawStatistics.channelCount {
            var out = v
            for i in 0..<out.count where !out[i].isFinite { out[i] = fill }
            return out
        }
        return [Double](repeating: fill, count: RawStatistics.channelCount)
    }

    // MARK: Compute

    /// Bin decoded scene-linear data.
    ///
    /// - `blackLevel`: subtracted before normalization (metadata's black level).
    /// - `saturation`: per-channel saturation level from metadata; the luma slot's
    ///   level is derived as the luminance of that triple.
    /// - `subsample`: site stride per axis; 4 → 1/16 of sites.
    /// - `provenance`: what `image` actually is. **No default.** A caller that cannot
    ///   name its input cannot claim to be measuring truth, and the panel prints this
    ///   word beside the numbers.
    /// - `recordedSiteStride`: what to store in `subsample` when `image` is itself a
    ///   downscale of the frame. `subsample`'s own contract is a stride *in sensor
    ///   sites*, so a caller that hands over a 2048 px proxy of an 8192 px file and
    ///   walks every pixel of it has a buffer stride of 1 and a site stride of 4;
    ///   storing the 1 would describe the measurement as sixteen times finer than it
    ///   is. Nil means the two are the same.
    ///
    /// Normalized value `v = (sample − black) / (sat − black)`, so 1.0 *is* saturation
    /// and the EV axis is `log2(v)` over `[evFloor, evCeiling]`. One pass, linear in
    /// sampled pixels, no allocation inside the loop.
    public static func compute(_ image: ImageBuffer,
                               provenance: Provenance,
                               space: RGBColorSpace = .rec2020,
                               blackLevel: Double = 0,
                               saturation: RGB = RGB.one,
                               subsample: Int = 4,
                               recordedSiteStride: Int? = nil,
                               analyzerRevision: UInt16 = RawStatistics.currentAnalyzerRevision)
    -> RawStatistics {
        let nb: Int = RawStatistics.binCount
        var bins = [UInt32](repeating: 0, count: RawStatistics.channelCount * nb)
        var clipHigh = [Int](repeating: 0, count: RawStatistics.channelCount)
        var nearHigh = [Int](repeating: 0, count: RawStatistics.channelCount)
        var clipLow = [Int](repeating: 0, count: RawStatistics.channelCount)
        var nearLow = [Int](repeating: 0, count: RawStatistics.channelCount)

        let black: Double = blackLevel.isFinite ? blackLevel : 0
        let w: RGB = space.luminanceWeights
        let satY: Double = w.r * saturation.r + w.g * saturation.g + w.b * saturation.b
        let levels: [Double] = [saturation.r, saturation.g, saturation.b, satY]
        var scale = [Double](repeating: 1, count: RawStatistics.channelCount)
        for i in 0..<RawStatistics.channelCount {
            let span: Double = levels[i] - black
            scale[i] = (span.isFinite && span > 0) ? 1.0 / span : 1.0
        }

        let step: Int = Swift.max(1, subsample)
        let pixels: [Float] = image.pixels
        let width: Int = image.width
        let height: Int = image.height
        let capacity: Int = pixels.count / 4
        var used: Int = 0

        var y: Int = 0
        while y < height {
            var x: Int = 0
            while x < width {
                let p: Int = y * width + x
                if p < capacity {
                    let i: Int = p * 4
                    let r0 = Double(pixels[i])
                    let g0 = Double(pixels[i + 1])
                    let b0 = Double(pixels[i + 2])
                    if r0.isFinite && g0.isFinite && b0.isFinite {
                        let yy: Double = w.r * r0 + w.g * g0 + w.b * b0
                        RawStatistics.accumulate((r0 - black) * scale[0], channel: 0,
                                                 bins: &bins, clipHigh: &clipHigh,
                                                 nearHigh: &nearHigh, clipLow: &clipLow,
                                                 nearLow: &nearLow)
                        RawStatistics.accumulate((g0 - black) * scale[1], channel: 1,
                                                 bins: &bins, clipHigh: &clipHigh,
                                                 nearHigh: &nearHigh, clipLow: &clipLow,
                                                 nearLow: &nearLow)
                        RawStatistics.accumulate((b0 - black) * scale[2], channel: 2,
                                                 bins: &bins, clipHigh: &clipHigh,
                                                 nearHigh: &nearHigh, clipLow: &clipLow,
                                                 nearLow: &nearLow)
                        RawStatistics.accumulate((yy - black) * scale[3], channel: 3,
                                                 bins: &bins, clipHigh: &clipHigh,
                                                 nearHigh: &nearHigh, clipLow: &clipLow,
                                                 nearLow: &nearLow)
                        used += 1
                    }
                }
                x += step
            }
            y += step
        }

        let denom: Double = used > 0 ? Double(used) : 1
        var hi = [Double](repeating: 0, count: RawStatistics.channelCount)
        var nh = [Double](repeating: 0, count: RawStatistics.channelCount)
        var lo = [Double](repeating: 0, count: RawStatistics.channelCount)
        var nl = [Double](repeating: 0, count: RawStatistics.channelCount)
        for c in 0..<RawStatistics.channelCount {
            hi[c] = used > 0 ? Double(clipHigh[c]) * 100 / denom : 0
            nh[c] = used > 0 ? Double(nearHigh[c]) * 100 / denom : 0
            lo[c] = used > 0 ? Double(clipLow[c]) * 100 / denom : 0
            nl[c] = used > 0 ? Double(nearLow[c]) * 100 / denom : 0
        }

        return RawStatistics(bins: bins,
                             clippedHighPercent: hi,
                             nearClippedHighPercent: nh,
                             clippedLowPercent: lo,
                             nearClippedLowPercent: nl,
                             sampleCount: used,
                             subsample: Swift.max(1, recordedSiteStride ?? step),
                             blackLevel: black,
                             saturation: [saturation.r, saturation.g, saturation.b, satY],
                             analyzerRevision: analyzerRevision,
                             sourceIsCFA: provenance == .sensorCFA,
                             provenance: provenance)
    }

    private static func accumulate(_ value: Double,
                                   channel: Int,
                                   bins: inout [UInt32],
                                   clipHigh: inout [Int],
                                   nearHigh: inout [Int],
                                   clipLow: inout [Int],
                                   nearLow: inout [Int]) {
        guard value.isFinite else { return }
        if value >= 1 { clipHigh[channel] += 1 }
        if value >= RawStatistics.nearHighLevel { nearHigh[channel] += 1 }
        if value <= 0 { clipLow[channel] += 1 }
        if value <= RawStatistics.nearLowLevel { nearLow[channel] += 1 }

        let ev: Double = Num.safeLog2(value, floorEV: RawStatistics.evFloor)
        let span: Double = RawStatistics.evCeiling - RawStatistics.evFloor
        let t: Double = span > 0 ? (ev - RawStatistics.evFloor) / span : 0
        guard t.isFinite else { return }
        let u: Double = t < 0 ? 0 : (t > 1 ? 1 : t)
        var idx: Int = Int(u * Double(RawStatistics.binCount))
        if idx >= RawStatistics.binCount { idx = RawStatistics.binCount - 1 }
        if idx < 0 { idx = 0 }
        let at: Int = channel * RawStatistics.binCount + idx
        if bins[at] < UInt32.max { bins[at] += 1 }
    }

    /// Normalized value 0.25 EV below saturation.
    public static let nearHighLevel: Double = pow(2.0, -RawStatistics.nearClipEV)
    /// Normalized value 0.25 EV above the EV floor — the low end's "nearly at the
    /// black-level floor" band. The floor has no ratio of its own (it is zero after
    /// black subtraction), so the axis floor is the reference, which is the only
    /// definition that stays meaningful across sensors.
    public static let nearLowLevel: Double = pow(2.0, RawStatistics.evFloor + RawStatistics.nearClipEV)

    // MARK: Readout

    public func count(_ channel: Channel, bin: Int) -> UInt32 {
        guard bin >= 0 && bin < RawStatistics.binCount else { return 0 }
        return bins[channel.rawValue * RawStatistics.binCount + bin]
    }

    /// EV of the centre of a bin, relative to saturation (negative below it).
    public func binEV(_ index: Int) -> Double {
        let i: Int = Swift.min(Swift.max(index, 0), RawStatistics.binCount - 1)
        let span: Double = RawStatistics.evCeiling - RawStatistics.evFloor
        return RawStatistics.evFloor + (Double(i) + 0.5) * span / Double(RawStatistics.binCount)
    }

    public func clippedPercent(_ channel: Channel, end: End) -> Double {
        end == .high ? clippedHighPercent[channel.rawValue] : clippedLowPercent[channel.rawValue]
    }

    public func nearClippedPercent(_ channel: Channel, end: End) -> Double {
        end == .high ? nearClippedHighPercent[channel.rawValue] : nearClippedLowPercent[channel.rawValue]
    }

    /// Junk-detection inputs (docs/10 §10.5): a frame that is almost entirely at the
    /// floor is a black frame; one almost entirely at saturation is a blown frame.
    public var isLikelyBlackFrame: Bool {
        clippedLowPercent[3] >= 99 || nearClippedLowPercent[3] >= 99.5
    }

    public var isLikelyBlownFrame: Bool { clippedHighPercent[3] >= 90 }

    /// The `R 2.1% clipped, G 0.0, B 0.0` line (docs/10 §10.5).
    public var clippingSummary: String {
        let names: [String] = ["R", "G", "B", sourceIsCFA ? "G2" : "Y"]
        var parts = [String]()
        parts.reserveCapacity(names.count)
        for i in 0..<names.count {
            parts.append(names[i] + " " + RawStatistics.format(clippedHighPercent[i]) + "%")
        }
        return parts.joined(separator: ", ") + " clipped"
    }

    /// The `raw_stats.clipped_pct` TEXT column: per-channel percentages as JSON, keys in
    /// fixed order so the row is byte-stable for a given input.
    public var clippedPercentJSON: String {
        let names: [String] = ["r", "g", "b", sourceIsCFA ? "g2" : "luma"]
        var parts = [String]()
        parts.reserveCapacity(names.count)
        for i in 0..<names.count {
            let body: String = "{\"high\":" + RawStatistics.format(clippedHighPercent[i])
                + ",\"nearHigh\":" + RawStatistics.format(nearClippedHighPercent[i])
                + ",\"low\":" + RawStatistics.format(clippedLowPercent[i])
                + ",\"nearLow\":" + RawStatistics.format(nearClippedLowPercent[i]) + "}"
            parts.append("\"" + names[i] + "\":" + body)
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func format(_ v: Double) -> String {
        guard v.isFinite else { return "0.0000" }
        return String(format: "%.4f", v)
    }

    // MARK: Binary form (`raw_stats.bins`)

    /// Byte layout, version 1. Little-endian throughout; the spec left this open
    /// (docs/15 gap G27), so it is pinned here and `analyzer_rev` guards changes.
    ///
    /// ```
    /// offset  size  field
    ///      0     4  magic 'L','R','S','1'
    ///      4     2  UInt16  layoutVersion = 1
    ///      6     2  UInt16  analyzerRevision
    ///      8     2  UInt16  binCount = 128
    ///     10     1  UInt8   channelCount = 4
    ///     11     1  UInt8   subsample (site stride per axis)
    ///     12     4  UInt32  sampleCount
    ///     16     4  Float32 blackLevel
    ///     20     4  Float32 saturation[0]  (R)
    ///     24     4  Float32 saturation[1]  (G)
    ///     28     4  Float32 saturation[2]  (B)
    ///     32     4  Float32 saturation[3]  (luma, or G2 when sourceIsCFA)
    ///     36     4  UInt32  flags — bit 0 = sourceIsCFA (kept, and kept in agreement
    ///                       with the provenance field so a v1 reader that only knows
    ///                       the bit still reads it correctly);
    ///                       bits 1…3 = `Provenance.rawValue`; bits 4…31 reserved (0)
    ///     40  2048  UInt32  bins, channel-major: bins[channel * 128 + bin]
    ///   2088    64  Float32 clipped percentages, 16 values in this order:
    ///                       high[0…3], nearHigh[0…3], low[0…3], nearLow[0…3]
    ///   2152        end
    /// ```
    ///
    /// 2152 bytes per photo — G27's "~4 KB/photo" budget with room to spare, and ~430 MB
    /// at the 200k-photo catalog target.
    public static let magic: [UInt8] = [0x4C, 0x52, 0x53, 0x31]   // "LRS1"
    public static let layoutVersion: UInt16 = 1
    public static let headerBytes: Int = 40
    public static let encodedBytes: Int = 40 + 4 * 4 * 128 + 64   // = 2152

    public func encoded() -> Data {
        var b = [UInt8]()
        b.reserveCapacity(RawStatistics.encodedBytes)
        b.append(contentsOf: RawStatistics.magic)
        RawStatistics.append(uint16: RawStatistics.layoutVersion, to: &b)
        RawStatistics.append(uint16: analyzerRevision, to: &b)
        RawStatistics.append(uint16: UInt16(RawStatistics.binCount), to: &b)
        b.append(UInt8(RawStatistics.channelCount))
        b.append(UInt8(truncatingIfNeeded: Swift.min(subsample, 255)))
        RawStatistics.append(uint32: UInt32(truncatingIfNeeded: sampleCount), to: &b)
        RawStatistics.append(float: blackLevel, to: &b)
        for i in 0..<RawStatistics.channelCount {
            RawStatistics.append(float: saturation[i], to: &b)
        }
        // Bit 0 and bits 1…3 are two spellings of one fact, written together so they
        // cannot drift: a reader that knows only the old bit still learns whether this
        // is CFA data, and a reader that knows the field learns which of the four.
        let flags: UInt32 = (sourceIsCFA ? 1 : 0)
            | ((provenance.rawValue & 0x7) << 1)
        RawStatistics.append(uint32: flags, to: &b)
        for i in 0..<bins.count { RawStatistics.append(uint32: bins[i], to: &b) }
        for i in 0..<RawStatistics.channelCount {
            RawStatistics.append(float: clippedHighPercent[i], to: &b)
        }
        for i in 0..<RawStatistics.channelCount {
            RawStatistics.append(float: nearClippedHighPercent[i], to: &b)
        }
        for i in 0..<RawStatistics.channelCount {
            RawStatistics.append(float: clippedLowPercent[i], to: &b)
        }
        for i in 0..<RawStatistics.channelCount {
            RawStatistics.append(float: nearClippedLowPercent[i], to: &b)
        }
        return Data(b)
    }

    /// Returns nil for anything that is not a version-1 blob of the expected shape —
    /// `cache.db` is disposable and self-healing (D52), so a bad row is simply recomputed.
    public static func decode(_ data: Data) -> RawStatistics? {
        let b = [UInt8](data)
        guard b.count >= RawStatistics.encodedBytes else { return nil }
        guard b[0] == magic[0], b[1] == magic[1], b[2] == magic[2], b[3] == magic[3] else { return nil }
        guard readUInt16(b, 4) == layoutVersion else { return nil }
        let rev: UInt16 = readUInt16(b, 6)
        guard Int(readUInt16(b, 8)) == binCount else { return nil }
        guard Int(b[10]) == channelCount else { return nil }
        let sub: Int = Int(b[11])
        let samples: Int = Int(readUInt32(b, 12))
        let black: Double = Double(Float(bitPattern: readUInt32(b, 16)))
        var sat = [Double](repeating: 1, count: channelCount)
        for i in 0..<channelCount {
            sat[i] = Double(Float(bitPattern: readUInt32(b, 20 + i * 4)))
        }
        let flags: UInt32 = readUInt32(b, 36)

        var bins = [UInt32](repeating: 0, count: channelCount * binCount)
        for i in 0..<bins.count {
            bins[i] = readUInt32(b, headerBytes + i * 4)
        }
        var pct = [[Double]](repeating: [Double](repeating: 0, count: channelCount), count: 4)
        let pctBase: Int = headerBytes + channelCount * binCount * 4
        for g in 0..<4 {
            for c in 0..<channelCount {
                pct[g][c] = Double(Float(bitPattern: readUInt32(b, pctBase + (g * channelCount + c) * 4)))
            }
        }

        return RawStatistics(bins: bins,
                             clippedHighPercent: pct[0],
                             nearClippedHighPercent: pct[1],
                             clippedLowPercent: pct[2],
                             nearClippedLowPercent: pct[3],
                             sampleCount: samples,
                             subsample: Swift.max(1, sub),
                             blackLevel: black,
                             saturation: sat,
                             analyzerRevision: rev,
                             sourceIsCFA: (flags & 1) != 0,
                             provenance: RawStatistics.provenance(fromFlags: flags))
    }

    /// The provenance a flags word carries.
    ///
    /// Three ways a blob can be wrong here, and each is answered rather than trusted:
    /// bits 1…3 zero means the writer predates the field, so the CFA bit is the only
    /// evidence there is; a value outside the enum means a newer writer, and an
    /// unreadable claim is reported as unrecorded rather than guessed at; and a value
    /// that disagrees with bit 0 means one of the two was written by hand, so the
    /// narrower claim — unrecorded — wins.
    static func provenance(fromFlags flags: UInt32) -> Provenance {
        let isCFA: Bool = (flags & 1) != 0
        let field: UInt32 = (flags >> 1) & 0x7
        if field == 0 { return isCFA ? .sensorCFA : .unspecified }
        guard let value = Provenance(rawValue: field) else { return .unspecified }
        guard value.isSensorTruth == isCFA else { return .unspecified }
        return value
    }

    private static func append(uint16 v: UInt16, to b: inout [UInt8]) {
        b.append(UInt8(truncatingIfNeeded: v))
        b.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    private static func append(uint32 v: UInt32, to b: inout [UInt8]) {
        b.append(UInt8(truncatingIfNeeded: v))
        b.append(UInt8(truncatingIfNeeded: v >> 8))
        b.append(UInt8(truncatingIfNeeded: v >> 16))
        b.append(UInt8(truncatingIfNeeded: v >> 24))
    }

    private static func append(float v: Double, to b: inout [UInt8]) {
        let f: Float = v.isFinite ? Float(v) : 0
        append(uint32: f.bitPattern, to: &b)
    }

    private static func readUInt16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private static func readUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}

// MARK: - Waveform

/// Column-major luma waveform (docs/14 §5.9): one histogram of tonal values per image
/// column, so the trace reads left-to-right exactly as the picture does.
///
/// Storage convention: `counts[column * bins + bin]`, `column` 0 = image left,
/// `bin` 0 = bottom of the tonal axis (black). A renderer drawing top-down flips the
/// bin index; the data itself never encodes a drawing convention.
public struct Waveform: Sendable {

    public let columns: Int
    public let bins: Int
    /// `columns × bins`, column-major.
    public let counts: [Int]
    public let sampleCount: Int
    public let peak: Int
    public let channel: Histogram.Channel
    public let transform: ReadoutTransform

    public init(columns: Int,
                bins: Int,
                counts: [Int],
                sampleCount: Int,
                channel: Histogram.Channel,
                transform: ReadoutTransform) {
        let c: Int = Swift.max(1, columns)
        let n: Int = Swift.max(1, bins)
        self.columns = c
        self.bins = n
        let sized: [Int] = counts.count == c * n ? counts : [Int](repeating: 0, count: c * n)
        self.counts = sized
        self.sampleCount = Swift.max(0, sampleCount)
        var m: Int = 0
        for v in sized { m = Swift.max(m, v) }
        self.peak = m
        self.channel = channel
        self.transform = transform
    }

    public static func compute(_ image: ImageBuffer,
                               columns: Int = 256,
                               bins: Int = 256,
                               space: RGBColorSpace = .rec2020,
                               readout: ReadoutSpace = .srgb255) -> Waveform {
        return compute(image, channel: .luma, columns: columns, bins: bins,
                       transform: ReadoutTransform(space: readout, working: space))
    }

    /// The general form: any channel, an explicit readout transform.
    public static func compute(_ image: ImageBuffer,
                               channel: Histogram.Channel,
                               columns: Int = 256,
                               bins: Int = 256,
                               transform: ReadoutTransform) -> Waveform {
        let c: Int = Swift.max(1, Swift.min(columns, Histogram.maxBins))
        let n: Int = Swift.max(1, Swift.min(bins, Histogram.maxBins))
        var counts = [Int](repeating: 0, count: c * n)

        let m: Mat3 = transform.primaries
        let tf: TransferFunction = transform.transfer
        let w: RGB = transform.working.luminanceWeights
        let ch: Int = channel.rawValue
        let pixels: [Float] = image.pixels
        let width: Int = image.width
        let height: Int = image.height
        let capacity: Int = pixels.count / 4
        var used: Int = 0

        var y: Int = 0
        while y < height {
            var x: Int = 0
            while x < width {
                let p: Int = y * width + x
                if p < capacity {
                    let i: Int = p * 4
                    let r0 = Double(pixels[i])
                    let g0 = Double(pixels[i + 1])
                    let b0 = Double(pixels[i + 2])
                    if r0.isFinite && g0.isFinite && b0.isFinite {
                        let v: Double
                        switch ch {
                        case 0: v = m.m[0][0] * r0 + m.m[0][1] * g0 + m.m[0][2] * b0
                        case 1: v = m.m[1][0] * r0 + m.m[1][1] * g0 + m.m[1][2] * b0
                        case 2: v = m.m[2][0] * r0 + m.m[2][1] * g0 + m.m[2][2] * b0
                        default: v = w.r * r0 + w.g * g0 + w.b * b0
                        }
                        let e: Double = tf.encode(v)
                        if e.isFinite {
                            let t: Double = e < 0 ? 0 : (e > 1 ? 1 : e)
                            var bi: Int = Int(t * Double(n))
                            if bi >= n { bi = n - 1 }
                            if bi < 0 { bi = 0 }
                            var col: Int = width > 0 ? (x * c) / width : 0
                            if col >= c { col = c - 1 }
                            if col < 0 { col = 0 }
                            counts[col * n + bi] += 1
                            used += 1
                        }
                    }
                }
                x += 1
            }
            y += 1
        }

        return Waveform(columns: c, bins: n, counts: counts, sampleCount: used,
                        channel: channel, transform: transform)
    }

    public func count(column: Int, bin: Int) -> Int {
        guard column >= 0, column < columns, bin >= 0, bin < bins else { return 0 }
        return counts[column * bins + bin]
    }

    /// Trace intensity in [0,1] — counts scaled against the whole scope's peak, which
    /// is what keeps a bright column from washing the rest of the trace out.
    public func intensity(column: Int, bin: Int) -> Double {
        guard peak > 0 else { return 0 }
        return Double(count(column: column, bin: bin)) / Double(peak)
    }

    /// Centre of a bin on the normalized tonal axis, [0,1].
    public func binAxis(_ index: Int) -> Double {
        let i: Int = Swift.min(Swift.max(index, 0), bins - 1)
        return (Double(i) + 0.5) / Double(bins)
    }
}

// MARK: - Parade

/// The RGB parade: three waveforms side by side, sharing one tonal axis (docs/14 §5.9).
public struct Parade: Sendable {

    public let red: Waveform
    public let green: Waveform
    public let blue: Waveform

    public init(red: Waveform, green: Waveform, blue: Waveform) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static func compute(_ image: ImageBuffer,
                               columns: Int = 256,
                               bins: Int = 256,
                               space: RGBColorSpace = .rec2020,
                               readout: ReadoutSpace = .srgb255) -> Parade {
        return compute(image, columns: columns, bins: bins,
                       transform: ReadoutTransform(space: readout, working: space))
    }

    public static func compute(_ image: ImageBuffer,
                               columns: Int,
                               bins: Int,
                               transform: ReadoutTransform) -> Parade {
        return Parade(
            red: Waveform.compute(image, channel: .red, columns: columns, bins: bins,
                                  transform: transform),
            green: Waveform.compute(image, channel: .green, columns: columns, bins: bins,
                                    transform: transform),
            blue: Waveform.compute(image, channel: .blue, columns: columns, bins: bins,
                                   transform: transform))
    }

    /// Peak across all three panels — the parade normalizes as one instrument, so the
    /// relative height of the three traces stays readable.
    public var peak: Int { Swift.max(red.peak, Swift.max(green.peak, blue.peak)) }

    public func waveform(_ channel: Histogram.Channel) -> Waveform {
        switch channel {
        case .red: return red
        case .green: return green
        case .blue: return blue
        // The parade has no luma panel; green is the closest stand-in, and callers
        // that want luma should ask `Waveform` for it directly.
        case .luma: return green
        }
    }
}

/// A point in a scope's plot. Normalized plot coordinates ([0,1] from the top-left)
/// unless the API returning it says otherwise.
public struct ScopePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - Vectorscope

/// Chroma scatter in the OKLab a/b plane, binned on a square grid (docs/06 §5.3,
/// docs/14 §5.9). Not a CIE chromaticity diagram — that scope is excluded forever
/// (D22); this one answers "where is my colour, and is skin on the line".
///
/// **Plot convention** — stated because everything downstream depends on it:
///  · Horizontal axis is OKLab **a**, increasing to the right (+a ≈ red/magenta).
///  · Vertical axis is OKLab **b**, increasing **upward** (+b ≈ yellow).
///  · `extent` is the half-width of the plot in OKLab chroma units, so the plot covers
///    a ∈ [−extent, +extent] and b ∈ [−extent, +extent]; the neutral axis is the centre.
///  · `counts` is **row-major with row 0 at the top** (`+extent` in b), matching
///    `ImageBuffer`'s top-left origin, so a renderer can blit rows straight out.
///  · Angles are measured counter-clockwise from **+a**, i.e. `OKLab.hue`.
public struct Vectorscope: Sendable {

    /// Grid is `resolution × resolution`.
    public let resolution: Int
    /// Half-width of the plot in OKLab chroma units.
    public let extent: Double
    /// `resolution × resolution`, row-major, row 0 = top (+b).
    public let counts: [Int]
    public let sampleCount: Int
    public let peak: Int
    /// Samples whose chroma fell outside `extent` (clamped into the border cells).
    public let outOfRangeCount: Int

    public init(resolution: Int,
                extent: Double,
                counts: [Int],
                sampleCount: Int,
                outOfRangeCount: Int) {
        let n: Int = Swift.max(1, resolution)
        self.resolution = n
        self.extent = (extent.isFinite && extent > 0) ? extent : Vectorscope.baseExtent
        let sized: [Int] = counts.count == n * n ? counts : [Int](repeating: 0, count: n * n)
        self.counts = sized
        self.sampleCount = Swift.max(0, sampleCount)
        var m: Int = 0
        for v in sized { m = Swift.max(m, v) }
        self.peak = m
        self.outOfRangeCount = Swift.max(0, outOfRangeCount)
    }

    /// Half-width at 1× zoom. OKLab chroma ~0.4 is about as saturated as real surface
    /// colour gets, so 1× shows the whole plausible gamut and 2× (extent 0.2) zooms into
    /// the low-saturation region where photographs actually live (docs/06 §9).
    public static let baseExtent: Double = 0.4

    /// Plot half-width for a zoom step: 1× → 0.4, 2× → 0.2 (docs/06 §9).
    public static func extentForZoom(_ zoom: Double) -> Double {
        let z: Double = (zoom.isFinite && zoom > 0) ? zoom : 1
        return Vectorscope.baseExtent / z
    }

    public static func compute(_ image: ImageBuffer,
                               resolution: Int = 256,
                               zoom: Double = 1,
                               space: RGBColorSpace = .rec2020) -> Vectorscope {
        return compute(image, resolution: resolution,
                       extent: Vectorscope.extentForZoom(zoom), space: space)
    }

    public static func compute(_ image: ImageBuffer,
                               resolution: Int,
                               extent: Double,
                               space: RGBColorSpace) -> Vectorscope {
        let n: Int = Swift.max(1, Swift.min(resolution, 2048))
        let e: Double = (extent.isFinite && extent > 0) ? extent : Vectorscope.baseExtent
        var counts = [Int](repeating: 0, count: n * n)

        // Built once: the per-pixel work is then two matrix multiplies and three cube
        // roots, with nothing allocated.
        let context = OKLabTransform.Context(space: space)
        let toLMS: Mat3 = context.rgbToLMS
        let toLab: Mat3 = OKLabTransform.lmsToLab
        let pixels: [Float] = image.pixels
        let total: Int = Swift.min(image.width * image.height, pixels.count / 4)
        let invExtent: Double = 1.0 / e
        var used: Int = 0
        var outside: Int = 0

        var p: Int = 0
        while p < total {
            let i: Int = p * 4
            let r0 = Double(pixels[i])
            let g0 = Double(pixels[i + 1])
            let b0 = Double(pixels[i + 2])
            if r0.isFinite && g0.isFinite && b0.isFinite {
                let l0 = toLMS.m[0][0] * r0 + toLMS.m[0][1] * g0 + toLMS.m[0][2] * b0
                let m0 = toLMS.m[1][0] * r0 + toLMS.m[1][1] * g0 + toLMS.m[1][2] * b0
                let s0 = toLMS.m[2][0] * r0 + toLMS.m[2][1] * g0 + toLMS.m[2][2] * b0
                let ln = Num.spow(l0, 1.0 / 3.0)
                let mn = Num.spow(m0, 1.0 / 3.0)
                let sn = Num.spow(s0, 1.0 / 3.0)
                let a = toLab.m[1][0] * ln + toLab.m[1][1] * mn + toLab.m[1][2] * sn
                let b = toLab.m[2][0] * ln + toLab.m[2][1] * mn + toLab.m[2][2] * sn
                if a.isFinite && b.isFinite {
                    if abs(a) > e || abs(b) > e { outside += 1 }
                    let u: Double = Num.saturate((a * invExtent + 1) * 0.5)
                    let v: Double = Num.saturate((1 - b * invExtent) * 0.5)
                    var col: Int = Int(u * Double(n))
                    var row: Int = Int(v * Double(n))
                    if col >= n { col = n - 1 }
                    if col < 0 { col = 0 }
                    if row >= n { row = n - 1 }
                    if row < 0 { row = 0 }
                    counts[row * n + col] += 1
                    used += 1
                }
            }
            p += 1
        }

        return Vectorscope(resolution: n, extent: e, counts: counts,
                           sampleCount: used, outOfRangeCount: outside)
    }

    public func count(column: Int, row: Int) -> Int {
        guard column >= 0, column < resolution, row >= 0, row < resolution else { return 0 }
        return counts[row * resolution + column]
    }

    public func intensity(column: Int, row: Int) -> Double {
        guard peak > 0 else { return 0 }
        return Double(count(column: column, row: row)) / Double(peak)
    }

    /// OKLab (a, b) at the centre of a cell — the inverse of the binning, for
    /// hover-to-highlight (docs/06 §9).
    public func cellCentre(column: Int, row: Int) -> ScopePoint {
        let c: Int = Swift.min(Swift.max(column, 0), resolution - 1)
        let r: Int = Swift.min(Swift.max(row, 0), resolution - 1)
        let u: Double = (Double(c) + 0.5) / Double(resolution)
        let v: Double = (Double(r) + 0.5) / Double(resolution)
        return ScopePoint(x: (u * 2 - 1) * extent, y: (1 - v * 2) * extent)
    }

    // MARK: Skin-tone line

    /// The skin-tone line: the NTSC vectorscope's I-bar transported into OKLab, the axis
    /// all human skin hues cluster on regardless of ethnicity (blood and melanin fix the
    /// hue; luminance is what varies — Van Hurkman, docs/06 §5.3).
    ///
    /// **One constant, two consumers**: this is `ColorEngine.skinLineDegrees`, not a
    /// second copy. The graticule the scope draws and the band the Skin tools protect
    /// have to be the same line or "protected" means two different things; aliasing the
    /// existing golden-locked constant is what guarantees that.
    ///
    /// The angular convention is this scope's: degrees CCW from +a, i.e. `OKLab.hue`,
    /// which is also the convention `ColorEngine.skinWeight` compares against.
    ///
    /// Caveat worth a golden test (see `deriveSkinToneLineDegrees`): re-deriving the
    /// I-bar through the working space lands at ≈56.4° from +a, not 33°. 33° is that same
    /// line measured from **+b** (90° − 56.4° = 33.6°), the traditional vectorscope
    /// orientation with the yellow–blue axis horizontal — so the shipped constant is
    /// right in the vectorscope's own frame and off by the complement in OKLab's. This
    /// file does not resolve it unilaterally, because both consumers must move together;
    /// `deriveSkinToneLineDegrees` is here so the reconciliation is one assertion away.
    public static let skinToneLineDegrees: Double = ColorEngine.skinLineDegrees

    /// The same line measured from the +b axis — the traditional vectorscope reading.
    public static let skinToneLineDegreesFromB: Double = 90 - Vectorscope.skinToneLineDegrees

    /// Half-width of the skin band. docs/06 §5.3 resolves the spec's ambiguous
    /// "band width 0..30°, default 10°" as a **half-width**: ±10°, total 20°, labeled
    /// literally "±10°". Aliased from the Skin tools' constant for the same reason as
    /// the line itself.
    public static let skinBandHalfWidthDegrees: Double = ColorEngine.skinBandDegrees

    /// Re-derive the skin line from first principles: the NTSC YIQ **+I** direction (the
    /// row of the YIQ→R'G'B' matrix, `(0.956, −0.272, −1.106)`), stepped off encoded mid
    /// grey, decoded to linear, carried into the working space and read as an OKLab hue
    /// against the neutral it was stepped from. Returns ≈56.4° at the default step.
    ///
    /// The angle drifts a few hundredths of a degree with `step` (OKLab is hue-linear,
    /// not hue-perfect); `step = 0.05` is the documented choice to lock against.
    public static func deriveSkinToneLineDegrees(space: RGBColorSpace = .rec2020,
                                                 encodedSpace: RGBColorSpace = .srgb,
                                                 transfer: TransferFunction = .srgb,
                                                 step: Double = 0.05) -> Double {
        let iAxis = RGB(0.956, -0.272, -1.106)
        let grey = RGB(gray: 0.5)
        let toWorking: Mat3 = encodedSpace.matrix(to: space)
        let context = OKLabTransform.Context(space: space)
        let sample: OKLab = context.toLab(toWorking.apply(transfer.decode(grey + iAxis * step)))
        let neutral: OKLab = context.toLab(toWorking.apply(transfer.decode(grey)))
        return Num.wrapHue(atan2(sample.b - neutral.b, sample.a - neutral.a) * 180 / .pi)
    }

    /// Points along the skin-tone ray for the overlay, in **normalized plot
    /// coordinates**: (0,0) is the top-left cell of `counts`, (1,1) the bottom-right,
    /// (0.5, 0.5) the neutral centre. The ray runs from the centre (`t = 0`) outward to
    /// the plot edge (`t = 1`) — skin sits on one side of the origin, and the opposite
    /// half is `angleDegrees + 180` if a caller wants the full diameter.
    ///
    /// `count` is the number of samples along the ray; 2 draws the line, more gives
    /// tick positions. Values below 2 are raised to 2.
    public func skinLinePoints(angleDegrees: Double = Vectorscope.skinToneLineDegrees,
                               count: Int = 2) -> [ScopePoint] {
        let n: Int = Swift.max(2, count)
        let theta: Double = (angleDegrees.isFinite ? angleDegrees : 0) * .pi / 180
        let ca: Double = cos(theta)
        let cb: Double = sin(theta)
        var out = [ScopePoint]()
        out.reserveCapacity(n)
        for i in 0..<n {
            let t: Double = Double(i) / Double(n - 1)
            let a: Double = ca * t
            let b: Double = cb * t
            out.append(ScopePoint(x: Num.saturate((a + 1) * 0.5),
                                  y: Num.saturate((1 - b) * 0.5)))
        }
        return out
    }

    /// The two band edges, as rays either side of the line.
    public func skinBandPoints(angleDegrees: Double = Vectorscope.skinToneLineDegrees,
                               halfWidthDegrees: Double = Vectorscope.skinBandHalfWidthDegrees,
                               count: Int = 2) -> (low: [ScopePoint], high: [ScopePoint]) {
        let w: Double = halfWidthDegrees.isFinite ? Num.clamp(halfWidthDegrees, 0, 30) : 0
        return (skinLinePoints(angleDegrees: angleDegrees - w, count: count),
                skinLinePoints(angleDegrees: angleDegrees + w, count: count))
    }

    /// Band membership for a sample, in [0,1] — full inside the band, rolled off to zero
    /// by 1.5× the band, gated by chroma so near-neutrals (which have no meaningful hue)
    /// are never called skin.
    ///
    /// This is the *scope overlay's* test: is this dot inside the graticule band. The
    /// editing guardrail is `ColorEngine.skinWeight`, which adds the plausibility term
    /// (crushed blacks and fire-engine chroma sit on the I-bar too). Same line, same
    /// band, different question — never substitute one for the other.
    public static func skinBandMembership(hueDegrees: Double,
                                          chroma: Double,
                                          halfWidthDegrees: Double = Vectorscope.skinBandHalfWidthDegrees) -> Double {
        guard hueDegrees.isFinite, chroma.isFinite else { return 0 }
        let band: Double = Num.clamp(halfWidthDegrees.isFinite ? halfWidthDegrees : 0, 0, 30)
        let delta: Double = abs(Num.hueDelta(Vectorscope.skinToneLineDegrees, hueDegrees))
        let angular: Double = band > 0
            ? 1 - Num.smoothstep(band, band * 1.5, delta)
            : (delta <= 0 ? 1 : 0)
        let chromaGate: Double = Num.smoothstep(0.01, 0.04, chroma)
        return Num.saturate(angular) * chromaGate
    }
}

// MARK: - Focus peaking

/// The cull-time focus overlay (docs/10 §5.5): 3×3 Laplacian magnitude normalized by
/// local luminance, thresholded by sensitivity. Normalizing by the local mean is the
/// whole trick — an absolute high-pass threshold finds edges in the bright half of the
/// frame and nothing in the shadows, which is exactly when a picker needs it most.
///
/// Output is a confidence plane in [0,1], not a colour: the renderer draws thin outlines
/// from it (never fills), in the user's chosen peaking colour.
public struct FocusPeaking: Sendable {

    public enum Sensitivity: String, Codable, Sendable, CaseIterable {
        case low
        case normal
        case fineDetail

        /// Local contrast ratio at which peaking starts. Lower = more sensitive;
        /// `fineDetail` is the landscape-texture setting.
        public var threshold: Double {
            switch self {
            case .low: return 0.35
            case .normal: return 0.18
            case .fineDetail: return 0.08
            }
        }
    }

    /// Floor on the local mean, so a black region cannot divide the response to infinity.
    public static let luminanceFloor: Double = 1.0 / 1024.0

    /// Local-contrast edge measure over a luminance plane.
    ///
    /// `response = |centre − mean(8 neighbours)| / max(mean(3×3), floor)`, then
    /// `saturate((response − threshold) / threshold)` so the output is 0 below the
    /// threshold and reaches 1 at twice it. Clamped edge addressing, so the frame border
    /// never invents an edge. Cost is a fixed 9 taps per pixel — linear, no allocation
    /// beyond the output plane.
    public static func compute(_ plane: Plane, threshold: Double = 0.18) -> Plane {
        var out = Plane(width: plane.width, height: plane.height)
        let t: Double = (threshold.isFinite && threshold > 0) ? threshold : 1e-6
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                let centre: Double = plane[x, y]
                var neighbours: Double = 0
                var dy: Int = -1
                while dy <= 1 {
                    var dx: Int = -1
                    while dx <= 1 {
                        if dx != 0 || dy != 0 {
                            neighbours += plane.clampedSample(x + dx, y + dy)
                        }
                        dx += 1
                    }
                    dy += 1
                }
                let meanNeighbours: Double = neighbours / 8
                let localMean: Double = (neighbours + centre) / 9
                let denom: Double = localMean > FocusPeaking.luminanceFloor
                    ? localMean
                    : FocusPeaking.luminanceFloor
                let response: Double = abs(centre - meanNeighbours) / denom
                if response.isFinite {
                    out[x, y] = Num.saturate((response - t) / t)
                } else {
                    out[x, y] = 0
                }
            }
        }
        return out
    }

    /// Convenience: peak an RGB frame through its working-space luminance.
    public static func compute(_ image: ImageBuffer,
                               sensitivity: Sensitivity = .normal,
                               space: RGBColorSpace = .rec2020) -> Plane {
        return compute(image.luminancePlane(space: space), threshold: sensitivity.threshold)
    }
}

// MARK: - Clipping overlay

/// The alt-drag threshold view (docs/04 §3.6) and the cull-time `O` overlay
/// (docs/10 §5.3), which share one classification rule.
///
/// Semantics: while an alt-drag is live the picture is replaced by a flat background —
/// **black** for Exposure / Highlights / Whites, **white** for Shadows / Blacks — and
/// only clipped pixels are painted, in a colour naming exactly which channels clipped:
/// `r` / `g` / `b` for one channel, **cyan** = G+B, **magenta** = R+B, **yellow** = R+G,
/// and solid **white** (on the black background) or **black** (on the white one) for all
/// three. Channel-diagnostic, not a red blob: "the reds are gone" and "everything is
/// gone" are different problems with different fixes.
///
/// Input is expected in the readout space (`ReadoutTransform.linearize`), where 0 is the
/// floor and 1 the ceiling.
public enum ClippingOverlay {

    public enum Mode: String, Codable, Sendable, CaseIterable {
        case exposure
        case highlights
        case whites
        case shadows
        case blacks

        /// Exposure / Highlights / Whites inspect the top of the scale; Shadows /
        /// Blacks the bottom.
        public var inspectsHighEnd: Bool {
            switch self {
            case .exposure, .highlights, .whites: return true
            case .shadows, .blacks: return false
            }
        }

        /// The flat ground clipped pixels are painted onto.
        public var background: RGB { inspectsHighEnd ? RGB.zero : RGB.one }

        /// The all-three-channels colour: maximum contrast against the background.
        public var saturatedColour: RGB { inspectsHighEnd ? RGB.one : RGB.zero }
    }

    /// Same tolerance the histogram's triangles use — one definition of "clipped".
    public static let epsilon: Double = Histogram.clipEpsilon

    /// Bit mask of clipped channels: bit 0 = R, bit 1 = G, bit 2 = B.
    public static func mask(_ c: RGB, mode: Mode) -> Int {
        var m: Int = 0
        if mode.inspectsHighEnd {
            if c.r >= 1 - epsilon { m |= 1 }
            if c.g >= 1 - epsilon { m |= 2 }
            if c.b >= 1 - epsilon { m |= 4 }
        } else {
            if c.r <= epsilon { m |= 1 }
            if c.g <= epsilon { m |= 2 }
            if c.b <= epsilon { m |= 4 }
        }
        return m
    }

    /// Overlay colour for a channel mask, or nil for "nothing clipped".
    /// `allChannels` is what a full mask paints — white on black, black on white.
    public static func colour(mask: Int, allChannels: RGB = RGB.one) -> RGB? {
        switch mask {
        case 0: return nil
        case 1: return RGB(1, 0, 0)          // R
        case 2: return RGB(0, 1, 0)          // G
        case 4: return RGB(0, 0, 1)          // B
        case 3: return RGB(1, 1, 0)          // R+G → yellow
        case 5: return RGB(1, 0, 1)          // R+B → magenta
        case 6: return RGB(0, 1, 1)          // G+B → cyan
        default: return allChannels          // all three
        }
    }

    /// The overlay colour for one pixel, or nil when the pixel is not clipped (in which
    /// case the renderer draws `mode.background`).
    public static func classify(_ c: RGB, mode: Mode) -> RGB? {
        return colour(mask: mask(c, mode: mode), allChannels: mode.saturatedColour)
    }

    /// Whole-frame form: every pixel becomes either its overlay colour or the flat
    /// background. Linear in pixel count; the shipping path is the same rule in a
    /// fragment shader.
    public static func render(_ image: ImageBuffer,
                              mode: Mode,
                              transform: ReadoutTransform) -> ImageBuffer {
        var out = ImageBuffer(width: image.width, height: image.height)
        let background: RGB = mode.background
        for y in 0..<image.height {
            for x in 0..<image.width {
                let c: RGB = transform.linearize(image[x, y])
                let painted: RGB? = classify(c, mode: mode)
                out[x, y] = painted ?? background
                out.setAlpha(1, x, y)
            }
        }
        return out
    }
}

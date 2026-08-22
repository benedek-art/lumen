// RawTruth.swift
// The cull-time raw-truth instrument's two halves that are arithmetic rather than
// AppKit: how much of the file to measure, and what the panel is allowed to say about
// the numbers that come back.
//
// WHAT THIS MEASURES, EXACTLY, BECAUSE THE WHOLE FEATURE IS A CLAIM ABOUT THAT.
//
// docs/10 §10.5 specifies statistics from undemosaiced CFA sites, black-subtracted, per
// channel including the second green, binned against the saturation level in the file's
// metadata. That is FastRawViewer's instrument and it is what "raw histogram" means.
// Lumen cannot produce it: there is no CFA reader and no LibRaw anywhere in the
// pipeline, and Apple's RAW API does not expose the mosaic.
//
// What Lumen CAN measure, and what this file is about, is the DECODED SCENE-LINEAR
// frame: `CIRAWFilter` at the flat settings `AppleRawSource` pins — Apple's tone curve,
// shadow boost, local tone mapping, gamut mapping and contrast all off, extended range
// kept — read before every Lumen stage and before the display transform. That is:
//
//   · post-demosaic, so it is NOT the sensor's mosaic and must never be called one;
//   · scene-referred and not clipped by the display transform, which is the whole
//     difference from the develop histogram — that one bins the RENDERED picture, which
//     is the histogram docs/10 §10.5 exists to beat;
//   · enough to answer the question a photographer actually asks at cull time, which is
//     not "what were the sensor's counts" but "is this highlight recoverable".
//
// So the instrument is named `Scene-linear (post-demosaic)` everywhere a person can see
// it, `RawStatistics.Provenance` carries that name into the persisted blob, and
// `sensorGapNote` below is the sentence the panel prints so nobody has to infer the
// remaining gap from a doc they will not read.
//
// The second honest limit is the proxy. Pulling a 45 MP decode into an f32 RGBA buffer
// is 720 MB, so the decode is scaled first, and scaling averages neighbouring sites.
// `Plan` computes the scale, records the site stride it corresponds to, and says in
// `samplingNote` what averaging does to a clipped-percentage — because a percentage
// measured on 4×4 block means is not the same number as one measured on sites, and a
// reader who is not told will assume it is.

import Foundation

/// The cull-time raw-truth instrument: what to measure, and what may be said about it.
public enum RawTruth {

    // MARK: - The gap, in the words the reader sees

    /// Printed by the panel under the numbers. The remaining distance between what this
    /// measures and what docs/10 §10.5 specifies, stated where somebody will find it
    /// rather than left for them to discover.
    ///
    /// Note what it does *not* claim: a direction. Apple's highlight reconstruction
    /// rebuilds a saturated channel from the channels that survived, so the value this
    /// reads for that channel is whatever the reconstruction produced. Whether that
    /// makes the reported percentage higher or lower than the sensor's has not been
    /// measured by this build, and guessing would be the same class of overstatement
    /// this file exists to avoid.
    public static let sensorGapNote: String =
        "Measured after Apple's demosaic, not on the sensor's CFA sites: Lumen has no "
        + "raw reader yet. Where Apple's highlight reconstruction has rebuilt a "
        + "saturated channel, this reads the reconstruction rather than the site."

    /// The one line that says why this is still worth reading — the difference from the
    /// develop histogram, which bins the rendered picture.
    public static let againstTheRenderNote: String =
        "Still scene-referred and unclipped by the display transform, so it shows "
        + "headroom the develop histogram cannot."

    /// What a measurement taken on a file's decode may honestly be called.
    ///
    /// A camera RAW decodes scene-referred, before any tone curve. An already-rendered
    /// file — JPEG, HEIC, PNG, TIFF — decodes the picture somebody's camera or somebody's
    /// editor already tone-mapped, and Core Image's conversion into linear Rec.2020 does
    /// not undo that: the curve and the clipped headroom are gone before this instrument
    /// sees a pixel. Labelling that `sceneLinearDecode` would put the honest name on the
    /// dishonest reading, which is the single worst thing this file could do.
    ///
    /// One function rather than a literal at each call site, because the decoder and the
    /// cache lookup have to agree: if the source labels a JPEG's row one way and the
    /// panel asks for it another, every open recomputes and nobody finds out.
    public static func provenance(isRenderedFile: Bool) -> RawStatistics.Provenance {
        isRenderedFile ? .renderedProxy : .sceneLinearDecode
    }

    // MARK: - Plan

    /// The longest edge the decode is scaled to before binning.
    ///
    /// 2048 puts roughly 2.8 M samples in front of the binner — the same sample count
    /// docs/10 §10.5 budgets for (1/16 of a 45 MP sensor) — for 44 MB of f32 RGBA,
    /// against 720 MB for the full decode. The count matches; the sampling does not,
    /// which is what `averagesSites` and `samplingNote` are for.
    public static let decodeLongEdge: Int = 2048

    /// Stride within the decoded proxy. Every pixel: the proxy is already the
    /// subsample, and striding it again would throw away sample count for no saving
    /// that matters once the decode has been paid for.
    public static let proxyStride: Int = 1

    /// How a given file gets measured.
    public struct Plan: Equatable, Sendable {
        /// What to ask the decoder to scale to, in (0, 1].
        public let decodeScaleFactor: Double
        /// The proxy's long edge in pixels.
        public let proxyLongEdge: Int
        /// Stride within the proxy — what the binner walks.
        public let bufferStride: Int
        /// What one proxy sample corresponds to at the sensor, in sites per axis. This
        /// is the number stored in `RawStatistics.subsample`, whose contract is sites.
        public let siteStride: Int
        /// True when the proxy is a downscale, i.e. when each sample is a mean of
        /// several sites rather than one site.
        public let averagesSites: Bool
        /// Roughly how many samples the binner will see.
        public let approximateSampleCount: Int

        public init(decodeScaleFactor: Double, proxyLongEdge: Int, bufferStride: Int,
                    siteStride: Int, averagesSites: Bool, approximateSampleCount: Int) {
            self.decodeScaleFactor = decodeScaleFactor
            self.proxyLongEdge = proxyLongEdge
            self.bufferStride = bufferStride
            self.siteStride = siteStride
            self.averagesSites = averagesSites
            self.approximateSampleCount = approximateSampleCount
        }

        /// What averaging does to the numbers, in the panel's words. Empty when the
        /// frame was small enough to measure at full size and nothing was averaged.
        public var samplingNote: String {
            guard averagesSites else { return "" }
            return "Binned on a \(proxyLongEdge) px proxy, so each sample is the mean of "
                + "about \(siteStride)×\(siteStride) sites: a large blown region reads "
                + "true, an isolated clipped pixel is averaged down."
        }
    }

    /// How to measure a file of this native size.
    ///
    /// Degenerate sizes are the reason this is a function with tests rather than two
    /// divisions at a call site: a zero or negative dimension has to produce a usable
    /// plan (scale 1, stride 1) rather than a division by zero or a scale of infinity
    /// that the decoder would clamp into something nobody chose.
    public static func plan(nativeWidth: Int, nativeHeight: Int) -> Plan {
        let longEdge: Int = Swift.max(nativeWidth, nativeHeight)
        guard longEdge > 0 else {
            return Plan(decodeScaleFactor: 1, proxyLongEdge: 0, bufferStride: proxyStride,
                        siteStride: 1, averagesSites: false, approximateSampleCount: 0)
        }
        let proxyEdge: Int = Swift.min(longEdge, decodeLongEdge)
        let scale: Double = Double(proxyEdge) / Double(longEdge)
        // Rounded UP, not to nearest. At 8192 → 2048 every rule gives 4; at 3000 → 2048
        // each sample covers about 1.5 sites, and the two ways to write that down are
        // 1 (the measurement is finer than it is) and 2 (it is coarser). The stride is
        // stored in the row and printed in the caption, so the error that survives has
        // to be the one that under-claims.
        let stride: Int = Swift.max(1, Int((Double(longEdge) / Double(proxyEdge)).rounded(.up)))
        let shortEdge: Int = Swift.max(0, Swift.min(nativeWidth, nativeHeight))
        let proxyShort: Int = Swift.max(1, Int((Double(shortEdge) * scale).rounded()))
        let perAxis: Int = Swift.max(1, proxyStride)
        let samples: Int = (proxyEdge / perAxis) * (proxyShort / perAxis)
        return Plan(decodeScaleFactor: scale,
                    proxyLongEdge: proxyEdge,
                    bufferStride: perAxis,
                    siteStride: stride,
                    averagesSites: proxyEdge < longEdge,
                    approximateSampleCount: Swift.max(0, samples))
    }

    // MARK: - Readout

    /// A channel that counts as clipped has to be measurably clipped. Below this a
    /// percentage is a handful of hot pixels on a 2.8 M-sample proxy, and calling that
    /// "clipped" would make the verdict fire on every frame.
    public static let significantPercent: Double = 0.1

    /// Above this, a clipped channel is a region rather than an edge, and the verdict
    /// stops saying "a trace".
    public static let regionPercent: Double = 1.0

    /// What the cull-time question gets as an answer.
    ///
    /// The rule is stated here rather than in the summary strings, because the strings
    /// are what a reader checks and the thresholds are what a test checks, and those
    /// two have to be the same sentence:
    ///
    ///   · `intact` — no channel reaches `significantPercent`;
    ///   · `gone` — every channel is over `regionPercent`, so there is no surviving
    ///     channel for highlight reconstruction to work from;
    ///   · `recoverable` — anything between: some clipping, but at least one channel is
    ///     still under a percent and can carry the reconstruction.
    public enum Verdict: String, Sendable, CaseIterable {
        case intact
        case recoverable
        case gone

        public var summary: String {
            switch self {
            case .intact: return "Highlights intact"
            case .recoverable: return "Recoverable — a channel is still under 1%"
            case .gone: return "Not recoverable — all three channels over 1%"
            }
        }
    }

    /// One channel's line in the panel.
    public struct Line: Equatable, Sendable {
        public let name: String
        /// % of samples at or above the ceiling.
        public let clippedPercent: Double
        /// % within 0.25 EV of it.
        public let nearClippedPercent: Double
        /// % at or below the black floor.
        public let crushedPercent: Double
        /// Whether this channel counts toward the verdict.
        public let isClipped: Bool

        public init(name: String, clippedPercent: Double, nearClippedPercent: Double,
                    crushedPercent: Double, isClipped: Bool) {
            self.name = name
            self.clippedPercent = clippedPercent
            self.nearClippedPercent = nearClippedPercent
            self.crushedPercent = crushedPercent
            self.isClipped = isClipped
        }

        /// `R 2.1%` — the number and nothing implied around it.
        public var text: String { name + " " + RawTruth.percent(clippedPercent) }
    }

    /// Everything the panel prints, derived once so the view draws and decides nothing.
    public struct Readout: Equatable, Sendable {
        /// R, G, B. The fourth slot is luma (or G2) and is not a colour channel, so it
        /// is reported separately rather than voting in the verdict.
        public let channels: [Line]
        public let luma: Line
        public let verdict: Verdict
        /// `R 2.1%, G 0.0%, B 0.0% clipped` — docs/10 §10.5's line.
        public let headline: String
        /// `Scene-linear (post-demosaic)`, from the provenance the blob carries.
        public let provenanceLabel: String
        /// What the percentages are a percentage of.
        public let ceilingNote: String
        /// The remaining distance to the sensor, plus what averaging did. Never empty:
        /// a readout with nothing to qualify still says which reading it is.
        public let qualifications: [String]
        /// True only when the numbers came from the sensor's own mosaic. Nothing in
        /// this repository can set it, and the panel must not claim it.
        public let isSensorTruth: Bool

        public init(channels: [Line], luma: Line, verdict: Verdict, headline: String,
                    provenanceLabel: String, ceilingNote: String,
                    qualifications: [String], isSensorTruth: Bool) {
            self.channels = channels
            self.luma = luma
            self.verdict = verdict
            self.headline = headline
            self.provenanceLabel = provenanceLabel
            self.ceilingNote = ceilingNote
            self.qualifications = qualifications
            self.isSensorTruth = isSensorTruth
        }
    }

    /// Turn a measurement into the panel's text and its verdict.
    ///
    /// `plan` is optional because a decoded blob from the catalog has no plan attached —
    /// the row records the site stride and that is what the note is rebuilt from.
    public static func readout(_ stats: RawStatistics, plan: Plan? = nil) -> Readout {
        let names: [String] = ["R", "G", "B"]
        var channels: [Line] = []
        channels.reserveCapacity(3)
        for i in 0..<3 {
            channels.append(line(stats, index: i, name: names[i]))
        }
        let luma: Line = line(stats, index: 3, name: stats.sourceIsCFA ? "G2" : "Y")

        let clippedCount: Int = channels.filter(\.isClipped).count
        let allOverARegion: Bool = channels.allSatisfy {
            $0.clippedPercent.isFinite && $0.clippedPercent >= RawTruth.regionPercent
        }
        let verdict: Verdict
        if clippedCount == 0 {
            verdict = .intact
        } else if allOverARegion {
            verdict = .gone
        } else {
            verdict = .recoverable
        }

        let headline: String = channels.map(\.text).joined(separator: ", ") + " clipped"

        var qualifications: [String] = []
        switch stats.provenance {
        case .sceneLinearDecode:
            qualifications.append(sensorGapNote)
            qualifications.append(againstTheRenderNote)
        case .sensorCFA:
            break
        case .renderedProxy:
            qualifications.append(
                "Binned from the rendered picture, which is the histogram a raw readout "
                + "exists to beat: it is post-tone-curve and post display transform.")
        case .unspecified:
            qualifications.append(
                "This row does not record what it was measured on, so it is not "
                + "evidence of anything. Recompute it before trusting a number here.")
        }
        let note: String = plan?.samplingNote ?? storedSamplingNote(stats)
        if !note.isEmpty { qualifications.append(note) }

        return Readout(channels: channels,
                       luma: luma,
                       verdict: verdict,
                       headline: headline,
                       provenanceLabel: stats.provenance.label,
                       ceilingNote: "Percentages are of samples at or above "
                           + stats.provenance.ceilingMeaning + ".",
                       qualifications: qualifications,
                       isSensorTruth: stats.provenance.isSensorTruth)
    }

    private static func line(_ stats: RawStatistics, index: Int, name: String) -> Line {
        let high: Double = stats.clippedHighPercent[index]
        return Line(name: name,
                    clippedPercent: high,
                    nearClippedPercent: stats.nearClippedHighPercent[index],
                    crushedPercent: stats.clippedLowPercent[index],
                    isClipped: high.isFinite && high >= significantPercent)
    }

    /// The sampling note rebuilt from a stored row, which knows its site stride and
    /// nothing else about how it was taken.
    private static func storedSamplingNote(_ stats: RawStatistics) -> String {
        guard stats.subsample > 1 else { return "" }
        return "Binned at one sample per \(stats.subsample)×\(stats.subsample) sites, so "
            + "a large blown region reads true and an isolated clipped pixel does not."
    }

    /// One decimal place, which is the precision docs/10 §10.5's example line prints
    /// (`R 2.1% clipped`) and as much as a subsampled proxy can honestly support.
    public static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let clamped: Double = value < 0 ? 0 : (value > 100 ? 100 : value)
        return String(format: "%.1f%%", clamped)
    }
}

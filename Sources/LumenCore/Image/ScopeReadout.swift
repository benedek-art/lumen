// ScopeReadout.swift
// The decisions the instrument column makes ABOUT its numbers, taken out of the views.
//
// `Scopes.swift` bins pixels. The views draw. Between the two sat four decisions that
// were neither binning nor drawing, each written once inside a SwiftUI file where no
// test could reach it:
//
//   · how many columns a waveform may ask for, given the proxy it was handed;
//   · which channels count as clipping, and at what fraction — asked twice, in two
//     places, so the triangle's colour and the number beside it could disagree;
//   · what the luma trace is weighted by, which was stated in no string anywhere;
//   · which image the numbers came off, which is the question the whole panel is an
//     answer to and which nothing in the app printed at all.
//
// They live here because every one of them is arithmetic or a string over arithmetic,
// and because a decision a test can reach is a decision that stops drifting.

import Foundation

public enum ScopeReadout {

    // MARK: - Trace geometry

    /// The number of waveform/parade columns to ask for, given the width of the buffer
    /// being binned.
    ///
    /// `Waveform.compute` maps a source column with `col = (x * columns) / width`. That
    /// map is injective but not surjective when `width < columns`, so `columns − width`
    /// of them are never written and the plate draws a picket fence of empty stripes:
    /// at the app's 512 px trace proxy a 1:3 crop is 171 px wide and leaves 85 of 256
    /// columns permanently blank (33.2 %), a 1:4 crop leaves 128 (50.0 %). The blanks
    /// are true zeros, so nothing downstream can tell them from black.
    ///
    /// A narrower scope is the honest answer: the view scales the bitmap to the panel
    /// either way, so the only thing lost is resolution the source never had.
    public static func traceColumns(forWidth width: Int, requested: Int = 256) -> Int {
        let w: Int = Swift.max(1, width)
        let r: Int = Swift.max(1, requested)
        return Swift.min(r, w)
    }

    // MARK: - Clipping

    /// The fraction of the frame one channel has to lose before the instrument calls it
    /// clipping.
    ///
    /// ONE constant, because the corner triangle's colour, the triangle's brightness and
    /// the headline percentage all have to be answers to the same question. They were
    /// three expressions in two files: a mask above `0.00005`, a `sqrt(worst * 200)`
    /// ramp with no floor at all, and a headline on the luma channel — so a blown red
    /// channel painted the triangle red, lit it at a third brightness, and printed
    /// `0.00% white` four points away from it.
    ///
    /// The value is unchanged from the one the triangle shipped with. It is a FRACTION,
    /// so it means the same thing whatever the frame is measured over — which matters
    /// now that the counts are exact counts of the frame's own pixels rather than of a
    /// 175k-sample proxy.
    public static let clippingThreshold: Double = 0.00005

    /// What is clipping at one end: the worst channel's share of the frame, and the
    /// channels flagged at `clippingThreshold`.
    ///
    /// R/G/B only. Luma clips when essentially all three channels are at the ceiling
    /// (`Histogram.compute` bins `w·(r,g,b)` into channel 3), which is why a headline on
    /// the luma channel reads zero through every single-channel clip there is — sunset,
    /// sodium light, a red dress.
    public static func clipping(_ histogram: Histogram,
                                end: Histogram.End) -> ClipReport {
        var worst: Double = 0
        for channel in [Histogram.Channel.red, .green, .blue] {
            let f: Double = histogram.clippedFraction(channel, end: end)
            if f.isFinite && f > worst { worst = f }
        }
        let mask: Int = histogram.clippingMask(end: end, threshold: clippingThreshold)
        return ClipReport(fraction: worst, mask: mask)
    }

    /// One end of the scale, as the panel reports it.
    public struct ClipReport: Sendable, Equatable {
        /// Worst of R/G/B, as a share of the samples the histogram is denominated in.
        public let fraction: Double
        /// Bit 1 = red, 2 = green, 4 = blue — the channels past `clippingThreshold`.
        /// This is exactly what `ClippingOverlay.colour(mask:)` paints the triangle.
        public let mask: Int

        public init(fraction: Double, mask: Int) {
            self.fraction = (fraction.isFinite && fraction > 0) ? Swift.min(fraction, 1) : 0
            self.mask = Swift.max(0, Swift.min(mask, 7))
        }

        public var percent: Double { fraction * 100 }

        /// True when no channel is past the threshold — the state in which the triangle
        /// must be dark and the headline must read zero, together.
        public var isClean: Bool { mask == 0 }

        /// How brightly the corner triangle burns, in [0,1].
        ///
        /// Zero below the threshold, so "no channel is flagged" and "the triangle is
        /// dark" are the same statement rather than two nearly-agreeing ones. Above it
        /// the ramp is deliberately steep at the bottom: a tenth of a percent of the
        /// frame is already worth seeing, and a linear ramp would leave it invisible.
        public var strength: Double {
            guard mask != 0 else { return 0 }
            let v: Double = (fraction * 200).squareRoot()
            return v.isFinite ? Swift.min(Swift.max(v, 0), 1) : 0
        }

        /// The channels flagged, as letters — "R", "RB", or "" when all three agree
        /// (which is what "white" and "black" already mean) or none is flagged.
        public var channelTag: String {
            guard mask != 0, mask != 7 else { return "" }
            var out = ""
            if mask & 1 != 0 { out += "R" }
            if mask & 2 != 0 { out += "G" }
            if mask & 4 != 0 { out += "B" }
            return out
        }
    }

    /// The histogram's headline: what is gone at each end, and in which channels.
    ///
    /// Both halves come from one `Histogram` through `clipping(_:end:)`, so the number
    /// printed here and the colour of the triangle beside it cannot be answers to
    /// different questions.
    ///
    /// Widest string this can produce is pinned by `clipHeadlineWidestCase` — a readout
    /// line is a fixed slot and a formatter with no stated maximum is how it overflows.
    public static func clipHeadline(_ histogram: Histogram) -> String {
        let high: ClipReport = clipping(histogram, end: .high)
        let low: ClipReport = clipping(histogram, end: .low)
        return headlineHalf(high, word: "white") + " · " + headlineHalf(low, word: "black")
    }

    private static func headlineHalf(_ report: ClipReport, word: String) -> String {
        let tag: String = report.channelTag
        let number: String = percentString(report.percent)
        return tag.isEmpty ? number + "% " + word : number + "% " + tag + " " + word
    }

    /// The widest headline the formatter above can emit, for a layout budget to be
    /// checked against. Two channels flagged is the widest tag ("RB" and "RG" and "GB"
    /// are all two letters; three is `""`, because that is what "white" means), and
    /// 100.00 is the widest number.
    public static let clipHeadlineWidestCase: String =
        "100.00% RB white · 100.00% RB black"

    /// The other string that shares that slot: what a zone drag prints while the pointer
    /// is inside the graph — the slider being scrubbed, its value, and the share of the
    /// frame that zone holds.
    ///
    /// Here rather than in the view for one reason: it is the WIDEST thing the readout
    /// line ever holds, and a fixed slot whose widest content is unknown is a slot that
    /// overflows in the field. It is also the same grammar as the headline (`·` between
    /// two facts), which the previous form — two spaces, then three — was not.
    public static func zoneReadout(name: String, value: Double, decimals: Int,
                                   sharePercent: Double) -> String {
        let v: String = value.isFinite
            ? String(format: "%.\(Swift.max(0, decimals))f", value) : "—"
        let s: String = sharePercent.isFinite
            ? String(format: "%.1f", Swift.min(Swift.max(sharePercent, 0), 100)) : "—"
        return name + " " + v + " · " + s + "% of frame"
    }

    /// The widest zone readout: the longest slider name, a three-digit negative value,
    /// and a full-frame share. Pinned so a layout test has something to check.
    public static let zoneReadoutWidestCase: String =
        zoneReadout(name: "Highlights", value: -100, decimals: 0, sharePercent: 100)

    /// The short name of a readout space — what a readout LINE has room for.
    ///
    /// `ReadoutSpace.label` spells it out ("Output profile 0–255", twenty characters)
    /// because it is written for places where an unlabeled number would be the defect.
    /// In a 320-point column the long form costs the instrument beside it its width, so
    /// both the histogram's cycling label and the scopes' caption use this one, and
    /// there is exactly one of it.
    public static func shortSpaceLabel(_ space: ReadoutSpace) -> String {
        switch space {
        case .working: return "Working %"
        case .srgb255: return "sRGB 255"
        case .outputProfile: return "Output 255"
        }
    }

    /// Percentages with two decimals, and a floor that does not lie.
    ///
    /// `String(format: "%.2f")` renders one blown pixel in ten million as `0.00`, which
    /// is the same string the instrument prints when the frame is genuinely clean —
    /// and the counts became exact precisely so that case could be told apart. Anything
    /// non-zero below the printable floor prints `<0.01` instead.
    public static func percentString(_ percent: Double) -> String {
        guard percent.isFinite else { return "—" }
        if percent <= 0 { return "0.00" }
        if percent < 0.005 { return "<0.01" }
        return String(format: "%.2f", percent)
    }

    // MARK: - What the luma trace is weighted by

    /// The name of the weighting behind the luma trace and the luma waveform.
    ///
    /// `Histogram.compute` and `Waveform.compute` both weight the WORKING triple by
    /// `transform.working.luminanceWeights` — the space's own row of `toXYZ`, never
    /// Rec.709 weights on Rec.2020 data. Every scope in this app is therefore a
    /// Rec.2020-luminance scope, and until this string existed it said so nowhere: an
    /// unstated weighting turns a luminance scope into a picture of one.
    public static func lumaLabel(_ transform: ReadoutTransform) -> String {
        transform.working.name + " luma"
    }

    /// What the vertical axis of the histogram is, said plainly, because it is neither
    /// linear-to-the-peak nor logarithmic and no label on screen implies either.
    ///
    /// `Histogram.normalized` scales bins against the 99th-percentile OCCUPIED bin and
    /// saturates everything above it at 1.0. That is the right choice — one white spike
    /// at +5 EV otherwise scales the rest of the graph into sub-pixel heights — but it
    /// means the top of the graph is a clamp and not a value, and a photographer reading
    /// two touching peaks as equal would be reading the clamp.
    public static let verticalScaleNote: String =
        "Vertical: linear, clamped at the 99th-percentile occupied bin — "
        + "traces that touch the top are saturated, not equal."

    // MARK: - Provenance

    /// WHICH IMAGE THE NUMBERS CAME OFF.
    ///
    /// The one question an instrument must answer about itself, and the one this panel
    /// never printed. Two feeds produce a `Histogram` in this app and they measure
    /// different pictures: the loupe bins the frame the viewer is already showing —
    /// which carries the soft proof, including the parts of the soft proof that are
    /// instruments rather than photograph — while the grid commissions its own render,
    /// which is deliberately taken without the proof.
    ///
    /// So "the scopes measure the display rendition" is true in both cases and
    /// insufficient in both. This value says which rendition, and the view prints it
    /// whenever the answer is not the plain one.
    public struct Provenance: Sendable, Equatable {

        public enum Frame: String, Sendable, Equatable {
            /// The pixels on screen, after every stage including picture formation, the
            /// display encode and the 8×8 ordered dither.
            case viewerFrame
            /// A render commissioned for the instrument, at the scope proxy's size, by a
            /// surface that has no frame of its own to offer.
            case commissionedRender
        }

        public enum Coverage: String, Sendable, Equatable {
            /// The whole photograph, as cropped.
            case wholeFrame
            /// Only the rectangle the viewer is showing — a zoomed loupe renders the
            /// visible region and nothing else.
            case visibleRegion
        }

        public let frame: Frame
        /// Whether those pixels are the whole photograph or only the part of it on
        /// screen.
        ///
        /// A zoomed loupe renders the VISIBLE RECTANGLE, not the frame — the file that
        /// caches developed thumbnails already refuses a region frame for exactly this
        /// reason ("a zoomed settle covers a rectangle, not the frame"). The scopes take
        /// the same frames and did not, so at 1:1 on a corner of a photograph the
        /// histogram described that corner and said nothing. Both answers are defensible
        /// — Resolve scopes the viewer, Lightroom scopes the image — but only if the
        /// panel says which.
        public let coverage: Coverage
        /// The soft proof's gamut mapping — space and intent — is in these pixels.
        public let proofed: Bool
        /// So is a proofing INSTRUMENT: the out-of-gamut flag's flat grey
        /// (`SoftProof.warningColor`), or the paper-white simulation's compression of
        /// the whole range into ink-black…paper-white. Both are chrome painted onto the
        /// photograph, and binning them measures the warning rather than the picture.
        public let instrumentPaint: Bool
        /// The clipping counts are exact counts over every pixel of the frame, rather
        /// than the box-averaged proxy's estimate (which erases any blown region
        /// smaller than one box).
        public let exactCounts: Bool

        public init(frame: Frame, coverage: Coverage = .wholeFrame,
                    proofed: Bool, instrumentPaint: Bool, exactCounts: Bool) {
            self.frame = frame
            self.coverage = coverage
            self.proofed = proofed
            self.instrumentPaint = instrumentPaint && proofed
            self.exactCounts = exactCounts
        }

        /// The plain case: the whole frame on screen, unproofed, counted exactly.
        /// Nothing to disclose, so `note` is nil and the panel spends no chrome.
        public var isPlain: Bool {
            frame == .viewerFrame && coverage == .wholeFrame && !proofed && exactCounts
        }

        /// Everything about this measurement a photographer would be surprised by,
        /// worst first — a scope binning its own gamut warning outranks a scope binning
        /// the visible corner, which outranks a proof, which outranks an estimate.
        public var clauses: [String] {
            var out: [String] = []
            // Exactly one clause about WHOSE pixels these are, which is what keeps the
            // widest case bounded — and is also the truer statement. A commissioned
            // render does not carry the proof at all, so "scope render, no proof" and
            // "soft proof" cannot both be facts about one measurement; if a caller hands
            // over both, the render is the stronger claim and wins.
            if frame == .commissionedRender {
                out.append("scope render, no proof")
            } else if instrumentPaint {
                out.append("soft proof + gamut flag")
            } else if proofed {
                out.append("soft proof")
            }
            if coverage == .visibleRegion { out.append("visible region only") }
            if !exactCounts { out.append("clipping % estimated") }
            return out
        }

        /// One short line for the panel, or nil when there is nothing to say.
        ///
        /// AT MOST TWO CLAUSES. The line is a fixed slot — the develop column can be
        /// dragged down to 320 points — and four clauses joined would be 97 characters
        /// and truncate, which turns a disclosure into a worse silence than none. The
        /// rest is in `statement`, which is the tooltip and has room.
        public var note: String? {
            let clauses = self.clauses
            guard !clauses.isEmpty else { return nil }
            return "Binned: " + clauses.prefix(2).joined(separator: " · ")
        }

        /// The widest `note` the assembly above can produce, for a layout budget to be
        /// checked against.
        ///
        /// It is asserted to BE the widest, over all thirty-two combinations, rather
        /// than reasoned about — and that assertion earned itself twice. Reasoning gave
        /// 52 characters against a real 56, and then 53 against a real 54; the
        /// enumeration in `ScopeMathTests.testTheNoteNeverGrowsPastTwoClauses` found
        /// both. A widest case arrived at by argument is a layout budget checked against
        /// a string the code cannot produce.
        public static let noteWidestCase: String =
            "Binned: soft proof + gamut flag · clipping % estimated"

        /// The whole sentence, for the tooltip: what was measured, in what, counted how.
        public func statement(readout: ReadoutSpace) -> String {
            var out: String = frame == .viewerFrame
                ? "Measured on the frame on screen, after the display transform"
                : "Measured on a render commissioned for the scopes, "
                    + "after the display transform"
            if instrumentPaint {
                out += ", through the soft proof INCLUDING its gamut flag "
                    + "(flat grey over out-of-gamut pixels is binned as picture)"
            } else if proofed {
                out += ", through the soft proof"
            } else if frame == .viewerFrame {
                out += ", without a soft proof"
            } else {
                out += "; the soft proof is not applied to this render"
            }
            out += coverage == .visibleRegion
                ? ", covering ONLY the rectangle on screen rather than the whole "
                    + "photograph (zoom to fit to measure the frame)"
                : ", covering the whole frame"
            out += ". Axis: " + readout.label + ". "
            out += exactCounts
                ? "Clipping % counted over every pixel of that frame."
                : "Clipping % estimated off the box-averaged proxy — a blown region "
                    + "smaller than one box is invisible to it."
            return out
        }
    }
}

// ScopeMathTests.swift
// The arithmetic behind the scope panel, which had none of its own.
//
// W2/H2-07 counted the hole: `grep -rn "Waveform\.\|Parade\.\|Vectorscope" Tests/`
// returned nothing, so the waveform's column map, the parade's shared normalization and
// the vectorscope's plot convention — three conventions every drawing routine in
// `ScopesView.swift` depends on being exactly what the header says — had never been run
// against an assertion. This file is that lane.
//
// It also holds the decisions `ScopeReadout.swift` took out of the views: how many
// columns a narrow proxy may ask for (H2-04), which channels count as clipped and what
// the headline says about them (H2-08), what the luma trace is weighted by, and which
// image a measurement was taken off. Every one of those was a literal inside a SwiftUI
// file, i.e. unreachable by any test this project can run.
//
// Where a claim is about the app layer's source rather than about arithmetic, it is a
// TEXT SCAN with comments stripped — a doc comment naming a symbol would otherwise let
// the scan pass its own substitution proof.

import Foundation
import XCTest
@testable import LumenCore

final class ScopeMathTests: XCTestCase {

    // MARK: - H2-04: the waveform's column map, and the blank columns it leaves

    /// The defect, reproduced exactly. `Waveform.compute` maps source column `x` to
    /// `(x * columns) / width`; for `width < columns` that map is injective but not
    /// surjective, so `columns − width` columns are never written and stay true zeros.
    ///
    /// The numbers are the audit's: a 100 px wide buffer asked for 256 columns leaves
    /// 156 of them empty (60.9 %), and the plate draws a picket fence.
    func testANarrowFrameLeavesTheWaveformFullOfBlankColumns() {
        let frame = ImageBuffer(width: 100, height: 200) { _, _ in RGB(gray: 0.5) }
        let scope = Waveform.compute(frame, columns: 256, bins: 64)

        var blank: Int = 0
        for column in 0..<scope.columns where Self.columnTotal(scope, column) == 0 {
            blank += 1
        }
        XCTAssertEqual(scope.columns, 256)
        XCTAssertEqual(blank, 156,
                       "156 of 256 columns are never written — the trace stops reading "
                       + "left to right as the picture does")
    }

    /// The fix, which is a decision about how many columns to ASK for rather than a
    /// change to the binner: a narrower, complete scope. The view scales the bitmap to
    /// the panel either way, so nothing is lost but resolution the source never had.
    func testAskingForTheProxysOwnWidthFillsEveryColumn() {
        let frame = ImageBuffer(width: 100, height: 200) { _, _ in RGB(gray: 0.5) }
        let columns = ScopeReadout.traceColumns(forWidth: frame.width)
        XCTAssertEqual(columns, 100)

        let scope = Waveform.compute(frame, columns: columns, bins: 64)
        for column in 0..<scope.columns {
            XCTAssertGreaterThan(Self.columnTotal(scope, column), 0,
                                 "column \(column) of \(scope.columns) is empty")
        }
    }

    /// And a wide frame still gets the full 256: the rule is a floor on waste, not a cap
    /// on resolution. The app's trace proxy is 512 px on the long edge, so every aspect
    /// ratio up to 2:1 tall keeps all 256 columns.
    func testAWideEnoughProxyStillGetsTheFullTwoHundredAndFiftySixColumns() {
        XCTAssertEqual(ScopeReadout.traceColumns(forWidth: 512), 256)
        XCTAssertEqual(ScopeReadout.traceColumns(forWidth: 256), 256)
        XCTAssertEqual(ScopeReadout.traceColumns(forWidth: 255), 255)
        // 512 px long edge at 1:3 — the audit's worst realistic crop.
        XCTAssertEqual(ScopeReadout.traceColumns(forWidth: 171), 171)
        // Degenerate inputs cannot produce a zero-column scope.
        XCTAssertEqual(ScopeReadout.traceColumns(forWidth: 0), 1)
        XCTAssertEqual(ScopeReadout.traceColumns(forWidth: -4), 1)
    }

    // MARK: - The waveform's two conventions, which every renderer depends on

    /// Column 0 is image LEFT and bin 0 is BLACK. `ScopeRaster.waveform` flips the bin
    /// index for drawing (`row = bins − 1 − bin`) and does not flip the column; if
    /// either convention moved, the trace would be a mirror of the picture and nothing
    /// in the app would notice.
    func testColumnZeroIsImageLeftAndBinZeroIsBlack() {
        // Left half black, right half white.
        let frame = ImageBuffer(width: 64, height: 8) { x, _ in
            RGB(gray: x < 0.5 ? 0 : 1)
        }
        let scope = Waveform.compute(frame, columns: 64, bins: 16)

        XCTAssertEqual(scope.count(column: 0, bin: 0), 8,
                       "the left column is black, and black is bin 0")
        XCTAssertEqual(scope.count(column: 0, bin: 15), 0)
        XCTAssertEqual(scope.count(column: 63, bin: 15), 8,
                       "the right column is white, and white is the top bin")
        XCTAssertEqual(scope.count(column: 63, bin: 0), 0)
    }

    /// Out-of-range indices are answered with zero rather than a trap: the renderer
    /// walks the grid it was handed, and a scope that crashes on a bad index would be a
    /// crash in `body`.
    func testTheWaveformAnswersOutOfRangeIndicesWithZero() {
        let scope = Waveform.compute(
            ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0.5) },
            columns: 8, bins: 8)
        XCTAssertEqual(scope.count(column: -1, bin: 0), 0)
        XCTAssertEqual(scope.count(column: 8, bin: 0), 0)
        XCTAssertEqual(scope.count(column: 0, bin: -1), 0)
        XCTAssertEqual(scope.count(column: 0, bin: 8), 0)
    }

    // MARK: - The parade is ONE instrument

    /// `ScopeRaster.parade` normalizes all three panels against `parade.peak`, so a weak
    /// blue channel draws weak. That is only true if `peak` is the maximum over the
    /// three grids rather than each channel's own — which is the difference between a
    /// parade and three unrelated waveforms.
    func testTheParadeSharesOneNormalizationAcrossItsThreeChannels() {
        // Red everywhere, blue nowhere: the red grid's peak is the frame, the blue
        // grid's peak is the same count in a different bin, and the parade's peak is
        // the larger of the three.
        let frame = ImageBuffer(width: 32, height: 16) { _, _ in RGB(0.8, 0.4, 0.02) }
        let parade = Parade.compute(frame, columns: 32, bins: 64)

        XCTAssertEqual(parade.peak,
                       max(parade.red.peak, max(parade.green.peak, parade.blue.peak)),
                       "one normalization, or a weak channel looks full strength")
        XCTAssertGreaterThan(parade.peak, 0)
        XCTAssertEqual(parade.red.columns, 32)
        XCTAssertEqual(parade.blue.bins, 64)

        // And the three channels land in DIFFERENT bins for the same pixel — a parade
        // whose panels agreed everywhere would be three copies of one waveform.
        let redBin = Self.occupiedBin(parade.red, column: 0)
        let greenBin = Self.occupiedBin(parade.green, column: 0)
        let blueBin = Self.occupiedBin(parade.blue, column: 0)
        XCTAssertGreaterThan(redBin, greenBin)
        XCTAssertGreaterThan(greenBin, blueBin)
    }

    // MARK: - The vectorscope's plot convention

    /// `counts` is row-major with row 0 at +b and column 0 at −a, and `ScopeRaster
    /// .vectorscope` blits rows straight out with no flip. Re-derived here from the
    /// documented formula against a colour whose OKLab is computed independently.
    func testAKnownColourLandsInTheCellTheConventionNames() {
        let colour = RGB(0.55, 0.18, 0.12)
        let frame = ImageBuffer(width: 16, height: 16) { _, _ in colour }
        let scope = Vectorscope.compute(frame, resolution: 64, zoom: 1)

        let lab = OKLabTransform.Context(space: .rec2020).toLab(colour)
        let extent = Vectorscope.extentForZoom(1)
        XCTAssertEqual(extent, 0.4, accuracy: 1e-12)

        let u = Num.saturate((lab.a / extent + 1) * 0.5)
        let v = Num.saturate((1 - lab.b / extent) * 0.5)
        let expectedColumn = min(Int(u * 64), 63)
        let expectedRow = min(Int(v * 64), 63)

        XCTAssertEqual(scope.counts[expectedRow * 64 + expectedColumn], 256,
                       "every one of the 256 identical pixels lands in one cell")
        XCTAssertEqual(scope.sampleCount, 256)
        XCTAssertEqual(scope.peak, 256)

        // A warm red is +a (right of centre) and, in OKLab, slightly +b (above it).
        XCTAssertGreaterThan(expectedColumn, 32, "+a is to the RIGHT of neutral")
        XCTAssertLessThan(expectedRow, 32, "+b is ABOVE neutral — row 0 is the top")
    }

    /// A neutral frame has no chroma, so it must land in the centre cell and nowhere
    /// else. This is the assertion that would fail if the plot ever gained an offset.
    func testANeutralFrameCollapsesToTheCentreCell() {
        let frame = ImageBuffer(width: 8, height: 8) { _, _ in RGB(gray: 0.5) }
        let scope = Vectorscope.compute(frame, resolution: 65, zoom: 1)
        XCTAssertEqual(scope.counts[32 * 65 + 32], 64,
                       "neutral is the centre of the plot")
        XCTAssertEqual(scope.outOfRangeCount, 0)
    }

    /// Zoom is a change of EXTENT, not of resolution: 2× halves the half-width so the
    /// low-saturation region where photographs live fills the plot.
    func testZoomHalvesThePlotHalfWidth() {
        XCTAssertEqual(Vectorscope.extentForZoom(1), 0.4, accuracy: 1e-12)
        XCTAssertEqual(Vectorscope.extentForZoom(2), 0.2, accuracy: 1e-12)
        XCTAssertEqual(Vectorscope.extentForZoom(0), 0.4, accuracy: 1e-12,
                       "a nonsense zoom falls back to base rather than dividing by zero")
        XCTAssertEqual(Vectorscope.extentForZoom(.nan), 0.4, accuracy: 1e-12)
    }

    // MARK: - The skin graticule

    /// H2-10's promised reconciliation, which `Scopes.swift` says is "one assertion
    /// away" and which has never been made. The graticule `ScopesView` draws is
    /// `skinToneLineDegrees`; the derivation from the NTSC +I bar is
    /// `deriveSkinToneLineDegrees`. If they part company, the dashed line on the plot
    /// stops being the skin locus and nothing else in the app would say so.
    func testTheDrawnSkinLineIsTheDerivedSkinLine() {
        XCTAssertEqual(Vectorscope.deriveSkinToneLineDegrees(),
                       Vectorscope.skinToneLineDegrees, accuracy: 0.15)
        XCTAssertEqual(Vectorscope.skinToneLineDegrees, ColorEngine.skinLineDegrees,
                       accuracy: 1e-12, "one constant, one consumer")
        XCTAssertEqual(Vectorscope.skinToneLineDegreesFromB,
                       90 - Vectorscope.skinToneLineDegrees, accuracy: 1e-12)
    }

    /// The band's roll-off, which the graticule wedge draws and the overlay tests
    /// against: full inside, zero by 1.5× the half-width, and never claiming a
    /// near-neutral is skin.
    func testTheSkinBandRollsOffAndGatesOnChroma() {
        let line = Vectorscope.skinToneLineDegrees
        let band = Vectorscope.skinBandHalfWidthDegrees

        XCTAssertEqual(Vectorscope.skinBandMembership(hueDegrees: line, chroma: 0.1), 1,
                       accuracy: 1e-9)
        XCTAssertEqual(
            Vectorscope.skinBandMembership(hueDegrees: line + band * 1.5, chroma: 0.1), 0,
            accuracy: 1e-9)
        let edge = Vectorscope.skinBandMembership(hueDegrees: line + band * 1.25,
                                                  chroma: 0.1)
        XCTAssertGreaterThan(edge, 0)
        XCTAssertLessThan(edge, 1)
        XCTAssertEqual(Vectorscope.skinBandMembership(hueDegrees: line, chroma: 0.001), 0,
                       accuracy: 1e-9, "a near-neutral has no meaningful hue")
    }

    // MARK: - H2-08: the headline and the triangle are one computation

    /// The defect, stated as arithmetic. A frame whose RED channel is blown and whose
    /// green and blue are mid: the luma channel — `w·(r,g,b)` in Rec.2020 weights — is
    /// nowhere near the ceiling, so a headline on `.luma` reads exactly zero while the
    /// triangle beside it paints red.
    func testALuminanceHeadlineIsBlindToASingleChannelClip() {
        let histogram = Self.blownRedHistogram()

        XCTAssertEqual(histogram.clippedPercent(.luma, end: .high), 0, accuracy: 1e-12,
                       "this is the number the panel used to print")
        XCTAssertEqual(histogram.clippedPercent(.red, end: .high), 100, accuracy: 1e-9,
                       "and this is what was actually gone")
    }

    /// The fix: one report, feeding the number, the triangle's colour mask and the
    /// triangle's brightness.
    func testTheHeadlineNamesTheChannelTheTriangleIsPainting() {
        let histogram = Self.blownRedHistogram()
        let report = ScopeReadout.clipping(histogram, end: .high)

        XCTAssertEqual(report.mask, 1, "red alone")
        XCTAssertEqual(report.channelTag, "R")
        XCTAssertEqual(report.percent, 100, accuracy: 1e-9)
        XCTAssertEqual(report.strength, 1, accuracy: 1e-12)
        XCTAssertEqual(ScopeReadout.clipHeadline(histogram),
                       "100.00% R white · 0.00% black")
    }

    /// All three channels clipping is what "white" already means, so the tag is dropped
    /// rather than printing `RGB white`.
    func testAllThreeChannelsPrintPlainWhite() {
        let n = 1000
        let histogram = Self.histogram(sampleCount: n, high: [n, n, n, n], low: [0, 0, 0, 0])
        let report = ScopeReadout.clipping(histogram, end: .high)
        XCTAssertEqual(report.mask, 7)
        XCTAssertEqual(report.channelTag, "")
        XCTAssertEqual(ScopeReadout.clipHeadline(histogram),
                       "100.00% white · 0.00% black")
    }

    /// Below the threshold, the triangle is dark and the headline says so — together.
    /// The strength ramp used to have no floor at all, so a frame with no channel
    /// flagged still lit the triangle to a third of full and the two disagreed about
    /// whether anything was wrong.
    func testBelowTheThresholdTheTriangleIsDarkAndTheNumberAgrees() {
        let n = 1_000_000
        // One pixel in a million is 1e-6, twentieth of `clippingThreshold`.
        let histogram = Self.histogram(sampleCount: n, high: [1, 0, 0, 0], low: [0, 0, 0, 0])
        let report = ScopeReadout.clipping(histogram, end: .high)

        XCTAssertEqual(report.mask, 0)
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(report.strength, 0, accuracy: 1e-12,
                       "no channel flagged means no glow")
        XCTAssertEqual(report.fraction, 1e-6, accuracy: 1e-12,
                       "the fraction is still reported truthfully — only the flag is off")
    }

    /// And the number itself does not round a real loss down to the string a clean frame
    /// prints. `%.2f` renders one pixel in a million as `0.00`, which is exactly the
    /// output of a frame with nothing wrong with it — after the counts were made exact
    /// so those two cases could be told apart.
    func testATinyRealClipDoesNotPrintAsClean() {
        XCTAssertEqual(ScopeReadout.percentString(0), "0.00")
        XCTAssertEqual(ScopeReadout.percentString(0.0001), "<0.01")
        XCTAssertEqual(ScopeReadout.percentString(0.004999), "<0.01")
        XCTAssertEqual(ScopeReadout.percentString(0.005), "0.01")
        XCTAssertEqual(ScopeReadout.percentString(100), "100.00")
        XCTAssertEqual(ScopeReadout.percentString(.nan), "—")
    }

    /// OVERFLOW BOUND. A fixed slot needs the widest string its formatter can produce,
    /// and this asserts the constant the layout is checked against is one the formatter
    /// can actually emit — a hand-typed "widest case" that the code cannot produce is
    /// how a readout overflows with a green test beside it.
    func testTheWidestHeadlineIsTheOneTheLayoutIsSizedAgainst() {
        let n = 1000
        // Red and blue at both ends: two-letter tags, both halves at 100.00.
        let histogram = Self.histogram(sampleCount: n,
                                       high: [n, 0, n, 0], low: [n, 0, n, 0])
        XCTAssertEqual(ScopeReadout.clipHeadline(histogram),
                       ScopeReadout.clipHeadlineWidestCase)
        XCTAssertEqual(ScopeReadout.clipHeadlineWidestCase.count, 35)
    }

    /// The other occupant of the readout slot, and the wider of the two. Its worst case
    /// is pinned for the same reason: a fixed-width slot is only safe if something knows
    /// the longest string that can land in it.
    func testTheZoneReadoutsWidestCaseIsOneTheFormatterCanEmit() {
        XCTAssertEqual(
            ScopeReadout.zoneReadout(name: "Highlights", value: -100, decimals: 0,
                                     sharePercent: 100),
            ScopeReadout.zoneReadoutWidestCase)
        XCTAssertEqual(ScopeReadout.zoneReadoutWidestCase,
                       "Highlights -100 · 100.0% of frame")
        XCTAssertEqual(ScopeReadout.zoneReadoutWidestCase.count, 33)

        // Exposure prints two decimals over a ±5 range, so it is narrower despite them.
        XCTAssertEqual(
            ScopeReadout.zoneReadout(name: "Exposure", value: -5, decimals: 2,
                                     sharePercent: 33.333),
            "Exposure -5.00 · 33.3% of frame")
        // A share cannot exceed the frame, and a non-finite value cannot print digits.
        XCTAssertEqual(
            ScopeReadout.zoneReadout(name: "Blacks", value: .nan, decimals: 0,
                                     sharePercent: 1e9),
            "Blacks — · 100.0% of frame")
    }

    /// One short name for a readout space, shared by the histogram's cycling label and
    /// the scopes' caption — they used to be a private switch and a full-length label,
    /// so the same space had two names four inches apart.
    func testTheShortSpaceLabelsAreShortAndComplete() {
        for space in ReadoutSpace.allCases {
            let short = ScopeReadout.shortSpaceLabel(space)
            XCTAssertFalse(short.isEmpty)
            XCTAssertLessThanOrEqual(short.count, 10, "\(space) is too long for a line")
            XCTAssertLessThan(short.count, space.label.count,
                              "the short form has to be shorter than the long one")
        }
        XCTAssertEqual(ScopeReadout.shortSpaceLabel(.srgb255), "sRGB 255")
        XCTAssertEqual(ScopeReadout.shortSpaceLabel(.outputProfile), "Output 255")
    }

    // MARK: - The clipping predicate, and why the counter may compare instead of bin

    /// `AppState.clipCounts` used to build three 256-entry code histograms and then read
    /// them at exactly two indices — everything at or below `lowCode`, everything at or
    /// above `highCode`. It now compares each code directly, which is only the same
    /// measurement if the predicates are monotone in the code: `decode(c/255) ≤ ε` true
    /// for a PREFIX of the range and `≥ 1 − ε` true for a SUFFIX, with nothing in
    /// between qualifying.
    ///
    /// That is the sRGB TRC being monotone, which is true — and is exactly the kind of
    /// "obviously true" that is worth an assertion when a per-pixel loop is rewritten
    /// around it. All 256 codes, both ends, both directions.
    func testTheClippingPredicatesAreMonotoneInTheCode() {
        let epsilon = Histogram.clipEpsilon
        var linear = [Double](repeating: 0, count: 256)
        for c in 0..<256 { linear[c] = TransferFunction.srgb.decode(Double(c) / 255) }

        var lowCode = -1
        var highCode = 256
        for c in 0..<256 {
            if linear[c] <= epsilon { lowCode = c }
            if linear[c] >= 1 - epsilon && c < highCode { highCode = c }
        }
        XCTAssertEqual(lowCode, 0, "only code 0 decodes to at or below epsilon")
        XCTAssertEqual(highCode, 255, "and only code 255 reaches the ceiling")

        for c in 0..<256 {
            XCTAssertEqual(c <= lowCode, linear[c] <= epsilon,
                           "code \(c): the prefix comparison must be the predicate")
            XCTAssertEqual(c >= highCode, linear[c] >= 1 - epsilon,
                           "code \(c): the suffix comparison must be the predicate")
        }

        // The neighbours, which are what make the thresholds meaningful rather than
        // arbitrary: code 1 misses the floor and code 254 misses the ceiling.
        XCTAssertEqual(linear[1], 0.000303527, accuracy: 1e-9)
        XCTAssertGreaterThan(linear[1], epsilon)
        XCTAssertEqual(linear[254], 0.991102, accuracy: 1e-6)
        XCTAssertLessThan(linear[254], 1 - epsilon)
    }

    // MARK: - What the luma trace is weighted by

    /// The label is not a caption someone typed: it is read off the transform the trace
    /// carries, and this proves the weights that label names are the weights the binner
    /// used — against the Rec.709 vector, which is the mistake the label exists to make
    /// impossible to make silently.
    func testTheStatedLumaWeightingIsTheWeightingTheBinnerUsed() {
        let transform = ReadoutTransform(space: .srgb255, working: .rec2020)
        XCTAssertEqual(ScopeReadout.lumaLabel(transform), "Rec.2020 luma")
        XCTAssertEqual(ScopeReadout.lumaLabel(ReadoutTransform(space: .srgb255,
                                                               working: .srgb)),
                       "sRGB luma")

        let colour = RGB(0.6, 0.3, 0.1)
        let frame = ImageBuffer(width: 4, height: 4) { _, _ in colour }
        let histogram = Histogram.compute(frame, bins: 4096, transform: transform)

        let w = RGBColorSpace.rec2020.luminanceWeights
        let expected = w.r * colour.r + w.g * colour.g + w.b * colour.b
        let expectedBin = histogram.bin(atAxis: TransferFunction.srgb.encode(expected))
        XCTAssertEqual(histogram.count(.luma, bin: expectedBin), 16,
                       "the luma channel is the working space's own luminance")

        // Rec.709 weights on the same triple land in a different bin, so the two
        // conventions are genuinely distinguishable at this precision.
        let seven09 = RGBColorSpace.srgb.luminanceWeights
        let wrong = seven09.r * colour.r + seven09.g * colour.g + seven09.b * colour.b
        let wrongBin = histogram.bin(atAxis: TransferFunction.srgb.encode(wrong))
        XCTAssertNotEqual(expectedBin, wrongBin,
                          "if these collided the assertion above would prove nothing")
        XCTAssertEqual(histogram.count(.luma, bin: wrongBin), 0)
    }

    // MARK: - Which image the numbers came off

    /// The plain case spends no chrome: the whole frame on screen, no proof, counted
    /// exactly.
    func testThePlainMeasurementDisclosesNothingBecauseThereIsNothingToDisclose() {
        let plain = ScopeReadout.Provenance(frame: .viewerFrame, proofed: false,
                                            instrumentPaint: false, exactCounts: true)
        XCTAssertTrue(plain.isPlain)
        XCTAssertNil(plain.note)
        XCTAssertTrue(plain.clauses.isEmpty)
        XCTAssertTrue(plain.statement(readout: .srgb255)
            .contains("frame on screen, after the display transform"))
        XCTAssertTrue(plain.statement(readout: .srgb255)
            .contains("covering the whole frame"))
        XCTAssertTrue(plain.statement(readout: .srgb255)
            .contains("counted over every pixel"))
    }

    /// A proofed frame is a different picture, and the gamut flag makes it a picture of
    /// the instrument. Both are disclosed, worst first.
    func testAProofedFrameSaysSoAndAFlaggedOneSaysMore() {
        let proofed = ScopeReadout.Provenance(frame: .viewerFrame, proofed: true,
                                              instrumentPaint: false, exactCounts: true)
        XCTAssertEqual(proofed.note, "Binned: soft proof")
        XCTAssertFalse(proofed.isPlain)

        let flagged = ScopeReadout.Provenance(frame: .viewerFrame, proofed: true,
                                              instrumentPaint: true, exactCounts: true)
        XCTAssertEqual(flagged.note, "Binned: soft proof + gamut flag")
        XCTAssertTrue(flagged.statement(readout: .srgb255)
            .contains("flat grey over out-of-gamut pixels is binned as picture"))

        // Instrument paint without a proof is not a state the pipeline can produce, so
        // the value refuses to represent it rather than letting a caller invent it.
        let impossible = ScopeReadout.Provenance(frame: .viewerFrame, proofed: false,
                                                 instrumentPaint: true, exactCounts: true)
        XCTAssertFalse(impossible.instrumentPaint)
        XCTAssertNil(impossible.note)
    }

    /// A zoomed loupe hands the scopes the visible rectangle, not the photograph. That
    /// is a legitimate thing to measure and an illegitimate thing to leave unsaid.
    func testAZoomedFrameSaysItIsMeasuringACorner() {
        let zoomed = ScopeReadout.Provenance(frame: .viewerFrame,
                                             coverage: .visibleRegion, proofed: false,
                                             instrumentPaint: false, exactCounts: true)
        XCTAssertEqual(zoomed.note, "Binned: visible region only")
        XCTAssertFalse(zoomed.isPlain)
        XCTAssertTrue(zoomed.statement(readout: .srgb255)
            .contains("ONLY the rectangle on screen"))
    }

    /// Two things wrong at once still fit one line: the note takes the two worst clauses
    /// and leaves the rest to the tooltip, because four joined would be 97 characters in
    /// a slot 320 points wide and a truncated disclosure is worse than none.
    func testTheNoteNeverGrowsPastTwoClauses() {
        let everything = ScopeReadout.Provenance(frame: .commissionedRender,
                                                 coverage: .visibleRegion, proofed: true,
                                                 instrumentPaint: true,
                                                 exactCounts: false)
        XCTAssertEqual(everything.clauses.count, 3)
        XCTAssertEqual(everything.note, "Binned: scope render, no proof · visible region only")
        XCTAssertEqual(ScopeReadout.Provenance.noteWidestCase.count, 54)

        // And the pinned worst case is the longest note the assembly can emit.
        var longest = 0
        for frame in [ScopeReadout.Provenance.Frame.viewerFrame, .commissionedRender] {
            for coverage in [ScopeReadout.Provenance.Coverage.wholeFrame, .visibleRegion] {
                for proofed in [false, true] {
                    for paint in [false, true] {
                        for exact in [false, true] {
                            let p = ScopeReadout.Provenance(
                                frame: frame, coverage: coverage, proofed: proofed,
                                instrumentPaint: paint, exactCounts: exact)
                            longest = max(longest, p.note?.count ?? 0)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(longest, ScopeReadout.Provenance.noteWidestCase.count)
    }

    /// The grid's feed measures a render commissioned without a proof — so with ⇧S on,
    /// the two surfaces genuinely measure two different pictures, and the panel says
    /// which one it has.
    func testTheCommissionedRenderSaysItHasNoProof() {
        let grid = ScopeReadout.Provenance(frame: .commissionedRender, proofed: false,
                                           instrumentPaint: false, exactCounts: true)
        XCTAssertEqual(grid.note, "Binned: scope render, no proof")
        XCTAssertTrue(grid.statement(readout: .srgb255)
            .contains("commissioned for the scopes"))
    }

    /// When the tap is refused — a frame past the memory ceiling — the percentages fall
    /// back to the proxy's estimate, which is the pre-H2-01 behaviour. That is bounded
    /// and it is also invisible, so it is disclosed.
    func testAnEstimatedCountIsDisclosedAsAnEstimate() {
        let estimated = ScopeReadout.Provenance(frame: .viewerFrame, proofed: false,
                                                instrumentPaint: false,
                                                exactCounts: false)
        XCTAssertEqual(estimated.note, "Binned: clipping % estimated")
        XCTAssertTrue(estimated.statement(readout: .srgb255)
            .contains("smaller than one box is invisible to it"))
    }

    // MARK: - The shipped views have to take these paths

    /// `HistogramView.swift` is in LumenApp, which has no test target on this lane
    /// (K-102), so this reads it as text with comments stripped.
    ///
    /// The claim: the headline and the triangle come from ONE computation. A
    /// `clippedPercent(.luma` in the readout, or a second literal threshold beside the
    /// mask, is the defect returning.
    func testTheHistogramsHeadlineAndTriangleShareOneComputation() throws {
        let source = Self.stripped(try Self.appSource("HistogramView.swift"))

        XCTAssertTrue(source.contains("ScopeReadout.clipHeadline(histogram)"),
                      "the headline is the shared computation's output")
        XCTAssertTrue(source.contains("ScopeReadout.clipping(histogram, end: end)"),
                      "and so are the triangle's colour and brightness")
        XCTAssertFalse(source.contains("clippedPercent(.luma"),
                       "a luma headline is blind to every single-channel clip — H2-08")
        XCTAssertFalse(source.contains("threshold: 0.0"),
                       "the threshold belongs to ScopeReadout, not to a view literal")
        XCTAssertFalse(source.contains("(worst * 200)"),
                       "the ramp moved with it")
        XCTAssertTrue(source.contains("state.scopes?.provenance?.note"),
                      "and the panel discloses which image it measured")
    }

    /// `ScopeData.swift`'s half: the trace columns are derived from the buffer, and both
    /// feeds record what they measured.
    func testTheFeedDerivesItsColumnsAndRecordsItsProvenance() throws {
        let source = Self.stripped(try Self.appSource("ScopeData.swift"))

        XCTAssertTrue(source.contains("ScopeReadout.traceColumns(forWidth: buffer.width)"),
                      "H2-04: the column count is a decision about the proxy's width")
        XCTAssertFalse(source.contains("columns: 256"),
                       "a fixed 256 is what leaves a narrow crop full of blank columns")
        XCTAssertTrue(source.contains("frame: .viewerFrame, coverage: coverage,"),
                      "the loupe feed records that it binned the frame on screen, "
                      + "soft proof and all")
        XCTAssertTrue(source.contains("frame: .commissionedRender, proof: nil"),
                      "and the grid feed records that its render carries no proof")
        XCTAssertTrue(source.contains("let proof = activeSoftProof"),
                      "which requires reading the proof on the main actor")
    }

    /// `ScopesView.swift`'s half: the caption names the weighting behind the word it
    /// prints, rather than printing "Luma" and leaving the weights to folklore.
    func testTheWaveformCaptionNamesItsWeighting() throws {
        let source = Self.stripped(try Self.appSource("ScopesView.swift"))
        XCTAssertTrue(source.contains("ScopeReadout.lumaLabel(waveform.transform)"),
                      "read off the transform the trace carries, not typed")
        XCTAssertFalse(source.contains("\"Luma waveform · \""),
                       "an unstated weighting is not an instrument")
        XCTAssertFalse(source.contains("transform.space.label"),
                       "the full-length space name does not fit a 320 pt column")
        XCTAssertTrue(source.contains("ScopeReadout.shortSpaceLabel("),
                      "both instruments in the column name a space the same way")
    }

    // MARK: - helpers

    private static func columnTotal(_ scope: Waveform, _ column: Int) -> Int {
        var total = 0
        for bin in 0..<scope.bins { total += scope.count(column: column, bin: bin) }
        return total
    }

    /// The single occupied bin of a flat column — the tests above build frames of one
    /// colour, so there is exactly one.
    private static func occupiedBin(_ scope: Waveform, column: Int) -> Int {
        for bin in 0..<scope.bins where scope.count(column: column, bin: bin) > 0 {
            return bin
        }
        return -1
    }

    /// A histogram with exactly the clipping counts a case needs. Built through the
    /// public initializer rather than by binning, so the case under test is the
    /// READOUT's arithmetic and not the binner's.
    private static func histogram(sampleCount: Int, high: [Int], low: [Int]) -> Histogram {
        Histogram(bins: 4,
                  counts: [Int](repeating: 0, count: Histogram.channelCount * 4),
                  sampleCount: sampleCount,
                  transform: ReadoutTransform(space: .srgb255),
                  clippedLowCounts: low,
                  clippedHighCounts: high)
    }

    /// A real binned frame whose red channel is blown and whose luma is not: this is
    /// the case H2-08 is about, and it is binned rather than constructed so the luma
    /// weighting doing the hiding is the shipped one.
    private static func blownRedHistogram() -> Histogram {
        let frame = ImageBuffer(width: 16, height: 16) { _, _ in RGB(2.0, 0.35, 0.30) }
        return Histogram.compute(frame, bins: 256, readout: .srgb255)
    }

    private static func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// Comments removed, so a doc comment naming a symbol cannot make a scan pass.
    private static func stripped(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        var block = false
        while i < source.endIndex {
            let rest = source[i...]
            if block {
                if rest.hasPrefix("*/") { block = false; i = source.index(i, offsetBy: 2) }
                else { i = source.index(after: i) }
                continue
            }
            if rest.hasPrefix("/*") { block = true; i = source.index(i, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while i < source.endIndex, source[i] != "\n" { i = source.index(after: i) }
                continue
            }
            out.append(source[i]); i = source.index(after: i)
        }
        return out
    }
}

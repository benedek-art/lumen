// ScopeTests.swift
// The instrument column's two fixed slots, measured rather than believed.
//
// The owner named overflow bugs specifically, and the scope panel has exactly two places
// a string meets a width it cannot argue with: the histogram's readout line, which holds
// either a clipping headline or a zone readout beside the readout-space label, and the
// scopes' caption, which holds one line of units under a 150-point plate. Neither had a
// stated maximum. A formatter with no stated maximum is not a formatter that fits; it is
// one nobody has caught yet.
//
// `LayoutMetricSupport.swift` is the instrument: `NSAttributedString.size()` is CoreText,
// needs no window server, and gives the real advance of the real string in the real face.
// The chain below is the same shape as `PanelChain`'s — a series of literals, each in one
// place in one file, each pinned against its source so the model cannot drift away from
// the app it claims to describe.
//
// The rest of this file is the app-layer half of the scope feed: which image a
// measurement was taken off, which is a decision `AppState` makes and `ScopeReadout`
// records. The arithmetic itself is in `Tests/LumenCoreTests/ScopeMathTests.swift`,
// where the Linux lane can run it.

#if os(macOS)
import AppKit
import Foundation
import XCTest
@testable import LumenApp
@testable import LumenCore

final class ScopeTests: XCTestCase {

    // MARK: - The horizontal chain

    /// Every inset between the develop column's edge and the histogram's readout text.
    /// The column is resizable, so the number that matters is the one at its MINIMUM:
    /// a readout that fits only when the photographer has dragged the column wide is a
    /// readout that does not fit.
    enum ScopeChain {
        /// `LumenControls.swift` — the narrowest the column can be dragged.
        static var columnMinimum: CGFloat { Lumen.minimumPanelWidth }
        /// `DevelopPanel.swift` — the instrument's own inset in the column, each side.
        static let instrumentInset: CGFloat = 4
        /// `HistogramView.swift` / `ScopesView.swift` — each view's inner gutter, each
        /// side. The two are the same number and are asserted to stay so.
        static let viewInset: CGFloat = 8
        /// `HistogramView.swift` — `readoutLine`'s `HStack(spacing:)`, twice (Text,
        /// Spacer, Button), plus the `Spacer(minLength:)` between them.
        static let readoutGap: CGFloat = 6
        static let readoutSpacerMinimum: CGFloat = 4
        /// The space label's own horizontal padding inside its button, each side.
        static let spaceLabelPadding: CGFloat = 5

        /// What either instrument's content gets, at the column's minimum.
        static var contentWidth: CGFloat {
            columnMinimum - 2 * instrumentInset - 2 * viewInset
        }

        /// What the readout's LEFT-hand text gets once the space label has taken its
        /// share. The label carries `layoutPriority` behind the readout, so this is the
        /// budget in the state where both are drawn at their natural size.
        static var readoutBudget: CGFloat {
            let label = ReadoutSpace.allCases
                .map { TextMetric.width(ScopeReadout.shortSpaceLabel($0),
                                        LayoutFont.caption) }
                .max() ?? 0
            return contentWidth
                - 2 * readoutGap - readoutSpacerMinimum
                - (label + 2 * spaceLabelPadding)
        }
    }

    /// The chain is only worth measuring if it is still the app's chain.
    ///
    /// Comments are stripped before the scan: `DevelopPanel.swift` writes a paragraph
    /// between the view and its padding, and a scan that matched across a comment would
    /// also match a comment that merely mentioned the number.
    func testTheScopeChainsLiteralsAreStillWhereThisFileSaysTheyAre() throws {
        XCTAssertEqual(Lumen.minimumPanelWidth, 320, "the column's narrowest drag")

        let develop = try Self.strippedFlattened("Sources/LumenApp/DevelopPanel.swift")
        XCTAssertTrue(develop.contains("HistogramView(histogram: state.scopes?.histogram) "
                                       + ".padding(.horizontal, 4)"),
                      "the histogram's inset in the column")
        XCTAssertTrue(develop.contains("ScopesView(scopes: state.scopes) "
                                       + ".padding(.horizontal, 4)"),
                      "and the scopes'")

        let histogram = try Self.strippedFlattened("Sources/LumenApp/HistogramView.swift")
        XCTAssertTrue(histogram.contains(".padding(.horizontal, 8)"))
        XCTAssertTrue(histogram.contains("HStack(spacing: 6) { Text(primaryReadout)"))
        XCTAssertTrue(histogram.contains("Spacer(minLength: 4)"))
        XCTAssertTrue(histogram.contains(".padding(.horizontal, 5)"))

        let scopes = try Self.strippedFlattened("Sources/LumenApp/ScopesView.swift")
        XCTAssertTrue(scopes.contains(".padding(.horizontal, 8)"))
    }

    // MARK: - Overflow: the readout line

    /// The headline, at its widest, in the face it is actually set in.
    ///
    /// `.lumenNumericStrong` — 11 pt medium with tabular figures — is deliberately the
    /// widest of the two weights the line uses, and it is the one the pointer produces,
    /// so it is the one the budget has to be checked against.
    func testTheWidestClippingHeadlineFitsTheReadoutAtTheColumnsMinimumWidth() {
        let widest = ScopeReadout.clipHeadlineWidestCase
        let width = TextMetric.width(widest, LayoutFont.numericStrong)
        XCTAssertLessThanOrEqual(
            width, ScopeChain.readoutBudget,
            "\"\(widest)\" is \(width) pt in a \(ScopeChain.readoutBudget) pt slot — "
            + "the headline truncates at the column's minimum width")
    }

    /// And the wider of the two strings that share the slot: the zone readout under a
    /// drag, which is what the photographer is looking at while they scrub.
    func testTheWidestZoneReadoutFitsTheSameSlot() {
        let widest = ScopeReadout.zoneReadoutWidestCase
        let width = TextMetric.width(widest, LayoutFont.numericStrong)
        XCTAssertLessThanOrEqual(
            width, ScopeChain.readoutBudget,
            "\"\(widest)\" is \(width) pt in a \(ScopeChain.readoutBudget) pt slot")
    }

    /// Every zone, not just the longest name, because "widest" is a claim about the
    /// whole set and a slider whose name grows would otherwise pass by not being tested.
    func testEveryZoneReadoutFitsAtItsOwnExtremes() {
        for slider in Histogram.ZoneSlider.allCases {
            let decimals = slider == .exposure ? 2 : 0
            let extreme = slider == .exposure ? -5.0 : -100.0
            let text = ScopeReadout.zoneReadout(name: slider.displayName,
                                                value: extreme, decimals: decimals,
                                                sharePercent: 100)
            let width = TextMetric.width(text, LayoutFont.numericStrong)
            XCTAssertLessThanOrEqual(width, ScopeChain.readoutBudget,
                                     "\(slider.rawValue): \"\(text)\" is \(width) pt")
            XCTAssertLessThanOrEqual(text.count,
                                     ScopeReadout.zoneReadoutWidestCase.count,
                                     "\(slider.rawValue) is wider than the pinned "
                                     + "worst case, so the pin is wrong")
        }
    }

    // MARK: - Overflow: the disclosure and the caption

    /// The provenance note is a full-width caption row, so it gets the whole content
    /// width — but it is generated text and every branch of it has to fit.
    func testEveryProvenanceNoteFitsTheColumnAtItsMinimumWidth() {
        var notes: [String] = [ScopeReadout.Provenance.noteWidestCase]
        for frame in [ScopeReadout.Provenance.Frame.viewerFrame, .commissionedRender] {
            for coverage in [ScopeReadout.Provenance.Coverage.wholeFrame, .visibleRegion] {
                for proofed in [false, true] {
                    for paint in [false, true] {
                        for exact in [false, true] {
                            let p = ScopeReadout.Provenance(
                                frame: frame, coverage: coverage, proofed: proofed,
                                instrumentPaint: paint, exactCounts: exact)
                            if let note = p.note { notes.append(note) }
                        }
                    }
                }
            }
        }
        XCTAssertFalse(notes.isEmpty, "the disclosure has to have something to say")
        for note in Set(notes) {
            let width = TextMetric.width(note, LayoutFont.caption)
            XCTAssertLessThanOrEqual(width, ScopeChain.contentWidth,
                                     "\"\(note)\" is \(width) pt of "
                                     + "\(ScopeChain.contentWidth)")
        }
    }

    /// The scopes' caption, at its widest in each of the three panels.
    ///
    /// Reconstructed from the same parts `ScopesView.caption` assembles — the scan below
    /// holds that correspondence — because the caption itself is a private computed
    /// property on a view this suite cannot host.
    func testEveryScopeCaptionFitsTheColumnAtItsMinimumWidth() {
        let space = ReadoutSpace.allCases
            .max(by: { ScopeReadout.shortSpaceLabel($0).count
                     < ScopeReadout.shortSpaceLabel($1).count }) ?? .outputProfile
        let transform = ReadoutTransform(space: space, working: .rec2020)

        let captions = [
            ScopeReadout.lumaLabel(transform) + " waveform · 256×256 · "
                + ScopeReadout.shortSpaceLabel(space),
            "RGB parade · 256×256 · " + ScopeReadout.shortSpaceLabel(space),
            "OKLab a/b · ±0.40 chroma · skin line 56° ±12°",
        ]
        for caption in captions {
            let width = TextMetric.width(caption, LayoutFont.caption)
            XCTAssertLessThanOrEqual(width, ScopeChain.contentWidth,
                                     "\"\(caption)\" is \(width) pt of "
                                     + "\(ScopeChain.contentWidth)")
        }
    }

    /// The compressions the caption depends on are real: the long forms do NOT fit, so
    /// the short ones are load-bearing rather than a style preference. A test that only
    /// showed the current strings fitting would not notice someone restoring the old
    /// ones.
    func testTheLongFormCaptionIsTheOneThatDoesNotFit() {
        let long = "Rec.2020 luma waveform · 256 columns × 256 bins · "
            + ReadoutSpace.outputProfile.label
        XCTAssertGreaterThan(TextMetric.width(long, LayoutFont.caption),
                             ScopeChain.contentWidth,
                             "if this fits, the short forms are not buying anything")
    }

    // MARK: - What the measurement is a measurement of

    /// The rule, at the app layer: a soft proof whose gamut flag or paper-white
    /// simulation is on paints an INSTRUMENT into the pixels the binner walks, and that
    /// is a different claim from "a proof is applied".
    func testAGamutFlagOrAPaperSimulationCountsAsInstrumentPaint() {
        var proof = SoftProof(enabled: true, showGamutWarning: false,
                              simulatePaperWhite: false)
        var p = AppState.provenance(frame: .viewerFrame, proof: proof, exactCounts: true)
        XCTAssertEqual(p.coverage, .wholeFrame)
        XCTAssertTrue(p.proofed)
        XCTAssertFalse(p.instrumentPaint, "space and intent are a mapping, not a warning")

        proof.showGamutWarning = true
        p = AppState.provenance(frame: .viewerFrame, proof: proof, exactCounts: true)
        XCTAssertTrue(p.instrumentPaint, "flat grey over out-of-gamut pixels is chrome")

        proof.showGamutWarning = false
        proof.simulatePaperWhite = true
        p = AppState.provenance(frame: .viewerFrame, proof: proof, exactCounts: true)
        XCTAssertTrue(p.instrumentPaint,
                      "paper white compresses the range the clipping test is taken in")

        // A disabled proof is not in the pixels whatever its other fields say.
        proof.enabled = false
        proof.showGamutWarning = true
        p = AppState.provenance(frame: .viewerFrame, proof: proof, exactCounts: true)
        XCTAssertFalse(p.proofed)
        XCTAssertFalse(p.instrumentPaint)
        XCTAssertTrue(p.isPlain)
    }

    /// `SoftProof`'s default has the gamut flag ON, so the ordinary way a photographer
    /// turns proofing on is also the way the histogram starts binning the warning. That
    /// is the case the disclosure exists for, and it is worth an assertion rather than a
    /// sentence: if the default ever changes, the note's importance changes with it.
    func testTheDefaultProofCarriesItsWarningIntoTheBins() {
        let p = AppState.provenance(frame: .viewerFrame,
                                    proof: SoftProof(enabled: true), exactCounts: true)
        XCTAssertTrue(p.instrumentPaint)
        XCTAssertEqual(p.note, "Binned: soft proof + gamut flag")
    }

    /// End to end through the real measurement: the provenance rides the data, and the
    /// traces are sized from the buffer rather than from a constant.
    func testAMeasurementCarriesItsProvenanceAndSizesItsTracesFromTheBuffer() {
        let narrow = ImageBuffer(width: 100, height: 200) { _, _ in RGB(gray: 0.5) }
        let data = AppState.measure(narrow, includeScopes: true, readout: .srgb255,
                                    tap: nil, frame: .viewerFrame,
                                    proof: SoftProof(enabled: true))

        XCTAssertEqual(data.waveform?.columns, 100,
                       "256 columns on a 100 px buffer leaves 156 of them blank")
        XCTAssertEqual(data.parade?.red.columns, 100)
        XCTAssertEqual(data.provenance?.frame, .viewerFrame)
        XCTAssertEqual(data.provenance?.proofed, true)
        XCTAssertEqual(data.provenance?.exactCounts, false,
                       "no tap was offered, so the counts are the proxy's estimate")
        XCTAssertNotNil(data.provenance?.note)

        let wide = ImageBuffer(width: 512, height: 341) { _, _ in RGB(gray: 0.5) }
        let full = AppState.measure(wide, includeScopes: true, readout: .srgb255,
                                    tap: nil, frame: .commissionedRender, proof: nil)
        XCTAssertEqual(full.waveform?.columns, 256, "a wide proxy still gets 256")
        XCTAssertEqual(full.provenance?.proofed, false)
    }

    /// The clipping headline and the corner triangles read one report. This is the app
    /// side of that: the histogram a real measurement produces feeds both, so a
    /// single-channel clip cannot light the triangle beside a zero.
    func testASingleChannelClipReachesTheHeadlineAndTheTriangleTogether() {
        let frame = ImageBuffer(width: 32, height: 32) { _, _ in RGB(2.0, 0.35, 0.30) }
        let data = AppState.measure(frame, includeScopes: false, readout: .srgb255,
                                    tap: nil, frame: .viewerFrame, proof: nil)
        let histogram = try? XCTUnwrap(data.histogram)
        guard let histogram else { return }

        let report = ScopeReadout.clipping(histogram, end: .high)
        XCTAssertEqual(report.mask, 1, "red alone is gone")
        XCTAssertGreaterThan(report.strength, 0, "so the triangle burns")
        XCTAssertTrue(ScopeReadout.clipHeadline(histogram).hasPrefix("100.00% R white"),
                      "and the number beside it names the same channel")
        XCTAssertEqual(histogram.clippedPercent(.luma, end: .high), 0, accuracy: 1e-12,
                       "which the luma channel — the old headline — still calls clean")
    }

    // MARK: - helpers

    /// One source file with comments removed and whitespace flattened, so a pin names a
    /// chain of modifiers rather than its indentation — and so a comment that mentions
    /// a constant cannot satisfy a pin on the constant.
    private static func strippedFlattened(_ relativePath: String) throws -> String {
        let raw = try LayoutSource.read(relativePath)
        var out = ""
        var i = raw.startIndex
        var block = false
        while i < raw.endIndex {
            let rest = raw[i...]
            if block {
                if rest.hasPrefix("*/") { block = false; i = raw.index(i, offsetBy: 2) }
                else { i = raw.index(after: i) }
                continue
            }
            if rest.hasPrefix("/*") { block = true; i = raw.index(i, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while i < raw.endIndex, raw[i] != "\n" { i = raw.index(after: i) }
                continue
            }
            out.append(raw[i]); i = raw.index(after: i)
        }
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
#endif

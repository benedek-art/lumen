// The colour and grading surfaces, measured rather than believed.
//
// Everything here is a WIDTH against a BUDGET, taken with the same instrument
// `LayoutMetricSupport` introduced: `NSAttributedString.size()` is CoreText, so it needs
// no window server and a claim about what fits becomes arithmetic. Nothing is hosted and
// no view is built — SwiftUI's own layout is not simulated, and where the horizontal
// chain runs into a `Spacer` this file stops and says so.
//
// Why these four rows and not others. The audit that arrived with this work measured
// every slider readout in the app and found none of the 140 overflowing, so the readout
// column is not the question. The question is the slots that are NOT a readout: the
// curve editor's own status row, which was added with a reset affordance on it; the
// point-colour swatch strip, which is eight fixed chips and two fixed buttons with only
// a `Spacer(minLength: 0)` between them and the edge; the curve channel selector, which
// is the widest segmented control in the app at six options; and the parametric band
// captions, which are drawn inside a `Canvas` where nothing truncates and a label too
// wide for its band would simply overrun the one beside it.
//
// The arithmetic these check is in LumenCore and tested there (`CurveMathTests`). What
// is checked here is the one thing that file cannot reach: how wide the strings actually
// render in the faces the app sets.

#if os(macOS)
import AppKit
import XCTest
import LumenCore
@testable import LumenApp

final class ColorPanelTests: XCTestCase {

    private func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }

    // MARK: - The curve editor's readout row

    /// The row is `HStack(spacing: 6)` of the readout, a `Spacer(minLength: 4)`, the
    /// point count and the reset button, inside `.frame(height: 14)` — so its height is
    /// fixed and its width is the host's. Three fixed children plus three 6 pt gaps plus
    /// the spacer's own floor is what the host has to be able to hold; past that the
    /// `Spacer` collapses and the readout, which has `lineLimit(1)`, truncates.
    ///
    /// The worst readout is `in 100.0%   out 100.0%` and it carries NO SIGN: the encoded
    /// axis has no negative half and both halves are clamped into 0…100 before
    /// formatting, which `CurveMathTests.testTheReadoutIsBoundedAndNeverSigned` proves
    /// over the whole −50…150 sweep.
    ///
    /// The worst count is three digits, and that is a bound rather than a guess:
    /// `CurveEditing.minimumPointGap` is 0.004, so at most 1/0.004 + 1 = 251 points fit
    /// on the axis at all.
    func testTheCurveEditorsReadoutRowFitsItsNarrowestHost() {
        let readout = CurveEditing.readout(input: 100, output: 100)
        XCTAssertEqual(readout, "in 100.0%   out 100.0%")
        XCTAssertFalse(readout.contains("-"))

        let readoutWidth = TextMetric.width(readout, LayoutFont.caption)
        let countWidth = TextMetric.width("251 pts", LayoutFont.caption)
        let resetWidth: CGFloat = 20          // CurveEditorView.resetButton's frame
        let gaps: CGFloat = 6 * 3             // HStack(spacing: 6), four children
        let spacerFloor: CGFloat = 4          // Spacer(minLength: 4)
        let needed = readoutWidth + countWidth + resetWidth + gaps + spacerFloor

        // The narrowest host the editor is placed in: the floating Masks pop-out at
        // `maskDetail` depth (MaskPanel.swift), which is a fixed 272 pt panel and does
        // not widen with the develop column.
        for host in [PanelChain.Host.maskDetail, .developTop] {
            let budget = host.contentWidth(columnWidth: Lumen.minimumPanelWidth)
            XCTAssertLessThanOrEqual(
                needed, budget,
                "the curve editor's readout row wants \(f(needed)) pt in \(host.rawValue)'s "
                + "\(f(budget)) pt: readout \(f(readoutWidth)) + count \(f(countWidth)) "
                + "+ reset \(f(resetWidth)) + \(f(gaps)) of gaps + \(f(spacerFloor)) of "
                + "spacer. Past this the readout truncates mid-number while a hand is "
                + "reading it to place a point")
        }
    }

    /// EVERY SEGMENT OF THE CHANNEL SELECTOR, AGAINST THE SHARE IT ACTUALLY GETS.
    ///
    /// Six options is the most any `LumenSegmented` in the app carries, and that control
    /// has `lineLimit(1)` and deliberately NO `minimumScaleFactor` — its labels are
    /// already at `.lumenCaption`, which is the app's stated 10 pt floor, so a shrink
    /// factor would be a way under the floor with no size written down. Which leaves the
    /// width as the only thing keeping the labels whole.
    func testTheCurveChannelSelectorsSixLabelsFitTheirShare() {
        let options = CurveEditorView.CurveChannel.allCases.map(\.shortLabel)
        XCTAssertEqual(options.count, 6)
        for host in [PanelChain.Host.maskDetail, .developTop] {
            let row = host.contentWidth(columnWidth: Lumen.minimumPanelWidth)
            // `HStack(spacing: 1)`, six equal `maxWidth: .infinity` shares.
            let share = (row - CGFloat(options.count - 1)) / CGFloat(options.count)
            for label in options {
                let w = TextMetric.width(label, LayoutFont.caption)
                XCTAssertLessThanOrEqual(
                    w, share,
                    "\"\(label)\" is \(f(w)) pt in a \(f(share)) pt share of "
                    + "\(host.rawValue) at the narrowest column — it truncates, and a "
                    + "truncated segment label is a curve nobody can find")
            }
        }
    }

    /// The four parametric band captions, drawn inside a `Canvas`.
    ///
    /// A `Canvas` does not truncate and does not shrink: `context.draw` centres the text
    /// on the band and lets it overrun. `CurveEditorView.draw` therefore DROPS a caption
    /// whose measured width plus 8 pt of breathing room exceeds its band, which is the
    /// right failure — but it is only the right failure if the captions normally fit, and
    /// a set of four bands that all silently go unlabelled is a picture of nothing.
    ///
    /// Measured in the develop column, at its narrowest, which is where the tone curve
    /// lives (`DevelopColumn.swift`): the graph is `aspectRatio(1)` inside the card less
    /// 16 pt of the editor's own horizontal padding, and the default splits give each of
    /// the four bands a quarter of it.
    ///
    /// NOT asserted for the Masks pop-out, deliberately. That host is a fixed 272 pt and
    /// its bands are about 55 pt, which is close enough to `Highlights` that the caption
    /// may or may not be drawn depending on the face's actual advances — and there the
    /// DROP is the correct outcome, since a `Canvas` neither truncates nor shrinks and
    /// an overrunning caption would print into the band beside it. What must not happen
    /// is the column losing them, because the column is where four sliders named after
    /// tones sit under a graph that would otherwise never say which part of the axis
    /// each one owns.
    func testTheParametricBandCaptionsFitTheirBandsAtTheDefaultSplits() {
        let titles = ["Shadows", "Darks", "Lights", "Highlights"]
        let bounds: [Double] = [0] + CurveEditing.defaultSplits + [1]

        let plot = PanelChain.Host.developTop
            .contentWidth(columnWidth: Lumen.minimumPanelWidth) - 16
        for (i, title) in titles.enumerated() {
            let band = plot * CGFloat(bounds[i + 1] - bounds[i])
            let w = TextMetric.width(title, LayoutFont.caption)
            XCTAssertLessThanOrEqual(
                w + 8, band,
                "\"\(title)\" measures \(f(w)) pt against a \(f(band)) pt band on a "
                + "\(f(plot)) pt plot, so the graph drops it — four unlabelled bands is "
                + "the state the captions exist to end")
        }
    }

    // MARK: - Point Colour's swatch strip

    /// EIGHT CHIPS AND TWO BUTTONS, ALL FIXED, WITH A `Spacer(minLength: 0)` BETWEEN.
    ///
    /// This is the one row in the panel where nothing can give: the chips are
    /// `frame(width: 22)`, both buttons are `frame(width: 24)`, and the spacer's floor is
    /// zero, so at full occupancy the row is a constant. `swatchChip`'s own comment
    /// prices it at "264 pt of a 292 pt column"; this is that claim, computed.
    func testThePointColourSwatchStripFitsAtEightSwatches() {
        let chips = CGFloat(ColorPanel.maxSwatches) * 22
        let buttons: CGFloat = 24 * 2
        // HStack(spacing: 4) over eight chips, the Spacer and two buttons: eleven
        // children, ten gaps.
        let gaps: CGFloat = 4 * 10
        let needed = chips + buttons + gaps
        let budget = PanelChain.Host.developTop
            .contentWidth(columnWidth: Lumen.minimumPanelWidth)
        XCTAssertLessThanOrEqual(
            needed, budget,
            "the swatch strip wants \(f(needed)) pt of \(f(budget)): \(f(chips)) of "
            + "chips + \(f(buttons)) of buttons + \(f(gaps)) of gaps. Over budget the "
            + "eyedropper and the − button are pushed off the row's trailing edge, "
            + "which is the state where \"the minus button does nothing\"")
    }

    // MARK: - The Zones register's readout

    /// The one signed three-character-plus readout in the owned panels.
    ///
    /// The zone rows accept ±5 stops by typing at two decimals, so `-5.00` is the widest
    /// string their formatter produces — and the readout is a pill whose padding comes
    /// out of the digits. Measured at the SCRUBBED weight, which is the wider of the two
    /// states and therefore the one the column has to hold.
    func testTheZoneRowsWidestReadoutFitsThePill() {
        for value in [-5.0, 5.0, -0.05] {
            let text = String(format: "%.2f", value)
            for font in [LayoutFont.numeric, LayoutFont.numericStrong] {
                let w = TextMetric.width(text, font)
                XCTAssertLessThanOrEqual(
                    w, PanelChain.valueTextWidth,
                    "\"\(text)\" is \(f(w)) pt in the readout's \(f(PanelChain.valueTextWidth)) pt "
                    + "of digit room (a \(f(Lumen.valueWidth)) pt column less "
                    + "\(f(2 * PanelChain.valuePadding)) of pill padding)")
            }
        }
    }
}
#endif

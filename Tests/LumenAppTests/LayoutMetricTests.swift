// Layout, MEASURED. The first test in this project that can see a UI bug.
//
// Every other UI check here is a text scan: grep for a constant, count a call site,
// assert a modifier is present. A text scan can prove `Lumen.labelWidth` is 86. It
// cannot answer the only question that matters about an 86-point column — does the word
// fit — because that question is about type advances and a grep has never measured one.
// So every "and every label in the app fits" in `LumenControls.swift`, every "measures
// about 399 pt" in `LookPanel.swift`, every fit table in the panel audit, is an estimate
// that has never been checked against a font.
//
// It can be checked. `NSAttributedString.size()` and `NSFont` are CoreText, not AppKit
// drawing: they need no window server, so they work on a headless macOS runner. This
// suite therefore measures the real strings in the real faces at the real sizes, runs
// them through the real horizontal chain of insets, and asserts numbers.
//
// The rule this suite is written under, because it is the failure mode it exists to end:
// A THRESHOLD IS NEVER SOFTENED TO MAKE THE SUITE GREEN. Every floor below is quoted
// from the source that states it — the "~1.0" in `LumenControls.swift`, the "10 is the
// floor" in `LumenType.swift`, the 56 pt the glyph row's own comment promises — and
// where today's tree does not clear one, the test fails and names the row. An instrument
// calibrated to agree with the thing it is measuring is not an instrument.
//
// `LayoutMetricSupport.swift` holds the inventory, the chain, and the pins that keep the
// chain honest.

#if os(macOS)
import AppKit
import XCTest
@testable import LumenApp
@testable import LumenCore

/// `@MainActor` for the same reason `PanelLayoutBroadcastTests` is: several of the
/// statics these measurements read hang off SwiftUI `View` types, and a test that has
/// to reason about which of them the compiler considers isolated is a test that will
/// break on a toolchain bump for a reason unrelated to layout. Nothing here is slow
/// enough for the hop to cost anything.
@MainActor
final class LayoutMetricTests: XCTestCase {

    // MARK: - Reporting

    /// Fails with a table rather than with a boolean.
    ///
    /// A layout failure is a list — nine rows are too narrow, two labels truncate — and
    /// `XCTAssertLessThan` on the first one hides the other eight. Every check here
    /// gathers its whole census first and prints it, so one run of the lane tells you
    /// the entire state of the panel rather than the first row of it.
    private func report(_ failures: [String], of total: Int, _ claim: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        guard !failures.isEmpty else { return }
        let body = failures.joined(separator: "\n  ")
        XCTFail("""
        \(claim)
        \(failures.count) of \(total) fail:
          \(body)
        """, file: file, line: line)
    }

    private func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
    private func f3(_ v: Double) -> String { String(format: "%.3f", v) }

    // MARK: - (a) The label column

    /// THE 56 POINT CLAIM, which has never been measured.
    ///
    /// `LumenControls.swift` prices the behaviour glyph in one sentence: the glyph is
    /// drawn inside the label column's own budget rather than beside it, "at 44 wide it
    /// took 48 of the 86 and left 38, six characters, which is why 'Follow edges'
    /// rendered 'Follo…'. At `inRowWidth` the name keeps 56 and every label in the app
    /// fits." The first half of that is arithmetic anybody can check. The second half is
    /// a claim about nine strings in a typeface, and this is the first time it has been
    /// put to a font.
    ///
    /// The threshold is truncation, not fit: the row carries `.minimumScaleFactor(0.86)`,
    /// so a name up to 56/0.86 = 65.1 points wide still renders whole, smaller. Past that
    /// the tail is cut, which is the exact defect — two controls reading the same
    /// truncated stem — the column was widened to 94 to avoid in the first place.
    func testEveryGlyphBearingLabelFitsTheFiftySixPointBudget() {
        let rows = SliderInventory.all.filter(\.hasGlyph)
        XCTAssertFalse(rows.isEmpty, "the glyph rows are the subject; an empty set proves nothing")

        var failures: [String] = []
        for row in rows {
            let fit = TextMetric.fit(row.title, LayoutFont.body,
                                     budget: PanelChain.glyphLabelBudget,
                                     minimumScaleFactor: PanelChain.labelScaleFloor)
            guard fit.truncates else { continue }
            failures.append("\(row.title) — \(row.site): \(f(fit.nominal)) pt nominal, "
                            + "\(f(fit.nominal * PanelChain.labelScaleFloor)) pt at the 0.86 "
                            + "shrink floor, against a \(f(fit.budget)) pt budget — TRUNCATES")
        }
        report(failures, of: rows.count,
               "LumenControls.swift: \"At `inRowWidth` the name keeps 56 and every label "
               + "in the app fits.\"")
    }

    /// The same question for the rows with no glyph, where the budget is the whole
    /// 86 pt column — or 74 of it once `indented: true` has taken its 12.
    ///
    /// `LumenControls.swift` claims this one too: "86 fits every name that exists — the
    /// four denoise labels that forced 94 (`Luminance Contrast` and friends) measure
    /// under 84 at 11 pt SF Pro". Those four have since been renamed under their masters,
    /// which is the cheap half of the fix the panel audit asked for; what this asks is
    /// whether the OTHER eighty-odd names clear it.
    func testEveryPlainLabelFitsTheLabelColumnWithoutTruncating() {
        let rows = SliderInventory.all.filter { !$0.hasGlyph && !$0.title.isEmpty }
        var failures: [String] = []
        for row in rows {
            let fit = TextMetric.fit(row.title, LayoutFont.body,
                                     budget: row.labelBudget,
                                     minimumScaleFactor: PanelChain.labelScaleFloor)
            guard fit.truncates else { continue }
            failures.append("\(row.title) — \(row.site): \(f(fit.nominal)) pt nominal, "
                            + "\(f(fit.nominal * PanelChain.labelScaleFloor)) pt shrunk, "
                            + "budget \(f(fit.budget))\(row.indented ? " (indented)" : "") "
                            + "— TRUNCATES")
        }
        report(failures, of: rows.count,
               "LumenControls.swift: \"86 fits every name that exists.\"")
    }

    /// SHRINKING IS NOT FITTING once it goes under the app's own floor.
    ///
    /// `.minimumScaleFactor(0.86)` is defended in `LumenControls.swift` as "a name that
    /// renders 8% smaller on four rows out of ninety-two", which is a fair price. What
    /// it is not licensed to do is take a label under the 10 pt `LumenType.swift` sets
    /// as the minimum — "there were 46 sites at 9pt in a build whose own design audit had
    /// already set 10 as the minimum and never enforced it" — because that is the
    /// enforcement, and a shrink is a way of getting under it without writing a size
    /// down anywhere.
    ///
    /// At 11 pt body, 0.86 is 9.46 pt. So the floor and the shrink factor are in direct
    /// contradiction for any label that uses the whole of the shrink: this test is what
    /// makes that contradiction visible on the rows where it actually bites.
    func testNoLabelShrinksBelowTheAppsOwnTypeFloor() {
        var failures: [String] = []
        for row in SliderInventory.all where !row.title.isEmpty {
            let fit = TextMetric.fit(row.title, LayoutFont.body,
                                     budget: row.labelBudget,
                                     minimumScaleFactor: PanelChain.labelScaleFloor)
            guard !fit.truncates, fit.renderedSize < LayoutFont.legibilityFloor else { continue }
            failures.append("\(row.title) — \(row.site): \(f(fit.nominal)) pt in a "
                            + "\(f(fit.budget)) pt column renders at \(f(fit.renderedSize)) pt, "
                            + "under the \(f(LayoutFont.legibilityFloor)) pt floor")
        }
        report(failures, of: SliderInventory.all.count,
               "LumenType.swift: \"10 is the floor.\"")
    }

    /// The Printer Lights rows are the one label column in the app with NO shrink at all
    /// — `PrinterLightRow` sets `.lineLimit(1)` and no `minimumScaleFactor` — so their
    /// threshold is the bare 86 and a single point over is a truncation.
    func testThePrinterLightLabelsFitWithNoShrinkToFallBackOn() {
        var failures: [String] = []
        for title in ["Master", "Red / Cyan", "Green / Mag", "Blue / Yellow"] {
            let w = TextMetric.width(title, LayoutFont.body)
            guard w > Lumen.labelWidth else { continue }
            failures.append("\(title) — LookPanel.swift:1615: \(f(w)) pt against "
                            + "\(f(Lumen.labelWidth)) pt, and this row has no "
                            + "minimumScaleFactor — TRUNCATES")
        }
        report(failures, of: 4,
               "PrinterLightRow draws its label in a fixed 86 pt frame with lineLimit(1) "
               + "and no shrink.")
    }

    // MARK: - (b) The track

    /// The floor `LumenControls.swift` states in its own words, applied at the width its
    /// own argument defends.
    ///
    /// The sentence used to read "At 320 a ±100 control had 0.90 points of travel per
    /// unit — under the ~1.0 at which a one-pixel tremor stops costing a whole unit… At
    /// 380 it is 1.24, past Lightroom's default", and both of those figures were stale:
    /// they predate `WorkspaceSectionView`'s card gutter (−20) and `valueWidth` going
    /// 44 → 52 for the readout pill (−8 on every row in the app). The measured pair is
    /// **0.710 and 1.010**, and `Lumen.defaultPanelWidth`'s comment now says so — which
    /// is a repair rather than a concession: a comment that overstates the instrument by
    /// 23% is how a panel gets narrowed twice.
    ///
    /// WHAT THIS CENSUS STILL FAILS ON, AND WHY THE FLOOR IS NOT MOVING. Forty-two of
    /// the 142 rows are under 1.0 at the default, and they are not a layout problem:
    /// they are the fine-quantum rows — Exposure's 0.01 EV over ±5 is 1,000 steps and
    /// would want 1,000 points of track, which no width this app permits comes near. The
    /// answer to those is the readout's own scrub, and
    /// `testEveryValueTheReadoutAdvertisesIsReachableBySomeGesture` is where that
    /// answer is checked. So this census reads as a REPORT with a floor attached: the
    /// floor is quoted from the source and stays quoted, and the message below prints
    /// the whole ordered list so a reader can see which rows are the ±100 class the
    /// claim is about and which are the fine-quantum rows it never covered. Narrowing
    /// the census to the class the sentence names is a decision about what the product
    /// promises; it is not a decision to take by editing a threshold until a run is
    /// green.
    func testTheCoarseTrackClearsThePrecisionFloorAtTheDefaultPanelWidth() {
        let failures = precisionCensus(columnWidth: Lumen.defaultPanelWidth)
        report(failures, of: SliderInventory.all.count,
               "LumenControls.swift: the default width exists to buy \"~1.0\" points of "
               + "track travel per unit.\n"
               + chainSummary(columnWidth: Lumen.defaultPanelWidth))
    }

    /// The same floor at the narrowest the column can be dragged to.
    ///
    /// This one is the panel audit's finding G1-02 restated: the column is resizable, the
    /// minimum is a state a photographer can actually be in, and a control that cannot
    /// address its own integers there is broken there.
    ///
    /// 99 of the 142 rows are under the floor here, against 42 at the default, and the
    /// 57 that separate the two censuses are the 200-step class: 0.710 pt per unit at 320,
    /// 1.010 at 380. `Lumen.defaultPanelWidth` now states that gap in the place the
    /// promise is made, because the honest reading of these two numbers is that the
    /// floor is bought by the width the panel OPENS at and spent again by dragging it in
    /// — and a photographer who drags it in is trading precision for room knowingly,
    /// which is a different thing from a control that arrives broken.
    func testTheCoarseTrackClearsThePrecisionFloorAtTheMinimumPanelWidth() {
        let failures = precisionCensus(columnWidth: Lumen.minimumPanelWidth)
        report(failures, of: SliderInventory.all.count,
               "LumenControls.swift: \"under the ~1.0 at which a one-pixel tremor stops "
               + "costing a whole unit\".\n"
               + chainSummary(columnWidth: Lumen.minimumPanelWidth))
    }

    /// The single number finding G1-02 turns on, isolated so it cannot hide inside a
    /// census: a ±100 control inside a `DevelopDisclosure` at the narrowest column.
    ///
    /// `LumenControls.swift` records what this geometry did the last time it happened, in
    /// the comment on `labelWidth`: at 142 points of track and 0.71 points per unit,
    /// "58 of the 201 integer values could not be landed on by dragging at all", and the
    /// owner reported it as "limited to being able to touch it up slightly". That is a
    /// description of arithmetic, and this is the arithmetic.
    ///
    /// THE FOLD TERM IS ZERO NOW AND THE SHORTFALL IS UNCHANGED, which is the useful
    /// thing this test has to say today. The disclosure's 16 points came back to the
    /// track (`PanelChain.disclosureInset`), so a fold no longer costs a row anything and
    /// a ±100 control inside one went 126 → 142 pt, 0.630 → 0.710 pt per unit. It is
    /// still not 1.0, and no arrangement of insets can make it 1.0: 200 points of track
    /// wants 350 points of card content, which wants a 378-point column. What is left is
    /// a decision about `Lumen.minimumPanelWidth` — 320 today, 378 to make the floor
    /// hold at every width the drag reaches — and that decision belongs to whoever owns
    /// how narrow the column may be dragged, not to this file. The assertion stays where
    /// it is so the number stays visible; softening it to 0.71 would turn the instrument
    /// into a record of the tree it was run against.
    func testTheNarrowestTrackCanAddressEveryIntegerOfABipolarHundredControl() {
        let track = PanelChain.Host.developDisclosure
            .trackWidth(columnWidth: Lumen.minimumPanelWidth)
        let perUnit = Double(track) / 200
        let reachable = min(Double(track) + 1, 201).rounded(.down)
        // The column this row would need for 200 points of groove, so the failure names
        // the one lever left rather than only the shortfall.
        let neededColumn = 200 + PanelChain.sliderChrome + 2 * PanelChain.cardInset
            + 2 * PanelChain.scrollInset + 2 * PanelChain.disclosureInset
        XCTAssertGreaterThanOrEqual(
            perUnit, 1.0,
            "a ±100 slider in a fold at the minimum column has \(f(track)) pt of track "
            + "— \(f3(perUnit)) pt per unit, so only about \(Int(reachable)) of its 201 "
            + "integers are reachable by dragging. The chain: \(f(Lumen.minimumPanelWidth)) "
            + "column − \(f(2 * PanelChain.scrollInset)) scroll − "
            + "\(f(2 * PanelChain.cardInset)) card − "
            + "\(f(2 * PanelChain.disclosureInset)) fold − "
            + "\(f(PanelChain.sliderChrome)) row chrome "
            + "(label \(f(Lumen.labelWidth)) + 2×6 gaps + readout "
            + "\(f(Lumen.valueWidth))). Clearing it needs 200 pt of track, i.e. a "
            + "\(f(neededColumn)) pt column — every inset in the chain above is "
            + "already spent")
    }

    /// The two-instrument contract, which is the question the track alone cannot answer.
    ///
    /// `LumenControls.swift` opens by promising two gestures over one value: the groove
    /// is coarse, and "drag the NUMBER to scrub it — three track-widths of travel per
    /// full range, so the readout is the precision instrument". `FineDrag.scale` gives
    /// each of them a quarter gear under ⇧. So the honest reachability question is
    /// whether the BEST available gesture can land on every value the readout advertises,
    /// and a row where the answer is no is a row printing decimals nothing can reach.
    func testEveryValueTheReadoutAdvertisesIsReachableBySomeGesture() {
        var failures: [String] = []
        for row in SliderInventory.all {
            let track = row.trackWidth(columnWidth: Lumen.maximumPanelWidth)
            let best = SliderGesture.allCases
                .map { (gesture: $0,
                        perStep: $0.travel(trackWidth: track) / row.addressableSteps) }
                .max { $0.perStep < $1.perStep }
            guard let best, best.perStep < 1.0 else { continue }
            failures.append("\(row.title) — \(row.site): "
                            + "\(Int(row.addressableSteps)) steps of \(row.step) across "
                            + "\(row.range.lowerBound)…\(row.range.upperBound); best gesture "
                            + "\(best.gesture.name) at \(f3(best.perStep)) pt/step — even the "
                            + "widest column and the fine gear cannot land on them all")
        }
        report(failures, of: SliderInventory.all.count,
               "LumenControls.swift: \"the readout is the precision instrument and the "
               + "track is the coarse one\" — every advertised step must be reachable by "
               + "one of them.")
    }

    /// The census both floor tests print, sorted worst first so the message opens on the
    /// row that is furthest out rather than on whichever one sorts first alphabetically.
    private func precisionCensus(columnWidth: CGFloat) -> [String] {
        SliderInventory.all
            .map { (row: $0, perStep: $0.pointsPerStep(columnWidth: columnWidth)) }
            .filter { $0.perStep < 1.0 }
            .sorted { $0.perStep < $1.perStep }
            .map { entry in
                "\(f3(entry.perStep)) pt/step — \(entry.row.title) "
                + "(\(entry.row.site), \(entry.row.host.rawValue)): "
                + "\(f(entry.row.trackWidth(columnWidth: columnWidth))) pt of track over "
                + "\(Int(entry.row.addressableSteps)) steps of \(entry.row.step)"
            }
    }

    /// Titled hosts only: `Host.trackWidth` prices a label column, and the two wheel-bar
    /// hosts have no labelled row in them at all — printing them here would put a
    /// negative number in the middle of a summary of the chain.
    private func chainSummary(columnWidth: CGFloat) -> String {
        func untitled(_ host: PanelChain.Host) -> String {
            f(host.contentWidth(columnWidth: columnWidth) - PanelChain.untitledSliderChrome)
        }
        let titled = PanelChain.Host.allCases
            .filter(\.rowsAreTitled)
            .map { "\($0.rawValue) \(f($0.trackWidth(columnWidth: columnWidth)))" }
            .joined(separator: ", ")
        return "track at column \(f(columnWidth)): \(titled); untitled wheel bars "
            + "\(untitled(.gradeWheelBar)) / \(untitled(.maskWheelBar))"
    }

    // MARK: - (c) The value column

    /// EVERY READOUT, AT BOTH WEIGHTS, AGAINST THE DIGITS' ACTUAL ROOM.
    ///
    /// The readout is a pill now, and a pill's padding comes out of the digits: the
    /// column is `Lumen.valueWidth` wide and the text gets that minus
    /// `2 × PanelChain.valuePadding`. `LumenControls.swift` argues the raise from 44 to
    /// 52 on exactly one row — "the binding case is not the one you would guess. It is
    /// Black target — hard range 0…15 at three decimals, so `15.000`" — and this checks
    /// the other hundred and thirty.
    ///
    /// Three things the naive version of this test gets wrong, and why each is here:
    ///
    ///   · the HARD range, not the soft one. `-10.00` is typeable into Exposure even
    ///     though dragging pins at ±5, and a number you can enter is a number that has
    ///     to be legible once it is entered;
    ///   · the SCRUBBING weight. The readout goes `.lumenNumericStrong` — medium — while
    ///     it is being dragged, which is wider, and a column measured only at rest clips
    ///     exactly when a hand is on it;
    ///   · the sign only where the range is signed. Measuring `-50000` for a Kelvin
    ///     control that never goes negative would inflate every white-balance row by a
    ///     whole glyph and hide a real failure somewhere else.
    func testEveryReadoutFitsItsValueColumnAtBothWeights() {
        var failures: [String] = []
        for row in SliderInventory.all {
            let text = row.widestReadout
            let rest = TextMetric.width(text, LayoutFont.numeric)
            let scrubbing = TextMetric.width(text, LayoutFont.numericStrong)
            let widest = max(rest, scrubbing)
            guard widest > PanelChain.valueTextWidth else { continue }
            failures.append("\(row.title) — \(row.site): \"\(text)\" is \(f(rest)) pt at rest "
                            + "and \(f(scrubbing)) pt while scrubbing, against "
                            + "\(f(PanelChain.valueTextWidth)) pt of room "
                            + "(\(f(Lumen.valueWidth)) column − "
                            + "2×\(f(PanelChain.valuePadding)) pill padding) — OVERFLOWS "
                            + "by \(f(widest - PanelChain.valueTextWidth))")
        }
        report(failures, of: SliderInventory.all.count,
               "LumenControls.swift: the readout pill has to hold every string its own "
               + "formatter can produce.")
    }

    /// The Printer Lights readout, which is the app's one other fixed numeric slot and
    /// the only one that prints two units in one string.
    ///
    /// `PrinterLightRow.readout` composes `"\(points) pt · "` with `"%+.2f EV"`, in a
    /// hard 124 pt frame. Master's limit is `GradeEngine.masterPointLimit`, the trims'
    /// is `trimPointLimit`, and one point is exactly 1/12 stop — so the widest string is
    /// the master at full throw in both directions.
    func testThePrinterLightReadoutFitsItsFixedColumn() {
        let column: CGFloat = 124
        let limit = Int(GradeEngine.masterPointLimit)
        var failures: [String] = []
        for points in [limit, -limit] {
            let ev = String(format: "%+.2f EV", Double(points) / GradeEngine.pointsPerStop)
            let text = (points >= 0 ? "+" : "") + "\(points) pt · " + ev
            let w = TextMetric.width(text, LayoutFont.numeric)
            guard w > column else { continue }
            failures.append("\"\(text)\" is \(f(w)) pt against a \(f(column)) pt frame "
                            + "with no lineLimit — LookPanel.swift:1631")
        }
        report(failures, of: 2, "PrinterLightRow draws its readout in a fixed 124 pt frame.")
    }

    // MARK: - (d) Strings that come from data

    /// The film stock badge, which is what replaced the header that used to truncate.
    ///
    /// This is finding G1-05 in its fixed form. The header printed
    /// "Display Transform · replaced by Kodak Gold 200" as one line, which the file's own
    /// comment prices at "about 399 pt against the 223 the narrow column leaves"; it now
    /// prints "Display Transform" at full size with the stock in a `LumenBadge` pill.
    /// The name is stripped of its shared `Lumen ` prefix at `LookPanel.replacingStockName`
    /// for the few points that buys, so the badge measures the stripped form — and the
    /// header title is `.fixedSize(horizontal: true)`, meaning it will not compress: if
    /// this ever stops fitting, the row grows past its card rather than truncating.
    func testTheDisplayTransformHeaderAndEveryStockBadgeFitTheNarrowColumn() {
        let content = PanelChain.Host.developTop.contentWidth(columnWidth: Lumen.minimumPanelWidth)
        // LumenSectionHeader: 4 pt of horizontal padding each side; a 20 pt chevron, the
        // 5 pt modified dot and the "Reset" button, each with one 4 pt gap.
        let chrome: CGFloat = 8 + (20 + 4) + (5 + 4)
            + (TextMetric.width("Reset", LayoutFont.caption) + 4)
        let room = content - chrome
        let title = TextMetric.width("Display Transform", LayoutFont.heading)

        var failures: [String] = []
        for stock in FilmStock.all {
            let shown = stock.name.hasPrefix("Lumen ")
                ? String(stock.name.dropFirst(6)) : stock.name
            // LumenBadge: `.lumenCaption` with 6 pt of horizontal padding each side.
            let badge = TextMetric.width(shown, LayoutFont.caption) + 12
            let need = title + 4 + badge
            guard need > room else { continue }
            failures.append("\(stock.name) → badge \"\(shown)\" \(f(badge)) pt; with the "
                            + "\(f(title)) pt title that is \(f(need)) pt against \(f(room)) pt "
                            + "of header — OVER by \(f(need - room))")
        }
        report(failures, of: FilmStock.all.count,
               "LookPanel.swift: the stock's name moved into a badge so the header would "
               + "stop eating it (G1-05).")
    }

    /// The mask navigator's name slot, and the claim `MaskPanel.swift` makes about it:
    /// "the wider card leaves the name 132", where "'Radial Gradient 1' needs about 105,
    /// so every default name in the list arrived truncated" at the old width.
    ///
    /// Auto-names are `kindName + index`, so the widest is the widest kind with a
    /// two-digit index. The row DOES truncate (`.lineLimit(1).truncationMode(.tail)`), so
    /// nothing here overflows — what is being checked is the stronger promise the comment
    /// makes, that the default names fit whole.
    func testEveryDefaultMaskNameFitsTheNavigatorsNameSlot() {
        let slot: CGFloat = 132
        // `MaskKind` is not `CaseIterable` — it is a wire format, and the app keeps its
        // own rosters — so the roster is assembled from the panel's own three lists plus
        // the two kinds that are editable but no longer offered. Taking them from the
        // panel means a kind added to a menu is measured without anybody remembering to.
        let kinds = MaskPanel.drawnKinds + MaskPanel.rangeKinds + MaskPanel.aiKinds
            + [.depthRange, .maskRef]
        var failures: [String] = []
        for kind in kinds {
            let name = MaskPanel.kindName(kind) + " 12"
            let w = TextMetric.width(name, LayoutFont.body)
            guard w > slot else { continue }
            failures.append("\"\(name)\" is \(f(w)) pt against \(f(slot)) pt — truncates")
        }
        report(failures, of: kinds.count,
               "MaskPanel.swift: \"the wider card leaves the name 132\" and the default "
               + "names fit whole.")
    }

    /// `LumenSegmented` was the one control in the kit whose label carried NO `lineLimit`
    /// and no `minimumScaleFactor`, inside a `.frame(maxWidth: .infinity)` share.
    ///
    /// That meant it did not truncate when it ran out of room — it WRAPPED, and the whole
    /// segmented control grew a second line, which is a row-height change rather than a
    /// clipped word: it moves every control below it and reads as a rendering fault. The
    /// control carries `.lineLimit(1)` now, so the failure mode is a clipped tail instead
    /// of a taller panel.
    ///
    /// It gets no `minimumScaleFactor` to go with it, and that is why this test still
    /// matters rather than being retired by the fix. These labels are drawn at
    /// `.lumenCaption`, which is 10 pt, and `LumenType.swift`'s floor is 10 — there is no
    /// room to shrink into, so a segment label that outgrows its share has nothing to
    /// fall back on but truncation. The width is therefore the only thing keeping the
    /// words whole, and the width is what is measured here. Today every set clears its
    /// share (the widest is `Perceptual` at 50.7 in a 99.5 pt share); this is here so the
    /// day a longer option is added, the suite says so instead of the panel quietly
    /// eating a word.
    func testEverySegmentedControlsLabelsFitTheirShare() {
        // label set, the width the control is given, where it is drawn
        let controls: [(labels: [String], width: CGFloat, site: String)] = [
            (["Off", "Classic", "AI (stand-in)"],
             PanelChain.Host.developDisclosure.contentWidth(columnWidth: Lumen.minimumPanelWidth),
             "DetailPanel.swift:476 — denoise mode"),
            (["Perceptual", "Relative"],
             PanelChain.Host.developTop.contentWidth(columnWidth: Lumen.minimumPanelWidth)
                - Lumen.labelWidth - PanelChain.rowGap,
             "EffectsPanel.swift:536 — proof intent"),
            (["Add", "Subtract", "Intersect"],
             PanelChain.Host.maskComponent.contentWidth(columnWidth: Lumen.minimumPanelWidth),
             "MaskPanel.swift:1147 — component operation"),
            (["Lights", "Darks", "Midtones"], 190,
             "MaskPanel.swift:1453 — luminosity series"),
            (["Shift", "Kelvin"],
             PanelChain.Host.developTop.contentWidth(columnWidth: Lumen.minimumPanelWidth) / 2,
             "MaskPanel.swift:2367 — mask white balance unit"),
        ]
        var failures: [String] = []
        for control in controls {
            // `HStack(spacing: 1)` between the segments, then an equal share each.
            let share = (control.width - CGFloat(control.labels.count - 1))
                / CGFloat(control.labels.count)
            for label in control.labels {
                let w = TextMetric.width(label, LayoutFont.caption)
                guard w > share else { continue }
                failures.append("\(control.site): \"\(label)\" is \(f(w)) pt against a "
                                + "\(f(share)) pt share — TRUNCATES, and LumenSegmented "
                                + "has no minimumScaleFactor to fall back on because its "
                                + "labels are already at the 10 pt floor")
            }
        }
        report(failures, of: controls.reduce(0) { $0 + $1.labels.count },
               "LumenSegmented draws its labels at the 10 pt floor with lineLimit(1) and "
               + "no shrink, so a label that does not fit loses its tail.")
    }

    // MARK: - (e) The rest of the G1 list

    /// FINDING G1-06, measured at 11 pt rather than the 12 the audit had.
    ///
    /// The develop footer is a stack of `HStack(spacing: 4)`s of `DevelopFooterButton`s
    /// inside `.padding(.horizontal, 8)`, each button `.frame(maxWidth: .infinity)` with
    /// no horizontal padding of its own and `.lineLimit(1)` on the word. So the width one
    /// button gets is fixed arithmetic, and what has to fit inside it is a 10 pt SF Symbol,
    /// a 5 pt gap and the verb.
    ///
    /// The glyph is measured rather than allowed for: SF Symbols are not a fixed-width
    /// family, and "Paste Look" fails or passes on about three points.
    ///
    /// TWO THINGS IN THIS TEST WERE MEASURING A FOOTER THAT DOES NOT EXIST, and both are
    /// corrected here rather than left because they happened to pass.
    ///
    ///   · the first command's title was `Auto Tone`; `DevelopPanel.swift` has drawn
    ///     `Auto` for as long as this footer has existed. Measuring a string the app does
    ///     not draw is the "suite measures its own copy of the app" failure this file's
    ///     header is written against, and it cuts both ways — the extra five characters
    ///     were slack in the wrong direction, but a shorter invented string would have
    ///     hidden a real overflow;
    ///   · the share was hard-coded to a quarter for all eight. It is a quarter for the
    ///     four commands on the first row and a HALF for the four below it, which is the
    ///     G1-06 fix: `Paste Look` needed 76.3 pt of a 73.0 pt quarter and `Copy Look`
    ///     73.7, so the second row of four became two rows of two and each of those four
    ///     buttons now gets 150.0.
    func testEveryDevelopFooterButtonFitsItsShareOfTheRow() {
        // DevelopPanel.swift: the footer takes 8 pt of gutter each side and stacks
        // `HStack(spacing: 4)`s of `.frame(maxWidth: .infinity)` buttons, so a button's
        // width is fixed arithmetic once the row's population is known.
        func share(across count: Int) -> CGFloat {
            (Lumen.minimumPanelWidth - 16 - CGFloat(4 * (count - 1))) / CGFloat(count)
        }
        // title, symbol, how many buttons share that button's row.
        let commands: [(title: String, symbol: String, across: Int)] = [
            ("Auto", "wand.and.stars", 4), ("Reset", "arrow.uturn.backward", 4),
            ("Undo", "arrow.uturn.left", 4), ("Redo", "arrow.uturn.right", 4),
            ("Copy", "doc.on.doc", 2), ("Paste", "doc.on.clipboard", 2),
            ("Copy Look", "photo.stack", 2), ("Paste Look", "photo.stack.fill", 2),
        ]
        var failures: [String] = []
        for command in commands {
            let text = TextMetric.width(command.title, LayoutFont.body)
            guard let glyph = TextMetric.symbolWidth(command.symbol, pointSize: 10) else {
                XCTFail("\(command.symbol) did not resolve; the footer cannot be measured "
                        + "without it and a guessed width is not a measurement")
                continue
            }
            let budget = share(across: command.across)
            let need = glyph + 5 + text
            guard need > budget else { continue }
            failures.append("\(command.title): glyph \(f(glyph)) + 5 gap + text \(f(text)) "
                            + "= \(f(need)) pt against a \(f(budget)) pt share "
                            + "(1 of \(command.across) across) "
                            + "— OVER by \(f(need - budget)), truncates")
        }
        report(failures, of: commands.count,
               "DevelopPanel.swift: eight footer commands — four across, then two and "
               + "two — at the minimum column width (G1-06).")
    }

    /// FINDING G1-01, verified rather than assumed.
    ///
    /// The audit's fix was to rename the two Detail rows under the masters they already
    /// sit below — `Luminance Contrast` → `Contrast`, `Colour Smoothness` → `Smoothness`
    /// — and subordinate them with `indented: true`. This asserts the old names are gone
    /// AND that the new ones fit the smaller budget the indent leaves them, which is the
    /// half a rename can get wrong.
    func testTheRenamedDenoiseRowsAreGoneAndTheirReplacementsFit() throws {
        // Read from `DetailPanel.swift` rather than from this file's own table: asking
        // the inventory whether a name is absent only proves the inventory says so, and
        // the thing that can regress is the panel.
        let panel = try LayoutSource.flattened("Sources/LumenApp/DetailPanel.swift")
        for name in ["Luminance Contrast", "Colour Smoothness", "Luminance Detail",
                     "Colour Detail"] {
            // The argument form, not the bare string: the file discusses these names in
            // its own comments, and a scan that cannot tell a mention from a call site
            // fails on the paragraph explaining why they are gone.
            XCTAssertFalse(panel.contains("title: \"\(name)\""),
                           "\(name) is back in DetailPanel.swift; it measures "
                           + "\(f(TextMetric.width(name, LayoutFont.body))) pt against an "
                           + "\(f(Lumen.labelWidth)) pt column, so it truncates at every "
                           + "column width (G1-01)")
        }
        let indented = SliderInventory.all.filter(\.indented)
        XCTAssertFalse(indented.isEmpty, "the subordinated rows are the subject")
        for row in indented {
            let fit = TextMetric.fit(row.title, LayoutFont.body,
                                     budget: row.labelBudget,
                                     minimumScaleFactor: PanelChain.labelScaleFloor)
            XCTAssertFalse(fit.truncates,
                           "\(row.title) — \(row.site): \(f(fit.nominal)) pt against "
                           + "\(f(fit.budget)) pt once the 12 pt indent is taken")
        }
    }

    // MARK: - Keeping the instrument honest

    /// The inventory has to cover every slider that ships, or every number above is a
    /// measurement of a subset that happens to pass.
    ///
    /// Counting call sites rather than parsing them: the table is written out on purpose
    /// — a test that derives its expectations from the code under test proves only that
    /// the code agrees with itself — and this is the tripwire that stops the written-out
    /// version going quietly stale.
    func testTheInventoryCoversEveryShippedSlider() throws {
        let sites = try LayoutSource.sliderCallSites()
        XCTAssertEqual(sites, SliderInventory.callSiteCount,
                       "Sources/LumenApp holds \(sites) `LumenSlider(` call sites and this "
                       + "suite is written against \(SliderInventory.callSiteCount). Add the "
                       + "new row to `SliderInventory.all` with its range and step, then "
                       + "move this count — an unmeasured slider is the one that ships broken.")
    }

    /// THE PINS. Every constant this suite divides by is a literal in a source file, and
    /// a suite carrying its own copy of the layout measures its own copy of the app.
    ///
    /// So each one is looked up where it is written. If somebody moves the card gutter or
    /// the readout's padding, this fails and names the number to re-derive — instead of
    /// the metric tests above going on reporting the geometry of a panel that no longer
    /// exists. Whitespace is flattened first so a pin names a chain of modifiers without
    /// also pinning its indentation.
    func testTheLayoutChainThisSuiteMeasuresIsTheOneInTheSource() throws {
        var missing: [String] = []
        func pin(_ file: String, _ needle: String, _ what: String) throws {
            let text = try LayoutSource.flattened(file)
            let flat = needle.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !text.contains(flat) { missing.append("\(what) — \(file): expected `\(flat)`") }
        }

        // The develop column's chain, outside in.
        try pin("Sources/LumenApp/DevelopPanel.swift",
                ".padding(.horizontal, 4) .padding(.top, 6) .padding(.bottom, 16)",
                "scroll inset \(f(PanelChain.scrollInset))")
        try pin("Sources/LumenApp/DevelopColumn.swift",
                ".padding(.horizontal, 10) .padding(.top, 8) .padding(.bottom, 8)",
                "section card gutter \(f(PanelChain.cardInset))")
        // THE FOLD COSTS ITS ROWS NOTHING, pinned as two facts rather than one.
        //
        // The first is an ABSENCE — no horizontal padding between `content()` and its
        // transition — and an absence is the hardest thing to pin, because the obvious
        // way to write it is to delete the pin. So it is pinned as an adjacency: these
        // two tokens are neighbours in the flattened source exactly when nothing sits
        // between them, and any inset reintroduced there separates them and fails here.
        // The second is where the fold's depth went instead, which is what makes the
        // first one a design decision rather than an oversight somebody will "fix".
        try pin("Sources/LumenApp/DevelopPanel.swift",
                "content() .transition(.opacity.combined(",
                "disclosure content inset \(f(PanelChain.disclosureInset)) — a fold's "
                + "track equals a top-level track")
        try pin("Sources/LumenApp/DevelopPanel.swift",
                "topRhythm: 10) .padding(.leading, 8)",
                "fold depth carried on the header, not on the rows")

        // The row.
        try pin("Sources/LumenApp/LumenControls.swift",
                "var body: some View { HStack(spacing: 6) {",
                "slider row gap \(f(PanelChain.rowGap))")
        try pin("Sources/LumenApp/LumenControls.swift",
                ".padding(.horizontal, 5) .frame(width: Lumen.valueWidth, alignment: .trailing)",
                "readout pill padding \(f(PanelChain.valuePadding))")
        try pin("Sources/LumenApp/LumenControls.swift",
                ".padding(.leading, indented ? 12 : 0)",
                "label indent \(f(PanelChain.labelIndent))")
        try pin("Sources/LumenApp/LumenControls.swift",
                ".minimumScaleFactor(0.86)",
                "label shrink floor \(PanelChain.labelScaleFloor)")

        // The floating Masks pop-out, which never resizes.
        try pin("Sources/LumenApp/MaskFloatingPanel.swift",
                "static let width: CGFloat = 272",
                "mask panel width \(f(PanelChain.maskPanelWidth))")
        try pin("Sources/LumenApp/MaskFloatingPanel.swift",
                ".padding(.horizontal, 10) .padding(.top, 8) .padding(.bottom, 10)",
                "mask panel content inset \(f(PanelChain.maskPanelContentInset))")
        try pin("Sources/LumenApp/MaskPanel.swift",
                ".padding(.leading, MaskPanel.detailIndent) .padding(.trailing, 2)",
                "mask detail insets \(f(PanelChain.maskDetailLeading))/"
                + "\(f(PanelChain.maskDetailTrailing))")
        try pin("Sources/LumenApp/MaskPanel.swift",
                ".padding(.leading, 6).padding(.bottom, 4)",
                "component editor indent \(f(PanelChain.maskComponentLeading))")

        // The export sheet.
        try pin("Sources/LumenApp/ExportSheet.swift",
                "recipeColumn.frame(width: 244)",
                "export recipe column \(f(PanelChain.exportRecipeColumn))")
        try pin("Sources/LumenApp/ExportSheet.swift",
                ".frame(width: 800, height: 640)",
                "export sheet width \(f(PanelChain.exportSheetWidth))")
        try pin("Sources/LumenApp/ExportSheet.swift",
                ".padding(.horizontal, 14) .padding(.vertical, 8)",
                "export editor gutter \(f(PanelChain.exportEditorInset))")

        // The footer G1-06 is about.
        try pin("Sources/LumenApp/DevelopPanel.swift",
                ".padding(.horizontal, 8) .padding(.vertical, 6)",
                "footer gutter 8")

        // The grading wheels' lightness bar, whose host is built out of the wheel's own
        // diameter rather than out of any column — so the three literals that decide how
        // wide its groove is live in two different files and none of them is a panel
        // width.
        try pin("Sources/LumenApp/LumenControls.swift",
                ".padding(.leading, Lumen.valueWidth + 6) "
                + ".frame(width: diameter + 2 * (Lumen.valueWidth + 6))",
                "captioned wheel bar: counterweight and frame")
        try pin("Sources/LumenApp/LumenControls.swift",
                "lightnessBar .frame(width: diameter + 40)",
                "compact wheel bar frame \(f(PanelChain.maskWheelBarWidth)) at the 68 pt wheel")
        try pin("Sources/LumenApp/LookPanel.swift",
                "path: gradeZone.path, diameter: 150)",
                "grade wheel diameter \(f(PanelChain.gradeWheelDiameter))")

        // The scrub's fixed travel, and the fine gear.
        try pin("Sources/LumenApp/LumenControls.swift",
                "SliderTrack(width: 426,",
                "scrub travel \(f(SliderGesture.scrubTravel))")

        XCTAssertTrue(missing.isEmpty,
                  "the chain moved under the measurements:\n  "
                  + missing.joined(separator: "\n  "))
        XCTAssertEqual(SliderGesture.fineScale, FineDrag.scale,
                       "the fine gear is FineDrag.scale, not a number retyped here")
        XCTAssertEqual(PanelChain.glyphLabelBudget, 56,
                       "the 56 pt budget is `labelWidth − inRowWidth − 4`; if either "
                       + "moves, the claim in LumenControls.swift moves with it")
    }

    /// The bridge from `LumenType`'s tokens to the `NSFont`s these measurements are taken
    /// in, pinned the same way.
    ///
    /// A SwiftUI `Font` is opaque — there is no way to ask one for its point size — so
    /// the bridge has to be written out, and a duplicated constant is exactly what this
    /// project keeps finding at the moment it stops agreeing. Measuring 11 pt while the
    /// app draws 12 would understate every width in this file by nine percent, which is
    /// more than several of the margins above.
    func testTheTypeScaleThisSuiteMeasuresInIsTheOneTheAppDraws() throws {
        let text = try LayoutSource.flattened("Sources/LumenApp/LumenType.swift")
        let expected: [(String, NSFont, CGFloat)] = [
            ("lumenBody: Font = .system(size: 11, weight: .regular)", LayoutFont.body, 11),
            ("lumenCaption: Font = .system(size: 10, weight: .regular)", LayoutFont.caption, 10),
            ("lumenHeading: Font = .system(size: 12, weight: .semibold)",
             LayoutFont.heading, 12),
            ("lumenNumeric: Font = .system(size: 11, weight: .regular).monospacedDigit()",
             LayoutFont.numeric, 11),
            ("lumenNumericStrong: Font = .system(size: 11, weight: .medium).monospacedDigit()",
             LayoutFont.numericStrong, 11),
        ]
        for (declaration, font, size) in expected {
            XCTAssertTrue(text.contains(declaration),
                      "LumenType.swift no longer declares `\(declaration)`; re-derive "
                      + "LayoutFont before trusting any width in this suite")
            XCTAssertEqual(font.pointSize, size, accuracy: 0.001)
        }
        XCTAssertTrue(text.contains("10 is the floor"),
                  "the legibility floor these tests enforce is LumenType.swift's own "
                  + "sentence, and it is gone")
    }

    /// The instrument itself, proved able to answer before anything is asked of it.
    ///
    /// A measuring test that silently measures zero is worse than no test: every
    /// assertion above passes vacuously. So this checks that the font really resolves,
    /// that width is monotone in the string, and that a headless runner really does
    /// return type metrics — which is the whole premise the suite is built on.
    func testTheInstrumentMeasuresBeforeAnythingIsAskedOfIt() {
        XCTAssertGreaterThan(TextMetric.width("W", LayoutFont.body), 0,
                             "NSAttributedString.size() returned nothing — this runner has "
                             + "no usable text metrics and every result below is vacuous")
        XCTAssertGreaterThan(TextMetric.width("WW", LayoutFont.body),
                             TextMetric.width("W", LayoutFont.body))
        XCTAssertGreaterThan(TextMetric.width("Smoothness", LayoutFont.heading),
                             TextMetric.width("Smoothness", LayoutFont.body),
                             "12 pt semibold must measure wider than 11 pt regular")
        XCTAssertGreaterThan(TextMetric.width("8", LayoutFont.numericStrong),
                             0, "the scrubbing weight has to resolve too")
        // Tabular figures: every digit the same advance, which is the property
        // `.monospacedDigit()` is bought for and the reason a readout does not jitter.
        let one = TextMetric.width("111", LayoutFont.numeric)
        let mixed = TextMetric.width("890", LayoutFont.numeric)
        XCTAssertEqual(one, mixed, accuracy: 0.01,
                       "the numeric face is not tabular, so a readout's width depends on "
                       + "its digits and the column cannot be sized at all")
    }
}
#endif

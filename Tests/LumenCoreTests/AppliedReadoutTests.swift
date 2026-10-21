// AppliedReadoutTests.swift
// Panels that tell the truth where the engine already measures it.
//
// Each engine below already computes how far a control falls short of its slider —
// `ToneEngine.zoneFlattening` (Astra AI-07) — and nothing showed it. `AppliedReadout`
// is the value each panel reads; these tests exercise it for real against the engine,
// and then scan the panel's source to pin that the panel reads it and draws it.
//
// WHY HALF OF THIS IS A TEXT SCAN. The panels live in `Sources/LumenApp`, which has no
// test target that runs on this lane. The arithmetic half pins what the readout says;
// the scan pins that the shipped view asks for it. Neither is a proof alone.
//
// COMMENTS ARE STRIPPED BEFORE EVERY SCAN, with the shared `blankingComments`: the
// panels' comments name the very symbols scanned for, and a comment must not satisfy an
// assertion about code.

import Foundation
import XCTest
@testable import LumenCore

final class AppliedReadoutTests: XCTestCase {

    // MARK: - Zones (AI-07, WS-08)

    private func darks(_ ev: Double) -> Zones {
        var zones = Zones()
        zones.dark.ev = ev
        return zones
    }

    /// The Zones recipe that still reaches the bake's clamp once the register eases
    /// itself (WS-08): Darks alone never does, Contrast −100 underneath it does.
    private func deepContrast() -> Tone { Tone(contrast: -100) }

    func testAnUntouchedRegisterShowsNothing() {
        XCTAssertNil(AppliedReadout.zoneFlattening(tone: Tone(), zones: Zones()))
        XCTAssertEqual(AppliedReadout.zoneEasing(tone: Tone(), zones: Zones()), [])
        // Inside the ease's knee the register renders what it asks for and says nothing.
        XCTAssertEqual(AppliedReadout.zoneEasing(tone: Tone(), zones: darks(0.75)), [])
        // And on its own it never reaches the clamp, however far it is pushed: Darks +4
        // used to flatten 3.85 EV of input.
        XCTAssertNil(AppliedReadout.zoneFlattening(tone: Tone(), zones: darks(1.25)))
        XCTAssertNil(AppliedReadout.zoneFlattening(tone: Tone(), zones: darks(4)))
    }

    /// Darks +3 is eased, and the readout carries the amount the render applies — the
    /// engine's own number, not a parallel computation.
    ///
    /// SUBSTITUTION: make `zoneEasing(tone:zones:)` return `[]` and the unwrap fails.
    func testAnEasedZoneIsNamedWithTheAmountTheRenderApplies() throws {
        let zones = darks(3)
        let applied = ToneEngine(tone: Tone(), zones: zones).appliedZoneEV
        let eased = AppliedReadout.zoneEasing(tone: Tone(), zones: zones)
        let darksRow = try XCTUnwrap(eased.first, "Darks +3 is eased to \(applied[0]) and "
                                     + "the panel's readout said nothing")
        XCTAssertEqual(eased.count, 1)
        XCTAssertEqual(darksRow.name, "Darks")
        XCTAssertEqual(darksRow.requested, 3)
        XCTAssertEqual(darksRow.applied, applied[0])
        XCTAssertEqual(darksRow.caption,
                       "Applied +0.95 EV — eased so no brighter tone renders darker.")
        XCTAssertEqual(AppliedReadout.zoneNames,
                       ["Darks", "Shadows", "Midtones", "Lights", "Brights"])
    }

    /// The readout IS the engine's report — not a parallel computation that could drift
    /// from the bake — placed on the strip through the register's own axis.
    ///
    /// SUBSTITUTION: make `zoneFlattening(tone:zones:)` return nil and the unwrap of the
    /// readout fails here, as do the two tests below that unwrap it.
    func testAClampedBandIsNamedInEVAndPlacedOnTheStrip() throws {
        let zones = darks(3)
        let engine = ToneEngine(tone: deepContrast(), zones: zones)
        let report = try XCTUnwrap(engine.zoneFlattening())
        let readout = try XCTUnwrap(AppliedReadout.zoneFlattening(tone: deepContrast(),
                                                                  zones: zones),
                                    "Contrast −100 with Darks +3 flattens 1.06 EV of "
                                        + "input and the panel's readout said nothing")
        XCTAssertEqual(readout.flattening, report)
        XCTAssertEqual(readout.lowX, ToneEngine.zoneAxis(report.lowEV))
        XCTAssertEqual(readout.highX, ToneEngine.zoneAxis(report.highEV))
        XCTAssertLessThan(readout.lowX, readout.highX)
        // Measured, as the photographer reads it.
        XCTAssertTrue(readout.caption.contains("\u{2212}3.18…\u{2212}2.12 EV"), readout.caption)
        XCTAssertTrue(readout.caption.contains("0.05 EV"), readout.caption)
    }

    /// INVERTED BY WS-08 (Z3). This asserted that the mark followed the LIVE anchors,
    /// which was right while the zones themselves did: the register now sits on fixed
    /// stops (`ToneEngine.zoneAxis`), so do its pivots and its strip, and a mark placed
    /// through the live anchors would slide off the tones it names the moment Whites or
    /// Blacks moved.
    func testThePlacementFollowsTheAnchorsWhitesAndBlacksMove() throws {
        let zones = darks(3)
        let moved = Tone(contrast: -100, whites: -60, blacks: 60)
        let engine = ToneEngine(tone: moved, zones: zones)
        let report = try XCTUnwrap(engine.zoneFlattening())
        let readout = try XCTUnwrap(AppliedReadout.zoneFlattening(tone: moved, zones: zones))
        XCTAssertEqual(readout.lowX, ToneEngine.zoneAxis(report.lowEV))
        XCTAssertEqual(readout.highX, ToneEngine.zoneAxis(report.highEV))
        XCTAssertNotEqual(readout.lowX, engine.normalizedAxis(report.lowEV), accuracy: 1e-3,
                          "the mark is placed through the live anchors")
    }

    /// A deeper conflict flattens a wider band, and the readout grows with it. The zone
    /// request is eased, so it is Contrast that deepens it now.
    func testTheMarkGrowsWithTheRequest() throws {
        let some = try XCTUnwrap(AppliedReadout.zoneFlattening(tone: Tone(contrast: -80),
                                                               zones: darks(3)))
        let more = try XCTUnwrap(AppliedReadout.zoneFlattening(tone: deepContrast(),
                                                               zones: darks(3)))
        XCTAssertGreaterThan(more.highX - more.lowX, some.highX - some.lowX)
    }

    /// The panel asks for the readout with the recipe's own tone stack, hands the band to
    /// the strip, prints the caption, and the strip draws the band.
    ///
    /// SUBSTITUTION: drop the `flattened:` argument from the `ZonePivotStrip(` call (the
    /// strip then defaults to nil and draws nothing) and the second assertion fails;
    /// delete the `Text(flattened.caption)` row and the third fails.
    func testTheZonesPanelReadsTheReadoutAndDrawsIt() throws {
        let source = Scan.squeezed(Scan.stripped(try Scan.appSource("ZonesPanel.swift")))
        let rows = try Scan.between("private var rows: some View {", "private func evBinding(",
                                    in: source)
        XCTAssertTrue(rows.contains("AppliedReadout.zoneFlattening(tone: recipe.develop.tone, "
                                    + "zones: zones)"),
                      "the Zones panel no longer asks the engine what it flattened")
        XCTAssertTrue(rows.contains("flattened: flattened.map { $0.lowX...$0.highX }"),
                      "the flattened band is not handed to the strip")
        XCTAssertTrue(rows.contains("if let flattened { Text(flattened.caption)"),
                      "the flattened band is not named under the strip")
        // WS-08 Z1.7: an eased zone shows the applied amount under its own row.
        XCTAssertTrue(rows.contains("AppliedReadout.zoneEasing(tone: recipe.develop.tone, "
                                    + "zones: zones)"),
                      "the Zones panel no longer asks the engine what it eased")
        XCTAssertTrue(rows.contains("if let eased = easing.first(where: { $0.name == zone.name }) "
                                    + "{ Text(eased.caption)"),
                      "an eased zone is not captioned under its row")

        let strip = try Scan.between("struct ZonePivotStrip: View {", "private func handle(",
                                     in: source)
        XCTAssertTrue(strip.contains("var flattened: ClosedRange<Double>? = nil"))
        XCTAssertTrue(strip.contains("let flat = flattened"))
        XCTAssertTrue(strip.contains("if let flat {"),
                      "the strip takes the band and never draws it")
        XCTAssertTrue(strip.contains("flat.lowerBound") && strip.contains("flat.upperBound"))
    }
}

// MARK: - The sweep: limiters the engine reports and no panel showed

final class EngineLimitReadoutTests: XCTestCase {

    // MARK: Tone — effectiveHighlights and its three siblings

    func testUntouchedAndSingleSliderAtContrastZeroAreNeverCaptioned() {
        XCTAssertNil(AppliedReadout.toneEasingCaption(tone: Tone()))
        // At Contrast 0 a single slider is never eased (ToneEngine's own claim), and the
        // two halves are solved separately, so the ordinary "flatten it" move is silent.
        for v in [-100.0, 100] {
            XCTAssertNil(AppliedReadout.toneEasingCaption(tone: Tone(highlights: v)))
            XCTAssertNil(AppliedReadout.toneEasingCaption(tone: Tone(shadows: v)))
            XCTAssertNil(AppliedReadout.toneEasingCaption(tone: Tone(whites: v)))
            XCTAssertNil(AppliedReadout.toneEasingCaption(tone: Tone(blacks: v)))
        }
        XCTAssertNil(AppliedReadout.toneEasingCaption(
            tone: Tone(highlights: -100, shadows: 100)))
    }

    /// The caption carries the number the render uses. Measured: Highlights −100 at
    /// Contrast −100 applies −94; Blacks +100 there applies +91 on its shelf.
    ///
    /// SUBSTITUTION: make `easedToneSliders` return `[]` and both unwraps fail.
    func testAnEasedSliderIsNamedWithTheAmountTheRenderApplies() throws {
        let tone = Tone(contrast: -100, highlights: -100)
        let engine = ToneEngine(tone: tone)
        let caption = try XCTUnwrap(AppliedReadout.toneEasingCaption(tone: tone),
                                    "Highlights is eased to \(engine.effectiveHighlights) "
                                        + "and the panel's readout said nothing")
        let shown = "Highlights \(AppliedReadout.signed(engine.effectiveHighlights * 100)) "
            + "of \u{2212}100"
        XCTAssertTrue(caption.contains(shown), caption)
        XCTAssertTrue(caption.contains("\u{2212}94"), caption)

        let blacks = Tone(contrast: -100, blacks: 100)
        let shelf = try XCTUnwrap(AppliedReadout.toneEasingCaption(tone: blacks))
        XCTAssertTrue(shelf.contains("Blacks (tone shelf) +91 of +100"), shelf)
    }

    /// Every row the readout reports is the engine's own applied value, and every
    /// slider the engine holds back by half a unit or more is reported — over a grid
    /// that includes the binding corners.
    func testTheReadoutIsExactlyTheEnginesAppliedAmounts() {
        var reported = 0
        let steps: [Double] = [-100, -50, 0, 50, 100]
        for c in steps { for h in steps { for s in steps { for w in steps { for b in steps {
            let tone = Tone(contrast: c, highlights: h, shadows: s, whites: w, blacks: b)
            let engine = ToneEngine(tone: tone)
            let rows = AppliedReadout.easedToneSliders(tone: tone)
            let truth: [(String, Double, Double)] = [
                ("Highlights", h, engine.effectiveHighlights * 100),
                ("Shadows", s, engine.effectiveShadows * 100),
                ("Whites (tone shelf)", w, engine.effectiveWhites * 100),
                ("Blacks (tone shelf)", b, engine.effectiveBlacks * 100),
            ]
            for (name, requested, applied) in truth {
                let row = rows.first { $0.name == name }
                if abs(requested - applied) >= 0.5 {
                    XCTAssertEqual(row?.applied, applied, "\(name) at \(tone)")
                    XCTAssertEqual(row?.requested, requested)
                } else {
                    XCTAssertNil(row, "\(name) is applied as set at \(tone)")
                }
            }
            reported += rows.count
        } } } } }
        XCTAssertGreaterThan(reported, 0, "the grid never reached a binding case")
    }

    // MARK: Grade — the wheels' Luminance and the grid's Brilliance

    private func plannedGrade(_ recipe: Recipe) -> GradeEngine {
        // The anchors the render actually uses, from the render's own plan.
        let plan = RenderPlan(recipe: recipe)
        return GradeEngine(wheels: recipe.look.wheels,
                           printerLights: recipe.look.printerLights,
                           whiteAnchorEV: plan.tone.whiteAnchorEV,
                           blackAnchorEV: plan.tone.blackAnchorEV)
    }

    func testAnUngradedRecipeIsNeverCaptioned() {
        XCTAssertEqual(AppliedReadout.wheelLuminanceScale(Recipe()), 1)
        XCTAssertNil(AppliedReadout.wheelLuminanceCaption(Recipe()))
        XCTAssertEqual(AppliedReadout.brillianceScale(Recipe()), 1)
        XCTAssertNil(AppliedReadout.brillianceCaption(Recipe()))
    }

    /// Measured: Shadows +1 / Midtones +1 / Highlights −1 at Blending 0 applies 2% of
    /// the zone wheels' Luminance. Whites −60 moves the anchors the windows hang off,
    /// so the readout must build its engine from the recipe's tone, not the defaults.
    ///
    /// SUBSTITUTION: make `wheelLuminanceCaption` return nil and the unwrap fails.
    func testHeldWheelLuminanceIsNamedWithTheRendersScale() throws {
        var recipe = Recipe()
        recipe.look.wheels.shadows.lum = 1
        recipe.look.wheels.mid.lum = 1
        recipe.look.wheels.high.lum = -1
        recipe.look.wheels.blending = 0
        recipe.develop.tone.whites = -60
        let g = plannedGrade(recipe)
        XCTAssertEqual(AppliedReadout.wheelLuminanceScale(recipe), g.lumScale * g.jointScale)
        XCTAssertLessThan(g.lumScale * g.jointScale, 0.5)
        let caption = try XCTUnwrap(AppliedReadout.wheelLuminanceCaption(recipe))
        XCTAssertTrue(caption.contains(AppliedReadout.percent(g.lumScale * g.jointScale)),
                      caption)
    }

    /// Measured: Brilliance Shadows +100 / Highlights −100 applies 34% on the zone rows.
    func testHeldBrillianceIsNamedWithTheRendersScale() throws {
        var recipe = Recipe()
        recipe.look.wheels.colorBalance.brilliance.shadows = 100
        recipe.look.wheels.colorBalance.brilliance.high = -100
        let scale = plannedGrade(recipe).colorBalance.appliedBrillianceScale
        XCTAssertEqual(AppliedReadout.brillianceScale(recipe), scale)
        let caption = try XCTUnwrap(AppliedReadout.brillianceCaption(recipe))
        XCTAssertTrue(caption.contains("34%"), caption)
    }

    // MARK: The panels read them

    /// SUBSTITUTION: delete any of the three `AppliedReadout.` calls from its panel and
    /// the matching assertion is red.
    func testThePanelsAskForTheReadouts() throws {
        let basic = Scan.squeezed(Scan.stripped(try Scan.appSource("BasicPanel.swift")))
        let toneRows = try Scan.between("private var toneRows: some View {",
                                        "private var presenceSection", in: basic)
        XCTAssertTrue(toneRows.contains("if let eased = AppliedReadout.toneEasingCaption("
                                        + "tone: recipe.develop.tone) { Text(eased)"),
                      "the Tone rows no longer show what the solve applies")

        let look = Scan.squeezed(Scan.stripped(try Scan.appSource("LookPanel.swift")))
        let wheels = try Scan.between("private var wheelsRows: some View {",
                                      "colorBalanceDisclosure", in: look)
        XCTAssertTrue(wheels.contains("if let held = AppliedReadout.wheelLuminanceCaption("
                                      + "state.currentRecipe) { Text(held)"),
                      "the wheels no longer show what Luminance the grade applies")

        let grid = try Scan.between("private var colorBalanceDisclosure: some View {",
                                    "private func balanceAxis(", in: look)
        XCTAssertTrue(grid.contains("let brillianceHeld = AppliedReadout.brillianceCaption("
                                    + "state.currentRecipe)"))
        XCTAssertTrue(grid.contains("note: brillianceNote"))
        XCTAssertTrue(grid.contains("brillianceNote = brillianceHeld"),
                      "the Brilliance note never carries the held amount")
    }
}

// MARK: - AI-08, interim: the per-pixel variance tools say what they cost

/// Mixer Uniformity ("Even out hues") and Point Colour Variance are meant to compress
/// the LOCAL MEAN toward a target and leave texture alone. The shipping path hands the
/// kernel the pixel itself (S9 is a colour table and cannot see a neighbourhood), so
/// they flatten hue texture instead. Until a spatial mean reaches the stage (P14
/// DECISION 6), the help says so. These tests pin the help's claims to the engine: if
/// the engine stops flattening, the arithmetic half goes red and the help has to change
/// with it; if the help loses the sentence, the scan goes red.
final class PerPixelVarianceHelpTests: XCTestCase {

    private let ctx = OKLabTransform.working

    private func lch(_ L: Double, _ C: Double, _ h: Double) -> RGB {
        ctx.toRGB(OKLCh(L: L, C: C, h: h))
    }

    private func pointEngine(swatch: RGB, variance: Double) -> ColorEngine {
        ColorEngine(mixer: Mixer(),
                    pointColors: [PointColor(sample: [swatch.r, swatch.g, swatch.b],
                                             variance: variance)],
                    color: ColorAdjust(), primaries: Primaries(), bw: nil)
    }

    /// "at −100 colours well inside its range take the swatch's hue and colourfulness
    /// and move halfway to its lightness". Measured: 24°/29°/34° all leave at 29.23°.
    func testPointVarianceMinus100TakesTheSwatchsHueAndChromaAndHalfItsLightness() {
        let swatch = lch(0.55, 0.10, 29.23)
        let engine = pointEngine(swatch: swatch, variance: -100)
        for dh in [-5.0, 0, 5] {
            let out = ctx.toLCh(engine.apply(lch(0.55, 0.10, 29.23 + dh)))
            XCTAssertEqual(out.h, 29.23, accuracy: 0.01,
                           "a hue \(dh)° off the swatch kept its offset: the help's "
                               + "\"pixel by pixel\" sentence is no longer true")
        }
        for dC in [-0.02, 0.02] {
            XCTAssertEqual(ctx.toLCh(engine.apply(lch(0.55, 0.10 + dC, 29.23))).C, 0.10,
                           accuracy: 1e-6)
        }
        for dL in [-0.04, 0.04] {
            XCTAssertEqual(ctx.toLCh(engine.apply(lch(0.55 + dL, 0.10, 29.23))).L,
                           0.55 + dL / 2, accuracy: 1e-6)
        }
    }

    /// "positive amplifies it, noise included": +100 doubles a hue's offset.
    func testPointVariancePlus100AmplifiesTheOffset() {
        let swatch = lch(0.55, 0.10, 29.23)
        let engine = pointEngine(swatch: swatch, variance: 100)
        let out = ctx.toLCh(engine.apply(lch(0.55, 0.10, 34.23)))
        XCTAssertEqual(out.h, 39.23, accuracy: 0.01)
    }

    /// "at 100 the hues inside a band all land on one": ±5° around every band's centre.
    func testUniformity100LandsEveryHueInsideABandOnOne() {
        var mixer = Mixer()
        mixer.uniformity = 100
        let engine = ColorEngine(mixer: mixer, pointColors: [], color: ColorAdjust(),
                                 primaries: Primaries(), bw: nil)
        for centre in ColorEngine.bandHueCentres {
            for dh in [-5.0, 0, 5] {
                let out = ctx.toLCh(engine.apply(lch(0.6, 0.10, centre + dh)))
                XCTAssertEqual(Num.hueDelta(centre, out.h), 0, accuracy: 0.01,
                               "band at \(centre)°: a hue \(dh)° off kept its offset")
            }
        }
    }

    /// The help on both rows carries the sentence. String literals are joined first so
    /// the assertion is about the words, not where the author wrapped them.
    ///
    /// SUBSTITUTION: restore either help string to its old text and this is red.
    func testBothRowsSayTheyWorkPixelByPixel() throws {
        let source = Scan.squeezed(Scan.stripped(try Scan.appSource("ColorPanel.swift")))
            .replacingOccurrences(of: "\" + \"", with: "")
        let uniformity = try Scan.between("LumenSlider(title: \"Even out hues\"",
                                          "private func", in: source)
        XCTAssertTrue(uniformity.contains("For now it works pixel by pixel, not on the "
                                          + "neighbourhood: at 100 the hues inside a band "
                                          + "all land on one, so fine colour texture "
                                          + "flattens along with the blotches."),
                      "Even out hues no longer says it flattens texture")
        let variance = try Scan.between("LumenSlider(title: \"Variance\"",
                                        ".onChange(of: swatches.count)", in: source)
        XCTAssertTrue(variance.contains("For now it works pixel by pixel, not on the "
                                        + "neighbourhood: at \u{2212}100 colours well "
                                        + "inside its range take the swatch's hue and "
                                        + "colourfulness and move halfway to its "
                                        + "lightness, so fine colour texture flattens "
                                        + "too; positive amplifies it, noise included."),
                      "Point Colour Variance no longer says it flattens texture")
    }
}

// MARK: - reading LumenApp as text

/// Private to this file, in the shape `ColorPanelReachTests` uses; the stripper is the
/// shared `blankingComments`.
private enum Scan {

    static let appRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")

    static func appSource(_ name: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(name), encoding: .utf8)
    }

    static func stripped(_ source: String) -> String {
        blankingComments(in: source)
    }

    static func between(_ a: String, _ b: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: a), "missing marker: \(a)").upperBound
        let tail = source[start...]
        let end = try XCTUnwrap(tail.range(of: b), "missing marker: \(b)").lowerBound
        return String(tail[..<end])
    }

    /// Every run of whitespace to one space, so an assertion about a wrapped expression
    /// is not an assertion about where the author wrapped it.
    static func squeezed(_ source: String) -> String {
        var out = ""
        var space = false
        for ch in source {
            if ch.isWhitespace {
                if !space { out.append(" "); space = true }
            } else {
                out.append(ch); space = false
            }
        }
        return out
    }
}

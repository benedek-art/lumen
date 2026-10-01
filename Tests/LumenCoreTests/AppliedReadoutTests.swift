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

    // MARK: - Zones (AI-07)

    private func darks(_ ev: Double) -> Zones {
        var zones = Zones()
        zones.dark.ev = ev
        return zones
    }

    func testAnUntouchedRegisterShowsNothing() {
        XCTAssertNil(AppliedReadout.zoneFlattening(tone: Tone(), zones: Zones()))
        // Below the clamp's onset the register renders what it asks for, and says so by
        // saying nothing. Darks alone first flattens between +1.25 and +1.5 EV.
        XCTAssertNil(AppliedReadout.zoneFlattening(tone: Tone(), zones: darks(1.25)))
    }

    /// The readout IS the engine's report — not a parallel computation that could drift
    /// from the bake — placed on the strip through the engine's own axis.
    ///
    /// SUBSTITUTION: make `zoneFlattening(tone:zones:)` return nil and the unwrap of the
    /// readout fails here, as do the two tests below that unwrap it.
    func testDarksPlusFourIsNamedInEVAndPlacedOnTheStrip() throws {
        let zones = darks(4)
        let engine = ToneEngine(tone: Tone(), zones: zones)
        let report = try XCTUnwrap(engine.zoneFlattening())
        let readout = try XCTUnwrap(AppliedReadout.zoneFlattening(tone: Tone(), zones: zones),
                                    "Darks +4 EV flattens 3.85 EV of input and the "
                                        + "panel's readout said nothing")
        XCTAssertEqual(readout.flattening, report)
        XCTAssertEqual(readout.lowX, engine.normalizedAxis(report.lowEV))
        XCTAssertEqual(readout.highX, engine.normalizedAxis(report.highEV))
        XCTAssertLessThan(readout.lowX, readout.highX)
        // The audit's own numbers, as the photographer reads them.
        XCTAssertTrue(readout.caption.contains("\u{2212}3.77…+0.08 EV"), readout.caption)
        XCTAssertTrue(readout.caption.contains("2.20 EV"), readout.caption)
    }

    /// The strip's x axis is `normalizedAxis` at the LIVE anchors, and Whites and Blacks
    /// move them. A readout placed through the default anchors would mark the wrong
    /// tones the moment either slider moved.
    func testThePlacementFollowsTheAnchorsWhitesAndBlacksMove() throws {
        let zones = darks(4)
        let plain = try XCTUnwrap(AppliedReadout.zoneFlattening(tone: Tone(), zones: zones))
        let moved = Tone(whites: -60, blacks: 60)
        let engine = ToneEngine(tone: moved, zones: zones)
        let report = try XCTUnwrap(engine.zoneFlattening())
        let readout = try XCTUnwrap(AppliedReadout.zoneFlattening(tone: moved, zones: zones))
        XCTAssertEqual(readout.lowX, engine.normalizedAxis(report.lowEV))
        XCTAssertEqual(readout.highX, engine.normalizedAxis(report.highEV))
        XCTAssertNotEqual(readout.lowX, plain.lowX, accuracy: 1e-3)
    }

    /// A wider request flattens a wider band, and the readout grows with it.
    func testTheMarkGrowsWithTheRequest() throws {
        let two = try XCTUnwrap(AppliedReadout.zoneFlattening(tone: Tone(), zones: darks(2)))
        let four = try XCTUnwrap(AppliedReadout.zoneFlattening(tone: Tone(), zones: darks(4)))
        XCTAssertGreaterThan(four.highX - four.lowX, two.highX - two.lowX)
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

        let strip = try Scan.between("struct ZonePivotStrip: View {", "private func handle(",
                                     in: source)
        XCTAssertTrue(strip.contains("var flattened: ClosedRange<Double>? = nil"))
        XCTAssertTrue(strip.contains("let flat = flattened"))
        XCTAssertTrue(strip.contains("if let flat {"),
                      "the strip takes the band and never draws it")
        XCTAssertTrue(strip.contains("flat.lowerBound") && strip.contains("flat.upperBound"))
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

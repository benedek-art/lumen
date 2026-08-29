// DominantBandTests.swift
// Which of the eight mixer bands a colour reads as.
//
// This is the arithmetic behind the picker-first mixer (docs/28 Phase 5): click a colour
// in the photograph and the band that owns it selects itself, instead of the
// photographer having to know which of Red/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta
// a particular skin tone or sky lives in. It is derived from `bandWeights` rather than
// from the band centres, and these tests are mostly about why that distinction matters:
// the arcs are draggable, so the answer has to follow the ring the user drew.

import XCTest
@testable import LumenCore

final class DominantBandTests: XCTestCase {

    private var canonical: [ColorEngine.BandArc] { ColorEngine.canonicalArcs }

    // MARK: The centres

    func testEachBandCentreBelongsToItsOwnBand() {
        for i in 0..<ColorEngine.bandCount {
            let hue = ColorEngine.bandHueCentres[i]
            XCTAssertEqual(ColorEngine.dominantBand(hue: hue, arcs: canonical), i,
                           "\(ColorEngine.bandNames[i])'s own centre must read as itself")
        }
    }

    func testEveryHueOnTheCircleLandsOnSomeRealBand() {
        // No hole and no crash: the partition of unity covers the circle, so there is
        // always an answer, and it is always an index the panel can select.
        for degrees in stride(from: 0.0, to: 360.0, by: 0.5) {
            let band = ColorEngine.dominantBand(hue: degrees, arcs: canonical)
            XCTAssertTrue((0..<ColorEngine.bandCount).contains(band),
                          "hue \(degrees) produced band \(band)")
        }
    }

    func testTheAnswerIsTheHeaviestWeightAndNotTheNearestCentre() {
        // The property that makes this the engine's answer rather than a second model
        // of it: at every hue, the chosen band is the argmax of the membership vector
        // the pixel loop uses.
        for degrees in stride(from: 0.0, to: 360.0, by: 1.0) {
            let band = ColorEngine.dominantBand(hue: degrees, arcs: canonical)
            let weights = ColorEngine.bandWeights(hue: degrees, arcs: canonical)
            let heaviest = weights.max() ?? 0
            XCTAssertEqual(weights[band], heaviest, accuracy: 1e-12,
                           "hue \(degrees) chose band \(band) at weight \(weights[band]) "
                           + "while \(heaviest) was available")
        }
    }

    func testAHueWalkingRoundTheCircleVisitsEveryBand() {
        var seen: Set<Int> = []
        for degrees in stride(from: 0.0, to: 360.0, by: 1.0) {
            seen.insert(ColorEngine.dominantBand(hue: degrees, arcs: canonical))
        }
        XCTAssertEqual(seen.count, ColorEngine.bandCount,
                       "a band no hue can reach is a band the picker can never select")
    }

    func testTheAnswerWrapsRatherThanClampingAtZero() {
        // 360 and 0 are the same angle, and a picker that disagreed with itself across
        // the seam would select a different band for the same red depending on which
        // side of the wrap the sample landed.
        for offset in stride(from: -720.0, through: 720.0, by: 45.0) {
            XCTAssertEqual(
                ColorEngine.dominantBand(hue: ColorEngine.bandAnchorDegrees + offset,
                                         arcs: canonical),
                ColorEngine.dominantBand(hue: ColorEngine.bandAnchorDegrees
                                             + offset.truncatingRemainder(dividingBy: 360),
                                         arcs: canonical))
        }
    }

    // MARK: Following the ring the user drew

    func testAWidenedBandTakesHuesItsNeighbourUsedToOwn() {
        // The whole reason this reads `bandWeights` instead of comparing against
        // `bandHueCentres`. Widen Red's core and feather toward Orange, and a hue that
        // the default geometry called Orange must now answer Red — otherwise the panel
        // would select a band the ring says is not the one grading that colour.
        let towardOrange = ColorEngine.bandHueCentres[0]
            + ColorEngine.bandSpacingDegrees * 0.45
        XCTAssertEqual(ColorEngine.dominantBand(hue: towardOrange, arcs: canonical), 0,
                       "precondition: just inside Red at default geometry")

        let justPastMidpoint = ColorEngine.bandHueCentres[0]
            + ColorEngine.bandSpacingDegrees * 0.62
        XCTAssertEqual(ColorEngine.dominantBand(hue: justPastMidpoint, arcs: canonical), 1,
                       "precondition: Orange owns this at default geometry")

        var bands = [MixerBand](repeating: MixerBand(), count: ColorEngine.bandCount)
        bands[0].core = [ColorEngine.bandCoreDegrees, ColorEngine.bandCoreMaxDegrees]
        bands[0].feather = [ColorEngine.bandFeatherDegrees, 60]
        let widened = ColorEngine.bandArcs(bands)
        XCTAssertEqual(ColorEngine.dominantBand(hue: justPastMidpoint, arcs: widened), 0,
                       "a widened Red must claim the hue it now grades most")
    }

    func testTheDefaultGeometryStillAnswersTheSameWayThroughTheArcsItProduces() {
        // `bandArcs` of untouched bands must be the canonical geometry, or every
        // reshaped-ring test above is measuring the sanitizer rather than the reshape.
        let untouched = ColorEngine.bandArcs(
            [MixerBand](repeating: MixerBand(), count: ColorEngine.bandCount))
        for degrees in stride(from: 0.0, to: 360.0, by: 3.0) {
            XCTAssertEqual(ColorEngine.dominantBand(hue: degrees, arcs: untouched),
                           ColorEngine.dominantBand(hue: degrees, arcs: canonical))
        }
    }

    // MARK: Colours, and the ones that have no colour

    func testASaturatedColourResolvesToTheBandItLooksLike() {
        // Red, green and blue primaries, through the same OKLab transform the engine
        // grades in. Named by what the band is called, because that is what the
        // photographer will see selected.
        let cases: [(RGB, String)] = [
            (RGB(0.9, 0.05, 0.05), "Red"),
            (RGB(0.05, 0.7, 0.1), "Green"),
            (RGB(0.05, 0.1, 0.9), "Blue"),
        ]
        for (colour, expected) in cases {
            guard let band = ColorEngine.dominantBand(for: colour, arcs: canonical) else {
                XCTFail("\(expected) sample read as having no colour")
                continue
            }
            XCTAssertEqual(ColorEngine.bandNames[band], expected)
        }
    }

    func testANearGreyHasNoBandRatherThanARandomOne() {
        // Below the chroma gate the hue angle is noise. Selecting a band from it would
        // put three sliders in front of a decision nobody made, so the answer is nil and
        // the panel can say "there is no colour there".
        for level in [0.02, 0.2, 0.5, 0.8, 0.98] {
            let grey = RGB(gray: level)
            XCTAssertNil(ColorEngine.dominantBand(for: grey, arcs: canonical),
                         "grey at \(level) claimed a band")
        }
    }

    func testANonFiniteSampleIsRefusedRatherThanResolved() {
        XCTAssertNil(ColorEngine.dominantBand(
            for: RGB(.nan, 0.5, 0.5), arcs: canonical))
        XCTAssertNil(ColorEngine.dominantBand(
            for: RGB(.infinity, 0.5, 0.5), arcs: canonical))
    }

    func testTheColourAnswerAgreesWithTheHueAnswer() {
        // One implementation, not two: the colour entry point must be the hue entry
        // point plus a conversion and a gate, or a picked swatch and the ring could
        // disagree about the same colour.
        let colour = RGB(0.82, 0.45, 0.12)
        let lch = OKLabTransform.working.toLCh(colour)
        XCTAssertEqual(ColorEngine.dominantBand(for: colour, arcs: canonical),
                       ColorEngine.dominantBand(hue: lch.h, arcs: canonical))
    }
}

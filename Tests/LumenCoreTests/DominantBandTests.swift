// DominantBandTests.swift
// Which of the eight mixer bands a colour reads as.
//
// This is the arithmetic behind the picker-first mixer (docs/28 Phase 5): click a colour
// in the photograph and the band that owns it selects itself, instead of the
// photographer having to know which of Red/Orange/Yellow/Mint/Aqua/Azure/Purple/Magenta
// a particular skin tone or sky lives in. It is derived from `bandWeights` rather than
// from the band centres, and these tests are mostly about why that distinction matters:
// the arcs are draggable, so the answer has to follow the ring the user drew.
//
// The picker matters more than it looks, and B1-08 is why: the eight names were inherited
// from a product whose bands sit somewhere else, and two of them were most of a band out
// (see `ColorEngine.bandNames`). They are honest now, but there is still no band centred
// on ordinary green — so "click the thing you want to change" is the reliable route to a
// band, and reading the label is not.

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
        // WS-31: the bands are uneven now, so "just inside" and "just past" are read off
        // the Red/Orange crossover rather than off a fixed 45° spacing.
        let crossover = ColorEngine.bandCrossoverDegrees[0]
        let towardOrange = crossover - 3
        XCTAssertEqual(ColorEngine.dominantBand(hue: towardOrange, arcs: canonical), 0,
                       "precondition: just inside Red at default geometry")

        let justPastMidpoint = crossover + 6
        XCTAssertEqual(ColorEngine.dominantBand(hue: justPastMidpoint, arcs: canonical), 1,
                       "precondition: Orange owns this at default geometry")

        // Widen Red's upper core and feather to the panel's limits, in degrees.
        let d = ColorEngine.defaultArc(0)
        let wide = ColorEngine.BandArc(centre: d.centre, coreBelow: d.coreBelow,
                                       coreAbove: ColorEngine.bandCoreMaxDegrees,
                                       featherBelow: d.featherBelow,
                                       featherAbove: ColorEngine.bandFeatherMaxDegrees)
        let handles = ColorEngine.wireHandles(for: wide, band: 0)
        var bands = [MixerBand](repeating: MixerBand(), count: ColorEngine.bandCount)
        bands[0].core = handles.core
        bands[0].feather = handles.feather
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

    /// A saturated colour resolves to a stable band, and the band's NAME is now the one
    /// its centre earns.
    ///
    /// This test used to be called `...ResolvesToTheBandItLooksLike` and expected the
    /// green primary to select a band called "Green" and the blue primary a band called
    /// "Blue". Both passed, and both were the defect: B1-08 measured the band centres and
    /// found "Green" sitting 43.3° from green and "Blue" 31.8° from blue — most of a band
    /// away — so what the test really pinned was that a mislabelled band kept its label.
    ///
    /// THE ASSIGNMENT DID NOT CHANGE and that is the point. The green primary reads as
    /// band 3 and the blue primary as band 5 exactly as before; the arithmetic was never
    /// wrong. Only the two strings moved, to Mint and Azure, and the expectations below
    /// moved with them — which is why this test going red on the rename was the evidence
    /// that the rename took, rather than an inconvenience.
    ///
    /// The band INDEX is asserted alongside the name from here on. A future rename can
    /// then only be a rename: if the name and the index ever disagree about which band a
    /// primary belongs to, one of them moved and the message says which.
    func testASaturatedColourResolvesToAStablyNamedBand() {
        // Red, green and blue primaries, through the same OKLab transform the engine
        // grades in.
        let cases: [(sample: RGB, band: Int, name: String)] = [
            (RGB(0.9, 0.05, 0.05), 0, "Red"),
            (RGB(0.05, 0.7, 0.1), 3, "Green"),
            (RGB(0.05, 0.1, 0.9), 5, "Blue"),
        ]
        for (colour, expectedBand, expectedName) in cases {
            guard let band = ColorEngine.dominantBand(for: colour, arcs: canonical) else {
                XCTFail("the \(expectedName) sample read as having no colour")
                continue
            }
            XCTAssertEqual(band, expectedBand,
                           "\(colour) moved from band \(expectedBand) to band \(band) — "
                               + "that is the arithmetic changing, not a rename")
            XCTAssertEqual(ColorEngine.bandNames[band], expectedName,
                           "band \(band) is called \(ColorEngine.bandNames[band]) now")
        }
    }

    // MARK: WS-31 E1: a pick selects the band a photographer would name

    /// sRGB HSV 0/30/60/120/180/240/270/300 select their own band; ColorChecker light and
    /// dark skin select Orange; the foliage medians select Green; skies select Blue.
    /// On the old equal 45° grid sRGB orange and green were exact 50/50 seams and both
    /// skins picked Red.
    func testAPickSelectsTheBandAPhotographerWouldName() {
        let srgbToWorking = RGBColorSpace.srgb.matrix(to: .rec2020)
        func srgb(_ hsvDegrees: Double) -> RGB {
            // Full-saturation, full-value sRGB at an HSV hue, linearised.
            let h = hsvDegrees / 60
            let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
            let (r, g, b): (Double, Double, Double)
            switch Int(h) {
            case 0: (r, g, b) = (1, x, 0)
            case 1: (r, g, b) = (x, 1, 0)
            case 2: (r, g, b) = (0, 1, x)
            case 3: (r, g, b) = (0, x, 1)
            case 4: (r, g, b) = (x, 0, 1)
            default: (r, g, b) = (1, 0, x)
            }
            func lin(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return srgbToWorking.apply(RGB(lin(r), lin(g), lin(b))) * 0.45
        }
        for (hsv, band) in [(0.0, 0), (30, 1), (60, 2), (120, 3), (180, 4), (240, 5),
                            (270, 6), (300, 7)] {
            XCTAssertEqual(ColorEngine.dominantBand(for: srgb(hsv), arcs: canonical), band,
                           "sRGB HSV \(hsv)° should pick \(ColorEngine.bandNames[band])")
        }
        // ColorChecker light and dark skin, Rec.2020 linear (corpus/synthetic/colorchecker.json).
        let lightSkin = OKLabTransform.working.toRGB(OKLCh(L: 0.708, C: 0.068, h: 40.7))
        let darkSkin = OKLabTransform.working.toRGB(OKLCh(L: 0.468, C: 0.052, h: 42.3))
        XCTAssertEqual(ColorEngine.dominantBand(for: lightSkin, arcs: canonical), 1)
        XCTAssertEqual(ColorEngine.dominantBand(for: darkSkin, arcs: canonical), 1)
        for hue in [127.6, 134.3, 137.9] {
            XCTAssertEqual(ColorEngine.dominantBand(hue: hue, arcs: canonical), 3,
                           "foliage at \(hue)° should pick Green")
        }
        for hue in stride(from: 251.0, through: 260.0, by: 0.5) {
            XCTAssertEqual(ColorEngine.dominantBand(hue: hue, arcs: canonical), 5,
                           "sky at \(hue)° should pick Blue")
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

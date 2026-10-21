import Foundation
import XCTest
@testable import LumenCore

/// THE EIGHT MIXER BANDS MUST BE CALLED SOMETHING TRUE.
///
/// B1-08 was not an arithmetic defect. `bandWeights`, `dominantBand` and the ring all did
/// exactly what they claim; the eight STRINGS were inherited from a product whose bands sit
/// somewhere else, and nothing in the repository had ever compared a name to the colour at
/// the centre it names. "Green" was 43.3° from green — most of a 45° band — so a
/// photographer dragging the slider marked Green got 39% of the move he asked for and the
/// other 61% waited under a slider marked Yellow.
///
/// A green test cannot catch that by construction: every assertion in `DominantBandTests`
/// was about which band a colour resolves to, and the answer was right. The gap was between
/// the engine and the English, and only a test that knows what the English MEANS closes it.
///
/// SO THIS FILE ENCODES A JUDGEMENT, and says so rather than pretending to be arithmetic:
/// the conventional sRGB for a colour word. Those triples are the ordinary ones — the CSS /
/// X11 values where they exist. They are opinions about language, not measurements of the
/// engine, which is why they live in a test and not in `ColorEngine`.
///
/// THE RULE WAS HALF A BAND while centres were 45° apart. WS-31 made the bands uneven, and
/// the rule is now the one the half-band test stood in for: the colour a name means belongs
/// to the band of that name (see `testEveryBandIsNamedForTheColourAtItsOwnCentre`).
///
/// This is the assertion that would have caught B1-08 on the day the names were written.
final class MixerBandNameTests: XCTestCase {

    /// Conventional sRGB for each colour word the mixer uses or might use.
    private static let conventional: [String: (Double, Double, Double)] = [
        "Red": (255, 0, 0),
        "Orange": (255, 128, 0),
        "Amber": (255, 191, 0),
        "Yellow": (255, 255, 0),
        "Lime": (191, 255, 0),
        "Green": (0, 255, 0),
        "Mint": (0, 255, 178),
        "Teal": (0, 128, 128),
        "Aqua": (0, 255, 255),
        "Cyan": (0, 255, 255),
        "Azure": (0, 127, 255),
        "Blue": (0, 0, 255),
        "Purple": (128, 0, 255),
        "Violet": (143, 0, 255),
        "Magenta": (255, 0, 255),
        "Rose": (255, 0, 127),
        "Pink": (255, 0, 153),
    ]

    /// Hue angle in degrees, the ordinary HSV one. Not OKLab: the question here is what a
    /// colour WORD means to a person, and colour words are learned off screens and paint
    /// charts, not off a perceptual transform.
    private static func hueDegrees(_ rgb: (Double, Double, Double)) -> Double {
        let r = rgb.0 / 255, g = rgb.1 / 255, b = rgb.2 / 255
        let hi = max(r, g, b), lo = min(r, g, b)
        let c = hi - lo
        guard c > 0 else { return 0 }
        let h: Double
        if hi == r { h = ((g - b) / c).truncatingRemainder(dividingBy: 6) }
        else if hi == g { h = (b - r) / c + 2 }
        else { h = (r - g) / c + 4 }
        return (h * 60).truncatingRemainder(dividingBy: 360) + (h < 0 ? 360 : 0)
    }

    private static func separation(_ a: Double, _ b: Double) -> Double {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    /// THE RULE, SINCE WS-31: THE COLOUR A NAME MEANS MUST BELONG TO THAT BAND.
    ///
    /// It was "the name sits within half the 45° spacing of the band's centre", which was
    /// the right rule for equal bands and is meaningless for uneven ones — the Blue band is
    /// centred on sky blue (OKLCh 251.5°, HSV ≈ 213°) and still owns pure blue outright.
    /// What a photographer relies on is the direction that test was standing in for: the
    /// slider marked Green grades green. So the conventional sRGB of each band's name,
    /// through the engine's own membership, must have that band as its dominant band,
    /// and hold at least 0.8 of its weight there.
    func testEveryBandIsNamedForTheColourAtItsOwnCentre() {
        var report = ""
        let toWorking = RGBColorSpace.srgb.matrix(to: .rec2020)
        func lin(_ v: Double) -> Double {
            v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        for i in 0..<ColorEngine.bandCount {
            let name = ColorEngine.bandNames[i]
            guard let word = Self.conventional[name] else {
                XCTFail("band \(i) is called \"\(name)\", which this test has no "
                            + "conventional sRGB for. Add it to `conventional` with the "
                            + "ordinary value for that colour word — deliberately, "
                            + "because that entry is what the name is then judged against")
                continue
            }
            let c = toWorking.apply(RGB(lin(word.0 / 255), lin(word.1 / 255), lin(word.2 / 255)))
            let hue = OKLabTransform.working.toLCh(c).h
            let w = ColorEngine.bandWeights(hue: hue)
            report += String(format: "  band %d  %-8s name at OKLCh %6.1f°  centre %6.1f°  weight %.2f\n",
                             i, (name as NSString).utf8String!, hue,
                             ColorEngine.bandHueCentres[i], w[i])
            XCTAssertEqual(ColorEngine.dominantBand(hue: hue, arcs: ColorEngine.canonicalArcs), i,
                           "the colour called \"\(name)\" belongs to another band")
            XCTAssertGreaterThanOrEqual(w[i], 0.8,
                                        "the colour called \"\(name)\" is only \(w[i]) in its band")
        }
        print("MIXERNAMES\n" + report)
    }

    /// A rename must not be a re-anchor wearing a rename's clothes — and a re-anchor must
    /// be a deliberate one. WS-31 moved the centres (docs/quality/lanes/WS-31); this pins
    /// where they are now, and the legacy grid the B&W mix and pre-WS-31 recipes use.
    func testTheBandCentresAreWhereTheGoldenLockSaysTheyAre() {
        let pinned = [17.2, 60.925, 102.25, 143.225, 203.7, 253.25, 295.75, 336.3]
        for i in 0..<ColorEngine.bandCount {
            XCTAssertEqual(ColorEngine.bandHueCentres[i], pinned[i], accuracy: 1e-9,
                           "band \(i)'s centre moved. If that is deliberate it is a "
                               + "pipelineVersion bump, because every recipe that touched "
                               + "the mixer re-renders")
        }
        XCTAssertEqual(ColorEngine.bandAnchorDegrees, 29.23, accuracy: 1e-12)
        XCTAssertEqual(ColorEngine.bandSpacingDegrees, 45.0, accuracy: 1e-12)
        for i in 0..<ColorEngine.bandCount {
            let expected = (29.23 + 45.0 * Double(i)).truncatingRemainder(dividingBy: 360)
            XCTAssertEqual(ColorEngine.uniformBandHueCentres[i], expected, accuracy: 1e-9)
        }
    }

    /// The names reach a person, so they have to survive being read.
    func testTheNamesAreDistinctAndFitTheColumnTheyAreDrawnIn() {
        XCTAssertEqual(Set(ColorEngine.bandNames).count, ColorEngine.bandCount,
                       "two bands share a name: \(ColorEngine.bandNames)")
        // `LayoutMetricSupport.swift:381` sizes the mixer's label column from Magenta as
        // the widest of the eight, and the ui-layout lane measures against it. A longer
        // name than that is not wrong, but it is a layout change and has to be made there
        // in the same commit rather than discovered on a macOS runner.
        let widest = ColorEngine.bandNames.max(by: { $0.count < $1.count }) ?? ""
        XCTAssertEqual(widest.count, "Magenta".count,
                       "\"\(widest)\" is now the widest band name, not Magenta — update "
                           + "LayoutMetricSupport's mixer row in this commit")
    }
}

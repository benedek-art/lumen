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
/// THE RULE IS HALF A BAND. Centres are 45° apart, so a name more than 22.5° from its own
/// centre is describing the neighbouring band's territory, and at that point the label is
/// worse than no label. Inside half a band the name is the closest ordinary word for where
/// the band sits, and arguing about the last few degrees is taste.
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

    /// Half of the 45° band spacing. Past this, the name belongs to the next band along.
    private static let halfBand = 22.5

    func testEveryBandIsNamedForTheColourAtItsOwnCentre() {
        XCTAssertEqual(ColorEngine.bandNames.count, ProofFrames.bandCentreSRGB.count,
                       "the name list and the centre table have come apart")

        var report = ""
        var worst = (name: "", drift: 0.0)
        for i in 0..<ColorEngine.bandCount {
            let name = ColorEngine.bandNames[i]
            guard let word = Self.conventional[name] else {
                XCTFail("band \(i) is called \"\(name)\", which this test has no "
                            + "conventional sRGB for. Add it to `conventional` with the "
                            + "ordinary value for that colour word — deliberately, "
                            + "because that entry is what the name is then judged against")
                continue
            }
            let centre = Self.hueDegrees(ProofFrames.bandCentreSRGB[i])
            let drift = Self.separation(centre, Self.hueDegrees(word))
            report += String(format: "  band %d  %-8s centre %6.1f°  name %6.1f°  off %5.1f°\n",
                             i, (name as NSString).utf8String!, centre,
                             Self.hueDegrees(word), drift)
            if drift > worst.drift { worst = (name, drift) }

            XCTAssertLessThan(
                drift, Self.halfBand,
                "band \(i) is called \"\(name)\" but its centre sits \(drift)° away — "
                    + "more than half of the 45° spacing, so the name is describing the "
                    + "band next door. Either rename it for where it sits, or, if the "
                    + "centre is what is wrong, that is a `pipelineVersion` bump and a "
                    + "migration (see `ColorEngine.bandNames`) and not a quiet edit")
        }
        print("MIXERNAMES worst \(worst.name) at \(worst.drift)°, limit \(Self.halfBand)°\n"
              + report)
    }

    /// A rename must not be a re-anchor wearing a rename's clothes.
    ///
    /// The centres are golden-locked: moving one changes what every saved mixer edit
    /// renders as. The B1-08 rename was affordable precisely because it left them alone,
    /// so the thing that made it cheap is worth pinning next to the thing it enabled.
    func testTheBandCentresAreWhereTheGoldenLockSaysTheyAre() {
        XCTAssertEqual(ColorEngine.bandAnchorDegrees, 29.23, accuracy: 1e-12)
        XCTAssertEqual(ColorEngine.bandSpacingDegrees, 45.0, accuracy: 1e-12)
        for i in 0..<ColorEngine.bandCount {
            let expected = (29.23 + 45.0 * Double(i)).truncatingRemainder(dividingBy: 360)
            XCTAssertEqual(ColorEngine.bandHueCentres[i], expected, accuracy: 1e-9,
                           "band \(i)'s centre moved. If that is deliberate it is a "
                               + "pipelineVersion bump with a badged migration, because "
                               + "every recipe that touched the mixer re-renders")
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

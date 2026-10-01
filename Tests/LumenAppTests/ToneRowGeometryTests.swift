// Two surfaces write the same five recipe fields, and they now agree about how.
//
// `BasicPanel` builds a `LumenSlider` per basic tone row: clamped to `range`, snapped to
// `step`, with a wider `hardRange` accepted from typing. `HistogramView`'s five draggable
// zone handles write the SAME five fields, and did it through their own clamp —
// `slider == .exposure ? 5 : 100` — with no step at all. A histogram drag could leave
// Exposure at 0.374296…, a value the slider that displays it can neither produce nor
// return to, and whose readout then shows a number the recipe does not hold.
//
// `Lumen.ToneRow` is the single statement of that geometry. These tests are what stop the
// two drifting again.
#if os(macOS)
import XCTest
import LumenCore
@testable import LumenApp

final class ToneRowGeometryTests: XCTestCase {

    /// Every histogram handle maps to a row. Without this, a sixth `ZoneSlider` would
    /// fall through `setTone`'s lookup and be written with no clamp and no snap at all —
    /// which is the defect this file is about, reintroduced by an enum case.
    func testEveryHistogramHandleHasARow() {
        for slider in Histogram.ZoneSlider.allCases {
            XCTAssertNotNil(Lumen.ToneRow(rawValue: slider.rawValue),
                            "\(slider.rawValue) has no Lumen.ToneRow, so the histogram "
                                + "would write it unclamped and unsnapped")
        }
    }

    /// The clamp.
    func testResolveClampsToTheDragRange() {
        XCTAssertEqual(Lumen.ToneRow.exposure.resolve(99), 5, accuracy: 1e-12)
        XCTAssertEqual(Lumen.ToneRow.exposure.resolve(-99), -5, accuracy: 1e-12)
        XCTAssertEqual(Lumen.ToneRow.highlights.resolve(1000), 100, accuracy: 1e-12)
        XCTAssertEqual(Lumen.ToneRow.blacks.resolve(-1000), -100, accuracy: 1e-12)
    }

    /// The snap — the half that was missing entirely.
    func testResolveSnapsToTheStepTheSliderUses() {
        // Exposure moves in hundredths; a drag that computes 0.374296 must land where a
        // slider drag would.
        XCTAssertEqual(Lumen.ToneRow.exposure.resolve(0.374296), 0.37, accuracy: 1e-12)
        XCTAssertEqual(Lumen.ToneRow.exposure.resolve(-1.2349), -1.23, accuracy: 1e-12)
        // The ±100 rows move in whole units.
        XCTAssertEqual(Lumen.ToneRow.shadows.resolve(42.7), 43, accuracy: 1e-12)
        XCTAssertEqual(Lumen.ToneRow.whites.resolve(-17.2), -17, accuracy: 1e-12)
    }

    /// A resolved value is a fixed point: writing it again cannot move it. This is the
    /// property that makes the two surfaces interchangeable rather than merely similar.
    func testResolvedValuesAreStableUnderASecondWrite() {
        for row in Lumen.ToneRow.allCases {
            for raw in [-1234.5, -7.77, -0.333, 0, 0.333, 7.77, 1234.5] {
                let once = row.resolve(raw)
                XCTAssertEqual(row.resolve(once), once, accuracy: 1e-12,
                               "\(row.rawValue) moved a value it had already resolved")
            }
        }
    }

    /// Non-finite input cannot reach a recipe. `Double("nan")` parses, and `max(NaN, lo)`
    /// is NaN because every comparison against NaN is false — the failure mode
    /// `LumenSlider.commitText` already guards for on the typing path.
    func testNonFiniteIsRefusedRatherThanClamped() {
        for row in Lumen.ToneRow.allCases {
            XCTAssertEqual(row.resolve(.nan), 0)
            XCTAssertEqual(row.resolve(.infinity), 0)
            XCTAssertEqual(row.resolve(-.infinity), 0)
        }
    }

    /// The hard range is wider than the drag range on Exposure and nowhere else, which is
    /// what `BasicPanel` spells at its call sites.
    func testTheHardRangeIsWiderOnlyWhereThePanelSaysItIs() {
        XCTAssertEqual(Lumen.ToneRow.exposure.hardRange, -10...10)
        XCTAssertEqual(Lumen.ToneRow.exposure.range, -5...5)
        for row in Lumen.ToneRow.allCases where row != .exposure {
            XCTAssertEqual(row.hardRange, row.range,
                           "\(row.rawValue) grew a hard range the panel does not offer")
        }
    }
}
#endif

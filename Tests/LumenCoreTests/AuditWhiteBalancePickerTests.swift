import XCTest
@testable import LumenCore

final class AuditWhiteBalancePickerTests: XCTestCase {
    private func checkTargets(_ tints: [Double], space: RGBColorSpace = .rec2020) {
        let asShot = (kelvin: 4900.0, tint: -15.0)
        let current = WhiteBalanceEngine(asShotKelvin: asShot.kelvin, asShotTint: asShot.tint,
                                         targetKelvin: 7200, targetTint: 40, space: space)
        for kelvin in [3200.0, 5500, 12000] {
            for tint in tints {
                let manual = WhiteBalanceEngine(asShotKelvin: asShot.kelvin, asShotTint: asShot.tint,
                                                targetKelvin: kelvin, targetTint: tint, space: space)
                let decoded = manual.matrix.inverse.apply(RGB(gray: 0.18))
                let sample = current.apply(decoded)
                let solved = WhiteBalanceEngine.neutralizing(sample: sample,
                    asShotKelvin: asShot.kelvin, asShotTint: asShot.tint,
                    current: current, space: space)
                let picked = WhiteBalanceEngine(asShotKelvin: asShot.kelvin, asShotTint: asShot.tint,
                                                targetKelvin: solved.kelvin, targetTint: solved.tint,
                                                space: space).apply(decoded)
                let mean = (picked.r + picked.g + picked.b) / 3
                XCTAssertGreaterThan(mean, 0)
                let residual = max(abs(picked.r / mean - 1),
                                   max(abs(picked.g / mean - 1), abs(picked.b / mean - 1)))
                XCTAssertLessThan(residual, 0.003, "\(kelvin) K / \(tint): returned \(solved)")
                XCTAssertTrue((-300...300).contains(solved.tint))
            }
        }
    }

    func testPickerCanReachNegativeTintHardRangeAfterUndoingCurrentWB() {
        checkTargets([-300, -250, -175])
    }

    func testPositiveHardRangeUsesTheSamePhysicalTintGuardAsManualEdits() {
        checkTargets([175, 250, 300])
    }

    func testOrdinaryTargetsAndAlternativeWorkingSpaceStillNeutralize() {
        checkTargets([-40, 0, 40], space: .srgb)
    }

    /// The picker and the magenta guard must agree on the NUMBER, not only on the
    /// picture. Every tint past `tintLimit(kelvin:)` renders identically, so a search
    /// on the rendered residual cannot tell +10 from +3.5 at 2000 K and kept whichever
    /// grid point it met first. The pixels were right; the recipe stored +10, the Tint
    /// row showed +10, and `BasicPanel.boundedTintCaption` immediately announced
    /// "bounded by physics at +4" on a value the user's own click had just written.
    /// `ColorTemperature.temperatureAndTint` — the other eyedropper — already reports
    /// the tint the render will use (`TintGuardTests`); this holds the WB picker to
    /// the same contract.
    func testThePickerReportsTheTintTheRenderWillUse() {
        let current = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                         targetKelvin: nil, targetTint: nil)
        var checked = 0
        for kelvin in [2000.0, 2500, 2800, 3200, 4000] {
            for tint in [40.0, 120, 300] {
                let manual = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                                targetKelvin: kelvin, targetTint: tint)
                let decoded = manual.matrix.inverse.apply(RGB(gray: 0.18))
                let solved = WhiteBalanceEngine.neutralizing(
                    sample: current.apply(decoded), asShotKelvin: 5500, asShotTint: 0,
                    current: current)
                let effective = ColorTemperature.clampedTint(kelvin: solved.kelvin,
                                                             tint: solved.tint)
                XCTAssertEqual(solved.tint, effective, accuracy: 1e-9,
                               "target \(kelvin) K / +\(tint): the picker wrote tint "
                                   + "\(solved.tint) but the render uses \(effective) at "
                                   + "\(solved.kelvin) K")
                // And the reported pair still neutralizes the sample.
                let picked = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                                targetKelvin: solved.kelvin,
                                                targetTint: solved.tint).apply(decoded)
                let mean = (picked.r + picked.g + picked.b) / 3
                XCTAssertLessThan(max(abs(picked.r / mean - 1), abs(picked.g / mean - 1),
                                      abs(picked.b / mean - 1)), 0.003)
                checked += 1
            }
        }
        XCTAssertEqual(checked, 15)
    }
}

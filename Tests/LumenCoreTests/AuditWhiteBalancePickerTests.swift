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
}

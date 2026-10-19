import XCTest
@testable import LumenCore

final class NeutralAbsoluteWhiteBalanceIdentityTests: XCTestCase {
    func testNeutralAbsoluteFlagMatchesExactEngineIdentity() {
        let balanced = WhiteBalanceEngine.Neutral(kelvin: 5500, tint: 0)
        for tint: Double? in [nil, 0] {
            let engine = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                targetKelvin: 5500, targetTint: 0, space: .rec2020)
            let local = ReferenceRenderer.LocalWhiteBalance(kelvin: 5500, tint: tint,
                amount: 1, balanced: balanced, space: .rec2020)
            XCTAssertEqual(engine.matrix, .identity)
            XCTAssertTrue(engine.isIdentity)
            XCTAssertEqual(local.matrix, engine.matrix)
            XCTAssertEqual(local.isIdentity, engine.isIdentity)
        }
    }

    func testNonneutralAbsoluteMatrixAndFlagRetainEngineResult() {
        let balanced = WhiteBalanceEngine.Neutral(kelvin: 5500, tint: 0)
        for target in [3200.0, 7500.0] {
            let engine = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                targetKelvin: 1e6 / (1e6 / 5500.0 + (1e6 / target - 1e6 / 5500.0)), targetTint: 17, space: .rec2020)
            let local = ReferenceRenderer.LocalWhiteBalance(kelvin: target, tint: 17,
                amount: 1, balanced: balanced, space: .rec2020)
            XCTAssertFalse(engine.isIdentity)
            XCTAssertEqual(local.matrix, engine.matrix)
            XCTAssertEqual(local.isIdentity, engine.isIdentity)
        }
    }
}

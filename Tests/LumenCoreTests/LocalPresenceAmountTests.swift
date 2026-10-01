import XCTest
@testable import LumenCore

final class LocalPresenceAmountTests: XCTestCase {
    func testControlClampsBeforeLocalStrengthAndAggregateStopsAtTwo() {
        for amount in [-300.0, -100, -50, 0, 50, 100, 300] {
            for strength in [-1.0, 0, 0.5, 1, 2, 4] {
                let expected = max(-100, min(100, amount)) * max(0, min(2, strength))
                XCTAssertEqual(DetailEngine.scaledPresenceAmount(amount, strength: strength), expected)
            }
            XCTAssertEqual(DetailEngine.scaledPresenceAmount(amount), max(-100, min(100, amount)))
        }
    }

    func testGlobalAndExplicitUnitStrengthAreBitIdentical() {
        let image = ImageBuffer(width: 48, height: 32) { u, v in
            RGB(gray: 0.18 + 0.035 * sin(80 * u) * cos(60 * v))
        }
        let decomposition = DetailEngine.Decomposition(image: image, workingRadius: 3,
                                                        space: .rec2020)
        for amount in [-100.0, -50, 0, 50, 100] {
            XCTAssertEqual(DetailEngine.applyTexture(image, amount: amount,
                decomposition: decomposition).pixels,
                DetailEngine.applyTexture(image, amount: amount, strength: 1,
                decomposition: decomposition).pixels)
            XCTAssertEqual(DetailEngine.applyClarity(image, amount: amount,
                decomposition: decomposition).pixels,
                DetailEngine.applyClarity(image, amount: amount, strength: 1,
                decomposition: decomposition).pixels)
        }
    }
}

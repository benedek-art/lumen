// A release that changed nothing (a thumb click, a crop-tool drag) moves only the settle
// tick. With a settle of that exact request on screen, the loupe must not render the same
// picture again at full resolution in front of the next real request.
#if os(macOS)

import Foundation
import XCTest
@testable import LumenApp
@testable import LumenCore

final class RedundantSettleTests: XCTestCase {

    private func key(tick: Int, longEdge: Int = 2048,
                     uncropped: Bool = false) -> ViewerRenderKey {
        ViewerRenderKey(url: URL(fileURLWithPath: "/roll/a.ARW"), recipe: Recipe(),
                        longEdge: longEdge, strokeRefs: [], softProof: nil,
                        matteKinds: [], showingUncropped: uncropped,
                        settleTick: tick, regionUnit: nil)
    }

    func testTwoRequestsDifferingOnlyByTheTickHaveTheSameInputs() {
        XCTAssertNotEqual(key(tick: 1), key(tick: 2))
        XCTAssertEqual(key(tick: 1).ignoringSettleTick, key(tick: 2).ignoringSettleTick)
    }

    func testAnyRealInputStillDiffers() {
        XCTAssertNotEqual(key(tick: 1).ignoringSettleTick,
                          key(tick: 2, longEdge: 2304).ignoringSettleTick)
        XCTAssertNotEqual(key(tick: 1).ignoringSettleTick,
                          key(tick: 2, uncropped: true).ignoringSettleTick)
    }

    /// The skip has to come before the quality loop, or it saves nothing.
    func testLoadConsultsTheRuleBeforeTheQualityPass() throws {
        let code = blankingComments(in: try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LumenApp/LoupeView.swift"),
            encoding: .utf8))
        let rule = try XCTUnwrap(code.range(of: "FrameDelivery.settleIsRedundant("))
        let quality = try XCTUnwrap(code.range(of: "while attempt < PhotoRenderModel.qualityAttempts"))
        XCTAssertLessThan(rule.lowerBound, quality.lowerBound)
    }
}
#endif

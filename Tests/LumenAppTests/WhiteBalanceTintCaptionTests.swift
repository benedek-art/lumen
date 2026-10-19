#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

final class WhiteBalanceTintCaptionTests: XCTestCase {
    func testWarmAbsoluteMaskPlateauReportsTheExistingEffectiveTargetBound() throws {
        let balanced = WhiteBalanceEngine.Neutral(kelvin: 5500, tint: 0)
        let lower = ReferenceRenderer.LocalWhiteBalance(kelvin: 2000, tint: 50,
                                                       amount: 1, balanced: balanced)
        let upper = ReferenceRenderer.LocalWhiteBalance(kelvin: 2000, tint: 150,
                                                       amount: 1, balanced: balanced)
        // The engine guard is intentionally unchanged: two distinct saved/UI values
        // produce the same correction. The caption explains the otherwise dead travel.
        for basis in [RGB(1, 0, 0), RGB(0, 1, 0), RGB(0, 0, 1)] {
            XCTAssertEqual(lower.apply(basis), upper.apply(basis))
        }
        let effective = ColorTemperature.clampedTint(kelvin: 2000, tint: 50)
        XCTAssertLessThan(effective, 50)
        let caption = try XCTUnwrap(WhiteBalanceTintCaption.text(kelvin: 2000, tint: 50,
                                                                atFullStrength: true))
        XCTAssertEqual(caption, WhiteBalanceTintCaption.text(kelvin: 2000, tint: 150,
                                                           atFullStrength: true))
        XCTAssertEqual(caption, "At full strength, magenta is bounded by physics at +\(Int(effective.rounded())) for 2000 K.")
        XCTAssertFalse(caption.contains("the render uses"),
                       "partial/group strength can interpolate to another bound")
    }

    func testOrdinaryAndNonMagentaTargetsNeedNoBoundCaption() {
        for tint in [-150.0, 0, 10] {
            XCTAssertNil(WhiteBalanceTintCaption.text(kelvin: 6500, tint: tint))
            XCTAssertNil(WhiteBalanceTintCaption.text(kelvin: 6500, tint: tint,
                                                     atFullStrength: true))
        }
    }

    func testUnrepresentableAndNonfiniteCaptionNumbersAreSafelyOmitted() {
        for kelvin in [1e300, -1e300, Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertNil(WhiteBalanceTintCaption.text(kelvin: kelvin, tint: 150))
            XCTAssertNil(WhiteBalanceTintCaption.text(kelvin: kelvin, tint: 150,
                                                     atFullStrength: true))
        }
        for tint in [Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertNil(WhiteBalanceTintCaption.text(kelvin: 2000, tint: tint))
            XCTAssertNil(WhiteBalanceTintCaption.text(kelvin: 2000, tint: tint,
                                                     atFullStrength: true))
        }
    }

    func testGlobalCaptionKeepsItsExistingWordingAndTargetSemantics() throws {
        let effective = ColorTemperature.clampedTint(kelvin: 2000, tint: 50)
        XCTAssertEqual(WhiteBalanceTintCaption.text(kelvin: 2000, tint: 50),
            "Magenta is bounded by physics at +\(Int(effective.rounded())) for 2000 K — the render uses that value.")
    }
}
#endif

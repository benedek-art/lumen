// The reported-versus-delivered reconciliation (docs/32 owner round): a portrait
// exposure is a landscape sensor readout plus an EXIF orientation, and every overlay
// that places something in the photograph's coordinates was laid out against the
// landscape number. The owner saw it as the crop tool "stretching my entire image out
// into a horizontal landscape photo, not a vertical photo like it is".
import XCTest
@testable import LumenCore

final class FrameOrientationTests: XCTestCase {

    private let landscapeSensor = CGSize(width: 7008, height: 4672)
    private let portraitFrame = CGSize(width: 4672, height: 7008)

    /// The reported defect, stated as arithmetic.
    func testAPortraitDeliveryFromALandscapeSensorIsTransposed() {
        XCTAssertTrue(FrameOrientation.isTransposed(reported: landscapeSensor,
                                                    delivered: portraitFrame))
        XCTAssertEqual(FrameOrientation.sourceSize(reported: landscapeSensor,
                                                   transposed: true),
                       portraitFrame,
                       "the overlay must be laid out against the frame on screen")
    }

    /// And the case that must not change: a landscape photograph, where the two already
    /// agree. Every function here has to be the identity there, or the reconciliation
    /// introduces the very defect it removes.
    func testAgreementIsAlwaysTheIdentity() {
        XCTAssertFalse(FrameOrientation.isTransposed(reported: landscapeSensor,
                                                     delivered: landscapeSensor))
        XCTAssertFalse(FrameOrientation.isTransposed(reported: portraitFrame,
                                                     delivered: portraitFrame))
        XCTAssertEqual(FrameOrientation.sourceSize(reported: landscapeSensor,
                                                   transposed: false),
                       landscapeSensor)
    }

    /// A delivery at a different SCALE is the same frame — the renderer hands back a
    /// proxy, not the sensor, and a proxy is not a rotation.
    func testAScaledDeliveryOfTheSameFrameIsNotTransposed() {
        XCTAssertFalse(FrameOrientation.isTransposed(
            reported: landscapeSensor,
            delivered: CGSize(width: 2560, height: 1707)))
        XCTAssertTrue(FrameOrientation.isTransposed(
            reported: landscapeSensor,
            delivered: CGSize(width: 1707, height: 2560)))
    }

    /// A frame near enough to square that turning it sideways changes the plate by
    /// less than the layout's own rounding: the answer would be a coin flip dressed as
    /// a decision, so it is false.
    func testNearSquareFramesAreNeverTransposed() {
        XCTAssertFalse(FrameOrientation.isTransposed(
            reported: CGSize(width: 1001, height: 1000),
            delivered: CGSize(width: 1000, height: 4000)))
        // Exactly square is the limiting case of the same argument.
        XCTAssertFalse(FrameOrientation.isTransposed(
            reported: CGSize(width: 4000, height: 4000),
            delivered: CGSize(width: 2000, height: 3000)))
        XCTAssertFalse(FrameOrientation.isTransposed(
            reported: CGSize(width: 3000, height: 2000),
            delivered: CGSize(width: 2000, height: 2000)))
        // …and just past the tolerance it answers again, so the guard is a threshold
        // rather than a way of never answering.
        XCTAssertTrue(FrameOrientation.isTransposed(
            reported: CGSize(width: 1100, height: 1000),
            delivered: CGSize(width: 1000, height: 1100)))
    }

    func testDegenerateSizesAnswerFalseRatherThanDividing() {
        XCTAssertFalse(FrameOrientation.isTransposed(reported: .zero,
                                                     delivered: portraitFrame))
        XCTAssertFalse(FrameOrientation.isTransposed(reported: landscapeSensor,
                                                     delivered: .zero))
        XCTAssertFalse(FrameOrientation.isTransposed(
            reported: CGSize(width: CGFloat.nan, height: 100),
            delivered: portraitFrame))
        XCTAssertFalse(FrameOrientation.isTransposed(
            reported: landscapeSensor,
            delivered: CGSize(width: -10, height: 100)))
    }

    /// Transposing twice is the identity — the property that makes it safe to ask the
    /// question again on the next frame.
    func testTransposingIsAnInvolution() {
        XCTAssertEqual(FrameOrientation.transposed(
            FrameOrientation.transposed(landscapeSensor)), landscapeSensor)
    }
}

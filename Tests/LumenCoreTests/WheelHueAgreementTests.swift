// B2-02, from both ends: the angle on the grading wheel and the angle in the engine are
// the same angle, in the same colour system.
//
// They were not. The wheel painted `Color(hue: i/12, saturation: 0.72, brightness: 0.8)`
// — SwiftUI HSB — while `ZoneOffset.init` takes the same number and uses it as an OKLab
// **ab** angle: `a = amplitude·cos(θ)`, `b = amplitude·sin(θ)`. Two hue circles wearing
// one number, measured at mean 29.6° and worst 50.3° apart. Drag the puck to the orange
// the ring shows and the picture goes yellow.
//
// The fix repaints the ring through `Lumen.hueColor`, the conversion the mixer's band
// ring already used. That makes the paint DEPEND on the engine's convention, so this
// file pins the convention: if the engine ever stops reading `wheel.hue` as an OKLCh
// hue angle, the wheel silently goes wrong again and only this says so.
import XCTest
@testable import LumenCore

final class WheelHueAgreementTests: XCTestCase {

    /// The engine's half of the contract: the (a, b) offset a wheel produces sits at
    /// exactly the angle the wheel was set to.
    func testAWheelsHueIsTheOKLabHueAngleOfTheOffsetItProduces() {
        for degrees in stride(from: 0.0, to: 360.0, by: 7.5) {
            let offset = WheelTint(Wheel(hue: degrees, sat: 1, lum: 0))
            let measured = (atan2(offset.b, offset.a) * 180 / .pi + 360)
                .truncatingRemainder(dividingBy: 360)
            XCTAssertEqual(measured, degrees, accuracy: 1e-9,
                           "a wheel set to \(degrees)° produced an offset at \(measured)°, "
                               + "so the ring cannot be painted from the wheel's number")
        }
    }

    /// And the magnitude is Saturation, so painting the ring at a fixed chroma is honest
    /// about hue while the puck's radius carries the strength.
    func testSaturationIsTheOffsetsChromaAndHueIsUnchangedByIt() {
        for sat in [0.1, 0.5, 1.0] {
            let offset = WheelTint(Wheel(hue: 210, sat: sat, lum: 0))
            let chroma = (offset.a * offset.a + offset.b * offset.b).squareRoot()
            XCTAssertEqual(chroma, GradeEngine.maxABOffset * sat, accuracy: 1e-12)
            let measured = (atan2(offset.b, offset.a) * 180 / .pi + 360)
                .truncatingRemainder(dividingBy: 360)
            XCTAssertEqual(measured, 210, accuracy: 1e-9,
                           "saturation \(sat) moved the hue")
        }
    }

    /// Saturation 0 stays a bit-exact no-op — the property the engine's own comment
    /// calls out, and the one a "paint it from the engine" change could quietly break by
    /// routing zero through a trig call.
    func testSaturationZeroIsExactlyNeutral() {
        for degrees in [0.0, 90, 180, 270, 359.9] {
            let offset = WheelTint(Wheel(hue: degrees, sat: 0, lum: 0))
            XCTAssertEqual(offset.a, 0)
            XCTAssertEqual(offset.b, 0)
            XCTAssertTrue(offset.isNeutral, "hue \(degrees) at sat 0 was not neutral")
        }
    }
}

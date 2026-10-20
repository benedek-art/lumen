// DisplayTransformBlueRotationTests.swift
// docs/04 §6: the primaries inset "attenuates and rotates R/G/B — the AgX mechanism
// that ... kills the Notorious Six per-channel hue skews (bright reds snapping
// orange, blues going magenta)", and Hue preservation 100 means "hue-stable through
// the midtones".
//
// The blue rotation shipped with the wrong sign. `insetSpace` turns each primary
// counter-clockwise about white in xy by `rotation` radians, and Rec.2020 blue sits
// at about 238° around D65, so +0.06 turned the inset blue TOWARD the purple line —
// the same direction the per-channel curve already skews a bright blue. Purity
// restore only undoes 40% of the inset (25% on Film Base), so most of the rotation
// survives to the output even at Hue preservation 100: the transform was adding
// to the blue-to-magenta skew it exists to remove. Measured in OKLCh, LED blue at
// luminance 0.18 drifted +41° by +2 EV on Neutral (+22° with no rotation at all),
// a sky blue was off by +6° at every exposure from −3 EV up, and jersey blue +12°.
// Nothing pinned the direction; the value came in with no rationale and no test.
//
// −0.04 is the measured minimax over the patches below on all four curved presets
// (LED blue ≤ 5°, sky ≤ 3.3°, jersey ≤ 5.3°, skin/orange/purple ≤ 5.6°), and it
// leaves red, green and cyan where they were. The red rotation is left alone: in
// the midtones it moves sRGB red by about nothing, and its only effect is in the
// last stops before white, where the path-to-white ramp decides the hue anyway.
//
// The sweep stops at +2 EV on purpose. Past that the path-to-white ramp takes over
// and every rotation (including none) swings a blue's hue by tens of degrees on its
// way to white, which is bleaching doing its job, not this defect.

import XCTest
@testable import LumenCore

final class DisplayTransformBlueRotationTests: XCTestCase {

    /// Every preset that runs the curve and the inset. Linear has neither.
    private let curvedPresets = DisplayTransformParams.presetNames.filter { $0 != "Linear" }

    /// An sRGB colour in the Rec.2020 working space, scaled to luminance 0.18 so
    /// 0 EV is a mid-grey-bright patch of that colour.
    private func midtone(_ srgb: RGB) -> RGB {
        let c = RGBColorSpace.srgb.matrix(to: .rec2020).apply(srgb)
        let k = 0.18 / RGBColorSpace.rec2020.luminance(c)
        return RGB(c.r * k, c.g * k, c.b * k)
    }

    /// Signed OKLCh hue change through the transform at `ev` stops, wrapped to
    /// (−180°, 180°]; nil when the output is too close to neutral for its hue to mean
    /// anything.
    private func hueDrift(_ t: DisplayTransform, _ c: RGB, ev: Double) -> Double? {
        let ctx = OKLabTransform.working
        let k = pow(2.0, ev)
        let out = ctx.toLCh(t.apply(RGB(c.r * k, c.g * k, c.b * k), gamut: nil))
        guard out.C > 0.03 else { return nil }
        let d = out.h - ctx.toLCh(c).h
        return (d + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    private let evs = stride(from: -3.0, through: 2.0, by: 0.25)

    /// The headline: a saturated LED blue holds its hue from −3 to +2 EV on every
    /// curved preset. With +0.06 it drifted 38–43° toward purple; with −0.04, ≤ 5°.
    func testTheDisplayTransformDoesNotTurnBrightBluesPurple() {
        let led = midtone(RGB(0.05, 0.05, 1))
        for preset in curvedPresets {
            let t = DisplayTransform(DisplayTransformParams.preset(named: preset))
            for ev in evs {
                guard let d = hueDrift(t, led, ev: ev) else { continue }
                XCTAssertLessThanOrEqual(abs(d), 10,
                    "\(preset): LED blue at \(ev) EV turned \(d)° (positive is toward purple)")
            }
        }
    }

    /// Hue-stable through the midtones is a promise about ordinary blues too: a sky
    /// and a jersey blue, not just an LED. Both were off by a constant +6°/+8–12° at
    /// every exposure, which is the rotation, not the shoulder.
    func testSkyAndJerseyBluesStayOnHueThroughTheMidtones() {
        let sky = midtone(RGB(0.3, 0.5, 0.9))
        let jersey = midtone(RGB(0.05, 0.15, 0.6))
        for preset in curvedPresets {
            let t = DisplayTransform(DisplayTransformParams.preset(named: preset))
            for ev in evs {
                if let d = hueDrift(t, sky, ev: ev) {
                    XCTAssertLessThanOrEqual(abs(d), 4, "\(preset): sky at \(ev) EV turned \(d)°")
                }
                if let d = hueDrift(t, jersey, ev: ev) {
                    XCTAssertLessThanOrEqual(abs(d), 6, "\(preset): jersey at \(ev) EV turned \(d)°")
                }
            }
        }
    }

    /// The sign tripwire. Whatever magnitude a preset is retuned to, its blue
    /// rotation must pull a bright blue's hue BACK from purple relative to no
    /// rotation at all — the direction the per-channel skew already goes. The
    /// shipped +0.06 doubled the drift instead of cancelling it.
    func testTheBlueRotationCountersTheSkewItsAttenuationLeaves() {
        let led = midtone(RGB(0.05, 0.05, 1))
        for preset in curvedPresets {
            let shipped = DisplayTransformParams.preset(named: preset)
            var unrotated = shipped
            unrotated.rotation.b = 0
            let withRotation = DisplayTransform(shipped)
            let without = DisplayTransform(unrotated)
            for ev in [-2.0, 0.0, 1.0, 2.0] {
                guard let a = hueDrift(withRotation, led, ev: ev),
                      let b = hueDrift(without, led, ev: ev) else { continue }
                XCTAssertLessThan(a, b,
                    "\(preset) at \(ev) EV: blue rotation \(shipped.rotation.b) pushed LED blue "
                        + "\(a)° against \(b)° unrotated — it adds to the blue-to-purple skew")
            }
        }
    }
}

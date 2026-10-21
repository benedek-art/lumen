// SaturationOutOfGamutChromaTests.swift
// "+Saturation never decreases any pixel's chroma" — for the colours the working
// gamut cannot hold, too.
//
// `HuePreservationTests` proves Saturation monotone over a grid built ON the working
// gamut, and on that grid it is. But nothing between S6 and the colour stage clamps or
// gamut-maps (the colour stage deliberately leaves that to S14), so a scene colour
// outside Rec.2020 — a narrow-band cyan or blue LED through a 3x3 camera matrix —
// arrives at S9 with a NEGATIVE channel. Density's subtractive branch raised every
// channel ratio to a power with a signed `pow`, and for a ratio below zero that pulls
// the channel TOWARD zero: the colour walks back toward the gamut and loses chroma.
// At the shipped Density of 50 a 490 nm cyan lost 17% of its chroma at Saturation
// +100, and lost more the further the slider went — the slider fighting the user.
//
// A negative ratio is not an absorbing dye layer, so the dye model had nothing to say
// about it: the first fix held negative ratios where they were. Since WS-16 the push is
// compressed against the working gamut and a colour already outside it is held exactly.
// These samples sit deliberately OUTSIDE the in-gamut grid so the existing grid law is
// untouched.

import XCTest
@testable import LumenCore

final class SaturationOutOfGamutChromaTests: XCTestCase {

    private static let space = OKLabTransform.working

    /// Linear working-space (Rec.2020) colours with a negative channel.
    private static let outOfGamut: [(name: String, rgb: RGB)] = [
        ("490 nm cyan at Y 0.2", RGB(-0.132, 0.310, 0.413)),
        ("450 nm LED at Y 0.2", RGB(0.603, -0.709, 8.812)),
        ("dark olive past the blue edge", RGB(0.057, 0.043, -0.021)),
    ]

    private func engine(saturation: Double, density: Double = 50) -> ColorEngine {
        var color = ColorAdjust(saturation: saturation)
        color.density = density
        return ColorEngine(mixer: Mixer(), pointColors: [], color: color,
                           primaries: Primaries(), bw: nil)
    }

    private func chroma(_ c: RGB) -> Double { Self.space.toLCh(c).C }

    func testPositiveSaturationNeverRemovesChromaFromAnOutOfGamutColour() {
        for density in [50.0, 100.0] {
            for (name, rgb) in Self.outOfGamut {
                let start = chroma(rgb)
                var previous = start
                for step in 1...10 {
                    let s = Double(step) * 10
                    let C = chroma(engine(saturation: s, density: density).apply(rgb))
                    XCTAssertGreaterThanOrEqual(
                        C, previous - 1e-9,
                        "\(name), Density \(density): chroma fell from \(previous) to \(C) "
                        + "between Saturation \(s - 10) and \(s)")
                    XCTAssertGreaterThanOrEqual(
                        C, start - 1e-9,
                        "\(name), Density \(density): Saturation +\(s) left chroma \(C) "
                        + "below the input's \(start)")
                    previous = C
                }
            }
        }
    }

    /// The GPU's Swift twin (and through it the GLSL kernel it mirrors) must agree.
    func testTheExactStageTwinAlsoNeverRemovesChromaFromAnOutOfGamutColour() {
        for (name, rgb) in Self.outOfGamut {
            let start = chroma(rgb)
            var previous = start
            for step in 1...10 {
                let s = Double(step) * 10
                let C = chroma(engine(saturation: s).exactStage.apply(rgb))
                XCTAssertGreaterThanOrEqual(
                    C, previous - 1e-5,
                    "exact stage, \(name): chroma fell from \(previous) to \(C) "
                    + "between Saturation \(s - 10) and \(s)")
                XCTAssertGreaterThanOrEqual(
                    C, start - 1e-5,
                    "exact stage, \(name): Saturation +\(s) left chroma \(C) "
                    + "below the input's \(start)")
                previous = C
            }
        }
    }

    /// A colour already outside the working gamut is held exactly where it is by a push.
    ///
    /// This replaced a check on `subtractivePush`, the per-channel gamma Density used to
    /// blend in; WS-16 retired it (it turned hue and could lower chroma at Density 100).
    /// What the old test protected — that a push never walks an out-of-gamut colour back
    /// toward the gamut — is now the push's own rule: with no room left to push into, a
    /// colour with a negative channel is returned unchanged, at any Density.
    func testAPushHoldsAnOutOfGamutColourExactly() {
        for density in [0.0, 100.0] {
            for (name, rgb) in Self.outOfGamut {
                let out = engine(saturation: 100, density: density).apply(rgb)
                XCTAssertLessThan(out.maxAbsDifference(rgb), 1e-12,
                                  "\(name), Density \(density): moved to \(out)")
            }
        }
    }
}

// BlackAndWhiteMixTests.swift
// The B&W mix is not switched off by the Saturation slider (B1-03).
//
// `ColorEngine.apply` runs Saturation before the B&W treatment, and the mix's per-band
// gain is multiplied by the chroma gate of the pixel it is handed. Saturation is a chroma
// scale, so it drove that gate to zero: at −75 the eight band sliders were 84 % dead and
// at −100 exactly inert, silently. "Desaturate, then mix the sky down" is the standard
// route into a black-and-white edit, and it produced a flat conversion with eight
// sliders that moved nothing.
//
// There was no behavioural B&W test at all before this file.

import XCTest
@testable import LumenCore

final class BlackAndWhiteMixTests: XCTestCase {

    private let sky = OKLabTransform.working.toRGB(OKLCh(L: 0.60, C: 0.12, h: 255))

    /// Every band at the same value, so the test needs no knowledge of which index is
    /// "blue": the gain is then `1 + Σw·gate·(band/100)·κ` with Σw = 1, and only the
    /// gate can make it vary.
    private func engine(bands: Double, saturation: Double) -> ColorEngine {
        ColorEngine(mixer: Mixer(), pointColors: [],
                    color: ColorAdjust(saturation: saturation),
                    primaries: Primaries(),
                    bw: BlackAndWhite(bands: Array(repeating: bands, count: 8),
                                      enabled: true),
                    bandMeanHues: nil)
    }

    private func grey(_ e: ColorEngine, _ c: RGB) -> Double {
        e.apply(c, localMean: c).r
    }

    // MARK: - The defect

    func testTheMixSurvivesNegativeSaturation() {
        let flatAt0 = grey(engine(bands: 0, saturation: 0), sky)
        let mixedAt0 = grey(engine(bands: -80, saturation: 0), sky)
        let moveAt0 = flatAt0 - mixedAt0
        XCTAssertGreaterThan(moveAt0, 0.01,
                             "the fixture must show the mix working at Saturation 0, or "
                             + "the assertion below proves nothing")

        for saturation in [-75.0, -100.0] {
            let flat = grey(engine(bands: 0, saturation: saturation), sky)
            let mixed = grey(engine(bands: -80, saturation: saturation), sky)
            let move = flat - mixed
            XCTAssertEqual(move, moveAt0, accuracy: moveAt0 * 0.05,
                           "at Saturation \(saturation) the mix moved the sky by "
                           + "\(move) against \(moveAt0) at 0 — the chroma scale gated "
                           + "the band sliders off")
        }
    }

    // MARK: - What must NOT change

    /// A true neutral has no hue to fall in a band, and must stay unmoved by the mix at
    /// every Saturation — the fix must not make greys band-sensitive.
    func testANeutralIsUntouchedByTheMixAtAnySaturation() {
        let grey18 = RGB(0.18, 0.18, 0.18)
        for saturation in [0.0, -100.0] {
            let flat = grey(engine(bands: 0, saturation: saturation), grey18)
            let mixed = grey(engine(bands: -80, saturation: saturation), grey18)
            XCTAssertEqual(flat, mixed, accuracy: 1e-9,
                           "a neutral moved under the mix at Saturation \(saturation)")
        }
    }

    /// The B&W output is a neutral whatever the input, at every Saturation.
    func testTheOutputIsANeutral() {
        for saturation in [0.0, -50.0, -100.0] {
            let out = engine(bands: -80, saturation: saturation).apply(sky, localMean: sky)
            XCTAssertEqual(out.r, out.g, accuracy: 1e-9)
            XCTAssertEqual(out.g, out.b, accuracy: 1e-9)
        }
    }
}

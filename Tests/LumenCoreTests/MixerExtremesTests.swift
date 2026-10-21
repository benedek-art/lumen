// MixerExtremesTests.swift
// WS-31 SPEC X1 (stage level): the Mixer never produces a NaN or an infinity, on the CPU
// reference or on the GPU twin, for any input a scene-referred buffer can hold and any
// all-bands ±100 combination; plus the monotone and identity properties the new Luminance
// and Saturation kernels are built on.

import XCTest
@testable import LumenCore

final class MixerExtremesTests: XCTestCase {

    private static let inputs: [RGB] = {
        let context = OKLabTransform.working
        var out: [RGB] = [RGB(0, 0, 0), RGB(1e4, 1e4, 1e4), RGB(1e4, 0, 0), RGB(0, 1e4, 0),
                          RGB(0, 0, 1e4), RGB(-0.2, 0.1, 0.3), RGB(-1, -1, -1),
                          RGB(0.5, -0.4, 0.1), RGB(1e-12, 0, 0), RGB(-1e4, 2, 5)]
        for L in stride(from: 0.0, through: 1.5, by: 0.1) {
            for C in [0.0, 0.005, 0.02, 0.05, 0.1, 0.2, 0.3, 0.4] {
                for h in stride(from: 0.0, to: 360.0, by: 15) {
                    out.append(context.toRGB(OKLCh(L: L, C: C, h: h)))
                }
            }
        }
        return out
    }()

    /// Every all-bands combination of the three attributes at −100, 0 and +100, the
    /// alternating pattern, and both with Uniformity on.
    private static let mixers: [(String, Mixer)] = {
        var out: [(String, Mixer)] = []
        for hue in [-100.0, 0, 100] {
            for sat in [-100.0, 0, 100] {
                for lum in [-100.0, 0, 100] {
                    for uniformity in [0.0, 100] {
                        var m = Mixer()
                        for i in 0..<8 {
                            m.bands[i].hue = hue
                            m.bands[i].sat = sat
                            m.bands[i].lum = lum
                        }
                        m.uniformity = uniformity
                        out.append(("h\(hue) s\(sat) l\(lum) u\(uniformity)", m))
                    }
                }
            }
        }
        var alternating = Mixer()
        for i in 0..<8 {
            let v: Double = i % 2 == 0 ? 100 : -100
            alternating.bands[i].hue = v
            alternating.bands[i].sat = -v
            alternating.bands[i].lum = v
        }
        out.append(("alternating", alternating))
        return out
    }()

    func testNoInputAndNoAllBandsCombinationProducesANonFiniteValue() {
        var failures: [String] = []
        for (name, mixer) in Self.mixers {
            let e = ColorEngine(mixer: mixer, pointColors: [], color: ColorAdjust(),
                                primaries: Primaries(), bw: nil)
            let stage = e.exactStage
            for c in Self.inputs {
                let engine = e.apply(c)
                let twin = stage.apply(c)
                if !engine.isFinite { failures.append("engine \(name) at \(c): \(engine)") }
                if !twin.isFinite { failures.append("twin \(name) at \(c): \(twin)") }
            }
        }
        XCTAssertEqual(Array(failures.prefix(10)), [], "\(failures.count) non-finite outputs")
    }

    func testTheLuminanceKernelIsARatioMonotoneInLightnessAndInTheSlider() {
        XCTAssertEqual(ColorEngine.mixerLightness(0, stops: -1), 0)
        XCTAssertEqual(ColorEngine.mixerLightness(0.5, stops: 0), 0.5)
        XCTAssertEqual(ColorEngine.mixerLightness(-0.1, stops: 1), -0.1)
        let extremes = (ColorEngine.mixerLumStopsDown + ColorEngine.mixerLumStopsUp).max() ?? 1
        for stops in [-extremes, -0.1, 0.1, extremes] {
            var previous = 0.0
            var L = 0.001
            while L <= 20 {
                let out = ColorEngine.mixerLightness(L, stops: stops)
                XCTAssertGreaterThan(out, previous, "not monotone in L at \(L), stops \(stops)")
                XCTAssertGreaterThan(out, 0)
                previous = out
                L *= 1.02
            }
        }
        for L in [0.05, 0.3, 0.6, 1.2] {
            var previous = 0.0
            for step in -10...10 {
                let out = ColorEngine.mixerLightness(L, stops: extremes * Double(step) / 10)
                XCTAssertGreaterThan(out, previous, "not monotone in the slider at L \(L)")
                previous = out
            }
        }
    }

    func testTheSaturationPushRollsOffAtTheConeAndNeverReversesChromaOrder() {
        for hue in stride(from: 0.0, to: 360.0, by: 5) {
            let sigma = ColorEngine.mixerReferenceSaturation(hue: hue)
            XCTAssertGreaterThan(sigma, 0.1)
            XCTAssertLessThan(sigma, 0.9)
            for L in [0.2, 0.6, 1.1] {
                // A dull colour doubles at +100.
                let dull = ColorEngine.mixerSatGain(chroma: 1e-6, lightness: L, hue: hue, push: 1)
                XCTAssertEqual(dull, 2, accuracy: 1e-4)
                // At or beyond the ceiling it does not move.
                let edge = L * sigma * ColorEngine.mixerSatCeiling
                XCTAssertEqual(ColorEngine.mixerSatGain(chroma: edge * 1.01, lightness: L,
                                                        hue: hue, push: 1), 1)
                for push in [0.25, 0.5, 1.0] {
                    var previous = 0.0
                    var C = 0.0005
                    while C < 0.5 {
                        let out = C * ColorEngine.mixerSatGain(chroma: C, lightness: L,
                                                               hue: hue, push: push)
                        XCTAssertGreaterThanOrEqual(out, previous - 1e-12,
                                                    "chroma order reversed at C \(C), h \(hue)")
                        previous = out
                        C *= 1.03
                    }
                }
            }
        }
        XCTAssertEqual(ColorEngine.mixerSatGain(chroma: 0.1, lightness: 0.5, hue: 30, push: 0), 1)
        XCTAssertEqual(ColorEngine.mixerSatGain(chroma: 0.1, lightness: 0, hue: 30, push: 1), 1)
    }

    /// The Fourier cone is a smooth stand-in for the exact one: it never claims more
    /// than 15% more room than an sRGB-primaries colour really has.
    func testTheReferenceConeTracksTheExactSRGBCone() {
        let context = OKLabTransform.working
        let toSRGB = RGBColorSpace.srgb.fromXYZ * RGBColorSpace.rec2020.toXYZ
        for hue in stride(from: 0.0, to: 360.0, by: 2.5) {
            var lo = 0.0, hi = 2.0
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                let c = toSRGB.apply(context.toRGB(OKLCh(L: 1, C: mid, h: hue)))
                if c.minComponent >= 0 { lo = mid } else { hi = mid }
            }
            let fitted = ColorEngine.mixerReferenceSaturation(hue: hue)
            XCTAssertLessThan(fitted / lo, 1.15, "the cone fit overstates room at \(hue)°")
            XCTAssertGreaterThan(fitted / lo, 0.7, "the cone fit is far off at \(hue)°")
        }
    }
}

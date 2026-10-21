// MixerHueMonotoneTests.swift
// WS-31 SPEC H6: the stage-level hue lines, on the CPU reference (`ColorEngine`) and on
// the GPU twin (`ExactColorStage`, which runs `ExactColorTwin.mixer`).
//
// For every band at Hue ±100, on rows L 0.4/0.6/0.8 × C 0.03/0.06/0.12/0.2 and a 0.05°
// input-hue grid:
//   H1  output hue strictly increases with input hue: local slope ≥ 0.10 everywhere
//       (the old 45° move folded 14–20° of every band's hue backwards);
//   H3  at the band centre, row L 0.6 C 0.06, |Δh| ∈ [25°, 35°] and ≤ gap − 2°, so a
//       move never reaches the neighbour's centre;
//   H4  +100 moves toward the next band in wire order, −100 toward the previous;
//   H5  a hue move leaves chroma and lightness alone (|ΔC|/C < 2%, |ΔL| < 0.005).

import XCTest
@testable import LumenCore

final class MixerHueMonotoneTests: XCTestCase {

    private static let rows: [(L: Double, C: Double)] = {
        var out: [(Double, Double)] = []
        for L in [0.4, 0.6, 0.8] { for C in [0.03, 0.06, 0.12, 0.2] { out.append((L, C)) } }
        return out
    }()
    private static let step = 0.05
    private static let context = OKLabTransform.working

    private static func engine(band: Int, hue: Double) -> ColorEngine {
        var mixer = Mixer()
        mixer.bands[band].hue = hue
        return ColorEngine(mixer: mixer, pointColors: [], color: ColorAdjust(),
                           primaries: Primaries(), bw: nil)
    }

    /// Runs `apply` over one row and returns the unwrapped output hue at every grid point.
    private static func outputHues(L: Double, C: Double, _ apply: (RGB) -> RGB)
        -> (hues: [Double], dC: Double, dL: Double) {
        let n = Int(360 / step)
        var out: [Double] = []
        out.reserveCapacity(n + 1)
        var previous = 0.0
        var dC = 0.0, dL = 0.0
        for i in 0...n {
            let h = Double(i) * step
            let lch = context.toLCh(apply(context.toRGB(OKLCh(L: L, C: C, h: h))))
            let unwrapped: Double
            if i == 0 {
                unwrapped = h + Num.hueDelta(h, lch.h)
            } else {
                unwrapped = previous + Num.hueDelta(Num.wrapHue(previous), lch.h)
            }
            out.append(unwrapped)
            previous = unwrapped
            dC = Swift.max(dC, abs(lch.C - C) / C)
            dL = Swift.max(dL, abs(lch.L - L))
        }
        return (out, dC, dL)
    }

    private func checkAllBands(_ twin: Bool) {
        var worstSlope = Double.infinity
        var worstAt = ""
        var worstC = 0.0, worstL = 0.0
        for band in 0..<8 {
            for v in [-100.0, 100] {
                let e = Self.engine(band: band, hue: v)
                let stage = e.exactStage
                let apply: (RGB) -> RGB = twin ? { stage.apply($0) } : { e.apply($0) }
                for row in Self.rows {
                    let r = Self.outputHues(L: row.L, C: row.C, apply)
                    for i in 1..<r.hues.count {
                        let slope = (r.hues[i] - r.hues[i - 1]) / Self.step
                        if slope < worstSlope {
                            worstSlope = slope
                            worstAt = "band \(band) \(v) L \(row.L) C \(row.C) h \(Double(i) * Self.step)"
                        }
                    }
                    // A full turn in, a full turn out: nothing folded over the wrap.
                    XCTAssertEqual(r.hues.last! - r.hues.first!, 360, accuracy: 1e-3,
                                   "band \(band) \(v) row \(row)")
                    worstC = Swift.max(worstC, r.dC)
                    worstL = Swift.max(worstL, r.dL)
                }
                // H3, H4 at the band centre, row L 0.6 C 0.06.
                let centre = ColorEngine.bandHueCentres[band]
                let input = Self.context.toRGB(OKLCh(L: 0.6, C: 0.06, h: centre))
                let shift = Num.hueDelta(centre, Self.context.toLCh(apply(input)).h)
                let gap = v > 0 ? ColorEngine.bandGapAbove(band) : ColorEngine.bandGapBelow(band)
                XCTAssertGreaterThanOrEqual(abs(shift), 25, "H3 band \(band) \(v): \(shift)°")
                XCTAssertLessThanOrEqual(abs(shift), 35, "H3 band \(band) \(v): \(shift)°")
                XCTAssertLessThanOrEqual(abs(shift), gap - 2, "H3 band \(band) \(v) reaches its neighbour")
                XCTAssertEqual(shift.sign, v.sign == .minus ? .minus : .plus,
                               "H4 band \(band) \(v) moved the wrong way: \(shift)°")
            }
        }
        XCTAssertGreaterThanOrEqual(worstSlope, 0.10, "H1 fold: slope \(worstSlope) at \(worstAt)")
        XCTAssertLessThan(worstC, 0.02, "H5 chroma moved by \(worstC)")
        XCTAssertLessThan(worstL, 0.005, "H5 lightness moved by \(worstL)")
        print("MIXER_HUE \(twin ? "twin" : "engine") min slope \(worstSlope) at \(worstAt); "
              + "max |ΔC|/C \(worstC), max |ΔL| \(worstL)")
    }

    func testEveryBandsHueMoveIsMonotoneAndBoundedOnTheEngine() {
        checkAllBands(false)
    }

    func testEveryBandsHueMoveIsMonotoneAndBoundedOnTheTwin() {
        checkAllBands(true)
    }

    /// Two neighbours driven hard toward each other is the case a per-band limit cannot
    /// cover; `resolvedHueShifts` scales the set until the squeezed interval keeps
    /// `hueMinSlope` of its width. Every adjacent pair, both ways, every row.
    func testNeighboursDrivenTogetherStillNeverFoldTheCircle() {
        for band in 0..<8 {
            var mixer = Mixer()
            mixer.bands[band].hue = 100
            mixer.bands[(band + 1) % 8].hue = -100
            mixer.bands[(band + 4) % 8].hue = 100
            let e = ColorEngine(mixer: mixer, pointColors: [], color: ColorAdjust(),
                                primaries: Primaries(), bw: nil)
            for row in [(0.6, 0.06), (0.8, 0.2)] {
                let r = Self.outputHues(L: row.0, C: row.1) { e.apply($0) }
                var worst = Double.infinity
                for i in 1..<r.hues.count {
                    worst = Swift.min(worst, (r.hues[i] - r.hues[i - 1]) / Self.step)
                }
                XCTAssertGreaterThanOrEqual(worst, ColorEngine.hueMinSlope - 1e-3,
                                            "bands \(band)/\(band + 1) squeezed to slope \(worst)")
            }
        }
    }

    /// The hue move holds still where nobody asked for it: an untouched band's centre
    /// two bands away from the moved one does not move.
    func testAHueMoveStopsAtTheNeighbouringCentres() {
        for band in 0..<8 {
            for v in [-100.0, 100] {
                let e = Self.engine(band: band, hue: v)
                for k in [(band + 2) % 8, (band + 6) % 8, (band + 4) % 8] {
                    let h = ColorEngine.bandHueCentres[k]
                    let out = Self.context.toLCh(e.apply(Self.context.toRGB(OKLCh(L: 0.6, C: 0.1, h: h))))
                    XCTAssertEqual(Num.hueDelta(h, out.h), 0, accuracy: 1e-9,
                                   "band \(band) \(v) moved band \(k)'s centre")
                }
            }
        }
    }
}

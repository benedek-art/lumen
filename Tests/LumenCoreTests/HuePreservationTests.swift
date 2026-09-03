// HuePreservationTests.swift
// A property sweep over a real grid of colours, for the class of defect that hides
// between hand-picked values: "why do skin tones go orange".
//
// Every test here states one law about the colour stage and then asks the whole grid
// — 36 hues × 5 lightnesses × 4 chromas, built ON the working gamut so every sample is
// a colour a photograph can contain — whether the law holds. A hand-picked triple can
// only confirm a law where somebody already suspected it; a grid finds the hue nobody
// thought to look at, which is how a rotation that is invisible on red and 4° on skin
// gets found at all.
//
// The laws, in the order the file asserts them:
//   1. a saturation control does not rotate hue, at either sign;
//   2. a vibrance control does not rotate hue, at either sign;
//   3. every scalar colour control is monotone in its own parameter;
//   4. a hue rotation of +δ then −δ returns the colour it started from;
//   5. the band controls obey 1–4 too, and a band Luminance move carries chroma
//      through literally unchanged (the engine header's invariant #1);
//   6. gamut pressure changes chroma, never hue — clipping is a display-space
//      operation and the working space never sees one;
//   7. white balance round-trips a neutral, and each of its two axes is monotone.
//
// Failure messages carry the worst input on the grid rather than the first one, so a
// regression reports the colour it is worst on instead of the colour it reached first.

import XCTest
@testable import LumenCore

final class HuePreservationTests: XCTestCase {

    // MARK: - The grid

    /// One sample: the colour, and enough of its coordinates to name it in a failure.
    struct Sample {
        let rgb: RGB
        let hue: Double
        let chroma: Double
        let lightness: Double
        /// Fraction of the working gamut's boundary chroma at this (L, h).
        let fill: Double

        var label: String {
            String(format: "h=%.0f° L=%.2f C=%.3f (%.0f%% of gamut) rgb=(%.4f, %.4f, %.4f)",
                   hue, lightness, chroma, fill * 100, rgb.r, rgb.g, rgb.b)
        }
    }

    private static let context = OKLabTransform.working

    /// 36 hues × 5 lightnesses × 4 gamut fills = 720 real colours.
    ///
    /// Chroma is a FRACTION OF THE BOUNDARY rather than an absolute number, because an
    /// absolute chroma grid is a different experiment at every hue: 0.20 is deep inside
    /// the gamut on blue and outside it on yellow, so a fixed-chroma sweep tests the
    /// interior on some hues and the edge on others and cannot say which it found a
    /// defect in. Fills of 15/40/70/95% mean "the same distance out" everywhere, and
    /// the 95% ring is what puts a sample under gamut pressure at every hue at once.
    static let grid: [Sample] = {
        var out: [Sample] = []
        let boundary = Gamut.sharedBoundary
        for hi in 0..<36 {
            let h = Double(hi) * 10
            for L in [0.20, 0.35, 0.50, 0.65, 0.80] {
                let maxC = boundary.maxChroma(L: L, hue: h)
                guard maxC > 0 else { continue }
                for fill in [0.15, 0.40, 0.70, 0.95] {
                    let C = maxC * fill
                    let rgb = context.toRGB(OKLCh(L: L, C: C, h: h))
                    guard rgb.isFinite else { continue }
                    out.append(Sample(rgb: rgb, hue: h, chroma: C, lightness: L, fill: fill))
                }
            }
        }
        return out
    }()

    // MARK: - Reading a colour back

    private func lch(_ c: RGB) -> OKLCh { Self.context.toLCh(c) }

    /// Below this chroma a colour HAS no hue — the angle is the arctangent of two
    /// numbers that are both noise, and the engine says so itself: `chromaGate` is
    /// exactly zero at and below `gateLoChroma`, and no hue-selective tool is allowed
    /// to act on a pixel there.
    ///
    /// It has to be said out loud in the test too, because a sweep that reads hue off
    /// the output finds it the hard way. Saturation −100 and Vibrance −100 both drive
    /// chroma to exactly zero — that is what they are FOR — and the hue of an exact
    /// neutral came back 180° from where it started. Reported as a defect, that reads
    /// "Vibrance −100 rotated hue by 180.000°"; it is nothing of the kind, and a grid
    /// that cannot tell the two apart would have sent a fleet chasing it.
    private static let hueIsMeaningful: Double = ColorEngine.gateLoChroma

    /// Signed hue movement in degrees, input → output. `nil` when either end has no
    /// hue to speak of.
    private func hueMove(_ input: RGB, _ output: RGB) -> Double? {
        let a = lch(input), b = lch(output)
        guard a.C > Self.hueIsMeaningful, b.C > Self.hueIsMeaningful else { return nil }
        return Num.hueDelta(a.h, b.h)
    }

    private func colorEngine(_ color: ColorAdjust,
                             mixer: Mixer = Mixer(),
                             pointColors: [PointColor] = []) -> ColorEngine {
        ColorEngine(mixer: mixer, pointColors: pointColors, color: color,
                    primaries: Primaries(), bw: nil)
    }

    /// The worst |hue move| on the grid under one engine, and the sample it happened on.
    private func worstHueMove(_ engine: ColorEngine,
                              over samples: [Sample] = HuePreservationTests.grid)
        -> (degrees: Double, sample: Sample?) {
        var worst = 0.0
        var at: Sample?
        for s in samples {
            let out = engine.apply(s.rgb)
            guard out.isFinite, let d = hueMove(s.rgb, out).map(abs) else { continue }
            if d > worst { worst = d; at = s }
        }
        return (worst, at)
    }

    /// What "the same hue" means here, in degrees of OKLab arc.
    ///
    /// 0.25° is well under the ~1° hue difference a trained observer can see on a large
    /// flat patch, and about ten times the round-trip noise of the RGB↔OKLab pair
    /// (measured below at 3e-11°). A tool that claims to hold hue and lands inside this
    /// is holding it; one that lands outside is rotating it.
    private static let hueTolerance: Double = 0.25

    // MARK: - 1. Saturation

    func testSaturationPreservesHueAcrossTheWheelAtTheShippedDefaults() {
        // The SHIPPED ColorAdjust defaults — density 50, protectSkin 70 — because the
        // complaint is about what the photographer gets, not about what the stage can
        // be configured to do.
        for amount in [10.0, 25, 50, 75, 100] {
            let engine = colorEngine(ColorAdjust(saturation: amount))
            let (worst, at) = worstHueMove(engine)
            XCTAssertLessThan(worst, Self.hueTolerance,
                              String(format: "Saturation +%.0f rotated hue by %.3f° at %@",
                                     amount, worst, at?.label ?? "—"))
        }
    }

    func testNegativeSaturationPreservesHueAcrossTheWheel() {
        for amount in [-10.0, -25, -50, -75] {
            let engine = colorEngine(ColorAdjust(saturation: amount))
            let (worst, at) = worstHueMove(engine)
            XCTAssertLessThan(worst, Self.hueTolerance,
                              String(format: "Saturation %.0f rotated hue by %.3f° at %@",
                                     amount, worst, at?.label ?? "—"))
        }
    }

    /// A control that rotates hue in one direction and not the other is not a colour
    /// model, it is an accident: whatever film-like intent the rotation serves, +50 and
    /// −50 have to be the same instrument seen from two sides.
    func testSaturationRotatesHueSymmetricallyAboutZero() {
        var worst = 0.0
        var detail = "—"
        for amount in [25.0, 50, 75, 100] {
            let up = colorEngine(ColorAdjust(saturation: amount))
            let down = colorEngine(ColorAdjust(saturation: -amount))
            for s in HuePreservationTests.grid {
                let a = hueMove(s.rgb, up.apply(s.rgb))
                let b = hueMove(s.rgb, down.apply(s.rgb))
                let asymmetry = abs(abs(a) - abs(b))
                if asymmetry > worst {
                    worst = asymmetry
                    detail = String(format: "±%.0f: +%.3f° vs %.3f° at %@",
                                    amount, a, b, s.label)
                }
            }
        }
        XCTAssertLessThan(worst, Self.hueTolerance,
                          "Saturation's hue rotation is one-sided — \(detail)")
    }

    /// The whole reason the complaint is about SKIN: the rotation, if there is one,
    /// has to be reported where faces live.
    func testSaturationHoldsSkinHues() {
        // The vectorscope skin band the engine itself defines, ±10° about the I-bar.
        let skin = HuePreservationTests.grid.filter {
            abs(Num.hueDelta(ColorEngine.skinLineDegrees, $0.hue)) <= ColorEngine.skinBandDegrees
        }
        XCTAssertFalse(skin.isEmpty, "the grid must contain skin hues at all")
        for amount in [25.0, 50, 100] {
            let engine = colorEngine(ColorAdjust(saturation: amount))
            let (worst, at) = worstHueMove(engine, over: skin)
            XCTAssertLessThan(worst, Self.hueTolerance,
                              String(format: "Saturation +%.0f rotated a SKIN hue by %.3f° at %@",
                                     amount, worst, at?.label ?? "—"))
        }
    }

    /// Whatever hue movement exists must not grow with the slider: a bounded artefact
    /// is a look, an amplifying one is a defect that gets worse exactly where the
    /// photographer is pushing hardest.
    func testSaturationsHueMovementDoesNotAmplifyWithTheSlider() {
        var worst = 0.0
        var detail = "—"
        for s in HuePreservationTests.grid {
            var previous = 0.0
            for amount in [10.0, 25, 50, 75, 100] {
                let engine = colorEngine(ColorAdjust(saturation: amount))
                let d = abs(hueMove(s.rgb, engine.apply(s.rgb)))
                let growth = d - previous
                if growth > worst {
                    worst = growth
                    detail = String(format: "+%.0f moved %.3f° where +the step below moved %.3f°, at %@",
                                    amount, d, previous, s.label)
                }
                previous = d
            }
        }
        XCTAssertLessThan(worst, Self.hueTolerance,
                          "Saturation's hue rotation amplifies with the slider — \(detail)")
    }

    // MARK: - 2. Vibrance

    func testVibrancePreservesHueAcrossTheWheel() {
        for amount in [-100.0, -50, -25, 25, 50, 100] {
            let engine = colorEngine(ColorAdjust(vibrance: amount))
            let (worst, at) = worstHueMove(engine)
            XCTAssertLessThan(worst, Self.hueTolerance,
                              String(format: "Vibrance %+.0f rotated hue by %.3f° at %@",
                                     amount, worst, at?.label ?? "—"))
        }
    }

    /// Vibrance's stated rule is two-part: spend the move on the colours that have
    /// least chroma, and hold back inside the skin band. Both halves are asserted as
    /// ORDERINGS rather than numbers, so the rule survives a retune of the constants.
    func testVibranceSpendsItselfOnLowChromaAndProtectsSkin() {
        let engine = colorEngine(ColorAdjust(vibrance: 100))

        // Part one: at a fixed hue and lightness, the relative chroma gain must fall as
        // the starting chroma rises. That IS "vibrance, not saturation".
        var worstOrdering = 0.0
        var orderingDetail = "—"
        for hi in 0..<36 {
            let h = Double(hi) * 10
            for L in [0.35, 0.50, 0.65] {
                let ladder = HuePreservationTests.grid.filter {
                    $0.hue == h && $0.lightness == L
                }.sorted { $0.chroma < $1.chroma }
                guard ladder.count >= 2 else { continue }
                var previousGain = Double.infinity
                for s in ladder {
                    let gain = lch(engine.apply(s.rgb)).C / Swift.max(s.chroma, 1e-9)
                    let rise = gain - previousGain
                    if previousGain.isFinite, rise > worstOrdering {
                        worstOrdering = rise
                        orderingDetail = String(format: "gain rose to %.4f from %.4f at %@",
                                                gain, previousGain, s.label)
                    }
                    previousGain = gain
                }
            }
        }
        XCTAssertLessThan(worstOrdering, 1e-6,
                          "Vibrance gained MORE on the more saturated colour — \(orderingDetail)")

        // Part two: at equal chroma and lightness, a skin hue must move less than a
        // non-skin one. Compared at the same gamut fill so the two are the same
        // distance out, and against the hue 180° away, which is as far from the skin
        // band as the wheel goes.
        let bare = colorEngine(ColorAdjust(vibrance: 100, protectSkin: 0))
        for L in [0.35, 0.50, 0.65] {
            for fill in [0.15, 0.40] {
                guard let skin = HuePreservationTests.grid.first(where: {
                    abs(Num.hueDelta(ColorEngine.skinLineDegrees, $0.hue)) < 5
                        && $0.lightness == L && $0.fill == fill
                }) else { continue }
                let guarded = lch(engine.apply(skin.rgb)).C / Swift.max(skin.chroma, 1e-9)
                let unguarded = lch(bare.apply(skin.rgb)).C / Swift.max(skin.chroma, 1e-9)
                XCTAssertLessThan(guarded, unguarded - 1e-6,
                                  "Protect Skin did not hold Vibrance back at \(skin.label)")
            }
        }
    }

    // MARK: - 3. Monotonicity

    /// Every scalar control must be monotone in its parameter. A slider that reverses
    /// somewhere in the middle is felt as "the slider fights me", and it is felt long
    /// before it can be described — the photographer drags further and the picture
    /// comes back toward where it started.
    ///
    /// The observable is output chroma, which is what a saturation control is FOR, read
    /// in the same OKLab the stage works in.
    func testSaturationIsMonotoneInItsParameterAcrossTheWheel() {
        var worst = 0.0
        var detail = "—"
        var previous: [Double] = Array(repeating: -.infinity, count: HuePreservationTests.grid.count)
        var previousAmount = -100.0
        for step in 0...80 {
            let amount = -100 + Double(step) * 2.5
            let engine = colorEngine(ColorAdjust(saturation: amount))
            for (i, s) in HuePreservationTests.grid.enumerated() {
                let out = engine.apply(s.rgb)
                let C = out.isFinite ? lch(out).C : 0
                let drop = previous[i] - C
                if previous[i].isFinite, drop > worst {
                    worst = drop
                    detail = String(format: "chroma fell %.6f between Saturation %.1f and %.1f at %@",
                                    drop, previousAmount, amount, s.label)
                }
                previous[i] = C
            }
            previousAmount = amount
        }
        XCTAssertLessThan(worst, 1e-6, "Saturation reverses — \(detail)")
    }

    func testVibranceIsMonotoneInItsParameterAcrossTheWheel() {
        var worst = 0.0
        var detail = "—"
        var previous: [Double] = Array(repeating: -.infinity, count: HuePreservationTests.grid.count)
        var previousAmount = -100.0
        for step in 0...80 {
            let amount = -100 + Double(step) * 2.5
            let engine = colorEngine(ColorAdjust(vibrance: amount))
            for (i, s) in HuePreservationTests.grid.enumerated() {
                let out = engine.apply(s.rgb)
                let C = out.isFinite ? lch(out).C : 0
                let drop = previous[i] - C
                if previous[i].isFinite, drop > worst {
                    worst = drop
                    detail = String(format: "chroma fell %.6f between Vibrance %.1f and %.1f at %@",
                                    drop, previousAmount, amount, s.label)
                }
                previous[i] = C
            }
            previousAmount = amount
        }
        XCTAssertLessThan(worst, 1e-6, "Vibrance reverses — \(detail)")
    }

    /// Density is a blend dial between two renderings of the same push. Whatever it
    /// blends toward, it has to get there monotonically, and it must be inert at 0.
    func testDensityIsInertAtZeroAndMonotoneAboveIt() {
        let plain = colorEngine(ColorAdjust(saturation: 60, density: 0))
        var worst = 0.0
        var detail = "—"
        for s in HuePreservationTests.grid {
            var previousMove = 0.0
            let reference = plain.apply(s.rgb)
            XCTAssertLessThan(abs(hueMove(s.rgb, reference)), Self.hueTolerance,
                              "Density 0 still rotated hue at \(s.label)")
            for d in stride(from: 0.0, through: 100.0, by: 5.0) {
                let engine = colorEngine(ColorAdjust(saturation: 60, density: d))
                let move = abs(Num.hueDelta(lch(reference).h, lch(engine.apply(s.rgb)).h))
                let drop = previousMove - move
                if drop > worst {
                    worst = drop
                    detail = String(format: "at density %.0f, %@", d, s.label)
                }
                previousMove = move
            }
        }
        XCTAssertLessThan(worst, 1e-9, "Density's effect is not monotone in the dial — \(detail)")
    }

    // MARK: - 4. Hue linearity

    /// The representation itself: rotate by +δ in OKLCh, come back through RGB, rotate
    /// by −δ, and the colour must be the one you started with. This is the floor every
    /// hue-selective tool stands on — if the round trip through RGB is not hue-linear
    /// there is no point testing anything built on it — and it is what fixes the noise
    /// figure the tolerance above is quoted against.
    func testAHueRotationAndItsInverseReturnTheColourAcrossTheWheel() {
        var worst = 0.0
        var detail = "—"
        for s in HuePreservationTests.grid {
            for delta in [1.0, 10.0, 45.0, 179.0] {
                let start = lch(s.rgb)
                let there = Self.context.toRGB(OKLCh(L: start.L, C: start.C,
                                                     h: Num.wrapHue(start.h + delta)))
                let mid = lch(there)
                let back = Self.context.toRGB(OKLCh(L: mid.L, C: mid.C,
                                                    h: Num.wrapHue(mid.h - delta)))
                let d = s.rgb.maxAbsDifference(back)
                if d > worst {
                    worst = d
                    detail = String(format: "±%.0f° left %.3e at %@", delta, d, s.label)
                }
            }
        }
        XCTAssertLessThan(worst, 1e-9, "The hue round trip does not return the colour — \(detail)")
    }

    /// The same law one level up, through the shipping stage: a Mixer band Hue move of
    /// +δ followed by −δ must return the picture. The band weights are read off the
    /// moved colour on the second pass, so an exact return is not on offer — but the
    /// residue has to be small enough that the photographer cannot see the control
    /// failing to undo itself, which is the property this pins.
    func testAMixerHueMoveAndItsInverseReturnTheColour() {
        var worst = 0.0
        var detail = "—"
        for band in 0..<ColorEngine.bandCount {
            for amount in [10.0, 25.0] {
                var up = Mixer()
                up.bands[band].hue = amount
                var down = Mixer()
                down.bands[band].hue = -amount
                let there = colorEngine(ColorAdjust(), mixer: up)
                let back = colorEngine(ColorAdjust(), mixer: down)
                for s in HuePreservationTests.grid where s.fill >= 0.40 {
                    let out = back.apply(there.apply(s.rgb))
                    let d = abs(hueMove(s.rgb, out))
                    if d > worst {
                        worst = d
                        detail = String(format: "band %d ±%.0f left %.3f° at %@",
                                        band, amount, d, s.label)
                    }
                }
            }
        }
        // 1.5° is the scale at which a hue error stops being a rounding residue and
        // starts being a colour a photographer would notice had not come back.
        XCTAssertLessThan(worst, 1.5, "A Mixer Hue move does not undo itself — \(detail)")
    }

    // MARK: - 5. The band controls

    /// A band Saturation move is a chroma scale and nothing else.
    func testBandSaturationPreservesHue() {
        var worst = 0.0
        var detail = "—"
        for band in 0..<ColorEngine.bandCount {
            for amount in [-100.0, -50, 50, 100] {
                var mixer = Mixer()
                mixer.bands[band].sat = amount
                let engine = colorEngine(ColorAdjust(), mixer: mixer)
                let (d, at) = worstHueMove(engine)
                if d > worst {
                    worst = d
                    detail = String(format: "band %d sat %+.0f moved %.3f° at %@",
                                    band, amount, d, at?.label ?? "—")
                }
            }
        }
        XCTAssertLessThan(worst, Self.hueTolerance,
                          "A band Saturation move rotated hue — \(detail)")
    }

    /// Invariant #1, stated in `ColorEngine`'s own header: a band Luminance move carries
    /// chroma through LITERALLY unchanged, so darkening a blue sky cannot desaturate it.
    func testBandLuminancePreservesHueAndChroma() {
        var worstHue = 0.0
        var worstChroma = 0.0
        var hueDetail = "—"
        var chromaDetail = "—"
        for band in 0..<ColorEngine.bandCount {
            for amount in [-100.0, -50, 50, 100] {
                var mixer = Mixer()
                mixer.bands[band].lum = amount
                let engine = colorEngine(ColorAdjust(), mixer: mixer)
                for s in HuePreservationTests.grid {
                    let out = engine.apply(s.rgb)
                    guard out.isFinite else { continue }
                    let after = lch(out)
                    let dh = abs(Num.hueDelta(s.hue, after.h))
                    if dh > worstHue {
                        worstHue = dh
                        hueDetail = String(format: "band %d lum %+.0f moved %.3f° at %@",
                                           band, amount, dh, s.label)
                    }
                    let dc = abs(after.C - s.chroma)
                    if dc > worstChroma {
                        worstChroma = dc
                        chromaDetail = String(format: "band %d lum %+.0f moved chroma %.5f at %@",
                                              band, amount, dc, s.label)
                    }
                }
            }
        }
        XCTAssertLessThan(worstHue, Self.hueTolerance,
                          "A band Luminance move rotated hue — \(hueDetail)")
        XCTAssertLessThan(worstChroma, 1e-9,
                          "A band Luminance move changed chroma — \(chromaDetail)")
    }

    /// Monotone in the parameter, on all three band axes at once.
    func testEveryBandAxisIsMonotoneInItsParameter() {
        for band in 0..<ColorEngine.bandCount {
            // Saturation: output chroma rises with the slider.
            var previousC: [Double] = Array(repeating: -.infinity, count: HuePreservationTests.grid.count)
            // Hue: the signed rotation rises with the slider.
            var previousH: [Double] = Array(repeating: -.infinity, count: HuePreservationTests.grid.count)
            // Luminance: output lightness rises with the slider.
            var previousL: [Double] = Array(repeating: -.infinity, count: HuePreservationTests.grid.count)
            for step in 0...40 {
                let amount = -100 + Double(step) * 5
                var satMixer = Mixer(); satMixer.bands[band].sat = amount
                var hueMixer = Mixer(); hueMixer.bands[band].hue = amount
                var lumMixer = Mixer(); lumMixer.bands[band].lum = amount
                let satEngine = colorEngine(ColorAdjust(), mixer: satMixer)
                let hueEngine = colorEngine(ColorAdjust(), mixer: hueMixer)
                let lumEngine = colorEngine(ColorAdjust(), mixer: lumMixer)
                for (i, s) in HuePreservationTests.grid.enumerated() {
                    let C = lch(satEngine.apply(s.rgb)).C
                    XCTAssertGreaterThan(C, previousC[i] - 1e-6,
                                         String(format: "band %d Saturation reversed at %.0f, %@",
                                                band, amount, s.label))
                    previousC[i] = C
                    let H = hueMove(s.rgb, hueEngine.apply(s.rgb))
                    XCTAssertGreaterThan(H, previousH[i] - 1e-6,
                                         String(format: "band %d Hue reversed at %.0f, %@",
                                                band, amount, s.label))
                    previousH[i] = H
                    let L = lch(lumEngine.apply(s.rgb)).L
                    XCTAssertGreaterThan(L, previousL[i] - 1e-9,
                                         String(format: "band %d Luminance reversed at %.0f, %@",
                                                band, amount, s.label))
                    previousL[i] = L
                }
            }
        }
    }

    // MARK: - 6. Gamut

    /// The stage runs on unbounded scene-referred data and must never clip a channel:
    /// a per-channel clip is what turns a pushed red into a different colour rather
    /// than a brighter one. Pushing the 95% ring to Saturation +100 has to come out as
    /// MORE CHROMA at the SAME HUE, out of gamut if need be — the display transform
    /// compresses it back later, hue-preserving, once "the display" means something.
    func testAGamutEdgePushGainsChromaWithoutSwingingHue() {
        let edge = HuePreservationTests.grid.filter { $0.fill >= 0.95 }
        XCTAssertFalse(edge.isEmpty)
        let engine = colorEngine(ColorAdjust(saturation: 100))
        var worstHue = 0.0
        var detail = "—"
        for s in edge {
            let out = engine.apply(s.rgb)
            let after = lch(out)
            XCTAssertGreaterThan(after.C, s.chroma - 1e-9,
                                 "Saturation +100 LOST chroma at the gamut edge, \(s.label)")
            let d = abs(Num.hueDelta(s.hue, after.h))
            if d > worstHue { worstHue = d; detail = String(format: "%.3f° at %@", d, s.label) }
        }
        XCTAssertLessThan(worstHue, Self.hueTolerance,
                          "Saturation swung hue at the gamut edge — \(detail)")
    }

    /// And the display-space clip, where clipping is legal: it compresses chroma at
    /// constant hue and lightness, and it is monotone in the chroma it is handed.
    func testTheDisplaySpaceGamutClipHoldsHueAndIsMonotone() {
        let boundary = Gamut.sharedBoundary
        var worstHue = 0.0
        var hueDetail = "—"
        var worstReversal = 0.0
        var reversalDetail = "—"
        for hi in 0..<36 {
            let h = Double(hi) * 10
            for L in [0.20, 0.35, 0.50, 0.65, 0.80] {
                var previous = -Double.infinity
                for step in 0...60 {
                    let C = Double(step) * 0.008
                    let input = Self.context.toRGB(OKLCh(L: L, C: C, h: h))
                    let clipped = Gamut.softClip(input, boundary: boundary)
                    let after = lch(clipped)
                    if C > 1e-4 {
                        let d = abs(Num.hueDelta(h, after.h))
                        if d > worstHue {
                            worstHue = d
                            hueDetail = String(format: "%.3f° at h=%.0f L=%.2f C=%.3f", d, h, L, C)
                        }
                    }
                    let drop = previous - after.C
                    if previous.isFinite, drop > worstReversal {
                        worstReversal = drop
                        reversalDetail = String(format: "%.6f at h=%.0f L=%.2f C=%.3f",
                                                drop, h, L, C)
                    }
                    previous = after.C
                }
            }
        }
        XCTAssertLessThan(worstHue, Self.hueTolerance,
                          "The gamut clip rotated hue — \(hueDetail)")
        XCTAssertLessThan(worstReversal, 1e-9,
                          "The gamut clip is not monotone in chroma — \(reversalDetail)")
    }

    // MARK: - 7. White balance

    /// A neutral through a temp/tint move and back must be the neutral it started as.
    /// The two engines are each other's inverse by construction — adapt to the target,
    /// then adapt back — so anything left over is a place where the forward and reverse
    /// models disagree about what a (Kelvin, tint) pair means.
    func testANeutralSurvivesATempTintRoundTrip() {
        let neutral = RGB(gray: 0.18)
        var worst = 0.0
        var detail = "—"
        for kelvin in [2000.0, 2800, 3200, 4000, 5000, 5500, 6500, 8000, 12000, 20000] {
            for tint in [-150.0, -75, -25, 0, 25, 75, 150] {
                let forward = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                                 targetKelvin: kelvin, targetTint: tint)
                let reverse = WhiteBalanceEngine(asShotKelvin: kelvin,
                                                 asShotTint: forward.effectiveTint,
                                                 targetKelvin: 5500, targetTint: 0)
                let back = reverse.apply(forward.apply(neutral))
                let d = neutral.maxAbsDifference(back)
                if d > worst {
                    worst = d
                    detail = String(format: "%.0f K / %+.0f tint left %.3e", kelvin, tint, d)
                }
            }
        }
        XCTAssertLessThan(worst, 1e-12, "A neutral did not survive the WB round trip — \(detail)")
    }

    /// And the eyedropper's own contract: the colour a neutral turns INTO under a
    /// temp/tint move must be the colour that, clicked with the eyedropper, gives that
    /// move back — which is the same statement as "the neutral you picked renders
    /// neutral again".
    func testTheEyedropperReturnsAPickedNeutralToNeutral() {
        let neutral = RGB(gray: 0.18)
        var worst = 0.0
        var detail = "—"
        for kelvin in [2800.0, 3200, 4000, 5000, 6500, 8000, 12000] {
            for tint in [-100.0, -40, 0, 40, 100] {
                let current = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                                 targetKelvin: kelvin, targetTint: tint)
                let sample = current.apply(neutral)
                let solved = WhiteBalanceEngine.neutralizing(sample: sample,
                                                            asShotKelvin: 5500, asShotTint: 0,
                                                            current: current)
                let settled = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                                 targetKelvin: solved.kelvin,
                                                 targetTint: solved.tint)
                let out = settled.apply(current.matrix.inverse.apply(sample))
                let mean = (out.r + out.g + out.b) / 3
                let residue = Swift.max(abs(out.r - mean), Swift.max(abs(out.g - mean),
                                                                     abs(out.b - mean))) / mean
                if residue > worst {
                    worst = residue
                    detail = String(format: "%.0f K / %+.0f tint left %.4f of chroma (solved %.0f K / %+.1f)",
                                    kelvin, tint, residue, solved.kelvin, solved.tint)
                }
            }
        }
        // A thousandth of a channel ratio is a quarter of an 8-bit code value.
        XCTAssertLessThan(worst, 1e-3,
                          "The eyedropper did not return a picked neutral to neutral — \(detail)")
    }

    /// Both white-balance axes must be monotone in their own parameter, and neither may
    /// drive the other: warming a frame is not allowed to add magenta.
    func testBothWhiteBalanceAxesAreMonotoneAndIndependent() {
        let neutral = RGB(gray: 0.18)

        var previousB = Double.infinity
        for step in 0...120 {
            // Even in MIREDS, the axis the slider is even in.
            let mired = 1e6 / 20000 + Double(step) * (1e6 / 2000 - 1e6 / 20000) / 120
            let kelvin = 1e6 / mired
            let engine = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                            targetKelvin: kelvin, targetTint: 0)
            let b = Self.context.toLab(engine.apply(neutral)).b
            XCTAssertLessThan(b, previousB + 1e-9,
                              String(format: "Temperature reversed on the blue–yellow axis at %.0f K",
                                     kelvin))
            previousB = b
        }

        for kelvin in [2800.0, 4000, 5500, 8000] {
            var previousA = -Double.infinity
            for step in 0...120 {
                let tint = -150 + Double(step) * 2.5
                let engine = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                                targetKelvin: kelvin, targetTint: tint)
                let a = Self.context.toLab(engine.apply(neutral)).a
                XCTAssertGreaterThan(a, previousA - 1e-9,
                                     String(format: "Tint reversed on the green–magenta axis at %.0f K, tint %+.1f",
                                            kelvin, tint))
                previousA = a
            }
        }
    }
}

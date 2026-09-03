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
//   2. a vibrance control does not rotate hue, and spends itself where it says it does;
//   3. every scalar colour control is monotone in its own parameter;
//   4. a hue rotation of +δ and one of −δ are equal and opposite;
//   5. the band controls obey 1–4 too, and a band Luminance move carries chroma
//      through literally unchanged (the engine header's invariant #1);
//   6. gamut pressure changes chroma, never hue;
//   7. white balance round-trips a neutral, renders a colour at every setting, and
//      each of its two axes is monotone.
//
// Two of these do not hold today and the tests say so in the only honest way a test
// can: they PIN the measured size of the violation, name the mechanism, and carry the
// worst input on the grid. `testDensityIsTheWholeOfSaturationsHueRotation` is the
// headline — everything else in section 1 exists to prove that Density and only
// Density is what moves the hue.
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
    /// the OUTPUT finds it the hard way. Saturation −100 and Vibrance −100 both drive
    /// chroma to exactly zero — that is what they are for — and the hue of an exact
    /// neutral came back 180° from where it started. Reported as a defect that reads
    /// "Vibrance −100 rotated hue by 180.000°", and it is nothing of the kind; a grid
    /// that could not tell the two apart would have sent somebody chasing it.
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
    /// flat patch, and far above the round-trip noise of the RGB↔OKLab pair every
    /// measurement here goes through —
    /// `testAHueRotationAndItsInverseReturnTheColourAcrossTheWheel` holds that pair to
    /// 1e-12 of a channel over the same grid. A tool that claims to hold hue and lands
    /// inside this is holding it; one that lands outside is rotating it.
    private static let hueTolerance: Double = 0.25

    /// The skin band the engine itself defines, ±10° about the vectorscope I-bar, and
    /// restricted to samples the engine's own `skinWeight` actually scores as skin —
    /// the plausibility term rejects a chroma too low to be a face, so a 15%-fill
    /// sample on the skin line is a warm grey and not a subject.
    private static let skinSamples: [Sample] = grid.filter {
        ColorEngine.skinWeight($0.rgb) > 0.5
    }

    // MARK: - 1. Saturation, and the whole of where its hue rotation comes from

    /// THE LAW, and it holds — with the Density dial at zero.
    ///
    /// This is the control the docs describe: a chroma scale in Lumen UCS, holding
    /// H-K-corrected perceived brightness and hue. At `density = 0` the stage is
    /// exactly that and nothing else, and across the whole grid, at every push from
    /// +10 to +100, it does not move a hue by a quarter of a degree.
    func testSaturationPreservesHueWhenTheDensityDialIsAtZero() {
        for amount in [10.0, 25, 50, 75, 100] {
            let engine = colorEngine(ColorAdjust(saturation: amount, density: 0))
            let (worst, at) = worstHueMove(engine)
            XCTAssertLessThan(worst, Self.hueTolerance,
                              String(format: "Saturation +%.0f at Density 0 rotated hue by %.3f° at %@",
                                     amount, worst, at?.label ?? "—"))
        }
    }

    /// And it holds on the way down at any Density, because the subtractive branch is
    /// guarded on `satAmount > 0`: a negative Saturation is a plain walk toward the
    /// neutral axis.
    func testNegativeSaturationPreservesHueAcrossTheWheel() {
        for amount in [-10.0, -25, -50, -75, -100] {
            let engine = colorEngine(ColorAdjust(saturation: amount))
            let (worst, at) = worstHueMove(engine)
            XCTAssertLessThan(worst, Self.hueTolerance,
                              String(format: "Saturation %.0f rotated hue by %.3f° at %@",
                                     amount, worst, at?.label ?? "—"))
        }
    }

    /// **THE DEFECT.** At the shipped defaults — `density = 50`, on by default, on
    /// every photograph — a positive Saturation move rotates hue, and the rotation
    /// grows with the slider.
    ///
    /// The mechanism, confirmed against the engine rather than taken from an audit:
    /// `ColorEngine.applyVibranceSaturation` blends the additive push against
    /// `subtractivePush`, which is a PER-CHANNEL GAMMA on the channel ratios against
    /// `c.maxComponent`. A per-channel power in linear RGB multiplies all three
    /// log-ratios by γ, and a log-RGB ray is not an iso-hue line in OKLab — only the
    /// six primaries and secondaries sit on one. Everything between them rotates, and
    /// γ = 1 + satAmount, so the rotation is proportional to the slider. The two tests
    /// above are what prove it is this and not something else: turn the dial that
    /// selects the subtractive branch to zero and the rotation is gone; take the same
    /// slider negative, where the branch is guarded off, and it is gone.
    ///
    /// Measured on the grid at the shipped Density 50, worst case over 720 colours:
    ///
    ///     Saturation  +10   +25   +50   +75  +100
    ///     rotation   2.14° 4.70° 7.83° 10.07° 11.57°
    ///
    /// The worst colours are the violets — h = 280–290, where the log-RGB ray is
    /// furthest from an OKLab hue line — and on the skin band the same sweep reads
    /// 2.21° at +25, 4.15° at +50 and 7.29° at +100, which is the visible half of the
    /// complaint this file was opened for: a face pushed +50 lands four degrees round
    /// the wheel, and four degrees off the I-bar is the difference between skin and
    /// orange.
    ///
    /// THIS TEST USED TO PIN THE DEFECT. It now pins its absence, at the same
    /// settings and over the same grid, so the numbers above stay falsifiable in-tree
    /// rather than becoming a story about something that was once true.
    ///
    /// The fix is in `ColorEngine`, after the blend: the hue of the colour the two
    /// branches are two renderings of is restored once, on the blended result. So the
    /// rotation is not "small now" — it is zero by construction, and the tolerance
    /// below is a floating-point tolerance rather than a behavioural one. What is left
    /// is around 1e-12 degrees, which is the round trip through OKLCh and back.
    func testSaturationNoLongerRotatesHueAtAnyAmount() {
        // Exactly the amounts that were measured, and the degrees they used to move.
        let wasRotating: [(amount: Double, wasDegrees: Double)] = [
            (10, 2.14), (25, 4.70), (50, 7.83), (75, 10.07), (100, 11.57),
        ]
        for m in wasRotating {
            let engine = colorEngine(ColorAdjust(saturation: m.amount))
            let (worst, at) = worstHueMove(engine)
            XCTAssertLessThan(worst, 1e-6,
                              String(format: "Saturation +%.0f rotates hue by %.6f° — it used to move %.2f° and must now move none, at %@",
                                     m.amount, worst, m.wasDegrees, at?.label ?? "—"))
        }

        // And on the band the complaint was about. A face pushed +50 landed four
        // degrees round the wheel, and four degrees off the I-bar is the difference
        // between skin and orange.
        XCTAssertFalse(Self.skinSamples.isEmpty, "the grid must contain real skin tones")
        let onSkin: [(amount: Double, wasDegrees: Double)] = [(25, 2.21), (50, 4.15), (100, 7.29)]
        for m in onSkin {
            let engine = colorEngine(ColorAdjust(saturation: m.amount))
            let (worst, at) = worstHueMove(engine, over: Self.skinSamples)
            XCTAssertLessThan(worst, 1e-6,
                              String(format: "Saturation +%.0f rotates a SKIN hue by %.6f° — it used to move %.2f°, at %@",
                                     m.amount, worst, m.wasDegrees, at?.label ?? "—"))
        }
    }

    /// THE DARKENING SURVIVED. This is the other half of the fix and the half a
    /// hue-restore can quietly destroy.
    ///
    /// Density's photographic idea is that colour intensifies by DENSIFYING — the
    /// absorbing layers deepen while the transmitting one holds, so a saturated colour
    /// goes darker instead of pushing its channels apart toward neon. Restoring hue
    /// after the blend must not also restore lightness, or the dial becomes a no-op and
    /// the fix has thrown out the model along with its artefact.
    ///
    /// So: at the shipped Density, a positive Saturation move must still land DARKER
    /// than the purely additive path does, on colours with enough chroma to have a
    /// direction at all.
    func testDensityStillDarkensAfterTheHueIsRestored() {
        let dense = colorEngine(ColorAdjust(saturation: 60))
        let additive = colorEngine(ColorAdjust(saturation: 60, density: 0))
        var darker = 0
        var compared = 0
        for sample in HuePreservationTests.grid {
            let a = lch(additive.apply(sample.rgb))
            let d = lch(dense.apply(sample.rgb))
            guard lch(sample.rgb).C > 0.05,
                  a.L.isFinite, d.L.isFinite else { continue }
            compared += 1
            if d.L < a.L - 1e-9 { darker += 1 }
        }
        XCTAssertGreaterThan(compared, 100, "the grid must offer real colours to compare")
        XCTAssertGreaterThan(Double(darker) / Double(compared), 0.9,
                             "the subtractive path stopped darkening: only \(darker) of "
                             + "\(compared) chromatic colours came out darker than the "
                             + "additive push, so the hue restore has undone the model "
                             + "rather than its artefact")
    }

    /// Density at zero is not merely small, it is the additive path exactly — which is
    /// what makes the dial the whole of the mechanism rather than most of it.
    func testDensityZeroIsExactlyThePurelyAdditivePush() {
        let plain = colorEngine(ColorAdjust(saturation: 60, density: 0))
        for s in HuePreservationTests.grid {
            let out = plain.apply(s.rgb)
            guard let d = hueMove(s.rgb, out).map(abs) else { continue }
            XCTAssertLessThan(d, Self.hueTolerance,
                              "Density 0 still rotated hue by \(d)° at \(s.label)")
        }
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

        // Part two: on a colour the engine's own `skinWeight` scores as skin, the
        // guarded push must land short of the unguarded one. Compared against the same
        // engine with Protect Skin at zero, so the only difference is the guard.
        let bare = colorEngine(ColorAdjust(vibrance: 100, protectSkin: 0))
        XCTAssertFalse(Self.skinSamples.isEmpty, "the grid must contain real skin tones")
        for s in Self.skinSamples {
            let guarded = lch(engine.apply(s.rgb)).C / Swift.max(s.chroma, 1e-9)
            let unguarded = lch(bare.apply(s.rgb)).C / Swift.max(s.chroma, 1e-9)
            XCTAssertLessThan(guarded, unguarded - 1e-9,
                              "Protect Skin did not hold Vibrance back at \(s.label)")
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
        assertChromaRisesWithTheSlider("Saturation") { ColorAdjust(saturation: $0) }
    }

    func testVibranceIsMonotoneInItsParameterAcrossTheWheel() {
        assertChromaRisesWithTheSlider("Vibrance") { ColorAdjust(vibrance: $0) }
    }

    private func assertChromaRisesWithTheSlider(_ name: String,
                                                _ make: (Double) -> ColorAdjust) {
        var worst = 0.0
        var detail = "—"
        var previous = [Double](repeating: -.infinity, count: HuePreservationTests.grid.count)
        var previousAmount = -100.0
        for step in 0...80 {
            let amount = -100 + Double(step) * 2.5
            let engine = colorEngine(make(amount))
            for (i, s) in HuePreservationTests.grid.enumerated() {
                let out = engine.apply(s.rgb)
                let C = out.isFinite ? lch(out).C : 0
                let drop = previous[i] - C
                if previous[i].isFinite, drop > worst {
                    worst = drop
                    detail = String(format: "chroma fell %.6f between %@ %.1f and %.1f at %@",
                                    drop, name, previousAmount, amount, s.label)
                }
                previous[i] = C
            }
            previousAmount = amount
        }
        XCTAssertLessThan(worst, 1e-6, "\(name) reverses — \(detail)")
    }

    // MARK: - 4. Hue linearity

    /// The representation itself: rotate by +δ in OKLCh, come back through RGB, rotate
    /// by −δ, and the colour must be the one you started with. This is the floor every
    /// hue-selective tool stands on — if the round trip through RGB is not hue-linear
    /// there is no point testing anything built on it — and it is what fixes the noise
    /// figure `hueTolerance` is quoted against.
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
        XCTAssertLessThan(worst, 1e-12, "The hue round trip does not return the colour — \(detail)")
    }

    /// The seam. `Num.wrapHue` promises [0, 360) and twenty-one callers across the
    /// colour engine read it for that, so the top end has to be closed in fact and not
    /// only in the comment.
    ///
    /// The input that breaks it is not exotic: `ulp(360)` is 5.7e-14, so any hue in the
    /// last few ulps below zero lands on exactly 360 when the wrap adds 360 to it. Two
    /// grade pucks on opposite sides of red interpolate straight through that point,
    /// and the sign of the rounding error at `atan2(≈0, +x)` is not the caller's to
    /// choose — so the same colour came back as 0 half the time and 360 the other half.
    /// Nothing renders differently, which is exactly why nothing surfaced it: it is the
    /// canonical text and therefore the fingerprint that splits in two.
    ///
    /// Swept three ways — by construction on the ulps themselves, by walking a puck
    /// across the seam the way a look blend does, and through `OKLab.hue` on the whole
    /// grid, which is where the engine's own hues come from.
    func testHueWrappingClosesItsTopEndAcrossTheSeam() {
        // 1. By construction. Every hue in the last ulps below zero is a hue of zero.
        // The smallest negative double there is, then a walk further from zero. Every
        // one of these is `360 − something far below ulp(360)`, so the wrap rounds it
        // to 360 and the fold has to take it back to 0.
        var x: Double = -Double.leastNonzeroMagnitude
        for _ in 0..<64 {
            XCTAssertEqual(Num.wrapHue(x), 0,
                           String(format: "wrapHue(%.3e) came back as %.17g", x, Num.wrapHue(x)))
            x = x.nextDown
        }
        for e in [-1e-18, -1e-16, -5.7e-14, -1e-13, -360.0, -720.0] {
            let wrapped = Num.wrapHue(e)
            XCTAssertGreaterThanOrEqual(wrapped, 0, "wrapHue(\(e)) went below zero")
            XCTAssertLessThan(wrapped, 360,
                              String(format: "wrapHue(%.3e) came back as %.17g", e, wrapped))
        }

        // 2. The walk a look blend takes: two pucks 350° and 10°, slid in a straight
        //    line on the disc, which is `LookSubset.blendedWheel`'s geometry.
        let radiansPerDegree: Double = .pi / 180
        let a = (x: cos(350 * radiansPerDegree), y: sin(350 * radiansPerDegree))
        let b = (x: cos(10 * radiansPerDegree), y: sin(10 * radiansPerDegree))
        for step in 0...4001 {
            let t = Double(step) / 4001
            let px = Num.mix(a.x, b.x, t)
            let py = Num.mix(a.y, b.y, t)
            let wrapped = Num.wrapHue(atan2(py, px) * 180 / .pi)
            XCTAssertGreaterThanOrEqual(wrapped, 0, "the seam walk went below zero at t=\(t)")
            XCTAssertLessThan(wrapped, 360,
                              String(format: "the seam walk reported %.17g at t=%.6f", wrapped, t))
        }

        // 3. Where the engine's own hues come from, over the whole grid and over a fine
        //    sweep of the a/b plane through the seam itself.
        for s in HuePreservationTests.grid {
            XCTAssertLessThan(lch(s.rgb).h, 360, "OKLab reported hue 360 at \(s.label)")
        }
        for i in -2000...2000 {
            let bb = Double(i) * 1e-18
            XCTAssertLessThan(OKLab(L: 0.5, a: 0.1, b: bb).hue, 360,
                              "OKLab reported hue 360 at b = \(bb)")
        }
    }

    /// The same seam, as a PROPERTY over the whole input domain rather than over the
    /// inputs somebody already suspected.
    ///
    /// `testHueWrappingClosesItsTopEndAcrossTheSeam` above sweeps where the engine's
    /// hues actually come from. This one sweeps what a `Double` can be, because
    /// `wrapHue` is `public` and the twenty-one call sites hand it sums, differences
    /// and `atan2` results rather than curated numbers. It states four things:
    ///
    ///   1. RANGE. Every finite input comes back in [0, 360) — never 360, never below
    ///      zero. Checked on the exact boundary the arithmetic has, on the whole
    ///      dynamic range of the type, and on a deterministic pseudo-random sweep.
    ///   2. THE WINDOW ITSELF. The set of inputs that used to return 360 is exactly
    ///      [−2⁻⁴⁵, 0). `ulp(360)` is 2⁻⁴⁴, so `360 − |h|` rounds up to 360 for every
    ///      `|h|` at or below half of that, and ties go to 360 because its last
    ///      mantissa bit is even. Both sides of that boundary are pinned: −2⁻⁴⁵ is the
    ///      largest magnitude that rounds up, and its `nextDown` is the first that
    ///      does not. No input of magnitude ≥ 360 can reach the window — `h` is a
    ///      multiple of its own ulp, which is ≥ 2⁻⁴⁴ there, so a non-zero remainder
    ///      cannot be smaller than 2⁻⁴⁴ — which is why the multiples of 360 come back
    ///      as an exact zero rather than as a near miss.
    ///   3. SAME ANGLE. Wrapping is a change of representative, not of direction: the
    ///      unit vector at the result is the unit vector at the input.
    ///   4. WHAT NON-FINITE DOES. Pinned, not asserted to be nice: ±∞ and NaN come back
    ///      NaN, because `truncatingRemainder` gives NaN and neither comparison fires.
    ///      Callers that can see one guard first (`Gamut.Boundary.maxChroma` and
    ///      `GradeEngine.apply` both do). This is here so a change to it is visible.
    ///
    /// The sign of zero rides along at the end. `wrapHue(-360)` is −0.0 — the `x < 0`
    /// test is false for a negative zero, so the `+= 360` never runs — and that is
    /// tolerated rather than corrected because it cannot be observed: −0.0 compares and
    /// hashes equal to +0.0, and `CanonicalJSON.canonicalNumber` takes its integer
    /// branch and emits "0" for both. That last one is the one that matters, since a
    /// fingerprint split is the whole reason the 360 case was worth closing.
    func testWrapHueHoldsItsHalfOpenRangeOverTheWholeInputDomain() {

        func check(_ h: Double, _ what: String) {
            let w = Num.wrapHue(h)
            guard h.isFinite else {
                XCTAssertTrue(w.isNaN,
                              String(format: "wrapHue(%@) returned %.17g, not NaN — %@",
                                     "\(h)", w, what))
                return
            }
            XCTAssertFalse(w.isNaN, "wrapHue(\(h)) returned NaN — \(what)")
            XCTAssertGreaterThanOrEqual(w, 0,
                String(format: "wrapHue(%.17g) = %.17g is below zero — %@", h, w, what))
            XCTAssertLessThan(w, 360,
                String(format: "wrapHue(%.17g) = %.17g is not below 360 — %@", h, w, what))
            XCTAssertNotEqual(w, 360,
                String(format: "wrapHue(%.17g) returned exactly 360 — %@", h, what))
        }

        // 1. The window, both sides of its boundary. `-2^-45` is the largest magnitude
        //    that rounds up to 360 (ties to even, and 360's last mantissa bit is 0);
        //    one ulp further from zero is the first that does not.
        let windowEdge = -0x1p-45          // −2.842170943040401e-14
        check(windowEdge, "the exact top of the rounding window")
        check(windowEdge.nextDown, "one ulp past the top of the rounding window")
        XCTAssertEqual(Num.wrapHue(windowEdge.nextDown), 359.99999999999994, accuracy: 0,
                       "the first input outside the window no longer lands on 359.99999999999994")

        // Everything inside the window, sampled across sixty orders of magnitude down
        // to the subnormals, plus a walk of the smallest doubles there are.
        for e in stride(from: -45.0, through: -320.0, by: -5.0) {
            check(-exp2(e), "inside the window at -2^\(Int(e))")
        }
        var tiny = -Double.leastNonzeroMagnitude
        for _ in 0..<512 {
            check(tiny, "a subnormal just below zero")
            XCTAssertEqual(Num.wrapHue(tiny), 0,
                           String(format: "wrapHue(%.3e) is not zero", tiny))
            tiny = tiny.nextDown
        }
        for h in [-1e-18, -1e-16, -1e-15, -2.8e-14, -5.7e-14, -1e-13, -1e-9] {
            check(h, "a small negative hue")
        }

        // 2. Multiples of 360, both signs, out to where the spacing of doubles is
        //    coarser than a degree. These come back an exact zero, and the negative
        //    ones come back a NEGATIVE exact zero, which is the pinned part.
        for k in [1.0, 2.0, 3.0, 7.0, 100.0, 1e6, 1e12, 1e15, 2.5e13] {
            check(360 * k, "+\(k) turns")
            check(-360 * k, "−\(k) turns")
            XCTAssertEqual(Num.wrapHue(360 * k), 0, "+\(k) turns is not a zero hue")
            XCTAssertEqual(Num.wrapHue(-360 * k), 0, "−\(k) turns is not a zero hue")
            // The neighbours of a whole turn: the inputs closest to the window that a
            // number of that size can express.
            check((360 * k).nextDown, "just under +\(k) turns")
            check((-360 * k).nextUp, "just inside −\(k) turns")
        }

        // 3. The dynamic range of the type, and a deterministic pseudo-random sweep of
        //    it. SplitMix64 rather than `Double.random` so a failure is reproducible.
        for h in [Double.leastNonzeroMagnitude, -Double.leastNonzeroMagnitude,
                  Double.leastNormalMagnitude, -Double.leastNormalMagnitude,
                  1e-300, -1e-300, 1e300, -1e300, 1e15, -1e15, 1e17, -1e17,
                  Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
                  359.99999999999994, 360, -360, 0, -0.0, 180, -180, 29.23, -29.23] {
            check(h, "a corner of the input range")
        }
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        for i in 0..<200_000 {
            // Half the draws are ordinary hue-sized numbers — sums and differences of
            // degrees, which is what the call sites actually produce — and half are
            // arbitrary bit patterns, filtered to the finite ones.
            let h: Double
            if i % 2 == 0 {
                let u = Double(next() >> 11) * 0x1p-53          // [0, 1)
                h = (u - 0.5) * 4000
            } else {
                let bits = next()
                let candidate = Double(bitPattern: bits)
                h = candidate.isFinite ? candidate : Double(bitPattern: bits & 0x7FEF_FFFF_FFFF_FFFF)
            }
            check(h, "pseudo-random draw \(i)")
        }

        // 4. Same angle, not merely some angle in range. Trig, so the check does not
        //    reuse the remainder the function under test is built on. Bounded to inputs
        //    where argument reduction is still meaningful.
        let toRadians = Double.pi / 180
        for i in -4000...4000 {
            let h = Double(i) * 0.37 - 740          // ≈ ±2220°, several turns either way
            let w = Num.wrapHue(h)
            XCTAssertEqual(cos(w * toRadians), cos(h * toRadians), accuracy: 1e-9,
                           String(format: "wrapHue(%.6f) = %.6f is a different angle", h, w))
            XCTAssertEqual(sin(w * toRadians), sin(h * toRadians), accuracy: 1e-9,
                           String(format: "wrapHue(%.6f) = %.6f is a different angle", h, w))
        }

        // 5. Non-finite, pinned rather than wished away.
        for h in [Double.infinity, -Double.infinity, Double.nan, Double.signalingNaN] {
            XCTAssertTrue(Num.wrapHue(h).isNaN, "wrapHue(\(h)) is no longer NaN")
        }

        // 6. The sign of zero, and the only place it could ever have been seen.
        XCTAssertTrue(Num.wrapHue(-360).sign == .minus,
                      "wrapHue(-360) no longer returns a negative zero — if this is a "
                      + "deliberate normalization the comment above needs to change")
        XCTAssertEqual(Num.wrapHue(-360), Num.wrapHue(360),
                       "the two zeroes stopped comparing equal")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(Num.wrapHue(-360)), "0",
                       "a negative zero hue now reaches canonical text — that is a "
                       + "recipe_fp split of exactly the kind hue 360 was")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(Num.wrapHue(-360)),
                       CanonicalJSON.canonicalNumber(Num.wrapHue(360)),
                       "the two zeroes serialize differently")
    }

    /// The law one level up, through the shipping stage: a Mixer band Hue move of +δ
    /// and one of −δ must be equal and opposite on the same input. That is the property
    /// a photographer feels when he drags a hue slider past zero and back, and it is
    /// the one a band tool can actually keep — the selection is read off the input, so
    /// both directions are weighted identically.
    func testAMixerHueMoveIsEqualAndOppositeAboutZero() {
        var worst = 0.0
        var detail = "—"
        for band in 0..<ColorEngine.bandCount {
            for amount in [10.0, 25.0, 100.0] {
                var up = Mixer(); up.bands[band].hue = amount
                var down = Mixer(); down.bands[band].hue = -amount
                let there = colorEngine(ColorAdjust(), mixer: up)
                let back = colorEngine(ColorAdjust(), mixer: down)
                for s in HuePreservationTests.grid {
                    guard let a = hueMove(s.rgb, there.apply(s.rgb)),
                          let b = hueMove(s.rgb, back.apply(s.rgb)) else { continue }
                    let d = abs(a + b)
                    if d > worst {
                        worst = d
                        detail = String(format: "band %d ±%.0f gave %+.3f° and %+.3f° at %@",
                                        band, amount, a, b, s.label)
                    }
                }
            }
        }
        XCTAssertLessThan(worst, 1e-9, "A Mixer Hue move is not symmetric about zero — \(detail)")
    }

    /// The other reading of "+10 then −10 returns the colour" — two STACKED stages,
    /// which is what a global Mixer plus a mask's own Mixer is — and it cannot be
    /// exactly true of any band tool, including this one. The second stage reads its
    /// band weights off the colour the first stage moved, so a hue pushed across a
    /// feather edge comes back weighted differently than it went. Measured worst on the
    /// grid: 4.65°, on an orange at h = 80 pushed +25 into the Yellow band's feather.
    ///
    /// Pinned rather than asserted to zero because the alternative — evaluating the
    /// selection against a reference the stage no longer has — would make a mask's
    /// colour edit depend on the global one in a way the photographer cannot see. This
    /// is the honest bound, and it is here so that a change which makes it WORSE is
    /// visible.
    func testTwoStackedMixerHueMovesNearlyCancel() {
        var worst = 0.0
        var detail = "—"
        for band in 0..<ColorEngine.bandCount {
            for amount in [10.0, 25.0] {
                var up = Mixer(); up.bands[band].hue = amount
                var down = Mixer(); down.bands[band].hue = -amount
                let there = colorEngine(ColorAdjust(), mixer: up)
                let back = colorEngine(ColorAdjust(), mixer: down)
                for s in HuePreservationTests.grid where s.fill >= 0.40 {
                    guard let d = hueMove(s.rgb, back.apply(there.apply(s.rgb))).map(abs)
                    else { continue }
                    if d > worst {
                        worst = d
                        detail = String(format: "band %d ±%.0f left %.3f° at %@",
                                        band, amount, d, s.label)
                    }
                }
            }
        }
        XCTAssertLessThan(worst, 5.0, "Stacked Mixer Hue moves cancel worse than they did — \(detail)")
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
                    if let dh = hueMove(s.rgb, out).map(abs), dh > worstHue {
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
        let n = HuePreservationTests.grid.count
        for band in 0..<ColorEngine.bandCount {
            // Saturation: output chroma rises with the slider.
            var previousC = [Double](repeating: -.infinity, count: n)
            // Hue: the signed rotation rises with the slider.
            var previousH = [Double](repeating: -.infinity, count: n)
            // Luminance: output lightness rises with the slider.
            var previousL = [Double](repeating: -.infinity, count: n)
            for step in 0...20 {
                let amount = -100 + Double(step) * 10
                var satMixer = Mixer(); satMixer.bands[band].sat = amount
                var hueMixer = Mixer(); hueMixer.bands[band].hue = amount
                var lumMixer = Mixer(); lumMixer.bands[band].lum = amount
                let satEngine = colorEngine(ColorAdjust(), mixer: satMixer)
                let hueEngine = colorEngine(ColorAdjust(), mixer: hueMixer)
                let lumEngine = colorEngine(ColorAdjust(), mixer: lumMixer)
                for (i, s) in HuePreservationTests.grid.enumerated() {
                    let C = lch(satEngine.apply(s.rgb)).C
                    XCTAssertGreaterThan(C, previousC[i] - 1e-9,
                                         String(format: "band %d Saturation reversed at %.0f, %@",
                                                band, amount, s.label))
                    previousC[i] = C
                    if let H = hueMove(s.rgb, hueEngine.apply(s.rgb)) {
                        XCTAssertGreaterThan(H, previousH[i] - 1e-9,
                                             String(format: "band %d Hue reversed at %.0f, %@",
                                                    band, amount, s.label))
                        previousH[i] = H
                    }
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

    /// The colour stage runs on unbounded scene-referred data and must never clip a
    /// channel: a per-channel clip is what turns a pushed red into a different colour
    /// rather than a more saturated one. Pushing the 95% ring to Saturation +100 has to
    /// come out as MORE CHROMA at the SAME HUE, out of gamut if need be — the display
    /// transform compresses it back later, hue-preserving, once "the display" means
    /// something.
    ///
    /// Read at Density 0, which is the only setting at which the stage is the thing it
    /// is documented to be; `testDensityIsTheWholeOfSaturationsHueRotation` carries
    /// what the shipped default does to the same colours, and its worst input — h=290
    /// at 95% of gamut — is one of these.
    func testAGamutEdgePushGainsChromaWithoutSwingingHue() {
        let edge = HuePreservationTests.grid.filter { $0.fill >= 0.95 }
        XCTAssertFalse(edge.isEmpty)
        let engine = colorEngine(ColorAdjust(saturation: 100, density: 0))
        var worstHue = 0.0
        var detail = "—"
        for s in edge {
            let out = engine.apply(s.rgb)
            let after = lch(out)
            XCTAssertGreaterThan(after.C, s.chroma - 1e-9,
                                 "Saturation +100 LOST chroma at the gamut edge, \(s.label)")
            guard let d = hueMove(s.rgb, out).map(abs) else { continue }
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
                    if C > Self.hueIsMeaningful {
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

    /// What the boundary TABLE is worth, because the clip is only as good as the gamut
    /// it aims at, and this one is a 36 × 17 bilinear approximation of a surface with a
    /// cusp in it.
    ///
    /// Measured against a bisection at every (L, h) on a 95 × 360 grid, the table
    /// under-reports the real boundary by up to 17.8% through the whole photographic
    /// range — worst around the Rec.2020 blue cusp, h ≈ 246 — and by up to 53.5% in the
    /// last twentieth of lightness, where the last row is pinned at zero and the
    /// interpolation ramps down from L = 0.9375 while the true boundary is still 0.25
    /// of chroma at L = 0.97. So the last colour operation in the render aims at a
    /// gamut up to a fifth smaller than the display's, and Lumen's most saturated
    /// colours are duller than the screen can show.
    ///
    /// It is NOT fixed here, and the measurement is why: a 4× finer table (72 × 65)
    /// costs 3× the build and still leaves 13.5%, and the standard two-line
    /// cusp model is worse on this gamut than the table is — 30% over-reported at
    /// L = 0.97. The fix is a boundary that follows the cusp, which is a redesign
    /// rather than a constant, and it would move every proof record in the suite.
    ///
    /// What IS asserted is the safety direction. Over-reporting is the dangerous one:
    /// it lets a colour through that the encoder then clips per channel, and a
    /// per-channel clip swings hue. Measured across the same grid at up to 4× the
    /// boundary chroma, what survives the clip sits at most 0.0225 outside [0, 1] and
    /// the clamp that follows moves hue by at most 0.98°, which is the edge of visible
    /// on a flat patch and nowhere near the 11.6° section 1 is about.
    func testWhatEscapesTheGamutClipIsSmallEnoughForTheEncodersClampToSwallow() {
        let boundary = Gamut.sharedBoundary
        var worstExcursion = 0.0
        var excursionDetail = "—"
        var worstSwing = 0.0
        var swingDetail = "—"
        for hi in 0..<72 {
            let hue = Double(hi) * 5
            for li in 2..<40 {
                let L = Double(li) / 40
                let maxC = Gamut.maxChroma(L: L, hue: hue)
                guard maxC > 1e-4 else { continue }
                for fill in [1.0, 1.5, 2.5, 4.0] {
                    let c = Self.context.toRGB(OKLCh(L: L, C: maxC * fill, h: hue))
                    let mapped = Gamut.softClip(c, boundary: boundary)
                    let over = Swift.max(mapped.maxComponent - 1, -mapped.minComponent)
                    if over > worstExcursion {
                        worstExcursion = over
                        excursionDetail = String(format: "%.4f at h=%.0f L=%.2f ×%.1f",
                                                 over, hue, L, fill)
                    }
                    let clamped = mapped.clamped()
                    guard let swing = hueMove(mapped, clamped).map(abs) else { continue }
                    if swing > worstSwing {
                        worstSwing = swing
                        swingDetail = String(format: "%.3f° at h=%.0f L=%.2f ×%.1f",
                                             swing, hue, L, fill)
                    }
                }
            }
        }
        XCTAssertLessThan(worstExcursion, 0.05,
                          "The clip left a channel further outside the display than the encoder can absorb — \(excursionDetail)")
        XCTAssertLessThan(worstSwing, 1.5,
                          "The encoder's clamp swung hue — \(swingDetail)")
    }

    // MARK: - 7. White balance

    /// A neutral through a temp/tint move and back must be the neutral it started as.
    /// The two engines are each other's inverse by construction — adapt to the target,
    /// then adapt back — so anything left over is a place where the forward and reverse
    /// models disagree about what a (Kelvin, tint) pair means.
    func testANeutralSurvivesATempTintRoundTrip() {
        let neutral = RGB(gray: LumenLog.midGrey)
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
        let neutral = RGB(gray: LumenLog.midGrey)
        var worst = 0.0
        var detail = "—"
        for kelvin in [3200.0, 4000, 6500, 12000] {
            for tint in [-40.0, 0, 40] {
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
                let residue = Swift.max(abs(out.r - mean),
                                        Swift.max(abs(out.g - mean), abs(out.b - mean))) / mean
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

    /// **The second defect the grid found, and this one is closed.** Both white-balance
    /// axes must be monotone in their own parameter.
    ///
    /// Tint was not. `ColorTemperature.tintLimit` bounded the magenta half by the
    /// illuminant's own cone response, which is very nearly exact for a PURE tint move
    /// — as-shot equal to target — and is the only case `TintGuardTests` sweeps. Off
    /// that diagonal, which is what a daylight-balanced file taken to a warm target is,
    /// the rendered green↔magenta axis turned round well inside the bound: at +46 at
    /// 2800 K against a bound of +69.80, at +101 at 4000 K against +114.51, at +136 at
    /// 5000 K against +142.69. Past the turn the magenta slider moved the picture
    /// toward green, and at 2800 K tint +80 it rendered RGB(0.0967, −0.0872, 3.1857) —
    /// a negative green channel and blue at 17.7× the neutral it started from.
    ///
    /// `magentaMonotoneLimit` now bounds it on the picture instead of on the
    /// illuminant, and this is the sweep that says so.
    func testBothWhiteBalanceAxesAreMonotoneInTheirOwnParameter() {
        let neutral = RGB(gray: LumenLog.midGrey)

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

        for kelvin in [2000.0, 2800, 3200, 4000, 5000, 5500, 8000] {
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

    /// The claim `TintGuardTests` makes — "no (Kelvin, tint) pair the app can ask for"
    /// inverts the picture — swept only as-shot == target. This is the same claim over
    /// the PAIR, which is where it was false: a negative channel is not a dark colour,
    /// it is not a colour, and every stage downstream of white balance is entitled to
    /// assume it never sees one.
    func testNoTemperatureAndTintPairRendersAChannelNegative() {
        let neutral = RGB(gray: LumenLog.midGrey)
        for asShot in [2000.0, 2800, 4000, 5500, 8000, 12000] {
            for target in stride(from: 2000.0, through: 12000.0, by: 250) {
                for tint in stride(from: -150.0, through: 150.0, by: 5) {
                    let out = WhiteBalanceEngine(asShotKelvin: asShot, asShotTint: 0,
                                                 targetKelvin: target, targetTint: tint)
                        .apply(neutral)
                    XCTAssertTrue(out.isFinite,
                                  "as-shot \(asShot) K → \(target) K tint \(tint) is not finite")
                    XCTAssertGreaterThanOrEqual(
                        out.minComponent, 0,
                        String(format: "as-shot %.0f K → %.0f K tint %+.0f rendered (%.4f, %.4f, %.4f)",
                               asShot, target, tint, out.r, out.g, out.b))
                }
            }
        }
    }

    /// THE CROSSOVER, PINNED FROM BOTH SIDES.
    ///
    /// The test below asserts the inequality the guard's contract is written as — the
    /// bound is at least 150 from 5500 K up — and an inequality is not enough here,
    /// because the margin is 2.2 units. The bound at 5500 K is +152.22 against a
    /// slider that stops at +150, and it first enters the shipped range at about
    /// 5430 K: 5400 K is already +149.13.
    ///
    /// Both directions matter, and for different reasons. If the bound DROPS below
    /// 150 at 5500 K, ordinary daylight work starts hitting a clamp that the guard's
    /// own docstring promises it never will — and an "at least 150" test passes right
    /// up until the moment that happens, which is too late to be told. If it RISES far
    /// above 150, the bound has stopped tracking the turn it is supposed to be
    /// measuring and the reversal is back inside the slider somewhere warmer.
    ///
    /// The bound is a function of the `locus` fit, and `locus` crossfades from the
    /// Planckian branch to the daylight branch through a smoothstep between 3500 and
    /// 4500 K. A change anywhere near that fit moves this number. Failing here means
    /// the margin moved; go and look at what it is now before deciding whether the
    /// bound or the fit is wrong.
    func testTheMagentaBoundKeepsItsDaylightMarginOnBothSides() {
        let atDaylight = ColorTemperature.tintLimit(kelvin: 5500)
        XCTAssertGreaterThanOrEqual(atDaylight, ColorTemperature.maxTint,
                                    "5500 K now clamps inside the shipped range at \(atDaylight)")
        XCTAssertLessThan(atDaylight, 160,
                          "5500 K's bound rose to \(atDaylight) — it has stopped tracking the turn")

        // And the crossover itself: the bound enters the shipped range between these
        // two temperatures, which is what "about 5430 K" means as an assertion.
        XCTAssertLessThan(ColorTemperature.tintLimit(kelvin: 5400), ColorTemperature.maxTint,
                          "the bound no longer enters the shipped range below 5500 K")
        XCTAssertGreaterThan(ColorTemperature.tintLimit(kelvin: 5450), 140,
                             "the bound fell far below the shipped range just under daylight")
    }

    /// The bound tightened only where it had to. Daylight — the range the guard's own
    /// contract promises is untouched — still spends its whole ±150.
    func testTheMagentaBoundLeavesDaylightAlone() {
        for kelvin in stride(from: 5500.0, through: ColorTemperature.maxKelvin, by: 250) {
            XCTAssertGreaterThanOrEqual(ColorTemperature.tintLimit(kelvin: kelvin), 150,
                                        "\(kelvin) K clamps inside the shipped range")
        }
        for kelvin in [2000.0, 2800, 3200, 4000, 5000] {
            XCTAssertLessThan(ColorTemperature.tintLimit(kelvin: kelvin), 150,
                              "\(kelvin) K should still be bounded")
        }
        // Green is never bounded, at any temperature: it moves toward the interior of
        // the plane, where every cone response grows.
        for kelvin in stride(from: 2000.0, through: 20000.0, by: 500) {
            XCTAssertEqual(ColorTemperature.clampedTint(kelvin: kelvin, tint: -150), -150,
                           accuracy: 1e-12, "green tint clamped at \(kelvin) K")
        }
    }
}

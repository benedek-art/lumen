// GradeJointLimiterTests.swift
// The grading wheels' Luminance limiter and the Colour Balance grid's Brilliance
// limiter each solved the same constraint — `1 + 3·slope ≥ margin`, margin 0.05 — as if
// it were the only thing grading the frame, so each was permitted to hand away 0.95 of
// a base slope of 1. They run on the SAME pixel, over the SAME crossfades, inside one
// `GradeEngine.apply`, and nothing accounted for both.
//
// Measured on a −9…+5 EV grey ramp, before `solveJointScale` existed:
//
//   wheels mid +1.0 / high −1.0 alone         0.0 sRGB code values of fold
//   Brilliance mid +100 / high −100 alone     0.0
//   BOTH                                     46.87   (lumScale 0.600212485,
//                                                     brillianceScale 0.205318960)
//   wheels ±0.5 with Brilliance ±20          30.75   (0.997976599 / 0.933268047)
//   wheels ±0.3 with Brilliance ±15           4.39   (1.000000000 / 1.000000000)
//
// THE SHARP CASE IS THE GENTLE ONE. At wheels ±0.3 with Brilliance ±15 both limiters
// report exactly 1.0 — "nothing to limit" — and the picture folds by 4.4 code values
// anyway. That is a lone Midtones +0.3, which `GradeLuminanceInversionTests` calls
// "nowhere near the monotonicity limit", set beside a Brilliance inside the panel's own
// ±20 warning line (LookPanel.swift:865). It is larger than the B2-01 defect the
// Brilliance limiter was built for (28.53 code values) and it is on the shipping render
// path: `RenderPlan.swift:218` bakes `grade.apply(color.apply(scene))`.
//
// Why neither existing file could see it: `GradeLuminanceInversionTests` sweeps the
// three wheel `lum` values with colourBalance at zero throughout, and
// `BrillianceMonotoneTests` sweeps a full 5×5×5 Brilliance grid with every wheel `lum`
// at zero. Neither ever set both. Both have been widened by this change; this file is
// the composed space's own.
//
// THE LOAD-BEARING CLAIM IS THE FIRST TEST, not the last. A joint correction that fixed
// the fold and moved everything else would not be landable: the fix is bounded by the
// property that `jointScale` is EXACTLY 1 whenever either side is untouched, so every
// single-tool recipe renders bit-identically and only recipes using both can move.
// `testEitherSideUntouchedRendersBitIdentically` pins that against a hash of 71,136
// renders measured on the PRE-FIX engine.

import XCTest
@testable import LumenCore

final class GradeJointLimiterTests: XCTestCase {

    /// A reversal smaller than this is float noise, not a control changing its mind —
    /// the same millionth of a code value `ProofRecord.agrees` calls agreement.
    private static let noise: Double = 1e-6

    // MARK: - Reading the composed response

    private func engine(_ wheels: GradingWheels) -> GradeEngine {
        GradeEngine(wheels: wheels, printerLights: PrinterLights())
    }

    /// The two controls opposed across the mid/highlight crossfade, which is where they
    /// compose: a Luminance ring on each of Midtones and Highlights, and a Brilliance
    /// row on each of the same two zones.
    private func opposed(wheelLum: Double, brilliance: Double,
                         blending: Double = 50) -> GradingWheels {
        var wheels = GradingWheels()
        wheels.blending = blending
        wheels.mid.lum = wheelLum
        wheels.high.lum = -wheelLum
        wheels.colorBalance.brilliance = ColorBalanceAxis(mid: brilliance,
                                                          high: -brilliance)
        return wheels
    }

    private func realisedLuminance(_ engine: GradeEngine, at t: Double) -> Double {
        let out: RGB = engine.apply(RGB(gray: LumenLog.midGrey * pow(2.0, t)))
        let w: RGB = GradeEngine.workingLuminanceWeights
        return w.r * out.r + w.g * out.g + w.b * out.b
    }

    private func codeValue(_ luminance: Double) -> Double {
        255 * TransferFunction.srgb.encode(Swift.max(0, luminance))
    }

    /// Worst peak-to-trough reversal over the whole −9…+5 EV axis, in sRGB code values,
    /// with the two positions it happened between.
    private func worstReversal(step: Double = 0.005,
                               _ luminance: (Double) -> Double)
        -> (code: Double, peakEV: Double, troughEV: Double) {
        var peak: Double = -.infinity
        var peakEV: Double = -9
        var worst: Double = 0
        var worstPeakEV: Double = -9
        var worstTroughEV: Double = -9
        var t: Double = -9
        while t <= 5 + 1e-12 {
            let value: Double = codeValue(luminance(t))
            if value > peak {
                peak = value
                peakEV = t
            }
            if peak - value > worst {
                worst = peak - value
                worstPeakEV = peakEV
                worstTroughEV = t
            }
            t += step
        }
        return (worst, worstPeakEV, worstTroughEV)
    }

    /// THE COMPOSED RESPONSE, written out of the documented model rather than read off
    /// the engine, so a test can render what the PRE-FIX engine rendered — whose joint
    /// factor was 1 by not existing — without keeping a second engine.
    ///
    /// On the neutral axis both moves are multiplicative and both cube back to light
    /// (`GradeEngine.lumRangeStops`): a neutral has zero chroma, so the H-K term drops
    /// out of the grid's quadratics, Brilliance rides `L` alone, the wheels' UCS gain
    /// rides `L` alone, and `L` cubes back to luminance.
    /// ```
    /// Y = 0.18·2^t · 2^(3·S) · G³
    ///   S = Σ w_z·stops_z · lumScale · joint
    ///   G = max(0, 1 + (global + brillianceScale·joint·Σ w_z·v_z)/100)
    /// ```
    /// `testTheComposedModelIsTheEngine` is what makes it evidence rather than
    /// assertion.
    private func modelledLuminance(_ wheels: GradingWheels, windows: ZoneWindows,
                                   lumScale: Double, brillianceScale: Double,
                                   joint: Double, at t: Double) -> Double {
        let w = windows.weights(at: t)
        let stopsOf: (Wheel) -> Double = { GradeEngine.lumRangeStops * Num.clamp($0.lum, -1, 1) }
        let zoned: Double = w.shadows * stopsOf(wheels.shadows)
            + w.mid * stopsOf(wheels.mid) + w.high * stopsOf(wheels.high)
        let stops: Double = Num.clamp(stopsOf(wheels.global) + zoned * lumScale * joint,
                                      -2, 2)
        let axis: ColorBalanceAxis = wheels.colorBalance.brilliance
        let brillianceZone: Double = w.shadows * Num.clamp(axis.shadows, -100, 100)
            + w.mid * Num.clamp(axis.mid, -100, 100)
            + w.high * Num.clamp(axis.high, -100, 100)
        let gain: Double = Swift.max(0, 1 + (Num.clamp(axis.global, -100, 100)
            + brillianceScale * joint * brillianceZone) / 100)
        return LumenLog.midGrey * pow(2.0, t) * pow(2.0, 3 * stops) * gain * gain * gain
    }

    // MARK: - The identity proof

    /// Neutral and three off-neutral rays at each of 57 exposures — 228 colours, so the
    /// claim is about the OKLab and UCS round trips a real frame takes, not only the
    /// grey axis the solves are derived on.
    private static func probes() -> [RGB] {
        var out: [RGB] = []
        for t in stride(from: -9.0, through: 5.0, by: 0.25) {
            let y = LumenLog.midGrey * pow(2.0, t)
            out.append(RGB(gray: y))
            out.append(RGB(y * 1.6, y * 0.9, y * 0.4))
            out.append(RGB(y * 0.3, y * 0.8, y * 1.7))
            out.append(RGB(y * 0.9, y * 1.4, y * 0.7))
        }
        return out
    }

    /// Every recipe here uses ONE of the two tools. The joint correction must be
    /// exactly 1 on all of them, which is what makes it landable.
    ///
    /// Two of the families are the ones a careless guard would get wrong:
    ///   · the wheels driven hard WITH the grid's other axes at full deflection — hue
    ///     shift, vibrance, chroma, saturation and a GLOBAL Brilliance of +80. None of
    ///     those contributes tonal slope (chroma and saturation hold perceived
    ///     brightness by construction, and global rides on top of the partition), so
    ///     the joint factor must not engage;
    ///   · the grid's Brilliance zones driven hard WITH the GLOBAL wheel's Luminance at
    ///     +0.4 and a tint on it. The Global wheel is outside `lumScale` for the same
    ///     reason, and must be outside this too.
    private static func singleToolRecipes() -> [(String, GradingWheels)] {
        var out: [(String, GradingWheels)] = []
        let lums: [Double] = [-1, -0.6, -0.3, 0.3, 0.6, 1]
        let paths: [(String, WritableKeyPath<GradingWheels, Wheel>)] =
            [("global", \.global), ("shadows", \.shadows), ("mid", \.mid), ("high", \.high)]
        for blending in [0.0, 25.0, 50.0, 100.0] {
            for (name, path) in paths {
                for lum in lums {
                    var w = GradingWheels()
                    w.blending = blending
                    w[keyPath: path].lum = lum
                    out.append(("wheel.\(name).lum=\(lum)@\(blending)", w))
                }
            }
            for lum in lums {
                var w = GradingWheels()
                w.blending = blending
                w.mid.lum = lum
                w.high.lum = -lum
                out.append(("wheel.opposed=\(lum)@\(blending)", w))
                var s = GradingWheels()
                s.blending = blending
                s.shadows.lum = lum
                s.high.lum = -lum
                out.append(("wheel.shadowOpposed=\(lum)@\(blending)", s))
            }
            for lum in lums {
                var w = GradingWheels()
                w.blending = blending
                w.mid.lum = lum
                w.high.lum = -lum
                w.shadows = Wheel(hue: 30, sat: 0.8, lum: 0)
                w.colorBalance.chroma = ColorBalanceAxis(global: 40, shadows: -60,
                                                          mid: 80, high: -100)
                w.colorBalance.saturation = ColorBalanceAxis(shadows: 70, mid: -90,
                                                              high: 100)
                w.colorBalance.hueShift = 35
                w.colorBalance.vibrance = -60
                w.colorBalance.brilliance = ColorBalanceAxis(global: 80)
                out.append(("wheel+grid-no-zone-brilliance=\(lum)@\(blending)", w))
            }
            let vals: [Double] = [-100, -50, -20, 20, 50, 100]
            let zones: [(String, WritableKeyPath<ColorBalanceAxis, Double>)] =
                [("global", \.global), ("shadows", \.shadows), ("mid", \.mid),
                 ("high", \.high)]
            for (name, zone) in zones {
                for v in vals {
                    var w = GradingWheels()
                    w.blending = blending
                    w.colorBalance.brilliance[keyPath: zone] = v
                    out.append(("bril.\(name)=\(v)@\(blending)", w))
                }
            }
            for v in vals {
                var w = GradingWheels()
                w.blending = blending
                w.colorBalance.brilliance = ColorBalanceAxis(mid: v, high: -v)
                out.append(("bril.opposed=\(v)@\(blending)", w))
                var x = GradingWheels()
                x.blending = blending
                x.colorBalance.brilliance = ColorBalanceAxis(global: -50, shadows: -v,
                                                              mid: v, high: -v)
                x.global = Wheel(hue: 200, sat: 0.5, lum: 0.4)
                out.append(("bril.mixed+globalWheel=\(v)@\(blending)", x))
            }
        }
        return out
    }

    /// FNV-1a over the bit patterns of every rendered channel, and of both independent
    /// scales, in a fixed order. A hash rather than a table because the claim is about
    /// 71,136 renders and no table of that size is readable; the per-recipe assertions
    /// beside it are what localise a failure when the hash moves.
    private static func identityHash(_ recipes: [(String, GradingWheels)],
                                     probes: [RGB],
                                     each: (String, GradeEngine) -> Void) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func feed(_ d: Double) {
            var bits: UInt64 = d.bitPattern
            for _ in 0..<8 {
                hash = (hash ^ (bits & 0xff)) &* 0x100000001b3
                bits >>= 8
            }
        }
        for (name, wheels) in recipes {
            let engine = GradeEngine(wheels: wheels, printerLights: PrinterLights())
            each(name, engine)
            feed(engine.lumScale)
            feed(engine.colorBalance.brillianceScale)
            for c in probes {
                let out = engine.apply(c)
                feed(out.r)
                feed(out.g)
                feed(out.b)
            }
        }
        return hash
    }

    /// Measured on the PRE-FIX engine — the tree with no `solveJointScale` in it at all
    /// — over the 312 single-tool recipes above at 228 colours each: 71,136 renders,
    /// 213,408 channels, plus the two solved scales per recipe.
    private static let preFixIdentityHash: UInt64 = 12_301_920_802_024_793_674

    /// THE LOAD-BEARING CLAIM. Every recipe that uses ONE of the two tools renders
    /// bit-identically to what it rendered before the joint correction existed.
    ///
    /// It holds structurally — `jointScale` is exactly 1.0 on all of them and `x * 1.0`
    /// is exactly `x` in IEEE 754 — and this checks it empirically against the pre-fix
    /// engine anyway, because "structurally" is what the two solves this fix corrects
    /// each said about the other.
    func testEitherSideUntouchedRendersBitIdentically() {
        let recipes = Self.singleToolRecipes()
        XCTAssertEqual(recipes.count, 312, "the recipe set behind the hash changed")
        let hash = Self.identityHash(recipes, probes: Self.probes()) { name, engine in
            XCTAssertEqual(engine.jointScale, 1.0, accuracy: 0,
                           "\(name) uses one of the two tools and the joint correction "
                               + "engaged anyway — every single-tool recipe must be "
                               + "exactly unlimited, which is what bounds this change "
                               + "to recipes that use both")
            XCTAssertEqual(engine.colorBalance.appliedBrillianceScale,
                           engine.colorBalance.brillianceScale, accuracy: 0,
                           "\(name) applied a Brilliance scale other than the grid's "
                               + "own solve")
        }
        XCTAssertEqual(hash, Self.preFixIdentityHash,
                       "71,136 single-tool renders no longer hash to what the PRE-FIX "
                           + "engine rendered. The joint correction is only landable "
                           + "while every recipe that uses one of the two tools is "
                           + "byte-identical: got \(hash), pre-fix "
                           + "\(Self.preFixIdentityHash).")
    }

    // MARK: - The model is the engine

    /// The composed model against `apply` itself, at settings where the joint factor is
    /// 1, where it binds, and where the grid's gain floors. Every pre-fix number in
    /// this file is read through that model.
    func testTheComposedModelIsTheEngine() {
        for blending in [0.0, 25.0, 50.0, 100.0] {
            for (lum, brilliance) in [(0.0, 0.0), (1.0, 0.0), (0.0, 100.0),
                                      (1.0, 100.0), (0.5, 20.0), (0.3, 15.0),
                                      (-1.0, 100.0), (0.6, -100.0)] {
                let wheels = opposed(wheelLum: lum, brilliance: brilliance,
                                     blending: blending)
                let graded = engine(wheels)
                var t: Double = -9
                while t <= 5 + 1e-12 {
                    let fromEngine = realisedLuminance(graded, at: t)
                    let fromModel = modelledLuminance(
                        wheels, windows: graded.windows, lumScale: graded.lumScale,
                        brillianceScale: graded.colorBalance.brillianceScale,
                        joint: graded.jointScale, at: t)
                    XCTAssertEqual(
                        fromEngine, fromModel,
                        accuracy: Swift.max(fromModel * 1e-9, 1e-18),
                        "the composed model and the engine disagree at t = \(t) EV on "
                            + "wheels ±\(lum) with Brilliance ±\(brilliance) at "
                            + "Blending \(blending)")
                    t += 0.25
                }
            }
        }
    }

    // MARK: - The fold

    /// The three measured settings, pinned from both ends so a regression names itself:
    /// what each did before the joint correction, and what it does now.
    ///
    /// The middle one is the interesting pair of scales — 0.998 and 0.933, both a hair
    /// under 1, each side almost unlimited — and it folds by 30.75 code values. The
    /// last one is the one that matters: both limiters report exactly 1.0 and it folds
    /// by 4.39, more than a code value per five of Brilliance.
    func testTheFoldIsGoneAtEveryMeasuredSetting() {
        let cases: [(lum: Double, brilliance: Double, before: Double,
                     peakEV: Double, troughEV: Double)] = [
            (1.0, 100, 46.8724, -0.535, 1.400),
            (0.5, 20, 30.7537, -0.435, 1.310),
            (0.3, 15, 4.3871, -0.050, 0.955),
        ]
        for c in cases {
            let wheels = opposed(wheelLum: c.lum, brilliance: c.brilliance)
            let graded = engine(wheels)
            let label = "wheels ±\(c.lum) with Brilliance ±\(c.brilliance)"

            // What the pre-fix engine rendered: the two independent scales, and no
            // joint factor at all.
            let before = worstReversal {
                modelledLuminance(wheels, windows: graded.windows,
                                  lumScale: graded.lumScale,
                                  brillianceScale: graded.colorBalance.brillianceScale,
                                  joint: 1, at: $0)
            }
            XCTAssertEqual(before.code, c.before, accuracy: 0.01,
                           "the defect's own magnitude moved on \(label)")
            XCTAssertEqual(before.peakEV, c.peakEV, accuracy: 0.01,
                           "the reversal used to start at \(c.peakEV) EV on \(label)")
            XCTAssertEqual(before.troughEV, c.troughEV, accuracy: 0.01,
                           "the trough used to be at \(c.troughEV) EV on \(label)")

            // And what it renders now.
            let after = worstReversal { realisedLuminance(graded, at: $0) }
            XCTAssertLessThan(after.code, Self.noise,
                              "\(label) still hands back \(after.code) sRGB code values "
                                  + "between \(after.peakEV) EV and \(after.troughEV) "
                                  + "EV, with lumScale \(graded.lumScale), "
                                  + "brillianceScale "
                                  + "\(graded.colorBalance.brillianceScale) and joint "
                                  + "scale \(graded.jointScale)")
        }
    }

    /// The case the two existing files were each blind to, on its own, because it is
    /// the one that makes the defect a defect: NEITHER limiter reports anything to
    /// limit and the picture folds anyway.
    func testTheGentleCaseWhereBothLimitersReportNothingToLimit() {
        let wheels = opposed(wheelLum: 0.3, brilliance: 15)
        let graded = engine(wheels)
        XCTAssertEqual(graded.lumScale, 1.0, accuracy: 0,
                       "the premise of this test is that the wheels' own solve finds "
                           + "nothing to limit at ±0.3")
        XCTAssertEqual(graded.colorBalance.brillianceScale, 1.0, accuracy: 0,
                       "the premise of this test is that the grid's own solve finds "
                           + "nothing to limit at ±15 — inside the panel's own ±20 "
                           + "warning line")
        XCTAssertLessThan(graded.jointScale, 1.0,
                          "both sides are unlimited and the composition of them is "
                              + "not: this is the setting that folds by 4.39 code "
                              + "values behind two limiters both reporting 1.0")
        let after = worstReversal { realisedLuminance(graded, at: $0) }
        XCTAssertLessThan(after.code, Self.noise,
                          "the gentle case still hands back \(after.code) code values")
    }

    /// The composed space itself — the sweep neither existing file performed. Wheel
    /// Luminance on Midtones and Highlights crossed with Brilliance on the same two
    /// zones, 25 × 25 at two Blending settings, against the engine.
    ///
    /// Zero is kept in both level sets deliberately: a quarter of these combinations
    /// use one tool only, so the sweep also states that widening the space did not cost
    /// the single-tool settings anything.
    ///
    /// Read at 0.01 EV, not the 0.02 the earlier drafts used: at Blending 0 the whole
    /// crossfade is 0.1 EV wide, and a step that puts five samples across the feature
    /// being measured is the coarsest that can report its depth rather than a fraction
    /// of it — the failure `solveLumScale`'s own sampling comment describes.
    func testTheComposedSpaceIsMonotone() {
        let lums: [Double] = [-1, -0.4, 0, 0.4, 1]
        let brilliances: [Double] = [-100, -40, 0, 40, 100]
        for blending in [0.0, 50.0] {
            for midLum in lums {
                for highLum in lums {
                    for midBrilliance in brilliances {
                        for highBrilliance in brilliances {
                            var wheels = GradingWheels()
                            wheels.blending = blending
                            wheels.mid.lum = midLum
                            wheels.high.lum = highLum
                            wheels.colorBalance.brilliance = ColorBalanceAxis(
                                mid: midBrilliance, high: highBrilliance)
                            let graded = engine(wheels)
                            let reversal = worstReversal(step: 0.01) {
                                realisedLuminance(graded, at: $0)
                            }
                            XCTAssertLessThan(
                                reversal.code, Self.noise,
                                "wheels \(midLum)/\(highLum) with Brilliance "
                                    + "\(midBrilliance)/\(highBrilliance) at Blending "
                                    + "\(blending) renders \(reversal.troughEV) EV "
                                    + "darker than \(reversal.peakEV) EV — "
                                    + "\(reversal.code) sRGB code values, with "
                                    + "lumScale \(graded.lumScale), brillianceScale "
                                    + "\(graded.colorBalance.brillianceScale) and "
                                    + "joint scale \(graded.jointScale)")
                        }
                    }
                }
            }
        }
    }

    /// And on the SHIPPING PATH, not only in the stage. `RenderPlan` bakes
    /// `grade.apply(color.apply(scene))` into the S9+S10 table, so the fold reached the
    /// picture through a LUT as well as through the engine — and the bake made it
    /// slightly worse, not better, because a cube cell straddling the fold interpolates
    /// across it.
    ///
    /// Measured on the pre-fix tree, on the same −9…+5 EV ramp, at the gentle setting
    /// where both limiters report nothing to limit: 4.84 sRGB code values through
    /// `referenceColor` (the sampled table, which is what a render uses) and 5.45
    /// through `exactColor` (the f32 reference the table's error is measured against).
    /// The full pair reads 56.46 and 58.64.
    func testTheFoldIsGoneThroughTheShippingRenderPath() {
        var recipe = Recipe()
        recipe.look.wheels.mid.lum = 0.3
        recipe.look.wheels.high.lum = -0.3
        recipe.look.wheels.colorBalance.brilliance = ColorBalanceAxis(mid: 15, high: -15)
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
        for (name, sampler) in [("referenceColor", { plan.referenceColor($0) }),
                                ("exactColor", { plan.exactColor($0) })]
            as [(String, (RGB) -> RGB)] {
            let reversal = worstReversal(step: 0.01) { t in
                let out: RGB = sampler(RGB(gray: LumenLog.midGrey * pow(2.0, t)))
                let w: RGB = GradeEngine.workingLuminanceWeights
                return w.r * out.r + w.g * out.g + w.b * out.b
            }
            XCTAssertLessThan(
                reversal.code, Self.noise,
                "wheels ±0.3 with Brilliance ±15 still hands back \(reversal.code) sRGB "
                    + "code values through \(name), between \(reversal.peakEV) EV and "
                    + "\(reversal.troughEV) EV — the fold is on the path a photograph "
                    + "actually takes")
        }
    }

    // MARK: - Pixels

    /// WHICH COMMITTED PROOF RECORDS CAN MOVE BEHIND THIS FIX: none, and this is the
    /// check rather than the claim.
    ///
    /// Every `ControlSpec` builds its recipe from a fresh `Recipe()` and mutates one
    /// control family — `ProofRunner.render` is `var recipe = Recipe(); spec.apply(...)`
    /// — so a record can only move if a single spec sets a wheel's zone Luminance AND a
    /// Brilliance zone. This walks all 21 sweep settings of every registered control,
    /// plus its neutral, and reads the two predicates the joint solve actually tests off
    /// the recipe the harness would render.
    ///
    /// The two sets it collects are the answer in full: the wheel side is reached only
    /// by `grade.{shadows,mid,high}.lum` and the grid side only by
    /// `cb.brilliance.{shadows,mid,high}`, and no spec appears in both. Nothing else in
    /// the registry comes close: `grade.global.lum` moves the GLOBAL wheel, which rides
    /// on top of the partition and is outside every one of these solves;
    /// `cb.brilliance.global` is the same statement one disclosure down; the four zone
    /// geometry specs set two opposed TINTS with `lum: 0` explicitly; and no spec in the
    /// registry touches a mask, where `ReferenceRenderer`'s local grade would build a
    /// second engine.
    func testNoRegisteredProofControlCanMove() {
        var wheelSide = Set<String>()
        var gridSide = Set<String>()
        for spec in ProofRegistry.all {
            var settings: [Double] = [spec.neutral]
            for step in 0...20 {
                settings.append(spec.low + (spec.high - spec.low) * Double(step) / 20)
            }
            for setting in settings {
                var recipe = Recipe()
                spec.apply(&recipe, setting)
                let wheels: GradingWheels = recipe.look.wheels
                let zoneLuminance: Bool = wheels.shadows.lum != 0 || wheels.mid.lum != 0
                    || wheels.high.lum != 0
                let axis: ColorBalanceAxis = wheels.colorBalance.brilliance
                let zoneBrilliance: Bool = axis.shadows != 0 || axis.mid != 0
                    || axis.high != 0
                if zoneLuminance { wheelSide.insert(spec.id) }
                if zoneBrilliance { gridSide.insert(spec.id) }
                XCTAssertFalse(
                    zoneLuminance && zoneBrilliance,
                    "\(spec.id) at \(setting) sets BOTH a wheel's zone Luminance and a "
                        + "Brilliance zone, so its committed record renders through the "
                        + "joint correction and can move. Re-record it deliberately "
                        + "rather than letting the sweep discover it.")
                let graded = GradeEngine(wheels: wheels,
                                         printerLights: recipe.look.printerLights)
                XCTAssertEqual(
                    graded.jointScale, 1.0, accuracy: 0,
                    "\(spec.id) at \(setting) renders through a joint correction of "
                        + "\(graded.jointScale) — its committed proof record moves")
            }
        }
        XCTAssertEqual(wheelSide, ["grade.shadows.lum", "grade.mid.lum",
                                   "grade.high.lum"],
                       "the set of registered controls that reach the wheels' zone "
                           + "Luminance changed")
        XCTAssertEqual(gridSide, ["cb.brilliance.shadows", "cb.brilliance.mid",
                                  "cb.brilliance.high"],
                       "the set of registered controls that reach the grid's Brilliance "
                           + "zones changed")
        XCTAssertTrue(wheelSide.isDisjoint(with: gridSide),
                      "a registered control reaches both sides of the joint correction")
    }

    // MARK: - What the correction must NOT do

    /// Gentle settings of BOTH controls together stay exactly unlimited. The joint
    /// factor exists for the pair that composes past the bound, not for the pair that
    /// happens to be non-zero — a correction that engaged the moment a second control
    /// was touched would be its own bug, and the eased knee is what keeps it from
    /// stepping to 0.918 at first contact.
    func testGentleCombinedSettingsAreExactlyUnlimited() {
        for (lum, brilliance) in [(0.1, 5.0), (0.05, 2.0), (0.2, 4.0), (0.1, 10.0),
                                  (0.15, 3.0)] {
            let graded = engine(opposed(wheelLum: lum, brilliance: brilliance))
            XCTAssertEqual(graded.jointScale, 1.0, accuracy: 0,
                           "wheels ±\(lum) with Brilliance ±\(brilliance) is nowhere "
                               + "near the composed monotonicity limit and must not be "
                               + "scaled at all — it was scaled by \(graded.jointScale)")
        }
    }

    /// Both controls keep doing MORE across their travel under the joint correction —
    /// the aliveness property the two sibling limiters each pin for themselves, which a
    /// hard joint cap would destroy for both at once: `deflection × cap` is constant
    /// once a hard cap binds, so the pair would apply one identical grade over most of
    /// its travel.
    ///
    /// SWEPT ONE AT A TIME, WITH THE OTHER PARKED, which is how the panel is used — a
    /// photographer drags one ring and then the other, and what must never happen is
    /// that dragging one further applies less of it. Every step of every sweep here is
    /// strictly larger than the one before it, at four settings of the parked control
    /// including its full deflection.
    func testBothControlsStayAliveUnderTheJointCorrection() {
        for parkedBrilliance in [0.0, 20.0, 50.0, 100.0] {
            var previous: Double = -.infinity
            for step in 1...40 {
                let lum: Double = Double(step) / 40
                let graded = engine(opposed(wheelLum: lum, brilliance: parkedBrilliance))
                let stops: Double = GradeEngine.lumRangeStops * lum * graded.lumScale
                    * graded.jointScale
                XCTAssertGreaterThan(
                    stops, previous,
                    "the Luminance ring at \(lum), with Brilliance parked at "
                        + "±\(parkedBrilliance), applied no more than the step before "
                        + "it — the joint correction has become a cap")
                previous = stops
            }
        }
        for parkedLum in [0.0, 0.3, 0.5, 1.0] {
            var previous: Double = -.infinity
            for step in 1...40 {
                let brilliance: Double = Double(step) / 40 * 100
                let graded = engine(opposed(wheelLum: parkedLum, brilliance: brilliance))
                let applied: Double = brilliance
                    * graded.colorBalance.appliedBrillianceScale
                XCTAssertGreaterThan(
                    applied, previous,
                    "the Brilliance row at \(brilliance), with the Luminance rings "
                        + "parked at ±\(parkedLum), applied no more than the step "
                        + "before it — the joint correction has become a cap")
                previous = applied
            }
        }
    }

    /// And what the PAIR renders keeps growing too, pushed together — the separation
    /// the two controls exist to create, read off the rendered ramp rather than off a
    /// scale: `log2` of the mid zone's gain over the highlight zone's, at −0.5 EV and
    /// +1.5 EV.
    ///
    /// It has to ASYMPTOTE — the composed bound is what stops the picture folding, so
    /// the separation approaches about 1.55 stops and cannot pass it — and the property
    /// that matters is that it never turns around on the way. THE COST, measured: with
    /// both controls large, pushing Brilliance further takes a little of the budget
    /// back from the wheels, so the midtone's own level drifts DOWN by at most 0.14
    /// sRGB code values over the whole remaining travel (0.07 at wheels ±0.5). That
    /// drift is the price of a shared budget under any split — once the pair is at the
    /// bound, more of one tool is less of the other — and at a seventh of one code
    /// value it is below what an 8-bit display can show.
    func testThePairKeepsSeparatingTheZonesAsBothArePushed() {
        var previous: Double = -.infinity
        for step in 1...40 {
            let lum: Double = Double(step) / 40
            let graded = engine(opposed(wheelLum: lum, brilliance: lum * 100))
            let low: Double = realisedLuminance(graded, at: -0.5)
                / (LumenLog.midGrey * pow(2.0, -0.5))
            let high: Double = realisedLuminance(graded, at: 1.5)
                / (LumenLog.midGrey * pow(2.0, 1.5))
            let separation: Double = log2(low / high)
            XCTAssertGreaterThan(
                separation, previous,
                "wheels ±\(lum) with Brilliance ±\(lum * 100) separated the mid and "
                    + "highlight zones by \(separation) stops, no more than the step "
                    + "before it (\(previous)) — the pair has stopped responding")
            previous = separation
        }
        XCTAssertEqual(previous, 1.5515, accuracy: 0.001,
                       "the composed separation the full pair reaches has moved. It is "
                           + "the monotonicity bound itself — about 1.55 stops across "
                           + "the crossfade — and a change to it is a change to what "
                           + "the pair is allowed to do.")
    }

    /// THE DESIGN CALL, pinned as behaviour: the budget is split IN PROPORTION TO WHAT
    /// EACH SIDE ASKS FOR, so both keep the same fraction of the move they requested
    /// and the balance a colorist struck between the two tools survives the correction.
    ///
    /// One shared factor is what "proportional" means once written down — each side's
    /// contribution shrinks by the same factor, so each gives up an amount proportional
    /// to its own demand. This test is what would fail if a future retune quietly
    /// adopted "the second solve pays": there, the wheels would keep everything and the
    /// grid would absorb the whole deficit.
    func testTheBudgetIsSplitProportionallyAndNotDumpedOnOneSide() {
        let graded = engine(opposed(wheelLum: 1, brilliance: 100))
        XCTAssertLessThan(graded.jointScale, 1.0,
                          "the premise of this test is that this setting is limited")
        // Both sides pay, and pay the same fraction.
        let wheelShare: Double = graded.jointScale
        let gridShare: Double = graded.colorBalance.appliedBrillianceScale
            / graded.colorBalance.brillianceScale
        XCTAssertEqual(wheelShare, gridShare, accuracy: 1e-12,
                       "the two sides gave up different fractions of the move they "
                           + "asked for — the split is proportional to demand, which "
                           + "is one shared factor")
        XCTAssertGreaterThan(wheelShare, 0.4,
                             "neither side may be annihilated to protect the other: "
                                 + "each alone is already inside its own limiter, so "
                                 + "the joint budget is a division, not a veto")

        // THE LOPSIDED PAIR is where the splits separate. A full wheel opposition at
        // the shipped Blending has already spent the budget on its own — its own solve
        // binds hard, at 0.600 — so under "whichever solve runs second pays" the grid's
        // allowance beside it would be what is left of a budget with nothing left in
        // it, and a Brilliance of ±5 would be scaled to about nothing. Proportional to
        // demand, the small control gives up the same FRACTION as the large one and
        // therefore a small absolute amount: it keeps three quarters of a move that was
        // small to begin with.
        let lopsided = engine(opposed(wheelLum: 1, brilliance: 5))
        XCTAssertEqual(lopsided.lumScale, 0.600212485, accuracy: 1e-9,
                       "the premise of this case is that the wheels alone are already "
                           + "at their own limit")
        XCTAssertGreaterThan(lopsided.colorBalance.appliedBrillianceScale, 0.7,
                             "a Brilliance of ±5 beside a full wheel opposition was "
                                 + "scaled to "
                                 + "\(lopsided.colorBalance.appliedBrillianceScale) — "
                                 + "the small control paying the large one's bill "
                                 + "rather than its own share of it")
        XCTAssertEqual(lopsided.jointScale,
                       lopsided.colorBalance.appliedBrillianceScale
                           / lopsided.colorBalance.brillianceScale,
                       accuracy: 1e-12,
                       "and it gives up exactly the fraction the wheels beside it do")
    }
}

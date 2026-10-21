// HalationControlTests.swift
// Two controls that were built, plumbed, computed from — and unreachable (C2-05).
//
// `HalationProfile.init` has taken `size` and `redness` since it was written and uses
// both for real: `sigma1 = 65µm/1000 × size / gate × px` sets the halo's radius, and
// `strength = base.mix(RGB(base.r, 0, 0), redness) × amount` decides how far it is
// pulled toward pure red. It had exactly two callers and both passed the defaults, so
// every stock's halo was the same 65 µm radius scaled only by its gate and no halo
// could be warmed or neutralised. `FilmLab` in the recipe had no key for either, and
// `LookPanel` had one Halation row.
//
// These assertions could not be WRITTEN against the recipe type as it stood — there
// was nothing to set — which is the shape of defect a test suite cannot catch by
// getting more thorough. It is caught by asking, of every parameter a profile computes
// from, "what writes this?"

import XCTest
@testable import LumenCore

final class HalationControlTests: XCTestCase {

    private func chain(_ mutate: (inout FilmLab) -> Void = { _ in }) -> FilmChain {
        var lab = FilmChain.defaultRecipe(for: .portra400)
        lab.halation = 60
        mutate(&lab)
        return FilmChain(lab, displayWhite: 1.0)
    }

    // MARK: - Size reaches the radius

    /// SIZE IS A RADIUS AND IT SCALES LINEARLY. 2.0 is four times 0.5, and the profile's
    /// three bounce sigmas must all move together — they are one geometric series off
    /// `sigma1`, so a Size that reached only the first would be a different halo shape
    /// at every setting rather than the same halo, larger.
    func testHaloSizeScalesEveryBounceRadiusLinearly() {
        let small = chain { $0.halationSize = 0.5 }.halation(longEdgePixels: 4000)
        let large = chain { $0.halationSize = 2.0 }.halation(longEdgePixels: 4000)

        XCTAssertEqual(small.sigmasInPixels.count, HalationProfile.bounceCount)
        XCTAssertEqual(large.sigmasInPixels.count, HalationProfile.bounceCount)
        for (i, (s, l)) in zip(small.sigmasInPixels, large.sigmasInPixels).enumerated() {
            XCTAssertGreaterThan(s, 0, "bounce \(i) has no radius to scale")
            XCTAssertEqual(l / s, 4.0, accuracy: 4.0 * 0.05,
                           "bounce \(i): Size 2.0 gives \(l) px against Size 0.5's \(s) "
                               + "— the ratio must be 4, and was 1 for the whole life "
                               + "of this control because nothing could set it")
        }
    }

    /// And the DEFAULT is what shipped, to the bit. This is the assertion that says the
    /// control was added without changing a single existing photograph.
    func testTheDefaultHaloIsExactlyWhatShippedBeforeTheControlExisted() {
        let shipped = chain().halation(longEdgePixels: 4000)
        XCTAssertEqual(shipped.sizeMultiplier, 1.0)
        XCTAssertNil(FilmLab(stock: "lumen/portra400").halationSize,
                     "nil, not 1.0 — a present film lab serializes every non-optional "
                         + "key it has, so a defaulted Double would write itself into "
                         + "every recipe that ever loaded a stock")
        XCTAssertEqual(FilmLab(stock: "lumen/portra400").effectiveHalationSize, 1.0)
        XCTAssertNil(FilmLab(stock: "lumen/portra400").halationRedness,
                     "nil means the stock's own measured redness, which is a real "
                         + "answer and not a value — writing a number into every "
                         + "recipe would pin it against a future re-measurement")
        // 65 µm at the gate, in pixels of this render, is the number the profile's own
        // constant names — so the default is traceable rather than merely unchanged.
        let gate = Swift.max(FilmStock.portra400.gateLongEdgeMM, 1e-3)
        let expected = (HalationProfile.firstSigmaMicrons / 1000.0) / gate * 4000.0
        XCTAssertEqual(shipped.sigmasInPixels[0], expected, accuracy: 1e-9)
    }

    // MARK: - Redness reaches the colour

    /// REDNESS 100 IS A PURE RED HALO: green and blue strength go to zero.
    ///
    /// `strength = base.mix(RGB(base.r, 0, 0), red) × amount`, so at red = 1 the mix is
    /// the pure-red vector outright. A photographer asking for CineStill's bloom is
    /// asking for exactly this, and could not.
    func testHaloRednessAtFullDrivesGreenAndBlueToZero() {
        let full = chain { $0.halationRedness = 100 }.halation(longEdgePixels: 4000)
        XCTAssertEqual(full.strengths.g, 0, accuracy: 1e-12)
        XCTAssertEqual(full.strengths.b, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(full.strengths.r, 0,
                             "a pure-red halo with no red in it is not a halo")
    }

    /// REDNESS TAKES GREEN AND BLUE OUT; IT NEVER ADDS RED. Worth stating as its own
    /// assertion because the name says the opposite and the first draft of this test
    /// asserted the opposite: `pureRed` is `RGB(base.r, 0, 0)`, so the red component is
    /// the SAME on both sides of the mix and cannot move. Turning Redness up does not
    /// make the halo redder by adding red — it makes it redder by removing everything
    /// else, which is what an anti-halation layer failing on one record actually does.
    ///
    /// Zero is therefore the emulsion's full colour, unpulled, and the stock's own
    /// value is the middle of the control.
    func testHaloRednessRemovesTheOtherRecordsAndLeavesRedAlone() {
        let neutral = chain { $0.halationRedness = 0 }.halation(longEdgePixels: 4000)
        let stockOwn = chain().halation(longEdgePixels: 4000)
        let full = chain { $0.halationRedness = 100 }.halation(longEdgePixels: 4000)

        XCTAssertGreaterThan(FilmStock.portra400.halationRedness, 0,
                             "this stock needs a non-zero redness for the ordering "
                                 + "below to mean anything")
        XCTAssertGreaterThan(neutral.strengths.g, 0,
                             "redness 0 must leave the emulsion's own green leak alone, "
                                 + "not neutralise the halo")
        // Strictly decreasing in green as redness rises, which is the whole control.
        XCTAssertGreaterThan(neutral.strengths.g, stockOwn.strengths.g,
                             "pulling redness BELOW the stock's own must leave more "
                                 + "green than the stock does — the recipe's value is "
                                 + "not reaching the profile")
        XCTAssertGreaterThan(stockOwn.strengths.g, full.strengths.g)
        // And red is invariant across the whole travel.
        XCTAssertEqual(neutral.strengths.r, full.strengths.r, accuracy: 1e-12,
                       "Redness has started changing the red record — it mixes toward "
                           + "RGB(base.r, 0, 0), whose red IS base.r, so this is a "
                           + "different control from the one the profile computes")
    }

    // MARK: - The wire format

    /// A RECIPE WRITTEN BEFORE THESE KEYS EXISTED DECODES TO THE SHIPPED BEHAVIOUR, and
    /// one that never touches them writes no new bytes.
    ///
    /// The second half is `CanonicalJSON.sparse`'s job and the reason `halationSize`
    /// could be a plain `Double` rather than another optional: a key sitting at its
    /// default is pruned, so no existing sidecar changes and no catalog fingerprint
    /// moves. `ExportRecipe`'s tolerant decoder (K-016) is the pattern the decode half
    /// follows.
    func testTheNewKeysAreAbsentTolerantAndSparse() throws {
        let old = #"{"stock":"lumen/portra400","amount":100,"halation":40}"#
        let decoded = try JSONDecoder().decode(FilmLab.self,
                                               from: Data(old.utf8))
        XCTAssertNil(decoded.halationSize)
        XCTAssertEqual(decoded.effectiveHalationSize, 1.0,
                       "an old recipe must render the halo it always rendered")
        XCTAssertNil(decoded.halationRedness)
        XCTAssertEqual(decoded.halation, 40)

        var recipe = Recipe()
        recipe.look.filmLab = FilmChain.defaultRecipe(for: .portra400)
        let untouched = try CanonicalJSON.canonicalRecipeJSON(recipe)
        XCTAssertFalse(untouched.contains("halationSize"),
                       "an untouched recipe is writing a key it never set — every "
                           + "existing sidecar's bytes just moved:\n\(untouched)")
        XCTAssertFalse(untouched.contains("halationRedness"))

        recipe.look.filmLab?.halationSize = 1.6
        let moved = try CanonicalJSON.canonicalRecipeJSON(recipe)
        XCTAssertTrue(moved.contains("halationSize"),
                      "a moved Halo Size is not being written, so it will not survive "
                          + "a reload:\n\(moved)")
    }

    /// And it round-trips, both halves, including the optional's nil.
    func testTheNewKeysRoundTrip() throws {
        for redness in [nil, 0, 55, 100] as [Double?] {
            var lab = FilmChain.defaultRecipe(for: .portra400)
            lab.halationSize = 1.35
            lab.halationRedness = redness
            let data = try JSONEncoder().encode(lab)
            let back = try JSONDecoder().decode(FilmLab.self, from: data)
            XCTAssertEqual(back.halationSize, 1.35)
            XCTAssertEqual(back.effectiveHalationSize, 1.35)
            XCTAssertEqual(back.halationRedness, redness)
        }
    }

    // MARK: - The accessor both renderers use

    /// THE FIX HAD TO LAND IN `halation(longEdgePixels:)`, not in `halationProfile`.
    ///
    /// `ReferenceRenderer.applyHalation` and `RenderGraph.applyHalation` each call the
    /// former — its own comment says so, "the same accessor the graph uses, so the two
    /// stages cannot be handed different profiles for the same recipe" — and it is the
    /// one that hardcoded `size: 1.0, redness: nil`. Fixing only the unused
    /// `halationProfile` would have left both renderers exactly where they were, with a
    /// panel row that moved a number nothing read.
    func testTheRecipesValuesReachTheAccessorBothRenderersCall() {
        let moved = chain {
            $0.halationSize = 1.8
            $0.halationRedness = 90
        }.halation(longEdgePixels: 4000)
        XCTAssertEqual(moved.sizeMultiplier, 1.8, accuracy: 1e-12,
                       "the recipe's Halo Size is not reaching the profile the "
                           + "renderers build")
        XCTAssertEqual(moved.redness, 0.9, accuracy: 1e-12,
                       "the recipe's Halo Redness is not reaching the profile the "
                           + "renderers build")
    }

    // MARK: - The panel's capability predicate agrees with the engine

    /// THE PANEL DISABLES ALL THREE ROWS ON ONE PREDICATE, `halationStrength != .zero`
    /// (LookPanel `halationSupported`, Astra M14 / September C1-08). That is only honest
    /// if, for every stock this build ships, the predicate is true exactly when some
    /// Amount, Size and Redness reach pixels, and false exactly when none can. The
    /// LumenApp test checks the predicate's text and two stocks; this sweeps the roster
    /// through the accessor both renderers call, at every Redness end, so a stock whose
    /// halo dies at Redness 100 (a zero red record) cannot sit behind an enabled row.
    func testEveryStocksHalationRowsAreLiveExactlyWhenTheEngineCanGlow() {
        for stock in FilmStock.all {
            let supported = stock.halationStrength != .zero
            for redness in [0.0, 50, 100] {
                for size in [0.5, 1.0, 2.0] {
                    var lab = FilmChain.defaultRecipe(for: stock)
                    lab.halation = 100
                    lab.halationSize = size
                    lab.halationRedness = redness
                    let chain = FilmChain(lab, displayWhite: 1.0)
                    let profile = chain.halation(longEdgePixels: 3000)
                    let reaches = chain.halationAmount > 0
                        && profile.strengths.maxComponent > 0
                    XCTAssertEqual(reaches, supported,
                                   "\(stock.id) redness \(redness) size \(size): the panel "
                                       + "says \(supported ? "enabled" : "disabled") but "
                                       + "the engine \(reaches ? "glows" : "cannot glow")")
                }
            }
        }
        // Not vacuous: the roster carries both kinds.
        XCTAssertTrue(FilmStock.all.contains { $0.halationStrength == .zero })
        XCTAssertTrue(FilmStock.all.contains { $0.halationStrength != .zero })
    }

    // MARK: - Where it glows (WS-39)

    private func film(_ stock: FilmStock = .portra400, amount: Double = 100,
                      size: Double? = nil, redness: Double? = nil) -> FilmChain {
        var lab = FilmChain.defaultRecipe(for: stock)
        lab.halation = amount
        lab.halationSize = size
        lab.halationRedness = redness
        return FilmChain(lab, displayWhite: 1.0)
    }

    /// A small clipped-or-brighter disk on a dark field.
    private func disk(side: Int, radius: Double, level: Double,
                      field: Double = 0.0) -> ImageBuffer {
        let c = Double(side) / 2 - 0.5
        return ImageBuffer(width: side, height: side) { u, v in
            let x = u * Double(side) - 0.5 - c, y = v * Double(side) - 0.5 - c
            return RGB(gray: (x * x + y * y).squareRoot() <= radius ? level : field)
        }
    }

    /// SPEC M2. A FLAT FIELD COMES OUT UNTOUCHED at every level, clipped or not. The
    /// stock's curve is measured on flat fields, so the base's reflection onto the spot
    /// it came from is already inside it; the stage adds only the light spread AWAY.
    /// The stage used to add `strength · F`, which on a flat field is `strength · H`:
    /// +4…+7 sRGB codes of red on every bright wall, lawn and sky at Amount 100.
    func testAFlatFieldGetsNoHalationAtAnyLevel() {
        let chain = film(size: 2.0, redness: 0)
        for level in [0.05, 0.18, 0.5, 0.9, 1.0, 4.0, 16.0] {
            let source = ImageBuffer(width: 64, height: 64) { _, _ in RGB(gray: level) }
            let out = ReferenceRenderer.applyHalation(source, film: chain, longEdge: 2215)
            var worst = 0.0
            for y in 0..<64 { for x in 0..<64 {
                worst = Swift.max(worst, out[x, y].maxAbsDifference(source[x, y]))
            } }
            XCTAssertLessThanOrEqual(worst, level * 1e-5,
                                     "a flat field at \(level) moved by \(worst) — the stage "
                                         + "is adding a cast, not a halo")
        }
    }

    /// SPEC M3. NOTHING TWO STOPS UNDER THE CLIP FEEDS THE GLOW. Mid grey sat at a third
    /// of full weight under the old four-stop gate.
    func testNothingTwoStopsUnderTheClipFeedsTheGlow() {
        let profile = film().halation(longEdgePixels: 2400)
        for level in [0.01, 0.18, 0.25] {
            XCTAssertEqual(profile.highlightEnergy(RGB(gray: level)), RGB.zero,
                           "\(level) contributes energy")
        }
        XCTAssertGreaterThan(profile.highlightEnergy(RGB(gray: 0.5)).r, 0)
        // A disk at the gate's edge on a dark field changes nothing anywhere.
        let source = disk(side: 96, radius: 8, level: 0.25, field: 0.01)
        let out = ReferenceRenderer.applyHalation(source, film: film(size: 2), longEdge: 2215)
        for y in 0..<96 { for x in 0..<96 {
            XCTAssertEqual(out[x, y], source[x, y])
        } }
    }

    /// SPEC M4. A CLIPPED SAMPLE CARRIES FAR MORE ENERGY THAN A DIFFUSE WHITE. The
    /// recording stops at the clip; the light onto the film did not. A lamp used to throw
    /// no more glow than a white wall (0.3-stop headroom).
    func testAClippedSampleOutGlowsADiffuseWhite() {
        let profile = film().halation(longEdgePixels: 2400)
        let clipped = profile.highlightEnergy(RGB(gray: 1.0)).r
        let white = profile.highlightEnergy(RGB(gray: 0.8)).r
        XCTAssertEqual(clipped, pow(2.0, HalationProfile.boostRange), accuracy: 1e-9)
        XCTAssertGreaterThan(clipped / white, 3.0)
        // Monotone in exposure and continuous across the clip band.
        var previous = 0.0
        var level = 0.2
        while level < 40 {
            let e = profile.highlightEnergy(RGB(gray: level)).r
            XCTAssertGreaterThanOrEqual(e, previous - 1e-12, "energy fell at \(level)")
            XCTAssertLessThan(e - previous, 0.5, "energy jumps at \(level)")
            previous = e
            level *= 1.005
        }
        // Real HDR above the reconstruction floor stays linear.
        XCTAssertEqual(profile.highlightEnergy(RGB(gray: 16)).r, 16, accuracy: 1e-9)
    }

    /// The added light outside a clipped disk, per ring, in working space.
    private func rings(_ chain: FilmChain, longEdge: Int = 2400, side: Int = 256,
                       radius: Double = 10) -> [RGB] {
        let source = disk(side: side, radius: radius, level: 1.0)
        let out = ReferenceRenderer.applyHalation(source, film: chain, longEdge: longEdge)
        let c = Double(side) / 2 - 0.5
        var sum = [RGB](repeating: .zero, count: side / 2)
        var n = [Double](repeating: 0, count: side / 2)
        for y in 0..<side { for x in 0..<side {
            let d = (pow(Double(x) - c, 2) + pow(Double(y) - c, 2)).squareRoot() - radius
            guard d > 0, Int(d) < side / 2 else { continue }
            sum[Int(d)] = sum[Int(d)] + (out[x, y] - source[x, y])
            n[Int(d)] += 1
        } }
        return zip(sum, n).map { $0.1 > 0 ? $0.0 * (1 / $0.1) : .zero }
    }

    /// SPEC M5. RED-ORANGE AT THE SOURCE, REDDER FURTHER OUT, and never green or blue
    /// dominant. Green and blue spread on the narrower `narrowSigmas`, so G/R falls with
    /// distance. Every bounce used to carry one colour.
    func testTheHaloIsOrangeNearTheSourceAndRedderFurtherOut() {
        let r = rings(film(amount: 100))
        let toLayers = HalationProfile.workingToLayers
        let near = toLayers.apply(r[1]), far = toLayers.apply(r[40])
        XCTAssertGreaterThan(near.r, 0)
        XCTAssertGreaterThan(far.r, 0, "no tail 40 px out")
        XCTAssertGreaterThan(near.g / near.r, 0.15, "the core of the halo is not orange")
        XCTAssertLessThan(far.g / far.r, 0.6 * (near.g / near.r),
                          "the halo is not redder further out")
        for (i, ring) in r.prefix(60).enumerated() {
            XCTAssertGreaterThanOrEqual(ring.r, ring.g - 1e-7, "green over red at ring \(i)")
            XCTAssertGreaterThanOrEqual(ring.g, ring.b - 1e-7, "blue over green at ring \(i)")
        }
        // A neutral stock keeps one radius and no colour fringe.
        let mono = rings(film(.triX400, amount: 100))
        XCTAssertEqual(mono[20].r, mono[20].g, accuracy: 1e-6)
        XCTAssertEqual(mono[20].g, mono[20].b, accuracy: 1e-6)
    }

    /// SPEC M6. THE HALO IS THE SAME FRACTION OF THE PICTURE AT EVERY SIZE: the ring
    /// where the glow falls under a fixed fraction of its peak sits at the same
    /// fraction of the long edge at 1200 and 3600 px.
    func testTheHaloScalesWithTheRender() {
        func reach(_ longEdge: Int, side: Int, radius: Double) -> Double {
            let r = rings(film(amount: 100), longEdge: longEdge, side: side, radius: radius)
            let peak = r[0].r
            let i = r.firstIndex { $0.r < 0.1 * peak } ?? r.count
            return Double(i) / Double(longEdge)
        }
        let small = reach(1200, side: 160, radius: 6)
        let large = reach(3600, side: 480, radius: 18)
        XCTAssertEqual(small, large, accuracy: 0.15 * large)
    }

    /// SPEC M9. AMOUNT IS A LINEAR GAIN with zero an exact identity.
    func testAmountIsALinearGain() {
        let full = rings(film(amount: 100)), half = rings(film(amount: 50))
        XCTAssertEqual(half[5].r, 0.5 * full[5].r, accuracy: 1e-5 * full[5].r + 1e-7)
        let source = disk(side: 64, radius: 6, level: 1.0)
        XCTAssertEqual(ReferenceRenderer.applyHalation(source, film: film(amount: 0, size: 2,
                                                                         redness: 100),
                                                       longEdge: 2400).pixels,
                       source.pixels)
    }

    /// The renderer accumulates the NORMALIZED bounces (N-006): far from the frame's
    /// border the blurred field keeps the energy's mass, so the halo's total is
    /// `strength · Σ(F − H)⁺` with no hidden 1.75.
    func testTheRendererAppliesBounceWeightsThatSumToOne() {
        let profile = film().halation(longEdgePixels: 2215)
        var sum = 0.0
        for w in profile.normalizedWeights { sum += w }
        XCTAssertEqual(profile.normalizedWeights.count, HalationProfile.bounceCount)
        XCTAssertEqual(sum, 1.0, accuracy: 1e-15)
    }
}

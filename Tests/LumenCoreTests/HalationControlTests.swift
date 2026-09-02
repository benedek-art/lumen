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
}

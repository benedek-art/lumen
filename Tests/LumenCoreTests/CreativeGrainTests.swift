// CreativeGrainTests.swift
// Grain as a first-class creative effect: `look.grain`, on any photograph, with no film
// stock loaded.
//
// The defect this closes, in the owner's words: *"the vignette is all we have with the
// feather as well as a grain that we can only use when we load a film stock. So there's
// no ability to make creative kinds of grain on the image, which is kind of sad."* He is
// describing a wiring accident, not a design: `FilmGrainProfile` is a complete
// density-domain grain model and the only way to build one was `init(stock:…)`, so every
// grain reader on both render paths was gated on `plan.filmChain` and the Effects panel's
// stockless state was a button labelled "Load a film stock".
//
// So this file has two jobs. The first is the ordinary one — the new fields decode, they
// travel, they reach pixels, and each of the three does what its tooltip says. The second
// is the one that matters more, and it is the reason for
// `testTheFilmPathIsByteIdenticalThroughTheNewPlan`: nothing here may be a SECOND grain.
// Every number lands on the same profile, the same grain field and the same amplitude
// law the emulsions use, and a film recipe must render bit-for-bit what it always did
// even though the stage now reaches it through `GrainPlan` instead of through
// `FilmChain`. Two deterministic grains is the same problem as none — this file's
// neighbour `FilmGrainProfile.defaultPlateSeed` has the paragraph.

import XCTest
@testable import LumenCore

final class CreativeGrainTests: XCTestCase {

    private func flat(_ size: Int = 96, level: Double = 0.18) -> ImageBuffer {
        ImageBuffer(width: size, height: size) { _, _ in RGB(gray: level) }
    }

    private func render(_ recipe: Recipe, _ frame: ImageBuffer) -> ImageBuffer {
        ReferenceRenderer.render(frame, plan: RenderPlan(recipe: recipe))
    }

    /// The grain a render added, per channel, as raw deltas.
    private func grainDeltas(_ recipe: Recipe, _ frame: ImageBuffer) -> [[Double]] {
        let plain = render(Recipe(), frame)
        let out = render(recipe, frame)
        var deltas: [[Double]] = [[], [], []]
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                for c in 0..<3 { deltas[c].append(Double(out[x, y][c] - plain[x, y][c])) }
            }
        }
        return deltas
    }

    private static func sigma(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
            / Double(values.count)
        return variance.squareRoot()
    }

    private static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let ma = a.reduce(0, +) / Double(a.count)
        let mb = b.reduce(0, +) / Double(b.count)
        var cov = 0.0, va = 0.0, vb = 0.0
        for i in 0..<a.count {
            let da = a[i] - ma, db = b[i] - mb
            cov += da * db
            va += da * da
            vb += db * db
        }
        guard va > 0, vb > 0 else { return 0 }
        return cov / (va * vb).squareRoot()
    }

    // MARK: - The wire format

    /// A recipe written before the key existed decodes to an ABSENT slot, which is no
    /// grain, so every sidecar in every catalog renders exactly what it rendered
    /// yesterday — and a slot that IS present but sitting at its defaults renders the
    /// same picture, which is the property `CreativeGrain.normalized` exists to make
    /// unreachable from the app and `renderIdentity` exists to absorb from a sidecar.
    ///
    /// Written as a byte-identity comparison rather than as a field check, because the
    /// field check would pass on a default that rendered something.
    func testAnOldSidecarDecodesToNoGrainAndRendersIdentically() throws {
        let old = try CanonicalJSON.decodeRecipe(
            from: Data(#"{"look":{"vignette":-1},"pipelineVersion":2}"#.utf8))
        XCTAssertNil(old.look.grain,
                     "an absent key must decode to an absent slot, not to a block of "
                         + "defaults")

        var explicit = Recipe()
        explicit.look.vignette = -1
        explicit.look.grain = CreativeGrain()   // present, but at its defaults
        let frame = flat(48)
        let a = render(old, frame)
        let b = render(explicit, frame)
        for y in 0..<frame.height {
            for x in 0..<frame.width where a[x, y] != b[x, y] {
                return XCTFail("byte-identity broke at (\(x), \(y))")
            }
        }
    }

    /// A PARTIAL block — the shape a hand-edited sidecar takes — lands on the middles of
    /// the two axes it did not mention rather than on their zeros. Size 0 is the finest
    /// grain the model draws and Roughness 0 the smoothest plate; neither is what
    /// "unspecified" means, and both are a long way from the control's own neutral.
    func testAPartialBlockDecodesToTheMiddlesOfWhatItDidNotSay() throws {
        let recipe = try CanonicalJSON.decodeRecipe(
            from: Data(#"{"look":{"grain":{"amount":40}},"pipelineVersion":2}"#.utf8))
        XCTAssertEqual(recipe.look.grain?.amount, 40)
        XCTAssertEqual(recipe.look.grain?.size, 50)
        XCTAssertEqual(recipe.look.grain?.roughness, 50)
    }

    /// An untouched recipe does not mention the key, so no fingerprint in any existing
    /// catalog moves — and a recipe that DOES set it hashes differently, because it
    /// renders a different picture.
    func testTheFingerprintOfUntouchedRecipesDoesNotMove() throws {
        let untouched = try CanonicalJSON.canonicalRecipeJSON(Recipe())
        XCTAssertFalse(untouched.contains("grain"),
                       "a defaulted grain must be pruned by the sparse serializer")

        var grained = Recipe()
        grained.look.grain = CreativeGrain(amount: 35)
        let json = try CanonicalJSON.canonicalRecipeJSON(grained)
        XCTAssertTrue(json.contains("\"amount\":35"), "a set grain must serialize")
        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(grained),
                          try RecipeFingerprint.fingerprint(Recipe()),
                          "two recipes that render differently must not hash the same")

        let roundTripped = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertEqual(roundTripped.look.grain, grained.look.grain,
                       "the field must survive its own round trip")
    }

    /// A saved look carries it. Grain is an expression of intent about a set of frames,
    /// which is the D4 test for the `look` side, and a preset that dropped its grain
    /// would apply a different picture than it saved.
    func testASavedLookCarriesTheGrain() {
        var recipe = Recipe()
        recipe.look.grain = CreativeGrain(amount: 60, size: 20, roughness: 90)
        let applied = LookSubset.extracted(from: recipe).applied(to: Recipe())
        XCTAssertEqual(applied.look.grain, recipe.look.grain)
    }

    // MARK: - It reaches pixels, on a photograph with no stock

    /// THE HEADLINE. A photograph with no film stock, grain Amount above zero, and the
    /// picture changes. This is the test that fails on the code as it was.
    func testGrainRendersWithNoFilmStockLoaded() {
        var recipe = Recipe()
        recipe.look.grain = CreativeGrain(amount: 60)
        XCTAssertNil(recipe.look.filmLab, "the point is that there is no stock")

        let plan = RenderPlan(recipe: recipe)
        XCTAssertNil(plan.filmChain, "and therefore no film chain")
        XCTAssertNotNil(plan.grain, "but there must still be a grain stage")
        XCTAssertTrue(plan.grain?.isCreative == true)

        let frame = flat()
        let deltas = grainDeltas(recipe, frame)
        for c in 0..<3 {
            XCTAssertGreaterThan(Self.sigma(deltas[c]), 1e-4,
                                 "channel \(c) got no grain — the creative grain is not "
                                     + "reaching pixels")
        }
    }

    /// Amount 0 renders nothing at all, byte for byte, so the stage costs nothing on the
    /// overwhelming majority of photographs.
    func testAmountZeroIsByteIdentical() {
        var recipe = Recipe()
        recipe.look.grain = CreativeGrain(amount: 0, size: 90, roughness: 10)
        XCTAssertNil(RenderPlan(recipe: recipe).grain,
                     "a zero amount must not even build a plan, let alone a plate")
        let frame = flat(48)
        let a = render(Recipe(), frame)
        let b = render(recipe, frame)
        for y in 0..<frame.height {
            for x in 0..<frame.width where a[x, y] != b[x, y] {
                return XCTFail("Size and Roughness moved a pixel at Amount 0, at "
                               + "(\(x), \(y))")
            }
        }
    }

    /// Amount is monotone in the amplitude it lays down, and it is denominated the same
    /// way the film path's Amount is — 100 is `FilmGrainProfile.densityScale` density
    /// units at the envelope's peak, for both.
    func testAmountIsMonotoneAndSharesTheFilmDenomination() {
        let frame = flat(64)
        var previous = 0.0
        for amount in [10.0, 30.0, 60.0, 100.0] {
            var recipe = Recipe()
            recipe.look.grain = CreativeGrain(amount: amount)
            let sigma = Self.sigma(grainDeltas(recipe, frame)[1])
            XCTAssertGreaterThan(sigma, previous,
                                 "grain at Amount \(amount) is no stronger than at the "
                                     + "setting below it")
            previous = sigma
        }
        // The denomination, stated against the film path rather than against a number:
        // a creative grain at 45 and Portra's own default of 45 resolve to the same peak
        // amplitude, so the two Amount sliders mean the same thing.
        let creative = GrainPlan.creative(CreativeGrain(amount: 45), monochrome: false)
        let stock = FilmStock.portra400
        let film = GrainPlan.film(FilmChain(FilmChain.defaultRecipe(for: stock),
                                            displayWhite: 1.0))
        XCTAssertEqual(stock.grainDefault, 45, "this test is written around Portra's 45")
        XCTAssertEqual(creative.amount, film.amount, accuracy: 1e-12,
                       "the creative Amount and the film Amount must be one denomination")
    }

    // MARK: - Size

    /// Size is a pitch at the gate, so it scales the grain's radius and nothing else.
    /// The radius has no floor (WS-40: the pixel aperture averages a sub-pixel grain the
    /// way a downsample would), so every step of the slider is live at every size.
    func testSizeIsAPitchAndCoarsensTheFootprint() {
        var previous = 0.0
        for size in [0.0, 25.0, 50.0, 75.0, 100.0] {
            let plan = GrainPlan.creative(CreativeGrain(amount: 50, size: size),
                                          monochrome: false)
            let radius = plan.grainRadiusPixels(longEdgePixels: 6000, channel: 1)
            XCTAssertGreaterThan(radius, previous * 1.5,
                                 "Size \(size) is not coarser than the setting below it")
            previous = radius
            // And at a preview size too: no dead range at the bottom (SPEC 6, F5).
            if size > 0 { XCTAssertLessThan(GrainPlan.creative(CreativeGrain(amount: 50, size: size - 1),
                                                 monochrome: false)
                                .grainRadiusPixels(longEdgePixels: 1024, channel: 1),
                              plan.grainRadiusPixels(longEdgePixels: 1024, channel: 1)) }
        }
        // The mapping the tooltip quotes: 7.2 µm → 72 µm, ×10 geometric, so a grain
        // radius of 0.6 → 6 px on a 6000 px frame.
        XCTAssertEqual(FilmGrainProfile.creativePitchMicrons(size: 0), 7.2, accuracy: 1e-9)
        XCTAssertEqual(FilmGrainProfile.creativePitchMicrons(size: 100), 72, accuracy: 1e-9)
        XCTAssertEqual(FilmGrainProfile.creativePitchMicrons(size: 50), 7.2 * 10.0.squareRoot(),
                       accuracy: 1e-9)
        let zero = GrainPlan.creative(CreativeGrain(amount: 50, size: 0), monochrome: false)
        XCTAssertEqual(zero.grainRadiusPixels(longEdgePixels: 6000, channel: 0), 0.6,
                       accuracy: 1e-9)
    }

    /// The gate anchoring, which is the property that makes Size mean one thing: the
    /// grain is the same FRACTION of the picture at every render size, so a preview and
    /// an export show the same texture rather than the same pixel count of it.
    ///
    /// The film path's own guarantee, tested for the creative path because it arrives
    /// through a different constructor and a gate that is named rather than measured.
    func testGrainFollowsTheGateAndNotThePixelCount() {
        let plan = GrainPlan.creative(CreativeGrain(amount: 50, size: 60),
                                      monochrome: false)
        let small = plan.grainRadiusPixels(longEdgePixels: 2000, channel: 1)
        let large = plan.grainRadiusPixels(longEdgePixels: 6000, channel: 1)
        XCTAssertEqual(large / small, 3.0, accuracy: 1e-9,
                       "three times the pixels must be three times the footprint, or the "
                           + "same Size means two different textures")
        // And print size cancels out of it entirely, exactly as it does for a stock.
        let atTen = plan.profile.grainRadiusPixels(longEdgePixels: 4000, printSizeInches: 10,
                                                   channel: 1)
        let atThirty = plan.profile.grainRadiusPixels(longEdgePixels: 4000,
                                                      printSizeInches: 30, channel: 1)
        XCTAssertEqual(atTen, atThirty, accuracy: 1e-12)
    }

    // MARK: - Roughness

    /// Roughness is the grain's IRREGULARITY: dense even grains of one size at 0;
    /// sparse grains of mixed size plus a coarser clump layer at 100. The field is
    /// normalised per layer, so the amplitude stays put; `GrainSpecTests` measures the
    /// character (kurtosis, local-energy CV) and the strength on rendered fields.
    func testRoughnessMovesTheCharacterAndNotTheAmplitude() {
        var previousCount = Double.infinity
        var previousSpread = -1.0
        for roughness in [0.0, 25.0, 50.0, 75.0, 100.0] {
            let field = GrainPlan.creative(CreativeGrain(amount: 100, size: 50,
                                                         roughness: roughness),
                                           monochrome: false).field(longEdge: 6000)
            let layers = field.channels[0]
            XCTAssertEqual(layers.count, roughness == 0 ? 1 : 2,
                           "Roughness 0 has no clump layer and any other value has one")
            XCTAssertLessThan(layers[0].count, previousCount)
            XCTAssertGreaterThan(layers[0].spread, previousSpread)
            previousCount = layers[0].count
            previousSpread = layers[0].spread
            let v = field.evaluate(width: 256, height: 256)[0].map(Double.init)
            XCTAssertEqual(Self.sigma(v), 0.93, accuracy: 0.12,
                           "roughness \(roughness) changed the field's amplitude")
        }
    }

    /// A stock is grained at the middle of the creative Roughness, so a stock's grain
    /// and the creative grain at Roughness 50 have one character.
    func testAStockIsGrainedAtRoughnessFifty() {
        XCTAssertEqual(FilmGrainProfile.creativeRoughness(50), FilmGrainProfile.stockRoughness)
        for stock in FilmStock.all {
            XCTAssertEqual(FilmGrainProfile(stock: stock, size: 1, amount: 50, pushPull: 0)
                            .roughness, FilmGrainProfile.stockRoughness)
        }
    }

    // MARK: - Colour structure

    /// CREATIVE GRAIN IS ONE FIELD, on a colour photograph as much as on a
    /// black-and-white one — and this test asserted the exact opposite for one release,
    /// which is why the reasoning is written out rather than the number changed.
    ///
    /// The claim it used to make was that three decorrelated dye layers are "most of
    /// what makes grain read as film rather than as noise laid over the picture". That
    /// is true of a film stock and false here, and the difference is a pitch. A stock
    /// grains at a few microns, so all three layers land sub-pixel at preview resolution
    /// and recombine into something the eye reads as luminance. `Size` on this control
    /// reaches 56 µm by design, and the blue layer's old 2.0x crystal doubled it again:
    /// eight-pixel blobs of pure blue beside one-pixel red ones, independently seeded.
    ///
    /// The owner's verdict on the build that shipped it: "the grain is absolutely
    /// ridiculously bad. It just turns into rainbow splotches. It looks like noise, not
    /// grain." A test asserting decorrelation was, at that pitch, a test asserting the
    /// defect.
    func testCreativeGrainIsOneLuminanceField() {
        var recipe = Recipe()
        recipe.look.grain = CreativeGrain(amount: 100, size: 70)
        XCTAssertTrue(RenderPlan(recipe: recipe).grain?.profile.monochrome == true,
                      "one plate and one seed is what makes this grain and not chroma noise")
        let deltas = grainDeltas(recipe, flat())
        for (i, j) in [(0, 1), (0, 2), (1, 2)] {
            XCTAssertGreaterThan(Self.correlation(deltas[i], deltas[j]), 0.99,
                                 "channels \(i) and \(j) are not the same field — "
                                     + "independent seeds per channel ARE the rainbow, "
                                     + "at whatever size they are drawn")
        }
    }

    /// One crystal size across the layers, for the same reason: equalizing the sizes
    /// alone would not have helped (the seeds are the colour), but a per-channel size on
    /// a single shared field would stretch one channel's grain against the others and
    /// reintroduce colour through the back door.
    func testCreativeGrainHasOneCrystalSize() {
        let profile = FilmGrainProfile(creative: CreativeGrain(amount: 60, size: 80),
                                       monochrome: false)
        XCTAssertEqual(profile.sizeScale.r, 1.0, accuracy: 1e-12)
        XCTAssertEqual(profile.sizeScale.g, 1.0, accuracy: 1e-12)
        XCTAssertEqual(profile.sizeScale.b, 1.0, accuracy: 1e-12)
    }

    /// A black-and-white photograph is unchanged by all of the above — it always got one
    /// field, and it still does. The treatment flag no longer decides the grain's colour
    /// structure, but it must not crash or change the answer either.
    func testABlackAndWhitePhotographStillGetsOneField() {
        var recipe = Recipe()
        recipe.look.grain = CreativeGrain(amount: 100, size: 70)
        recipe.look.bw = BlackAndWhite(bands: Array(repeating: 0, count: 8),
                                       enabled: true)
        XCTAssertTrue(RenderPlan(recipe: recipe).grain?.profile.monochrome == true)
        let deltas = grainDeltas(recipe, flat())
        for (i, j) in [(0, 1), (0, 2), (1, 2)] {
            XCTAssertGreaterThan(Self.correlation(deltas[i], deltas[j]), 0.99)
        }
        var switchedOff = recipe
        switchedOff.look.bw?.enabled = false
        XCTAssertTrue(RenderPlan(recipe: switchedOff).grain?.profile.monochrome == true,
                      "creative grain is one field whatever the treatment says")
    }

    // MARK: - Precedence, and the film path's byte-identity

    /// A live stock's grain wins, and the creative grain waits. Stated as a matrix
    /// because the panel draws one set of rows or the other off the same predicate, and
    /// a panel that guessed differently from the renderer would be offering sliders that
    /// reach no pixel — which is the trap this whole change exists to close.
    func testThePanelAndThePlanAgreeAboutWhichGrainRenders() {
        let stock = FilmStock.portra400
        var withStock = Recipe()
        withStock.look.filmLab = FilmChain.defaultRecipe(for: stock)
        withStock.look.grain = CreativeGrain(amount: 80)

        // Stock loaded, strength up, stock grain up: the stock's grain renders.
        XCTAssertTrue(GrainPlan.filmOwnsTheGrain(withStock.look))
        XCTAssertEqual(RenderPlan(recipe: withStock).grain?.isCreative, false)

        // Film Lab strength at 0 — the trap. The chain is not built, so the stock can
        // lay down nothing, and the creative grain takes the stage instead of the
        // caption that used to stand there.
        var strengthZero = withStock
        strengthZero.look.filmLab?.amount = 0
        XCTAssertFalse(GrainPlan.filmOwnsTheGrain(strengthZero.look))
        XCTAssertEqual(RenderPlan(recipe: strengthZero).grain?.isCreative, true)

        // Stock loaded and RENDERING, with its own grain pulled to 0: the chain still
        // owns the stage, so nothing grains. This is the case that decides the
        // predicate — answering "the creative grain" here would make the stock's own
        // Amount slider replace itself with three different rows at the bottom of its
        // travel, which is `filmOwnsTheGrain`'s whole argument.
        var stockGrainZero = withStock
        stockGrainZero.look.filmLab?.grain.amount = 0
        XCTAssertTrue(GrainPlan.filmOwnsTheGrain(stockGrainZero.look))
        XCTAssertNil(RenderPlan(recipe: stockGrainZero).grain,
                     "a rendering stock with its grain at 0 lays down no grain, which "
                         + "is exactly what its slider says it will do")

        // A stock the catalog does not know builds no chain, so it owns nothing.
        var unknown = withStock
        unknown.look.filmLab?.stock = "lumen/not-a-stock"
        XCTAssertFalse(GrainPlan.filmOwnsTheGrain(unknown.look))
        XCTAssertEqual(RenderPlan(recipe: unknown).grain?.isCreative, true)

        // And with the creative grain off, none of those cases grains at all.
        var noCreative = strengthZero
        noCreative.look.grain = nil
        XCTAssertNil(RenderPlan(recipe: noCreative).grain)
    }

    /// THE PARITY-ADJACENT ONE. A film recipe renders bit-for-bit what it rendered
    /// before the stage was routed through `GrainPlan`, because `GrainPlan.film` carries
    /// exactly the four values the stage used to read off `FilmChain`.
    ///
    /// Written against `ReferenceRenderer.applyGrain`'s two front doors rather than
    /// against a stored golden, so it fails on the day the two stop agreeing rather than
    /// on the day somebody regenerates a fixture.
    func testTheFilmPathIsByteIdenticalThroughTheNewPlan() {
        let chain = FilmChain(FilmChain.defaultRecipe(for: .portra400),
                              displayWhite: 1.0)
        let frame = flat(64)
        let viaChain = ReferenceRenderer.applyGrain(
            frame, film: chain, seed: FilmGrainProfile.defaultPlateSeed, longEdge: 64)
        let viaPlan = ReferenceRenderer.applyGrain(
            frame, grain: GrainPlan.film(chain),
            seed: FilmGrainProfile.defaultPlateSeed, longEdge: 64)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                XCTAssertEqual(viaChain[x, y].r, viaPlan[x, y].r, accuracy: 0,
                               "the film path moved at (\(x), \(y))")
                XCTAssertEqual(viaChain[x, y].g, viaPlan[x, y].g, accuracy: 0)
                XCTAssertEqual(viaChain[x, y].b, viaPlan[x, y].b, accuracy: 0)
            }
        }
        XCTAssertEqual(GrainPlan.film(chain).profile.roughness,
                       FilmGrainProfile.stockRoughness,
                       "a stock's grain must keep the stock roughness")
    }

    // MARK: - The panel's section state

    /// The Effects dot lights for a moved creative grain, and the section's Reset puts
    /// it back — both halves, because the section draws whichever grain renders and a
    /// Reset that cleared only the visible one would leave the other waiting under a
    /// switch the photographer cannot see.
    func testTheEffectsSectionSeesAndResetsTheCreativeGrain() {
        var recipe = Recipe()
        recipe.look.grain = CreativeGrain(amount: 40, size: 70, roughness: 20)
        XCTAssertTrue(WorkspaceSection.nonDefault(in: recipe).contains(.effects),
                      "a moved creative grain is an edit the header must admit to")

        recipe.look.filmLab = FilmChain.defaultRecipe(for: .portra400)
        recipe.look.filmLab?.grain.amount = 90
        WorkspaceSection.effects.reset(&recipe)
        XCTAssertNil(recipe.look.grain, "Reset must clear the creative grain")
        XCTAssertEqual(recipe.look.filmLab?.grain,
                       FilmGrain(size: 1.0,
                                 amount: FilmStock.portra400.grainDefault),
                       "and must put the stock's grain back to the stock's own")
        XCTAssertFalse(WorkspaceSection.nonDefault(in: recipe).contains(.effects),
                       "after Reset the section must read clean")
    }

    /// THE TWO GRAINS DO NOT SHARE A BINDER KEY, and the stock's rows use the key the
    /// panel that also binds them uses (C2-07).
    ///
    /// A binder key is an identity: undo coalescing and the last-edited-control record
    /// resolve one. `EffectsPanel` keyed its stock Amount and Size rows
    /// `look.grain.amount` / `look.grain.size` — the literal string the creative rows
    /// twenty lines below use for a completely different field, and a recipe path the
    /// stock rows do not write. Nothing looked wrong, because the two sets of rows are
    /// never on screen together; that is exactly what makes it the kind of defect a
    /// test has to hold rather than a person.
    ///
    /// Read as text, for the reason `DesignSystemTests` and `KeyGrammarTests` are:
    /// `Sources/LumenApp` is `#if os(macOS)` and no test here can construct a panel.
    func testTheStockAndCreativeGrainRowsUseDifferentBinderKeys() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        func text(_ name: String) -> String {
            guard let s = try? String(contentsOf: root.appendingPathComponent(name),
                                      encoding: .utf8) else {
                XCTFail("\(name) not found — if it moved, move this scan with it")
                return ""
            }
            return s
        }
        let effects = text("EffectsPanel.swift")
        let look = text("LookPanel.swift")
        XCTAssertFalse(effects.isEmpty)
        XCTAssertFalse(look.isEmpty)

        // The creative rows own `look.grain.*`; the stock rows must not also claim it.
        XCTAssertTrue(effects.contains("creativeBinding(\"look.grain.amount\""),
                      "the creative Amount row's key moved — move this scan with it")
        XCTAssertFalse(effects.contains("binder.custom(\"look.grain.amount\""),
                       "the stock's Amount row is keyed `look.grain.amount` again — the "
                           + "same string the creative row uses, for a different field")
        XCTAssertFalse(effects.contains("binder.custom(\"look.grain.size\""),
                       "the stock's Size row is keyed `look.grain.size` again — the same "
                           + "string the creative row uses, for a different field")

        // And they agree with the other panel that binds the same two fields.
        for key in ["film.grain.amount", "film.grain.size"] {
            XCTAssertTrue(effects.contains("binder.custom(\"\(key)\""),
                          "the Effects stock row no longer carries \(key)")
            XCTAssertTrue(look.contains("bindFilm(\"\(key)\""),
                          "LookPanel no longer carries \(key) — the two panels bind one "
                              + "field and have stopped agreeing about its identity")
        }
    }

    /// Roughness alone counts as an edit even at Amount 0, where it renders nothing —
    /// the recipe differs from its defaults and a dot that ignored it would leave the
    /// Reset unoffered with a moved slider on screen. `Look.vignetteFeather`'s own rule,
    /// one section up.
    func testAMovedRoughnessCountsEvenAtAmountZero() {
        var recipe = Recipe()
        recipe.look.grain = CreativeGrain(roughness: 80)
        XCTAssertTrue(WorkspaceSection.nonDefault(in: recipe).contains(.effects))
    }
}

// MARK: - The grain radius: per layer, no floor, relative to the frame (C2-01, WS-40)
//
// The plate's half-pixel floor was applied twice once (C2-01), which drew Velvia's blue
// record 17% coarser in the fit view than in the file; then it was applied once, which
// still left a dead bottom range at preview sizes (WS-40 F5). The grain field has no
// floor at all: a sub-pixel grain is averaged by the pixel aperture, so the radius is a
// pure fraction of the frame at every size and every layer.

extension CreativeGrainTests {

    private func profile(_ stock: FilmStock) -> FilmGrainProfile {
        FilmGrainProfile(stock: stock, size: 1.0, amount: 50, pushPull: 0)
    }

    /// Radius per long edge — the resolution-independent quantity. Preview and export
    /// agree on it for every stock and every record, down to a thumbnail.
    func testEveryRecordHasTheSameTextureInThePreviewAndTheExport() {
        for stock in FilmStock.all {
            let p = profile(stock)
            for channel in 0...2 {
                let export = p.grainRadiusPixels(longEdgePixels: 8000, printSizeInches: 8,
                                                 channel: channel) / 8000
                for edge in [200, 1024, 2560] {
                    let preview = p.grainRadiusPixels(longEdgePixels: edge,
                                                      printSizeInches: 8,
                                                      channel: channel) / Double(edge)
                    XCTAssertEqual(preview / export, 1.0, accuracy: 1e-9,
                                   "\(stock.id) record \(channel) at \(edge) px")
                }
            }
        }
    }

    /// The number, so a change that re-introduces a floor or drops the half is caught
    /// by value: Velvia 50's blue at 2560 is ½ × 6 µm on a 36 mm gate × 2.0.
    func testVelviasBlueRadiusIsTheScaledHalfPitch() {
        let velvia = profile(FilmStock.velvia50)
        XCTAssertEqual(velvia.grainRadiusPixels(longEdgePixels: 2560, printSizeInches: 8,
                                                channel: 2),
                       0.5 * 0.006 / 36 * 2560 * 2.0, accuracy: 1e-9)
        XCTAssertEqual(velvia.grainRadiusPixels(longEdgePixels: 2560, printSizeInches: 8,
                                                channel: 2)
                       / velvia.grainRadiusPixels(longEdgePixels: 2560, printSizeInches: 8,
                                                  channel: 1),
                       velvia.sizeScale.b / velvia.sizeScale.g, accuracy: 1e-12)
    }
}

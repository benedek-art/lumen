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
// Every number lands on the same profile, the same plate generator and the same amplitude
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

    /// Size is a pitch at the gate, so it scales the plate's footprint and nothing else.
    /// Measured on `plateScale` at an export-sized render, where the half-pixel floor is
    /// not in the way.
    func testSizeIsAPitchAndCoarsensTheFootprint() {
        var previous = 0.0
        for size in [0.0, 25.0, 50.0, 75.0, 100.0] {
            let plan = GrainPlan.creative(CreativeGrain(amount: 50, size: size),
                                          monochrome: false)
            let scale = plan.plateScale(longEdgePixels: 6000, channel: 1)
            XCTAssertGreaterThan(scale, previous,
                                 "Size \(size) is no coarser than the setting below it")
            previous = scale
            print(String(format: "GRAIN size %5.0f → pitch %.2f µm → %.3f px at 6000",
                         size, plan.profile.pitchMicrons, scale))
        }
        // The mapping the tooltip quotes.
        XCTAssertEqual(FilmGrainProfile.creativePitchMicrons(size: 0), 7, accuracy: 1e-9)
        XCTAssertEqual(FilmGrainProfile.creativePitchMicrons(size: 50), 19.8,
                       accuracy: 0.05)
        XCTAssertEqual(FilmGrainProfile.creativePitchMicrons(size: 100), 56,
                       accuracy: 1e-9)
        // Doubling every 33⅓ points, which is the sentence the help gives.
        let a = FilmGrainProfile.creativePitchMicrons(size: 20)
        let b = FilmGrainProfile.creativePitchMicrons(size: 20 + 100.0 / 3.0)
        XCTAssertEqual(b / a, 2, accuracy: 1e-9)
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
        let small = plan.plateScale(longEdgePixels: 2000, channel: 1)
        let large = plan.plateScale(longEdgePixels: 6000, channel: 1)
        XCTAssertEqual(large / small, 3.0, accuracy: 1e-9,
                       "three times the pixels must be three times the footprint, or the "
                           + "same Size means two different textures")
        // And print size cancels out of it entirely, exactly as it does for a stock.
        let atTen = plan.profile.plateScale(longEdgePixels: 4000, printSizeInches: 10)
        let atThirty = plan.profile.plateScale(longEdgePixels: 4000, printSizeInches: 30)
        XCTAssertEqual(atTen, atThirty, accuracy: 1e-12)
    }

    // MARK: - Roughness

    /// Roughness redistributes the plate's energy across scales and leaves the amplitude
    /// alone. That is the property that makes it a third control rather than a second
    /// strength, and it comes from the plate's renormalization rather than from care at
    /// the call site — so it is measured on the plate itself.
    func testRoughnessMovesTheCharacterAndNotTheAmplitude() {
        let size = 128
        var previousDetail = 0.0
        for roughness in [0.0, 25.0, 50.0, 75.0, 100.0] {
            let p = FilmGrainProfile.creativePersistence(roughness: roughness)
            let plate = FilmGrainProfile.plate(size: size, seed: 99, sigma: 1,
                                               persistence: p)
            let values = plate.map(Double.init)
            // Unit variance, at every roughness: the plate is rescaled after the octaves
            // are summed.
            XCTAssertEqual(Self.sigma(values), 1.0, accuracy: 1e-6,
                           "roughness \(roughness) changed the plate's amplitude")
            // High-frequency content: the mean absolute difference between horizontal
            // neighbours, wrapped, which rises as the fine octaves gain weight.
            var detail = 0.0
            for y in 0..<size {
                for x in 0..<size {
                    detail += abs(values[y * size + x]
                                  - values[y * size + (x + 1) % size])
                }
            }
            detail /= Double(size * size)
            print(String(format: "GRAIN roughness %5.0f → persistence %.3f → "
                         + "neighbour detail %.4f", roughness, p, detail))
            XCTAssertGreaterThan(detail, previousDetail,
                                 "roughness \(roughness) is no grittier than the setting "
                                     + "below it")
            previousDetail = detail
        }
    }

    /// Roughness 50 IS the plate every film stock has always been given — the same
    /// bytes, not merely the same statistics. This is what makes the control's neutral a
    /// real neutral and what lets Roughness exist without moving one pixel of any
    /// film-grained photograph.
    func testRoughnessFiftyIsExactlyTheFilmPlate() {
        XCTAssertEqual(FilmGrainProfile.creativePersistence(roughness: 50),
                       FilmGrainProfile.defaultPersistence, accuracy: 0)
        let withDefault = FilmGrainProfile.plate(size: 64, seed: 4242, sigma: 1)
        let explicit = FilmGrainProfile.plate(
            size: 64, seed: 4242, sigma: 1,
            persistence: FilmGrainProfile.creativePersistence(roughness: 50))
        XCTAssertEqual(withDefault, explicit,
                       "the default plate and the Roughness-50 plate must be identical "
                           + "bytes, or every stock's grain moved when this control "
                           + "was added")
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
    /// exactly the four values the stage used to read off `FilmChain` and
    /// `FilmGrainProfile.plate` defaults to the persistence it used to hard-code.
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
        XCTAssertEqual(GrainPlan.film(chain).profile.persistence,
                       FilmGrainProfile.defaultPersistence,
                       "a stock's plate must still be the plate it always was")
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

// MARK: - The half-pixel floor, applied once (C2-01)
//
// `plateScale(…, channel:)` read the already-floored whole-frame scale and floored its
// own product on top. Two floors in a chain that ends in one sample.
//
// For the red and green records that is provably a no-op — `sizeScale` 0.8 and 1.0, and
// scaling a floored value down still lands on the floor — which is where the audit that
// found this had the channel wrong. For BLUE, at 2.0, it is a real distortion: a base
// of 0.43 px floors to 0.5 and doubles to a full pixel, where one floor gives 0.85. On
// Velvia 50 at the 2560 px working resolution that is a blue plate 17 % coarser than the
// exported file's, and on Ektar 100 0.45 % — so the fit view's grain has a different
// COLOUR texture from the delivered frame, on precisely the two stocks somebody chooses
// for being fine-grained.
//
// What this does NOT fix, and the audit claimed it would: the red record's 46 % and the
// green's 17 % divergence on Velvia. Those are the floor itself — the working resolution
// sits below it and the export does not — and they need the band-limited plate from
// R7 C.2.3, not a rearrangement of the max().

extension CreativeGrainTests {

    private func profile(_ stock: FilmStock) -> FilmGrainProfile {
        FilmGrainProfile(stock: stock, size: 1.0, amount: 50, pushPull: 0)
    }

    /// Cells per long edge — the resolution-independent quantity. Preview and export
    /// must agree on it, because it is what the texture looks like.
    private func cellsPerEdge(_ p: FilmGrainProfile, _ edge: Int, _ channel: Int) -> Double {
        p.plateScale(longEdgePixels: edge, printSizeInches: 8, channel: channel) / Double(edge)
    }

    /// The defect: the blue record drawn 17 % coarser in the fit view than in the file.
    func testTheBlueRecordHasTheSameTextureInThePreviewAndTheExport() {
        let velvia = profile(FilmStock.velvia50)
        let preview = cellsPerEdge(velvia, 2560, 2)
        let export = cellsPerEdge(velvia, 8000, 2)
        XCTAssertEqual(preview / export, 1.0, accuracy: 1e-9,
                       "Velvia's blue plate is \((preview / export - 1) * 100)% coarser "
                       + "at 2560 than at 8000 — the double floor took a 0.43 px base to "
                       + "0.5 and then doubled it")

        let ektar = profile(FilmStock.ektar100)
        XCTAssertEqual(cellsPerEdge(ektar, 2560, 2) / cellsPerEdge(ektar, 8000, 2),
                       1.0, accuracy: 1e-9)
    }

    /// And the number, so a future change that re-floors early is caught by value and
    /// not only by ratio: Velvia's blue at 2560 is 0.4267 × 2.0.
    func testVelviasBlueCellIsTheScaledBaseAndNotTheScaledFloor() {
        let velvia = profile(FilmStock.velvia50)
        XCTAssertEqual(velvia.plateScale(longEdgePixels: 2560, printSizeInches: 8, channel: 2),
                       0.8533333333, accuracy: 1e-6,
                       "flooring before the ×2.0 gave 1.0 px — a fifth of a stop of "
                       + "coarseness invented by the order of two max()es")
    }

    // MARK: What must NOT change

    /// THE FLOOR IS STILL THERE. It exists because a cell below half a render pixel
    /// cannot be sampled, and removing it rather than moving it would alias the plate
    /// into a fixed pattern.
    func testACellIsNeverAllowedBelowHalfAPixel() {
        for stock in FilmStock.all {
            let p = profile(stock)
            for channel in 0...2 {
                let tiny = p.plateScale(longEdgePixels: 200, printSizeInches: 8,
                                        channel: channel)
                XCTAssertGreaterThanOrEqual(tiny, 0.5,
                                            "\(stock.id) channel \(channel) at 200 px")
            }
            XCTAssertGreaterThanOrEqual(p.plateScale(longEdgePixels: 200,
                                                     printSizeInches: 8), 0.5)
        }
    }

    /// The red and green records do not move at all. This is the honest half of the
    /// finding: had they moved, every film proof record would drift, and they do not.
    func testTheRedAndGreenRecordsAreUntouchedByTheReordering() {
        for stock in FilmStock.all {
            let p = profile(stock)
            for edge in [800, 2560, 4000, 8000] {
                for channel in [0, 1] {
                    let once = p.plateScale(longEdgePixels: edge, printSizeInches: 8,
                                            channel: channel)
                    // What the two-floor form computed, written out.
                    let base = p.plateScale(longEdgePixels: edge, printSizeInches: 8)
                    let twice = Swift.max(base * Swift.max(p.sizeScale[channel], 0.05), 0.5)
                    XCTAssertEqual(once, twice, accuracy: 1e-12,
                                   "\(stock.id) ch\(channel) at \(edge)")
                }
            }
        }
    }

    /// Above the floor everything is unchanged for every channel — the reordering only
    /// ever speaks where the base was being clamped.
    func testWellAboveTheFloorNothingMovesAtAll() {
        for stock in FilmStock.all {
            let p = profile(stock)
            for channel in 0...2 {
                let base = p.plateScale(longEdgePixels: 8000, printSizeInches: 8)
                XCTAssertGreaterThan(base, 0.5, "\(stock.id) must be above the floor here")
                XCTAssertEqual(p.plateScale(longEdgePixels: 8000, printSizeInches: 8,
                                            channel: channel),
                               base * p.sizeScale[channel], accuracy: 1e-12)
            }
        }
    }
}

// MARK: - The plate is band-limited to the resolution it is sampled at (C2-01b)
//
// The plate is four octaves of value noise on a 128-texel field: octave `k` spans
// `128 / (8 << k)` texels, so 16, 8, 4 and 2. Multiplied by `plateScale` those become
// render pixels, and an octave whose features fall below two render pixels is past
// Nyquist — what reaches the screen is aliasing, not grain.
//
// Velvia 50's green record is 0.5 render pixels per texel at the 2560 px working
// resolution, so its finest octave has ONE-pixel features in the fit view; at 8000 the
// same octave is 2.67 pixels and resolves cleanly. The preview was showing false
// high-frequency detail the delivered file does not contain — which is the half of the
// grain parity loss that reordering the half-pixel floor did not touch, and which the
// finding that prescribed that reordering attributed to it.

extension CreativeGrainTests {

    /// Energy above the sampling limit, measured as the mean absolute difference between
    /// neighbouring texels. An aliasing octave shows up here and nowhere else.
    private func neighbourEnergy(_ plate: [Float], size: Int) -> Double {
        var total = 0.0
        var count = 0
        for y in 0..<size {
            for x in 0..<(size - 1) {
                total += abs(Double(plate[y * size + x + 1] - plate[y * size + x]))
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    // MARK: The defect

    /// At a scale where the finest octave cannot be sampled, it is not built.
    func testTheFinestOctaveIsDroppedWhenItCannotBeSampled() {
        let full = FilmGrainProfile.plate(size: 128, seed: 7, sigma: 1)
        // 0.5 render pixels per texel: the 2-texel octave spans one pixel. Past Nyquist.
        let limited = FilmGrainProfile.plate(size: 128, seed: 7, sigma: 1,
                                             renderPixelsPerCell: 0.5)
        XCTAssertLessThan(neighbourEnergy(limited, size: 128),
                          neighbourEnergy(full, size: 128) * 0.95,
                          "the plate carries the same texel-to-texel energy at a scale "
                          + "where its finest octave cannot be resolved — that energy "
                          + "reaches the screen as aliasing")
    }

    /// And at a scale where every octave resolves, nothing is dropped: the plate must be
    /// byte-identical to the unlimited one, or the export's grain has silently changed.
    func testAnExportResolutionPlateIsUnchanged() {
        let full = FilmGrainProfile.plate(size: 128, seed: 7, sigma: 1)
        // 1.333 px per texel — Velvia's green at 8000, where the finest octave is 2.67.
        let limited = FilmGrainProfile.plate(size: 128, seed: 7, sigma: 1,
                                             renderPixelsPerCell: 1.3333)
        XCTAssertEqual(limited, full,
                       "an octave was dropped at a resolution that can resolve all four")
    }

    // MARK: What must NOT change

    /// AMPLITUDE IS PRESERVED. The plate renormalises to unit variance by measurement,
    /// so dropping an octave makes the texture coarser and not quieter. A band-limited
    /// plate that also lost energy would read as the grain slider having moved.
    func testDroppingAnOctaveDoesNotChangeTheAmplitude() {
        for perCell in [0.25, 0.5, 1.0, 2.0] {
            let plate = FilmGrainProfile.plate(size: 128, seed: 7, sigma: 1,
                                               renderPixelsPerCell: perCell)
            let mean = plate.reduce(0.0) { $0 + Double($1) } / Double(plate.count)
            let variance = plate.reduce(0.0) { $0 + pow(Double($1) - mean, 2) }
                / Double(plate.count)
            XCTAssertEqual(variance.squareRoot(), 1, accuracy: 1e-6,
                           "at \(perCell) px per texel the plate's amplitude moved")
        }
    }

    /// Nil is the old behaviour exactly, so every caller that does not know its
    /// resolution is untouched.
    func testNoScaleMeansEveryOctave() {
        XCTAssertEqual(FilmGrainProfile.plate(size: 128, seed: 11, sigma: 1,
                                              renderPixelsPerCell: nil),
                       FilmGrainProfile.plate(size: 128, seed: 11, sigma: 1))
    }

    /// A degenerate scale is ignored rather than dropping every octave and leaving a
    /// flat plate — a hand-edited sidecar can produce one.
    func testADegenerateScaleIsIgnored() {
        let full = FilmGrainProfile.plate(size: 128, seed: 3, sigma: 1)
        for bad in [0.0, -1.0, Double.nan, Double.infinity] {
            XCTAssertEqual(FilmGrainProfile.plate(size: 128, seed: 3, sigma: 1,
                                                  renderPixelsPerCell: bad),
                           full, "a scale of \(bad) changed the plate")
        }
    }
}

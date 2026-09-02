// LookSubset.swift
// What a look IS, as a value — and the two operations that take one off a photograph
// and put it onto another.
//
// docs/00 §4 states the rule the whole product is cut along: "Develop makes the file
// true … Look makes the set yours", and then the sentence this file exists to make
// mechanical — "Presets respect the boundary, so a film look never smuggles in
// someone's white balance."
//
// The boundary was already structural in the format (docs/15 §15.4 doctrine 3: "Stage
// tags are structural … per-frame normalization is never dragged along by accident"),
// but nothing had ever expressed it as code that can be wrong. `AppState.copyLook`
// copied `recipe.look` inside a SwiftUI observable object in a target with no tests, so
// the partition was a fact about one line of an untestable file. Here it is a pure
// function over two values, with the partition itself written down as data so a new
// top-level recipe key cannot slip past the decision.
//
// THE PARTITION, and why each side is where it is:
//
//   look        TRAVELS. Grading wheels, printer lights, the Film Lab, primaries, the
//               B&W treatment, vignette, creative grain, the display transform's five
//               overrides, and the (inert) LUT slot. Every one of them is an expression
//               of intent about a set of frames, and each reads a develop-normalized,
//               scene-referred image (docs/14 §3), so it computes the same thing on
//               every frame it lands on.
//
//   look.render.preset
//               TRAVELS ONLY WITHIN A REGISTER — the one field on the travelling side
//               that the paragraph above is not true of. The exception is written out
//               here rather than left inside `applied(to:)` because the sentence it
//               breaks is this file's entire justification, and a reader who believes
//               that sentence will not go looking for a counterexample.
//
//               Four of the five preset names — "Neutral", "Soft", "Punchy", "Film
//               Base" — are curve choices, and those really are intents about a set of
//               frames. The fifth, "Linear", is not a curve at all. docs/04 §6.1 put it
//               there as the escape hatch for a file that has ALREADY been tone-mapped,
//               and `AppState.startingRecipe` writes it onto every JPEG, HEIC and TIFF
//               at ingest for exactly that reason: "a JPEG … is clipped at display
//               white and carries a manufacturer's S-curve. Handing it the default
//               sigmoid applies a SECOND." `RenderedImageSource` says the same thing
//               about the pixels and `WorkspaceSection.nonDefault` a third time. So on
//               a rendered file the preset is not an expression of intent about a set
//               of frames at all; it is a fact about THIS one, of the same kind as its
//               white balance — and a rendered file is the one input to this pipeline
//               that is not scene-referred, which is precisely the property the
//               travelling side is justified by.
//
//               Carrying it whole therefore moves the target between two registers, and
//               the cost is not subtle. Measured through the shipping curve
//               (`DisplayTransform.tone`, neutral preset, white target 100, black
//               0.0152, anchors −9/+5 EV): a RAW-born look landing on a JPEG takes sRGB
//               code value 32 → 13, 48 → 27, 255 → 222 — plugged shadows, and a white
//               that is no longer white. The reverse, a JPEG-born look landing on a
//               RAW, clips everything above +2.47 EV to paper white: two and a half
//               stops of highlight the display transform was holding, gone. It is the
//               same defect the Looks header's Reset had (audit K-027, fixed at
//               `DevelopColumn.swift:596` by re-applying the photograph's own starting
//               render per target), arriving instead through the two doors the feature
//               exists for — Apply Look and Paste Look.
//
//               So the rule is a boundary rather than a ban: the preset travels unless
//               it would carry the frame across the line between tone-mapped and not,
//               and in that case the target keeps its own. "Punchy" still travels RAW
//               to RAW and JPEG to JPEG — every case where the two frames agree about
//               what they are, which is nearly every case, and which is why this went
//               unnoticed. `carriedRenderPreset` is the rule; `applied(to:)` applies it.
//
//   develop     STAYS. White balance is derived from THIS camera's as-shot neutral;
//               exposure and tone are THIS frame's light; geometry is THIS frame's
//               crop; denoise is THIS frame's ISO; the mixer, point colours and the
//               curve are corrective, per docs/14 §3's register table. A look that
//               carried any of them would be the copy-paste-then-fix ritual docs/00
//               names as Lightroom's failure, with the wrong exposure baked in.
//
//   masks       STAY, today, and the reason is not the same as develop's. docs/14 §3
//               and docs/15 §15.4 both say masks declare their own register and that
//               look-tagged ones travel — and `Mask` carries no register field, so
//               there is no such thing as a look-tagged mask to carry (audit FILM-17).
//               Until one exists, "carry the masks" would mean carrying ALL of them,
//               and a mask's geometry is per-frame by construction: a brush component
//               is a stroke blob recorded over one photograph, a radial is a centre in
//               that frame's source coordinates, a linear is a line across it. Moving
//               those to another frame is the same defect as moving a crop.
//
//   pipelineVersion
//               NEITHER. It is carried IN the stored look, because docs/14 §3 defines a
//               named look as "the look-slice of a recipe plus its pipelineVersion" and
//               a reader has to know which vocabulary the slice is written in. It is
//               not applied ONTO the target as-is: see `applied(to:)`.
//
// ONE THING THE DOCUMENTS DISAGREE ABOUT, left alone rather than decided here.
// docs/14 §3's register list puts "printer lights" on the DEVELOP side; docs/15 §15.4's
// recipe format puts `printerLights` inside `look`, which is where `Look` puts it, which
// is where the Look panel draws it, and which is therefore what travels today. Three
// sources against one, so this file follows them — but the odd one out is arguable
// rather than obviously a typo (a printer-light master IS an exposure, and exposure is
// the develop side's own example of what must not travel), and unilaterally editing the
// pipeline document to match the code is how a real design question gets closed by
// whoever touched the file last. It is written down here instead.
//
// Nothing in the Look subtree is conditional here — a look carries the whole struct,
// `lut` included. That is deliberate on two counts. `Recipe.renderIdentity` strips
// `look.lut` because no stage reads it, and that projection is about which recipes
// render the same picture; which fields a photographer's saved look remembers is a
// different question with a different answer. And a LUT is the most look-shaped thing
// there is, so the day a LUT stage lands, looks carry it with no change here and no
// second dead-field decision to unwind.

import Foundation

/// `look.kind` — the three registers docs/15 §15.3 declares for the table. Only `look`
/// has a writer today; the other two are named so the column's values are a closed set
/// rather than free text, and so a listing can ask for one register.
public enum LookKind: String, Codable, Sendable, CaseIterable {
    /// The portable creative layer. What "Save Look" writes.
    case look
    /// A develop-side starting point (per-camera defaults, a denoise baseline). No
    /// writer: `LookSubset` carries no develop fields, by the partition above.
    case developPreset = "develop-preset"
    /// Applied automatically at ingest. No writer.
    case importDefault = "import-default"
}

/// The portable slice of a recipe: the Look layer plus the vocabulary version it was
/// written in. Stored as canonical sparse JSON in `look.subset`.
public struct LookSubset: Codable, Equatable, Sendable {
    /// The pipeline version of the recipe this slice was taken from.
    public var pipelineVersion: Int
    public var look: Look

    public init(pipelineVersion: Int = currentPipelineVersion, look: Look = Look()) {
        self.pipelineVersion = pipelineVersion
        self.look = look
    }

    // MARK: - The partition, as data

    /// Top-level recipe keys a look TAKES from the photograph it is saved off.
    ///
    /// TOP-LEVEL is the whole claim. One leaf inside `look` is qualified —
    /// `look.render.preset` travels only within its register, see the header and
    /// `carriedRenderPreset` — and that is not expressible here, because this set
    /// answers "which subtrees" and the preset question is "which of two frames does
    /// this field describe". Written down at both ends rather than at one, so the set
    /// is not read as a promise it does not make.
    public static let carriedRecipeKeys: Set<String> = ["look"]

    /// Top-level recipe keys a look leaves behind. `pipelineVersion` is here because it
    /// is not content: it is copied into the stored look as a stamp, and never written
    /// over the target's own (see `applied(to:)`).
    /// `maskGroups` is here because `masks` is, and for the same reason rather than by
    /// association: a folder is a name for a set of masks, and a look that carried the
    /// folders without the masks would arrive as a column of empty headers. The
    /// partition test is what forced this decision to be made rather than defaulted —
    /// adding the field to `Recipe` and not to one of these two sets fails it by name.
    public static let uncarriedRecipeKeys: Set<String> = [
        "pipelineVersion", "develop", "masks", "maskGroups",
    ]

    // MARK: - Taking a look off a photograph

    /// The look this recipe expresses.
    public static func extracted(from recipe: Recipe) -> LookSubset {
        LookSubset(pipelineVersion: recipe.pipelineVersion, look: recipe.look)
    }

    // MARK: - Putting it onto another

    /// The preset name that means "this frame has already been tone-mapped once",
    /// spelled once here because three modules have to agree about the string and two
    /// of them (`AppState.startingRecipe`, `DisplayTransformParams.preset(named:)`) are
    /// not visible from this one.
    ///
    /// Anything that is NOT this name is treated as a tone-mapping preset, which is the
    /// same reading `DisplayTransformParams.preset(named:)` gives — its `default:` case
    /// resolves an unrecognised name to Neutral. So a preset written by a later build
    /// is a curve, not a second escape hatch, and it travels. That is the conservative
    /// answer for an unknown name: mistaking a curve for a curve costs a different
    /// grade, mistaking an escape hatch for a curve costs a second tone map.
    public static let linearPresetName = "Linear"

    /// Which preset a frame ends up on when a look carrying `carried` lands on a frame
    /// currently sitting on `own`. The header explains why the answer is not simply
    /// `carried`.
    ///
    /// It reads the TARGET RECIPE's preset rather than the target photograph's format,
    /// because a `Recipe` records no format and this is a pure function over two values
    /// — which is the property that makes the rule testable at all, and the reason it
    /// is here rather than in the view layer where it started. The recipe's preset is
    /// the format's own statement in the first place: `AppState.startingRecipe` writes
    /// "Linear" onto every rendered file at ingest, and nothing else writes it unless
    /// the photographer picks it.
    ///
    /// The two readings differ in exactly one case — a RAW the photographer deliberately
    /// parked on Linear to inspect the data — and there this rule is the conservative
    /// one: that frame keeps Linear, and a look cannot pull it off. A look that silently
    /// took a frame off the honesty control would be the same class of surprise in the
    /// other direction, and the preset picker is the affordance for changing registers
    /// on purpose. No look moves a frame across the boundary, either way.
    ///
    /// Public and named because it is a RULE, not an implementation detail: `applied(to:)`
    /// is not the only door a look comes through — `AppState.pasteLook` assigns
    /// `recipe.look` directly — and a second copy of this decision written at the other
    /// call site is how the two drift apart.
    public static func carriedRenderPreset(_ carried: String, onto own: String) -> String {
        let carriedIsRendered = carried == LookSubset.linearPresetName
        let ownIsRendered = own == LookSubset.linearPresetName
        return carriedIsRendered == ownIsRendered ? carried : own
    }

    /// This look applied to one recipe: the Look layer replaced whole — save for the one
    /// leaf in it that describes the target rather than the look — with develop and
    /// masks untouched.
    ///
    /// The version is raised, never lowered, and never simply overwritten. Lowering it
    /// would stamp a v1 vocabulary onto a recipe whose develop layer is written in v2 —
    /// a claim about the whole document made by a slice that only speaks for part of
    /// it. Leaving it alone is wrong in the other direction: a v2 look can express
    /// "black and white, off, mix kept" (`look.bw.enabled == false`), which a v1 reader
    /// renders as black and white, so a recipe that has just been handed one has to say
    /// v2 or it lies about what it holds. `max` is the only rule that is right at both
    /// ends, and it is safe because no version-1 recipe renders differently under
    /// version 2 (see `currentPipelineVersion`).
    ///
    /// `render`'s five OVERRIDES — contrast, skew, huePreservation, blackTarget,
    /// whiteTarget — travel unconditionally and are deliberately NOT part of the preset
    /// exception. Each is a number the photographer dialled on top of whatever curve is
    /// in force, each means the same thing under every preset, and none of them names a
    /// register: `blackTarget` and `whiteTarget` are display targets in % of SDR white,
    /// true of the screen rather than of the file, and `contrast`, `skew` and
    /// `huePreservation` shape a curve that a rendered frame simply does not run. A look
    /// that dropped them would apply a different picture than it saved, which is the
    /// same argument `vignetteFeather` and `grain` are carried under. Only `preset`
    /// answers "what kind of file is this", so only `preset` is guarded.
    ///
    /// `applied(toAll:)` needs no rule of its own for any of this. The decision is taken
    /// against each target recipe, so a selection mixing RAWs with delivered JPEGs — a
    /// real job, and the case that makes this worth guarding rather than a curiosity —
    /// gets the right answer per frame for free.
    public func applied(to recipe: Recipe) -> Recipe {
        var copy = recipe
        copy.look = look
        copy.look.render.preset = LookSubset.carriedRenderPreset(look.render.preset,
                                                                 onto: recipe.look.render.preset)
        copy.pipelineVersion = max(recipe.pipelineVersion, pipelineVersion)
        return copy
    }

    /// This look applied across a selection.
    ///
    /// Spelled out rather than left to the call site's `map`, because "apply to the
    /// selection" is the gesture the split exists for — one look across 800 frames —
    /// and the property worth pinning is about the whole set: every frame ends up
    /// expressing the same look while keeping its own normalization. A `map` in a view
    /// cannot be asserted; this can.
    ///
    /// "The same look" is exact for a selection of one kind of file and has one stated
    /// exception for a mixed one: a rendered frame keeps its own `render.preset`, per
    /// `applied(to:)`. That is not a weaker promise, it is the promise — a selection
    /// dropped on a shoot folder holds the RAWs and the delivered JPEGs together, and
    /// "the same look" cannot mean "the same tone-mapping register" for files that
    /// arrive in different ones.
    public func applied(toAll recipes: [Recipe]) -> [Recipe] {
        recipes.map(applied(to:))
    }

    // MARK: - Names

    /// The name a look is stored under, or nil if the string is not a name.
    ///
    /// Trimmed, because " Portra warm " and "Portra warm" are the same look to the
    /// person typing and two rows to SQLite; collapsed internally so tab-pasted names
    /// do not sort strangely; length-capped so a paste accident cannot put a paragraph
    /// in the browser. Empty is nil rather than an error string, so the save button has
    /// something to disable itself on.
    public static func normalizedName(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if collapsed.isEmpty { return nil }
        if collapsed.count <= LookSubset.maximumNameLength { return collapsed }
        return String(collapsed.prefix(LookSubset.maximumNameLength))
    }

    public static let maximumNameLength = 120

    private enum CodingKeys: String, CodingKey {
        case pipelineVersion, look
    }

    /// Tolerant of a recipe written before any of these keys existed: each falls
    /// back to the default in the memberwise initializer above. See RecipeDecoding.swift.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.pipelineVersion = try c.decodeIfPresent(Int.self, forKey: .pipelineVersion)
            ?? currentPipelineVersion
        self.look = try c.decodeIfPresent(Look.self, forKey: .look) ?? Look()
    }
}

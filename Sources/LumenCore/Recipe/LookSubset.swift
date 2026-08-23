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
//               B&W treatment, vignette, the display transform's preset and overrides,
//               and the (inert) LUT slot. Every one of them is an expression of intent
//               about a set of frames, and each reads a develop-normalized,
//               scene-referred image (docs/14 §3), so it computes the same thing on
//               every frame it lands on.
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
    public static let carriedRecipeKeys: Set<String> = ["look"]

    /// Top-level recipe keys a look leaves behind. `pipelineVersion` is here because it
    /// is not content: it is copied into the stored look as a stamp, and never written
    /// over the target's own (see `applied(to:)`).
    public static let uncarriedRecipeKeys: Set<String> = [
        "pipelineVersion", "develop", "masks",
    ]

    // MARK: - Taking a look off a photograph

    /// The look this recipe expresses.
    public static func extracted(from recipe: Recipe) -> LookSubset {
        LookSubset(pipelineVersion: recipe.pipelineVersion, look: recipe.look)
    }

    // MARK: - Putting it onto another

    /// This look applied to one recipe: the Look layer replaced whole, develop and
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
    public func applied(to recipe: Recipe) -> Recipe {
        var copy = recipe
        copy.look = look
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
}

// RecipeReset.swift
// What "as imported" means for one photograph, and the verb that puts it back there.
//
// AS IMPORTED IS NOT AN EMPTY RECIPE, and that sentence is the whole reason this file
// exists. A photograph arrives already carrying decisions nobody made by hand:
//
//   · a file that has ALREADY been tone-mapped — JPEG, HEIC, TIFF, PNG — starts on the
//     "Linear" display transform, because Lumen's own transform is the only one a scene-
//     referred raw will ever get and applying it a second time on top of the camera's
//     crushes the blacks and hardens the highlights (docs/04 §6.1 put the preset there
//     as exactly this escape hatch);
//   · a camera raw starts on the denoise its own capture ISO calls for, because Tier 1
//     is always live and a flat "Colour 25" is, in docs/07 §4's words, a guess that
//     happens to be acceptable.
//
// Put a bare `Recipe()` on either of those and you have not restored the photograph, you
// have edited it — and the app has been convicted of both directions of that mistake
// already. `WorkspaceModification.nonDefault` carries the receipts: comparing a JPEG
// against the TYPE's default lit the Looks dot on every untouched rendered file in the
// library, and the header Reset that dot enabled then wrote "Neutral" and visibly
// crushed the picture.
//
// WHY IT IS HERE rather than in the app. `AppState.startingRecipe` was the only
// statement of this rule, and `Sources/LumenApp` compiles on macOS alone: nothing could
// check the answer until CI, and a wrong field path would surface as a photograph that
// quietly comes back different rather than as a build failure. Six call sites read it —
// the whole-photo Reset; `DevelopColumn`'s per-section Reset, which has to patch the ISO
// denoise and the display transform back in after `WorkspaceSection.reset` has written
// the type's defaults over them; `LookPanel`'s Display Transform Reset, which patches
// the same field again; the accordion's modified dot, which takes the same two values as
// `denoiseDefault` and `renderDefault`; the footer's Reset enablement; and `recipe(for:)`
// itself. Most of them resolve the same two fields by hand, which is that many chances
// for one copy to drift. This is the one place, and `ResetSemanticsTests` is what holds
// it.
//
// The one fact this file deliberately does NOT know is which extensions are rendered:
// that list is `PhotoFormats` in the app target, and duplicating it here would be a
// second answer to "is this a JPEG" that can disagree with the one the scanner used.
// The caller states the answer; see `SourceFile`.

import Foundation

extension Recipe {

    /// The two facts about the file on disk that decide what its untouched recipe is.
    ///
    /// Deliberately not a URL. A path is a thing this module would have to interpret —
    /// lowercasing an extension and looking it up in a set the folder scanner also owns
    /// — and the interpretation is precisely what must not exist twice. Two booleans and
    /// an integer cannot drift from the scanner's reading of the same file, because they
    /// ARE the scanner's reading of it.
    public struct SourceFile: Equatable, Sendable {
        /// True for a file that has already been through somebody's tone map — every
        /// format in `PhotoFormats.rendered`. False for a camera raw.
        public var isRendered: Bool
        /// The capture ISO the file recorded, or nil when it recorded none. A file with
        /// no ISO keeps the flat wire defaults rather than being handed a guess: an
        /// invented noise profile is worse than an honest absence (docs/07 §4).
        public var iso: Int?

        public init(isRendered: Bool = false, iso: Int? = nil) {
            self.isRendered = isRendered
            self.iso = iso
        }
    }

    /// The recipe this file has the moment it is imported and before anybody touches it.
    ///
    /// THE ISO PROFILE IS FOR RAW ONLY, and the `else` below is load-bearing rather than
    /// tidy. A rendered file has an ISO in its EXIF like any other, and the camera has
    /// already denoised it — its pixels no longer follow any sensor noise model this
    /// table knows, so handing a JPEG shot at 12800 the Tier-1 profile for 12800 would
    /// smooth a picture that was smoothed once already.
    ///
    /// `pipelineVersion` is today's, and that is a decision rather than a default
    /// falling through. A reset document has no version-sensitive content in it at all —
    /// no `look.bw`, nothing — and it was written just now, by this build's writer, in
    /// this build's vocabulary, so saying so is the honest claim. Carrying an older
    /// recipe's version across instead would leave two photographs that render the same
    /// picture and are the same document holding two different `recipe_fp`s, and
    /// `recipe_fp` keys every preview and artifact in the cache: the reset frame could
    /// never share a cached render with a freshly imported sibling, and would re-render
    /// 45 megapixels to produce identical bytes. That is the `look.lut` defect
    /// `Recipe.renderIdentity` argues at length, one field over. It is also the same
    /// answer `LookSubset.applied` reaches by `max`: a version is raised when a writer
    /// this build owns rewrites the document, never quietly preserved.
    public static func asImported(from file: SourceFile) -> Recipe {
        var recipe = Recipe()
        if file.isRendered {
            recipe.look.render.preset = LookSubset.linearPresetName
        } else if let iso = file.iso {
            recipe.develop.denoise = ISODefaults.startingDenoise(forISO: Double(iso))
        }
        return recipe
    }

    /// Put this photograph back to how it was imported: the whole develop layer, the
    /// whole look layer, every mask and every mask folder.
    ///
    /// WHAT SURVIVES, and why the list is shorter than it looks. Rating, flag, colour
    /// label, keywords, album membership and stack membership are not in a `Recipe` at
    /// all — they live on the photo row in the catalog — so a reset cannot reach them
    /// however hard it tries, and that is the design rather than a lucky accident: the
    /// culling decisions are about the photograph and the recipe is about the picture.
    /// The app's undo step records only `PhotoEdit(recipe:)` for a reset, so undoing one
    /// cannot drag a star back with it either.
    ///
    /// THE CROP GOES, and that is the house's answer rather than a shrug. Lumen has no
    /// as-shot crop to keep: `Crop()` is the whole frame, nothing reads a crop out of
    /// raw metadata, and `develop.geometry.crop` is an edit like any other —
    /// `WorkspaceSection.frame`'s own Reset clears it, and a whole-photo Reset that
    /// spared it would be the one control in the app that resets everything except the
    /// thing you can see. A photographer who wants the framing and not the grade has
    /// the section Reset one row up.
    ///
    /// MASKS GO WITH IT. They are geometry in source coordinates plus a sub-recipe each,
    /// which is to say they are edits, and a "put it back" that left forty local
    /// adjustments standing would be answering a different question. Their brush strokes
    /// are content-addressed blobs and are not deleted by this — an undo restores the
    /// `strokesRef` and the painting is still on the other end of it.
    public mutating func resetToImported(from file: SourceFile) {
        self = Recipe.asImported(from: file)
    }

    /// Whether this photograph is still exactly as it was imported — the predicate a
    /// Reset affordance offers itself on, and the honest form of "is this edited".
    ///
    /// `pipelineVersion` is normalized away before the comparison, because the two
    /// questions are different ones. "What vocabulary is this document written in" is
    /// answered by the writer; "has the photographer changed anything" is answered by
    /// the values, and a pipeline bump must not mark every photograph in the library as
    /// edited on the morning it ships. `DevelopPanel.isRecipeModified` reads it the same
    /// way, and this is the two of them agreeing rather than a second judgement.
    public func isAsImported(from file: SourceFile) -> Bool {
        var baseline = Recipe.asImported(from: file)
        baseline.pipelineVersion = pipelineVersion
        return self == baseline
    }
}

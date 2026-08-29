// WorkspaceModification.swift
// Which workspace sections a recipe has actually touched.
//
// The accordion needs this twice, for two different jobs. The header dot answers "what
// did I change?" down a whole workspace at a glance — the question docs/00 says this app
// exists to answer. And the Simple register needs it for something stronger than
// convenience: hiding a section does NOT revert it, so Simple can be concealing live
// adjustments, and a photographer looking at a picture that does not match the controls
// in front of them has no way to find out why. `WorkspaceLayout.hiddenActiveIndicator`
// is the disclosure, and this is what feeds it.
//
// SEPARATE FROM `Workspace.swift` ON PURPOSE. That file is the arrangement — membership,
// order, the solo rule — and it states that it does not know how to read a recipe. This
// is the one place the two meet, so the coupling is a file a reader can find rather than
// a method hidden on an enum.
//
// It is also here rather than in the column because it is arithmetic over a value, and
// `Sources/LumenApp` compiles only on macOS: a mapping written there could not be
// checked by anything until CI, and a wrong field path would show up as a dot that never
// lights rather than as a build failure.

import Foundation

extension WorkspaceSection {

    /// The sections this recipe has moved off their defaults.
    ///
    /// `softProofEnabled` is passed in because soft proof is a VIEWING mode rather than
    /// part of the recipe — it belongs to the session, not to the photograph, and a
    /// recipe copied to another frame must not carry it.
    ///
    /// Deliberately compared against freshly constructed defaults rather than against a
    /// stored "clean" recipe: the default IS the type's initialiser, and any other
    /// source for it is a second place to keep in step.
    /// `denoiseDefault` is the photograph's OWN starting point, not the type's.
    /// `ISODefaults.startingDenoise(forISO:)` gives a high-ISO frame a non-zero denoise
    /// before anybody touches it, so comparing against `Denoise()` would light Detail on
    /// every RAW file ever opened — a dot that is always on is a dot that says nothing.
    /// nil is the right answer for a rendered file, which has no ISO profile to start
    /// from.
    public static func nonDefault(in recipe: Recipe,
                                  softProofEnabled: Bool = false,
                                  denoiseDefault: Denoise? = nil) -> Set<WorkspaceSection> {
        var out: Set<WorkspaceSection> = []
        let develop = recipe.develop
        let look = recipe.look

        // nil temp and tint mean "as shot", which is not an edit however far the camera
        // put them from neutral. `BasicPanel` reads it the same way.
        if develop.raw.temp != nil || develop.raw.tint != nil { out.insert(.whiteBalance) }

        // Zones folds inside Tone as a disclosure, so it lights Tone's dot rather than
        // one of its own — otherwise a photographer who used the zone sliders would see
        // a clean Tone header above them.
        if develop.tone != Tone() || develop.zones != Zones() { out.insert(.tone) }

        if develop.curve != CurveSet() { out.insert(.curve) }

        // PRESENCE AND DETAIL SHARE `develop.detail`, which is why this is field-level
        // rather than a struct comparison. Texture, Clarity and Dehaze are Presence's;
        // Capture Sharpening and Sharpening are Detail's; they live in one struct
        // because they are all "detail" to the engine and in two sections because they
        // are two jobs to a photographer. Comparing the struct would light both dots for
        // either edit.
        if develop.detail.texture != 0 || develop.detail.clarity != 0
            || develop.detail.dehaze != 0 || develop.color != ColorAdjust() {
            out.insert(.presence)
        }
        if develop.detail.capture != CaptureSharpen()
            || develop.detail.sharpen != ManualSharpen()
            || develop.denoise != (denoiseDefault ?? Denoise()) {
            out.insert(.detail)
        }

        // SPLIT, because Reset is per-section and these are two decisions. The frame
        // carries crop, straighten, flip and upright; Lens carries the corrections.
        // While they shared a section, resetting either cleared both.
        let geometry = develop.geometry
        if geometry.crop != Crop() || geometry.angle != 0 || geometry.flipH
            || geometry.upright != nil {
            out.insert(.frame)
        }
        if geometry.lens != LensCorrections() { out.insert(.optics) }

        // The vignette is a look; `develop.heal` is a photograph's healed spots. The
        // Retouch SECTION is gone (docs/30 Phase A — heal and clone are not implemented
        // and the section held nothing but a paragraph saying so), but the field is not:
        // a recipe from another build, or a sidecar written elsewhere, can carry spots.
        // The dot still lights for them, because the alternative is a photograph whose
        // recipe differs from its defaults with nothing on screen admitting it.
        if look.vignette != 0 || develop.heal != Heal() { out.insert(.effects) }

        if develop.mixer != Mixer() || !develop.pointColors.isEmpty || look.bw != nil {
            out.insert(.color)
        }
        if look.wheels != GradingWheels() || look.printerLights != PrinterLights()
            || look.primaries != Primaries() {
            out.insert(.grading)
        }
        if look.filmLab != nil { out.insert(.filmLab) }

        // The Display Transform is parked in Looks pending a section of its own (see
        // `Workspace.swift`, which leaves canonical rank 3 free for it), so a changed
        // render lights the section it is actually drawn in. The stored-but-unapplied
        // LUT counts too: it is a thing the photographer set, and a dot that ignored it
        // would be the panel disagreeing with the sidecar.
        if look.render != RenderParams() || look.lut != nil { out.insert(.looks) }

        if softProofEnabled { out.insert(.softProof) }

        // `.exportRecipes` is deliberately never here: export recipes are catalog-wide
        // settings, not this photograph's, so a dot would be answering a question about
        // some other frame.
        return out
    }
}

extension WorkspaceSection {

    /// Put this section back to its defaults.
    ///
    /// The accordion's header owns Reset now. It used to belong to whichever
    /// `DevelopSection` a panel happened to draw, which meant a section assembled out of
    /// several panels' pieces — Optics from Crop and Lens, Effects from Vignette, Grain
    /// and Retouch — had no single Reset at all, and one folded into a disclosure lost
    /// the one it had. `DevelopDisclosure` takes no reset, so Denoise and Zones both
    /// went dark the moment they were folded.
    ///
    /// Here rather than in the column for `nonDefault`'s reason: it is a mutation of a
    /// value, `Sources/LumenApp` compiles only on macOS, and the two have to agree.
    /// `WorkspaceModificationTests` asserts exactly that agreement — reset a section and
    /// it must stop reporting as modified — for every section, which is a property no
    /// hand-written pair of closures would keep true for long.
    ///
    /// `softProof` is deliberately absent: it is session state, not the photograph's,
    /// and the caller clears it. `exportRecipes` is absent because export recipes are
    /// catalog-wide, so resetting them from a photograph's panel would edit every other
    /// photograph's export too.
    public func reset(_ recipe: inout Recipe) {
        switch self {
        case .whiteBalance:
            // nil, not a number: nil MEANS as-shot, and writing the camera's own value
            // in as an explicit temperature would make the photograph permanently
            // "edited" at exactly the values it started from.
            recipe.develop.raw.temp = nil
            recipe.develop.raw.tint = nil

        case .tone:
            // Zones go with it. They are folded into this section as a disclosure, so a
            // photographer clicking Reset on Tone means the whole register — and leaving
            // them would put the section's dot back on the instant the reset finished.
            recipe.develop.tone = Tone()
            recipe.develop.zones = Zones()

        case .curve:
            recipe.develop.curve = CurveSet()

        case .presence:
            // Only the three fields Presence draws. `develop.detail` also holds Capture
            // Sharpening and Sharpening, which are Detail's — assigning the whole struct
            // would reset a section the photographer did not click on.
            recipe.develop.detail.texture = 0
            recipe.develop.detail.clarity = 0
            recipe.develop.detail.dehaze = 0
            recipe.develop.color = ColorAdjust()

        case .detail:
            // The other half of that split, and denoise with it — `Denoise()` rather
            // than the photograph's ISO starting point, because this function does not
            // know the ISO. The caller that does re-applies it; see `nonDefault`'s
            // `denoiseDefault`, which exists for the same asymmetry.
            recipe.develop.detail.capture = CaptureSharpen()
            recipe.develop.detail.sharpen = ManualSharpen()
            recipe.develop.denoise = Denoise()

        case .frame:
            // The frame only. `lens` is deliberately carried across — it is the other
            // section of this workspace and resetting a crop must not un-tick a lens
            // profile the photographer set separately.
            let lens = recipe.develop.geometry.lens
            recipe.develop.geometry = Geometry()
            recipe.develop.geometry.lens = lens

        case .optics:
            recipe.develop.geometry.lens = LensCorrections()

        case .looks:
            recipe.look.render = RenderParams()
            recipe.look.lut = nil

        case .color:
            recipe.develop.mixer = Mixer()
            recipe.develop.pointColors = []
            recipe.look.bw = nil

        case .grading:
            recipe.look.wheels = GradingWheels()
            recipe.look.printerLights = PrinterLights()
            recipe.look.primaries = Primaries()

        case .filmLab:
            recipe.look.filmLab = nil

        case .effects:
            recipe.look.vignette = 0
            recipe.develop.heal = Heal()

        case .softProof, .exportRecipes:
            break
        }
    }

    /// Whether this section's header should offer a Reset at all.
    ///
    /// A button that does nothing is the same lie as a caption promising a dead
    /// shortcut, and both of these sections have a real reason to have none: soft proof
    /// is cleared by the caller because it is not in the recipe, and export recipes
    /// belong to the catalog rather than to this photograph.
    public var resetsTheRecipe: Bool {
        switch self {
        case .softProof, .exportRecipes: return false
        default: return true
        }
    }
}

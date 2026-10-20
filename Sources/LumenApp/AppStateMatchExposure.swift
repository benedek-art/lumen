// AppStateMatchExposure.swift
// Match Total Exposures (Lightroom's Settings > Match Total Exposures), Photo menu
// ⌥⇧⌘M: the primary selection is the reference, and every other selected frame's
// Exposure slider is set so its capture settings plus its slider total the same as the
// reference's. The arithmetic is `ExposureMatch` in LumenCore, where it is tested.
//
// The EXIF is read off the files rather than from `PhotoItem`, which carries only ISO.
// `CaptureMetadataReader` reads the metadata block and stops, so a few hundred frames of
// a burst cost file opens, not decodes — and they happen off the main actor.

#if os(macOS)

import Foundation
import LumenCore
import LumenPipeline

extension AppState {

    func matchTotalExposures() {
        let targets = editTargets
        guard targets.count > 1, let reference = primarySelection,
              targets.contains(where: { $0.id == reference.id }) else {
            statusMessage = "Select two or more photos — exposures are matched to the active one"
            return
        }
        statusMessage = "Reading exposure settings…"
        let urls = targets.map(\.id)
        Task {
            let captures = await Task.detached(priority: .userInitiated) {
                var out: [URL: ExposureMatch.Capture] = [:]
                for url in urls {
                    // nil is a file that cannot be opened (an offline original); it is
                    // left out and the plan reports it as skipped.
                    if let metadata = CaptureMetadataReader.read(url: url) {
                        out[url] = ExposureMatch.Capture(metadata: metadata)
                    }
                }
                return out
            }.value
            await MainActor.run {
                self.applyExposureMatch(reference: reference, targets: targets,
                                        captures: captures)
            }
        }
    }

    /// Land the match as ONE named undo step. Separate from the read so the landing can
    /// be exercised without files.
    ///
    /// The sliders are read here, at landing, not when the command was given: the read
    /// is asynchronous, and matching against a value the photographer has since moved
    /// would undo their move. The gesture is closed first for the reason Auto Tone gives
    /// at `applyAutoToneSuggestions`.
    func applyExposureMatch(reference: PhotoItem, targets: [PhotoItem],
                            captures: [URL: ExposureMatch.Capture]) {
        // The photos as they stand now: one that left the library during the read (a
        // removal, a folder switch) gets no recipe written, and the rest carry their
        // current fields (`recipe(for:)` reads `iso` for an unedited frame's baseline).
        // The read is asynchronous: if the photographer moved the cursor or changed the
        // selection meanwhile, the match was for photos they are no longer pointing at.
        guard primarySelection?.id == reference.id,
              Set(editTargets.map(\.id)) == Set(targets.map(\.id)) else {
            statusMessage = "Match Total Exposures cancelled: the selection changed while "
                + "exposure settings were read"
            return
        }
        var current: [URL: PhotoItem] = [:]
        for photo in allPhotos { current[photo.id] = photo }
        guard let liveReference = current[reference.id] else {
            statusMessage = "Match Total Exposures: the active photo is no longer in the library"
            return
        }
        let liveTargets: [PhotoItem] = targets.compactMap { current[$0.id] }
        sliderGesture(active: false)
        let frames: [ExposureMatch.Frame<URL>] = liveTargets.map { photo in
            ExposureMatch.Frame(id: photo.id,
                                capture: captures[photo.id] ?? ExposureMatch.Capture(),
                                exposure: recipe(for: photo).develop.tone.exposure)
        }
        let plan = ExposureMatch.plan(referenceID: liveReference.id, frames: frames)
        let exposures = plan.exposures
        if !exposures.isEmpty {
            updateRecipe(label: "Match Total Exposures", targets: liveTargets) { photo, recipe in
                guard let exposure = exposures[photo.id] else { return }
                recipe.develop.tone.exposure = exposure
            }
        }
        statusMessage = ExposureMatch.summary(plan, referenceName: liveReference.filename)
    }
}

#endif

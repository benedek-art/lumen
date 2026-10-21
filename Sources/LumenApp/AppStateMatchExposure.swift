// AppStateMatchExposure.swift
// Match Total Exposures (Lightroom's Settings > Match Total Exposures), Photo menu
// ⌥⇧⌘M: the primary selection is the reference, and every other selected frame's
// Exposure slider is set so it renders as bright as the reference. Where a frame shares
// a view with the reference its brightness is MEASURED on that shared content (the same
// proxy Auto Tone reads, tone sliders at zero); otherwise the capture settings decide,
// which is Lightroom's rule. `ExposureMatch` in LumenCore says why and holds the tests.
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
        // Probes: every frame as it renders with its tone sliders at zero, so the
        // measurement is of the capture and not of an edit the match is about to move.
        var probes: [URL: Recipe] = [:]
        for photo in targets {
            var probe = recipe(for: photo)
            probe.develop.tone = Tone()
            probes[photo.id] = probe
        }
        let strokes = Dictionary(uniqueKeysWithValues: probes.map {
            ($0.key, strokeSets(for: $0.value))
        })
        let coordinator = renderCoordinator
        Task {
            var grids: [URL: ExposureMatch.LumaGrid] = [:]
            for url in urls {
                guard let probe = probes[url],
                      let proxy = await Self.measurementProxy(
                          url: url, recipe: probe, coordinator: coordinator,
                          strokeSets: strokes[url] ?? [:]) else { continue }
                grids[url] = await Task.detached(priority: .userInitiated) {
                    ExposureMatch.LumaGrid(encodedSRGB: proxy.bytes, width: proxy.width,
                                           height: proxy.height, channels: 4,
                                           transform: proxy.transform,
                                           displayWhite: proxy.transform.white)
                }.value
            }
            let referenceID = reference.id
            let referenceGrid = grids[referenceID]
            let measuredGrids = grids
            let measured = await Task.detached(priority: .userInitiated) {
                var out: [URL: Double] = [:]
                guard let referenceGrid else { return out }
                for (url, grid) in measuredGrids where url != referenceID {
                    if let overlap = ExposureMatch.measureOverlap(reference: referenceGrid,
                                                                  frame: grid) {
                        out[url] = overlap.stopsBrighter
                    }
                }
                return out
            }.value
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
                                        captures: captures, measured: measured)
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
                            captures: [URL: ExposureMatch.Capture],
                            measured: [URL: Double] = [:]) {
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
                                exposure: recipe(for: photo).develop.tone.exposure,
                                measuredStopsBrighter: measured[photo.id])
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

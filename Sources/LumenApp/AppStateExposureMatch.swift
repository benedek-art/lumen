// AppStateExposureMatch.swift
// Match Total Exposures (Settings menu): the app half of `ExposureMatch`, which owns
// the arithmetic and its tests. The primary photograph is the reference; every other
// selected photograph gets the Exposure slider that renders it as bright, from its
// shutter, ISO and aperture. One undo step for the whole selection.

#if os(macOS)
import SwiftUI
import LumenCore
import LumenPipeline

extension AppState {

    func matchTotalExposures() {
        guard let reference = primarySelection else { return }
        let targets = editTargets.filter { $0.id != reference.id }
        guard !targets.isEmpty else {
            statusMessage = "Select the frames to match, with the reference as the active one"
            return
        }
        let referenceExposure = recipe(for: reference).develop.tone.exposure
        let urls = [reference.id] + targets.map(\.id)
        Task { [weak self] in
            // ImageIO header reads, off the main actor: cheap per file, not per batch.
            let metadata = await Task.detached(priority: .userInitiated) {
                var read: [URL: PhotoMetadata] = [:]
                for url in urls {
                    if let m = CaptureMetadataReader.read(url: url) { read[url] = m }
                }
                return read
            }.value
            guard let self else { return }
            guard let ref = metadata[reference.id],
                  ExposureMatch.capturedStops(ref) != nil else {
                self.statusMessage = "The active photograph has no shutter, ISO and aperture to match from"
                return
            }
            var values: [URL: Double] = [:]
            for photo in targets {
                guard let m = metadata[photo.id],
                      let value = ExposureMatch.matchedExposure(
                        referenceExposure: referenceExposure, reference: ref, target: m)
                else { continue }
                values[photo.id] = value
            }
            let matched = targets.filter { values[$0.id] != nil }
            if !matched.isEmpty {
                self.updateRecipe(label: "Match Total Exposures", targets: matched) { photo, recipe in
                    if let value = values[photo.id] { recipe.develop.tone.exposure = value }
                }
            }
            let skipped = targets.count - matched.count
            self.statusMessage = skipped == 0
                ? "Matched \(matched.count) photographs"
                : "Matched \(matched.count), skipped \(skipped) without exposure metadata"
        }
    }
}
#endif

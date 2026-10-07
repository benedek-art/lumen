#if os(macOS)
import Foundation
import LumenCore
import LumenPipeline

/// A discrete ratio/swap request is all-or-none across the actual edit targets.
/// Geometry and file identity are snapshotted, not whole recipes: an unrelated
/// Exposure edit during the metadata read is preserved by the eventual crop-only write.
enum CropAspectEdit {
    enum Action { case ratio(Double), swap }
    struct Target: Sendable {
        let photo: URL
        let geometry: Geometry
        let source: SourceFileIdentity?
    }
    struct Refusal: Error { let message: String }
    private static let duplicateSelection = Refusal(message:
        "The selection contains duplicate photo entries. Reopen the source and try again. No selected photo was changed.")

    static func rangeDescription(size: CGSize?, degrees: Double) -> String {
        guard let size,
              let range = CropGeometry.representableAspectRange(sourceWidth: size.width,
                  sourceHeight: size.height, degrees: degrees) else {
            return "Source dimensions are unavailable. Wait for the photo to load, then try again."
        }
        return String(format: "At %.1f°, this %.0f × %.0f source allows approximately %.6g:1–%.6g:1 (width:height).",
                      degrees, size.width, size.height, range.lowerBound, range.upperBound)
            + " Both crop edges must remain at least 5% of the usable frame."
            + (range.lowerBound < 1.0 / 60 || range.upperBound > 60
               ? " Custom text entries are also limited to 1:60–60:1." : "")
    }

    static func plan(_ action: Action, targets: [Target], sizes: [URL: CGSize])
        -> Result<[URL: Crop], Refusal> {
        guard Set(targets.map(\.photo)).count == targets.count else { return .failure(duplicateSelection) }
        var crops: [URL: Crop] = [:]
        for target in targets {
            let size = sizes[target.photo]
            let crop: Crop?
            if let size {
                switch action {
                case .ratio(let ratio):
                    crop = CropGeometry.refitIfRepresentable(target.geometry.crop, aspect: ratio,
                        sourceWidth: size.width, sourceHeight: size.height, degrees: target.geometry.angle)
                case .swap:
                    crop = CropGeometry.swapIfRepresentable(target.geometry.crop,
                        sourceWidth: size.width, sourceHeight: size.height, degrees: target.geometry.angle)
                }
            } else { crop = nil }
            guard let crop else {
                return .failure(Refusal(message: "\(target.photo.lastPathComponent): "
                    + rangeDescription(size: size, degrees: target.geometry.angle)
                    + " Choose a ratio within that range. No selected photo was changed."))
            }
            crops[target.photo] = crop
        }
        return .success(crops)
    }

    /// Metadata reports un-oriented dimensions; orientations 5–8 exchange the axes.
    /// No thumbnail dimensions and no guessed 3:2 fallback authorize an edit.
    static func sourceSize(metadata: PhotoMetadata?) -> CGSize? {
        guard let metadata, let w = metadata.width, let h = metadata.height, w > 0, h > 0 else { return nil }
        if let orientation = metadata.orientation, !(1...8).contains(orientation) { return nil }
        return (5...8).contains(metadata.orientation ?? 1)
            ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    static func readSizes(_ targets: [Target],
                          readMetadata: @escaping @Sendable (URL) -> PhotoMetadata?
                            = { CaptureMetadataReader.read(url: $0) }) async -> [URL: CGSize] {
        let worker = Task.detached(priority: .userInitiated) {
            var sizes: [URL: CGSize] = [:]
            for target in targets {
                guard !Task.isCancelled else { break }
                guard let identity = target.source,
                      SourceFileIdentity.read(target.photo) == identity,
                      let size = sourceSize(metadata: readMetadata(target.photo)),
                      !Task.isCancelled,
                      SourceFileIdentity.read(target.photo) == identity else { continue }
                sizes[target.photo] = size
            }
            return sizes
        }
        // Detached tasks do not inherit cancellation. This stops between files;
        // an ImageIO metadata read already in progress remains non-interruptible.
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func stillCurrent(_ snapshot: [Target], current: [Target]) -> Bool {
        guard snapshot.count == current.count,
              Set(snapshot.map(\.photo)).count == snapshot.count,
              Set(current.map(\.photo)).count == current.count else { return false }
        let now = Dictionary(uniqueKeysWithValues: current.map { ($0.photo, $0) })
        return snapshot.allSatisfy { before in
            guard let after = now[before.photo], before.source != nil else { return false }
            return before.geometry == after.geometry && before.source == after.source
        }
    }

    @MainActor
    static func apply(_ action: Action, in state: AppState,
                      loadSizes: ([Target]) async -> [URL: CGSize] = { await readSizes($0) })
        async -> Result<Void, Refusal> {
        let photos = state.editTargets
        let primary = state.primarySelection?.id
        guard !photos.isEmpty else { return .failure(Refusal(message: "Select a photo first.")) }
        guard Set(photos.map(\.id)).count == photos.count else { return .failure(duplicateSelection) }
        func snapshot(_ photos: [PhotoItem]) -> [Target] {
            photos.map { Target(photo: $0.id, geometry: state.recipe(for: $0).develop.geometry,
                                source: SourceFileIdentity.read($0.id)) }
        }
        let before = snapshot(photos)
        if let unreadable = before.first(where: { $0.source == nil }) {
            return .failure(Refusal(message: "\(unreadable.photo.lastPathComponent): source unavailable. "
                + "Restore access to the photo and try again. No selected photo was changed."))
        }
        let sizes = await loadSizes(before)
        guard !Task.isCancelled, state.primarySelection?.id == primary,
              stillCurrent(before, current: snapshot(state.editTargets)) else {
            return .failure(Refusal(message: "The selection, framing, or source changed while checking the ratio. Try again. No selected photo was changed."))
        }
        // Do not substitute primaryFrameSize here: for RAW it may still be sensor-
        // oriented until a whole-frame delivery reconciles it. Every target uses its
        // own explicitly oriented header, including the primary.
        switch plan(action, targets: before, sizes: sizes) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let crops):
            let key: String
            switch action { case .ratio: key = "geometry.crop.aspect"; case .swap: key = "geometry.crop.orientation" }
            state.updateRecipe(coalescingKey: key, targets: photos) { photo, recipe in
                if let crop = crops[photo.id] { recipe.develop.geometry.crop = crop }
            }
            return .success(())
        }
    }
}
#endif

#if os(macOS)
import Foundation
import LumenCore

@MainActor
final class PhotoSnapshotsModel: ObservableObject {
    @Published var rows: [EditRow] = []
    @Published var error: String?
    @Published var busy = false
    var epoch = 0
}

extension AppState {
    func refreshPhotoSnapshots() {
        let model = photoSnapshots
        model.epoch += 1
        let epoch = model.epoch
        model.rows = []
        model.error = nil
        guard let photoID = primarySelection?.catalogID, let catalog else { return }
        Task { [weak self] in
            do {
                let rows = try await catalog.photoSnapshots(photoID: photoID)
                guard let self, self.photoSnapshots.epoch == epoch,
                      self.primarySelection?.catalogID == photoID else { return }
                self.photoSnapshots.rows = rows
            } catch {
                guard let self, self.photoSnapshots.epoch == epoch else { return }
                self.photoSnapshots.error = error.localizedDescription
            }
        }
    }

    func createPhotoSnapshot(named name: String) async {
        guard !photoSnapshots.busy, let photo = primarySelection,
              let photoID = photo.catalogID, let catalog else { return }
        sliderGesture(active: false)
        let recipe = recipe(for: photo)
        photoSnapshots.error = nil
        photoSnapshots.busy = true
        defer { photoSnapshots.busy = false }
        do {
            try await catalog.createPhotoSnapshot(recipe: recipe, photoID: photoID, name: name)
            refreshPhotoSnapshots()
        } catch { reportPhotoSnapshotFailure(error.localizedDescription, photoID: photoID) }
    }

    func restorePhotoSnapshot(_ snapshot: EditRow) async {
        guard !photoSnapshots.busy, let photo = primarySelection,
              photo.catalogID == snapshot.photoID, let catalog else { return }
        sliderGesture(active: false)
        let before = recipe(for: photo)
        photoSnapshots.error = nil
        photoSnapshots.busy = true
        defer { photoSnapshots.busy = false }
        do {
            let restored = try await catalog.photoSnapshotRecipe(id: snapshot.id, photoID: snapshot.photoID)
            guard primarySelection?.id == photo.id, primarySelection?.catalogID == snapshot.photoID,
                  recipe(for: photo) == before else {
                reportPhotoSnapshotFailure("The photograph or its edits changed while loading the snapshot. Restore again when ready.", photoID: snapshot.photoID)
                return
            }
            loadStrokeSets(for: restored)
            updateRecipe(label: "Restore Snapshot", targets: [photo]) { _, recipe in recipe = restored }
        } catch { reportPhotoSnapshotFailure(error.localizedDescription, photoID: snapshot.photoID) }
    }

    private func reportPhotoSnapshotFailure(_ message: String, photoID: Int64) {
        if primarySelection?.catalogID == photoID { photoSnapshots.error = message }
        else { statusMessage = "Snapshot operation for the previously selected photograph: " + message }
    }

    func deletePhotoSnapshot(_ snapshot: EditRow) async {
        guard !photoSnapshots.busy, primarySelection?.catalogID == snapshot.photoID,
              let catalog else { return }
        photoSnapshots.error = nil
        photoSnapshots.busy = true
        defer { photoSnapshots.busy = false }
        do {
            try await catalog.deletePhotoSnapshot(id: snapshot.id, photoID: snapshot.photoID)
            refreshPhotoSnapshots()
        } catch { reportPhotoSnapshotFailure(error.localizedDescription, photoID: snapshot.photoID) }
    }
}
#endif

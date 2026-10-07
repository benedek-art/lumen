#if os(macOS)
import SwiftUI
import LumenCore

struct PhotoSnapshotsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var model: PhotoSnapshotsModel
    @State private var name = ""
    @State private var pendingDelete: EditRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Named snapshots").font(.lumenBodyStrong)
            HStack {
                TextField("Snapshot name", text: $name)
                    .accessibilityLabel("Snapshot name")
                Button("Save") {
                    let captured = name
                    Task {
                        await state.createPhotoSnapshot(named: captured)
                        if model.error == nil { name = "" }
                    }
                }
                .disabled(model.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || state.primarySelection?.catalogID == nil)
                .help("Save this photograph's current settings in the catalog")
            }
            if let error = model.error { DevelopNote(error, prominent: true) }
            ForEach(model.rows, id: \.id) { snapshot in
                HStack {
                    Button(snapshot.name ?? "Snapshot") {
                        Task { await state.restorePhotoSnapshot(snapshot) }
                    }
                    .buttonStyle(.plain)
                    .help("Restore these settings on this photograph; Undo restores the previous edit")
                    Spacer()
                    Button { pendingDelete = snapshot } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete snapshot \(snapshot.name ?? "Snapshot")")
                }
                .disabled(model.busy)
            }
            DevelopNote("Snapshots stay with this photograph across launches and catalog backups.")
        }
        .padding(.top, 8)
        .confirmationDialog("Delete this named snapshot?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete snapshot", role: .destructive) {
                    guard let snapshot = pendingDelete else { return }
                    pendingDelete = nil
                    Task { await state.deletePhotoSnapshot(snapshot) }
                }
        } message: { Text("The current edit and other snapshots are kept.") }
        .onChange(of: state.primarySelection?.id) { _, _ in name = ""; pendingDelete = nil }
    }
}
#endif

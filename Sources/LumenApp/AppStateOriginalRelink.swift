#if os(macOS)
import AppKit
import Foundation
import LumenCore

extension AppState {
    /// Explicit selection and review; no automatic search or guessed replacement.
    func chooseOriginalRelink() {
        guard let catalog, !isExporting, !isScanning, !isRelinkingOriginal else {
            statusMessage = "Finish the active export, scan or relink before relinking an original."
            return
        }
        sliderGesture(active: false)
        isRelinkingOriginal = true
        statusMessage = "Checking missing originals…"
        Task {
            defer { isRelinkingOriginal = false }
            do {
                let targets = try await catalog.missingOriginals(includePhotoID: primarySelection?.catalogID)
                guard !targets.isEmpty else { statusMessage = "No catalog originals are confirmed missing. Rescan their folder first."; return }
                let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 520, height: 28))
                picker.addItems(withTitles: targets.map { $0.original.path })
                let selection = NSAlert()
                selection.messageText = "Select the missing original"
                selection.informativeText = "Relinking keeps this catalog photo's edits and memberships. Choose its replacement explicitly."
                selection.accessoryView = picker
                selection.addButton(withTitle: "Choose File…")
                selection.addButton(withTitle: "Cancel")
                guard selection.runModal() == .alertFirstButtonReturn else { return }
                let target = targets[picker.indexOfSelectedItem]
                let panel = NSOpenPanel()
                panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                panel.title = "Locate \(target.original.lastPathComponent)"
                panel.message = "Choose the same original. Its stored size and signature must match."
                guard panel.runModal() == .OK, let candidateURL = panel.url else { return }
                statusMessage = "Checking the chosen original’s stored identity…"
                let prepared = try await catalog.prepareOriginalRelink(photoID: target.photoID, candidateURL: candidateURL)
                let review = NSAlert()
                review.messageText = "Relink this original?"
                let proof = target.fullHash?.isEmpty == false
                    ? "The stored full-file checksum also matches."
                    : "This prefix signature is an identity hint; it does not prove full-file byte equality."
                review.informativeText = "Missing: \(target.original.path)\nChosen: \(prepared.candidate.url.path)\n\nStored size (\(target.fileSize) bytes) and signature match. \(proof)\nCatalog edits are retained; conflicting sidecars are refused."
                review.addButton(withTitle: "Relink")
                review.addButton(withTitle: "Cancel")
                guard review.runModal() == .alertFirstButtonReturn else { return }
                statusMessage = "Relinking the original…"
                try await relinkOriginal(prepared)
            } catch { statusMessage = "Original was not relinked: \(error.localizedDescription)" }
        }
    }

    func relinkOriginal(_ preparation: CatalogService.OriginalRelinkPreparation) async throws {
        guard let catalog, !isExporting else { throw OriginalRelinkError.changedMapping }
        sliderGesture(active: false)
        let completion = try await catalog.commitOriginalRelink(preparation)
        applyOriginalRelink(completion)
        statusMessage = "Relinked \(completion.result.original.lastPathComponent) to \(completion.result.destination.path); catalog edits retained"
    }
}
#endif

// AppStateQuickExport.swift
// Export with Previous (⌥⇧⌘E), the remembered export folder, and the post-export
// reveal in Finder. The decisions are `QuickExport` in LumenCore; this file is the
// UserDefaults, panel and NSWorkspace side of them.
//
// Three hooks reach in from elsewhere, one line each: `chooseExportDestination` starts
// its panel in `lastExportDirectoryURL`, `export(to:)` calls `noteExportFinished` in its
// closing main-actor hop, and the Export menu calls the two verbs below.

#if os(macOS)
import AppKit
import Foundation
import LumenCore
import SwiftUI

extension AppState {

    /// The last run's memory, or nil before the first export on this machine.
    var lastExport: LastExport? {
        LastExport.decode(UserDefaults.standard.data(forKey: QuickExport.lastExportDefaultsKey))
    }

    /// Where the folder panel opens: the last export folder, while it still exists.
    var lastExportDirectoryURL: URL? {
        guard let path = lastExport?.directoryPath,
              Self.isDirectory(URL(fileURLWithPath: path)) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// ⌥⇧⌘E: the selection, the checked recipes, the last folder — no sheet, no panel.
    /// Anything only the sheet can fix (no folder yet, folder gone, no recipe checked,
    /// a recipe's Contact invalid) opens the sheet with the reason in the status bar.
    func exportWithPrevious() {
        let targetCount = selectedPhotos.isEmpty
            ? (primarySelection == nil ? 0 : 1)
            : selectedPhotos.count
        let plan = QuickExport.plan(last: lastExport, recipes: exportRecipes,
                                    targetCount: targetCount, isExporting: isExporting,
                                    directoryExists: { Self.isDirectory(URL(fileURLWithPath: $0)) })
        switch plan {
        case .refuse(let message):
            statusMessage = message
        case .openSheet(let message):
            statusMessage = message
            showExportSheet = true
        case .run(let directory, let message):
            // The sheet's Export button refuses an invalid Contact block; this path has
            // no button, so it checks the same thing and sends the photographer there.
            guard ExportContactEligibility(recipes: exportRecipes).canExport else {
                statusMessage = "A checked recipe's Contact needs fixing before export"
                showExportSheet = true
                return
            }
            statusMessage = message
            export(to: URL(fileURLWithPath: directory, isDirectory: true))
        }
    }

    /// Export ▸ Show Last Export in Finder.
    func revealLastExport() {
        guard let last = lastExport else {
            statusMessage = "Nothing has been exported yet"
            return
        }
        let paths = QuickExport.existingRevealTargets(last, exists: {
            FileManager.default.fileExists(atPath: $0)
        })
        guard !paths.isEmpty else {
            statusMessage = "The last export is no longer on disk"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
    }

    /// Called once at the end of every batch, on the main actor, after the status line
    /// is written. Remembers the run for ⌥⇧⌘E and the reveal command, and reveals the
    /// delivery when the sheet's "Show in Finder when done" is on.
    func noteExportFinished(directory: URL, recipes: [ExportRecipe], report: OperationReport) {
        let memory = LastExport(directory: directory.path, recipes: recipes, report: report)
        if let data = memory.encoded() {
            UserDefaults.standard.set(data, forKey: QuickExport.lastExportDefaultsKey)
        }
        guard UserDefaults.standard.bool(forKey: QuickExport.revealWhenDoneDefaultsKey),
              memory.deliveredCount > 0 else { return }
        revealLastExport()
    }
}

/// The export sheet's footer checkbox for the post-export action. Global rather than per
/// recipe — one run writes every checked recipe and should reveal once.
struct ExportRevealWhenDoneOption: View {
    @AppStorage(QuickExport.revealWhenDoneDefaultsKey) private var revealWhenDone = false

    var body: some View {
        HStack(spacing: 6) {
            LumenCheckbox(isOn: $revealWhenDone)
            Text("Show in Finder when done")
                .font(.lumenBody)
                .foregroundStyle(Lumen.secondaryText)
                .onTapGesture { revealWhenDone.toggle() }
        }
        .help("Reveal the exported files in Finder when the batch finishes. "
              + "Export ▸ Show Last Export in Finder does it on demand.")
    }
}
#endif

// AppStateDevelopPresets.swift
// Develop presets: save the ticked groups of the photo under the cursor under a name,
// apply one to the selection, rename, delete, import and export.
//
// What a preset holds and how it lands are `DevelopPreset` and `DevelopPresetLibrary`
// in LumenCore, where `DevelopPresetTests` covers them; this file is the doors. Apply is
// one `updateRecipe` call, so one named undo step across the whole selection, and it
// goes through the same `adoptingSettings(from:groups:)` as Sync Settings.
//
// The library is per Mac, not per catalog (`DevelopPresetLibrary`'s header), so it lives
// on `DevelopPresetShelf` rather than on `AppState`, and saving or deleting a preset is
// not an undoable edit — the status bar says so, as for Saved Looks.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import SwiftUI
import UniformTypeIdentifiers

/// The loaded library and its file. Observed by the Photo menu's preset list, the
/// manage sheet and the ⌘K palette.
///
/// NOT `@MainActor` on the type, for `KeywordEntry`'s reason: a `static let` singleton
/// of an actor-isolated class cannot be built from a view's property initialiser. Every
/// caller is a menu action, a sheet or `AppState`, all on the main actor already.
final class DevelopPresetShelf: ObservableObject {

    static let shared = DevelopPresetShelf()

    @Published private(set) var library = DevelopPresetLibrary()

    /// Nil when there is nowhere safe to write — no Application Support folder, or an
    /// unreadable library that could not be moved aside. Saving then refuses.
    private let presetFile: DevelopPresetStore?

    /// Something to tell the photographer about the load, said once by the first
    /// preset action (`AppState.takePresetLoadProblem`).
    private var loadProblem: String?

    private init() {
        // Worked out in locals and assigned once: `library` is wrapper-backed, so it
        // cannot be set before `presetFile` is.
        var loaded = DevelopPresetLibrary()
        var writable: DevelopPresetStore?
        var problem: String?
        if let directory = try? AppState.applicationSupportCatalogDirectory() {
            let candidate = DevelopPresetStore(directory: directory)
            do {
                loaded = try candidate.load()
                writable = candidate
            } catch {
                // Never written over: moved aside first, or saving is switched off.
                if let moved = candidate.setAsideUnreadable() {
                    writable = candidate
                    problem = "The preset library could not be read and was kept as "
                        + moved.lastPathComponent
                } else {
                    problem = "The preset library could not be read; presets will not "
                        + "be saved this session"
                }
            }
        } else {
            problem = "Develop presets are unavailable: no Application Support folder"
        }
        presetFile = writable
        loadProblem = problem
        library = loaded
    }

    var presets: [DevelopPreset] { library.presets }

    /// The load message, once.
    func takeLoadProblem() -> String? {
        defer { loadProblem = nil }
        return loadProblem
    }

    /// Write `next` and publish it. Returns the status-bar sentence when it failed, in
    /// which case the library on screen stays what is on disk.
    func commit(_ next: DevelopPresetLibrary) -> String? {
        guard let presetFile else {
            return "Presets cannot be saved this session"
        }
        do {
            try presetFile.save(next)
        } catch {
            return "Presets could not be saved: \(error.localizedDescription)"
        }
        library = next
        return nil
    }
}

extension AppState {

    /// The UserDefaults key for the save sheet's last ticks. Kept apart from Copy/Sync
    /// Settings' own memory: a preset's groups and a sync's are different answers.
    static let developPresetGroupsDefaultsKey = "developPresets.groups"

    var rememberedDevelopPresetGroups: Set<SettingsGroup> {
        get {
            guard let stored = UserDefaults.standard.string(
                forKey: AppState.developPresetGroupsDefaultsKey) else {
                return DevelopPreset.defaultGroups
            }
            return SettingsGroup.fromStorageString(stored)
                .intersection(DevelopPreset.offeredGroups)
        }
        set {
            UserDefaults.standard.set(SettingsGroup.storageString(newValue),
                                      forKey: AppState.developPresetGroupsDefaultsKey)
        }
    }

    /// Says the shelf's load problem, if there is one still unsaid. True when it did.
    @discardableResult
    func takePresetLoadProblem() -> Bool {
        guard let problem = DevelopPresetShelf.shared.takeLoadProblem() else { return false }
        statusMessage = problem
        return true
    }

    /// Save `groups` of the photo under the cursor as a preset called `name`; a taken
    /// name is replaced (the sheet says "Replace" first).
    func saveDevelopPreset(named name: String, groups: Set<SettingsGroup>) {
        guard let photo = primarySelection else {
            statusMessage = "Select the photo whose settings the preset should keep"
            return
        }
        guard let preset = DevelopPreset.captured(named: name, from: recipe(for: photo),
                                                  groups: groups) else {
            statusMessage = LookSubset.normalizedName(name) == nil
                ? "A preset needs a name"
                : "Tick at least one group for the preset to keep"
            return
        }
        let shelf = DevelopPresetShelf.shared
        var library = shelf.library
        let replaced = library.save(preset)
        if let problem = shelf.commit(library) {
            statusMessage = problem
            return
        }
        statusMessage = "Preset \"\(preset.name)\" " + (replaced ? "updated" : "saved")
            + ": " + preset.summary
    }

    /// Put a preset on the edit targets: its groups only, one undo step.
    func applyDevelopPreset(_ preset: DevelopPreset) {
        let targets = editTargets
        guard !targets.isEmpty else {
            statusMessage = "Select the photos to apply \"\(preset.name)\" to"
            return
        }
        updateRecipe(label: "Apply Preset") { recipe in
            recipe = preset.applied(to: recipe)
        }
        statusMessage = targets.count == 1
            ? "Applied preset \"\(preset.name)\""
            : "Applied preset \"\(preset.name)\" to \(targets.count) photos"
    }

    func renameDevelopPreset(_ preset: DevelopPreset, to name: String) {
        let shelf = DevelopPresetShelf.shared
        var library = shelf.library
        do {
            try library.renamePreset(preset.name, to: name)
        } catch DevelopPresetLibrary.EditError.nameTaken(let taken) {
            statusMessage = "There is already a preset called \"\(taken)\""
            return
        } catch {
            return       // a blank name, or a preset deleted meanwhile: nothing to say
        }
        if let problem = shelf.commit(library) { statusMessage = problem }
    }

    func deleteDevelopPreset(_ preset: DevelopPreset) {
        let shelf = DevelopPresetShelf.shared
        var library = shelf.library
        guard library.delete(named: preset.name) else { return }
        if let problem = shelf.commit(library) {
            statusMessage = problem
            return
        }
        // Said out loud: deleting a preset is not undoable, and photos keep their settings.
        statusMessage = "Deleted preset \"\(preset.name)\" — edited photos keep their settings"
    }

    // MARK: Files

    /// The types the panels offer: `.lumenpreset`, and plain JSON for a renamed file.
    private var developPresetFileTypes: [UTType] {
        var types: [UTType] = [.json]
        if let own = UTType(filenameExtension: DevelopPreset.fileExtension) {
            types.insert(own, at: 0)
        }
        return types
    }

    func exportDevelopPreset(_ preset: DevelopPreset) {
        writeDevelopPresetFile(name: preset.suggestedFileName, count: 1) {
            try preset.fileData()
        }
    }

    func exportAllDevelopPresets() {
        let presets = DevelopPresetShelf.shared.presets
        guard !presets.isEmpty else {
            statusMessage = "No presets to export yet"
            return
        }
        writeDevelopPresetFile(name: "Lumen Presets." + DevelopPreset.fileExtension,
                               count: presets.count) {
            try DevelopPreset.libraryData(presets)
        }
    }

    private func writeDevelopPresetFile(name: String, count: Int,
                                        _ makeData: () throws -> Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try makeData().write(to: url, options: .atomic)
            statusMessage = count == 1
                ? "Exported preset to \(url.lastPathComponent)"
                : "Exported \(count) presets to \(url.lastPathComponent)"
        } catch {
            statusMessage = "Could not write \(url.lastPathComponent): "
                + error.localizedDescription
        }
    }

    /// Choose preset files and add what they hold. Nothing is replaced: a clash with
    /// different settings arrives as "Name 2" (`DevelopPresetLibrary.importing`).
    func importDevelopPresets() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = developPresetFileTypes
        panel.message = "Choose Lumen develop preset files"
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        var incoming: [DevelopPreset] = []
        var refused: [String] = []
        for url in panel.urls {
            do {
                let data = try Data(contentsOf: url)
                incoming.append(contentsOf: try DevelopPreset.presets(fromFileData: data))
            } catch let failure as DevelopPresetFileError {
                refused.append("\(url.lastPathComponent) \(failure.message)")
            } catch {
                refused.append("\(url.lastPathComponent) could not be read")
            }
        }
        let shelf = DevelopPresetShelf.shared
        var library = shelf.library
        let result = library.importing(incoming)
        if !result.added.isEmpty, let problem = shelf.commit(library) {
            statusMessage = problem
            return
        }
        var parts: [String] = []
        if !result.added.isEmpty {
            parts.append(result.added.count == 1
                         ? "Imported preset \"\(result.added[0])\""
                         : "Imported \(result.added.count) presets")
        }
        if !result.unchanged.isEmpty {
            parts.append("\(result.unchanged.count) already here")
        }
        if let first = refused.first {
            parts.append(refused.count == 1 ? first
                         : "\(first) (and \(refused.count - 1) more refused)")
        }
        statusMessage = parts.isEmpty ? "No presets found" : parts.joined(separator: " · ")
    }
}

#endif

// AppStateSelectiveSettings.swift
// Sync Settings and Paste from Previous: the group-filtered paste without the clipboard.
//
// Both carry only the groups last ticked in the Copy Settings… / Sync Settings… sheet
// (`SettingsGroup`, remembered in UserDefaults), through `Recipe.adoptingSettings(from:
// groups:)` — the LumenCore rule `SettingsSubsetTests` covers. Neither touches the
// clipboard, and each is one `updateRecipe` call, so one named undo step however many
// photographs it lands on.

#if os(macOS)

import Foundation
import LumenCore

extension AppState {

    /// The UserDefaults key for the last ticked groups. `SettingsGroup.storageString`
    /// owns the format.
    static let settingsGroupsDefaultsKey = "selectiveSettings.groups"

    /// The groups the sheet opens with and the no-dialog commands carry.
    var rememberedSettingsGroups: Set<SettingsGroup> {
        get {
            SettingsGroup.fromStorageString(
                UserDefaults.standard.string(forKey: AppState.settingsGroupsDefaultsKey))
        }
        set {
            UserDefaults.standard.set(SettingsGroup.storageString(newValue),
                                      forKey: AppState.settingsGroupsDefaultsKey)
        }
    }

    /// The photographs Sync writes to: the selection less the photo under the cursor,
    /// which is the source. Empty unless two or more are selected.
    var syncTargets: [PhotoItem] {
        guard selection.count > 1, let source = primarySelection else { return [] }
        return selectedPhotos.filter { $0.id != source.id }
    }

    /// Sync Settings: `groups` from the photo under the cursor onto the rest of the
    /// selection.
    func syncSettings(groups: Set<SettingsGroup>) {
        guard let sourcePhoto = primarySelection else { return }
        let targets = syncTargets
        guard !targets.isEmpty else {
            statusMessage = "Select two or more photos to sync — the one under the "
                + "cursor is the source"
            return
        }
        guard !groups.isEmpty else {
            statusMessage = "Nothing to sync — tick a group in Sync Settings…"
            return
        }
        let source = recipe(for: sourcePhoto)
        updateRecipe(label: "Sync Settings", targets: targets) { _, recipe in
            recipe = recipe.adoptingSettings(from: source, groups: groups)
        }
        statusMessage = "Synced \(SettingsGroup.summary(groups)) to \(targets.count) photo"
            + (targets.count == 1 ? "" : "s")
    }

    /// Paste from Previous: the remembered groups from the photo the cursor was on
    /// before this one, onto the edit targets (less that photo, if it is among them).
    func pasteFromPrevious() {
        let targets = editTargets
        guard let url = previousPhoto.source(writingTo: targets.map { $0.id }) else {
            statusMessage = "No previous photo to paste from yet"
            return
        }
        guard let sourcePhoto = allPhotos.first(where: { $0.id == url }) else {
            statusMessage = "The previous photo is no longer in this source"
            return
        }
        let groups = rememberedSettingsGroups
        guard !groups.isEmpty else {
            statusMessage = "Nothing to paste — tick a group in Copy Settings…"
            return
        }
        let source = recipe(for: sourcePhoto)
        let writes = targets.filter { $0.id != url }
        updateRecipe(label: "Paste from Previous", targets: writes) { _, recipe in
            recipe = recipe.adoptingSettings(from: source, groups: groups)
        }
        statusMessage = "Pasted \(SettingsGroup.summary(groups)) from "
            + url.lastPathComponent
    }
}

#endif

// DevelopPresetSheets.swift
// Save Preset… (⇧⌘N, Lightroom's New Preset), Manage Presets…, and the Photo menu's
// Develop Presets submenu that applies one to the selection.
//
// The save sheet is `SettingsSubsetSheet`'s checkbox list with a name field on top,
// offering `DevelopPreset.offeredGroups` — no crop, masks or spot removal — and opening
// on the last ticks. A taken name turns the button into "Replace", as Saved Looks do.

#if os(macOS)

import LumenCore
import SwiftUI

struct SaveDevelopPresetSheet: View {

    @EnvironmentObject var state: AppState
    @ObservedObject private var shelf = DevelopPresetShelf.shared
    @State private var name: String = ""
    @State private var chosen: Set<SettingsGroup> = []
    @State private var loaded = false

    private var cleanName: String? { LookSubset.normalizedName(name) }

    private var isReplace: Bool {
        guard let cleanName else { return false }
        return shelf.library.preset(named: cleanName) != nil
    }

    private var canSave: Bool {
        cleanName != nil && !chosen.isEmpty && state.primarySelection != nil
    }

    private var subtitle: String {
        let source = state.primarySelection?.id.lastPathComponent ?? "no photo"
        return "From \(source). Apply it later from Photo ▸ Develop Presets or ⌘K."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Develop Preset")
                    .font(.lumenTitle)
                    .foregroundStyle(Lumen.primaryText)
                Text(subtitle)
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Preset name, e.g. Soccer ISO 6400", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.lumenBody)
                .onSubmit { if canSave { confirm() } }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(DevelopPreset.offeredGroups, id: \.self) { group in
                    HStack(spacing: 7) {
                        LumenCheckbox(isOn: binding(for: group))
                        Text(group.title)
                            .font(.lumenBody)
                            .foregroundStyle(Lumen.primaryText)
                            .onTapGesture { toggle(group) }
                        Spacer()
                    }
                }
            }
            Text("Crop, masks and spot removal belong to one frame and are never saved.")
                .font(.lumenCaption)
                .foregroundStyle(Lumen.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Lumen.separator)
            HStack(spacing: 8) {
                Button("All") { chosen = Set(DevelopPreset.offeredGroups) }
                Button("None") { chosen = [] }
                Spacer()
                Button("Cancel") { state.activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(isReplace ? "Replace" : "Save") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Lumen.panelBackground)
        .onAppear {
            guard !loaded else { return }
            chosen = state.rememberedDevelopPresetGroups
            loaded = true
            state.takePresetLoadProblem()
        }
    }

    private func binding(for group: SettingsGroup) -> Binding<Bool> {
        Binding(get: { chosen.contains(group) },
                set: { isOn in
                    if isOn { chosen.insert(group) } else { chosen.remove(group) }
                })
    }

    private func toggle(_ group: SettingsGroup) {
        if chosen.contains(group) { chosen.remove(group) } else { chosen.insert(group) }
    }

    private func confirm() {
        let groups = chosen
        let typed = name
        state.rememberedDevelopPresetGroups = groups
        state.activeSheet = nil
        state.saveDevelopPreset(named: typed, groups: groups)
    }
}

/// Every preset with Apply, Rename, Export and Delete, plus Import and Export All.
struct ManageDevelopPresetsSheet: View {

    @EnvironmentObject var state: AppState
    @ObservedObject private var shelf = DevelopPresetShelf.shared
    /// The preset being renamed, by name, and the draft.
    @State private var renaming: String?
    @State private var draft: String = ""
    /// The preset whose Delete is armed; a second click deletes.
    @State private var pendingDelete: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Develop Presets")
                    .font(.lumenTitle)
                    .foregroundStyle(Lumen.primaryText)
                Text("Apply puts a preset's groups on every selected photo — one undo step.")
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if shelf.presets.isEmpty {
                Text("No presets yet. Edit a photo, then Photo ▸ Develop Presets ▸ "
                     + "New Preset… (⇧⌘N).")
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shelf.presets, id: \.name) { preset in
                            row(preset)
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 320)
            }
            Divider().overlay(Lumen.separator)
            HStack(spacing: 8) {
                Button("Import…") { state.importDevelopPresets() }
                Button("Export All…") { state.exportAllDevelopPresets() }
                    .disabled(shelf.presets.isEmpty)
                Spacer()
                Button("Done") { state.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 500)
        .background(Lumen.panelBackground)
        .onAppear { state.takePresetLoadProblem() }
    }

    @ViewBuilder
    private func row(_ preset: DevelopPreset) -> some View {
        HStack(spacing: 8) {
            if renaming == preset.name {
                TextField(preset.name, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.lumenBody)
                    .onSubmit {
                        state.renameDevelopPreset(preset, to: draft)
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.lumenLead)
                        .foregroundStyle(Lumen.primaryText)
                    Text(preset.summary)
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.secondaryText)
                }
            }
            Spacer()
            if pendingDelete == preset.name {
                Button("Delete \"\(preset.name)\"") {
                    pendingDelete = nil
                    state.deleteDevelopPreset(preset)
                }
                Button("Keep") { pendingDelete = nil }
            } else {
                Button("Apply") { state.applyDevelopPreset(preset) }
                    .disabled(state.editTargets.isEmpty)
                // Plain buttons rather than a row menu: the system `Menu` is the
                // control `LumenMenu`'s header explains this app avoids.
                Button("Rename") {
                    draft = preset.name
                    renaming = preset.name
                }
                Button("Export…") { state.exportDevelopPreset(preset) }
                Button("Delete…") { pendingDelete = preset.name }
            }
        }
        .controlSize(.small)
        .padding(.vertical, 2)
    }
}

/// The Photo menu's submenu: New Preset…, Manage, Import, then one item per preset that
/// applies it to the selection. Its own view so only it observes the shelf, not the
/// whole menu bar (`LumenCommands`' header has why that matters).
struct DevelopPresetMenu: View {

    let state: AppState
    let hasSelection: Bool
    @ObservedObject private var shelf = DevelopPresetShelf.shared

    var body: some View {
        Menu("Develop Presets") {
            Button("Manage Presets…") { state.presentSettingsSubsetSheet(.manageDevelopPresets) }
            Button("Import Presets…") { state.importDevelopPresets() }
            if !shelf.presets.isEmpty {
                Divider()
                ForEach(shelf.presets, id: \.name) { preset in
                    Button(preset.name) { state.applyDevelopPreset(preset) }
                        .disabled(!hasSelection)
                }
            }
        }
    }
}

#endif

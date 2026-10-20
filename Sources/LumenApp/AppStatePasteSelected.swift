// AppStatePasteSelected.swift
// Paste Selected Settings (⇧⌘S) and settings presets: the app half of
// `LumenCore/Recipe/SelectivePaste.swift`, which owns the rule and its tests.
//
// Kept out of AppState.swift on purpose. The only hook there is `copiedRecipe` being
// readable from this file; everything else is a new type or an extension.
//
// The presets live in UserDefaults, not the catalog: they are the photographer's tools,
// like export recipes, and must survive opening a different catalog.

#if os(macOS)
import SwiftUI
import LumenCore

@MainActor
final class SettingsPresetStore: ObservableObject {
    static let shared = SettingsPresetStore()

    private static let libraryKey = "lumen.settingsPresets.v1"
    private static let lastGroupsKey = "lumen.pasteSelected.lastGroups.v1"

    @Published private(set) var library: SettingsPresetLibrary
    /// The sheet's last answer. Remembered because the question is answered the same way
    /// for a whole game; the first time it is `PasteGroup.syncDefault`.
    @Published var lastGroups: Set<PasteGroup> {
        didSet {
            UserDefaults.standard.set(PasteGroup.ordered(lastGroups).map(\.rawValue),
                                      forKey: Self.lastGroupsKey)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: Self.libraryKey) as? Data {
            library = SettingsPresetLibrary.decode(stored)
        } else {
            library = SettingsPresetLibrary()
        }
        if let raw = defaults.stringArray(forKey: Self.lastGroupsKey) {
            lastGroups = Set(raw.compactMap(PasteGroup.init(rawValue:)))
        } else {
            lastGroups = PasteGroup.syncDefault
        }
    }

    @discardableResult
    func save(_ preset: SettingsPreset) -> Bool {
        guard library.save(preset) else { return false }
        persist()
        return true
    }

    func delete(named name: String) {
        library.delete(named: name)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(library.encoded(), forKey: Self.libraryKey)
    }
}

extension AppState {

    /// Opens the sheet, with `present`'s rule: never over a running export's sheet.
    func openPasteSelected() {
        if isExporting, activeSheet == .export {
            statusMessage = "An export is running — stop it or let it finish first"
            return
        }
        activeSheet = .pasteSelected
    }

    /// Carry exactly `groups` of the copied recipe onto every edit target, as ONE undo
    /// step. With nothing copied it does nothing and says so.
    func pasteSelectedSettings(_ groups: Set<PasteGroup>) {
        guard let source = copiedRecipe else {
            statusMessage = "Copy settings first (⌘C)"
            return
        }
        guard !groups.isEmpty else { return }
        updateRecipe(label: "Paste Selected Settings") { recipe in
            recipe = recipe.adopting(groups, from: source)
        }
    }

    /// Paste the remembered groups (the sheet's last answer) from the frame just before
    /// the selection in the roll's order, ignoring the clipboard: edit one frame, move
    /// to the next, ⌥⇧⌘V. Crops stay put unless the photographer ticked Crop.
    func pasteFromPrevious() {
        let list = photos
        var indexByURL: [URL: Int] = [:]
        for (i, photo) in list.enumerated() { indexByURL[photo.id] = i }
        let selected = editTargets.compactMap { indexByURL[$0.id] }
        guard let index = PreviousFrame.sourceIndex(selected: selected) else {
            statusMessage = "No previous photograph to paste from"
            return
        }
        let groups = SettingsPresetStore.shared.lastGroups
        guard !groups.isEmpty else { return }
        let source = recipe(for: list[index])
        updateRecipe(label: "Paste from Previous") { recipe in
            recipe = recipe.adopting(groups, from: source)
        }
    }

    /// Apply a saved preset to every edit target, as one undo step.
    func applySettingsPreset(_ preset: SettingsPreset) {
        updateRecipe(label: "Apply Preset \u{201C}\(preset.name)\u{201D}") { recipe in
            recipe = preset.applied(to: recipe)
        }
    }

    /// Save the primary photograph's `groups` under `name`. False when there is no
    /// photograph, the name is blank, or nothing is ticked.
    @discardableResult
    func saveSettingsPreset(named name: String, groups: Set<PasteGroup>) -> Bool {
        guard let photo = primarySelection else { return false }
        return SettingsPresetStore.shared.save(
            SettingsPreset(name: name, groups: groups, recipe: recipe(for: photo)))
    }
}

/// The sheet behind ⇧⌘S. Two halves: tick groups and paste them from the clipboard
/// recipe, or save/apply a named preset of the same groups.
struct PasteSelectedSheet: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var store = SettingsPresetStore.shared
    @State private var groups: Set<PasteGroup> = PasteGroup.syncDefault
    @State private var presetName = ""

    private var targetCount: Int { state.editTargets.count }

    /// Groups in which the clipboard differs from the active photograph. A group outside
    /// it is labelled "same" so a tick that would change nothing reads as such. Nil
    /// when there is nothing to compare.
    private var differing: Set<PasteGroup>? {
        guard let source = state.copiedRecipe, let photo = state.primarySelection else {
            return nil
        }
        return state.recipe(for: photo).differingGroups(from: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Paste Selected Settings").font(.lumenTitle)
                Spacer()
                Button("Cancel") { state.activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Button("Sync") { groups = PasteGroup.syncDefault }
                    .help("Everything except crop, masks and spot removal")
                Button("WB + Tone") { groups = PasteGroup.exposureAndWhiteBalance }
                    .help("White balance and the tone sliders only")
                Button("All") { groups = Set(PasteGroup.allCases) }
                Button("None") { groups = [] }
            }
            .controlSize(.small)

            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                let changes = differing
                ForEach(PasteGroup.allCases, id: \.self) { group in
                    let same = changes.map { !$0.contains(group) } ?? false
                    Toggle(same ? "\(group.label) (same)" : group.label, isOn: Binding(
                        get: { groups.contains(group) },
                        set: { on in
                            if on { groups.insert(group) } else { groups.remove(group) }
                        }))
                    .toggleStyle(.checkbox)
                }
            }

            HStack {
                Text(targetCount == 1 ? "1 photograph selected"
                                      : "\(targetCount) photographs selected")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                Spacer()
                Button("Paste") {
                    store.lastGroups = groups
                    state.pasteSelectedSettings(groups)
                    state.activeSheet = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groups.isEmpty || !state.hasCopiedSettings || targetCount == 0)
                .help(state.hasCopiedSettings ? "Paste the ticked groups onto the selection"
                                              : "Copy settings from a photograph first (⌘C)")
            }

            Divider().overlay(Lumen.separator)

            Text("Presets").font(.lumenBodyStrong)
            HStack {
                TextField("Preset name", text: $presetName)
                    .accessibilityLabel("Preset name")
                Button("Save Ticked Groups") {
                    if state.saveSettingsPreset(named: presetName, groups: groups) {
                        presetName = ""
                    }
                }
                .disabled(groups.isEmpty || state.primarySelection == nil
                          || presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Save the ticked groups of the current photograph as a preset")
            }
            if store.library.presets.isEmpty {
                Text("No presets yet. Tick groups, name them and save from a finished frame.")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.library.presets) { preset in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(preset.name).font(.lumenBody)
                                    Text(preset.groups.map(\.label).joined(separator: ", "))
                                        .font(.lumenCaption)
                                        .foregroundStyle(Lumen.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("Apply") {
                                    state.applySettingsPreset(preset)
                                    state.activeSheet = nil
                                }
                                .disabled(targetCount == 0)
                                Button("Delete") { store.delete(named: preset.name) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { groups = store.lastGroups }
    }
}
#endif

// SettingsSubsetSheet.swift
// Copy Settings… (⇧⌘C) and Sync Settings… (⇧⌘S): one checkbox per `SettingsGroup`.
//
// Opens on the last choice (`AppState.rememberedSettingsGroups`) and stores the new one
// when confirmed, so the usual answer is Return. The per-frame groups — crop, masks, spot
// removal, ISO-resolved noise reduction — sit under their own heading and start unticked
// (`SettingsGroup.defaultSelection`), because they are the ones that wreck a burst when
// they travel by accident.

#if os(macOS)

import LumenCore
import SwiftUI

struct SettingsSubsetSheet: View {

    enum Mode {
        case copy
        case sync
    }

    let mode: Mode

    @EnvironmentObject var state: AppState
    @State private var chosen: Set<SettingsGroup> = []
    @State private var loaded = false

    private var lookGroups: [SettingsGroup] {
        SettingsGroup.allCases.filter { !$0.isPerFrame }
    }

    private var frameGroups: [SettingsGroup] {
        SettingsGroup.allCases.filter { $0.isPerFrame }
    }

    private var title: String {
        mode == .copy ? "Copy Settings" : "Sync Settings"
    }

    private var actionTitle: String {
        mode == .copy ? "Copy" : "Sync"
    }

    private var subtitle: String {
        let name = state.primarySelection?.id.lastPathComponent ?? "no photo"
        switch mode {
        case .copy:
            return "From \(name). Paste (⌘V) carries only the ticked groups."
        case .sync:
            let count = state.syncTargets.count
            return "From \(name) to \(count) other selected photo"
                + (count == 1 ? "." : "s.")
        }
    }

    private var canConfirm: Bool {
        guard !chosen.isEmpty, state.primarySelection != nil else { return false }
        return mode == .copy || !state.syncTargets.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.lumenTitle)
                    .foregroundStyle(Lumen.primaryText)
                Text(subtitle)
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            groupList(lookGroups)
            Divider().overlay(Lumen.separator)
            Text("THIS FRAME'S OWN")
                .font(.lumenCaptionStrong)
                .foregroundStyle(Lumen.secondaryText)
            groupList(frameGroups)
            Divider().overlay(Lumen.separator)
            footer
        }
        .padding(16)
        .frame(width: 340)
        .background(Lumen.panelBackground)
        .onAppear {
            guard !loaded else { return }
            chosen = state.rememberedSettingsGroups
            loaded = true
        }
    }

    private func groupList(_ groups: [SettingsGroup]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(groups, id: \.self) { group in
                HStack(spacing: 7) {
                    LumenCheckbox(isOn: binding(for: group))
                    // The label toggles too, as an AppKit checkbox's title does.
                    Text(group.title)
                        .font(.lumenBody)
                        .foregroundStyle(Lumen.primaryText)
                        .onTapGesture { toggle(group) }
                    Spacer()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("All") { chosen = Set(SettingsGroup.allCases) }
            Button("None") { chosen = [] }
            Spacer()
            Button("Cancel") { state.activeSheet = nil }
                .keyboardShortcut(.cancelAction)
            Button(actionTitle) { confirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
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
        state.rememberedSettingsGroups = groups
        state.activeSheet = nil
        switch mode {
        case .copy: state.copySettings(groups: groups)
        case .sync: state.syncSettings(groups: groups)
        }
    }
}

#endif

// AppStateCullSelection.swift
// The culling verbs the menu bar adds beside Select All: selecting by decision, the
// filter shortcuts with ⌘L's memory, and "Pick Sharpest in Each Burst".
//
// The rules are LumenCore's and tested there (`CullSelection`, `FilterShortcut`,
// `FilterToggleMemory`, `BurstPick`); this file only supplies the roll and carries the
// answer out through the verbs `AppState` already has — `selection`, `filter`,
// `mutateCulling` (one undo step) and the status bar.

#if os(macOS)

import AppKit
import Foundation
import LumenCore

/// ⌘L's stash. A holder rather than a stored property because an extension cannot add
/// one, and the stash is menu state that no view draws.
@MainActor
final class FilterToggleStash {
    static let shared = FilterToggleStash()
    var memory = FilterToggleMemory()
}

extension AppState {

    // MARK: - Selecting by decision

    /// Apply a selection rule to the photos shown. The filter is left alone.
    ///
    /// The cursor follows into the new selection when it is outside it: with one photo
    /// selected, `editTargets` is the cursor, so a cursor left behind would make the next
    /// P land on a photo the rule did not choose.
    func applySelectionRule(_ rule: CullSelection.Rule) {
        let shown = photos
        let chosen = CullSelection.apply(rule, to: shown, selection: selection)
        selection = chosen
        let cursorInside = primarySelection.map { chosen.contains($0.id) } ?? false
        if !cursorInside, let first = shown.first(where: { chosen.contains($0.id) }) {
            moveCursor(to: first)
        }
        statusMessage = CullSelection.summary(rule, selected: chosen.count, shown: shown.count)
    }

    // MARK: - Filter shortcuts

    func toggleFilterShortcut(_ shortcut: FilterShortcut) {
        filter = shortcut.toggled(in: filter)
    }

    /// ⌘L: the filter off, remembered; ⌘L again puts it back.
    func toggleFiltersEnabled() {
        let (next, outcome) = FilterToggleStash.shared.memory.toggle(filter)
        switch outcome {
        case .turnedOff:
            filter = next
            statusMessage = "Filters off — ⌘L turns them back on"
        case .turnedOn:
            filter = next
            statusMessage = "Filters on"
        case .nothingToRestore:
            statusMessage = "No filter to turn on"
        }
    }

    // MARK: - Pick sharpest in each burst

    /// Flag the best-ranked frame of every burst in scope Pick, after a confirmation that
    /// states the count. Scope is the selection when more than one photo is selected,
    /// otherwise every photo shown. Rejecting the other frames is a separate button in
    /// the same confirmation, never the default.
    func pickSharpestInEachBurst() {
        let scope = selection.count > 1 ? selectedPhotos : photos
        let frames: [BurstPickFrame<URL>] = scope.map { item in
            BurstPickFrame(id: item.id, burstID: item.attention?.burstID,
                       burstRank: item.attention?.burstRank,
                       sharpness: item.attention?.sharpness, flag: item.flag)
        }
        let plan = BurstPick.plan(frames)
        guard !plan.picks.isEmpty else {
            if plan.bursts == 0 {
                statusMessage = "No measured bursts here — the culling pass groups frames "
                    + "shot less than two seconds apart"
            } else {
                statusMessage = "Every burst here already has a decision"
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Pick the sharpest frame in each burst?"
        alert.informativeText = BurstPick.confirmation(plan)
        alert.addButton(withTitle: "Pick \(plan.picks.count)")
        alert.addButton(withTitle: "Cancel")
        if !plan.rest.isEmpty {
            alert.addButton(withTitle: "Pick \(plan.picks.count) and Reject \(plan.rest.count) Others")
        }
        let response = alert.runModal()
        let rejectRest: Bool
        if response == .alertFirstButtonReturn {
            rejectRest = false
        } else if response == .alertThirdButtonReturn {
            rejectRest = true
        } else {
            return
        }

        let decisions = plan.decisions(rejectRest: rejectRest)
        mutateCulling(of: Set(decisions.keys),
                      label: rejectRest ? "Pick Sharpest, Reject Rest" : "Pick Sharpest") { item in
            if let flag = decisions[item.id] { item.flag = flag }
        }
        var message = "Picked the sharpest frame in \(plan.picks.count) "
            + (plan.picks.count == 1 ? "burst" : "bursts")
        if rejectRest { message += ", rejected \(plan.rest.count) others" }
        statusMessage = message + " — ⌘Z takes it back"
    }
}

#endif

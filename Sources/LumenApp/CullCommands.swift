// CullCommands.swift
// The culling selection and filter verbs in the menu bar: Edit ▸ Select Picks and
// friends, and a Library menu for the filter shortcuts and the burst pick.
//
// Its own `Commands` rather than more items in `LumenCommands`, whose top-level group
// is at the ten-child builder limit. Like that type, `state` is held, not observed, and
// every title is fixed — the filter's state is in the status bar's sentence, and a
// title that read it would rebuild the menu bar on every filter change.
//
// The chords follow Lightroom where Lightroom has one and it is free here: ⌥⌘A Select
// Flagged, ⌥⇧⌘D Deselect Unflagged, ⌘L Enable Filters. ⇧⌘I would be Lightroom's
// Invert, but it is Ingest here (and Import there), so Invert has no chord. Every chord
// is declared in `KeyGrammar`; ⌃⌘ for the ratings because ⌥⌘1–5 are Lightroom's module
// keys and ⌘1–5 are this app's workspaces.

#if os(macOS)

import LumenCore
import SwiftUI

struct CullCommands: Commands {

    let state: AppState
    @ObservedObject var commands: CommandState

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Group {
                Divider()
                Button("Invert Selection") { state.applySelectionRule(.invert) }
                Button("Select Picks") { state.applySelectionRule(.picks) }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Button("Select Rejects") { state.applySelectionRule(.rejects) }
                Button("Select Unflagged") { state.applySelectionRule(.unflagged) }
                Menu("Select by Rating") {
                    Button("1★ or More") { state.applySelectionRule(.ratedAtLeast(1)) }
                    Button("2★ or More") { state.applySelectionRule(.ratedAtLeast(2)) }
                    Button("3★ or More") { state.applySelectionRule(.ratedAtLeast(3)) }
                    Button("4★ or More") { state.applySelectionRule(.ratedAtLeast(4)) }
                    Button("5★") { state.applySelectionRule(.ratedAtLeast(5)) }
                }
                Button("Deselect Unpicked") { state.applySelectionRule(.deselectUnpicked) }
                    .keyboardShortcut("d", modifiers: [.command, .option, .shift])
            }
        }

        CommandMenu("Library") {
            Group {
                Button("Filters On / Off") { state.toggleFiltersEnabled() }
                    .keyboardShortcut("l", modifiers: [.command])
                Divider()
                // Each shows one flag and nothing else moves; the same chord again
                // takes the flag criterion off, like the sidebar's rows.
                Button("Show Picks Only") { state.toggleFilterShortcut(.picksOnly) }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Show Unflagged Only") { state.toggleFilterShortcut(.unflaggedOnly) }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                Button("Show Rejected Only") { state.toggleFilterShortcut(.rejectedOnly) }
                    .keyboardShortcut("x", modifiers: [.command, .option])
            }
            Group {
                Divider()
                Button("Show Rated 1★ or More") { state.toggleFilterShortcut(.ratedAtLeast(1)) }
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Button("Show Rated 2★ or More") { state.toggleFilterShortcut(.ratedAtLeast(2)) }
                    .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Show Rated 3★ or More") { state.toggleFilterShortcut(.ratedAtLeast(3)) }
                    .keyboardShortcut("3", modifiers: [.command, .control])
                Button("Show Rated 4★ or More") { state.toggleFilterShortcut(.ratedAtLeast(4)) }
                    .keyboardShortcut("4", modifiers: [.command, .control])
                Button("Show Rated 5★") { state.toggleFilterShortcut(.ratedAtLeast(5)) }
                    .keyboardShortcut("5", modifiers: [.command, .control])
            }
            Group {
                Divider()
                // No chord: a batch decision over a whole shoot is deliberate, and it
                // asks first (D37).
                Button("Pick Sharpest in Each Burst…") { state.pickSharpestInEachBurst() }
                    .disabled(!commands.hasCatalog)
            }
        }
    }
}

#endif

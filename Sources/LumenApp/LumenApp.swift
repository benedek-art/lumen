// LumenApp.swift
// Entry point and the menu bar. Menus carry the commands that want a modifier; the
// bare-key grammar lives in Keymap.swift, because a culling loop cannot afford to go
// through the responder chain for every keystroke.

#if os(macOS)

import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Lumen") {
            ContentView()
                .environmentObject(state)
                // Neutral dark chrome, always: the surround must not bias a colour
                // judgement about the photograph (docs/00 Law 7).
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { state.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
            }

            CommandGroup(replacing: .undoRedo) {
                Button(state.history.undoLabel.map { "Undo \($0)" } ?? "Undo") {
                    state.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!state.history.canUndo)

                Button(state.history.redoLabel.map { "Redo \($0)" } ?? "Redo") {
                    state.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!state.history.canRedo)
            }

            CommandGroup(replacing: .pasteboard) {
                Button("Copy Settings") { state.copySettings() }
                    .keyboardShortcut("c", modifiers: [.command])
                Button("Paste Settings") { state.pasteSettings() }
                    .keyboardShortcut("v", modifiers: [.command])
                Divider()
                // The look-only pair is the point of the Develop/Look split: one look
                // across a whole shoot without touching each frame's own corrections.
                Button("Copy Look") { state.copyLook() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Paste Look") { state.pasteLook() }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                Divider()
                Button("Reset Settings") { state.resetSettings() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Button("Select All") { state.selectAll() }
                    .keyboardShortcut("a", modifiers: [.command])
                Button("Select None") { state.selectNone() }
                    .keyboardShortcut("d", modifiers: [.command])
            }

            CommandMenu("Photo") {
                Button("Pick") { state.setFlag(.picked) }
                Button("Reject") { state.setFlag(.rejected) }
                Button("Unflag") { state.setFlag(.none) }
                Divider()
                ForEach(1...5, id: \.self) { value in
                    Button("Rating \(value)") { state.setRating(value) }
                }
                Button("Clear Rating") { state.setRating(0) }
                Divider()
                Button("Auto Tone") { state.applyAutoTone() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            CommandMenu("Export") {
                Button("Export…") { state.showExportSheet = true }
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(state.primarySelection == nil)
            }

            CommandGroup(replacing: .help) {
                Button("Lumen Keyboard Reference") { state.showKeyReference = true }
                    .keyboardShortcut("/", modifiers: [.command])
            }
        }
    }
}

#else

// Linux: LumenApp is macOS-only. This stub keeps `swift build` of the whole package
// possible on a non-Mac host, where LumenCore is what actually gets exercised.
@main
struct LumenAppUnavailable {
    static func main() {
        print("LumenApp is macOS-only. Build LumenCore on this platform instead.")
    }
}

#endif

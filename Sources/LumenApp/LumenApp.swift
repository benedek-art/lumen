// LumenApp.swift
// Entry point and the menu bar. Menus carry the commands that want a modifier; the
// bare-key grammar lives in Keymap.swift, because a culling loop cannot afford to go
// through the responder chain for every keystroke.

#if os(macOS)

import AppKit
import SwiftUI

/// Exists for one reason: something has to run at quit.
///
/// `CatalogService.close` and `backup` had no callers anywhere — no delegate, no
/// `.onDisappear`, no termination hook — so flags, ratings and recipes written in the
/// last two seconds before ⌘Q never left the debounce window and never reached their
/// sidecar, and the WAL was never checkpointed. `VACUUM INTO` backups were implemented
/// and untakeable: a photographer had no way to back the catalog up from inside the
/// app. `applicationWillTerminate` is synchronous, which is what this needs — the
/// pending sidecar flush has to complete before the process goes away.
final class LumenAppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            state?.prepareToQuit()
        }
    }
}

@main
struct LumenApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(LumenAppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Lumen") {
            ContentView()
                .environmentObject(state)
                // The develop footer's undo/redo pair reads the same four facts the
                // Edit menu does, and for the same reason must observe something that
                // does not move on every mouse event of a drag.
                .environmentObject(state.commands)
                // The other half of that trade: `AppState.recipes` no longer publishes,
                // so the surfaces that DO show an edit observe this instead — and the
                // filmstrip, the grid, the sidebar and the menu bar stop being rebuilt
                // between two mouse events. `EditRevision`'s header has the rule for
                // any view added later that reads a recipe.
                .environmentObject(state.edits)
                // Neutral dark chrome, always: the surround must not bias a colour
                // judgement about the photograph (docs/00 Law 7).
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.state = state
                    // The owner's first Mac session started at the empty state and
                    // so has every launch since; a daily driver reopens where you
                    // left off. Quiet no-op when the bookmark is gone or revoked.
                    state.reopenLastFolder()
                    // The ship-to-self loop's last mile: an installed CI build
                    // replaces itself from the rolling dev release. Delayed so the
                    // launch render wins the disk and the network first; silent
                    // unless there is genuinely a newer build.
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await AppUpdater.shared.checkQuietly()
                    }
                }
        }
        .commands {
            LumenCommands(state: state, commands: state.commands)
        }
    }
}

/// The menu bar.
///
/// Split out of `LumenApp.body` and given its own observed object deliberately. The
/// menus display five facts — two undo labels, whether there is a catalog, whether
/// there is a selection, and whether the latency HUD is on — and every one of them is
/// on `CommandState`, which changes a handful of times per session. Reading them off
/// `AppState` instead meant this whole tree was rebuilt whenever ANY of that object's
/// sixty published properties moved, which during a slider drag is every mouse event:
/// seven menus and twenty-five items reconstructed on the main actor, per event, so
/// that a menu nobody had opened could hold a label that does not change during a drag.
///
/// `state` is held as a plain reference, not observed: the buttons need it to ACT, and
/// a menu that rebuilds because an action's receiver changed is the bug this type
/// exists to remove.
private struct LumenCommands: Commands {

    let state: AppState
    @ObservedObject var commands: CommandState

    var body: some Commands {
        Group {
            CommandGroup(after: .appInfo) {
                // A plain Text renders as a disabled menu line: the build's number,
                // commit and date, so "am I on the newest build?" is one click, no
                // network. The updater's alert names the same stamp.
                Text(BuildStamp.current)
                Button("Check for Updates…") {
                    Task { await AppUpdater.shared.check(interactive: true) }
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { state.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Ingest from Card…") { state.showIngestSheet = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                // `VACUUM INTO` was implemented in CatalogService and had no caller, so
                // the one maintenance action a photographer actually wants was
                // unreachable from inside the app.
                Button("Back Up Catalog") { state.backUpCatalog() }
                    .disabled(!commands.hasCatalog)
            }

            // Instruments for a test session, not features: everything here exists
            // so an owner session produces numbers instead of impressions.
            CommandMenu("Debug") {
                Button(commands.showLatencyHUD
                       ? "Hide Latency HUD" : "Show Latency HUD") {
                    state.showLatencyHUD.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .undoRedo) {
                Button(commands.undoLabel.map { "Undo \($0)" } ?? "Undo") {
                    state.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!commands.canUndo)

                Button(commands.redoLabel.map { "Redo \($0)" } ?? "Redo") {
                    state.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!commands.canRedo)
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
                    .disabled(!commands.hasSelection)
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

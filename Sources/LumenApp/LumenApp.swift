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
            CommandGroup(after: .appInfo) {
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
                    .disabled(state.catalog == nil)
            }

            // Instruments for a test session, not features: everything here exists
            // so an owner session produces numbers instead of impressions.
            CommandMenu("Debug") {
                Button(state.showLatencyHUD ? "Hide Latency HUD" : "Show Latency HUD") {
                    state.showLatencyHUD.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
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

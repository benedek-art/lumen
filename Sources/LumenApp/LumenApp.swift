// LumenApp.swift
// Entry point. `swift run LumenApp` from the repo root launches the walking skeleton
// (an unbundled SwiftUI window — the .app bundle + signing script arrives with the
// first ship-to-self build, docs/16 Phase 1).

#if os(macOS)

import SwiftUI

@main
struct LumenApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Lumen") {
            ContentView()
                .environmentObject(state)
                .preferredColorScheme(.dark)   // neutral dark chrome (Law 7 / D46)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { state.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}

#else

// Linux: LumenApp is macOS-only; this stub keeps `swift build` of the full package
// possible on non-Mac hosts (the core is what CI builds there).
@main
struct LumenAppUnavailable {
    static func main() {
        print("LumenApp is macOS-only. Build LumenCore on this platform instead.")
    }
}

#endif

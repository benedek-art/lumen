// Keymap.swift
// The keyboard grammar, in one dispatcher, because a culling loop that runs at key-
// repeat speed cannot afford SwiftUI's per-view shortcut plumbing — and because a
// grammar scattered across twenty views is a grammar nobody can audit.
//
// Bare letters are the point (D35): P/X/U flag, 1–5 rate, 6–9 label, G/E/C/N switch
// views, and every one of them auto-advances so the hands never leave the home row.
// That is Photo Mechanic's bar, and it is the highest-frequency job Lumen has.
//
// Two rules keep it safe:
//   · while a text field has focus, every bare key belongs to the text field;
//   · a key this dispatcher does not claim is returned to the system unchanged, so
//     menu equivalents and system shortcuts keep working.

#if os(macOS)

import AppKit
import Foundation
import SwiftUI

@MainActor
final class KeyDispatcher {

    private weak var state: AppState?
    private var monitor: Any?
    /// Set while a hold-key gesture is active, so key-up can undo what key-down did.
    private var holdActive: Character?

    init(state: AppState) {
        self.state = state
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                self.handle(event) ? nil : event
            }
        }
    }

    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Dispatch

    private func handle(_ event: NSEvent) -> Bool {
        guard let state else { return false }

        // A focused text field owns every key. Nothing below runs while the user is
        // typing a value into a slider or a filter box.
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Command-modified keys are menu territory; leave them alone.
        if flags.contains(.command) { return false }

        if event.type == .keyUp {
            return handleKeyUp(event, state: state)
        }

        // Arrows and the like arrive as special key codes rather than characters.
        if let special = specialKey(event, state: state, flags: flags) {
            return special
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              let key = characters.first else { return false }

        // Ignore auto-repeat for the toggles where repeat would be nonsense, but keep
        // it for navigation, which is exactly where key repeat earns its keep.
        if event.isARepeat && !"[]".contains(key) {
            if !"pxu0123456789".contains(key) { return false }
        }

        switch key {
        // ---- Views -------------------------------------------------------------
        case "g":
            state.showGrid()
        case "e":
            state.showLoupe()
        case "c":
            state.toggleCompare()
        case "n":
            state.toggleSurvey()

        // ---- Flags -------------------------------------------------------------
        case "p":
            state.setFlag(.picked)
        case "x":
            state.setFlag(.rejected)
        case "u":
            state.setFlag(.none)

        // ---- Ratings and labels ------------------------------------------------
        case "0", "1", "2", "3", "4", "5":
            if let value = Int(String(key)) { state.setRating(value) }
        case "6":
            state.setLabel(.red)
        case "7":
            state.setLabel(.yellow)
        case "8":
            state.setLabel(.green)
        case "9":
            state.setLabel(.blue)

        // ---- Editing -----------------------------------------------------------
        case "\\":
            state.showBefore.toggle()
        case "r":
            state.activeSection = .effects       // crop lives with the effects group
            state.showLoupe()
        case "m":
            state.activeSection = .masks
            state.showLoupe()
        case "b":
            state.activeSection = .basic
        case "l":
            state.activeSection = .look
        case "d":
            state.activeSection = .detail
        case "h":
            state.showHistogram.toggle()
        case "s":
            state.showScopes.toggle()
        case "a":
            state.autoAdvance.toggle()
        case "f":
            state.showFilmstrip.toggle()

        // ---- Zoom --------------------------------------------------------------
        case "z":
            state.zoomLevel = state.zoomLevel == 0 ? 1 : 0
        case "-":
            state.zoomLevel = state.zoomLevel == 0 ? 0 : max(state.zoomLevel / 2, 0.125)
        case "=", "+":
            state.zoomLevel = state.zoomLevel == 0 ? 1 : min(state.zoomLevel * 2, 8)

        // ---- Thumbnail size ----------------------------------------------------
        case "[":
            state.gridThumbnailSize = max(state.gridThumbnailSize - 24, 80)
        case "]":
            state.gridThumbnailSize = min(state.gridThumbnailSize + 24, 400)

        // ---- Hold-key overlays -------------------------------------------------
        case " ":
            // Hold space for the loupe from the grid; release returns you to it.
            if holdActive == nil && state.viewMode == .grid {
                holdActive = " "
                state.showLoupe()
                return true
            }
            state.zoomLevel = state.zoomLevel == 0 ? 1 : 0

        default:
            return false
        }
        return true
    }

    private func handleKeyUp(_ event: NSEvent, state: AppState) -> Bool {
        guard let key = event.charactersIgnoringModifiers?.first,
              holdActive == key else { return false }
        holdActive = nil
        if key == " " {
            state.showGrid()
        }
        return true
    }

    private func specialKey(_ event: NSEvent, state: AppState,
                            flags: NSEvent.ModifierFlags) -> Bool? {
        guard let scalars = event.charactersIgnoringModifiers?.unicodeScalars,
              let first = scalars.first else { return nil }
        switch Int(first.value) {
        case NSRightArrowFunctionKey:
            state.selectNext()
            return true
        case NSLeftArrowFunctionKey:
            state.selectPrevious()
            return true
        case NSDownArrowFunctionKey:
            state.moveSelection(by: state.viewMode == .grid ? state.gridColumns : 1)
            return true
        case NSUpArrowFunctionKey:
            state.moveSelection(by: state.viewMode == .grid ? -state.gridColumns : -1)
            return true
        case NSDeleteFunctionKey, 0x7F:
            state.setFlag(.rejected)
            return true
        case 0x1B:      // Escape
            if state.viewMode != .grid {
                state.showGrid()
                return true
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - SwiftUI installation

/// Installs the dispatcher for the lifetime of the view it modifies.
struct KeyboardGrammar: ViewModifier {
    @EnvironmentObject var state: AppState
    @State private var dispatcher: KeyDispatcher?

    func body(content: Content) -> some View {
        content
            .onAppear {
                let created = KeyDispatcher(state: state)
                created.install()
                dispatcher = created
            }
            .onDisappear {
                dispatcher?.uninstall()
                dispatcher = nil
            }
    }
}

extension View {
    func keyboardGrammar() -> some View { modifier(KeyboardGrammar()) }
}

/// The keymap, as data, so the Help sheet cannot drift from the dispatcher above.
enum KeyReference {
    struct Entry: Identifiable {
        let id = UUID()
        let keys: String
        let action: String
    }

    struct Group: Identifiable {
        let id = UUID()
        let title: String
        let entries: [Entry]
    }

    static let groups: [Group] = [
        Group(title: "Views", entries: [
            Entry(keys: "G", action: "Grid"),
            Entry(keys: "E", action: "Loupe"),
            Entry(keys: "C", action: "Compare two"),
            Entry(keys: "N", action: "Survey selection"),
            Entry(keys: "Space", action: "Hold for loupe from the grid; toggles zoom in the loupe"),
            Entry(keys: "Esc", action: "Back to the grid"),
        ]),
        Group(title: "Culling", entries: [
            Entry(keys: "P", action: "Pick"),
            Entry(keys: "X", action: "Reject"),
            Entry(keys: "U", action: "Unflag"),
            Entry(keys: "1–5", action: "Rating"),
            Entry(keys: "0", action: "Clear rating"),
            Entry(keys: "6–9", action: "Red / yellow / green / blue label"),
            Entry(keys: "A", action: "Toggle auto-advance"),
            Entry(keys: "← →", action: "Previous / next photo"),
            Entry(keys: "↑ ↓", action: "Previous / next row"),
        ]),
        Group(title: "Develop", entries: [
            Entry(keys: "B", action: "Basic panel"),
            Entry(keys: "D", action: "Detail panel"),
            Entry(keys: "L", action: "Look panel"),
            Entry(keys: "M", action: "Masks"),
            Entry(keys: "R", action: "Crop"),
            Entry(keys: "\\", action: "Before / after"),
            Entry(keys: "H", action: "Histogram"),
            Entry(keys: "S", action: "Scopes"),
        ]),
        Group(title: "View controls", entries: [
            Entry(keys: "Z", action: "Zoom 1:1 / fit"),
            Entry(keys: "+ −", action: "Zoom in / out"),
            Entry(keys: "[ ]", action: "Thumbnail size"),
            Entry(keys: "F", action: "Filmstrip"),
        ]),
        Group(title: "Menu commands", entries: [
            Entry(keys: "⌘O", action: "Open folder"),
            Entry(keys: "⌘Z / ⇧⌘Z", action: "Undo / redo"),
            Entry(keys: "⌘C / ⌘V", action: "Copy / paste settings"),
            Entry(keys: "⌥⌘C / ⌥⌘V", action: "Copy / paste Look"),
            Entry(keys: "⌘E", action: "Export"),
            Entry(keys: "⌘A / ⌘D", action: "Select all / none"),
        ]),
    ]
}

#endif

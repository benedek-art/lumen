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
//
// The reference the Help sheet prints is `LumenCore.KeyGrammar`, and it is checked
// against these sources rather than trusted: `KeyGrammarTests` reads the switch below
// for its bare keys and every `.keyboardShortcut` in this target for its chords, and
// fails when either side names a key the other does not.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
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

        // A sheet owns every key too. This monitor sits in FRONT of the responder
        // chain, so without this an X pressed while reading the export sheet rejects
        // the photo behind it — silently, because the sheet is covering the badge.
        if state.isPresentingSheet { return false }

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
        // Purple is offered by the label picker and the filter bar, so it needs a key
        // like the other five; `-` sits next to 9 and is otherwise only a zoom key in
        // the loupe, where labels are rarer than zooming — so purple takes it only
        // outside the loupe.
        case "-" where state.viewMode != .loupe:
            state.setLabel(.purple)

        // ---- Editing -----------------------------------------------------------
        case "\\":
            state.showBefore.toggle()

        // The before/after family. `LoupeViewport.beforeMode` had no writer anywhere:
        // no key, no menu item, no button — so `BeforeAfterSplit`, `BeforeAfterPair`,
        // `SplitScissor` and the whole second render pipeline behind them could never
        // be shown, while the enum's own doc comment named these three shortcuts. Only
        // the `\` full-frame flip worked, and nothing said the rest was missing.
        //
        // Pressing the same one again turns it off, so Y is a toggle rather than a
        // mode you have to know how to leave.
        case "y":
            let wanted: BeforeAfterMode
            if flags.contains(.shift) {
                wanted = .split
            } else if flags.contains(.option) {
                wanted = .topBottom
            } else {
                wanted = .sideBySide
            }
            let viewport = LoupeViewport.shared
            viewport.beforeMode = viewport.beforeMode == wanted ? .off : wanted
            if viewport.beforeMode != .off { state.showLoupe() }
        case "r":
            // R opens the crop tool and R again leaves it, which is the grammar every
            // photographer already has. The overlay was complete and unreachable:
            // `showCrop` had no writer anywhere. A first attempt at wiring it drew the
            // wrong rectangle, because `renderPreview` cropped before returning and the
            // overlay's rect is normalized to the straightened frame — a second inset
            // crop inside the first, compounding on every drag. The renderer now shows
            // the uncropped frame while this is on, which is what makes it correct.
            state.activeSection = .effects       // crop lives with the effects group
            state.showLoupe()
            LoupeViewport.shared.showCrop.toggle()
        case "m":
            state.activeSection = .masks
            state.showLoupe()

        // ---- Mask overlays (docs/08 §8.6) --------------------------------------
        //
        // LR's three overlay keys, adopted verbatim: fifteen years of tutorials and
        // muscle memory describe exactly this grammar. Until now the overlay had no
        // key at all and one mode of six, so the only way to look at a mask was a
        // button in the panel that drew a flat tint.
        case "o":
            if flags.contains(.option) {
                state.cycleMaskOverlayMode()
            } else if flags.contains(.shift) {
                state.cycleMaskOverlayTint()
            } else {
                state.toggleMaskOverlay()
            }
            state.activeSection = .masks
            state.showLoupe()
        case "'":
            // Invert the selected COMPONENT, which is what this key means in LR and in
            // docs/08 §8.1. The whole-mask invert is a toggle in the panel, because a
            // second invert key would be two keys nobody could tell apart.
            state.invertActiveMaskComponent()
        case "b":
            state.activeSection = .basic
        case "l":
            state.activeSection = .look
        case "d":
            state.activeSection = .detail
        case "h":
            state.showHistogram.toggle()
        // docs/09 gives soft proofing a bare `S`, which this grammar had already spent on
        // the scopes long before proofing existed. ⇧S rather than stealing it back: a key
        // that moves is worse than a key that is one modifier away, and the keyboard
        // reference names both.
        case "s" where flags.contains(.shift):
            state.softProof.enabled.toggle()
        case "s":
            state.showScopes.toggle()
        case "a":
            state.autoAdvance.toggle()
        case "f":
            state.showFilmstrip.toggle()

        // ---- Zoom --------------------------------------------------------------
        //
        // Through `LoupeViewport`'s verbs, which are headed "the keymap's entry points"
        // and had no callers at all — this ran its own arithmetic on `zoomLevel`
        // instead. Two consequences the user could feel: the keyboard never anchored
        // the zoom at the cursor, which is the entire purpose of
        // `anchorNextZoomAtCursor`, so Z and + zoomed about the centre while a click
        // zoomed where you pointed; and `−` walked 1 → 0.5 → 0.25 → 0.125 without ever
        // snapping back to Fit, because `zoomOut`'s "below 0.35 means fit" rule lived
        // in the verb nobody called. Click-to-zoom already went through these, so the
        // mouse and the keyboard were following different ladders.
        case "z":
            LoupeViewport.shared.toggleZoom(in: state)
        case "-":
            LoupeViewport.shared.zoomOut(in: state)
        case "=", "+":
            LoupeViewport.shared.zoomIn(in: state)

        // ---- Thumbnail size ----------------------------------------------------
        case "[":
            state.gridThumbnailSize = max(state.gridThumbnailSize - 24,
                                          AppState.minThumbnailSize)
        case "]":
            state.gridThumbnailSize = min(state.gridThumbnailSize + 24,
                                          AppState.maxThumbnailSize)

        // ---- Hold-key overlays -------------------------------------------------
        case " ":
            // Hold space for the loupe from the grid; release returns you to it.
            if holdActive == nil && state.viewMode == .grid {
                holdActive = " "
                state.showLoupe()
                return true
            }
            // Through the viewport verb, like Z and − above it. This line used to read
            // `state.zoomLevel = state.zoomLevel == 0 ? 1 : 0`: the same two ratios and
            // none of the anchoring, so Space zoomed about the centre of the window
            // while a click zoomed where you pointed — on the key whose own
            // documentation says "centred on the cursor". Exactly the bug the comment
            // above claims was fixed for Z, reintroduced one case later.
            LoupeViewport.shared.toggleZoom(in: state)

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
        case NSRightArrowFunctionKey, NSLeftArrowFunctionKey,
             NSDownArrowFunctionKey, NSUpArrowFunctionKey:
            // Zoomed in, the arrows pan the picture. Returning nil hands the event to
            // the responder chain, where the loupe's own `onMoveCommand` is waiting —
            // this monitor runs first, so claiming the key here made that pan handler
            // unreachable code.
            if state.viewMode == .loupe && state.zoomLevel > 0 { return nil }
            switch Int(first.value) {
            case NSRightArrowFunctionKey: state.selectNext()
            case NSLeftArrowFunctionKey: state.selectPrevious()
            case NSDownArrowFunctionKey:
                state.moveSelection(by: state.viewMode == .grid ? state.gridColumns : 1)
            default:
                state.moveSelection(by: state.viewMode == .grid ? -state.gridColumns : -1)
            }
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

/// The keyboard reference the Help sheet draws, as SwiftUI needs it.
///
/// The text itself is `LumenCore.KeyGrammar`, and this is the adapter that gives each
/// row the identity `ForEach` wants. The claim that used to sit here — that the
/// reference is "data, so the Help sheet cannot drift from the dispatcher" — was false
/// when it was written: seven of the app's ⌘-shortcuts were in neither this list nor
/// the switch above. Being data is not a mechanism. The mechanism is
/// `KeyGrammarTests`, which reads these sources and fails when a key is attached in one
/// place and named in neither.
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

    static let groups: [Group] = KeyGrammar.groups.map { section in
        Group(title: section.title,
              entries: section.rows.map { Entry(keys: $0.keys, action: $0.action) })
    }
}

#endif

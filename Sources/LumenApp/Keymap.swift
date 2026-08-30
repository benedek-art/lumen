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

        // A KEY-UP IS ANSWERED BEFORE ANY GUARD, and the ordering is the whole fix.
        //
        // It used to sit below the three guards, so a release could be discarded even
        // though the press had been claimed. Hold `[` to check the shadows, reach for ⌘
        // while it is down — any chord, or a thumb resting on it — and release: the
        // key-up hit `flags.contains(.command)` and vanished. `holdActive` stayed `"["`,
        // so the frame stayed lifted three stops with a badge over it and nothing holding
        // it, AND `InspectionHolds.resolve` refuses to begin any new hold while
        // `holdActive != nil` — so both brackets and the Space peek were dead for the
        // rest of the session. The same trap caught Space in the grid.
        //
        // Hoisting is safe because `handleKeyUp` claims nothing it did not start: a
        // release that matches no hold key and no active hold returns false and falls
        // through to whoever else wants it.
        if event.type == .keyUp {
            return handleKeyUp(event, state: state)
        }

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

        // A POPOVER OWNS THEM TOO, for exactly the reason a sheet does. The Filter
        // popover and every `LumenMenu` dropdown are popovers, and until this line an `x`
        // pressed while reading the filter list rejected the photograph behind it —
        // silently, because the popover was covering the badge. A popover is a window of
        // its own on this platform, so "the key window is not the main window" is the
        // test, and it costs nothing when none is up.
        if let window = NSApp.keyWindow, window !== NSApp.mainWindow, !window.isSheet {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Command-modified keys are menu territory; leave them alone.
        if flags.contains(.command) { return false }
        // CONTROL TOO, and it was never checked. ⌃N, ⌃P, ⌃A, ⌃E and ⌃H are the standard
        // macOS text-navigation bindings that work in every control on the system; here
        // they fell straight through to the bare-key switch and toggled Survey, picked
        // the photograph, flipped auto-advance, opened the loupe and toggled the
        // histogram. Nothing in this app's grammar uses ⌃ at all.
        if flags.contains(.control) { return false }

        // Arrows and the like arrive as special key codes rather than characters.
        if let special = specialKey(event, state: state, flags: flags) {
            return special
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              let key = characters.first else { return false }

        // Ignore auto-repeat for the toggles where repeat would be nonsense, but keep
        // it for navigation, which is exactly where key repeat earns its keep.
        //
        // AND THE FLAG AND LABEL KEYS ARE ONLY NAVIGATION WHILE AUTO-ADVANCE IS ON. P, X,
        // U and the ten digits all INVERT when the value already matches — `setFlag` and
        // `setRating` and `setLabel` are toggles — so with auto-advance off, holding P
        // flips pick/unpick at the key-repeat rate and what you end up with is the parity
        // of however long you held it. With auto-advance on the same repeat is the thing
        // it was allowed for: flag, move to the next frame, flag again. The comment above
        // was describing the second case and the code was permitting both.
        if event.isARepeat && !"[]".contains(key) {
            guard "pxu0123456789".contains(key), state.autoAdvance else { return false }
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
            // Crop is its own workspace now, and R is one of three doors into it — the
            // menu item and the tab strip are the others. All three call the same verb,
            // because fixing them one at a time is exactly how the tab came to be the
            // one route that did not arm the tool. `AppState.toggleCropTool` holds the
            // round trip: from outside it enters Crop with the section open and the
            // rectangle live, and from inside it toggles the rectangle without leaving.
            state.toggleCropTool()
        case "m":
            // M IS A ROUND TRIP, and it has to be, because it is the only key that both
            // enters and leaves. The column becomes the mask editor and the workspace
            // underneath is remembered, so pressing M twice puts a photographer back
            // exactly where they were — which is the property that lets a mask be a
            // detour rather than a destination.
            //
            // One verb, shared with the rail's mask door. `toggleMasking` carries the
            // whole entry contract — the loupe only on the way in (Cull's round trip
            // broke when it ran on both edges), the crop tool disarmed so its rectangle
            // is never stranded under `MaskCanvas` — and the history of both rules now
            // lives on the verb in WorkspaceEntry.swift. This key held its own copy of
            // that body for one commit; two copies of an entry contract is how the tab
            // became the one route that did not arm the crop tool, so neither the key
            // nor the door keeps one.
            state.toggleMasking()

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
            // The overlay keys ENTER masking rather than toggling it: pressing O to
            // look at a mask and having it close the editor you are looking at would be
            // the key undoing its own reason for existing.
            PanelLayout.shared.setMasking(true)
            state.showLoupe()
        case "'":
            // Invert the selected COMPONENT, which is what this key means in LR and in
            // docs/08 §8.1. The whole-mask invert is a toggle in the panel, because a
            // second invert key would be two keys nobody could tell apart.
            state.invertActiveMaskComponent()
        // The three panel keys now name a workspace AND a section, because a workspace
        // alone would leave the photographer looking at whichever section was last open.
        // Each opens the section that tab used to lead with.
        //
        // Through `state.jump` rather than `PanelLayout.reveal` directly, because a key
        // that names a section is a key that names a PLACE: pressed from the grid,
        // `reveal` opened Tone behind a contact sheet and left it there.
        case "b":
            state.jump(to: .tone)
        case "l":
            state.jump(to: .looks)
        case "d":
            // Through `click` this key was silent from any other workspace — `jump`
            // (reveal, plus everything arriving somewhere means) opens the section
            // from anywhere.
            state.jump(to: .detail)
        // H is the develop histogram, which bins the RENDERED picture — the instrument
        // docs/10 §10.5 calls the one that lies, because the render has been through
        // the tone stage and the display transform before it is counted. ⇧H is the
        // other one: statistics measured on the decoded scene-linear frame, before
        // every Lumen stage, with per-channel clipped percentages. Not the sensor's
        // mosaic — Lumen has no CFA reader — and the panel is named for what it is.
        case "h" where flags.contains(.shift):
            state.showRawTruth.toggle()
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
        // THE LOUPE'S ZOOM IS THE LOUPE'S. `LoupeViewport` writes `state.zoomLevel`, which
        // only `LoupeView` draws — Compare and Survey run their own `CompareSync.zoom`
        // and the grid has no zoom at all. Unguarded, these three keys did nothing
        // visible in the other three surfaces AND still returned true, so the press was
        // swallowed; worse, pressing Z in the grid left `zoomLevel` at 1 with nothing on
        // screen to say so, and the next E opened the loupe at 1:1 with the arrow keys
        // panning the picture instead of paging the roll.
        //
        // Each guards its own surface rather than sharing one `where` clause, because a
        // `where` on a multi-pattern case binds to the LAST pattern only — `case "z",
        // "-", "=", "+" where cond:` guards `+` and nothing else, which compiles and is
        // wrong. `-` outside the loupe is already the purple label, above.
        case "z":
            guard state.viewMode == .loupe else { return false }
            LoupeViewport.shared.toggleZoom(in: state)
        case "-":
            guard state.viewMode == .loupe else { return false }
            LoupeViewport.shared.zoomOut(in: state)
        case "=", "+":
            guard state.viewMode == .loupe else { return false }
            LoupeViewport.shared.zoomIn(in: state)

        // ---- Thumbnail size, and the two momentary inspections ------------------
        //
        // `[` and `]` are wanted by two features. They already sized the contact sheet's
        // cells, and docs/10 §10.5 gives them to Shadow Boost and Highlight Inspect —
        // momentary holds that answer "is there anything in the shadows" and "does the
        // highlight structure survive" without writing an edit. Neither feature can be
        // dropped: the size step is a control that works, and the holds are half of the
        // FastRawViewer pillar.
        //
        // The split is by surface, and it is `InspectionHolds` in LumenCore rather than
        // three conditionals here, because the collision, the key-repeat policy and the
        // key-up pairing are exactly the kind of rule that cannot be tested in this
        // target. `gridThumbnailSize` is drawn by the contact sheet and by the filter
        // bar's slider and by nothing else, so in the loupe, Compare and Survey these
        // keys were already moving a number nobody could see — and those three are
        // precisely where the picture is large enough to inspect.
        case "[", "]":
            return apply(InspectionHolds.resolve(key: String(key),
                                                 surface: Self.surface(state.viewMode),
                                                 isKeyDown: true,
                                                 isRepeat: event.isARepeat,
                                                 holdActive: holdActive.map { String($0) }),
                         state: state)

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
        // SHIFT IS FOLDED OUT, because `charactersIgnoringModifiers` ignores every
        // modifier EXCEPT shift. Press Shift at any point while `[` is held and the
        // release arrives as `"{"`, which matches neither `InspectionHolds.keys` nor
        // `holdActive` — so the hold sticks, exactly as it did when the whole key-up was
        // being eaten by the ⌘ guard above. Only the two bracket keys need it; a letter
        // is handled by `lowercased()`.
        guard let raw = event.charactersIgnoringModifiers?.lowercased().first
        else { return false }
        //
        // Written as a ternary rather than a `switch`, and that is not a style choice:
        // `KeyGrammarTests` reads this file as TEXT and treats every `case "x":` in the
        // dispatcher as a bare-key binding, so a `switch` here declared `{` and `}` as two
        // new keys the grammar reference does not have — and the suite said so within the
        // minute. The scanner is right; a normalisation is not a binding.
        let key: Character = raw == "{" ? "[" : (raw == "}" ? "]" : raw)

        // The inspection holds answer their own key-up, through the same rule that
        // answered the key-down. Asking the rule rather than testing `holdActive` here
        // is what makes "a `]` release does not cancel a held `[`" a fact a test can
        // check instead of a line of this file nobody can run.
        if InspectionHolds.keys.contains(String(key)) {
            return apply(InspectionHolds.resolve(key: String(key),
                                                 surface: Self.surface(state.viewMode),
                                                 isKeyDown: false,
                                                 holdActive: holdActive.map { String($0) }),
                         state: state)
        }

        guard holdActive == key else { return false }
        holdActive = nil
        if key == " " {
            state.showGrid()
        }
        return true
    }

    /// Carry out what `InspectionHolds` decided. Every branch is claimed: these two
    /// keys belong to this dispatcher in every view, so an ignored one is swallowed
    /// rather than passed on to be interpreted by something else.
    private func apply(_ action: BracketAction, state: AppState) -> Bool {
        switch action {
        case .ignore:
            break
        case .stepThumbnailSize(let delta):
            state.gridThumbnailSize = min(max(state.gridThumbnailSize + delta,
                                              AppState.minThumbnailSize),
                                          AppState.maxThumbnailSize)
        case .beginHold(let hold):
            holdActive = hold.key.first
            state.inspectionHold = hold
        case .endHold:
            holdActive = nil
            state.inspectionHold = nil
        }
        return true
    }

    /// Which surface the rule is being asked about.
    private static func surface(_ mode: ViewMode) -> InspectionSurface {
        switch mode {
        case .grid: return .grid
        case .loupe: return .loupe
        case .compare: return .compare
        case .survey: return .survey
        }
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
            // A focused slider owns the arrows, for exactly the same reason and by
            // exactly the same mechanism (docs/28 Phase 7). Without this the nudge is
            // unreachable code too: `LumenSlider`'s `onKeyPress` lives in the responder
            // chain, behind this monitor, so the arrow would page to the next photograph
            // while a control sat focused and apparently broken.
            //
            // `sliderHoldsFocus` is deliberately NOT `@Published` — nothing renders from
            // it, and it is read here imperatively at key-down, so publishing it would
            // re-body the window every time focus moved between two rows.
            if state.sliderHoldsFocus { return nil }
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
            // A focused slider gets Escape first, to drop its focus. This monitor runs
            // in front of the responder chain, so without the yield the slider's own
            // `onKeyPress(.escape)` would be unreachable code and Escape would jump
            // straight to the grid from under a control the photographer was using.
            // Press it again with nothing focused and it means the grid, as before —
            // the ordinary nested-Escape idiom.
            if state.sliderHoldsFocus { return nil }
            // Then masking, which is the next layer out: the column is showing the mask
            // editor instead of the workspace, so Escape leaves it the way Escape leaves
            // every other thing you are inside. Above the grid rather than below it, or
            // Escape would jump past a whole surface to the light table.
            if PanelLayout.shared.layout.isMasking {
                PanelLayout.shared.setMasking(false)
                return true
            }
            // Then the crop tool, the same layer of the same idiom: a rectangle on the
            // photograph is a thing you are inside, and Escape leaves it.
            //
            // It has to be HERE rather than in the overlay, and that is the whole point.
            // This monitor sits in front of the responder chain and spent 0x1B on the
            // grid unconditionally, so a `.keyboardShortcut(.escape)` on the crop panel
            // would have been dead code wearing a shortcut — the exact defect class this
            // project has shipped twice and now tests for.
            //
            // Leaving reverts, because that is what Escape means everywhere else. The
            // rectangle at arming time is `CropTool`'s to remember — and since the crop
            // saves as you go (the Done/Revert row is gone, owner pass 4), this key is
            // the ONLY way back that is not Reset, which is exactly why it lives at the
            // dispatcher where it cannot go dead.
            if LoupeViewport.shared.showCrop {
                CropTool.shared.revert(in: state)
                LoupeViewport.shared.showCrop = false
                LoupeViewport.shared.showStraighten = false
                return true
            }
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
/// when it was written: nine of the app's nineteen ⌘-shortcuts were in neither this
/// list nor the switch above, ⌘/ among them, which is the chord that opens this sheet.
/// Being data is not a mechanism. The mechanism is `KeyGrammarTests`, which reads these
/// sources and fails when a key is attached in one place and named in neither.
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

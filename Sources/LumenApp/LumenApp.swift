// LumenApp.swift
// Entry point and the menu bar. Menus carry the commands that want a modifier; the
// bare-key grammar lives in Keymap.swift, because a culling loop cannot afford to go
// through the responder chain for every keystroke.

#if os(macOS)

import AppKit
import LumenCore
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

            // THE WORKSPACES, AND THEY ARE IN A MENU FOR A REASON.
            //
            // Two reasons, and both are defects this project has already paid for.
            // `KeyDispatcher` returns early on any command-modified key — "menu
            // territory" — so ⌘1–⌘4 cannot go through it. And a `.keyboardShortcut`
            // attached to a view that is not in the hierarchy is never registered: the
            // switcher lives in the develop column, which Cull does not draw, so
            // attaching them there would make the key that RETURNS from Cull the one key
            // Cull cannot press. A `Scene`'s commands are always registered.
            //
            // ⌘ rather than the bare digits is the owner's decision (docs/29 §2.1):
            // `1`–`5` stay star ratings, so culling keeps its Lightroom muscle memory.
            //
            // Written out rather than looped over `Workspace.allCases`, deliberately.
            // `KeyGrammarTests` scans these files as TEXT for `.keyboardShortcut` call
            // sites and asserts set-equality against `KeyGrammar` in both directions —
            // an attached chord with no entry fails, and an entry nothing attaches
            // fails. A computed `KeyEquivalent` is invisible to that scanner, so the
            // elegant loop would silently opt these four keys out of the one mechanism
            // that catches a dead shortcut.
            // ONE MENU FOR GOING PLACES — the palette and the four workspaces
            // together, because they are the same verb: the palette is "go to a control
            // I can name" and the workspaces are "go to a part of the app", and a
            // photographer looking for either looks in the same place.
            //
            // It is also what keeps this builder legal. `Commands` builders take at most
            // ten children, the group below was at exactly ten, and adding an eleventh
            // fails as `'buildExpression' is unavailable` on the ELEVENTH line rather
            // than saying anything about arity — an error that reads as "this expression
            // does not conform to Commands" about an expression that plainly does.
            // Nesting a second `Group` would have satisfied the compiler and left two
            // menus that should always have been one.
            // THE VIEW MENU, which is the cheapest possible answer to "it's super
            // difficult for me to navigate the app."
            //
            // 45 of this app's 65 keyboard actions had no menu item, and there was no
            // View menu at all — so Compare and Survey, two of the four primary view
            // modes, had NO pointer entry point of any kind. The only way to discover
            // them was to press C or N, printed in a sheet behind ⌘/. docs/12's law is
            // "every action has a key; every key action has a menu item", and the app
            // was satisfying exactly half of it.
            //
            // The bare keys are shown in the labels rather than attached as
            // `.keyboardShortcut`. That is deliberate and it is a compromise:
            // `KeyDispatcher` owns them through an `NSEvent` monitor, and claiming them
            // here would make the dispatcher's cases dead and break the set-equality
            // `KeyGrammarTests` asserts between the two. The real end state is docs/12's
            // — generate the menu FROM `KeyGrammar` so neither can drift — and that is a
            // larger change than this. Meanwhile the actions become findable, which is
            // the whole complaint.
            CommandMenu("View") {
                // GROUPED BECAUSE A BUILDER TAKES TEN CHILDREN, and this menu has
                // fifteen. The compiler does not say "too many children" — it says
                // `'buildExpression' is unavailable` on the eleventh line and then once
                // per sibling, which reads as a type error in code that is plainly a
                // View. `KeyGrammarTests` guards the outer `Commands` group against
                // exactly this; menu contents are the same limit one level in.
                Group {
                    Button("Grid — G") { state.showGrid() }
                    Button("Loupe — E") { state.showLoupe() }
                    Button("Compare — C") { state.toggleCompare() }
                    Button("Survey — N") { state.toggleSurvey() }
                    Divider()
                    // ⌘1 USED TO LIE. `PanelLayout.select` only mutates the layout
                    // value — structurally it cannot reach `viewMode`, since
                    // `WorkspaceLayout` lives in LumenCore with no access to `AppState`
                    // — so pressing ⌘1 for "Cull" removed the develop column and left
                    // the photographer looking at one large photograph with 320 points
                    // of empty space where the panel had been. The app's most prominent
                    // navigation control was named after a mode it did not enter.
                    //
                    // Pairing it here was the smallest fix and it was the wrong shape:
                    // ⌘3 then needed its own second line to arm the crop tool, and the
                    // TAB STRIP — which calls neither of these — got no fix at all, which
                    // is how the owner came to be looking at the Crop workspace with no
                    // rectangle on his photograph. `AppState.enter` is the one verb now,
                    // and these five are five names for it.
                    Button("Cull") { state.enter(.cull) }
                        .keyboardShortcut("1", modifiers: [.command])
                    Button("Develop") { state.enter(.develop) }
                        .keyboardShortcut("2", modifiers: [.command])
                    Button("Crop") { state.enter(.crop) }
                        .keyboardShortcut("3", modifiers: [.command])
                    Button("Grade") { state.enter(.grade) }
                        .keyboardShortcut("4", modifiers: [.command])
                    Button("Deliver") { state.enter(.deliver) }
                        .keyboardShortcut("5", modifiers: [.command])
                }
                Group {
                    Divider()
                    // In the Scene rather than beside the palette itself, for the reason
                    // ⌘1-⌘4 are: a `.keyboardShortcut` on a view that is not in the
                    // hierarchy is never registered, and the palette does not exist
                    // until this opens it.
                    Button("Go to a Control…") { state.showControlPalette = true }
                        .keyboardShortcut("k", modifiers: [.command])
                    Divider()
                    Button(state.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                        state.sidebarVisible.toggle()
                    }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    Divider()
                    Button("Filmstrip — F") { state.showFilmstrip.toggle() }
                    Button("Histogram — H") { state.showHistogram.toggle() }
                    Button("Scopes — S") { state.showScopes.toggle() }
                    // A NESTED GROUP, because a `ViewBuilder` block takes ten children
                    // and this one had reached it. `KeyGrammarTests` counts them, which
                    // is the only thing that says so in a sentence: the compiler's own
                    // answer is that `buildExpression` is unavailable, pointed at the
                    // whole block.
                    Group {
                        Divider()
                        // THE SURROUND, which docs/00's Law 7 makes part of the
                        // instrument. Both keys were named in docs/12 and neither was
                        // bound, because neither feature existed: `L` had been spent on
                        // the Look panel and ⌘B on the target album. The rules live in
                        // `ViewingConditions`, in LumenCore, where they are tested.
                        Button("Lights Out — L") { state.cycleLightsOut() }
                        // ⌘B rather than a bare key, and through a menu rather than
                        // through `KeyDispatcher`: command-modified keys are menu
                        // territory here (`Keymap.swift` returns false for them), which
                        // is the rule that keeps ⌘C, ⌘V and ⌘E working in a text field.
                        Button(state.assessmentMode
                               ? "Assessment Surround (on)" : "Assessment Surround") {
                            state.toggleAssessmentMode()
                        }
                        .keyboardShortcut("b", modifiers: [.command])
                    }
                }
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

            // THE EDIT MENU, AND THE FOUR CHORDS IT WAS TAKING FROM EVERY TEXT FIELD.
            //
            // `CommandGroup(replacing: .pasteboard)` does not add items beside AppKit's
            // Cut/Copy/Paste/Select All — it deletes them and puts these in their place,
            // for the whole application, in every context. And a menu item's key
            // equivalent is offered by `NSMenu` BEFORE the key window's responder chain
            // sees the event, which is the same rule that made ⌘B a dead shortcut on the
            // album button. So inside a keyword field, a new-album field, the export
            // sheet's filename or any other place a photographer types, ⌘C copied a
            // recipe rather than the selected text, ⌘V pasted one over it, ⌘A selected
            // photographs, and ⌘X did nothing whatever — because AppKit's Cut item had
            // been deleted with the rest of the group and nothing replaced it. Those are
            // the four oldest chords on this platform and the app owned all of them.
            //
            // THE CARVE-OUT IS IN THE ACTION, NOT IN A SECOND SET OF ITEMS, and that is
            // forced as well as preferred. Two branches of items would attach ⌘C twice in
            // this file, and `KeyGrammarAttachmentTests` fails on any chord attached
            // twice — correctly, because a menu bar built from a stale `if` is exactly
            // the kind of shortcut that goes dead without saying so. One item per chord,
            // which offers the key to whatever is typing and falls through to the photo
            // verb when nothing is: `TextEditingFocus` in `LumenFocus.swift` holds the
            // predicate, shared with `KeyDispatcher`, and its header holds the argument
            // for why focus is read at key time rather than published.
            CommandGroup(replacing: .pasteboard) {
                Group {
                    // ⌘X BELONGS TO THE TEXT FIELD ALONE. It is bound here and nowhere
                    // else because Lumen has no cut: a photograph is never moved out of
                    // anything by this application — the folder is the library, files are
                    // never modified, and removing a frame from an album is a right-click
                    // verb on a row rather than a pasteboard operation. Inventing a photo
                    // meaning to fill the item would be a chord nobody asked for standing
                    // in front of the one everybody expects.
                    //
                    // It stays ENABLED outside a text field rather than greying out.
                    // Enablement is read when the menu's body runs and focus is not
                    // published — deliberately, `TextEditingFocus`'s header says why — so
                    // a `.disabled` here would be stale in exactly the moment it was for.
                    // An item that does nothing is a smaller lie than one that is grey
                    // while the cursor is blinking in a field.
                    Button("Cut") { _ = TextEditingFocus.cut() }
                        .keyboardShortcut("x", modifiers: [.command])
                    Button("Copy Settings") {
                        if TextEditingFocus.copy() { return }
                        state.copySettings()
                    }
                    .keyboardShortcut("c", modifiers: [.command])
                    Button("Paste Settings") {
                        if TextEditingFocus.paste() { return }
                        state.pasteSettings()
                    }
                    .keyboardShortcut("v", modifiers: [.command])
                    // Masks are geometry in SOURCE coordinates, so a radial over a face in
                    // one frame lands on a shoulder in the next. Pasting a whole recipe
                    // across forty frames therefore destroys forty sets of local work to
                    // deliver one white balance, and Lightroom's answer is a checkbox
                    // dialog you answer identically nine times in ten. Two commands cost
                    // nothing and ask nothing.
                    //
                    // No carve-out on these four: ⇧⌘V, ⌥⌘C, ⌥⌘V and ⇧⌘R are not editing
                    // chords anywhere on the system, so a text field never wanted them.
                    Button("Paste Settings Without Masks") {
                        state.pasteSettingsWithoutMasks()
                    }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(!state.hasCopiedSettings)
                    Button("Paste Masks") { state.pasteMasks() }
                        .disabled(!state.hasCopiedMasks)
                }
                // A SECOND GROUP because a builder takes ten children and Cut made this
                // one eleven. Split where the divider already was rather than at the
                // count, so the nesting matches a boundary the menu itself draws.
                Group {
                    Divider()
                    // The look-only pair is the point of the Develop/Look split: one look
                    // across a whole shoot without touching each frame's own corrections.
                    Button("Copy Look") { state.copyLook() }
                        .keyboardShortcut("c", modifiers: [.command, .option])
                    Button("Paste Look") { state.pasteLook() }
                        .keyboardShortcut("v", modifiers: [.command, .option])
                    Divider()
                    Button("Reset Settings") { state.resetToImported() }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                }
            }

            CommandGroup(after: .pasteboard) {
                // ⌘A IS THE OTHER HALF OF THE SAME CARVE-OUT. `.pasteboard` covers Select
                // All as well as Cut/Copy/Paste, so replacing that group deleted the text
                // field's ⌘A too and this item inherited it — which is how "select all"
                // inside a filename came to select every photograph in the folder.
                Button("Select All") {
                    if TextEditingFocus.selectAll() { return }
                    state.selectAll()
                }
                .keyboardShortcut("a", modifiers: [.command])
                // ⌘D stays whole: macOS spends it on Duplicate and on Don't Save, never
                // on anything inside a text field, so there is nothing here to give back.
                Button("Select None") { state.selectNone() }
                    .keyboardShortcut("d", modifiers: [.command])
            }

            CommandMenu("Photo") {
                Group {
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
                // THE THREE CHORDS ⌥⌘S USED TO KILL, and they are here for the reason
                // ⌘1–⌘5 are: a `.keyboardShortcut` on a view that is not in the hierarchy
                // is never registered, and a `Scene`'s commands always are.
                //
                // All three were attached to buttons inside the sources sidebar, and
                // ⌥⌘S does not merely hide that column — `NavigationSplitView` at
                // `.detailOnly` takes it out of the tree, taking every key equivalent in
                // it along. So Stack, Unstack and Keyword were dead for as long as the
                // sidebar was hidden, silently, while the Help sheet went on printing all
                // three. The sidebar had already learned half of this lesson: its own
                // comments explain that a shortcut inside a COLLAPSED SECTION is dead and
                // move each one above the fold, which fixes the triangle and leaves the
                // column itself as the larger `if` nobody looked at.
                //
                // The buttons stay where they are — the verbs belong beside the stack
                // they act on — they simply no longer carry the chord. One chord, one
                // site (`KeyGrammarAttachmentTests`).
                //
                // Enabled on "there is a catalog", which is the fact these three actually
                // need and the one `CommandState` publishes. Not on the selection: both
                // stack verbs already refuse politely and say why in the status bar
                // ("Select two or more photos to stack them"), which is more than a grey
                // menu item can do.
                Group {
                    Divider()
                    Button("Stack Selection") { state.stackSelection() }
                        .keyboardShortcut("g", modifiers: [.command])
                        .disabled(!commands.hasCatalog)
                    Button("Unstack") { state.unstackSelection() }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .disabled(!commands.hasCatalog)
                    // ⇧⌘K MEANS "LET ME TYPE A KEYWORD" — it applies nothing, it puts the
                    // cursor in the field. So the menu has to do two things the sidebar's
                    // own button never had to: show the column, because the chord is now
                    // reachable while it is hidden, and then ask for the keyboard. The
                    // request goes through `KeywordEntry` rather than a flag on `AppState`
                    // because `@FocusState` is view-local by construction — only the
                    // section that draws the field can put the cursor in it.
                    Button("Keyword the Selection…") {
                        state.sidebarVisible = true
                        KeywordEntry.shared.request()
                    }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!commands.hasCatalog)
                }
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

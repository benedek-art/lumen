// LumenFocus.swift
// Focus, expressed as a surface instead of as a ring.
//
// A LEAF FILE ON PURPOSE (docs/28 Part 9). `LumenApp` compiles only on macOS and this
// machine cannot build it, so the surface checker and `swiftc -parse` are the only
// guards a change gets before CI. Neither sees type-level errors. `.focusable()`,
// `.focusEffectDisabled()` and `@FocusState` on a custom control are new to this
// codebase, so they live in one small file where a mistake fails in one place instead of
// scattering through the slider.
//
// WHY THE RING WENT. It drew a 1.5-point `Lumen.accent` border around the whole slider
// row, and the owner reported it as a defect on sight: "when I press on something, for
// example, highlight, it gets a blue border around it, which I don't want." He was not
// describing a corner case. `.focusable()` takes focus on MOUSE-DOWN, so the ring fired
// on the first event of every drag of every slider in the app — a chromatic outline
// snapping on beside the photograph, in a window whose whole argument is that no hue may
// sit next to a colour judgement (Law 7, docs/00). The accent policy that admitted it
// says "marker scale, never area"; a border around a 304-point row is area.
//
// IT COULD NOT SIMPLY BE DELETED. `.focusEffectDisabled()` (LumenControls) turns the
// system halo off, and the row's whole keyboard affordance hangs off focus actually
// being held: ←/→ nudge and Escape reach the slider only because `rowFocused` →
// `sliderFocusChanged` → `AppState.sliderHoldsFocus` makes `KeyDispatcher` stand down.
// Removing the ring and drawing nothing would have left the app's one focusable control
// with an invisible state, which is worse than a loud one.
//
// So focus moved onto the channel hover already speaks — the row's own surface — and
// climbed one rung of the ladder rather than changing axis: hover fills
// `Lumen.controlHover` (0.27), focus fills `Lumen.controlActive` (0.31). That is the
// same rest/hover/active triple every button and chip in the app already uses, so focus
// now looks like "this control is engaged" instead of like an error state. Zero chroma,
// no stroke, and no layout: a ring that changed a row's height on focus would make the
// whole panel jump as the arrows moved between rows.
//
// AND THEN THE HOVER RUNG CAME BACK OUT, one review later: "I would remove a bunch of
// the hover effects, like hovering over the white balance or the temperature or tint,
// stuff like that. I don't really like the fact that I can get that hover effect."
//
// He asked for hover on everything in the review before this one, and both requests are
// right, because a slider row is not the same kind of thing as a button. A button needs
// hover to say "this is pressable" — its whole affordance is that it can be clicked and
// nothing about a word in a panel says so on its own. A slider says what it is by
// LOOKING like a slider: there is a groove and a thumb sitting in it. The fill added
// nothing to that, and it cost something real, because these rows are what a photographer
// sweeps the pointer across on the way to the picture. Eleven of them lighting up in
// sequence is a wave of grey moving through the panel beside a photograph somebody is
// trying to judge the tone of — motion in the peripheral vision of a colour decision,
// which is the one thing docs/00's Law 4 says the surround may never do.
//
// So the fill is focus-only now, and the surviving hover in this app is on things you
// can click: headers, chevrons, tabs, buttons, chips. The keyboard state keeps its
// surface, because that is the state with nothing else to show it.
//
// AND THEN THE FILE GREW A SECOND HALF, because focus turned out to be two questions
// and this codebase was only answering one of them. The modifiers above are "how does a
// control SHOW that it holds the keyboard". Below them is "WHERE IS the keyboard", which
// is a different question with a different answer and, until now, two hand-rolled
// copies waiting to disagree with each other. Both live here so there is one file to
// read when the answer changes.

#if os(macOS)

import AppKit
import SwiftUI

extension View {

    /// Say that this row holds the keyboard, without a ring and without a hover.
    ///
    /// Drawn as a background rather than an overlay, because an overlay would sit ON the
    /// groove it is reporting — dimming the instrument in order to announce that you can
    /// type at it. It is the same fill `lumenHoverable()` paints one rung lower, so a
    /// focused row and a hovered button are visibly the same family of state.
    ///
    /// NO HOVER RUNG. It had one and the owner asked for it to go; the file header holds
    /// the argument. What is left is a single binary fill, which is also why this no
    /// longer needs `@State` of its own.
    func lumenFocusSurface(focused: Bool,
                           radius: CGFloat = Lumen.radiusControl) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(focused ? Lumen.controlActive : Color.clear))
            .contentShape(Rectangle())
            // Animated on the value rather than on the view, so losing focus fades out
            // rather than snapping — the asymmetry the eye reads as responsiveness.
            .animation(Lumen.motionState, value: focused)
    }

    /// Focus for a control that has no instrument of its own to look engaged.
    ///
    /// A slider row does not need this and must not have it — the owner rejected an
    /// accent border on a row on sight, the header above holds his words, and the row
    /// has a groove and a thumb that can carry the state instead. A menu trigger, a
    /// switch, a checkbox or a bare text button has nothing: they are a word or a small
    /// shape, and a fill alone on something that small reads as "selected" rather than
    /// as "the keyboard is here".
    ///
    /// So the ring exists, and it is scoped to exactly those. 1.5 pt of accent at 60%,
    /// drawn as a `strokeBorder` so it grows INWARD and cannot change the control's
    /// footprint — an outward ring would move every neighbour as focus stepped along a
    /// row of them.
    ///
    /// This is the U1 mockup's focus treatment, admitted for the controls it was right
    /// about and refused for the one it was not. The mockup showed it on everything.
    func lumenFocusRing(focused: Bool,
                        radius: CGFloat = Lumen.radiusControl) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(focused ? Lumen.focusRing : Color.clear,
                              lineWidth: Lumen.focusRingWidth))
            .animation(Lumen.motionState, value: focused)
    }
}

// MARK: - Where the keyboard is

/// The app's one answer to "is the photographer typing right now", and the four
/// standard editing chords forwarded to whatever is doing it.
///
/// TWO PLACES HAVE TO STAND DOWN FOR A TEXT FIELD and only one of them knew it.
/// `KeyDispatcher` did, from the beginning: its `NSEvent` monitor sits in front of the
/// responder chain, so without a first-responder test a `p` typed into the keyword box
/// flagged the photograph behind it. That test was written out inline in `Keymap.swift`
/// and nowhere else, which was fine for exactly as long as the monitor was the only
/// thing in front of a text field.
///
/// It was not. The MENU BAR is in front of it too, and further in front: a menu item's
/// key equivalent is offered by `NSMenu` before the key window's responder chain sees
/// the event at all. `LumenApp`'s Edit menu replaces the whole `.pasteboard` group with
/// the develop-settings verbs, so ⌘C, ⌘V and ⌘A were answered by the photo grammar
/// wherever the keyboard happened to be — including inside a keyword field, a new-album
/// field or an export filename, where ⌘C copied a recipe instead of the selected text,
/// ⌘V pasted one over it, ⌘A selected photographs, and ⌘X was bound to nothing at all
/// because AppKit's Cut item had been replaced along with the rest of the group. Those
/// four chords are the oldest agreement on this platform and the app was taking all of
/// them.
///
/// ASKED AT KEY TIME, NEVER PUBLISHED, and that is the design rather than a shortcut.
/// A `@Published var textFieldHasFocus` would be a second copy of a fact AppKit already
/// holds — the two-sources-of-truth shape this codebase has closed repeatedly — and it
/// would have to be maintained from `NSWindow` notifications, so it can only ever be
/// correct as of the last event it was told about. The one event where being a beat
/// stale matters is the keypress itself. A menu action closure runs at the moment the
/// chord is pressed, so reading the responder there is both simpler and strictly more
/// correct. It also keeps focus off `CommandState`, whose entire reason for existing is
/// that the menu bar must not rebuild for facts that move while a photographer works.
///
/// WHAT THIS COSTS, said out loud: the menu item's LABEL cannot follow focus. The Edit
/// menu says "Copy Settings" whether or not a field has the keyboard, because a title
/// is read at body time and only a publish would move it. The chord does the right
/// thing; the word above it names the photo verb. Making the label honest means making
/// focus publish, and the paragraph above is why that trade is refused.
@MainActor
enum TextEditingFocus {

    /// True while the keyboard belongs to a text field.
    ///
    /// The field editor is what actually holds first-responder while an `NSTextField`
    /// is being edited — a shared `NSTextView` the window lends to the control — so the
    /// `NSTextView` arm is the one that fires for every SwiftUI `TextField` in the app.
    /// `NSTextField` is checked as well for the moment before editing begins.
    static var isActive: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    /// The four below each return TRUE when a text field took the chord, so a menu item
    /// can offer it the key first and fall through to its photo verb otherwise. Sent to
    /// `nil`, which is what makes them go to the first responder rather than to any
    /// particular field: `NSApplication` walks the chain from whatever is typing.
    ///
    /// Guarded by `isActive` rather than trusting `sendAction` to fail: outside a text
    /// field something else in the chain may well answer `selectAll:`, and a photo verb
    /// that silently stopped happening because a scroll view accepted the selector is
    /// exactly the kind of defect nobody would find.
    static func cut() -> Bool {
        guard isActive else { return false }
        return NSApp.sendAction(#selector(NSTextView.cut(_:)), to: nil, from: nil)
    }

    static func copy() -> Bool {
        guard isActive else { return false }
        return NSApp.sendAction(#selector(NSTextView.copy(_:)), to: nil, from: nil)
    }

    static func paste() -> Bool {
        guard isActive else { return false }
        return NSApp.sendAction(#selector(NSTextView.paste(_:)), to: nil, from: nil)
    }

    static func selectAll() -> Bool {
        guard isActive else { return false }
        return NSApp.sendAction(#selector(NSTextView.selectAll(_:)), to: nil, from: nil)
    }
}

// MARK: - Asking for the keyboard

/// A request for the cursor to land in the sidebar's keyword field, from a menu that
/// cannot reach it.
///
/// ⇧⌘K MEANS "LET ME TYPE A KEYWORD", and until now it was attached to a button inside
/// the Keywords section of the sources sidebar. A `.keyboardShortcut` on a view that is
/// not in the hierarchy is never registered — the rule this file's neighbours have paid
/// for three times — and ⌥⌘S takes the whole sidebar out of the hierarchy. So the one
/// chord for keywording died the moment a photographer hid the column, silently, while
/// the Help sheet went on promising it.
///
/// The chord lives in the Scene's commands now, where it is registered in every state
/// of the window. The verb it performs still belongs to the sidebar, because the cursor
/// has to land in a specific `TextField` and `@FocusState` is view-local by
/// construction — so the menu raises a request here and the column answers it.
///
/// A COUNTER RATHER THAN A BOOL, deliberately: pressing ⇧⌘K twice in a row must put the
/// cursor back in the field the second time, and a `true` that is already `true`
/// publishes nothing. The same shape `PanelLayout` and `LoupeViewport` use for the
/// verbs a menu asks a view to perform.
///
/// NOT `@MainActor` ON THE TYPE, matching those two and for their reason: a `static let`
/// singleton of an actor-isolated class cannot be built from a view's property
/// initialiser, which is exactly how the sidebar will hold this one. The one verb is
/// called from a menu action and read from a body, both already on the main actor.
final class KeywordEntry: ObservableObject {

    static let shared = KeywordEntry()

    private init() {}

    /// Bumped by ⇧⌘K; watched by the sidebar's Keywords section.
    @Published private(set) var requests = 0

    func request() { requests &+= 1 }
}

#endif

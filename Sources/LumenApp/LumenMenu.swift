// LumenMenu.swift
// The dropdown, rebuilt — because the one macOS gives you is the loudest remaining tell
// that this app was assembled rather than designed.
//
// The owner's third review, and it is the only item he repeated twice: "These dropdowns
// are extremely boring, and I don't like the looks of it at all. I don't like any of these
// dropdown visuals. I feel like they are very basic, and they're very, very old Apple
// view. And honestly, I would remove most of these or rebuild them to be a little better.
// And that is basically every dropdown in the app."
//
// WHAT HE IS LOOKING AT. `Menu` and `Picker(.menu)` render an `NSPopUpButton`: a bezelled
// grey capsule with a blue-tinted chevron well on its right, drawn by AppKit at the system
// accent colour, at the system corner radius, in the system font, with the system's own
// pull-down list of 13-point rows and blue selection highlight. Nothing about it can be
// styled — `.buttonStyle`, `.tint`, `.controlSize` and `.menuStyle` between them reach the
// bezel and none of them reach the LIST — so this app's entire visual argument (zero
// chroma beside a photograph, a 14-point radius, a 12-point type scale, an elevation
// ladder lit from above) stops at the edge of every one of the twenty-odd popups in it.
// They are the one control that still looks like 2008 because they are the one control
// this codebase never drew.
//
// AND IT IS NOT ONLY LOOKS. The blue is a Law 7 violation (docs/00: no hue may sit beside
// a colour judgement) that survived four design passes purely because AppKit painted it
// rather than us. The soft-proof space popup sits four inches from the photograph.
//
// SO THIS DRAWS IT. A trigger that is a Lumen surface with a Lumen radius and a Lumen
// hover, and a popover whose rows are Lumen rows — checkmark on the left where the eye
// looks for state, optional glyph, optional right-hand annotation for the thing a label
// cannot say.
//
// THE ONE THING NOT REBUILT is `.contextMenu`. A right-click menu is an OS-level surface
// with no SwiftUI-visible content view, it is invoked by a gesture rather than by a
// control, and nobody looking at the app sees one unless they go looking. The owner's
// complaint is about the buttons he can see; those are these.

#if os(macOS)
import SwiftUI

// MARK: - Dismissal

/// How a row inside an open menu closes the menu it is in.
///
/// Through the environment rather than through a closure threaded into every call site,
/// because the content is a `@ViewBuilder`: the rows are built by the caller and there is
/// nowhere to hand them a parameter without making every menu in the app take a closure
/// argument it would then have to remember to forward. A menu that stays open after a
/// choice is the defect this is guarding against, and it is the kind that gets shipped
/// once per call site.
private struct LumenMenuDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var lumenMenuDismiss: () -> Void {
        get { self[LumenMenuDismissKey.self] }
        set { self[LumenMenuDismissKey.self] = newValue }
    }
}

// MARK: - The menu

/// A pull-down whose list this application draws.
///
/// `title` is what the trigger shows — for a picker that is the chosen value, and for a
/// command menu it is a verb. The content is any stack of `LumenMenuItem`,
/// `LumenMenuHeader` and `LumenMenuDivider`.
struct LumenMenu<Content: View>: View {

    let title: String
    /// A glyph before the title on the TRIGGER. Optional, and mostly used by command
    /// menus where the icon is the faster read.
    var symbol: String?
    /// Draw the trigger as a glyph alone, for strips where a word would not fit.
    var iconOnly: Bool = false
    /// OPEN IN PLACE INSTEAD OF IN A POPOVER, for the one menu that lives inside another
    /// popover.
    ///
    /// macOS will not nest them. A SwiftUI `.popover` is an `NSPopover`, an `NSPopover` is
    /// transient by default, and a transient popover closes when it loses key — which is
    /// exactly what presenting a second one does. So the Filter popover's metadata menu,
    /// left as a popover, would have dismissed its own parent on the click that opened it
    /// and both would have vanished. `NSMenu` does not have this problem, because it runs
    /// its own modal tracking loop rather than taking key, which is why nobody noticed
    /// while these were all `Menu`s.
    ///
    /// Rather than leave that one site on the AppKit control the owner asked to be rid
    /// of, it expands downward inside its parent. It is arguably the better shape there
    /// anyway: a list that pushes the popover open reads as part of the filter you are
    /// building, where a second floating panel over the first reads as a stack of
    /// windows.
    var inline: Bool = false
    /// Widen the trigger so a row of them lines up, or let it hug its title.
    var minWidth: CGFloat?
    var help: String?
    @ViewBuilder var content: () -> Content

    @State private var isOpen = false
    /// View-local, like every other hover flag in this app: a pointer crossing a panel
    /// must never publish through an `ObservableObject` (`LumenHoverModifier`, and what
    /// `CommandState` cost before it).
    @State private var hovering = false

    private var fill: Color {
        if isOpen { return Lumen.controlActive }
        if hovering { return Lumen.controlHover }
        return Lumen.controlSurface
    }

    @ViewBuilder
    var body: some View {
        if inline {
            VStack(alignment: .leading, spacing: 3) {
                trigger
                if isOpen {
                    VStack(alignment: .leading, spacing: 1) {
                        content()
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A WELL, not a card: the list is opening INSIDE something rather
                    // than over it, so it should read as a recess in the surface it
                    // pushed apart. `windowBase` is one step below `panel`, which is the
                    // same relationship the trough between two section cards has.
                    .background(Lumen.windowBase)
                    .lumenWell(radius: Lumen.radiusControl)
                    .environment(\.lumenMenuDismiss, { isOpen = false })
                    // The same unfold every other disclosure in this app uses. A list
                    // that appears instantly inside a popover reads as the popover
                    // having been replaced rather than having grown.
                    .transition(.opacity.combined(
                        with: .scale(scale: 0.97, anchor: .top)))
                }
            }
            // On the stack rather than on the trigger: what moves when this opens is the
            // list arriving and everything below it being pushed down, and neither of
            // those is inside the button.
            .animation(.spring(response: 0.26, dampingFraction: 1), value: isOpen)
        } else {
            trigger
                .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        content()
                    }
                    .padding(5)
                    .frame(minWidth: max(minWidth ?? 0, 168), alignment: .leading)
                    // `.fixedSize` vertically only: the popover should be exactly as tall
                    // as its rows and at least as wide as the trigger that opened it,
                    // which is the proportion a pull-down is supposed to have and the one
                    // AppKit gets right.
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Lumen.panel)
                    // THE SYSTEM'S OWN GROUND, REPLACED. A macOS popover paints a vibrancy
                    // material behind whatever you put in it — the frosted, faintly
                    // blue-shifted panel every stock menu in the OS sits on — and a
                    // `.background` inside the content cannot reach it: the material is
                    // under the content view, not behind the rows. Left alone, this
                    // control would have swapped an AppKit popup for a hand-drawn list on
                    // the same AppKit ground, which is most of the way to the same
                    // complaint. `presentationBackground` is the one modifier that reaches
                    // the presentation itself. `Lumen.panel` is the flat 0.20 grey the
                    // develop column is painted in, so an open menu reads as an extension
                    // of the panel that opened it rather than as a window from a
                    // different application.
                    //
                    // Vibrancy is also a Law 7 problem, not only a stylistic one: a
                    // translucent surface takes its tint from whatever is behind it, and
                    // what is behind this is a photograph somebody is judging the colour
                    // of.
                    .presentationBackground(Lumen.panel)
                    .environment(\.lumenMenuDismiss, { isOpen = false })
                }
        }
    }

    private var trigger: some View {
        Button {
            // OPENS RATHER THAN TOGGLES — but only when the list is a popover, and the
            // distinction is a bug this repository has already paid for once.
            //
            // `FilterBar.filterButton` carries the finding: "A popover eats the click
            // that dismisses it, so a toggle here would close and immediately reopen when
            // you click the button that is already showing one." The dismissing click
            // both closes the popover — through the `isPresented` binding — and then
            // reaches the button underneath, so a `toggle()` reads false, flips to true,
            // and the menu never appears to close. The photographer sees a control that
            // ignores every second click.
            //
            // A popover therefore closes the way every popover on this platform closes:
            // Escape, a click outside, or choosing something. An INLINE list has no
            // outside to click, so there the trigger is the only way back and it must
            // toggle.
            if inline {
                isOpen.toggle()
            } else {
                isOpen = true
            }
        } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.secondaryText)
                }
                if !iconOnly {
                    Text(title)
                        .font(.lumenBody)
                        .foregroundStyle(Lumen.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // ONE CHEVRON, TURNED — the same move the section headers make, and
                    // for the same reason. `chevron.up.chevron.down` is AppKit's glyph for
                    // "this is a popup" and it says it by being busy: two arrows, six
                    // strokes, at the size of the text beside it. A single chevron that
                    // rotates when the list opens says the same thing with a third of the
                    // ink AND reports state, which the double glyph cannot do at all.
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Lumen.secondaryText)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Lumen.rowHeight, alignment: .leading)
            .frame(minWidth: minWidth, alignment: .leading)
            // The lit top edge every other surface in the app carries. `.flush` rather
            // than `.raised`: a popup sits IN a row of controls, and a cast shadow under
            // one control in a stack of twelve reads as a mistake rather than as height.
            .lumenSurface(radius: Lumen.radiusControl, elevation: .flush, fill: fill)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .lumenClickCursor()
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(response: 0.26, dampingFraction: 1), value: isOpen)
        .help(help ?? title)
    }
}

// MARK: - The rows

/// One choice inside a `LumenMenu`.
///
/// THE CHECKMARK COLUMN IS ALWAYS RESERVED, whether or not anything in this menu is
/// selectable. A tick that appears and shifts every label four points right is the same
/// class of defect as a Reset button that inserts itself on hover: the list moves under
/// the pointer that came to read it.
struct LumenMenuItem: View {

    let title: String
    /// A glyph for this row. The curve presets, the mask kinds and the aspect ratios all
    /// have one; a colour space does not, and inventing one would be decoration.
    var symbol: String?
    /// The right-hand annotation — a shortcut, a ratio, a pixel count. Dimmer and
    /// trailing, so it reads as an aside rather than as a second title.
    var detail: String?
    var isSelected: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    @Environment(\.lumenMenuDismiss) private var dismiss
    @State private var hovering = false

    var body: some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Lumen.primaryText)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 10, alignment: .leading)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.lumenCaption)
                        .foregroundStyle(isEnabled ? Lumen.secondaryText : Lumen.tertiaryText)
                        .frame(width: 14, alignment: .center)
                }
                Text(title)
                    .font(isSelected ? .lumenBodyStrong : .lumenBody)
                    .foregroundStyle(isEnabled ? Lumen.primaryText : Lumen.tertiaryText)
                    .lineLimit(1)
                Spacer(minLength: 10)
                if let detail {
                    Text(detail)
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.tertiaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous)
                    .fill(hovering && isEnabled ? Lumen.controlHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// A group title inside a menu — "Standard", "Recent", "This photograph".
struct LumenMenuHeader: View {
    let title: String

    var body: some View {
        LumenCapsLabel(text: title, size: 10, color: Lumen.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The rule between two groups. Inset to the rows' own text edge rather than run wall to
/// wall, so it separates the list rather than cutting the panel in half.
struct LumenMenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Lumen.separator)
            .frame(height: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }
}

// MARK: - The picker

/// One option in a `LumenMenuPicker`.
struct LumenMenuOption<Value: Hashable>: Identifiable {
    let value: Value
    let label: String
    var symbol: String?
    var detail: String?

    var id: Value { value }

    init(_ value: Value, _ label: String, symbol: String? = nil, detail: String? = nil) {
        self.value = value
        self.label = label
        self.symbol = symbol
        self.detail = detail
    }
}

/// A labelled row whose control is a `LumenMenu` over a fixed list — the shape
/// `Picker(.menu)` was being used for everywhere, drawn the way this app draws rows.
///
/// It takes `Lumen.labelWidth` for the name so a column of these lines up with the column
/// of sliders above and below it, which `Picker`'s own label never did: AppKit sizes the
/// label to the text, so five popups in a panel had five different left edges for their
/// controls.
struct LumenMenuPicker<Value: Hashable>: View {

    /// The row's name. Empty means no label column at all — for the pickers that sit
    /// inside a `HStack` somebody else has already labelled.
    var title: String = ""
    let options: [LumenMenuOption<Value>]
    @Binding var selection: Value
    var help: String?

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? "—"
    }

    private var currentSymbol: String? {
        options.first { $0.value == selection }?.symbol
    }

    var body: some View {
        HStack(spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.secondaryText)
                    .frame(width: Lumen.labelWidth, alignment: .leading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
            LumenMenu(title: currentLabel, symbol: currentSymbol, help: help) {
                ForEach(options) { option in
                    LumenMenuItem(title: option.label,
                                  symbol: option.symbol,
                                  detail: option.detail,
                                  isSelected: option.value == selection) {
                        selection = option.value
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Lumen.rowHeight)
        .padding(.vertical, 2)
    }
}
#endif

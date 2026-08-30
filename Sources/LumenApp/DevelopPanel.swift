// DevelopPanel.swift
// The develop column: a section switcher, the active section's scrollable stack of
// panels, and a footer of the four gestures that operate on the whole recipe.
//
// Three rules this file exists to enforce:
//   · Every edit goes through `AppState.updateRecipe(coalescingKey:)` with a key that
//     names the control, so one drag is one undo step (docs/12 §12.10) and no panel
//     has to implement coalescing itself.
//   · Every slider is a `LumenSlider`. The slider contract (D45) lives in exactly one
//     place, and a panel that hand-rolls a row is a bug the user feels before they can
//     name it.
//   · A section that is at its defaults says so, and a section that is not offers to
//     put it back. "What did I change?" is answerable at a glance, not from memory.
//
// The panel edits `AppState.editTargets` — the whole selection when there is one —
// while it *displays* `primarySelection`'s values, which is what makes adjusting 40
// frames feel like adjusting one.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

// MARK: - Recipe binding

/// The one way a panel reaches into a recipe. Every binding produced here routes its
/// setter through `updateRecipe(coalescingKey:)`, so the coalescing key is impossible
/// to forget: you cannot make a binding without naming the control.
///
/// Optional recipe fields (`RawParams.temp`, `CaptureSharpen.radius`, …) mean "let the
/// stage decide" rather than "zero". A slider cannot show "no value", so the `orAuto:`
/// overload takes the value the UI stands in while the field is nil; the first move
/// writes a concrete number and the panel offers an explicit way back to nil.
@MainActor
struct RecipeBinder {
    let state: AppState

    /// A plain numeric field.
    func value(_ path: WritableKeyPath<Recipe, Double>, _ key: String) -> Binding<Double> {
        let state = self.state
        return Binding(
            get: { state.currentRecipe[keyPath: path] },
            set: { newValue in
                state.updateRecipe(coalescingKey: key) { $0[keyPath: path] = newValue }
            })
    }

    /// An optional numeric field, shown as `auto` while it is nil.
    func value(_ path: WritableKeyPath<Recipe, Double?>, _ key: String,
               orAuto auto: Double) -> Binding<Double> {
        let state = self.state
        return Binding(
            get: { state.currentRecipe[keyPath: path] ?? auto },
            set: { newValue in
                state.updateRecipe(coalescingKey: key) { $0[keyPath: path] = newValue }
            })
    }

    func flag(_ path: WritableKeyPath<Recipe, Bool>, _ key: String) -> Binding<Bool> {
        let state = self.state
        return Binding(
            get: { state.currentRecipe[keyPath: path] },
            set: { newValue in
                state.updateRecipe(coalescingKey: key) { $0[keyPath: path] = newValue }
            })
    }

    func choice<T: Equatable>(_ path: WritableKeyPath<Recipe, T>, _ key: String) -> Binding<T> {
        let state = self.state
        return Binding(
            get: { state.currentRecipe[keyPath: path] },
            set: { newValue in
                state.updateRecipe(coalescingKey: key) { $0[keyPath: path] = newValue }
            })
    }

    /// For the handful of fields that live behind an optional struct (`Look.filmLab`,
    /// `LensCorrections.defringe`), where a writable key path cannot reach.
    func custom(_ key: String,
                get: @escaping (Recipe) -> Double,
                set: @escaping (inout Recipe, Double) -> Void) -> Binding<Double> {
        let state = self.state
        return Binding(
            get: { get(state.currentRecipe) },
            set: { newValue in
                state.updateRecipe(coalescingKey: key) { set(&$0, newValue) }
            })
    }

    func customFlag(_ key: String,
                    get: @escaping (Recipe) -> Bool,
                    set: @escaping (inout Recipe, Bool) -> Void) -> Binding<Bool> {
        let state = self.state
        return Binding(
            get: { get(state.currentRecipe) },
            set: { newValue in
                state.updateRecipe(coalescingKey: key) { set(&$0, newValue) }
            })
    }

    /// A whole-subtree write (a preset, a reset), recorded as one step.
    func edit(_ key: String, _ mutate: @escaping (inout Recipe) -> Void) {
        state.updateRecipe(coalescingKey: key, mutate)
    }
}

// MARK: - Section scaffolding

/// A titled group of rows. Carries the modified marker, the Reset affordance, and the
/// "nothing changed here" badge that makes a clean section legible at a glance.
struct DevelopSection<Content: View>: View {
    private let title: String
    private let isModified: Bool
    private let onReset: (() -> Void)?
    /// Passed through to the header's Reset button — see `LumenSectionHeader.resetHelp`
    /// for when a Reset's scope needs saying. Crop is the caller that needed it.
    private let resetHelp: String?
    /// Whether this section draws its rows. `true` for every section that has no
    /// accordion above it, which is what the memberwise default preserves.
    private let isExpanded: Bool
    /// Present only when an accordion owns the expansion — see `LumenSectionHeader`'s
    /// `onToggle` for why the click cannot be a per-section binding.
    private let onToggle: ((Bool) -> Void)?
    /// THE CLOSURE, NOT THE VIEW.
    ///
    /// It was eager, on the reasoning that a section with no `if` renders its content on
    /// every pass anyway, so deferring would move an allocation rather than avoid one.
    /// That reasoning expires here: docs/28 §5.5 requires this to land BEFORE the
    /// workspaces, because a section that can now be closed but still CONSTRUCTS its
    /// rows is an accordion that costs what it claims to save — and a drag re-bodies the
    /// panel on every mouse event, so the per-event difference is the whole point.
    ///
    /// Look holds 38 sliders in one section. Each is a `LumenSlider` struct plus the two
    /// escaping closures a `RecipeBinder` binding allocates, built 48 times over a drag
    /// whether or not anybody can see them. `DevelopDisclosure` made this move already,
    /// for the same reason and with the same argument.
    private let content: () -> Content

    init(_ title: String, isModified: Bool, onReset: (() -> Void)? = nil,
         resetHelp: String? = nil,
         isExpanded: Bool = true, onToggle: ((Bool) -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isModified = isModified
        self.onReset = onReset
        self.resetHelp = resetHelp
        self.isExpanded = isExpanded
        self.onToggle = onToggle
        self.content = content
    }

    var body: some View {
        // 6, not 2. A heading two points off the row it governs is the "everything is
        // super back to back to back" the owner named; the gap has to be big enough that
        // the eye reads a title and then a list, rather than one column of text.
        VStack(alignment: .leading, spacing: 6) {
            // No "Default" badge on clean sections any more (design audit §1.9):
            // chrome announcing the ABSENCE of information, repeated per section per
            // panel. The accent dot already says "modified"; silence says default.
            //
            // The chevron appears only when somebody can act on it. A section with no
            // `onToggle` is not collapsible, and drawing a disclosure arrow that does
            // nothing is the same lie as a caption promising a dead shortcut.
            LumenSectionHeader(title: title,
                               isExpanded: onToggle == nil ? nil : .constant(isExpanded),
                               isModified: isModified, onReset: onReset,
                               resetHelp: resetHelp,
                               onToggle: onToggle)
            if isExpanded {
                content()
                    // The same unfold `WorkspaceSectionView` uses — a section built
                    // through this type and one composed by hand should not open two
                    // different ways.
                    .transition(.opacity.combined(
                        with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        // No compensating pad here any more: the header carries the whole of the
        // section rhythm itself, so a section composed by hand out of a
        // `LumenSectionHeader` — which is how Colour, Look and Masks build theirs — gets
        // the same boundary as one built through this type. That is what let the
        // `Divider()` between them go.
    }
}

/// Depth is one disclosure away (D3): the row everybody uses stays on the surface and
/// the parameter that earns its keep once a month sits behind a chevron.
struct DevelopDisclosure<Content: View>: View {
    private let title: String
    @Binding private var isExpanded: Bool
    /// THE CLOSURE, NOT THE VIEW — so a collapsed disclosure costs nothing.
    ///
    /// `if isExpanded` already stops SwiftUI evaluating the body of, and laying out,
    /// content that is closed. But storing `content()` meant the rows were still
    /// CONSTRUCTED on every pass of the parent's body: each `LumenSlider` struct, and
    /// each of the two escaping closures a `RecipeBinder` binding allocates. Deferring
    /// the call into the `if` makes "closed" mean closed.
    ///
    /// Today's saving is small and honest to state: three disclosures, of one, two and
    /// three rows. The reason to do it now is docs/28 Phase 4, which makes whole
    /// sections collapsible — and Look holds 38 sliders in one of them. A drag re-bodies
    /// its panel on every mouse event, so what a collapsed section costs per event is
    /// the difference between an accordion that is free and one that is not.
    private let content: () -> Content

    init(_ title: String, isExpanded: Binding<Bool>,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        // ANIMATED AT THE BINDING, because a disclosure's state is view-local `@State`
        // and never passes through `PanelLayout.commit` where the accordion's animation
        // lives. Wrapping the binding rather than each of the twenty call sites means a
        // fold cannot be added without the movement coming with it.
        // RE-TIMED, because "the animation for the open and close for the chevrons are
        // not great" and `.smooth(duration: 0.22)` was the wrong shape for a fold.
        //
        // `.smooth` is a bezier: it eases in as well as out, so the first frames of an
        // open barely move and the drawer appears to hesitate before committing — which
        // on a control that responds to a click reads as lag rather than as grace. A
        // critically damped spring (dampingFraction 1) leaves immediately and decelerates
        // into place with no overshoot, which is what a hinge does. The response is
        // slightly longer than the old duration and it still finishes sooner, because a
        // spring spends its time at the end of the movement rather than the start.
        //
        // No bounce, for the reason `PanelLayout.commit` already gives: a panel is
        // furniture being moved, not an object being thrown.
        self._isExpanded = Binding(get: { isExpanded.wrappedValue },
                                   set: { new in
                                       withAnimation(.spring(response: 0.28,
                                                             dampingFraction: 1)) {
                                           isExpanded.wrappedValue = new
                                       }
                                   })
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 10, not the section rhythm's 20: a disclosure is a fold inside a section,
            // and giving it a full boundary would make the sub-heading read as louder
            // than the heading it sits under.
            LumenSectionHeader(title: title, isExpanded: $isExpanded, topRhythm: 10)
            if isExpanded {
                content()
                    .padding(.leading, 8)
                    .transition(.opacity.combined(
                        with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }
}

/// A short explanatory line. Panels use it to say what an engine is doing rather than
/// leaving the user to infer it from a slider name.
///
/// Collapsed by default since the owner's second session: thirty-one of these sat
/// fully expanded and the panel read as documentation with sliders in it ("so much
/// text that is honestly unnecessary"). The knowledge is one hover away on the ⓘ
/// row — the same affordance as every slider's own tooltip.
///
/// `prominent: true` keeps the old always-visible rendering. It is for copy that must
/// be READ rather than merely available, and there are exactly two kinds:
///
///   1. **Honesty work** — a control that is stored but not applied, a source this
///      build does not have, a stage another stage replaces. Hiding a disclosure behind
///      a hover is the same as not making it.
///   2. **Live readouts** — a line whose text contains the current state of something
///      (a gradient's geometry, the loaded stock). That is an instrument, not teaching,
///      and an instrument nobody can see is not an instrument.
///
/// Everything else collapses. docs/28 Phase 1 extended this from `DevelopNote`'s own
/// call sites to the nineteen `caption()` blocks in Colour and Look and the twenty
/// `note()` blocks in Masks, which had never adopted it — roughly two to three full
/// panel-heights of always-visible prose.
struct DevelopNote: View {
    private let text: String
    private let prominent: Bool

    init(_ text: String, prominent: Bool = false) {
        self.text = text
        self.prominent = prominent
    }

    var body: some View {
        // NOT PROMINENT MEANS NOT DRAWN. It used to mean an ⓘ row reading "How this
        // works", and there were fifty-nine of them.
        //
        // That was meant to be the fix for always-visible prose, and it made the panel
        // worse in a way that looked like an improvement: nineteen paragraphs in the mask
        // panel did not become zero rows, they became nineteen rows advertising a
        // tooltip. A tooltip that ships its own visible label is not a tooltip — it is a
        // permanent three-word advertisement for one, in front of a photograph, at
        // 3.18:1 (below the contrast this project's own docs require), repeated down
        // every panel until it reads as texture rather than as language.
        //
        // `.help()` on the control already does this job with no row at all, and every
        // `LumenSlider` already carries one. The sentence is not lost; it stops being
        // furniture. docs/30 §2.2.
        if prominent {
            Text(text)
                .font(.lumenCaption)
                .foregroundStyle(Lumen.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        }
    }
}

// MARK: - Develop panel

struct DevelopPanel: View {
    @EnvironmentObject var state: AppState
    /// THE ARRANGEMENT, and the only observable a section click invalidates.
    ///
    /// Not on `AppState`, which about twenty-six views hold: `activeSection` lived there
    /// and one tab click re-bodied the whole window and the `Scene`'s seven menus. Four
    /// workspaces whose sections collapse individually are clicked MORE often than eight
    /// tabs were, and the sections are where the sliders live. See `PanelLayout`.
    @ObservedObject private var panel = PanelLayout.shared

    /// The photograph's denoise starting point, or nil for a rendered file with no ISO
    /// profile to start from. Read here and handed down so the header's dot and the
    /// header's Reset agree about what "default" means for this frame.
    /// The photograph's own display transform starting point — "Linear" for a rendered
    /// file, the type's default for a RAW. See `WorkspaceSection.nonDefault`.
    private var renderDefault: RenderParams? {
        guard let photo = state.primarySelection else { return nil }
        return AppState.startingRecipe(for: photo.id, iso: photo.iso).look.render
    }

    private var denoiseDefault: Denoise? {
        guard let photo = state.primarySelection,
              !PhotoFormats.isRendered(photo.id),
              let iso = photo.iso else { return nil }
        return ISODefaults.startingDenoise(forISO: Double(iso))
    }
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision
    /// The undo/redo pair's labels and enablement. Its own object so that keeping them
    /// current does not require `AppState` to publish when history moves — see
    /// `CommandState`.
    @EnvironmentObject var commands: CommandState

    /// The photo whose name the header shows. Values come from
    /// `state.primarySelection` and edits land on `state.editTargets`, so this is a
    /// label, never an edit target.
    var photo: PhotoItem?

    private var subject: PhotoItem? { photo ?? state.primarySelection }

    var body: some View {
        VStack(spacing: 0) {
            header
            // NEITHER of these carries a fixed height any more, and that is the fix
            // for MAC-06 rather than a style preference.
            //
            // The histogram was pinned to 96 points and its content was 157: 6 of
            // padding, a graph pinned to `graphHeight`, the readout line, the
            // readout-space picker that used to sit under it, two gaps and 6 more of
            // padding.
            // `.frame(height:)` does not clip — it sets the layout size and lets the
            // content draw past it — so roughly 30 points of "Working % | sRGB 255 |
            // Output 255" were painted straight over the divider and the section
            // switcher below. That is exactly what the owner reported: "the working
            // percent, the sRGB, and output 255 is not in the same layer or visually
            // the same as the other pages, like the color or the curves, because
            // they're kind of overlapping." He read a layout overflow as a layering
            // problem, which is the right reading of what it looked like.
            //
            // Scopes had the same defect, smaller: 204 points of content pinned to 190.
            //
            // Both now size to their content, so the graph constants inside each view
            // are the single source of truth for how tall it is. Restoring a fixed
            // height here means re-deriving that sum by hand and re-deriving it again
            // every time a row is added to either view, which is the arithmetic that
            // was got wrong once already.
            if state.showHistogram {
                // The histogram sits above the sliders because it is the instrument
                // they are being read against, not a panel of its own.
                HistogramView(histogram: state.scopes?.histogram)
                    // 4, matching the accordion's cards below, so the instrument's edges
                    // line up with the section edges instead of sitting eight points
                    // inside them. Its own inner padding makes up the difference.
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
            }
            if state.showScopes {
                ScopesView(scopes: state.scopes)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
            }
            // NO SWITCHER BAND ANY MORE. The workspace strip that opened the column
            // moved to the window's right edge as `WorkspaceRail` (docs/32 Stream A, the
            // owner's ask), so the column starts at its instruments. What remains of
            // that band is the one job the rail cannot do from the window's edge: while
            // masking has the column, the way back and the word "Masks" sit at the top
            // of the surface being worked in — `MaskPanel` renders headerless on the
            // promise that this bar is its header.
            if panel.layout.isMasking {
                MaskingReturnBar(panel: panel)
                    .frame(maxWidth: .infinity)
                    .background(Lumen.windowBase)
            }
            if state.editTargets.isEmpty {
                emptyState
            } else {
                sectionContent
            }
            footer
                .frame(maxWidth: .infinity)
                .background(Lumen.windowBase)
        }
        .frame(width: state.developPanelWidth)
        // THE COLUMN IS THE TROUGH NOW, not the surface.
        //
        // It was `panel` 0.20 with everything drawn flat on it, which is why the column
        // read as one undifferentiated scroll: nothing in it had anything to sit ON.
        // Dropping the ground to `windowBase` 0.18 and raising each section onto a 0.20
        // card is the same ladder used the way `LumenSurface.swift` describes — the
        // greys are untouched, the light is what changed. Every control inside a section
        // keeps the exact contrast against its background it was designed with, because
        // its background is still 0.20.
        .background(Lumen.windowBase)
        .foregroundStyle(Lumen.primaryText)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(subject?.filename ?? "No photo")
                .font(.lumenBodyStrong)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if state.editTargets.count > 1 {
                LumenBadge(text: "\(state.editTargets.count) photos", emphasized: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// EVERY SECTION SCROLLS TOGETHER NOW, which is the change and not a detail.
    ///
    /// Each panel used to own its own scrolling, and four of them owned their own
    /// `ScrollView` — which inside an accordion is a scroll trap: the column would stop
    /// scrolling wherever the pointer happened to be over Look, and Look is most of the
    /// column. One scroll view around the whole accordion is what makes a workspace read
    /// as one surface rather than as tabs that happen to be stacked.
    @ViewBuilder
    private var sectionContent: some View {
        scrollColumn {
            // A REPLACEMENT, not a stack. A mask's `LocalAdjust` is the global set
            // again, so drawing both put Tone, Curve, Colour and Grading in this column
            // twice — see `MaskEditor`.
            if panel.layout.isMasking {
                MaskEditor(panel: panel)
            } else {
                WorkspaceSections(panel: panel,
                                  nonDefault: WorkspaceSection.nonDefault(
                                    in: state.currentRecipe,
                                    softProofEnabled: state.softProof.enabled,
                                    // The photograph's OWN starting point, not the
                                    // type's. A high-ISO frame arrives with denoise
                                    // already on, so comparing against `Denoise()`
                                    // would light Detail on every RAW file ever
                                    // opened — and a dot that is always on says
                                    // nothing, which is the argument the "Default"
                                    // badges were removed under.
                                    denoiseDefault: denoiseDefault,
                                    // The photograph's own display transform, for the
                                    // reason `denoiseDefault` is here: a rendered file
                                    // starts at "Linear" and the type's default is
                                    // "Neutral", so without this the Looks dot was on for
                                    // every untouched JPEG in the library.
                                    renderDefault: renderDefault))
            }
        }
    }

    /// NO SCROLL INDICATOR, and this is a bug fix rather than a preference.
    ///
    /// The owner asked for it — "there's a lot of switching from a scroll bar to not a
    /// scroll bar, I just like no scroll bar" — and he was describing a real defect. On a
    /// mouse macOS draws LEGACY scrollers rather than overlay ones, and a legacy scroller
    /// insets the document view. So opening one accordion section makes this column
    /// overflow, the 15pt scroller appears, and every slider in the panel loses 15 of its
    /// 142 points of track: a 10.6% precision change in the control this app is made of,
    /// caused by clicking a chevron.
    ///
    /// `.never` rather than `.hidden`, because `.hidden` leaves the system free to show
    /// them anyway. The column's content is a named, ordered list the photographer chose
    /// the shape of; there is no "what else is down there" question for an indicator to
    /// answer, and the register line at the foot is the real door.
    private func scrollColumn<Content: View>(
        @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            // 4, not 8, and NOT four points off every slider's track.
            //
            // The other four moved inside the section card (`WorkspaceSectionView`), so
            // a row's content still begins eight points from the column's edge and the
            // track is exactly the width it was. What changed is where the padding is
            // spent: half of it now draws the trough the cards sit in rather than being
            // blank margin.
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.system(size: 22))
            Text("Select a photo to develop")
                .font(.lumenBody)
        }
        .foregroundStyle(Lumen.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                // Auto reads a proxy of the actual render — including the crop — and
                // writes the six sliders through `AutoTone.suggest(from:)`. The result
                // is ordinary slider positions: visible, arguable, one undo step.
                DevelopFooterButton(title: "Auto", systemImage: "wand.and.stars",
                                    help: "Set the six tone sliders from the scene's "
                                        + "own statistics (⇧⌘A). Every value stays "
                                        + "visible and individually revertable.",
                                    action: { state.applyAutoTone() })
                DevelopFooterButton(title: "Reset", systemImage: "arrow.uturn.backward",
                                    help: "Return every setting to its default",
                                    action: { state.resetSettings() })
                    .disabled(!isRecipeModified)
                // Through `commands`, not `state.history`. Reading the stack directly
                // is what needed a `history.objectWillChange` → `AppState` forward to
                // stay current, and that forward re-bodied the whole window on every
                // mouse event of every drag (see `CommandState`).
                DevelopFooterButton(title: "Undo", systemImage: "arrow.uturn.left",
                                    help: commands.undoLabel.map { "Undo \($0)" }
                                        ?? "Nothing to undo",
                                    action: { state.undo() })
                    .disabled(!commands.canUndo)
                DevelopFooterButton(title: "Redo", systemImage: "arrow.uturn.right",
                                    help: commands.redoLabel.map { "Redo \($0)" }
                                        ?? "Nothing to redo",
                                    action: { state.redo() })
                    .disabled(!commands.canRedo)
            }
            HStack(spacing: 4) {
                DevelopFooterButton(title: "Copy", systemImage: "doc.on.doc",
                                    help: "Copy all develop settings",
                                    action: { state.copySettings() })
                DevelopFooterButton(title: "Paste", systemImage: "doc.on.clipboard",
                                    help: "Paste develop settings onto the selection",
                                    action: { state.pasteSettings() })
                DevelopFooterButton(title: "Copy Look", systemImage: "photo.stack",
                                    help: "Copy only the portable creative subtree — "
                                        + "grade, film stock, render preset (D4)",
                                    action: { state.copyLook() })
                DevelopFooterButton(title: "Paste Look", systemImage: "photo.stack.fill",
                                    help: "Apply the copied Look, leaving each photo's "
                                        + "own white balance and exposure alone",
                                    action: { state.pasteLook() })
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var isRecipeModified: Bool {
        // Against the photo's own baseline — a JPEG's untouched state carries the
        // Linear preset, and comparing against bare defaults kept Reset lit and the
        // panel marked modified on a file nobody had edited.
        let current = state.currentRecipe
        var baseline = state.currentStartingRecipe
        baseline.pipelineVersion = current.pipelineVersion
        return current != baseline
    }
}

// MARK: - Footer button

/// A verb, not a tile. The icon-above-caption 4×2 grid was the iPhoto/Aperture
/// toolbar idiom — the audit's single most "2008" finding — and these are commands
/// with key equivalents, not modes.
///
/// Borderless at rest, surface on hover, which is the half of design step 6 the first
/// pass wrote in this comment and did not implement: it painted `controlSurface` under
/// all eight, so the bottom of the develop column was eight filled rectangles competing
/// for attention with the photograph. A rest fill is how you draw a MODE, something that
/// can be on; every one of these fires once and returns. The hover surface still
/// confirms the hit target, and it is now the only thing that does — which is the point.
private struct DevelopFooterButton: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.lumenCaption)
                Text(title)
                    .font(.lumenBody)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(hovering ? Lumen.controlHover : Color.clear)
            .foregroundStyle(hovering ? Lumen.primaryText : Lumen.secondaryText)
            .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusControl,
                                        style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .lumenClickCursor()
        .help(help)
    }
}

#endif

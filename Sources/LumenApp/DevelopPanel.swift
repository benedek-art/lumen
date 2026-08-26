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
    private let content: Content

    init(_ title: String, isModified: Bool, onReset: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.isModified = isModified
        self.onReset = onReset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                LumenSectionHeader(title: title, isExpanded: nil,
                                   isModified: isModified, onReset: onReset)
                if !isModified {
                    LumenBadge(text: "Default")
                }
            }
            content
        }
    }
}

/// Depth is one disclosure away (D3): the row everybody uses stays on the surface and
/// the parameter that earns its keep once a month sits behind a chevron.
struct DevelopDisclosure<Content: View>: View {
    private let title: String
    @Binding private var isExpanded: Bool
    private let content: Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: title, isExpanded: $isExpanded)
            if isExpanded {
                content
                    .padding(.leading, 8)
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
/// row — the same affordance as every slider's own tooltip. `prominent: true` keeps
/// the old always-visible rendering, and it is reserved for notes doing honesty work
/// (a control that is stored but not applied must say so without being asked).
struct DevelopNote: View {
    private let text: String
    private let prominent: Bool

    init(_ text: String, prominent: Bool = false) {
        self.text = text
        self.prominent = prominent
    }

    var body: some View {
        if prominent {
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                Text("How this works")
                    .font(.system(size: 9))
            }
            .foregroundStyle(Lumen.secondaryText.opacity(0.75))
            .help(text)
            .padding(.vertical, 1)
        }
    }
}

// MARK: - Develop panel

struct DevelopPanel: View {
    @EnvironmentObject var state: AppState

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
            // The histogram was pinned to 96 points and its content is 157: 6 of
            // padding, a graph pinned to `graphHeight` (104), the readout line (14),
            // the space picker (~19), the two 4-point gaps and 6 more of padding.
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
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            if state.showScopes {
                ScopesView(scopes: state.scopes)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }
            Divider().overlay(Lumen.separator)
            sectionSwitcher
            Divider().overlay(Lumen.separator)
            if state.editTargets.isEmpty {
                emptyState
            } else {
                sectionContent
            }
            Divider().overlay(Lumen.separator)
            footer
        }
        .frame(width: Lumen.panelWidth)
        .background(Lumen.panelBackground)
        .foregroundStyle(Lumen.primaryText)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(subject?.filename ?? "No photo")
                .font(.system(size: 11, weight: .medium))
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

    // MARK: Section switcher

    private var sectionSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(PanelSection.allCases) { section in
                Button {
                    state.activeSection = section
                } label: {
                    Image(systemName: section.symbolName)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(state.activeSection == section
                                    ? Lumen.fillColor.opacity(0.30) : Color.clear)
                        .foregroundStyle(state.activeSection == section
                                         ? Lumen.primaryText : Lumen.secondaryText)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(section.rawValue)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// Each section owns its own scrolling. The panels written here are plain columns
    /// of rows, so they get the standard scroll column; the Colour and Look panels
    /// bring their own, because a grading wheel and an eight-band ribbon need their own
    /// layout rules.
    @ViewBuilder
    private var sectionContent: some View {
        switch state.activeSection {
        case .basic:
            scrollColumn { BasicPanel() }
        case .zones:
            scrollColumn { ZonesPanel() }
        case .detail:
            scrollColumn { DetailPanel() }
        case .effects:
            scrollColumn { EffectsPanel() }
        case .color:
            ColorPanel()
        case .look:
            LookPanel()
        case .curve:
            // The scopes' histogram, so the curve is placed against the picture
            // rather than an empty square. The parameter defaulted to nil and
            // nothing ever passed one — the same constructed-with-no-argument
            // shape that left the crop ratios on an assumed 3:2.
            scrollColumn { CurveEditorView(histogram: state.scopes?.histogram) }
        case .masks:
            MaskPanel()
        }
    }

    private func scrollColumn<Content: View>(
        @ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "slider.horizontal.below.rectangle")
                .font(.system(size: 22))
            Text("Select a photo to develop")
                .font(.system(size: 11))
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
                DevelopFooterButton(title: "Undo", systemImage: "arrow.uturn.left",
                                    help: state.history.undoLabel.map { "Undo \($0)" }
                                        ?? "Nothing to undo",
                                    action: { state.undo() })
                    .disabled(!state.history.canUndo)
                DevelopFooterButton(title: "Redo", systemImage: "arrow.uturn.right",
                                    help: state.history.redoLabel.map { "Redo \($0)" }
                                        ?? "Nothing to redo",
                                    action: { state.redo() })
                    .disabled(!state.history.canRedo)
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
        let current = state.currentRecipe
        return current != Recipe(pipelineVersion: current.pipelineVersion)
    }
}

// MARK: - Footer button

private struct DevelopFooterButton: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Lumen.controlBackground)
            .foregroundStyle(Lumen.primaryText)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

#endif

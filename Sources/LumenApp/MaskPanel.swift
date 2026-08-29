// MaskPanel.swift
// The Masks panel: the photo's mask list, the selected mask's component stack, its
// refinement chain, and the full local adjustment set that runs through its alpha.
//
// Four things this panel exists to get right:
//   · The component operation is a control, not a modifier: Add / Subtract / Intersect
//     are three equal buttons, editable after creation. LrC hides Intersect behind an
//     Alt-click at creation time; that is the difference being made here.
//   · The refinement chain appears in the order the engine runs it (Refine → Grow /
//     Shrink → Feather → Start / End / Curve) under its UI names, never the wire names.
//     `MaskRefine` spells the guided filter `feather` and the Gaussian `blur`, and
//     leaking that would teach the user the wrong word for both; "Levels Lo/Hi/Gamma"
//     was a histogram dialog from 1994 describing a density ramp.
//   · A mask runs the local point curve and the local grading wheels — the two tools
//     Lightroom Classic still lacks inside a mask — so both are visible sections.
//   · Where the format has no field for a spec'd control (linear Mirror, per-axis
//     colour tolerances, similarity geometry), the control is ABSENT rather than
//     invented — and where a whole KIND cannot be computed at all (Depth, Sky, Object,
//     Landscape), it is absent from the picker rather than offered with an apology
//     attached to it. An absent entry teaches nothing false; a present one that
//     apologises teaches that the app is unfinished.
//
// Every slider is a `LumenSlider`, every edit goes through
// `updateRecipe(coalescingKey:)` so one drag is one undo step, and every index into
// `components` is bounds-checked at read and at write.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import SwiftUI

struct MaskPanel: View {
    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

    /// Brush parameters are session state, not recipe state: each stroke records its own
    /// size/feather/flow/density/flags into the blob as it is drawn, so the panel and the
    /// canvas share one store rather than inventing a component field.
    @ObservedObject private var brush: MaskBrushStore = MaskBrushStore.shared

    /// Whether this panel draws its own "Masks" section header.
    ///
    /// False when the caller has already titled it. `MaskDock` printed "Masks" and then
    /// drew this panel, which printed "Masks" again directly underneath — two identical
    /// headers, stacked, in every workspace, on every photograph. Every other panel the
    /// column embeds has this escape (`ZonesPanel.showsSectionHeader`, `ColorPanel.only`)
    /// and this one never did. The default is what a standalone rendering keeps.
    var showsOwnHeader: Bool = true

    /// Spelled out because the synthesised memberwise initialiser is private the moment
    /// any stored property is, and every `@State` fold below is. Without this,
    /// `MaskPanel(showsOwnHeader:)` would not be callable from the column that draws it.
    init(showsOwnHeader: Bool = true) {
        self.showsOwnHeader = showsOwnHeader
    }

    /// Selection lives in `AppState`, not in this view: the on-image canvas edits
    /// gradient and brush geometry from the viewer, and it has to know which component
    /// the panel is pointing at. Computed rather than `@State` so there is one copy.
    private var selectedMaskID: String? {
        get { state.activeMaskID }
        nonmutating set { state.activeMaskID = newValue }
    }
    private var selectedComponent: Int {
        get { state.activeComponentIndex }
        nonmutating set { state.activeComponentIndex = newValue }
    }
    @State private var selectedSwatch: Int = 0
    @State private var componentsExpanded: Bool = true
    @State private var refineExpanded: Bool = true
    @State private var lightExpanded: Bool = true
    @State private var colourExpanded: Bool = true
    @State private var curveExpanded: Bool = true
    @State private var wheelsExpanded: Bool = true
    @State private var detailExpanded: Bool = false
    @State private var pointExpanded: Bool = false

    // MARK: - Body

    /// NO SCROLL VIEW, NO PADDING, NO BACKGROUND OF ITS OWN any more.
    ///
    /// Masks stopped being one of eight tabs and became a dock available in every
    /// workspace (docs/28 Phase 4 item 14), so this is no longer the whole column and
    /// cannot behave as though it were. A nested `ScrollView` inside the column's own is
    /// a scroll trap: the column would stop scrolling wherever the pointer happened to
    /// be over the dock. The column supplies all three now, and it already paints the
    /// same `panelBackground` behind everything.
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Hairlines gone; each header's own 16 pt is the boundary now
            // (`LumenSectionHeader.topRhythm`). Design audit §1.1.
            maskListSection
            if let mask = activeMask {
                componentSection(mask)
                refineSection(mask)
                adjustSections(mask)
            } else {
                emptyMaskState
            }
        }
    }

    // MARK: - Mask list

    private var maskListSection: some View {
        let list = masks
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if showsOwnHeader {
                    LumenSectionHeader(title: "Masks", isExpanded: nil,
                                       isModified: !list.isEmpty)
                }
                // Only once there is a list to add to: with none, `emptyMaskState` below
                // carries the add control at a size worth aiming at, and the same
                // affordance twice, twenty points apart, is the duplication this rebuild
                // is for.
                if !list.isEmpty {
                    kindMenu(label: "Add mask") { kind in addMask(kind: kind) }
                }
            }
            ForEach(Array(list.indices), id: \.self) { i in maskRow(list[i], index: i) }
            if let mask = activeMask {
                LumenSlider(title: "Amount",
                            value: maskValue(mask.id, "amount", get: { $0.amount },
                                             set: { $0.amount = Num.clamp($1, 0, 200) }),
                            range: 0...200, defaultValue: 100, step: 1, decimals: 0)
                // Whole-mask invert (docs/08 §8.1), not the per-component one further
                // down: this flips the folded stack. It runs BEFORE the refinement
                // chain, so Refine still snaps to the picture and Grow / Shrink still
                // grows what is now selected.
                LumenToggleRow(title: "Invert mask",
                               isOn: optionBinding(mask.id, mask.invert,
                                                   on: { $0.invert = true },
                                                   off: { $0.invert = false }),
                               help: "Selects everything this stack does not, after the "
                                   + "components combine and before Refine, Grow / "
                                   + "Shrink, Feather and the density ramp")
                HStack(spacing: 4) {
                    smallButton("Duplicate", "plus.square.on.square") { duplicateMask(mask.id) }
                    smallButton("Delete", "trash") { deleteMask(mask.id) }
                    Spacer(minLength: 0)
                }
                .frame(height: Lumen.rowHeight)
                overlayControls(mask)
            }
        }
    }

    /// The empty state: an affordance, not a definition.
    ///
    /// What stood here defined a mask — "a stack of components combined with add,
    /// subtract and intersect" — to somebody looking at an empty list, which is the one
    /// moment that sentence cannot help. The only useful thing an empty list can do is
    /// be easy to fill, so the control that fills it is the biggest object on screen.
    private var emptyMaskState: some View {
        HStack(spacing: 0) {
            kindMenu(label: "Add a mask", prominent: true) { kind in addMask(kind: kind) }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func maskRow(_ mask: Mask, index: Int) -> some View {
        let isSelected = mask.id == activeMask?.id
        let isSolo = state.soloMaskOverlay == mask.id
        return HStack(spacing: 5) {
            Button { editMask(mask.id, key: nil) { $0.enabled.toggle() } } label: {
                Image(systemName: mask.enabled ? "eye" : "eye.slash").font(.system(size: 10))
                    .foregroundStyle(mask.enabled ? Lumen.primaryText : Lumen.secondaryText)
            }
            .buttonStyle(.plain)
            .help(mask.enabled ? "Stop rendering this mask, keeping it" : "Render it again")

            TextField("Mask \(index + 1)", text: maskName(mask.id))
                .textFieldStyle(.plain).font(.system(size: 11))
                .foregroundStyle(isSelected ? Lumen.primaryText : Lumen.secondaryText)

            LumenBadge(text: "\(mask.components.count)")

            Button { state.soloMaskOverlay = isSolo ? nil : mask.id } label: {
                Image(systemName: isSolo ? "circle.lefthalf.striped.horizontal"
                                        : "circle.lefthalf.filled")
                    .font(.system(size: 10))
                    .foregroundStyle(isSolo ? Lumen.accent : Lumen.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Show this mask's alpha as an overlay on the image")
        }
        .padding(.horizontal, 4).frame(height: Lumen.rowHeight)
        .background(isSelected ? Lumen.fillColor.opacity(0.20) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedMaskID = mask.id
            selectedComponent = 0
            selectedSwatch = 0
        }
    }

    /// The overlay's mode and colour, in the panel as well as on `⌥O` / `⇧O`. Both
    /// belong here because a control that only exists as a keystroke is a control most
    /// people never find — and the six modes are the whole of docs/08 §8.6.
    private func overlayControls(_ mask: Mask) -> some View {
        let showing = state.soloMaskOverlay == mask.id
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    state.soloMaskOverlay = showing ? nil : mask.id
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showing ? "eye.fill" : "eye")
                            .font(.system(size: 9))
                        Text(showing ? "Overlay on" : "Show overlay").font(.system(size: 10))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(showing ? Lumen.fillColor.opacity(0.35) : Lumen.controlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(showing ? Lumen.primaryText : Lumen.secondaryText)
                .help("O shows the overlay for this mask")

                Menu(state.maskOverlayMode.label) {
                    ForEach(MaskOverlay.Mode.allCases, id: \.self) { m in
                        Button(m.label) { state.maskOverlayMode = m }
                    }
                }
                .fixedSize()
                .help("⌥O cycles the six modes")

                Menu(state.maskOverlayTint.label) {
                    ForEach(MaskOverlay.Tint.allCases, id: \.self) { t in
                        Button(t.label) { state.maskOverlayTint = t }
                    }
                }
                .fixedSize()
                .help("⇧O cycles red, green, white and black")
                Spacer(minLength: 0)
            }
            .frame(height: Lumen.rowHeight)
        }
    }

    // MARK: - Component stack

    private func componentSection(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                LumenSectionHeader(title: "Components", isExpanded: $componentsExpanded,
                                   isModified: !mask.components.isEmpty)
                kindMenu(label: "Add") { kind in addComponent(kind: kind, to: mask.id) }
            }
            if componentsExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(mask.components.indices), id: \.self) { i in
                        componentRow(mask, i)
                    }
                    // Nothing when the stack is empty: `Add` sits in the header one row
                    // above, and a mask with no components is a state you pass through
                    // in a single click.
                    if let i = activeComponentIndex, mask.components.indices.contains(i) {
                        componentEditor(mask.id, i, mask.components[i])
                    }
                }
            }
        }
    }

    private func componentRow(_ mask: Mask, _ index: Int) -> some View {
        let component = mask.components[index]
        let isSelected = index == activeComponentIndex
        return HStack(spacing: 5) {
            Text(MaskPanel.opGlyph(component.op))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Lumen.secondaryText).frame(width: 12)
            Text(MaskPanel.kindName(component.kind)).font(.system(size: 11)).lineLimit(1)
                .foregroundStyle(isSelected ? Lumen.primaryText : Lumen.secondaryText)
            if component.invert { LumenBadge(text: "INV") }
            Spacer(minLength: 0)
            if component.validationError() != nil {
                LumenBadge(text: "INCOMPLETE", emphasized: true)
            }
            Button { removeComponent(mask.id, index) } label: {
                Image(systemName: "minus.circle").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(Lumen.secondaryText)
            .help("Remove this component")
        }
        .padding(.horizontal, 4).frame(height: Lumen.rowHeight)
        .background(isSelected ? Lumen.fillColor.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture { selectedComponent = index }
    }

    private func componentEditor(_ id: String, _ i: Int, _ c: MaskComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSegmented(options: [(value: MaskOp.add, label: "Add"),
                                     (value: MaskOp.subtract, label: "Subtract"),
                                     (value: MaskOp.intersect, label: "Intersect")],
                           selection: opBinding(id, i))
                .padding(.vertical, 2)
            LumenToggleRow(title: "Invert", isOn: invertBinding(id, i),
                           help: "Inverts this component before it folds into the stack")
            LumenSlider(title: "Amount",
                        value: Binding(get: { component(id, i)?.amount ?? 100 },
                                       set: { v in
                                           editComponent(id, i, key: "mask.c.amount.\(id).\(i)") {
                                               $0.amount = Num.clamp(v, 0, 100)
                                           }
                                       }),
                        range: 0...100, defaultValue: 100, step: 1, decimals: 0, bipolar: false)
            componentParameters(id, i, c)
            if let problem = c.validationError() {
                // A component that renders nothing must say so unprompted.
                note(problem + " — it renders empty until that is supplied.")
            }
        }
        .padding(.leading, 6).padding(.bottom, 4)
    }

    @ViewBuilder
    private func componentParameters(_ id: String, _ i: Int, _ c: MaskComponent) -> some View {
        switch c.kind {
        case .brush:
            brushParameters()
        case .linear:
            // Live: `lineSummary` is the gradient's current geometry, so this is a
            // readout wearing an instruction, not teaching.
            note("Drag on the image to set the gradient line — " + MaskPanel.lineSummary(c)
                 + ". The span between the ends is the feather; there is no other control.")
        case .similarityLine:
            VStack(alignment: .leading, spacing: 2) {
                note("Drag on the image to set the ramp — " + MaskPanel.lineSummary(c) + ".")
                similarityParameters(id, i, c)
            }
        case .radial:
            VStack(alignment: .leading, spacing: 2) {
                optionalSlider(id, i, "Feather", \.feather, 0...100, 50)
                optionalSlider(id, i, "Rotation", \.rotation, -180...180, 0, bipolar: true)
                note("Drag on the image to place and resize the ellipse — "
                     + MaskPanel.ellipseSummary(c) + ". Falloff runs inward from the edge.")
            }
        case .lumaRange:
            VStack(alignment: .leading, spacing: 2) {
                // From / To, not Band Lo / Band Hi. Both are EV on the fixed −10…+4
                // axis over scene luminance, never auto-ranged, so a band means the same
                // thing on every frame — which is a fact about the axis, not a caption.
                bandSlider(id, i, "From", isLow: true, depth: false)
                bandSlider(id, i, "To", isLow: false, depth: false)
                optionalSlider(id, i, "Smoothness", \.smooth, 0...100, 50)
            }
        // Still editable, no longer offerable. Nothing estimates depth and nothing reads
        // embedded depth — `aiMattes` is a literal empty dictionary at both call sites —
        // so the kind left `rangeKinds` and the paragraph apologising for it left with
        // the menu entry. A recipe made elsewhere can still carry one, and when it does
        // `modelNote` marks it inert in the same badge as every other kind that needs a
        // model it has not got.
        case .depthRange:
            VStack(alignment: .leading, spacing: 2) {
                bandSlider(id, i, "Near", isLow: true, depth: true)
                bandSlider(id, i, "Far", isLow: false, depth: true)
                optionalSlider(id, i, "Smoothness", \.smooth, 0...100, 50)
                modelNote(c)
            }
        case .colorRange:
            VStack(alignment: .leading, spacing: 2) {
                sampleChips(id, i, c)
                // One Refine, not three: it drives the hue, chroma and lightness
                // tolerances together because the per-axis split has no field in the
                // format, so the other two are absent rather than faked.
                optionalSlider(id, i, "Refine", \.rangeAmount, 0...100, 50)
            }
        case .similarity:
            similarityParameters(id, i, c)
        // People, Landscape and Object shipped sixteen checkboxes and a prompt counter
        // between them, every one of them writing a field (`personParts`, `classes`,
        // `prompt`) that NOTHING read. docs/18: a control that stores a value nothing
        // reads is worse than an absent one, because absence is honest — so those went,
        // and the five paragraphs that had grown up to explain their absence have now
        // gone the same way. Landscape and Object are not in the picker at all any more
        // (see `visionKinds`), so what is left for them is `modelNote`'s inert badge:
        // the disabled state doing the work three sentences were doing.
        //
        // Every kind routes through `modelNote`, People included — People was the one
        // Vision kind whose editor skipped it, so a People mask could never show
        // NOTHING FOUND however long you waited.
        case .aiPerson:
            VStack(alignment: .leading, spacing: 2) {
                // Six words, and they name what IS selected rather than what is not.
                // Per-person chips and the nine body parts need a face-landmark pass
                // and a per-person matte the wire format cannot express, which is a
                // fact for this comment to carry and not a row in the panel.
                Text("Entire Person, for everyone in the frame.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                modelNote(c)
            }
        case .aiSubject, .aiSky, .aiBackground, .aiObject, .aiLandscape:
            modelNote(c)
        }
    }

    /// No component argument any more. The only thing it fed was a note printing the
    /// stroke blob's content hash — a developer's readout, in a photographer's panel,
    /// under four sliders it said nothing about.
    ///
    /// These are the settings the NEXT stroke records, not this component's: a stroke
    /// carries its own size, feather, flow, density and flags into the blob as it is
    /// drawn. Size is a fraction of the source long edge, so a stroke keeps its width at
    /// export resolution.
    private func brushParameters() -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSlider(title: "Size", value: brushValue(\.size), range: 0.002...0.5,
                        defaultValue: BrushStroke.defaultSize, step: 0.002, decimals: 3,
                        bipolar: false)
            LumenSlider(title: "Feather", value: brushValue(\.feather), range: 0...100,
                        defaultValue: 50, step: 1, decimals: 0, bipolar: false)
            LumenSlider(title: "Flow", value: brushValue(\.flow), range: 1...100,
                        defaultValue: 100, step: 1, decimals: 0, bipolar: false)
            LumenSlider(title: "Density", value: brushValue(\.density), range: 0...100,
                        defaultValue: 100, step: 1, decimals: 0, bipolar: false)
            LumenToggleRow(title: "Eraser", isOn: brushFlag(\.erase),
                           help: "Erase strokes fold into the same buffer in draw order")
            LumenToggleRow(title: "Automask", isOn: brushFlag(\.automask),
                           help: "Gates each stamp by colour similarity to the stamp centre")
        }
    }

    /// Both sliders are the width of the OKLab similarity gate, one across chroma and
    /// one across lightness — "Chroma sel." and "Luma sel." were the axes of the gate
    /// wearing the abbreviations of a debug build. Point positions and radius have no
    /// field in the shipped format, so the gate evaluates over the whole frame; that was
    /// a paragraph in the panel and is a fact about the format, which is here.
    private func similarityParameters(_ id: String, _ i: Int,
                                      _ c: MaskComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sampleChips(id, i, c)
            optionalSlider(id, i, "Colour range", \.chromaSel, 0...100, 50)
            optionalSlider(id, i, "Brightness range", \.lumaSel, 0...100, 50)
        }
    }

    private func sampleChips(_ id: String, _ i: Int, _ c: MaskComponent) -> some View {
        let samples = c.samples ?? []
        return HStack(spacing: 4) {
            ForEach(Array(samples.indices), id: \.self) { s in
                RoundedRectangle(cornerRadius: 3).fill(MaskPanel.chipColor(samples[s]))
                    .frame(width: 20, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Lumen.separator, lineWidth: 0.5))
            }
            Spacer(minLength: 0)
            Button { addSample(id, i) } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain).disabled(samples.count >= 8)
            .foregroundStyle(samples.count < 8 ? Lumen.primaryText : Lumen.secondaryText)
            .help("Add a sample (up to 8); the eyedropper lands with the sampler")
            Button { removeSample(id, i) } label: {
                Image(systemName: "minus").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain).disabled(samples.count <= 1)
            .foregroundStyle(samples.count > 1 ? Lumen.primaryText : Lumen.secondaryText)
            .help("Remove the last sample")
        }
        .frame(height: Lumen.rowHeight)
    }

    /// What is actually happening to this component's matte.
    ///
    /// This used to read "Computed in the background once the model is available" for
    /// all seven AI kinds, which implied a background pass that did not exist — and it
    /// said it about Subject and People too, which need no model at all. Each row now
    /// states its own case.
    private func modelNote(_ c: MaskComponent) -> some View {
        let status = state.matteStatus(for: c.kind)
        let badge: String
        let text: String
        switch status {
        case .ready:
            badge = c.model ?? "VISION"
            text = "Computed on this Mac by Apple's Vision framework, cached at 1024 px; "
                + "Refine carries the edge up to full resolution."
        case .working:
            badge = "VISION"
            text = "Computing on this Mac — no download, no model. The mask is empty "
                + "until it lands, and the picture stays editable meanwhile."
        case .notFound:
            badge = "NOTHING FOUND"
            text = c.kind == .aiPerson
                ? "Vision found no person in this frame. Try a brush, or Subject."
                : "Vision found no clear subject in this frame. Try a brush, or a "
                    + "Colour Pick on what you meant."
        case .needsModel:
            // The badge is the whole message. Every kind that reaches this case has
            // left the picker (`visionKinds`, `rangeKinds`), so the only way to be
            // looking at one is a recipe made somewhere else — and a paragraph
            // apologising for a component you could not have created here teaches that
            // the app is unfinished, which is the opposite of what an inert badge on an
            // imported component teaches.
            badge = "MODEL NEEDED"
            text = ""
        case .notNeeded:
            badge = c.model ?? ""
            text = ""
        }
        return HStack(spacing: 6) {
            if !badge.isEmpty {
                LumenBadge(text: badge,
                           emphasized: status == .needsModel || status == .notFound)
            }
            Text(text)
                .font(.system(size: 10)).foregroundStyle(Lumen.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Refinement chain

    private func refineSection(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Refine", isExpanded: $refineExpanded,
                               isModified: mask.refine != MaskRefine(),
                               onReset: { editMask(mask.id, key: nil) { $0.refine = MaskRefine() } })
            if refineExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    // Drawn in the order the engine runs them — an edge-aware snap
                    // against the image structure, a boundary shift, a Gaussian soften,
                    // then the density remap — which is why they are not alphabetical
                    // and not grouped. Start / End / Curve are `levelsLo` / `levelsHi` /
                    // `levelsGamma`, and Grow / Shrink is `edge`: the wire names are a
                    // histogram dialog describing a density ramp, and the labels now say
                    // which end of the ramp each handle moves.
                    refineSlider(mask.id, "Refine", \.feather, 0...100, 0)
                    refineSlider(mask.id, "Grow / Shrink", \.edge, -50...50, 0,
                                 bipolar: true)
                    refineSlider(mask.id, "Feather", \.blur, 0...100, 0)
                    levelsSlider(mask.id, "Start", low: true)
                    levelsSlider(mask.id, "End", low: false)
                    refineSlider(mask.id, "Curve", \.levelsGamma, 0.2...5, 1,
                                 step: 0.05, decimals: 2, bipolar: true)
                }
            }
        }
    }

    // MARK: - Local adjustments

    private func adjustSections(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            lightSection(mask)
            curveSection(mask)
            colourSection(mask)
            wheelsSection(mask)
            pointColourSection(mask)
            detailSection(mask)
        }
    }

    private func lightSection(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Light", isExpanded: $lightExpanded)
            if lightExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    adjustSlider(mask.id, "Exposure", \.exposure, -4...4, step: 0.05, decimals: 2)
                    adjustSlider(mask.id, "Contrast", \.contrast, -100...100)
                    adjustSlider(mask.id, "Highlights", \.highlights, -100...100)
                    adjustSlider(mask.id, "Shadows", \.shadows, -100...100)
                    adjustSlider(mask.id, "Whites", \.whites, -100...100)
                    adjustSlider(mask.id, "Blacks", \.blacks, -100...100)
                    // Whites and Blacks do two things here. They move the tone engine's
                    // ANCHORS, which reshapes the Highlights and Shadows windows —
                    // globally those anchors also feed the display transform, which is
                    // the seam that makes them mean "white point" and "black point", and
                    // a mask has no display transform of its own, so that half really
                    // does stop at the window geometry. And `ToneEngine.zonalStops`
                    // gives each a SHELF, added because an anchor-only Whites measured
                    // 26.7 code values over its whole travel and Blacks 0.20 — "a slider
                    // a photographer would call dead". `LocalPlan` and
                    // `ReferenceRenderer.applyLocalAdjust` both feed the local values
                    // into that same engine, so a mask carrying nothing but Whites +100
                    // lifts the top of its range by up to 1.3 EV and Blacks −100 drops
                    // the bottom by up to 2.2, mid-grey untouched in both cases.
                    //
                    // All of which is a fact about the engine. The four-line caption
                    // that used to say it to the photographer is gone.
                }
            }
        }
    }

    private func colourSection(_ mask: Mask) -> some View {
        let hasTint = mask.adjust.colorTint != nil
        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Colour", isExpanded: $colourExpanded)
            if colourExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    adjustSlider(mask.id, "Temp", \.temp, -100...100)
                    adjustSlider(mask.id, "Tint", \.tint, -100...100)
                    adjustSlider(mask.id, "Hue", \.hue, -180...180)
                    adjustSlider(mask.id, "Saturation", \.sat, -100...100)
                    adjustSlider(mask.id, "Vibrance", \.vibrance, -100...100)
                    LumenToggleRow(title: "Colour tint",
                                   isOn: optionBinding(mask.id, hasTint,
                                                       on: { $0.adjust.colorTint = [0.5, 0.5, 0.5] },
                                                       off: { $0.adjust.colorTint = nil }),
                                   // There is no swatch control and no PickTarget
                                   // writes colorTint, so the target is always the
                                   // hardcoded mid-grey below. Against a grey target
                                   // `applyColorTint` preserves luminance while mixing
                                   // toward neutral — it DESATURATES. The control does
                                   // change the picture, in the opposite direction to
                                   // its name.
                                   help: "Not wired yet: with no picker the target is "
                                       + "mid-grey, so this desaturates toward neutral "
                                       + "rather than tinting. Use a mask Point Colour "
                                       + "swatch instead.")
                    if hasTint {
                        adjustSlider(mask.id, "Tint strength", \.colorTintStrength, 0...100,
                                     bipolar: false)
                    }
                }
            }
        }
    }

    private func curveSection(_ mask: Mask) -> some View {
        let has = mask.adjust.curve != nil
        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Curve", isExpanded: $curveExpanded, isModified: has,
                               onReset: { editMask(mask.id, key: nil) { $0.adjust.curve = nil } })
            if curveExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    // The same editor the global curve uses, pointed at this mask.
                    // A second, simpler widget here would be two curve UIs that could
                    // disagree about what the pipeline applies; this one draws
                    // `CurveStack`'s own evaluation, which is what gets baked. It taps
                    // AFTER the display transform, alongside the global curve, through
                    // this mask's alpha, so the axis means the same thing here as it
                    // does globally, and the mask's Amount scales how far it moves the
                    // picture.
                    //
                    // Fifty-three words of that were on screen, opening with which
                    // feature Lightroom lacks. A photographer editing a mask is not
                    // reading about Lightroom.
                    CurveEditorView(target: .mask(mask.id))
                }
            }
        }
    }

    private func wheelsSection(_ mask: Mask) -> some View {
        let has = mask.adjust.wheels != nil
        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Grading", isExpanded: $wheelsExpanded, isModified: has,
                               onReset: { editMask(mask.id, key: nil) { $0.adjust.wheels = nil } })
            if wheelsExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    // Off draws the toggle and nothing else. What stood under it was a
                    // forty-three-word advertisement — the same engine as the global
                    // grade, the thing Lightroom has no local equivalent for — shown to
                    // somebody already standing inside the mask panel with the switch
                    // under their pointer.
                    LumenToggleRow(title: "Local grading wheels",
                                   isOn: optionBinding(mask.id, has,
                                                       on: { $0.adjust.wheels = GradingWheels() },
                                                       off: { $0.adjust.wheels = nil }),
                                   help: "Three-way wheels plus Global, inside the mask")
                    if has {
                        HStack(spacing: 8) {
                            wheel(mask.id, "Shadows", \.shadows, "shadows")
                            wheel(mask.id, "Midtones", \.mid, "mid")
                        }
                        HStack(spacing: 8) {
                            wheel(mask.id, "Highlights", \.high, "high")
                            wheel(mask.id, "Global", \.global, "global")
                        }
                        wheelsSlider(mask.id, "Blending", \.blending, 0...100, 50)
                        wheelsSlider(mask.id, "Balance", \.balance, -100...100, 0, bipolar: true)
                    }
                }
            }
        }
    }

    private func pointColourSection(_ mask: Mask) -> some View {
        let swatches = mask.adjust.pointColors
        let index: Int? = swatches.isEmpty
            ? nil : Swift.min(Swift.max(selectedSwatch, 0), swatches.count - 1)
        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Point Colour", isExpanded: $pointExpanded,
                               isModified: !swatches.isEmpty,
                               onReset: { editMask(mask.id, key: nil) { $0.adjust.pointColors = [] } })
            if pointExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        ForEach(Array(swatches.indices), id: \.self) { s in
                            Button { selectedSwatch = s } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(MaskPanel.chipColor(swatches[s].sample))
                                    .frame(width: 20, height: 14)
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(s == index ? Lumen.primaryText : Lumen.separator,
                                                      lineWidth: s == index ? 1.5 : 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                        smallButton("Add", "plus") { addSwatch(mask.id) }
                        smallButton("Remove", "minus") { removeSwatch(mask.id) }
                    }
                    .frame(height: Lumen.rowHeight)
                    // Nothing when there are no swatches: Add is in the row directly
                    // above, and it is the whole message.
                    if let s = index {
                        swatchSlider(mask.id, s, "Hue", -60...60, 0,
                                     get: { $0.shift.h }, set: { $0.shift.h = $1 })
                        swatchSlider(mask.id, s, "Saturation", -100...100, 0,
                                     get: { $0.shift.s }, set: { $0.shift.s = $1 })
                        swatchSlider(mask.id, s, "Luminance", -100...100, 0,
                                     get: { $0.shift.l }, set: { $0.shift.l = $1 })
                        swatchSlider(mask.id, s, "Range", 0...100, 50,
                                     get: { $0.range }, set: { $0.range = $1 }, bipolar: false)
                        swatchSlider(mask.id, s, "Variance", -100...100, 0,
                                     get: { $0.variance }, set: { $0.variance = $1 })
                    }
                }
            }
        }
    }

    private func detailSection(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Presence & Detail", isExpanded: $detailExpanded)
            if detailExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    adjustSlider(mask.id, "Texture", \.texture, -100...100)
                    adjustSlider(mask.id, "Clarity", \.clarity, -100...100)
                    adjustSlider(mask.id, "Dehaze", \.dehaze, -100...100)
                    // Texture, Clarity and Dehaze reuse the global base–detail
                    // decomposition, and negative Sharpness softens.
                    adjustSlider(mask.id, "Sharpness", \.sharpness, -100...100)
                    // Not shown: local Noise, Noise (chroma), Moiré, Defringe and
                    // Grain. Every one of them has a field in the recipe and no stage
                    // that reads it, and a slider that moves while the picture does
                    // not is worse than an absent one — it costs the user the time to
                    // find out. They come back when the stage does.
                    //
                    // The row announcing that absence is gone too. There is nothing on
                    // screen for it to be about: an apology for a control you cannot
                    // see is one more thing to read past.
                }
            }
        }
    }

    // MARK: - Mutation

    private func addMask(kind: MaskKind) {
        var mask = Mask(name: "\(MaskPanel.kindName(kind)) \(masks.count + 1)",
                        components: [MaskPanel.makeComponent(kind: kind, op: .add)])
        // AI components ship with Refine at 10: an upsampled generation-resolution matte
        // needs the edge-aware snap to hold at 100% zoom, and a drawn shape does not.
        if MaskPanel.aiKinds.contains(kind) { mask.refine.feather = 10 }
        let id = mask.id
        state.updateRecipe(coalescingKey: nil) { $0.masks.append(mask) }
        selectedMaskID = id
        selectedComponent = 0
    }

    private func addComponent(kind: MaskKind, to id: String) {
        let component = MaskPanel.makeComponent(kind: kind, op: .add)
        editMask(id, key: nil) { m in
            m.components.append(component)
            if MaskPanel.aiKinds.contains(kind), m.refine == MaskRefine() { m.refine.feather = 10 }
        }
        selectedComponent = Swift.max((mask(id)?.components.count ?? 1) - 1, 0)
    }

    private func removeComponent(_ id: String, _ index: Int) {
        editMask(id, key: nil) { m in
            guard m.components.indices.contains(index) else { return }
            m.components.remove(at: index)
        }
        selectedComponent = Swift.max(Swift.min(index, (mask(id)?.components.count ?? 0) - 1), 0)
    }

    /// Arms a pick. Colour Range and both Similarity kinds compare against these
    /// samples, so a list of greys made three working kernels select nothing anybody
    /// wanted — the algorithms were fine and the input was a constant.
    private func addSample(_ id: String, _ i: Int) {
        state.beginPick(.maskSample(maskID: id, component: i))
    }

    private func removeSample(_ id: String, _ i: Int) {
        editComponent(id, i, key: nil) { c in
            var list = c.samples ?? []
            guard list.count > 1 else { return }
            list.removeLast()
            c.samples = list
        }
    }

    private func duplicateMask(_ id: String) {
        guard let source = mask(id) else { return }
        var copy = source
        copy.id = UUID().uuidString
        copy.name = source.name.isEmpty ? "Copy" : source.name + " copy"
        let newID = copy.id
        state.updateRecipe(coalescingKey: nil) { recipe in
            guard let i = recipe.masks.firstIndex(where: { $0.id == id }) else {
                recipe.masks.append(copy)
                return
            }
            recipe.masks.insert(copy, at: recipe.masks.index(after: i))
        }
        selectedMaskID = newID
    }

    private func deleteMask(_ id: String) {
        state.updateRecipe(coalescingKey: nil) { recipe in
            recipe.masks.removeAll { $0.id == id }
        }
        if state.soloMaskOverlay == id { state.soloMaskOverlay = nil }
        selectedMaskID = masks.first?.id
        selectedComponent = 0
    }

    /// Arms a pick, like the global swatch row. A swatch born neutral is not an
    /// unconfigured control, it is one that selects nothing — the chordal hue term
    /// against a grey target is identically zero.
    private func addSwatch(_ id: String) {
        guard (mask(id)?.adjust.pointColors.count ?? 8) < 8 else { return }
        state.beginPick(.maskPointColor(maskID: id))
    }

    private func removeSwatch(_ id: String) {
        let target = selectedSwatch
        editMask(id, key: nil) { m in
            guard m.adjust.pointColors.indices.contains(target) else { return }
            m.adjust.pointColors.remove(at: target)
        }
        selectedSwatch = Swift.max(Swift.min(target, (mask(id)?.adjust.pointColors.count ?? 0) - 1), 0)
    }

    private func editMask(_ id: String, key: String?, _ body: (inout Mask) -> Void) {
        state.updateRecipe(coalescingKey: key) { recipe in
            guard let i = recipe.masks.firstIndex(where: { $0.id == id }) else { return }
            body(&recipe.masks[i])
        }
    }

    private func editComponent(_ id: String, _ index: Int, key: String?,
                               _ body: (inout MaskComponent) -> Void) {
        state.updateRecipe(coalescingKey: key) { recipe in
            guard let m = recipe.masks.firstIndex(where: { $0.id == id }),
                  recipe.masks[m].components.indices.contains(index) else { return }
            body(&recipe.masks[m].components[index])
        }
    }

    // MARK: - Reads and bindings

    private var masks: [Mask] { state.currentRecipe.masks }

    private func mask(_ id: String) -> Mask? { masks.first(where: { $0.id == id }) }

    private var activeMask: Mask? {
        if let id = selectedMaskID, let found = mask(id) { return found }
        return masks.first
    }

    private func component(_ id: String, _ index: Int) -> MaskComponent? {
        guard let m = mask(id), m.components.indices.contains(index) else { return nil }
        return m.components[index]
    }

    private var activeComponentIndex: Int? {
        guard let m = activeMask, !m.components.isEmpty else { return nil }
        return Swift.min(Swift.max(selectedComponent, 0), m.components.count - 1)
    }

    private func maskName(_ id: String) -> Binding<String> {
        Binding(get: { mask(id)?.name ?? "" },
                set: { v in editMask(id, key: "mask.name.\(id)") { $0.name = v } })
    }

    private func maskValue(_ id: String, _ key: String, get: @escaping (Mask) -> Double,
                           set: @escaping (inout Mask, Double) -> Void) -> Binding<Double> {
        Binding(get: { mask(id).map(get) ?? 0 },
                set: { v in editMask(id, key: "mask.\(key).\(id)") { set(&$0, v) } })
    }

    private func optionBinding(_ id: String, _ isOn: Bool, on: @escaping (inout Mask) -> Void,
                               off: @escaping (inout Mask) -> Void) -> Binding<Bool> {
        Binding(get: { isOn },
                set: { want in
                    editMask(id, key: nil) { m in
                        if want { on(&m) } else { off(&m) }
                    }
                })
    }

    private func opBinding(_ id: String, _ i: Int) -> Binding<MaskOp> {
        Binding(get: { component(id, i)?.op ?? .add },
                set: { v in editComponent(id, i, key: nil) { $0.op = v } })
    }

    private func invertBinding(_ id: String, _ i: Int) -> Binding<Bool> {
        Binding(get: { component(id, i)?.invert ?? false },
                set: { v in editComponent(id, i, key: nil) { $0.invert = v } })
    }

    private func brushValue(_ p: ReferenceWritableKeyPath<MaskBrushStore, Double>) -> Binding<Double> {
        let store = brush
        return Binding(get: { store[keyPath: p] }, set: { v in store[keyPath: p] = v })
    }

    private func brushFlag(_ p: ReferenceWritableKeyPath<MaskBrushStore, Bool>) -> Binding<Bool> {
        let store = brush
        return Binding(get: { store[keyPath: p] }, set: { v in store[keyPath: p] = v })
    }

    // MARK: - Slider builders

    /// The kind-specific keys are optional on the flat component struct: `nil` means "not
    /// set", and the slider stands in the documented default until it is moved.
    private func optionalSlider(_ id: String, _ i: Int, _ t: String,
                                _ p: WritableKeyPath<MaskComponent, Double?>,
                                _ r: ClosedRange<Double>, _ d: Double,
                                bipolar: Bool = false) -> some View {
        LumenSlider(title: t,
                    value: Binding(get: { component(id, i)?[keyPath: p] ?? d },
                                   set: { v in
                                       editComponent(id, i, key: "mask.c.\(t).\(id).\(i)") {
                                           $0[keyPath: p] = Num.clamp(v, r.lowerBound, r.upperBound)
                                       }
                                   }),
                    range: r, defaultValue: d, step: 1, decimals: 0, bipolar: bipolar)
    }

    /// The luminance and depth bands, cross-clamped so `lo` can never pass `hi` — the
    /// rasterizer rejects an inverted band, and inversion is the invert toggle's job.
    /// Luminance handles are denominated in EV over the fixed −10…+4 axis the normalized
    /// wire value sits on.
    private func bandSlider(_ id: String, _ i: Int, _ t: String,
                            isLow: Bool, depth: Bool) -> some View {
        let r: ClosedRange<Double> = depth ? 0...1 : MaskPanel.evMin...MaskPanel.evMax
        let fallback: Double = isLow ? r.lowerBound : r.upperBound
        return LumenSlider(
            title: t,
            value: Binding(
                get: {
                    guard let c = component(id, i),
                          let raw = depth ? (isLow ? c.depthLo : c.depthHi)
                                          : (isLow ? c.lo : c.hi) else { return fallback }
                    return depth ? Num.saturate(raw) : MaskPanel.ev(raw)
                },
                set: { v in
                    let n = depth ? Num.saturate(v) : MaskPanel.normalizedEV(v)
                    editComponent(id, i, key: "mask.c.\(t).\(id).\(i)") { c in
                        switch (depth, isLow) {
                        case (true, true): c.depthLo = Swift.min(n, c.depthHi ?? 1)
                        case (true, false): c.depthHi = Swift.max(n, c.depthLo ?? 0)
                        case (false, true): c.lo = Swift.min(n, c.hi ?? 1)
                        case (false, false): c.hi = Swift.max(n, c.lo ?? 0)
                        }
                    }
                }),
            range: r, defaultValue: fallback, step: depth ? 0.01 : 0.1,
            decimals: depth ? 2 : 1, bipolar: false)
    }

    private func refineSlider(_ id: String, _ t: String, _ p: WritableKeyPath<MaskRefine, Double>,
                              _ r: ClosedRange<Double>, _ d: Double, step: Double = 1,
                              decimals: Int = 0, bipolar: Bool = false) -> some View {
        LumenSlider(title: t,
                    value: maskValue(id, t, get: { $0.refine[keyPath: p] },
                                     set: { $0.refine[keyPath: p] =
                                         Num.clamp($1, r.lowerBound, r.upperBound) }),
                    range: r, defaultValue: d, step: step, decimals: decimals, bipolar: bipolar)
    }

    private func levelsSlider(_ id: String, _ t: String, low: Bool) -> some View {
        LumenSlider(title: t,
                    value: maskValue(id, t,
                                     get: { low ? $0.refine.levelsLo : $0.refine.levelsHi },
                                     set: { m, v in
                                         let c = Num.clamp(v, 0, 100)
                                         if low { m.refine.levelsLo = Swift.min(c, m.refine.levelsHi) }
                                         else { m.refine.levelsHi = Swift.max(c, m.refine.levelsLo) }
                                     }),
                    range: 0...100, defaultValue: low ? 0 : 100, step: 1, decimals: 0,
                    bipolar: false)
    }

    private func adjustSlider(_ id: String, _ t: String,
                              _ p: WritableKeyPath<LocalAdjust, Double>,
                              _ r: ClosedRange<Double>, step: Double = 1,
                              decimals: Int = 0, bipolar: Bool = true) -> some View {
        LumenSlider(title: t,
                    value: maskValue(id, t, get: { $0.adjust[keyPath: p] },
                                     set: { $0.adjust[keyPath: p] =
                                         Num.clamp($1, r.lowerBound, r.upperBound) }),
                    range: r, defaultValue: 0, step: step, decimals: decimals, bipolar: bipolar)
    }

    private func wheelsSlider(_ id: String, _ t: String,
                              _ p: WritableKeyPath<GradingWheels, Double>,
                              _ r: ClosedRange<Double>, _ d: Double,
                              bipolar: Bool = false) -> some View {
        LumenSlider(title: t,
                    value: maskValue(id, "wheels." + t,
                                     get: { $0.adjust.wheels?[keyPath: p] ?? d },
                                     set: { m, v in
                                         var w = m.adjust.wheels ?? GradingWheels()
                                         w[keyPath: p] = Num.clamp(v, r.lowerBound, r.upperBound)
                                         m.adjust.wheels = w
                                     }),
                    range: r, defaultValue: d, step: 1, decimals: 0, bipolar: bipolar)
    }

    private func wheel(_ id: String, _ t: String, _ p: WritableKeyPath<GradingWheels, Wheel>,
                       _ key: String) -> some View {
        LumenColorWheel(title: t, hue: wheelValue(id, p, \.hue, key + ".hue"),
                        sat: wheelValue(id, p, \.sat, key + ".sat"),
                        lum: wheelValue(id, p, \.lum, key + ".lum"))
    }

    private func wheelValue(_ id: String, _ p: WritableKeyPath<GradingWheels, Wheel>,
                            _ f: WritableKeyPath<Wheel, Double>, _ key: String) -> Binding<Double> {
        maskValue(id, "wheel." + key,
                  get: { $0.adjust.wheels?[keyPath: p][keyPath: f] ?? 0 },
                  set: { m, v in
                      var w = m.adjust.wheels ?? GradingWheels()
                      w[keyPath: p][keyPath: f] = v
                      m.adjust.wheels = w
                  })
    }

    private func swatchSlider(_ id: String, _ index: Int, _ t: String,
                              _ r: ClosedRange<Double>, _ d: Double,
                              get: @escaping (PointColor) -> Double,
                              set: @escaping (inout PointColor, Double) -> Void,
                              bipolar: Bool = true) -> some View {
        LumenSlider(title: t,
                    value: maskValue(id, "point.\(t).\(index)",
                                     get: { m in
                                         guard m.adjust.pointColors.indices.contains(index)
                                         else { return d }
                                         return get(m.adjust.pointColors[index])
                                     },
                                     set: { m, v in
                                         guard m.adjust.pointColors.indices.contains(index)
                                         else { return }
                                         set(&m.adjust.pointColors[index],
                                             Num.clamp(v, r.lowerBound, r.upperBound))
                                     }),
                    range: r, defaultValue: d, step: 1, decimals: 0, bipolar: bipolar)
    }

    // MARK: - Small views

    /// Every component type that can select something, and only those.
    ///
    /// The fourth section — "AI — needs a model Lumen does not ship", each of its three
    /// entries suffixed "· empty" — is gone, and Depth Range has left the Range list.
    /// All four were an offer and a retraction in the same row: choosing one built a
    /// component that rasterizes to an empty plane, and the panel then spent a paragraph
    /// underneath saying so. Absence is quieter and it is truer. `MaskKind` still
    /// carries all four, `kindName` still names them and their editors still open, so a
    /// recipe made elsewhere loses nothing by this.
    ///
    /// `prominent` is the empty-list rendering: the same roster, drawn as the one thing
    /// worth pressing rather than as a corner of a header.
    private func kindMenu(label: String, prominent: Bool = false,
                          action: @escaping (MaskKind) -> Void) -> some View {
        Menu {
            Section("Drawn") {
                ForEach(MaskPanel.drawnKinds, id: \.self) { k in
                    Button(MaskPanel.kindName(k)) { action(k) }
                }
            }
            Section("Range") {
                ForEach(MaskPanel.rangeKinds, id: \.self) { k in
                    Button(MaskPanel.kindName(k)) { action(k) }
                }
            }
            Section("AI — on this Mac") {
                ForEach(MaskPanel.visionKinds, id: \.self) { k in
                    Button(MaskPanel.kindName(k)) { action(k) }
                }
            }
        } label: {
            HStack(spacing: prominent ? 5 : 3) {
                Image(systemName: "plus")
                    .font(.system(size: prominent ? 11 : 9, weight: .semibold))
                Text(label)
                    .font(.system(size: prominent ? 12 : 10,
                                  weight: prominent ? .medium : .regular))
            }
            .padding(.vertical, prominent ? 4 : 0)
        }
        .fixedSize()
        .help("Subject, Background and People are computed on this Mac by Vision, with "
              + "no download")
    }

    private func smallButton(_ title: String, _ systemImage: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 9))
                Text(title).font(.system(size: 10))
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Lumen.primaryText)
    }

    /// The four rows of copy this panel still draws, and none of them is prose.
    ///
    /// There were nineteen, always visible, in the panel that also holds thirty-five
    /// sliders plus a per-component editor — the worst prose-to-control ratio in the
    /// app. Fifteen were explanation. They are DELETED rather than collapsed behind a
    /// ⓘ row, because that was the previous fix and it turned nineteen paragraphs into
    /// nineteen rows advertising a tooltip (docs/30 §2.2). What is left is instrument:
    /// three carry the live geometry of the gradient or ellipse under the pointer right
    /// now, and one names a component that is producing nothing at this moment.
    ///
    /// So this always draws, and there is no `prominent:` to forget. Non-prominent
    /// `DevelopNote` renders nothing at all now; a note in this panel that nobody can
    /// see would be a bug, not a quiet default.
    private func note(_ text: String) -> some View {
        DevelopNote(text, prominent: true)
    }

    // MARK: - Static tables

    static let evMin: Double = -10
    static let evMax: Double = 4

    static func ev(_ n: Double) -> Double { evMin + Num.saturate(n) * (evMax - evMin) }

    static func normalizedEV(_ ev: Double) -> Double {
        Num.saturate((ev - evMin) / (evMax - evMin))
    }

    static let drawnKinds: [MaskKind] = [.brush, .linear, .radial]

    /// Depth Range is deliberately not in this list, and there is no `modelKinds` list
    /// any more. Between them they named the four kinds the picker can no longer offer:
    /// nothing estimates depth, nothing reads embedded depth, and no Core ML model is
    /// bundled, so all four rasterize to an empty plane. The kinds themselves stay in
    /// `MaskKind` — the wire format carries them and a foreign recipe may hold one —
    /// and their editors still open. What is gone is the offer.
    static let rangeKinds: [MaskKind] = [.lumaRange, .colorRange, .similarity,
                                         .similarityLine]

    /// Still the full roster: this is what decides whether a new mask gets the
    /// edge-aware snap seeded, which is a question about mattes and not about menus.
    static let aiKinds: [MaskKind] = [.aiSubject, .aiSky, .aiBackground, .aiObject,
                                      .aiPerson, .aiLandscape]

    /// What the picker offers, derived from `MaskKind.matteProvider` so a kind cannot
    /// end up in the wrong list. Only Vision's three: they come out of an OS framework
    /// on this Mac with no download and no bundled weights.
    static let visionKinds: [MaskKind] = aiKinds.filter { $0.matteProvider == .vision }

    static func kindName(_ kind: MaskKind) -> String {
        switch kind {
        case .brush: return "Brush"
        case .linear: return "Linear Gradient"
        case .radial: return "Radial Gradient"
        case .lumaRange: return "Brightness Range"
        case .colorRange: return "Colour Range"
        // "Similarity" is the kernel's word. What the photographer does is pick a
        // colour, or drag a line along one.
        case .similarity: return "Colour Pick"
        case .similarityLine: return "Colour Along a Line"
        case .aiSubject: return "Subject"
        case .aiSky: return "Sky"
        case .aiBackground: return "Background"
        case .aiObject: return "Object"
        case .aiPerson: return "People"
        case .aiLandscape: return "Landscape"
        case .depthRange: return "Depth Range"
        }
    }

    static func opGlyph(_ op: MaskOp) -> String {
        switch op {
        case .add: return "∪"
        case .subtract: return "∖"
        case .intersect: return "∩"
        }
    }

    /// The nine person parts plus Entire Person (the default), and the six landscape
    /// classes — exactly the sets the spec fixes.
    /// A component that already satisfies `validationError()` wherever the format lets
    /// one: a new mask should render something the moment it is created.
    static func makeComponent(kind: MaskKind, op: MaskOp) -> MaskComponent {
        var c = MaskComponent(op: op, kind: kind)
        switch kind {
        case .brush:
            c.strokesRef = try? BrushStrokeSet().blobRef()
        case .linear:
            c.line = [0.5, 0.75, 0.5, 0.25]
        case .radial:
            c.center = [0.5, 0.5]
            c.radii = [0.3, 0.3]
            c.rotation = 0
            c.feather = 50
        case .lumaRange:
            c.lo = 0
            c.hi = 1
            c.smooth = 50
        case .colorRange:
            c.samples = [AppState.placeholderSample]
            c.rangeAmount = 50
        case .similarity, .similarityLine:
            c.samples = [AppState.placeholderSample]
            c.chromaSel = 50
            c.lumaSel = 50
            if kind == .similarityLine { c.line = [0.5, 0.75, 0.5, 0.25] }
        case .depthRange:
            c.depthLo = 0
            c.depthHi = 1
            c.smooth = 50
        // `personParts` and `classes` are deliberately left nil. Nothing reads them,
        // so seeding them wrote a value into every new component that no stage would
        // ever consult — and made a mask's stored form claim a selection it does not
        // have.
        case .aiPerson, .aiLandscape,
             .aiSubject, .aiSky, .aiBackground, .aiObject:
            break
        }
        return c
    }

    static func lineSummary(_ c: MaskComponent) -> String {
        guard let line = c.line, line.count == 4 else { return "no line yet" }
        return String(format: "(%.2f, %.2f) → (%.2f, %.2f)", line[0], line[1], line[2], line[3])
    }

    static func ellipseSummary(_ c: MaskComponent) -> String {
        guard let centre = c.center, centre.count == 2,
              let radii = c.radii, radii.count == 2 else { return "no ellipse yet" }
        return String(format: "centre (%.2f, %.2f), radii (%.2f, %.2f)",
                      centre[0], centre[1], radii[0], radii[1])
    }

    /// Working-space RGB is scene-linear, so a swatch gets a rough encode before it is
    /// shown — otherwise every chip reads as too dark.
    static func chipColor(_ sample: [Double]) -> Color {
        guard sample.count >= 3 else { return Lumen.controlBackground }
        let r = Num.saturate(pow(Num.saturate(sample[0]), 1.0 / 2.2))
        let g = Num.saturate(pow(Num.saturate(sample[1]), 1.0 / 2.2))
        let b = Num.saturate(pow(Num.saturate(sample[2]), 1.0 / 2.2))
        return Color(red: r, green: g, blue: b)
    }
}

#endif

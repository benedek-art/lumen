// MaskPanel.swift
// The mask editor: the photo's mask list, the selected mask's component stack, its
// refinement chain, and the full local adjustment set that runs through its alpha.
//
// THIS IS THE WHOLE DEVELOP COLUMN while `WorkspaceLayout.isMasking` is set — not a
// panel among the workspace's sections and no longer a dock stacked above them. The
// owner asked for "its own page ... its own kind of section area where you can fully
// customize stuff about the masks", and the model agrees with him: `LocalAdjust` is the
// global adjustment set again, so a column that drew both offered Tone, Curve, Colour
// and Grading twice over. `MaskEditor` in DevelopColumn.swift is the seam.
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
    /// False when the caller has already titled it, which is what `MaskEditor` does —
    /// the column's top bar prints "Masks" beside the way out, and this printing it
    /// again a row below is two identical headings stacked. Every other panel the column
    /// embeds has this escape (`ZonesPanel.showsSectionHeader`, `ColorPanel.only`) and
    /// this one never did. The default is what a standalone rendering keeps.
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
    /// Whether each add-board is open. TWO flags, not one: the mask list and the
    /// component stack both disclose the same board, and a single flag opened both at
    /// once — twenty tiles under two headings, for one press.
    ///
    /// Closed by default once a photograph has masks; the empty state draws the board
    /// unconditionally instead, because there is nothing there to disclose it with.
    @State private var maskPickerOpen: Bool = false
    @State private var componentPickerOpen: Bool = false
    @State private var componentsExpanded: Bool = true
    @State private var refineExpanded: Bool = true
    @State private var lightExpanded: Bool = true
    @State private var colourExpanded: Bool = true
    @State private var curveExpanded: Bool = true
    @State private var wheelsExpanded: Bool = true
    @State private var detailExpanded: Bool = false
    @State private var pointExpanded: Bool = false

    // MARK: - Body

    /// NO SCROLL VIEW, NO PADDING, NO BACKGROUND OF ITS OWN.
    ///
    /// This fills the column but it does not OWN the column: `DevelopPanel.scrollColumn`
    /// supplies the scroll view, the horizontal padding and the background, exactly as
    /// it does for a workspace's sections. A nested `ScrollView` here would be a scroll
    /// trap — the column would stop scrolling wherever the pointer happened to be — and
    /// a second background would put a panel-coloured rectangle on a panel-coloured
    /// panel.
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
            if showsOwnHeader {
                LumenSectionHeader(title: "Masks", isExpanded: nil,
                                   isModified: !list.isEmpty)
            }
            ForEach(Array(list.indices), id: \.self) { i in maskRow(list[i], index: i) }
            // BELOW the rows, full width, not beside the header. The board it discloses
            // is a three-column grid of tiles; squeezed into a header's HStack it has no
            // room to be one. With no masks at all `emptyMaskState` draws the same board
            // with nothing to disclose it.
            if !list.isEmpty {
                kindMenu(label: "Add a mask", isOpen: $maskPickerOpen) { kind in
                    addMask(kind: kind)
                }
            }
            if let mask = activeMask {
                // "Strength", and it scales the EFFECT, not the selection — which is
                // why two sliders called Amount, nine rows apart, was the wrong pair of
                // names for the wrong pair of things.
                LumenSlider(title: "Strength",
                            value: maskValue(mask.id, "amount", get: { $0.amount },
                                             set: { $0.amount = Num.clamp($1, 0, 200) }),
                            range: 0...200, defaultValue: 100, step: 1, decimals: 0)
                // Whole-mask invert (docs/08 §8.1), not the per-component one further
                // down: this flips the folded stack. It runs BEFORE the refinement
                // chain, so Refine still snaps to the picture and Grow / Shrink still
                // grows what is now selected.
                LumenToggleRow(title: "Invert selection",
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
        VStack(alignment: .leading, spacing: 0) {
            kindMenu(label: "Add a mask", isOpen: $maskPickerOpen, prominent: true) { kind in
                addMask(kind: kind)
            }
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

            // Masks fold in list order too — both renderers walk `plan.masks` front to
            // back, so where two masks overlap the later one is working on the earlier
            // one's output. Same control as the component rows below, because it is the
            // same question being asked one level up.
            reorderControls(canMoveUp: index > 0,
                            canMoveDown: index < masks.count - 1,
                            what: "mask") { delta in
                moveMask(mask.id, by: delta)
            }

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
        // Hovering a row shows what it selects. `hoverMaskOverlay` holds the 120 ms
        // intent that keeps a pointer crossing the list on its way somewhere else from
        // strobing ten overlays across the photograph (docs/36 §1.4).
        .onHover { inside in state.hoverMaskOverlay(inside ? mask.id : nil) }
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

                // NO GLYPHS ON EITHER OF THESE, and the tint menu is why the rule
                // exists. The four colours are the one list in this panel whose meaning
                // IS a colour, and `LumenMenuItem` draws its glyph in `secondaryText`
                // like every other piece of chrome in the app — four identical grey
                // circles labelled Red, Green, White and Black would be a worse row
                // than no circle at all. The modes have no honest shape either: "Image
                // on Black" is a compositing rule, not an object.
                LumenMenu(title: state.maskOverlayMode.label,
                          help: "⌥O cycles the six modes") {
                    ForEach(MaskOverlay.Mode.allCases, id: \.self) { m in
                        LumenMenuItem(title: m.label,
                                      isSelected: state.maskOverlayMode == m) {
                            state.maskOverlayMode = m
                        }
                    }
                }

                LumenMenu(title: state.maskOverlayTint.label,
                          help: "⇧O cycles red, green, white and black") {
                    ForEach(MaskOverlay.Tint.allCases, id: \.self) { t in
                        LumenMenuItem(title: t.label,
                                      isSelected: state.maskOverlayTint == t) {
                            state.maskOverlayTint = t
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: Lumen.rowHeight)
        }
    }

    // MARK: - Component stack

    private func componentSection(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Components", isExpanded: $componentsExpanded,
                               isModified: !mask.components.isEmpty)
            if componentsExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(mask.components.indices), id: \.self) { i in
                        componentRow(mask, i)
                    }
                    if let i = activeComponentIndex, mask.components.indices.contains(i) {
                        componentEditor(mask.id, i, mask.components[i])
                    }
                    // Same board, same place: under the list it adds to.
                    kindMenu(label: "Add to this mask", isOpen: $componentPickerOpen) { kind in
                        addComponent(kind: kind, to: mask.id)
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
            // ORDER IS AN ARGUMENT HERE, not a preference. `MaskRaster.combine` folds
            // the stack top-down into an accumulator that seeds empty, so Subject
            // ∪ then Sky ∖ is a different selection from Sky ∖ then Subject ∪ — the
            // second one subtracts from nothing and then adds everything back. The
            // panel let you set the operation and never let you move the row, so half
            // of what the fold can express was unreachable.
            reorderControls(canMoveUp: index > 0,
                            canMoveDown: index < mask.components.count - 1,
                            what: "component") { delta in
                moveComponent(mask.id, from: index, by: delta)
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
            // "Invert this" against the mask's "Invert selection" above: the owner's
            // "there are two inverts and I don't know what that means" was two booleans
            // wearing one word. They are still two controls, because they are two
            // operations at two levels — but they no longer have the same name.
            LumenToggleRow(title: "Invert this", isOn: invertBinding(id, i),
                           help: "Inverts this component before it folds into the stack")
            LumenSlider(title: "Contribution",
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
                // ±90, not ±180: an axis-aligned ellipse has rotational period 180°
                // (`MaskRaster.radialPlane`), so half the old track duplicated the other
                // half — two thumb positions 180° apart rasterized the same mask.
                optionalSlider(id, i, "Rotation", \.rotation, -90...90, 0, bipolar: true)
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
                optionalSlider(id, i, "Tolerance", \.rangeAmount, 0...100, 50)
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
            LumenSlider(title: "Max strength", value: brushValue(\.density), range: 0...100,
                        defaultValue: 100, step: 1, decimals: 0, bipolar: false)
            LumenToggleRow(title: "Eraser", isOn: brushFlag(\.erase),
                           help: "Erase strokes fold into the same buffer in draw order")
            LumenToggleRow(title: "Stay inside edges", isOn: brushFlag(\.automask),
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
            optionalSlider(id, i, "Colour tolerance", \.chromaSel, 0...100, 50)
            optionalSlider(id, i, "Brightness tolerance", \.lumaSel, 0...100, 50)
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
            // "Edge", not "Refine": the section name used to be the same word as the
            // first slider inside it AND as a Colour Range control further up.
            LumenSectionHeader(title: "Edge", isExpanded: $refineExpanded,
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
                    // FOLLOW, not "snap". A guided filter bends the alpha toward image
                    // structure with a radius and a regularisation; it does not snap to
                    // anything, and at low values it does nothing a person can see. A
                    // control named "Snap" that visibly does nothing at 10 reads as
                    // broken, which is the failure this rebuild exists to remove
                    // (docs/36 §1.3).
                    refineSlider(mask.id, "Follow edges", \.feather, 0...100, 0)
                    refineSlider(mask.id, "Expand / Contract", \.edge, -50...50, 0,
                                 bipolar: true)
                    // "Soften edge", not "Feather": this is a Gaussian blur of the
                    // FINISHED alpha, and the brush's Feather is the hardness of one
                    // stamp. Two controls, nine rows apart, that were the same word.
                    refineSlider(mask.id, "Soften edge", \.blur, 0...100, 0)
                    // The density ramp. "Curve" was its old name and it sat directly
                    // above a section called Curve, which is the collision that could
                    // not be defended; "Start"/"End" were a 1994 histogram dialog.
                    levelsSlider(mask.id, "Ramp from", low: true)
                    levelsSlider(mask.id, "Ramp to", low: false)
                    refineSlider(mask.id, "Ramp shape", \.levelsGamma, 0.2...5, 1,
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
                    // WIRED, AND THE TARGET IS NOW A COLOUR THE PHOTOGRAPHER CHOSE.
                    //
                    // It used to seed `[0.5, 0.5, 0.5]` and offer no way to change it,
                    // because nothing in the app wrote `colorTint` — so the target was
                    // always neutral, and `applyColorTint` against a neutral target
                    // holds luminance while mixing toward grey: it DESATURATED. A
                    // control that moves the picture in the opposite direction to its
                    // own name is worse than an absent one, and its help text admitted
                    // as much rather than fixing it.
                    LumenToggleRow(title: "Colorize",
                                   isOn: optionBinding(mask.id, hasTint,
                                                       on: { MaskPanel.enableTint(&$0) },
                                                       off: { $0.adjust.colorTint = nil }),
                                   help: "Mixes everything the mask selects toward one "
                                       + "colour, holding each pixel's own brightness")
                    if hasTint {
                        tintTargetRow(mask)
                        adjustSlider(mask.id, "Colorize amount", \.colorTintStrength, 0...100,
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
                        // NO BLENDING OR BALANCE ROW. `adoptingWindows(from:)` copies
                        // the global wheels' `pivots`, `blending` and `balance` over the
                        // mask's own before either render path sees them — its own doc
                        // comment asserts the premise that made that safe, "whose window
                        // fields no mask control can write", which stopped being true
                        // when these two rows were added. Dragging them changed the
                        // recipe, the fingerprint and the modified dot, and produced a
                        // bit-identical frame. Worse: if they were the only mask grade
                        // edits, `GradingWheels.isNeutral` stayed true and the stage was
                        // declared identity, so no table was baked at all.
                        //
                        // docs/08 §8.4's contract is that a mask inherits the global
                        // tonal windows, so the rows go rather than the adoption.
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
                    // DELIBERATELY ABSENT, and re-checked with this rebuild: local
                    // Noise, Noise (chroma), Moiré, Defringe and Grain. All five are
                    // fields on `LocalAdjust`, all five round-trip through the wire
                    // format, and all five are read by NOTHING — `applyLocalAdjust`
                    // and `LocalPlan` between them are the complete list of consumers,
                    // and neither mentions any of them. So a slider here would move
                    // while the picture did not, which is worse than an absent one
                    // because it costs the photographer the time to find out.
                    //
                    // If you are adding one back, add the render stage first; the
                    // control is the easy half. The four above are here precisely
                    // because they DO have one (`localDetail` on the GPU path, the
                    // matching block in `ReferenceRenderer`).
                    //
                    // The row announcing the absence is gone too. There is nothing on
                    // screen for it to be about, and an apology for a control you
                    // cannot see is one more thing to read past.
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
        // The first second of a mask used to show nothing at all: no overlay, no
        // thumbnail, no pin. The one moment a photographer most needs to see what a
        // mask selected had no feedback in it (docs/35 §2.3). It flashes and stands
        // down; `O` is still how you make it stay.
        state.flashMaskOverlay(id)
    }

    private func addComponent(kind: MaskKind, to id: String) {
        let component = MaskPanel.makeComponent(kind: kind, op: .add)
        editMask(id, key: nil) { m in
            m.components.append(component)
            if MaskPanel.aiKinds.contains(kind), m.refine == MaskRefine() { m.refine.feather = 10 }
        }
        selectedComponent = Swift.max((mask(id)?.components.count ?? 1) - 1, 0)
    }

    /// A swap rather than a remove-and-insert: the move is always by one place, and the
    /// selection follows the row so that clicking the chevron twice moves the same
    /// component twice instead of walking the selection down the stack.
    private func moveComponent(_ id: String, from index: Int, by delta: Int) {
        let target = index + delta
        editMask(id, key: nil) { m in
            guard m.components.indices.contains(index),
                  m.components.indices.contains(target) else { return }
            m.components.swapAt(index, target)
        }
        if mask(id)?.components.indices.contains(target) == true { selectedComponent = target }
    }

    private func moveMask(_ id: String, by delta: Int) {
        state.updateRecipe(coalescingKey: nil) { recipe in
            guard let i = recipe.masks.firstIndex(where: { $0.id == id }) else { return }
            let target = i + delta
            guard recipe.masks.indices.contains(target) else { return }
            recipe.masks.swapAt(i, target)
        }
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
    private func kindMenu(label: String, isOpen: Binding<Bool>,
                          prominent: Bool = false,
                          action: @escaping (MaskKind) -> Void) -> some View {
        // A DISCLOSURE OVER A BOARD, not a popup menu.
        //
        // What stood here was `LumenMenu` — the owner's "a container inside of a
        // container inside of a dropdown". The roster is the one thing in this panel a
        // photographer chooses by RECOGNITION rather than by reading, and a menu hides
        // every shape until after the decision to open it. Lightroom's masking feels
        // approachable for three reasons and this is the first of them: the whole
        // roster is on screen at once.
        //
        // `prominent` is the empty-list rendering, where the board simply IS the panel
        // and there is nothing to disclose.
        VStack(alignment: .leading, spacing: 4) {
            if !prominent {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { isOpen.wrappedValue.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        Text(label).font(.lumenBody)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isOpen.wrappedValue ? 180 : 0))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Lumen.secondaryText)
                    .padding(.horizontal, 4)
                    .frame(height: Lumen.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lumenClickCursor()
                .help("Every kind of selection, on one board")
            }
            if prominent || isOpen.wrappedValue {
                kindBoard { kind in
                    isOpen.wrappedValue = false
                    action(kind)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// The board itself: three columns, grouped by the QUESTION each group answers.
    ///
    /// "Range" and "AI — on this Mac" were engineering categories — the first names a
    /// kernel family and the second names where the model runs. Neither is what a
    /// photographer is deciding between. "Draw it by hand", "Find it by tone or colour"
    /// and "Find it for me" are.
    private func kindBoard(_ action: @escaping (MaskKind) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            boardGroup("Draw it by hand", MaskPanel.drawnKinds, action)
            boardGroup("Find it by tone or colour", MaskPanel.rangeKinds, action)
            boardGroup("Find it for me", MaskPanel.visionKinds, action)
        }
        .padding(.vertical, 2)
    }

    private func boardGroup(_ title: String, _ kinds: [MaskKind],
                            _ action: @escaping (MaskKind) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LumenCapsLabel(text: title, size: 10, color: Lumen.tertiaryText)
            // Three across, laid out by hand rather than by `LazyVGrid`: the roster is
            // ten entries and will not grow past a dozen, and a lazy grid inside the
            // column's one ScrollView measures itself badly at this size.
            VStack(spacing: 4) {
                ForEach(Array(stride(from: 0, to: kinds.count, by: 3)), id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(row..<Swift.min(row + 3, kinds.count), id: \.self) { i in
                            kindTile(kinds[i], action)
                        }
                        // Keeps a short last row's tiles the same width as a full one's.
                        if kinds.count - row < 3 {
                            ForEach(0..<(3 - (kinds.count - row)), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
        }
    }

    private func kindTile(_ kind: MaskKind,
                          _ action: @escaping (MaskKind) -> Void) -> some View {
        Button { action(kind) } label: {
            VStack(spacing: 4) {
                Image(systemName: MaskPanel.kindSymbol(kind))
                    .font(.system(size: 15, weight: .regular))
                Text(MaskPanel.kindName(kind))
                    .font(.lumenCaption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Lumen.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lumenSurface(radius: Lumen.radiusChip, elevation: .flush,
                      fill: Lumen.controlSurface)
        .lumenHoverable(radius: Lumen.radiusChip)
        .lumenClickCursor()
        .help(MaskPanel.kindPurpose(kind))
    }

    /// Two chevrons, for a list whose ORDER changes the picture.
    ///
    /// Buttons rather than drag-to-reorder: these rows live in a `VStack` inside the
    /// column's one `ScrollView`, and a drag reorder there would need either a nested
    /// `List` — a scroll trap, which is the defect this panel was rebuilt to remove —
    /// or a hand-written hit-test against every row's frame. Two clicks move a row one
    /// place, which for stacks that are three deep is the whole job.
    private func reorderControls(canMoveUp: Bool, canMoveDown: Bool, what: String,
                                 move: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 1) {
            reorderButton("chevron.up", enabled: canMoveUp,
                          help: "Move this \(what) earlier in the stack") { move(-1) }
            reorderButton("chevron.down", enabled: canMoveDown,
                          help: "Move this \(what) later in the stack") { move(1) }
        }
    }

    private func reorderButton(_ symbol: String, enabled: Bool, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                // A fixed box, so a row with one chevron disabled does not shuffle the
                // controls beside it a pixel to the left.
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? Lumen.secondaryText : Lumen.separator)
        .help(help)
    }

    /// The tint target, as a swatch that opens the system colour panel.
    ///
    /// `ColorPicker` rather than an eyedropper: sampling FROM the frame is what the
    /// mask's Point Colour swatches already do, and a tint is the opposite job — you are
    /// naming a colour the picture does not contain yet. An eyedropper would also need a
    /// new `PickTarget`, which is a change to state this panel does not own.
    private func tintTargetRow(_ mask: Mask) -> some View {
        HStack(spacing: 6) {
            Text("Colorize to")
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
            Spacer(minLength: 0)
            ColorPicker("Colorize to", selection: tintBinding(mask.id),
                        supportsOpacity: false)
                .labelsHidden()
        }
        .frame(height: Lumen.rowHeight)
    }

    /// Working-space RGB on one side, a display colour on the other. `chipColor` is the
    /// encode every other swatch in this panel is drawn through, so this is its inverse
    /// and the two have to stay a pair — a picker that decoded differently would show a
    /// colour the chip beside it does not agree with.
    private func tintBinding(_ id: String) -> Binding<Color> {
        Binding(get: {
                    MaskPanel.chipColor(mask(id)?.adjust.colorTint ?? MaskPanel.defaultTint)
                },
                set: { picked in
                    let working = MaskPanel.workingRGB(picked)
                    editMask(id, key: "mask.tint.\(id)") { $0.adjust.colorTint = working }
                })
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

    /// One glyph per kind, and every one of them draws what the kind DOES: the brush is
    /// a brush, the linear gradient is a square lit from one side, the radial is a
    /// circle inside a circle, the two Colour Pick kinds carry the eyedropper they are
    /// operated with. The whole roster is covered rather than the three lists the menu
    /// currently offers, so a kind that comes back — Depth Range, the model kinds —
    /// cannot arrive glyphless and leave a hole in a column of icons.
    ///
    /// This is the owner's "add visuals a little bit more" where it pays best: an add
    /// menu is opened knowing roughly what you want, and a shape is recognised before a
    /// word is read.
    static func kindSymbol(_ kind: MaskKind) -> String {
        switch kind {
        case .brush: return "paintbrush"
        case .linear: return "square.lefthalf.filled"
        case .radial: return "circle.circle"
        case .lumaRange: return "circle.lefthalf.filled"
        case .colorRange: return "paintpalette"
        case .similarity: return "eyedropper"
        case .similarityLine: return "eyedropper.halffull"
        case .aiSubject: return "viewfinder"
        case .aiSky: return "cloud.sun"
        case .aiBackground: return "photo"
        case .aiObject: return "cube"
        case .aiPerson: return "person.2"
        case .aiLandscape: return "mountain.2"
        case .depthRange: return "cube.transparent"
        }
    }

    /// What each kind is FOR, in one line, on the tile's hover.
    ///
    /// Not prose in the panel — docs/30 §2.2 measured what happened the last time this
    /// panel explained itself, and the answer was nineteen rows advertising a tooltip.
    /// This is the tooltip, on a control that is opened knowing roughly what you want,
    /// and it says what the kind SELECTS rather than how it works.
    static func kindPurpose(_ kind: MaskKind) -> String {
        switch kind {
        case .brush: return "Paint the selection by hand"
        case .linear: return "A straight fade across the frame — skies, foregrounds"
        case .radial: return "An oval, faded at its edge — spotlights and vignettes"
        case .lumaRange: return "Everything this bright, wherever it is"
        case .colorRange: return "Everything this colour, wherever it is"
        case .similarity: return "Click a colour; take what looks like it"
        case .similarityLine: return "A fade, but only where the colour matches"
        case .aiSubject: return "Whatever the photograph is of"
        case .aiSky: return "The sky, including through branches"
        case .aiBackground: return "Everything the subject is not"
        case .aiObject: return "One thing you point at"
        case .aiPerson: return "The people in the frame"
        case .aiLandscape: return "Sky, water, greenery, ground — by class"
        case .depthRange: return "Everything at this distance from the camera"
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
            // NO SEEDED REF. It used to be the content hash of an EMPTY stroke set, and
            // nothing ever wrote those bytes to the blob store — `MaskCanvas.apply` is
            // the only writer and it runs on a committed stroke. So an unpainted brush
            // component carried a reference that resolves nowhere, which is exactly what
            // `BrushStrokes.unresolvedReferences` reports and what export refuses the
            // whole photograph over: "1 brush stroke set could not be read — the masking
            // would have exported empty", for strokes nobody ever made.
            //
            // Reachable in one click: add a mask (Brush is first in the picker), decide
            // on a gradient instead, paint nothing, export. Leaving it nil is also the
            // honest state — the component then reads INCOMPLETE, which is what
            // `validationError()` exists to say.
            break
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

    /// What a freshly enabled tint starts on: a warm amber, chosen because it is the
    /// commonest thing anyone tints a mask toward and because it is unmistakably NOT
    /// neutral. `applyColorTint` normalises the target by its own luminance, so only the
    /// chromaticity of these three numbers matters — and a neutral target has none,
    /// which is exactly why the mid-grey this replaces desaturated instead of tinting.
    static let defaultTint: [Double] = [0.96, 0.48, 0.15]

    /// Turning the tint on also lifts Strength off zero when it is still there.
    ///
    /// Strength defaults to 0 and gates the whole stage, so the toggle on its own
    /// changed nothing at all — a switch that has to be followed by a slider before it
    /// does anything teaches that it is broken. 50 is a tint you can see and undo, not
    /// one that commits the frame.
    static func enableTint(_ mask: inout Mask) {
        if mask.adjust.colorTint == nil { mask.adjust.colorTint = defaultTint }
        if mask.adjust.colorTintStrength == 0 { mask.adjust.colorTintStrength = 50 }
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

    /// `chipColor` run backwards, for the one control that reads a colour instead of
    /// writing one. sRGB rather than the display's own space: the picker hands back a
    /// colour in whatever space the user picked it in, and the encode this undoes is the
    /// same rough 2.2 the chips are drawn with.
    static func workingRGB(_ color: Color) -> [Double] {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return defaultTint }
        return [pow(Num.saturate(Double(srgb.redComponent)), 2.2),
                pow(Num.saturate(Double(srgb.greenComponent)), 2.2),
                pow(Num.saturate(Double(srgb.blueComponent)), 2.2)]
    }
}

#endif

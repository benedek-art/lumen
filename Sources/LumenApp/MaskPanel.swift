// MaskPanel.swift
// The Masks panel: the photo's mask list, the selected mask's component stack, its
// refinement chain, and the full local adjustment set that runs through its alpha.
//
// Four things this panel exists to get right:
//   · The component operation is a control, not a modifier: Add / Subtract / Intersect
//     are three equal buttons, editable after creation. LrC hides Intersect behind an
//     Alt-click at creation time; that is the difference being made here.
//   · The refinement chain appears in the order the engine runs it (Refine → Edge Shift
//     → Feather → Levels) under its UI names, never the wire names — `MaskRefine` spells
//     the guided filter `feather` and the Gaussian `blur`, and leaking that would teach
//     the user the wrong word for both.
//   · A mask runs the local point curve and the local grading wheels — the two tools
//     Lightroom Classic still lacks inside a mask — so both are visible sections.
//   · Where the format has no field for a spec'd control (linear Mirror, per-axis
//     colour tolerances, similarity geometry, depth source), the control is ABSENT
//     rather than invented.
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                maskListSection
                if let mask = activeMask {
                    Divider()
                    componentSection(mask)
                    Divider()
                    refineSection(mask)
                    Divider()
                    adjustSections(mask)
                } else {
                    note("No masks yet. A mask is a stack of components combined with add, "
                         + "subtract and intersect, carrying one set of local adjustments.")
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 18)
        }
        .background(Lumen.panelBackground)
        .foregroundStyle(Lumen.primaryText)
    }

    // MARK: - Mask list

    private var maskListSection: some View {
        let list = masks
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                LumenSectionHeader(title: "Masks", isExpanded: nil, isModified: !list.isEmpty)
                kindMenu(label: "Add mask") { kind in addMask(kind: kind) }
            }
            ForEach(Array(list.indices), id: \.self) { i in maskRow(list[i], index: i) }
            if let mask = activeMask {
                LumenSlider(title: "Amount",
                            value: maskValue(mask.id, "amount", get: { $0.amount },
                                             set: { $0.amount = Num.clamp($1, 0, 200) }),
                            range: 0...200, defaultValue: 100, step: 1, decimals: 0)
                // Whole-mask invert (docs/08 §8.1), not the per-component one further
                // down: this flips the folded stack. It runs BEFORE the refinement
                // chain, so Refine still snaps to the picture and Edge Shift still
                // grows what is now selected.
                LumenToggleRow(title: "Invert mask",
                               isOn: optionBinding(mask.id, mask.invert,
                                                   on: { $0.invert = true },
                                                   off: { $0.invert = false }),
                               help: "Selects everything this stack does not, after the "
                                   + "components combine and before Refine, Edge Shift, "
                                   + "Feather and Levels")
                HStack(spacing: 4) {
                    smallButton("Duplicate", "plus.square.on.square") { duplicateMask(mask.id) }
                    smallButton("Delete", "trash") { deleteMask(mask.id) }
                    Spacer(minLength: 0)
                }
                .frame(height: Lumen.rowHeight)
                overlayControls(mask)
                note("Amount scales the adjustment deltas, not the alpha: past 100 it "
                     + "amplifies beyond the slider maxima instead of clipping a mask that "
                     + "is already fully opaque.")
            }
        }
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
                    if let i = activeComponentIndex, mask.components.indices.contains(i) {
                        componentEditor(mask.id, i, mask.components[i])
                    } else {
                        note("No components yet, so this mask's alpha is empty. The stack "
                             + "folds in order, starting from nothing.")
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
                note(problem + " — it renders empty until that is supplied.",
                     prominent: true)
            }
        }
        .padding(.leading, 6).padding(.bottom, 4)
    }

    @ViewBuilder
    private func componentParameters(_ id: String, _ i: Int, _ c: MaskComponent) -> some View {
        switch c.kind {
        case .brush:
            brushParameters(c)
        case .linear:
            // Live: `lineSummary` is the gradient's current geometry, so this is a
            // readout wearing an instruction, not teaching.
            note("Drag on the image to set the gradient line — " + MaskPanel.lineSummary(c)
                 + ". The span between the ends is the feather; there is no other control.",
                 prominent: true)
        case .similarityLine:
            VStack(alignment: .leading, spacing: 2) {
                note("Drag on the image to set the ramp — " + MaskPanel.lineSummary(c) + ".",
                     prominent: true)
                similarityParameters(id, i, c)
            }
        case .radial:
            VStack(alignment: .leading, spacing: 2) {
                optionalSlider(id, i, "Feather", \.feather, 0...100, 50)
                optionalSlider(id, i, "Rotation", \.rotation, -180...180, 0, bipolar: true)
                note("Drag on the image to place and resize the ellipse — "
                     + MaskPanel.ellipseSummary(c) + ". Falloff runs inward from the edge.",
                     prominent: true)
            }
        case .lumaRange:
            VStack(alignment: .leading, spacing: 2) {
                bandSlider(id, i, "Band Lo", isLow: true, depth: false)
                bandSlider(id, i, "Band Hi", isLow: false, depth: false)
                optionalSlider(id, i, "Smoothness", \.smooth, 0...100, 50)
                note("EV-denominated on a fixed −10…+4 axis over scene luminance, never "
                     + "auto-ranged, so a band means the same on every frame.")
            }
        case .depthRange:
            VStack(alignment: .leading, spacing: 2) {
                bandSlider(id, i, "Near", isLow: true, depth: true)
                bandSlider(id, i, "Far", isLow: false, depth: true)
                optionalSlider(id, i, "Smoothness", \.smooth, 0...100, 50)
                // Nothing estimates depth and nothing reads embedded depth:
                // `aiMattes` is a literal empty dictionary at both call sites, so this
                // component rasterizes to an empty plane and selects nothing.
                note("No depth source in this build — embedded depth is not read and no "
                     + "estimator ships, so this component renders empty.",
                     prominent: true)
            }
        case .colorRange:
            VStack(alignment: .leading, spacing: 2) {
                sampleChips(id, i, c)
                optionalSlider(id, i, "Refine", \.rangeAmount, 0...100, 50)
                note("Refine drives the hue, chroma and lightness tolerances together; the "
                     + "per-axis split has no field in the format, so it is not shown.")
            }
        case .similarity:
            similarityParameters(id, i, c)
        // People and Landscape shipped sixteen checkboxes between them — ten person
        // parts, six landscape classes — that wrote `personParts` and `classes`, and
        // NOTHING read either field. The caption said parts were "synthesised from the
        // person matte"; nothing synthesised anything. Per-person chips and the nine
        // parts need a face-landmark pass and a per-person matte the wire format cannot
        // express yet, and Landscape needs a model that does not ship.
        //
        // docs/18: a control that stores a value nothing reads is worse than an absent
        // one, because absence is honest. So the checkboxes are gone and the note says
        // what the component actually selects. Both now route through `modelNote`, which
        // is what makes a row that has run and found nothing say so — People was the one
        // Vision kind whose editor skipped it, so a People mask could never show
        // NOTHING FOUND however long you waited.
        case .aiPerson:
            VStack(alignment: .leading, spacing: 2) {
                Text("Entire Person, for everyone in the frame.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Per-person selection and the nine body parts need a "
                     + "face-landmark pass and a per-person matte the recipe format "
                     + "cannot express yet, so they are not offered.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                modelNote(c)
            }
        case .aiLandscape:
            VStack(alignment: .leading, spacing: 2) {
                Text("Selects nothing yet — Lumen ships no landscape model.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("The six classes are designed and specified; the class toggles "
                     + "are not shown because nothing would read them.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                modelNote(c)
            }
        case .aiObject:
            // The prompt count and its Reset are gone, and this is the note that
            // replaces them. They were inert by construction, not by omission: nothing
            // anywhere writes `MaskComponent.prompt`, because `MaskCanvas.isLive`
            // excludes `aiObject` and the only other reference to the field in the app
            // was the count itself. So the row read "0 prompt point(s)" on every
            // component that has ever existed and could not read anything else, and
            // Reset cleared a value that was already nil. Two affordances for a model
            // that is not bundled, arranged so that the one thing they could tell you
            // was a number that never changes.
            VStack(alignment: .leading, spacing: 2) {
                Text("Selects nothing yet — Lumen ships no object model.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Click-to-select needs prompt points, and nothing writes them "
                     + "because there is nothing to prompt; the count and its Reset "
                     + "are not shown rather than shown reading zero forever.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                modelNote(c)
            }
        case .aiSubject, .aiSky, .aiBackground:
            modelNote(c)
        }
    }

    private func brushParameters(_ c: MaskComponent) -> some View {
        let ref = c.strokesRef.map { String($0.prefix(20)) + "…" } ?? "no blob yet"
        return VStack(alignment: .leading, spacing: 2) {
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
            note("The settings the NEXT stroke records. Size is a fraction of the source "
                 + "long edge, so a stroke keeps its width at export resolution. "
                 + "Strokes: " + ref + ".")
        }
    }

    private func similarityParameters(_ id: String, _ i: Int,
                                      _ c: MaskComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sampleChips(id, i, c)
            optionalSlider(id, i, "Chroma sel.", \.chromaSel, 0...100, 50)
            optionalSlider(id, i, "Luma sel.", \.lumaSel, 0...100, 50)
            note("Selectivity is the width of the OKLab similarity gate. Point positions "
                 + "and radius have no field in the shipped format, so the gate currently "
                 + "evaluates over the whole frame.")
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
                    + "Similarity Point on what you meant."
        case .needsModel:
            badge = "MODEL NEEDED"
            text = "No model for this is bundled and nothing computes it, so this "
                + "component selects nothing at all. Subject, Background and People "
                + "work today; this one does not."
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
                    refineSlider(mask.id, "Refine", \.feather, 0...100, 0)
                    refineSlider(mask.id, "Edge Shift", \.edge, -50...50, 0, bipolar: true)
                    refineSlider(mask.id, "Feather", \.blur, 0...100, 0)
                    levelsSlider(mask.id, "Levels Lo", low: true)
                    levelsSlider(mask.id, "Levels Hi", low: false)
                    refineSlider(mask.id, "Levels Gamma", \.levelsGamma, 0.2...5, 1,
                                 step: 0.05, decimals: 2, bipolar: true)
                    note("In engine order: an edge-aware snap against the image structure, "
                         + "a boundary shift, a Gaussian soften, then the density remap.")
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
                    // Whites and Blacks do two things, and this caption used to name
                    // only the first. They move the tone engine's ANCHORS, which is
                    // what reshapes the Highlights and Shadows windows — and globally
                    // those anchors also feed the display transform, which is the seam
                    // that makes them mean "white point" and "black point". A mask has
                    // no display transform of its own, so that half really does stop
                    // at the window geometry.
                    //
                    // But `ToneEngine.zonalStops` gives each of them a SHELF as well,
                    // added because an anchor-only Whites measured 26.7 code values
                    // over its whole travel and Blacks 0.20 — "a slider a photographer
                    // would call dead". `LocalPlan` and
                    // `ReferenceRenderer.applyLocalAdjust` both feed the local values
                    // into that same engine, so a mask carrying nothing but Whites
                    // +100 lifts the top of its range by up to 1.3 EV and Blacks −100
                    // drops the bottom by up to 2.2, with mid-grey untouched in both
                    // cases. "On their own they do not move the picture" described the
                    // engine before those shelves existed, and by then it was a claim
                    // no test covered on either path.
                    note("Whites and Blacks are shelves at the two ends of this mask's "
                         + "range, and they also reshape where Highlights and Shadows "
                         + "act. On their own they move the top and the bottom and "
                         + "leave mid-grey where it was.")
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
                    // `CurveStack`'s own evaluation, which is what gets baked.
                    CurveEditorView(target: .mask(mask.id))
                    note("A curve per mask — one of the two tools Lightroom still does "
                         + "not put inside a local adjustment. It taps AFTER the "
                         + "display transform, alongside the global curve, through this "
                         + "mask's alpha, so the axis means the same thing here as it "
                         + "does globally. Amount scales how far it moves the picture.")
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
                    } else {
                        note("Grading wheels inside a mask — the second thing Lightroom "
                             + "does not have locally. The same engine as the global "
                             + "grade, so the zone windows and the constant-luminance "
                             + "translation behave identically; the mask's Amount "
                             + "scales how far each wheel pushes, not which way.")
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
                    } else {
                        note("Up to eight swatches per mask, each shifting one colour without "
                             + "touching its neighbours on the hue circle.")
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
                    adjustSlider(mask.id, "Sharpness", \.sharpness, -100...100)
                    note("Texture, Clarity and Dehaze reuse the global base–detail "
                         + "decomposition; negative Sharpness softens.")
                    // Not shown: local Noise, Noise (chroma), Moiré, Defringe and
                    // Grain. Every one of them has a field in the recipe and no stage
                    // that reads it, and a slider that moves while the picture does
                    // not is worse than an absent one — it costs the user the time to
                    // find out. They come back when the stage does.
                    note("Local noise reduction, moiré, defringe and grain are not "
                         + "wired yet and are not shown. Use the global controls.",
                         prominent: true)
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

    private func kindMenu(label: String, action: @escaping (MaskKind) -> Void) -> some View {
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
            Section("AI — needs a model Lumen does not ship") {
                ForEach(MaskPanel.modelKinds, id: \.self) { k in
                    Button(MaskPanel.kindName(k) + "  ·  empty") { action(k) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                Text(label).font(.system(size: 10))
            }
        }
        .fixedSize()
        .help("Every component type. Subject, Background and People are computed on "
              + "this Mac by Vision, with no download; Sky, Object and Landscape need "
              + "a model that is not bundled, and adding one of those produces an "
              + "empty mask.")
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

    /// Explanatory copy, collapsed to a ⓘ row (see `DevelopNote`).
    ///
    /// Masks carried twenty of these, always visible, in the panel that also holds
    /// thirty-five sliders plus a per-component editor — the worst prose-to-control
    /// ratio in the app. Six stay visible, in the two categories `DevelopNote`
    /// documents: three that disclose something not wired (an incomplete component, the
    /// absent depth source, the local stages that do nothing), and three that carry the
    /// live geometry of the gradient or ellipse being dragged, which is an instrument
    /// rather than teaching.
    private func note(_ text: String, prominent: Bool = false) -> some View {
        DevelopNote(text, prominent: prominent)
    }

    // MARK: - Static tables

    static let evMin: Double = -10
    static let evMax: Double = 4

    static func ev(_ n: Double) -> Double { evMin + Num.saturate(n) * (evMax - evMin) }

    static func normalizedEV(_ ev: Double) -> Double {
        Num.saturate((ev - evMin) / (evMax - evMin))
    }

    static let drawnKinds: [MaskKind] = [.brush, .linear, .radial]
    static let rangeKinds: [MaskKind] = [.lumaRange, .colorRange, .similarity,
                                         .similarityLine, .depthRange]
    static let aiKinds: [MaskKind] = [.aiSubject, .aiSky, .aiBackground, .aiObject,
                                      .aiPerson, .aiLandscape]

    /// The menu splits the AI roster by what actually computes it, rather than filing
    /// all of it under "requires a model": three come out of Vision on this Mac with no
    /// download, and the rest select nothing at all until a model is bundled. Both
    /// lists are derived from `MaskKind.matteProvider`, so a kind cannot end up in the
    /// wrong one.
    /// (Depth Range is not in either list: it lives under Range, where its own row
    /// already says no depth source ships.)
    static let visionKinds: [MaskKind] = aiKinds.filter { $0.matteProvider == .vision }
    static let modelKinds: [MaskKind] = aiKinds.filter { $0.matteProvider == .model }

    static func kindName(_ kind: MaskKind) -> String {
        switch kind {
        case .brush: return "Brush"
        case .linear: return "Linear Gradient"
        case .radial: return "Radial Gradient"
        case .lumaRange: return "Luminance Range"
        case .colorRange: return "Colour Range"
        case .similarity: return "Similarity Point"
        case .similarityLine: return "Similarity Line"
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

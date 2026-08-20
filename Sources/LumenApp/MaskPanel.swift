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
//   · Where the format has no field for a spec'd control (whole-mask invert, linear
//     Mirror, per-axis colour tolerances, similarity geometry, depth source), the
//     control is ABSENT rather than invented.
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
                HStack(spacing: 4) {
                    smallButton("Duplicate", "plus.square.on.square") { duplicateMask(mask.id) }
                    smallButton("Delete", "trash") { deleteMask(mask.id) }
                    Spacer(minLength: 0)
                }
                .frame(height: Lumen.rowHeight)
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
                note(problem + " — it renders empty until that is supplied.")
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
                note("Relative depth, near = 0. Embedded depth is used when the file has "
                     + "it; otherwise it is estimated in the background.")
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
        case .aiPerson:
            checkboxList(id, i, MaskPanel.personParts, isParts: true,
                         caption: "Parts are synthesised from the person matte.")
        case .aiLandscape:
            checkboxList(id, i, MaskPanel.landscapeClasses, isParts: false,
                         caption: "Six classes, deliberately: snow is a luminance range "
                                + "intersected with this mask, not a seventh class.")
        case .aiObject:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(c.prompt?.count ?? 0) prompt point(s)")
                        .font(.system(size: 11)).foregroundStyle(Lumen.secondaryText)
                    Spacer(minLength: 0)
                    smallButton("Reset", "arrow.uturn.backward") {
                        editComponent(id, i, key: nil) { $0.prompt = nil }
                    }
                }
                .frame(height: Lumen.rowHeight)
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

    private func checkboxList(_ id: String, _ i: Int,
                              _ entries: [(key: String, label: String)],
                              isParts: Bool, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.indices), id: \.self) { e in
                LumenToggleRow(title: entries[e].label,
                               isOn: listBinding(id, i, entries[e].key, isParts: isParts),
                               help: "Include this in the mask")
            }
            note(caption)
        }
    }

    private func modelNote(_ c: MaskComponent) -> some View {
        HStack(spacing: 6) {
            LumenBadge(text: c.model ?? "MODEL NEEDED", emphasized: c.model == nil)
            Text(c.model == nil ? "Computed in the background once the model is available."
                                : "Cached at generation resolution; refine carries it up.")
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
                                   help: "Colorize the masked area; the eyedropper sets the swatch")
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
                    // The controls are absent rather than inert. `LocalAdjust.curve`
                    // has a wire format and no stage reads it: a local curve has to
                    // tap after the display transform, next to the global curve, and
                    // the local stage runs well before that. Offering four sliders
                    // that move a stored value and change no pixel is worse than
                    // offering none, because it costs the user the time to find out.
                    note("A curve per mask — the tool Lightroom still does not put "
                         + "inside a local adjustment. Not wired yet: it has to tap "
                         + "after the display transform, alongside the global curve, "
                         + "and the local stage runs before it. The global curve works.")
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
                        note("Grading wheels inside a mask — the second thing Lightroom does "
                             + "not have locally. Same colour space as the global grade, "
                             + "inheriting its zone pivots.")
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
                         + "wired yet and are not shown. Use the global controls.")
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

    private func addSample(_ id: String, _ i: Int) {
        editComponent(id, i, key: nil) { c in
            var list = c.samples ?? []
            guard list.count < 8 else { return }
            list.append([0.18, 0.18, 0.18])
            c.samples = list
        }
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

    private func addSwatch(_ id: String) {
        editMask(id, key: nil) { m in
            guard m.adjust.pointColors.count < 8 else { return }
            m.adjust.pointColors.append(PointColor(sample: [0.18, 0.18, 0.18]))
        }
        selectedSwatch = Swift.max((mask(id)?.adjust.pointColors.count ?? 1) - 1, 0)
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

    private func preserveBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { mask(id)?.adjust.curve?.preserveLuminance ?? true },
                set: { v in
                    editMask(id, key: nil) { m in
                        var c = m.adjust.curve ?? CurveSet()
                        c.preserveLuminance = v
                        m.adjust.curve = c
                    }
                })
    }

    private func listBinding(_ id: String, _ i: Int, _ key: String,
                             isParts: Bool) -> Binding<Bool> {
        Binding(
            get: {
                let c = component(id, i)
                return (isParts ? c?.personParts : c?.classes)?.contains(key) ?? false
            },
            set: { want in
                editComponent(id, i, key: nil) { c in
                    var list = (isParts ? c.personParts : c.classes) ?? []
                    if want {
                        if !list.contains(key) { list.append(key) }
                    } else {
                        list.removeAll { $0 == key }
                    }
                    let stored: [String]? = list.isEmpty ? nil : list
                    if isParts { c.personParts = stored } else { c.classes = stored }
                }
            })
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

    private func curveSlider(_ id: String, _ t: String,
                             _ p: WritableKeyPath<ParametricCurve, Double>) -> some View {
        LumenSlider(title: t,
                    value: maskValue(id, "curve." + t,
                                     get: { $0.adjust.curve?.parametric[keyPath: p] ?? 0 },
                                     set: { m, v in
                                         var c = m.adjust.curve ?? CurveSet()
                                         c.parametric[keyPath: p] = Num.clamp(v, -100, 100)
                                         m.adjust.curve = c
                                     }),
                    range: -100...100, defaultValue: 0, step: 1, decimals: 0)
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
            Section("AI — requires a model") {
                ForEach(MaskPanel.aiKinds, id: \.self) { k in
                    Button(MaskPanel.kindName(k) + "  ·  model") { action(k) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                Text(label).font(.system(size: 10))
            }
        }
        .fixedSize()
        .help("Every component type. The AI kinds run a model in the background and land as "
              + "a cached matte.")
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

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(Lumen.secondaryText)
            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
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
    static let personParts: [(key: String, label: String)] = [
        ("entirePerson", "Entire Person"), ("faceSkin", "Face Skin"),
        ("bodySkin", "Body Skin"), ("eyebrows", "Eyebrows"), ("eyeSclera", "Eye Sclera"),
        ("irisPupil", "Iris & Pupil"), ("lips", "Lips"), ("teeth", "Teeth"),
        ("hair", "Hair"), ("clothes", "Clothes"),
    ]

    static let landscapeClasses: [(key: String, label: String)] = [
        ("sky", "Sky"), ("water", "Water"), ("vegetation", "Vegetation"),
        ("mountains", "Mountains"), ("architecture", "Architecture"), ("ground", "Ground"),
    ]

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
            c.samples = [[0.18, 0.18, 0.18]]
            c.rangeAmount = 50
        case .similarity, .similarityLine:
            c.samples = [[0.18, 0.18, 0.18]]
            c.chromaSel = 50
            c.lumaSel = 50
            if kind == .similarityLine { c.line = [0.5, 0.75, 0.5, 0.25] }
        case .depthRange:
            c.depthLo = 0
            c.depthHi = 1
            c.smooth = 50
        case .aiPerson:
            c.personParts = ["entirePerson"]
        case .aiLandscape:
            c.classes = ["sky"]
        case .aiSubject, .aiSky, .aiBackground, .aiObject:
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

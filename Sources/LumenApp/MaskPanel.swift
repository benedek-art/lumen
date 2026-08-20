// MaskPanel.swift
// The Masks panel: the photo's mask list, the selected mask's component stack, its
// refinement chain, and the full local adjustment set that runs through its alpha.
//
// Four things this panel exists to get right:
//   · The component operation is a control, not a modifier. Add / Subtract / Intersect
//     are three equal buttons that stay editable after creation — LrC hides Intersect
//     behind an Alt-click at creation time and that is the difference being made here.
//   · The refinement chain is shown in the order the engine runs it (Refine → Edge
//     Shift → Feather → Levels) with the UI names, never the wire names: `MaskRefine`
//     spells the guided filter `feather` and the Gaussian `blur`, and a panel that
//     leaked that would teach the user the wrong word for both.
//   · A mask can run the local point curve and the local grading wheels — the two
//     tools Lightroom Classic still does not have inside a mask — so they are visible
//     sections here, not a disclosure nobody opens.
//   · Where the shipped wire format has no field for a spec'd control (whole-mask
//     invert, linear Mirror, per-axis colour tolerances, similarity point geometry,
//     depth source), the control is ABSENT rather than invented. A panel that writes
//     keys the format does not define is a migration nobody agreed to.
//
// Every slider is a `LumenSlider`, every edit goes through
// `AppState.updateRecipe(coalescingKey:)` so one drag is one undo step, and every
// index into `components` is bounds-checked at both read and write: a mask list is
// user work in flight and a stale index must degrade, never trap.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import SwiftUI

struct MaskPanel: View {
    @EnvironmentObject var state: AppState

    /// Brush parameters are session state, not recipe state: they are recorded INTO
    /// each stroke as it is drawn (BrushStroke carries its own size/feather/flow/
    /// density/flags), so the panel and the canvas share one store rather than
    /// inventing a component field the wire format does not have.
    @ObservedObject private var brush: MaskBrushStore = MaskBrushStore.shared

    @State private var selectedMaskID: String? = nil
    @State private var selectedComponent: Int = 0
    @State private var selectedSwatch: Int = 0
    @State private var componentsExpanded: Bool = true
    @State private var refineExpanded: Bool = true
    @State private var lightExpanded: Bool = true
    @State private var colourExpanded: Bool = true
    @State private var curveExpanded: Bool = true
    @State private var wheelsExpanded: Bool = true
    @State private var presenceExpanded: Bool = false
    @State private var detailAdjustExpanded: Bool = false
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
                    note("No masks yet. A mask is a stack of components combined with "
                         + "add, subtract and intersect, carrying one set of local "
                         + "adjustments through its alpha.")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 18)
        }
        .background(Lumen.panelBackground)
        .foregroundStyle(Lumen.primaryText)
    }

    // MARK: - Mask list

    private var maskListSection: some View {
        let list = masks
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                LumenSectionHeader(title: "Masks", isExpanded: nil,
                                   isModified: !list.isEmpty)
                kindMenu(label: "Add", systemImage: "plus") { kind in addMask(kind: kind) }
            }

            ForEach(Array(list.indices), id: \.self) { index in
                maskRow(list[index], index: index)
            }

            if let mask = activeMask {
                LumenSlider(title: "Amount",
                            value: maskValue(mask.id, "mask.amount",
                                             get: { $0.amount },
                                             set: { $0.amount = Num.clamp($1, 0, 200) }),
                            range: 0...200, defaultValue: 100, step: 1, decimals: 0,
                            bipolar: true)

                HStack(spacing: 4) {
                    smallButton("Duplicate", "plus.square.on.square") { duplicateMask(mask.id) }
                    smallButton("Delete", "trash") { deleteMask(mask.id) }
                    Spacer(minLength: 0)
                }
                .frame(height: Lumen.rowHeight)

                note("Amount scales the adjustment deltas, not the alpha: past 100 it "
                     + "amplifies beyond the slider maxima instead of clipping a mask "
                     + "that is already fully opaque.")
            }
        }
    }

    private func maskRow(_ mask: Mask, index: Int) -> some View {
        let isSelected = mask.id == activeMask?.id
        let isSolo = state.soloMaskOverlay == mask.id
        return HStack(spacing: 5) {
            Button {
                editMask(mask.id, key: nil) { $0.enabled.toggle() }
            } label: {
                Image(systemName: mask.enabled ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(mask.enabled ? Lumen.primaryText : Lumen.secondaryText)
            }
            .buttonStyle(.plain)
            .help(mask.enabled ? "Stop rendering this mask, keeping it" : "Render this mask again")

            TextField("Mask \(index + 1)",
                      text: maskName(mask.id))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Lumen.primaryText : Lumen.secondaryText)

            LumenBadge(text: "\(mask.components.count)")

            Button {
                state.soloMaskOverlay = isSolo ? nil : mask.id
            } label: {
                Image(systemName: isSolo ? "circle.lefthalf.filled.righthalf.striped.horizontal"
                                         : "circle.lefthalf.filled")
                    .font(.system(size: 10))
                    .foregroundStyle(isSolo ? Lumen.accent : Lumen.secondaryText)
            }
            .buttonStyle(.plain)
            .help("Show this mask's alpha as an overlay on the image")
        }
        .padding(.horizontal, 4)
        .frame(height: Lumen.rowHeight)
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
        let index = activeComponentIndex
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                LumenSectionHeader(title: "Components", isExpanded: $componentsExpanded,
                                   isModified: !mask.components.isEmpty)
                kindMenu(label: "Add", systemImage: "plus") { kind in
                    addComponent(kind: kind, to: mask.id)
                }
            }

            if componentsExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(mask.components.indices), id: \.self) { i in
                        componentRow(mask, i)
                    }
                    if let i = index, mask.components.indices.contains(i) {
                        componentEditor(mask.id, i, mask.components[i])
                    } else {
                        note("This mask has no components yet, so its alpha is empty. "
                             + "Add one — the stack folds add, subtract and intersect "
                             + "in order, starting from nothing.")
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
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: 12)
            Text(MaskPanel.kindName(component.kind))
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Lumen.primaryText : Lumen.secondaryText)
                .lineLimit(1)
            if component.invert {
                LumenBadge(text: "INV")
            }
            Spacer(minLength: 0)
            if component.validationError() != nil {
                LumenBadge(text: "INCOMPLETE", emphasized: true)
            }
            Button {
                removeComponent(mask.id, index)
            } label: {
                Image(systemName: "minus.circle").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Lumen.secondaryText)
            .help("Remove this component")
        }
        .padding(.horizontal, 4)
        .frame(height: Lumen.rowHeight)
        .background(isSelected ? Lumen.fillColor.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .contentShape(Rectangle())
        .onTapGesture { selectedComponent = index }
    }

    private func componentEditor(_ maskID: String, _ index: Int,
                                 _ component: MaskComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSegmented(options: [(value: MaskOp.add, label: "Add"),
                                     (value: MaskOp.subtract, label: "Subtract"),
                                     (value: MaskOp.intersect, label: "Intersect")],
                           selection: opBinding(maskID, index))
                .padding(.vertical, 2)

            LumenToggleRow(title: "Invert",
                           isOn: Binding(
                            get: { self.component(maskID, index)?.invert ?? false },
                            set: { on in editComponent(maskID, index, key: nil) { $0.invert = on } }),
                           help: "Inverts this component before it folds into the stack")

            LumenSlider(title: "Amount",
                        value: componentValue(maskID, index, "amount", 100,
                                              get: { $0.amount },
                                              set: { $0.amount = Num.clamp($1, 0, 100) }),
                        range: 0...100, defaultValue: 100, step: 1, decimals: 0,
                        bipolar: false)

            componentParameters(maskID, index, component)

            if let problem = component.validationError() {
                note(problem + " — it renders empty until that is supplied.")
            }
        }
        .padding(.leading, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func componentParameters(_ maskID: String, _ index: Int,
                                     _ component: MaskComponent) -> some View {
        switch component.kind {
        case .brush:
            brushParameters(component)
        case .linear:
            placementNote("Drag on the image to set the gradient line. The span between "
                          + "the two ends is the feather; there is no separate control.",
                          detail: MaskPanel.lineSummary(component.line))
        case .similarityLine:
            VStack(alignment: .leading, spacing: 2) {
                placementNote("Drag on the image to set the ramp.",
                              detail: MaskPanel.lineSummary(component.line))
                similarityParameters(maskID, index, component)
            }
        case .radial:
            radialParameters(maskID, index, component)
        case .lumaRange:
            lumaParameters(maskID, index)
        case .colorRange:
            colourRangeParameters(maskID, index, component)
        case .similarity:
            similarityParameters(maskID, index, component)
        case .depthRange:
            depthParameters(maskID, index)
        case .aiPerson:
            checkboxList(maskID, index, MaskPanel.personParts, isParts: true,
                         caption: "Parts are synthesised from the person matte; a part "
                                + "with low confidence is flagged on its row once the "
                                + "model has run.")
        case .aiLandscape:
            checkboxList(maskID, index, MaskPanel.landscapeClasses, isParts: false,
                         caption: "Six classes, deliberately: snow is a luminance range "
                                + "intersected with this mask, not a seventh class.")
        case .aiObject:
            objectParameters(maskID, index, component)
        case .aiSubject, .aiSky, .aiBackground:
            modelNote(component)
        }
    }

    private func brushParameters(_ component: MaskComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSlider(title: "Size", value: brushBinding(\.size),
                        range: 0.002...0.5, defaultValue: BrushStroke.defaultSize,
                        step: 0.002, decimals: 3, bipolar: false)
            LumenSlider(title: "Feather", value: brushBinding(\.feather),
                        range: 0...100, defaultValue: 50, step: 1, decimals: 0, bipolar: false)
            LumenSlider(title: "Flow", value: brushBinding(\.flow),
                        range: 1...100, defaultValue: 100, step: 1, decimals: 0, bipolar: false)
            LumenSlider(title: "Density", value: brushBinding(\.density),
                        range: 0...100, defaultValue: 100, step: 1, decimals: 0, bipolar: false)
            LumenToggleRow(title: "Eraser", isOn: brushFlag(\.erase),
                           help: "Erase strokes fold into the same buffer in draw order")
            LumenToggleRow(title: "Automask", isOn: brushFlag(\.automask),
                           help: "Gates each stamp by colour similarity to the stamp centre")
            note("These are the settings the NEXT stroke records. Size is a fraction of "
                 + "the source long edge, so a stroke keeps its width at export "
                 + "resolution. Strokes live in "
                 + (component.strokesRef.map { String($0.prefix(20)) + "…" } ?? "no blob yet")
                 + ".")
        }
    }

    private func radialParameters(_ maskID: String, _ index: Int,
                                  _ component: MaskComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSlider(title: "Feather",
                        value: componentValue(maskID, index, "feather", 50,
                                              get: { $0.feather ?? 50 },
                                              set: { $0.feather = Num.clamp($1, 0, 100) }),
                        range: 0...100, defaultValue: 50, step: 1, decimals: 0, bipolar: false)
            LumenSlider(title: "Rotation",
                        value: componentValue(maskID, index, "rotation", 0,
                                              get: { $0.rotation ?? 0 },
                                              set: { $0.rotation = Num.clamp($1, -180, 180) }),
                        range: -180...180, defaultValue: 0, step: 1, decimals: 0)
            placementNote("Drag on the image to place and resize the ellipse; the falloff "
                          + "runs inward from its edge.",
                          detail: MaskPanel.ellipseSummary(component))
        }
    }

    private func lumaParameters(_ maskID: String, _ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSlider(title: "Band Lo",
                        value: componentValue(maskID, index, "lo", MaskPanel.evMin,
                                              get: { MaskPanel.ev($0.lo ?? 0) },
                                              set: { c, v in
                                                  let n = MaskPanel.normalizedEV(v)
                                                  c.lo = Swift.min(n, c.hi ?? 1)
                                              }),
                        range: MaskPanel.evMin...MaskPanel.evMax, defaultValue: MaskPanel.evMin,
                        step: 0.1, decimals: 1, bipolar: false)
            LumenSlider(title: "Band Hi",
                        value: componentValue(maskID, index, "hi", MaskPanel.evMax,
                                              get: { MaskPanel.ev($0.hi ?? 1) },
                                              set: { c, v in
                                                  let n = MaskPanel.normalizedEV(v)
                                                  c.hi = Swift.max(n, c.lo ?? 0)
                                              }),
                        range: MaskPanel.evMin...MaskPanel.evMax, defaultValue: MaskPanel.evMax,
                        step: 0.1, decimals: 1, bipolar: false)
            LumenSlider(title: "Smoothness",
                        value: componentValue(maskID, index, "smooth", 50,
                                              get: { $0.smooth ?? 50 },
                                              set: { $0.smooth = Num.clamp($1, 0, 100) }),
                        range: 0...100, defaultValue: 50, step: 1, decimals: 0, bipolar: false)
            note("The band is denominated in EV on a fixed −10…+4 axis over the "
                 + "scene-referred luminance, never auto-ranged per photo, so the same "
                 + "band means the same thing on every frame.")
        }
    }

    private func depthParameters(_ maskID: String, _ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSlider(title: "Near",
                        value: componentValue(maskID, index, "depthLo", 0,
                                              get: { $0.depthLo ?? 0 },
                                              set: { c, v in
                                                  c.depthLo = Swift.min(Num.saturate(v), c.depthHi ?? 1)
                                              }),
                        range: 0...1, defaultValue: 0, step: 0.01, decimals: 2, bipolar: false)
            LumenSlider(title: "Far",
                        value: componentValue(maskID, index, "depthHi", 1,
                                              get: { $0.depthHi ?? 1 },
                                              set: { c, v in
                                                  c.depthHi = Swift.max(Num.saturate(v), c.depthLo ?? 0)
                                              }),
                        range: 0...1, defaultValue: 1, step: 0.01, decimals: 2, bipolar: false)
            LumenSlider(title: "Smoothness",
                        value: componentValue(maskID, index, "smooth", 50,
                                              get: { $0.smooth ?? 50 },
                                              set: { $0.smooth = Num.clamp($1, 0, 100) }),
                        range: 0...100, defaultValue: 50, step: 1, decimals: 0, bipolar: false)
            note("Relative depth, near = 0. Embedded depth is used when the file carries "
                 + "it; otherwise the depth map is estimated in the background.")
        }
    }

    private func colourRangeParameters(_ maskID: String, _ index: Int,
                                       _ component: MaskComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sampleChips(maskID, index, component)
            LumenSlider(title: "Refine",
                        value: componentValue(maskID, index, "rangeAmount", 50,
                                              get: { $0.rangeAmount ?? 50 },
                                              set: { $0.rangeAmount = Num.clamp($1, 0, 100) }),
                        range: 0...100, defaultValue: 50, step: 1, decimals: 0, bipolar: false)
            note("Refine drives the hue, chroma and lightness tolerances together. The "
                 + "per-axis split is a format addition that has not landed, so it is "
                 + "not shown rather than faked.")
        }
    }

    private func similarityParameters(_ maskID: String, _ index: Int,
                                      _ component: MaskComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sampleChips(maskID, index, component)
            LumenSlider(title: "Chroma sel.",
                        value: componentValue(maskID, index, "chromaSel", 50,
                                              get: { $0.chromaSel ?? 50 },
                                              set: { $0.chromaSel = Num.clamp($1, 0, 100) }),
                        range: 0...100, defaultValue: 50, step: 1, decimals: 0, bipolar: false)
            LumenSlider(title: "Luma sel.",
                        value: componentValue(maskID, index, "lumaSel", 50,
                                              get: { $0.lumaSel ?? 50 },
                                              set: { $0.lumaSel = Num.clamp($1, 0, 100) }),
                        range: 0...100, defaultValue: 50, step: 1, decimals: 0, bipolar: false)
            note("Selectivity is the width of the OKLab similarity gate. Point positions "
                 + "and radius have no field in the shipped format, so this component "
                 + "evaluates its gate over the whole frame for now.")
        }
    }

    private func sampleChips(_ maskID: String, _ index: Int,
                             _ component: MaskComponent) -> some View {
        let samples = component.samples ?? []
        return HStack(spacing: 4) {
            ForEach(Array(samples.indices), id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(MaskPanel.chipColor(samples[i]))
                    .frame(width: 20, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Lumen.separator, lineWidth: 0.5))
            }
            Spacer(minLength: 0)
            Button {
                editComponent(maskID, index, key: nil) { c in
                    var list = c.samples ?? []
                    guard list.count < 8 else { return }
                    list.append([0.18, 0.18, 0.18])
                    c.samples = list
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(samples.count < 8 ? Lumen.primaryText : Lumen.secondaryText)
            .disabled(samples.count >= 8)
            .help("Add a sample (up to 8). The eyedropper lands with the sampler.")

            Button {
                editComponent(maskID, index, key: nil) { c in
                    var list = c.samples ?? []
                    guard list.count > 1 else { return }
                    list.removeLast()
                    c.samples = list
                }
            } label: {
                Image(systemName: "minus").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(samples.count > 1 ? Lumen.primaryText : Lumen.secondaryText)
            .disabled(samples.count <= 1)
            .help("Remove the last sample")
        }
        .frame(height: Lumen.rowHeight)
    }

    private func objectParameters(_ maskID: String, _ index: Int,
                                  _ component: MaskComponent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(component.prompt?.count ?? 0) prompt point(s)")
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.secondaryText)
                Spacer(minLength: 0)
                smallButton("Reset", "arrow.uturn.backward") {
                    editComponent(maskID, index, key: nil) { $0.prompt = nil }
                }
            }
            .frame(height: Lumen.rowHeight)
            modelNote(component)
        }
    }

    private func checkboxList(_ maskID: String, _ index: Int,
                              _ entries: [(key: String, label: String)],
                              isParts: Bool, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.indices), id: \.self) { i in
                LumenToggleRow(title: entries[i].label,
                               isOn: listBinding(maskID, index, entries[i].key, isParts: isParts))
            }
            note(caption)
        }
    }

    private func modelNote(_ component: MaskComponent) -> some View {
        HStack(spacing: 6) {
            LumenBadge(text: component.model ?? "MODEL NEEDED",
                       emphasized: component.model == nil)
            Text(component.model == nil
                 ? "Computed in the background once the model is available."
                 : "Cached at generation resolution; the refine chain carries it to full size.")
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Refinement chain

    private func refineSection(_ mask: Mask) -> some View {
        let refine = mask.refine
        let modified = refine != MaskRefine()
        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Refine", isExpanded: $refineExpanded,
                               isModified: modified,
                               onReset: { editMask(mask.id, key: nil) { $0.refine = MaskRefine() } })
            if refineExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    LumenSlider(title: "Refine",
                                value: maskValue(mask.id, "mask.refine",
                                                 get: { $0.refine.feather },
                                                 set: { $0.refine.feather = Num.clamp($1, 0, 100) }),
                                range: 0...100, defaultValue: 0, step: 1, decimals: 0, bipolar: false)
                    LumenSlider(title: "Edge Shift",
                                value: maskValue(mask.id, "mask.edge",
                                                 get: { $0.refine.edge },
                                                 set: { $0.refine.edge = Num.clamp($1, -50, 50) }),
                                range: -50...50, defaultValue: 0, step: 1, decimals: 0)
                    LumenSlider(title: "Feather",
                                value: maskValue(mask.id, "mask.blur",
                                                 get: { $0.refine.blur },
                                                 set: { $0.refine.blur = Num.clamp($1, 0, 100) }),
                                range: 0...100, defaultValue: 0, step: 1, decimals: 0, bipolar: false)
                    LumenSlider(title: "Levels Lo",
                                value: maskValue(mask.id, "mask.levelsLo",
                                                 get: { $0.refine.levelsLo },
                                                 set: { m, v in
                                                     m.refine.levelsLo = Swift.min(Num.clamp(v, 0, 100),
                                                                                   m.refine.levelsHi)
                                                 }),
                                range: 0...100, defaultValue: 0, step: 1, decimals: 0, bipolar: false)
                    LumenSlider(title: "Levels Hi",
                                value: maskValue(mask.id, "mask.levelsHi",
                                                 get: { $0.refine.levelsHi },
                                                 set: { m, v in
                                                     m.refine.levelsHi = Swift.max(Num.clamp(v, 0, 100),
                                                                                   m.refine.levelsLo)
                                                 }),
                                range: 0...100, defaultValue: 100, step: 1, decimals: 0, bipolar: false)
                    LumenSlider(title: "Levels Gamma",
                                value: maskValue(mask.id, "mask.levelsGamma",
                                                 get: { $0.refine.levelsGamma },
                                                 set: { $0.refine.levelsGamma = Num.clamp($1, 0.2, 5) }),
                                range: 0.2...5, defaultValue: 1, step: 0.05, decimals: 2)
                    note("In engine order: an edge-aware snap against the image structure, "
                         + "then a boundary shift, then a Gaussian soften, then the "
                         + "density remap.")
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
            presenceSection(mask)
            detailSection(mask)
        }
    }

    private func lightSection(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Light", isExpanded: $lightExpanded)
            if lightExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    adjustSlider(mask.id, "Exposure", \.exposure, range: -4...4,
                                 step: 0.05, decimals: 2)
                    adjustSlider(mask.id, "Contrast", \.contrast, range: -100...100)
                    adjustSlider(mask.id, "Highlights", \.highlights, range: -100...100)
                    adjustSlider(mask.id, "Shadows", \.shadows, range: -100...100)
                    adjustSlider(mask.id, "Whites", \.whites, range: -100...100)
                    adjustSlider(mask.id, "Blacks", \.blacks, range: -100...100)
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
                    adjustSlider(mask.id, "Temp", \.temp, range: -100...100)
                    adjustSlider(mask.id, "Tint", \.tint, range: -100...100)
                    adjustSlider(mask.id, "Hue", \.hue, range: -180...180)
                    adjustSlider(mask.id, "Saturation", \.sat, range: -100...100)
                    adjustSlider(mask.id, "Vibrance", \.vibrance, range: -100...100)
                    LumenToggleRow(title: "Colour tint",
                                   isOn: Binding(
                                    get: { hasTint },
                                    set: { on in
                                        editMask(mask.id, key: nil) {
                                            $0.adjust.colorTint = on ? [0.5, 0.5, 0.5] : nil
                                        }
                                    }),
                                   help: "Colorize the masked area; the swatch is set by "
                                       + "the eyedropper")
                    if hasTint {
                        adjustSlider(mask.id, "Tint strength", \.colorTintStrength,
                                     range: 0...100, bipolar: false)
                    }
                }
            }
        }
    }

    private func curveSection(_ mask: Mask) -> some View {
        let curve = mask.adjust.curve
        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Curve", isExpanded: $curveExpanded,
                               isModified: curve != nil,
                               onReset: { editMask(mask.id, key: nil) { $0.adjust.curve = nil } })
            if curveExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    LumenToggleRow(title: "Local tone curve",
                                   isOn: Binding(
                                    get: { curve != nil },
                                    set: { on in
                                        editMask(mask.id, key: nil) {
                                            $0.adjust.curve = on ? CurveSet() : nil
                                        }
                                    }),
                                   help: "A tone curve that runs only inside this mask")
                    if curve != nil {
                        curveRows(mask.id)
                    } else {
                        note("A curve per mask — the tool Lightroom still does not put "
                             + "inside a local adjustment. It taps after the display "
                             + "transform, so it behaves like the global curve.")
                    }
                }
            }
        }
    }

    private func curveRows(_ maskID: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            curveSlider(maskID, "Highlights", \.highlights)
            curveSlider(maskID, "Lights", \.lights)
            curveSlider(maskID, "Darks", \.darks)
            curveSlider(maskID, "Shadows", \.shadows)
            LumenToggleRow(title: "Preserve luminance",
                           isOn: Binding(
                            get: { mask(maskID)?.adjust.curve?.preserveLuminance ?? true },
                            set: { on in
                                editMask(maskID, key: nil) { m in
                                    var c = m.adjust.curve ?? CurveSet()
                                    c.preserveLuminance = on
                                    m.adjust.curve = c
                                }
                            }),
                           help: "Chroma is held while the curve moves luminance")
            note("Point nodes are edited on the curve panel's editor; the four "
                 + "parametric regions and the channel curves are stored per mask.")
        }
    }

    private func wheelsSection(_ mask: Mask) -> some View {
        let wheels = mask.adjust.wheels
        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Grading", isExpanded: $wheelsExpanded,
                               isModified: wheels != nil,
                               onReset: { editMask(mask.id, key: nil) { $0.adjust.wheels = nil } })
            if wheelsExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    LumenToggleRow(title: "Local grading wheels",
                                   isOn: Binding(
                                    get: { wheels != nil },
                                    set: { on in
                                        editMask(mask.id, key: nil) {
                                            $0.adjust.wheels = on ? GradingWheels() : nil
                                        }
                                    }),
                                   help: "Three-way wheels plus Global, inside the mask")
                    if wheels != nil {
                        wheelRows(mask.id)
                    } else {
                        note("Grading wheels inside a mask — the second thing Lightroom "
                             + "does not have locally. They run in the same colour space "
                             + "as the global grade and inherit its zone pivots.")
                    }
                }
            }
        }
    }

    private func wheelRows(_ maskID: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                wheel(maskID, "Shadows", \.shadows, "shadows")
                wheel(maskID, "Midtones", \.mid, "mid")
            }
            HStack(spacing: 8) {
                wheel(maskID, "Highlights", \.high, "high")
                wheel(maskID, "Global", \.global, "global")
            }
            LumenSlider(title: "Blending",
                        value: wheelsValue(maskID, "blending", 50,
                                           get: { $0.blending },
                                           set: { $0.blending = Num.clamp($1, 0, 100) }),
                        range: 0...100, defaultValue: 50, step: 1, decimals: 0, bipolar: false)
            LumenSlider(title: "Balance",
                        value: wheelsValue(maskID, "balance", 0,
                                           get: { $0.balance },
                                           set: { $0.balance = Num.clamp($1, -100, 100) }),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
        }
    }

    private func wheel(_ maskID: String, _ title: String,
                       _ path: WritableKeyPath<GradingWheels, Wheel>,
                       _ key: String) -> some View {
        LumenColorWheel(title: title,
                        hue: wheelValue(maskID, path, \.hue, key + ".hue", 0),
                        sat: wheelValue(maskID, path, \.sat, key + ".sat", 0),
                        lum: wheelValue(maskID, path, \.lum, key + ".lum", 0))
    }

    private func pointColourSection(_ mask: Mask) -> some View {
        let swatches = mask.adjust.pointColors
        let index: Int? = swatches.isEmpty ? nil : Swift.min(Swift.max(selectedSwatch, 0),
                                                             swatches.count - 1)
        return VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Point Colour", isExpanded: $pointExpanded,
                               isModified: !swatches.isEmpty,
                               onReset: { editMask(mask.id, key: nil) { $0.adjust.pointColors = [] } })
            if pointExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        ForEach(Array(swatches.indices), id: \.self) { i in
                            Button {
                                selectedSwatch = i
                            } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(MaskPanel.chipColor(swatches[i].sample))
                                    .frame(width: 20, height: 14)
                                    .overlay(RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(i == index ? Lumen.primaryText : Lumen.separator,
                                                      lineWidth: i == index ? 1.5 : 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                        smallButton("Add", "plus") { addSwatch(mask.id) }
                        smallButton("Remove", "minus") { removeSwatch(mask.id) }
                    }
                    .frame(height: Lumen.rowHeight)

                    if let i = index {
                        pointColourRows(mask.id, i)
                    } else {
                        note("Up to eight swatches per mask, each shifting one colour "
                             + "without touching its neighbours on the hue circle.")
                    }
                }
            }
        }
    }

    private func pointColourRows(_ maskID: String, _ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSlider(title: "Hue", value: swatchValue(maskID, i, "h", -60, 60,
                                                         get: { $0.shift.h },
                                                         set: { $0.shift.h = $1 }),
                        range: -60...60, defaultValue: 0, step: 1, decimals: 0)
            LumenSlider(title: "Saturation", value: swatchValue(maskID, i, "s", -100, 100,
                                                                get: { $0.shift.s },
                                                                set: { $0.shift.s = $1 }),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
            LumenSlider(title: "Luminance", value: swatchValue(maskID, i, "l", -100, 100,
                                                               get: { $0.shift.l },
                                                               set: { $0.shift.l = $1 }),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
            LumenSlider(title: "Range", value: swatchValue(maskID, i, "range", 0, 100,
                                                           get: { $0.range },
                                                           set: { $0.range = $1 }),
                        range: 0...100, defaultValue: 50, step: 1, decimals: 0, bipolar: false)
            LumenSlider(title: "Variance", value: swatchValue(maskID, i, "variance", -100, 100,
                                                              get: { $0.variance },
                                                              set: { $0.variance = $1 }),
                        range: -100...100, defaultValue: 0, step: 1, decimals: 0)
        }
    }

    private func presenceSection(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Presence", isExpanded: $presenceExpanded)
            if presenceExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    adjustSlider(mask.id, "Texture", \.texture, range: -100...100)
                    adjustSlider(mask.id, "Clarity", \.clarity, range: -100...100)
                    adjustSlider(mask.id, "Dehaze", \.dehaze, range: -100...100)
                    adjustSlider(mask.id, "Grain", \.grainAmount, range: 0...100, bipolar: false)
                    note("Texture, Clarity and Dehaze reuse the global base–detail "
                         + "decomposition: sixteen masked clarity moves cost roughly one.")
                }
            }
        }
    }

    private func detailSection(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Detail", isExpanded: $detailAdjustExpanded)
            if detailAdjustExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    adjustSlider(mask.id, "Sharpness", \.sharpness, range: -100...100)
                    adjustSlider(mask.id, "Noise", \.noise, range: 0...100, bipolar: false)
                    adjustSlider(mask.id, "Noise (chroma)", \.noiseChroma, range: 0...100,
                                 bipolar: false)
                    adjustSlider(mask.id, "Moiré", \.moire, range: 0...100, bipolar: false)
                    adjustSlider(mask.id, "Defringe", \.defringe, range: 0...100, bipolar: false)
                    note("Local noise reduction is the classical tier; the AI denoise "
                         + "splice is global by design.")
                }
            }
        }
    }

    // MARK: - Mask and component mutation

    private func addMask(kind: MaskKind) {
        let component = MaskPanel.makeComponent(kind: kind, op: .add)
        var mask = Mask(name: "\(MaskPanel.kindName(kind)) \(masks.count + 1)",
                        components: [component])
        // The AI kinds ship with Refine at 10: an upsampled 1024 px matte needs the
        // edge-aware snap to hold at 100% zoom, and a drawn shape does not.
        if MaskPanel.aiKinds.contains(kind) { mask.refine.feather = 10 }
        let id = mask.id
        state.updateRecipe(coalescingKey: nil) { $0.masks.append(mask) }
        selectedMaskID = id
        selectedComponent = 0
    }

    private func addComponent(kind: MaskKind, to maskID: String) {
        let component = MaskPanel.makeComponent(kind: kind, op: .add)
        editMask(maskID, key: nil) { mask in
            mask.components.append(component)
            if MaskPanel.aiKinds.contains(kind), mask.refine == MaskRefine() {
                mask.refine.feather = 10
            }
        }
        selectedComponent = Swift.max((mask(maskID)?.components.count ?? 1) - 1, 0)
    }

    private func removeComponent(_ maskID: String, _ index: Int) {
        editMask(maskID, key: nil) { mask in
            guard mask.components.indices.contains(index) else { return }
            mask.components.remove(at: index)
        }
        let count = mask(maskID)?.components.count ?? 0
        selectedComponent = Swift.max(Swift.min(index, count - 1), 0)
    }

    private func duplicateMask(_ maskID: String) {
        guard let source = mask(maskID) else { return }
        var copy = source
        copy.id = UUID().uuidString
        copy.name = source.name.isEmpty ? "Copy" : source.name + " copy"
        let id = copy.id
        state.updateRecipe(coalescingKey: nil) { recipe in
            guard let i = recipe.masks.firstIndex(where: { $0.id == maskID }) else {
                recipe.masks.append(copy)
                return
            }
            recipe.masks.insert(copy, at: recipe.masks.index(after: i))
        }
        selectedMaskID = id
    }

    private func deleteMask(_ maskID: String) {
        state.updateRecipe(coalescingKey: nil) { recipe in
            recipe.masks.removeAll { $0.id == maskID }
        }
        if state.soloMaskOverlay == maskID { state.soloMaskOverlay = nil }
        selectedMaskID = masks.first?.id
        selectedComponent = 0
    }

    private func addSwatch(_ maskID: String) {
        editMask(maskID, key: nil) { mask in
            guard mask.adjust.pointColors.count < 8 else { return }
            mask.adjust.pointColors.append(PointColor(sample: [0.18, 0.18, 0.18]))
        }
        selectedSwatch = Swift.max((mask(maskID)?.adjust.pointColors.count ?? 1) - 1, 0)
    }

    private func removeSwatch(_ maskID: String) {
        let target = selectedSwatch
        editMask(maskID, key: nil) { mask in
            guard mask.adjust.pointColors.indices.contains(target) else { return }
            mask.adjust.pointColors.remove(at: target)
        }
        let count = mask(maskID)?.adjust.pointColors.count ?? 0
        selectedSwatch = Swift.max(Swift.min(target, count - 1), 0)
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

    private func component(_ maskID: String, _ index: Int) -> MaskComponent? {
        guard let mask = mask(maskID), mask.components.indices.contains(index) else { return nil }
        return mask.components[index]
    }

    private var activeComponentIndex: Int? {
        guard let mask = activeMask, !mask.components.isEmpty else { return nil }
        return Swift.min(Swift.max(selectedComponent, 0), mask.components.count - 1)
    }

    private func maskName(_ id: String) -> Binding<String> {
        Binding(get: { mask(id)?.name ?? "" },
                set: { v in editMask(id, key: "mask.name.\(id)") { $0.name = v } })
    }

    private func maskValue(_ id: String, _ key: String,
                           get: @escaping (Mask) -> Double,
                           set: @escaping (inout Mask, Double) -> Void) -> Binding<Double> {
        Binding(get: { mask(id).map(get) ?? 0 },
                set: { v in editMask(id, key: "\(key).\(id)") { set(&$0, v) } })
    }

    private func componentValue(_ id: String, _ index: Int, _ key: String, _ fallback: Double,
                                get: @escaping (MaskComponent) -> Double,
                                set: @escaping (inout MaskComponent, Double) -> Void) -> Binding<Double> {
        Binding(get: { component(id, index).map(get) ?? fallback },
                set: { v in
                    editComponent(id, index, key: "mask.component.\(key).\(id).\(index)") {
                        set(&$0, v)
                    }
                })
    }

    private func opBinding(_ id: String, _ index: Int) -> Binding<MaskOp> {
        Binding(get: { component(id, index)?.op ?? .add },
                set: { v in editComponent(id, index, key: nil) { $0.op = v } })
    }

    private func listBinding(_ id: String, _ index: Int, _ key: String,
                             isParts: Bool) -> Binding<Bool> {
        Binding(
            get: {
                let c = component(id, index)
                let list = isParts ? c?.personParts : c?.classes
                return list?.contains(key) ?? false
            },
            set: { on in
                editComponent(id, index, key: nil) { c in
                    var list = (isParts ? c.personParts : c.classes) ?? []
                    if on {
                        if !list.contains(key) { list.append(key) }
                    } else {
                        list.removeAll { $0 == key }
                    }
                    let stored: [String]? = list.isEmpty ? nil : list
                    if isParts { c.personParts = stored } else { c.classes = stored }
                }
            })
    }

    private func adjustSlider(_ id: String, _ title: String,
                              _ path: WritableKeyPath<LocalAdjust, Double>,
                              range: ClosedRange<Double>, step: Double = 1,
                              decimals: Int = 0, bipolar: Bool = true) -> some View {
        LumenSlider(title: title,
                    value: Binding(
                        get: { mask(id)?.adjust[keyPath: path] ?? 0 },
                        set: { v in
                            editMask(id, key: "mask.adjust.\(title).\(id)") {
                                $0.adjust[keyPath: path] = Num.clamp(v, range.lowerBound,
                                                                     range.upperBound)
                            }
                        }),
                    range: range, defaultValue: 0, step: step, decimals: decimals,
                    bipolar: bipolar)
    }

    private func curveSlider(_ id: String, _ title: String,
                             _ path: WritableKeyPath<ParametricCurve, Double>) -> some View {
        LumenSlider(title: title,
                    value: Binding(
                        get: { mask(id)?.adjust.curve?.parametric[keyPath: path] ?? 0 },
                        set: { v in
                            editMask(id, key: "mask.curve.\(title).\(id)") { m in
                                var c = m.adjust.curve ?? CurveSet()
                                c.parametric[keyPath: path] = Num.clamp(v, -100, 100)
                                m.adjust.curve = c
                            }
                        }),
                    range: -100...100, defaultValue: 0, step: 1, decimals: 0)
    }

    private func wheelsValue(_ id: String, _ key: String, _ fallback: Double,
                             get: @escaping (GradingWheels) -> Double,
                             set: @escaping (inout GradingWheels, Double) -> Void) -> Binding<Double> {
        Binding(
            get: { mask(id)?.adjust.wheels.map(get) ?? fallback },
            set: { v in
                editMask(id, key: "mask.wheels.\(key).\(id)") { m in
                    var w = m.adjust.wheels ?? GradingWheels()
                    set(&w, v)
                    m.adjust.wheels = w
                }
            })
    }

    private func wheelValue(_ id: String, _ path: WritableKeyPath<GradingWheels, Wheel>,
                            _ field: WritableKeyPath<Wheel, Double>,
                            _ key: String, _ fallback: Double) -> Binding<Double> {
        Binding(
            get: { mask(id)?.adjust.wheels?[keyPath: path][keyPath: field] ?? fallback },
            set: { v in
                editMask(id, key: "mask.wheel.\(key).\(id)") { m in
                    var w = m.adjust.wheels ?? GradingWheels()
                    w[keyPath: path][keyPath: field] = v
                    m.adjust.wheels = w
                }
            })
    }

    private func swatchValue(_ id: String, _ index: Int, _ key: String,
                             _ lo: Double, _ hi: Double,
                             get: @escaping (PointColor) -> Double,
                             set: @escaping (inout PointColor, Double) -> Void) -> Binding<Double> {
        Binding(
            get: {
                guard let list = mask(id)?.adjust.pointColors,
                      list.indices.contains(index) else { return 0 }
                return get(list[index])
            },
            set: { v in
                editMask(id, key: "mask.point.\(key).\(id).\(index)") { m in
                    guard m.adjust.pointColors.indices.contains(index) else { return }
                    set(&m.adjust.pointColors[index], Num.clamp(v, lo, hi))
                }
            })
    }

    private func brushBinding(_ path: ReferenceWritableKeyPath<MaskBrushStore, Double>) -> Binding<Double> {
        Binding(get: { MaskBrushStore.shared[keyPath: path] },
                set: { v in MaskBrushStore.shared[keyPath: path] = v })
    }

    private func brushFlag(_ path: ReferenceWritableKeyPath<MaskBrushStore, Bool>) -> Binding<Bool> {
        Binding(get: { MaskBrushStore.shared[keyPath: path] },
                set: { v in MaskBrushStore.shared[keyPath: path] = v })
    }

    // MARK: - Small views

    private func kindMenu(label: String, systemImage: String,
                          action: @escaping (MaskKind) -> Void) -> some View {
        Menu {
            Section("Drawn") {
                ForEach(MaskPanel.drawnKinds, id: \.self) { kind in
                    Button(MaskPanel.kindName(kind)) { action(kind) }
                }
            }
            Section("Range") {
                ForEach(MaskPanel.rangeKinds, id: \.self) { kind in
                    Button(MaskPanel.kindName(kind)) { action(kind) }
                }
            }
            Section("AI — requires a model") {
                ForEach(MaskPanel.aiKinds, id: \.self) { kind in
                    Button("\(MaskPanel.kindName(kind))  ·  model") { action(kind) }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                Text(label).font(.system(size: 10))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Every component type. The AI kinds run a model in the background and "
              + "land as a cached matte.")
    }

    private func smallButton(_ title: String, _ systemImage: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 9))
                Text(title).font(.system(size: 10))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Lumen.primaryText)
    }

    private func placementNote(_ text: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            note(text)
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Lumen.secondaryText)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Lumen.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
    }

    // MARK: - Static tables

    static let evMin: Double = -10
    static let evMax: Double = 4

    static func ev(_ normalized: Double) -> Double {
        evMin + Num.saturate(normalized) * (evMax - evMin)
    }

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

    /// The nine person parts and six landscape classes, exactly as the spec fixes them.
    static let personParts: [(key: String, label: String)] = [
        ("faceSkin", "Face Skin"), ("bodySkin", "Body Skin"), ("eyebrows", "Eyebrows"),
        ("eyeSclera", "Eye Sclera"), ("irisPupil", "Iris & Pupil"), ("lips", "Lips"),
        ("teeth", "Teeth"), ("hair", "Hair"), ("clothes", "Clothes"),
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
        case .similarity:
            c.samples = [[0.18, 0.18, 0.18]]
            c.chromaSel = 50
            c.lumaSel = 50
        case .similarityLine:
            c.samples = [[0.18, 0.18, 0.18]]
            c.chromaSel = 50
            c.lumaSel = 50
            c.line = [0.5, 0.75, 0.5, 0.25]
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

    static func lineSummary(_ line: [Double]?) -> String {
        guard let line, line.count == 4 else { return "no line yet" }
        return String(format: "(%.3f, %.3f) → (%.3f, %.3f)", line[0], line[1], line[2], line[3])
    }

    static func ellipseSummary(_ c: MaskComponent) -> String {
        guard let center = c.center, center.count == 2,
              let radii = c.radii, radii.count == 2 else { return "no ellipse yet" }
        return String(format: "centre (%.3f, %.3f)  radii (%.3f, %.3f)",
                      center[0], center[1], radii[0], radii[1])
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

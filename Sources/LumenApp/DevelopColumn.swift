// DevelopColumn.swift
// The develop column's arrangement: four workspaces where eight icon tabs used to be,
// and an accordion of sections inside each one.
//
// docs/28 Phase 4 items 13 and 15, and the owner's own words are the specification:
// "the tabs and menus can be a bit better and maybe be put into less ... maybe make it
// into collapsible tabs like lightroom has it because I think the tabs is great but I
// think we can make it into maybe 3-4 tabs not the 6ish we have now."
//
// WHY WORKSPACES ARE WORDS AND TABS WERE ICONS. Eight `Image(systemName:)`s with the
// title hidden in a tooltip is a row a photographer has to learn by position, and the
// owner said he did not: "I genuinely don't get some of it." Four fit in 320 points as
// text with room to spare, and a name that is legible without hovering is the whole
// reason four is better than eight.
//
// The arrangement itself is `WorkspaceLayout` in LumenCore — which workspace, which
// sections are open, which register — and the rules that move it (`SectionExpansion`,
// the register's visibility) are there too, with tests. `PanelLayout` is the observable
// that holds it. Nothing in this file decides what a click MEANS; it decides what a
// click looks like.

#if os(macOS)
import LumenCore
import SwiftUI

// MARK: - The workspace switcher

struct WorkspaceSwitcher: View {
    @ObservedObject var panel: PanelLayout

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Workspace.allCases, id: \.self) { workspace in
                let isCurrent = panel.layout.workspace == workspace
                Button {
                    panel.select(workspace)
                } label: {
                    Text(workspace.title)
                        .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isCurrent ? Lumen.fillColor.opacity(0.30) : Color.clear)
                        .foregroundStyle(isCurrent ? Lumen.primaryText : Lumen.secondaryText)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The chord, in the tooltip, because a switcher that teaches its own
                // shortcut is how a photographer stops using the switcher.
                .help("\(workspace.title) (⌘\(workspace.shortcutDigit))")
            }
            // THE DOCK NEEDS A DOOR THAT IS NOT A KEY.
            //
            // `M` toggles it and the dock's own header closes it, but a surface whose
            // only way in is a keystroke is half-built — it is exactly the "I genuinely
            // don't get some of it" the tab strip earned. Set apart by a divider and
            // drawn as an icon rather than a word, so four words plus one glyph cannot
            // be misread as five workspaces.
            Divider()
                .frame(height: 14)
                .overlay(Lumen.separator)
                .padding(.horizontal, 4)
            Button {
                panel.setMaskDock(open: !panel.layout.isMaskDockOpen)
            } label: {
                Image(systemName: "theatermasks")
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(panel.layout.isMaskDockOpen
                                ? Lumen.fillColor.opacity(0.30) : Color.clear)
                    .foregroundStyle(panel.layout.isMaskDockOpen
                                     ? Lumen.primaryText : Lumen.secondaryText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Masks (M) — available in every workspace")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

extension Workspace {

    /// The switcher's label. Deliberately not `rawValue`: the raw value is a
    /// persistence key (`PanelLayout`), and a key that doubles as a caption is a key
    /// that cannot be renamed without moving a photographer's stored panel state.
    var title: String {
        switch self {
        case .cull: return "Cull"
        case .develop: return "Develop"
        case .grade: return "Grade"
        case .deliver: return "Deliver"
        }
    }

    /// ⌘1–⌘4, in declaration order. The owner chose the modifier so that bare `1`–`5`
    /// stay star ratings and culling keeps its Lightroom muscle memory (docs/29 §2.1).
    var shortcutDigit: String {
        String((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }
}

// MARK: - The accordion

/// One workspace's sections, each collapsible, solo by default.
///
/// `layout.visibleSections` already answers "which sections, in which order, under this
/// register" — this walks that list and nothing else, so a section can never appear here
/// that the model does not think is visible, and the canonical order is the model's.
struct WorkspaceSections: View {
    @ObservedObject var panel: PanelLayout
    /// Which sections carry a non-default value, for the header dot and for the
    /// hidden-active indicator. Derived from the recipe by the caller, because the
    /// LumenCore model deliberately does not know how to read a recipe.
    let nonDefault: Set<WorkspaceSection>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(panel.layout.visibleSections, id: \.self) { section in
                WorkspaceSectionView(
                    section: section,
                    isExpanded: panel.layout.expanded.contains(section),
                    isModified: nonDefault.contains(section),
                    onToggle: { keepingOthersOpen in
                        panel.click(section, keepingOthersOpen: keepingOthersOpen)
                    })
            }
            hiddenIndicator
        }
    }

    /// "3 more sections have adjustments" — the Simple register's honesty clause.
    ///
    /// A register that hides a section does NOT revert it (that is `DisclosureRegister`'s
    /// stated contract), so Simple can be concealing live adjustments. Without this line
    /// a photographer in Simple sees a picture that does not match the controls in front
    /// of them and has no way to find out why, which is worse than the eight tabs this
    /// replaces. It is only ever drawn when there is something to disclose.
    @ViewBuilder
    private var hiddenIndicator: some View {
        if let text = panel.layout.hiddenActiveIndicator(nonDefault: nonDefault) {
            Button {
                panel.toggleRegister()
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(Lumen.accent).frame(width: 5, height: 5)
                    Text(text)
                        .font(.system(size: 10))
                        .foregroundStyle(Lumen.secondaryText)
                }
                .padding(.top, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show every section")
        }
    }
}

/// One section: its header, and its rows when it is open.
///
/// The header is the column's rather than the panel's, so that every section in every
/// workspace gets the same chevron, the same 16-point boundary and the same click rule —
/// including the ones assembled out of several panels' pieces, which could not have
/// agreed on it themselves.
private struct WorkspaceSectionView: View {
    let section: WorkspaceSection
    let isExpanded: Bool
    let isModified: Bool
    let onToggle: (Bool) -> Void
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: section.title,
                               isExpanded: .constant(isExpanded),
                               isModified: isModified,
                               onReset: reset,
                               onToggle: onToggle)
            // CLOSED MEANS CLOSED. `DevelopSection` and `DevelopDisclosure` both take
            // their content as a closure now for this reason: a section that collapses
            // but still CONSTRUCTS its rows costs a drag exactly what the accordion
            // claims to save, and Look holds 38 sliders in one of these.
            if isExpanded {
                WorkspaceSectionBody(section: section)
            }
        }
    }

    /// RESET BELONGS TO THE SECTION HEADER NOW, and the section is the column's idea of
    /// one rather than any single panel's.
    ///
    /// It used to belong to whichever `DevelopSection` a panel happened to draw, which
    /// left three holes the accordion would have shipped: a section assembled from
    /// several panels — Optics out of Crop and Lens, Effects out of Vignette, Grain and
    /// Retouch — had no single Reset at all; a section folded into a `DevelopDisclosure`
    /// lost the one it had, which is what happened to Denoise and to Zones; and a panel
    /// that drops its own header under `only:` would have taken its Reset with it.
    ///
    /// The mutation itself is `WorkspaceSection.reset` in LumenCore, where a property
    /// test asserts the thing that actually matters: reset a section and its dot must go
    /// out, and no other section's may. Two hand-written closures would not have stayed
    /// true to each other for a month.
    private var reset: (() -> Void)? {
        // A button that does nothing is the same lie as a caption promising a dead
        // shortcut. Only offer it where there is something to put back.
        guard isModified else { return nil }
        if section == .softProof {
            // The whole struct, not just the toggle: destination space, intent, gamut
            // warning and paper simulation go together, and a reset that only flipped
            // `enabled` would leave a proof configured for a destination nothing names
            // any more. Not in the recipe at all — soft proof is the session's.
            return { state.softProof = SoftProof() }
        }
        guard section.resetsTheRecipe else { return nil }
        return {
            let denoiseStart = denoiseDefault
            state.updateRecipe(coalescingKey: "workspace.\(section.rawValue).reset") {
                recipe in
                section.reset(&recipe)
                // `reset` writes `Denoise()` because LumenCore cannot know the ISO. The
                // photograph's own starting point is the honest default, and it is the
                // one double-clicking a denoise slider already lands on.
                if section == .detail, let denoiseStart {
                    recipe.develop.denoise = denoiseStart
                }
            }
        }
    }

    /// The photograph's own denoise starting point, or nil for a rendered file that has
    /// no ISO profile to start from.
    private var denoiseDefault: Denoise? {
        guard let photo = state.primarySelection,
              !PhotoFormats.isRendered(photo.id),
              let iso = photo.iso else { return nil }
        return ISODefaults.startingDenoise(forISO: Double(iso))
    }
}

/// The one place a section name becomes a view.
///
/// Every panel takes an `only:` naming the section it should render, so the split ones —
/// Effects across three workspaces, Look across three sections — stay single files with
/// their bindings and their reset logic intact, rather than being cut into pieces that
/// would each need their own copy of both.
private struct WorkspaceSectionBody: View {
    let section: WorkspaceSection
    @EnvironmentObject var state: AppState

    var body: some View {
        switch section {
        case .whiteBalance: BasicPanel(only: .whiteBalance)
        case .tone: BasicPanel(only: .tone)
        case .presence: BasicPanel(only: .presence)
        case .curve: CurveEditorView(histogram: state.scopes?.histogram)
        case .detail: DetailPanel(only: .detail)
        case .optics: EffectsPanel(only: .optics)
        case .looks: LookPanel(only: .looks)
        case .color: ColorPanel(only: .color)
        case .grading: LookPanel(only: .grading)
        case .filmLab: LookPanel(only: .filmLab)
        case .effects: EffectsPanel(only: .effects)
        case .softProof: EffectsPanel(only: .softProof)
        case .exportRecipes: ExportRecipesSection()
        }
    }
}

// MARK: - The mask dock

/// Masks, reachable from every workspace instead of being one tab among eight.
///
/// docs/28 item 14, and the reason it is a dock rather than a section is the workflow it
/// was breaking: a mask is a thing you make WHILE grading, and putting it in the tab
/// strip meant leaving whatever you were doing to reach it and leaving it again to see
/// the effect. `WorkspaceLayout.isMaskDockOpen` is therefore not part of the accordion's
/// expanded set — it does not participate in the solo rule, and opening it closes
/// nothing.
///
/// It sits at the TOP of the column, above the workspace's own sections, because while
/// it is open it is what the photographer is working in; the sections underneath are the
/// adjustments that mask is scaling.
struct MaskDock: View {
    @ObservedObject var panel: PanelLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSectionHeader(title: "Masks",
                               isExpanded: .constant(true),
                               isModified: false,
                               onToggle: { _ in panel.setMaskDock(open: false) })
            MaskPanel()
            // A boundary under the dock, because what follows it belongs to a different
            // job — the workspace's own sections — and the accordion's 16 pt rhythm
            // alone would read as one more section rather than as the end of a surface.
            Divider()
                .overlay(Lumen.separator)
                .padding(.top, 10)
        }
    }
}

/// Deliver's second section, and the honest version of it.
///
/// Export recipes exist and are edited, but only inside `ExportSheet` — a modal. There
/// is no panel-shaped view to re-parent here, and inventing a second editor for the same
/// data would be two places for a recipe to be wrong. So the section says what it is and
/// opens the one that exists. Lifting the sheet's editor into the column is its own
/// change, and a larger one than this phase.
private struct ExportRecipesSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DevelopNote("Export recipes are edited in the export sheet.")
            Button("Open Export…") { state.activeSheet = .export }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Lumen.accent)
        }
        .padding(.top, 2)
    }
}
#endif

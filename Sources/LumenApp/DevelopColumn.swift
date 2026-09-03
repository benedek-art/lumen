// DevelopColumn.swift
// The develop column's arrangement: a vertical workspace rail on the window's right
// edge, and an accordion of sections inside each workspace.
//
// docs/28 Phase 4 items 13 and 15, amended by the owner's fourth pass (docs/32): "I'd
// rather have a vertical area on the side of the page like Lightroom has it, the right
// side of the page." The horizontal strip that lived at the top of this column — and
// the `WorkspaceReturnBar` that had to re-draw it over the grid whenever the column was
// not there — are both gone; `WorkspaceRail` is the one home navigation has, and it is
// never off screen.
//
// The arrangement itself is `WorkspaceLayout` in LumenCore — which workspace, which
// sections are open — and the rules that move it (`SectionExpansion`) are there too,
// with tests. `PanelLayout` is the observable that holds it. Nothing in this file
// decides what a click MEANS; it decides what a click looks like.

#if os(macOS)
import LumenCore
import SwiftUI

// MARK: - The workspace rail

/// THE RAIL: five workspaces and the mask door, on the window's right edge, present in
/// every view mode and every workspace.
///
/// Its predecessor was a horizontal strip INSIDE the develop column, and that address
/// was the defect: Cull has no column, so choosing Cull took the tabs away with it —
/// the stranding trap the owner hit within minutes ("I clicked Cull ... the edit area
/// is completely gone", docs/30 §7.7) and that `WorkspaceReturnBar` then patched by
/// re-drawing the strip over the grid, so navigation jumped between two homes as you
/// moved. A rail that belongs to the WINDOW rather than to the column cannot vanish
/// with it, which closes the trap permanently instead of bandaging it.
///
/// ICON OVER WORD, where the strip was words alone — and this is a change of geometry,
/// not a change of heart. The strip's own arithmetic ruled glyphs out: five tabs shared
/// roughly 321 horizontal points, a glyph and its gap did not fit beside "Develop" in a
/// 64-point tab, and the first thing to truncate would have been the selected word. In
/// a 56-point rail the glyph has its own line and costs the word nothing, and the owner
/// asked for "a little bit more visual stuff" by name. The labels stay because eight
/// icon-only tabs with titles in tooltips is the row he could not learn ("I genuinely
/// don't get some of it") — the rail never repeats that.
struct WorkspaceRail: View {
    /// THE SUBSCRIPTION LIVES HERE, in the one small view that needs it, exactly as it
    /// did on `WorkspaceReturnBar`: `ContentView` reads `PanelLayout` without observing
    /// it, so a workspace change invalidates a 56-point rail rather than the window and
    /// the `Scene` behind it.
    @ObservedObject private var panel = PanelLayout.shared
    /// A tab is a DESTINATION, not an arrangement — see `AppState.enter`. The old strip
    /// once called `panel.select` directly, which moved the column and nothing else, so
    /// clicking Cull left you in the loupe and clicking Crop left the crop tool off.
    /// Every click here goes through the entry verbs, and `WorkspaceEntryTests` scans
    /// this file to keep it that way.
    @EnvironmentObject private var state: AppState

    /// Which tab the pointer is over. Row-local, so crossing the rail invalidates the
    /// rail and nothing else — hover state never reaches an `ObservableObject`
    /// (`LumenHoverModifier`, and what `CommandState` cost before it).
    @State private var hovered: Workspace?
    @State private var maskHovered = false

    /// 56: "Develop" at 10 pt is ~40 points, the widest label, and it clears the tab's
    /// sides with room; much past 60 the rail starts reading as a second column.
    static let width: CGFloat = 56

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Workspace.allCases, id: \.self) { workspace in
                railTab(workspace)
            }
            // MASKING NEEDS A DOOR THAT IS NOT A KEY. `M` opens it, but a surface whose
            // only way in is a keystroke is half-built. The divider is what says the
            // door is not a sixth workspace: masking is a takeover you come back from,
            // and the workspace underneath stays lit-adjacent below the line.
            Divider()
                .frame(width: 24)
                .overlay(Lumen.separator)
                .padding(.vertical, 4)
            maskDoor
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.top, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        // The chrome step the switcher band used to sit on, for the same reason: the
        // rail is furniture, and `windowBase` 0.18 beside the viewer's 0.165 canvas is
        // how two regions divide themselves on this ladder without a drawn rule.
        .background(Lumen.windowBase)
        .animation(Lumen.motionState, value: hovered)
        .animation(Lumen.motionState, value: maskHovered)
    }

    private func railTab(_ workspace: Workspace) -> some View {
        // Masking un-lights the five: the column is not showing a workspace while the
        // mask editor has it, and a lit Develop over a mask list would say otherwise.
        // The door below is what wears the selection then.
        let isCurrent = panel.layout.workspace == workspace && !panel.layout.isMasking
        return Button {
            state.enter(workspace)
        } label: {
            railLabel(symbol: workspace.symbolName, title: workspace.title,
                      selected: isCurrent, hovered: hovered == workspace)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = workspace
            } else if hovered == workspace {
                hovered = nil
            }
        }
        .lumenClickCursor()
        // The chord, in the tooltip, because a switcher that teaches its own shortcut
        // is how a photographer stops using the switcher.
        .help("\(workspace.title) (⌘\(workspace.shortcutDigit))")
    }

    /// The door wears the selected fill while masking — the strip this replaces never
    /// could, because it was not on screen once masking had the column. The rail always
    /// is, so the door is also the visible way back: clicking it again is the same
    /// round trip as `M`.
    private var maskDoor: some View {
        let isCurrent = panel.layout.isMasking
        return Button {
            state.toggleMasking()
        } label: {
            railLabel(symbol: "theatermasks", title: "Masks",
                      selected: isCurrent, hovered: maskHovered)
        }
        .buttonStyle(.plain)
        .onHover { maskHovered = $0 }
        .lumenClickCursor()
        .help(isCurrent
              ? "Leave masking and go back to \(panel.layout.workspace.title) (M)"
              : "Masks (M) — the column becomes the mask editor")
    }

    /// One drawing for all six stops, so the door cannot drift from the tabs.
    private func railLabel(symbol: String, title: String,
                           selected: Bool, hovered: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 14))
            // 10 pt is the app-wide type floor (design audit §1.9); medium rather than
            // a size change for the selected word, so the tab does not reflow.
            Text(title)
                .font(.system(size: 10, weight: selected ? .medium : .regular))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(tabFill(selected: selected, hovered: hovered))
        .foregroundStyle(selected ? Lumen.primaryText : Lumen.secondaryText)
        .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusTab, style: .continuous))
        .contentShape(Rectangle())
    }

    /// ONE BACKGROUND, THREE STATES — rest, hover, selected.
    ///
    /// `lumenHoverable()` cannot serve these tabs and it is worth saying why, because
    /// the mistake is invisible until you try it: the modifier paints its fill as a
    /// `.background`, BEHIND the content, and a selected tab already paints an opaque
    /// one. Stacking the two would have given every tab a hover except the one under
    /// the pointer's most likely destination. A colour computed from both states cannot
    /// be occluded by either.
    private func tabFill(selected: Bool, hovered: Bool) -> Color {
        if selected { return Lumen.controlActive }
        if hovered { return Lumen.controlHover }
        return .clear
    }
}

// MARK: - The way back from masking

/// "‹ Develop", at the top of the column while masking has it: the label is the
/// destination, so the photographer knows what they are returning to before they commit
/// to going. `layout.workspace` still holds it — masking never wrote it.
///
/// This survives the strip it used to be half of because it does two jobs the rail
/// cannot: it prints "Masks" where the column's sections used to announce themselves
/// (`MaskPanel` renders headerless on the promise that this bar is the header), and it
/// puts the way out at the top of the surface you are actually working in rather than
/// only on the window's edge.
struct MaskingReturnBar: View {
    @ObservedObject var panel: PanelLayout
    @EnvironmentObject private var state: AppState
    /// This bar shows a mask count and a thumbnail, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject private var edits: EditRevision
    @State private var backHovered = false
    @State private var masksHovered = false

    /// Spelled out rather than left to the memberwise initializer, which the private
    /// hover state would otherwise make inaccessible from DevelopPanel's file — the
    /// `PhotoCell` lesson, and one this machine cannot catch (parse-only for LumenApp).
    init(panel: PanelLayout) {
        self.panel = panel
    }

    private var masks: [Mask] { state.currentRecipe.masks }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                panel.setMasking(false)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.lumenGlyphCaptionStrong)
                    Image(systemName: panel.layout.workspace.symbolName)
                        .font(.lumenGlyphBody)
                    Text(panel.layout.workspace.title)
                        .font(.lumenBody)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(backHovered ? Lumen.controlHover : Color.clear)
                .foregroundStyle(backHovered ? Lumen.primaryText : Lumen.secondaryText)
                .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusTab,
                                            style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { backHovered = $0 }
            .lumenClickCursor()
            .help("Leave masking and go back to \(panel.layout.workspace.title) "
                  + "(Escape, or M)")
            Spacer(minLength: 0)
            masksChip
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .animation(Lumen.motionState, value: backHovered)
        .animation(Lumen.motionState, value: masksHovered)
    }

    /// The word that said where the column was, turned into the switch for the box.
    ///
    /// The Masks panel is a real floating card over the photograph now — the owner asked
    /// for that shape three times, with two screenshots, and got a popover anchored here
    /// instead. This is no longer the door: the box comes out by itself the first time a
    /// photograph has a mask. It is the way back after you close it, and the readout of
    /// how many masks the frame carries.
    private var masksChip: some View {
        Button { state.maskPanelVisible.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: state.maskPanelVisible
                      ? "square.on.square.dashed" : "square.on.square")
                    .font(.lumenBody)
                Text("Masks")
                    .font(.lumenHeading)
                    .foregroundStyle(masksHovered || state.maskPanelVisible
                                     ? Lumen.primaryText : Lumen.secondaryText)
                if !masks.isEmpty {
                    Text("\(masks.count)")
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.tertiaryText)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .foregroundStyle(masksHovered || state.maskPanelVisible
                             ? Lumen.primaryText : Lumen.secondaryText)
            .background(masksHovered ? Lumen.controlHover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusTab, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { masksHovered = $0 }
        .lumenClickCursor()
        .help(state.maskPanelVisible
              ? "Hide the Masks panel"
              : "Show the Masks panel — the list, what each mask is made of, and its edge")
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
        case .crop: return "Crop"
        case .grade: return "Grade"
        case .deliver: return "Deliver"
        }
    }

    /// ⌘1–⌘5, in declaration order. The owner chose the modifier so that bare `1`–`5`
    /// stay star ratings and culling keeps its Lightroom muscle memory (docs/29 §2.1).
    var shortcutDigit: String {
        String((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    /// The workspace's glyph — the rail draws it over each label, and the masking bar
    /// on the way back.
    ///
    /// One table rather than per-surface choices: the rail is not the only surface that
    /// names these five — the View menu lists all of them — and a menu and a rail that
    /// picked their own icons would be two tables to keep in step.
    var symbolName: String {
        switch self {
        // The grid, which is what Cull IS: `sections` is empty for this workspace and
        // the emptiness is the feature, so the glyph names the centre pane rather than
        // a column that is not there.
        case .cull: return "square.grid.2x2"
        // Sliders, because that is what the column becomes. Not a wand or a dial —
        // Develop is the normalising half of the split and its work is numeric.
        case .develop: return "slider.horizontal.3"
        // `crop.rotate` rather than the plain `crop` that `WorkspaceSection.frame`
        // wears. The workspace holds Crop AND Lens, so it is geometry entire, and the
        // two would otherwise be the same glyph one row apart on the same screen.
        case .crop: return "crop.rotate"
        // The interpreting half. A brush, deliberately not a palette: `color` and
        // `looks` already wear the two palettes, and Grade is the act rather than the
        // swatches.
        case .grade: return "paintbrush"
        // Sending, not saving. `square.and.arrow.up` belongs to Export Recipes, which
        // is one section INSIDE this workspace; using it here as well would say the
        // workspace and the section were the same thing.
        case .deliver: return "paperplane"
        }
    }
}

// MARK: - Glyphs

// AN SF SYMBOL PER SECTION, AND WHY THE TABLE LIVES HERE RATHER THAN IN LUMENCORE.
//
// The owner asked for it in his own words: "I'd also love it if we could add visuals a
// little bit more … giving the curves item a curve emoticon, and stuff like that, or
// overall just livening the app up a little bit more." He means SF Symbols; it is also
// docs/30 item 1.6, which wanted "an SF Symbol per section — a point-curve glyph for
// Curve, an aperture for Detail" and, in the same breath, a single home for it "so the
// header and the ⌘K palette read the same one".
//
// This file is that home, and `Workspace.swift` says why it cannot be the enum's: "What
// is deliberately not here … Anything presentational: no symbol names, no widths, no
// colours." A symbol name is the one fact about a section that would have to be thrown
// away if this app were ever drawn by something that is not SwiftUI. `title` is data —
// the header prints it. A glyph is a drawing instruction, so it sits beside the views
// that draw it, next to `Workspace.title` and `shortcutDigit`, which are here for
// exactly this reason.
//
// BOTH SWITCHES ARE EXHAUSTIVE AND NEITHER HAS A `default:`, which is the whole reason
// they are switches rather than dictionaries. A fifteenth section added to LumenCore
// cannot compile until it has answered this, and that matters more than it usually does
// because of how the failure looks: `Image(systemName:)` handed a name macOS does not
// know draws NOTHING AT ALL — no placeholder, no log line, no red. A missing case, a
// `default:` returning "", or one mistyped character all produce the same silent gap in
// the column, and the person who added the section would have no reason to look.
//
// WHICH NAMES ARE SAFE. Package.swift declares `.macOS(.v15)`, so the floor is SF
// Symbols 6 and every name below clears it with room. Most have existed since SF
// Symbols 1; the four that have not — `circle.lefthalf.filled` (3),
// `thermometer.medium`, `swatchpalette` and the curve (all 4) — arrived with macOS 12
// and 13. `camera.aperture` is already drawn in `FilterBar`, which is the one name here
// this codebase has seen render.

extension WorkspaceSection {

    /// The glyph the section header draws, and the same one the ⌘K palette puts beside
    /// the control it is offering to take you to. One table, two surfaces, so a
    /// photographer who learns the mark in the column recognises it in the palette.
    var symbolName: String {
        switch self {
        // Colour temperature, which is exactly what Temp and Tint are. The alternative
        // was a droplet, and a droplet says "water" in a panel that already draws an
        // eyedropper two rows down for the white-balance PICK — one glyph per idea.
        case .whiteBalance: return "thermometer.medium"
        // Light against dark across one shape: the six-slider tone contract in a
        // circle. It is the closest thing SF Symbols has to a contrast control.
        case .tone: return "circle.lefthalf.filled"
        // The section is called Crop and this is called `crop`. Nothing to argue.
        case .frame: return "crop"
        // THE ONE THE OWNER ASKED FOR BY NAME — "giving the curves item a curve
        // emoticon". It is a bezier between two control points, which is not a glyph
        // that merely suggests a curve; it is a picture of the editor underneath it.
        case .curve: return "point.topleft.down.to.point.bottomright.curvepath"
        // Texture, Clarity and Dehaze — the three sliders that make a flat frame read
        // as present. The standard "enhance" glyph, and the only near-collision in this
        // table: `LumenSlider`'s per-row auto button is `wand.and.stars`. They differ
        // in silhouette and never in position — that wand is at the right end of a
        // slider row, this one at the left end of a header.
        case .presence: return "wand.and.rays"
        // Sharpening and denoise, which is work done at the pixel. A dot grid says
        // "the fine structure" without pretending to be a magnifier; the app's one
        // `magnifyingglass` belongs to the filter bar's search.
        case .detail: return "circle.grid.3x3"
        // An aperture for the lens section, which is docs/30 1.6's own example.
        case .optics: return "camera.aperture"
        // A swatch fan: a SET of finished looks to pick from, which is what saved Looks
        // are. Not `photo.stack` — this app has photo stacks, and they are a different
        // thing in the library sidebar.
        case .looks: return "swatchpalette"
        // The mixer, Point Colour and B&W. A painter's palette is mixing, which is the
        // verb of this section, against the swatch fan above it which is choosing.
        case .color: return "paintpalette"
        // Three overlapping filter circles — the shadows/midtones/highlights wheels
        // drawn as the thing they are. Reads as colour grading in every tool that has
        // ever shipped one.
        case .grading: return "camera.filters"
        // A filmstrip, for the section that emulates film.
        case .filmLab: return "film"
        // Vignette, grain and retouch. The generic "effects" glyph, used generically on
        // purpose: these are the adjustments that do not belong to any one discipline.
        case .effects: return "sparkles"
        // A soft proof is a rehearsal of a print, so the glyph is the printer it is
        // rehearsing for.
        case .softProof: return "printer"
        // The share glyph, because export is the file leaving the app. Its workspace
        // wears `paperplane` instead so the two are not one mark twice.
        case .exportRecipes: return "square.and.arrow.up"
        }
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

    /// 8, not 2, and the gap is now doing work rather than merely existing.
    ///
    /// Each section is a card (`WorkspaceSectionView`), so this is the trough between
    /// two of them — the darker `windowBase` the column paints showing through. Below
    /// about 6 the cards read as one banded surface; much above 10 and the column starts
    /// to feel gappy while scrolling.
    /// No footer under the sections any more. The "Show all / Show fewer sections" line
    /// was the retired register's control (docs/32: the owner ruled the register
    /// unnecessary), and with every section always listed there is nothing left for a
    /// hidden-active indicator to be honest about — nothing is hidden.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(panel.layout.visibleSections, id: \.self) { section in
                WorkspaceSectionView(
                    section: section,
                    isExpanded: panel.layout.expanded.contains(section),
                    isModified: nonDefault.contains(section),
                    onToggle: { optionHeld in
                        panel.headerClicked(section, optionHeld: optionHeld)
                    })
            }
            HistorySection()
        }
    }
}

/// THE HISTORY, UNDER THE WORKSPACE'S OWN SECTIONS AND IN EVERY ONE OF THEM.
///
/// It wears `WorkspaceSectionView`'s card, gutter and header so that it reads as one
/// more area in the accordion, and it is deliberately NOT a `WorkspaceSection`. Two
/// reasons, and the second is the one that decided it:
///
///   · A `WorkspaceSection` belongs to exactly one `Workspace` — that is what
///     `visibleSections` walks — and history belongs to none of them. It is the same
///     list whether you are toning, cropping or delivering, and choosing a workspace to
///     file it under would mean the photographer had to remember which.
///   · The enum carries a `title`, a `canonicalRank` from docs/12 §12.1's panel-order
///     table, a `reset(_:)` that mutates a recipe and a `nonDefault` clause that reads
///     one. History has no rank in that table, resets nothing and is not part of a
///     recipe, so three of the four would have had to be answered with a lie.
///
/// LAST IN THE COLUMN, which is where a record of what you did belongs relative to the
/// controls you did it with. It is closed by default for the reason `ContentView` gives
/// about the sidebar's own two closed sections: defaults, not options, set perceived
/// complexity, and a section that is empty until the photograph has been edited is a
/// card of "nothing here yet" on every fresh folder.
private struct HistorySection: View {
    @EnvironmentObject private var state: AppState

    /// `@AppStorage`, exactly as the sidebar's four disclosures do it and for the same
    /// two reasons: it persists for free, and it invalidates this card rather than the
    /// window. It is deliberately not part of `WorkspaceLayout` — that value is the
    /// accordion's arrangement, one `expanded` set keyed by `WorkspaceSection`, and this
    /// is not one of those. The key sits in the column's `develop.` namespace beside
    /// `develop.workspace` and `develop.expanded`.
    @AppStorage("develop.history") private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // No modified dot and no Reset. The dot means "this section carries a
            // non-default value" and history carries none — it is a record, not a
            // setting — and a Reset here would either mean "clear the list", which
            // throws away the one thing the card exists to offer, or "put the
            // photograph back", which is what the bottom row already does and says.
            LumenSectionHeader(title: "History",
                               symbol: "clock.arrow.circlepath",
                               isExpanded: .constant(isExpanded),
                               topRhythm: 0,
                               onToggle: { _ in
                                   // The accordion's own animation lives in
                                   // `PanelLayout.commit`, which this fold does not go
                                   // through, so it wears the same curve by hand — the
                                   // way `DevelopDisclosure` wraps its binding. Without
                                   // it this one card would open as a jump cut beside
                                   // six that ease.
                                   withAnimation(Lumen.motionFold) {
                                       isExpanded.toggle()
                                   }
                               })
            // CLOSED MEANS CLOSED, the rule `WorkspaceSectionView` states one screen up:
            // the panel's body observes `HistoryStack`, which publishes on every mouse
            // event of a drag, so a card that collapsed but still CONSTRUCTED its rows
            // would cost the drag exactly what closing it claims to save.
            if isExpanded {
                HistoryPanel(history: state.history)
                    .transition(.opacity.combined(
                        with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .lumenSurface(radius: Lumen.radiusCard, elevation: .flush, fill: Lumen.panel)
    }
}

/// One section: its header, and its rows when it is open — drawn as a CARD.
///
/// The header is the column's rather than the panel's, so that every section in every
/// workspace gets the same chevron, the same boundary and the same click rule —
/// including the ones assembled out of several panels' pieces, which could not have
/// agreed on it themselves.
///
/// THE CARD IS THE SEPARATOR, and it is the answer to the loudest thing in the owner's
/// second review: "I get a fatigue when I scroll down because everything is so close
/// together … Lightroom has some sort of kind of separator from each different area so
/// that you can tell somewhat that you're entering into a new area."
///
/// A hairline was the obvious reading of that sentence and it is the wrong one here.
/// `Lumen.separator` measures 1.48:1 against the panel — a line the eye does not resolve
/// without being told where to look — so the choice would have been between an invisible
/// rule and repainting a token that eleven other files draw with. And a rule between two
/// stretches of identical grey only says "a line happened"; it does not say the surface
/// changed. `LumenSurface.swift` argues the alternative at length and had zero call
/// sites: give the section an EDGE — a lit top border over its own fill, sitting in a
/// darker trough — and the eye stops hunting for a boundary and starts reading an
/// object. Six of those down a column is unmistakably six areas, at any scroll speed.
///
/// THE HORIZONTAL ARITHMETIC, and it changed on the owner's third review: "I feel like
/// there isn't enough padding from the sides of the Exposure, Contrast, stuff like that,
/// the text, so it's really, really close to the wall. Can we move those in just a little
/// bit more so it's a little more comfortable?"
///
/// He is right, and the number says why. `scrollColumn` gave up its 8 points of side
/// padding to 4 and the card held the other 4, so "Exposure" began **8 points** from the
/// panel's edge — a gutter narrower than the gap between two of its own letters, on a
/// card whose corner radius is now 14. Ten points inside the card puts the label 14 from
/// the edge, which is the same distance as the corner, so the text clears the curve
/// instead of tucking under it.
///
/// It costs the track 12 points, and that is affordable now in a way it was not before:
/// the column is draggable (`ContentView.columnResizer`), so a photographer who wants
/// those points back takes them, and the default width is 380 rather than the 320 the
/// original arithmetic was measured against.
private struct WorkspaceSectionView: View {
    let section: WorkspaceSection
    let isExpanded: Bool
    let isModified: Bool
    let onToggle: (Bool) -> Void
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // `topRhythm: 0` — the card's own padding is the boundary now, and stacking
            // twenty more points of blank panel on top of it inside the card would only
            // push the title away from the rows it names.
            LumenSectionHeader(title: section.title,
                               symbol: section.symbolName,
                               isExpanded: .constant(isExpanded),
                               isModified: isModified,
                               onReset: reset,
                               topRhythm: 0,
                               onToggle: onToggle)
            // CLOSED MEANS CLOSED. `DevelopSection` and `DevelopDisclosure` both take
            // their content as a closure now for this reason: a section that collapses
            // but still CONSTRUCTS its rows costs a drag exactly what the accordion
            // claims to save, and Look holds 38 sliders in one of these.
            if isExpanded {
                WorkspaceSectionBody(section: section)
                    // UNFOLDING, NOT SLIDING — the other half of "the animation for the
                    // open and close for the chevrons are not great".
                    //
                    // It was `.move(edge: .top)`, which translates the whole body
                    // downward by its own height while the column's height grows to meet
                    // it. On a section of three rows that reads as a drawer; on Look's
                    // thirty-eight it is a long vertical wipe travelling at a completely
                    // different speed from the card growing around it, and the two fight
                    // visibly. A scale anchored at the top has no distance in it to get
                    // wrong: the body expands from the header's own edge, at 0.97 so it
                    // is felt rather than watched, and the card's clip keeps it from ever
                    // painting over the section below.
                    .transition(.opacity.combined(
                        with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        // `.flush`: an edge but no cast shadow. Six drop shadows stacked down a
        // scrolling column is a pile of floating tiles, and these are tiled edge to
        // edge — which is the case `Lumen.Elevation` names this step for.
        .lumenSurface(radius: Lumen.radiusCard, elevation: .flush, fill: Lumen.panel)
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
            // THE PHOTO-AWARE OVERLOAD, and per target rather than per selection.
            //
            // This used to resolve the ISO denoise profile once, from the PRIMARY
            // selection, and then write it through `updateRecipe` — which applies to
            // every edit target. Select an ISO 100 frame and an ISO 12800 frame, click
            // Reset on the Detail header, and both got the ISO 100 profile: the high-ISO
            // frame effectively un-denoised, its section reporting "default", with
            // nothing on screen to say so. The whole-recipe Reset in the footer always
            // did this correctly; this one was written against the wrong overload.
            state.updateRecipe(coalescingKey: "workspace.\(section.rawValue).reset") {
                photo, recipe in
                let start = AppState.startingRecipe(for: photo.id, iso: photo.iso)
                section.reset(&recipe)
                // `reset` writes `Denoise()` because LumenCore cannot know the ISO. The
                // photograph's own starting point is the honest default, and it is the
                // one double-clicking a denoise slider already lands on.
                if section == .detail {
                    recipe.develop.denoise = start.develop.denoise
                }
                // And the same for the display transform. `reset` writes `RenderParams()`
                // — preset "Neutral" — for the same reason it writes `Denoise()`: the
                // model cannot know the file is a JPEG that already carries the camera's
                // curve and starts at "Linear". Resetting to Neutral there applies a
                // second tone map and calls the result unedited.
                if section == .looks {
                    recipe.look.render = start.look.render
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
        case .frame: EffectsPanel(only: .frame)
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

// MARK: - The mask editor

/// THE COLUMN WHILE MASKING — the whole of it, not a dock above it.
///
/// It was a dock: the mask list stacked on top of the workspace's own sections, both
/// scrolling together. The owner named what was wrong with that — "when I press it, it
/// just shows up on the page that I am showing off" — and asked for "its own page ...
/// its own kind of section area where you can fully customize stuff about the masks".
///
/// The mask model says he is right rather than merely particular. `LocalAdjust` carries
/// twenty scalars plus a local point curve and local grading wheels, so a mask's
/// adjustments are a copy of the globals: stacked, the column offered Tone, Curve,
/// Colour and Grading TWICE, twenty rows apart, meaning different things depending on
/// how far you had scrolled. Nobody masking wants the global Tone — they want this
/// mask's Tone, and it is right here.
///
/// So this replaces `WorkspaceSections` rather than sitting above it, and the switcher
/// above becomes the way back (`WorkspaceSwitcher.maskingBar`). The workspace underneath
/// is untouched — `expanded`, `register` and `workspace` all survive, so leaving returns
/// the column exactly as it was left.
///
/// No header of its own: the bar above prints "Masks", and `MaskPanel` printing it again
/// a row below is the duplication that was here before this was a takeover.
struct MaskEditor: View {
    @ObservedObject var panel: PanelLayout
    /// This surface shows the edit, so it observes the edit signal — `AppState.recipes`
    /// is deliberately not published (see `EditRevision`).
    @EnvironmentObject private var edits: EditRevision

    var body: some View {
        MaskPanel(showsOwnHeader: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Ten, matching `WorkspaceSectionView`: the takeover wears the accordion's
            // card, so it has to wear the accordion's gutter or the column's text edge
            // would jump sideways every time masking opened.
            .padding(.horizontal, 10)
            // 8 AND 8, which is what `WorkspaceSectionView` uses. It was 4 and 8, so
            // the masking takeover sat four points higher inside its own card than
            // every accordion section does inside theirs — and the two cards are
            // adjacent, one replacing the other, which is the arrangement where four
            // points read as a jump rather than as nothing.
            .padding(.vertical, 8)
            // The same card the accordion's sections wear, for the same reason and to
            // keep the column's edges aligned across the takeover: while masking has the
            // column this IS the area, so it should sit on the surface an area sits on
            // rather than directly on the trough between them.
            .lumenSurface(radius: Lumen.radiusCard, elevation: .flush, fill: Lumen.panel)
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
                .font(.lumenBody)
                .foregroundStyle(Lumen.accent)
                .lumenClickCursor()
        }
        .padding(.top, 2)
    }
}
#endif

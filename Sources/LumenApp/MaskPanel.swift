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

    /// WHICH HALF OF MASKING THIS INSTANCE DRAWS.
    ///
    /// The owner's complaint, after using the panel that put both halves in one column:
    /// "the radial gradient and the add mask, that shouldn't be there… I'd rather have
    /// it in a place where if I need it, I can open it up instead of having this
    /// clutter… All I really want is temperature, tint, exposure, contrast."
    ///
    /// That is a real distinction and not a matter of taste. Making a mask and adjusting
    /// one are different activities on different clocks: the first happens once, in a
    /// burst, and then almost never again; the second is what a photographer does for
    /// the rest of the edit. A linear gradient across a sky is drawn in a second and
    /// then lived with — so the twenty-odd controls that describe HOW IT WAS MADE sat
    /// permanently between the photographer and the six that describe what it DOES.
    ///
    /// Lightroom splits them the same way and has since 11: a floating Masks panel holds
    /// the roster, the list and the overlay switch, and the right-hand column holds
    /// nothing but the sliders.
    ///
    /// Two roles rather than two view types, because everything both halves draw is
    /// already built here and the selection they share already lives in `AppState`.
    /// Extracting eight hundred lines into a second struct would have moved the same
    /// code past a compiler this machine does not have, for no gain a photographer
    /// could see.
    enum Role {
        /// The pop-out beside the histogram: the roster, the list, each mask's
        /// components, its Edge and the overlay switch.
        case navigator
        /// The column: which mask is being edited, and what it does to the picture.
        case adjustments
    }

    var role: Role = .adjustments

    /// Spelled out because the synthesised memberwise initialiser is private the moment
    /// any stored property is, and every `@State` fold below is. Without this,
    /// `MaskPanel(showsOwnHeader:)` would not be callable from the column that draws it.
    init(role: Role = .adjustments, showsOwnHeader: Bool = true) {
        self.role = role
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
    /// What the list is filtered by. Panel-local and never persisted: a filter that
    /// survived a relaunch would be a list of masks that is missing some, with nothing
    /// on screen to say why.
    /// The mask whose name is being typed, if any. Nil the rest of the time, which is
    /// almost always — see `maskRow`.
    @State private var renamingMaskID: String?
    /// The mask whose row is showing "Delete … ?", if any.
    ///
    /// The confirmation IS THE ROW, which is the shape `LookPanel.savedLookRow` settled
    /// for the same question — and that file's comment credits this panel's row menu for
    /// the half it already had. Not a sheet: a modal over the window to ask about a row
    /// in a floating panel is a second window to dismiss, and it takes the mask's own
    /// picture off screen at the moment somebody is deciding whether they want it.
    @State private var pendingDeleteMaskID: String?
    /// The row a drag is currently over, so the list can say where a drop would land.
    @State private var dropTargetMaskID: String?
    @State private var maskSearch: String = ""
    /// WHICH MASKS HAVE THEIR OWN SETTINGS OPEN, one entry per mask, empty by default.
    ///
    /// The owner's rule, and it is Lightroom's: "there should be a chevron. And if I
    /// press the chevron, then all of these settings come up. So invert, contribution,
    /// feather, rotation, as well as the edge stuff … And they are always closed until
    /// I open them. And each of them have their separate open area."
    ///
    /// A `Set` rather than one id, because "each of them have their separate open area"
    /// means two masks can be open at once — the panel is not an accordion. And separate
    /// from SELECTION, which is the distinction the previous arrangement lost: selecting
    /// a mask dumped its whole component stack, its editor and its Edge into the list
    /// unasked, so choosing which mask the sliders point at and asking to see how a mask
    /// was built were the same gesture. They are two questions and they now have two
    /// controls: the row selects, the chevron discloses.
    @State private var expandedMaskIDs: Set<String> = []
    /// WHICH MASKS HAVE AN ADD (OR SUBTRACT) BOARD OPEN — a set, not a flag.
    ///
    /// These were `Bool`s, and every disclosed mask drew its Add and Subtract buttons
    /// bound to the same one. Two chevrons open, press Add under the first, and the
    /// twelve-tile roster appeared under BOTH — the second one a live mis-target, since
    /// choosing a kind on it adds to whichever mask that board is nested in.
    ///
    /// This is the defect the disclosure rewrite says it fixed one level up ("One
    /// `Bool`, two disclosures reading it: one press flipped it and BOTH boards
    /// opened"), reintroduced hours later by the feature that let two masks be open at
    /// once. A flag that is per-mask in the UI has to be per-mask in the state; the
    /// moment `expandedMaskIDs` became a `Set`, these had to become sets too.
    @State private var componentPickerOpen: Set<String> = []
    @State private var subtractPickerOpen: Set<String> = []
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
    /// THREE ZONES, VISIBLY DIFFERENT, IN THE ORDER THE QUESTIONS ARE ASKED.
    ///
    /// A mask asks three things — what is selected, how the edge is shaped, what it does
    /// to the picture — and they used to be three visually identical stacks of grey rows
    /// under three visually identical headers, so nothing on screen said they were
    /// different kinds of question (docs/35 §4.1). Each is a surface now, and each says
    /// its own question beside its name, once.
    var body: some View {
        switch role {
        case .navigator: navigatorBody
        case .adjustments: adjustmentsBody
        }
    }

    /// The pop-out: everything about MAKING the mask.
    ///
    /// List, roster, components, Edge, the brush's tools and the overlay switch. None of
    /// it is needed to judge a photograph, and all of it was permanently in the way of
    /// the controls that are.
    @ViewBuilder
    private var navigatorBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            // THE ROSTER, disclosed by the round `+` in the title bar above — ONE board
            // behind ONE flag.
            //
            // What stood here was a full-width "Create new mask" disclosure button whose
            // `isOpen` was `$maskPickerOpen`… and so was the "Add a mask" button at the
            // bottom of `maskListSection`. One `Bool`, two disclosures reading it: one
            // press flipped it and BOTH boards opened, so the owner got "the entirety of
            // the add a mask twice, and I don't know why". Twenty tiles under two
            // headings for one click. There is one control now and it lives in the title
            // bar, where it is reachable whether the panel is open or collapsed.
            if state.maskCreateBoardOpen {
                kindBoard({ kind in
                    state.maskCreateBoardOpen = false
                    addMask(kind: kind)
                }, offersReference: false)
                .transition(.opacity.combined(with: .move(edge: .top)))
                Divider().overlay(Lumen.separator).padding(.vertical, 2)
            }
            maskListSection
            if let mask = activeMask {
                overlayControls(mask)
            }
        }
    }

    /// The column: everything about what the mask DOES.
    ///
    /// With no mask yet there is nothing to adjust, so the column draws the roster
    /// instead — which is where Lightroom puts it too, and it is the one moment the
    /// board deserves the whole width: there is nothing else to look at.
    @ViewBuilder
    private var adjustmentsBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mask = activeMask {
                editingRow(mask)
                // EDGE IS NOT HERE ANY MORE. It sat in this column for one round, on the
                // argument that refining an edge is the same kind of act as moving
                // Exposure, and the owner overruled it by name: the chevron he asked for
                // opens "invert, contribution, feather, rotation, as well as the edge
                // stuff". He is right and the argument was wrong — Edge changes WHAT IS
                // SELECTED, so it belongs beside the rest of the selection, and having
                // it a panel away meant judging an edge against an overlay you could
                // not see from where the slider was. `maskDetail` draws it now.
                //
                // The column is what the mask DOES, and nothing else.
                effectZone(mask)
            } else {
                emptyMaskState
            }
        }
    }

    /// Which mask the sliders below are pointing at.
    ///
    /// The column no longer contains the list, so without this there is nothing on
    /// screen naming what an Exposure drag is about to move — and a mask panel that does
    /// not say which mask it is editing is worse than one that is merely cluttered.
    /// Thumbnail, name, and the way back into the pop-out.
    private func editingRow(_ mask: Mask) -> some View {
        HStack(spacing: 7) {
            maskThumbnail(mask)
            VStack(alignment: .leading, spacing: 0) {
                Text(mask.name.isEmpty
                     ? MaskPanel.autoName(mask, index: masks.firstIndex(where: { $0.id == mask.id }) ?? 0)
                     : mask.name)
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.primaryText)
                    .lineLimit(1)
                if masks.count > 1 {
                    Text("\(masks.count) masks")
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.tertiaryText)
                }
            }
            Spacer(minLength: 0)
            Button {
                state.maskPanelVisible = true
                state.maskPanelMinimized = false
            } label: {
                Image(systemName: "square.on.square.dashed")
                    .font(.lumenGlyphCaption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Lumen.secondaryText)
            .help("Show the Masks panel — the list, components and the edge")
        }
        .frame(height: Lumen.rowHeight + 8)
    }

    /// Whether this mask has anything the brush parameters would apply to.
    ///
    /// The brush zone is a TOOL, not a property of the mask — the same four controls
    /// formatted like the mask's own was the defect docs/36 §1.1 names — so it is drawn
    /// only when a brush component is selected, and its name says whose settings they
    /// are.
    private func usesBrush(_ mask: Mask) -> Bool {
        guard let i = componentIndex(for: mask),
              mask.components.indices.contains(i) else { return false }
        return mask.components[i].kind == .brush
    }

    private var brushScope: String { "for the next stroke" }

    /// Strength, how it applies, and the whole local adjustment set.
    ///
    /// Strength moved here from the mask list, where it read as a property of the LIST.
    /// It scales the adjustments and never the selection, so this is where it belongs
    /// and this is why it is no longer called Amount.
    private func effectZone(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LumenSlider(title: "Strength",
                        value: maskValue(mask.id, "amount", get: { $0.amount },
                                         set: { $0.amount = Num.clamp($1, 0, 200) }),
                        range: 0...200, defaultValue: 100, step: 1, decimals: 0,
                        help: "How far every adjustment below is pushed, all together. "
                            + "Past 100 it exaggerates them. It does not change what is "
                            + "selected — Contribution, up in the stack, does that.")
            blendRow(mask)
            adjustSections(mask)
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
            // Only past the point where a list stops being scannable. A search field
            // over four masks is a control that costs a row and saves nothing, and
            // docs/36 §1.5's complaint was specifically about fifteen.
            if list.count >= MaskPanel.searchAppearsAt {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.lumenGlyphCaption)
                        .foregroundStyle(Lumen.secondaryText)
                    TextField("Filter", text: $maskSearch)
                        .textFieldStyle(.plain)
                        .font(.lumenBody)
                    if !maskSearch.isEmpty {
                        Button { maskSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.lumenGlyphCaption)
                                .foregroundStyle(Lumen.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Show every mask again")
                    }
                }
                .padding(.bottom, 2)
            }
            // Grouped rows first, then the loose ones. Not interleaved by list order:
            // a folder whose members are scattered through the list with other masks
            // between them is not a folder, and the alternative — forcing the mask
            // order to follow the grouping — would make dragging a mask into a group
            // silently reorder the stack, which changes the picture.
            ForEach(groupedRows, id: \.key) { row in
                switch row.kind {
                case .header(let group):
                    groupHeader(group)
                case .mask(let mask, let index):
                    // A MASK CARRIES ITS OWN PARTS WHEN ASKED, and not before. Depth is
                    // unlocked by the row's own CHEVRON — see `expandedMaskIDs` — not by
                    // selection and never by default.
                    //
                    // Selection used to do it, which is one gesture doing two jobs:
                    // pointing the sliders at a mask also dumped its component stack,
                    // its op control, Invert this, Contribution, the kind's parameters
                    // and its Edge into the list, so there was no way to switch masks
                    // without also unfolding one. Before that they were all permanently
                    // on screen; the owner's word for that was "overwhelmed".
                    VStack(alignment: .leading, spacing: 2) {
                        maskRow(mask, index: index)
                        if expandedMaskIDs.contains(mask.id) {
                            maskDetail(mask)
                        }
                    }
                    // A leading inset is the whole indent and wants no trailing
                    // partner: it moves the left edge in and leaves the right edge on
                    // the container's, which is what makes a grouped row line up with
                    // its ungrouped neighbours down the right-hand side. The lopsided
                    // insets the owner could see — "most of these things are padded on
                    // the left side and not the right side" — were in the DISCLOSED
                    // block, where `.padding(.leading, 14)` was applied three times to
                    // three different subtrees inside a container that had no matching
                    // inset of its own. `maskDetail` owns that now, once, on both sides.
                    .padding(.leading, mask.group == nil ? 0 : 12)
                }
            }
        }
    }

    /// One mask's own settings, disclosed by its chevron.
    ///
    /// Everything about how this particular mask was BUILT and how its edge is shaped:
    /// its parts, the two verbs that add more, the selected part's own controls (Invert,
    /// Contribution, and whatever the kind itself has — a radial's Feather and Rotation,
    /// a brush's flow) and then Edge. The owner named this list exactly: "invert,
    /// contribution, feather, rotation, as well as the edge stuff".
    ///
    /// Inset on BOTH sides. The indent says these belong to the row above; the trailing
    /// inset is what stops them growing past the rows they belong to, which is what made
    /// a disclosed mask look wider than its own container.
    @ViewBuilder
    private func maskDetail(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            componentRows(mask)
            // THE BRUSH'S OWN TOOLS, and their absence was not a design decision.
            //
            // `brushParameters()` was declared and called from nowhere: an earlier round
            // deleted the brush ZONE from the develop column on the correct grounds that
            // it drew the same seven controls the component editor already drew, and
            // `componentParameters` still returns `EmptyView()` for `.brush` with a
            // comment explaining that the zone has them. Both halves of that pair were
            // removed and the survivor kept deferring to a view that no longer existed,
            // so a brush mask has had NO Size, Feather, Flow or Density control anywhere
            // in the window — only the `[`/`]` keys, which you have to already know.
            //
            // Its own heading with its own caption, because the scope really is
            // different from everything above it: these are the settings the NEXT stroke
            // records into the blob, not properties of the strokes already painted.
            if usesBrush(mask) {
                LumenSectionHeader(title: "Brush", isExpanded: nil, topRhythm: 0)
                Text(brushScope)
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.tertiaryText)
                brushParameters()
            }
            // EDGE, in the pop-out and beside the mask it shapes.
            //
            // It was in the develop column, one panel away from the mask whose edge it
            // shapes, on the theory that refining an edge is the same kind of act as
            // moving Exposure. The owner disagrees and he is right: it is part of making
            // the selection, so it belongs with the rest of making the selection. Its
            // overlay rule comes with it — an Edge control moves the SELECTION, and the
            // overlay is the only place a selection is visible at all, so it is forced
            // on while one is dragged.
            LumenSectionHeader(title: "Edge", isExpanded: nil,
                               isModified: mask.refine != MaskRefine(),
                               onReset: mask.refine == MaskRefine() ? nil : {
                                   editMask(mask.id, key: nil) { $0.refine = MaskRefine() }
                               },
                               topRhythm: 0)
            refineSection(mask)
                .environment(\.sliderGestureChanged) { active in
                    state.sliderGestureSink(active)
                    state.setMaskEdgeGesture(active, mask: mask.id)
                }
        }
        .padding(.leading, MaskPanel.detailIndent)
        .padding(.trailing, 2)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    /// How far a mask's disclosed settings sit in from its own row.
    ///
    /// One constant rather than a `14` written at four call sites, three of which had
    /// drifted apart — the component rows, their Add/Subtract buttons and the component
    /// editor were each indented independently, so a disclosed mask had three different
    /// left edges stacked down it.
    static let detailIndent: CGFloat = 12

    /// One row of the list: either a folder's header or a mask.
    ///
    /// Flattened into a single sequence rather than nested `ForEach`es so that the
    /// index a `maskRow` is handed is still its index in `masks` — every action on a
    /// row (reorder, delete, solo) is written in terms of that, and a per-group index
    /// would silently address the wrong mask.
    struct MaskListRow: Identifiable {
        enum Kind {
            case header(MaskGroup)
            case mask(Mask, Int)
        }
        var key: String
        var kind: Kind
        var id: String { key }
    }

    /// The list as it is drawn: each group's header followed by its members, then every
    /// ungrouped mask. A collapsed group contributes its header and nothing else.
    ///
    /// A mask naming a group that is not in the list falls through to the ungrouped
    /// section rather than disappearing — the same rule `Recipe.effective` holds for the
    /// render, and for the same reason: a folder deleted by hand out of a sidecar must
    /// not take its members with it.
    private var maskGroups: [MaskGroup] {
        state.primarySelection.map { state.recipe(for: $0).maskGroups } ?? []
    }

    /// Where a list stops being scannable and starts needing a filter.
    static let searchAppearsAt = 8

    /// How wide the overlay's mode-and-colour menu is drawn — see `overlayControls` for
    /// the arithmetic and for which titles have to survive it whole.
    static let overlayMenuWidth: CGFloat = 128

    /// Does this mask answer the filter?
    ///
    /// Everything a row DISPLAYS is searchable — the name the photographer typed, the
    /// name it has when they have not typed one, the stack summary underneath, and the
    /// folder it is in. Matching only `name` would be a filter that cannot find "the
    /// radial one", which is how people actually describe a mask they have not named.
    static func matches(_ mask: Mask, index: Int, group: MaskGroup?,
                        query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let haystack = [mask.name, autoName(mask, index: index), stackSummary(mask),
                        group?.name ?? ""].joined(separator: " ").lowercased()
        return haystack.contains(q)
    }

    private var groupedRows: [MaskListRow] {
        let list = masks
        let groups = maskGroups
        let known = Set(groups.map(\.id))
        var rows: [MaskListRow] = []
        // The SELECTED mask is never filtered out. The editor below the list is showing
        // it either way, and a panel editing something the list says is not there is
        // the sort of thing that makes people stop trusting a filter.
        let selected = activeMask?.id
        func shown(_ mask: Mask, _ index: Int, _ group: MaskGroup?) -> Bool {
            mask.id == selected
                || MaskPanel.matches(mask, index: index, group: group,
                                     query: maskSearch)
        }
        for group in groups {
            let all = list.enumerated().filter { $0.element.group == group.id }
            let members = all.filter { shown($0.element, $0.offset, group) }
            // FILTERED AWAY AND GENUINELY EMPTY ARE DIFFERENT THINGS, and conflating
            // them loses a folder. A group the filter emptied is hidden — a column of
            // headers with nothing under them is a worse answer to "where is it" than a
            // short list. A group that is empty because its last mask was deleted STAYS,
            // because it is still somewhere to drag a mask into and, if it is not, its
            // own menu is the only place Ungroup lives. Hidden, it would sit in the
            // recipe invisible and unremovable.
            if !all.isEmpty && members.isEmpty { continue }
            rows.append(MaskListRow(key: "g:" + group.id, kind: .header(group)))
            guard !group.collapsed else { continue }
            for (index, mask) in members {
                rows.append(MaskListRow(key: "m:" + mask.id, kind: .mask(mask, index)))
            }
        }
        for (index, mask) in list.enumerated()
        where (mask.group == nil || !known.contains(mask.group ?? ""))
            && shown(mask, index, nil) {
            rows.append(MaskListRow(key: "m:" + mask.id, kind: .mask(mask, index)))
        }
        return rows
    }

    /// A folder's row: the triangle, the name, how many masks are in it, and the two
    /// controls a group has — its switch and its Amount, the second behind the row's
    /// own menu because a slider on every header would make a list of folders taller
    /// than the list of masks it exists to shorten.
    private func groupHeader(_ group: MaskGroup) -> some View {
        let count = masks.filter { $0.group == group.id }.count
        return HStack(spacing: 6) {
            Button {
                editGroup(group.id) { $0.collapsed.toggle() }
            } label: {
                Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                    .font(.lumenGlyphCaptionStrong)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(group.collapsed ? "Open this group" : "Close this group")

            Image(systemName: group.collapsed ? "folder.fill" : "folder")
                .font(.lumenGlyphCaption)
                .foregroundStyle(Lumen.secondaryText)

            // THE ONE THING ON THIS ROW THAT MAY SHRINK, and the two below say so.
            //
            // The header's fixed parts — chevron, folder mark, count, strength, switch,
            // menu and six gaps — come to about 145 points inside a 244 point row, so
            // there is room for the name AT its 110 and nothing spare if a group is
            // switched off at 150 %. Something has to give under pressure, and it must be
            // the field: a name field that has shrunk is still a name field, where a
            // count truncated to "12 ma…" has stopped being a count.
            TextField("Group", text: groupName(group.id))
                .textFieldStyle(.plain)
                .font(.lumenBody)
                .foregroundStyle(group.enabled ? Lumen.primaryText : Lumen.secondaryText)
                .frame(maxWidth: 110)

            // "Empty" rather than "0 masks": a folder with nothing in it is a state
            // worth naming, because the next question is whether to fill it or remove
            // it, and a zero reads as a count that failed to load.
            //
            // `.fixedSize()` AND `.lineLimit(1)`, which are two different refusals. The
            // line limit is what stops it wrapping — a `Text` in an `HStack` with no
            // fixed height will happily take a second line and make the whole header
            // taller than every other row in the list, which reads as a rendering fault
            // rather than as a squeeze. The fixed size is what stops it truncating
            // instead, which for a two-word count is the same as deleting it.
            Text(count == 0 ? "empty" : (count == 1 ? "1 mask" : "\(count) masks"))
                .font(.lumenCaption)
                .foregroundStyle(count == 0 ? Lumen.tertiaryText : Lumen.secondaryText)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 4)

            if group.amount != 100 {
                // Shown only when it is not at its default, like every other modified
                // mark in the application: a badge on every row is not a badge.
                Text("\(Int(group.amount.rounded()))%")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.accent)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button { editGroup(group.id) { $0.enabled.toggle() } } label: {
                Image(systemName: group.enabled ? "eye" : "eye.slash")
                    .font(.lumenGlyphCaption)
                    .foregroundStyle(group.enabled ? Lumen.primaryText
                                                   : Lumen.secondaryText)
            }
            .buttonStyle(.plain)
            .help(group.enabled ? "Stop rendering every mask in this group, keeping them"
                                : "Render them again")

            LumenMenu(title: "", symbol: "ellipsis", iconOnly: true,
                      help: "How strong the whole group is, and what happens to it") {
                LumenMenuHeader(title: "Strength")
                // Five stops rather than a slider. A slider on every folder header
                // would make a list of groups taller than the list of masks it exists
                // to shorten, and a group's Amount is a coarse control by nature —
                // "dial the whole retouch back" is not a one-percent decision.
                ForEach(MaskPanel.groupAmounts, id: \.self) { value in
                    LumenMenuItem(title: "\(Int(value))%",
                                  isSelected: abs(group.amount - value) < 0.5) {
                        editGroup(group.id) { $0.amount = value }
                    }
                }
                LumenMenuHeader(title: "This group")
                LumenMenuItem(title: "Ungroup", symbol: "folder.badge.minus") {
                    dissolveGroup(group.id)
                }
            }
        }
        // A FIXED HEIGHT, so nothing on this row can make it taller. Without it a long
        // folder name plus a count plus a strength badge could push a `Text` onto a
        // second line and the header would grow while its neighbours did not.
        .frame(height: Lumen.rowHeight)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// The strengths a group's menu offers. Coarse on purpose — see `groupHeader`.
    static let groupAmounts: [Double] = [25, 50, 75, 100, 150]

    private func groupName(_ id: String) -> Binding<String> {
        Binding(get: {
            state.primarySelection
                .flatMap { state.recipe(for: $0).maskGroups.first { $0.id == id } }?.name
                ?? ""
        }, set: { v in
            state.updateRecipe(coalescingKey: "maskgroup.name." + id) { recipe in
                guard let i = recipe.maskGroups.firstIndex(where: { $0.id == id })
                else { return }
                recipe.maskGroups[i].name = v
            }
        })
    }

    /// Delete the folder and KEEP every mask in it, at the top level.
    ///
    /// The only spelling of "delete a group" this panel offers, and deliberately: a
    /// control that removes a folder AND the twelve masks inside it is one misclick
    /// away from an hour of someone's work, and the masks can still be deleted one at a
    /// time by whoever actually meant to.
    private func dissolveGroup(_ id: String) {
        state.updateRecipe(coalescingKey: nil) { recipe in
            recipe.maskGroups.removeAll { $0.id == id }
            for i in recipe.masks.indices where recipe.masks[i].group == id {
                recipe.masks[i].group = nil
            }
        }
    }

    /// Put a mask in a folder, making one if it is not there yet.
    private func moveMask(_ maskID: String, toGroup id: String?) {
        state.updateRecipe(coalescingKey: nil) { recipe in
            guard let i = recipe.masks.firstIndex(where: { $0.id == maskID })
            else { return }
            recipe.masks[i].group = id
        }
    }

    private func groupMask(_ maskID: String) {
        let group = MaskGroup(id: UUID().uuidString, name: "")
        state.updateRecipe(coalescingKey: nil) { recipe in
            guard let i = recipe.masks.firstIndex(where: { $0.id == maskID })
            else { return }
            recipe.maskGroups.append(group)
            recipe.masks[i].group = group.id
        }
    }

    private func editGroup(_ id: String, _ body: @escaping (inout MaskGroup) -> Void) {
        state.updateRecipe(coalescingKey: nil) { recipe in
            guard let i = recipe.maskGroups.firstIndex(where: { $0.id == id })
            else { return }
            body(&recipe.maskGroups[i])
        }
    }

    /// The empty state: an affordance, not a definition.
    ///
    /// What stood here defined a mask — "a stack of components combined with add,
    /// subtract and intersect" — to somebody looking at an empty list, which is the one
    /// moment that sentence cannot help. The only useful thing an empty list can do is
    /// be easy to fill, so the control that fills it is the biggest object on screen.
    private var emptyMaskState: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ONE LINE, AND NO MARK. `LumenEmptyState` is the house shape for this — a
            // mark, a headline, an optional detail and one button — and it is the wrong
            // shape HERE for a reason its own API already anticipates: `symbol` is
            // optional "which the grid's overlay wants when it is sitting on top of a
            // filmstrip that is already showing thumbnails — a mark there would be a
            // second subject on a surface that has one". The board below is twelve
            // glyphs. A 40 pt mark over it would be exactly that second subject, and
            // `LumenEmptyState` also centres its stack and fills its container, which
            // would put a centred sentence over a left-aligned board.
            //
            // What is taken from it is the part that was missing: the headline, at the
            // same `lumenLead` and in the same voice, saying what this column is for.
            // Without it the develop column at masking with no masks was a board of tiles
            // under three group labels and nothing naming the activity.
            Text("No masks on this photograph yet.")
                .font(.lumenLead)
                .foregroundStyle(Lumen.primaryText)
            // `.constant(true)` because `prominent` draws the board unconditionally
            // and never reads the flag — there is nothing here to disclose it WITH, so
            // the board simply is the panel. It used to be handed `$maskPickerOpen`,
            // which is how one `Bool` ended up wired to three different disclosures.
            kindMenu(label: "Add a mask", isOpen: .constant(true), prominent: true) { kind in
                addMask(kind: kind)
            }
        }
        .padding(.vertical, 6)
    }

    private func maskRow(_ mask: Mask, index: Int) -> some View {
        let isSelected = mask.id == activeMask?.id
        let isOpen = expandedMaskIDs.contains(mask.id)
        return HStack(spacing: 5) {
            // THE CHEVRON, and it is the control the panel was missing.
            //
            // Its own hit target, ahead of everything else in the row, so disclosing a
            // mask and selecting one are two different places to press rather than two
            // meanings of one press.
            Button {
                withAnimation(Lumen.motionFold) {
                    if isOpen { expandedMaskIDs.remove(mask.id) }
                    else { expandedMaskIDs.insert(mask.id) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    // 10, the floor, and the same size every other disclosure chevron
                    // in the app draws at — this one was 8, which is two points under
                    // the app's own stated minimum and visibly lighter than the
                    // chevrons in the develop column beside it.
                    .font(.lumenCaptionStrong)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isOpen ? Lumen.primaryText : Lumen.secondaryText)
            .lumenClickCursor()
            .help(isOpen ? "Hide this mask's settings" : "Show this mask's settings")

            MaskThumbnail(image: state.maskThumbnails[mask.id],
                          enabled: mask.enabled,
                          width: MaskPanel.thumbnailSize.width,
                          height: MaskPanel.thumbnailSize.height,
                          // NO RING HERE, and the rail keeps its one. Selection in the
                          // open list is the row's own tinted background, which is a
                          // bigger and quieter signal than a border on a 44 pt picture;
                          // the collapsed rail has no row and no name, so down there the
                          // ring is the only thing saying which mask the sliders point
                          // at. Two states, one for each place, rather than the drift
                          // that had the selected mask marked in the collapsed panel and
                          // unmarked in the open one.
                          selected: false)

            if pendingDeleteMaskID == mask.id {
                deletePrompt(mask, index: index)
            } else {
                maskNameColumn(mask, index: index, isSelected: isSelected)
                enabledButton(mask)
                maskRowMenu(mask, index: index)
            }
        }
        // THE ROW'S OWN BUDGET, and the arithmetic is why the panel got wider rather
        // than why this row got more controls. At 236 points the card gave the content
        // 216, of which chrome took 120 and the name got 96 — "Radial Gradient 1" needs
        // about 105, so every default name in the list arrived truncated. The reorder
        // chevrons that used to sit here have moved into the row's own menu, where
        // "Move up" and "Move down" are words rather than two 12-point targets a
        // pixel apart, and that plus the wider card leaves the name 132.
        //
        // NOTHING SINCE HAS BEEN ADDED TO THIS LINE. Invert went onto the summary line
        // underneath, where the row's 30 pt picture is already paying for the height and
        // the first line's 132 points are untouched — see `maskNameColumn`.
        .padding(.horizontal, 4).padding(.vertical, 3)
        .background(rowBackground(isSelected: isSelected,
                                  isDropTarget: dropTargetMaskID == mask.id))
        .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip))
        .contentShape(Rectangle())
        // DRAG TO REORDER, and the payload is the mask's own id.
        //
        // Order is a render fact — both renderers walk `plan.masks` front to back, so
        // where two masks overlap the later one works on the earlier one's output — and
        // until now the only way to state it was two words in a menu, one place at a
        // time. Dragging is how every list on this platform is reordered and it is the
        // only gesture that can move a mask more than one place at once.
        //
        // `Move up` and `Move down` STAY in the menu beside it. A drag needs a pointer
        // that can hold a button down across 30 points of travel; the menu items do not,
        // and one of them is the only reorder a trackpad user with a tremor can make.
        .draggable(mask.id)
        .dropDestination(for: String.self) { ids, _ in
            guard let dragged = ids.first else { return false }
            dropTargetMaskID = nil
            return dropMask(dragged, onto: mask.id)
        } isTargeted: { inside in
            if inside { dropTargetMaskID = mask.id }
            else if dropTargetMaskID == mask.id { dropTargetMaskID = nil }
        }
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

    /// The row's ground: selected, or about to receive a drop, or neither.
    ///
    /// One function rather than a nested ternary in the modifier, because the two states
    /// have to be TOLD APART at a glance while a drag is in flight — a drop target drawn
    /// in the selection's own fill would say "this is the mask you are editing" at the
    /// exact moment it means "this is where it will land".
    private func rowBackground(isSelected: Bool, isDropTarget: Bool) -> Color {
        if isDropTarget { return Lumen.accent.opacity(0.28) }
        return isSelected ? Lumen.fillColor.opacity(0.20) : Color.clear
    }

    /// DISABLE, and it is a different verb from delete in every way the row can say it.
    ///
    /// A glyph that changes shape (an open eye against a struck-through one), a colour
    /// that drops a step, and the mask's own picture fading to 40 % — three channels for
    /// a state that is reversible and costs nothing. Delete is a word, in a menu, behind
    /// a deliberate open, and where it would throw away hand work it is a second press
    /// on a row that has stopped looking like a row. Neither is a small target: this is
    /// 16×16 with its own `contentShape`, and Delete is a full menu row.
    private func enabledButton(_ mask: Mask) -> some View {
        Button { editMask(mask.id, key: nil) { $0.enabled.toggle() } } label: {
            Image(systemName: mask.enabled ? "eye" : "eye.slash")
                .font(.lumenGlyphCaption)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(mask.enabled ? Lumen.secondaryText : Lumen.tertiaryText)
        .lumenClickCursor()
        .help(mask.enabled ? "Stop rendering this mask, keeping it" : "Render it again")
    }

    /// INVERT, ON THE ROW, in one press and readable without a hover.
    ///
    /// The word is constant and the glyph carries the state, which is the way round that
    /// makes a column of these scannable: a label that changed between "Invert" and
    /// "Inverted" would reflow the summary beside it on every press, and the eye reads a
    /// filled shape faster than it reads a suffix. `Lumen.accent` is the app's mark for
    /// "you changed this", at marker scale — the same argument `LumenSwitch` makes for
    /// filling its capsule with the modified fill.
    ///
    /// The menu keeps its "Invert selection" item. Two homes for one decision is
    /// normally the defect this panel keeps deleting, and this is the exception the row
    /// menu itself already makes for Rename: the menu is where the operation is NAMED in
    /// full, and the row is where it is reached while working.
    private func invertChip(_ mask: Mask) -> some View {
        Button { editMask(mask.id, key: nil) { $0.invert.toggle() } } label: {
            HStack(spacing: 3) {
                Image(systemName: MaskPanel.invertGlyph(mask.invert))
                    .font(.lumenGlyphCaption)
                Text("Invert").font(.lumenCaption)
            }
            .foregroundStyle(mask.invert ? Lumen.accent : Lumen.tertiaryText)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lumenClickCursor()
        .help(mask.invert
              ? "This mask selects everything its parts do NOT. Press to put it back."
              : "Select everything this mask's parts do not.")
    }

    /// The armed row: which mask is about to go, and the two ways out.
    ///
    /// It replaces the name and the trailing controls and keeps the mask's own picture,
    /// because the question being asked is "is this the one you meant" and the picture is
    /// the only honest answer to it. Keep is first and it is where the pointer already is
    /// when the menu closes — `LookPanel.savedLookRow`'s arrangement, for the same
    /// reason.
    private func deletePrompt(_ mask: Mask, index: Int) -> some View {
        let name = mask.name.isEmpty ? MaskPanel.autoName(mask, index: index) : mask.name
        return HStack(spacing: 6) {
            Text("Delete \u{201C}\(name)\u{201D}?")
                .font(.lumenBody)
                .foregroundStyle(Lumen.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { pendingDeleteMaskID = nil } label: {
                Text("Keep").font(.lumenCaptionStrong)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Lumen.secondaryText)
            .lumenClickCursor()
            .help("Leave this mask where it is.")
            Button {
                pendingDeleteMaskID = nil
                deleteMask(mask.id)
            } label: {
                Text("Delete").font(.lumenCaptionStrong)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Lumen.accent)
            .lumenClickCursor()
            // Undo DOES reach this, and saying so is the difference between a
            // confirmation that informs and one that frightens. What it protects against
            // is the deletion nobody notices — see `deletionLosesWork`.
            .help("Throw this mask and its adjustments away. Undo brings it back.")
        }
    }

    /// The mask's name, its rename field, its summary and its invert.
    @ViewBuilder
    private func maskNameColumn(_ mask: Mask, index: Int, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
                // TEXT UNTIL YOU ASK FOR A FIELD, and this is the single most confusing
                // thing in the panel until it is fixed.
                //
                // The name was an always-live `TextField` with no visible chrome, so it
                // ate the click: the most obvious target in the row — the mask's own
                // name — put a caret in a text field instead of selecting the mask. The
                // owner reported it exactly: "pressing it makes me change the name of
                // it. So I have to press on the actual mask name." He could not tell
                // which mask his sliders belonged to, because the click that should have
                // switched masks was being spent on a rename he did not ask for.
                //
                // Double-click renames, which is what Lightroom does and what every list
                // on macOS does. Escape and Return both end it.
                if renamingMaskID == mask.id {
                    TextField(MaskPanel.autoName(mask, index: index), text: maskName(mask.id))
                        .textFieldStyle(.plain).font(.lumenBody)
                        .foregroundStyle(Lumen.primaryText)
                        .onSubmit { renamingMaskID = nil }
                        .onExitCommand { renamingMaskID = nil }
                } else {
                    Text(mask.name.isEmpty ? MaskPanel.autoName(mask, index: index)
                                           : mask.name)
                        .font(.lumenBody)
                        .foregroundStyle(isSelected ? Lumen.primaryText : Lumen.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            selectedMaskID = mask.id
                            renamingMaskID = mask.id
                        }
                        .onTapGesture { selectedMaskID = mask.id; selectedComponent = 0 }
                }
                // What the stack actually is, under the name — the kinds and how they
                // fold, which is the sentence the count badge was standing in for.
                // "3" never told anybody what mask 3 selects.
                //
                // AND NOT WHEN IT WOULD ONLY REPEAT THE NAME. A fresh one-component mask
                // is called "Brush 1" and its stack is "Brush", so the row spent two
                // lines saying one word. The summary earns its line when there is more
                // than one component, or when a typed name has replaced the kind and the
                // kind is no longer visible anywhere on the row.
                //
                // INVERT LIVES ON THIS LINE, and this is where it costs nothing.
                //
                // It was reachable only through the row's `⋯` menu — an open, a read and
                // a choice for a one-bit state — and nothing anywhere on the row said
                // whether a mask was inverted, so "the sky" and "everything but the sky"
                // were the same row twice. It is the control a photographer flips most
                // often after making a mask and it was the most expensive one to reach.
                //
                // The SECOND line rather than the first, and that is the whole reason
                // this fits: the row's height is set by its 30 pt picture, not by its
                // text, so a name column that draws two lines instead of one is exactly
                // as tall as before — and the first line's name budget, which
                // `LayoutMetricTests` measures every default mask name against, is
                // untouched. What the chip costs is width on the SUMMARY, which already
                // tail-truncates and is the row's secondary reading.
                HStack(spacing: 4) {
                    invertChip(mask)
                    if MaskPanel.summaryAddsSomething(mask) {
                        Text(MaskPanel.stackSummary(mask))
                            .font(.lumenCaption)
                            .foregroundStyle(Lumen.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
        }
    }

    /// Move `dragged` to where `target` sits, through the pure rule above.
    ///
    /// Refused rather than silently ignored when the drop is a no-op, so the panel does
    /// not record an undo step for a drag that changed nothing — `updateRecipe` already
    /// drops a write whose recipe is unchanged, but a `false` here also tells AppKit the
    /// drop was not accepted, which is what stops the drag image snapping into a row it
    /// did not move to.
    @discardableResult
    private func dropMask(_ dragged: String, onto target: String) -> Bool {
        guard dragged != target, mask(dragged) != nil, mask(target) != nil else {
            return false
        }
        state.updateRecipe(coalescingKey: nil) { recipe in
            recipe.masks = MaskPanel.reordered(recipe.masks, moving: dragged, onto: target)
        }
        return true
    }

    /// How this mask's result meets the picture underneath.
    ///
    /// Three entries, and the two that are not Normal are the reason it exists: a mask
    /// in **Brightness only** dodges and burns skin without shifting its colour, and one
    /// in **Colour only** warms a sky without lifting it. Photoshop, Affinity and ON1
    /// give a layer a blend mode; no raw editor with this much depth per mask does
    /// (docs/36 §3).
    ///
    /// Named for what each LEAVES ALONE rather than for the compositing operator, because
    /// that is the half a photographer is choosing on — and because "Luminosity" and
    /// "Color" are Photoshop's words for a Photoshop model, and the thing being chosen
    /// here is not a layer.
    private func blendRow(_ mask: Mask) -> some View {
        HStack(spacing: 6) {
            Text("Applies")
                .font(.lumenBody)
                .foregroundStyle(Lumen.secondaryText)
            Spacer(minLength: 0)
            LumenMenu(title: mask.blend.label,
                      help: MaskBlend.allCases
                          .map { "\($0.label) — \($0.explanation)" }
                          .joined(separator: "\n")) {
                ForEach(MaskBlend.allCases, id: \.self) { blend in
                    LumenMenuItem(title: blend.label,
                                  isSelected: mask.blend == blend) {
                        editMask(mask.id, key: nil) { $0.blend = blend }
                    }
                }
            }
        }
        .frame(height: Lumen.rowHeight)
    }

    /// A picture of what this mask selects, in its own row.
    ///
    /// This is the single biggest comprehension win in the rebuild and the cheapest:
    /// a row carried a COUNT BADGE, so "Mask 3" had to be remembered rather than seen,
    /// and a stack of three components was an abstraction rather than three pictures
    /// and a result (docs/35 §4.3). Lightroom has had this for years and it is most of
    /// why its masking reads as approachable despite being the deepest in the market.
    ///
    /// ONE CALLER: `editingRow`, in the develop column. The list builds `MaskThumbnail`
    /// directly and so does `MaskFloatingPanel.maskRail`, because each passes a different
    /// `selected:` and neither wants this method's argument list.
    ///
    /// The comment that stood here named the collapsed rail as the reason the shared view
    /// exists — "two copies of the corner radius and the border would have drifted the
    /// moment one of them changed" — and the rail has never called it. Worse, the drift
    /// the sentence was written to prevent had already happened in the one dimension the
    /// method did own: this drew 40×27 while both direct constructions drew 44×30, so the
    /// picture beside "which mask am I editing" was a different size from the picture of
    /// the same mask in the list (audit F4-04). `MaskPanel.thumbnailSize` is the one size
    /// now and all three read it.
    ///
    /// The shared VIEW is still worth having, and its own doc comment says why: the
    /// radius, the border and the disabled opacity really are drawn in three places.
    private func maskThumbnail(_ mask: Mask) -> some View {
        MaskThumbnail(image: state.maskThumbnails[mask.id],
                      enabled: mask.enabled,
                      width: MaskPanel.thumbnailSize.width,
                      height: MaskPanel.thumbnailSize.height,
                      selected: false)
    }

    /// Everything that acts on ONE mask, attached to that mask's row.
    ///
    /// Invert, Duplicate, Delete and the three overlay controls used to float in the
    /// column below the list — six controls with no visible owner, which is what the
    /// owner meant by "duplicate, delete, which is in a weird place". A row's own menu
    /// is where an operation on a row belongs, and it takes six rows out of the column.
    private func maskRowMenu(_ mask: Mask, index: Int) -> some View {
        let room = MaskPanel.reorderRoom(masks, index)
        return LumenMenu(title: "", symbol: "ellipsis", iconOnly: true,
                         help: "Rename, reorder, invert, duplicate, delete") {
            LumenMenuHeader(title: "This mask")
            LumenMenuItem(title: "Rename", symbol: "pencil") {
                selectedMaskID = mask.id
                renamingMaskID = mask.id
            }
            LumenMenuItem(title: mask.invert ? "Stop inverting" : "Invert selection",
                          symbol: "circle.righthalf.filled") {
                editMask(mask.id, key: nil) { $0.invert.toggle() }
            }
            LumenMenuItem(title: "Duplicate", symbol: "plus.square.on.square") {
                duplicateMask(mask.id)
            }
            LumenMenuItem(title: "Duplicate and invert",
                          symbol: "plus.square.on.square.dashed") {
                duplicateMask(mask.id, inverting: true)
            }
            // DELETE ASKS ONLY WHERE THE ANSWER COULD BE "no".
            //
            // A gradient you dragged or a colour you picked is one gesture to make
            // again, and a confirmation on those would be a dialog in front of something
            // cheaper than reading it — which is how an application teaches people to
            // dismiss its confirmations without looking. Painted strokes, a traced
            // outline, a stack of parts or a mask you have graded are not one gesture,
            // and those arm the row instead. `deletionLosesWork` is the whole rule and it
            // is written down there.
            LumenMenuItem(title: "Delete", symbol: "trash") {
                if MaskPanel.deletionLosesWork(mask) {
                    renamingMaskID = nil
                    pendingDeleteMaskID = mask.id
                } else {
                    deleteMask(mask.id)
                }
            }

            // REORDER LIVES HERE NOW, as two words rather than two 12-point chevrons
            // wedged into the row. Masks fold in list order — both renderers walk
            // `plan.masks` front to back, so where two masks overlap the later one is
            // working on the earlier one's output — so this is a real operation and not
            // a cosmetic sort. It is also used about once a session, which is exactly
            // the kind of control that should cost a menu rather than 30 points of every
            // row's width forever. Getting it out of the row is most of what bought the
            // mask's own name enough room to be read.
            if room.up || room.down {
                LumenMenuHeader(title: "Order")
                if room.up {
                    LumenMenuItem(title: "Move up", symbol: "chevron.up") {
                        moveMask(mask.id, by: -1)
                    }
                }
                if room.down {
                    LumenMenuItem(title: "Move down", symbol: "chevron.down") {
                        moveMask(mask.id, by: 1)
                    }
                }
            }

            LumenMenuHeader(title: "Group")
            LumenMenuItem(title: "New group", symbol: "folder.badge.plus") {
                groupMask(mask.id)
            }
            ForEach(maskGroups, id: \.id) { group in
                LumenMenuItem(title: group.name.isEmpty ? "Group" : group.name,
                              symbol: "folder",
                              isSelected: mask.group == group.id) {
                    moveMask(mask.id, toGroup: mask.group == group.id ? nil : group.id)
                }
            }
            if mask.group != nil {
                LumenMenuItem(title: "Leave the group", symbol: "folder.badge.minus") {
                    moveMask(mask.id, toGroup: nil)
                }
            }

            // NO OVERLAY SECTION. Twelve of this menu's items — the switch, six modes
            // and four colours — moved to `overlayControls`, which is drawn under the
            // list and had been dead code since it was written. Two homes for one
            // decision is worse than either, and the menu was a flat list of fifteen-plus
            // items of which twelve were about how the red is drawn.
        }
    }

    /// The overlay's switch, mode and colour, in the panel as well as on `O`/`⌥O`/`⇧O`.
    ///
    /// **This function was written, styled, argued for in its own doc comment — and
    /// never called.** Zero call sites. Its comment said "a control that only exists as
    /// a keystroke is a control most people never find", and meanwhile the entire
    /// visible surface of a five-input overlay state machine was two items buried in a
    /// row's `⋯` menu plus a badge in the corner of the loupe. The owner's "I don't know
    /// how much of these is actually working" was, for the overlay, exactly right.
    ///
    /// It is drawn under the mask list now, which is where Lightroom puts the same three
    /// controls, and the `⋯` menu's twelve overlay items are gone: one home each.
    private func overlayControls(_ mask: Mask) -> some View {
        let showing = state.soloMaskOverlay == mask.id
        // ONE BUTTON AND ONE MENU, because three controls did not fit and did not
        // admit it.
        //
        // This row used to be an `HStack` of the "Show overlay" pill (~85 pt), a mode
        // menu whose longest title is "Image on Black" (~110 pt) and a tint menu
        // (~55 pt), with 12 points of gaps: about 262 points of content laid across a
        // 216-point card. `LumenMenu` has no truncation — a menu that shortened its own
        // title would be lying about what is selected — so the row simply won the layout
        // and drew past the card's edge. That is the "the radial gradient item is bigger
        // than the container it's in" the owner could see and could not name.
        //
        // Folding the two menus into one fixes it honestly rather than by shrinking
        // type: mode and tint are both "how the overlay draws", they are chosen
        // together, and each is a four-to-six entry list that a menu holds better than a
        // row does.
        //
        // AND THE MENU IS 128, NOT 108. `LumenMenu`'s trigger does now truncate — it
        // carries `.lineLimit(1)` on the title — so the row no longer draws past the
        // card's edge, and at 108 it paid for that by cutting the title instead: the
        // trigger spends 16 points on its own padding, 5 on the gap, 4 on the minimum
        // spacer and about 10 on the chevron, leaving 73 for a word, and "Image on Black"
        // and "Colour Overlay" both measure past 77 at `lumenBody`. A menu that shortens
        // its own title is lying about what is selected, which is the exact reason this
        // row was rebuilt in the first place. The card's content is 244 points wide and
        // the toggle beside it needs about 65, so the 20 points cost nothing.
        return HStack(spacing: 6) {
            Button {
                // Through the pin in both directions. The raw `soloMaskOverlay`
                // write this used to carry is the same one that made "Keep it
                // hidden" a trap: a solo cleared without its pin leaves every
                // ambient path guarded off.
                if showing { state.unpinMaskOverlay() } else { state.pinMaskOverlay(mask.id) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showing ? "eye.fill" : "eye")
                        .font(.lumenGlyphCaption)
                    Text("Overlay").font(.lumenCaption)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(showing ? Lumen.fillColor.opacity(0.35) : Lumen.controlSurface)
                .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(showing ? Lumen.primaryText : Lumen.secondaryText)
            .lumenClickCursor()
            .help("Keep this mask's overlay up. O does the same from the keyboard.")

            // NO GLYPHS ON THE TINTS, and they are why the rule exists. The four
            // colours are the one list in this panel whose meaning IS a colour, and
            // `LumenMenuItem` draws its glyph in `secondaryText` like every other piece
            // of chrome in the app — four identical grey circles labelled Red, Green,
            // White and Black would be a worse row than no circle at all. The modes have
            // no honest shape either: "Image on Black" is a compositing rule, not an
            // object.
            LumenMenu(title: state.maskOverlayMode.label,
                      help: "How the overlay draws, and in what colour. "
                          + "⌥O cycles the six modes, ⇧O the four colours.") {
                LumenMenuHeader(title: "How it draws")
                ForEach(MaskOverlay.Mode.allCases, id: \.self) { m in
                    LumenMenuItem(title: m.label,
                                  isSelected: state.maskOverlayMode == m) {
                        state.maskOverlayMode = m
                    }
                }
                LumenMenuHeader(title: "Colour")
                ForEach(MaskOverlay.Tint.allCases, id: \.self) { t in
                    LumenMenuItem(title: t.label,
                                  isSelected: state.maskOverlayTint == t) {
                        state.maskOverlayTint = t
                    }
                }
            }
            .frame(maxWidth: MaskPanel.overlayMenuWidth)
        }
        .frame(height: Lumen.rowHeight)
        .padding(.horizontal, 4)
    }

    // MARK: - Component stack

    /// The selected mask's parts, indented under it, and the two verbs that add more.
    ///
    /// Indented on the LEFT with a smaller thumbnail right-aligned to the same edge as
    /// the mask's, which is Lightroom's exact arrangement: the eye reads one column of
    /// pictures down the list, and indentation alone says which belong to which.
    ///
    /// Add and Subtract sit INSIDE the list, under the parts they extend — attached to
    /// the thing they modify rather than parked at the panel's edge. Holding ⌥ turns
    /// them into one Intersect button, which is also how Lightroom spells it, and it
    /// costs no permanent row.
    @ViewBuilder
    private func componentRows(_ mask: Mask) -> some View {
        // ONE INDENT FOR THE WHOLE BLOCK, applied by `maskDetail` above rather than
        // three times here at three different call sites. The rows, the Add/Subtract
        // pair and the editor each carried their own `.padding(.leading, 14)`, so
        // anything that moved one of them moved one left edge out of three.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(mask.components.indices), id: \.self) { i in
                componentRow(mask, i)
            }
            // ONE READ OF THE MODIFIER PER EVALUATION, and the button cannot lie about
            // what it is going to do.
            //
            // `intersecting` is a synchronous poll of `NSEvent.modifierFlags`. It used to
            // be read three times here — once to title the button, once to decide whether
            // Subtract exists, and once again INSIDE the action closure, at press time —
            // so releasing ⌥ between the draw and the click gave you a button reading
            // "Intersect" that added an Add, and holding it gave you the reverse (audit
            // F4-03). Bound once, the title and the operation are the same answer by
            // construction; `opFor` and `opLabel` are the two spellings of that one
            // value and they cannot come apart.
            //
            // THE OTHER HALF IS NOT FIXED HERE. Nothing invalidates this view when a
            // modifier changes — there is no `flagsChanged` monitor in the app — so the
            // label can still be STALE until something else re-bodies the panel. That
            // needs a published flag on `AppState`, fed by one monitor beside `Keymap`'s.
            // What this closes is the disagreement; what is left is the delay.
            let modifiesToIntersect = intersecting
            HStack(spacing: 4) {
                kindMenu(label: MaskPanel.opLabel(intersecting: modifiesToIntersect),
                         isOpen: pickerBinding($componentPickerOpen, mask.id),
                         offersReference: masks.count > 1) { kind in
                    addComponent(kind: kind, to: mask.id,
                                 op: MaskPanel.opFor(intersecting: modifiesToIntersect))
                }
                if !modifiesToIntersect {
                    kindMenu(label: "Subtract",
                             isOpen: pickerBinding($subtractPickerOpen, mask.id),
                             offersReference: masks.count > 1) { kind in
                        addComponent(kind: kind, to: mask.id, op: .subtract)
                    }
                }
            }
            if let i = componentIndex(for: mask), mask.components.indices.contains(i) {
                componentEditor(mask.id, i, mask.components[i])
            }
        }
    }

    /// Whether ⌥ is down, which turns Add and Subtract into a single Intersect.
    private var intersecting: Bool { MaskCanvas.optionHeld() }


    private func componentRow(_ mask: Mask, _ index: Int) -> some View {
        let component = mask.components[index]
        let isSelected = index == componentIndex(for: mask)
        // THE NAME FIRST, and the operation as a badge behind it rather than a symbol
        // in front of it. `∪` in a 12 pt box, five points from the word, in the same
        // grey, fused with it: the owner read the row as one word, "Ubrush", and asked
        // what it was. A badge cannot fuse — it carries its own fill and its own edge.
        //
        // A leading Add draws nothing at all. Every stack starts by selecting
        // something, so the first `∪` was pure ceremony; what a photographer needs to
        // see at a glance is the row that SUBTRACTS.
        //
        // `.lumenBody` rather than `.system(size: 11)`: 11 pt appeared nowhere else in
        // the panel — one point off the caption above it and the labels below it, which
        // is the jitter `LumenType` was written to end.
        return HStack(spacing: 5) {
            Text(MaskPanel.kindName(component.kind)).font(.lumenBody).lineLimit(1)
                .foregroundStyle(isSelected ? Lumen.primaryText : Lumen.secondaryText)
            if index > 0 || component.op != .add {
                LumenBadge(text: MaskPanel.opName(component.op))
            }
            if component.invert { LumenBadge(text: "Inverted") }
            Spacer(minLength: 0)
            if component.validationError() != nil {
                LumenBadge(text: "INCOMPLETE", emphasized: true)
            }
            // ITS OWN MENU, the same shape as the mask row's one level up — because
            // it is the same question being asked one level down, and because the
            // chevron pair plus the remove button were 37 points of permanent chrome on
            // a row that is already indented and already carries up to two badges.
            //
            // ORDER IS AN ARGUMENT HERE, not a preference. `MaskRaster.combine` folds
            // the stack top-down into an accumulator that seeds empty, so Subject
            // ∪ then Sky ∖ is a different selection from Sky ∖ then Subject ∪ — the
            // second one subtracts from nothing and then adds everything back. The
            // panel let you set the operation and never let you move the row, so half
            // of what the fold can express was unreachable.
            LumenMenu(title: "", symbol: "ellipsis", iconOnly: true,
                      help: "Reorder or remove this part of the mask") {
                if index > 0 || index < mask.components.count - 1 {
                    LumenMenuHeader(title: "Order")
                    if index > 0 {
                        LumenMenuItem(title: "Move up", symbol: "chevron.up") {
                            moveComponent(mask.id, from: index, by: -1)
                        }
                    }
                    if index < mask.components.count - 1 {
                        LumenMenuItem(title: "Move down", symbol: "chevron.down") {
                            moveComponent(mask.id, from: index, by: 1)
                        }
                    }
                }
                LumenMenuItem(title: "Remove", symbol: "minus.circle") {
                    removeComponent(mask.id, index)
                }
            }
        }
        .padding(.horizontal, 4).frame(height: Lumen.rowHeight)
        .background(isSelected ? Lumen.fillColor.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip))
        .contentShape(Rectangle())
        // SELECTS THE MASK TOO. Tapping a part of a mask is a statement about which
        // mask you are working on, and without the first line this row moved the
        // selected mask's index while appearing to move this one's.
        .onTapGesture {
            selectedMaskID = mask.id
            selectedComponent = index
        }
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
                        range: 0...100, defaultValue: 100, step: 1, decimals: 0, bipolar: false,
                        help: "How much of THIS piece counts toward the selection, "
                            + "before it folds into the ones above it. Strength, down "
                            + "in Effect, scales the adjustment instead.")
            componentParameters(id, i, c)
            if c.validationError() != nil, !MaskPanel.saysItsOwnProblem(c.kind) {
                // A component that renders nothing must say so unprompted — unless its
                // own editor already does, in the photographer's words rather than the
                // wire format's.
                //
                // IT USED TO PRINT `validationError()` VERBATIM, and that string is a
                // wire-format diagnostic: `makeComponent` deliberately leaves
                // `strokesRef` nil, so every brush mask greeted its owner with
                // "brush component missing strokesRef — it renders empty until that is
                // supplied." The doc comment on `saysItsOwnProblem` diagnosed exactly
                // this — "fine when the only way to see it was to hand-edit a sidecar" —
                // and then routed it to the panel for seven kinds out of eleven.
                note(MaskPanel.unfinishedNote(c.kind))
            }
        }
        .padding(.leading, 6).padding(.bottom, 4)
    }

    @ViewBuilder
    private func componentParameters(_ id: String, _ i: Int, _ c: MaskComponent) -> some View {
        switch c.kind {
        case .brush:
            // NOTHING, and that is still the fix. `maskDetail` draws the brush
            // settings under their own heading when a brush component is selected —
            // which is exactly when this case is reached — so drawing them here too put
            // the same seven controls on screen TWICE, bound to the same
            // `MaskBrushStore` and moving together. The heading is the right home:
            // they are the settings the NEXT stroke records, not this component's, and
            // only the caption up there says so.
            //
            // The pairing has to hold in BOTH directions, which is the half that broke:
            // for one round this said "the zone has them" while the zone did not exist,
            // and the controls were simply gone.
            EmptyView()
        case .linear:
            // Live: `lineSummary` is the gradient's current geometry, so this is a
            // readout wearing an instruction, not teaching.
            note(MaskPanel.optionalLineIsSet(c)
                 ? MaskPanel.lineSummary(c)
                     + ". The span between the ends is the feather; there is no other "
                     + "control. ⇧ snaps the angle to 15°."
                 : "Drag on the photograph to draw the gradient. The span between the "
                     + "ends is the feather; ⇧ snaps the angle to 15°.")
        case .similarityLine:
            VStack(alignment: .leading, spacing: 2) {
                note(MaskPanel.optionalLineIsSet(c)
                     ? MaskPanel.lineSummary(c) + "."
                     : "Drag on the photograph to draw the fade.")
                similarityParameters(id, i, c)
            }
        case .radial:
            VStack(alignment: .leading, spacing: 2) {
                // BOTH SLIDERS ARE NOW THE SECOND WAY TO DO THIS, and they stay for the
                // same reason a numeric field stays beside a colour picker: a slider is
                // how you type 45° exactly, and the handle is how you find it. The
                // handle came first because "sliders are slow — I have to read it, press
                // it, slowly move side to side" is a description of the tool getting in
                // the way of the picture.
                optionalSlider(id, i, "Feather", \.feather, 0...100, 50,
                               behaviour: .softenEdge)
                // ±90, not ±180: an axis-aligned ellipse has rotational period 180°
                // (`MaskRaster.radialPlane`), so half the old track duplicated the other
                // half — two thumb positions 180° apart rasterized the same mask.
                optionalSlider(id, i, "Rotation", \.rotation, -90...90, 0, bipolar: true)
                note(MaskPanel.ellipseHint(c))
            }
        case .lumaRange:
            VStack(alignment: .leading, spacing: 2) {
                channelRow(id, i, c)
                // From / To, not Band Lo / Band Hi. Both are EV on the fixed −10…+4
                // axis over the CHANNEL above, never auto-ranged, so a band means the
                // same thing on every frame and keeps meaning it when the channel
                // changes under it — which is why every channel is on one axis.
                bandSlider(id, i, "From", isLow: true, depth: false)
                bandSlider(id, i, "To", isLow: false, depth: false)
                optionalSlider(id, i, "Smoothness", \.smooth, 0...100, 50,
                               behaviour: .smoothness)
            }
        case .polygon:
            VStack(alignment: .leading, spacing: 2) {
                optionalSlider(id, i, "Feather", \.feather, 0...100, 0,
                               behaviour: .softenEdge)
                note(MaskPanel.outlineHint(c))
            }
        case .luminosity:
            VStack(alignment: .leading, spacing: 2) {
                channelRow(id, i, c)
                seriesRow(id, i, c)
                // The generator, and there is only one of it. Lumenzia's whole purpose
                // is baking fifteen of these into a Photoshop document; here the level
                // is a slider, so there is nothing to generate and nothing lands in the
                // mask list that the photographer did not ask for.
                optionalSlider(id, i, "Level", \.level,
                               MaskRaster.luminosityMinLevel...MaskRaster.luminosityMaxLevel,
                               1, step: 0.1, decimals: 1,
                               behaviour: .luminositySeries(c.series ?? .lights))
            }
        // Still editable, no longer offerable. Nothing PRODUCES a depth plane — no depth
        // estimator, no reader for an embedded one — so the kind left `rangeKinds` and
        // the paragraph apologising for it left with the menu entry.
        //
        // THE PLUMBING IS COMPLETE AND ONLY THE PRODUCER IS MISSING, which is the useful
        // fact and the opposite of what this comment used to assert. It said "`aiMattes`
        // is a literal empty dictionary at both call sites", and it is not: the renderer
        // passes `mattes[source.url]?.planes ?? [:]` at five sites, and `depthRangePlane`
        // already reads the `depthRange`/`depth` keys out of it. A maintainer reading the
        // old sentence would conclude depth could not arrive even if a plane existed
        // (audit F5-10). A recipe made elsewhere can still carry one of these, and when
        // it does `modelNote` marks it inert in the same badge as every other kind that
        // needs a model this application has not got.
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
                    .font(.lumenCaption)
                    .foregroundStyle(.secondary)
                modelNote(c)
            }
        case .maskRef:
            referenceRow(id, i, c)
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
                        bipolar: false,
                        behaviour: .size,
                        behaviourValue: (brush.size - 0.002) / 0.498,
                        help: "How wide the brush is, as a fraction of the long edge — "
                            + "so it keeps its width at export size. [ and ] on the "
                            + "photograph, where the cursor ring already shows it.")
            LumenSlider(title: "Feather", value: brushValue(\.feather), range: 0...100,
                        defaultValue: 50, step: 1, decimals: 0, bipolar: false,
                        behaviour: .stampFalloff, behaviourValue: brush.feather / 100,
                        help: "How soft the brush's own edge is. At 0 the stamp has a "
                            + "hard rim; at 100 it fades from the centre out. ⇧[ and ⇧] "
                            + "on the photograph — it is the cursor's inner ring.")
            LumenSlider(title: "Flow", value: brushValue(\.flow), range: 1...100,
                        defaultValue: 100, step: 1, decimals: 0, bipolar: false,
                        behaviour: .flow, behaviourValue: brush.flow / 100,
                        help: "How much each pass lays down. Low Flow builds the "
                            + "selection up gradually, so you can paint over the same "
                            + "place twice to deepen it. The digit keys set it.")
            LumenSlider(title: "Max strength", value: brushValue(\.density), range: 0...100,
                        defaultValue: 100, step: 1, decimals: 0, bipolar: false,
                        behaviour: .densityCeiling, behaviourValue: brush.density / 100,
                        help: "The ceiling repeated passes build toward. At 60 the "
                            + "brush can never select more than 60% however long you "
                            + "paint — Flow is the rate, this is the limit.")
            // Last of the five, because it is the only one that changes how the tool
            // FOLLOWS rather than what it lays down — and the only one a photographer
            // sets once and forgets.
            LumenSlider(title: "Steadiness", value: brushValue(\.stabilize),
                        range: 0...100, defaultValue: 0, step: 1, decimals: 0,
                        bipolar: false,
                        help: "Pulls the brush along behind the pointer on a short "
                            + "rope, so a slow hand draws a smooth line. It never "
                            + "leaves the path you drew, and the stroke ends where you "
                            + "let go.")
            LumenToggleRow(title: "Eraser", isOn: brushFlag(\.erase),
                           help: "Erase strokes fold into the same buffer in draw order")
            LumenToggleRow(title: "Stay inside edges", isOn: brushFlag(\.automask),
                           help: "Gates each stamp by colour similarity to the stamp centre")
        }
    }

    /// Which mask this component folds in.
    ///
    /// The list excludes THIS mask, because a mask that references itself has no fixed
    /// point to be right about — the engine refuses the cycle and selects nothing, and
    /// a picker that can only produce that is a picker offering a mistake.
    ///
    /// What it takes is the other mask's FINISHED alpha: its fold, its invert, its whole
    /// refinement chain. Live, so softening the Sky mask's edge softens every
    /// intersection built on it. Not its Amount — that scales the other mask's
    /// adjustments, which are none of this one's business.
    private func referenceRow(_ id: String, _ i: Int, _ c: MaskComponent) -> some View {
        let others = masks.filter { $0.id != id }
        let target = others.first { $0.id == c.maskRef }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Points at")
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.secondaryText)
                Spacer(minLength: 0)
                LumenMenu(title: target.map { MaskPanel.displayName($0, in: masks) }
                              ?? "Choose a mask",
                          help: "This component selects whatever that mask selects, "
                              + "and follows it when it changes") {
                    ForEach(Array(others.indices), id: \.self) { index in
                        LumenMenuItem(title: MaskPanel.displayName(others[index], in: masks),
                                      isSelected: others[index].id == c.maskRef) {
                            let chosen = others[index].id
                            editComponent(id, i, key: nil) { $0.maskRef = chosen }
                        }
                    }
                }
            }
            .frame(height: Lumen.rowHeight)
        }
    }

    /// A mask's name as a menu should say it — its own name, or its position when it has
    /// none, so an unnamed mask is still distinguishable from the other unnamed ones.
    static func displayName(_ mask: Mask, in list: [Mask]) -> String {
        if !mask.name.isEmpty { return mask.name }
        let index = list.firstIndex { $0.id == mask.id }.map { $0 + 1 } ?? 0
        return "Mask \(index)"
    }

    /// Which signal the band measures.
    ///
    /// The Photoshop luminosity-mask tradition is channel-based, and no raw editor
    /// exposes the channels natively (docs/36 §3, bet 2). Red separates skin and sunset
    /// cloud a luma band cannot; Darkest channel finds where EVERY channel is down,
    /// which is the mask for lifting a shadow without pulling its colour cast with it.
    private func channelRow(_ id: String, _ i: Int, _ c: MaskComponent) -> some View {
        let channel = c.channel ?? .luma
        return HStack(spacing: 6) {
            Text("Measures")
                .font(.lumenBody)
                .foregroundStyle(Lumen.secondaryText)
            Spacer(minLength: 0)
            LumenMenu(title: channel.label,
                      help: "Every channel reads the same −10…+4 EV axis, so the band "
                          + "keeps its meaning when you change what it measures") {
                ForEach(MaskChannel.allCases, id: \.self) { option in
                    LumenMenuItem(title: option.label, isSelected: channel == option) {
                        editComponent(id, i, key: nil) { $0.channel = option }
                    }
                }
            }
        }
        .frame(height: Lumen.rowHeight)
    }

    /// Which end of the tone scale. Three segments rather than a menu, because there
    /// are exactly three and they are the thing the photographer is choosing between —
    /// a menu would hide two of the three answers behind the one already picked.
    private func seriesRow(_ id: String, _ i: Int, _ c: MaskComponent) -> some View {
        let series = c.series ?? .lights
        return HStack(spacing: 6) {
            Text("Selects")
                .font(.lumenBody)
                .foregroundStyle(Lumen.secondaryText)
            Spacer(minLength: 8)
            LumenSegmented(
                options: LuminositySeries.allCases.map {
                    (value: $0, label: $0.label)
                },
                selection: Binding(get: { series },
                                   set: { option in
                                       editComponent(id, i, key: nil) { $0.series = option }
                                   }))
                .frame(maxWidth: 190)
        }
        .frame(height: Lumen.rowHeight)
    }

    /// Both sliders are the width of the OKLab similarity gate, one across chroma and
    /// one across lightness — "Chroma sel." and "Luma sel." were the axes of the gate
    /// wearing the abbreviations of a debug build. Point positions and radius have no
    /// field in the shipped format, so the gate evaluates over the whole frame; that was
    /// a paragraph in the panel and is a fact about the format, which is here.
    private func similarityParameters(_ id: String, _ i: Int,
                                      _ c: MaskComponent) -> some View {
        let points = c.points ?? []
        return VStack(alignment: .leading, spacing: 2) {
            sampleChips(id, i, c)
            // The spatial half, which used to have no controls because it had no
            // fields. Reach is one slider over every point of this component rather
            // than one per point: the format stores a radius each, so per-point reach
            // is a later canvas gesture, and a slider per point would be eight sliders
            // for a control most people set once.
            if !points.isEmpty {
                LumenSlider(title: "Reach",
                            value: Binding(
                                get: { (component(id, i)?.points?.first?.count ?? 0) >= 3
                                        ? (component(id, i)!.points![0][2] * 100) : 15 },
                                set: { v in
                                    editComponent(id, i, key: "mask.reach.\(id).\(i)") { c in
                                        let r = Num.clamp(v, 1, 100) / 100
                                        c.points = (c.points ?? []).map { p in
                                            var q = p
                                            if q.count >= 3 { q[2] = r }
                                            return q
                                        }
                                    }
                                }),
                            range: 1...100, defaultValue: 15, step: 1, decimals: 0,
                            bipolar: false)
                pointSigns(id, i, points)
            }
            optionalSlider(id, i, "Colour tolerance", \.chromaSel, 0...100, 50)
            optionalSlider(id, i, "Brightness tolerance", \.lumaSel, 0...100, 50)
        }
    }

    /// One ± per point, aligned under the sample chips they belong to.
    ///
    /// A negative point carves its own area back out of the selection — the half of
    /// U-Point that makes "the sky, but not the sun" one more click rather than a
    /// second mask. The control is a toggle on the point rather than a mode on the
    /// eyedropper, because a mode you have to be in before you click is a mode you
    /// discover by getting it wrong.
    private func pointSigns(_ id: String, _ i: Int, _ points: [[Double]]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(points.indices), id: \.self) { index in
                let negative = points[index].count >= 4 && points[index][3] < 0
                Button {
                    editComponent(id, i, key: nil) { c in
                        guard var list = c.points, list.indices.contains(index),
                              list[index].count >= 3 else { return }
                        while list[index].count < 4 { list[index].append(1) }
                        list[index][3] = list[index][3] < 0 ? 1 : -1
                        c.points = list
                    }
                } label: {
                    Image(systemName: negative ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.lumenGlyphRow)
                        .foregroundStyle(negative ? Lumen.secondaryText : Lumen.primaryText)
                        .frame(width: 20, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lumenClickCursor()
                .help(negative ? "This point takes its area back out of the selection"
                               : "This point adds its area to the selection")
            }
            Spacer(minLength: 0)
        }
        .frame(height: Lumen.rowHeight)
    }

    private func sampleChips(_ id: String, _ i: Int, _ c: MaskComponent) -> some View {
        let samples = c.samples ?? []
        return HStack(spacing: 4) {
            ForEach(Array(samples.indices), id: \.self) { s in
                RoundedRectangle(cornerRadius: Lumen.swatchRadius(14)).fill(MaskPanel.chipColor(samples[s]))
                    .frame(width: 20, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: Lumen.swatchRadius(14))
                        .strokeBorder(Lumen.separator, lineWidth: 0.5))
            }
            Spacer(minLength: 0)
            // Both carry all three channels of "off": the fill drops, the press is
            // blocked, and the pointing hand is withheld. The colour used to fall only to
            // `secondaryText`, which is the same step a hovered control takes, so a full
            // sample list read as an ordinary button that had stopped working.
            Button { addSample(id, i) } label: {
                Image(systemName: "plus").font(.lumenGlyphCaptionStrong)
            }
            .buttonStyle(.plain).disabled(samples.count >= MaskPanel.maxSwatches)
            .foregroundStyle(samples.count < MaskPanel.maxSwatches
                             ? Lumen.primaryText : Lumen.tertiaryText)
            .lumenClickCursor(samples.count < MaskPanel.maxSwatches)
            .help("Add a sample (up to \(MaskPanel.maxSwatches)); the eyedropper lands "
                  + "with the sampler")
            Button { removeSample(id, i) } label: {
                Image(systemName: "minus").font(.lumenGlyphCaptionStrong)
            }
            .buttonStyle(.plain).disabled(samples.count <= 1)
            .foregroundStyle(samples.count > 1 ? Lumen.primaryText : Lumen.tertiaryText)
            .lumenClickCursor(samples.count > 1)
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
                .font(.lumenCaption).foregroundStyle(Lumen.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Refinement chain

    private func refineSection(_ mask: Mask) -> some View {
        // NO HEADER OF ITS OWN. `maskDetail` prints "Edge" and carries the modified dot
        // and the Reset — this drew all four a second time, one row below, at a smaller
        // size. "Edge", not "Refine", is still the right word and the reason still
        // holds: the old name was the same word as the first slider inside it AND as a
        // Colour Range control further up.
        //
        // NO SECOND DISCLOSURE EITHER. It used to guard itself on `refineExpanded`, a
        // chevron carried by the zone wrapper in the develop column. That wrapper is
        // gone and the mask's own chevron is now the one control that decides whether
        // any of this is on screen — a disclosure inside a disclosure is the "box inside
        // of a box inside of a box" the panel keeps being told about.
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
            refineSlider(mask.id, "Follow", \.feather, 0...100, 0,
                         help: "Bends the selection toward edges it can find in "
                             + "the photograph itself. Does nothing where there "
                             + "is no edge under the boundary.",
                         behaviour: .followEdges,
                         behaviourValue: mask.refine.feather / 100)
            // "Expand", not "Expand / Contract". Seventeen characters could not
            // fit the label column at any panel width, and a name that arrives
            // as "Expa…" has told you less than no name at all. The track is
            // bipolar with a centre detent and the glyph draws both directions,
            // so the negative half needs no second word in the label — it needs
            // the sentence underneath, which is what the tooltip is for.
            refineSlider(mask.id, "Expand", \.edge, -50...50, 0,
                         bipolar: true,
                         help: "Moves the boundary outward, or inward below "
                             + "zero. About one percent of the long edge at "
                             + "either end.",
                         behaviour: .expandContract,
                         behaviourValue: mask.refine.edge / 50)
            // "Soften", not "Feather": this is a Gaussian blur of the FINISHED
            // alpha, and the brush's Feather is the hardness of one stamp. Two
            // controls, nine rows apart, that were the same word.
            //
            // AND ONE WORD, not two. Shrinking the behaviour glyph from 44 to 26
            // bought the label column back to 56 points, and that was still not
            // enough: "Follow edges" and "Soften edge" measure past 60 at 12 pt
            // even at the 0.86 shrink floor, so both still arrived as "Follow
            // ed…" and "Soften e…" — which the owner photographed. A name that
            // ellipsizes has told you less than no name. Follow / Expand /
            // Soften is a parallel trio that fits, and the sentence each one
            // needs is in its tooltip, where it costs no width at all.
            refineSlider(mask.id, "Soften", \.blur, 0...100, 0,
                         help: "Blurs the finished selection, so the adjustment "
                             + "fades in across a wider band. Not the brush's "
                             + "Feather, which is the hardness of one stamp.",
                         behaviour: .softenEdge,
                         behaviourValue: mask.refine.blur / 100)
            // The density ramp. "Curve" was its old name and it sat directly
            // above a section called Curve, which is the collision that could
            // not be defended; "Start"/"End" were a 1994 histogram dialog.
            levelsSlider(mask.id, "Ramp from", low: true)
            levelsSlider(mask.id, "Ramp to", low: false)
            refineSlider(mask.id, "Ramp shape", \.levelsGamma, 0.2...5, 1,
                         step: 0.05, decimals: 2, bipolar: true,
                         help: "Bends the fade between Ramp from and Ramp to. "
                             + "Below 1 the selection comes up early and eases "
                             + "in; above 1 it holds back and arrives late.")
        }
    }

    // MARK: - Local adjustments

    /// The overlay gets out of the way while an adjustment is being dragged.
    ///
    /// It is a red wash over the exact pixels being judged, which is the one moment it
    /// is an obstruction rather than information — Lightroom's rule, and it is right.
    /// `setMaskOverlaySuppressed` existed for a while as dead code, which is a worse
    /// state than not having written it: a reader would have believed the behaviour
    /// shipped.
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
            LumenSectionHeader(title: "Light", isExpanded: $lightExpanded,
                               isModified: mask.adjust.isModified(.light),
                               onReset: { editMask(mask.id, key: nil) {
                                   $0.adjust.reset(.light)
                               } })
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
            LumenSectionHeader(title: "Colour", isExpanded: $colourExpanded,
                               isModified: mask.adjust.isModified(.colour),
                               onReset: { editMask(mask.id, key: nil) {
                                   $0.adjust.reset(.colour)
                               } })
            if colourExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    whiteBalanceRows(mask)
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
                                RoundedRectangle(cornerRadius: Lumen.swatchRadius(14))
                                    .fill(MaskPanel.chipColor(swatches[s].sample))
                                    .frame(width: 20, height: 14)
                                    .overlay(RoundedRectangle(cornerRadius: Lumen.swatchRadius(14))
                                        .strokeBorder(s == index ? Lumen.primaryText : Lumen.separator,
                                                      lineWidth: s == index ? 1.5 : 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                        // The same ceiling `addSwatch` enforces and the same floor
                        // `removeSwatch` does, said on the control instead of inside it.
                        smallButton("Add", "plus",
                                    enabled: swatches.count < MaskPanel.maxSwatches) {
                            addSwatch(mask.id)
                        }
                        smallButton("Remove", "minus", enabled: !swatches.isEmpty) {
                            removeSwatch(mask.id)
                        }
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
            LumenSectionHeader(title: "Presence & Detail", isExpanded: $detailExpanded,
                               isModified: mask.adjust.isModified(.detail),
                               onReset: { editMask(mask.id, key: nil) {
                                   $0.adjust.reset(.detail)
                               } })
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
        // AND IT STAYS UP UNTIL THE FIRST ADJUSTMENT, rather than flashing for 1400 ms.
        //
        // The flash was written because the first second of a mask used to show nothing
        // at all (docs/35 §2.3), and for a brush, a gradient, a radial or an outline it
        // fixed nothing: an undrawn mask's alpha is zero, and a zero-alpha colour
        // overlay composites to the photograph unchanged. So the four kinds you DRAW
        // got a flash of the picture, and then painting did not raise the overlay
        // either — a brush mask could reach a finished adjustment without the red ever
        // being visible for one frame, which is what the owner reported.
        //
        // Persistent, it costs nothing while the mask is empty and appears with the
        // first stroke, which is the moment it means something. `O` still overrides.
        state.beginPersistentMaskOverlay(id)
        armIfItNeedsAColour(kind: kind, maskID: id, component: 0)
    }

    /// `op` is chosen at creation now, because the button you pressed already said it.
    ///
    /// It used to hardcode `.add` and leave you to find the segmented control lower down
    /// and change it — which is what made Subtract feel like two steps. Intersect is
    /// stored as its own op here; Lightroom spells the same thing as a subtract component
    /// with invert set, and either is a faithful encoding of "everything both select".
    private func addComponent(kind: MaskKind, to id: String, op: MaskOp = .add) {
        let component = MaskPanel.makeComponent(kind: kind, op: op)
        editMask(id, key: nil) { m in
            m.components.append(component)
            if MaskPanel.aiKinds.contains(kind), m.refine == MaskRefine() { m.refine.feather = 10 }
        }
        let index = Swift.max((mask(id)?.components.count ?? 1) - 1, 0)
        selectedComponent = index
        armIfItNeedsAColour(kind: kind, maskID: id, component: index)
    }

    /// A kind whose whole input is a colour arms the eyedropper the moment it is made.
    ///
    /// Choosing "Colour Pick" and then having to find a second control to say WHICH
    /// colour is a step that exists only because the roster and the sampler are two
    /// different surfaces. The component is born carrying a placeholder grey so it is
    /// valid; arming here means the next click on the photograph replaces it, which is
    /// what the person who chose this kind was about to do anyway.
    private func armIfItNeedsAColour(kind: MaskKind, maskID: String, component: Int) {
        switch kind {
        case .colorRange, .similarity, .similarityLine:
            state.beginPick(.maskSample(maskID: maskID, component: component))
        default:
            break
        }
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

    /// Move a mask one place, WITHIN ITS FOLDER.
    ///
    /// Masks fold in list order — both renderers walk `plan.masks` front to back — so
    /// the reorder has to happen in the flat array however the list is drawn. But a flat
    /// swap is wrong now that folders exist: the neighbour in the array is very often in
    /// a different group, so pressing "move down" inside a folder would either appear to
    /// do nothing (the two rows are not adjacent on screen) or shuffle two folders'
    /// contents past each other. Both read as the button being broken.
    ///
    /// So the neighbour is found among the masks that share this one's group, and THEN
    /// swapped in the array. Order across the whole list still means what it always
    /// meant; what changed is which pair the arrow picks.
    private func moveMask(_ id: String, by delta: Int) {
        state.updateRecipe(coalescingKey: nil) { recipe in
            guard let i = recipe.masks.firstIndex(where: { $0.id == id }) else { return }
            let group = recipe.masks[i].group
            let siblings = recipe.masks.indices.filter { recipe.masks[$0].group == group }
            guard let here = siblings.firstIndex(of: i) else { return }
            let next = here + delta
            guard siblings.indices.contains(next) else { return }
            recipe.masks.swapAt(i, siblings[next])
        }
    }

    /// Whether this mask has a neighbour to swap with inside its own folder — which is
    /// what the arrows must be enabled on, or they offer a move that does nothing.
    static func reorderRoom(_ masks: [Mask], _ index: Int) -> (up: Bool, down: Bool) {
        guard masks.indices.contains(index) else { return (false, false) }
        let group = masks[index].group
        let siblings = masks.indices.filter { masks[$0].group == group }
        guard let here = siblings.firstIndex(of: index) else { return (false, false) }
        return (here > 0, here < siblings.count - 1)
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
            // Points pair with samples BY INDEX, so a sample removed without its point
            // would leave the next sample wearing the previous one's geometry.
            if var points = c.points, points.count >= list.count + 1 {
                points.removeLast()
                c.points = points.isEmpty ? nil : points
            }
        }
    }

    /// `inverting` is LrC's Duplicate-and-Invert, which docs/08 §8.1 lists and we did
    /// not have: the fastest way to grade "the subject" and "everything else" as a pair
    /// that cannot drift apart, because the second is defined as the first's complement.
    private func duplicateMask(_ id: String, inverting: Bool = false) {
        guard let source = mask(id) else { return }
        var copy = source
        copy.id = UUID().uuidString
        if inverting { copy.invert.toggle() }
        copy.name = source.name.isEmpty
            ? (inverting ? "Inverted" : "Copy")
            : source.name + (inverting ? " inverted" : " copy")
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
        // Through the pin, so deleting the mask whose overlay was pinned does not leave
        // the pin standing over nothing — which would silently disable flash and hover.
        if state.soloMaskOverlay == id { state.unpinMaskOverlay() }
        selectedMaskID = masks.first?.id
        selectedComponent = 0
    }

    /// Arms a pick, like the global swatch row. A swatch born neutral is not an
    /// unconfigured control, it is one that selects nothing — the chordal hue term
    /// against a grey target is identically zero.
    /// How many Point Colour swatches a mask may carry, and how many samples a colour
    /// component may. One number rather than the `8` that was written into `addSwatch`,
    /// `sampleChips` and the two `.disabled` predicates separately — a ceiling enforced
    /// in one place and drawn in another is a ceiling that will disagree with itself.
    static let maxSwatches = 8

    private func addSwatch(_ id: String) {
        guard (mask(id)?.adjust.pointColors.count ?? MaskPanel.maxSwatches)
                < MaskPanel.maxSwatches else { return }
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

    /// WHICH COMPONENT OF *THIS* MASK IS BEING EDITED, or nil when none is.
    ///
    /// `activeComponentIndex` answers for the SELECTED mask, and every child of
    /// `maskDetail` used it regardless of which mask it was drawing — so opening a
    /// second mask's chevron without selecting it showed that mask's list highlighted
    /// at the other mask's index, opened an editor on whatever component happened to
    /// sit there, and decided the Brush section by what the other mask's index landed
    /// on. Worse, tapping a row in the unselected mask moved the SELECTED mask's index,
    /// so the next Contribution drag landed on a mask that was not under the pointer.
    ///
    /// One component is active at a time and it belongs to the selected mask — the
    /// panel's own thesis, "the row selects, the chevron discloses", carried down to the
    /// component level, where it was only ever applied at the top. A disclosed but
    /// unselected mask shows its parts with none highlighted and no editor; tapping one
    /// selects that mask and that component in a single gesture, which is also what
    /// makes the canvas agree, since `MaskCanvas` reads the same selection.
    private func componentIndex(for mask: Mask) -> Int? {
        MaskSelection.activeComponent(maskID: mask.id,
                                      componentCount: mask.components.count,
                                      selectedMaskID: activeMask?.id,
                                      selectedComponent: selectedComponent)
    }

    /// A picker board's open state for one mask.
    private func pickerBinding(_ open: Binding<Set<String>>, _ id: String) -> Binding<Bool> {
        Binding(get: { open.wrappedValue.contains(id) },
                set: { isOpen in
                    if isOpen { open.wrappedValue.insert(id) }
                    else { open.wrappedValue.remove(id) }
                })
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
                                step: Double = 1, decimals: Int = 0,
                                bipolar: Bool = false,
                                behaviour: BehaviourShape? = nil) -> some View {
        let current = component(id, i)?[keyPath: p] ?? d
        return LumenSlider(title: t,
                    value: Binding(get: { component(id, i)?[keyPath: p] ?? d },
                                   set: { v in
                                       editComponent(id, i, key: "mask.c.\(t).\(id).\(i)") {
                                           $0[keyPath: p] = Num.clamp(v, r.lowerBound, r.upperBound)
                                       }
                                   }),
                    range: r, defaultValue: d, step: step, decimals: decimals,
                    bipolar: bipolar,
                    behaviour: behaviour,
                    behaviourValue: (current - r.lowerBound)
                        / Swift.max(r.upperBound - r.lowerBound, 1e-9))
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
                              decimals: Int = 0, bipolar: Bool = false,
                              help: String? = nil,
                              behaviour: BehaviourShape? = nil,
                              behaviourValue: Double = 0) -> some View {
        LumenSlider(title: t,
                    value: maskValue(id, t, get: { $0.refine[keyPath: p] },
                                     set: { $0.refine[keyPath: p] =
                                         Num.clamp($1, r.lowerBound, r.upperBound) }),
                    range: r, defaultValue: d, step: step, decimals: decimals,
                    bipolar: bipolar,
                    behaviour: behaviour, behaviourValue: behaviourValue,
                    help: help)
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
                    bipolar: false,
                    help: low
                        ? "Where the selection starts counting. Raise it and the "
                            + "faintest part of the mask drops out entirely."
                        : "Where the selection counts as full. Lower it and the "
                            + "middle of the mask reaches full strength sooner.")
    }

    // MARK: - White balance, in either of its two units

    /// The neutral the picture is balanced TO — the number an ABSOLUTE mask is a delta
    /// from. Same `?? asShot` rule the Basic panel's own Temp row uses, via the same
    /// function, because a mask that rendered against one resolution while the row
    /// beside it printed another would be unusable in exactly the way the owner
    /// described the old panel being.
    private var balancedNeutral: WhiteBalanceEngine.Neutral {
        let recipe = state.primarySelection.map { state.recipe(for: $0) } ?? Recipe()
        let shown = WhiteBalanceEngine.displayed(
            temp: recipe.develop.raw.temp, tint: recipe.develop.raw.tint,
            asShot: state.primaryAsShotNeutral ?? .reference)
        return WhiteBalanceEngine.Neutral(kelvin: shown.temperature, tint: shown.tint)
    }

    /// ONE control with two units, not two controls.
    ///
    /// Every competitor's local white balance is a relative shift, which is correct
    /// until the global row moves and then silently wrong — a mask built to neutralize a
    /// tungsten window is a fixed nudge, so re-balancing the photograph re-lights the
    /// window too. Kelvin says "this region is lit at 5600 K" and holds.
    ///
    /// The switch seeds from the balanced neutral in both directions, so flipping it
    /// changes no pixel: the first thing a photographer does with a new control is press
    /// it to find out what it is, and a control that jump-cuts the picture on that press
    /// has taught them to distrust it.
    @ViewBuilder
    private func whiteBalanceRows(_ mask: Mask) -> some View {
        let neutral = balancedNeutral
        let absolute = mask.adjust.kelvin != nil
        HStack(spacing: 6) {
            Text("White balance")
                .font(.lumenCaption)
                .foregroundStyle(Lumen.secondaryText)
            Spacer(minLength: 8)
            LumenSegmented(
                options: [(value: false, label: "Shift"), (value: true, label: "Kelvin")],
                selection: Binding(
                    get: { absolute },
                    set: { wantsAbsolute in
                        guard wantsAbsolute != absolute else { return }
                        editMask(mask.id, key: "mask.wb.unit.\(mask.id)") { m in
                            if wantsAbsolute {
                                m.adjust.kelvin = neutral.kelvin
                                m.adjust.kelvinTint = neutral.tint
                            } else {
                                m.adjust.kelvin = nil
                                m.adjust.kelvinTint = nil
                            }
                        }
                    }),
                marked: absolute ? [true] : [])
                .frame(maxWidth: 140)
        }
        .padding(.top, 2)
        if absolute {
            // THE SAME RANGE, THE SAME STEP, AND NOW THE SAME AXIS.
            //
            // This comment used to stop at "the same range and step the global row uses"
            // and claim that giving a mask "a second scale would mean two numbers a
            // photographer has to translate between" — while the call underneath passed
            // no `scale:` at all and therefore took `LumenSlider`'s `.linear` default
            // against `BasicPanel`'s `.reciprocal`. The ranges did match; the axes did
            // not, so the two rows printed the same number and answered the same drag
            // completely differently: 5500 K sat at 7 % of this track and the whole of
            // 2000–10000 K was crushed into its first sixth, while 10000–50000 K — light
            // nobody balances for — took the other five (audit F4-05, K-006(a)).
            //
            // `MaskPanel.temperatureScale` rather than `.reciprocal` written out, because
            // the property that has to hold is not "reciprocal" but "whatever the global
            // row is", and the tracks come with it: the grey stop lands where the mired
            // axis actually puts 5500 K, which is the whole reason `Lumen.temperatureStops`
            // was placed in Kelvin rather than at the track's middle.
            optionalAdjustSlider(mask.id, "Temp", \.kelvin,
                                 ColorTemperature.minKelvin...ColorTemperature.maxKelvin,
                                 neutral.kelvin, step: 10, bipolar: false,
                                 scale: MaskPanel.temperatureScale,
                                 trackStops: Lumen.temperatureStops)
            optionalAdjustSlider(mask.id, "Tint", \.kelvinTint, -150...150, neutral.tint,
                                 step: 1, bipolar: true,
                                 trackStops: Lumen.tintStops)
        } else {
            adjustSlider(mask.id, "Temp", \.temp, -100...100)
            adjustSlider(mask.id, "Tint", \.tint, -100...100)
        }
    }

    /// A slider over an optional field whose nil is not a value but an absence. The
    /// stand-in is the balanced neutral, which is also the `defaultValue` the
    /// double-click reset returns to — so "reset" means "this region is lit like the
    /// rest of the photograph", which is the only reading of it that is true.
    private func optionalAdjustSlider(_ id: String, _ t: String,
                                      _ p: WritableKeyPath<LocalAdjust, Double?>,
                                      _ r: ClosedRange<Double>, _ standIn: Double,
                                      step: Double = 1, decimals: Int = 0,
                                      bipolar: Bool = false,
                                      scale: SliderScale = .linear,
                                      trackStops: [LumenTrackStop]? = nil) -> some View {
        LumenSlider(title: t,
                    value: maskValue(id, "abs." + t,
                                     get: { $0.adjust[keyPath: p] ?? standIn },
                                     set: { $0.adjust[keyPath: p] =
                                         Num.clamp($1, r.lowerBound, r.upperBound) }),
                    range: r, scale: scale, defaultValue: standIn,
                    step: step, decimals: decimals,
                    bipolar: bipolar,
                    trackStops: trackStops)
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
                    // No behaviour glyph: a point colour's Hue, Saturation and
                    // Luminance are magnitudes, and `BehaviourShape`'s roster is
                    // deliberately only parameters whose meaning IS a shape.
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
                          offersReference: Bool = false,
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
                    withAnimation(Lumen.motionFold) { isOpen.wrappedValue.toggle() }
                } label: {
                    // THE MOST-PRESSED CONTROL IN THE PANEL, drawn like it. It was a
                    // 22 pt row of secondary text with an 8 pt chevron — "the add mask
                    // button is super small" — which is the weight of a disclosure
                    // triangle on the one thing every session starts with. It is a real
                    // button now: a control surface, primary text, centred, and tall
                    // enough to hit without aiming.
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Image(systemName: "plus")
                            .font(.lumenGlyphRow)
                        Text(label).font(.lumenBody)
                        Image(systemName: "chevron.down")
                            .font(.lumenGlyphCaptionStrong)
                            .rotationEffect(.degrees(isOpen.wrappedValue ? 180 : 0))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Lumen.primaryText)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Lumen.controlSurface)
                    .lumenWell()
                    .contentShape(Rectangle())
                }
                .padding(.top, 4)
                .buttonStyle(.plain)
                .lumenClickCursor()
                .help("Every kind of selection, on one board")
            }
            if prominent || isOpen.wrappedValue {
                kindBoard({ kind in
                    isOpen.wrappedValue = false
                    action(kind)
                }, offersReference: offersReference)
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
    private func kindBoard(_ action: @escaping (MaskKind) -> Void,
                           offersReference: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            boardGroup("Draw it by hand", MaskPanel.drawnKinds, action)
            boardGroup("Find it by tone or colour", MaskPanel.rangeKinds, action)
            boardGroup("Find it for me", MaskPanel.visionKinds, action)
            // Only where there is something to point AT. A reference offered on a
            // photograph with one mask is a tile that can only make an empty component,
            // which is the shape of offer-and-retraction this panel keeps deleting.
            if offersReference, masks.count > 1 {
                boardGroup("Reuse", [.maskRef], action)
            }
        }
        .padding(.vertical, 2)
    }

    private func boardGroup(_ title: String, _ kinds: [MaskKind],
                            _ action: @escaping (MaskKind) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LumenCapsLabel(text: title, color: Lumen.tertiaryText)
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
                    .font(.lumenGlyphLarge)
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

    /// The tint target, as a swatch that opens the system colour panel.
    ///
    /// `ColorPicker` rather than an eyedropper: sampling FROM the frame is what the
    /// mask's Point Colour swatches already do, and a tint is the opposite job — you are
    /// naming a colour the picture does not contain yet. An eyedropper would also need a
    /// new `PickTarget`, which is a change to state this panel does not own.
    private func tintTargetRow(_ mask: Mask) -> some View {
        HStack(spacing: 6) {
            Text("Colorize to")
                .font(.lumenBody)
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

    /// A DISABLED ONE HAS TO LOOK DISABLED, and these two did not.
    ///
    /// Point Colour's Add and Remove had no `enabled` at all: `addSwatch` returns early
    /// at eight swatches and `removeSwatch` returns early at none, so both buttons drew
    /// at full weight, took the click and did nothing. That is the same defect
    /// `LumenToggleRow` was fixed for — "a row that lights up, offers the click cursor,
    /// and then does nothing… just quieter, because the photographer reads the affordance
    /// rather than the result" — reproduced in a button this file rolled itself.
    ///
    /// All three channels, because `.disabled` on its own only stops the gesture: the
    /// text drops to tertiary, `.disabled` blocks the press, and `lumenClickCursor` is
    /// withheld so the pointer stays an arrow.
    private func smallButton(_ title: String, _ systemImage: String,
                             enabled: Bool = true,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.lumenCaption)
                Text(title).font(.lumenGlyphCaption)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Lumen.primaryText : Lumen.tertiaryText)
        .disabled(!enabled)
        .lumenClickCursor(enabled)
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

    /// THE ONE SIZE A MASK'S PICTURE IS DRAWN AT, in all three places it is drawn.
    ///
    /// `MaskThumbnail` was extracted so that "three copies of a corner radius, a border
    /// and a disabled opacity" could not drift — and the SIZE was left as a literal at
    /// each of the three call sites, so it drifted instead: 44×30 in the list, 44×30 in
    /// the collapsed rail, 40×27 in the develop column's editing strip. The mask picture
    /// beside "which mask am I editing" was a different size from the mask picture in the
    /// list of masks, which is the one comparison a photographer makes with it (F4-04).
    static let thumbnailSize = CGSize(width: 44, height: 30)

    static let drawnKinds: [MaskKind] = [.brush, .linear, .radial, .polygon]

    /// Depth Range is deliberately not in this list, and there is no `modelKinds` list
    /// any more. Between them they named the four kinds the picker can no longer offer:
    /// nothing estimates depth, nothing reads embedded depth, and no Core ML model is
    /// bundled, so all four rasterize to an empty plane. The kinds themselves stay in
    /// `MaskKind` — the wire format carries them and a foreign recipe may hold one —
    /// and their editors still open. What is gone is the offer.
    static let rangeKinds: [MaskKind] = [.lumaRange, .luminosity, .colorRange,
                                         .similarity, .similarityLine]

    /// Still the full roster: this is what decides whether a new mask gets the
    /// edge-aware snap seeded, which is a question about mattes and not about menus.
    static let aiKinds: [MaskKind] = [.aiSubject, .aiSky, .aiBackground, .aiObject,
                                      .aiPerson, .aiLandscape]

    /// What the picker offers, derived from `MaskKind.matteProvider` so a kind cannot
    /// end up in the wrong list. Only Vision's three: they come out of an OS framework
    /// on this Mac with no download and no bundled weights.
    static let visionKinds: [MaskKind] = aiKinds.filter { $0.matteProvider == .vision }

    /// THE KINDS THAT CANNOT BE MADE HERE, derived rather than listed.
    ///
    /// Four of them, and every one is a kind whose matte would have to come from a Core
    /// ML model this application does not bundle: Sky, Object, Landscape and Depth
    /// Range. Each rasterizes to an empty plane, so each is ABSENT from the picker rather
    /// than present-and-disabled — `kindTile` carries no `.disabled` and no greyed row,
    /// because a tile a photographer can see, read and never enable is a promise the app
    /// cannot keep, and it teaches that the app is unfinished rather than that this kind
    /// is not one of its tools.
    ///
    /// Derived from `MaskKind.matteProvider` so the roster cannot go stale in either
    /// direction: the day a sky model lands and that kind's provider becomes `.vision`,
    /// it leaves this list and joins `visionKinds` — the picker gains the tile with no
    /// second edit anywhere. `MaskKind` is not `CaseIterable` (it is a wire format, and
    /// F5-07 owns that), so the candidates are the kinds that could plausibly need one.
    static let unofferedKinds: [MaskKind] =
        (aiKinds + [.depthRange]).filter { $0.matteProvider == .model }

    /// Every kind the picker actually offers, in board order.
    ///
    /// One roster rather than three lists read off `kindBoard`'s three groups, so the
    /// question "what can a photographer reach from here" has an answer that is not a
    /// reading of a view body. `maskRef` is conditional for the reason `kindBoard` gives:
    /// a reference offered on a photograph with one mask can only make an empty
    /// component.
    static func pickerKinds(maskCount: Int) -> [MaskKind] {
        drawnKinds + rangeKinds + visionKinds + (maskCount > 1 ? [.maskRef] : [])
    }

    /// WHICH OPERATION THE ADD BUTTON MAKES, from whether ⌥ is down.
    ///
    /// A function rather than a `?:` written twice, and that is the whole finding
    /// (F4-03): the panel read `intersecting` once to LABEL the button and again, inside
    /// the action closure, to CHOOSE the op — two reads of a synchronous
    /// `NSEvent.modifierFlags` poll at two different moments, with nothing between them
    /// to keep them agreeing. Release ⌥ between the draw and the click and the button
    /// that said "Intersect" added an Add.
    ///
    /// `componentRows` now reads the modifier once per evaluation and passes that one
    /// value through both of these, so the label and the press are the same answer by
    /// construction. The other half — that the label can be STALE, because no
    /// `flagsChanged` monitor invalidates the view — needs a published flag on
    /// `AppState` and is not this file's to fix.
    static func opFor(intersecting: Bool) -> MaskOp { intersecting ? .intersect : .add }

    /// What that button is titled, from the same value, so the two cannot disagree.
    static func opLabel(intersecting: Bool) -> String { opName(opFor(intersecting: intersecting)) }

    /// The mask-level invert's glyph, filled when the selection is inverted.
    ///
    /// A half-filled circle for both states, filled or hollow — the same shape the row
    /// menu's "Invert selection" carries, so the chip on the row and the item in the menu
    /// are visibly one control reached two ways. Named here rather than written into
    /// `maskRow` because it is the thing a test can ask for: whether the row carries an
    /// invert control at all.
    static func invertGlyph(_ inverted: Bool) -> String {
        inverted ? "circle.righthalf.filled" : "circle"
    }

    /// THE AXIS A MASK'S KELVIN ROW IS DRAWN ON, and it is the global row's.
    ///
    /// The comment above `whiteBalanceRows`' Temp slider has claimed since it was written
    /// that it uses "the same range and step the global row uses" — and it passed no
    /// `scale:` at all, so it took `LumenSlider`'s `.linear` default while
    /// `BasicPanel.swift` passes `.reciprocal`. The ranges did match; the axis did not,
    /// and the axis is the entire point of that row. On a linear Kelvin track 5500 K sits
    /// at 7% and everything between 2000 and 10000 K — the whole of what a photographer
    /// uses — is crushed into the first sixth of the travel, while the other five sixths
    /// are 10000–50000 K. Two controls printing the same number answered the same drag
    /// completely differently (audit F4-05, K-006(a)).
    ///
    /// A named constant rather than `.reciprocal` written at the call site, because what
    /// has to hold is not "this row is reciprocal" but "this row is on the same axis as
    /// the global one", and a literal cannot say that.
    static let temperatureScale: SliderScale = .reciprocal

    /// WHETHER DELETING THIS MASK THROWS AWAY SOMETHING THAT WAS MADE BY HAND.
    ///
    /// The gate on the row's delete confirmation, and it is deliberately narrow. Undo
    /// reaches a deleted mask — `AppState.updateRecipe` records every recipe write into
    /// `HistoryStack` — so a confirmation on every mask would be a dialog protecting
    /// something already protected, and the app would have taught the photographer to
    /// dismiss it without reading. What undo does NOT protect against is the deletion
    /// nobody notices: a misclick on the wrong row, twenty edits before anyone looks at
    /// the mask list again.
    ///
    /// So the line is drawn at ONE GESTURE. A radial you drew, a gradient you dragged, a
    /// single colour you picked — each is one movement to make again, and stopping to
    /// confirm those would cost more than losing them. Painted strokes, a traced outline,
    /// a stack of several parts, several sampled colours, or any adjustment dialled into
    /// the mask are minutes of work that cannot be reproduced by repeating a gesture, and
    /// those are what the confirmation is for.
    static func deletionLosesWork(_ mask: Mask) -> Bool {
        // A stack is a decision about how several selections fold together, which is not
        // something a hand repeats — and the fold's order is itself part of the work.
        if mask.components.count > 1 { return true }
        if adjustmentsCarryWork(mask) { return true }
        guard let only = mask.components.first else { return false }
        // Strokes are the clearest case in the panel: a painted mask is the only thing
        // here whose input is measured in minutes.
        if only.strokesRef != nil { return true }
        // A closed outline is a corner at a time; three is the fewest it can have.
        if (only.path ?? []).count >= 3 { return true }
        // One sample is one click of the eyedropper. Several is a colour range somebody
        // built up by hand, and the samples are the whole of what it selects.
        if (only.samples ?? []).count > 1 { return true }
        return false
    }

    /// Whether this mask carries a grade — anything under Light, Colour, Presence &
    /// Detail, the local curve, the local wheels or a Point Colour swatch.
    ///
    /// Its own function because `LocalAdjust.isModified` answers per GROUP by design (a
    /// section's dot is a question about that section), and Curve, Grading and Point
    /// Colour are deliberately outside those groups — each is one optional or one array
    /// with its own Reset. "Has this mask been graded at all" is a different question and
    /// it has to name all six.
    static func adjustmentsCarryWork(_ mask: Mask) -> Bool {
        for group in LocalAdjust.Group.allCases where mask.adjust.isModified(group) {
            return true
        }
        return mask.adjust.curve != nil || mask.adjust.wheels != nil
            || !mask.adjust.pointColors.isEmpty
    }

    /// WHERE A DRAGGED MASK LANDS, as a pure rearrangement of the list.
    ///
    /// The rule is the one a photographer can predict without being told: the dragged
    /// mask ends up at the index the mask it was dropped on used to occupy, and
    /// everything else keeps its relative order. Drop A on C and A is where C was; C and
    /// everything between it and A shift one place to make room, in the direction the
    /// drag came from.
    ///
    /// IT ALSO ADOPTS THE TARGET'S FOLDER, and that is not a convenience. The list draws
    /// each group's members together and the loose masks after them (`groupedRows`), so a
    /// mask dropped between two members of a folder that did NOT join the folder would be
    /// drawn somewhere else entirely — the drop would appear to have been refused, or
    /// worse, to have moved it somewhere at random. Reorder is a real operation on the
    /// render (both renderers walk `plan.masks` front to back, so where two masks overlap
    /// the later one works on the earlier one's output), and a real operation that does
    /// not land where it was aimed is worse than none.
    static func reordered(_ masks: [Mask], moving id: String, onto target: String) -> [Mask] {
        guard id != target,
              let from = masks.firstIndex(where: { $0.id == id }),
              let to = masks.firstIndex(where: { $0.id == target }) else { return masks }
        var list = masks
        var moved = list.remove(at: from)
        moved.group = masks[to].group
        // `to` is valid as an insertion index in both directions: dragging down, the
        // removal has already shifted the target to `to - 1`, so inserting at `to` puts
        // the dragged mask just after it and therefore AT the target's old index;
        // dragging up, the target has not moved and inserting at `to` puts it just
        // before. One expression rather than two because the invariant is one sentence.
        list.insert(moved, at: to)
        return list
    }

    static func kindName(_ kind: MaskKind) -> String {
        switch kind {
        case .brush: return "Brush"
        case .linear: return "Linear Gradient"
        case .radial: return "Radial Gradient"
        case .lumaRange: return "Brightness Range"
        case .luminosity: return "Luminosity"
        case .polygon: return "Outline"
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
        case .maskRef: return "Another Mask"
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
        case .luminosity: return "circle.righthalf.filled"
        case .polygon: return "lasso"
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
        case .maskRef: return "square.on.square.dashed"
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
        case .luminosity: return "The bright end, or the dark end, with no edge at all"
        case .polygon: return "Lasso a shape, or click its corners"
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
        case .maskRef: return "Whatever another mask selects, live"
        }
    }

    /// What a mask is called when it has not been named.
    ///
    /// "Brush 1" told you which TOOL made it, which is the least interesting thing about
    /// a mask by the time there are five. A mask made of one component is named for what
    /// that component selects; a stack is named for its first component and its depth.
    static func autoName(_ mask: Mask, index: Int) -> String {
        guard let first = mask.components.first else { return "Mask \(index + 1)" }
        let base = kindName(first.kind)
        return mask.components.count == 1 ? base : "\(base) +\(mask.components.count - 1)"
    }

    /// Whether the stack summary tells you anything the name above it does not.
    ///
    /// Two components or more, always: the summary is the only place the fold is
    /// written. One component, only when the name does not already contain the kind —
    /// so "Brush 1" over "Brush" collapses to one line, and "Roof" over "Brush" keeps
    /// both, because "Roof" alone does not say what tool made it.
    ///
    /// Case-insensitive containment rather than equality: "Sky brush" over "Brush" is
    /// the same redundancy as "Brush 1" over "Brush".
    static func summaryAddsSomething(_ mask: Mask) -> Bool {
        // Nought components summarises as "nothing selected yet", which is the one thing
        // a mask most needs to say. Two or more, the fold is only written here.
        guard mask.components.count == 1, let only = mask.components.first else {
            return true
        }
        // An unfinished component's summary carries ", not drawn yet", which is the one
        // thing the list must be able to say about a mask whose editor is not on screen.
        guard only.validationError() == nil else { return true }
        guard only.op == .add, !only.invert else { return true }
        let name = mask.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        return !name.lowercased().contains(kindName(only.kind).lowercased())
    }

    /// The stack, as one line under the name: `Sky, minus Brush`.
    ///
    /// It used to read `∪ Sky  ∖ Brush`, and the owner reported the result: "I don't
    /// know what Ubrush is." He was reading the screen correctly. U+222A at 10 pt is a
    /// capital U with no crossbar and no serifs, set in the same grey as the word a few
    /// points to its right, so the eye bound them into one token — and in the row's
    /// subtitle, at `.lumenCaption`, `∪ Brush` read as "a Brush".
    ///
    /// Set-theory notation was never the right register for a panel whose whole job is
    /// to be legible at a glance, and it was REDUNDANT besides: the same three values
    /// are spelled Add / Subtract / Intersect in a segmented control two rows below.
    /// Words, and the leading Add is dropped — a stack starts by selecting something,
    /// so "∪ Sky" only ever meant "Sky".
    static func stackSummary(_ mask: Mask) -> String {
        guard !mask.components.isEmpty else { return "nothing selected yet" }
        return mask.components.enumerated()
            .map { index, c in
                var name = kindName(c.kind)
                if c.invert { name += " inverted" }
                // A row you have not selected is a row whose editor you cannot see, so
                // the ONE thing the list has to be able to say about a component is that
                // it selects nothing yet. Without this the subtitle just repeated the
                // kind, which the name above it already carries.
                if c.validationError() != nil { name += ", not drawn yet" }
                guard index > 0 || c.op != .add else { return name }
                return "\(opPhrase(c.op)) \(name)"
            }
            .joined(separator: " ")
    }

    /// How one component joins the one before it, in words a photographer reads rather
    /// than operators a mathematician does.
    static func opPhrase(_ op: MaskOp) -> String {
        switch op {
        case .add: return "plus"
        case .subtract: return "minus"
        case .intersect: return "inside"
        }
    }

    /// The same three, capitalised, for a badge that stands alone on a row.
    static func opName(_ op: MaskOp) -> String {
        switch op {
        case .add: return "Add"
        case .subtract: return "Subtract"
        case .intersect: return "Intersect"
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
            // Unseeded, like the ellipse below and for the same reason: a gradient
            // already lying down the middle of the frame is one you have to move rather
            // than place, and it leaves no clear space for the draw gesture to fire in.
            break
        case .radial:
            // NO ELLIPSE. Being handed a circle in the middle of the frame is the
            // owner's complaint word for word — "I don't want to automatically be given
            // the oval shape" — and it had a second cost that was not obvious: the
            // `.create` gesture only fires on a press with clear space around it, so a
            // shape parked under the pointer meant the draw-it-out gesture that has been
            // in `MaskHandles` all along could never be reached. The first drag on the
            // picture makes it, which is Lightroom's rule and now ours.
            //
            // Feather and rotation are still seeded: they are the shape's SETTINGS, not
            // its geometry, and a nil feather renders as 50 anyway. Writing them here
            // means the canvas never has to invent a value mid-drag.
            c.rotation = 0
            c.feather = 50
        case .lumaRange:
            c.lo = 0
            c.hi = 1
            c.smooth = 50
        case .polygon:
            // Deliberately unseeded. Every other drawn kind can be born somewhere
            // sensible — a gradient down the middle, an ellipse in the centre — because
            // it has a shape before anyone touches it. An outline does not: the only
            // outline that means anything is the one the photographer drew, and a
            // starter triangle in the middle of the frame would be a shape they have to
            // delete before they can begin. `validationError` reads INCOMPLETE until
            // three corners exist, which is what that badge is for, and the canvas says
            // how to make them.
            break
        case .luminosity:
            // Lights 1 is the plain luminance channel: it selects the whole frame,
            // weighted toward the highlights. A new component that selects SOMETHING is
            // the difference between a control you drag to explore and a form you fill
            // in before anything happens.
            c.series = .lights
            c.level = 1
        case .colorRange:
            c.samples = [AppState.placeholderSample]
            c.rangeAmount = 50
        case .similarity, .similarityLine:
            c.samples = [AppState.placeholderSample]
            c.chromaSel = 50
            c.lumaSel = 50
            // No line, for the same reason the plain gradient has none: one lying down
            // the middle of the frame is one you have to move rather than place. The
            // order here is pick a colour, then drag the fade — and `validationError`
            // says which half is still missing at each step.
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
        case .maskRef:
            // Deliberately unseeded. A reference born pointing at an arbitrary other
            // mask would be a component that silently does something nobody asked for;
            // `validationError` reads INCOMPLETE until one is chosen, which is what
            // that badge is for.
            break
        }
        return c
    }

    static func optionalLineIsSet(_ c: MaskComponent) -> Bool {
        guard let line = c.line, line.count == 4 else { return false }
        return line.allSatisfy(\.isFinite)
    }

    static func lineSummary(_ c: MaskComponent) -> String {
        guard let line = c.line, line.count == 4 else { return "no line yet" }
        return String(format: "(%.2f, %.2f) → (%.2f, %.2f)", line[0], line[1], line[2], line[3])
    }

    /// What the outline's note says, in the three states it has — none, part-built, and
    /// closed. The same shape as `ellipseHint`, and for the same reason: before a shape
    /// exists there are no handles to discover the tool from, so this is the one moment
    /// the panel has to carry the gesture.
    ///
    /// The third state is the one worth splitting out. Once the outline is closed a
    /// plain drag deliberately does NOTHING — it used to replace the whole path, and
    /// reaching for a corner and missing is the ordinary way to miss — so the note has
    /// to say where the redraw went, or the tool reads as having stopped working.
    static func outlineHint(_ c: MaskComponent) -> String {
        let corners = (c.path ?? []).count
        if corners == 0 {
            return "Drag on the photograph to lasso a shape, or click to place its "
                 + "corners one at a time."
        }
        if corners < 3 {
            return outlineSummary(c) + " — keep clicking, or drag to lasso instead. "
                 + "Three is the fewest an outline can have."
        }
        return outlineSummary(c) + ". Drag one to move it, ⌥-click to remove it, click "
             + "anywhere to add one. ⌘-drag starts a new outline."
    }

    static func outlineSummary(_ c: MaskComponent) -> String {
        let n = (c.path ?? []).count
        switch n {
        case 0: return "no corners yet"
        case 1: return "one corner, two more needed"
        case 2: return "two corners, one more needed"
        default: return "\(n) corners"
        }
    }

    /// True for the kinds whose own editor already says what is missing, and says it
    /// as a gesture rather than as a schema.
    ///
    /// `validationError` is a wire-format diagnostic — "radial component needs center
    /// [cx,cy] and radii [rx,ry]" — and it was fine when the only way to see it was to
    /// hand-edit a sidecar. Now that a shape is DRAWN rather than seeded, an incomplete
    /// radial is the ordinary first second of every one, so that sentence would be the
    /// first thing a photographer reads about the tool. The badge on the chip still
    /// says INCOMPLETE, which is the part that is worth saying twice.
    /// What to do about an unfinished component, said to a photographer.
    ///
    /// `MaskComponent.validationError()` stays exactly as it is — it is the engine's
    /// truth about whether a component can render, it is what the tests assert against,
    /// and it names wire-format fields because that is its job. What it is not is a
    /// sentence anyone should read: "brush component missing strokesRef" appeared on
    /// screen every time a brush mask was created, because `makeComponent` leaves
    /// `strokesRef` nil by design and filling it is the photographer's next action.
    ///
    /// Every line here says the ACTION rather than the absence, because the absence is
    /// already visible — the mask is doing nothing.
    static func unfinishedNote(_ kind: MaskKind) -> String {
        switch kind {
        case .brush:
            return "Drag on the photograph to paint what this selects."
        case .colorRange:
            return "Click the photograph to sample a colour this should find."
        case .similarity:
            return "Click the photograph to sample the colour this follows."
        case .similarityLine:
            return "Drag on the photograph to draw the gradient, then sample a colour."
        case .lumaRange:
            return "Set the brightness range this selects."
        case .aiObject:
            return "Point at the object you want selected."
        case .depthRange:
            return "Set the depth range this selects."
        case .luminosity:
            return "Choose which end of the tone scale this selects."
        case .aiSubject, .aiSky, .aiBackground, .aiPerson, .aiLandscape:
            return "Waiting for this to be found in the photograph."
        // These four print their own instruction in their own editor, so this is
        // unreachable for them — `saysItsOwnProblem` gates the call site. Written out
        // rather than defaulted so adding a kind is a compile error here instead of a
        // silently generic sentence.
        case .linear, .radial, .polygon, .maskRef:
            return "This is not finished yet."
        }
    }

    static func saysItsOwnProblem(_ kind: MaskKind) -> Bool {
        switch kind {
        case .radial, .linear, .similarityLine, .polygon:
            return true
        case .brush, .lumaRange, .luminosity, .colorRange, .similarity, .maskRef,
             .depthRange, .aiSubject, .aiSky, .aiBackground, .aiObject, .aiPerson,
             .aiLandscape:
            return false
        }
    }

    /// What the radial's note says, which is a different sentence before the shape
    /// exists and after.
    ///
    /// Before, it is the only place that says the gesture: an ellipse you have not drawn
    /// has no handles to discover the tool from, so this is the one moment the panel has
    /// to carry it. After, it is a readout with the four grabs named — and naming them
    /// is what stops the two sliders above from looking like the only way.
    static func ellipseHint(_ c: MaskComponent) -> String {
        guard c.center?.count == 2, c.radii?.count == 2 else {
            return "Drag on the photograph to draw the ellipse. Hold ⇧ to keep it "
                 + "round, ⌥ to draw it out from the centre."
        }
        return ellipseSummary(c)
            + ". Drag inside to move it, the edge to resize, the inner ring to feather, "
            + "the outer dot to turn it."
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

/// A picture of what one mask selects.
///
/// Its own view rather than a method on `MaskPanel`, because it is drawn in three
/// places now — the mask row, the develop column's "which mask am I editing" strip, and
/// the collapsed panel, which is nothing BUT a column of these — and three copies of a
/// corner radius, a border and a disabled opacity drift the moment one of them changes.
///
/// The placeholder is a well rather than a spinner: a thumbnail lands within a frame or
/// two of an edit, and a spinner that appears and vanishes that fast is worse than a
/// quiet empty box.
struct MaskThumbnail: View {
    let image: CGImage?
    let enabled: Bool
    let width: CGFloat
    let height: CGFloat
    /// Whether to draw the selection ring. Only the collapsed column asks for it: there
    /// is no name and no highlight bar down there, so the ring is the ONLY thing saying
    /// which mask the sliders are pointing at.
    var selected: Bool = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black.opacity(0.35)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous)
                .strokeBorder(selected ? Lumen.accent : Lumen.separator,
                              lineWidth: selected ? 1.5 : 0.5)
        )
        .opacity(enabled ? 1 : 0.4)
    }
}

#endif

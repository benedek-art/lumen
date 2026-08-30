// Workspace.swift
// The develop column's information architecture as data: which sections a workspace
// holds and in what order, and what a click on a section header does to the sections
// already open.
//
// WHY IT IS HERE AND NOT IN THE PANELS. The eight-tab strip this replaces
// (`PanelSection`, deleted with this phase) was eight cases and a symbol name; every other fact
// about the layout — that Zones is a tab rather than a disclosure under Tone, that Masks
// is a tab rather than a dock available everywhere, that a panel is always fully open —
// is spread across the panel files themselves, where nothing outside macOS can read it.
// docs/28 §5.1 replaces the strip with four workspaces, so what was one rule becomes two
// that interact: membership and expansion. Interacting rules living in a SwiftUI body is
// the shape `InspectionHolds` and `KeyGrammar` were both extracted out of, and for the
// same reason — a rule nobody can run is a rule nobody can check.
//
// THE REGISTER IS GONE, DELIBERATELY. docs/12 §12.12 specified a Simple/Full register —
// a subset of sections drawn by default, the rest one visible click away — and it
// shipped. The owner used it and ruled against it in the fourth pass (docs/32): "I don't
// know why we have show fewer sections. That's kind of unnecessary, as well as the one
// hidden section active." Every workspace now always draws every section it holds; what
// folds is the section's own chevron, which is the disclosure a photographer actually
// reads. `DisclosureRegister`, the hidden-active indicator and the register half of the
// old `isVisible` rule were deleted with the decision rather than left as dead weight.
//
// THE ONE THING WORTH SAYING TWICE. `WorkspaceSection.workspace` is a total switch and
// everything else — the per-workspace lists, the canonical order — is derived from it.
// There is deliberately no second, hand-written table of "what is in Develop" for that
// switch to drift from. docs/12's §12.1 panel order and docs/28's §5.1 membership are
// the same fact stated twice in prose; stating it a third time in code is how nine of
// the app's nineteen chords came to sit in neither the dispatcher nor the reference that
// documents it (`KeyGrammar`).
//
// WHAT IS DELIBERATELY NOT HERE.
//
//   · Keys. docs/28 §5.1 wants the four workspaces on `1`–`4`, and `1`–`5` are already
//     the rating grammar (`KeyGrammar.dispatchedKeys`). That collision is an open owner
//     decision, and a model that guessed at it would make the guess look settled.
//   · Anything presentational: no symbol names, no widths, no colours. `title` is the
//     text the header prints, which is data in the same sense `KeyGrammar`'s rows are.
//   · Where the state is stored. docs/28 §5.5 rules that layout state never becomes
//     `@Published` on AppState. `WorkspaceLayout` is a value with no observation in it
//     precisely so the app can hold it wherever that ruling lands, and its `Equatable`
//     conformance is what an equality-guarded setter needs.

import Foundation

// MARK: - Workspaces

/// One of docs/28 §5.1's four named layouts, in the order they are offered.
///
/// The order is the workflow's: you cull, you develop, you grade, you deliver. It is a
/// default and never a gate — docs/12 §12.1 is explicit that every panel works in any
/// order — so nothing here forbids grading a frame that was never culled.
public enum Workspace: String, CaseIterable, Hashable, Sendable {

    /// Filmstrip, grid and badges, and no develop column at all. The emptiness is the
    /// feature (docs/12 §12.1: "Photo Mechanic's emptiness without an architectural wall
    /// behind it"), which is why `sections` is empty rather than the column being hidden
    /// by some separate flag.
    case cull

    /// The normalising half of D4's Develop/Look split.
    case develop

    /// GEOMETRY IS ITS OWN JOB, and it is the one job in this app done entirely on the
    /// photograph rather than in the column.
    ///
    /// It was a section of Develop, which was wrong in a way the tool made obvious: the
    /// crop rectangle is gated on the WORKSPACE (fold the accordion to see more of the
    /// picture and the rectangle must stay), so Optics was already behaving like a mode
    /// while being filed as a section. The owner named the same thing from the other end
    /// — "I'd just like to have cull, develop, crop, grade, and deliver."
    ///
    /// Between Develop and Grade because that is the order of the work: normalise the
    /// frame, choose what is in it, then interpret it.
    case crop

    /// The interpreting half. Two workspaces rather than two tabs among eight is what
    /// makes that split spatial, which is the whole argument of docs/28 §5.1.
    case grade

    /// Soft proof and export recipes.
    case deliver

    /// docs/12 §12.12 names Develop as the workspace the app opens in.
    public static let initial: Workspace = .develop
}

// MARK: - Sections

/// One accordion section of a develop column, across all four workspaces.
///
/// Thirteen cases, not the fourteen panels of docs/12 §12.1's table, and the differences
/// are docs/28 §5.1's and are deliberate:
///
///   · **Zones** folds into Tone, **Denoise** into Detail and **B&W** into Colour, as
///     disclosures inside those sections rather than sections of their own. That is
///     §12.12's second shape — per-control disclosure — and it is the difference between
///     Develop being six rows deep and being eight.
///   · **Masks has no case at all**, and the reason changed. It used to be that masking
///     happens while developing *and* while grading, so a section of either would be
///     wrong twice over. The mask model says something stronger: `LocalAdjust` carries
///     twenty scalars plus a local point curve and local grading wheels, which is to say
///     a mask's adjustments are a COPY OF THE GLOBALS. Nobody masking wants global Tone
///     — they want that mask's Tone, and it is right there. So masking is not one more
///     section beside the others; it is what the column shows INSTEAD of them, and that
///     is `WorkspaceLayout.isMasking`.
///   · **Render** (§12.1 #3, shipped as the Look panel's Display Transform) is not in
///     §5.1's Develop list. `canonicalRank` leaves 3 unused rather than closing the gap,
///     so adding it later is one case and one rank, with nothing renumbered.
///
/// `rawValue` is a persistence key — docs/28 §5.5 puts expansion in `@AppStorage` — so
/// renaming a case silently discards whatever was stored under the old name. `title` is
/// the separate string the header prints, and can be reworded freely.
public enum WorkspaceSection: String, CaseIterable, Hashable, Sendable {

    // Declared in canonical order, which `WorkspaceTests` re-derives from
    // `canonicalRank` rather than trusting.

    case whiteBalance
    /// Zones lives inside this one.
    case tone
    /// The frame itself — crop, straighten, flip. Split from `optics` when Crop became
    /// a workspace, and the split is a correctness fix rather than a tidying: the two
    /// were one section, so Reset on it cleared the crop AND the lens corrections
    /// together. Those are unrelated decisions a photographer makes at different times,
    /// and one Reset that undoes both is the same defect class as a caption promising a
    /// key that does nothing — it does more than it says.
    ///
    /// Declared HERE rather than beside `optics` because declaration order is canonical
    /// order in this enum and the tests hold it: rank 3 was left vacant for a section
    /// that had not been designed yet, and this is it.
    case frame

    case curve
    case presence
    /// Denoise lives inside this one.
    case detail
    case optics

    case looks
    /// Mixer, Point Colour and B&W live inside this one.
    ///
    /// Spelled American here and British in `title`, matching a split the codebase
    /// already made: `ColorEngine` and `ColorPanel` against panel
    /// headers that read "Colour Mixer" and "Colour Grading". Identifiers follow the
    /// identifiers; user-facing text follows the user-facing text.
    case color
    case grading
    case filmLab
    case effects

    case softProof
    case exportRecipes

    /// The section's position in docs/12 §12.1's panel-order table — base rendering →
    /// balance → tone → global colour → local → detail → output, the order four
    /// independent traditions converge on.
    ///
    /// The table's own numbering, gaps included: 3 is Render and 12 is B&W, neither of
    /// which is a section here. Renumbering to close them would mean this file and the
    /// document no longer share a vocabulary, and the first question anyone asks of a
    /// rank is "which row of the table is that".
    ///
    /// 14 and 15 are not in the table, which marks both Masks and Export "—" because
    /// neither is a panel in the rail. They continue the sequence because output is last
    /// in every tradition §12.1 cites, and soft proof precedes export because it is the
    /// check you make before you write the file.
    public var canonicalRank: Int {
        switch self {
        case .whiteBalance: return 1
        case .tone: return 2
        case .curve: return 4
        case .presence: return 5
        case .detail: return 6
        // 3 was left vacant for a section that had not been designed yet. This is it.
        case .frame: return 3
        case .optics: return 7
        case .looks: return 8
        case .color: return 9
        case .grading: return 10
        case .filmLab: return 11
        case .effects: return 13
        case .softProof: return 14
        case .exportRecipes: return 15
        }
    }

    /// The workspace this section belongs to, and the single source of truth for
    /// membership: `Workspace.sections` is derived from it, so a section cannot be in two
    /// workspaces or in none, and a new case cannot compile without answering this.
    public var workspace: Workspace {
        switch self {
        case .whiteBalance, .tone, .curve, .presence, .detail:
            return .develop
        case .frame, .optics:
            return .crop
        case .looks, .color, .grading, .filmLab, .effects:
            return .grade
        case .softProof, .exportRecipes:
            return .deliver
        }
    }

    /// What the section header prints.
    public var title: String {
        switch self {
        case .whiteBalance: return "White Balance"
        case .tone: return "Tone"
        case .curve: return "Curve"
        case .presence: return "Presence"
        case .detail: return "Detail"
        case .frame: return "Crop"
        case .optics: return "Lens"
        case .looks: return "Looks"
        case .color: return "Colour"
        case .grading: return "Grading"
        case .filmLab: return "Film Lab"
        case .effects: return "Effects"
        case .softProof: return "Soft Proof"
        case .exportRecipes: return "Export Recipes"
        }
    }

}

// MARK: - Membership

extension Workspace {

    /// The workspace's sections, in docs/12 §12.1's canonical order. Always all of them:
    /// the Simple register that used to filter this list is gone (see the header).
    public var sections: [WorkspaceSection] {
        Workspace.sectionsByWorkspace[self] ?? []
    }

    public func contains(_ section: WorkspaceSection) -> Bool {
        section.workspace == self
    }

    // Built once and stored, rather than filtering `allCases` per call: these are read
    // from a SwiftUI body on every pass, and returning a stored array retains rather
    // than allocates.
    //
    // Sorted explicitly instead of leaning on either `allCases`' declaration order or
    // `Dictionary(grouping:by:)`'s within-group order. Both happen to be canonical
    // today; neither is a property this file should depend on, since the cost of one of
    // them quietly changing is a rail that presents colour before tone.
    //
    // Cull never appears as a key — grouping creates a key only where an element landed
    // — hence `?? []` at each call site above, which is also exactly the answer Cull
    // wants.
    private static let sectionsByWorkspace: [Workspace: [WorkspaceSection]] =
        Dictionary(grouping: WorkspaceSection.allCases, by: \.workspace)
            .mapValues { $0.sorted { $0.canonicalRank < $1.canonicalRank } }
}

// MARK: - The solo rule

/// What a click on a section header does to the set of sections already open.
///
/// Solo — one section open at a time — is the default, and docs/28 §5.5 is the reason it
/// is load-bearing rather than a taste: per-event cost is proportional to the slider rows
/// in scope, and a workspace stacking six sections could put around forty rows there
/// where a single panel puts sixteen. Solo-by-default is what holds the IA change at
/// parity with the tab strip it replaces.
public enum SectionExpansion {

    /// The new expanded set.
    ///
    /// - `section`: the header that was clicked. It names its own workspace, which is
    ///   what bounds the rule (below).
    /// - `expanded`: what is open now, across all workspaces.
    /// - `keepingOthersOpen`: the modifier docs/28 §5.1 gives as ⌥-click. Named for its
    ///   effect rather than its key, because no key is assigned in this file.
    ///
    /// Three decisions, each of which has a plausible opposite:
    ///
    /// **Solo clears only the clicked section's own workspace.** Sections partition by
    /// workspace, so leaving the other three workspaces' entries alone costs nothing and
    /// buys per-workspace memory for free: leave Develop with Tone open, work in Grade,
    /// come back to Tone open. Clearing the whole set instead would make every workspace
    /// switch a small amnesia, and there is no gesture that would restore it.
    ///
    /// **A plain click on the only open section closes it.** The alternative — a plain
    /// click can only ever open — leaves no way to see an empty column without reaching
    /// for the modifier, and a disclosure triangle that cannot close is not a disclosure
    /// triangle.
    ///
    /// **A plain click on one of several open sections solos it rather than closing it.**
    /// The alternative is a pure toggle, which would leave the others open — and then the
    /// plain click is not the solo gesture, so the one move a user makes to get back to
    /// one open panel leaves the expensive state exactly where it was.
    public static func afterClick(on section: WorkspaceSection,
                                  expanded: Set<WorkspaceSection>,
                                  keepingOthersOpen: Bool) -> Set<WorkspaceSection> {
        if keepingOthersOpen {
            return expanded.symmetricDifference([section])
        }
        let stack = Set(section.workspace.sections)
        if expanded.intersection(stack) == [section] {
            return expanded.subtracting([section])
        }
        return expanded.subtracting(stack).union([section])
    }
}

// MARK: - The layout as a value

/// Everything the develop column needs to draw itself, and the transitions that change
/// it. A value with no observation in it: docs/28 §5.5 rules that layout state must not
/// become `@Published` on AppState, and `Equatable` is what an equality-guarded setter
/// needs to avoid publishing a change that changed nothing.
public struct WorkspaceLayout: Equatable, Sendable {

    public var workspace: Workspace

    /// Every section the user has opened, across all four workspaces — not only the
    /// current one. Storing the superset is what makes a workspace switch
    /// non-destructive: leave Develop with Tone open, grade, come back to Tone open.
    /// Read `expandedSections` to draw.
    public var expanded: Set<WorkspaceSection>

    /// MASKING TAKES THE COLUMN OVER, and this is the flag that says so.
    ///
    /// The owner asked for it in those terms — "I would like to have its own page ...
    /// instead of when I press it, it just shows up on the page that I am showing off" —
    /// and the mask model agrees: `LocalAdjust` is the global adjustment set again, so a
    /// column that stacked the mask editor ON TOP of Tone, Curve and Colour was offering
    /// the same six controls twice, twenty rows apart, meaning different things.
    ///
    /// **It is a field and not a sixth `Workspace` case.** Two reasons, and the first is
    /// mechanical: `LumenApp`'s View menu puts the workspaces in a `Group`, which is at
    /// its ten-child builder limit now that Crop is the fifth. The second is that a
    /// workspace is a persistent destination the switcher always offers, and masking is
    /// somewhere you go and come back from — `workspace` keeps holding where you were,
    /// which is what the way out returns to.
    ///
    /// **It is not an `AppState.viewMode` case either.** Masking does not want a
    /// different centre pane — `LoupeView` is right, and `MaskCanvas` already composes
    /// into it as an overlay gated on this same flag. What it takes over is the right
    /// column, which `viewMode` has no say over; putting it there would add a second
    /// orthogonal mode axis and cost a whole-window publish per toggle, which is the
    /// exact cost `PanelLayout` was extracted to stop paying.
    ///
    /// Not forbidden in Cull. A rule saying where masking may not begin would be a
    /// second rule to keep in step with the first, and docs/12:108 says any workspace.
    public var isMasking: Bool

    public init(workspace: Workspace = .initial,
                expanded: Set<WorkspaceSection> = [],
                isMasking: Bool = false) {
        self.workspace = workspace
        self.expanded = expanded
        self.isMasking = isMasking
    }

    /// What a fresh install opens with: a first pass's three sections, open.
    ///
    /// White Balance, Tone and Presence — the set the retired Simple register used to
    /// draw for Develop, kept as the opening arrangement now that every section is
    /// always listed: a column that opens with nothing unfolded reads as mostly empty,
    /// and the fix for that should not be a photographer clicking before they can start.
    /// Curve and Detail start folded because they are the deep half of a first pass, not
    /// because anything hides them — their headers are right there.
    public static let initial = WorkspaceLayout(
        workspace: .initial,
        expanded: [.whiteBalance, .tone, .presence])

    // MARK: What to draw

    /// Whether there is a develop column at all — false only in Cull, and only when
    /// nothing has taken the column over.
    ///
    /// THE `isMasking` CLAUSE IS NOT A SPECIAL CASE, it is the sentence above applied
    /// to a column that no longer draws sections at all. `isMasking`'s own contract has
    /// always said masking is "not forbidden in Cull" — and it was, silently, because
    /// Cull has no sections, so `ContentView` drew no column, so there was nothing for
    /// the editor to take over and `M` did nothing a photographer could see. The dock
    /// had the same hole and it mattered less, since a dock that cannot appear is a
    /// missing panel rather than a missing page.
    public var showsDevelopColumn: Bool {
        !workspace.sections.isEmpty || isMasking
    }

    /// The sections the column draws, in canonical order — the workspace's whole list.
    ///
    /// Kept as a named property rather than folded into call sites: it is the one
    /// question the column asks, and while the register existed this was where the
    /// filtering lived. It filters nothing now, on the owner's decision (see the
    /// header), and a caller cannot tell the difference — which is the point.
    public var visibleSections: [WorkspaceSection] {
        workspace.sections
    }

    /// The visible sections that are open, in canonical order.
    ///
    /// Filtering the drawn list rather than reading `expanded` directly is what stops a
    /// set that holds entries for every workspace from ever opening a section this
    /// workspace does not have.
    public var expandedSections: [WorkspaceSection] {
        visibleSections.filter(expanded.contains)
    }

    // MARK: Transitions

    /// Switch workspaces, WHICH IS ALSO HOW YOU LEAVE MASKING.
    ///
    /// Expansion survives untouched — a switch changes which sections are on screen and
    /// nothing about how they are arranged, so the round trip back is exact.
    ///
    /// Masking does not survive, and that is the one behaviour this verb gained with the
    /// takeover. Naming a workspace is naming what the column shows, and while masking
    /// there is no switcher on screen to name one with: the only callers left are ⌘1–⌘5
    /// and the View menu. A ⌘3 that changed a workspace nobody could see, leaving the
    /// mask editor exactly where it was, is a key that appears dead — the failure
    /// `PanelLayout.reveal` already exists to avoid.
    public mutating func select(_ workspace: Workspace) {
        self.workspace = workspace
        isMasking = false
    }

    /// A click on a section header. See `SectionExpansion.afterClick`.
    ///
    /// A click on a section of another workspace is ignored rather than silently opening
    /// something the user cannot see: there is no header on screen to click, so a call
    /// that says otherwise is a caller bug, and honouring it would leave `expanded`
    /// carrying a change nothing drew.
    public mutating func click(_ section: WorkspaceSection,
                               keepingOthersOpen: Bool = false) {
        guard workspace.contains(section) else { return }
        expanded = SectionExpansion.afterClick(on: section,
                                               expanded: expanded,
                                               keepingOthersOpen: keepingOthersOpen)
    }
}

// Workspace.swift
// The develop column's information architecture as data: which sections a workspace
// holds and in what order, which of them the Simple register shows, how many of the
// hidden ones are still carrying an edit, and what a click on a section header does to
// the sections already open.
//
// WHY IT IS HERE AND NOT IN THE PANELS. The eight-tab strip this replaces
// (`PanelSection`, AppState.swift) is eight cases and a symbol name; every other fact
// about the layout — that Zones is a tab rather than a disclosure under Tone, that Masks
// is a tab rather than a dock available everywhere, that a panel is always fully open —
// is spread across the panel files themselves, where nothing outside macOS can read it.
// docs/28 §5.1 replaces the strip with four workspaces and docs/12 §12.12 puts two
// registers behind them, so what was one rule becomes three that interact: membership,
// register, expansion. Three interacting rules living in a SwiftUI body is the shape
// `InspectionHolds` and `KeyGrammar` were both extracted out of, and for the same reason
// — a rule nobody can run is a rule nobody can check.
//
// THE ONE THING WORTH SAYING TWICE. `WorkspaceSection.workspace` is a total switch and
// everything else — the per-workspace lists, the canonical order, the Simple register's
// subset — is derived from it. There is deliberately no second, hand-written table of
// "what is in Develop" for that switch to drift from. docs/12's §12.1 panel order and
// docs/28's §5.1 membership are the same fact stated twice in prose; stating it a third
// time in code is how nine of the app's nineteen chords came to sit in neither the
// dispatcher nor the reference that documents it (`KeyGrammar`).
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
///   · **Masks has no case at all.** docs/12 §12.1 already lists it as floating or docked
///     via a key rather than as a panel in the rail, and masking happens while developing
///     *and* while grading, so making it a section of either would be wrong twice over.
///     It is `WorkspaceLayout.isMaskDockOpen`, which survives every workspace switch.
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
    case curve
    case presence
    /// Denoise lives inside this one.
    case detail
    case optics

    case looks
    /// Mixer, Point Colour and B&W live inside this one.
    ///
    /// Spelled American here and British in `title`, matching a split the codebase
    /// already made: `ColorEngine`, `ColorPanel` and `PanelSection.color` against panel
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
        case .whiteBalance, .tone, .curve, .presence, .detail, .optics:
            return .develop
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
        case .optics: return "Optics"
        case .looks: return "Looks"
        case .color: return "Colour"
        case .grading: return "Grading"
        case .filmLab: return "Film Lab"
        case .effects: return "Effects"
        case .softProof: return "Soft Proof"
        case .exportRecipes: return "Export Recipes"
        }
    }

    /// True for the six sections the Simple register keeps on screen.
    ///
    /// Develop's three and Grade's two are docs/28 §5.1 verbatim. Deliver's is read from
    /// docs/12 §12.12, whose Simple set is "WB, Tone's six sliders, Looks, Crop, Masks,
    /// Export" — Export is named in it and soft proof is not, which is the right way
    /// round: a soft proof is a check against a specific destination profile, and a
    /// photographer who has not chosen one has nothing to check against.
    ///
    /// Cull contributes nothing to either register because it has no sections; the Simple
    /// register is not what empties it.
    public var isInSimpleRegister: Bool {
        switch self {
        case .whiteBalance, .tone, .presence, .looks, .color, .exportRecipes:
            return true
        case .curve, .detail, .optics, .grading, .filmLab, .effects, .softProof:
            return false
        }
    }

    /// Whether this register shows the section. Full shows everything, which is what
    /// makes "Show all" a single visible control rather than a preference.
    public func isVisible(in register: DisclosureRegister) -> Bool {
        register == .full || isInSimpleRegister
    }
}

// MARK: - Registers

/// docs/12 §12.12's two registers, one tool.
///
/// A register is not a preference and not a mode: hidden sections keep applying their
/// adjustments, and the count of the hidden ones that are doing so is on the screen
/// (`WorkspaceLayout.hiddenActiveIndicator`). Switching registers changes what is drawn
/// and nothing else, which is what lets `WorkspaceLayout` treat expansion as a set that
/// outlives both registers.
public enum DisclosureRegister: String, CaseIterable, Hashable, Sendable {

    /// The default, and §12.12 names what the other way round costs: darktable built the
    /// deepest disclosure system in any editor and then defaulted to the deep end,
    /// because "defaults, not options, set perceived complexity".
    case simple

    /// Every section of the workspace.
    case full

    public static let initial: DisclosureRegister = .simple

    /// The other one, for the control that toggles between them.
    public var toggled: DisclosureRegister {
        self == .simple ? .full : .simple
    }
}

// MARK: - Membership

extension Workspace {

    /// The workspace's sections, in docs/12 §12.1's canonical order.
    public var sections: [WorkspaceSection] {
        Workspace.sectionsByWorkspace[self] ?? []
    }

    /// The sections this register draws, in the same order.
    public func sections(in register: DisclosureRegister) -> [WorkspaceSection] {
        switch register {
        case .full: return sections
        case .simple: return Workspace.simpleSectionsByWorkspace[self] ?? []
        }
    }

    /// The sections the register is holding back — what "Show all" would reveal, and
    /// therefore what the hidden-active indicator has to be counted against.
    public func hiddenSections(in register: DisclosureRegister) -> [WorkspaceSection] {
        switch register {
        case .full: return []
        case .simple: return Workspace.hiddenSectionsByWorkspace[self] ?? []
        }
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

    private static let simpleSectionsByWorkspace: [Workspace: [WorkspaceSection]] =
        sectionsByWorkspace.mapValues { $0.filter(\.isInSimpleRegister) }

    private static let hiddenSectionsByWorkspace: [Workspace: [WorkspaceSection]] =
        sectionsByWorkspace.mapValues { $0.filter { !$0.isInSimpleRegister } }
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
    public var register: DisclosureRegister

    /// Every section the user has opened, across all four workspaces — not only the
    /// current one, and not filtered by the register. Storing the superset is what makes
    /// both a workspace switch and a register toggle non-destructive, which docs/12
    /// §12.12 requires of the register in as many words. Read `expandedSections` to draw.
    public var expanded: Set<WorkspaceSection>

    /// docs/12 §12.1 lists Masks as floating or docked via a key rather than as a panel
    /// in the rail, and docs/28 §5.1 makes it available in every workspace. It is a field
    /// here rather than a `WorkspaceSection` case, and `select(_:)` leaves it alone, so
    /// masking a frame and then switching from Develop to Grade to grade it does not put
    /// the mask list away mid-edit.
    ///
    /// Not forbidden in Cull. A rule saying where the dock may not open would be a second
    /// rule to keep in step with the first, and docs/12:108 says any workspace.
    public var isMaskDockOpen: Bool

    public init(workspace: Workspace = .initial,
                register: DisclosureRegister = .initial,
                expanded: Set<WorkspaceSection> = [],
                isMaskDockOpen: Bool = false) {
        self.workspace = workspace
        self.register = register
        self.expanded = expanded
        self.isMaskDockOpen = isMaskDockOpen
    }

    /// What a fresh install opens with.
    ///
    /// Tone rather than White Balance is the one invention here, and it is docs/12
    /// §12.1's own amendment applied one level up: the Basic panel already orders its
    /// rows Tone → Presence → WB, "tone first because it is what the hand reaches for
    /// first in practice, white balance demoted below it because most frames' as-shot
    /// neutral is close and the row is a correction, not an opening move". The rail's
    /// order stays canonical; what is *open* on launch follows the hand.
    public static let initial = WorkspaceLayout(workspace: .initial,
                                                register: .initial,
                                                expanded: [.tone])

    // MARK: What to draw

    /// Whether there is a develop column at all — false only in Cull.
    ///
    /// Deliberately not `visibleSections.isEmpty`: a workspace whose sections are all
    /// hidden by the Simple register still needs its column, or the control that would
    /// bring them back goes with them.
    public var showsDevelopColumn: Bool {
        !workspace.sections.isEmpty
    }

    /// The sections the column draws, in canonical order.
    public var visibleSections: [WorkspaceSection] {
        workspace.sections(in: register)
    }

    /// The visible sections that are open, in canonical order.
    ///
    /// Filtering the drawn list rather than reading `expanded` directly is what stops a
    /// set that holds entries for every workspace and both registers from ever opening a
    /// section this workspace does not have or this register is hiding.
    public var expandedSections: [WorkspaceSection] {
        visibleSections.filter(expanded.contains)
    }

    // MARK: The hidden-active indicator

    /// The sections that are hidden by the register *and* holding a non-default value, in
    /// canonical order. docs/12 §12.12: hidden panels keep applying, "with a '3 hidden
    /// panels active' indicator so state never becomes secret".
    ///
    /// - `nonDefault`: every section whose controls differ from their defaults. The
    ///   caller derives it from the recipe; it may name sections from any workspace and
    ///   visible ones too, and both are filtered out here.
    ///
    /// Scoped to the current workspace on purpose. The indicator sits beside the control
    /// that reveals these sections, so it has to count exactly what that control would
    /// reveal — a badge reading five beside a click that produces two is worse than no
    /// badge. A non-default section in another workspace is hidden by a move the user
    /// made, not by a default they never chose, which is the state §12.12 is about.
    public func hiddenActiveSections(nonDefault: Set<WorkspaceSection>)
            -> [WorkspaceSection] {
        workspace.hiddenSections(in: register).filter(nonDefault.contains)
    }

    public func hiddenActiveCount(nonDefault: Set<WorkspaceSection>) -> Int {
        hiddenActiveSections(nonDefault: nonDefault).count
    }

    /// The indicator's text, or nil when there is nothing to disclose.
    ///
    /// Composed here rather than in the view because the singular is the half that gets
    /// shipped wrong, and here a test can read it.
    public func hiddenActiveIndicator(nonDefault: Set<WorkspaceSection>) -> String? {
        let count = hiddenActiveCount(nonDefault: nonDefault)
        guard count > 0 else { return nil }
        return "\(count) hidden section\(count == 1 ? "" : "s") active"
    }

    // MARK: Transitions

    /// Switch workspaces. Expansion, register and the mask dock all survive, so the only
    /// thing a switch changes is which sections are on screen.
    public mutating func select(_ workspace: Workspace) {
        self.workspace = workspace
    }

    /// The visible "Show all" control of docs/12 §12.12 — visible, and therefore a verb
    /// rather than a preference.
    public mutating func toggleRegister() {
        register = register.toggled
    }

    /// A click on a section header. See `SectionExpansion.afterClick`.
    ///
    /// A click on a section the current register is hiding is ignored rather than
    /// silently opening something the user cannot see: there is no header to click, so a
    /// call that says otherwise is a caller bug, and honouring it would leave `expanded`
    /// carrying a section that only reappears on a later register toggle.
    public mutating func click(_ section: WorkspaceSection,
                               keepingOthersOpen: Bool = false) {
        guard section.isVisible(in: register), workspace.contains(section) else { return }
        expanded = SectionExpansion.afterClick(on: section,
                                               expanded: expanded,
                                               keepingOthersOpen: keepingOthersOpen)
    }
}

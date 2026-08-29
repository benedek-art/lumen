// PanelLayout.swift
// The develop column's own observable, and the ONLY thing that publishes when the
// arrangement of that column changes.
//
// docs/28 Phase 4 items 13 and 16. The arrangement itself — which workspace, which
// sections are open, which register, whether the mask dock is out — is `WorkspaceLayout`
// in LumenCore, a plain `Equatable` value with no observation in it and its own tests.
// This is the thin observable wrapper that lets a SwiftUI column watch it, and its whole
// job is to publish as rarely as the value actually changes.
//
// WHY NOT `AppState`. `activeSection` lived there as a `@Published`, and `AppState` is a
// `@StateObject` in `LumenApp` plus an `@EnvironmentObject` in about twenty-six views —
// so one tab click re-bodied the whole window AND the `Scene`, all seven menus with it.
// Four workspaces with collapsible sections make that click more frequent, not less, and
// the sections are where the sliders live. A separate object read only by the column
// means an expansion change invalidates the column and nothing else.
//
// The equality guard is not decoration. `@Published` performs no equality check of its
// own, so `layout = layout` publishes, and a setter that recomputes a set is exactly the
// shape that assigns an equal value. `CommandState.refresh` guards for the same reason
// and after the same defect.

#if os(macOS)
import Combine
import Foundation
import LumenCore
import SwiftUI

/// Not `@MainActor` on the type, matching `LoupeViewport`: a `static let` singleton of
/// an actor-isolated class cannot be built from a view's property initialiser, and every
/// verb here is called from a SwiftUI body or a menu action, both of which are already
/// on the main actor. Nothing in this object touches `AppState`.
final class PanelLayout: ObservableObject {

    /// One per process, like `LoupeViewport`. The develop column is a singleton surface
    /// and a second arrangement of it would be a second answer to "which section is
    /// open". Tests build their own instance instead — the initialiser is internal and
    /// takes the value, so a counting test never touches the user's stored defaults.
    static let shared = PanelLayout()

    /// PRIVATE SETTER, so every mutation goes through a named verb below.
    ///
    /// A public setter would let a caller assign a whole layout and skip the guard, and
    /// the guard is the only thing standing between an accordion and a per-event
    /// publish. The verbs also keep the solo rule in LumenCore where it is tested:
    /// nothing here decides what a click means.
    @Published private(set) var layout: WorkspaceLayout

    private let defaults: UserDefaults?

    init(layout: WorkspaceLayout = .initial, defaults: UserDefaults? = nil) {
        self.layout = layout
        self.defaults = defaults
    }

    /// The shared instance restores what was stored; a test instance is given a value
    /// and no store at all.
    private convenience init() {
        let store = UserDefaults.standard
        self.init(layout: Self.restore(from: store) ?? .initial, defaults: store)
    }

    // MARK: Verbs

    /// ⌘1–⌘4 and the workspace switcher. One publish, and none at all when the
    /// photographer clicks the workspace they are already in — which is most of the
    /// clicks a switcher receives.
    func select(_ workspace: Workspace) {
        var next = layout
        next.select(workspace)
        commit(next)
    }

    /// A HEADER WAS CLICKED, and this is the one place that decides what a click means.
    ///
    /// A plain click toggles ONLY the section clicked; ⌥ solos it, closing the rest of
    /// that workspace's stack. It shipped the other way round for one build and the
    /// owner asked for this within minutes of using it: "can we make it so that I can
    /// open all of the chevrons at the same time instead of having to only open one at a
    /// time."
    ///
    /// He is right, and Lightroom agrees: its panels collapse independently and Solo
    /// Mode is an opt-in you turn on deliberately. Solo defends the scroll length of a
    /// long column, which is a cost the photographer can see and judge for themselves —
    /// and paying it by default means every second click is undoing the first one. The
    /// expansion set persists (`develop.expanded`), so opening what you want is a thing
    /// you do once rather than every session.
    ///
    /// Both behaviours still exist, because `SectionExpansion.afterClick` in LumenCore
    /// expresses both and always did. This inverted a default, not a rule.
    func headerClicked(_ section: WorkspaceSection, optionHeld: Bool) {
        click(section, keepingOthersOpen: !optionHeld)
    }

    /// The rule underneath, taking the model's own vocabulary rather than the modifier's
    /// — `SectionExpansion.afterClick` in LumenCore holds it and its tests.
    func click(_ section: WorkspaceSection, keepingOthersOpen: Bool) {
        var next = layout
        next.click(section, keepingOthersOpen: keepingOthersOpen)
        commit(next)
    }

    /// OPEN A SECTION BY NAME, from a key — and promote the register if it is hiding.
    ///
    /// `click` is a header being clicked, so the section is visible by construction and
    /// the guard inside `WorkspaceLayout.click` never fires. A KEY is different: `D`
    /// names Detail and `R` names Optics, and neither is in the Simple register the app
    /// opens in, so routing a key through `click` answers a photographer who asked for a
    /// section by name with silence. A key that does nothing is worse than a key that
    /// does not exist, because it teaches that the app is broken rather than that the
    /// feature is missing.
    ///
    /// Promoting rather than refusing is the right trade: Simple is a default, not a
    /// mode, and the photographer just demonstrated they want the thing it was hiding.
    /// Still one publish — the whole arrangement is one value.
    func reveal(_ section: WorkspaceSection) {
        var next = layout
        next.select(section.workspace)
        if !section.isVisible(in: next.register) { next.register = .full }
        next.click(section, keepingOthersOpen: false)
        commit(next)
    }

    /// Simple ⇄ Full.
    func toggleRegister() {
        var next = layout
        next.toggleRegister()
        commit(next)
    }

    /// The mask dock, which is available in every workspace and therefore is not a
    /// section — see `WorkspaceLayout.isMaskDockOpen`.
    func setMaskDock(open: Bool) {
        var next = layout
        next.isMaskDockOpen = open
        commit(next)
    }

    // MARK: The guard, and the store

    /// THE ONE PLACE A PUBLISH CAN HAPPEN.
    ///
    /// Writing an equal value through `@Published` still publishes, and every verb above
    /// recomputes a whole `WorkspaceLayout` — including a set — so assigning an equal
    /// one is the normal case rather than the exotic one. Clicking the open section's
    /// own workspace, ⌥-clicking a section twice, toggling the dock to where it already
    /// is: all of those arrive here identical.
    private func commit(_ next: WorkspaceLayout) {
        guard next != layout else { return }
        layout = next
        persist(next)
    }

    // MARK: Persistence

    // The sidebar's four keys are `sidebar.<name>` (`ContentView`), so these are
    // `develop.<name>`. Expansion is stored as `WorkspaceSection.rawValue`s, which
    // `Workspace.swift` designates as the persistence key for exactly this — renaming a
    // case silently discards what a photographer had open, which is why the raw values
    // are spelled out there rather than derived.
    private enum Key {
        static let workspace = "develop.workspace"
        static let register = "develop.register"
        static let expanded = "develop.expanded"
        static let maskDock = "develop.maskDock"
    }

    private func persist(_ value: WorkspaceLayout) {
        guard let defaults else { return }
        defaults.set(value.workspace.rawValue, forKey: Key.workspace)
        defaults.set(value.register.rawValue, forKey: Key.register)
        // Sorted, so the stored array does not churn on every write for a set whose
        // iteration order is not stable. A defaults write is cheap and a diff-free one
        // is cheaper.
        defaults.set(value.expanded.map(\.rawValue).sorted(), forKey: Key.expanded)
        defaults.set(value.isMaskDockOpen, forKey: Key.maskDock)
    }

    /// TOLERANT, because this reads a previous version's idea of the layout.
    ///
    /// A section that no longer exists, a workspace that was renamed, a key written by a
    /// build that predates all of this: every one of them decodes to the default for
    /// that field rather than to a failure. The cost of a wrong answer here is a panel
    /// opening in the wrong place once; the cost of a throw is a photographer who cannot
    /// open the app.
    private static func restore(from defaults: UserDefaults) -> WorkspaceLayout? {
        guard defaults.object(forKey: Key.workspace) != nil
                || defaults.object(forKey: Key.expanded) != nil else { return nil }
        let workspace = (defaults.string(forKey: Key.workspace))
            .flatMap(Workspace.init(rawValue:)) ?? .initial
        let register = (defaults.string(forKey: Key.register))
            .flatMap(DisclosureRegister.init(rawValue:)) ?? .initial
        let expanded = Set((defaults.stringArray(forKey: Key.expanded) ?? [])
            .compactMap(WorkspaceSection.init(rawValue:)))
        return WorkspaceLayout(workspace: workspace,
                               register: register,
                               expanded: expanded,
                               // `object(forKey:) as? Bool` rather than `bool(forKey:)`:
                               // the typed accessor answers false both for "stored
                               // false" and for "never written", and it is also the one
                               // name in this file that collides with the in-tree
                               // SQLite `bool(_:)` the surface checker resolves against.
                               isMaskDockOpen: defaults.object(forKey: Key.maskDock)
                                   as? Bool ?? false)
    }
}
#endif

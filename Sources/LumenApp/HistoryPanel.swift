// HistoryPanel.swift
// The history, on screen — the list of where this photograph has been, and a click back
// to any of it.
//
// WHY THIS FILE EXISTS. `HistoryStack` is a complete, tested, coalescing undo stack with
// typed edits, and until now the entire user interface over it was two menu items. ⌘Z is
// a keyhole onto a four-hundred-step structure: it can only say "one back" and it can
// only say it about a step it names "Edit", so the photographer's model of where they
// have been is whatever they can hold in their head. Every editor in this category shows
// the list instead, and the reason is not completeness — it is that a visible history is
// what makes experimenting free. You cannot be afraid of a change you can see yourself
// walking back from.
//
// WHAT A CLICK MEANS, decided once and stated here because the alternative is a control
// whose behaviour depends on which row you press: **clicking a row is a plain position
// move.** It is exactly the ⌘Z / ⇧⌘Z the menu already performs, repeated until the
// cursor arrives, and it records NOTHING. The other reading — "jumping back is itself an
// edit, so it can be undone" — is the one Lightroom rejects and it is worse here for a
// concrete reason: `record` truncates the redo tail (`steps.removeSubrange(position...)`),
// so making a jump an edit would DESTROY the steps you jumped over at the moment you
// looked at them. A cursor move destroys nothing; the rows above the current one stay
// live and clickable until you actually edit from where you have landed. The row's own
// tooltip says so, because that is the one thing about a history list a photographer has
// to be able to trust.
//
// THE THREE THINGS THIS PANEL DOES NOT DO, each because it cannot be done honestly from
// here rather than because nobody thought of it:
//
//   · **It does not preview the photograph on hover.** The house has two hover idioms
//     and this row can only reach one of them. `lumenInteractive` is the affordance —
//     a surface that answers the pointer — and it is here. `MaskPanel`'s
//     `state.hoverMaskOverlay` is the PREVIEW, and it works by asking `AppState` to
//     draw something else, behind a 120 ms intent hold. A row here would need the same
//     shape and cannot have it: there is no recipe override the render coordinator
//     reads instead of `currentRecipe`, and a panel cannot invent one. `LookPanel`'s
//     saved-look browser carries the identical limitation with the identical note, and
//     for the identical reason. So the row answers the pointer with a fill, a pointing
//     hand, and a tooltip naming exactly where the click lands and how far it is.
//   · **It does not offer snapshots.** `HistoryStack` carries `Snapshot`, `snapshots`
//     and two verbs for them, all four unreferenced — and the audit that found them
//     (L-05) is explicit about the condition: wire them "plus persistence — snapshots
//     that die with the process are worse than none". They would die with the process:
//     there is no catalog table, no `CatalogService` reader or writer, and `Snapshot`
//     carries no URL, so a snapshot taken on one photograph would list under every
//     other one. That is four changes across three files this panel does not own.
//   · **It does not scroll on its own.** The develop column is ONE scroll surface on
//     purpose (`DevelopPanel.scrollColumn`: four panels used to own their own
//     `ScrollView`, which inside an accordion is a scroll trap — the column stops
//     scrolling wherever the pointer happens to be). A list nested in a fixed-height
//     scroller here would rebuild that trap in the one card most likely to be under the
//     pointer. The list scrolls because the column scrolls, and it is bounded instead:
//     the most recent `visibleSteps` rows, with the rest one click away.
//
// WHAT IT RETAINS: nothing. Every row is a `HistoryStack.Entry` — an Int and two
// Strings — built inside `body` and thrown away. No `@State` in this file holds a
// `Recipe`, a `Step` or a `PhotoEdit`, and the rows are derived from `history.steps`
// rather than copied out of it, so a thousand-frame session costs this panel the same as
// a two-frame one. The only place a recipe lives is the stack's own 400-step ring, which
// is a bound this file neither raises nor duplicates.

#if os(macOS)

import Foundation
import SwiftUI

/// One photograph's history, newest first, with the current position marked.
struct HistoryPanel: View {

    /// THE NARROWEST SUBSCRIPTION IN THE APPLICATION, and it has to be argued for
    /// because `HistoryStack`'s own header is an argument against observing it.
    ///
    /// What that header forbids is the blanket `history.objectWillChange` →
    /// `AppState.objectWillChange` forward that used to exist: coalescing a drag event
    /// into the open step replaces `steps[position - 1]`, which publishes, and through
    /// the forward that invalidated twenty-six views and the whole menu bar per mouse
    /// event. The lesson was about the BREADTH of the invalidation, not about the
    /// publish — `PanelLayout` states the positive form of it: "a separate object read
    /// only by the column means an expansion change invalidates the column and nothing
    /// else."
    ///
    /// This is that shape. Nothing else in the application observes `HistoryStack`, so a
    /// publish from it reaches exactly this card, and only while the card is open — the
    /// section wrapper takes its body as a closure, so a collapsed History costs a
    /// drag literally nothing. `CommandState` cannot serve instead, and it is worth
    /// saying why since it is the obvious candidate: it holds the two undo LABELS, which
    /// are equality-guarded, so two consecutive steps that happen to share a label
    /// publish nothing — correct for a menu item and silently wrong for a list.
    @ObservedObject private var history: HistoryStack
    @EnvironmentObject private var state: AppState

    /// Spelled out rather than left to the memberwise initializer, which the private
    /// `@State` below would otherwise make inaccessible from `DevelopColumn.swift` —
    /// the same reason `MaskingReturnBar` writes one, and one this machine cannot catch
    /// (parse-only for LumenApp).
    init(history: HistoryStack) {
        self.history = history
    }

    /// Whether the list is showing every step or only the recent ones. View-local and
    /// deliberately not persisted: it is a reading position, not a preference, and a
    /// column that reopens with four hundred rows in it is not what anybody stored.
    @State private var showsEverything = false

    /// HOW MANY ROWS THE LIST DRAWS BEFORE IT ASKS.
    ///
    /// 40 covers a working session on one frame with room — a slider drag is one step,
    /// not two hundred, because the stack coalesces — while keeping the card's height in
    /// the register of the sections above it. The number matters beyond tidiness: this
    /// body is re-evaluated on every mouse event of a drag (see `history` above), so the
    /// rows drawn are the rows rebuilt, and the stack's ceiling is 400.
    static let visibleSteps = 40

    /// The photograph the list is about — the one in the loupe, not the whole edit
    /// target set. A multi-selection edits several frames and shows one, and a history
    /// list has to be about the frame you can see.
    private var url: URL? { state.primarySelection?.id }

    /// Recomputed rather than cached, and that IS the fix for the second trap.
    ///
    /// There is no per-photograph state anywhere in this file — no dictionary keyed by
    /// URL, no `@State` list, nothing to go stale — so switching photographs cannot
    /// show the last one's history: the list is a pure function of the stack and the
    /// current URL, and the URL has already changed by the time this is read.
    /// `HistoryPanelTests` pins the function directly.
    private var entries: [HistoryStack.Entry] {
        guard let url else { return [] }
        return HistoryStack.entries(steps: history.steps, for: url)
    }

    var body: some View {
        let rows = entries
        let current = HistoryStack.currentRow(in: rows, position: history.position)
        // 2, which is the mask list's own row spacing rather than `Lumen.rowGap`: these
        // are single-line rows in a scrolling list, not slider rows with a track and a
        // readout, and the two lists sit in the same column at the same width.
        return VStack(alignment: .leading, spacing: 2) {
            if rows.isEmpty {
                DevelopNote("Nothing to go back to yet — this photograph has not been "
                            + "edited since the folder was opened.", prominent: true)
            } else {
                // NEWEST AT THE TOP, which is the end `position` counts up to and the
                // end the eye starts from. It is also the only order under which the
                // most recent step — the one ⌘Z is about, and the one being made while
                // a slider is under the hand — does not move down the card as the
                // session grows.
                ForEach(drawn(rows)) { item in
                    row(item.entry, index: item.index, current: current,
                        total: rows.count)
                }
                if rows.count > Self.visibleSteps { moreRows(rows.count) }
                footnote
            }
        }
        // A photograph switch is a new list, so a reading position taken on the old one
        // means nothing. Without this, opening "all steps" on a heavily worked frame and
        // arrowing to the next photograph leaves the toggle on for a frame with three.
        .onChange(of: url) { _, _ in showsEverything = false }
    }

    /// A row on its way to the screen, carrying its index in the FULL list.
    ///
    /// The index has to travel with the row rather than be re-derived from the drawn
    /// window: `current` is an index into the whole of this photograph's history, and a
    /// truncated window enumerated on its own would compare a window offset against it
    /// and mark the wrong row — silently, and only once a photograph has more than
    /// `visibleSteps` steps, which is precisely the case nobody tries by hand.
    private struct DrawnRow: Identifiable {
        let index: Int
        let entry: HistoryStack.Entry

        var id: Int { entry.position }
    }

    /// The window of rows to draw — everything, or the most recent `visibleSteps` —
    /// newest first, which is the order they are drawn in.
    private func drawn(_ rows: [HistoryStack.Entry]) -> [DrawnRow] {
        let start = showsEverything ? 0 : max(0, rows.count - Self.visibleSteps)
        return (start..<rows.count).reversed().map {
            DrawnRow(index: $0, entry: rows[$0])
        }
    }

    /// One step.
    ///
    /// - Parameter index: the row's index in the FULL list, so the marks below can be
    ///   compared against `current` whether or not the list is truncated.
    private func row(_ entry: HistoryStack.Entry, index: Int, current: Int?,
                     total: Int) -> some View {
        let isCurrent = index == current
        // Above the cursor: a step that has been made and walked back past. It is still
        // here and still clickable — that is the whole point of the cursor being a
        // cursor — so it is dimmed rather than removed.
        let isAhead = current.map { index > $0 } ?? false
        return Button {
            move(to: entry.position)
        } label: {
            HStack(spacing: 6) {
                // THE MARK IS A DOT, NOT A FILL, and that is a constraint rather than a
                // preference. `lumenHoverable` paints its lift as a `.background`,
                // BEHIND the content, so a row carrying its own opaque selection fill
                // would be the one row in the list that could not answer the pointer —
                // exactly the trap `WorkspaceRail.tabFill` documents. A 5-point accent
                // dot occludes nothing, and it is the same mark the section headers use
                // for "this one carries something".
                Circle()
                    .fill(isCurrent ? Lumen.accent : Color.clear)
                    .frame(width: 5, height: 5)
                Text(entry.title)
                    .font(isCurrent ? .lumenBodyStrong : .lumenBody)
                    .foregroundStyle(titleColor(isCurrent: isCurrent, isAhead: isAhead))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.tertiaryText)
                        .lineLimit(1)
                }
            }
            // The mask list's row padding, because these are the same object at the same
            // scale: a one-line row in a card, in a column 380 points wide.
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The whole "this is clickable" statement in one call — fill and pointing hand
        // together, so a row cannot ship with half of it. `on:` is the PANEL value
        // because that is what this row sits on: the lift is additive, and the control
        // surface's 0.24 is a step for a chip and a jump for a row at 0.20.
        //
        // It is NOT a hover preview, and `LookPanel`'s saved-look row keeps the same
        // distinction for the same reason: previewing needs a path that draws something
        // else on the photograph, and `MaskPanel`'s row is what one looks like when
        // that path exists — `state.hoverMaskOverlay`, with a 120 ms intent hold so a
        // pointer crossing the list does not strobe. There is no equivalent for a
        // recipe, so the tooltip carries the information instead.
        .lumenInteractive(radius: Lumen.radiusChip, on: Lumen.panelValue)
        .help(helpText(entry, isCurrent: isCurrent, isAhead: isAhead, total: total))
    }

    private func titleColor(isCurrent: Bool, isAhead: Bool) -> Color {
        if isCurrent { return Lumen.primaryText }
        return isAhead ? Lumen.tertiaryText : Lumen.secondaryText
    }

    /// What the pointer is told, since the pointer cannot be shown the picture.
    ///
    /// Three facts, and the third is the one that makes the list safe to play with: how
    /// far the jump is, what it lands on, and — going backwards — that the steps you
    /// are stepping over survive the trip. They do: a cursor move records nothing, and
    /// only an EDIT made from the new position truncates the tail.
    private func helpText(_ entry: HistoryStack.Entry, isCurrent: Bool,
                          isAhead: Bool, total: Int) -> String {
        guard !isCurrent else {
            return "Where this photograph is now, of \(total) "
                + (total == 1 ? "step" : "steps")
        }
        let distance = abs(history.position - entry.position)
        let steps = "\(distance) " + (distance == 1 ? "step" : "steps")
        if isAhead { return "Go forward \(steps), to \(entry.title)" }
        return "Go back \(steps), to \(entry.title) — the steps above stay in the list "
            + "until you edit from there"
    }

    /// The door to the rest of the list.
    ///
    /// A count rather than a bare "Show all": the number is the interesting half —
    /// "312 steps" is a session, "3 steps" is a glance — and it is the only place the
    /// panel says how deep the history actually goes.
    private func moreRows(_ total: Int) -> some View {
        Button(showsEverything
               ? "Show the last \(Self.visibleSteps)"
               : "Show all \(total) steps") {
            withAnimation(Lumen.motionFold) { showsEverything.toggle() }
        }
        .buttonStyle(.plain)
        .font(.lumenBody)
        .foregroundStyle(Lumen.accent)
        .lumenClickCursor()
        .padding(.top, 4)
        .help(showsEverything
              ? "Draw only the most recent steps again"
              : "Every step this photograph has, back to the one below which the stack "
                + "stops keeping them")
    }

    /// SAYING THE ONE THING THAT WOULD OTHERWISE BE FOUND OUT THE HARD WAY.
    ///
    /// `AppState` calls `history.clear()` on a folder switch, so this list is the
    /// session's rather than the photograph's, and the file on disk carries no history
    /// at all. A photographer who assumes otherwise loses nothing they can see — the
    /// recipe is saved, every time — but they would plan around a safety net that is not
    /// there. One caption is what that costs to prevent, and `DevelopNote(prominent:)`
    /// is the form this app gives copy that must be read rather than merely available.
    private var footnote: some View {
        DevelopNote("This list is kept while the folder is open; the edits themselves "
                    + "are saved as you make them.", prominent: true)
    }

    /// WALK THE CURSOR, one ⌘Z or ⇧⌘Z at a time, until it arrives.
    ///
    /// Deliberately the menu's own verbs rather than a new one. `AppState.undo()` and
    /// `redo()` are the only paths that put a step back correctly: they restore only the
    /// fields the step recorded, persist through `persist`, re-bin the scopes, refresh
    /// the mask overlay and its thumbnails, and ask for any Vision matte again — five
    /// things a shortcut straight into `HistoryStack.position` would each have to
    /// remember, and the comment on `AppState.apply` records what forgetting the fourth
    /// one looked like. A jump of *n* rows is therefore *n* undos, and it costs *n*
    /// catalog writes; the honest fix for that is a composed move on `AppState` that
    /// applies one merged edit, which is a change to a file this panel does not own.
    ///
    /// Bounded rather than `while`, because `undo()` is a no-op at the bottom of the
    /// stack: if a row's position could ever fall outside the stack, an unbounded loop
    /// would spin the main actor forever. `limit` is the stack's own ceiling, so the
    /// bound cannot be reached by a position that is actually in the list.
    private func move(to position: Int) {
        for _ in 0..<HistoryStack.limit {
            if history.position == position { return }
            if history.position > position { state.undo() } else { state.redo() }
        }
    }
}

#endif

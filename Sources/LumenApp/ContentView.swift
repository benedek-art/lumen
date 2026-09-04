// ContentView.swift
// The three-pane shell: sources on the left, the picture in the middle, develop on the
// right, filmstrip underneath. The layout is deliberately boring — a photo editor's
// chrome should be furniture, and the only thing in the window that is allowed to be
// interesting is the photograph.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    /// `showsMaskPanel` reads `state.currentRecipe.masks`, and `AppState.recipes` is not
    /// `@Published` — so without this declaration that expression has NO invalidation
    /// source (I1-06). It happened to re-body because `addMask` also writes selection
    /// and overlay state, which is coincidence rather than mechanism: the empty →
    /// non-empty transition this line gates is exactly the one the coincidence covers
    /// least reliably, so the floating Masks box could fail to appear when the first
    /// mask was created, or fail to leave when the last was deleted, depending on which
    /// unrelated published property the surrounding action happened to touch.
    ///
    /// The rule is stated in `EditRevision`'s own header and was, until now, enforced by
    /// nothing. `EditRevisionRuleTests` is the mechanism.
    @EnvironmentObject private var edits: EditRevision

    /// THE SIDEBAR CAN BE HIDDEN, AND THAT IS THE LARGEST SINGLE THING THIS WINDOW CAN
    /// DO FOR THE PHOTOGRAPH.
    ///
    /// The composition audit ran the arithmetic and it is counter-intuitive enough to
    /// write down. For an 1800x1169 window, chrome is 41.3% and a 3:2 landscape frame is
    /// 49.35% of the window. Then:
    ///
    ///     delete the top bar AND the status bar  ->  landscape photograph: +0.00 points
    ///     hide the 230pt sidebar                 ->  landscape photograph: +19.95 points
    ///
    /// A landscape photograph in this window is WIDTH-limited. Every horizontal band
    /// removed gives back letterbox, not picture. The sidebar is worth more than every
    /// other composition change combined — and until now the app declared no
    /// `columnVisibility`, no toggle, and no sidebar row in its own 65-row keyboard
    /// reference, so there was no way to get those points at all.
    ///
    /// `Tab` is the key, because it is Lightroom's and has been for twenty years, and
    /// because `KeyGrammar.dispatchedKeys` did not claim it.
    /// THE DIVIDER IS THE HANDLE. Owner: "what if I can have a click and drag? So if I
    /// wanted a specific size, I can click or drag the right side pop-up window either
    /// out more or in more, and the only thing that changes there is the size of the
    /// sliders."
    ///
    /// That last clause is the whole reason this is worth doing, and it needed no work:
    /// a slider row spends a fixed `labelWidth + valueWidth + gaps` on text, so every
    /// point the column gains lands in the TRACK. Dragging from 320 to 520 takes a ±100
    /// control from 0.90 points per unit to 1.90 — from below the threshold where a
    /// one-pixel tremor costs a whole unit, to twice it.
    ///
    /// A 6pt hit region over a 1pt line, because a hairline is not a target; the drawn
    /// rule stays exactly where it was. The width is written on every event so the
    /// column tracks the hand, and persisted once on release — a `UserDefaults` write
    /// per mouse event is the same defect the slider gesture sink exists to avoid.
    private var columnResizer: some View {
        Divider()
            .overlay(Lumen.separator)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    // Through the balanced modifier: the raw pair here pushed on
                    // enter and popped on exit with no record of whether the push had
                    // happened, so a second enter without an exit — which SwiftUI
                    // delivers across a re-layout, and this handle sits on a divider
                    // that re-lays out as the column resizes — left the whole app
                    // wearing a resize cursor.
                    .lumenScrubCursor()
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                // Leftward drag widens the column, so the delta is
                                // negated: the pointer and the edge move together.
                                let next = state.developPanelWidth - drag.translation.width
                                state.developPanelWidth = Swift.min(
                                    Swift.max(next, Lumen.minimumPanelWidth),
                                    Lumen.maximumPanelWidth)
                            }
                            .onEnded { _ in state.persistDevelopPanelWidth() })
            }
    }

    /// Whether the floating Masks box is on screen.
    ///
    /// Masking has to be the current tool, there has to be a mask to list, and the
    /// photographer must not have dismissed it. The middle condition is the owner's
    /// rule verbatim — the box "comes out when there is a mask" rather than sitting
    /// there empty waiting for one.
    private var showsMaskPanel: Bool {
        // `PanelLayout.shared` read directly rather than observed, matching
        // `showsDevelopColumn` two properties down — this view deliberately does not
        // observe `PanelLayout`, and the workspace change that flips `isMasking` already
        // republishes through `state`.
        PanelLayout.shared.layout.isMasking && state.maskPanelVisible
            && !state.currentRecipe.masks.isEmpty
    }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { state.sidebarVisible ? .all : .detailOnly },
            set: { state.sidebarVisible = ($0 != .detailOnly) })) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                // No rule under the bar: it sits on `panel` 0.20 and the photo's field
                // below is `surroundCanvas` 0.165, so the surfaces already divide
                // themselves (design audit §1.1, and Phase 1's rule for the develop
                // column's own bands).
                // THE CHROME OBEYS THE SURROUND CONTROLS. Removed at the `out` rung
                // rather than drawn at zero opacity, so nothing invisible can take a
                // click; dimmed at `dim` and in assessment mode, where it is still
                // meant to be reachable. `chromeOpacity` is 1 and `chromeHidden` false
                // in ordinary use, so every one of these is a no-op until a key is
                // pressed.
                if !state.chromeHidden {
                    FilterBar()
                        .opacity(state.chromeOpacity)
                }
                HStack(spacing: 0) {
                    centre
                        // The clipping panel and the hold badge ride the centre pane
                        // rather than the develop column, because the develop column
                        // is loupe-and-compare only and a keep/kill call is made in
                        // the grid as often as anywhere else.
                        .overlay(alignment: .topTrailing) {
                            if state.showRawTruth {
                                RawTruthPanel()
                                    .padding(10)
                            }
                        }
                        // THE MASKS BOX, over the photograph on the RIGHT — beside
                        // the histogram, which is where the owner asked for it twice and
                        // where he dragged it the first time he saw it on the left. It appears on its own once a photograph
                        // has a mask ("a separate box that comes out when there is a
                        // mask"), minimizes to its title bar, drags anywhere inside the
                        // pane, and fades out of the way while the hand is on the
                        // picture. `GeometryReader` supplies the pane's size so the drag
                        // can be clamped to it — a panel dragged off the window is a
                        // panel you cannot get back.
                        .overlay(alignment: .topTrailing) {
                            if showsMaskPanel {
                                // The reader fills the pane so the drag can be clamped
                                // against it; it draws nothing itself, so only the card
                                // inside it ever takes a click.
                                //
                                // THE INNER `.frame(alignment:)` IS LOAD-BEARING and its
                                // absence is why the panel opened on the LEFT, which was
                                // the owner's first complaint on first use. A
                                // `GeometryReader` is greedy: it takes every point it is
                                // offered, so `.overlay(alignment: .topTrailing)` was
                                // top-trailing-aligning a view that already filled the
                                // whole pane — a no-op — and the reader then placed its
                                // own child at its own top-LEADING corner, which is what
                                // a `GeometryReader` does. The alignment has to be
                                // restated INSIDE the reader, against the reader's own
                                // filled frame, or it does not happen at all.
                                GeometryReader { proxy in
                                    MaskFloatingPanel(bounds: proxy.size)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                                               alignment: .topTrailing)
                                        // Out from under the clipping panel, which owns
                                        // this corner when it is showing. Both are
                                        // top-trailing and a silent overlap reads as a
                                        // broken window rather than as two panels.
                                        .padding(.top, state.showRawTruth ? 118 : 0)
                                }
                            }
                        }
                        .overlay(alignment: .bottom) { inspectionBadge }
                    if showsDevelopColumn, !state.chromeHidden {
                        columnResizer
                        DevelopPanel()
                            .frame(width: state.developPanelWidth)
                            .opacity(state.chromeOpacity)
                    }
                    // THE RAIL, on the window's right edge, outside the `if` above —
                    // which is the whole point. Navigation used to live inside the
                    // develop column, so Cull (no column) took the tabs with it, and
                    // `WorkspaceReturnBar` had to re-draw them over the grid (docs/30
                    // §7.7's stranding trap, patched at 538eb08). The rail belongs to
                    // the window: it is on screen in every view mode and every
                    // workspace, masking included, so no state of the app lacks visible
                    // navigation. It observes `PanelLayout` itself — this view still
                    // deliberately does not.
                    if !state.chromeHidden {
                        Divider().overlay(Lumen.separator).frame(width: 1)
                        WorkspaceRail()
                            .opacity(state.chromeOpacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.showFilmstrip, !state.photos.isEmpty, !state.chromeHidden {
                    Divider().overlay(Lumen.separator)
                    // No fixed frame here any more: the strip sizes itself from its
                    // own persisted height step (see `FilmstripView`).
                    FilmstripView()
                        .opacity(state.chromeOpacity)
                }
                if !state.chromeHidden {
                    StatusBar()
                        .opacity(state.chromeOpacity)
                }
            }
            // THE FIELD THE PHOTOGRAPH SITS ON, which is a control rather than a
            // constant now: `surroundCanvas` normally, black at the lights-out rung,
            // and ISO 12646's mid-grey in assessment mode — where it wins over black,
            // because black is the wrong field for judging tone and judging tone is
            // the only thing assessment mode is for. `ViewingConditions` holds the
            // rule and the argument.
            .background(state.surroundColor)
        }
        .frame(minWidth: 1180, minHeight: 720)
        .keyboardGrammar()
        // Every slider and wheel in the tree reports its gesture through this one
        // hook (RenderRequest.swift), so a drag defers per-event catalog writes and
        // scope re-bins to its release without ninety call sites knowing about it.
        // The closure is STORED on the state, not built here. An environment value is
        // compared by identity, and a closure allocated inside `body` is a new
        // identity on every body pass — so every descendant reading this key (every
        // slider, both canvases, the wheels, the curve, the zones) was invalidated
        // unconditionally on each pass. Today the global re-body hides that; the
        // moment AppState moves to `@Observable` it would BECOME the bug.
        .environment(\.sliderGestureChanged, state.sliderGestureSink)
        // The focus half of the same story (docs/28 Phase 7): a slider reports taking
        // and losing keyboard focus so `KeyDispatcher` hands the arrows back. Stored on
        // the state for the same reason as the gesture sink — a closure built here would
        // be a new identity on every body pass, invalidating every slider in the tree.
        .environment(\.sliderFocusChanged, state.sliderFocusSink)
        // AN OVERLAY, NOT A SHEET, and deliberately not routed through the presenter
        // below. A sheet is modal, animates in, and dims what is behind it — right for
        // Export, wrong for a thing you open, type four letters into and dismiss. It is
        // also the reason it does not share `activeSheet`: the palette must be able to
        // open while a sheet is up without either of them fighting for the presenter.
        //
        // The scrim takes a click so that dismissing is the obvious thing anywhere
        // outside it, which is the grammar every other ⌘K palette has taught.
        .overlay {
            if state.showControlPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { state.showControlPalette = false }
                    ControlPalette()
                        // Below the top rather than centred: a palette that opens over
                        // the middle of the frame covers the photograph it is about.
                        .padding(.top, 120)
                }
            }
        }
        // One presenter, not three: chained `.sheet` modifiers on a single view are
        // not reliably independent, and "Export silently does nothing because the
        // keyboard sheet flag is also set" is not a failure anybody would diagnose.
        .sheet(item: Binding(get: { state.activeSheet },
                             set: { state.activeSheet = $0 })) { sheet in
            switch sheet {
            case .keyReference: KeyReferenceSheet()
            case .export: ExportSheet()
            case .ingest: IngestSheet()
            }
        }
    }

    private var showsDevelopColumn: Bool {
        ContentView.showsDevelopColumn(layout: PanelLayout.shared.layout, state: state)
    }

    /// Whether the column is on screen RIGHT NOW — workspace, view mode and selection.
    ///
    /// This used to be one of two questions, the other belonging to a
    /// `WorkspaceReturnBar` that re-drew the tab strip over the grid whenever the column
    /// was gone. The rail retired that bar — navigation sits on the window's edge in
    /// every state — so this is the only question left, and it is only about the column.
    ///
    /// CULL DRAWS NO COLUMN, and the emptiness is the feature rather than a hidden panel:
    /// docs/12 §12.1 asks for "Photo Mechanic's emptiness without an architectural wall
    /// behind it", which is why `Workspace.cull` has an empty section list instead of the
    /// column being suppressed by some separate flag. `WorkspaceLayout.showsDevelopColumn`
    /// is that list being empty, asked as a question.
    static func showsDevelopColumn(layout: WorkspaceLayout, state: AppState) -> Bool {
        layout.showsDevelopColumn
            && state.primarySelection != nil
            && (state.viewMode == .loupe || state.viewMode == .compare)
    }

    /// What is on screen while `[` or `]` is held. A momentary change to the picture
    /// that does not announce itself is indistinguishable from an edit the user made by
    /// accident, and this one deliberately does not reach the recipe — so the badge is
    /// the only thing that says why the frame looks different.
    @ViewBuilder
    private var inspectionBadge: some View {
        if let hold = state.inspectionHold {
            LumenBadge(text: hold.badge(stops: InspectionHolds.defaultStops),
                       emphasized: true)
                .padding(.bottom, 12)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var centre: some View {
        // `allPhotos`, not `photos`: an open folder whose filter or album currently
        // matches nothing is not an app with no folder open, and saying "Open a folder
        // of photographs" to somebody who has one open is how a filter looks like a
        // crash. The grid draws its own "nothing matches, here is Clear Filter"
        // overlay, which this condition used to make unreachable.
        if state.allPhotos.isEmpty {
            EmptyState()
        } else {
            switch state.viewMode {
            case .grid:
                GridView()
            case .loupe:
                if let photo = state.primarySelection {
                    LoupeView(photo: photo)
                } else {
                    GridView()
                }
            case .compare, .survey:
                CompareView()
            }
        }
    }
}

// MARK: - Sidebar

/// Sources on the left: the open folder, the culling counts, and — new — the three
/// catalog structures that had complete store APIs and no way in from the app at all:
/// albums, keywords and stacks.
///
/// The keyboard verbs here are Command-modified — `⌘G`, `⇧⌘G`, `⇧⌘K` — attached to
/// visible controls and every one of them disabled, visibly, when there is nothing for
/// it to act on.
///
/// ALBUMS IS THE EXCEPTION AND IT IS NOT A CHORD. This comment used to say that `⌘B`
/// was free and spend it on the album button, because bare `B` was the Basic panel at
/// the time. K-104 took `B` and `L` back for docs/10 §10.9's culling grammar, so
/// add-to-album is the bare `B` in `Keymap.swift` and `⌘B` is the assessment surround
/// in the View menu. Nothing in this file may attach `⌘B` again: two attachments of one
/// chord is a dead shortcut, and `KeyGrammarAttachmentTests` in LumenAppTests now fails
/// when any chord is attached twice.
private struct Sidebar: View {
    @EnvironmentObject var state: AppState

    @State private var newAlbumName: String = ""
    @State private var newKeyword: String = ""
    @FocusState private var keywordFieldFocused: Bool

    /// ⇧⌘K now fires from the Scene, which cannot reach a view-local `@FocusState`.
    /// `KeywordEntry.shared` is a counter it bumps and this column watches; only the
    /// section that draws the field can put the cursor in it. Named `keywordRequests`
    /// rather than `keywordEntry` because this struct already has a `keywordEntry`
    /// view below.
    @ObservedObject private var keywordRequests = KeywordEntry.shared

    // Expansion is `@AppStorage`, deliberately, and never a published field on
    // `AppState` (docs/28 §5.5): it persists for free and it invalidates this column
    // and nothing else, where a publish on AppState re-bodies the whole window.
    //
    // Keywords and Stack start CLOSED because they are inert until a photo is selected
    // or a stack exists, and on a fresh folder they were two full-height sections of
    // "nothing here yet". Defaults, not options, set perceived complexity — docs/12
    // §12.12 says so about darktable and it is just as true of a sidebar. Neither is
    // ever secret: a closed section whose contents hold state wears the accent dot.
    //
    // THE RULE NOW RUNS THE OTHER WAY, and the fold was only ever half of it. A
    // `.keyboardShortcut` on a view that is not in the hierarchy is never registered,
    // so collapsing a section that contains one leaves the shortcut in the source,
    // still passing `KeyGrammarTests` — which reads shortcuts as TEXT — and dead in
    // the app. Keeping every shortcut-bearing button above the fold fixed that case
    // and left the bigger one open: ⌥⌘S hides this entire column, and a chord attached
    // anywhere in it dies with the column. That is not a fold problem, and no
    // arrangement inside these sections can solve it.
    //
    // So no chord is attached here at all any more. ⌘G, ⇧⌘G and ⇧⌘K live in the
    // Scene's `CommandMenu("Photo")`, where nothing on screen can take them away, and
    // ⇧⌘K shows the sidebar before it asks for the cursor. The buttons stay, and their
    // `.help` still names the chord — the section still leads with its one-click entry
    // point, which is what docs/12 §12.12 asked for on its own merits. What is gone is
    // the assumption that this column is always there to hold a key equivalent.
    @AppStorage("sidebar.library") private var libraryExpanded = true
    @AppStorage("sidebar.albums") private var albumsExpanded = true
    @AppStorage("sidebar.keywords") private var keywordsExpanded = false
    @AppStorage("sidebar.stack") private var stackExpanded = false


    var body: some View {
        ScrollView {
            // Four sections on the SAME header the develop panels use, which is most of
            // the answer to "the side bar with the files is hard to understand": it was
            // five unrelated jobs — an action, a path, three counts, three catalog
            // structures and a help button — stacked with hairlines between them and no
            // grouping, in a column whose own idiom appeared nowhere else in the app.
            // One idiom, four groups, and the rules are gone the way they went in the
            // panels (Phase 1): the header carries its own 20 pt boundary.
            //
            // (It said 16 for as long as `topRhythm` has been 20 — raised after "everything
            // is super back to back to back … I get a fatigue when I scroll down".)
            //
            // The FOLDER now sits above all four rather than inside the first. It is what
            // the whole column is about, so it reads as the column's title; and it took
            // the third of "Library"'s three jobs out of a section that is now just the
            // flag axis.
            VStack(alignment: .leading, spacing: 2) {
                folderHeader
                librarySection
                if state.isCatalogAvailable {
                    albumsSection
                    keywordsSection
                    stackSection
                }

                if let catalogStatus = state.catalogStatus {
                    // Was .orange — the one chroma violation in the chrome (Law 7:
                    // zero-chroma everywhere the photo isn't). Urgency reads through
                    // primary-value text in a quiet chrome just as well.
                    Text(catalogStatus)
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
            // A VStack inside a ScrollView is only as wide as its widest child, and the
            // album rows put their count on a trailing Spacer — without this they draw
            // the count hard against the name instead of at the column edge.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // docs/30: every scroll view in the app is silent. A legacy scroller insets
        // its content, so an indicator appearing is a relayout of everything inside it.
        .scrollIndicators(.never)
        .background(Lumen.panelBackground)
    }

    // MARK: Library

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            LumenSectionHeader(title: "Library", symbol: "flag.fill",
                               isExpanded: $libraryExpanded)
            if libraryExpanded { counts }
        }
    }

    /// WHAT YOU ARE LOOKING AT, as the column's title rather than a row inside it.
    ///
    /// It was the loudest element in the sidebar — `lumenBodyStrong`, the only medium
    /// weight in the column — and the only one you could not click, hover, right-click or
    /// read to the end. A two-line volume path at 10 pt, truncated from the head, with no
    /// tooltip carrying the whole of it. So the thing the eye landed on first was the one
    /// thing that answered nothing, sitting in a list of things that answer clicks.
    ///
    /// Moving it out of "Library" also settles what that section is FOR. It held three
    /// jobs — an action, a status readout and three filters — and now holds one: the flag
    /// axis. The folder is not a filter and never was; it is the subject the whole column
    /// is about.
    ///
    /// The path finally does something. Click reveals the folder in Finder, the tooltip
    /// carries it in full, and the context menu offers both plus the folder change — three
    /// affordances on a block that had none, none of them a keyboard-only secret because
    /// the button beside it does the one that matters.
    private var folderHeader: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(state.folderURL?.lastPathComponent ?? "No folder open")
                    .font(.lumenBodyStrong)
                    .foregroundStyle(state.folderURL == nil
                                     ? Lumen.tertiaryText : Lumen.primaryText)
                    .lineLimit(1)
                if let folder = state.folderURL {
                    // One line, not two. At 230 pt a second line of head-truncated path
                    // buys about twenty more characters of a string whose informative end
                    // is already visible, and costs the header its shape.
                    Text(folder.deletingLastPathComponent().path)
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            Button {
                state.chooseFolder()
            } label: {
                Image(systemName: "folder")
                    .font(.lumenGlyphCaption)
                    // A real target. The glyph's own bounds are 10 pt and this app's own
                    // convention for a glyph-only button is a 16 pt box with an explicit
                    // content shape.
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Lumen.secondaryText)
            .lumenClickCursor()
            .help("Choose a different folder")
        }
        .padding(.horizontal, 6)
        .frame(height: Lumen.rowHeight)
        .contentShape(Rectangle())
        .help(state.folderURL?.path ?? "No folder open")
        .onTapGesture { revealFolderInFinder() }
        .lumenClickCursor(state.folderURL != nil)
        .contextMenu {
            Button("Reveal in Finder") { revealFolderInFinder() }
                .disabled(state.folderURL == nil)
            Button("Copy Path") {
                guard let path = state.folderURL?.path else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            .disabled(state.folderURL == nil)
            Divider()
            Button("Open Folder…") { state.chooseFolder() }
        }
        .accessibilityLabel(Text(state.folderURL
                                 .map { "Folder \($0.lastPathComponent), \($0.path)" }
                                 ?? "No folder open"))
    }

    private func revealFolderInFinder() {
        guard let folder = state.folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// The culling counts, and they are CONTROLS now rather than readouts.
    ///
    /// A row reading "Picked  14" beside an album list that selects on click is a row a
    /// photographer will click, and it did nothing — which is most of what "hard to
    /// understand" meant here. Every other library sidebar in the field (Lightroom's
    /// collections, Capture One's filters, Finder's tags) answers a click on a count by
    /// showing you those items, so this one does too: it writes the flag criterion the
    /// Filter popover writes, and the two stay in step because both read `state.filter`.
    ///
    /// "Showing" is gone: the status bar now says "12 of 239" beside the sentence that
    /// explains why, which is a better home for a derived number than a list of sources.
    private var counts: some View {
        // Memoised in AppState.cullCounts; these were two more full passes per body.
        let picked = state.cullCounts.flags[.picked] ?? 0
        let rejected = state.cullCounts.flags[.rejected] ?? 0
        // Named and typed rather than written as bare `[.picked]` literals at four
        // sites: `LumenApp` compiles only on macOS and the surface checker misses
        // everything type-level, so an inference that needs help is an inference this
        // machine cannot find out about.
        let unflagged = state.cullCounts.flags[.none] ?? 0
        let picks: Set<PhotoFlag> = [.picked]
        let rejects: Set<PhotoFlag> = [.rejected]
        let unflaggeds: Set<PhotoFlag> = [.none]
        let noFlag: Set<PhotoFlag> = []
        // `Lumen.rowGap`, not a bare 1. The rows are 24 pt now and a one-point gutter
        // between them read as a single block of text rather than as a list.
        return VStack(alignment: .leading, spacing: Lumen.rowGap) {
            // These three set the FLAG criterion and nothing else, which the help text
            // says out loud: a rating or a label filter set elsewhere still applies, so
            // "All photos" means "no flag restriction", not "clear everything". ⌘\ is
            // what clears everything, and the status bar's sentence always says which
            // it is.
            sourceRow(title: "All photos", count: state.allPhotos.count,
                      isSelected: state.filter.flags.isEmpty, isTarget: false,
                      help: "No flag restriction — any other criteria still apply") {
                state.filter.flags = noFlag
            }
            sourceRow(title: "Picked", count: picked,
                      isSelected: state.filter.flags == picks, isTarget: false,
                      help: "Show only picks") {
                state.filter.flags = state.filter.flags == picks ? noFlag : picks
            }
            // UNFLAGGED, which the Filter bar has had all along and this list did not.
            //
            // `FilterBar` offers all three chips against the same `state.filter.flags`,
            // so the sidebar was the poorer copy of a control three inches above it —
            // and "the ones I have not looked at yet" is the single most useful scope in
            // a first cull pass. docs/10 §10.4 names it among the counts the cull HUD is
            // specified to show.
            sourceRow(title: "Unflagged", count: unflagged,
                      isSelected: state.filter.flags == unflaggeds, isTarget: false,
                      help: "Show only frames you have not flagged either way") {
                state.filter.flags = state.filter.flags == unflaggeds ? noFlag : unflaggeds
            }
            sourceRow(title: "Rejected", count: rejected,
                      isSelected: state.filter.flags == rejects, isTarget: false,
                      help: "Show only rejects") {
                state.filter.flags = state.filter.flags == rejects ? noFlag : rejects
            }
        }
    }

    // MARK: Albums

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // THE VERB IS IN THE HEADER NOW, and that is what makes the triangle honest.
            //
            // It sat outside the `if albumsExpanded` — so a section drawn CLOSED still
            // showed a row underneath it. The original reason was real: a
            // `.keyboardShortcut` on a view outside the hierarchy is never registered, so
            // a chord-bearing button inside a section that ships closed is a dead chord.
            // That reason went when the three chords moved to the Scene's commands; the
            // shape stayed, and the shape tells the photographer the fold means something
            // it does not.
            //
            // It holds NO chord. It held ⌘B until K-104 settled the keymap the other way
            // round: bare `B` is add-to-album (`Keymap.swift`, `case "b"`) and ⌘B is the
            // assessment surround. Both were attached and only one can win — the main menu
            // offers its key equivalent before the window's hierarchy sees the event — so
            // this button's ⌘B was a dead shortcut whose `.help` advertised it anyway. The
            // tooltip names the bare key it actually has, and names the ALBUM too, which
            // the title used to carry and a glyph cannot.
            LumenSectionHeader(title: "Albums", symbol: "photo.stack",
                               isExpanded: $albumsExpanded,
                               isModified: state.selectedCollectionID != nil,
                               onAction: { state.addSelectionToTargetCollection() },
                               actionSymbol: "tray.and.arrow.down",
                               actionHelp: "\(addToTargetTitle) (B)",
                               actionEnabled: state.targetCollection != nil
                                   && !state.editTargets.isEmpty)

            if albumsExpanded { albums }
        }
    }

    private var albums: some View {
        VStack(alignment: .leading, spacing: 4) {
            // "WHOLE FOLDER", not "This folder", and the rename is the fix.
            //
            // It read identically to "All photos" one section above — same shape, same
            // 239, same treatment — and did something entirely different: "All photos"
            // clears the FLAG criterion, this clears the ALBUM. Two rows that look the
            // same and act on different axes is a trap, and it is the visible half of
            // J2-03, whose other half (the counts describe the folder and ignore the
            // album selection) is its own landing.
            //
            // It also gains a tooltip. Every album row passed no `help:` at all, so
            // `sourceRow`'s `.help(help ?? "")` rendered an empty one.
            sourceRow(title: "Whole folder", count: state.allPhotos.count,
                      isSelected: state.selectedCollectionID == nil,
                      isTarget: false,
                      help: "Every photograph in the folder — no album restriction") {
                state.selectedCollectionID = nil
            }

            ForEach(state.collections) { album in
                sourceRow(title: album.name, count: album.count,
                          isSelected: state.selectedCollectionID == album.id,
                          isTarget: album.isTarget,
                          help: album.isTarget
                              ? "Show \(album.name) — the target album, where B adds"
                              : "Show \(album.name)") {
                    state.selectedCollectionID = album.id
                }
                .contextMenu {
                    Button("Make Target Album") { state.setTargetCollection(album.id) }
                    Button("Remove Selection from \(album.name)") {
                        state.removeSelectionFromCollection(album.id)
                    }
                }
            }

            HStack(spacing: 4) {
                TextField("New album", text: $newAlbumName)
                    .textFieldStyle(.plain)
                    .font(.lumenBody)
                    .onSubmit { createAlbum() }
                Button {
                    createAlbum()
                } label: {
                    Image(systemName: "plus")
                        .font(.lumenGlyphCaption)
                        // The glyph's own bounds are no hit target — 10 points square was
                        // the whole of it. 16 with an explicit content shape is what every
                        // other glyph-only button in this app gets.
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Lumen.secondaryText)
                .lumenClickCursor()
                .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Lumen.controlBackground)
            // A WELL, not a clipped rectangle. `LumenSurface.swift` names text fields as
            // the case `lumenWell` exists for — the light lands on the far lip, so the
            // highlight sits along the BOTTOM and a dark inner edge sits along the top,
            // which is what makes a field read as somewhere you type into rather than as
            // a grey rectangle that happens to hold a cursor. The modifier had two call
            // sites in the app and neither was a field.
            //
            // And the radius is the token now: this was a hardcoded 4, from before there
            // were three radii, so it stayed at the Aqua proportion while every surface
            // around it moved to 9 and 14.
            .lumenWell(radius: Lumen.radiusControl)
        }
    }

    private var addToTargetTitle: String {
        guard let target = state.targetCollection else { return "No target album" }
        return "Add to \(target.name)"
    }

    private func createAlbum() {
        state.createCollection(named: newAlbumName)
        newAlbumName = ""
    }

    // MARK: Keywords

    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            LumenSectionHeader(title: "Keywords", isExpanded: $keywordsExpanded,
                               isModified: !state.primaryKeywords.isEmpty)
            // INSIDE THE FOLD, both of them. The field used to sit above it, so a
            // section drawn CLOSED still showed a text field — and the `.onChange` below
            // already says why that was never wanted: "a collapsed section is a strange
            // place to land a caret". ⇧⌘K is unaffected; it opens the section first and
            // then asks for the cursor, which is the order `PasteboardCarveOutTests`
            // pins in `LumenApp.swift`.
            if keywordsExpanded {
                keywordEntry
                keywords
            }
        }
        // ⇧⌘K asked for the cursor. The Scene has already shown this column; opening
        // the section is this view's half of the job, because `keywordEntry` is drawn
        // whether or not the section is expanded but a collapsed section is a strange
        // place to land a caret.
        .onChange(of: keywordRequests.requests) { _, _ in
            keywordsExpanded = true
            keywordFieldFocused = true
        }
    }

    private var keywordEntry: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                TextField("Add keyword", text: $newKeyword)
                    .textFieldStyle(.plain)
                    .font(.lumenBody)
                    .focused($keywordFieldFocused)
                    .onSubmit { addKeyword() }
                Button {
                    addKeyword()
                } label: {
                    Image(systemName: "plus")
                        .font(.lumenGlyphCaption)
                        // The glyph's own bounds are no hit target — 10 points square was
                        // the whole of it. 16 with an explicit content shape is what every
                        // other glyph-only button in this app gets.
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Lumen.secondaryText)
                .lumenClickCursor()
                .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Lumen.controlBackground)
            // A WELL, not a clipped rectangle. `LumenSurface.swift` names text fields as
            // the case `lumenWell` exists for — the light lands on the far lip, so the
            // highlight sits along the BOTTOM and a dark inner edge sits along the top,
            // which is what makes a field read as somewhere you type into rather than as
            // a grey rectangle that happens to hold a cursor. The modifier had two call
            // sites in the app and neither was a field.
            //
            // And the radius is the token now: this was a hardcoded 4, from before there
            // were three radii, so it stayed at the Aqua proportion while every surface
            // around it moved to 9 and 14.
            .lumenWell(radius: Lumen.radiusControl)

            // ⌘⇧K puts the cursor in the field rather than applying anything: the verb
            // a photographer wants from a keyword shortcut is "let me type one". It also
            // opens the section, so the keywords already on the photo come into view
            // with the cursor.
            //
            // It was ⌘K until the control palette took that key (docs/29 §2.2, the
            // owner's decision). Keywording is a deliberate, low-frequency act performed
            // with the sidebar already open, so a modifier costs it nothing; the palette
            // is the opposite, and its whole value is that ⌘K is the key your hands
            // already know from every other tool.
            // "KEYWORD THE SELECTION" IS GONE, because it did not. Its whole body was
            // `keywordsExpanded = true; keywordFieldFocused = true` — it opened the
            // section it already sat in and moved the caret into the field beside it.
            // A verb-shaped control whose label names an action it does not perform is
            // worse than no control: it is a row a photographer clicks and then has to
            // work out what happened.
            //
            // Nothing is lost. The field IS the affordance, ⇧⌘K in the Photo menu still
            // shows this column and focuses it (`LumenApp.swift`), and the section is
            // one triangle away rather than behind a button that only opened it.
        }
    }

    /// What is already on the photo — the part that folds away, because on a fresh
    /// folder with nothing selected it is a section-height way of saying "nothing yet".
    private var keywords: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.primaryKeywords.isEmpty {
                Text(state.primarySelection == nil
                     ? "Select a photo to keyword it"
                     : "None on this photo")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.tertiaryText)
            } else {
                ForEach(state.primaryKeywords, id: \.self) { word in
                    HStack(spacing: 4) {
                        Text(word)
                            .font(.lumenBody)
                            .foregroundStyle(Lumen.primaryText)
                        Spacer()
                        Button {
                            state.removeKeyword(word)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.lumenGlyphCaption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Lumen.secondaryText)
                        .help("Remove \(word) from the selection")
                    }
                }
            }
        }
    }

    private func addKeyword() {
        state.addKeyword(newKeyword)
        newKeyword = ""
    }

    // MARK: Stacks

    private var stackSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The verb is in the header, for the same reason Albums' is: it sat outside
            // the `if stackExpanded` and this section SHIPS CLOSED, so the fold's triangle
            // was drawn shut over a visible row on every fresh folder.
            LumenSectionHeader(title: "Stack", symbol: "square.stack",
                               isExpanded: $stackExpanded,
                               isModified: state.primaryStack != nil,
                               onAction: { state.stackSelection() },
                               actionSymbol: "square.stack",
                               actionHelp: "Group the selection into one stack (⌘G)",
                               actionEnabled: state.selection.count >= 2)

            // ⇧⌘G used to be held here by a zero-size invisible button, because a
            // `.keyboardShortcut` on a view that is not in the hierarchy is never
            // registered and this section ships closed. That fixed the fold and left
            // the larger hole open: every chord in this column dies with ⌥⌘S, which
            // hides the whole sidebar. ⌘G, ⇧⌘G and ⇧⌘K now live in the Scene's
            // commands, where nothing on screen can take them away, and the invisible
            // button is gone with them.

            if stackExpanded { stacks }
        }
    }

    private var stacks: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let stack = state.primaryStack {
                Text("\(stack.memberCount) frame\(stack.memberCount == 1 ? "" : "s")"
                     + " · \(stack.collapsed ? "collapsed" : "expanded")"
                     + (stack.isPick ? " · this is the pick" : ""))
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                // These two have NO bare key and this column is their only home —
                // `docs/29-keymap-reconciliation.md:40` settled that when `S` and `⇧S`
                // went to Scopes and Soft-proof, and recorded it as "a real if small
                // loss, not a redundancy". So they are not candidates for moving to a
                // menu and quietly dropping.
                SidebarVerb(title: stack.collapsed ? "Expand Stack" : "Collapse Stack",
                            // Both names already ship in this app. `Image(systemName:)`
                            // handed a name the system does not know draws NOTHING — no
                            // placeholder, no log — so a symbol chosen from memory is a
                            // 14 pt hole nobody notices until a screenshot.
                            systemImage: stack.collapsed
                                ? "square.grid.2x2"
                                : "square.stack.3d.down.forward",
                            help: stack.collapsed
                                ? "Show every frame in this stack"
                                : "Show this stack as one frame") {
                    state.toggleStackCollapsed()
                }

                SidebarVerb(title: "Promote to Pick", systemImage: "arrow.up.square",
                            help: "Make this frame the one the collapsed stack shows") {
                    state.promoteStackPick()
                }
                .disabled(stack.isPick)

                // Unstack's BUTTON stays here beside the other stack verbs, where it
                // reads; ⇧⌘G moved above the fold. See the note there.
                SidebarVerb(title: "Unstack", systemImage: "square.on.square.dashed",
                            help: "Unstack (⇧⌘G)") {
                    state.unstackSelection()
                }
            } else {
                // THIS DREW NOTHING AT ALL, and that is not what it looked like.
                //
                // It was a `DevelopNote`, whose `prominent` defaults to false, and
                // `prominent == false` means the body is empty — deliberately, because in
                // a develop panel the sentence belongs on the `.help()` of the control it
                // describes and every `LumenSlider` already carries one. That reasoning
                // is right and it does not reach here: an expanded Stack section with no
                // stack has NO control in it, so there was nothing to hover, and opening
                // the section gave you a blank box.
                //
                // One caption line, no mark, which is the shape `MaskPanel` settled on
                // for exactly this case and the shape the Keywords section above already
                // uses. `LumenEmptyState` is the house form, but it centres its stack and
                // fills its container, which is wrong in a 230 pt column that has three
                // other sections in it.
                Text("No stacks yet. Select two or more frames and stack them.")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }

    // MARK: Pieces

    // `sectionLabel` is gone with the four sections that used it: this column now takes
    // `LumenSectionHeader` like every panel does. It was one of the three separately
    // hand-rolled caps-label styles the audit counted (§1.2), and at 9 pt it was under
    // the type floor the same audit set. One idiom, one size, one place to change it.

    /// A row in the source list: a place you can be, with how many frames are there.
    ///
    /// THE POINTER TREATMENT IS THE POINT. `LumenSectionHeader` states the rule this row
    /// was breaking — "the pointer treatment is the row's claim to be a control, and this
    /// row is not one" — and every comparable row in the app makes that claim through
    /// `lumenInteractive`: the history list, the mask list, the menu items, the develop
    /// footer buttons. This one made it nowhere. No hover fill, no pointing hand, no
    /// `contentShape`; the hit region was whatever `Color.clear` happened to cover. The
    /// owner's report was "most of the buttons don't look like buttons", and for the four
    /// rows that ARE buttons that was not an impression, it was the literal state of the
    /// modifier stack.
    ///
    /// It is the mirror of the affordance lie this app already fixed once. The header's
    /// hover fill is gated on `isInteractive` because "a label that lights up while doing
    /// nothing" is a promise broken. A control that never lights up at all is the same
    /// promise, unmade.
    ///
    /// UNSELECTED IS NOT DISABLED. The row used to render its title in `secondaryText`
    /// until it was chosen, which is this app's disabled idiom — so a list of four
    /// scopes read as four unavailable ones and a chosen one. Selection is carried by the
    /// fill, which is what a fill is for; the title stays legible throughout and only the
    /// COUNT is secondary, because the count is a fact about the row rather than the row.
    ///
    /// 24 pt is not a taste. `docs/audit-2026-09/PLAN.md:93` records it as an owner
    /// decision — "Row pitch: 24 pt, one pitch everywhere" — and this row was the
    /// divergence, at 11 pt of text plus 2 of padding.
    private func sourceRow(title: String, count: Int, isSelected: Bool,
                           isTarget: Bool, help: String? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isTarget {
                    Image(systemName: "target")
                        .font(.lumenGlyphCaption)
                        .foregroundStyle(isSelected ? Lumen.primaryText : Lumen.secondaryText)
                }
                Text(title)
                    .font(.lumenBody)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    // `.lumenCaptionNumeric` IS `.lumenCaption.monospacedDigit()`, which
                    // is what this said for as long as the token existed beside it.
                    .font(.lumenCaptionNumeric)
                    .foregroundStyle(isSelected ? Lumen.primaryText : Lumen.secondaryText)
            }
            .padding(.horizontal, 6)
            .frame(height: Lumen.rowHeight)
            .foregroundStyle(Lumen.primaryText)
            // ACCENT, AND NO LEADING BAR. Chosen by the owner against a real photograph after
            // seeing both — the bar "reads as a stray tick", which it does, because the fill
            // behind it was too weak to contain it.
            //
            // `docs/25-design-audit.md:69` asked for exactly this: every selected state in
            // the app is "a ~30% white wash", and "a faint lighter wash on flat gray reads as
            // HOVER or DISABLED, not selected". `Lumen.accent` is documented at
            // `LumenControls.swift:171` as the colour for "state that must be noticed".
            //
            // 0.30 rather than solid: this is a row-sized area and the token's own note says
            // marker scale, never area. Over the 0.20 panel it reads as deliberate colour
            // without becoming a colour field beside the photograph — and it clears the 0.27
            // hover step by far more than the 0.28 grey wash it replaces, which sat one point
            // off hover and lost.
            .background(isSelected ? Lumen.accent.opacity(0.30) : Color.clear)
            // `radiusChip`, not a hardcoded 3. A sidebar row is a chip by every other
            // measure in this app and it was the last place still drawing the pre-token
            // radius, so the selected album sat in a squarer rectangle than anything
            // beside it.
            .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous))
        }
        .buttonStyle(.plain)
        // On the PANEL value, not the control surface: this row sits directly on the
        // sidebar's own 0.20 ground, and `hovered(on:)` is additive, so passing the
        // default 0.24 would light it to a value 0.03 above a surface that is not there.
        .lumenInteractive(radius: Lumen.radiusChip, on: Lumen.panelValue)
        .help(help ?? "")
        // The app's second accessibility label. The count is the row's other half and a
        // screen reader that reads only the title cannot tell an empty scope from a full
        // one — which is most of what these rows are for.
        .accessibilityLabel(Text("\(title), \(count) photograph\(count == 1 ? "" : "s")"))
    }


    // `row` is gone too: the culling counts were the only caller and they are
    // `sourceRow`s now, because a count sitting in a source list is a thing people click.
}

// MARK: - Sidebar verb

/// A command in the sources column: borderless at rest, surface on hover, pointing hand.
///
/// IT REPLACES `.buttonStyle(.borderless)`, which this column held SEVEN of — out of eight
/// in the whole application. Everything else in Lumen is `.buttonStyle(.plain)`, sixty-nine
/// times. That is not a stylistic quibble: `.borderless` renders its label in the **macOS
/// system accent**, and this app sets no `.tint` anywhere except one control in the filter
/// bar, so the sidebar's verbs were the one place whose colour was chosen by System
/// Settings rather than by the app. On a Graphite Mac they read grey and nobody noticed; on
/// a default Mac they are blue, in a chrome that `docs/00` Law 7 requires to be zero-chroma
/// everywhere the photograph is not.
///
/// The idiom is `DevelopFooterButton`'s, deliberately — "borderless at rest, surface on
/// hover … a rest fill is how you draw a MODE, something that can be on; every one of these
/// fires once and returns." That type is file-private to `DevelopPanel.swift`, is laid out
/// `maxWidth: .infinity` for a four-across footer, and has its quarter-of-the-row arithmetic
/// pinned by `LayoutMetricTests`. Reaching into it to serve a left-aligned column would put
/// the develop footer's layout at risk to save a screenful of code, so this is the same
/// argument stated again rather than the same type stretched.
///
/// DISABLED IS READ FROM THE ENVIRONMENT, not passed in, so `.disabled(…)` at the call site
/// is the single source of truth and cannot disagree with the appearance. It matters here:
/// four of these are disabled most of the time — no target album, no selection, no stack —
/// and a control that lights up and points the hand while refusing the click is the
/// affordance lie in its loudest form.
private struct SidebarVerb: View {
    let title: String
    var systemImage: String? = nil
    let help: String
    let action: () -> Void

    /// Row-local. Hover must never reach an `ObservableObject` — a pointer crossing this
    /// column would publish once per row, which `CommandState` has already paid for once.
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var lit: Bool { hovering && isEnabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        // A fixed box, because SF Symbols are not a fixed-width family and
                        // a ragged left edge reads as sloppiness before it reads as icons.
                        // 14 is the menu item's column, which is what this row is.
                        .font(.lumenGlyphCaption)
                        .frame(width: 14)
                }
                Text(title)
                    .font(.lumenBody)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: Lumen.rowHeight)
            .background(lit ? Lumen.hovered(on: Lumen.panelValue) : Color.clear)
            // Three states, not two. `secondaryText` at rest and `primaryText` lit is the
            // footer button's pair; `tertiaryText` for disabled is the third, because
            // without it "not available" and "available, not hovered" were the same grey
            // and half this column is disabled until something is selected.
            .foregroundStyle(isEnabled ? (lit ? Lumen.primaryText : Lumen.secondaryText)
                                       : Lumen.tertiaryText)
            .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusChip, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Lumen.motionState, value: hovering)
        .lumenClickCursor(isEnabled)
        .help(help)
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // Built once and read twice, by the label and by its own tooltip — the tooltip
        // is what a truncated sentence falls back on in a 22-point bar.
        let sentence = state.filter.sentence(catalogLive: state.isLibraryQueryLive)
        return HStack(spacing: 12) {
            if state.isScanning {
                // `LumenSpinner`, not `ProgressView()`: the indeterminate AppKit
                // spinner is tinted by the system accent like every other stock control,
                // and this one sits in the status bar under the photograph.
                LumenSpinner(diameter: 11, lineWidth: 1.6)
            }
            if let message = state.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
            }
            // The query, in words. It used to own the second row of a full-width filter
            // bar; the bar is one row now (docs/28 Phase 3) and the sentence outlived it
            // because it is the part worth keeping — better product thinking than
            // Lightroom's filter bar, which shows you lit chips and leaves you to
            // reconstruct what they mean together. Here it sits beside the count it
            // qualifies, which is where a query result belongs.
            Text(sentence)
                .font(.lumenCaption)
                .foregroundStyle(state.filter.isActive
                                 ? Lumen.primaryText : Lumen.tertiaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(sentence)
            Text(countText)
                .font(.lumenCaptionNumeric)
                .foregroundStyle(Lumen.secondaryText)
            Spacer()
            if state.isExporting {
                // Two states, not one. Once a stop has been asked for, the percentage
                // keeps climbing through the file being finished — and this readout is
                // the only always-visible sign of an export, so a photographer who
                // pressed Stop and then closed the sheet was watching a number rise on
                // a batch that was already stopping. `exportCancelRequested` was
                // published and nothing read it; the sheet's own "Cancelling…" is local
                // `@State` and goes away with the sheet.
                Text(state.exportCancelRequested
                     ? "Stopping — finishing this file"
                     : "Exporting \(Int(state.exportProgress * 100))%")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
            }
            // NO FILENAME HERE. `DevelopPanel.header` draws it whenever the develop
            // column is showing, which is every loupe and compare session — so the same
            // string sat at both ends of the window, about 990 points apart. The panel's
            // copy is the one beside the controls that act on that photograph; this one
            // was decoration at the far corner.
            if state.selection.count > 1 {
                Text("\(state.selection.count) selected")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.accent)
            }
            // THE FILMSTRIP'S SWITCH, and it lives here rather than only on the strip
            // because a hide control that exists only on the thing it hides strands the
            // way back the moment it works — the Cull lesson, one storey down. The
            // status bar is persistent chrome directly under the strip, so the toggle
            // is beside what it governs and survives it in both directions. `F` and
            // the View menu drive the same flag.
            Button {
                state.showFilmstrip.toggle()
            } label: {
                Image(systemName: "film")
                    .font(.lumenGlyphCaption)
                    .foregroundStyle(state.showFilmstrip
                                     ? Lumen.primaryText : Lumen.secondaryText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .lumenClickCursor()
            .help(state.showFilmstrip
                  ? "Hide the filmstrip (F)" : "Show the filmstrip (F)")
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Lumen.panelBackground)
    }

    /// Read off the grid itself rather than counted separately, so the number and the
    /// contact sheet under it can never disagree — an older version re-ran the whole
    /// in-memory predicate on every keystroke to produce a second answer.
    private var countText: String {
        let total = state.allPhotos.count
        guard state.filter.isActive || state.selectedCollectionID != nil else {
            return "\(total) photos"
        }
        return "\(state.photos.count) of \(total)"
    }
}

// MARK: - Empty state

private struct EmptyState: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        LumenEmptyState(
            symbol: "photo.on.rectangle.angled",
            headline: "Open a folder of photographs",
            detail: "Folders are the library. Nothing is copied, moved, or modified.",
            actionTitle: "Open Folder…") { state.chooseFolder() }
    }
}

// MARK: - Keyboard reference

private struct KeyReferenceSheet: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard")
                    .font(.lumenTitle)
                Spacer()
                Button("Done") { state.showKeyReference = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider().overlay(Lumen.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(KeyReference.groups) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(Lumen.secondaryText)
                            ForEach(group.entries) { entry in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(entry.keys)
                                        .font(.lumenNumeric)
                                        .frame(width: 84, alignment: .leading)
                                        .foregroundStyle(Lumen.primaryText)
                                    Text(entry.action)
                                        .font(.lumenBody)
                                        .foregroundStyle(Lumen.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
            // docs/30: every scroll view in the app is silent. A legacy scroller insets
            // its content, so an indicator appearing is a relayout of everything inside it.
            .scrollIndicators(.never)
        }
        .frame(width: 460, height: 560)
        .background(Lumen.panelBackground)
    }
}

// `WorkspaceReturnBar` is gone: it existed to re-draw the workspace strip over the grid
// whenever the column that carried the strip was not on screen. The strip itself is
// gone — `WorkspaceRail` sits on the window's right edge in every state — so there is
// nothing left to return. The lesson it taught survives in the rail's placement: the
// subscription to `PanelLayout` lives in the small view that needs it, never on this
// window.

#endif

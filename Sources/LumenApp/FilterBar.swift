// FilterBar.swift
// One compact strip: search, the filter behind a button, and the view controls. Three
// things here are product decisions rather than layout:
//
//   · The boolean grammar is made legible (D39). Values inside a group OR — two flag
//     chips lit means "picked or rejected" — and the groups AND with each other unless
//     the All/Any toggle says otherwise. `LibraryFilter.sentence` spells the active
//     query back out, because a query a photographer cannot read is a query they will
//     not trust. It reads in two places now, the status bar and the popover's foot.
//   · Every chip compiles to an indexed SQL predicate (docs/10 §10.8). This bar used to
//     filter five criteria with a linear scan of the roll while a 200-line query
//     builder sat in `CatalogStore` with no callers — which is why camera, lens, ISO,
//     keyword, stack state and "edited" could not exist here at all.
//   · Auto-advance is a visible toggle, never a hidden preference and never Caps-Lock
//     folklore (D35, docs/10 §10.4.1).
//
// The one rule that shapes what is on screen: a chip the running configuration cannot
// honour is not drawn. Without a catalog the app filters in memory over `PhotoItem`,
// which knows a photo's flag, rating, label, name and extension and nothing else — so
// in that mode the metadata chips are not drawn at all, the sort menu greys out the
// keys that need columns only the catalog has and says so next to each, and the
// sentence reads "filtering in memory, without the catalog". A lit chip that silently
// does nothing is worse than an absent one.
//
// Chrome here is zero-chroma (Law 7). The only hues are the colour-label swatches,
// which cannot be told apart without them, and they are the same values the cell
// badges use.

#if os(macOS)

import SwiftUI

struct FilterBar: View {
    @EnvironmentObject var state: AppState

    private static let labelOrder: [ColorLabel] = [.red, .yellow, .green, .blue, .purple]

    @State private var showingFilters = false

    var body: some View {
        // ONE row of five controls, where there were two rows of fourteen (docs/28
        // Phase 3, and the owner's first-named complaint: "the top bar area with
        // ratings is not needed, or at least not needed so much that it deserves a full
        // top bar"). He is also where the market is — Lightroom keeps its filter bar in
        // the Library grid behind a key, Capture One puts filters in a tool inside the
        // Library tab, and Photomator uses a popover at the filmstrip's edge. Nobody
        // spends two permanent rows of window height on them.
        //
        // What moved, rather than what went away, because nothing here was wrong:
        //   · the criteria         → the Filter popover, where they finally have room
        //                            for their per-chip counts
        //   · the query sentence   → the status bar (`LibraryFilter.sentence`), because
        //                            it is the best thing in this file and deserves to
        //                            outlive its container
        //   · the photo count      → the status bar, beside the sentence it qualifies
        // and the view controls stay, because sort, auto-advance and thumbnail size are
        // not filters and never belonged in the same cluster as them.
        HStack(spacing: 8) {
            textFilter
            filterButton
            // Clear stays OUT of the popover on purpose. It carries ⌘\ (docs/10 §10.8,
            // "one key back to everything"), and a `.keyboardShortcut` on a view that
            // is not in the hierarchy is not registered — so filing it inside a popover
            // would leave the shortcut in the source, still passing `KeyGrammarTests`
            // which reads these as text, and dead in the app. It is also the one filter
            // action worth a click without opening anything.
            if state.filter.isActive { clearButton }
            Spacer(minLength: 8)
            sortMenu
            directionButton
            autoAdvanceToggle
            sizeSlider
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Lumen.panelBackground)
    }

    // MARK: The filter, behind one button

    private var filterButton: some View {
        Button {
            // Opens, rather than toggles. A popover eats the click that dismisses it, so
            // a toggle here would close and immediately reopen when you click the button
            // that is already showing one. Escape and a click outside close it.
            showingFilters = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 9))
                Text("Filter")
                    .font(.system(size: 10))
                // Criteria, not chips: three flag chips lit is ONE clause of the query,
                // and a badge counting chips would read 5 where the sentence reads 2.
                // And HIDDEN criteria, not all of them — the search field is in this
                // same strip with its own contents visible, so badging the button for
                // it would send you into a popover where every group is empty.
                if state.filter.hiddenCriteriaCount > 0 {
                    Text("\(state.filter.hiddenCriteriaCount)")
                        .font(.system(size: 9).monospacedDigit())
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(state.filter.hiddenCriteriaCount > 0
                             ? Lumen.primaryText : Lumen.secondaryText)
            .background(state.filter.hiddenCriteriaCount > 0
                        ? Lumen.fillColor.opacity(0.35) : Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("Flag, rating, label, file and metadata criteria")
        .popover(isPresented: $showingFilters) { filterPopover }
    }

    private var clearButton: some View {
        Button("Clear") { state.filter = LibraryFilter() }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(Lumen.secondaryText)
            .keyboardShortcut("\\", modifiers: [.command])
            .help("Clear the filter (⌘\\)")
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            popoverGroup("Flag") { flagGroup }
            popoverGroup("Rating") { ratingGroup }
            popoverGroup("Label") { labelGroup }
            popoverGroup("File") {
                HStack(spacing: 3) {
                    rawOnlyChip
                    if state.isLibraryQueryLive { editedChip }
                }
            }
            if state.isLibraryQueryLive {
                popoverGroup("Metadata") {
                    HStack(spacing: 3) {
                        metadataMenu
                        Spacer(minLength: 8)
                        matchToggle
                    }
                }
            }
            // The sentence again, inside the control that produced it. One source
            // (`LibraryFilter.sentence`) so the popover and the status bar cannot
            // describe the same query two different ways.
            Text(state.filter.sentence(catalogLive: state.isLibraryQueryLive))
                .font(.system(size: 10))
                .foregroundStyle(state.filter.isActive
                                 ? Lumen.primaryText : Lumen.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func popoverGroup<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            groupLabel(title)
            content()
        }
    }

    // MARK: Criteria

    // The groups no longer carry their own caps label — `popoverGroup` supplies it, and
    // three hand-rolled group headings inside a row was one of the twenty same-weight
    // targets the audit counted (§1.7).
    private var flagGroup: some View {
        HStack(spacing: 3) {
            chip(title: "Pick", systemImage: "flag.fill",
                 count: flagCount(.picked),
                 isOn: state.filter.flags.contains(.picked)) { toggleFlag(.picked) }
            chip(title: "Reject", systemImage: "xmark",
                 count: flagCount(.rejected),
                 isOn: state.filter.flags.contains(.rejected)) { toggleFlag(.rejected) }
            chip(title: "Unflagged", systemImage: nil,
                 count: flagCount(.none),
                 isOn: state.filter.flags.contains(.none)) { toggleFlag(.none) }
        }
    }

    /// Stars with their counts under them. The count used to live only in a tooltip, so
    /// deciding where to set the threshold meant hovering five targets one at a time —
    /// Capture One shows them and it is the single most useful thing in its Filters
    /// tool. The popover is where there is finally room for it.
    private var ratingGroup: some View {
        HStack(spacing: 6) {
            Text("≥")
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
            ForEach(1...5, id: \.self) { value in
                Button {
                    state.filter.minRating = state.filter.minRating == value ? 0 : value
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(value <= state.filter.minRating
                                             ? Lumen.primaryText : Lumen.trackColor)
                        Text("\(ratingCount(value))")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(Lumen.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rating \(value) or better — \(ratingCount(value)) photos")
            }
        }
    }

    private var labelGroup: some View {
        HStack(spacing: 6) {
            ForEach(Self.labelOrder, id: \.rawValue) { label in
                Button {
                    toggleLabel(label)
                } label: {
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(label.color)
                            .frame(width: 14, height: 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(state.filter.labels.contains(label)
                                                  ? Lumen.primaryText : Color.black.opacity(0.35),
                                                  lineWidth: state.filter.labels.contains(label) ? 2 : 1)
                            )
                        Text("\(labelCount(label))")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(Lumen.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(label.displayName) — \(labelCount(label)) photos")
            }
            Spacer(minLength: 6)
            chip(title: "Unlabelled", systemImage: nil, count: labelCount(.none),
                 isOn: state.filter.labels.contains(.none)) { toggleLabel(.none) }
        }
    }

    private var rawOnlyChip: some View {
        chip(title: "RAW only", systemImage: nil, count: nil, isOn: state.filter.rawOnly) {
            state.filter.rawOnly.toggle()
        }
    }

    /// Three states, not two: any / edited / untouched. `photo.edited` is maintained in
    /// the same transaction as the recipe and is true only when the recipe actually
    /// renders differently, so "untouched" means the photograph, not the row.
    private var editedChip: some View {
        chip(title: editedTitle, systemImage: "pencil",
             count: nil, isOn: state.filter.edited != nil) {
            if state.filter.edited == nil {
                state.filter.edited = true
            } else if state.filter.edited == true {
                state.filter.edited = false
            } else {
                state.filter.edited = nil
            }
        }
        .help("Edited / untouched / any")
    }

    private var editedTitle: String {
        state.filter.edited == false ? "Untouched" : "Edited"
    }

    /// Camera, lens, ISO, keyword and stack state behind one menu. They belong in the
    /// bar by docs/10 §10.8, and they do not fit in it as five more visible groups — a
    /// strip that wraps is a strip that stops being readable at a glance.
    private var metadataMenu: some View {
        // `inline: true`, and it is a correctness fix rather than a style choice.
        //
        // macOS will not nest popovers: an `NSPopover` is transient by default and a
        // transient popover closes when it loses key, which is exactly what presenting a
        // second one does. As a popover, this menu would have dismissed the Filter
        // popover it lives in on the very click that opened it, taking itself with it —
        // and nobody would have seen the bug until the macOS lane, because none of this
        // type-checks anywhere else. `Menu` never had the problem, because `NSMenu` runs
        // its own tracking loop instead of taking key, which is why it went unnoticed for
        // as long as this was one.
        //
        // See `LumenMenu.inline`. The list expands downward inside the Filter popover,
        // which is also the better shape here: it reads as part of the filter being
        // built rather than as a second window over the first.
        LumenMenu(title: metadataTitle, symbol: "camera.aperture", inline: true,
                  help: "Camera, lens, ISO, keyword and stack state") {
            // THE COUNTS MOVE TO THE ANNOTATION COLUMN. They used to be glued into the
            // label — "Canon EOS R5  (214)" — as one string, which is how you get a
            // column of names whose right edge lands wherever each name happened to
            // end. `detail:` is drawn dim and trailing, so the eye reads a column of
            // bodies and a column of numbers rather than a stack of ragged sentences.
            //
            // NO GLYPHS IN THIS ONE, and that is a rule rather than an omission: the
            // only honest glyph for a camera row is a camera, and one camera repeated
            // down the whole left margin is texture, not information. The headers
            // already say which kind of thing each group holds.
            //
            // This is also the only menu in the app that opens from INSIDE another
            // popover — the Filter popover is its parent — which is worth knowing
            // before anything here is moved.
            //
            // Each section is a `Group` because `ViewBuilder` stops at ten children:
            // five headers, five lists and three empty-state rows is thirteen, and the
            // failure mode is a compiler error about `buildExpression` that never
            // mentions arity at all.
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    Group {
                        LumenMenuHeader(title: "Camera")
                        if state.cameraChoices.isEmpty {
                            LumenMenuItem(title: "No camera has been read yet",
                                          isEnabled: false) {}
                        }
                        ForEach(state.cameraChoices) { camera in
                            LumenMenuItem(title: camera.name,
                                          detail: "\(camera.count)",
                                          isSelected: state.filter.cameras
                                              .contains(camera.name)) {
                                toggle(&state.filter.cameras, camera.name)
                            }
                        }
                    }
                    Group {
                        LumenMenuHeader(title: "Lens")
                        if state.lensChoices.isEmpty {
                            LumenMenuItem(title: "No lens has been read yet",
                                          isEnabled: false) {}
                        }
                        ForEach(state.lensChoices) { lens in
                            LumenMenuItem(title: lens.name,
                                          detail: "\(lens.count)",
                                          isSelected: state.filter.lenses
                                              .contains(lens.name)) {
                                toggle(&state.filter.lenses, lens.name)
                            }
                        }
                    }
                    Group {
                        LumenMenuHeader(title: "ISO")
                        ForEach(ISOBand.allCases) { band in
                            LumenMenuItem(title: band.rawValue,
                                          isSelected: state.filter.isoBands
                                              .contains(band)) {
                                toggle(&state.filter.isoBands, band)
                            }
                        }
                    }
                    Group {
                        LumenMenuHeader(title: "Keyword")
                        if state.keywordVocabulary.isEmpty {
                            LumenMenuItem(title: "No keywords yet",
                                          isEnabled: false) {}
                        }
                        ForEach(state.keywordVocabulary) { keyword in
                            LumenMenuItem(title: keyword.name,
                                          detail: "\(keyword.count)",
                                          isSelected: state.filter.keywords
                                              .contains(keyword.name)) {
                                toggle(&state.filter.keywords, keyword.name)
                            }
                        }
                    }
                    Group {
                        LumenMenuHeader(title: "Stacks")
                        ForEach(StackFilter.allCases) { option in
                            LumenMenuItem(title: option.rawValue,
                                          isSelected: state.filter.stackState == option) {
                                state.filter.stackState = option
                            }
                        }
                    }
                }
            }
            // The one menu in the app whose length is the LIBRARY's rather than the
            // design's: a roll shot on four bodies with sixty keywords fills this list
            // sixty rows deep, and `LumenMenu` sizes itself to its content. AppKit
            // scrolled its own menus; ours has to be told to.
            //
            // 240 rather than 320, because opening in place makes this height ADDITIVE:
            // the Filter popover already holds five groups, and a list that expands
            // inside it pushes the whole popover taller rather than floating over it. Ten
            // rows is still more than a normal shoot ever needs, and it leaves the parent
            // room to stay on screen on a laptop display.
            .frame(maxHeight: 240)
            .scrollIndicators(.never)
        }
    }

    private var metadataTitle: String {
        var lit = state.filter.cameras.count + state.filter.lenses.count
            + state.filter.isoBands.count + state.filter.keywords.count
        if state.filter.stackState != .any { lit += 1 }
        return lit == 0 ? "Metadata" : "Metadata (\(lit))"
    }

    /// The All/Any toggle. All = the criteria AND, which is what every other filter bar
    /// does; Any = they OR, which is the query LR cannot express (D39).
    private var matchToggle: some View {
        chip(title: state.filter.matchAny ? "Any" : "All", systemImage: nil,
             count: nil, isOn: state.filter.matchAny) {
            state.filter.matchAny.toggle()
        }
        .help("All: every criterion must match. Any: one is enough.")
    }

    /// What the text chip searches, which is not the same in both modes: with a catalog
    /// it is the FTS index over filename, extension, camera, lens, job and keywords;
    /// without one it is the filename in memory. Saying so in the placeholder is the
    /// cheapest possible way to stop the field lying about its reach.
    private var textPlaceholder: String {
        state.isLibraryQueryLive ? "Name, camera, keyword" : "File name"
    }

    private var textFilter: some View {
        HStack(spacing: 3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(Lumen.secondaryText)
            TextField(textPlaceholder, text: $state.filter.text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Lumen.primaryText)
                .frame(width: 130)
            if !state.filter.text.isEmpty {
                Button {
                    state.filter.text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Lumen.secondaryText)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Lumen.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: View controls

    private var sortMenu: some View {
        LumenMenu(title: state.sortOrder.rawValue, symbol: "arrow.up.arrow.down",
                  help: "Sort order") {
            ForEach(SortOrder.allCases) { order in
                LumenMenuItem(title: order.rawValue,
                              symbol: sortSymbol(order),
                              detail: unavailableNote(order),
                              isSelected: order == state.sortOrder,
                              isEnabled: unavailableReason(order) == nil) {
                    state.sortOrder = order
                }
                // The FULL sentence, on the row it is about. The short form in the
                // annotation column is what keeps the popover the width of a sort key
                // instead of the width of an explanation — twelve keys against a
                // sixty-character clause would have set this list nearly five hundred
                // points wide — and the tooltip is where the clause goes on living. A
                // disabled key still has to say what it is waiting for.
                .help(unavailableReason(order)
                      ?? "Order the roll by \(order.rawValue.lowercased())")
            }
        }
    }

    /// Twelve keys, twelve glyphs, and every one of them is the thing the key sorts by
    /// rather than a decoration on it — a star for the stars, a flag for the flags, a
    /// clock for the time. The list earns its icon column: this is the one menu in the
    /// bar you open knowing what you want, and a glyph is found faster than a word.
    private func sortSymbol(_ order: SortOrder) -> String {
        switch order {
        case .captureTime: return "clock"
        case .addedOrder: return "tray.and.arrow.down"
        case .editTime: return "pencil"
        case .rating: return "star"
        case .flag: return "flag"
        case .label: return "tag"
        case .filename: return "textformat"
        case .fileType: return "doc"
        case .aspectRatio: return "aspectratio"
        case .userOrder: return "rectangle.stack"
        case .sharpness: return "magnifyingglass"
        case .aesthetic: return "sparkles"
        }
    }

    /// A disabled key says what it is waiting for. An ordering that silently does
    /// nothing is the failure mode this whole file is written against.
    ///
    /// Two lengths of the same fact: this is the annotation column's version, three
    /// words wide, and `unavailableReason` is the sentence the row's tooltip carries.
    /// `scoreSortsPending` is written as prose because that is what a tooltip wants;
    /// prose in a trailing annotation sets the width of the entire list.
    private func unavailableNote(_ order: SortOrder) -> String? {
        guard let reason = unavailableReason(order) else { return nil }
        return reason == SortOrder.scoreSortsPending ? "not built yet" : reason
    }

    private func unavailableReason(_ order: SortOrder) -> String? {
        if !state.isLibraryQueryLive && !order.worksFromMemory {
            return "needs the catalog"
        }
        switch order {
        case .sharpness, .aesthetic:
            // `cache.frame_score` has no writer anywhere in the repo: the culling
            // analysis pass of docs/10 §10.6 is not built. Sorting by it would order
            // every photo by NULL and look like the menu item did nothing.
            return SortOrder.scoreSortsPending
        case .userOrder:
            // `ap.position` only exists inside an album; outside one the builder falls
            // back to added order, which is a different sort wearing this one's name.
            //
            // This used to read "drag to reorder inside an album", which described a
            // gesture Lumen does not have: `onMove` appears in no file in the repo, and
            // `album_photo.position` is written once, at insert, by `addToAlbum`. A
            // disabled key is supposed to say what it is WAITING FOR — an album — and
            // this one was instead teaching the user a drag that would never work.
            return state.selectedCollectionID == nil ? "select an album" : nil
        default:
            return nil
        }
    }

    private var directionButton: some View {
        Button {
            state.sortAscending.toggle()
        } label: {
            Image(systemName: state.sortAscending ? "arrow.up" : "arrow.down")
                .font(.system(size: 9))
                .foregroundStyle(Lumen.primaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Lumen.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(state.sortAscending ? "Ascending" : "Descending")
    }

    private var autoAdvanceToggle: some View {
        // Hand-composed rather than a `Toggle` with a label, because the switch is drawn
        // now (`LumenSwitch`) and AppKit's label placement was the only thing `Toggle`
        // was still supplying. The whole strip toggles, not just the 28 points of switch.
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                Image(systemName: "forward.end.alt.fill")
                    .font(.system(size: 9))
                Text("Auto-advance")
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundStyle(state.autoAdvance ? Lumen.primaryText : Lumen.secondaryText)
            LumenSwitch(isOn: $state.autoAdvance)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.autoAdvance.toggle() }
        .lumenClickCursor()
        .fixedSize()
        .help("After a flag, star or label, move to the next photo")
    }

    /// THE GRID'S OWN CONTROL, drawn only where the grid is.
    ///
    /// `gridThumbnailSize` is read by exactly one view — `GridView`. This slider sat in
    /// the top-right of the window in ALL FOUR view modes and in the empty state, moving
    /// a number that has no visible effect in three of them. The codebase had already
    /// diagnosed precisely this for the keyboard: `Keymap` notes that "`[` / `]` were
    /// already moving a number nobody could see" outside the grid, and made those keys
    /// conditional on the view mode. The pointer version received no such condition.
    ///
    /// It also duplicated a documented keyboard grammar — `[` and `]` step the same
    /// value through the same clamps — and its left end-cap, a `square.grid.3x3.fill`
    /// glyph, is the one thing in this bar that LOOKS like a view-mode switcher. The
    /// owner read it as exactly that. There was no view-mode switcher; there is now, in
    /// the View menu.
    @ViewBuilder
    private var sizeSlider: some View {
        if state.viewMode == .grid {
            HStack(spacing: 4) {
                Slider(value: $state.gridThumbnailSize,
                       in: AppState.minThumbnailSize...AppState.maxThumbnailSize)
                    .controlSize(.mini)
                    .tint(Lumen.fillColor)
                    .frame(width: 90)
            }
            .help("Thumbnail size  ([ and ])")
        }
    }

    // MARK: Counts

    // Flag, rating and label counts come from the roll in memory, which holds the
    // culling state a keystroke has already written. Asking the catalog would be one
    // round trip per chip per keystroke to arrive at the same number one frame later.
    //
    // Through `AppState.cullCounts` — ONE memoised pass — because this bar is on
    // screen in every view mode and these three used to be fourteen separate reduces
    // over the whole roll per body evaluation, re-run on every publish.

    private func flagCount(_ flag: PhotoFlag) -> Int {
        state.cullCounts.flags[flag] ?? 0
    }

    private func ratingCount(_ minimum: Int) -> Int {
        guard (1...5).contains(minimum) else { return 0 }
        return state.cullCounts.ratingAtLeast[minimum]
    }

    private func labelCount(_ label: ColorLabel) -> Int {
        state.cullCounts.labels[label] ?? 0
    }

    // MARK: Mutation

    private func toggleFlag(_ flag: PhotoFlag) {
        if state.filter.flags.contains(flag) {
            state.filter.flags.remove(flag)
        } else {
            state.filter.flags.insert(flag)
        }
    }

    private func toggleLabel(_ label: ColorLabel) {
        if state.filter.labels.contains(label) {
            state.filter.labels.remove(label)
        } else {
            state.filter.labels.insert(label)
        }
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }

    // MARK: Pieces

    private func groupLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Lumen.secondaryText)
    }

    private func chip(title: String,
                      systemImage: String?,
                      count: Int?,
                      isOn: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9))
                }
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(1)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Lumen.secondaryText)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(isOn ? Lumen.primaryText : Lumen.secondaryText)
            .background(isOn ? Lumen.fillColor.opacity(0.35) : Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

#endif

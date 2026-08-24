// FilterBar.swift
// The grid's filter, sort and view controls in one strip. Three things here are
// product decisions rather than layout:
//
//   · The boolean grammar is made legible (D39). Values inside a group OR — two flag
//     chips lit means "picked or rejected" — and the groups AND with each other unless
//     the All/Any toggle says otherwise. The sentence in the second row spells the
//     active query back out, because a query a photographer cannot read is a query
//     they will not trust.
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
// keys that need columns only the catalog has and says so next to each, and the summary
// row reads "filtering in memory, without the catalog". A lit chip that silently does
// nothing is worse than an absent one.
//
// Chrome here is zero-chroma (Law 7). The only hues are the colour-label swatches,
// which cannot be told apart without them, and they are the same values the cell
// badges use.

#if os(macOS)

import SwiftUI

struct FilterBar: View {
    @EnvironmentObject var state: AppState

    private static let labelOrder: [ColorLabel] = [.red, .yellow, .green, .blue, .purple]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                flagGroup
                separator
                ratingGroup
                separator
                labelGroup
                separator
                rawOnlyChip
                if state.isLibraryQueryLive {
                    editedChip
                    metadataMenu
                    matchToggle
                }
                textFilter
                Spacer(minLength: 8)
                sortMenu
                directionButton
                autoAdvanceToggle
                sizeSlider
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            summaryRow
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
        }
        .background(Lumen.panelBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Lumen.separator)
                .frame(height: 1)
        }
    }

    // MARK: Criteria

    private var flagGroup: some View {
        HStack(spacing: 3) {
            groupLabel("Flag")
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

    private var ratingGroup: some View {
        HStack(spacing: 3) {
            groupLabel("Rating")
            Text("≥")
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
            ForEach(1...5, id: \.self) { value in
                Button {
                    state.filter.minRating = state.filter.minRating == value ? 0 : value
                } label: {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(value <= state.filter.minRating
                                         ? Lumen.primaryText : Lumen.trackColor)
                }
                .buttonStyle(.plain)
                .help("Rating \(value) or better — \(ratingCount(value)) photos")
            }
        }
    }

    private var labelGroup: some View {
        HStack(spacing: 3) {
            groupLabel("Label")
            ForEach(Self.labelOrder, id: \.rawValue) { label in
                Button {
                    toggleLabel(label)
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(label.color)
                        .frame(width: 14, height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(state.filter.labels.contains(label)
                                              ? Lumen.primaryText : Color.black.opacity(0.35),
                                              lineWidth: state.filter.labels.contains(label) ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
                .help("\(label.displayName) — \(labelCount(label)) photos")
            }
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
        Menu {
            Section("Camera") {
                if state.cameraChoices.isEmpty {
                    Text("No camera has been read yet")
                }
                ForEach(state.cameraChoices) { camera in
                    Button {
                        toggle(&state.filter.cameras, camera.name)
                    } label: {
                        if state.filter.cameras.contains(camera.name) {
                            Label("\(camera.name)  (\(camera.count))", systemImage: "checkmark")
                        } else {
                            Text("\(camera.name)  (\(camera.count))")
                        }
                    }
                }
            }
            Section("Lens") {
                if state.lensChoices.isEmpty {
                    Text("No lens has been read yet")
                }
                ForEach(state.lensChoices) { lens in
                    Button {
                        toggle(&state.filter.lenses, lens.name)
                    } label: {
                        if state.filter.lenses.contains(lens.name) {
                            Label("\(lens.name)  (\(lens.count))", systemImage: "checkmark")
                        } else {
                            Text("\(lens.name)  (\(lens.count))")
                        }
                    }
                }
            }
            Section("ISO") {
                ForEach(ISOBand.allCases) { band in
                    Button {
                        toggle(&state.filter.isoBands, band)
                    } label: {
                        if state.filter.isoBands.contains(band) {
                            Label(band.rawValue, systemImage: "checkmark")
                        } else {
                            Text(band.rawValue)
                        }
                    }
                }
            }
            Section("Keyword") {
                if state.keywordVocabulary.isEmpty {
                    Text("No keywords yet")
                }
                ForEach(state.keywordVocabulary) { keyword in
                    Button {
                        toggle(&state.filter.keywords, keyword.name)
                    } label: {
                        if state.filter.keywords.contains(keyword.name) {
                            Label("\(keyword.name)  (\(keyword.count))",
                                  systemImage: "checkmark")
                        } else {
                            Text("\(keyword.name)  (\(keyword.count))")
                        }
                    }
                }
            }
            Section("Stacks") {
                ForEach(StackFilter.allCases) { option in
                    Button {
                        state.filter.stackState = option
                    } label: {
                        if state.filter.stackState == option {
                            Label(option.rawValue, systemImage: "checkmark")
                        } else {
                            Text(option.rawValue)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 9))
                Text(metadataTitle)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .help("Camera, lens, ISO, keyword and stack state")
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
        Menu {
            ForEach(SortOrder.allCases) { order in
                Button {
                    state.sortOrder = order
                } label: {
                    if order == state.sortOrder {
                        Label(sortTitle(order), systemImage: "checkmark")
                    } else {
                        Text(sortTitle(order))
                    }
                }
                .disabled(unavailableReason(order) != nil)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9))
                Text(state.sortOrder.rawValue)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .help("Sort order")
    }

    /// A disabled key says what it is waiting for. An ordering that silently does
    /// nothing is the failure mode this whole file is written against.
    private func sortTitle(_ order: SortOrder) -> String {
        guard let reason = unavailableReason(order) else { return order.rawValue }
        return "\(order.rawValue) — \(reason)"
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
        Toggle(isOn: $state.autoAdvance) {
            HStack(spacing: 3) {
                Image(systemName: "forward.end.alt.fill")
                    .font(.system(size: 9))
                Text("Auto-advance")
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundStyle(state.autoAdvance ? Lumen.primaryText : Lumen.secondaryText)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .fixedSize()
        .help("After a flag, star or label, move to the next photo")
    }

    private var sizeSlider: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 9))
                .foregroundStyle(Lumen.secondaryText)
            Slider(value: $state.gridThumbnailSize,
                   in: AppState.minThumbnailSize...AppState.maxThumbnailSize)
                .controlSize(.mini)
                .tint(Lumen.fillColor)
                .frame(width: 100)
            Image(systemName: "square.fill")
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
        }
        .help("Thumbnail size")
    }

    // MARK: Legibility row

    private var summaryRow: some View {
        HStack(spacing: 8) {
            Text(state.filter.isActive ? summary : noFilterText)
                .font(.system(size: 10))
                .foregroundStyle(state.filter.isActive ? Lumen.primaryText : Lumen.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(countText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Lumen.secondaryText)
            if state.filter.isActive {
                Button("Clear") { state.filter = LibraryFilter() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.primaryText)
                    // docs/10 §10.8: one key back to everything.
                    .keyboardShortcut("\\", modifiers: [.command])
                    .help("Clear the filter (⌘\\)")
            }
        }
    }

    private var noFilterText: String {
        state.isLibraryQueryLive
            ? "No filter — showing every photo"
            : "No filter — filtering in memory, without the catalog"
    }

    /// The active query written out. "or" inside a criterion, and between criteria
    /// whatever the Match toggle says — the sentence is the documentation.
    private var summary: String {
        var parts: [String] = []
        if !state.filter.flags.isEmpty {
            let flags = state.filter.flags
                .sorted { $0.rawValue > $1.rawValue }
                .map(Self.flagName)
            parts.append(flags.joined(separator: " or "))
        }
        if state.filter.minRating > 0 {
            parts.append("★ \(state.filter.minRating) or better")
        }
        if !state.filter.labels.isEmpty {
            let labels = state.filter.labels
                .sorted { $0.rawValue < $1.rawValue }
                .map { $0 == ColorLabel.none ? "Unlabelled" : $0.displayName }
            parts.append(labels.joined(separator: " or "))
        }
        if state.filter.rawOnly {
            parts.append("RAW only")
        }
        if let edited = state.filter.edited {
            parts.append(edited ? "edited" : "untouched")
        }
        if !state.filter.cameras.isEmpty {
            parts.append(state.filter.cameras.sorted().joined(separator: " or "))
        }
        if !state.filter.lenses.isEmpty {
            parts.append(state.filter.lenses.sorted().joined(separator: " or "))
        }
        if !state.filter.isoBands.isEmpty {
            let bands = ISOBand.allCases
                .filter { state.filter.isoBands.contains($0) }
                .map { "ISO " + $0.rawValue }
            parts.append(bands.joined(separator: " or "))
        }
        if !state.filter.keywords.isEmpty {
            parts.append(state.filter.keywords.sorted().joined(separator: " or "))
        }
        if state.filter.stackState != .any {
            parts.append(state.filter.stackState.rawValue.lowercased())
        }
        if !state.filter.text.isEmpty {
            parts.append("matching \"\(state.filter.text)\"")
        }
        let glue = state.filter.matchAny ? "  or  " : "  and  "
        return parts.joined(separator: glue)
    }

    /// Read off the grid itself rather than counted separately, so the number and the
    /// contact sheet under it can never disagree — the old version re-ran the whole
    /// in-memory predicate on every keystroke to produce a second answer.
    private var countText: String {
        let total = state.allPhotos.count
        guard state.filter.isActive || state.selectedCollectionID != nil else {
            return "\(total) photos"
        }
        return "\(state.photos.count) of \(total)"
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

    private static func flagName(_ flag: PhotoFlag) -> String {
        switch flag {
        case .picked: return "Picked"
        case .rejected: return "Rejected"
        case .none: return "Unflagged"
        }
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

    private var separator: some View {
        Rectangle()
            .fill(Lumen.separator)
            .frame(width: 1, height: 16)
    }

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
                        .font(.system(size: 9, design: .monospaced))
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

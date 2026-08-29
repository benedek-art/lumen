// ContentView.swift
// The three-pane shell: sources on the left, the picture in the middle, develop on the
// right, filmstrip underneath. The layout is deliberately boring — a photo editor's
// chrome should be furniture, and the only thing in the window that is allowed to be
// interesting is the photograph.

#if os(macOS)

import LumenCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                // No rule under the bar: it sits on `panel` 0.20 and the photo's field
                // below is `surroundCanvas` 0.165, so the surfaces already divide
                // themselves (design audit §1.1, and Phase 1's rule for the develop
                // column's own bands).
                FilterBar()
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
                        .overlay(alignment: .bottom) { inspectionBadge }
                    if showsDevelopColumn {
                        Divider().overlay(Lumen.separator)
                        DevelopPanel()
                            .frame(width: Lumen.panelWidth)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.showFilmstrip && !state.photos.isEmpty {
                    Divider().overlay(Lumen.separator)
                    FilmstripView()
                        .frame(height: 96)
                }
                StatusBar()
            }
            .background(Lumen.viewerBackground)
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
        state.primarySelection != nil && (state.viewMode == .loupe || state.viewMode == .compare)
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
/// The keyboard verbs are Command-modified rather than the bare `B` / `S` / `⇧S` that
/// docs/10 §10.9 specifies. The bare-key dispatcher in Keymap.swift already spends
/// those two letters on the Basic panel and the scopes, and moving them is a change to
/// the culling grammar that belongs in one deliberate pass over the whole keymap, not
/// as a side effect of giving albums a sidebar. `⌘B`, `⌘G`, `⇧⌘G` and `⌘K` are free,
/// they are attached to visible controls, and every one of them is disabled — visibly —
/// when there is nothing for it to act on.
private struct Sidebar: View {
    @EnvironmentObject var state: AppState

    @State private var newAlbumName: String = ""
    @State private var newKeyword: String = ""
    @FocusState private var keywordFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    state.chooseFolder()
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)

                if let folder = state.folderURL {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.lastPathComponent)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(folder.deletingLastPathComponent().path)
                            .font(.system(size: 10))
                            .foregroundStyle(Lumen.secondaryText)
                            .lineLimit(2)
                            .truncationMode(.head)
                    }
                }

                Divider().overlay(Lumen.separator)

                counts

                if state.isCatalogAvailable {
                    Divider().overlay(Lumen.separator)
                    albums
                    Divider().overlay(Lumen.separator)
                    keywords
                    Divider().overlay(Lumen.separator)
                    stacks
                }

                if let catalogStatus = state.catalogStatus {
                    // Was .orange — the one chroma violation in the chrome (Law 7:
                    // zero-chroma everywhere the photo isn't). Urgency reads through
                    // primary-value text in a quiet chrome just as well.
                    Text(catalogStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(Lumen.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    state.showKeyReference = true
                } label: {
                    Label("Keyboard", systemImage: "keyboard")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Lumen.secondaryText)
            }
            .padding(12)
            // A VStack inside a ScrollView is only as wide as its widest child, and the
            // album rows put their count on a trailing Spacer — without this they draw
            // the count hard against the name instead of at the column edge.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Lumen.panelBackground)
    }

    private var counts: some View {
        // Memoised in AppState.cullCounts; these were two more full passes per body.
        let picked = state.cullCounts.flags[.picked] ?? 0
        let rejected = state.cullCounts.flags[.rejected] ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            row("All photos", state.allPhotos.count)
            row("Picked", picked)
            row("Rejected", rejected)
            if state.filter.isActive || state.selectedCollectionID != nil {
                row("Showing", state.photos.count)
            }
        }
    }

    // MARK: Albums

    private var albums: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Albums")

            sourceRow(title: "This folder", count: state.allPhotos.count,
                      isSelected: state.selectedCollectionID == nil,
                      isTarget: false) {
                state.selectedCollectionID = nil
            }

            ForEach(state.collections) { album in
                sourceRow(title: album.name, count: album.count,
                          isSelected: state.selectedCollectionID == album.id,
                          isTarget: album.isTarget) {
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
                    .font(.system(size: 11))
                    .onSubmit { createAlbum() }
                Button {
                    createAlbum()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Lumen.secondaryText)
                .disabled(newAlbumName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Button {
                state.addSelectionToTargetCollection()
            } label: {
                Label(addToTargetTitle, systemImage: "tray.and.arrow.down")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("b", modifiers: [.command])
            .disabled(state.targetCollection == nil || state.editTargets.isEmpty)
            .help("Add the selection to the target album (⌘B)")
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

    private var keywords: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Keywords")

            if state.primaryKeywords.isEmpty {
                Text(state.primarySelection == nil
                     ? "Select a photo to keyword it"
                     : "None on this photo")
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
            } else {
                ForEach(state.primaryKeywords, id: \.self) { word in
                    HStack(spacing: 4) {
                        Text(word)
                            .font(.system(size: 11))
                            .foregroundStyle(Lumen.primaryText)
                        Spacer()
                        Button {
                            state.removeKeyword(word)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Lumen.secondaryText)
                        .help("Remove \(word) from the selection")
                    }
                }
            }

            HStack(spacing: 4) {
                TextField("Add keyword", text: $newKeyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($keywordFieldFocused)
                    .onSubmit { addKeyword() }
                Button {
                    addKeyword()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Lumen.secondaryText)
                .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // ⌘K puts the cursor in the field rather than applying anything: the verb a
            // photographer wants from a keyword shortcut is "let me type one".
            Button("Keyword the selection") { keywordFieldFocused = true }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(state.editTargets.isEmpty)
                .help("Type a keyword for the selection (⌘K)")
        }
    }

    private func addKeyword() {
        state.addKeyword(newKeyword)
        newKeyword = ""
    }

    // MARK: Stacks

    private var stacks: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Stack")

            if let stack = state.primaryStack {
                Text("\(stack.memberCount) frame\(stack.memberCount == 1 ? "" : "s")"
                     + " · \(stack.collapsed ? "collapsed" : "expanded")"
                     + (stack.isPick ? " · this is the pick" : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    state.toggleStackCollapsed()
                } label: {
                    Text(stack.collapsed ? "Expand Stack" : "Collapse Stack")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))

                Button("Promote to Pick") { state.promoteStackPick() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(stack.isPick)

                Button("Unstack") { state.unstackSelection() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .help("Unstack (⇧⌘G)")
            } else {
                Text("Collapsed stacks show one frame each — the pick. Filter the grid "
                     + "to them with the Metadata chip.")
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Stack Selection") { state.stackSelection() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(state.selection.count < 2)
                .help("Group the selection into one stack (⌘G)")
        }
    }

    // MARK: Pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Lumen.secondaryText)
    }

    private func sourceRow(title: String, count: Int, isSelected: Bool,
                           isTarget: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isTarget {
                    Image(systemName: "target")
                        .font(.system(size: 9))
                        .foregroundStyle(Lumen.secondaryText)
                }
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Lumen.secondaryText)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(isSelected ? Lumen.primaryText : Lumen.secondaryText)
            .background(isSelected ? Lumen.fillColor.opacity(0.28) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }

    private func row(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Lumen.primaryText)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Lumen.secondaryText)
        }
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
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
            if let message = state.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
            }
            // The query, in words. It used to own the second row of a full-width filter
            // bar; the bar is one row now (docs/28 Phase 3) and the sentence outlived it
            // because it is the part worth keeping — better product thinking than
            // Lightroom's filter bar, which shows you lit chips and leaves you to
            // reconstruct what they mean together. Here it sits beside the count it
            // qualifies, which is where a query result belongs.
            Text(sentence)
                .font(.system(size: 10))
                .foregroundStyle(state.filter.isActive
                                 ? Lumen.primaryText : Lumen.tertiaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(sentence)
            Text(countText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Lumen.secondaryText)
            Spacer()
            if state.isExporting {
                Text("Exporting \(Int(state.exportProgress * 100))%")
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
            }
            if let photo = state.primarySelection {
                Text(photo.filename)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Lumen.secondaryText)
            }
            if state.selection.count > 1 {
                Text("\(state.selection.count) selected")
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.accent)
            }
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
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(Lumen.secondaryText)
            Text("Open a folder of photographs")
                .font(.system(size: 13))
                .foregroundStyle(Lumen.primaryText)
            Text("Folders are the library. Nothing is copied, moved, or modified.")
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
            Button("Open Folder…") { state.chooseFolder() }
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Keyboard reference

private struct KeyReferenceSheet: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard")
                    .font(.system(size: 15, weight: .semibold))
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
                                        .font(.system(size: 11, design: .monospaced))
                                        .frame(width: 84, alignment: .leading)
                                        .foregroundStyle(Lumen.primaryText)
                                    Text(entry.action)
                                        .font(.system(size: 11))
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
        }
        .frame(width: 460, height: 560)
        .background(Lumen.panelBackground)
    }
}

#endif

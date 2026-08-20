// ContentView.swift
// The three-pane shell: sources on the left, the picture in the middle, develop on the
// right, filmstrip underneath. The layout is deliberately boring — a photo editor's
// chrome should be furniture, and the only thing in the window that is allowed to be
// interesting is the photograph.

#if os(macOS)

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                FilterBar()
                Divider().overlay(Lumen.separator)
                HStack(spacing: 0) {
                    centre
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
        .sheet(isPresented: $state.showKeyReference) { KeyReferenceSheet() }
        .sheet(isPresented: $state.showExportSheet) { ExportSheet() }
    }

    private var showsDevelopColumn: Bool {
        state.primarySelection != nil && (state.viewMode == .loupe || state.viewMode == .compare)
    }

    @ViewBuilder
    private var centre: some View {
        if state.photos.isEmpty {
            EmptyState()
        } else {
            switch state.viewMode {
            case .grid:
                GridView()
            case .loupe:
                if state.primarySelection != nil {
                    LoupeView()
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

private struct Sidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
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

            Spacer()

            if let catalogStatus = state.catalogStatus {
                Text(catalogStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
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
        .background(Lumen.panelBackground)
    }

    private var counts: some View {
        let picked = state.allPhotos.filter { $0.flag == .picked }.count
        let rejected = state.allPhotos.filter { $0.flag == .rejected }.count
        return VStack(alignment: .leading, spacing: 3) {
            row("All photos", state.allPhotos.count)
            row("Picked", picked)
            row("Rejected", rejected)
            if state.filter.isActive {
                row("Showing", state.photos.count)
            }
        }
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
        HStack(spacing: 12) {
            if state.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
            Text(state.statusMessage ?? "")
                .font(.system(size: 10))
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

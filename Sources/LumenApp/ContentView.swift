// ContentView.swift
// Phase-1 three-pane shell (docs/12 layout, skeleton register): sources sidebar /
// center grid-or-loupe / develop panel. G and E switch views from day 1 — the
// keyboard grammar starts in the walking skeleton (docs/16 Phase 1).

#if os(macOS)

import LumenCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            HStack(spacing: 0) {
                centerView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if state.isLoupeVisible, let photo = state.selected {
                    Divider()
                    DevelopPanel(photo: photo)
                        .frame(width: 300)
                }
            }
            .background(Color(nsColor: .init(white: 0.16, alpha: 1))) // neutral gray, Law 7
        }
        .frame(minWidth: 1000, minHeight: 640)
        .overlay(keyboardShortcuts)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                state.chooseFolder()
            } label: {
                Label("Open Folder…", systemImage: "folder")
            }
            if let folder = state.folderURL {
                Text(folder.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
            }
            if let status = state.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private var centerView: some View {
        if state.photos.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("Open a folder of RAW files to begin")
                    .foregroundStyle(.secondary)
            }
        } else if state.isLoupeVisible, let photo = state.selected {
            LoupeView(photo: photo)
        } else {
            GridView()
        }
    }

    /// Invisible buttons carrying the bare-key grammar (G/E, arrows come via the
    /// grid/loupe onMoveCommand). Replaced by the full keyboard system in Phase 2.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { state.isLoupeVisible = false }
                .keyboardShortcut("g", modifiers: [])
            Button("") {
                if state.selected == nil { state.selected = state.photos.first }
                if state.selected != nil { state.isLoupeVisible = true }
            }
            .keyboardShortcut("e", modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }
}

#endif

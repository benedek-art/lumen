// GridView.swift
// The contact sheet, embedded previews only (Law 14). Selection follows clicks and
// arrow keys; double-click or E enters the loupe.

#if os(macOS)

import SwiftUI

struct GridView: View {
    @EnvironmentObject var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(state.photos) { photo in
                    GridCell(photo: photo, isSelected: state.selected == photo)
                        .onTapGesture(count: 2) {
                            state.selected = photo
                            state.isLoupeVisible = true
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            state.selected = photo
                        })
                }
            }
            .padding(8)
        }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: state.selectPrevious()
            case .right: state.selectNext()
            default: break
            }
        }
    }
}

private struct GridCell: View {
    @EnvironmentObject var state: AppState
    let photo: PhotoItem
    let isSelected: Bool

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Rectangle()
                    .fill(Color(nsColor: .init(white: 0.12, alpha: 1)))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            )
            Text(photo.filename)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
        }
        .task(id: photo.id) {
            thumbnail = await state.thumbnails.load(url: photo.id)
        }
    }
}

#endif

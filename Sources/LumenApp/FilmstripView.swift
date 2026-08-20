// FilmstripView.swift
// The strip under the loupe: a one-row grid of the same `PhotoCell`, drawing from the
// same thumbnail cache as the contact sheet — never a second preview system
// (docs/12 §B1). It exists so paging has a spatial sense of where you are in the
// take, and so a click is always an alternative to ←/→.
//
// Cells are a fixed small size here on purpose: the strip must not re-decode when the
// grid's thumbnail slider moves, and one cache level for the strip means the ring
// prefetch (8 ahead / 2 behind) warms exactly the frames paging is about to reach.

#if os(macOS)

import SwiftUI

struct FilmstripView: View {
    @EnvironmentObject var state: AppState

    /// Total strip height including padding; the cell is the remainder.
    var height: CGFloat = 92

    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 6
    /// One fixed cache level: the strip must not re-decode when the grid slider moves.
    private static let pixels: Int = 256

    var body: some View {
        let photos = state.photos
        let spacing = Self.spacing
        let padding = Self.padding
        let pixels = Self.pixels
        let side = max(height - padding * 2, 32)

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(photos) { photo in
                        PhotoCell(photo: photo,
                                  side: side,
                                  pixels: pixels,
                                  isSelected: state.selection.contains(photo.id),
                                  isPrimary: state.primarySelection?.id == photo.id,
                                  showsCaption: false,
                                  loader: state.thumbnails)
                            .onTapGesture(count: 2) {
                                state.select(photo)
                                state.showLoupe()
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                selectFromClick(photo, state: state)
                            })
                    }
                }
                .padding(.horizontal, padding)
                .padding(.vertical, padding)
            }
            .frame(height: height)
            .background(Lumen.panelBackground)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Lumen.separator)
                    .frame(height: 1)
            }
            .onAppear {
                if let id = state.primarySelection?.id {
                    proxy.scrollTo(id, anchor: .center)
                }
                state.thumbnails.prefetch(around: state.primarySelection?.id,
                                          in: photos.map(\.id), size: pixels)
            }
            .onChange(of: state.primarySelection?.id) { _, id in
                guard let id else { return }
                // Paging is the point of this strip, so the current frame is kept
                // centred; the move is animated only enough to read as motion.
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
                state.thumbnails.prefetch(around: id, in: photos.map(\.id), size: pixels)
            }
        }
        .frame(height: height)
    }
}

#endif

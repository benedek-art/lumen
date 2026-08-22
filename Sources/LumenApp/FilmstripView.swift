// FilmstripView.swift
// The strip under the loupe: a one-row grid of the same `PhotoCell`, drawing from the
// same thumbnail cache as the contact sheet — never a second preview system
// (docs/12 §B1). It exists so paging has a spatial sense of where you are in the
// take, and so a click is always an alternative to ←/→.
//
// Cells are a fixed small size here on purpose: the strip must not re-decode when the
// grid's thumbnail slider moves.
//
// That fixed size used to be the ONLY level this view's ring prefetch warmed, under a
// comment claiming the ring "warms exactly the frames paging is about to reach". It
// did not. Paging happens in the loupe above the strip, and the loupe asks the same
// cache for `ThumbnailLadder.loupeInstantPixels` — a different level entirely, so
// every advance found it cold and paid an embedded-JPEG decode before the pipeline
// even started. The strip passes `surface: .filmstrip` now, and the loader warms every
// level `ThumbnailLadder.warmSizes` names for that surface; which levels those are is
// asserted in LumenCore against the number the loupe actually requests.

#if os(macOS)

import LumenCore
import SwiftUI

struct FilmstripView: View {
    @EnvironmentObject var state: AppState

    /// Total strip height including padding; the cell is the remainder. Matches the
    /// height the shell reserves for the strip.
    var height: CGFloat = 96

    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 6
    /// One fixed cache level: the strip must not re-decode when the grid slider moves.
    private static let pixels: Int = 256

    /// The strip is on screen in every view mode, so which levels its ring warms is a
    /// fact about the view above it. Under the loupe the strip IS the paging surface
    /// and has to warm the viewer's level as well as its own; in the grid it is a
    /// second row of thumbnails, and warming the viewer's rung there would compete with
    /// the contact sheet's own scroll for the same eight decode workers.
    private var stripSurface: PagingSurface {
        state.viewMode == .loupe ? .filmstrip : .grid
    }

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
                                          in: photos.map(\.id), size: pixels,
                                          surface: stripSurface)
            }
            .onChange(of: state.primarySelection?.id) { _, id in
                guard let id else { return }
                // Paging is the point of this strip, so the current frame is kept
                // centred; the move is animated only enough to read as motion.
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
                state.thumbnails.prefetch(around: id, in: photos.map(\.id),
                                          size: pixels, surface: stripSurface)
            }
        }
        .frame(height: height)
    }
}

#endif

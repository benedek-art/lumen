// FilmstripView.swift
// The strip under the loupe: a one-row grid of the same `PhotoCell`, drawing from the
// same thumbnail cache as the contact sheet — never a second preview system
// (docs/12 §B1). It exists so paging has a spatial sense of where you are in the
// take, and so a click is always an alternative to ←/→.
//
// The left end carries the strip's own controls (docs/32 Stream A): the visible way
// back to the grid, and the height steps. The grid button exists because the round trip
// grid ⇄ loupe was half-invisible — double-click opened a photograph and only the `G`
// key came back, which is a door with a handle on one side. Hide/show lives in the
// status bar (`ContentView.StatusBar`), because a control that lives only on the thing
// it hides strands the way back the moment it works.
//
// Cells are a fixed small cache level here on purpose: the strip must not re-decode
// when the grid's thumbnail slider moves, and the height steps stay under that level —
// the tallest step's cell is 116 points, 232 pixels at 2×, inside the fixed 256.
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

    /// The strip's height in points, persisted. Written only by the two step buttons,
    /// so `@AppStorage`'s write-through costs one defaults write per deliberate click —
    /// not the per-event pattern the develop column's width has to avoid.
    @AppStorage("filmstrip.height") private var storedHeight: Double = 96

    /// The photo the last CLICK selected — the same suppression the grid runs, for the
    /// same double-click race. See `handleCellClick` in GridView.swift for the trace.
    @State private var lastClickedID: URL?

    /// Three steps, not a free drag: the strip is furniture, and 72/96/128 are the
    /// sizes at which the cells stay legible without the strip competing with the
    /// photograph. 128 is also the ceiling the fixed 256-pixel cache level can serve
    /// at 2× without a re-decode.
    private static let heightSteps: [CGFloat] = [72, 96, 128]

    private static let spacing: CGFloat = 6
    private static let padding: CGFloat = 6
    /// One fixed cache level: the strip must not re-decode when its height steps or
    /// the grid slider move.
    private static let pixels: Int = 256

    /// Clamped on read rather than on write, because a value restored from a previous
    /// version's bounds is not the user doing anything wrong.
    private var height: CGFloat {
        guard let floor = Self.heightSteps.first,
              let ceiling = Self.heightSteps.last else { return 96 }
        return Swift.min(Swift.max(CGFloat(storedHeight), floor), ceiling)
    }

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

        HStack(spacing: 0) {
            controls
            Divider()
                .overlay(Lumen.separator)
                .padding(.vertical, 8)
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
                                // ONE tap handler, exactly as in the grid — see
                                // `handleCellClick` for the double-click trace.
                                .onTapGesture {
                                    lastClickedID = photo.id
                                    handleCellClick(photo, state: state)
                                }
                        }
                    }
                    .padding(.horizontal, padding)
                    .padding(.vertical, padding)
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
                    // Paging is the point of this strip, so a KEYSTROKE keeps the
                    // current frame centred. A CLICK does not: the clicked cell is
                    // already under the pointer, and sliding the strip between the two
                    // clicks of a double-click is the same race the grid had — the
                    // second click lands on whatever moved in under the cursor.
                    if id == lastClickedID {
                        lastClickedID = nil
                    } else {
                        lastClickedID = nil
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    state.thumbnails.prefetch(around: id, in: photos.map(\.id),
                                              size: pixels, surface: stripSurface)
                }
            }
        }
        .frame(height: height)
        .background(Lumen.panelBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Lumen.separator)
                .frame(height: 1)
        }
    }

    // MARK: The strip's own controls

    /// Grid on top — the way back, made visible; the height steps underneath. The
    /// column is deliberately narrow furniture: three small glyphs, no words, with the
    /// words in the tooltips where every icon control in this app keeps them.
    private var controls: some View {
        VStack(spacing: 2) {
            stripButton(symbol: "square.grid.2x2",
                        help: "Grid (G) — back to the contact sheet",
                        disabled: state.viewMode == .grid) {
                state.showGrid()
            }
            Spacer(minLength: 0)
            stripButton(symbol: "chevron.up", help: "Taller filmstrip",
                        disabled: height >= (Self.heightSteps.last ?? 128)) {
                stepHeight(+1)
            }
            stripButton(symbol: "chevron.down", help: "Shorter filmstrip",
                        disabled: height <= (Self.heightSteps.first ?? 72)) {
                stepHeight(-1)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 3)
    }

    private func stripButton(symbol: String, help: String, disabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.lumenBodyStrong)
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Lumen.tertiaryText : Lumen.secondaryText)
        .disabled(disabled)
        .lumenHoverable(radius: Lumen.radiusChip, enabled: !disabled)
        .lumenClickCursor(!disabled)
        .help(help)
    }

    /// One step up or down the ladder. Nearest-step first, so a stored value from
    /// outside the family (an old build, a hand-edited default) still steps sanely
    /// instead of jumping to an end.
    private func stepHeight(_ direction: Int) {
        let steps = Self.heightSteps
        let current = steps.indices.min {
            abs(steps[$0] - height) < abs(steps[$1] - height)
        } ?? 1
        let next = Swift.min(Swift.max(current + direction, 0), steps.count - 1)
        storedHeight = Double(steps[next])
    }
}

#endif

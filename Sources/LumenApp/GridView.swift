// GridView.swift
// The contact sheet: the view the app is judged by, because it is the one a
// photographer stares at for an hour after a shoot. Embedded previews only (Law 14),
// cells sized by the thumbnail slider, badges read straight off the in-memory index.
//
// The scroll path is the budget (docs/10 §10.2: 8.3 ms/frame at 120 Hz, 5,000 cells),
// so a cell is deliberately dull: a rectangle, one image, a text line and at most
// three badge glyphs. No spinner (the progress ladder says nothing under a second),
// no per-cell timer, no shadow, no blur, no gradient, no view that animates on its
// own. A cell asks the loader one synchronous question — "have you got it?" — and
// otherwise waits in a structured task that dies with the cell when it scrolls away.
//
// This file also hosts `PhotoCell`, which the filmstrip reuses: the strip is a
// one-row grid backed by the same thumbnail cache, never a second preview system
// (docs/12 §B1).
//
// Keyboard belongs to the keymap, with one exception of geometry rather than grammar:
// the grid publishes its column count to `AppState.gridColumns`, because ↑/↓ mean
// "one row" and only the view that laid the row out knows how wide it is.

#if os(macOS)

import AppKit
import CoreGraphics
import LumenCore
import SwiftUI

struct GridView: View {
    @EnvironmentObject var state: AppState

    /// The photo the last CLICK selected, read by the auto-centering below. See the
    /// `onChange` for why a click must not centre and a keystroke must.
    @State private var lastClickedID: URL?

    private static let cellSpacing: CGFloat = 10

    var body: some View {
        let photos = state.photos
        let side = CGFloat(state.gridThumbnailSize)
        // Retina: ask for twice the point size, then let the loader snap to a cache level.
        let pixels = Int(side * 2)
        let spacing = Self.cellSpacing
        let columns = [GridItem(.adaptive(minimum: side, maximum: side), spacing: spacing)]

        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVGrid(columns: columns, spacing: spacing) {
                        ForEach(photos) { photo in
                            PhotoCell(photo: photo,
                                      side: side,
                                      pixels: pixels,
                                      isSelected: state.selection.contains(photo.id),
                                      isPrimary: state.primarySelection?.id == photo.id,
                                      showsCaption: side >= 110,
                                      // Stored on AppState, so this is the same
                                      // closure value on every pass rather than a
                                      // fresh identity per cell per body.
                                      onRate: state.ratingSink,
                                      loader: state.thumbnails)
                                // ONE tap handler, not a count-2 gesture racing a
                                // simultaneous count-1. See `handleCellClick` for the
                                // trace of why the pair "sometimes" lost the second
                                // click.
                                .onTapGesture {
                                    lastClickedID = photo.id
                                    handleCellClick(photo, state: state)
                                }
                        }
                    }
                    .padding(spacing)
                }
                // docs/30: every scroll view in the app is silent. A legacy scroller insets
                // its content, so an indicator appearing is a relayout of everything inside it.
                .scrollIndicators(.never)
                .background(Lumen.viewerBackground)
                .onAppear {
                    // ↑/↓ are the keymap's, but only the grid knows how wide a row is.
                    state.gridColumns = columnCount(width: geometry.size.width, side: side)
                    state.thumbnails.prefetch(around: state.primarySelection?.id,
                                              in: photos.map(\.id), size: pixels,
                                              surface: .grid)
                }
                .onChange(of: geometry.size.width) { _, width in
                    state.gridColumns = columnCount(width: width, side: side)
                }
                .onChange(of: side) { _, newSide in
                    state.gridColumns = columnCount(width: geometry.size.width, side: newSide)
                }
                .onChange(of: state.primarySelection?.id) { _, id in
                    guard let id else { return }
                    // CENTRE ON KEYSTROKES, NEVER ON CLICKS — and this is half of the
                    // double-click fix, not a taste call. A clicked cell is already
                    // under the pointer, so centring it moves the whole sheet BETWEEN
                    // the two clicks of a double-click: the second click lands on
                    // whatever thumbnail slid under the cursor, selecting a photograph
                    // nobody aimed at instead of opening the one they did. Arrow keys
                    // are the case this scroll exists for — they walk selection off
                    // screen and the sheet must follow.
                    if id == lastClickedID {
                        lastClickedID = nil
                    } else {
                        lastClickedID = nil
                        proxy.scrollTo(id, anchor: .center)
                    }
                    state.thumbnails.prefetch(around: id, in: photos.map(\.id),
                                              size: pixels, surface: .grid)
                }
            }
        }
        .overlay(emptyState(count: photos.count))
    }

    private func columnCount(width: CGFloat, side: CGFloat) -> Int {
        let spacing = Self.cellSpacing
        let usable = width - spacing
        guard side > 0, usable > 0 else { return 1 }
        return max(1, Int(usable / (side + spacing)))
    }

    @ViewBuilder
    private func emptyState(count: Int) -> some View {
        if count == 0 {
            VStack(spacing: 8) {
                Text(emptyMessage)
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.secondaryText)
                if state.filter.isActive {
                    Button("Clear Filter") { state.filter = LibraryFilter() }
                        .buttonStyle(.plain)
                        .font(.lumenBody)
                        .foregroundStyle(Lumen.primaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Lumen.viewerBackground)
        }
    }

    private var emptyMessage: String {
        if state.isScanning { return "Scanning…" }
        if state.filter.isActive { return "No photos match this filter" }
        return "Open a folder of RAW files to begin"
    }
}

// MARK: - Click grammar

/// EVERY CLICK ON A CELL LANDS HERE — single, double, modified — shared by the grid and
/// the filmstrip so the two cannot drift apart.
///
/// It replaces an `.onTapGesture(count: 2)` stacked with a `.simultaneousGesture(`
/// `TapGesture())`, which is the pair the owner reported as "sometimes doesn't work",
/// and the failure was mechanical, not timing luck:
///
///   1. The single tap ran SIMULTANEOUSLY — deliberately, so selection is instant
///      rather than waiting out a double-click interval — which means it fires on the
///      FIRST click of every double-click.
///   2. That first click's selection publish made the grid re-body AND, worse, ran
///      `proxy.scrollTo(id, anchor: .center)` in the selection `onChange` — an
///      unanimated jump that recentres the sheet on the clicked cell.
///   3. So between the two clicks of a double-click on any not-already-centred cell,
///      the content MOVED under a stationary pointer. The second click landed on a
///      different thumbnail: SwiftUI's count-2 recogniser never completed, and the
///      stray click selected a photograph nobody aimed at. Double-click on the
///      already-primary cell worked every time — no selection change, no scroll, no
///      re-body — which is exactly the "sometimes" in the report.
///
/// The fix has two halves. The grid/strip suppress the recentring for click-driven
/// selection (see their `onChange`s), so nothing moves between the clicks. And the
/// double-click stops being a second SwiftUI recogniser at all: this one handler reads
/// `clickCount` off the `NSEvent`, the way `selectFromClick` already reads modifiers.
/// AppKit counts clicks by time and pointer travel alone, so the count survives any
/// re-body — the first click selects, the second click of the same physical
/// double-click arrives with `clickCount == 2` and opens the loupe. Instant selection
/// is kept; no recogniser holds state that an update can reset.
///
/// A modified click never opens: ⌘ toggles membership and ⇧ extends, and two fast
/// ⌘-clicks are a selection gesture, not a request to leave the grid.
@MainActor
func handleCellClick(_ photo: PhotoItem, state: AppState) {
    let flags = NSEvent.modifierFlags
    let clicks = NSApp.currentEvent?.clickCount ?? 1
    if clicks >= 2 && !flags.contains(.command) && !flags.contains(.shift) {
        state.select(photo)
        state.showLoupe()
    } else {
        selectFromClick(photo, state: state)
    }
}

/// Click, ⇧-click, ⌘-click — shared by the grid and the filmstrip so the two cannot
/// drift apart. Modifiers are read from the current event rather than from separate
/// modifier-qualified gestures, which keeps one tap handler on the cell.
@MainActor
func selectFromClick(_ photo: PhotoItem, state: AppState) {
    let flags = NSEvent.modifierFlags
    if flags.contains(.command) {
        state.select(photo, toggling: true)
    } else if flags.contains(.shift) {
        state.select(photo, extending: true)
    } else {
        state.select(photo)
    }
}

// MARK: - Cell

/// One contact-sheet cell. Value-typed inputs only: it never reads AppState, so a
/// rating written three cells away does not invalidate the whole sheet.
struct PhotoCell: View {
    let photo: PhotoItem
    let side: CGFloat
    let pixels: Int
    let isSelected: Bool
    let isPrimary: Bool
    let showsCaption: Bool
    /// Non-nil turns the badge strip's stars into targets and reveals them on hover.
    ///
    /// The filmstrip passes nil: its cells are 96 points tall, and five click targets
    /// eleven points wide inside one of them is a dexterity test, not an affordance.
    let onRate: ((PhotoItem, Int) -> Void)?
    let loader: ThumbnailLoader

    @State private var image: CGImage? = nil
    /// Cell-local, so a pointer crossing one thumbnail invalidates one thumbnail. It
    /// never reaches AppState, which is what keeps this type's stated contract — value
    /// inputs only, no observation — true.
    @State private var hovering = false

    /// Spelled out rather than left to the memberwise initializer, which private
    /// state would otherwise make inaccessible from the filmstrip's file.
    init(photo: PhotoItem,
         side: CGFloat,
         pixels: Int,
         isSelected: Bool,
         isPrimary: Bool,
         showsCaption: Bool = true,
         onRate: ((PhotoItem, Int) -> Void)? = nil,
         loader: ThumbnailLoader) {
        self.photo = photo
        self.side = side
        self.pixels = pixels
        self.isSelected = isSelected
        self.isPrimary = isPrimary
        self.showsCaption = showsCaption
        self.onRate = onRate
        self.loader = loader
    }

    private var wellHeight: CGFloat { showsCaption ? side * 0.76 : side }

    private var hasBadges: Bool {
        photo.flag != .none || photo.rating > 0 || photo.label != .none
    }

    /// Hovering a rateable cell reveals the strip even on an untouched photo, so five
    /// empty stars appear under the pointer and nowhere else. Drawing them on every
    /// cell unconditionally would put three hundred grey stars on a contact sheet — the
    /// reason `hasBadges` exists at all.
    private var showsStars: Bool { photo.rating > 0 || (onRate != nil && hovering) }

    private var borderColor: Color {
        // Primary selection is the accent's textbook job (design audit §1.9): three
        // grays meant "which one am I actually on?" took a second look. Accent =
        // the photo you are on; light gray = also selected; quiet = the rest.
        if isPrimary { return Lumen.accent }
        if isSelected { return Lumen.fillColor }
        return Lumen.separator
    }

    var body: some View {
        VStack(spacing: 3) {
            well
            if showsCaption {
                Text(photo.filename)
                    .font(.lumenCaption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isPrimary ? Lumen.primaryText : Lumen.secondaryText)
                    .frame(width: side)
            }
        }
        .frame(width: side)
        .contentShape(Rectangle())
        .task(id: CellRequest(url: photo.id, pixels: pixels)) {
            await loadThumbnail()
        }
    }

    private var well: some View {
        ZStack {
            Rectangle()
                .fill(Lumen.controlBackground)
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // A rejected frame reads as rejected without leaving the sheet.
                    .opacity(photo.flag == .rejected ? 0.4 : 1)
            }
        }
        // 120 ms, first appearance only (docs/10 §10.2): never a white flash.
        .animation(.easeOut(duration: 0.12), value: image == nil)
        .frame(width: side, height: wellHeight)
        .overlay(alignment: .bottom) {
            if hasBadges || showsStars { badges }
        }
        .onHover { if onRate != nil { hovering = $0 } }
        .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Lumen.radiusControl, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isPrimary ? 2 : 1)
        )
    }

    private var badges: some View {
        HStack(spacing: 3) {
            if photo.flag != .none {
                Image(systemName: photo.flag.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(photo.flag == .picked ? Color.white : Lumen.secondaryText)
            }
            if showsStars { stars }
            Spacer(minLength: 0)
            if photo.label != .none {
                RoundedRectangle(cornerRadius: Lumen.swatchRadius(7))
                    .fill(photo.label.color)
                    .frame(width: 12, height: 7)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(width: side)
        .background(Color.black.opacity(0.45))
    }

    private var stars: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { index in
                if let onRate {
                    Button {
                        onRate(photo, index)
                    } label: {
                        star(index)
                            // The drawn star is 10 points; the target is the strip's
                            // full height, because aiming at a ten-point glyph and
                            // missing costs a rating on the wrong number.
                            .frame(width: 12, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(index == photo.rating ? "Clear the rating" : "Rate \(index)")
                } else {
                    star(index)
                }
            }
        }
    }

    private func star(_ index: Int) -> some View {
        Image(systemName: "star.fill")
            // 7pt was below any Mac legibility floor (design audit §1.9);
            // 10pt is the app-wide minimum now.
            .font(.lumenCaption)
            .foregroundStyle(index <= photo.rating ? Color.white : Lumen.trackColor)
    }

    private func loadThumbnail() async {
        if let hit = await loader.thumbnail(for: photo.id, size: pixels) {
            if image !== hit { image = hit }
            return
        }
        if let loaded = await loader.image(for: photo.id, size: pixels) {
            image = loaded
        }
    }
}

/// `.task` identity for a cell's pixels: the same photo at a new thumbnail size is a
/// new request, the same photo at the same size is not.
private struct CellRequest: Equatable {
    let url: URL
    let pixels: Int
}

#endif

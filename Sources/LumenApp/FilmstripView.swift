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
//
// One more thing this strip owes a photographer holding an arrow key down: it must land
// on the frame that is selected, not on the frame that was selected a beat ago. The
// centring scroll below is animated, and an animation that is restarted every 35 ms
// never arrives — see `CursorArrivals` for what that looked like and what replaced it.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

/// How fast the cursor is arriving, so the strip can tell paging from scrubbing.
///
/// A REFERENCE BOX, not `@State private var rate = EventRate()`, and that is the point
/// rather than an implementation detail: `@State` publishes on every write, so keeping
/// the meter as a struct in state would re-body the strip a second time per keystroke —
/// the exact per-key cost this file is spending its comments removing. Nothing draws
/// from this; it is scratch that the view writes through on its way past.
private final class CursorArrivals {

    private var rate = EventRate()

    /// Note that the cursor has just moved, and answer whether it is now moving faster
    /// than one scroll animation can finish.
    ///
    /// `false` for the first move after a pause — `EventRate` reports no rate from a
    /// single timestamp, which is the right answer here: one arrow press is paging, and
    /// paging is what the glide is for.
    ///
    /// The meter's window is a trailing second, so the strip stays in cut mode for a
    /// beat after the key comes up. That is deliberate rather than tolerated: a hand
    /// that has just run down forty frames is still running, and the frame the eye is
    /// catching up with should be waiting where it will be, not travelling towards it.
    func outrunsAnimation(settleSeconds: Double) -> Bool {
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        rate.record(at: now)
        guard let perSecond = rate.perSecond(now: now) else { return false }
        return perSecond * settleSeconds > 1
    }
}

struct FilmstripView: View {
    @EnvironmentObject var state: AppState

    /// The strip's height in points, persisted. Written only by the two step buttons,
    /// so `@AppStorage`'s write-through costs one defaults write per deliberate click —
    /// not the per-event pattern the develop column's width has to avoid.
    @AppStorage("filmstrip.height") private var storedHeight: Double = 96

    /// The photo the last CLICK selected — the same suppression the grid runs, for the
    /// same double-click race. See `handleCellClick` in GridView.swift for the trace.
    @State private var lastClickedID: URL?

    /// The key-repeat meter the centring scroll consults. Constructed once by `@State`
    /// and never republished; see `CursorArrivals`.
    @State private var arrivals = CursorArrivals()

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

    /// How long the centring scroll takes to arrive — `Lumen.motionState`'s own 0.12 s,
    /// written out because `Animation` does not answer questions about itself.
    ///
    /// It is a duration used as a RATE LIMIT: a cursor moving faster than one of these
    /// per second-fraction can never see the end of an animation, so above that the
    /// strip stops starting them. If the motion token is ever retimed, this number
    /// follows it — the two are the same fact, and the only thing keeping them together
    /// is this sentence.
    private static let settleSeconds: Double = 0.12

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
                    // The roll itself, not a fresh array of its URLs — see the grid's
                    // `onChange` for what that projection cost per key repeat.
                    state.thumbnails.prefetch(around: state.primarySelection?.id,
                                              in: photos, size: pixels,
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
                        // THE SCROLL IS ISSUED HERE, ON THIS PASS, IN BOTH BRANCHES.
                        // Only the glide is negotiable, and that is the whole of the
                        // rule: the strip may take 120 ms to move, it may never take
                        // 120 ms to decide WHICH frame to move to.
                        //
                        // Culling a real shoot means holding → down, and macOS repeats
                        // at 25–30 a second — three or four cursor moves inside one
                        // `motionState`. Each one restarted the animation from wherever
                        // the last one had got to, so the strip spent the whole run
                        // chasing a target it never reached and the cell under the
                        // centre line was never the selected one. That is precisely the
                        // drift a cull cannot have: the photographer rates what is in
                        // front of them.
                        //
                        // So above the rate one animation can settle, the strip CUTS.
                        // A single press, or a click, still glides — one move at a time
                        // is paging, and the glide is what makes the direction legible.
                        if arrivals.outrunsAnimation(settleSeconds: Self.settleSeconds) {
                            proxy.scrollTo(id, anchor: .center)
                        } else {
                            withAnimation(Lumen.motionState) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                    state.thumbnails.prefetch(around: id, in: photos,
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
                .font(.lumenGlyphBodyStrong)
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

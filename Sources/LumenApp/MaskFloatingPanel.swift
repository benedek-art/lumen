// MaskFloatingPanel.swift
// The Masks box: a real floating panel over the photograph, the way Lightroom does it.
//
// The owner asked for this shape three times, with two screenshots, and got something
// else twice. The first attempt left the mask list inline in the develop column, which
// was the clutter he was complaining about. The second turned the column's "Masks" label
// into a chip that opened a popover — and I argued in favour of that shape, on the
// grounds that a card over a 511-point centre pane covers half the picture, then shipped
// it as though the argument had been settled. It had not been. His answer: "You
// disregarded what I said and you just did your own thing."
//
// The width concern was real and it is answered here rather than used as a reason to
// build something else:
//
//   · It MINIMIZES to its own title bar — the control Lightroom puts in the same corner,
//     and the one that makes a floating panel affordable on a small screen.
//   · It is DRAGGABLE, so it goes where the photograph is not, and clamped so it cannot
//     be dragged somewhere it cannot be dragged back from.
//   · It only ever occludes its own footprint. It is a visible, opaque card: a stroke
//     that lands on it and not on the picture is not a mystery the way an invisible hit
//     region is, which is the difference between this and the docked pin that would have
//     eaten strokes at the frame's edge.
//
// What it deliberately does NOT do is fade itself out while a gesture runs underneath.
// Adobe ships a preference for that ("Auto Hide Masking Panel") and it was tempting, but
// the only signal available for it — `AppState.sliderGestureActive` — is documented as
// deliberately unpublished, because publishing it "would re-body the window twice per
// gesture for nothing". Today's work was about removing exactly that kind of cost. Drag
// it or collapse it; both are one gesture and neither costs a frame.

#if os(macOS)

import LumenCore
import SwiftUI

struct MaskFloatingPanel: View {

    @EnvironmentObject private var state: AppState
    /// This panel lists masks and draws their thumbnails, so it observes the edit
    /// signal — `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject private var edits: EditRevision

    /// The pane it floats over, so a drag cannot put it off the edge of the window.
    let bounds: CGSize

    @State private var dragging: CGSize = .zero
    @State private var titleHovered = false
    /// What the contents actually want to be. See the body: a `ScrollView` has no
    /// intrinsic height, so it has to be told one.
    @State private var measured: CGFloat = 240

    /// Wide enough for the kind board's three-across tiles, which is the one thing a
    /// roster chosen by recognition cannot give up. The develop column's minimum is 320
    /// and this is not bound by it.
    static let width: CGFloat = 236
    /// The title bar's own height, which is all that is left when minimized.
    static let barHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if !state.maskPanelMinimized {
                Divider().overlay(Lumen.separator)
                ScrollView(.vertical) {
                    MaskPanel(role: .navigator, showsOwnHeader: false)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
                        // MEASURED, because a `ScrollView` takes every point it is
                        // offered. `.frame(maxHeight:)` caps how tall it may get and does
                        // nothing at all about how tall it WANTS to be — so the panel was
                        // always its cap, with the list at the top and a field of empty
                        // grey underneath it. The owner: "it's way too large in terms of
                        // height. You can see there's so much empty space."
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: MaskPanelHeightKey.self,
                                                       value: proxy.size.height)
                            }
                        )
                }
                .frame(height: Swift.min(measured, contentHeight))
                .onPreferenceChange(MaskPanelHeightKey.self) { measured = $0 }
            }
        }
        .frame(width: Self.width)
        .lumenSurface(radius: Lumen.radiusCard, elevation: .floating, fill: Lumen.panel)
        .offset(x: clamped.width, y: clamped.height)
        .padding(12)
    }

    // MARK: - The bar

    /// Title, minimize, close — and the whole strip is the drag handle.
    ///
    /// Dragging by the title bar only, not by the body: the body is a list of masks whose
    /// rows are click targets, and a card that moved when you reached for a row would be
    /// unusable.
    private var titleBar: some View {
        HStack(spacing: 6) {
            // NO MASTER EYE YET, and its absence is deliberate rather than an
            // oversight. Lightroom carries "hide every mask" in this corner and it is a
            // real gap here — the only way to see the photograph clean is to switch
            // masks off one at a time and then remember which were already off. But it
            // is not view state: it has to reach the renderer, which means threading a
            // flag from `AppState` through `ViewerRenderKey` into the plan. Half of it
            // — a toggle that flips and changes no pixels — is the exact defect the rest
            // of this round was spent removing, so it waits until it can be done whole.
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
            LumenCapsLabel(text: "Masks", size: 11, color: Lumen.primaryText)
            if !masks.isEmpty {
                Text("\(masks.count)")
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.tertiaryText)
                    .monospacedDigit()
            }

            // CENTRED GRAB PILL, which is what says the panel moves. Lightroom puts one
            // in the same place and it is the only affordance for dragging it — without
            // it, a floating card looks fixed.
            Spacer(minLength: 4)
            Capsule()
                .fill(Lumen.secondaryText.opacity(titleHovered ? 0.55 : 0.3))
                .frame(width: 22, height: 2)
            Spacer(minLength: 4)

            barButton(state.maskPanelMinimized ? "chevron.down" : "chevron.up",
                      help: state.maskPanelMinimized
                          ? "Show the masks again"
                          : "Collapse to the title bar") {
                state.maskPanelMinimized.toggle()
            }
            barButton("xmark", help: "Hide this panel — the Masks button brings it back") {
                state.maskPanelVisible = false
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.barHeight)
        .background(titleHovered ? Lumen.controlHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { titleHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    dragging = CGSize(width: state.maskPanelOffset.width + value.translation.width,
                                      height: state.maskPanelOffset.height + value.translation.height)
                }
                .onEnded { _ in
                    state.maskPanelOffset = clamped
                    dragging = .zero
                }
        )
        .onTapGesture(count: 2) { state.maskPanelMinimized.toggle() }
    }

    private func barButton(_ symbol: String, help: String,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Lumen.secondaryText)
        .help(help)
    }

    // MARK: - Placement

    private var masks: [Mask] { state.currentRecipe.masks }

    /// How tall the list may grow before it scrolls inside itself.
    ///
    /// Bounded against the pane rather than fixed: on a short window a panel taller than
    /// the picture is worse than one that scrolls, and on a tall one there is no reason
    /// to make the photographer scroll a list that would fit.
    private var contentHeight: CGFloat {
        Swift.max(200, bounds.height - Self.barHeight - 90)
    }

    /// The offset, held inside the pane.
    ///
    /// A panel dragged off the window is a panel you cannot get back, and the title bar
    /// is the only part that can bring it home — so the clamp keeps the whole bar
    /// reachable rather than merely keeping one pixel on screen.
    private var clamped: CGSize {
        let live = dragging == .zero ? state.maskPanelOffset : dragging
        let maxX = Swift.max(0, bounds.width - Self.width - 24)
        let maxY = Swift.max(0, bounds.height - Self.barHeight - 24)
        return CGSize(width: Num.clamp(Double(live.width), 0, Double(maxX)),
                      height: Num.clamp(Double(live.height), 0, Double(maxY)))
    }
}

/// The navigator's natural height, reported up from its own contents.
private struct MaskPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = Swift.max(value, nextValue())
    }
}

#endif

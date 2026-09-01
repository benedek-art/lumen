// MaskFloatingPanel.swift
// The Masks box: a real floating panel over the photograph, the way Lightroom does it.
//
// The owner asked for this shape three times, with two screenshots, and got something
// else twice. The first attempt left the mask list inline in the develop column, which
// was the clutter he was complaining about. The second turned the column's "Masks" label
// into a chip that opened a popover — and I argued in favour of that shape, then shipped
// it as though the argument had been settled. It had not been.
//
// This file then got the shape right and the placement wrong. Three defects the owner
// found on first use, all of them in the twenty lines below, all of them fixed here:
//
//   · IT OPENED ON THE LEFT. `ContentView` mounted it in an `.overlay(alignment:
//     .topTrailing)` wrapped in a `GeometryReader` — and a `GeometryReader` is greedy.
//     It expanded to fill the whole overlay, so the alignment positioned the READER,
//     which filled everything, and the reader then placed the card at its own
//     top-LEADING corner. The alignment was never doing anything.
//
//   · DRAGGING IT WAS GLITCHY, and the cause is the classic one: a `DragGesture` with
//     no coordinate space measures in the LOCAL space of the view it is attached to,
//     and this gesture moves that view. Every frame the card moved, the space the
//     translation was measured in moved with it, so the next event's translation was
//     reported against a frame that had already been displaced — a feedback loop that
//     reads as stutter and overshoot. `.global` is a fixed frame and breaks it.
//     A second, quieter cause sat beside it: the offset was clamped on READ and stored
//     unclamped, so dragging past the edge silently accumulated travel the card never
//     showed, and dragging back did nothing at all until that debt was paid off. It is
//     clamped on WRITE now, so the card is always where the pointer is.
//
//   · MINIMIZING GAVE YOU NOTHING. It collapsed to the title bar — a control strip with
//     no content. The owner's rule: "one column, and one column just shows the picture
//     of the black and white gradient, and it shows all of them down the line." That is
//     `maskRail` below, and it is the reason minimizing is worth doing: the list at its
//     smallest useful size still tells you what every mask selects.
//
// The card rests at the pane's TOP-RIGHT, beside the histogram, and `maskPanelOffset` is
// a delta from there rather than an absolute position — so the resting place is right by
// construction and cannot drift when the window resizes.

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

    /// The live drag, as a delta from the RESTING top-right corner. Nil between drags,
    /// which is almost always — see `offset`.
    @State private var dragging: CGSize?
    @State private var titleHovered = false

    /// Wide enough that a mask's own name fits beside its picture.
    ///
    /// 236 was not. A row spends 14 on the disclosure chevron, 44 on the thumbnail, 16
    /// on the eye, 18 on the row menu and 28 on padding and gaps — 120 points of chrome
    /// — which left 96 for the name inside a 216-point content box. "Radial Gradient 1"
    /// needs about 105 at 12 pt, so EVERY default name in the panel arrived truncated,
    /// in the one panel whose entire job is telling masks apart. At 272 the name gets
    /// 132 and the default names fit whole.
    static let width: CGFloat = 272
    /// The collapsed column: one thumbnail wide, plus its breathing room.
    static let railWidth: CGFloat = 62
    /// The title bar's own height.
    static let barHeight: CGFloat = 28
    /// How far from the pane's edges the card is kept.
    private static let inset: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().overlay(Lumen.separator)
            if state.maskPanelMinimized {
                maskRail
            } else {
                // EXTRACTED, and the extraction is the third half of the drag fix.
                // `dragging` is `@State` on THIS view, so every one of the sixty-odd
                // mouse events a second a drag produces re-runs this `body`. When the
                // list was inline that meant re-evaluating the whole mask list, every
                // thumbnail and every menu per event. As its own view whose stored
                // properties do not change during a drag, SwiftUI can leave it alone.
                MaskFloatingPanelContent(maxHeight: contentHeight)
            }
        }
        .frame(width: state.maskPanelMinimized ? Self.railWidth : Self.width)
        .lumenSurface(radius: Lumen.radiusCard, elevation: .floating, fill: Lumen.panel)
        .offset(x: offset.width, y: offset.height)
        .padding(Self.inset)
    }

    // MARK: - The bar

    /// Create, title, collapse, close — and the whole strip is the drag handle.
    ///
    /// Dragging by the title bar only, not by the body: the body is a list of masks whose
    /// rows are click targets, and a card that moved when you reached for a row would be
    /// unusable.
    private var titleBar: some View {
        HStack(spacing: 5) {
            createButton
            if !state.maskPanelMinimized {
                LumenCapsLabel(text: "Masks", size: 11, color: Lumen.primaryText)
                if !masks.isEmpty {
                    Text("\(masks.count)")
                        .font(.lumenCaption)
                        .foregroundStyle(Lumen.tertiaryText)
                        .monospacedDigit()
                }
                // CENTRED GRAB PILL, which is what says the panel moves. Lightroom puts
                // one in the same place and it is the only affordance for dragging a
                // floating card — without it the card looks fixed.
                Spacer(minLength: 4)
                Capsule()
                    .fill(Lumen.secondaryText.opacity(titleHovered ? 0.55 : 0.3))
                    .frame(width: 22, height: 2)
            }
            Spacer(minLength: 2)
            barButton(state.maskPanelMinimized
                          ? "arrow.up.left.and.arrow.down.right"
                          : "arrow.down.right.and.arrow.up.left",
                      help: state.maskPanelMinimized
                          ? "Open the full list again"
                          : "Collapse to a column of mask pictures") {
                state.maskPanelMinimized.toggle()
            }
            if !state.maskPanelMinimized {
                barButton("xmark",
                          help: "Hide this panel — the Masks button brings it back") {
                    state.maskPanelVisible = false
                }
            }
        }
        .padding(.horizontal, 7)
        .frame(height: Self.barHeight)
        .background(titleHovered ? Lumen.controlHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { titleHovered = $0 }
        .gesture(
            // `.global`, and the coordinate space is the whole fix. See the file
            // comment: measuring a drag in the local space of the view the drag is
            // moving is a feedback loop.
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    // CLAMPED ON WRITE. Storing the raw translation and clamping it on
                    // the way out is what made the drag sticky: travel past the edge
                    // accumulated invisibly and had to be un-travelled before the card
                    // would move again.
                    dragging = clamp(CGSize(
                        width: state.maskPanelOffset.width + value.translation.width,
                        height: state.maskPanelOffset.height + value.translation.height))
                }
                .onEnded { _ in
                    if let dragging { state.maskPanelOffset = dragging }
                    dragging = nil
                }
        )
    }

    /// CREATE NEW MASK, as a round `+`.
    ///
    /// The owner, on the full-width disclosure button this replaces: "I don't feel like
    /// having this weird container looking thing is correct. I'd like it kind of a
    /// circle like Lightroom has it."
    ///
    /// In the title bar rather than in the list, for a reason the shape alone does not
    /// give: it is the one control that has to be reachable in BOTH states, and the
    /// collapsed column has no list to put it at the top of. Pressing it while collapsed
    /// opens the panel first, because a roster board 62 points wide is not a board.
    private var createButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                if state.maskPanelMinimized {
                    state.maskPanelMinimized = false
                    state.maskCreateBoardOpen = true
                } else {
                    state.maskCreateBoardOpen.toggle()
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(state.maskCreateBoardOpen
                                 ? Lumen.primaryText : Lumen.secondaryText)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(state.maskCreateBoardOpen
                                  ? Lumen.controlActive : Lumen.controlSurface)
                )
                .overlay(Circle().strokeBorder(Lumen.separator, lineWidth: 0.5))
                .rotationEffect(.degrees(state.maskCreateBoardOpen ? 45 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .lumenClickCursor()
        .help("Create a new mask — every kind, on one board")
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

    // MARK: - The collapsed column

    /// Every mask as a picture, one under the other, and nothing else.
    ///
    /// The owner's minimize, verbatim: "one column just shows the picture of the black
    /// and white gradient, and it shows all of them down the line." Clicking one selects
    /// it, so the column is a usable list and not a decoration — which is the whole
    /// argument for collapsing to this rather than to a bare title bar.
    private var maskRail: some View {
        ScrollView(.vertical) {
            VStack(spacing: 5) {
                ForEach(masks, id: \.id) { mask in
                    Button {
                        state.activeMaskID = mask.id
                        state.activeComponentIndex = 0
                    } label: {
                        MaskThumbnail(image: state.maskThumbnails[mask.id],
                                      enabled: mask.enabled,
                                      width: 44, height: 30,
                                      selected: mask.id == state.activeMaskID)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .lumenClickCursor()
                    .help(mask.name.isEmpty ? "This mask" : mask.name)
                    .onHover { inside in state.hoverMaskOverlay(inside ? mask.id : nil) }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .frame(height: Swift.min(contentHeight,
                                 CGFloat(masks.count) * 35 + 16))
    }

    // MARK: - Placement

    private var masks: [Mask] { state.currentRecipe.masks }

    /// How tall the list may grow before it scrolls inside itself.
    ///
    /// Bounded against the pane rather than fixed: on a short window a panel taller than
    /// the picture is worse than one that scrolls, and on a tall one there is no reason
    /// to make the photographer scroll a list that would fit.
    private var contentHeight: CGFloat {
        Swift.max(180, bounds.height - Self.barHeight - Self.inset * 2 - 24)
    }

    /// Where the card sits, as a delta from the pane's top-RIGHT corner.
    ///
    /// Zero is the resting place — beside the histogram, which is where the owner asked
    /// for it twice. `x` runs negative as it is dragged left and `y` positive as it is
    /// dragged down, and both are held inside the pane: a panel dragged off the window
    /// is a panel you cannot get back, and the title bar is the only part that can bring
    /// it home, so the clamp keeps the whole BAR reachable rather than one pixel of card.
    private var offset: CGSize { dragging ?? clamp(state.maskPanelOffset) }

    private func clamp(_ live: CGSize) -> CGSize {
        let cardWidth = state.maskPanelMinimized ? Self.railWidth : Self.width
        let leftmost = -Swift.max(0, bounds.width - cardWidth - Self.inset * 2)
        let lowest = Swift.max(0, bounds.height - Self.barHeight - Self.inset * 2)
        return CGSize(width: Num.clamp(Double(live.width), Double(leftmost), 0),
                      height: Num.clamp(Double(live.height), 0, Double(lowest)))
    }
}

/// The panel's contents, as their own view.
///
/// Split out so a drag of the title bar does not re-evaluate the mask list — see the
/// call site. Its one stored property does not change while a drag runs, which is what
/// lets SwiftUI skip it.
private struct MaskFloatingPanelContent: View {
    let maxHeight: CGFloat
    /// What the contents actually want to be. A `ScrollView` has no intrinsic height,
    /// so it takes every point it is offered and the panel was always its own cap, with
    /// the list at the top and a field of empty grey underneath it — the owner: "it's
    /// way too large in terms of height. You can see there's so much empty space."
    @State private var measured: CGFloat = 240

    var body: some View {
        ScrollView(.vertical) {
            MaskPanel(role: .navigator, showsOwnHeader: false)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: MaskPanelHeightKey.self,
                                               value: proxy.size.height)
                    }
                )
        }
        .frame(height: Swift.min(measured, maxHeight))
        .onPreferenceChange(MaskPanelHeightKey.self) { measured = $0 }
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

// CullBadgeStrip.swift
// Flag, stars and colour label on a Compare or Survey pane, so a decision made in the
// survey shows in the survey — the grid cell's badges, at pane scale, and clickable.
//
// A click makes that pane the active frame and runs the same verb as the key
// (`AppState.cullPane`), so the toggle, the undo step and auto-advance are the
// keyboard's. The label chip is display only; 6–9 and - set it.

#if os(macOS)

import LumenCore
import SwiftUI

struct CullBadgeStrip: View {

    @EnvironmentObject var state: AppState
    let photo: PhotoItem

    var body: some View {
        HStack(spacing: 4) {
            flagButton(.pick, help: "Pick")
            flagButton(.reject, help: "Reject")
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { index in
                    starButton(index)
                }
            }
            if let label = photo.label {
                RoundedRectangle(cornerRadius: Lumen.swatchRadius(7))
                    .fill(label.color)
                    .frame(width: 12, height: 7)
                    .help("\(label.displayName) label")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Lumen.hudFill)
        .clipShape(Capsule(style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CullMarks.summary(flag: photo.flag,
                                              rating: photo.rating,
                                              label: photo.label))
    }

    /// Lit when the photo carries this flag; clicking a lit flag clears it, as the
    /// key does.
    private func flagButton(_ flag: PhotoFlag, help: String) -> some View {
        let lit = photo.flag == flag
        return Button {
            state.cullPane(photo, flag: flag)
        } label: {
            Image(systemName: flag.symbolName)
                .font(.lumenGlyphCaptionStrong)
                .foregroundStyle(lit ? Color.white : Lumen.trackColor)
                .frame(width: 14, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(lit ? "Unflag" : help)
    }

    private func starButton(_ index: Int) -> some View {
        Button {
            state.cullPane(photo, rating: index)
        } label: {
            Image(systemName: "star.fill")
                .font(.lumenGlyphCaption)
                .foregroundStyle(index <= photo.rating ? Color.white : Lumen.trackColor)
                // A ten-point glyph in a strip-high target, as the grid cell does.
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(CullMarks.starHelp(index: index, rating: photo.rating))
    }
}

#endif

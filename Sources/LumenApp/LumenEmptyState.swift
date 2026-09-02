// LumenEmptyState.swift
// The one empty state, replacing five.
//
// An empty state is the app talking to a photographer at the only moment it has nothing
// to show them, and this app had five of them written five ways: the window's own (a
// 40 pt mark, a 13 pt line, an 11 pt line and a button), the grid's (one line of 11 pt
// text and sometimes a button, no mark at all), the compare pane's two (a 34 pt mark and
// a 26 pt mark, each with one line), and the viewer's unreadable-file state (a 30 pt mark
// and a hand-written 12 pt line). Four mark sizes, three text treatments, four stack
// spacings — for one idea, in a shell whose whole design argument is that it reads as one
// thing.
//
// None of that was anybody's decision. Each was written where it was needed by somebody
// looking at that one screen, which is exactly how a design system erodes and exactly
// what `DesignSystemTests` was built to catch — it just had no way to see a SHAPE
// repeated five times, only a token spelled out.
//
// THE MARK IS ONE SIZE. That is the choice worth naming, because the sizes it replaces
// look like they were reasoned about: 26 in a half-pane, 34 in a whole one, 40 in the
// window. They scale with the container, which is a plausible rule and the wrong one —
// an empty state is not a picture that should fill its frame, it is a sentence with a
// mark over it, and the mark's job is the same at every size. Scaling it makes the
// half-pane's version look like a different component, which is what it had become.
//
// The DETAIL line is optional and is where the honest sentence goes — "Folders are the
// library. Nothing is copied, moved, or modified." is the best line in the app's chrome
// and it exists because that state had room for it. The others now have room too.

#if os(macOS)

import SwiftUI

struct LumenEmptyState: View {
    /// The SF Symbol over the headline. Nil draws no mark, which the grid's overlay
    /// wants when it is sitting on top of a filmstrip that is already showing thumbnails
    /// — a mark there would be a second subject on a surface that has one.
    var symbol: String?
    /// What is going on, in a sentence a photographer can act on.
    let headline: String
    /// Why, or what to do about it. Optional because two of these states have nothing
    /// more honest to add than the headline already says.
    var detail: String?
    /// The one thing to do from here. Both must be present or neither draws.
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.lumenGlyphDisplay)
                    .foregroundStyle(Lumen.secondaryText)
            }
            Text(headline)
                .font(.lumenLead)
                .foregroundStyle(Lumen.primaryText)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.top, 6)
            }
        }
        // A width bound rather than none: a detail line running the width of a 1600 pt
        // window is a paragraph nobody reads, and centring it makes that worse. 260 is
        // about 55 characters at `lumenBody`, which is inside the measure prose wants.
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif

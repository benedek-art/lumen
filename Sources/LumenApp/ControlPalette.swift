// ControlPalette.swift
// ⌘K: name a control, go to it.
//
// docs/28 Phase 6 item 24. Nobody in the field has this — Lightroom, Capture One and
// Darkroom all require you to know which panel a slider is in — and on macOS a ⌘K
// palette reads as native rather than as a novelty, because every editor a photographer
// already uses has one.
//
// It matters MORE after Phase 4, not less. Four workspaces with collapsible sections is
// a better map than eight icon tabs, but it is still a map, and the fastest path to a
// control you can NAME should never be navigation. "Where is dehaze" is a question the
// app should answer rather than ask back.
//
// WHAT IT DOES, STATED HONESTLY, because the plan asked for more. It finds the control
// and opens the section it lives in — promoting the Simple register if that section is
// hidden, via `PanelLayout.reveal`. It does NOT yet scroll to and focus the individual
// row: every slider would need an identity the column could scroll to, which is a change
// to every panel rather than to this file, and it is worth doing separately where it can
// be seen. Typing "dehaze" and landing on an open Presence with Dehaze in it is the
// large majority of the value and none of that risk.
//
// The ranking is `ControlIndex` in LumenCore, where it is tested — it is exactly the
// kind of rule that is wrong in ways only examples reveal, and "sat" ranking Capture
// Sharpening above Saturation is not a thing anybody would notice by reading code.

#if os(macOS)
import LumenCore
import SwiftUI

struct ControlPalette: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var panel = PanelLayout.shared
    @State private var query: String = ""
    @State private var selection: Int = 0
    @FocusState private var fieldFocused: Bool

    private var results: [ControlIndex.Control] { ControlIndex.search(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Go to a control…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .focused($fieldFocused)
                // Every keystroke can change the list under the cursor, so the highlight
                // goes home rather than pointing at whatever now occupies row four.
                .onChange(of: query) { _, _ in selection = 0 }
                .onSubmit { commit() }

            Divider().overlay(Lumen.separator)

            if results.isEmpty {
                Text("No control by that name")
                    .font(.system(size: 12))
                    .foregroundStyle(Lumen.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) {
                                index, control in
                                row(control, isSelected: index == selection)
                                    .id(index)
                                    .onTapGesture {
                                        selection = index
                                        commit()
                                    }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    .onChange(of: selection) { _, new in
                        // Arrowing past the fold has to bring the row with it, or the
                        // highlight walks off screen and the palette looks frozen.
                        withAnimation(.linear(duration: 0.08)) { scroller.scrollTo(new) }
                    }
                }
            }
        }
        .frame(width: 460)
        .background(Lumen.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Lumen.separator))
        .shadow(radius: 24, y: 8)
        .onAppear { fieldFocused = true }
        // The arrows and Escape are claimed HERE rather than left to the dispatcher.
        // `KeyDispatcher`'s `NSEvent` monitor sits in front of the responder chain, so
        // without these an arrow press inside the palette would page to the next
        // photograph underneath it — the same hazard a focused slider has, solved the
        // same way.
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.escape) {
            state.showControlPalette = false
            return .handled
        }
    }

    private func row(_ control: ControlIndex.Control, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(control.title)
                .font(.system(size: 13))
                .foregroundStyle(Lumen.primaryText)
            Spacer()
            // WHERE IT WILL TAKE YOU, always. A palette that jumps somewhere unnamed is
            // a palette a photographer stops trusting after the first surprise, and this
            // line is also how they learn the four workspaces without being taught.
            Text("\(control.section.workspace.title) · \(control.section.title)")
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Lumen.fillColor.opacity(0.30) : Color.clear)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        // Clamped rather than wrapped: a list that jumps from the bottom to the top under
        // a held arrow loses the photographer's place, and there is no long list here to
        // make wrapping worth that.
        selection = min(max(selection + delta, 0), results.count - 1)
        return .handled
    }

    private func commit() {
        guard results.indices.contains(selection) else { return }
        let control = results[selection]
        // `reveal`, not `click`: half these sections are hidden by the Simple register
        // the app opens in, and a palette that answers a named request with silence is
        // worse than no palette at all.
        panel.reveal(control.section)
        state.showLoupe()
        state.showControlPalette = false
    }
}
#endif

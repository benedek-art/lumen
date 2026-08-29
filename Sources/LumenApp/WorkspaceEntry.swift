// WorkspaceEntry.swift
// Going to a workspace — the whole of it, in one verb.
//
// THE DEFECT THIS FILE EXISTS TO CLOSE, and it has now shipped three times in three
// different clothes:
//
//   · ⌘1 selected the Cull workspace and left the photographer in the loupe, looking at
//     one photograph with 320 points of empty space where the column had been. Fixed at
//     the menu item, by pairing `select` with `showGrid`.
//   · ⌘3 selected the Crop workspace without arming the crop tool, so the rectangle
//     never appeared. Fixed at the menu item, by pairing `select` with `showCrop`.
//   · And then the owner clicked the Crop TAB with the mouse — which calls neither of
//     those pairs, because they were written into the menu — and reported the tool
//     missing: "For the crop, when I go into it, I should be automatically taken into the
//     grid view where I can edit the crop. Right now, I don't really know how to edit it
//     by hand."
//
// He was not describing a missing feature. The rectangle, the eight handles, the rotate
// drag and the ratio lock were all built and all correct; the tab simply did not turn
// them on. Every route into a workspace had been fixed one at a time at its own call
// site, so each new route arrived unfixed, and the one a photographer actually uses —
// clicking the tab — was the one nobody had wired.
//
// So the pairing stops being something a call site remembers. `PanelLayout.select` moves
// the ARRANGEMENT and is deliberately unable to reach anything else (`PanelLayout`'s own
// header: "Nothing in this object touches `AppState`", and `WorkspaceLayout` lives in
// LumenCore where `AppState` does not exist). This is the layer above it: the one place
// that knows a workspace is a PLACE, with a view mode and a tool state attached, and the
// only thing the menu, the tab strip and the keys are allowed to call.
//
// ON `AppState` rather than beside it, because the two things a workspace switch has to
// reach besides the layout — the view mode and the loupe's viewport — are its own and its
// singleton's. A free function taking `AppState` would read identically and be one more
// name to know.

#if os(macOS)
import LumenCore
import SwiftUI

extension AppState {

    /// GO TO A WORKSPACE. The menu item, the tab, and the key all call this and nothing
    /// else.
    ///
    /// Three things happen, and the reason each is here rather than at a call site is
    /// that a call site is where they were and it is how they went missing:
    ///
    ///   · **The arrangement** — `PanelLayout.select`, which is equality-guarded, so
    ///     naming the workspace you are already in costs no publish.
    ///   · **The view mode** — Cull is the grid and the other four are the loupe. A
    ///     workspace whose sections adjust a photograph cannot be looked at from a
    ///     contact sheet.
    ///   · **The crop tool** — armed on the way in, disarmed on the way out.
    ///
    /// ARMING ON ENTRY IS THE POINT, and it is a stronger rule than "⌘3 also sets a
    /// flag". Crop is a workspace whose entire content is a direct manipulation of the
    /// picture: the panel holds the ratio, the angle and the guides, and the rectangle
    /// they describe is on the photograph. Entering it and finding no rectangle is
    /// entering a room with the lights off. So the invariant is now the simple one —
    /// **you are in the Crop workspace, therefore the tool is live** — and the flag is
    /// left to say the one thing the workspace cannot, which is whether the photographer
    /// has pressed Done to look at the result without leaving.
    ///
    /// LEAVING DISARMS, for the same reason in reverse: a crop rectangle drawn over a
    /// Grade workspace is a control from a room you walked out of. It does NOT end the
    /// crop session — `CropTool.beginSession` treats leaving and coming back as one piece
    /// of framing, so Revert still has its baseline — but it does forget the arming
    /// transition, so an `R` pressed after clicking away is a first press rather than the
    /// second half of a double press that would reset the crop.
    func enter(_ workspace: Workspace) {
        // `expose(.frame)` rather than `select(.crop)`, and only here: arriving in Crop
        // has to leave the Crop section OPEN, or the ratio, the angle and the guides are
        // one click further away than the rectangle they describe. It selects the
        // workspace on the way past, so this is still one publish rather than two, and it
        // is idempotent — see `PanelLayout.expose` for why that matters and why `reveal`
        // could not be used.
        if workspace == .crop {
            PanelLayout.shared.expose(.frame)
        } else {
            PanelLayout.shared.select(workspace)
        }
        settle(in: workspace)
    }

    /// GO TO A NAMED SECTION — the ⌘K palette, and the B / L / D keys.
    ///
    /// The same journey as `enter`, arranged differently: `reveal` solos the section
    /// asked for and promotes the register if it is hidden, which is what "take me to
    /// Detail" means and is not what clicking a tab means. Everything AFTER the
    /// arrangement is identical, and that is the part that kept going missing — the
    /// palette set the view mode and forgot the crop tool, the three keys forgot both, so
    /// pressing B from the grid opened Tone behind a contact sheet.
    func jump(to section: WorkspaceSection) {
        PanelLayout.shared.reveal(section)
        settle(in: section.workspace)
    }

    /// What arriving in a workspace means once the column has been arranged: the view
    /// mode, and the crop tool. Private, because the two verbs above are the vocabulary
    /// and a third caller reaching past them would be the next unwired route.
    private func settle(in workspace: Workspace) {
        if workspace == .cull {
            showGrid()
        } else {
            showLoupe()
        }

        let viewport = LoupeViewport.shared
        if workspace == .crop {
            viewport.showCrop = true
        } else if viewport.showCrop {
            viewport.showCrop = false
            viewport.showStraighten = false
            CropTool.shared.forgetArming()
        }
    }

    /// `R`, and the Crop tab pressed a second time: a round trip rather than a one-way
    /// door.
    ///
    /// From outside the workspace this is `enter(.crop)` — go there, tool live. From
    /// inside it toggles the tool without leaving, which is what "Done" means: the
    /// photograph redraws cropped and the ratio, angle and guide rows stay under the
    /// hand. Pressing it again puts the rectangle back.
    ///
    /// `enter` handles the way in, including opening the Crop section and promoting the
    /// register when the photographer is in Simple — so this stays two branches rather
    /// than growing its own copy of them.
    func toggleCropTool() {
        let viewport = LoupeViewport.shared
        guard PanelLayout.shared.layout.workspace == .crop else {
            enter(.crop)
            return
        }
        viewport.showCrop.toggle()
        if !viewport.showCrop { viewport.showStraighten = false }
        showLoupe()
    }
}
#endif

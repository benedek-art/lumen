// CropKeys.swift
// The crop tool's own keys, while its rectangle is on the photograph: X swaps
// portrait ↔ landscape, O cycles the guides and ⇧O turns them, the arrows nudge the
// crop (⇧ ×10), and Return puts the tool away keeping the crop. Escape (revert) stays
// in the dispatcher's Escape ladder, where it already was.
//
// Offered by one line in `KeyDispatcher.handle`, ahead of the arrow and character
// switches, the way `ParityKeys` offers its chords — so X and O mean what Lightroom
// means inside the crop tool and keep meaning reject and mask overlay everywhere else.
// Nil for anything it does not claim, so the rest of the grammar is untouched.

#if os(macOS)

import AppKit
import Foundation
import LumenCore

@MainActor
enum CropKeys {

    static func handle(_ event: NSEvent, state: AppState,
                       flags: NSEvent.ModifierFlags) -> Bool? {
        let viewport = LoupeViewport.shared
        // Only while the rectangle is the thing the photographer is inside. Masking and
        // healing own the photograph's keys when they are up, and a focused slider owns
        // the arrows (`LumenSlider`'s nudge).
        guard viewport.showCrop, state.viewMode == .loupe,
              !PanelLayout.shared.layout.isMasking, !HealTool.shared.armed,
              !state.sliderHoldsFocus else { return nil }
        if flags.contains(.option) { return nil }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
        else { return nil }
        let tool = CropTool.shared
        let shift = flags.contains(.shift)

        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey:
            tool.nudge(stepsX: -1, stepsY: 0, shift: shift, in: state)
            return true
        case NSRightArrowFunctionKey:
            tool.nudge(stepsX: 1, stepsY: 0, shift: shift, in: state)
            return true
        case NSUpArrowFunctionKey:
            tool.nudge(stepsX: 0, stepsY: -1, shift: shift, in: state)
            return true
        case NSDownArrowFunctionKey:
            tool.nudge(stepsX: 0, stepsY: 1, shift: shift, in: state)
            return true
        case 0x0D, 0x03:    // Return, and the keypad's Enter
            guard !event.isARepeat else { return true }
            tool.commit()
            return true
        default:
            break
        }

        switch Character(scalar).lowercased() {
        case "x":
            guard !event.isARepeat else { return true }
            tool.swapOrientation(in: state)
            return true
        case "o":
            guard !event.isARepeat else { return true }
            if shift {
                tool.turnGuide()
                state.statusMessage = tool.overlay.orientations > 1
                    ? "\(tool.overlay.title), turned"
                    : "\(tool.overlay.title) has no orientation to turn"
            } else {
                tool.cycleGuide()
                state.statusMessage = "Guide: \(tool.overlay.title)"
            }
            return true
        default:
            return nil
        }
    }
}

#endif

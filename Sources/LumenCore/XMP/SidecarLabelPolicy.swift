// SidecarLabelPolicy.swift
// What a culling keystroke is entitled to say about `xmp:Label`.
//
// The sidecar's label field is a double optional, and the two nils mean different
// things: `nil` is "this write has no opinion, leave whatever is in the file", and
// `.some(nil)` is "the photographer cleared the label, remove it". That distinction was
// designed and then never used — `saveCullingState` passed `.some(...)` unconditionally,
// so every flag and every rating keystroke also asserted a label.
//
// It asserted the app's five-case enum, and the enum is lossy. `appLabel(_:)` maps
// anything that is not red / yellow / green / blue / purple to `.none`, `.none` became
// `.some(nil)`, `XMPMerge` owns `xmp:Label` and strips it, and `fieldLines` did not put
// it back. So Lightroom's "To Print", a translated colour name, and any custom label
// were deleted from the file by pressing `2` — a rating — on a photograph somebody else
// had labelled. The XMP layer's own header promises the opposite: it is supposed to
// leave other tools' work alone.
//
// The rule below is what the app actually knows. It knows a label it can name. It knows
// when this edit changed the label. It does NOT know whether a `.none` it is holding
// means "no label" or "a label this build has no word for" — and the honest answer to a
// question you cannot answer is to say nothing.

import Foundation

public enum SidecarLabelPolicy {

    /// What to hand the sidecar writer for `xmp:Label`.
    ///
    /// - Parameters:
    ///   - appLabel: the label this build can name, or nil for none — which is both
    ///     "no label" and "a label outside the five cases", indistinguishably.
    ///   - labelChanged: whether THIS edit moved the label. The culling path knows it by
    ///     comparing the state it captured for undo before and after.
    /// - Returns: `nil` to leave the file's label untouched, `.some(nil)` to clear it,
    ///   `.some(name)` to write it.
    public static func write(appLabel: String?, labelChanged: Bool) -> String?? {
        if let appLabel, !appLabel.isEmpty { return .some(appLabel) }
        // Nothing this build can name. Only a change entitles it to clear the file:
        // the photographer took a label off, and that is a decision worth persisting.
        if labelChanged { return .some(nil) }
        // Otherwise this keystroke was about a flag or a rating and has nothing to say.
        return nil
    }
}

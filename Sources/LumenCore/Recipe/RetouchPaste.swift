// RetouchPaste.swift
// What Paste Settings does with retouching: by default, NOTHING — each target keeps its
// own spots and heal strokes.
//
// THE DEFECT. Paste Settings assigned `develop` whole, and since S5 exists `develop.heal`
// holds every Heal and Clone spot and every painted heal stroke. Those are positions in
// SOURCE coordinates on one photograph's blemishes; pasted across a shoot they land on a
// cheek, a horizon, an eye in every other frame, and they replaced whatever retouching
// each target already had. Lightroom leaves Spot Removal unchecked in its sync dialog for
// exactly this reason, and the masks next door already have their own way out (Paste
// Settings Without Masks) for the same one.
//
// So retouching travels only when the photographer opts in (`includingRetouch`, the
// Edit menu's "Paste Includes Spot Removal"), and when it does not travel the target's
// own `heal` is kept rather than emptied: a paste that is about white balance must not
// delete the dust work already done on the frame it lands on.
//
// Built as a `Develop` before it is assigned, never as "assign, then put the heal
// back": `Recipe.develop`'s observer raises the stated version the moment a spot
// arrives and never lowers it, so a round trip through the source's spots would leave a
// spot-free target stamped as a spot recipe.

import Foundation

public enum RetouchPaste {

    /// The `develop` a paste writes onto a target whose own is `target`.
    public static func develop(_ source: Develop, onto target: Develop,
                               includingRetouch: Bool) -> Develop {
        var out = source
        if !includingRetouch { out.heal = target.heal }
        return out
    }
}

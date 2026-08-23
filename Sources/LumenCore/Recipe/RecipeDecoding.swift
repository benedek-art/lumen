// RecipeDecoding.swift
// One rule, stated once, for every Codable type in the recipe format:
//
//     A RECIPE IS USER WORK. IT MUST NOT BE LOST TO AN ABSENT KEY.
//
// Swift's synthesized `Codable` conformance REQUIRES every non-optional key. A field
// added to a struct that has no `init(from decoder:)` therefore breaks every recipe
// already written — every catalog row, every `.xmp` sidecar — because none of them
// carries a key that did not exist when they were saved. That is not a hypothetical:
// `MixerBand.core` and `.feather` did exactly this, and the decode failure propagated
// out of `CatalogStore.currentRecipe` far enough to take down the registration of a
// whole folder. No catalog, so no rating, flag, label or edit persisted for any photo
// in it.
//
// So every type in the format decodes each of its keys with `decodeIfPresent(…) ??
// <the default in its own memberwise init>`. The fallback is never a judgement call and
// never a new value: it is the number already written a few lines above, which is what
// makes "an old recipe renders what it always rendered" true rather than hoped for.
//
// Three things this deliberately does NOT do.
//
// It does not swallow a key that is present with the WRONG TYPE. `"amount":"50"` still
// throws, because that is corruption rather than an older vocabulary, and a reader that
// silently substitutes a default for a value somebody's tool actually wrote is lying
// about the edit. Callers are expected to contain such a failure to the one photo it
// belongs to.
//
// It does not touch ENCODING. Every type here declares `CodingKeys` and `init(from:)`
// and lets `encode(to:)` stay synthesized, so what goes onto the wire — including the
// sparse omission of nil optionals — is byte-identical to what went onto it before.
// The recipe fingerprint keys every cache in the app; changing it by accident would
// throw away every rendered preview and artifact ever computed.
//
// It does not make unknown ENUM CASES tolerable. A `MaskKind` or a `Denoise.Mode`
// written by a LATER build still fails to decode here, and inventing a fallback case
// would be worse than the failure: a mask that silently becomes a different kind of
// mask renders a picture nobody asked for. Recorded rather than fixed.

import Foundation

/// Decoding rules the recipe format shares.
enum RecipeWire {

    /// A FIXED-LENGTH array field, decoded without discarding what arrived.
    ///
    /// Several fields in this format are arrays whose length is part of their meaning —
    /// the mixer's eight bands, a band's `[below, above]` arc handles, the zone pivots,
    /// the parametric curve's three splits, a Point Colour's RGB triple. Readers index
    /// them: `ColorEngine` walks eight black-and-white bands and reads `sample[0…2]`,
    /// and the colour panel reads that same triple with no guard at all. An array that
    /// arrives one element short from an older build would therefore survive the decode
    /// and trap somewhere further downstream, which is a worse failure than the one this
    /// file exists to end — it is the same lost work, minus the error message.
    ///
    /// THE RULE: take what is there, in order, and fill the rest from the default; an
    /// array longer than expected is truncated.
    ///
    /// The obvious alternative — a wrong length means fall back to the default array
    /// whole — is rejected, and the reason is the same one behind the whole file. A
    /// mixer that arrived with six real bands would lose all six because two were
    /// missing. Truncation discards only positions no reader can address, and padding
    /// keeps every value the photographer actually set.
    static func fixedLength<T>(_ decoded: [T]?, default defaults: [T]) -> [T] {
        guard let decoded, decoded.count != defaults.count else {
            return decoded ?? defaults
        }
        if decoded.count > defaults.count {
            return Array(decoded.prefix(defaults.count))
        }
        return decoded + defaults[decoded.count...]
    }
}

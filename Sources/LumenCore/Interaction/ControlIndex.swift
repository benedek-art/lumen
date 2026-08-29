// ControlIndex.swift
// Every control a photographer might go looking for, and where it lives.
//
// docs/28 Phase 6 item 24, the ⌘K palette: type a control's name and go to it. Nobody in
// the field has this — Lightroom, Capture One and Darkroom all make you know which panel
// a slider is in — and on macOS a ⌘K palette reads as native rather than as a novelty,
// because every editor the photographer already uses has one.
//
// IT MATTERS MORE AFTER PHASE 4, not less. Four workspaces with collapsible sections is
// a better map than eight icon tabs, but it is still a map, and the fastest path to a
// control you can NAME should never be navigation. "Where is dehaze" is a question the
// app should answer, not ask back.
//
// In LumenCore because matching is arithmetic and `Sources/LumenApp` compiles only on
// macOS: a ranking rule written there could not be tested by anything until CI, and
// ranking is exactly the kind of thing that is wrong in ways only examples reveal.
//
// This is a NAVIGATION index and `ProofRegistry` is a VERIFICATION one. They overlap and
// are deliberately not merged: the proof registry knows how to drive a control and what
// its authority floor is, and knows nothing about where it is drawn; this knows where it
// is drawn and nothing about what it does. `ControlIndexTests` asserts the overlap stays
// honest in the direction that matters — every proved control is findable.

import Foundation

public struct ControlIndex: Sendable {

    public struct Control: Equatable, Sendable, Identifiable {
        /// The recipe path, matching `ProofRegistry.ControlSpec.id` where one exists, so
        /// the two catalogues can be compared rather than merely coexisting.
        public let id: String
        /// What the panel prints. The palette shows this, so it must be the words on
        /// screen and not a developer's name for the field.
        public let title: String
        /// Where the palette sends you.
        public let section: WorkspaceSection
        /// Other words a photographer might reach for. NOT synonyms for their own sake —
        /// each of these is a name some other tool uses, or the abbreviation people
        /// actually type. "temp" for Temperature is the whole reason this field exists.
        public let aliases: [String]

        public init(id: String, title: String, section: WorkspaceSection,
                    aliases: [String] = []) {
            self.id = id
            self.title = title
            self.section = section
            self.aliases = aliases
        }
    }

    /// How well a query matched, worst to best. The palette sorts on this before it
    /// sorts on anything else, because a photographer typing "sat" means Saturation and
    /// not "Capture Sharpening" — which contains s, a and t in order and would otherwise
    /// rank alongside it.
    public enum Match: Int, Comparable, Sendable {
        case subsequence = 0
        case substring = 1
        case wordPrefix = 2
        case prefix = 3
        case exact = 4

        public static func < (a: Match, b: Match) -> Bool { a.rawValue < b.rawValue }
    }

    public static let all: [Control] = [
        // Develop — White Balance
        Control(id: "raw.temp", title: "Temperature", section: .whiteBalance,
                aliases: ["temp", "kelvin", "wb", "white balance", "warmth"]),
        Control(id: "raw.tint", title: "Tint", section: .whiteBalance,
                aliases: ["wb", "white balance", "green", "magenta"]),

        // Develop — Tone
        Control(id: "tone.exposure", title: "Exposure", section: .tone,
                aliases: ["ev", "brightness", "stops"]),
        Control(id: "tone.contrast", title: "Contrast", section: .tone),
        Control(id: "tone.contrastPivot", title: "Pivot", section: .tone,
                aliases: ["contrast pivot"]),
        Control(id: "tone.highlights", title: "Highlights", section: .tone,
                aliases: ["recovery"]),
        Control(id: "tone.shadows", title: "Shadows", section: .tone,
                aliases: ["fill", "lift"]),
        Control(id: "tone.whites", title: "Whites", section: .tone),
        Control(id: "tone.blacks", title: "Blacks", section: .tone),
        Control(id: "zones", title: "Zones", section: .tone,
                aliases: ["zone", "luminosity", "bands"]),

        // Develop — Curve
        Control(id: "curve", title: "Curve", section: .curve,
                aliases: ["tone curve", "points", "parametric"]),

        // Develop — Presence
        Control(id: "detail.texture", title: "Texture", section: .presence),
        Control(id: "detail.clarity", title: "Clarity", section: .presence,
                aliases: ["midtone contrast", "punch"]),
        Control(id: "detail.dehaze", title: "Dehaze", section: .presence,
                aliases: ["haze", "fog", "atmosphere"]),
        Control(id: "color.vibrance", title: "Vibrance", section: .presence,
                aliases: ["vib"]),
        Control(id: "color.saturation", title: "Saturation", section: .presence,
                aliases: ["sat", "chroma"]),

        // Develop — Detail
        Control(id: "detail.capture.amount", title: "Capture Sharpening",
                section: .detail, aliases: ["capture sharpen", "deconvolution"]),
        Control(id: "detail.sharpen.amount", title: "Sharpening", section: .detail,
                aliases: ["sharpen", "sharpness", "unsharp"]),
        Control(id: "denoise.amount", title: "Noise Reduction", section: .detail,
                aliases: ["denoise", "noise", "nr", "grain removal"]),

        // Develop — Optics
        Control(id: "geometry.crop", title: "Crop", section: .frame,
                aliases: ["aspect", "ratio", "trim"]),
        Control(id: "geometry.angle", title: "Straighten", section: .frame,
                aliases: ["angle", "rotate", "level", "horizon"]),
        Control(id: "geometry.lens", title: "Lens Corrections", section: .optics,
                aliases: ["distortion", "vignetting", "chromatic aberration", "ca"]),

        // Grade — Looks
        Control(id: "look.saved", title: "Saved Looks", section: .looks,
                aliases: ["preset", "presets", "look"]),
        Control(id: "look.render", title: "Display Transform", section: .looks,
                aliases: ["render", "transform", "tone mapping", "preset"]),
        // LUT is deliberately absent, for the same reason Retouch is (see below).
        //
        // It was here, and it was the index's one orphan: `look.lut` has no picker, no
        // importer and NO STAGE — `Recipe.swift` says so in as many words and
        // `renderIdentity` strips it. So typing "cube" or "film emulation" into ⌘K
        // returned one confident result, and Return took the photographer to a Looks
        // section containing Saved Looks and Display Transform and nothing else. The
        // palette answered a named request by sending them somewhere it isn't, which is
        // the one failure a palette must not have.
        //
        // "film emulation" moves to Film Lab, which is the control a photographer typing
        // that phrase is actually looking for — and which it did not match, because
        // "film emulation" is not a subsequence of "film lab".

        // Grade — Colour
        Control(id: "mixer", title: "Colour Mixer", section: .color,
                aliases: ["hsl", "mixer", "hue saturation luminance", "bands"]),
        Control(id: "pointColor", title: "Point Colour", section: .color,
                aliases: ["point color", "selective colour", "eyedropper"]),
        Control(id: "look.bw", title: "Black & White", section: .color,
                aliases: ["bw", "b&w", "monochrome", "mono", "greyscale", "grayscale"]),

        // Grade — Grading
        Control(id: "look.wheels", title: "Colour Grading", section: .grading,
                aliases: ["wheels", "colour balance", "color balance", "lift gamma gain",
                          "shadows midtones highlights"]),
        Control(id: "look.printerLights", title: "Printer Lights", section: .grading,
                aliases: ["printer", "darkroom", "rgb"]),
        Control(id: "look.primaries", title: "Primaries", section: .grading,
                aliases: ["primary", "hue purity", "gamut"]),

        // Grade — Film Lab
        Control(id: "look.filmLab", title: "Film Lab", section: .filmLab,
                aliases: ["film", "stock", "halation", "push pull", "portra",
                          "film emulation", "lut", "cube"]),

        // Grade — Effects
        Control(id: "look.vignette", title: "Vignette", section: .effects,
                aliases: ["vignetting", "corners", "edge darkening"]),
        Control(id: "look.filmLab.grain", title: "Grain", section: .effects,
                aliases: ["noise", "film grain"]),
        // Retouch is deliberately absent. Its section was deleted with the rest of
        // docs/30 Phase A: heal and clone are not implemented, and a named section whose
        // entire content was 43 words about its own absence cost a header, a paragraph
        // and the photographer's attention forever. A palette entry that reveals a
        // section with no trace of the thing you searched for is the same lie one level
        // up. It comes back when a stage renders a stroke.

        // Deliver
        Control(id: "softProof", title: "Soft Proof", section: .softProof,
                aliases: ["proof", "gamut warning", "paper", "print preview"]),
        Control(id: "exportRecipes", title: "Export Recipes", section: .exportRecipes,
                aliases: ["export", "save", "output", "jpeg", "tiff"]),
    ]

    /// Controls matching `query`, best first.
    ///
    /// An empty query returns everything, because a palette that opens blank and shows
    /// nothing looks broken — the first thing it should do is tell you what there is.
    ///
    /// Ranking is by match STRENGTH first and by the section's canonical order second,
    /// so equally-good matches come back in the order the panel draws them rather than
    /// in whatever order this table happens to be written. Ties inside a section fall
    /// back to the table's order, which is the panel's.
    public static func search(_ query: String, in catalogue: [Control] = all) -> [Control] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return catalogue }
        var scored: [(control: Control, match: Match, rank: Int, order: Int)] = []
        for (order, control) in catalogue.enumerated() {
            guard let match = strength(of: needle, against: control) else { continue }
            scored.append((control, match, control.section.canonicalRank, order))
        }
        return scored.sorted {
            if $0.match != $1.match { return $0.match > $1.match }
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.order < $1.order
        }.map(\.control)
    }

    /// The best match this control can offer for the needle, or nil if it does not match
    /// at all. Title and aliases compete and the strongest wins — "wb" is an exact alias
    /// of Temperature's and only a subsequence of its title, and the alias is what the
    /// photographer meant.
    static func strength(of needle: String, against control: Control) -> Match? {
        var best: Match?
        for candidate in [control.title] + control.aliases {
            guard let m = strength(of: needle, in: normalize(candidate)) else { continue }
            if best == nil || m > best! { best = m }
        }
        return best
    }

    static func strength(of needle: String, in hay: String) -> Match? {
        if hay == needle { return .exact }
        if hay.hasPrefix(needle) { return .prefix }
        // A word prefix, so "bal" finds "Colour balance" as strongly as "col" does. The
        // space is the only word boundary here on purpose: hyphens and ampersands appear
        // inside single names ("Black & White") where splitting would help nobody.
        if hay.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
            return .wordPrefix
        }
        if hay.contains(needle) { return .substring }
        return isSubsequence(needle, of: hay) ? .subsequence : nil
    }

    /// Every character of `needle`, in order, somewhere in `hay`. This is what lets
    /// "clrty" find Clarity, and it is also why it ranks last: it matches almost
    /// everything, and a ranking that let it compete with a prefix would bury the answer
    /// under coincidences.
    static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var i = needle.startIndex
        for character in hay where character == needle[i] {
            i = needle.index(after: i)
            if i == needle.endIndex { return true }
        }
        return needle.isEmpty
    }

    /// Case and surrounding space folded away. Deliberately NOT stripping punctuation:
    /// "b&w" is how people write it and the alias carries the ampersand, so removing it
    /// on both sides would be work that changes nothing.
    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

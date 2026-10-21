// SettingsSubset.swift
// Copy Settings…, Sync Settings… and Paste from Previous: the groups a photographer ticks,
// and the rule that carries only those groups from one recipe onto another.
//
// `adoptingSettings(from:includingMasks:includingRetouch:)` replaces the whole develop and
// the whole look, so a paste meant to deliver one white balance across a soccer burst
// also overwrote every frame's own crop, and an astro session's ISO-resolved noise
// reduction travelled from the ISO 800 frame onto the ISO 6400 ones. Lightroom answers
// with a checkbox dialog; these are its groups, cut along the same seams as
// `WorkspaceSection.reset` so "Presence" means the same three sliders and saturation in
// both places, with Crop and Lens apart for the reason `.frame` gives.
//
// THE RULE DELEGATES rather than repeats. A donor recipe is built — this recipe with the
// chosen groups taken from `source`, `source`'s masks, spots and version stamp — and
// handed to `adoptingSettings`. The unchosen groups are this recipe's own values, so
// replacing them is a no-op, and the render-preset boundary, the retouch rule and the
// version stamp (including its cap when spots stay behind) are the ones that rule
// already owns and tests. The stamp is the source's, as for a whole paste: it may claim
// more vocabulary than the chosen groups use, which is the side `adoptingSettings`
// already chooses — an over-stated stamp loses nothing, an under-stated one can.
//
// `develop.raw.decoder` and `decoderVersion` are facts about each FILE, not settings,
// so no group carries them; a whole-recipe paste still does, as it always has.

import Foundation

/// One checkbox of the Copy Settings… / Sync Settings… sheet.
///
/// `rawValue` is a persistence key (the last choice is remembered in UserDefaults), so
/// renaming a case discards what was stored under the old name. `title` is free to change.
public enum SettingsGroup: String, CaseIterable, Hashable, Codable, Sendable {
    /// Temperature and tint.
    case whiteBalance
    /// The six tone sliders and the zones.
    case tone
    /// Texture, clarity, dehaze, vibrance and saturation.
    case presence
    /// Parametric and point curves.
    case curve
    /// Colour mixer, point colour, black & white, grading wheels, printer lights, primaries.
    case colorAndGrading
    /// The display transform and the creative LUT.
    case displayTransform
    /// Capture sharpening and output sharpening.
    case sharpening
    /// The whole `develop.denoise`, which the app resolves per photograph from its ISO.
    case noiseReduction
    /// Lens profile, chromatic aberration, defringe.
    case lens
    /// Crop, straighten, flip and upright: everything in the geometry except the lens.
    case crop
    /// Vignette, creative grain and the Film Lab chain.
    case effects
    /// The masks and their folders, REPLACING the target's (as Paste Settings does).
    case masks
    /// Heal and Clone spots and painted heal strokes (`RetouchPaste`).
    case spotRemoval

    public var title: String {
        switch self {
        case .whiteBalance: return "White Balance"
        case .tone: return "Exposure & Tone"
        case .presence: return "Presence"
        case .curve: return "Tone Curve"
        case .colorAndGrading: return "Colour Mixer & Grading"
        case .displayTransform: return "Display Transform & LUT"
        case .sharpening: return "Detail & Sharpening"
        case .noiseReduction: return "Noise Reduction"
        case .lens: return "Lens Corrections"
        case .crop: return "Crop & Straighten"
        case .effects: return "Effects & Film"
        case .masks: return "Masks"
        case .spotRemoval: return "Spot Removal"
        }
    }

    /// The groups that are positions on, or measurements of, ONE frame: a crop, a mask's
    /// geometry, a spot's blemish, a denoise resolved from that frame's ISO. Left out of
    /// the default and printed under their own heading by the sheet.
    public var isPerFrame: Bool {
        switch self {
        case .crop, .masks, .spotRemoval, .noiseReduction: return true
        default: return false
        }
    }

    /// The first-run choice: everything that describes the look of a shoot, nothing that
    /// describes one frame (`isPerFrame`).
    public static let defaultSelection: Set<SettingsGroup> =
        Set(allCases.filter { !$0.isPerFrame })

    // MARK: Remembering the last choice

    /// The stored form: raw values in declaration order, comma-separated. An empty
    /// string is a real answer ("nothing ticked") and round-trips as the empty set.
    public static func storageString(_ groups: Set<SettingsGroup>) -> String {
        SettingsGroup.allCases.filter { groups.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    /// The set a stored string names. Nil — never stored — is the default; unknown
    /// names (a case renamed or removed since) are dropped rather than failing the read.
    public static func fromStorageString(_ stored: String?) -> Set<SettingsGroup> {
        guard let stored else { return defaultSelection }
        let names = stored.split(separator: ",").map(String.init)
        return Set(names.compactMap(SettingsGroup.init(rawValue:)))
    }

    /// A short phrase for the status bar: "White Balance, Exposure & Tone and 3 more".
    public static func summary(_ groups: Set<SettingsGroup>) -> String {
        let titles = SettingsGroup.allCases.filter { groups.contains($0) }.map(\.title)
        switch titles.count {
        case 0: return "nothing"
        case 1...2: return titles.joined(separator: " and ")
        default: return titles.prefix(2).joined(separator: ", ")
            + " and \(titles.count - 2) more"
        }
    }
}

extension Recipe {

    /// This recipe with only `groups` taken from `source`; everything else stays its own.
    /// An empty set returns this recipe unchanged. See the file header for the stamp.
    public func adoptingSettings(from source: Recipe,
                                 groups: Set<SettingsGroup>) -> Recipe {
        guard !groups.isEmpty else { return self }
        let from = source.develop
        var develop = self.develop
        var look = self.look
        for group in groups {
            switch group {
            case .whiteBalance:
                develop.raw.temp = from.raw.temp
                develop.raw.tint = from.raw.tint
            case .tone:
                develop.tone = from.tone
                develop.zones = from.zones
            case .presence:
                develop.detail.texture = from.detail.texture
                develop.detail.clarity = from.detail.clarity
                develop.detail.dehaze = from.detail.dehaze
                develop.color = from.color
            case .curve:
                develop.curve = from.curve
            case .colorAndGrading:
                develop.mixer = from.mixer
                develop.pointColors = from.pointColors
                look.bw = source.look.bw
                look.wheels = source.look.wheels
                look.printerLights = source.look.printerLights
                look.primaries = source.look.primaries
            case .displayTransform:
                look.render = source.look.render
                look.lut = source.look.lut
            case .sharpening:
                develop.detail.capture = from.detail.capture
                develop.detail.sharpen = from.detail.sharpen
            case .noiseReduction:
                develop.denoise = from.denoise
            case .lens:
                develop.geometry.lens = from.geometry.lens
            case .crop:
                let lens = develop.geometry.lens
                develop.geometry = from.geometry
                develop.geometry.lens = lens
            case .effects:
                look.vignette = source.look.vignette
                look.vignetteFeather = source.look.vignetteFeather
                look.vignetteMidpoint = source.look.vignetteMidpoint
                look.vignetteRoundness = source.look.vignetteRoundness
                look.vignetteHighlights = source.look.vignetteHighlights
                look.vignetteStyle = source.look.vignetteStyle
                look.grain = source.look.grain
                look.filmLab = source.look.filmLab
            case .masks, .spotRemoval:
                break        // passed to `adoptingSettings` as its two flags below
            }
        }
        // The source's retouching always goes into the donor: `RetouchPaste` puts this
        // recipe's own back when Spot Removal is unticked, and the stamp cap has to see
        // the SOURCE's spots to know there were spots that stayed behind.
        develop.heal = from.heal
        var donor = self
        donor.develop = develop
        donor.look = look
        donor.masks = source.masks
        donor.maskGroups = source.maskGroups
        // Assigned after `develop`, whose observer may have raised it for the spots.
        donor.pipelineVersion = source.pipelineVersion
        return adoptingSettings(from: donor, includingMasks: groups.contains(.masks),
                                includingRetouch: groups.contains(.spotRemoval))
    }
}

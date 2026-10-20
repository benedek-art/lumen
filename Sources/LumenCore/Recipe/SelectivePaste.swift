// SelectivePaste.swift
// Paste Selected Settings and settings presets: one rule for "carry THESE parts of that
// recipe onto this one".
//
// WHY A THIRD PASTE. Paste Settings and Paste Settings Without Masks both hand the
// target the source's whole `develop`, and `develop.geometry` is the CROP. A sports
// shooter who corrects white balance and exposure on one frame of a burst and pastes
// it across forty frames loses forty crops — every frame of a soccer game is framed on
// its own action. The same is true of denoise across an ISO ladder (an indoor game
// shot at 3200 and 12800 wants each frame's own profile) and of the curve in a
// sequence where the light changed. Lightroom's sync dialog exists for exactly this;
// the house rejected it as a question answered identically nine times in ten, and it
// is — but the tenth time is every game. So the dialog is a SEPARATE command, it
// remembers its last answer, and the two no-question pastes are untouched.
//
// WHAT A GROUP IS. Each `PasteGroup` names a subtree a photographer thinks of as one
// thing and a panel draws as one section. White balance is `raw.temp` and `raw.tint`
// ONLY: the decoder and its pinned version describe how THIS file is decoded and never
// travel (a JPEG has no decoder at all). Crop carries the framing (crop, straighten,
// flip, upright) and nothing else; lens corrections are their own group, because a
// lens profile is right for every frame from that lens and a crop is right for one.
//
// THE VERSION STAMP is `Recipe.adoptingSettings`'s rule, applied to what travelled: the
// newer of the two stamps when anything was carried, less the spot vocabulary when the
// spots stayed behind. Raising is the safe side — an older build refuses to write a
// document it may not represent, it never misreads one.

import Foundation

/// One section of a recipe that can be pasted, synced or saved on its own.
public enum PasteGroup: String, Codable, CaseIterable, Sendable, Hashable {
    case whiteBalance
    case tone
    case zones
    case curve
    case color
    case mixer
    case pointColor
    case detail
    case denoise
    case lens
    case crop
    case look
    case masks
    case retouch

    /// The name the paste sheet and the preset list print.
    public var label: String {
        switch self {
        case .whiteBalance: return "White Balance"
        case .tone: return "Tone"
        case .zones: return "Zones"
        case .curve: return "Curves"
        case .color: return "Vibrance & Saturation"
        case .mixer: return "Color Mixer"
        case .pointColor: return "Point Color"
        case .detail: return "Detail"
        case .denoise: return "Noise Reduction"
        case .lens: return "Lens Corrections"
        case .crop: return "Crop & Straighten"
        case .look: return "Look (Grade, Film, Effects)"
        case .masks: return "Masks"
        case .retouch: return "Spot Removal"
        }
    }

    /// The groups that describe ONE frame's content rather than its light or its
    /// treatment. Sync leaves them unticked by default; each lands on unrelated content
    /// in every other frame of a sequence.
    public static let perFrame: Set<PasteGroup> = [.crop, .masks, .retouch]

    /// "Everything a sequence shares": the sheet's starting selection and the answer
    /// to "sync this burst", which is every group except the per-frame ones.
    public static let syncDefault: Set<PasteGroup> = Set(allCases).subtracting(perFrame)

    /// The light-and-colour subset: what changes between two ends of a pitch under
    /// different floodlights. White balance and the tone sliders, nothing else.
    public static let exposureAndWhiteBalance: Set<PasteGroup> = [.whiteBalance, .tone]

    /// Groups in display order, for a stable list in UI and in stored presets.
    public static func ordered(_ groups: Set<PasteGroup>) -> [PasteGroup] {
        Self.allCases.filter(groups.contains)
    }
}

extension Recipe {

    /// This recipe with exactly the `groups` of `source` carried over, everything else
    /// left as it was. An empty set returns this recipe unchanged, stamp included.
    public func adopting(_ groups: Set<PasteGroup>, from source: Recipe) -> Recipe {
        guard !groups.isEmpty else { return self }
        var out = self
        // Built as one `Develop` and assigned once, so the raise-only observer on
        // `develop` sees only the retouching that actually lands.
        var d = develop
        let s = source.develop
        for group in groups {
            switch group {
            case .whiteBalance:
                d.raw.temp = s.raw.temp
                d.raw.tint = s.raw.tint
            case .tone: d.tone = s.tone
            case .zones: d.zones = s.zones
            case .curve: d.curve = s.curve
            case .color: d.color = s.color
            case .mixer: d.mixer = s.mixer
            case .pointColor: d.pointColors = s.pointColors
            case .detail: d.detail = s.detail
            case .denoise: d.denoise = s.denoise
            case .lens: d.geometry.lens = s.geometry.lens
            case .crop:
                d.geometry.crop = s.geometry.crop
                d.geometry.angle = s.geometry.angle
                d.geometry.flipH = s.geometry.flipH
                d.geometry.upright = s.geometry.upright
            case .retouch: d.heal = s.heal
            case .look:
                // The same leaf rule as Paste Look: a rendered file's Linear preset
                // never lands on a raw, and a raw's tone map never lands on a JPEG.
                let own = look.render.preset
                out.look = source.look
                out.look.render.preset =
                    LookSubset.carriedRenderPreset(source.look.render.preset, onto: own)
            case .masks:
                out.masks = source.masks
                out.maskGroups = source.maskGroups
            }
        }
        out.develop = d
        var carried = source.pipelineVersion
        let sourceHasRetouch = !s.heal.spots.isEmpty || s.heal.strokesRef != nil
        if !groups.contains(.retouch), sourceHasRetouch,
           carried <= healSpotsPipelineVersion {
            carried = Swift.min(carried, healSpotsPipelineVersion - 1)
        }
        out.pipelineVersion = Swift.max(out.pipelineVersion, carried)
        return out
    }

    /// The groups in which this recipe differs from `other` — what a paste of all of
    /// them would change. The sheet uses it to mark groups that would do nothing.
    public func differingGroups(from other: Recipe) -> Set<PasteGroup> {
        Set(PasteGroup.allCases.filter { group in
            adopting([group], from: other).withoutStamp != withoutStamp
        })
    }

    private var withoutStamp: Recipe {
        var copy = self
        copy.pipelineVersion = 0
        return copy
    }
}

/// Lightroom's "Previous": where the settings come from when there is no clipboard,
/// only the frame you just finished.
public enum PreviousFrame {
    /// The index of the frame just BEFORE the earliest selected one, in the order the
    /// roll is drawn. Nil when the selection is empty or starts at the first frame —
    /// there is nothing before it, and wrapping to the last frame of the shoot would
    /// paste a different scene's settings.
    public static func sourceIndex(selected: [Int]) -> Int? {
        guard let first = selected.min(), first > 0 else { return nil }
        return first - 1
    }
}

/// A named, saved selection of groups with the values they had when it was saved:
/// "Indoor soccer 6400" = white balance + tone + detail + noise reduction, applied to a
/// whole game in one gesture. Unlike a saved look it can carry develop groups.
public struct SettingsPreset: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var groups: [PasteGroup]
    public var recipe: Recipe

    public var id: String { name }

    public init(name: String, groups: Set<PasteGroup>, recipe: Recipe) {
        self.name = name
        self.groups = PasteGroup.ordered(groups)
        // The whole source is stored and only `groups` are ever read from it. Copying
        // the groups onto a blank `Recipe()` instead would run the look's render-preset
        // rule against the BLANK document's preset, and a JPEG's Linear would be lost.
        self.recipe = recipe
    }

    public var groupSet: Set<PasteGroup> { Set(groups) }

    /// `target` with this preset applied.
    public func applied(to target: Recipe) -> Recipe {
        target.adopting(groupSet, from: recipe)
    }

    private enum CodingKeys: String, CodingKey { case name, groups, recipe }

    /// Tolerant of a group a newer build added: an unknown raw value is dropped rather
    /// than failing the whole preset (and with it the whole list).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        let raw = (try? c.decode([String].self, forKey: .groups)) ?? []
        groups = PasteGroup.ordered(Set(raw.compactMap(PasteGroup.init(rawValue:))))
        recipe = try c.decode(Recipe.self, forKey: .recipe)
    }
}

/// The saved presets as one ordered list, with the edits a list UI needs. Pure value
/// logic; the app decides where the bytes live.
public struct SettingsPresetLibrary: Equatable, Sendable {
    public private(set) var presets: [SettingsPreset]

    public init(presets: [SettingsPreset] = []) { self.presets = presets }

    /// Saving under an existing name replaces that preset in place (case-insensitive,
    /// whitespace-trimmed), so "Save" twice is an update and not a duplicate. A blank
    /// name or an empty group set is refused and returns false.
    @discardableResult
    public mutating func save(_ preset: SettingsPreset) -> Bool {
        var preset = preset
        preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.name.isEmpty, !preset.groups.isEmpty else { return false }
        if let i = index(named: preset.name) {
            presets[i] = preset
        } else {
            presets.append(preset)
        }
        return true
    }

    public mutating func delete(named name: String) {
        if let i = index(named: name) { presets.remove(at: i) }
    }

    public func preset(named name: String) -> SettingsPreset? {
        index(named: name).map { presets[$0] }
    }

    private func index(named name: String) -> Int? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return presets.firstIndex { $0.name.lowercased() == key }
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(presets)) ?? Data("[]".utf8)
    }

    /// Decodes a stored list, skipping any entry that does not decode rather than
    /// losing every preset to one bad one. Unreadable bytes give an empty library.
    public static func decode(_ data: Data) -> SettingsPresetLibrary {
        struct Lossy: Decodable {
            let preset: SettingsPreset?
            init(from decoder: Decoder) throws {
                preset = try? SettingsPreset(from: decoder)
            }
        }
        let list = (try? JSONDecoder().decode([Lossy].self, from: data)) ?? []
        return SettingsPresetLibrary(presets: list.compactMap(\.preset))
    }
}

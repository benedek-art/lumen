// DevelopPreset.swift
// A named develop preset: some of a recipe's settings groups, kept to put on other photos.
//
// Lightroom's develop preset is the tool for "Soccer ISO 6400" (white balance, noise
// reduction, sharpening) or "Astro base" (WB, tone, lens): a ticked subset of one
// photograph's settings, applied to a whole selection later. Saved Looks cannot hold
// it: `LookSubset` carries the look layer only, by design. This holds the same groups
// Copy Settings… and Sync Settings… tick (`SettingsGroup`) and applies them through the
// same rule (`Recipe.adoptingSettings(from:groups:)`), so a preset, a sync and a
// selective paste of the same groups land identically.
//
// THREE GROUPS ARE NOT OFFERED: crop, masks and spot removal. Each is a position on one
// frame (`SettingsGroup.isPerFrame`), and a preset is for frames it has never seen — the
// same three Lightroom leaves out of its preset dialog. Noise reduction IS offered,
// although it is per-frame for a sync: a high-ISO NR recipe is exactly what the soccer
// preset is for, and ticking it is the photographer's explicit choice.
//
// `settings` is a whole recipe, but only the chosen groups differ from `Recipe()`:
// `captured` builds it by adopting those groups onto a default recipe, so the stored
// JSON is sparse and holds nothing the preset does not apply.
//
// THE FILE FORMAT is a versioned JSON envelope (`lumen-develop-preset`, version 1) with
// the settings as canonical sparse recipe JSON, so missing keys read as defaults and
// unknown ones are ignored, as for recipes. A file from a newer format version, or with
// a recipe stamp this build cannot represent, is refused by name rather than read lossily.

import Foundation

public struct DevelopPreset: Equatable, Sendable {
    /// Normalized by `LookSubset.normalizedName` — the saved-look rule.
    public var name: String
    /// Always a non-empty subset of `offeredGroups`.
    public var groups: Set<SettingsGroup>
    /// `Recipe()` with the chosen groups adopted from the photo it was saved off.
    public var settings: Recipe

    /// The groups a preset can carry, in sheet order. See the header for the three left out.
    public static let offeredGroups: [SettingsGroup] = SettingsGroup.allCases.filter {
        $0 != .crop && $0 != .masks && $0 != .spotRemoval
    }

    /// First-run ticks for the save sheet: the look-of-a-shoot groups, as for a sync.
    public static let defaultGroups: Set<SettingsGroup> =
        SettingsGroup.defaultSelection.intersection(offeredGroups)

    /// Nil when the name is blank or no offered group is chosen. Unoffered groups are dropped.
    public init?(name: String, groups: Set<SettingsGroup>, settings: Recipe) {
        guard let clean = LookSubset.normalizedName(name) else { return nil }
        let kept = groups.intersection(DevelopPreset.offeredGroups)
        guard !kept.isEmpty else { return nil }
        self.name = clean
        self.groups = kept
        self.settings = settings
    }

    /// A preset of `groups` taken from `recipe`.
    public static func captured(named name: String, from recipe: Recipe,
                                groups: Set<SettingsGroup>) -> DevelopPreset? {
        let kept = groups.intersection(offeredGroups)
        let settings = Recipe().adoptingSettings(from: recipe, groups: kept)
        return DevelopPreset(name: name, groups: kept, settings: settings)
    }

    /// `recipe` with this preset's groups; everything else, masks and spots included,
    /// stays the photo's own.
    public func applied(to recipe: Recipe) -> Recipe {
        recipe.adoptingSettings(from: settings, groups: groups)
    }

    /// "White Balance, Noise Reduction and 1 more", for menus and the status bar.
    public var summary: String { SettingsGroup.summary(groups) }

    /// Same name (case-insensitively) — the library's uniqueness rule.
    public func hasName(_ other: String) -> Bool {
        name.lowercased() == (LookSubset.normalizedName(other) ?? other).lowercased()
    }
}

// MARK: - Files

/// Why a preset file could not be read. `message` is the status-bar sentence.
public enum DevelopPresetFileError: Error, Equatable, Sendable {
    case notJSON
    case notAPresetFile
    /// The envelope's `version` is newer than this build writes.
    case newerFormat(Int)
    /// The settings' `pipelineVersion` is newer than this build can represent.
    case newerRecipe(Int)
    /// A preset with no name, or none of the groups this build offers.
    case emptyPreset
    case unreadableSettings

    public var message: String {
        switch self {
        case .notJSON: return "is not a JSON file"
        case .notAPresetFile: return "is not a Lumen develop preset file"
        case .newerFormat(let v): return "was written by a newer Lumen (format \(v))"
        case .newerRecipe(let v): return "needs a newer Lumen (recipe version \(v))"
        case .emptyPreset: return "holds a preset with no name or no settings Lumen can apply"
        case .unreadableSettings: return "holds settings Lumen cannot read"
        }
    }
}

extension DevelopPreset {

    /// `format` of a one-preset file and of a library file.
    public static let fileFormat = "lumen-develop-preset"
    public static let libraryFormat = "lumen-develop-presets"
    /// The envelope version this build writes and the newest it reads.
    public static let fileVersion = 1
    /// The extension Export writes. Import takes any JSON file whose `format` matches.
    public static let fileExtension = "lumenpreset"

    /// The preset as a JSON object: name, groups in declaration order, sparse settings.
    func jsonValue() throws -> JSONValue {
        let settingsJSON = try CanonicalJSON.canonicalRecipeJSON(settings)
        let settingsTree = try JSONDecoder().decode(JSONValue.self,
                                                    from: Data(settingsJSON.utf8))
        let names = SettingsGroup.allCases.filter { groups.contains($0) }
            .map { JSONValue.string($0.rawValue) }
        return .object([
            "name": .string(name),
            "groups": .array(names),
            "settings": settingsTree,
        ])
    }

    /// Reads one preset object. Unknown group names are dropped (a renamed case, or a
    /// group a later build added); a preset left with none is refused.
    static func fromJSONValue(_ value: JSONValue) throws -> DevelopPreset {
        guard case .object(let object) = value,
              case .string(let name)? = object["name"],
              case .array(let groupValues)? = object["groups"],
              case .object(let settingsObject)? = object["settings"]
        else { throw DevelopPresetFileError.notAPresetFile }
        if case .number(let stamp)? = settingsObject["pipelineVersion"],
           Int(stamp) > supportedPipelineVersion {
            throw DevelopPresetFileError.newerRecipe(Int(stamp))
        }
        let groups: [SettingsGroup] = groupValues.compactMap { item in
            guard case .string(let raw) = item else { return nil }
            return SettingsGroup(rawValue: raw)
        }
        let data = Data(CanonicalJSON.serialize(.object(settingsObject)).utf8)
        guard let settings = try? CanonicalJSON.decodeRecipe(from: data) else {
            throw DevelopPresetFileError.unreadableSettings
        }
        guard let preset = DevelopPreset(name: name, groups: Set(groups),
                                         settings: settings)
        else { throw DevelopPresetFileError.emptyPreset }
        return preset
    }

    /// A one-preset file (`fileFormat`), canonical JSON.
    public func fileData() throws -> Data {
        let envelope = JSONValue.object([
            "format": .string(DevelopPreset.fileFormat),
            "version": .number(Double(DevelopPreset.fileVersion)),
            "preset": try jsonValue(),
        ])
        return Data(CanonicalJSON.serialize(envelope).utf8)
    }

    /// Several presets in one file (`libraryFormat`) — Export All, and the library's own
    /// file on disk.
    public static func libraryData(_ presets: [DevelopPreset]) throws -> Data {
        let envelope = JSONValue.object([
            "format": .string(libraryFormat),
            "version": .number(Double(fileVersion)),
            "presets": .array(try presets.map { try $0.jsonValue() }),
        ])
        return Data(CanonicalJSON.serialize(envelope).utf8)
    }

    /// The presets in a file of either format. Strict: one unreadable preset fails the
    /// file, so a library is never rewritten without a preset it could not read.
    public static func presets(fromFileData data: Data) throws -> [DevelopPreset] {
        guard let tree = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DevelopPresetFileError.notJSON
        }
        guard case .object(let envelope) = tree,
              case .string(let format)? = envelope["format"],
              case .number(let version)? = envelope["version"]
        else { throw DevelopPresetFileError.notAPresetFile }
        guard format == fileFormat || format == libraryFormat else {
            throw DevelopPresetFileError.notAPresetFile
        }
        guard Int(version) <= fileVersion else {
            throw DevelopPresetFileError.newerFormat(Int(version))
        }
        if format == fileFormat {
            guard let preset = envelope["preset"] else {
                throw DevelopPresetFileError.notAPresetFile
            }
            return [try fromJSONValue(preset)]
        }
        guard case .array(let items)? = envelope["presets"] else {
            throw DevelopPresetFileError.notAPresetFile
        }
        return try items.map(fromJSONValue)
    }

    /// A file name for Export: the preset's name less the characters Finder or a
    /// shell would trip over.
    public var suggestedFileName: String {
        let unsafe: Set<Character> = ["/", ":", "\\", "?", "*", "\"", "<", ">", "|"]
        let cleaned = String(name.map { unsafe.contains($0) ? "-" : $0 })
        return cleaned + "." + DevelopPreset.fileExtension
    }
}

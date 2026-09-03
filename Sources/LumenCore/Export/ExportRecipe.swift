// ExportRecipe.swift
// The multi-recipe export model (D40, docs/11): a set of named recipes, any number of
// which can be checked at once, so one Export click emits the web JPEG, the print TIFF
// and the HDR HEIC together. That gesture is real, it works, and Lightroom Classic still
// cannot do it.
//
// What it does NOT do is share the render. This header used to say "the render forks at
// the resize node — everything upstream is computed once and shared, which is why three
// recipes cost far less than three exports", and that is false:
// `AppStateActions.export` loops photos × recipes and each iteration calls
// `PipelineRenderer.export`, which builds a fresh `RenderGraph` and renders the full
// develop chain end to end. Three checked recipes cost three full renders. The one thing
// reused is the decoded `CIImage`, from `ImageSource`'s own cache.
//
// Stated here rather than quietly dropped, because the false version was load-bearing on
// a user's behaviour: it is the sentence that tells a photographer checking a fourth
// recipe is nearly free.

import Foundation

// MARK: - Tolerant decoding

/// TOLERANCE THAT REACHES THE NESTED TYPES.
///
/// `ExportRecipe.init(from:)` below already makes every top-level key optional (K-016),
/// and that tolerance was one level deep. `decodeIfPresent` returns nil for a key that
/// is ABSENT; a key that is PRESENT is handed to its type's own decoder and everything
/// that decoder objects to is rethrown straight through. So a stored `sharpen` object
/// written before a field this build added throws `keyNotFound` from inside
/// `OutputSharpen`'s synthesised decoder, and a `"format":"avif"` written by a later
/// build throws `dataCorrupted` from `ExportFormat`'s — both out of the recipe, and out
/// of `JSONDecoder.decode([ExportRecipe].self)`, which decodes an array atomically, so
/// one entry takes all of them. `AppState.loadExportRecipes` reads that with `try?` and
/// answers `ExportRecipe.defaults`; the first edit afterwards fires `didSet` and
/// `saveExportRecipes` overwrites the stored blob with the stock four. Every delivery
/// preset the photographer ever built, gone, with no error and nothing to restore from.
///
/// ONE helper rather than a fallback written out per field, because the defect is not
/// any of the six enums or the four nested structs — it is that reading stored preset
/// text can throw at all. Every decoder in this file reads through `tolerant`, which
/// makes the guarantee structural rather than enumerated: once `ExportRecipe.init(from:)`
/// holds its container, nothing it does can throw, whatever a nested type does — a
/// nested type nobody has written yet included. The four nested types get tolerant
/// decoders of their own anyway, for GRANULARITY, not for safety: without them the outer
/// fallback would swallow a whole `sharpen` object over one added key and quietly reset
/// a medium and an amount the photographer chose. Braces for the door we know about,
/// belt for the one we do not.
///
/// This is deliberately the OPPOSITE rule from `RecipeDecoding.swift`, which refuses to
/// substitute a default for a value somebody's tool actually wrote, on two grounds: a
/// mask that silently becomes another kind of mask renders a picture nobody asked for,
/// and its caller can contain the failure to the one photo it belongs to. Neither holds
/// here. A preset is an instruction that is VISIBLE — a format that came back JPEG
/// because this build has never heard of AVIF shows as JPEG in the export sheet, beside
/// the name and subfolder the photographer gave it, and is one click from right. And the
/// caller can contain nothing: the list is a single blob, decoded atomically, with the
/// stock four waiting behind it. The choice is not "the stored value or a default", it
/// is "the preset with one field defaulted or no presets at all".
///
/// The one door this cannot close from here: an array element that is not an object at
/// all throws before `init(from:)` is ever given a container. Only an element-by-element
/// decode in the caller survives that, and the caller is `AppState.loadExportRecipes`.
///
/// The ENCODER stays synthesised everywhere, as it was. Writing is this build's job and
/// this build knows all its own fields; only reading has to survive the other builds.
extension ExportRecipe {

    /// A stored preset list, decoded ELEMENT BY ELEMENT.
    ///
    /// The tolerant decoder below makes any one `ExportRecipe` survive a field it does
    /// not understand. It cannot make the ARRAY survive, and that is the other half of
    /// J3-01: `JSONDecoder` decodes an array atomically, so a single element that is not
    /// even a JSON object — a null, a string, a shape from a format this build predates —
    /// throws, and the caller's `try?` hands back the stock four. Every delivery preset
    /// the photographer ever made, replaced, with no error anywhere. The next edit's
    /// `didSet` then writes those four over the stored blob, so it is not recoverable by
    /// relaunching either.
    ///
    /// Decoding through an unkeyed container makes the blast radius one entry: a bad
    /// element is skipped and named in the log, and the presets either side of it live.
    ///
    /// SKIPPING IS THE HARD PART, and the obvious spelling is a hang. An unkeyed
    /// container advances `currentIndex` only on a decode that SUCCEEDS, and
    /// `decodeNil()` advances only when the value genuinely is null — so on a element
    /// that is a string, a number, or an object this decoder cannot read, `decodeNil()`
    /// answers false, consumes nothing, `isAtEnd` never becomes true, and the loop spins
    /// forever. That is worse than the defect it was written to fix: a stored blob with
    /// one bad element would hang the app on launch instead of merely losing the list.
    ///
    /// The first draft of this function did exactly that, and the comment here asserted
    /// the property the code did not have. `test-fast` hung on
    /// `testOneUnreadableElementCostsOnlyItself` and reported no failing test at all,
    /// which is what a hang looks like from the outside.
    ///
    /// `Skipped` is the fix and it cannot fail: its `init(from:)` reads nothing, so
    /// `decode` always succeeds and the index always advances. One element consumed per
    /// iteration, whatever the element is.
    ///
    /// It returns the list even when EMPTY, and the distinction matters: "the file has no
    /// presets" is a thing a photographer can mean by deleting them all, and answering
    /// that with the stock four resurrects four presets he threw away. Only a MISSING or
    /// unreadable blob deserves the defaults, and that is the caller's `nil`.
    public static func decodeList(_ data: Data) -> [ExportRecipe]? {
        /// Consumes exactly one element of an unkeyed container and reads nothing from
        /// it. `init(from:)` cannot throw, so `decode` cannot fail, so `currentIndex`
        /// always advances — which is the whole job.
        struct Skipped: Decodable {
            init(from decoder: Decoder) throws {}
        }

        struct Wire: Decodable {
            var recipes: [ExportRecipe] = []
            var skipped = 0
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                while !c.isAtEnd {
                    if let one = try? c.decode(ExportRecipe.self) {
                        recipes.append(one)
                    } else {
                        // Unconditional, and it is what makes the loop terminate.
                        _ = try? c.decode(Skipped.self)
                        skipped += 1
                    }
                }
            }
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        if wire.skipped > 0 {
            NSLog("Lumen: %d stored export preset(s) could not be read and were skipped; "
                  + "the other %d are intact", wire.skipped, wire.recipes.count)
        }
        return wire.recipes
    }
}

fileprivate extension KeyedDecodingContainer {

    /// The stored value, or `fallback` when the key is absent, null, or unreadable —
    /// wrong type, unknown enum raw value, or a nested object whose own decode threw.
    ///
    /// `try?` flattens the optional `decodeIfPresent` already returns (SE-0230), which
    /// is why one `??` covers all four: absent, null and unreadable are deliberately the
    /// same answer here, because the fallback is the right answer to all of them.
    func tolerant<T: Decodable>(_ type: T.Type, forKey key: Key,
                                default fallback: @autoclosure () -> T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? fallback()
    }

    /// The same for a field whose absence is itself the value — `watermark`, `subfolder`,
    /// `hdr`. Unreadable and absent answer alike here, which is what "no watermark" means.
    func tolerant<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

// MARK: - Format

public enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case jpeg, heif, tiff, png

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heif: return "heic"
        case .tiff: return "tif"
        case .png: return "png"
        }
    }

    public var supportsQuality: Bool {
        self == .jpeg || self == .heif
    }

    public var supportsSixteenBit: Bool {
        self == .tiff || self == .png
    }

    /// HEIC is the one lossy container with a deeper option: HEVC has a Main 10
    /// profile, and Core Image can author it (`writeHEIF10Representation`, macOS 12+).
    /// Whether THIS machine's encoder accepts it is a runtime question the pipeline
    /// probes (`PipelineRenderer.canWriteTenBitHEIC`); this flag is only the format's
    /// side of the answer. JPEG has no such option — 8-bit is the format.
    public var supportsTenBit: Bool {
        self == .heif
    }

    /// Only the two modern container formats can carry a gain map (docs/11 §HDR).
    public var supportsGainMap: Bool {
        self == .heif || self == .jpeg
    }
}

public enum ExportColorSpace: String, Codable, Sendable, CaseIterable {
    case srgb, displayP3, adobeRGB, rec2020, proPhoto

    public var space: RGBColorSpace {
        switch self {
        case .srgb: return .srgb
        case .displayP3: return .displayP3
        case .adobeRGB: return .adobeRGB
        case .rec2020: return .rec2020
        case .proPhoto: return .proPhoto
        }
    }

    public var displayName: String {
        switch self {
        case .srgb: return "sRGB"
        case .displayP3: return "Display P3"
        case .adobeRGB: return "Adobe RGB (1998)"
        case .rec2020: return "Rec. 2020"
        case .proPhoto: return "ProPhoto RGB"
        }
    }
}

public enum ResizeMode: String, Codable, Sendable, CaseIterable {
    case none
    case longEdge
    case shortEdge
    case width
    case height
    case megapixels

    public var displayName: String {
        switch self {
        case .none: return "Don't resize"
        case .longEdge: return "Long edge"
        case .shortEdge: return "Short edge"
        case .width: return "Width"
        case .height: return "Height"
        case .megapixels: return "Megapixels"
        }
    }
}

/// What leaves the building with the picture. Stripping GPS by default is the one
/// privacy decision that should never need to be remembered.
public struct MetadataPolicy: Codable, Equatable, Sendable {
    public var includeEXIF: Bool
    public var includeCameraSerial: Bool
    public var includeGPS: Bool
    public var includeKeywords: Bool
    public var copyright: String?
    public var contact: String?

    public init(includeEXIF: Bool = true, includeCameraSerial: Bool = false,
                includeGPS: Bool = false, includeKeywords: Bool = true,
                copyright: String? = nil, contact: String? = nil) {
        self.includeEXIF = includeEXIF
        self.includeCameraSerial = includeCameraSerial
        self.includeGPS = includeGPS
        self.includeKeywords = includeKeywords
        self.copyright = copyright
        self.contact = contact
    }

    /// Tolerant, per the note at the top of this file: a policy stored before this
    /// build grew a key keeps the four flags and two strings it does carry, rather
    /// than costing the recipe it belongs to — and the whole list behind it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = MetadataPolicy()
        includeEXIF = c.tolerant(Bool.self, forKey: .includeEXIF,
                                 default: fallback.includeEXIF)
        includeCameraSerial = c.tolerant(Bool.self, forKey: .includeCameraSerial,
                                         default: fallback.includeCameraSerial)
        includeGPS = c.tolerant(Bool.self, forKey: .includeGPS, default: fallback.includeGPS)
        includeKeywords = c.tolerant(Bool.self, forKey: .includeKeywords,
                                     default: fallback.includeKeywords)
        copyright = c.tolerant(String.self, forKey: .copyright)
        contact = c.tolerant(String.self, forKey: .contact)
    }
}

// MARK: - Output sharpening

/// Fraser-style output sharpening: the halo width is anchored to the *viewing* medium,
/// not to the pixel grid — a print at 300 ppi wants a wider radius than a screen image
/// at the same pixel dimensions, and matte paper wants more energy than glossy because
/// the ink spreads.
public struct OutputSharpen: Codable, Equatable, Sendable {

    public enum Medium: String, Codable, Sendable, CaseIterable {
        case none, screen, matte, glossy

        public var displayName: String {
            switch self {
            case .none: return "None"
            case .screen: return "Screen"
            case .matte: return "Matte paper"
            case .glossy: return "Glossy paper"
            }
        }
    }

    public enum Amount: String, Codable, Sendable, CaseIterable {
        case low, standard, high

        public var scale: Double {
            switch self {
            case .low: return 0.65
            case .standard: return 1.0
            case .high: return 1.45
            }
        }
    }

    public var medium: Medium
    public var amount: Amount

    public init(medium: Medium = .none, amount: Amount = .standard) {
        self.medium = medium
        self.amount = amount
    }

    /// Tolerant, per the note at the top of this file. Both fields are raw-value enums,
    /// which is the half that matters here: a `medium` this build has no case for falls
    /// back to Off and leaves `amount` exactly as the photographer set it, instead of
    /// throwing `dataCorrupted` and taking every preset in the list with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = OutputSharpen()
        medium = c.tolerant(Medium.self, forKey: .medium, default: fallback.medium)
        amount = c.tolerant(Amount.self, forKey: .amount, default: fallback.amount)
    }

    /// Base radius in output pixels, before the amount scale.
    ///
    /// Screen: ~1 px, the width of the display's own sampling. Print: the halo should
    /// subtend 1/50″–1/100″ at the print's resolution, so it scales with ppi — matte
    /// wider (1/50″) because the ink spreads, glossy tighter (1/100″).
    public func baseRadius(printPPI: Double = 300) -> Double {
        switch medium {
        case .none: return 0
        case .screen: return 1.0
        case .matte: return Swift.max(printPPI / 50.0 / 2.0, 1.0)
        case .glossy: return Swift.max(printPPI / 100.0 / 2.0, 1.0)
        }
    }

    /// The bounds `PipelineRenderer.applyOutputSharpen` clamps its radius to. Here,
    /// beside the formula, so the export sheet's readout and the renderer share one
    /// number: matte at the Resolution slider's typed-entry ceiling (2400 ppi) derives
    /// a 24 px radius, the renderer runs 12, and a readout printing the formula's
    /// answer would be claiming a halo twice as wide as the one delivered.
    public static let appliedRadiusBounds: ClosedRange<Double> = 0.3...12

    /// The radius the renderer actually runs: `baseRadius` through the shared clamp,
    /// and exactly zero when the medium is Off — the renderer skips the filter
    /// entirely then, and a clamp that turned "off" into 0.3 px would undo that.
    public func appliedRadius(printPPI: Double = 300) -> Double {
        guard !isIdentity else { return 0 }
        return Num.clamp(baseRadius(printPPI: printPPI),
                         Self.appliedRadiusBounds.lowerBound,
                         Self.appliedRadiusBounds.upperBound)
    }

    /// Sharpening energy — the master amount, and the only amount.
    ///
    /// This used to say that "asymmetric dark:light weighting (dark halos read as
    /// 'crisp', light halos read as 'oversharpened') is applied by the renderer", and it
    /// is not applied by anything. `PipelineRenderer.applyOutputSharpen` builds a bare
    /// `CIUnsharpMask` from `baseRadius` and this number, and an unsharp mask halos
    /// symmetrically by construction: it adds the same high-pass on both sides of an
    /// edge. The ratio the sentence referred to was a `lightHaloRatio = 0.6` constant
    /// with no reader anywhere in the repository, so the asymmetry existed as a number
    /// and a claim and nothing else.
    ///
    /// The observation behind it is sound and is why docs/11 asks for the asymmetry: a
    /// light halo along a skyline is the tell that gives "oversharpened" its name, and
    /// a dark one at the same amplitude reads as definition. Delivering it needs a
    /// two-sided kernel — split the high-pass by sign and scale the positive lobe to
    /// about 0.6 of the negative — which is a new kernel with its own halo bound to
    /// assert, and it is not written. The constant is gone rather than left sitting
    /// beside a function that does not consult it; the number it held is recorded in
    /// this sentence, which is the only place it was ever doing any work.
    public func energy() -> Double {
        switch medium {
        case .none: return 0
        case .screen: return 0.55 * amount.scale
        case .matte: return 0.95 * amount.scale
        case .glossy: return 0.70 * amount.scale
        }
    }

    public var isIdentity: Bool { medium == .none }
}

// MARK: - Watermark

public struct Watermark: Codable, Equatable, Sendable {
    public enum Position: String, Codable, Sendable, CaseIterable {
        case bottomLeft, bottomRight, topLeft, topRight, centre
    }

    public var text: String
    public var position: Position
    public var opacity: Double     // 0…100
    public var sizePercent: Double // % of the long edge
    public var insetPercent: Double

    public init(text: String = "", position: Position = .bottomRight,
                opacity: Double = 60, sizePercent: Double = 3, insetPercent: Double = 2) {
        self.text = text
        self.position = position
        self.opacity = opacity
        self.sizePercent = sizePercent
        self.insetPercent = insetPercent
    }

    /// Tolerant, per the note at the top of this file. The text is the part with the
    /// photographer's work in it — a studio name typed once and used for years — so an
    /// unreadable `position` costs a corner, not the mark.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Watermark()
        text = c.tolerant(String.self, forKey: .text, default: fallback.text)
        position = c.tolerant(Position.self, forKey: .position, default: fallback.position)
        opacity = c.tolerant(Double.self, forKey: .opacity, default: fallback.opacity)
        sizePercent = c.tolerant(Double.self, forKey: .sizePercent,
                                 default: fallback.sizePercent)
        insetPercent = c.tolerant(Double.self, forKey: .insetPercent,
                                  default: fallback.insetPercent)
    }
}

// MARK: - The recipe

public struct ExportRecipe: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool

    public var format: ExportFormat
    public var quality: Double          // 0…100, JPEG/HEIF only
    /// 8 or 16 for TIFF/PNG; 8 or 10 for HEIC; ignored for JPEG, which is 8-bit by
    /// format. One stored number for every format ON PURPOSE: a new field here would
    /// have to survive the strict `try?` preset decode (docs/31 carried-forward #2),
    /// and an Int a given format cannot write is already handled by
    /// `effectiveBitDepth` folding it to what the encoder will actually do.
    public var bitDepth: Int
    public var colorSpace: ExportColorSpace

    public var resizeMode: ResizeMode
    public var resizeValue: Double
    /// Never upscale past the source's own pixels unless explicitly asked.
    public var allowUpscale: Bool
    public var resolutionPPI: Double

    public var sharpen: OutputSharpen
    public var metadata: MetadataPolicy
    public var watermark: Watermark?

    /// Tokens implemented today, by `AppState.renderFilename`: {name} {date} {recipe}
    /// {ext} — and the sheet's Naming note lists exactly these. This used to claim a
    /// grammar "shared with the ingest renamer" including {seq:N} {time} {camera}
    /// {lens} {iso}; the ingest renamer (`RenameTemplate`) is a separate
    /// implementation with its own token set, and none of those five is read by the
    /// export path. An unknown token stays visible in the delivered name rather than
    /// being silently dropped.
    public var filenameTemplate: String
    public var subfolder: String?

    /// HDR: emit a gain map alongside the SDR base rendition.
    public var hdr: HDRSettings?

    /// `quality` defaults to 100 (docs/32 Stream G): a delivery should not pay
    /// compression's price unasked. The one preset that deliberately trades quality
    /// for web-sized files says so in its own name ("q90").
    public init(id: String = UUID().uuidString, name: String, enabled: Bool = true,
                format: ExportFormat = .jpeg, quality: Double = 100, bitDepth: Int = 8,
                colorSpace: ExportColorSpace = .srgb,
                resizeMode: ResizeMode = .none, resizeValue: Double = 2048,
                allowUpscale: Bool = false, resolutionPPI: Double = 300,
                sharpen: OutputSharpen = OutputSharpen(),
                metadata: MetadataPolicy = MetadataPolicy(),
                watermark: Watermark? = nil,
                filenameTemplate: String = "{name}", subfolder: String? = nil,
                hdr: HDRSettings? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.format = format
        self.quality = quality
        self.bitDepth = bitDepth
        self.colorSpace = colorSpace
        self.resizeMode = resizeMode
        self.resizeValue = resizeValue
        self.allowUpscale = allowUpscale
        self.resolutionPPI = resolutionPPI
        self.sharpen = sharpen
        self.metadata = metadata
        self.watermark = watermark
        self.filenameTemplate = filenameTemplate
        self.subfolder = subfolder
        self.hdr = hdr
    }

    /// A TOLERANT DECODE, because the strict one loses every preset the photographer
    /// ever built (K-016) — and a decode tolerant only of THIS level loses them too,
    /// which is the note at the top of this file.
    ///
    /// `Codable`'s synthesised decoder requires every one of the seventeen stored
    /// properties above. `AppState.loadExportRecipes` reads the list with `try?` and
    /// falls back to `ExportRecipe.defaults` — so a payload missing ONE key does not
    /// produce an error, or a warning, or a partial list. It silently replaces the
    /// photographer's delivery presets with the stock four.
    ///
    /// And the missing key arrives by ordinary means: this build adds a field, the
    /// user's stored payload was written before it existed, and every preset they had
    /// is gone the first time they launch. The `bitDepth` comment three screens up is
    /// the previous author noticing the same trap and routing around it by refusing to
    /// add a field — which is the design being dictated by a decoder.
    ///
    /// Every field is optional with the memberwise initializer's own default behind it,
    /// so an old payload decodes, a new field takes its default, and the preset
    /// survives. `id` and `name` get generated fallbacks rather than a default value:
    /// an entry with no id would collide in `Identifiable` and one with no name would
    /// render as a blank row, and both are recoverable states rather than reasons to
    /// discard the list.
    ///
    /// Every read goes through `tolerant` rather than `decodeIfPresent`, so the same
    /// sentence covers the key that is missing, the key whose type has changed, the
    /// enum case a later build invented and the nested object that objected to
    /// something inside itself. All four used to be one thrown error and no presets.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ExportRecipe(name: "")
        id = c.tolerant(String.self, forKey: .id, default: UUID().uuidString)
        name = c.tolerant(String.self, forKey: .name, default: "Untitled")
        enabled = c.tolerant(Bool.self, forKey: .enabled, default: fallback.enabled)
        format = c.tolerant(ExportFormat.self, forKey: .format, default: fallback.format)
        quality = c.tolerant(Double.self, forKey: .quality, default: fallback.quality)
        bitDepth = c.tolerant(Int.self, forKey: .bitDepth, default: fallback.bitDepth)
        colorSpace = c.tolerant(ExportColorSpace.self, forKey: .colorSpace,
                                default: fallback.colorSpace)
        resizeMode = c.tolerant(ResizeMode.self, forKey: .resizeMode,
                                default: fallback.resizeMode)
        resizeValue = c.tolerant(Double.self, forKey: .resizeValue,
                                 default: fallback.resizeValue)
        allowUpscale = c.tolerant(Bool.self, forKey: .allowUpscale,
                                  default: fallback.allowUpscale)
        resolutionPPI = c.tolerant(Double.self, forKey: .resolutionPPI,
                                   default: fallback.resolutionPPI)
        sharpen = c.tolerant(OutputSharpen.self, forKey: .sharpen, default: fallback.sharpen)
        metadata = c.tolerant(MetadataPolicy.self, forKey: .metadata,
                              default: fallback.metadata)
        watermark = c.tolerant(Watermark.self, forKey: .watermark)
        filenameTemplate = c.tolerant(String.self, forKey: .filenameTemplate,
                                      default: fallback.filenameTemplate)
        subfolder = c.tolerant(String.self, forKey: .subfolder)
        hdr = c.tolerant(HDRSettings.self, forKey: .hdr)
    }

    /// The depth the encoder will actually use.
    ///
    /// The stored `bitDepth` can hold a value the current format cannot write (switch
    /// a 16-bit TIFF recipe to HEIC and 16 is still stored), so anything that has to
    /// reason about the real quantization — the dither's amplitude above all — asks
    /// this rather than the stored number. JPEG is 8 whatever the field says; TIFF and
    /// PNG fold to 16 or 8; HEIC folds any deeper request to 10, the most its HEVC
    /// Main-10 profile carries. Whether this machine's encoder ACCEPTS a 10-bit HEIC
    /// is the pipeline's runtime question (`PipelineRenderer.canWriteTenBitHEIC`) —
    /// this is the depth the recipe is asking for, and a writer that cannot honour it
    /// must refuse loudly rather than quietly deliver 8.
    public var effectiveBitDepth: Int {
        if format.supportsSixteenBit && bitDepth >= 16 { return 16 }
        if format.supportsTenBit && bitDepth >= 10 { return 10 }
        return 8
    }

    /// Target pixel size for a source of the given dimensions, honouring the
    /// no-upscale rule.
    public func targetSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        targetSize(sourceWidth: Double(sourceWidth), sourceHeight: Double(sourceHeight))
    }

    /// The same, from the extent EXACTLY as the renderer holds it — fractional after
    /// any crop or straighten (docs/32 Stream G item 3, handed off by the `.none` fix).
    ///
    /// The export path used to truncate the crop extent to `Int` before asking, which
    /// moved the scale by up to a part in two thousand — enough, near a rounding
    /// boundary, to promise a short edge one pixel off the size the resampler then
    /// actually delivers (2000.5 × 1333.5 at long edge 1600 promises 1066 truncated,
    /// delivers 1067). The target is rounded from the un-truncated extent, so the
    /// promise and the delivery are the same arithmetic.
    public func targetSize(sourceWidth: Double,
                           sourceHeight: Double) -> (width: Int, height: Int) {
        let w = sourceWidth, h = sourceHeight
        guard w.isFinite, h.isFinite, w > 0, h > 0 else {
            // The degenerate answer the Int overload always gave: the source echoed
            // back, with a non-finite axis folded to zero rather than trapped on.
            return (Swift.max(Int(w.isFinite ? w.rounded() : 0), 0),
                    Swift.max(Int(h.isFinite ? h.rounded() : 0), 0))
        }
        var scale = 1.0
        switch resizeMode {
        case .none:
            return (Swift.max(Int(w.rounded()), 1), Swift.max(Int(h.rounded()), 1))
        case .longEdge:
            scale = resizeValue / Swift.max(w, h)
        case .shortEdge:
            scale = resizeValue / Swift.min(w, h)
        case .width:
            scale = resizeValue / w
        case .height:
            scale = resizeValue / h
        case .megapixels:
            let targetPixels = Swift.max(resizeValue, 0.01) * 1_000_000
            scale = (targetPixels / (w * h)).squareRoot()
        }
        if !allowUpscale { scale = Swift.min(scale, 1.0) }
        guard scale.isFinite, scale > 0 else {
            return (Swift.max(Int(w.rounded()), 1), Swift.max(Int(h.rounded()), 1))
        }
        return (Swift.max(Int((w * scale).rounded()), 1),
                Swift.max(Int((h * scale).rounded()), 1))
    }

    // MARK: Stock recipes

    /// The one preset that keeps quality below 100, deliberately, and the name says
    /// so: at 2048 px for screens, q90 reads identically and roughly halves the file
    /// — the point of a web preset. Every other recipe defaults to 100 (docs/32
    /// Stream G): a delivery should not lose to compression unasked.
    public static var webJPEG: ExportRecipe {
        ExportRecipe(name: "Web sRGB 2048 q90", format: .jpeg, quality: 90,
                     colorSpace: .srgb, resizeMode: .longEdge, resizeValue: 2048,
                     sharpen: OutputSharpen(medium: .screen, amount: .standard),
                     filenameTemplate: "{name}")
    }

    public static var printTIFF: ExportRecipe {
        ExportRecipe(name: "Print Adobe RGB full", enabled: false, format: .tiff,
                     bitDepth: 16, colorSpace: .adobeRGB, resizeMode: .none,
                     sharpen: OutputSharpen(medium: .glossy, amount: .standard),
                     filenameTemplate: "{name}-print", subfolder: "print")
    }

    public static var hdrHEIC: ExportRecipe {
        ExportRecipe(name: "HDR HEIC", enabled: false, format: .heif, quality: 100,
                     colorSpace: .displayP3, resizeMode: .none,
                     filenameTemplate: "{name}-hdr", subfolder: "hdr",
                     hdr: HDRSettings())
    }

    public static var archiveOriginalSize: ExportRecipe {
        ExportRecipe(name: "Full-size JPEG", enabled: false, format: .jpeg,
                     quality: 100, colorSpace: .displayP3, resizeMode: .none)
    }

    public static var defaults: [ExportRecipe] {
        [webJPEG, printTIFF, hdrHEIC, archiveOriginalSize]
    }

    /// The path components `subfolder` actually contributes, sanitized.
    ///
    /// Here rather than in the app layer, and shared, for two reasons. It is a security
    /// boundary — `appendingPathComponent` appends a multi-component string verbatim
    /// and the exporter then creates intermediate directories, so a subfolder of
    /// `../../..` writes outside the folder the open panel granted, which is the one
    /// thing that panel exists to decide. And the export sheet's filename PREVIEW was
    /// building its own path by string concatenation with no sanitizing at all, so for
    /// exactly the inputs that matter it showed the user a path the exporter would not
    /// use. One function, both callers, one answer.
    ///
    /// `LumenApp` has no test target; `LumenCore` does.
    public static func sanitizedSubfolderComponents(_ subfolder: String?) -> [String] {
        guard let subfolder, !subfolder.isEmpty else { return [] }
        var out: [String] = []
        // Backslash separates too: a subfolder pasted from a Windows path would
        // otherwise become one component containing separators.
        for component in subfolder.split(whereSeparator: { $0 == "/" || $0 == "\\" }) {
            let cleaned = component
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            // "." and ".." are the two that mean "somewhere else"; a leading separator
            // is already gone because `split` drops the empty component it produces,
            // which is what keeps an absolute path from staying absolute.
            guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { continue }
            out.append(cleaned)
        }
        return out
    }

    /// The same components as a display string — what a preview must show, so that the
    /// preview and the written path cannot disagree.
    public static func sanitizedSubfolderPath(_ subfolder: String?) -> String {
        sanitizedSubfolderComponents(subfolder).joined(separator: "/")
    }

    /// A destination that is not already spoken for, suffixing `-1`, `-2`, … until one
    /// is free. `isTaken` covers both "a file is already there" and "an earlier job in
    /// this same run claimed it" — the caller has to answer for both, and the injection
    /// is what lets this be tested without a filesystem.
    ///
    /// Export had no guard of either kind. The encoders truncate, so re-exporting into
    /// a folder that already held a delivery replaced it with no prompt; and because
    /// the folder scan is recursive while the filename template is built from the
    /// basename, `day1/DSC_0001.NEF` and `day2/DSC_0001.NEF` resolved to one output
    /// path. The sheet counted photos × recipes and the status line reported that many
    /// files exported, so the user was told forty files were written when thirty-eight
    /// were, and no error was raised.
    ///
    /// Suffixing rather than prompting: it is what the platform does, it needs no
    /// decision from someone who is mid-delivery, and it cannot destroy anything.
    public static func disambiguated(_ url: URL, isTaken: (URL) -> Bool) -> URL {
        guard isTaken(url) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        func candidate(_ suffix: String) -> URL {
            let named = folder.appendingPathComponent(stem + suffix)
            return ext.isEmpty ? named : named.appendingPathExtension(ext)
        }

        var n = 1
        while n <= 9_999 {
            let next = candidate("-\(n)")
            if !isTaken(next) { return next }
            n += 1
        }
        // Ten thousand collisions on one name is not a case worth a nicer answer, but
        // it is still not a reason to overwrite somebody's file. A name nothing else
        // will pick beats returning the one we know is taken.
        return candidate("-" + UUID().uuidString)
    }
}

// MARK: - HDR

/// Gain-map authoring (D42). The pipeline renders twice at two display peaks off one
/// shared checkpoint; the map is the per-pixel log ratio between the renditions.
public struct HDRSettings: Codable, Equatable, Sendable {
    /// Headroom above SDR white, in stops. +2 EV (4×) is the photographic default.
    public var headroomEV: Double
    /// The gain map is stored at a fraction of full resolution — it is a smooth
    /// ratio field, and quarter-res is visually lossless while costing 1/16 the bytes.
    public var mapScale: Double
    /// Write the SDR base rendition deliberately rather than deriving it.
    public var deliberateSDRBase: Bool

    public init(headroomEV: Double = 2.0, mapScale: Double = 0.25,
                deliberateSDRBase: Bool = true) {
        self.headroomEV = headroomEV
        self.mapScale = mapScale
        self.deliberateSDRBase = deliberateSDRBase
    }

    /// Tolerant, per the note at the top of this file. This is the nested type most
    /// likely to grow — the gain map it describes is half-written (`hdrIsWritable`) and
    /// the ISO 21496-1 fields it still needs are not invented yet — so it is the one
    /// whose next field would otherwise be the one that empties the preset list.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = HDRSettings()
        headroomEV = c.tolerant(Double.self, forKey: .headroomEV, default: fallback.headroomEV)
        mapScale = c.tolerant(Double.self, forKey: .mapScale, default: fallback.mapScale)
        deliberateSDRBase = c.tolerant(Bool.self, forKey: .deliberateSDRBase,
                                       default: fallback.deliberateSDRBase)
    }

    public var whiteTargetPercent: Double { 100 * pow(2, Num.clamp(headroomEV, 0, 4)) }
}

extension ExportRecipe {

    /// Whether the encoder can actually store the extra range HDR asks for.
    ///
    /// False everywhere today, and stated here rather than assumed, because assuming it
    /// made the HDR toggle produce a file strictly WORSE than leaving it off.
    /// `renderHDRPair` and the whole `GainMap` relation are implemented and tested, but
    /// nothing calls them: `export` renders once and `write` emits a single rendition
    /// through `writeJPEG`/`HEIFRepresentation` with only a quality option. No second
    /// image plane is ever attached.
    ///
    /// What `hdr` DID reach was the render plan's `displayWhiteTarget`. At the default
    /// +2 EV that is 400%, which puts the display transform's white at 4.0 and scales
    /// the finish LUT to match — and then the result was encoded to 8 bits, so every
    /// value above diffuse white clipped to 255. Ticking the box threw away all the
    /// highlight roll-off the transform had just placed between 1.0 and 4.0.
    ///
    /// Writing it for real needs an auxiliary gain-map image attached through
    /// `CGImageDestination` (ISO 21496-1), which is the piece that does not exist.
    /// Until it does, HDR must not change the render, and the sheet must not claim a
    /// map was stored.
    public var hdrIsWritable: Bool { false }

    /// The display white target the render should actually use — the HDR ceiling only
    /// when there is somewhere to put it, and SDR otherwise.
    public var renderWhiteTargetPercent: Double? {
        guard let hdr, hdrIsWritable else { return nil }
        return hdr.whiteTargetPercent
    }
}

/// The ISO 21496-1 gain-map relation, as pure maths so the encoder side stays thin.
public enum GainMap {

    /// Per-channel gain, in log2, between the HDR and SDR renditions.
    /// The tiny offsets keep the ratio finite where either rendition is black.
    public static func logGain(hdr: RGB, sdr: RGB, offsetSDR: Double = 1.0 / 64.0,
                               offsetHDR: Double = 1.0 / 64.0) -> RGB {
        func g(_ h: Double, _ s: Double) -> Double {
            let num = Swift.max(h, 0) + offsetHDR
            let den = Swift.max(s, 0) + offsetSDR
            return log2(num / den)
        }
        return RGB(g(hdr.r, sdr.r), g(hdr.g, sdr.g), g(hdr.b, sdr.b))
    }

    /// Encode a log gain into the map's 0…1 storage range.
    public static func encode(_ logGain: Double, min: Double, max: Double) -> Double {
        guard max > min else { return 0 }
        return Num.saturate((logGain - min) / (max - min))
    }

    /// Reconstruct the HDR rendition a viewer would compute from the base image and
    /// the map at a given display headroom — what the SDR-proof toggle previews.
    public static func reconstruct(sdr: RGB, encodedMap: RGB, min: Double, max: Double,
                                   displayHeadroomEV: Double, contentHeadroomEV: Double,
                                   offsetSDR: Double = 1.0 / 64.0,
                                   offsetHDR: Double = 1.0 / 64.0) -> RGB {
        let weight = contentHeadroomEV > 0
            ? Num.saturate(displayHeadroomEV / contentHeadroomEV) : 0
        func c(_ s: Double, _ m: Double) -> Double {
            let logGain = Num.mix(min, max, Num.saturate(m)) * weight
            return (Swift.max(s, 0) + offsetSDR) * pow(2, logGain) - offsetHDR
        }
        return RGB(c(sdr.r, encodedMap.r), c(sdr.g, encodedMap.g), c(sdr.b, encodedMap.b))
    }
}

// MARK: - Soft proofing

/// Soft proof + gamut warning (docs/11). Rendering intent is deliberately limited to
/// the two that mean something for photographs.
public enum RenderingIntent: String, Codable, Sendable, CaseIterable {
    case perceptual, relativeColorimetric

    public var displayName: String {
        self == .perceptual ? "Perceptual" : "Relative colorimetric"
    }
}

public struct SoftProof: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var space: ExportColorSpace
    public var intent: RenderingIntent
    public var showGamutWarning: Bool
    public var simulatePaperWhite: Bool

    public init(enabled: Bool = false, space: ExportColorSpace = .srgb,
                intent: RenderingIntent = .relativeColorimetric,
                showGamutWarning: Bool = true, simulatePaperWhite: Bool = false) {
        self.enabled = enabled
        self.space = space
        self.intent = intent
        self.showGamutWarning = showGamutWarning
        self.simulatePaperWhite = simulatePaperWhite
    }

    /// Colour used to flag out-of-gamut pixels. Mid grey reads as "flat" against any
    /// photograph without being mistaken for content.
    public static let warningColor = RGB(0.5, 0.5, 0.5)

    /// True when the colour falls outside the proof space.
    public static func isOutOfGamut(_ c: RGB, working: RGBColorSpace, proof: RGBColorSpace,
                                    epsilon: Double = 1e-4) -> Bool {
        let converted = working.matrix(to: proof).apply(c)
        return converted.minComponent < -epsilon || converted.maxComponent > 1 + epsilon
    }
}

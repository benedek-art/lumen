// ExportRecipe.swift
// The multi-recipe export model (D40, docs/11): a set of named recipes, any number of
// which can be checked at once, so one Export click emits the web JPEG, the print TIFF
// and the HDR HEIC together. The render forks at the resize node — everything upstream
// is computed once and shared, which is why three recipes cost far less than three
// exports.

import Foundation

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

    /// Sharpening energy. Asymmetric dark:light weighting (dark halos read as
    /// "crisp", light halos read as "oversharpened") is applied by the renderer;
    /// this is the master amount.
    public func energy() -> Double {
        switch medium {
        case .none: return 0
        case .screen: return 0.55 * amount.scale
        case .matte: return 0.95 * amount.scale
        case .glossy: return 0.70 * amount.scale
        }
    }

    /// Light halos get less energy than dark ones, at this ratio.
    public static let lightHaloRatio: Double = 0.6

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
}

// MARK: - The recipe

public struct ExportRecipe: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool

    public var format: ExportFormat
    public var quality: Double          // 0…100, JPEG/HEIF only
    public var bitDepth: Int            // 8 or 16, TIFF/PNG only
    public var colorSpace: ExportColorSpace

    public var resizeMode: ResizeMode
    public var resizeValue: Double
    /// Never upscale past the source's own pixels unless explicitly asked.
    public var allowUpscale: Bool
    public var resolutionPPI: Double

    public var sharpen: OutputSharpen
    public var metadata: MetadataPolicy
    public var watermark: Watermark?

    /// Token grammar shared with the ingest renamer: {name} {seq:N} {date} {time}
    /// {camera} {lens} {iso} {recipe} {ext}.
    public var filenameTemplate: String
    public var subfolder: String?

    /// HDR: emit a gain map alongside the SDR base rendition.
    public var hdr: HDRSettings?

    public init(id: String = UUID().uuidString, name: String, enabled: Bool = true,
                format: ExportFormat = .jpeg, quality: Double = 90, bitDepth: Int = 8,
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

    /// Target pixel size for a source of the given dimensions, honouring the
    /// no-upscale rule.
    public func targetSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let w = Double(sourceWidth), h = Double(sourceHeight)
        guard w > 0, h > 0 else { return (sourceWidth, sourceHeight) }
        var scale = 1.0
        switch resizeMode {
        case .none:
            return (sourceWidth, sourceHeight)
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
        guard scale.isFinite, scale > 0 else { return (sourceWidth, sourceHeight) }
        return (Swift.max(Int((w * scale).rounded()), 1),
                Swift.max(Int((h * scale).rounded()), 1))
    }

    // MARK: Stock recipes

    public static var webJPEG: ExportRecipe {
        ExportRecipe(name: "Web sRGB 2048", format: .jpeg, quality: 90,
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
        ExportRecipe(name: "HDR HEIC", enabled: false, format: .heif, quality: 85,
                     colorSpace: .displayP3, resizeMode: .none,
                     filenameTemplate: "{name}-hdr", subfolder: "hdr",
                     hdr: HDRSettings())
    }

    public static var archiveOriginalSize: ExportRecipe {
        ExportRecipe(name: "Full-size JPEG", enabled: false, format: .jpeg, quality: 95,
                     colorSpace: .displayP3, resizeMode: .none)
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

    public var whiteTargetPercent: Double { 100 * pow(2, Num.clamp(headroomEV, 0, 4)) }
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

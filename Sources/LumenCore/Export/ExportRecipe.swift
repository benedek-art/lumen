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

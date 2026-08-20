// AppleRawSource.swift
// The RAW stage (docs/14 S1, D50): CIRAWFilter behind the RawSource idea, run FLAT.
//
// "Flat" is the contract that matters. Apple's display-referred machinery — its tone
// curve, shadow boost, local tone mapping, gamut mapping — is switched off, because
// D8 admits exactly one display transform and it is ours. What we take from Apple is
// the genuinely hard 40%: format decode, demosaic including X-Trans, per-camera colour
// matrices, embedded lens corrections and highlight recovery. What we do downstream is
// entirely Lumen's.
//
// White balance and exposure are deliberately NOT applied here (docs/14 §2.1.4). The
// decode always runs at camera-reference WB, which is what keeps dragging the
// temperature slider from invalidating the decode, the AI-denoise artifact and the
// retouch cache — the three most expensive things in the app.

#if os(macOS)

import CoreGraphics
import CoreImage
import Foundation
import LumenCore

public enum RawSourceError: Error {
    case unreadable(URL)
    case undecodable(URL)
}

public final class AppleRawSource: ImageSource {

    private let filter: CIRAWFilter
    public let url: URL

    /// The decoder version actually pinned — persist into recipe.develop.raw.decoderVersion.
    public let pinnedDecoderVersion: Int?

    /// The as-shot neutral, which is what Lumen's own CAT16 white balance adapts FROM.
    public let asShotTemperature: Double
    public let asShotTint: Double

    private let defaultLuminanceNR: Float
    private let defaultColorNR: Float
    private let defaultSharpness: Float

    /// The ISO this frame was shot at, read once from the file's EXIF block.
    ///
    /// `CIRAWFilter` does not surface it, and it is not worth a second demosaic to find
    /// out, so this goes through the same metadata reader the catalog backfill uses:
    /// one `CGImageSourceCopyPropertiesAtIndex` per opened photo, no pixels decoded.
    public let captureISO: Double?

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RawSourceError.unreadable(url)
        }
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RawSourceError.undecodable(url)
        }
        self.url = url
        self.filter = filter

        // Pin the decoder version (D50): an implicit "latest" could shift under a
        // macOS update and silently change three years of renders. If pinning breaks
        // this particular file, a working implicit decoder beats a dead pinned one.
        let originalVersion = filter.decoderVersion
        if let newest = filter.supportedDecoderVersions.last {
            filter.decoderVersion = newest
            if filter.outputImage == nil {
                filter.decoderVersion = originalVersion
            }
        }
        self.pinnedDecoderVersion = Int(filter.decoderVersion.rawValue.filter(\.isNumber))

        self.asShotTemperature = Double(filter.neutralTemperature)
        self.asShotTint = Double(filter.neutralTint)
        self.defaultLuminanceNR = filter.luminanceNoiseReductionAmount
        self.defaultColorNR = filter.colorNoiseReductionAmount
        self.defaultSharpness = filter.sharpnessAmount
        self.captureISO = CaptureMetadataReader.read(url: url)?.iso.map { Double($0) }
    }

    public var nativeLongEdge: Double {
        let size = filter.nativeSize
        return Double(max(size.width, size.height))
    }

    public var nativePixelSize: (width: Int, height: Int) {
        let size = filter.nativeSize
        return (Int(size.width), Int(size.height))
    }

    /// Decode at camera-reference white balance, with Apple's picture-forming stages
    /// off. `draft` uses the fast path for interactive frames.
    /// What the decode actually depends on. Everything else in a recipe happens
    /// downstream of it.
    ///
    /// This is D48/D49's prefix reuse applied at the most expensive prefix there is.
    /// Dragging Exposure changes none of these, and without this the demosaic ran again
    /// for every frame of the drag — on a 45MP RAW that is the whole cost of the
    /// interaction, repeated, to produce an identical image each time.
    private struct DecodeKey: Equatable {
        let draft: Bool
        let scaleFactor: Double
        let captureStrength: Double
        let luminanceNR: Double
        let colorNR: Double
        let lensProfile: Bool
    }

    private var cachedKey: DecodeKey?
    private var cachedImage: CIImage?

    public func decode(recipe: Recipe, draft: Bool, scaleFactor: Double = 1.0) -> CIImage? {
        let dev = recipe.develop

        let standIn = dev.denoise.appleStandIn
        let key = DecodeKey(draft: draft,
                            scaleFactor: Num.clamp(scaleFactor, 0.01, 1.0),
                            captureStrength: dev.detail.capture.strengthFraction,
                            luminanceNR: standIn.luma,
                            colorNR: standIn.chroma,
                            lensProfile: dev.geometry.lens.profile)
        // Core Image is lazy, so the cached value is a recipe rather than pixels — but
        // it is a recipe bound to the filter's CURRENT settings, which is exactly why
        // it can only be reused when nothing the filter reads has changed. The source
        // lives inside an actor, so there is no window where another caller mutates the
        // filter between the check and the use.
        if let cachedKey, cachedKey == key, let cachedImage {
            return cachedImage
        }

        filter.isDraftModeEnabled = draft
        filter.scaleFactor = Float(Num.clamp(scaleFactor, 0.01, 1.0))

        // Camera reference, always. Lumen's WB is a CAT16 adaptation at S6.
        filter.neutralTemperature = Float(asShotTemperature)
        filter.neutralTint = Float(asShotTint)

        // Everything display-referred: off. This is the whole point of the contract.
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        filter.localToneMapAmount = 0
        filter.isGamutMappingEnabled = false
        filter.contrastAmount = 0
        filter.exposure = 0

        // Keep whatever headroom the file carries; scene-referred unboundedness
        // preserves it all the way to the display transform.
        filter.extendedDynamicRangeAmount = 1.0

        // Capture sharpening rides Apple's at-demosaic sharpener until Lumen's own RL
        // deconvolution moves into the graph.
        //
        // `auto` is the ON switch, not a choice between two strengths. The panel says
        // so — with it off it prints "Capture sharpening is off for this photo", and
        // with it on it offers an Overrides disclosure — and the two branches here were
        // the other way round.
        //
        // What that cost: `amount` defaults to nil, so the "manual" branch computed
        // `clamp(100/100) = 1.0` and multiplied the default strength by exactly one.
        // Turning capture sharpening OFF rendered pixel-for-pixel the same picture as
        // leaving it on, while the panel said it was off. And the Amount slider lives
        // inside `captureOverrides`, which the panel shows only when `auto` is TRUE —
        // the branch that never read it. The one control was invisible in the state
        // that used it and useless in the state that showed it.
        // The mapping itself lives on `CaptureSharpen` so it can be tested; this stage
        // needs a camera RAW to reach at all.
        filter.sharpnessAmount = defaultSharpness
            * Float(dev.detail.capture.strengthFraction)

        // Noise reduction: Tier 1 runs in the graph now (S3,
        // `RenderGraph.applyDenoise`), so Off and Classic both hand this stage zero —
        // leaving Apple's denoise on underneath a profiled wavelet shrinkage would
        // smooth the frame twice, once with a model of this sensor and once with
        // somebody else's guess. Only `.ai` still reaches it, because Tier 2 is a
        // cached artifact that does not exist yet and its Amount would drive nothing.
        //
        // The mapping lives on `Denoise` so it can be tested — this stage needs a
        // camera RAW to reach at all, and the wiring here was wrong in a way the panel
        // hid: `.ai` read the two Classic sliders, which the AI panel does not show,
        // and ignored `amount`, which is the only one it does. Switching Classic → AI
        // changed nothing and the AI Amount slider changed nothing.
        let denoise = dev.denoise.appleStandIn
        filter.luminanceNoiseReductionAmount = Float(denoise.luma)
        filter.colorNoiseReductionAmount = Float(denoise.chroma)

        filter.isLensCorrectionEnabled = dev.geometry.lens.profile

        let image = filter.outputImage
        cachedKey = image == nil ? nil : key
        cachedImage = image
        return image
    }

    /// Metadata the develop panel and the catalog both want.
    public var captureMetadata: CaptureMetadata {
        CaptureMetadata(asShotTemperature: asShotTemperature,
                        asShotTint: asShotTint,
                        decoderVersion: pinnedDecoderVersion,
                        pixelSize: nativePixelSize,
                        iso: captureISO)
    }
}

public struct CaptureMetadata: Sendable {
    public let asShotTemperature: Double
    public let asShotTint: Double
    public let decoderVersion: Int?
    public let pixelSize: (width: Int, height: Int)
    /// What the file says it was shot at. It is what selects the noise profile the
    /// denoise stage's every threshold is denominated in, so a source that cannot
    /// answer says nil rather than guessing — `RenderPlan` then falls back to the
    /// gentlest profile on the seed curve.
    public let iso: Double?

    public init(asShotTemperature: Double, asShotTint: Double, decoderVersion: Int?,
                pixelSize: (width: Int, height: Int), iso: Double? = nil) {
        self.asShotTemperature = asShotTemperature
        self.asShotTint = asShotTint
        self.decoderVersion = decoderVersion
        self.pixelSize = pixelSize
        self.iso = iso
    }
}

#endif

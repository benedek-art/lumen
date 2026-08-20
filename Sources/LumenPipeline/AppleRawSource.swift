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

public final class AppleRawSource {

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
    public func decode(recipe: Recipe, draft: Bool, scaleFactor: Double = 1.0) -> CIImage? {
        let dev = recipe.develop

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

        // Noise reduction: Lumen's Tier 1 is the reference implementation and neither
        // tier runs in the GPU graph yet, so Apple's stage stands in. Tracked in
        // BUILDING.md; `.off` really is off.
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

        return filter.outputImage
    }

    /// Metadata the develop panel and the catalog both want.
    public var captureMetadata: CaptureMetadata {
        CaptureMetadata(asShotTemperature: asShotTemperature,
                        asShotTint: asShotTint,
                        decoderVersion: pinnedDecoderVersion,
                        pixelSize: nativePixelSize)
    }
}

public struct CaptureMetadata: Sendable {
    public let asShotTemperature: Double
    public let asShotTint: Double
    public let decoderVersion: Int?
    public let pixelSize: (width: Int, height: Int)

    public init(asShotTemperature: Double, asShotTint: Double, decoderVersion: Int?,
                pixelSize: (width: Int, height: Int)) {
        self.asShotTemperature = asShotTemperature
        self.asShotTint = asShotTint
        self.decoderVersion = decoderVersion
        self.pixelSize = pixelSize
    }
}

#endif

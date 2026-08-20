// AppleRawSource.swift
// The Apple RAW stage (docs/14 S1–S5, D50): CIRAWFilter wrapped behind the RawSource
// idea. Phase 1 maps the walking-skeleton sliders onto Apple's own scene-referred
// controls; Lumen's own stages replace everything downstream of decode in Phase 3.
//
// D50 contract honored here:
//  - decoderVersion pinned on first open and recorded into the recipe
//  - isDraftModeEnabled + scaleFactor for preview-speed decodes
//  - degrade gracefully: a file CIRAWFilter refuses must surface as a typed error the
//    UI turns into "showing embedded preview" — never a crash (docs/13 safety posture).
//
// NOTE (Phase 1 honesty): the highlights/shadows mapping below rides Apple's
// boostShadowAmount / localToneMapAmount as approximations. They are placeholders for
// Lumen's own EV-zone engine (docs/04) and are marked for replacement in Phase 3.

#if os(macOS)

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
    /// nil when Apple's rawValue for this file's decoder isn't a plain integer
    /// (some DNG-variant decoders) — the pin still holds on the filter itself.
    public let pinnedDecoderVersion: Int?

    /// As-shot values captured at init so decode() can restore them: the filter
    /// instance is cached and reused, so every property must be written on every
    /// decode or previous recipes' values stick (review finding: sticky state).
    private let asShotTemperature: Float
    private let asShotTint: Float
    private let defaultLuminanceNR: Float
    private let defaultColorNR: Float

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RawSourceError.unreadable(url)
        }
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RawSourceError.undecodable(url)
        }
        self.url = url
        self.filter = filter

        // Pin the decoder version explicitly (D50): implicit "latest" could shift
        // under a macOS update and silently change renders. Defensive: if assigning
        // a version kills the decode (outputImage goes nil), revert — a working
        // implicit decoder beats a dead pinned one.
        let originalVersion = filter.decoderVersion
        if let newest = filter.supportedDecoderVersions.last {
            filter.decoderVersion = newest
            if filter.outputImage == nil {
                print("Lumen: decoder pin \(newest.rawValue) broke decode for "
                      + "\(url.lastPathComponent); reverting to \(originalVersion.rawValue)")
                filter.decoderVersion = originalVersion
            }
        }
        self.pinnedDecoderVersion = Int(filter.decoderVersion.rawValue.filter(\.isNumber))

        self.asShotTemperature = filter.neutralTemperature
        self.asShotTint = filter.neutralTint
        self.defaultLuminanceNR = filter.luminanceNoiseReductionAmount
        self.defaultColorNR = filter.colorNoiseReductionAmount
    }

    /// Native long edge in pixels — lets callers decode at view resolution
    /// (scaleFactor) instead of paying for the full sensor on every render.
    public var nativeLongEdge: Double {
        let size = filter.nativeSize
        return Double(max(size.width, size.height))
    }

    /// Configure Apple's stage from the recipe and return the decoded image.
    /// Every recipe-driven property is written unconditionally (recipe value or
    /// captured as-shot default) so a cached filter never carries stale state.
    /// `draft: true` uses the fast decode path for interactive preview rendering.
    public func decode(recipe: Recipe, draft: Bool, scaleFactor: Double = 1.0) -> CIImage? {
        let dev = recipe.develop

        filter.isDraftModeEnabled = draft
        filter.scaleFactor = Float(scaleFactor)

        // White balance: recipe Kelvin/tint, or the captured as-shot neutral.
        filter.neutralTemperature = dev.raw.temp.map(Float.init) ?? asShotTemperature
        filter.neutralTint = dev.raw.tint.map(Float.init) ?? asShotTint

        // Exposure in EV maps directly.
        filter.exposure = Float(dev.tone.exposure)

        // Phase 1 approximations (replaced by Lumen's zone engine in Phase 3):
        // shadows lift rides Apple's shadow boost; highlight recovery rides the
        // local tone map amount. Both clamp to Apple's 0…1 ranges.
        filter.boostShadowAmount =
            dev.tone.shadows > 0 ? Float(min(dev.tone.shadows / 100.0, 1.0)) : 0
        filter.localToneMapAmount =
            dev.tone.highlights < 0 ? Float(min(-dev.tone.highlights / 100.0, 1.0)) : 0

        // NR: mode .off zeroes Apple's noise reduction; otherwise camera defaults.
        if dev.denoise.mode == .off {
            filter.luminanceNoiseReductionAmount = 0
            filter.colorNoiseReductionAmount = 0
        } else {
            filter.luminanceNoiseReductionAmount = defaultLuminanceNR
            filter.colorNoiseReductionAmount = defaultColorNR
        }

        filter.isLensCorrectionEnabled = dev.geometry.lens.profile

        return filter.outputImage
    }
}

#endif

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
    /// The decoder version actually in use — persist into recipe.develop.raw.decoderVersion.
    public let decoderVersionRawValue: Int

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RawSourceError.unreadable(url)
        }
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RawSourceError.undecodable(url)
        }
        self.url = url
        self.filter = filter

        // Pin the newest supported decoder version explicitly (D50): implicit "latest"
        // could shift under a macOS update and silently change renders.
        if let newest = filter.supportedDecoderVersions.map(\.rawValue).sorted().last,
           let version = Int(newest) {
            self.decoderVersionRawValue = version
        } else {
            self.decoderVersionRawValue = 0
        }
    }

    /// Configure Apple's stage from the recipe and return the decoded image.
    /// `draft: true` uses the fast decode path for interactive preview rendering.
    public func decode(recipe: Recipe, draft: Bool, scaleFactor: Double = 1.0) -> CIImage? {
        let dev = recipe.develop

        filter.isDraftModeEnabled = draft
        filter.scaleFactor = Float(scaleFactor)

        // White balance: as-shot unless the recipe sets Kelvin/tint.
        if let temp = dev.raw.temp {
            filter.neutralTemperature = Float(temp)
        }
        if let tint = dev.raw.tint {
            filter.neutralTint = Float(tint)
        }

        // Exposure in EV maps directly.
        filter.exposure = Float(dev.tone.exposure)

        // Phase 1 approximations (replaced by Lumen's zone engine in Phase 3):
        // shadows lift rides Apple's shadow boost; highlight recovery rides the
        // local tone map amount. Both clamp to Apple's 0…1 ranges.
        if dev.tone.shadows > 0 {
            filter.boostShadowAmount = Float(min(dev.tone.shadows / 100.0, 1.0))
        } else {
            filter.boostShadowAmount = 0
        }
        if dev.tone.highlights < 0 {
            filter.localToneMapAmount = Float(min(-dev.tone.highlights / 100.0, 1.0))
        } else {
            filter.localToneMapAmount = 0
        }

        // NR: mode .off zeroes Apple's noise reduction; otherwise leave camera defaults.
        if dev.denoise.mode == .off {
            filter.luminanceNoiseReductionAmount = 0
            filter.colorNoiseReductionAmount = 0
        }

        filter.isLensCorrectionEnabled = dev.geometry.lens.profile

        return filter.outputImage
    }
}

#endif

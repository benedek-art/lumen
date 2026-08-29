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
import CoreVideo
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
    /// The same pin as the typed value the filter takes, kept so `decode` can restore
    /// it after honouring (or failing to honour) a recipe's own recorded version.
    private let pinnedVersion: CIRAWDecoderVersion

    /// The as-shot neutral, which is what Lumen's own CAT16 white balance adapts FROM.
    public let asShotTemperature: Double
    public let asShotTint: Double

    private let defaultLuminanceNR: Float
    private let defaultColorNR: Float
    private let defaultSharpness: Float

    /// This decoder runs Apple's picture-forming stages OFF (see `decode`), so what
    /// comes out is scene-referred and carries the headroom above display white. It is
    /// still post-demosaic — Apple's API does not expose the mosaic — which is exactly
    /// the distinction `RawStatistics.Provenance` exists to keep.
    public let statisticsProvenance: RawStatistics.Provenance =
        RawTruth.provenance(isRenderedFile: false)

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
        self.pinnedVersion = filter.decoderVersion

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
        /// The decoder version this decode resolved to — two decoders are two
        /// different demosaics, and a cache that cannot tell them apart would hand a
        /// v11 recipe v12 pixels the moment both were asked for in one session.
        let decoderVersion: String
    }

    /// A handful of entries, not one. The viewer settles at one scale, the draft at
    /// another, the scope probe decodes at 512, the mask raster at ≤1024, and
    /// clipping statistics and auto-tone at their own sizes — six consumers whose
    /// keys legitimately differ, all against a single-entry cache, so every one of
    /// them EVICTED the viewer's demosaic and the viewer paid it again on the next
    /// frame. On a 45 MP RAW the demosaic is the whole cost of the interaction. Eight
    /// entries covers the working set; the values are lazy CIImage recipes, so the
    /// held cost is filter descriptions, not pixels.
    private static let decodeCacheCapacity = 8
    /// `bytes` is what the entry actually allocated — zero for one still held lazily.
    private var decodeCache: [(key: DecodeKey, image: CIImage, bytes: Int)] = []

    // MARK: Materializing the decode

    /// THE MEASUREMENT THAT FORCED THIS, from the owner's own machine:
    ///
    ///     in/out      106/s    4fps
    ///     draft     457.5 ms @2048
    ///     settle     14.5 ms @2560
    ///
    /// A draft frame at 2048 px cost 457 ms — thirteen times the drag budget, and
    /// thirty times what a settle at a LARGER size cost. No graph over 2.8 megapixels
    /// does that. A 33 MP demosaic does.
    ///
    /// The cache above is why. `filter.outputImage` is a lazy `CIImage`: a description
    /// of a decode, not its pixels. Storing it caches the INTENTION to decode, so every
    /// frame that consumed a "hit" re-ran the full RAW demosaic on the GPU. The context
    /// runs with `cacheIntermediates: true`, which is what was supposed to save this —
    /// but the intermediate here is a 33 MP RGBAh buffer, roughly 260 MB, far past what
    /// that cache will hold, so it was evicted and recomputed every single frame.
    /// `DragProbeTests` names this trap in its own header and measured it as worth
    /// ~10%; it measured a SYNTHETIC source, where there is no demosaic to repeat.
    ///
    /// So the decode is rendered into real pixels once per key and the cache holds
    /// those. Half-float RGBA in the working space, because the whole contract of this
    /// file is that what leaves it is scene-referred and keeps the headroom above
    /// display white — an 8-bit or clamped materialization would throw away the
    /// highlights the entire pipeline exists to protect.
    private static let materializeContext: CIContext = {
        var options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAh,
            // Nothing is reused across these renders — each one materializes a
            // different key exactly once — so an intermediate cache would only hold
            // megabytes nobody reads.
            .cacheIntermediates: false,
        ]
        if let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) {
            options[.workingColorSpace] = working
            options[.outputColorSpace] = working
        }
        return CIContext(options: options)
    }()

    /// Above this, leave the decode lazy.
    ///
    /// An export decodes at full resolution, uses the result once, and would gain
    /// nothing from being held; at 60 MP the buffer would be half a gigabyte. Every
    /// INTERACTIVE size is below this — the viewer's settle, every rung of
    /// `DraftLadder`, the mask raster, the 512 px probes — which is the whole working
    /// set that repeats.
    private static let materializeLongEdgeLimit = 3072

    /// The decode's pixels and what they weigh, or nil if it should stay lazy.
    private func materialized(_ image: CIImage) -> (image: CIImage, bytes: Int)? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1,
              Swift.max(extent.width, extent.height)
                  <= CGFloat(Self.materializeLongEdgeLimit)
        else { return nil }

        let width = Int(extent.width.rounded())
        let height = Int(extent.height.rounded())
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            // An IOSurface-backed buffer stays on the GPU, so the graph that reads it
            // back does not pay a CPU round trip for the privilege of not re-decoding.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_64RGBAHalf,
                                  attributes as CFDictionary,
                                  &created) == kCVReturnSuccess,
              let buffer = created,
              let working = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        else { return nil }

        Self.materializeContext.render(image, to: buffer, bounds: extent,
                                       colorSpace: working)
        // Named explicitly on the way back in, or Core Image assumes sRGB for a pixel
        // buffer and every value would be re-interpreted through the wrong transfer
        // function — a silent colour shift on every photograph in the app.
        let out = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: working])
        // 8 bytes a pixel: four half-float channels.
        let bytes = width * height * 8
        // The buffer starts at the origin; the decode's extent may not. Put the pixels
        // back where the caller's geometry expects to find them.
        guard extent.origin != .zero else { return (out, bytes) }
        return (out.transformed(by: CGAffineTransform(translationX: extent.origin.x,
                                                     y: extent.origin.y)), bytes)
    }

    public func decode(recipe: Recipe, draft: Bool, scaleFactor: Double = 1.0) -> CIImage? {
        let dev = recipe.develop

        // D50's honouring half (docs/23 audit queue item 6). The recipe records the
        // decoder version it was built on, the fingerprint hashes it — and decode()
        // never read it, so every render used the newest decoder this macOS offers
        // and a system update silently shifted three years of renders, which is the
        // exact drift the pin exists to prevent. A recorded version that this OS
        // still supports is honoured; one it no longer supports falls back to the
        // pin, because a working newer decoder beats a dead recorded one — the same
        // trade the pinning probe in `init` already makes.
        let resolvedVersion: CIRAWDecoderVersion
        if let requested = dev.raw.decoderVersion,
           requested != pinnedDecoderVersion,
           let match = filter.supportedDecoderVersions.first(where: {
               Int($0.rawValue.filter(\.isNumber)) == requested
           }) {
            resolvedVersion = match
        } else {
            resolvedVersion = pinnedVersion
        }

        let standIn = dev.denoise.appleStandIn
        let key = DecodeKey(draft: draft,
                            scaleFactor: Num.clamp(scaleFactor, 0.01, 1.0),
                            captureStrength: dev.detail.capture.strengthFraction,
                            luminanceNR: standIn.luma,
                            colorNR: standIn.chroma,
                            lensProfile: dev.geometry.lens.profile,
                            decoderVersion: resolvedVersion.rawValue)
        // Core Image is lazy, so the cached value is a recipe rather than pixels — but
        // it is a recipe bound to the filter's settings AT DECODE TIME, which is why a
        // hit must match every field the filter reads. The source lives inside an
        // actor, so there is no window where another caller mutates the filter between
        // the check and the use.
        if let hit = decodeCache.first(where: { $0.key == key })?.image {
            return hit
        }

        filter.decoderVersion = resolvedVersion
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

        var image = filter.outputImage
        if image == nil, resolvedVersion.rawValue != pinnedVersion.rawValue {
            // The recorded decoder claims support and still cannot form an image on
            // this file. Fall back to the pin rather than failing the render — the
            // same posture as the probe in `init`.
            filter.decoderVersion = pinnedVersion
            image = filter.outputImage
        }
        guard let image else { return nil }
        // Pixels, not the promise of pixels — see `materialized`. Falling back to the
        // lazy image keeps every failure path working exactly as before: a decode that
        // cannot be materialized is still a correct decode, just an expensive one.
        let stored = materialized(image) ?? (image: image, bytes: 0)
        decodeCache.removeAll { $0.key == key }
        decodeCache.insert((key: key, image: stored.image, bytes: stored.bytes), at: 0)
        evictDecodes()
        return stored.image
    }

    /// Bound the cache by BYTES as well as by count.
    ///
    /// Eight entries was chosen when an entry was a lazy `CIImage` — a filter
    /// description, costing kilobytes. Materializing changed what an entry weighs by
    /// four orders of magnitude without changing the number held: eight decodes at
    /// 2560 px is about 280 MB, and the ladder walking its rungs is exactly the thing
    /// that mints new keys. Trading a re-demosaic for memory pressure would be a poor
    /// bargain and a hard one to attribute, since what a photographer would notice is
    /// the machine hitching under swap rather than anything this file did.
    ///
    /// Newest-first order, so this drops the least recently produced.
    private func evictDecodes() {
        while decodeCache.count > Self.decodeCacheCapacity {
            decodeCache.removeLast()
        }
        while decodeCache.count > 1, decodeHeldBytes > Self.decodeCacheByteBudget {
            decodeCache.removeLast()
        }
    }

    /// What the held decodes weigh, from what was actually allocated.
    ///
    /// Measured at materialization rather than inferred from the stored image, because
    /// inferring it is wrong in a way that would be silent: `CIImage.pixelBuffer` is nil
    /// for an image that has been TRANSFORMED, and a decode whose extent does not start
    /// at the origin gets exactly that treatment on the way into the cache. Such an
    /// entry would have been counted as weightless and never evicted — the budget
    /// leaking on precisely the entries it was written to bound.
    private var decodeHeldBytes: Int { decodeCache.reduce(0) { $0 + $1.bytes } }

    /// Room for the working set that actually repeats — the viewer's settle, the rung
    /// under the hand, the 512 px probes, the mask raster — and not much more.
    private static let decodeCacheByteBudget = 320 * 1024 * 1024

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

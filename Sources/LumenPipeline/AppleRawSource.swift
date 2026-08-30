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
    /// entries covers the working set.
    ///
    /// This used to end "the values are lazy CIImage recipes, so the held cost is filter
    /// descriptions, not pixels" — which was true, and was the whole defect: a
    /// description is not a decode, so every hit re-ran the demosaic. Entries are pixels
    /// now — from the first ask below the interactive ceiling and from the first HIT
    /// above it, which is where the promotion in `decode` lives and where its argument
    /// is written down. That is why `evictDecodes` bounds them by bytes as well as by
    /// count, and why `heldDecodeBytes` is readable from outside.
    private static let decodeCacheCapacity = 8

    private struct DecodeEntry {
        let key: DecodeKey
        /// Pixels once the entry has earned them, the lazy `CIRAWFilter.outputImage`
        /// until then — see `decode`'s promotion path.
        var image: CIImage
        /// What the entry actually allocated — zero for one still held lazily.
        var bytes: Int
        /// THE LONG EDGE THAT WAS ASKED FOR, which is not the one that came back.
        ///
        /// The two classes this cache sorts entries into — an interactive working set
        /// under a byte budget, and one budget-exempt native inspection plane — used to
        /// be told apart by the DELIVERED extent. That reads the decoder's opinion where
        /// ours is meant: `CIRAWFilter.scaleFactor` is a request, this codebase already
        /// knows a decoder can decline one, and a declined scale factor is invisible
        /// downstream because `applyGeometry` clamps the delivered frame to the ask
        /// afterwards. Under the old rule an ordinary 2560 px viewer decode that came
        /// back native would become "the" inspection entry — exempt from the budget and
        /// limited to one — so the draft, the settle, the scope probe and the band-hue
        /// probe would evict each other in a four-way cycle and every frame in the app
        /// would pay a full-sensor demosaic and a full-sensor materialization. The rule
        /// and its argument are `DraftLadder.isInspectionAsk`, in LumenCore with tests.
        let askedLongEdge: Int
    }

    /// Newest first. Order is USE order, not production order — see the promotion in
    /// `decode`.
    private var decodeCache: [DecodeEntry] = []

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
    private func materialized(_ image: CIImage) -> (image: CIImage, bytes: Int)? {
        DecodeMaterializer.materialize(image)
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
        let clampedScale = Num.clamp(scaleFactor, 0.01, 1.0)
        let key = DecodeKey(draft: draft,
                            scaleFactor: clampedScale,
                            captureStrength: dev.detail.capture.strengthFraction,
                            luminanceNR: standIn.luma,
                            colorNR: standIn.chroma,
                            lensProfile: dev.geometry.lens.profile,
                            decoderVersion: resolvedVersion.rawValue)
        // What this call ASKED the decoder for, in pixels. Not read back from the
        // result: see `DecodeEntry.askedLongEdge` for why the delivered extent is the
        // wrong number to classify an entry by.
        //
        // Guarded rather than converted, because `Int(_:)` on a non-finite `Double`
        // TRAPS — the same trap `PipelineRenderer.byte` guards for the same reason a few
        // files away. `nativeLongEdge` comes from `CIRAWFilter.nativeSize`, and a source
        // that cannot say how big it is answers zero here, which classifies as
        // interactive: the safe side, since the only thing the inspection class buys is
        // an exemption from the memory budget.
        let asked = clampedScale * nativeLongEdge
        let askedLongEdge = asked.isFinite && asked > 0 && asked < 1e9
            ? Int(asked.rounded()) : 0

        // A hit must match every field the filter reads, because the entry was produced
        // under the filter's settings AT DECODE TIME. The source lives inside an actor,
        // so there is no window where another caller mutates the filter between the
        // check and the use.
        //
        // THE HIT MOVES TO THE FRONT, and that is a fix rather than housekeeping. This
        // list was documented as "newest-first, so eviction drops the least recently
        // PRODUCED" — and a hit did not touch the order, so the entry the viewer is
        // hitting on every single frame sank steadily toward the tail while the probes
        // that ran once each stayed at the head. `evictDecodes` removes from the tail.
        // So the first thing thrown away, once the ladder had minted a few rung keys or
        // the 512 px probes had run, was the one entry that was actually being used, and
        // the next frame paid a full RAW demosaic to get it back — 457 ms on the owner's
        // machine, per frame, from a cache that was reporting a hit rate. An LRU that
        // never records a use is not an LRU; it is a queue.
        if let index = decodeCache.firstIndex(where: { $0.key == key }) {
            var entry = decodeCache.remove(at: index)
            // THE SECOND ASK IS WHAT BUYS THE PIXELS, for entries above the interactive
            // ceiling — see the miss path below for the argument. A hit IS the second
            // ask, by definition, so this is where a native decode stops being a promise
            // and becomes a buffer.
            //
            // `bytes == 0` is the flag and it is honest for the other lazy cases too: a
            // decode the materializer refused (too large for the byte ceiling, no
            // working space, a pixel buffer that would not allocate) retries here and
            // costs a handful of guards when it fails again.
            if entry.bytes == 0, let promoted = materialized(entry.image) {
                entry.image = promoted.image
                entry.bytes = promoted.bytes
            }
            decodeCache.insert(entry, at: 0)
            evictDecodes()
            return entry.image
        }

        filter.decoderVersion = resolvedVersion
        filter.isDraftModeEnabled = draft
        filter.scaleFactor = Float(clampedScale)

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
        //
        // …EXCEPT ON FIRST SIGHT OF AN INSPECTION-CLASS ASK, WHICH IS NOT FREE TO GUESS
        // ABOUT. Materializing costs a whole-frame demosaic AND a whole-frame buffer —
        // 260 MB for a 7008 px ARW, half a gigabyte at 60 MP — and it is worth paying
        // exactly when the same key comes back. Below the interactive ceiling that is a
        // safe bet: those sizes are the viewer's settle, the rungs under a moving hand,
        // the mask raster, the 512 px probes, and every one of them repeats within a
        // gesture. Above it the bet was silently wrong for four callers that ask for
        // `scaleFactor: 1.0` and read FIVE PIXELS — `sampleSceneLinear`,
        // `sampleMaskStageInput`, `sampleColorStageInput` and the neutral solve behind
        // them. Their own documentation says so in as many words: "Cheap despite
        // decoding at full resolution: Core Image is lazy, so rendering a
        // five-pixel-square bounds computes that region and its filter support, not the
        // frame." That claim was TRUE while the materializer's limit was 4096 and became
        // false the day it moved to 16384; since then every eyedropper click, every
        // Point Colour pick and every white-balance solve has paid a full-sensor
        // demosaic and allocated a quarter of a gigabyte to average twenty-five pixels.
        // `exportedImage`, `renderHDRPair` and `renderFullSize` decode at 1.0 and use
        // the result once as well, which on a two-hundred-file batch is two hundred
        // buffers nobody reads twice.
        //
        // So: hold the promise, and let the FIRST HIT buy the pixels. What that costs is
        // named plainly rather than glossed — the viewer's own entry into a zoomed photo
        // asks twice (a draft, then a settle forty milliseconds later), so it now
        // evaluates the lazy decode once over the region it is drawing and materializes
        // on the second ask. That is roughly a tenth of a demosaic added to one frame,
        // bought against removing the whole thing from every one-shot consumer.
        //
        // The safety of holding a lazy `CIRAWFilter.outputImage` rests on one property:
        // that `outputImage` SNAPSHOTS the filter's settings rather than reading them at
        // evaluation time. It does, and this codebase is its own evidence — for the
        // whole of its history before `DecodeMaterializer` existed, every entry in this
        // cache was a lazy image, and `renderPreviewDelivery` obtains its decode and
        // then builds a `RenderPlan` whose `measuredBandMeanHues` reconfigures this very
        // filter to draft mode at 512 px before the decode is ever evaluated. Were
        // `outputImage` live-bound, the first frame of every photograph ever opened
        // would have been delivered at 512 px in draft demosaic. That is the falsifier,
        // it is loud, and nobody has ever seen it.
        let stored: (image: CIImage, bytes: Int)
        if DraftLadder.isInspectionAsk(longEdge: askedLongEdge) {
            stored = (image: image, bytes: 0)
        } else {
            stored = materialized(image) ?? (image: image, bytes: 0)
        }
        decodeCache.removeAll { $0.key == key }
        decodeCache.insert(DecodeEntry(key: key, image: stored.image,
                                       bytes: stored.bytes,
                                       askedLongEdge: askedLongEdge), at: 0)
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
    /// Newest-first order, so this drops the least recently USED — which it did not,
    /// until `decode` started moving a hit to the front. It dropped the least recently
    /// PRODUCED, and the entry a viewer hits every frame is by definition the one that
    /// stops being produced first.
    ///
    /// NATIVE INSPECTION ENTRIES ARE A CLASS OF THEIR OWN. The zoomed settle decodes
    /// at the sensor's full size for true 1:1 (docs/32 owner round), and one such
    /// entry weighs 260–460 MB — held under the ordinary byte budget it would
    /// alternate-evict with the drag's draft entry, and every settle at zoom would
    /// pay the demosaic again. So: at most ONE entry above the interactive ceiling,
    /// the newest, EXEMPT from the byte budget; the budget keeps bounding the
    /// interactive working set beneath it exactly as before. The exemption is per
    /// source and sources are themselves bounded (and evicted whole), so the worst
    /// case is one native plane per photograph the user actually zoomed into.
    ///
    /// AND THE EXEMPTION IS BOUNDED FROM OUTSIDE, which the sentence above got wrong by
    /// not doing the multiplication. "One native plane per photograph the user actually
    /// zoomed into" is one per SOURCE, and `RenderCoordinator` holds twelve sources —
    /// so the worst case it describes is twelve exempt planes at 260–460 MB apiece
    /// sitting on top of twelve interactive budgets at 320 MB apiece: something like
    /// seven gigabytes of wired, IOSurface-backed half-float buffers, in an app that
    /// also runs a 512 MB thumbnail cache. What a photographer would see is not a slow
    /// render but a machine swapping, which is exactly the attribution problem the byte
    /// budget was introduced to avoid. The per-source rules below still hold; the
    /// process-wide one is `RenderCoordinator.trimDecodeResidency`, which is where the
    /// twelve live and therefore the only place that can count them.
    private func evictDecodes() {
        func isInspection(_ entry: DecodeEntry) -> Bool {
            DraftLadder.isInspectionAsk(longEdge: entry.askedLongEdge)
        }
        var keptInspection = false
        decodeCache.removeAll { entry in
            guard isInspection(entry) else { return false }
            if keptInspection { return true }
            keptInspection = true
            return false
        }
        while decodeCache.filter({ !isInspection($0) }).count > Self.decodeCacheCapacity,
              let last = decodeCache.lastIndex(where: { !isInspection($0) }) {
            decodeCache.remove(at: last)
        }
        while decodeCache.filter({ !isInspection($0) }).count > 1,
              decodeCache.filter({ !isInspection($0) }).reduce(0, { $0 + $1.bytes })
                  > Self.decodeCacheByteBudget,
              let last = decodeCache.lastIndex(where: { !isInspection($0) }) {
            decodeCache.remove(at: last)
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
    ///
    /// Public because the only place that can bound the PROCESS is the one that holds
    /// the sources — see `evictDecodes`'s note about the missing multiplication. It had
    /// been `private` and unread since the eviction rules were rewritten to sum inline:
    /// a memory accountant with no reader.
    public var heldDecodeBytes: Int { decodeCache.reduce(0) { $0 + $1.bytes } }

    /// Drop the native inspection planes this source is holding. Returns the bytes
    /// freed.
    ///
    /// The exemption in `evictDecodes` is what lets a settle at zoom keep its 260 MB
    /// decode against a drag that would otherwise evict it; it is emphatically not a
    /// licence to hold one for every photograph the user has passed through. A source
    /// nobody is rendering is not inspecting anything.
    ///
    /// Always safe, in the strong sense: a released decode is not a lost decode, it is a
    /// decode that will be made again if it is wanted. The whole cost of being wrong
    /// here is one demosaic, and only if the photographer returns to this photograph AND
    /// zooms back past the interactive ceiling.
    @discardableResult
    public func releaseInspectionDecodes() -> Int {
        var freed = 0
        decodeCache.removeAll { entry in
            guard DraftLadder.isInspectionAsk(longEdge: entry.askedLongEdge) else {
                return false
            }
            freed += entry.bytes
            return true
        }
        return freed
    }

    /// Drop everything this source is holding. Returns the bytes freed.
    ///
    /// The blunt instrument, for a source that has fallen out of the working set
    /// entirely. Same argument as above and the same bounded cost: the decodes are
    /// recomputable, the `CIRAWFilter` and the metadata are not thrown away with them,
    /// and the photograph reopens at the price of a demosaic rather than a file open.
    @discardableResult
    public func releaseDecodes() -> Int {
        let freed = heldDecodeBytes
        decodeCache.removeAll()
        return freed
    }

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

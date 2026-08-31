// RenderCoordinator.swift
// The one place pipeline work is allowed to happen (docs/13 §3). The main actor hands
// it a recipe version and gets a frame back; it decodes, renders, coalesces and
// cancels. Nothing here touches SwiftUI, and nothing in SwiftUI touches Core Image.
//
// Coalescing is the whole trick behind a slider that keeps up with a hand: while a
// drag is producing recipe versions faster than frames can be made, only the newest
// one is rendered and every superseded request is dropped on arrival rather than
// rendered and thrown away.

#if os(macOS)

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import LumenCore
import LumenPipeline

struct RenderResult: @unchecked Sendable {
    let image: CGImage
    let generation: UInt64
    let isDraft: Bool
    /// True when the RAW stage refused the file and this is the embedded preview.
    /// The UI must say so — a preview shown as if it were the edit is a lie.
    let usedEmbeddedPreview: Bool
    let note: String?
    /// The source file's own long edge, in pixels — what a zoomed request should ask
    /// for so that "1:1" means the sensor's pixels rather than a proxy's (docs/32
    /// owner round: a 7008 px ARW at 1142% drew a 4096 proxy as mush, because 4096
    /// was both the cap and the number the zoom was denominated in). Zero when the
    /// source could not be opened at all.
    let nativeLongEdge: Int
    /// The unit rectangle of the delivered frame these pixels cover, top-left origin —
    /// nil for a whole-frame render. Region renders are what make a zoomed draft
    /// sharp for viewport cost (docs/32 fifth round); the viewer places the
    /// sub-image inside the full drawn geometry, which `fullPixelSize` describes.
    let regionUnit: CGRect?
    /// The FULL delivered frame's pixel size for this render — the geometry basis the
    /// viewer draws, clamps and samples against, whether or not the pixels are a
    /// region of it. Nil only on the embedded-preview fallback.
    let fullPixelSize: CGSize?
    /// Wall time the RAW decode cost inside this render — near zero on a cache hit.
    /// Zero on the paths that do not decode (the embedded-preview fallback).
    let decodeMilliseconds: Double
}

/// What the renderer knows about one file's AI mattes after a pass, plus the files its
/// bounded cache dropped along the way.
///
/// The third field is the one that had to exist. `PipelineRenderer` holds the mattes
/// behind a bound of twelve files; `AppState` held a ledger of the same facts that was
/// never trimmed, so browsing thirteen photographs with Vision masks and returning to
/// the first left the app certain it had a matte the renderer had thrown away — the
/// render read nothing, the panel said READY, and no edit short of an unrelated one
/// could clear it. A copy of somebody else's bounded cache is only honest if the
/// evictions come back with it.
struct MattePass: Sendable {
    /// Kinds this file now has a matte for.
    let available: Set<String>
    /// Kinds a pass has been RUN for on this file, whatever it found. The difference
    /// between `available` and this is "Vision looked and found nothing", which the
    /// panel says out loud and must not say about a request nobody made.
    let attempted: Set<String>
    /// Files whose mattes are gone. Any entry a caller holds for one of these is now a
    /// lie and must be dropped, not refreshed.
    let evicted: [URL]
}

actor RenderCoordinator {

    private let renderer = PipelineRenderer()
    private var sources: [URL: any ImageSource] = [:]
    private var latestGeneration: UInt64 = 0

    /// Bounded so a fast scroll through a folder cannot pin a hundred decoded RAWs in
    /// memory at once; the eviction is safe because a source is recreatable.
    private static let sourceCacheLimit = 12
    private var sourceOrder: [URL] = []

    /// THE PROCESS-WIDE CEILING ON HELD DECODES, which nothing had.
    ///
    /// `AppleRawSource` bounds what ONE source holds: eight entries, 320 MB of
    /// interactive working set, plus one native inspection plane exempt from that budget
    /// so a settle at zoom is not alternate-evicted by the drag beneath it. Every clause
    /// of that is right, and all of it is per source — while this actor holds twelve.
    /// Multiplied out, the shipped worst case is twelve exempt native planes at
    /// 260–460 MB each on top of twelve interactive budgets at 320 MB each: on the order
    /// of seven gigabytes of wired, IOSurface-backed half-float buffers, in a process
    /// that also runs a 512 MB thumbnail cache and a Core Image context with
    /// `cacheIntermediates: true`. The commit that introduced the exemption wrote the
    /// worst case down as "one native plane per photograph the user actually zoomed
    /// into" and did not multiply it by the source cache.
    ///
    /// What that costs is not a slow render, which is why it is hard to attribute: it is
    /// the machine paging, and every part of the app gets slower at once — the owner's
    /// "everything is slightly slow", with occasional stalls far longer than any render
    /// could explain. A decode cache several times the size of the thumbnail cache is
    /// the tail wagging the dog.
    ///
    /// 768 MB holds one native inspection plane and a full interactive working set for
    /// the photograph on screen, with room for a second photograph's settle beside it —
    /// which is what a compare pane and a before/after need. Above that the app is
    /// holding pixels for photographs nobody is looking at.
    private static let decodeResidencyBudget = 768 * 1024 * 1024

    /// Bring held decodes back under `decodeResidencyBudget`, least-recently-used source
    /// first, never touching the newest.
    ///
    /// Two passes, coarsening as it goes, because the two classes are worth very
    /// different amounts. A native inspection plane belongs to whichever photograph is
    /// being INSPECTED, and only one photograph can be; every other source holding one
    /// is holding it against a zoom that already ended. The interactive working set is
    /// different — a compare pane really does want its pane's decode between frames — so
    /// it is only released once dropping the inspection planes has failed to get under
    /// the line, and then from the coldest source forward.
    ///
    /// Releasing a decode is always CORRECT, never merely acceptable: the entry is
    /// recomputable from a file that has not moved, the `CIRAWFilter` and the capture
    /// metadata stay in the source, and the whole cost of a wrong guess is one demosaic
    /// on a photograph the user came back to. That asymmetry is why this trims eagerly
    /// rather than waiting for a memory-pressure notification that arrives after the
    /// machine is already swapping.
    ///
    /// The downcast is deliberate and narrow. `ImageSource` has two conformers and only
    /// one of them holds pixels — `RenderedImageSource` keeps a single lazy `CIImage` of
    /// a file Core Image will re-read — so a protocol requirement would be a method
    /// existing for one implementation. The cast says that in one line instead.
    private func trimDecodeResidency() {
        func held() -> Int {
            sourceOrder.reduce(0) { total, url in
                total + ((sources[url] as? AppleRawSource)?.heldDecodeBytes ?? 0)
            }
        }
        var total = held()
        guard total > Self.decodeResidencyBudget else { return }
        // Oldest first, newest excluded: the newest is the photograph a render just
        // asked for, and taking its decode is taking the one that is about to be used.
        let cold: [URL] = Array(sourceOrder.dropLast())
        for url in cold {
            guard total > Self.decodeResidencyBudget else { return }
            guard let raw = sources[url] as? AppleRawSource else { continue }
            total -= raw.releaseInspectionDecodes()
        }
        // The blunt pass spares the surfaces that legitimately alternate. A four-up
        // survey and a two-pane compare render several photographs in rotation, each one
        // becoming "newest" in turn, so a rule that protected only the newest would have
        // every pane release the decode the next pane's frame just made it re-do — a
        // trim that manufactures exactly the re-demosaic it exists to prevent. The
        // inspection pass above needs no such guard: the compare panes deliberately keep
        // the interactive cap, so they never mint an inspection entry at all.
        let alternating: [URL] = Array(sourceOrder.suffix(Self.residencyLiveSources))
        for url in cold where !alternating.contains(url) {
            guard total > Self.decodeResidencyBudget else { return }
            guard let raw = sources[url] as? AppleRawSource else { continue }
            total -= raw.releaseDecodes()
        }
    }

    /// How many of the most recently used sources the blunt trim leaves alone.
    ///
    /// Not "the number of panes", which is not a fixed number — the survey is N-up over
    /// whatever the photographer selected. It is the number of surfaces that alternate
    /// at FULL render cost: the loupe (one), the two-up compare (two), and one spare for
    /// the photograph an arrow press is about to land on. A survey's cells are 160–520 pt
    /// and ask for a few hundred pixels each, so ten of them together hold a fraction of
    /// the budget and this pass never reaches them however many there are.
    private static let residencyLiveSources = 4

    /// Files the renderer's bounded matte cache has dropped since the app last asked.
    ///
    /// An export or a full-size render generates mattes inline and can therefore evict
    /// somebody else's, with no return value going anywhere near the app. Holding the
    /// evictions here until the next `ensureMattes` is what lets a ledger kept outside
    /// this actor find out at all.
    private var evictedMattes: Set<URL> = []

    /// A render that takes part in coalescing: it claims the newest ticket, and any
    /// request holding an older one is dropped wherever it happens to be.
    ///
    /// `generation` must be a real ticket from `RenderGeneration.next()`. A sentinel
    /// like `.max` would latch `latestGeneration` at the ceiling and every subsequent
    /// request would compare as stale — one poisoned call and the viewer never updates
    /// again. Work that must not participate goes through `renderOneShot` instead.
    func render(url: URL, recipe: Recipe, maxLongEdge: Int, draft: Bool,
                generation: UInt64,
                strokeSets: [String: BrushStrokeSet] = [:],
                showingUncropped: Bool = false,
                softProof: SoftProof? = nil,
                region: CGRect? = nil) async -> RenderResult? {
        latestGeneration = max(latestGeneration, generation)
        // Drop work that is already stale before paying for a decode.
        guard generation >= latestGeneration else { return nil }
        return await produce(url: url, recipe: recipe, maxLongEdge: maxLongEdge,
                             draft: draft,
                             // A FRAME SOMEBODY IS LOOKING AT DECODES AT FULL DETAIL.
                             // Apple's draft decode is a lower-quality demosaic — a
                             // second quality knob beside the resolution one
                             // `DraftLadder` holds, hard-coded where nothing measured
                             // it, and the one the eye notices. The ladder trades
                             // quality for speed by resolution; that is the only lever
                             // here, and it is the only lever that is measured.
                             coarseDecode: false,
                             generation: generation, coalesced: true,
                             strokeSets: strokeSets,
                             showingUncropped: showingUncropped,
                             softProof: softProof,
                             region: region)
    }

    /// A render nobody else is waiting on — the scope proxy, the Auto-tone probe. It
    /// neither claims a ticket nor yields to one: the caller has its own supersede
    /// check, and letting these touch `latestGeneration` would have them cancelling
    /// the viewer's frames (or, with a sentinel, all of them forever).
    ///
    /// Deliberately takes no soft proof. A scope is an instrument on the EDIT, and a
    /// histogram with a gamut flag's flat grey binned into it would be measuring the
    /// warning rather than the photograph — and Auto Tone would then solve against it.
    func renderOneShot(url: URL, recipe: Recipe, maxLongEdge: Int, draft: Bool,
                       strokeSets: [String: BrushStrokeSet] = [:]) async -> RenderResult? {
        await produce(url: url, recipe: recipe, maxLongEdge: maxLongEdge,
                      draft: draft,
                      // A one-shot is an instrument input — a 512 px scope proxy or the
                      // auto-tone probe — read as statistics rather than looked at, so
                      // a cheap demosaic would cost nothing anyone can see. Tied to
                      // `draft` because that is the honest rule for this path.
                      //
                      // Worth saying plainly: BOTH current callers pass `draft: false`,
                      // and their own comments say why (an instrument must not read a
                      // stale table, or it disagrees with the settle by exactly the
                      // amount the user is asking it about). So no path in the app takes
                      // the coarse decode today. It survives as the meaning of the flag,
                      // not as a live shortcut — and if that stays true, the flag should
                      // eventually go rather than sit here looking load-bearing.
                      coarseDecode: draft,
                      generation: 0, coalesced: false,
                      strokeSets: strokeSets)
    }

    private func produce(url: URL, recipe: Recipe, maxLongEdge: Int, draft: Bool,
                         coarseDecode: Bool,
                         generation: UInt64, coalesced: Bool,
                         strokeSets: [String: BrushStrokeSet],
                         showingUncropped: Bool = false,
                         softProof: SoftProof? = nil,
                         region: CGRect? = nil) async -> RenderResult? {
        // Stale by TICKET, or stale because the caller has gone away.
        //
        // The ticket alone could not drop a backlog. `latestGeneration` is claimed when
        // a request ENTERS this actor, and the actor is serial with a synchronous
        // render inside it — so while one frame is being produced, the twelve requests
        // queued behind it have not raised the number and every one of them compares as
        // current when its turn comes. A drag delivers an event every 8–16 ms and a
        // render costs tens of milliseconds, so the queue grew for the whole gesture
        // and every superseded frame was rendered in full. That is the mechanism behind
        // "the image isn't really updating very well": not a slow render, an unbounded
        // one per event.
        //
        // Cancellation is the signal that was already there and unread. The viewer
        // drives these from `.task(id:)`, which cancels the previous task the moment
        // the id moves, so a request nobody is waiting for arrives here already
        // cancelled. Checking it costs a load and collapses the backlog to at most one
        // frame behind. Work that must not be dropped — the export path — does not come
        // through here.
        func stale() -> Bool {
            if Task.isCancelled { return true }
            return coalesced && generation < latestGeneration
        }

        guard !stale() else { return nil }

        do {
            let source = try self.source(for: url)
            guard !stale() else { return nil }

            // The fallback the kernel header promises, actually taken.
            //
            // This used to render through the graph unconditionally and then ATTACH a
            // "CPU fallback" note to the GPU's own output — so when the core kernels
            // were missing the user got a wrong picture with a label claiming it came
            // from the reference path. `renderReference` existed the whole time and had
            // no caller. Without `logEncode` in particular the graph cannot form a
            // picture at all: S9/S10 is skipped, picture formation is skipped, and even
            // the fallback tone curve needs it — the output is scene-referred data
            // presented as a photograph.
            let image: CGImage
            let note: String?
            var regionUnit: CGRect?
            var fullPixelSize: CGSize?
            var decodeMilliseconds: Double = 0
            if KernelLibrary.coreAvailable {
                let delivery = try renderer.renderPreviewDelivery(
                    source: source, recipe: recipe,
                    maxLongEdge: maxLongEdge, draft: draft,
                    coarseDecode: coarseDecode,
                    showingUncropped: showingUncropped,
                    strokeSets: strokeSets,
                    softProof: softProof,
                    region: region)
                image = delivery.image
                regionUnit = delivery.regionUnit
                fullPixelSize = delivery.fullPixelSize
                decodeMilliseconds = delivery.decodeMilliseconds
                // Core kernels present but something else missing: the picture is real,
                // and some stage of it silently did nothing. Say which.
                let missing = KernelLibrary.unavailableKernels
                note = missing.isEmpty
                    ? nil
                    : "Reduced — \(missing.count) GPU "
                        + (missing.count == 1 ? "kernel" : "kernels")
                        + " unavailable: " + missing.joined(separator: ", ")
            } else {
                // No region on the CPU fallback: it is rare, whole-frame by
                // construction, and a region contract it half-honoured would be
                // worse than the full frame it already delivers.
                image = try renderer.renderReference(source: source, recipe: recipe,
                                                     maxLongEdge: maxLongEdge,
                                                     strokeSets: strokeSets,
                                                     softProof: softProof)
                fullPixelSize = CGSize(width: image.width, height: image.height)
                // The framing caveat is not decoration. `renderReference` never
                // calls `applyGeometry`, so this path returns the WHOLE frame:
                // no crop, no straighten, no flip. Everything else about the picture
                // is right, which is what makes it dangerous — it reads as a correct
                // render of a photograph the user did not compose.
                //
                // Not fixed here, deliberately. `applyGeometry` wants a `CIImage` and
                // this path holds an `ImageBuffer`, and the bridge crosses the row-order
                // convention `KernelGoldenTests` documents at length: Core Image extents
                // are bottom-up, the UI hands down a top-down fraction, and
                // `CIImage(bitmapData:)` is a third convention again. Getting it wrong
                // returns a plausible picture mirrored about its centre line. None of
                // this compiles on the machine the fix would be written on, so writing
                // it blind trades a wrongly-framed preview for a possibly upside-down
                // one. It wants a Mac and one golden.
                note = "CPU fallback — GPU kernels unavailable; crop, straighten and "
                    + "flip are not applied to this preview"
            }

            // No staleness check HERE, deliberately (FrameDelivery in LumenCore is
            // the law and the arithmetic). This used to re-check `stale()` after the
            // render — but a drag cancels the viewer's task on every event, events
            // outpace renders, so every completed frame was paid for and then thrown
            // away, and the picture moved only when the hand paused. Finished work is
            // never stale by cancellation: the caller decides against
            // `FrameDelivery.shouldShow`, whose only questions are identity and order.
            return RenderResult(image: image, generation: generation, isDraft: draft,
                                usedEmbeddedPreview: false,
                                note: note,
                                nativeLongEdge: Int(source.nativeLongEdge.rounded()),
                                regionUnit: regionUnit,
                                fullPixelSize: fullPixelSize,
                                decodeMilliseconds: decodeMilliseconds)
        } catch {
            // Never leave the viewer empty: fall back to the embedded preview and
            // label it honestly.
            if let preview = Self.embeddedPreview(url: url, maxLongEdge: maxLongEdge) {
                return RenderResult(image: preview, generation: generation, isDraft: true,
                                    usedEmbeddedPreview: true,
                                    note: "Embedded preview — \(Self.describe(error))",
                                    nativeLongEdge: Int((try? self.source(for: url))
                                        .map(\.nativeLongEdge)?.rounded() ?? 0),
                                    regionUnit: nil,
                                    fullPixelSize: nil,
                                    decodeMilliseconds: 0)
            }
            return nil
        }
    }

    /// Render at full resolution for export. Never coalesced: an export is a promise.
    func renderFullSize(url: URL, recipe: Recipe,
                        strokeSets: [String: BrushStrokeSet] = [:]) throws -> CGImage {
        let source = try self.source(for: url)
        generateMattesNow(source: source, recipe: recipe)
        return try renderer.renderPreview(source: source, recipe: recipe,
                                          maxLongEdge: Int(source.nativeLongEdge),
                                          draft: false, coarseDecode: false,
                                          strokeSets: strokeSets)
    }

    /// Returns the names of the kernels that were unavailable, so the caller can report
    /// a reduced file instead of counting it as a clean one. Empty means every stage
    /// ran; a throw means nothing was delivered.
    func export(url: URL, recipe: Recipe, to destination: URL,
                exportRecipe: ExportRecipe,
                strokeSets: [String: BrushStrokeSet] = [:]) throws -> [String] {
        let source = try self.source(for: url)
        generateMattesNow(source: source, recipe: recipe)
        return try renderer.export(source: source, recipe: recipe, to: destination,
                                   using: exportRecipe, strokeSets: strokeSets)
    }

    /// The matte pass, run INLINE, for the delivery paths.
    ///
    /// Everywhere else it is asynchronous because a frame must not wait for it. An
    /// export is the opposite promise: a file that quietly comes out with the Subject
    /// mask contributing nothing — because it happened to be a photo the viewer had
    /// never opened, or a batch of two hundred — is exactly the silent-empty-mask
    /// failure this project has already shipped twice. A second per photo is the right
    /// price for the file being the picture.
    private func generateMattesNow(source: any ImageSource, recipe: Recipe) {
        // Per KIND. This used to ask whether the file had been attempted at all, so a
        // recipe that gained a People mask after a Subject mask exported with the
        // People component selecting nothing.
        let missing = missingMatteKinds(url: source.url, recipe: recipe)
        guard !missing.isEmpty else { return }
        guard let picture = renderer.matteSourceImage(source: source) else { return }
        record(evicted: renderer.storeMattes(
            VisionMattes.generate(image: picture, kinds: missing),
            requested: Set(missing.map { $0.rawValue }), for: source.url))
    }

    /// The kinds this recipe wants that no pass has looked for yet on this file.
    private func missingMatteKinds(url: URL, recipe: Recipe) -> Set<MaskKind> {
        let wanted = VisionMattes.kinds(in: recipe)
        guard !wanted.isEmpty else { return [] }
        let done = renderer.attemptedMatteKinds(for: url)
        return wanted.filter { !done.contains($0.rawValue) }
    }

    private func record(evicted: [URL]) {
        for url in evicted { evictedMattes.insert(url) }
    }

    /// One mask's alpha, for the loupe's overlay. Small by construction — the raster is
    /// capped at 1024 px — so it does not claim a render ticket.
    func maskAlpha(url: URL, recipe: Recipe, maskID: String,
                   strokeSets: [String: BrushStrokeSet]) -> Plane? {
        guard let source = try? self.source(for: url) else { return nil }
        return renderer.renderMaskAlpha(source: source, recipe: recipe,
                                        maskID: maskID, strokeSets: strokeSets)
    }

    /// A mask's alpha, small enough to draw in its own row.
    ///
    /// The thing that makes a stack of three components readable at a glance: the fold
    /// stops being an abstraction and becomes three pictures and a result (docs/35
    /// §4.3). A mask row carried a COUNT BADGE and nothing else, so "Mask 3" had to be
    /// remembered rather than seen.
    ///
    /// 96 px is a hundredth of the proxy's pixels, so this is affordable per row per
    /// edit in a way the 1024 px overlay is not.
    func maskThumbnail(url: URL, recipe: Recipe, maskID: String,
                       strokeSets: [String: BrushStrokeSet]) -> Plane? {
        guard let source = try? self.source(for: url) else { return nil }
        return renderer.renderMaskAlpha(source: source, recipe: recipe,
                                        maskID: maskID, strokeSets: strokeSets,
                                        longEdge: AppState.maskThumbnailLongEdge)
    }

    /// Generate the Vision mattes this recipe's masks need, if they are not cached
    /// already, and hand back what the renderer knows afterwards (docs/08 §8.7).
    ///
    /// Never blocks a render. The segmentation runs on `VisionMatteWorker`, a
    /// different actor, so the `await` below SUSPENDS this one — frames keep being
    /// drawn from the cache while a matte is computed, which is the whole of the §8.7
    /// contract and the thing LrC's masking is most criticised for missing.
    ///
    /// One pass per file AND KIND: the result is recorded even when a kind produced
    /// nothing, so a photograph with no subject in it is not re-segmented on every
    /// slider move — and a kind added later is not skipped because a different one was
    /// already done.
    ///
    /// Always safe to call. The authoritative check is here rather than in the caller
    /// deliberately: the cache this reads is the renderer's own, it is bounded, and a
    /// caller that decided for itself whether a pass was needed would be deciding from
    /// a copy that eviction can silently invalidate. Two dictionary lookups is what the
    /// fast path costs.
    func ensureMattes(url: URL, recipe: Recipe) async -> MattePass {
        let missing = missingMatteKinds(url: url, recipe: recipe)
        if !missing.isEmpty,
           let source = try? self.source(for: url),
           let picture = renderer.matteSourceImage(source: source) {
            let produced = await VisionMatteWorker.shared.mattes(image: picture,
                                                                kinds: missing)
            record(evicted: renderer.storeMattes(
                produced, requested: Set(missing.map { $0.rawValue }), for: url))
        }
        let dropped = evictedMattes.subtracting([url])
        evictedMattes.removeAll()
        return MattePass(available: renderer.matteKinds(for: url),
                         attempted: renderer.attemptedMatteKinds(for: url),
                         evicted: Array(dropped))
    }

    /// Decode a photograph nobody has asked for yet, so that when they do, the file is
    /// already read.
    ///
    /// This is the whole read-ahead: it does not render, it does not produce an image,
    /// and it returns nothing. It puts the DECODE in `AppleRawSource`'s cache under the
    /// exact key the real render will look for — same scale, same draft flag, same
    /// recipe fields — so the render that follows finds it and skips the two and a half
    /// seconds the owner measured for a read off his offload drive.
    ///
    /// Matching that key is the entire correctness requirement, and it is why the
    /// caller passes the recipe rather than a neutral one: `DecodeKey` carries the noise
    /// amounts, the capture sharpening and the lens profile, so a warm under the wrong
    /// recipe is a second cache entry — twice the memory and no hit, which is worse
    /// than not warming at all.
    ///
    /// Runs on this actor like everything else, and that is a deliberate constraint
    /// rather than an oversight: a decode has no cancellation points, so a warm in
    /// flight cannot yield to a photographer who has moved on. `DecodeWarming.mayWarm`
    /// is what keeps that from mattering — it offers a warm only once the current
    /// photograph has SETTLED, which happens when someone stops to work and never
    /// happens while they page.
    func warmDecode(url: URL, recipe: Recipe, longEdge: Int) {
        guard let source = try? self.source(for: url) else { return }
        let native = source.nativeLongEdge
        guard native > 0, longEdge > 0 else { return }
        let scale = Swift.min(1.0, Double(longEdge) / native)
        // The result is deliberately discarded. The value is the cache entry it leaves
        // behind, which is also why a hit costs nothing: `decode` answers from the
        // cache before it considers going to the file.
        _ = source.decode(recipe: recipe, draft: false, scaleFactor: scale)
    }

    func nativeSize(for url: URL) -> (width: Int, height: Int)? {
        guard let source = try? self.source(for: url) else { return nil }
        return source.nativePixelSize
    }

    /// The neutral this file was actually shot at — the one the render adapts FROM.
    ///
    /// It has always been here and the panel has never seen it: `RenderPlan` gets it
    /// from `source.asShotTemperature` on every render while the Temp row stood a
    /// literal 5500 in for it. Same shape as `nativeSize(for:)`, and for the same
    /// reason: the answer lives on the decoded source, which lives on this actor.
    func asShotNeutral(for url: URL) -> WhiteBalanceEngine.Neutral? {
        guard let source = try? self.source(for: url) else { return nil }
        return WhiteBalanceEngine.Neutral(kelvin: source.asShotTemperature,
                                          tint: source.asShotTint)
    }

    func invalidate(url: URL) {
        sources.removeValue(forKey: url)
        sourceOrder.removeAll { $0 == url }
        // The matte was computed from this file's pixels, so it goes with them — and
        // anyone holding a copy of the ledger hears about it the same way they hear
        // about an eviction, since to them the two are the same event.
        renderer.forgetMattes(for: url)
        evictedMattes.insert(url)
    }

    /// One scene-linear sample, for the eyedroppers.
    ///
    /// Lives on the actor because the decoded source does, and it reuses the same
    /// bounded cache the renders use — picking on a photo you are already looking at
    /// costs no decode at all.
    func sampleSceneLinear(url: URL, recipe: Recipe,
                           sourceX: Double, sourceY: Double) -> RGB? {
        guard let source = try? self.source(for: url) else { return nil }
        return renderer.sampleSceneLinear(source: source, recipe: recipe,
                                          sourceX: sourceX, sourceY: sourceY)
    }

    /// The cull-time clipping measurement for one file.
    ///
    /// On this actor for the same reason every other tap is: the decoded source lives
    /// here, so measuring a photo the viewer is already showing costs no second decode.
    /// It claims no render ticket — a measurement must never cancel the frame the user
    /// is waiting on.
    ///
    /// The recipe is passed through because `decode` reads it (lens profile, capture
    /// sharpening, Apple's stand-in denoise) and the decode cache is keyed on those; a
    /// synthetic recipe here would evict the viewer's decode on every measurement.
    /// Nothing downstream of the decode runs, so the tone and colour settings in it
    /// have no effect on the numbers — which is the property that makes them worth
    /// caching against the file rather than against the edit.
    func clippingStatistics(url: URL,
                            recipe: Recipe) -> (RawStatistics, RawTruth.Plan)? {
        guard let source = try? self.source(for: url) else { return nil }
        return renderer.clippingStatistics(source: source, recipe: recipe)
    }

    // `sampleWorking` — the post-S6 tap — is deliberately GONE. Its doc-comment
    // claimed it sampled "the value the colour stage will actually compare against",
    // and it did not: the colour stage compares after tone and presence
    // (`colorStageInput`), and its one caller, the global Point Colour eyedropper,
    // now goes through `samplePointColorReference` below. A zero-caller tap whose
    // contract is false is the FAKE class with an API instead of a tooltip.

    /// One sample in the space a MASK compares against — `localStageInput`, S6 through
    /// S10, the same image the mask rasterizer is handed.
    ///
    /// A third tap, and the third is not a luxury. `sampleWorking` stops after the
    /// linear matrix, which is right for a tool whose comparison happens there and
    /// wrong for `colorRangePlane` and `similarityPlane`, which compare a component's
    /// stored samples against the picture AFTER tone and after the colour+grade table.
    /// Storing the shorter tap meant that on any photograph with a real global edit the
    /// clicked colour and the compared colour were different numbers — so a Colour
    /// Range mask could fail to select the pixel that was clicked, and got worse the
    /// more the picture had been worked on.
    ///
    /// A mask has to compare against what it will be applied to, and it is applied to
    /// the output of this stage list.
    func sampleMaskReference(url: URL, recipe: Recipe,
                             sourceX: Double, sourceY: Double) -> RGB? {
        guard let source = try? self.source(for: url),
              let sample = renderer.sampleMaskStageInput(source: source, recipe: recipe,
                                                        sourceX: sourceX,
                                                        sourceY: sourceY),
              sample.isFinite
        else { return nil }
        return sample
    }

    /// The fourth tap: the COLOUR stage's input, S3 through S8 — what
    /// `ColorEngine.apply` compares a global Point Colour swatch against. The global
    /// eyedropper stored `sampleWorking` (post-S6) while the engine compared here,
    /// so a swatch picked with tone moves selected the wrong colour (docs/23 dossier
    /// queue item 5).
    func samplePointColorReference(url: URL, recipe: Recipe,
                                   sourceX: Double, sourceY: Double) -> RGB? {
        guard let source = try? self.source(for: url),
              let sample = renderer.sampleColorStageInput(source: source, recipe: recipe,
                                                          sourceX: sourceX,
                                                          sourceY: sourceY),
              sample.isFinite
        else { return nil }
        return sample
    }

    /// Sample a point and solve the Temp/Tint that make it neutral.
    ///
    /// The whole solve happens here rather than in the app because everything it needs
    /// is on this side of the actor: the sample, and the as-shot neutral it has to be
    /// measured against. Handing the caller a bare RGB would have meant exporting the
    /// capture metadata too, and then two places would have to agree about what the
    /// sample means.
    ///
    /// `neutralizing` expects a value with the CURRENT white balance already applied —
    /// it inverts that matrix internally to recover the decoded value — so the sample
    /// goes through `wb.matrix` on the way in. The round trip is deliberate and exact:
    /// it keeps this call correct without depending on the solver's internals.
    func solveNeutral(url: URL, recipe: Recipe,
                      sourceX: Double, sourceY: Double) -> (kelvin: Double, tint: Double)? {
        guard let source = try? self.source(for: url),
              let sample = renderer.sampleSceneLinear(source: source, recipe: recipe,
                                                     sourceX: sourceX, sourceY: sourceY),
              sample.isFinite, sample.maxComponent > 1e-9
        else { return nil }
        let wb = WhiteBalanceEngine(asShotKelvin: source.asShotTemperature,
                                    asShotTint: source.asShotTint,
                                    targetKelvin: recipe.develop.raw.temp,
                                    targetTint: recipe.develop.raw.tint)
        return WhiteBalanceEngine.neutralizing(sample: wb.matrix.apply(sample),
                                               asShotKelvin: source.asShotTemperature,
                                               asShotTint: source.asShotTint,
                                               current: wb)
    }

    // MARK: - Sources

    /// Picks the decoder by extension rather than by trying one and catching, because
    /// `CIRAWFilter(imageURL:)` is not documented to refuse a JPEG — it may return a
    /// filter that produces something, and a rendered file quietly run through the RAW
    /// stage would be wrong in ways nobody could see from the picture.
    private func source(for url: URL) throws -> any ImageSource {
        if let cached = sources[url] {
            sourceOrder.removeAll { $0 == url }
            sourceOrder.append(url)
            // Here rather than after the render, because this is the one line every
            // consumer passes through — the viewer's frames, the scope proxy, the
            // clipping measurement, the four eyedropper taps and the export — and the
            // budget has to bound the process rather than the viewer. It costs a walk of
            // at most twelve sources summing at most eight integers each; the thing it
            // is standing in front of is a RAW demosaic.
            trimDecodeResidency()
            return cached
        }
        let created: any ImageSource = PhotoFormats.isRendered(url)
            ? try RenderedImageSource(url: url)
            : try AppleRawSource(url: url)
        sources[url] = created
        sourceOrder.append(url)
        while sourceOrder.count > Self.sourceCacheLimit, let oldest = sourceOrder.first {
            sourceOrder.removeFirst()
            sources.removeValue(forKey: oldest)
        }
        trimDecodeResidency()
        return created
    }

    private static func describe(_ error: Error) -> String {
        if let raw = error as? RawSourceError {
            switch raw {
            case .unreadable: return "file unreadable"
            case .undecodable: return "this file could not be decoded"
            }
        }
        return "render failed"
    }

    /// The picture shown when the RAW stage refused the file, labelled as such by the
    /// caller.
    ///
    /// THE EMBEDDED PREVIEW IS TRIED FIRST AND THE SYNTHESIZED ONE ONLY IF THERE IS
    /// NONE, which is not what this did. `kCGImageSourceCreateThumbnailFromImageAlways`
    /// was true unconditionally, and with it ImageIO is entitled to decode the whole
    /// file to produce the thumbnail — a full RAW demosaic through ImageIO, on this
    /// actor, synchronously, for a file whose RAW decode has just failed. That is the
    /// one thing `ThumbnailLoader` refuses to do anywhere on the browse path, and its
    /// header says why in a sentence that applies here word for word: a contact sheet
    /// that demosaics is a contact sheet the photographer waits for. The ask made it
    /// worse rather than better — `maxLongEdge` on the zoomed loupe is the sensor's own
    /// long edge now, so the size being requested is precisely the one that forces the
    /// full-image path instead of the 1616 px JPEG the camera already wrote.
    ///
    /// Same picture in every case where an embedded preview exists, which is every
    /// camera RAW; strictly the old behaviour when one does not. And the ask is capped
    /// at the interactive ceiling deliberately: this is the frame the app puts up to say
    /// it could not develop the file, it carries a badge saying so, and nobody judges
    /// sharpness on it. `kCGImageSourceThumbnailMaxPixelSize` is a maximum and never
    /// upscales, so a smaller preview still arrives at its own size.
    nonisolated static func embeddedPreview(url: URL, maxLongEdge: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let pixels = min(max(maxLongEdge, 64), DraftLadder.interactiveLongEdgeCeiling)
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        if let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                              options as CFDictionary) {
            return embedded
        }
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// A monotonically increasing ticket the main actor stamps on every render request.
@MainActor
final class RenderGeneration {
    private var value: UInt64 = 0

    func next() -> UInt64 {
        value &+= 1
        return value
    }

    var current: UInt64 { value }
}

#endif

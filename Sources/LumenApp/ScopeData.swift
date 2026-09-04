// ScopeData.swift
// The measurement feed behind the histogram and the scopes.
//
// TWO RESOLUTIONS, because the panel prints two different kinds of number.
//
// The TRACES — histogram shape, waveform, parade, vectorscope — are DISTRIBUTIONS, and
// a distribution is what a proxy is for. A ~512 px box-average of the composite carries
// 256 bins with several hundred samples each, the vectorscope's three cube roots per
// pixel stay affordable, and the whole refresh stays far below the cost of the frame the
// user is already waiting for.
//
// The CLIPPING PERCENTAGES are not a distribution. They are a COUNT of pixels that
// reached the end of the scale, and a box average destroys exactly that: averaging is a
// low-pass filter, so a blown region smaller than one box does not get smaller, it
// disappears. Re-derived on a 45 MP frame binned at a 512 px long edge (a 16×16 box per
// sample): an unaligned 16×16 blown square reported 0.00000 % against a truth of
// 0.00057 %, and a 32×32 square reported 25 % of its truth (W2/H2-01). The specular on a
// wet rock and the sun through leaves are exactly that size, and they read `0.00% white`
// beside a dark triangle. Raising the proxy does not fix it — `ScopeProxy`'s ~1 MP
// budget is still a 7×7 box on a 45 MP frame, and anything below 7×7 still vanishes.
// Only counting does.
//
// So the counts are taken from `ScopeTap` — the frame's OWN pixels, every one of them,
// at native resolution — and the traces' bins are rescaled to that denominator, which
// leaves every ratio the panel reads (`normalized`, `fraction(in:)`, `clippedFraction`)
// denominated in the picture rather than in the proxy.
//
// WHAT THE TAP CAN AND CANNOT ANSWER. `PipelineRenderer` hands the viewer an `RGBA8`
// image in `CGColorSpace.sRGB`, after an 8×8 ordered dither at ±0.5 LSB. Working-space
// headroom above 1.0 and everything outside the sRGB gamut are gone two stages before
// the binner sees a pixel, so the readout-space picker gets one honest answer and two
// refusals — see `scopeTransform(requested:)`, which is where the argument lives.
//
// WHICH IMAGE, said once here and printed by the panel. The two feeds below do not
// measure the same picture. `measureScopes(fromViewerFrame:)` bins the frame the viewer
// is already showing, which `LoupeView` renders WITH `state.activeSoftProof` — so with
// ⇧S on the numbers describe the proofed rendition, and with the gamut flag on (its
// default) they also describe the flat grey the flag paints over out-of-gamut pixels.
// `scheduleScopeRefresh` commissions its own render, and `renderOneShot` deliberately
// takes no proof at all. Both are defensible; neither may be silent. Every measurement
// therefore carries a `ScopeReadout.Provenance`, and the views print it whenever the
// answer is not the plain one.
//
// Refreshes are debounced and superseded: during a slider drag the scopes update from
// the newest settled state, never from a queue of stale ones.

#if os(macOS)

import CoreGraphics
import Foundation
import LumenCore
import SwiftUI

struct ScopeData: @unchecked Sendable {
    var histogram: Histogram?
    var waveform: Waveform?
    var parade: Parade?
    var vectorscope: Vectorscope?

    /// The traces, pre-rasterized on the same detached task that binned the pixels.
    /// `ScopesView` used to rasterize these inside `body` — up to ~197k pixels and a
    /// megabyte of allocation per evaluation, re-run on every publish during a drag.
    /// (`@unchecked`: CGImage is immutable and safely crosses the hop from the
    /// detached task; it just predates Sendable.)
    var waveformImage: CGImage?
    var paradeImages: [CGImage]?    // R, G, B — one normalization, in ScopeRaster
    var vectorscopeImage: CGImage?

    /// WHICH IMAGE THESE NUMBERS CAME OFF — see `ScopeReadout.Provenance`.
    ///
    /// The panel used to print a histogram and say nothing at all about what it was a
    /// histogram OF, and the two feeds in this file do not measure the same picture: the
    /// loupe bins the frame the viewer is showing, soft proof and all, while the grid
    /// commissions a render the coordinator deliberately builds without one. Carrying
    /// the answer with the bins is what lets `HistogramView` and `ScopesView` disclose
    /// it instead of the reader having to know which surface they are on.
    var provenance: ScopeReadout.Provenance?
}

// MARK: - The tap

/// The frame's own pixels: 8-bit sRGB, RGBA, row-major, at native resolution.
///
/// Naming it is half the point. Every number this file prints comes off this one
/// surface, and the surface is display-encoded and gamut-clamped, so what the
/// instrument can honestly claim is bounded by it rather than by the picker above it.
/// What it CAN do is answer this space's question exactly, which is what
/// `AppState.clipCounts(in:)` does — no downsample, no interpolation, no estimate.
struct ScopeTap: Sendable {
    let width: Int
    let height: Int
    /// `width × height × 4`, RGBA, alpha byte unused.
    let bytes: [UInt8]

    var sampleCount: Int { width * height }
}

/// Per-channel counts of pixels at the ends of the readout scale, and the number of
/// pixels they are denominated in. Channel order is `Histogram.Channel`'s: R, G, B, luma.
struct ScopeClipCounts: Sendable {
    let low: [Int]
    let high: [Int]
    let samples: Int
}

extension AppState {

    /// How long the app waits after the last edit before re-binning. Long enough that
    /// a drag does not queue work, short enough that letting go feels immediate.
    static let scopeDebounce: Duration = .milliseconds(180)

    /// The long edge the TRACES are binned at, and nothing else.
    ///
    /// It used to size the clipping percentages as well, which is the whole of H2-01:
    /// a count taken off a box average is not a count. The counts moved to `ScopeTap`;
    /// this number now buys only what a proxy is legitimately for — the shape of four
    /// distributions and the cost of the vectorscope's cube roots.
    static let scopeProxyLongEdge: Int = 512

    /// The long edge the grid path asks the renderer for.
    ///
    /// The loupe measures the frame already on screen, which is as many pixels as the
    /// photographer is being shown. The grid has no frame to offer, so it commissions
    /// one — and it used to commission it at `scopeProxyLongEdge`, which made the
    /// clipping count a count of a 512 px picture of a 45 MP file. It now asks for the
    /// proxy this codebase already defines and docs/04:502 specifies: `ScopeProxy
    /// .targetPixels`, spent on a 3:2 frame. Other aspect ratios land near it.
    ///
    /// The traces are still binned at `scopeProxyLongEdge` from the result, so the
    /// extra pixels are spent entirely on the number that has to be a measurement.
    static let scopeMeasureLongEdge: Int =
        Int(sqrt(1.5 * Double(ScopeProxy.targetPixels)).rounded())

    /// Above this many pixels the tap is not materialized and the counts fall back to
    /// the traces' proxy — i.e. to the pre-H2-01 behaviour, which is wrong but bounded.
    ///
    /// It is a memory guard, not a resolution policy, and it is unreachable from either
    /// caller: a whole-frame settle is capped at `LoupeView.maxRenderLongEdge` (4096, so
    /// ≤ 16.8 MP even square), and a zoomed settle rasterizes only the visible region,
    /// which is the viewport in device pixels. 24 MP is a 6K viewport at 1:1 with room
    /// over it, and costs 96 MB of transient bytes at the ceiling.
    static let scopeTapPixelCeiling: Int = 24_000_000

    /// Measure the scopes off the frame the viewer already has.
    ///
    /// This is the fast path and, once the loupe is showing a photograph, the only one.
    /// It costs a downsample and some binning — no decode, no render, and no time on the
    /// serial render actor, which is what the proxy path was really spending.
    ///
    /// It also makes the instrument more truthful, which is the part worth arguing
    /// rather than asserting. The proxy was a SEPARATE render at 512 px: the same recipe
    /// through the same graph, but at a scale where every local operator — clarity,
    /// texture, the sharpening mask — behaves differently from the frame on screen. The
    /// histogram therefore described a picture nobody was looking at, and could disagree
    /// with the pixel under the readout. Measuring the delivered frame cannot.
    ///
    /// Bumping the generation is what stands the pending proxy task down: it is already
    /// gated on `scopeGeneration`, so a frame arriving before its debounce expires
    /// cancels it for free.
    @MainActor
    func measureScopes(fromViewerFrame image: CGImage, url: URL) {
        guard showHistogram || showScopes else { return }
        guard primarySelection?.id == url else { return }
        scopeGeneration &+= 1
        let generation = scopeGeneration
        let wantsScopes = showScopes
        // Read on the main actor, where it lives, and carried into the detached task —
        // this is the whole of H2-02's first half: `measure` used to hard-code
        // `.srgb255` four times and never see this value at all.
        let space = readoutSpace
        // THE PROOF IS IN THESE PIXELS, and that is the whole reason this is read here.
        //
        // `LoupeView` renders the viewer frame with `softProof: state.activeSoftProof`,
        // and the frame handed to this function IS that render. So with ⇧S on, the bins
        // describe the proofed rendition — which is defensible and arguably what a
        // photographer proofing a print wants — and with the gamut flag on (it defaults
        // to ON, `SoftProof.init`) they also describe `SoftProof.warningColor`, a flat
        // mid grey painted over every out-of-gamut pixel. That grey is an INSTRUMENT.
        // Binning it puts a spike at code 128 in all three channels and moves every
        // percentage the panel prints, and `RenderCoordinator.renderOneShot` states the
        // rule in its own comment — "a histogram with a gamut flag's flat grey binned
        // into it would be measuring the warning rather than the photograph".
        //
        // The frame cannot be un-proofed from here; what can be fixed from here is the
        // instrument's silence about it.
        let proof = activeSoftProof
        // AND HOW MUCH OF THE PHOTOGRAPH IT IS. A zoomed loupe renders the visible
        // rectangle and nothing else (`LoupeView.requestedRegion`), so above fit the
        // frame handed here is a corner of the picture — which the developed-thumbnail
        // cache four lines below the call site already refuses for exactly this reason
        // ("a zoomed settle covers a rectangle, not the frame"), while the scopes took
        // it and said nothing.
        //
        // `zoomLevel > 0` is the first clause of `regionActive` and the only one visible
        // from here; the rest (an overlay, a masking workspace, an armed crop) can each
        // stand the region ask down, so this errs toward disclosing. That is the right
        // direction to be wrong in: every one of those states also puts something
        // unusual in the frame, and the alternative is a silent corner. The exact answer
        // is `model.regionUnit != nil`, which only `LoupeView` can pass.
        let coverage: ScopeReadout.Provenance.Coverage =
            LoupeViewport.shared.zoom > 0 ? .visibleRegion : .wholeFrame
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { () -> ScopeData? in
                guard let buffer = AppState.buffer(
                    from: image, targetLongEdge: AppState.scopeProxyLongEdge)
                else { return nil }
                var measured = AppState.measure(buffer, includeScopes: wantsScopes,
                                                readout: space,
                                                tap: AppState.scopeTap(from: image),
                                                frame: .viewerFrame, coverage: coverage,
                                                proof: proof)
                if let waveform = measured.waveform {
                    measured.waveformImage = ScopeRaster.waveform(
                        waveform, peak: waveform.peak, tint: ScopeTint.neutral)
                }
                if let parade = measured.parade {
                    measured.paradeImages = ScopeRaster.parade(parade)
                }
                if let vectorscope = measured.vectorscope {
                    measured.vectorscopeImage = ScopeRaster.vectorscope(vectorscope)
                }
                return measured
            }.value
            guard let self, let data, self.scopeGeneration == generation else { return }
            self.scopes = data
        }
    }

    func scheduleScopeRefresh() {
        guard showHistogram || showScopes else { return }
        guard let photo = primarySelection else {
            scopes = nil
            return
        }
        // THE LOUPE FEEDS ITSELF. When a photograph is on screen its settled frame is
        // both cheaper and more truthful than a proxy rendered beside it
        // (`measureScopes(fromViewerFrame:)`), so this path is left to the surfaces
        // that have no frame to offer — the grid, and the moment before the first one
        // lands.
        //
        // WITH ONE EXCEPTION, and it is a bug this early return used to have. `S`
        // toggles the scopes panel, `scopesBecameVisible` calls this method, and this
        // line stood it down — but the loupe does not re-render on a panel toggle
        // either: `ViewerRenderKey` (RenderRequest.swift) carries the recipe, the size
        // and the region, not `showScopes`. So the render task does not re-run, nothing
        // calls `measureScopes`, and the panel that was just switched on reads "No
        // waveform yet" until the photographer happens to move a slider or page to
        // another photograph. The histogram never showed it because it is on by default
        // and every settle measures it.
        //
        // The exception is drawn as narrowly as it can be: fall through ONLY when a
        // measurement already exists (so the settle has landed and this one-shot is not
        // racing it), the scopes are on, and that measurement has no traces — which is
        // exactly the state the toggle creates and nothing else does. One ~1 MP render,
        // once; the next settle feeds the panel from the viewer's own frame again, and
        // says so, because the two carry different provenance.
        //
        // `scopes != nil` is the part that is deliberately conservative, and it leaves
        // one case uncovered: with the histogram ALSO off there has been no measurement
        // at all, so turning the scopes on still waits for the next settle. Covering it
        // would mean commissioning a render whenever no measurement exists, and the
        // moment that is true is the first frame of a photograph — where a second 1 MP
        // render competes with the settle on the serial render actor, which is the
        // second-decode cost docs/34 removed. The common case (the histogram is on by
        // default, so a measurement exists) is covered; that one is not, and this is
        // where it is written down rather than discovered.
        let scopesAskForWhatWeDoNotHave: Bool =
            showScopes && scopes != nil && scopes?.waveform == nil
        if viewMode == .loupe, !scopesAskForWhatWeDoNotHave { return }
        scopeGeneration &+= 1
        let generation = scopeGeneration
        let recipe = recipe(for: photo)
        let url = photo.id
        let wantsScopes = showScopes
        let space = readoutSpace

        let coordinator = renderCoordinator
        let strokes = strokeSets(for: recipe)

        Task { [weak self] in
            try? await Task.sleep(for: AppState.scopeDebounce)
            guard let self, self.scopeGeneration == generation else { return }

            // One-shot: the scopes must not claim a render ticket. Coalescing exists
            // to let the newest *viewer* frame win, and a measurement that joined that
            // race would cancel the frame the user is actually waiting on.
            //
            // NOT draft — for the tables, now that the stage gates are gone. A draft
            // may ride one-event-stale colour tables and mask rasters
            // (`allowStaleTables`/`MaskRasterCache`), which is right for a picture
            // chasing a hand and wrong for a measurement: an instrument reading a
            // stale table would disagree with the settle by exactly the amount the
            // user is asking it about.
            //
            // `scopeMeasureLongEdge`, not `scopeProxyLongEdge`: the clipping count is
            // taken off these pixels, so asking for 512 of them was asking the
            // question at a resolution that could not answer it.
            guard let result = await coordinator.renderOneShot(
                url: url, recipe: recipe,
                maxLongEdge: AppState.scopeMeasureLongEdge, draft: false,
                strokeSets: strokes) else { return }
            guard self.scopeGeneration == generation else { return }

            // `Task {}` inside a main-actor method inherits the main actor, and a
            // `nonisolated` function called from it still runs right here. Binning a
            // quarter of a million pixels on the main thread is a visible hitch every
            // time a slider settles, so the arithmetic gets its own thread explicitly.
            let data = await Task.detached(priority: .utility) { () -> ScopeData? in
                // The traces stay at the proxy long edge whatever the render's size:
                // the extra pixels were commissioned for the count, not for the shape.
                guard let buffer = AppState.buffer(
                    from: result.image, targetLongEdge: AppState.scopeProxyLongEdge)
                else { return nil }
                var measured = AppState.measure(buffer, includeScopes: wantsScopes,
                                                readout: space,
                                                tap: AppState.scopeTap(from: result.image),
                                                // `renderOneShot` takes no soft proof,
                                                // by its own argument — so this feed
                                                // measures the unproofed edit, and says
                                                // so, whatever ⇧S is doing.
                                                frame: .commissionedRender, proof: nil)
                // Rasterize HERE, once per measurement, so the view never does — the
                // traces used to be re-rasterized on every body evaluation.
                if let waveform = measured.waveform {
                    measured.waveformImage = ScopeRaster.waveform(
                        waveform, peak: waveform.peak, tint: ScopeTint.neutral)
                }
                if let parade = measured.parade {
                    measured.paradeImages = ScopeRaster.parade(parade)
                }
                if let vectorscope = measured.vectorscope {
                    measured.vectorscopeImage = ScopeRaster.vectorscope(vectorscope)
                }
                return measured
            }.value

            guard let data, self.scopeGeneration == generation else { return }
            self.scopes = data
        }
    }

    // MARK: - The readout space (H2-02)

    /// Resolve the picker's choice against what this tap can actually answer, and
    /// record the answer in the transform the bins carry — `HistogramView`'s readout
    /// line prints "binned in …" whenever `histogram.transform.space` disagrees with
    /// `state.readoutSpace`, so a refusal is disclosed rather than silent.
    ///
    /// **`.srgb255` is honoured**, and it is the only one of the three this tap can be
    /// asked. The frame is an 8-bit sRGB `CGImage`, so a channel's readout-linear value
    /// is exactly `TransferFunction.srgb.decode(code / 255)` — the round trip through
    /// the working primaries is the identity — and the clipping test is exact.
    ///
    /// **`.working` is refused**, and refusing it makes the instrument MORE accurate,
    /// not less, which is the part worth stating. Clipping is judged on the
    /// readout-linear triple, and the tap has already been clamped into the sRGB gamut:
    /// a pixel the working space genuinely blew — Rec.2020 linear (1.0, 0.2, 0.2) —
    /// leaves the encoder as sRGB (255, 89, 119) and reconstructs as working
    /// (0.668, 0.163, 0.190). In `.working` that reads NOT CLIPPED; in `.srgb255` it
    /// reads clipped, which is the truth about the frame. Honouring the picker here
    /// would replace a correct answer with a systematic under-report of every saturated
    /// clip — the same failure class as H2-01, one space over. It would also move the
    /// bins onto a LINEAR axis, which `HistogramView` is not built for: `level(atAxis:)`
    /// converts an sRGB-encoded axis position into working percent (a mid-grey would
    /// print 2.7 % instead of 18.0 %), and the five drag zones tile fixed windows on
    /// that same axis, so "Blacks" would cover the bottom 44 % of the graph.
    ///
    /// **`.outputProfile` is refused** because Develop focuses no export recipe — the
    /// loupe's own pixel readout says so in as many words ("no export profile chosen —
    /// showing sRGB", `ViewerOverlays.swift`) — and because pushing sRGB-clamped data
    /// into a WIDER space and reporting the result would answer "will this export
    /// clip?" with a confident no built out of data the clamp already threw away.
    ///
    /// The honest fix for both is upstream of this file: tap `PipelineRenderer`'s float
    /// image one line above `applyDither`, where the working values still exist. Until
    /// that lands the picker should stop offering the two spaces (`HistogramView.swift`
    /// builds it from `ReadoutSpace.allCases`); this function is what makes the refusal
    /// a decision with a reason instead of a hard-coded constant.
    nonisolated static func scopeTransform(requested: ReadoutSpace) -> ReadoutTransform {
        let honoured: ReadoutSpace
        switch requested {
        case .srgb255: honoured = .srgb255
        case .working: honoured = .srgb255          // refused, and why, above
        case .outputProfile: honoured = .srgb255    // refused, and why, above
        }
        return ReadoutTransform(space: honoured, working: .rec2020)
    }

    // MARK: - Measuring

    /// Binning is pure arithmetic over the proxy, so it runs off the main actor.
    ///
    /// `readout` is the picker's request and `tap` is the frame's own pixels. The
    /// traces come from `buffer`; the clipping counts come from `tap` when there is one,
    /// because a count taken off a box average is an area estimate wearing a count's
    /// units.
    nonisolated static func measure(_ buffer: ImageBuffer,
                                    includeScopes: Bool,
                                    readout: ReadoutSpace,
                                    tap: ScopeTap?,
                                    frame: ScopeReadout.Provenance.Frame,
                                    coverage: ScopeReadout.Provenance.Coverage
                                        = .wholeFrame,
                                    proof: SoftProof?) -> ScopeData {
        var data = ScopeData()
        let transform = AppState.scopeTransform(requested: readout)
        var histogram = Histogram.compute(buffer, bins: 256, transform: transform)
        var exact: Bool = false
        if let tap, let counts = AppState.clipCounts(in: tap) {
            histogram = AppState.redenominated(histogram, to: counts)
            exact = true
        }
        data.histogram = histogram
        data.provenance = AppState.provenance(frame: frame, coverage: coverage,
                                              proof: proof, exactCounts: exact)
        if includeScopes {
            // `traceColumns`, not 256 (W2/H2-04). `Waveform.compute` maps source column
            // x to `(x * columns) / width`, so a proxy narrower than the ask leaves
            // `columns − width` of them never written — 85 of 256 blank on a 1:3 crop,
            // 128 on a 1:4 — and they are true zeros, so the plate draws a picket fence
            // and the trace stops reading left-to-right as the picture does.
            let columns: Int = ScopeReadout.traceColumns(forWidth: buffer.width)
            data.waveform = Waveform.compute(buffer, channel: .luma, columns: columns,
                                             bins: 256, transform: transform)
            data.parade = Parade.compute(buffer, columns: columns, bins: 256,
                                         transform: transform)
            data.vectorscope = Vectorscope.compute(buffer, resolution: 192, zoom: 1,
                                                   space: transform.working)
        }
        return data
    }

    /// What the measurement is a measurement OF. Split out so both feeds build it the
    /// same way and a test can reach the rule: a proof is "instrument paint" when the
    /// gamut flag or the paper-white simulation is on, because those two put chrome into
    /// the pixels the binner walks — `PipelineRenderer.deliveredProof` strips exactly
    /// this pair on the way to a file, for the same reason.
    nonisolated static func provenance(frame: ScopeReadout.Provenance.Frame,
                                       coverage: ScopeReadout.Provenance.Coverage
                                           = .wholeFrame,
                                       proof: SoftProof?,
                                       exactCounts: Bool) -> ScopeReadout.Provenance {
        let on: Bool = proof?.enabled == true
        let paint: Bool = on
            && ((proof?.showGamutWarning ?? false) || (proof?.simulatePaperWhite ?? false))
        return ScopeReadout.Provenance(frame: frame, coverage: coverage, proofed: on,
                                       instrumentPaint: paint, exactCounts: exactCounts)
    }

    /// The traces' bins, re-denominated in the frame's own pixels, with the exact
    /// counts in place of the proxy's estimates.
    ///
    /// Every reader of a `Histogram` in this app takes a RATIO — `normalized(_:)`,
    /// `fraction(in:channel:)`, `clippedFraction(_:end:)` — so scaling all four
    /// channels' bins by one factor leaves each of them exactly where it was while
    /// moving the denominator onto the surface the clipping counts were measured on.
    /// `peak(_:)` becomes a count extrapolated to the frame; nothing in `Sources/`
    /// reads it.
    nonisolated static func redenominated(_ histogram: Histogram,
                                          to counts: ScopeClipCounts) -> Histogram {
        let binned: Int = histogram.sampleCount
        guard binned > 0, counts.samples > 0 else { return histogram }
        var scaled: [Int] = histogram.counts
        if counts.samples != binned {
            let k: Double = Double(counts.samples) / Double(binned)
            for i in 0..<scaled.count {
                scaled[i] = Int((Double(scaled[i]) * k).rounded())
            }
        }
        return Histogram(bins: histogram.bins,
                         counts: scaled,
                         sampleCount: counts.samples,
                         transform: histogram.transform,
                         clippedLowCounts: counts.low,
                         clippedHighCounts: counts.high)
    }

    /// The frame's own pixels, undownsampled, 8-bit sRGB RGBA.
    ///
    /// `noneSkipLast` rather than `premultipliedLast`: nothing here reads alpha, and a
    /// premultiply would let a non-opaque pixel darken the codes the counter tests.
    nonisolated static func scopeTap(from image: CGImage) -> ScopeTap? {
        let width: Int = image.width
        let height: Int = image.height
        guard width > 0, height > 0 else { return nil }
        guard width * height <= AppState.scopeTapPixelCeiling else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew: Bool = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            guard let context = CGContext(
                data: base, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            // 1:1, so there is no resampling to choose and nothing is averaged.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return ScopeTap(width: width, height: height, bytes: bytes)
    }

    /// Count, exactly, the pixels of `tap` at either end of the sRGB readout scale.
    ///
    /// THE POINT OF THE WHOLE FILE. One pass, no downsample, no float per channel:
    ///
    /// · **R, G, B** are counted through a 256-entry code histogram, which is exact
    ///   because the tap is 8 bits. The two clipping codes are DERIVED from
    ///   `Histogram.clipEpsilon` rather than assumed, so the threshold cannot drift
    ///   away from the binner's: `decode(c/255) ≥ 1 − ε` first happens at code 255
    ///   (254 decodes to 0.99110, and ε is 1/4096), and `≤ ε` last happens at code 0
    ///   (code 1 decodes to 0.000304 against ε = 0.000244).
    ///
    /// · **Luma** is the working-space luminance of the working triple, which is what
    ///   `Histogram.compute` bins into channel 3. Written as one weight vector over the
    ///   tap's own linear channels — `u = wᵀ·M`, derived here rather than asserted —
    ///   it is three table lookups and two adds per pixel, and it is the same number
    ///   the binner would have produced.
    ///
    /// Dither is the residual honesty problem and it is upstream: `PipelineRenderer`
    /// applies an 8×8 ordered plate at ±0.5 LSB before quantizing, so on a flat region
    /// pinned at display white up to half the cell's pixels are nudged off code 255 and
    /// out of this count. That is a real under-report of a few tens of percent on a
    /// large flat blown area; it is not the hundred percent this function removes.
    nonisolated static func clipCounts(in tap: ScopeTap) -> ScopeClipCounts? {
        let total: Int = tap.sampleCount
        guard total > 0, tap.bytes.count >= total * 4 else { return nil }

        let epsilon: Double = Histogram.clipEpsilon
        var linear = [Double](repeating: 0, count: 256)
        for c in 0..<256 {
            linear[c] = TransferFunction.srgb.decode(Double(c) / 255)
        }
        var highCode: Int = 256      // 256 = no code reaches the ceiling
        var lowCode: Int = -1        // -1 = no code reaches the floor
        for c in 0..<256 {
            if linear[c] <= epsilon { lowCode = c }
            if linear[c] >= 1 - epsilon && c < highCode { highCode = c }
        }

        // The luminance weights the TAP's channels carry: the histogram's luma channel
        // is `w · (M · x)` for working weights `w` and sRGB→working matrix `M`, which
        // is `(wᵀM) · x` on the tap's own linear triple. Computed, not quoted.
        let toWorking: Mat3 = RGBColorSpace.srgb.matrix(to: .rec2020)
        let w: RGB = RGBColorSpace.rec2020.luminanceWeights
        let m: [[Double]] = toWorking.m
        let ur: Double = w.r * m[0][0] + w.g * m[1][0] + w.b * m[2][0]
        let ug: Double = w.r * m[0][1] + w.g * m[1][1] + w.b * m[2][1]
        let ub: Double = w.r * m[0][2] + w.g * m[1][2] + w.b * m[2][2]
        var wr = [Double](repeating: 0, count: 256)
        var wg = [Double](repeating: 0, count: 256)
        var wb = [Double](repeating: 0, count: 256)
        for c in 0..<256 {
            wr[c] = ur * linear[c]
            wg[c] = ug * linear[c]
            wb[c] = ub * linear[c]
        }

        // NO 256-BIN CODE HISTOGRAMS. They were built per channel and then read at
        // exactly two indices — everything at or below `lowCode`, everything at or above
        // `highCode` — so 254 of every 256 bins were written and discarded. The
        // derivation above is what makes the direct comparison legitimate: the sRGB TRC
        // is monotone, so `decode(c/255) <= epsilon` and `>= 1 - epsilon` are each true
        // for a PREFIX and a SUFFIX of the code range and a threshold code exists. That
        // property is asserted, over all 256 codes, in `ScopeMathTests
        // .testTheClippingPredicatesAreMonotoneInTheCode` — without it this loop would
        // be a different measurement rather than a cheaper one.
        //
        // WHAT THIS IS AND IS NOT WORTH, measured rather than assumed. Both forms were
        // benchmarked at 1, 6 and 16 MP, three runs each: they are the same speed, 1-4 %
        // apart, which is inside this machine's noise. (An early run said 17-19 %; the
        // box was throttled, and repeating it on a settled machine did not reproduce it.
        // The number is recorded here because a comment quoting a speed-up that is not
        // there is the defect this file keeps finding elsewhere.) What the change does
        // buy is smaller and real: three 256-entry accumulators and their scattered
        // per-pixel writes are gone, 254 of every 256 bins were written and discarded,
        // and the loop now says what it measures. The pass itself is the expensive part
        // either way — about 4.6 ms per megapixel here, so ~28 ms on a 6 MP viewer frame
        // and ~78 ms at the 16.8 MP whole-frame ceiling, on every settle.
        //
        // `lowCode` is −1 and `highCode` 256 when no code reaches an end; both
        // comparisons are then simply never true, which is the answer.
        var lowR: Int = 0, lowG: Int = 0, lowB: Int = 0
        var highR: Int = 0, highG: Int = 0, highB: Int = 0
        var lumaLow: Int = 0
        var lumaHigh: Int = 0
        let bytes: [UInt8] = tap.bytes
        var p: Int = 0
        while p < total {
            let i: Int = p * 4
            let r: Int = Int(bytes[i])
            let g: Int = Int(bytes[i + 1])
            let b: Int = Int(bytes[i + 2])
            if r <= lowCode { lowR += 1 }
            if r >= highCode { highR += 1 }
            if g <= lowCode { lowG += 1 }
            if g >= highCode { highG += 1 }
            if b <= lowCode { lowB += 1 }
            if b >= highCode { highB += 1 }
            let y: Double = wr[r] + wg[g] + wb[b]
            if y <= epsilon { lumaLow += 1 }
            if y >= 1 - epsilon { lumaHigh += 1 }
            p += 1
        }

        var low = [Int](repeating: 0, count: Histogram.channelCount)
        var high = [Int](repeating: 0, count: Histogram.channelCount)
        low[0] = lowR; low[1] = lowG; low[2] = lowB; low[3] = lumaLow
        high[0] = highR; high[1] = highG; high[2] = highB; high[3] = lumaHigh
        return ScopeClipCounts(low: low, high: high, samples: total)
    }

    /// The rendered proxy arrives as an sRGB-encoded CGImage; linearize it so the
    /// scopes measure light rather than code values.
    /// `targetLongEdge` downsamples on the way in, so the binner always walks about the
    /// same number of samples whatever it was handed.
    ///
    /// It exists because the scopes stopped rendering their own proxy. They used to ask
    /// the coordinator for a fresh 512 px render, which — because `DecodeKey` carries
    /// the scale factor — was a SECOND FULL READ of the RAW for every photograph, on
    /// top of the one the picture needed. On the owner's offload drive that is about
    /// 2.4 seconds; on his SD card about 0.65. It also occupied the serial render actor,
    /// so it could delay the NEXT photograph as well as this one.
    ///
    /// Now they measure the frame already on screen. `CGContext.draw` into a smaller
    /// context AVERAGES, which is right for a distribution and is why the buffer this
    /// returns feeds the TRACES only. It is wrong for a count, and the counts no longer
    /// come from here — see `clipCounts(in:)`.
    nonisolated static func buffer(from image: CGImage,
                                   targetLongEdge: Int = 0) -> ImageBuffer? {
        var width = image.width
        var height = image.height
        guard width > 0, height > 0 else { return nil }
        if targetLongEdge > 0, Swift.max(width, height) > targetLongEdge {
            let k = Double(targetLongEdge) / Double(Swift.max(width, height))
            width = Swift.max(Int((Double(width) * k).rounded()), 1)
            height = Swift.max(Int((Double(height) * k).rounded()), 1)
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: info) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var pixels = [Float](repeating: 1, count: width * height * 4)
        let toWorking = RGBColorSpace.srgb.matrix(to: .rec2020)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let encoded = RGB(Double(bytes[i]) / 255,
                              Double(bytes[i + 1]) / 255,
                              Double(bytes[i + 2]) / 255)
            let linear = toWorking.apply(TransferFunction.srgb.decode(encoded))
            pixels[i] = Float(linear.r)
            pixels[i + 1] = Float(linear.g)
            pixels[i + 2] = Float(linear.b)
            pixels[i + 3] = 1
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }
}

#endif

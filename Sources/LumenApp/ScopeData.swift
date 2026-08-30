// ScopeData.swift
// The measurement feed behind the histogram and the scopes.
//
// Scopes describe the picture you are looking at, so they are binned from a proxy of
// the actual composite rather than from the raw file (docs/14 §5.9). The proxy is
// small on purpose: a ~512 px render is more than enough for 256 bins, and it keeps
// the whole refresh far below the cost of the frame the user is already waiting for.
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
}

extension AppState {

    /// How long the app waits after the last edit before re-binning. Long enough that
    /// a drag does not queue work, short enough that letting go feels immediate.
    static let scopeDebounce: Duration = .milliseconds(180)
    static let scopeProxyLongEdge: Int = 512

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
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { () -> ScopeData? in
                guard let buffer = AppState.buffer(
                    from: image, targetLongEdge: AppState.scopeProxyLongEdge)
                else { return nil }
                var measured = AppState.measure(buffer, includeScopes: wantsScopes)
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
        if viewMode == .loupe { return }
        scopeGeneration &+= 1
        let generation = scopeGeneration
        let recipe = recipe(for: photo)
        let url = photo.id
        let wantsScopes = showScopes

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
            // user is asking it about. The proxy is 512 px precisely so the exact
            // path is affordable here.
            guard let result = await coordinator.renderOneShot(
                url: url, recipe: recipe,
                maxLongEdge: AppState.scopeProxyLongEdge, draft: false,
                strokeSets: strokes) else { return }
            guard self.scopeGeneration == generation else { return }

            // `Task {}` inside a main-actor method inherits the main actor, and a
            // `nonisolated` function called from it still runs right here. Binning a
            // quarter of a million pixels on the main thread is a visible hitch every
            // time a slider settles, so the arithmetic gets its own thread explicitly.
            let data = await Task.detached(priority: .utility) { () -> ScopeData? in
                guard let buffer = AppState.buffer(from: result.image) else { return nil }
                var measured = AppState.measure(buffer, includeScopes: wantsScopes)
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

    /// Binning is pure arithmetic over the proxy, so it runs off the main actor.
    nonisolated static func measure(_ buffer: ImageBuffer, includeScopes: Bool) -> ScopeData {
        var data = ScopeData()
        data.histogram = Histogram.compute(buffer, bins: 256, space: .rec2020,
                                           readout: .srgb255)
        if includeScopes {
            data.waveform = Waveform.compute(buffer, columns: 256, bins: 256,
                                             space: .rec2020, readout: .srgb255)
            data.parade = Parade.compute(buffer, columns: 256, bins: 256,
                                         space: .rec2020, readout: .srgb255)
            data.vectorscope = Vectorscope.compute(buffer, resolution: 192, zoom: 1,
                                                   space: .rec2020)
        }
        return data
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
    /// Now they measure the frame already on screen. Downsampling it here to the same
    /// long edge the proxy used keeps the sample count — and therefore the bin
    /// populations and the clipping percentages — comparable with what the instrument
    /// reported before, which matters more than the few milliseconds a stride would
    /// have saved: `CGContext.draw` into a smaller context AVERAGES, exactly as
    /// rendering at 512 did, where a stride would have sampled and quietly changed
    /// every number the panel prints.
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

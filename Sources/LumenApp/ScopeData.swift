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

struct ScopeData: Sendable {
    var histogram: Histogram?
    var waveform: Waveform?
    var parade: Parade?
    var vectorscope: Vectorscope?
}

extension AppState {

    /// How long the app waits after the last edit before re-binning. Long enough that
    /// a drag does not queue work, short enough that letting go feels immediate.
    static let scopeDebounce: Duration = .milliseconds(180)
    static let scopeProxyLongEdge: Int = 512

    func scheduleScopeRefresh() {
        guard showHistogram || showScopes else { return }
        guard let photo = primarySelection else {
            scopes = nil
            return
        }
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
            // NOT draft. Draft mode exists so a full-resolution interactive frame can
            // skip the expensive spatial stages, and it skips exactly the ones a
            // photographer watches the scopes for: presence (texture, clarity,
            // dehaze), every local adjustment, creative sharpening, halation and
            // grain — and `makeGraph` returns an empty graph outright, so no mask is
            // even rasterized. Measuring that render meant dragging Clarity changed the
            // picture without moving the histogram by one bin, while this file's own
            // header promised the scopes describe the picture you are looking at.
            //
            // The proxy is 512 px precisely so the full-quality path is affordable
            // here; skipping stages to save time on a 512 px frame was buying nothing
            // and paying for it with a wrong answer.
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
                return AppState.measure(buffer, includeScopes: wantsScopes)
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
    nonisolated static func buffer(from image: CGImage) -> ImageBuffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
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

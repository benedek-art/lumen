// SharpenMaskView.swift
// ⌥-drag on Sharpening's Masking: the viewer shows the edge mask, white where the
// sharpening lands and black where Masking holds it off — Lightroom's Alt-drag view.
//
// A VIEW, built from the sampler's display bytes the way `SpotVisualizationView` is,
// and opaque so it replaces the picture while the drag lasts. The mask itself is
// `SharpenStage.maskPreview`, the render's own knees and edge measure applied to the
// displayed pixels (that function says how close that is). Nothing here reaches the
// recipe or a render.

#if os(macOS)

import CoreGraphics
import Foundation
import LumenCore
import SwiftUI

struct SharpenMaskView: View {

    let sampler: PixelSampler
    let masking: Double

    @State private var overlay: CGImage?
    @State private var buildTask: Task<CGImage?, Never>?

    private struct BuildKey: Equatable {
        let sampler: UUID
        let masking: Double
    }

    var body: some View {
        Group {
            if let overlay {
                Image(decorative: overlay, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .task(id: BuildKey(sampler: sampler.id, masking: masking)) {
            await rebuild()
        }
    }

    @MainActor
    private func rebuild() async {
        let source = sampler
        let wanted = masking
        buildTask?.cancel()
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            SharpenMaskView.build(sampler: source, masking: wanted)
        }
        buildTask = task
        let built = await task.value
        guard !Task.isCancelled else { return }
        if let built { overlay = built } else if !task.isCancelled { overlay = nil }
    }

    nonisolated static func build(sampler: PixelSampler, masking: Double) -> CGImage? {
        let width = sampler.width, height = sampler.height
        if Task.isCancelled { return nil }
        // Masking is 0…100 in the recipe and 0…1 in the stage.
        let grey = SharpenStage.maskPreview(sRGB: sampler.bytes, width: width,
                                            height: height, masking: masking / 100)
        if Task.isCancelled { return nil }
        guard grey.count == width * height,
              let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let provider = CGDataProvider(data: Data(grey) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }
}

#endif

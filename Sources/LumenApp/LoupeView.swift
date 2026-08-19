// LoupeView.swift
// Phase-1 loupe: renders the current photo through the real pipeline (same graph as
// export — docs/13) with draft decode during slider interaction, full quality when
// settled. Falls back to the embedded preview when a file can't be RAW-decoded
// (docs/13 safety posture) with an honest badge (docs/10 handoff honesty).
//
// The Metal-layer zoomable loupe (load-bearing for 1:1 and EDR — docs/16 Phase 1)
// replaces this SwiftUI Image once the skeleton runs; the render plumbing stays.

#if os(macOS)

import LumenCore
import LumenPipeline
import SwiftUI

struct LoupeView: View {
    @EnvironmentObject var state: AppState
    let photo: PhotoItem

    @State private var rendered: CGImage?
    @State private var isEmbeddedFallback = false
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let rendered {
                    Image(decorative: rendered, scale: 1.0)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView("Rendering…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isEmbeddedFallback {
                Text("EMBEDDED PREVIEW")
                    .font(.caption2.bold())
                    .padding(4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.yellow)
                    .padding(8)
            }
        }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: state.selectPrevious()
            case .right: state.selectNext()
            default: break
            }
        }
        .task(id: renderKey) { await render() }
    }

    /// Re-render whenever the photo or its recipe changes.
    private var renderKey: String {
        let fp = (try? RecipeFingerprint.fingerprint(state.recipe(for: photo))) ?? "?"
        return photo.id.absoluteString + "|" + fp
    }

    @MainActor
    private func render() async {
        let url = photo.id
        let recipe = state.recipe(for: photo)
        let renderer = RenderCoordinator.shared

        // Show the embedded preview instantly while the real render happens (Law 11:
        // something honest within a frame beats a spinner).
        if rendered == nil, let thumb = await state.thumbnails.load(url: url, maxPixel: 1600),
           let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            if !Task.isCancelled && rendered == nil {
                rendered = cg
                isEmbeddedFallback = true
            }
        }

        let result = await renderer.render(url: url, recipe: recipe, maxLongEdge: 2560)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let cg):
            rendered = cg
            isEmbeddedFallback = false
        case .failure:
            // keep the embedded preview + badge; never crash on an undecodable file
            isEmbeddedFallback = rendered != nil
        }
    }
}

/// Serializes renders off the main actor and caches open RAW sources per URL.
/// Becomes the render actor of docs/13's concurrency model in Phase 2.
actor RenderCoordinator {
    static let shared = RenderCoordinator()

    private let renderer = PipelineRenderer()
    private var sources: [URL: AppleRawSource] = [:]

    func render(url: URL, recipe: Recipe, maxLongEdge: Int) -> Result<CGImage, Error> {
        do {
            let source: AppleRawSource
            if let cached = sources[url] {
                source = cached
            } else {
                source = try AppleRawSource(url: url)
                if sources.count > 8 { sources.removeAll() } // crude LRU; Phase 2 replaces
                sources[url] = source
            }
            let cg = try renderer.renderPreview(
                source: source, recipe: recipe, maxLongEdge: maxLongEdge, draft: true)
            return .success(cg)
        } catch {
            return .failure(error)
        }
    }

    func export(url: URL, recipe: Recipe, to destination: URL,
                settings: ExportSettings) -> Result<Void, Error> {
        do {
            let source = try sources[url] ?? AppleRawSource(url: url)
            sources[url] = source
            try renderer.exportJPEG(source: source, recipe: recipe,
                                    to: destination, settings: settings)
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}

#endif

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

    /// Everything that should trigger a re-render, cheap to compare (Recipe is
    /// Equatable — no fingerprint hashing on the main actor per body pass).
    private struct RenderKey: Equatable {
        let url: URL
        let recipe: Recipe
    }

    @State private var rendered: CGImage?
    @State private var renderedFor: URL?      // which photo `rendered` belongs to
    @State private var isEmbeddedFallback = false
    @State private var isUnreadable = false
    @State private var lastRenderError: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let rendered, renderedFor == photo.id {
                    Image(decorative: rendered, scale: 1.0)
                        .resizable()
                        .scaledToFit()
                } else if isUnreadable {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                        Text("Can't read \(photo.filename)")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView("Rendering…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                if isEmbeddedFallback && renderedFor == photo.id {
                    Text("EMBEDDED PREVIEW")
                        .font(.caption2.bold())
                        .padding(4)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.yellow)
                }
                if let lastRenderError {
                    // Honest errors (docs/12): name the cause, never fail silently.
                    Text(lastRenderError)
                        .font(.caption2)
                        .padding(4)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.red)
                }
            }
            .padding(8)
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onMoveCommand { direction in
            switch direction {
            case .left: state.selectPrevious()
            case .right: state.selectNext()
            default: break
            }
        }
        .task(id: RenderKey(url: photo.id, recipe: state.recipe(for: photo))) {
            await render()
        }
    }

    @MainActor
    private func render() async {
        let url = photo.id
        let recipe = state.recipe(for: photo)

        // New photo: drop the previous photo's pixels and give THIS photo the
        // instant embedded-preview path (Law 11) before the real render lands.
        if renderedFor != url {
            rendered = nil
            renderedFor = nil
            isEmbeddedFallback = false
            isUnreadable = false
            lastRenderError = nil
            if let thumb = await state.thumbnails.load(url: url, maxPixel: 1600),
               let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                guard !Task.isCancelled else { return }
                rendered = cg
                renderedFor = url
                isEmbeddedFallback = true
            }
        }

        // Two-tier render (docs/12 progressive-refine): a cheap low-res pass lands
        // immediately so slider drags feel live, then a settle debounce dispatches
        // one quality pass per pause — stale requests die at the coordinator.
        let fast = await RenderCoordinator.shared.render(
            url: url, recipe: recipe, maxLongEdge: 1024)
        guard !Task.isCancelled else { return }
        if case .success(let cg) = fast {
            rendered = cg
            renderedFor = url
            isEmbeddedFallback = false
            lastRenderError = nil
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }

        let result = await RenderCoordinator.shared.render(
            url: url, recipe: recipe, maxLongEdge: 2560)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let cg):
            rendered = cg
            renderedFor = url
            isEmbeddedFallback = false
            isUnreadable = false
            lastRenderError = nil
        case .failure(let error):
            if error is CancellationError { return }  // superseded, not failed
            let message = "RAW render failed: \(error)"
            print("Lumen: \(message) [\(url.lastPathComponent)]")
            lastRenderError = message
            // Keep the embedded preview + badge when we have one; otherwise say so
            // honestly instead of spinning forever (docs/12: honest errors).
            if renderedFor == url, rendered != nil {
                isEmbeddedFallback = true
            } else {
                isUnreadable = true
            }
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
        // Actor calls run in the caller's task context: when a slider drag has
        // already superseded this request, its task is cancelled — bail before the
        // expensive decode instead of burying the queue in stale renders.
        if Task.isCancelled { return .failure(CancellationError()) }
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

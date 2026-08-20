// CompareView.swift
// The two compare canvases (docs/12 §B1: `C` and `N` are views of one context, not
// modules): 2-up compare with synced zoom and pan, and the N-up survey grid. Both are
// driven by `AppState.selectedPhotos` — selecting is how you populate a comparison,
// which is why neither view has an "add to compare" ceremony of its own.
//
// Zoom and pan sync as an image-normalized centre point rather than as a pixel offset,
// so two frames of different pixel dimensions still hold the same part of the picture
// under the same part of the window. Every pane renders through `PhotoRenderModel`, the
// same two-tier draft-then-quality driver the loupe uses — no second preview system.

#if os(macOS)

import AppKit
import CoreGraphics
import Foundation
import LumenCore
import SwiftUI

// MARK: - Layout

enum CompareLayout: String, CaseIterable, Identifiable, Sendable {
    /// `C` — two frames, synced.
    case twoUp
    /// `N` — as many frames as are selected, each fit.
    case survey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twoUp: return "Compare"
        case .survey: return "Survey"
        }
    }
}

/// The shared viewport for a 2-up compare: one ratio and one image-normalized centre,
/// so both panes move together whatever their pixel dimensions.
final class CompareSync: ObservableObject {

    /// 0 = fit, otherwise a ratio of image pixels to device pixels.
    @Published var zoom: Double = 0
    /// The point of the picture held at the centre of each pane, in unit coordinates
    /// with the origin at the top-left.
    @Published var center: CGPoint = CGPoint(x: 0.5, y: 0.5)

    func fit() {
        zoom = 0
        center = CGPoint(x: 0.5, y: 0.5)
    }

    func setZoom(_ ratio: Double, at unitPoint: CGPoint?) {
        let clamped: Double = ratio.isFinite ? Swift.max(0, Swift.min(ratio, 16)) : 0
        zoom = clamped
        if clamped <= 0 {
            center = CGPoint(x: 0.5, y: 0.5)
        } else if let unitPoint {
            center = unitPoint
        }
    }

    func toggleZoom(at unitPoint: CGPoint?) {
        if zoom > 0 {
            fit()
        } else {
            setZoom(1, at: unitPoint)
        }
    }
}

// MARK: - Compare

struct CompareView: View {

    @EnvironmentObject var state: AppState
    var layout: CompareLayout = .twoUp

    @StateObject private var sync: CompareSync = CompareSync()

    var body: some View {
        Group {
            if comparisonSet.isEmpty {
                empty
            } else if layout == .survey {
                survey
            } else {
                twoUp
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Lumen.viewerBackground)
    }

    /// What is being compared. A real multi-selection is the answer; with one photo
    /// selected the obvious second frame is its neighbour, which is what "compare this
    /// to the next one" means during a cull.
    private var comparisonSet: [PhotoItem] {
        let selected = state.selectedPhotos
        if selected.count >= 2 { return selected }
        guard let primary = state.primarySelection else { return selected }
        let all = state.photos
        if let index = all.firstIndex(of: primary), index + 1 < all.count {
            return [primary, all[index + 1]]
        }
        return [primary]
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 34))
            Text("Select two or more photos to compare")
                .font(.system(size: 12))
        }
        .foregroundStyle(Lumen.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 2-up

    private var twoUp: some View {
        let pair = Array(comparisonSet.prefix(2))
        return HStack(spacing: 1) {
            ForEach(pair) { photo in
                ComparePane(photo: photo,
                            sync: sync,
                            isPrimary: photo.id == state.primarySelection?.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture(count: 2) { state.primarySelection = photo }
            }
            if pair.count == 1 {
                VStack(spacing: 6) {
                    Image(systemName: "plus.rectangle")
                        .font(.system(size: 26))
                    Text("Select a second photo")
                        .font(.system(size: 11))
                }
                .foregroundStyle(Lumen.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Lumen.viewerBackground)
            }
        }
        .overlay(alignment: .topTrailing) {
            LumenBadge(text: LoupeZoom.label(sync.zoom))
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    // MARK: N-up survey

    private var survey: some View {
        GeometryReader { geometry in
            let count = Swift.max(comparisonSet.count, 1)
            let minimum = surveyCellMinimum(count: count, in: geometry.size)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 6)],
                          spacing: 6) {
                    ForEach(comparisonSet) { photo in
                        SurveyCell(photo: photo,
                                   isPrimary: photo.id == state.primarySelection?.id)
                            .frame(height: minimum * 0.78)
                            .onTapGesture { state.primarySelection = photo }
                    }
                }
                .padding(6)
            }
        }
    }

    /// Aim for roughly square tiles that use the pane without producing one enormous
    /// cell for a survey of two. Guarded against a zero-sized container.
    private func surveyCellMinimum(count: Int, in size: CGSize) -> CGFloat {
        let width = size.width > 0 ? size.width : 900
        let columns = CGFloat(Swift.max(1, Int(Double(count).squareRoot().rounded(.up))))
        let candidate = (width - 12) / columns - 6
        return Swift.min(Swift.max(candidate, 160), 520)
    }
}

// MARK: - Synced pane

/// One frame of a 2-up compare. Reads its ratio and centre from the shared `CompareSync`
/// and writes both back when dragged or clicked, so the other pane follows within the
/// same frame.
private struct ComparePane: View {

    @EnvironmentObject var state: AppState
    let photo: PhotoItem
    @ObservedObject var sync: CompareSync
    let isPrimary: Bool

    @StateObject private var model: PhotoRenderModel = PhotoRenderModel()
    @Environment(\.displayScale) private var displayScale: CGFloat
    @State private var dragStartCenter: CGPoint?

    private struct RenderKey: Equatable {
        let url: URL
        let recipe: Recipe
        let longEdge: Int
    }

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            let longEdge: Int = requestedLongEdge(container: container)
            ZStack(alignment: .bottomLeading) {
                Lumen.viewerBackground

                if let cg = model.image, model.imageURL == photo.id {
                    plate(cg, container: container)
                } else if model.isUnreadable {
                    Text("Can't read \(photo.filename)")
                        .font(.system(size: 11))
                        .foregroundStyle(Lumen.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if model.usedEmbeddedPreview, model.imageURL == photo.id {
                        LumenBadge(text: "EMBEDDED PREVIEW", emphasized: true)
                    }
                    if let note = model.note {
                        LumenBadge(text: note, emphasized: true)
                    }
                    LumenBadge(text: photo.filename)
                }
                .padding(8)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(container: container))
            .overlay {
                Rectangle()
                    .strokeBorder(isPrimary ? Lumen.fillColor : Lumen.separator,
                                  lineWidth: isPrimary ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .task(id: RenderKey(url: photo.id,
                                recipe: state.recipe(for: photo),
                                longEdge: longEdge)) {
                await render(longEdge: longEdge)
            }
        }
    }

    @MainActor
    private func render(longEdge: Int) async {
        await model.load(url: photo.id,
                         recipe: state.recipe(for: photo),
                         coordinator: state.renderCoordinator,
                         thumbnails: state.thumbnails,
                         draftLongEdge: LoupeView.draftLongEdge,
                         fullLongEdge: longEdge)
    }

    // MARK: Geometry

    private func ratio(for cg: CGImage, container: CGSize) -> Double {
        if sync.zoom > 0 { return sync.zoom }
        return LoupeGeometry.fitRatio(imageWidth: cg.width, imageHeight: cg.height,
                                      container: container, displayScale: displayScale)
    }

    /// Pan that puts the shared centre point at the centre of this pane, clamped so the
    /// image can never be dragged off screen.
    private func offset(for cg: CGImage, container: CGSize, drawn: CGSize) -> CGSize {
        let raw = CGSize(width: -(sync.center.x - 0.5) * drawn.width,
                         height: -(sync.center.y - 0.5) * drawn.height)
        return LoupeGeometry.clampPan(raw, container: container, drawn: drawn)
    }

    private func plate(_ cg: CGImage, container: CGSize) -> some View {
        let r = ratio(for: cg, container: container)
        let drawn = LoupeGeometry.drawnSize(imageWidth: cg.width, imageHeight: cg.height,
                                            ratio: r, displayScale: displayScale)
        return Image(decorative: cg, scale: 1, orientation: .up)
            .resizable()
            .interpolation(r >= 1 ? .none : .high)
            .antialiased(r < 1)
            .frame(width: drawn.width, height: drawn.height)
            .offset(offset(for: cg, container: container, drawn: drawn))
            .frame(width: container.width, height: container.height)
            .clipped()
    }

    private func dragGesture(container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let cg = model.image else { return }
                let r = ratio(for: cg, container: container)
                let drawn = LoupeGeometry.drawnSize(imageWidth: cg.width,
                                                    imageHeight: cg.height,
                                                    ratio: r, displayScale: displayScale)
                guard drawn.width > 0, drawn.height > 0 else { return }
                guard drawn.width > container.width || drawn.height > container.height else {
                    return
                }
                let base = dragStartCenter ?? sync.center
                if dragStartCenter == nil { dragStartCenter = base }
                let moved = CGSize(width: -(base.x - 0.5) * drawn.width + value.translation.width,
                                   height: -(base.y - 0.5) * drawn.height + value.translation.height)
                let clamped = LoupeGeometry.clampPan(moved, container: container, drawn: drawn)
                sync.center = CGPoint(x: 0.5 - clamped.width / drawn.width,
                                      y: 0.5 - clamped.height / drawn.height)
            }
            .onEnded { value in
                dragStartCenter = nil
                let travel = abs(value.translation.width) + abs(value.translation.height)
                guard travel < 3 else { return }
                guard let cg = model.image else {
                    sync.toggleZoom(at: nil)
                    return
                }
                let r = ratio(for: cg, container: container)
                let drawn = LoupeGeometry.drawnSize(imageWidth: cg.width,
                                                    imageHeight: cg.height,
                                                    ratio: r, displayScale: displayScale)
                let pan = offset(for: cg, container: container, drawn: drawn)
                let unit = LoupeGeometry.imageUnitPoint(value.location, container: container,
                                                        drawn: drawn, pan: pan)
                sync.toggleZoom(at: unit)
            }
    }

    private func requestedLongEdge(container: CGSize) -> Int {
        if sync.zoom > 0 { return LoupeView.maxRenderLongEdge }
        let scale = Double(Swift.max(displayScale, 1))
        let longEdge = Double(Swift.max(container.width, container.height)) * scale
        guard longEdge.isFinite, longEdge > 0 else { return 1024 }
        let bucket = Int((longEdge / 256).rounded(.up)) * 256
        return Swift.min(Swift.max(bucket, 640), LoupeView.maxRenderLongEdge)
    }
}

// MARK: - Survey cell

/// One frame of the N-up survey: always fit, no zoom, and a reject affordance so the
/// survey narrows the way culling actually works — you take frames out until the keeper
/// is the one left.
private struct SurveyCell: View {

    @EnvironmentObject var state: AppState
    let photo: PhotoItem
    let isPrimary: Bool

    @StateObject private var model: PhotoRenderModel = PhotoRenderModel()
    @Environment(\.displayScale) private var displayScale: CGFloat

    private struct RenderKey: Equatable {
        let url: URL
        let recipe: Recipe
        let longEdge: Int
    }

    var body: some View {
        GeometryReader { geometry in
            let container = geometry.size
            let longEdge: Int = requestedLongEdge(container: container)
            ZStack(alignment: .bottomLeading) {
                Lumen.viewerBackground

                if let cg = model.image, model.imageURL == photo.id {
                    Image(decorative: cg, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.isUnreadable {
                    Text("Can't read \(photo.filename)")
                        .font(.system(size: 10))
                        .foregroundStyle(Lumen.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(alignment: .leading, spacing: 3) {
                    if model.usedEmbeddedPreview, model.imageURL == photo.id {
                        LumenBadge(text: "EMBEDDED PREVIEW", emphasized: true)
                    }
                    LumenBadge(text: photo.filename)
                }
                .padding(6)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(alignment: .topTrailing) {
                Button {
                    state.selection.remove(photo.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(4)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .foregroundStyle(Lumen.primaryText)
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Remove \(photo.filename) from the survey")
            }
            .overlay {
                Rectangle()
                    .strokeBorder(isPrimary ? Lumen.fillColor : Lumen.separator,
                                  lineWidth: isPrimary ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .task(id: RenderKey(url: photo.id,
                                recipe: state.recipe(for: photo),
                                longEdge: longEdge)) {
                await render(longEdge: longEdge)
            }
        }
    }

    @MainActor
    private func render(longEdge: Int) async {
        await model.load(url: photo.id,
                         recipe: state.recipe(for: photo),
                         coordinator: state.renderCoordinator,
                         thumbnails: state.thumbnails,
                         draftLongEdge: 512,
                         fullLongEdge: longEdge)
    }

    private func requestedLongEdge(container: CGSize) -> Int {
        let scale = Double(Swift.max(displayScale, 1))
        let longEdge = Double(Swift.max(container.width, container.height)) * scale
        guard longEdge.isFinite, longEdge > 0 else { return 640 }
        let bucket = Int((longEdge / 256).rounded(.up)) * 256
        return Swift.min(Swift.max(bucket, 512), 2048)
    }
}

#endif

// ZoomRegion.swift
// Which part of the photograph a zoomed render should actually pay for.
//
// The owner's fifth-round screenshots, one commit after zoom went native: the SETTLE
// was finally the sensor's pixels, and then touching Highlights flashed a 1024 px
// whole-frame draft blown up twenty-three times — "there is still a slight blur
// effect… a drastic difference". The mechanism is that every render while zoomed was
// still a WHOLE-FRAME render: the draft ladder budgets a full frame against the drag
// deadline, so it steps to the low rungs precisely when the magnification makes those
// rungs unwatchable, and nearly every pixel it renders is off screen. The same
// whole-frame habit made the pinch clunky — a 33 MP plate re-laid-out per gesture
// frame to show a viewport of a few million pixels.
//
// So a zoomed render asks for a REGION: the visible rectangle plus a margin, at full
// sharpness, for viewport-proportional cost. The graph is lazy — rasterizing a
// sub-rect evaluates only that sub-rect (plus each kernel's own neighbourhood) — so
// sharp-during-the-drag stops being a budget problem and becomes a geometry one.
// This file is the geometry: pure arithmetic, in LumenCore, where it is tested.
//
// The unit space is the DELIVERED frame (post-crop, post-straighten), origin top-left,
// exactly `LoupeGeometry.imageUnitPoint`'s convention — the pipeline flips to Core
// Image's bottom-up extent at the one line that rasterizes.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum ZoomRegion {

    /// Extra frame rendered beyond each visible edge, as a fraction of the viewport —
    /// what lets a small pan redraw pixels that already exist instead of re-rendering.
    /// A quarter viewport per side is (1.5)² = 2.25× the visible pixels: at a laptop
    /// viewport that is a 2048-class render through the full graph, which the draft
    /// budget measured at 8.5 ms — affordable per drag event without any ladder.
    public static let marginFraction: Double = 0.25

    /// Region edges snap OUT to this grid, so a drifting pan mints a new region — and
    /// a new render key — only when it actually leaves the margin, not per point.
    public static let grid: Double = 1.0 / 32.0

    /// The unit rectangle of the full drawn frame a zoomed render should produce, or
    /// nil when (margins included) the whole frame is visible — whole-frame rendering
    /// serves that case, and its ladder cost model is the right one there.
    public static func requestUnit(container: CGSize, drawnFull: CGSize,
                                   pan: CGSize) -> CGRect? {
        let dw = Double(drawnFull.width)
        let dh = Double(drawnFull.height)
        let cw = Double(container.width)
        let ch = Double(container.height)
        guard dw > 0, dh > 0, cw > 0, ch > 0,
              dw.isFinite, dh.isFinite, cw.isFinite, ch.isFinite else { return nil }

        // `imageUnitPoint`'s arithmetic at the container's corners, margin included.
        let px = Double(pan.width.isFinite ? pan.width : 0)
        let py = Double(pan.height.isFinite ? pan.height : 0)
        let marginX = cw * marginFraction
        let marginY = ch * marginFraction
        var u0 = (0 - marginX - cw / 2 - px) / dw + 0.5
        var u1 = (cw + marginX - cw / 2 - px) / dw + 0.5
        var v0 = (0 - marginY - ch / 2 - py) / dh + 0.5
        var v1 = (ch + marginY - ch / 2 - py) / dh + 0.5

        // Whole frame (nearly) visible: not a region render.
        if u0 <= 0, v0 <= 0, u1 >= 1, v1 >= 1 { return nil }

        // Snap OUTWARD to the grid, then clamp. Snapping inward would shave pixels
        // off the very edge the margin exists to cover.
        u0 = Swift.max(0, (u0 / grid).rounded(.down) * grid)
        v0 = Swift.max(0, (v0 / grid).rounded(.down) * grid)
        u1 = Swift.min(1, (u1 / grid).rounded(.up) * grid)
        v1 = Swift.min(1, (v1 / grid).rounded(.up) * grid)
        guard u1 > u0, v1 > v0 else { return nil }
        return CGRect(x: u0, y: v0, width: u1 - u0, height: v1 - v0)
    }
}

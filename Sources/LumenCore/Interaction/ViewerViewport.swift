// ViewerViewport.swift
// The loupe's viewport as one value: zoom, pan, the layout hold, and the frame the
// zoom is measured against. Every zoom and pan source — pinch, wheel, scroll, drag,
// double-click, keys — is a mutation of this value, so they cannot disagree.
//
// Coordinates are view-local points, origin top-left. `pan` is the picture centre's
// offset from the container centre.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct ViewerViewport: Equatable, Sendable {

    // MARK: World

    /// What the view knows about its surroundings on one pass.
    public struct World: Equatable, Sendable {
        public var container: CGSize
        public var displayScale: Double
        /// The full frame's pixel extent as last delivered, at whatever scale it was
        /// rendered. Zero when nothing is on screen.
        public var delivered: CGSize
        /// The full frame at the resolution a zoomed settle delivers, when the
        /// source's size is known (`nativeFrame`).
        public var native: CGSize?
        /// The long edge to denominate the zoom in while `native` is unknown.
        public var fallbackLongEdge: Double

        public init(container: CGSize, displayScale: Double, delivered: CGSize,
                    native: CGSize?, fallbackLongEdge: Double) {
            self.container = container
            self.displayScale = displayScale
            self.delivered = delivered
            self.native = native
            self.fallbackLongEdge = fallbackLongEdge
        }
    }

    /// A zoom and pan the canvas is laid out at.
    public struct Layout: Equatable, Sendable {
        public var zoom: Double
        public var pan: CGSize

        public init(zoom: Double, pan: CGSize) {
            self.zoom = zoom
            self.pan = pan
        }
    }

    // MARK: Rules

    /// THE PAN LIMIT. The picture may be pushed past any viewport edge until this
    /// fraction of the viewport's extent, on each axis, still has picture in it. A
    /// picture smaller than that on an axis stays wholly inside on that axis.
    public static let overscrollKeepFraction: Double = 0.25

    /// A delivered extent within this many of its own pixels of a shape IS that
    /// shape: two renders of one frame differ by integer rounding only.
    static let shapeSlackPixels: Double = 1.5

    // MARK: State

    /// 0 is fit; otherwise device pixels per pixel of `frame`.
    public private(set) var zoom: Double = ZoomLadder.fit
    public private(set) var pan: CGSize = .zero
    /// While a continuous zoom is in flight, the layout the canvas and the render
    /// ask stay pinned to. The picture itself is wherever `zoom` and `pan` say.
    public private(set) var held: Layout?
    public private(set) var container: CGSize = .zero
    public private(set) var displayScale: Double = 1
    /// The full frame `zoom` is denominated in. Changes only in `setWorld`, never
    /// because a draft, settle or region of a different pixel size was delivered.
    public private(set) var frame: CGSize = .zero

    public init() {}

    // MARK: Reading

    public var isFit: Bool { ZoomLadder.isFit(zoom) }

    public var isUsable: Bool {
        Self.usable(container) && Self.usable(frame)
    }

    /// The picture's size in points at `ratio` (0 is fit).
    public func drawn(atZoom ratio: Double) -> CGSize {
        guard isUsable else { return .zero }
        let fw = Double(frame.width)
        let fh = Double(frame.height)
        let k: Double
        if ratio.isFinite, ratio > 0 {
            k = ratio / displayScale
        } else {
            k = Swift.min(Double(container.width) / fw, Double(container.height) / fh)
        }
        return CGSize(width: fw * k, height: fh * k)
    }

    public var drawn: CGSize { drawn(atZoom: zoom) }

    /// The ratio at which the zoomed draw is exactly the fitted one.
    public var fitZoom: Double {
        guard isUsable else { return 0 }
        return Self.long(drawn(atZoom: ZoomLadder.fit)) * displayScale / Self.long(frame)
    }

    /// What the canvas is laid out at and the render ask is sized from.
    public var layout: Layout { held ?? Layout(zoom: zoom, pan: pan) }

    public var layoutDrawn: CGSize { drawn(atZoom: layout.zoom) }

    /// The scale that turns the laid-out canvas into the picture on screen.
    public var stretch: Double {
        guard held != nil else { return 1 }
        return ZoomLayoutHold.stretch(base: Self.long(layoutDrawn), live: Self.long(drawn))
    }

    /// Where the picture is on screen.
    public var pictureRect: CGRect {
        Self.rect(drawn: drawn, pan: pan, container: container)
    }

    /// The picture's unit coordinate (origin top-left, unclamped) under a view point.
    public func unitPoint(at point: CGPoint) -> CGPoint? {
        let rect = pictureRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return CGPoint(x: (Double(point.x) - Double(rect.minX)) / Double(rect.width),
                       y: (Double(point.y) - Double(rect.minY)) / Double(rect.height))
    }

    /// The viewport's numbers, flat, for instruments and the automation driver.
    public var summary: [String: Double] {
        let rect = pictureRect
        let laid = layoutDrawn
        return [
            "zoom": zoom, "fitZoom": fitZoom,
            "panX": Double(pan.width), "panY": Double(pan.height),
            "containerWidth": Double(container.width),
            "containerHeight": Double(container.height),
            "frameWidth": Double(frame.width), "frameHeight": Double(frame.height),
            "displayScale": displayScale,
            "pictureX": Double(rect.minX), "pictureY": Double(rect.minY),
            "pictureWidth": Double(rect.width), "pictureHeight": Double(rect.height),
            "held": held == nil ? 0 : 1,
            "layoutZoom": layout.zoom,
            "layoutWidth": Double(laid.width), "layoutHeight": Double(laid.height),
            "stretch": stretch,
        ]
    }

    // MARK: The world

    /// Adopt the view's surroundings. A change of container re-limits the pan; a
    /// change of frame re-denominates the zoom so the picture keeps its size.
    public mutating func setWorld(_ world: World) {
        container = Self.usable(world.container) ? world.container : .zero
        displayScale = world.displayScale.isFinite && world.displayScale >= 1
            ? world.displayScale : 1
        let next = Self.resolveFrame(current: frame, world: world)
        if next != frame { rebase(onto: next) }
        if isFit {
            pan = .zero
        } else if isUsable {
            pan = limited(pan, drawn: drawn)
        }
    }

    /// This viewport as it would be in `world`, for a pass that has not committed it.
    public func inWorld(_ world: World) -> ViewerViewport {
        var copy = self
        copy.setWorld(world)
        return copy
    }

    /// A new photograph: fit, centred, nothing held. Its frame arrives by `setWorld`.
    public mutating func reset() {
        zoom = ZoomLadder.fit
        pan = .zero
        held = nil
    }

    // MARK: Zoom

    /// A discrete zoom to `ratio` (keys, double-click), about `anchor` or the centre.
    public mutating func setZoom(_ ratio: Double, anchor: CGPoint?) {
        let target = ZoomLadder.clamp(ratio)
        guard target != zoom else { return }
        apply(zoom: target, anchor: anchor)
    }

    /// One increment of a continuous zoom (pinch, wheel, ⌥-scroll): the picture's
    /// size is multiplied by `factor` about `anchor`. Fit is the floor, and landing
    /// on it is landing on fit. `hold` pins the layout until `releaseHold`.
    public mutating func magnify(by factor: Double, anchor: CGPoint?, hold: Bool) {
        guard factor.isFinite, factor > 0, isUsable else { return }
        let fit = fitZoom
        let current = isFit ? fit : zoom
        let candidate = current * factor
        let upper = Swift.max(ZoomLadder.maximum, current)
        let target: Double
        if candidate >= upper {
            target = upper
        } else if current >= fit {
            target = candidate > fit ? candidate : ZoomLadder.fit
        } else {
            // Smaller than fit already (a ladder ratio on a small picture, or the
            // window grew): in grows from here, out is fit.
            target = candidate > current ? candidate : ZoomLadder.fit
        }
        let resolved = isFit && target == fit ? ZoomLadder.fit : target
        guard resolved != zoom else { return }
        if hold, held == nil { held = Layout(zoom: zoom, pan: pan) }
        apply(zoom: resolved, anchor: anchor)
    }

    /// The layout catches up with the picture. Geometrically a no-op.
    public mutating func releaseHold() {
        held = nil
    }

    /// The hand has left a continuous zoom: release the hold, and a picture left
    /// within `ContinuousZoom.fitSnapSlack` above fit becomes fit.
    public mutating func endContinuousZoom() {
        held = nil
        guard !isFit, isUsable else { return }
        let fitted = Self.long(drawn(atZoom: ZoomLadder.fit))
        let now = Self.long(drawn)
        if now >= fitted, now <= fitted * ContinuousZoom.fitSnapSlack {
            zoom = ZoomLadder.fit
            pan = .zero
        }
    }

    // MARK: Pan

    /// Move the picture by `delta` points. Fit does not pan.
    public mutating func pan(by delta: CGSize) {
        pan(to: CGSize(width: Double(pan.width) + Double(delta.width),
                       height: Double(pan.height) + Double(delta.height)))
    }

    public mutating func pan(to target: CGSize) {
        guard !isFit, isUsable else { return }
        pan = limited(target, drawn: drawn)
    }

    // MARK: The frame

    /// The full frame a zoomed settle delivers: the crop of the straightened source
    /// at the resolution an ask of `askLongEdge` decodes. Nil without a usable source.
    public static func nativeFrame(source: CGSize, decoderLongEdge: Int?,
                                   geometry: Geometry, askLongEdge: Int) -> CGSize? {
        guard usable(source), askLongEdge > 0 else { return nil }
        let sourceLong = long(source)
        let decoded = decoderLongEdge.flatMap { $0 > 0 ? Double($0) : nil } ?? sourceLong
        let scale = Swift.min(Double(askLongEdge), decoded) / sourceLong
        let crop = CropGeometry.resolve(sourceWidth: Double(source.width),
                                        sourceHeight: Double(source.height),
                                        geometry: geometry)
        let size = CGSize(width: crop.width * scale, height: crop.height * scale)
        return usable(size) ? size : nil
    }

    /// Which frame the zoom is denominated in. The prediction when the picture on
    /// screen has its shape; otherwise the picture's own shape at the predicted long
    /// edge, kept across deliveries that differ by rounding alone.
    static func resolveFrame(current: CGSize, world: World) -> CGSize {
        let native: CGSize? = world.native.flatMap { usable($0) ? $0 : nil }
        guard usable(world.delivered) else { return native ?? .zero }
        if let native, hasShape(world.delivered, of: native) { return native }
        var wanted = world.fallbackLongEdge
        if let native { wanted = long(native) }
        guard wanted.isFinite, wanted > 0 else { return world.delivered }
        if usable(current), abs(long(current) - wanted) < 0.5,
           hasShape(world.delivered, of: current) {
            return current
        }
        let k = wanted / long(world.delivered)
        return CGSize(width: Double(world.delivered.width) * k,
                      height: Double(world.delivered.height) * k)
    }

    static func hasShape(_ delivered: CGSize, of shape: CGSize) -> Bool {
        let k = long(delivered) / long(shape)
        return abs(Double(shape.width) * k - Double(delivered.width)) <= shapeSlackPixels
            && abs(Double(shape.height) * k - Double(delivered.height)) <= shapeSlackPixels
    }

    // MARK: Internals

    /// `next` replaces `frame`. The picture keeps its size on screen and the zoom
    /// number moves — except on a named ratio with nothing held, where 1:1 must stay
    /// one frame pixel per device pixel and the viewport centre keeps its point.
    private mutating func rebase(onto next: CGSize) {
        let oldLong = Self.long(frame)
        let newLong = Self.long(next)
        guard zoom > 0, Self.usable(frame), Self.usable(next), oldLong != newLong else {
            frame = next
            return
        }
        if held == nil, ZoomLadder.isNamedRatio(zoom) {
            let before = drawn
            frame = next
            let after = drawn
            if before.width > 0, before.height > 0 {
                pan = CGSize(width: Double(pan.width) * Double(after.width / before.width),
                             height: Double(pan.height) * Double(after.height / before.height))
            }
            return
        }
        let ratio = oldLong / newLong
        zoom *= ratio
        if let layout = held, layout.zoom > 0 {
            held = Layout(zoom: layout.zoom * ratio, pan: layout.pan)
        }
        frame = next
    }

    /// The one zoom transition. The anchor is the given point brought onto the
    /// picture, and the picture point under it stays under it.
    private mutating func apply(zoom target: Double, anchor: CGPoint?) {
        guard target > 0 else {
            zoom = ZoomLadder.fit
            pan = .zero
            return
        }
        guard isUsable else {
            zoom = target
            pan = .zero
            return
        }
        let before = drawn
        let fitted = drawn(atZoom: ZoomLadder.fit)
        let rect = Self.rect(drawn: before, pan: pan, container: container)
        zoom = target
        let after = drawn

        let cx = Double(container.width) / 2
        let cy = Double(container.height) / 2
        let wanted = anchor ?? CGPoint(x: cx, y: cy)
        let ax = Swift.min(Swift.max(Double(wanted.x), Double(rect.minX)), Double(rect.maxX))
        let ay = Swift.min(Swift.max(Double(wanted.y), Double(rect.minY)), Double(rect.maxY))
        let ux = (ax - Double(rect.minX)) / Double(before.width)
        let uy = (ay - Double(rect.minY)) / Double(before.height)
        var px = ax - cx - (ux - 0.5) * Double(after.width)
        var py = ay - cy - (uy - 0.5) * Double(after.height)

        // Zooming out never opens a gap between a picture edge and the pane's, and a
        // gap already there shrinks with the share of the way to fit still left — so
        // fit arrives centred without a jump. Zooming in never moves the anchor.
        let was = Self.long(before)
        let now = Self.long(after)
        let floor = Self.long(fitted)
        if now < was {
            let left = was > floor
                ? Swift.min(Swift.max((now - floor) / (was - floor), 0), 1)
                : 0
            px = Self.closing(px, from: Double(pan.width),
                              drawnBefore: Double(before.width),
                              drawnAfter: Double(after.width),
                              container: Double(container.width), keeping: left)
            py = Self.closing(py, from: Double(pan.height),
                              drawnBefore: Double(before.height),
                              drawnAfter: Double(after.height),
                              container: Double(container.height), keeping: left)
        }
        pan = limited(CGSize(width: px, height: py), drawn: after)
    }

    /// The pan with the picture covering as much of the pane as its size allows.
    private static func covering(_ pan: Double, drawn: Double, container: Double) -> Double {
        let cover = Swift.max(0, (drawn - container) / 2)
        return Swift.min(Swift.max(pan, -cover), cover)
    }

    private static func closing(_ pan: Double, from old: Double,
                                drawnBefore: Double, drawnAfter: Double,
                                container: Double, keeping share: Double) -> Double {
        let allowed = (old - covering(old, drawn: drawnBefore, container: container)) * share
        let covered = covering(pan, drawn: drawnAfter, container: container)
        let gap = Swift.min(Swift.max(pan - covered, Swift.min(0, allowed)),
                            Swift.max(0, allowed))
        return covered + gap
    }

    /// `overscrollKeepFraction`, applied.
    private func limited(_ pan: CGSize, drawn: CGSize) -> CGSize {
        CGSize(width: Self.limited(Double(pan.width), drawn: Double(drawn.width),
                                   container: Double(container.width)),
               height: Self.limited(Double(pan.height), drawn: Double(drawn.height),
                                    container: Double(container.height)))
    }

    static func limited(_ pan: Double, drawn: Double, container: Double) -> Double {
        guard pan.isFinite, drawn > 0, container > 0 else { return 0 }
        let keep = Swift.min(container * overscrollKeepFraction, drawn)
        let bound = (container + drawn) / 2 - keep
        return Swift.min(Swift.max(pan, -bound), bound)
    }

    private static func rect(drawn: CGSize, pan: CGSize, container: CGSize) -> CGRect {
        CGRect(x: Double(container.width) / 2 + Double(pan.width) - Double(drawn.width) / 2,
               y: Double(container.height) / 2 + Double(pan.height) - Double(drawn.height) / 2,
               width: Double(drawn.width), height: Double(drawn.height))
    }

    private static func long(_ size: CGSize) -> Double {
        Double(Swift.max(size.width, size.height))
    }

    private static func usable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

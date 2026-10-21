// StrokeHandles.swift
// What a press means to a painted heal stroke on the loupe (the Heal tool's Brush
// mode), in LumenCore where it can be tested; `HealCanvas` draws and routes.

import Foundation

public enum StrokeHandles {

    /// The topmost stroke (last drawn) whose tube contains the source-normalized point,
    /// or nil. `minimumGrab` is in source pixels, so a hair-thin stroke is still a
    /// target at fit size.
    public static func hit(x: Double, y: Double, strokes: [BrushStroke],
                           sourceWidth: Int, sourceHeight: Int,
                           minimumGrab: Double = 0) -> Int? {
        let w = Double(sourceWidth), h = Double(sourceHeight)
        let p = StrokeHeal.Point(x * w, y * h)
        for index in strokes.indices.reversed() {
            let stroke = strokes[index]
            guard stroke.retouch != nil, !stroke.points.isEmpty else { continue }
            let radius = Num.clamp(stroke.size / 2, HealSpot.radiusRange.lowerBound,
                                   HealSpot.radiusRange.upperBound) * Swift.max(w, h)
            let line = stroke.points.map { StrokeHeal.Point($0.x * w, $0.y * h) }
            if StrokeHeal.distance(p, to: line) <= Swift.max(radius, minimumGrab) {
                return index
            }
        }
        return nil
    }

    /// Where a just-painted stroke borrows from until the search answers: beside it,
    /// perpendicular to its overall direction, 2.6 radii away (the middle of the
    /// search's own candidate distances) — toward the side with more frame. A dab with
    /// no direction goes sideways. As `StrokeRetouch` states it: fractions of width and
    /// height.
    public static func provisionalOffset(points: [BrushPoint], size: Double,
                                         sourceWidth: Int,
                                         sourceHeight: Int) -> (dx: Double, dy: Double) {
        let w = Double(Swift.max(sourceWidth, 1)), h = Double(Swift.max(sourceHeight, 1))
        let radius = Num.clamp(size / 2, HealSpot.radiusRange.lowerBound,
                               HealSpot.radiusRange.upperBound) * Swift.max(w, h)
        guard let first = points.first, let last = points.last else { return (0, 0) }
        var nx = 1.0, ny = 0.0
        let ex = (last.x - first.x) * w, ey = (last.y - first.y) * h
        let length = hypot(ex, ey)
        if length > 1e-9 {
            nx = -ey / length
            ny = ex / length
        }
        // Toward the frame's centre from the stroke's middle, so the source stays on it.
        let mx = (first.x + last.x) / 2 * w, my = (first.y + last.y) / 2 * h
        if nx * (w / 2 - mx) + ny * (h / 2 - my) < 0 {
            nx = -nx
            ny = -ny
        }
        let distance = 2.6 * radius
        return (nx * distance / w, ny * distance / h)
    }

    /// Whether a press at source-normalized (`x`, `y`) lands on `stroke`'s SOURCE — the
    /// dashed centreline the canvas draws at the stroke's points plus its offset —
    /// within half its tube width (at least `minimumGrab` source pixels). The canvas
    /// asks this of the SELECTED stroke only, and before any other hit: a source drawn
    /// over another stroke or a spot is still the thing the photographer reached for.
    public static func hitSource(x: Double, y: Double, stroke: BrushStroke,
                                 sourceWidth: Int, sourceHeight: Int,
                                 minimumGrab: Double = 0) -> Bool {
        guard let retouch = stroke.retouch, !stroke.points.isEmpty,
              retouch.dx.isFinite, retouch.dy.isFinite else { return false }
        let w = Double(sourceWidth), h = Double(sourceHeight)
        guard w > 0, h > 0 else { return false }
        let radius = Num.clamp(stroke.size / 2, HealSpot.radiusRange.lowerBound,
                               HealSpot.radiusRange.upperBound) * Swift.max(w, h)
        let line = stroke.points.map {
            StrokeHeal.Point(($0.x + retouch.dx) * w, ($0.y + retouch.dy) * h)
        }
        return StrokeHeal.distance(StrokeHeal.Point(x * w, y * h), to: line)
            <= Swift.max(radius * 0.5, minimumGrab)
    }

    /// `stroke` with its source dragged by (`dx`, `dy`), source-normalized: the
    /// painted points stay, only the offset moves — a spot's source drag
    /// (`SpotHandles.dragged(_:part: .source)`) for a brush.
    public static func draggedSource(_ stroke: BrushStroke, dx: Double,
                                     dy: Double) -> BrushStroke {
        guard dx.isFinite, dy.isFinite else { return stroke }
        var out = stroke
        out.retouch?.dx += dx
        out.retouch?.dy += dy
        return out
    }
}

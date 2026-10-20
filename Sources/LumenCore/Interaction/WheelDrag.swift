// WheelDrag.swift
// The grading wheel's drag law: what a press picks up, and what a drag is worth.
//
// The wheel used to be purely absolute — every event, the press included, put the puck
// under the pointer. So pressing the rim of a 9-point puck to nudge it moved it up to
// 4.5 points before the hand did (about 0.13 of strength on a 68-point wheel, and tens
// of degrees of hue near the centre), and ⇧ did nothing, unlike every slider beside it.
// The same two answers the slider has, stated for two dimensions: a press on the puck
// picks it up where it is (`SliderDrag.grabsThumb`), and ⇧ changes gear without moving
// it (`FineDrag`). Offsets are in points from the wheel's centre, y down — the view's
// own axes.

import Foundation

/// A point relative to the wheel's centre, in points, y down.
public struct WheelPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = WheelPoint(x: 0, y: 0)
}

/// One wheel gesture: an anchor the drag is measured from, re-based when ⇧ changes.
public struct WheelDrag: Equatable, Sendable {

    /// Wider than the 9-point puck is drawn, for the same reason as
    /// `SliderDrag.thumbGrabRadius`: missing it costs a jump. Narrower than the slider's,
    /// because a 68-point wheel has far less room around its puck than a track has.
    public static let puckGrabRadius: Double = 7

    /// Where the puck is drawn for a hue and strength — the inverse of `reading`.
    public static func puckOffset(hue: Double, saturation: Double,
                                  radius: Double) -> WheelPoint {
        let r = saturation * radius
        let a = hue * .pi / 180
        return WheelPoint(x: r * cos(a), y: r * sin(a))
    }

    /// Hue (0…360) and strength (0…1) under an offset. The arithmetic the wheel has
    /// always used, moved here unchanged; nil for a geometry that cannot answer.
    public static func reading(_ p: WheelPoint,
                               radius: Double) -> (hue: Double, saturation: Double)? {
        guard radius > 0, radius.isFinite, p.x.isFinite, p.y.isFinite else { return nil }
        let r = min((p.x * p.x + p.y * p.y).squareRoot() / radius, 1)
        let hue = (atan2(p.y, p.x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return (hue, r)
    }

    public static func grabsPuck(press: WheelPoint, puck: WheelPoint) -> Bool {
        let dx = press.x - puck.x
        let dy = press.y - puck.y
        guard dx.isFinite, dy.isFinite else { return false }
        return (dx * dx + dy * dy).squareRoot() <= puckGrabRadius
    }

    /// True when the press picked the puck up, so a press with no travel is worth
    /// nothing; false when it landed on bare disc, where a click places the puck.
    public let grabbedPuck: Bool

    private var anchor: WheelPoint
    private var anchorTravel: WheelPoint
    private var isFine: Bool

    public init(press: WheelPoint, puck: WheelPoint, fine: Bool = false) {
        let grabbed = Self.grabsPuck(press: press, puck: puck)
        self.grabbedPuck = grabbed
        self.anchor = grabbed ? puck : press
        self.anchorTravel = .zero
        self.isFine = fine
    }

    /// The offset the gesture is worth now, and a replacement ONLY when the gear moved —
    /// the same shape as `FineDrag.resolving`, for the same `@State`-write reason.
    public func resolving(travelled: WheelPoint,
                          fine: Bool) -> (offset: WheelPoint, changedGear: WheelDrag?) {
        guard travelled.x.isFinite, travelled.y.isFinite else { return (anchor, nil) }
        guard fine != isFine else { return (resolved(travelled), nil) }
        // Re-base at what the OLD gear had reached, so the change itself moves nothing.
        var next = self
        next.anchor = resolved(travelled)
        next.anchorTravel = travelled
        next.isFine = fine
        return (next.resolved(travelled), next)
    }

    private func resolved(_ travelled: WheelPoint) -> WheelPoint {
        let gear = isFine ? FineDrag.scale : 1
        return WheelPoint(x: anchor.x + (travelled.x - anchorTravel.x) * gear,
                          y: anchor.y + (travelled.y - anchorTravel.y) * gear)
    }
}

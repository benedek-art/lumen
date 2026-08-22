// Straighten.swift
// The ruler: drag a line along a horizon or a doorframe, and the frame levels to
// whichever axis that line is closer to (docs/09 §Straighten / Level).
//
// This is pure arithmetic in `LumenCore` rather than in the overlay that captures the
// drag, for one reason: the SIGN. The ruler is measured on the frame the viewer is
// showing, and that frame has ALREADY been rotated by the angle currently in the
// recipe — so a ruler that writes `atan2` straight into `geometry.angle` is wrong by
// exactly the angle that was there before, and wrong in the direction that makes the
// second drag worse than the first. The sign also inverts under a horizontal flip.
// Neither of those is testable from a machine with no renderer unless the mapping is
// written down as a function, which is what `displayedDirection` below is.
//
// THE DERIVATION, so the sign can be checked rather than trusted:
//
//   `PipelineRenderer.applyGeometry` builds its orientation as
//       identity.scaledBy(x: flipH ? -1 : 1, y: 1).rotated(by: -angle · π/180)
//   and Core Image's coordinates are y-UP, so a source direction φ (measured in that
//   y-up frame) leaves the rotation as φ − angle. The rendered CGImage is then drawn
//   y-DOWN, which negates every angle. Writing s = −φ for the same direction expressed
//   in view coordinates, a direction s appears at
//       θ = angle + s               (no flip)
//       θ = −(angle + s)            (flipped, because the mirror sends θ to 180° − θ,
//                                    which is −θ modulo the 180° a line is defined to)
//
// Levelling means choosing the angle that puts θ on an axis: θ = 0 for a line nearer
// horizontal, θ = ±90° for one nearer vertical. Solving `angle + s = 0` for the angle,
// given that the drag observed θ on the current frame, is what `angle(current:…)` does.

import Foundation

public enum Straighten {

    /// The slider's range, and the ruler's. ±45° covers every levelling job because a
    /// line more than 45° from horizontal is levelled to vertical instead.
    public static let limitDegrees: Double = 45

    /// Shortest drag the ruler will act on, as a fraction of the frame's long edge.
    ///
    /// A two-pixel drag has an angle, and it is noise: at 2 px the quantization of the
    /// endpoints alone is worth tens of degrees. Below this the gesture is a click that
    /// happened to move, and the right answer is to change nothing.
    public static let minimumDragFraction: Double = 0.02

    /// Where a source direction appears on the frame the viewer is drawing, in degrees,
    /// with y measured DOWNWARD as a view hands it over.
    ///
    /// The forward half of the ruler's mapping — see the derivation at the top of the
    /// file. It exists so the inverse below can be checked against it rather than
    /// asserted, which is the only way the sign gets tested on a machine that cannot run
    /// the renderer.
    public static func displayedDirection(sourceDegrees s: Double, angle: Double,
                                          flipped: Bool = false) -> Double {
        let displayed = flipped ? -(angle + s) : (angle + s)
        return wrapToAxis(displayed)
    }

    /// The angle the recipe should hold so that the dragged line becomes level.
    ///
    /// `dx`/`dy` are the drag's extent in VIEW points, y downward, measured on the frame
    /// the loupe is currently showing — which is the frame `current` has already been
    /// applied to. Returns nil when the drag is too short to carry an angle.
    public static func angle(current: Double, dx: Double, dy: Double,
                             flipped: Bool = false,
                             frameLongEdge: Double = 0) -> Double? {
        guard dx.isFinite, dy.isFinite, current.isFinite else { return nil }
        let length = (dx * dx + dy * dy).squareRoot()
        let floor = frameLongEdge > 0 ? frameLongEdge * minimumDragFraction : 1.0
        guard length >= Swift.max(floor, 1e-9) else { return nil }

        // How far the dragged line sits from the nearest axis, in (−45°, +45°]. A line
        // within 45° of horizontal levels to horizontal, anything else to vertical —
        // one gesture for a horizon and for a doorframe, which is docs/09's rule.
        let observed = wrapToAxis(atan2(dy, dx) * 180 / .pi)

        // Solve `displayedDirection(source, newAngle, flipped) == 0`. Under no flip the
        // observed tilt subtracts; under a flip the mirror has already negated it, so it
        // adds. Getting this backwards doubles the error on the second drag instead of
        // fixing it, which is why it is one expression with a test either side of it.
        let next = flipped ? current + observed : current - observed
        guard next.isFinite else { return nil }
        return Num.clamp(next, -limitDegrees, limitDegrees)
    }

    /// Fold an angle into (−45°, +45°]: the distance to the NEAREST axis, since a line
    /// and the same line turned by 90° are the same reference for levelling.
    public static func wrapToAxis(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var d = degrees.truncatingRemainder(dividingBy: 90)
        if d > 45 { d -= 90 }
        if d <= -45 { d += 90 }
        return d
    }
}

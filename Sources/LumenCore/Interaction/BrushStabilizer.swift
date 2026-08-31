// BrushStabilizer.swift
// The reason a mask painted by hand looks painted by hand.
//
// A brush follows the pointer exactly, and a pointer is not steady. Every tremor, every
// bump of the desk and every quantisation of the mouse's own sampling is recorded into
// the stroke and then rasterized into the mask's edge at full resolution — so a boundary
// meant to run along a jawline arrives with a fine wobble on it that is invisible while
// painting at fit-to-window and obvious at 1:1, which is exactly the wrong way round.
//
// Photoshop and Krita both solve it and Lightroom and Capture One do not, which is the
// gap this closes.
//
// THE PULLED STRING, and it is chosen over the two easier answers on purpose.
//
//   An EXPONENTIAL AVERAGE of recent positions is one line and it cuts corners: the
//   smoothed point crosses the inside of every turn, so painting round the end of a nose
//   takes a bite out of it. It also lags forever — the brush is still catching up long
//   after the hand has stopped, which reads as the tool being slow rather than steady.
//
//   A LOW-PASS over the finished stroke fixes the wobble and cannot help while painting,
//   which is when the photographer is deciding where the edge goes.
//
// The string is a length of rope between the pointer and the brush. Move the pointer and
// nothing happens until the rope goes taut; then the brush is dragged along behind, always
// exactly `length` away. Two properties follow, and they are what make it feel like a
// tool rather than a filter:
//
//   Jitter SMALLER than the rope does not move the brush at all. Not attenuated — it
//   does not move it, so a stroke held still is perfectly still.
//
//   A turn is ROUNDED by the rope's length rather than cut across. The brush cannot
//   arrive anywhere the pointer has not been within `length`, so the stroke stays inside
//   the shape the hand drew.
//
// The cost is a fixed lag of `length`, paid at the start of a stroke and at every change
// of direction, and it is the honest price: it is what makes the smoothing a constraint
// the hand can feel and steer against rather than a delay it has to guess at.

import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A pulled-string smoother over one stroke's pointer samples.
///
/// One instance per stroke. It carries the brush's position between samples, so it is a
/// `struct` the caller keeps rather than a function — a stateless version would have to
/// be handed the whole history and would re-derive the same point every event.
public struct BrushStabilizer: Sendable {

    /// Rope length in SOURCE-NORMALIZED long-edge units, matching `BrushStroke.size`.
    /// Zero is a rigid connection: the brush is the pointer, which is what shipped and
    /// what a stroke recorded before this existed replays as.
    public let length: Double

    private var brush: (x: Double, y: Double)?

    /// `strength` is the panel's 0…100. `maxLength` is what 100 means.
    public init(strength: Double, maxLength: Double = BrushStabilizer.maxLength) {
        let s = strength.isFinite ? Num.saturate(strength / 100) : 0
        // SQUARED, not linear. The useful range of a stabilizer is bunched at the bottom
        // — the difference between 0 and 10 is the difference between a jittery edge and
        // a clean one, and the difference between 60 and 70 is two flavours of "very
        // smooth". A linear slider spends four fifths of its travel where nobody can
        // tell the settings apart.
        self.length = s * s * Swift.max(maxLength, 0)
    }

    /// What 100 means: 2% of the long edge, which is about 90 px on a 45 MP frame and
    /// roughly a third of the default brush. Longer than that and the lag stops reading
    /// as steadiness and starts reading as the tool being broken.
    public static let maxLength: Double = 0.02

    /// Where the brush is after the pointer moved to `x`, `y`.
    ///
    /// Returns nil for a sample that does not move the brush — the caller records
    /// nothing, which is also what keeps a held-still pointer from filling the stroke
    /// with duplicate points.
    public mutating func next(x: Double, y: Double) -> (x: Double, y: Double)? {
        guard x.isFinite, y.isFinite else { return nil }
        guard let current = brush else {
            // The first sample places the brush under the pointer. Starting it `length`
            // behind would mean every stroke began with a jump toward the second point.
            brush = (x, y)
            return (x, y)
        }
        guard length > 0 else {
            brush = (x, y)
            return (x, y)
        }
        let dx = x - current.x
        let dy = y - current.y
        let distance = (dx * dx + dy * dy).squareRoot()
        // Slack rope: the pointer moved inside the circle, so the brush does not.
        guard distance > length else { return nil }
        let step = distance - length
        let next = (x: current.x + dx / distance * step,
                    y: current.y + dy / distance * step)
        brush = next
        return next
    }

    /// The stroke has ended: let the brush travel the rest of the way to the pointer.
    ///
    /// Without this a stabilized stroke stops `length` short of where the photographer
    /// released, every time — which is a systematic error rather than smoothing, and on
    /// a stroke drawn to meet another one it is a visible gap.
    public mutating func finish(x: Double, y: Double) -> (x: Double, y: Double)? {
        guard x.isFinite, y.isFinite else { return nil }
        guard let current = brush else { return nil }
        guard abs(current.x - x) > 1e-12 || abs(current.y - y) > 1e-12 else { return nil }
        brush = (x, y)
        return (x, y)
    }
}

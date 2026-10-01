// SpotHandles.swift
// What a press on the photograph means while the Heal tool is armed — in LumenCore,
// for `MaskHandles`' reason: the canvas lives in a target with no Linux tests, and a
// hit rule that cannot be reached from a test is a rule nobody has checked.
//
// The grammar, LR's, kept small:
//
//   on a spot's destination circle → select it, and a drag moves the destination
//                                    (the source stays where it is, as in LR)
//   on a spot's source circle      → select it, and a drag moves only the source
//   anywhere else                  → a new spot here
//
// Circles are hit in SOURCE PIXELS, so a spot is the same size target whatever the
// aspect ratio, and a minimum grab radius in VIEW points keeps a tiny spot pressable.
// The topmost spot wins — the last in the list, which is also the one drawn last and
// the one applied last.

import Foundation

public enum SpotHandles {

    public enum Part: Equatable, Sendable {
        case destination
        case source
    }

    public struct Hit: Equatable, Sendable {
        public let id: String
        public let part: Part
    }

    /// The spot part under a press at source-normalized (`x`, `y`), or nil for clear
    /// space. `minimumGrab` is in source pixels — the caller converts its view-point
    /// tolerance at the current zoom.
    public static func hit(x: Double, y: Double, spots: [HealSpot],
                           sourceWidth: Int, sourceHeight: Int,
                           minimumGrab: Double) -> Hit? {
        let w = Double(sourceWidth), h = Double(sourceHeight)
        guard w > 0, h > 0 else { return nil }
        let edge = Swift.max(w, h)
        let px = x * w, py = y * h
        for spot in spots.reversed() {
            let reach = Swift.max(spot.radius * edge, minimumGrab)
            // The destination first: where the two circles overlap, the press is far
            // more likely to be about the blemish than about where it borrows from.
            if hypot(px - spot.x * w, py - spot.y * h) <= reach {
                return Hit(id: spot.id, part: .destination)
            }
            if hypot(px - spot.sourceX * w, py - spot.sourceY * h) <= reach {
                return Hit(id: spot.id, part: .source)
            }
        }
        return nil
    }

    /// A source to show the instant a spot is placed, before the search answers: two
    /// and a half radii to the right, or to the left when that would leave the frame.
    /// Never the destination itself, which would render as nothing and read as broken.
    public static func provisionalSource(for spot: HealSpot, sourceWidth: Int,
                                         sourceHeight: Int) -> (x: Double, y: Double) {
        let w = Double(Swift.max(sourceWidth, 1)), h = Double(Swift.max(sourceHeight, 1))
        let offset = 2.5 * spot.radius * Swift.max(w, h) / w
        let right = spot.x + offset
        let x = right + spot.radius * Swift.max(w, h) / w <= 1 ? right : spot.x - offset
        return (x, spot.y)
    }

    /// The spot after a drag of (`dx`, `dy`) source-normalized units on `part`.
    public static func dragged(_ spot: HealSpot, part: Part,
                               dx: Double, dy: Double) -> HealSpot {
        var out = spot
        switch part {
        case .destination:
            out.x += dx
            out.y += dy
        case .source:
            out.sourceX += dx
            out.sourceY += dy
        }
        return out
    }
}

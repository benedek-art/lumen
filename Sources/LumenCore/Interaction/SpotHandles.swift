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
    /// and a half radii to the right, left, below or above, the first whose disc fits in
    /// the frame. The search finds nothing for a spot too large for any candidate, so
    /// this can be the source that renders: a disc off the frame would paste the edge
    /// pixels stretched. When none fits, the in-frame disc farthest from the spot.
    /// Never the destination itself, which would render as nothing and read as broken.
    public static func provisionalSource(for spot: HealSpot, sourceWidth: Int,
                                         sourceHeight: Int) -> (x: Double, y: Double) {
        let w = Double(Swift.max(sourceWidth, 1)), h = Double(Swift.max(sourceHeight, 1))
        let edge = Swift.max(w, h)
        let rx = spot.radius * edge / w, ry = spot.radius * edge / h
        let ox = 2.5 * rx, oy = 2.5 * ry
        func fits(_ p: (x: Double, y: Double)) -> Bool {
            p.x - rx >= 0 && p.x + rx <= 1 && p.y - ry >= 0 && p.y + ry <= 1
        }
        let beside = [(spot.x + ox, spot.y), (spot.x - ox, spot.y),
                      (spot.x, spot.y + oy), (spot.x, spot.y - oy)]
        if let p = beside.first(where: fits) { return p }
        guard 2 * rx <= 1, 2 * ry <= 1 else { return (spot.x - ox, spot.y) }
        let cy = Num.clamp(spot.y, ry, 1 - ry), cx = Num.clamp(spot.x, rx, 1 - rx)
        let inFrame = [(rx, cy), (1 - rx, cy), (cx, ry), (cx, 1 - ry)]
        func distance(_ p: (x: Double, y: Double)) -> Double {
            hypot((p.x - spot.x) * w, (p.y - spot.y) * h)
        }
        let farthest = inFrame.max { distance($0) < distance($1) }!
        return distance(farthest) > 0 ? farthest : (spot.x - ox, spot.y)
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

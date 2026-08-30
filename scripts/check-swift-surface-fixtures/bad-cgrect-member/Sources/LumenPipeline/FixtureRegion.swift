// The defect this fixture plants is the one that reached a Mac: `CGRect` has no
// `isFinite` (that is `isInfinite`, negated), and `swiftc -parse` on the free lane
// does not type-check — so nothing but this pass can see it before CI.
import CoreGraphics

func fixtureRasterRect(_ fixtureExtent: CGRect) -> CGRect {
    guard fixtureExtent.isFinite else { return fixtureExtent }
    return fixtureExtent.integral
}

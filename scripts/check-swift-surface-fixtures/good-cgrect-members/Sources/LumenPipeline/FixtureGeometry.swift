// Every one of these IS a member of its type. A pass that flagged any of them would be
// noise, and a checker with false positives gets ignored.
import CoreGraphics

func fixtureGeometry(_ fixtureRect: CGRect, _ fixtureSize: CGSize,
                     _ fixturePoint: CGPoint) -> CGFloat {
    let inset: CGRect = fixtureRect.insetBy(dx: 1, dy: 1)
    let joined: CGRect = inset.union(fixtureRect).standardized.integral
    guard !joined.isNull, !joined.isInfinite, !joined.isEmpty else { return 0 }
    let span: CGFloat = joined.maxX - joined.minX + joined.midY
        + joined.origin.y + joined.size.height + joined.width + joined.height
    return span + fixtureSize.width + fixtureSize.height + fixturePoint.x + fixturePoint.y
}

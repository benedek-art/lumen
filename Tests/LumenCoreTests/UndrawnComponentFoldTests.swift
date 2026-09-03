// UndrawnComponentFoldTests.swift
// An unfinished component contributes NOTHING to the fold — not zero, nothing.
//
// `combine` already refused to invert a mask whose every component was unfinished, and
// the argument written above that guard is the right one: "a component that reads
// INCOMPLETE is not a selection of nothing, it is the absence of a selection, and there
// is nothing there to invert."
//
// The guard only covered the all-unfinished case. A mask with one working component and
// one unfinished one rasterized the unfinished one to a zero plane and folded it in.
// Under `.add` that is invisible — max(a, 0) is a. Under `.subtract` it is invisible too
// — min(a, 1) is a. Under `.intersect` it is a × 0, and every pixel the mask selected
// disappears.
//
// Two clicks away: a mask with a working Radial, press "Add to this mask" — which seeds
// no geometry, deliberately — and set the new component's op to Intersect with the
// segmented control that is always on screen. And it is not transient: a recipe saved in
// that state renders empty forever, in the loupe and in the delivered file, with the
// panel flagging only the one component.

import XCTest
@testable import LumenCore

final class UndrawnComponentFoldTests: XCTestCase {

    private let size = (width: 48, height: 32)

    private func drawnRadial() -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [0.5, 0.5]
        c.radii = [0.3, 0.3]
        c.feather = 0
        return c
    }

    /// A component exactly as `MaskPanel.makeComponent` produces it: a kind, an op, and
    /// nothing drawn yet.
    private func undrawn(_ kind: MaskKind, op: MaskOp) -> MaskComponent {
        var c = MaskComponent(op: op, kind: kind)
        c.op = op
        XCTAssertNotNil(c.validationError(),
                        "this test needs a component that is genuinely unfinished")
        return c
    }

    private func alpha(_ mask: Mask) -> Plane {
        MaskRaster.combine(mask: mask, size: size)
    }

    private func range(_ p: Plane) -> (min: Float, max: Float) {
        (p.values.min() ?? 0, p.values.max() ?? 0)
    }

    // MARK: - The bug

    /// The one that emptied the mask. Every unfinished kind, because the panel offers
    /// Intersect on all of them.
    func testAnUndrawnIntersectComponentDoesNotEmptyTheMask() {
        for kind in [MaskKind.brush, .radial, .linear, .polygon, .colorRange, .maskRef] {
            var mask = Mask(id: "m", name: "Sky")
            mask.components = [drawnRadial(), undrawn(kind, op: .intersect)]
            let got = range(alpha(mask))
            XCTAssertGreaterThan(got.max, 0.9,
                                 "an undrawn \(kind) set to Intersect emptied the mask")
        }
    }

    /// And the mask is not merely non-empty — it is exactly what the finished component
    /// alone selects. An unfinished component must be inert, not merely survivable.
    func testTheMaskIsExactlyWhatTheFinishedComponentSelects() {
        var alone = Mask(id: "m", name: "Sky")
        alone.components = [drawnRadial()]
        let expected = alpha(alone)

        for op in [MaskOp.add, .subtract, .intersect] {
            var withGhost = Mask(id: "m", name: "Sky")
            withGhost.components = [drawnRadial(), undrawn(.brush, op: op)]
            let got = alpha(withGhost)
            for i in 0..<expected.values.count {
                XCTAssertEqual(got.values[i], expected.values[i], accuracy: 1e-6,
                               "an undrawn \(op) component changed pixel \(i)")
            }
        }
    }

    /// The unfinished component in FIRST position, where it seeds the accumulator.
    func testAnUndrawnComponentFirstInTheStackIsAlsoInert() {
        var alone = Mask(id: "m", name: "Sky")
        alone.components = [drawnRadial()]
        let expected = alpha(alone)

        var leading = Mask(id: "m", name: "Sky")
        leading.components = [undrawn(.brush, op: .add), drawnRadial()]
        let got = alpha(leading)
        for i in 0..<expected.values.count {
            XCTAssertEqual(got.values[i], expected.values[i], accuracy: 1e-6)
        }
    }

    // MARK: - The rule it must not break

    /// The guard this extends: a mask with NOTHING finished selects nothing, Invert or
    /// not. Inverting an empty stack is otherwise the whole photograph, and that is a
    /// two-stop lift on every pixel.
    func testAMaskWithNothingFinishedStillSelectsNothingEvenInverted() {
        for invert in [false, true] {
            var mask = Mask(id: "m", name: "Sky")
            mask.invert = invert
            mask.components = [undrawn(.brush, op: .add), undrawn(.radial, op: .intersect)]
            let got = range(alpha(mask))
            XCTAssertEqual(got.max, 0, accuracy: 1e-6,
                           "an unfinished mask selected something with invert \(invert)")
        }
    }

    /// A mask that is finished and inverted still inverts — the fix must not have turned
    /// the whole-mask Invert off.
    func testAFinishedMaskStillInverts() {
        var mask = Mask(id: "m", name: "Sky")
        mask.invert = true
        mask.components = [drawnRadial(), undrawn(.brush, op: .intersect)]
        let got = range(alpha(mask))
        XCTAssertEqual(got.max, 1, accuracy: 1e-6, "the corners should be fully selected")
        XCTAssertEqual(got.min, 0, accuracy: 1e-6, "the disc should be fully out")
    }

    /// An intersect between two FINISHED components still intersects. The fix skips the
    /// unevaluable, not the empty: a colour range that legitimately matches nothing must
    /// still be able to empty a mask, because that is a real answer.
    func testIntersectStillIntersectsWhenBothComponentsAreFinished() {
        var left = drawnRadial(); left.center = [0.3, 0.5]
        var right = drawnRadial(); right.center = [0.7, 0.5]; right.op = .intersect

        var mask = Mask(id: "m", name: "Sky")
        mask.components = [left, right]
        let got = range(alpha(mask))
        XCTAssertGreaterThan(got.max, 0.9, "the discs overlap, so something must survive")

        // Pull them apart until they do not touch: the intersection is then genuinely
        // empty, and that is the correct answer rather than a bug.
        var far = drawnRadial(); far.center = [0.95, 0.5]; far.radii = [0.03, 0.03]
        far.op = .intersect
        var disjoint = Mask(id: "m", name: "Sky")
        disjoint.components = [left, far]
        XCTAssertEqual(range(alpha(disjoint)).max, 0, accuracy: 1e-6,
                       "two finished components that do not overlap intersect to nothing")
    }
}

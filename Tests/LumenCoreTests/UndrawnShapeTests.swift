// UndrawnShapeTests.swift
// A mask you have not drawn yet selects NOTHING.
//
// The picker stopped seeding geometry this round — a radial arriving as a circle in the
// middle of the frame was the owner's complaint, and it also blocked the draw-it-out
// gesture, since `.create` only fires on a press with clear space around it. So between
// choosing the kind and drawing the shape there is now a window, measured in seconds,
// where the component has no geometry at all.
//
// The failure mode in that window is not "nothing happens". It is a component that
// rasterizes to a FULL plane and applies the mask's adjustments to the whole photograph
// — and the photographer's next gesture is to drag the shape they meant to draw, so they
// would watch the frame go two stops bright and then correct back. Every kind that can
// now arrive empty is checked here, at the same three sizes, against the same claim.

import XCTest
@testable import LumenCore

final class UndrawnShapeTests: XCTestCase {

    private let sizes = [(width: 8, height: 8), (width: 64, height: 41),
                         (width: 331, height: 197)]

    private func assertSelectsNothing(_ c: MaskComponent, _ what: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(c.validationError(),
                        "\(what) with no geometry must read INCOMPLETE, or the panel's "
                            + "badge cannot say so", file: file, line: line)
        for size in sizes {
            let plane = MaskRaster.rasterize(component: c, size: size,
                                             source: ImageBuffer(width: size.width,
                                                                 height: size.height) {
                                                 u, v in RGB(u, v, 0.5)
                                             })
            XCTAssertEqual(plane.values.max().map(Double.init) ?? 1, 0, accuracy: 0,
                           "\(what) selected something at \(size.width)×\(size.height)",
                           file: file, line: line)
        }
    }

    func testAnUndrawnEllipseSelectsNothing() {
        var c = MaskComponent(op: .add, kind: .radial)
        c.feather = 50
        c.rotation = 0
        assertSelectsNothing(c, "a radial")
    }

    func testAnUndrawnGradientSelectsNothing() {
        assertSelectsNothing(MaskComponent(op: .add, kind: .linear), "a linear gradient")
    }

    func testAnUndrawnColourFadeSelectsNothing() {
        var c = MaskComponent(op: .add, kind: .similarityLine)
        c.samples = [[0.4, 0.5, 0.6]]
        c.chromaSel = 50
        c.lumaSel = 50
        assertSelectsNothing(c, "a colour fade with a colour but no line")
    }

    func testAnUndrawnOutlineSelectsNothing() {
        assertSelectsNothing(MaskComponent(op: .add, kind: .polygon), "an outline")
    }

    func testAHalfDrawnEllipseSelectsNothingEither() {
        // A centre with no radii, and radii with no centre. Both are reachable by hand
        // editing a sidecar, and neither is a shape.
        var centreOnly = MaskComponent(op: .add, kind: .radial)
        centreOnly.center = [0.5, 0.5]
        assertSelectsNothing(centreOnly, "a radial with a centre and no radii")

        var radiiOnly = MaskComponent(op: .add, kind: .radial)
        radiiOnly.radii = [0.3, 0.3]
        assertSelectsNothing(radiiOnly, "a radial with radii and no centre")
    }

    func testAWholeMaskOfUndrawnComponentsChangesNoPixel() {
        // The claim that actually matters, through the composite the renderer uses: a
        // mask carrying a two-stop lift and nothing to apply it to must leave the
        // photograph exactly as it was, not two stops brighter.
        var mask = Mask(id: "m", name: "not drawn yet")
        mask.adjust.exposure = 2
        mask.components = [MaskComponent(op: .add, kind: .radial),
                           MaskComponent(op: .add, kind: .linear)]

        let image = ImageBuffer(width: 12, height: 9) { u, v in RGB(0.2 + u * 0.5, v, 0.3) }
        let alpha = MaskRaster.combine(mask: mask, size: (width: 12, height: 9))
        let out = ReferenceRenderer.applyMasks(image, plan: RenderPlan(recipe: Recipe()),
                                               alphas: [(mask, alpha)],
                                               space: .rec2020)
        for i in 0..<out.pixels.count {
            XCTAssertEqual(Double(out.pixels[i]), Double(image.pixels[i]), accuracy: 0,
                           "an undrawn mask moved a pixel")
        }
    }

    func testAnUndrawnMaskWithInvertTickedIsStillEmpty() {
        // THE ONE THAT WOULD HAVE BEEN WORST, and it is newly reachable because the
        // picker stopped seeding geometry. `invert` flips the folded alpha, so an empty
        // stack inverted is the WHOLE FRAME — and there is now a window of seconds
        // between choosing a kind and drawing it, in which ticking Invert would hand a
        // two-stop lift to the entire photograph.
        //
        // A component that reads INCOMPLETE is not a selection of nothing; it is the
        // absence of a selection, and there is nothing there to invert.
        var mask = Mask(id: "m", name: "not drawn yet")
        mask.invert = true
        mask.components = [MaskComponent(op: .add, kind: .radial)]
        let alpha = MaskRaster.combine(mask: mask, size: (width: 16, height: 16))
        XCTAssertEqual(alpha.values.max().map(Double.init) ?? 1, 0, accuracy: 0)
    }

    func testAMaskWithNoComponentsAtAllIsEmptyInvertedToo() {
        // The same statement, and the one the stack summary has always made in words:
        // "nothing selected yet".
        var mask = Mask(id: "m", name: "empty")
        mask.invert = true
        let alpha = MaskRaster.combine(mask: mask, size: (width: 16, height: 16))
        XCTAssertEqual(alpha.values.max().map(Double.init) ?? 1, 0, accuracy: 0)
    }

    func testAFINISHEDComponentStillInvertsToTheWholeFrame() {
        // The rule is about INCOMPLETE components, not about empty results. A radial
        // that has been drawn somewhere and selects a small disc must still invert to
        // everything else — that is what Invert is for, and narrowing the guard to
        // catch the undrawn case must not touch it.
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [0.5, 0.5]
        c.radii = [0.2, 0.2]
        c.feather = 0
        var mask = Mask(id: "m", name: "drawn", components: [c])
        mask.invert = true
        let alpha = MaskRaster.combine(mask: mask, size: (width: 32, height: 32))
        XCTAssertGreaterThan(Double(alpha[1, 1]), 0.99, "the corner is selected")
        XCTAssertLessThan(Double(alpha[16, 16]), 0.01, "and the disc is not")
    }

    func testOneFinishedComponentAmongUnfinishedOnesStillWorks() {
        // Half-built stacks are ordinary: you add a gradient, then a second component,
        // and the second is undrawn for a moment. The first must keep selecting.
        var drawn = MaskComponent(op: .add, kind: .radial)
        drawn.center = [0.5, 0.5]
        drawn.radii = [0.3, 0.3]
        drawn.feather = 0
        let mask = Mask(id: "m", name: "half built",
                        components: [drawn, MaskComponent(op: .add, kind: .linear)])
        let alpha = MaskRaster.combine(mask: mask, size: (width: 32, height: 32))
        XCTAssertGreaterThan(Double(alpha[16, 16]), 0.99)
    }
}

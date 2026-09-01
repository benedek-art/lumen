// MissingMaskInputTests.swift
// A mask whose input never arrived selects nothing — and inverted, still nothing.
//
// `MaskRaster.combine` already refused to invert a mask nobody had finished making: an
// empty stack inverted is the whole photograph, and that was catastrophic for a mask
// still being drawn. It measured "finished" with `validationError()`, which is a check on
// the RECIPE — a brush passes it the moment it carries a `strokesRef`.
//
// A reference is only a promise that bytes exist somewhere. When the promise is unkept —
// a catalog restored without its blob directory, a sidecar that silently dropped its
// payload above the size cap, a matte not yet generated — the component rasterizes to a
// zero plane. Zero reads as "selects nothing". Invert turns that into "selects
// everything". So an inverted brush dodge on one shoulder became a two-stop lift on the
// entire frame, in the loupe, the overlay and the thumbnails, all of which read the
// in-memory stroke cache rather than the export path's refusal.
//
// These run on Linux against the reference rasterizer, which is the renderer the GPU is
// held to, so the property is pinned where both paths must honour it.

import XCTest
@testable import LumenCore

final class MissingMaskInputTests: XCTestCase {

    private let size = (width: 24, height: 16)

    private func brushMask(invert: Bool, ref: String? = "blob-1") -> Mask {
        var c = MaskComponent(op: .add, kind: .brush)
        c.strokesRef = ref
        var m = Mask(id: "m", components: [c])
        m.invert = invert
        return m
    }

    private func mean(_ p: Plane) -> Double {
        guard !p.values.isEmpty else { return 0 }
        return p.values.reduce(0.0) { $0 + Double($1) } / Double(p.values.count)
    }

    // MARK: - The defect

    /// The one that cost the photograph. No stroke set, no held plane, invert on.
    func testAnInvertedBrushWhoseBlobIsMissingSelectsNothing() {
        let plane = MaskRaster.combine(mask: brushMask(invert: true), size: size)
        XCTAssertEqual(mean(plane), 0, accuracy: 1e-9,
                       "an inverted brush whose strokes never loaded selected the whole "
                       + "frame — the restore-without-blobs case, and every catalog open "
                       + "before the strokes land")
    }

    /// The same mask the right way up: unchanged behaviour, and the control.
    func testAnUninvertedBrushWhoseBlobIsMissingAlsoSelectsNothing() {
        let plane = MaskRaster.combine(mask: brushMask(invert: false), size: size)
        XCTAssertEqual(mean(plane), 0, accuracy: 1e-9)
    }

    /// An AI kind with no matte is the same shape of absence.
    func testAnInvertedSubjectMaskWithNoMatteSelectsNothing() {
        var m = Mask(id: "s", components: [MaskComponent(op: .add, kind: .aiSubject)])
        m.invert = true
        XCTAssertEqual(mean(MaskRaster.combine(mask: m, size: size)), 0, accuracy: 1e-9,
                       "a Subject mask whose matte has not been generated yet is an "
                       + "absent selection, not an empty one")
    }

    // MARK: - What must NOT change

    /// A brush that HAS its strokes still paints, inverted or not. Without this the
    /// guard could be satisfied by refusing every brush, which would pass the three
    /// assertions above and delete the feature.
    func testABrushWithItsStrokesStillPaintsAndStillInverts() {
        var stroke = BrushStroke(size: 0.25, feather: 50, flow: 100, density: 100)
        stroke.points = [BrushPoint(x: 0.5, y: 0.5)]
        let sets = ["blob-1": BrushStrokeSet(strokes: [stroke])]

        let painted = MaskRaster.combine(mask: brushMask(invert: false), size: size,
                                         strokeSets: sets)
        let inverted = MaskRaster.combine(mask: brushMask(invert: true), size: size,
                                          strokeSets: sets)
        XCTAssertGreaterThan(mean(painted), 0,
                             "a brush with strokes must still select something")
        XCTAssertLessThan(mean(inverted), 1,
                          "and its inverse must still be an inverse, not the whole frame")
        XCTAssertEqual(mean(painted) + mean(inverted), 1, accuracy: 1e-6,
                       "invert is a complement wherever the mask is evaluable")
    }

    /// An EMPTY stroke set is a real answer — strokes undone back to nothing — and must
    /// stay distinguishable from strokes that never arrived. Presence is the test, not
    /// point count; this is what stops the fix from being "non-empty strokes only",
    /// which would make an undone brush invert to the whole frame again.
    func testAnEmptyStrokeSetIsAnAnswerAndNotAnAbsence() {
        let sets = ["blob-1": BrushStrokeSet(strokes: [])]
        let inverted = MaskRaster.combine(mask: brushMask(invert: true), size: size,
                                          strokeSets: sets)
        XCTAssertEqual(mean(inverted), 1, accuracy: 1e-6,
                       "a brush whose strokes were undone selects nothing, so inverted "
                       + "it selects everything — that is a decision the photographer "
                       + "made and it must survive")
    }

    /// A mask with one working component and one whose input is missing keeps the
    /// working one, rather than the absence emptying the whole mask through Intersect.
    func testAMissingComponentDoesNotEmptyTheMaskItSitsIn() {
        var radial = MaskComponent(op: .add, kind: .radial)
        radial.center = [0.5, 0.5]
        radial.radii = [0.4, 0.4]
        radial.feather = 0
        var absent = MaskComponent(op: .intersect, kind: .brush)
        absent.strokesRef = "never-stored"

        let alone = MaskRaster.combine(mask: Mask(id: "a", components: [radial]), size: size)
        let withGhost = MaskRaster.combine(mask: Mask(id: "b", components: [radial, absent]),
                                           size: size)
        XCTAssertGreaterThan(mean(alone), 0, "the fixture must select something")
        XCTAssertEqual(mean(withGhost), mean(alone), accuracy: 1e-9,
                       "a component whose data never arrived has nothing to contribute; "
                       + "intersecting with its zero plane deleted the mask")
    }
}

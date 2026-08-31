// BrushSidecarTests.swift
// docs/35 §7.1 — the one defect in the masking plan that loses work.
//
// The sidecar carried the whole recipe, mask parameters included, which is why
// docs/08 §8.9 could claim masks survive catalog loss. But a brush component stores
// only `strokesRef` — a content hash into the blob store — and the blob store lives in
// the catalog. So the claim was false for exactly the mask type a photographer paints
// by hand: restore a sidecar without the store and every brush component rasterized
// EMPTY, forever, with no badge, indistinguishable from a mask that selects nothing on
// purpose.
//
// `testAPaintedMaskSurvivesTheCatalogAndTheBlobStore` is the whole feature. It paints,
// serializes, throws away everything but the sidecar text, reads it back, and asserts
// the mask rasterizes to the same pixels. If that test passes, the promise is kept; if
// it fails, no amount of the rest of this matters.

import XCTest
@testable import LumenCore

final class BrushSidecarTests: XCTestCase {

    private let size = (width: 40, height: 28)

    private func paintedSet() -> BrushStrokeSet {
        let points = (0...10).map { step -> BrushPoint in
            let u = Double(step) / 10
            return BrushPoint(x: 0.2 + 0.6 * u, y: 0.35 + 0.25 * sin(u * 3.1),
                              pressure: 0.4 + 0.6 * u, t: step * 12)
        }
        let second = (0...6).map { step -> BrushPoint in
            let u = Double(step) / 6
            return BrushPoint(x: 0.3 + 0.4 * u, y: 0.7, pressure: 1, t: step * 9)
        }
        return BrushStrokeSet(strokes: [
            BrushStroke(points: points, size: 0.12, feather: 65, flow: 70,
                        density: 85, erase: false, automask: false),
            BrushStroke(points: second, size: 0.08, feather: 20, flow: 100,
                        density: 100, erase: false, automask: false),
        ])
    }

    private func recipe(ref: String) -> Recipe {
        var component = MaskComponent(op: .add, kind: .brush)
        component.strokesRef = ref
        var mask = Mask(id: "m1", name: "Painted", components: [component])
        mask.adjust.exposure = 0.8
        var r = Recipe()
        r.masks = [mask]
        return r
    }

    private func plane(_ recipe: Recipe, _ sets: [String: BrushStrokeSet]) -> Plane {
        MaskRaster.combine(mask: recipe.masks[0], size: size, source: nil, strokeSets: sets)
    }

    // MARK: - The promise

    func testAPaintedMaskSurvivesTheCatalogAndTheBlobStore() throws {
        let set = paintedSet()
        let ref = try set.blobRef()
        let original = recipe(ref: ref)
        let before = plane(original, [ref: set])

        // Write the sidecar the way the app does: recipe JSON plus the stroke payload,
        // resolved out of a blob store that is about to cease to exist.
        let store: [String: BrushStrokeSet] = [ref: set]
        let content = SidecarContent(
            rating: 3,
            recipeJSON: try CanonicalJSON.canonicalRecipeJSON(original),
            strokesPayload: BrushStrokeSidecar.payload(for: original) { store[$0] })
        XCTAssertNotNil(content.strokesPayload,
                        "a recipe with a painted brush mask must produce a payload")
        let text = XMPSidecar.serialize(content)

        // Now everything except those bytes is gone: no catalog, no blob store.
        let read = try XCTUnwrap(XMPSidecar.parse(text))
        let restoredRecipe = try XCTUnwrap(
            read.recipeJSON.flatMap { try? CanonicalJSON.decodeRecipe(from: Data($0.utf8)) })
        let restoredSets = BrushStrokeSidecar.decode(try XCTUnwrap(read.strokesPayload))

        XCTAssertEqual(restoredSets.count, 1)
        let after = plane(restoredRecipe, restoredSets)

        var worst: Double = 0
        for i in 0..<before.values.count {
            worst = Swift.max(worst, abs(Double(before.values[i]) - Double(after.values[i])))
        }
        XCTAssertEqual(worst, 0, accuracy: 0,
                       "the restored mask must rasterize to the same pixels — this is the "
                           + "whole of the promise that masks survive catalog loss")
        XCTAssertGreaterThan(before.values.map(Double.init).reduce(0, +), 1,
                             "the fixture must actually paint something, or this proves nothing")
    }

    func testWithoutThePayloadTheRestoredMaskIsEmptyWhichIsTheDefect() throws {
        // The before-state, kept as a test so the reason for the payload cannot be
        // deleted by someone who thinks the recipe alone is enough.
        let set = paintedSet()
        let ref = try set.blobRef()
        let original = recipe(ref: ref)

        let content = SidecarContent(
            recipeJSON: try CanonicalJSON.canonicalRecipeJSON(original),
            strokesPayload: nil)
        let read = try XCTUnwrap(XMPSidecar.parse(XMPSidecar.serialize(content)))
        let restored = try XCTUnwrap(
            read.recipeJSON.flatMap { try? CanonicalJSON.decodeRecipe(from: Data($0.utf8)) })

        // The recipe survives in full…
        XCTAssertEqual(restored.masks.count, 1)
        XCTAssertEqual(restored.masks[0].components[0].strokesRef, ref)
        XCTAssertEqual(restored.masks[0].adjust.exposure, 0.8, accuracy: 1e-9)
        // …and selects nothing, silently.
        XCTAssertEqual(plane(restored, [:]).values.max().map(Double.init) ?? 0, 0, accuracy: 0)
    }

    // MARK: - The payload's own rules

    func testAPhotographWithNoBrushMaskingGrowsNoPayload() throws {
        var r = Recipe()
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [0.5, 0.5]
        c.radii = [0.3, 0.3]
        r.masks = [Mask(id: "m", name: "radial", components: [c])]
        XCTAssertNil(BrushStrokeSidecar.payload(for: r) { _ in nil })
    }

    func testAnUnreadableReferenceSkipsItselfRatherThanTheWholeMap() throws {
        let good = paintedSet()
        let goodRef = try good.blobRef()
        var r = recipe(ref: goodRef)
        var missing = MaskComponent(op: .add, kind: .brush)
        missing.strokesRef = "blob:xxh64:deadbeefdeadbeef"
        r.masks.append(Mask(id: "m2", name: "lost", components: [missing]))

        let store: [String: BrushStrokeSet] = [goodRef: good]
        let payload = try XCTUnwrap(BrushStrokeSidecar.payload(for: r) { store[$0] })
        let back = BrushStrokeSidecar.decode(payload)
        XCTAssertEqual(Array(back.keys), [goodRef],
                       "one unreadable blob must not cost the ones that are fine")
    }

    func testTwoMasksSharingOneBlobStoreItOnce() throws {
        let set = paintedSet()
        let ref = try set.blobRef()
        var r = recipe(ref: ref)
        var shared = MaskComponent(op: .subtract, kind: .brush)
        shared.strokesRef = ref
        r.masks.append(Mask(id: "m2", name: "same painting", components: [shared]))

        var asked = 0
        let payload = try XCTUnwrap(BrushStrokeSidecar.payload(for: r) { key in
            asked += 1
            return key == ref ? set : nil
        })
        XCTAssertEqual(asked, 1, "the blob store is asked once per reference, not per component")
        XCTAssertEqual(BrushStrokeSidecar.decode(payload).count, 1)
    }

    func testAPayloadWhoseKeyDoesNotAddressItsContentIsDropped() throws {
        // Hand-edited or corrupted past base64's ability to notice. Restoring the set
        // under the wrong reference would put somebody else's painting into this mask,
        // which is worse than the mask being empty.
        let set = paintedSet()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let forged = ["blob:xxh64:0000000000000000": set]
        let payload = try encoder.encode(forged).base64EncodedString()
        XCTAssertTrue(BrushStrokeSidecar.decode(payload).isEmpty)
    }

    func testGarbageDecodesToAnEmptyMapRatherThanThrowing() {
        XCTAssertTrue(BrushStrokeSidecar.decode("").isEmpty)
        XCTAssertTrue(BrushStrokeSidecar.decode("   \n  ").isEmpty)
        XCTAssertTrue(BrushStrokeSidecar.decode("not base64 !!!").isEmpty)
        XCTAssertTrue(BrushStrokeSidecar.decode(Data("{}".utf8).base64EncodedString()).isEmpty)
        XCTAssertTrue(BrushStrokeSidecar.decode(
            Data("[1,2,3]".utf8).base64EncodedString()).isEmpty)
    }

    func testTheStrokePayloadRoundTripsThroughXMLEscaping() throws {
        // Base64's alphabet contains `+` and `/` and the padding `=`; the element also
        // passes through `escapeXML`. This is the guard that the two agree.
        let set = paintedSet()
        let ref = try set.blobRef()
        let r = recipe(ref: ref)
        let store: [String: BrushStrokeSet] = [ref: set]
        let payload = try XCTUnwrap(BrushStrokeSidecar.payload(for: r) { store[$0] })
        let read = try XCTUnwrap(XMPSidecar.parse(
            XMPSidecar.serialize(SidecarContent(strokesPayload: payload))))
        XCTAssertEqual(read.strokesPayload, payload)
    }
}

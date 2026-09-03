// MaskReferenceIdentityTests.swift
// THE RENDER KEY MUST CHANGE WHEN AND ONLY WHEN THE PICTURE WOULD — and a mask's id is
// not cosmetic once another mask names it.
//
// `Recipe.renderIdentity` blanked every mask's id, on the argument that an id is a
// random UUID and hashing it made renaming a mask throw away every cached render.
// That argument is exactly right for a mask nobody points at, and the projection was
// audited against precisely that case: `RobustnessTests
// .testCosmeticsDoNotChangeTheRenderKeyButRealEditsDo` changes a mask's id and asserts
// the fingerprint holds, using a mask whose `components` array is EMPTY.
//
// The reachable space is larger by one dimension. A `.maskRef` component names another
// mask BY ID and `MaskRaster.referenced` resolves it against the same list, so on the
// slice the audit never swept — a recipe that carries a reference — the id IS a pixel.
// Both directions of "when and only when" fail there, and this file states each as the
// pair of recipes that exhibits it:
//
//   · SAME KEY, DIFFERENT PICTURE. Move the target's id and the reference dangles;
//     `referenced` reports ABSENT, the component is skipped, and the mask selects
//     nothing. Both recipes blanked to `id: ""`, so `recipe_fp` was identical and
//     `rendersSameAs` said true — a cache key that serves the other render, and a
//     library that calls a real edit no edit.
//
//   · DIFFERENT KEY, SAME PICTURE. Build the same two-mask stack twice with fresh
//     UUIDs — which is what "Paste Masks" onto a photo that already holds the mask
//     produces, since `appendingMasks` re-issues the colliding ids and remaps the
//     references with them. The pictures are identical and the UUID leaked back into
//     the hash through `maskRef`, so the two photographs could never share an artifact.
//     That is the very cost the blanking exists to avoid.
//
// The fix keeps the structure and drops the arbitrary bytes: a mask's canonical id is
// its position in the stack, and every reference is rewritten to the canonical id of the
// mask it actually resolves to (first-wins on a duplicate, as every reader resolves).
//
// NOTHING HERE MOVES A PIXEL. `renderIdentity` is only ever hashed or compared; the
// stored recipe and every rasterizer are untouched. Recipes with no reference keep the
// blanking and therefore keep their existing `recipe_fp`.

import XCTest
@testable import LumenCore

final class MaskReferenceIdentityTests: XCTestCase {

    private let size = (width: 48, height: 32)

    private func radial(_ cx: Double) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [cx, 0.5]
        c.radii = [0.25, 0.4]
        c.feather = 0
        return c
    }

    private func reference(_ id: String) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .maskRef)
        c.maskRef = id
        return c
    }

    /// The mask that carries the reference, rendered through the one resolver.
    private func coverage(_ recipe: Recipe, _ index: Int) -> Double {
        MaskRaster.combine(mask: recipe.masks[index], size: size,
                           masks: recipe.masks).mean
    }

    // MARK: - Same key, different picture

    func testMovingTheIdAReferencePointsAtChangesThePictureAndMustChangeTheKey() throws {
        var resolving = Recipe()
        resolving.masks = [
            Mask(id: "sky-0", name: "Sky", components: [radial(0.35)]),
            Mask(id: "ref-0", name: "Sky again", components: [reference("sky-0")]),
        ]
        var dangling = resolving
        dangling.masks[0].id = "sky-1"

        // The two recipes really do render different pictures: the reference lends the
        // whole of the target's selection in one and nothing at all in the other.
        let lent = coverage(resolving, 1)
        let absent = coverage(dangling, 1)
        XCTAssertGreaterThan(lent, 0.05,
                             "the fixture's reference selects nothing even when it "
                                 + "resolves — the test cannot tell the two apart")
        XCTAssertEqual(absent, 0, accuracy: 1e-12,
                       "a reference to an id no mask carries must be absent, not empty")

        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(resolving),
                          try RecipeFingerprint.fingerprint(dangling),
                          "two recipes rendering \(lent) and \(absent) of the frame "
                              + "were handed the same recipe_fp — the cache will serve "
                              + "one photograph's render for the other")
        XCTAssertFalse(resolving.rendersSameAs(dangling),
                       "rendersSameAs called a real edit no edit")
    }

    /// The same defect one step further in, because a chain is what a reference is for:
    /// A ← B ← C, and moving A's id empties both B and C.
    func testAChainNoticesTheMovedIdToo() throws {
        var resolving = Recipe()
        resolving.masks = [
            Mask(id: "a", name: "A", components: [radial(0.35)]),
            Mask(id: "b", name: "B", components: [reference("a")]),
            Mask(id: "c", name: "C", components: [reference("b")]),
        ]
        var moved = resolving
        moved.masks[0].id = "a-moved"

        XCTAssertGreaterThan(coverage(resolving, 2), 0.05)
        XCTAssertEqual(coverage(moved, 2), 0, accuracy: 1e-12)
        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(resolving),
                          try RecipeFingerprint.fingerprint(moved),
                          "a chain that went empty did not change the render key")
    }

    /// Which mask a reference names is a pixel, so pointing it somewhere else must
    /// change the key. This one held before the fix and holds after it — it is here so
    /// the canonicalization cannot be satisfied by throwing the reference away.
    func testPointingAReferenceAtADifferentMaskStillChangesTheKey() throws {
        var left = Recipe()
        left.masks = [
            Mask(id: "one", name: "One", components: [radial(0.25)]),
            Mask(id: "two", name: "Two", components: [radial(0.75)]),
            Mask(id: "ref", name: "Ref", components: [reference("one")]),
        ]
        var right = left
        right.masks[2].components = [reference("two")]

        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(left),
                          try RecipeFingerprint.fingerprint(right),
                          "re-pointing a reference did not reach the render key")
    }

    // MARK: - Different key, same picture

    func testTheSameStackBuiltWithDifferentUUIDsIsOneRenderIdentity() throws {
        func stack(_ target: String, _ pointer: String) -> Recipe {
            var r = Recipe()
            r.masks = [
                Mask(id: target, name: "Sky", components: [radial(0.35)]),
                Mask(id: pointer, name: "Sky again", components: [reference(target)]),
            ]
            return r
        }
        let onePhoto = stack("11111111-1111-1111-1111-111111111111",
                             "22222222-2222-2222-2222-222222222222")
        let another = stack("33333333-3333-3333-3333-333333333333",
                            "44444444-4444-4444-4444-444444444444")

        // Same picture, mask for mask.
        for index in 0..<2 {
            XCTAssertEqual(coverage(onePhoto, index), coverage(another, index),
                           accuracy: 1e-12,
                           "the two fixtures are not the same picture at mask \(index)")
        }
        XCTAssertEqual(try RecipeFingerprint.fingerprint(onePhoto),
                       try RecipeFingerprint.fingerprint(another),
                       "two photographs given the same mask stack got different keys "
                           + "because the UUID leaked back in through maskRef — they "
                           + "can never share a cached artifact")
        XCTAssertTrue(onePhoto.rendersSameAs(another))
    }

    /// Paste Masks is the gesture that produces it: appending a batch onto a photo that
    /// already holds the same mask re-issues the colliding ids and remaps the references
    /// with them, so the picture is unchanged and every id in the batch is new.
    func testPasteMasksReIssuesIdsWithoutChangingThePictureOrTheKey() throws {
        var source = Recipe()
        source.masks = [
            Mask(id: "sky", name: "Sky", components: [radial(0.35)]),
            Mask(id: "ref", name: "Sky again", components: [reference("sky")]),
        ]
        // Pasting onto a photo that already carries `sky` forces the re-issue.
        var target = Recipe()
        target.masks = [Mask(id: "sky", name: "Existing", components: [radial(0.8)])]

        let once = target.appendingMasks(from: source)
        let twice = target.appendingMasks(from: source)
        XCTAssertNotEqual(once.masks[1].id, twice.masks[1].id,
                          "the fixture did not exercise the re-issue")

        for index in 0..<once.masks.count {
            XCTAssertEqual(coverage(once, index), coverage(twice, index),
                           accuracy: 1e-12,
                           "two pastes of one batch are not the same picture at \(index)")
        }
        XCTAssertEqual(try RecipeFingerprint.fingerprint(once),
                       try RecipeFingerprint.fingerprint(twice),
                       "the same paste, twice, produced two render keys")
    }

    // MARK: - The neighbours the canonicalization must not disturb

    /// Renaming is still free, and a mask nobody points at still keys on nothing —
    /// which is what `RobustnessTests` asserts and what must not regress.
    func testAMaskNobodyPointsAtStillHasACosmeticId() throws {
        var one = Recipe()
        one.develop.tone.exposure = 0.4
        one.masks = [Mask(id: "a", name: "Sky", components: [radial(0.5)])]
        var other = one
        other.masks[0].id = "b"
        other.masks[0].name = "Sky (final)"
        XCTAssertEqual(try RecipeFingerprint.fingerprint(one),
                       try RecipeFingerprint.fingerprint(other),
                       "renaming a mask changed the render key")
    }

    /// Every way a reference can fail to resolve renders the same — absent — so they
    /// are one identity. Deleted, never-there and empty must not be three keys.
    func testEveryUnresolvableReferenceIsOneIdentityBecauseItIsOnePicture() throws {
        func pointing(at ref: String) -> Recipe {
            var r = Recipe()
            r.masks = [
                Mask(id: "sky", name: "Sky", components: [radial(0.35)]),
                Mask(id: "ref", name: "Ref", components: [reference(ref)]),
            ]
            return r
        }
        let gone = pointing(at: "deleted-mask")
        let never = pointing(at: "never-existed")
        for recipe in [gone, never] {
            XCTAssertEqual(coverage(recipe, 1), 0, accuracy: 1e-12,
                           "the fixture's reference resolved after all")
        }
        XCTAssertEqual(try RecipeFingerprint.fingerprint(gone),
                       try RecipeFingerprint.fingerprint(never),
                       "two references that both dangle render the same nothing and "
                           + "must not be two cache keys")
    }

    /// Colliding ids are a state this format can carry — `Mask.init(from:)` invents an
    /// id when the key is absent, and `appendingMasks` re-issues rather than merges — so
    /// the projection has to resolve them the way every reader does: first wins.
    func testADuplicateIdHashesAsThePictureItRendersRatherThanTheOneItDescribes() throws {
        var collided = Recipe()
        collided.masks = [
            Mask(id: "same", name: "First", components: [radial(0.25)]),
            Mask(id: "same", name: "Second", components: [radial(0.75)]),
            Mask(id: "ref", name: "Ref", components: [reference("same")]),
        ]
        // The reference resolves to the FIRST mask carrying the id, so this recipe
        // renders exactly as one whose second mask carries a distinct id.
        var distinct = collided
        distinct.masks[1].id = "different"

        XCTAssertEqual(coverage(collided, 2), coverage(distinct, 2), accuracy: 1e-12,
                       "the fixture's two recipes are not the same picture")
        XCTAssertEqual(try RecipeFingerprint.fingerprint(collided),
                       try RecipeFingerprint.fingerprint(distinct),
                       "a duplicate id changed the key without changing the render")
    }
}

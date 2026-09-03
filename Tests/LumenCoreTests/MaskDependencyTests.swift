// MaskDependencyTests.swift
// A MASK BUILT ON A SWITCHED-OFF MASK MUST STILL HAVE A SELECTION, and the two
// neighbouring cases — a dependency that has been DELETED and one that closes a CYCLE —
// must both be defined and neither may hang.
//
// The rule itself was never in doubt and has been pinned twice: `enabled` says whether a
// mask's ADJUSTMENTS reach the picture, never that it stops SELECTING
// (`MaskChannelAndReferenceTests.testADisabledMaskStillLendsItsSelection`), and both
// renderers resolve a reference against `RenderPlan.allMasks` rather than the filtered
// list (`MaskGroupTests.testTheRendererResolvesAReferenceAgainstEveryMaskAndNotJustThe
// EnabledOnes`).
//
// WHAT NEITHER OF THOSE COULD SEE is that a mask does not rasterize out of thin air.
// Every kind that reads an INPUT — a Vision matte, a brush blob — is evaluable only if
// something fetched that input first, and the rosters that decide what to fetch were a
// separate walk of the recipe that stopped at `where mask.enabled`. So the promise held
// for a radial and broke for a Subject mask: switch A off, and B's "Another Mask → A"
// renders as nothing, in the loupe and in the delivered file, with no badge anywhere,
// because B's row is a reference row and never reaches the model note (audit F5-01).
//
// The fix is one walk — `MaskDependency.contributing` — that every roster asks, and one
// resolver — `MaskRaster.combine` — that every renderer calls. This file measures both,
// and it measures them by SUBSTITUTION: each test carries the walk it replaced, so the
// old answer is computed side by side with the new one rather than described.

import XCTest
@testable import LumenCore

final class MaskDependencyTests: XCTestCase {

    private let size = (width: 40, height: 28)

    // MARK: - Fixtures

    private func radial(_ cx: Double) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [cx, 0.5]
        c.radii = [0.25, 0.4]
        c.feather = 0
        return c
    }

    private func reference(_ id: String, op: MaskOp = .add) -> MaskComponent {
        var c = MaskComponent(op: op, kind: .maskRef)
        c.maskRef = id
        return c
    }

    private func brush(_ ref: String) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .brush)
        c.strokesRef = ref
        return c
    }

    /// The matte the segmenter would produce for a Subject: the left half of the frame.
    private func subjectMatte() -> Plane {
        Plane(width: size.width, height: size.height) { x, _ in x < 0.5 ? 1 : 0 }
    }

    /// Mean alpha — "does this mask still have area", in one number.
    private func area(_ p: Plane) -> Double {
        p.values.reduce(0.0) { $0 + Double($1) } / Double(p.values.count)
    }

    /// A recipe with the whole defect in it: A is a Subject mask the photographer has
    /// switched off to look past it, B is built on A and is the mask doing the work.
    private func switchedOffDependency() -> Recipe {
        var a = Mask(id: "a", name: "Subject", components: [MaskComponent(op: .add,
                                                                          kind: .aiSubject)])
        a.enabled = false
        var b = Mask(id: "b", name: "Skin", components: [reference("a")])
        b.adjust.exposure = 1
        var recipe = Recipe()
        recipe.masks = [a, b]
        return recipe
    }

    // MARK: - The two rosters, as functions this file can substitute one for the other

    /// What the matte generator asks for today.
    private func roster(_ recipe: Recipe) -> Set<MaskKind> {
        MaskDependency.wantedMattes(in: recipe, from: .vision)
    }

    /// What it asked for before — `for mask in recipe.masks where mask.enabled`, copied
    /// out verbatim so the defect is computed here rather than remembered.
    private func rosterBeforeTheFix(_ recipe: Recipe) -> Set<MaskKind> {
        var wanted: Set<MaskKind> = []
        for mask in recipe.masks where mask.enabled {
            for component in mask.components
            where component.kind.matteProvider == .vision {
                wanted.insert(component.kind)
            }
        }
        return wanted
    }

    /// One render, in the shape BOTH shipping paths have: fetch exactly the inputs the
    /// roster asks for, then resolve the mask through the one resolver against the
    /// plan's unfiltered list.
    private func render(_ recipe: Recipe, mask id: String,
                        roster: (Recipe) -> Set<MaskKind>) -> Plane {
        var mattes: [String: Plane] = [:]
        for kind in roster(recipe) { mattes[kind.rawValue] = subjectMatte() }
        guard let target = recipe.masks.first(where: { $0.id == id }) else {
            return Plane(width: size.width, height: size.height)
        }
        return MaskRaster.combine(mask: target, size: size, aiMattes: mattes,
                                  masks: RenderPlan(recipe: recipe).allMasks)
    }

    // MARK: - F5-01 · a disable is not a delete

    func testAMaskBuiltOnASwitchedOffMaskStillHasArea() {
        let recipe = switchedOffDependency()

        XCTAssertTrue(roster(recipe).contains(.aiSubject),
                      "nothing asked for the matte the reference needs, so the mask it "
                          + "points at has no selection to lend")

        let now = area(render(recipe, mask: "b", roster: roster))
        XCTAssertGreaterThan(now, 0.3,
                             "a mask built on a switched-off mask rendered as nothing")

        // The substitution, computed rather than described: put the `enabled` filter
        // back and the same fixture, through the same resolver, comes out empty.
        XCTAssertEqual(area(render(recipe, mask: "b", roster: rosterBeforeTheFix)), 0,
                       accuracy: 0,
                       "the fixture cannot show the defect it was built for")
    }

    /// The same rule one level up, because a folder is how a photographer switches six
    /// masks off at once.
    func testAMaskBuiltOnAMemberOfASwitchedOffFolderStillHasArea() {
        var recipe = switchedOffDependency()
        recipe.masks[0].enabled = true
        recipe.masks[0].group = "g"
        recipe.maskGroups = [MaskGroup(id: "g", name: "sources", enabled: false)]

        XCTAssertFalse(recipe.effective(recipe.masks[0]).enabled,
                       "the fixture needs a member that is off through its folder")
        XCTAssertTrue(roster(recipe).contains(.aiSubject))
        XCTAssertGreaterThan(area(render(recipe, mask: "b", roster: roster)), 0.3)
    }

    /// The blob half of the same defect, and the one the audit did not name: a painted
    /// mask switched off still lends its selection, and it can only lend it if the bytes
    /// were fetched. `unresolvedReferences` is also what WARMS the cache the export then
    /// reads, so a blob missing from this roster is masking missing from the file.
    func testTheBlobRosterFollowsAReferenceIntoASwitchedOffMask() {
        var painted = Mask(id: "a", name: "Painted", components: [brush("blob:a")])
        painted.enabled = false
        let user = Mask(id: "b", name: "Skin", components: [reference("a")])
        var recipe = Recipe()
        recipe.masks = [painted, user]

        XCTAssertEqual(BrushStrokes.references(in: recipe), ["blob:a"],
                       "the export would not have fetched the blob the render asks for")

        let unreadable = BrushStrokes.unresolvedReferences(in: recipe) { _ in false }
        XCTAssertEqual(unreadable, ["blob:a"],
                       "an unreadable blob behind a live reference did not refuse the "
                           + "delivery — the file goes out with the masking absent")
    }

    /// And the rule that keeps the roster honest in the other direction, which is the
    /// one `MaskingTests` already relies on: a switched-off mask NOBODY points at costs
    /// nothing, because refusing a delivery over a mask the photographer already turned
    /// off is a refusal with no picture behind it.
    func testASwitchedOffMaskNobodyPointsAtIsStillLeftOutOfTheRoster() {
        var lonely = Mask(id: "a", name: "Painted", components: [brush("blob:a")])
        lonely.enabled = false
        let other = Mask(id: "b", name: "Sky", components: [radial(0.5)])
        var recipe = Recipe()
        recipe.masks = [lonely, other]

        XCTAssertEqual(BrushStrokes.references(in: recipe), [],
                       "a blob nothing will rasterize was fetched anyway")
        XCTAssertEqual(MaskDependency.contributing(in: recipe).map(\.id), ["b"])
    }

    // MARK: - The neighbouring cases

    /// A DELETED dependency is ABSENT, not empty. The difference is the whole stack: an
    /// empty plane folded under `.intersect` is `a × 0`, which takes every other
    /// component down with it, and folded under a whole-mask `invert` it is the entire
    /// photograph.
    func testADeletedDependencyIsAbsentRatherThanEmpty() {
        var recipe = Recipe()
        let survivor = Mask(id: "b", name: "Skin",
                            components: [radial(0.5), reference("gone", op: .intersect)])
        recipe.masks = [survivor]

        let alpha = MaskRaster.combine(mask: survivor, size: size,
                                       masks: RenderPlan(recipe: recipe).allMasks)
        XCTAssertGreaterThan(alpha.values.max().map(Double.init) ?? 0, 0.9,
                             "deleting the mask B was built on silently emptied B")

        // It is exactly what the surviving component selects — inert, not merely
        // survivable, which is the rule `UndrawnComponentFoldTests` states for every
        // other unfinished component.
        let alone = Mask(id: "b", name: "Skin", components: [radial(0.5)])
        let expected = MaskRaster.combine(mask: alone, size: size)
        for i in 0..<expected.values.count {
            XCTAssertEqual(alpha.values[i], expected.values[i], accuracy: 1e-6,
                           "a dangling reference changed pixel \(i)")
        }
    }

    /// And the case that is a two-stop lift on the whole photograph rather than a
    /// missing edit: a mask whose only component points at something deleted, with
    /// Invert on. There is nothing there to invert.
    func testADeletedDependencyIsNotInvertedIntoTheWholeFrame() {
        var orphan = Mask(id: "b", name: "Skin", components: [reference("gone")])
        orphan.invert = true
        var recipe = Recipe()
        recipe.masks = [orphan]

        let alpha = MaskRaster.combine(mask: orphan, size: size,
                                       masks: RenderPlan(recipe: recipe).allMasks)
        XCTAssertEqual(alpha.values.max().map(Double.init) ?? 1, 0, accuracy: 0,
                       "a reference to a deleted mask, inverted, selected the whole frame")
    }

    /// The same, one step further out: the target is present but has no selection to
    /// lend, because its own input never arrived. "Selects nothing" would be a claim
    /// about the picture that nothing measured.
    func testADependencyWhoseInputNeverArrivedIsAbsentToo() {
        let recipe = switchedOffDependency()
        var pointer = recipe.masks[1]
        pointer.invert = true

        // No mattes at all — the state before the pass has run, or after a restore.
        let alpha = MaskRaster.combine(mask: pointer, size: size,
                                       masks: RenderPlan(recipe: recipe).allMasks)
        XCTAssertEqual(alpha.values.max().map(Double.init) ?? 1, 0, accuracy: 0,
                       "a mask waiting for its matte was inverted into the whole frame")
    }

    /// A CYCLE terminates, does not grow a stack, and does not take the rest of the
    /// stack with it. A → B → A has no fixed point to be right about, so the reference
    /// is absent; the radial beside it is not.
    func testACycleTerminatesAndLeavesTheRestOfTheStackStanding() {
        var recipe = Recipe()
        let a = Mask(id: "a", name: "A",
                     components: [radial(0.5), reference("b", op: .intersect)])
        let b = Mask(id: "b", name: "B", components: [reference("a")])
        recipe.masks = [a, b]

        let alpha = MaskRaster.combine(mask: a, size: size,
                                       masks: RenderPlan(recipe: recipe).allMasks)
        XCTAssertGreaterThan(alpha.values.max().map(Double.init) ?? 0, 0.9,
                             "a cycle emptied the component that had nothing to do with it")

        // A mask that names itself is the same statement with one fewer hop.
        var recipeSelf = Recipe()
        let loop = Mask(id: "l", name: "L",
                        components: [radial(0.5), reference("l", op: .intersect)])
        recipeSelf.masks = [loop]
        XCTAssertGreaterThan(
            MaskRaster.combine(mask: loop, size: size,
                               masks: RenderPlan(recipe: recipeSelf).allMasks)
                .values.max().map(Double.init) ?? 0, 0.9)

        // And the roster walk terminates on the same shape rather than following the
        // loop forever: reachability visits an id once.
        XCTAssertEqual(MaskDependency.contributing(in: recipe).map(\.id), ["a", "b"])
        XCTAssertEqual(MaskDependency.contributing(in: recipeSelf).map(\.id), ["l"])
    }

    /// A chain long enough to be a mistake stops rather than growing a stack, and a
    /// chain a photograph could justify still resolves. `referenceDepthLimit` is the
    /// belt; the cycle guard is the brace.
    func testAnAbsurdlyLongChainStopsWithoutHanging() {
        var recipe = Recipe()
        var masks = [Mask(id: "leaf", name: "leaf", components: [radial(0.5)])]
        var previous = "leaf"
        for step in 0..<40 {
            let id = "n\(step)"
            masks.append(Mask(id: id, name: id, components: [reference(previous)]))
            previous = id
        }
        recipe.masks = masks

        let head = masks[masks.count - 1]
        let alpha = MaskRaster.combine(mask: head, size: size,
                                       masks: RenderPlan(recipe: recipe).allMasks)
        XCTAssertEqual(alpha.values.max().map(Double.init) ?? 1, 0, accuracy: 0)
        XCTAssertEqual(MaskDependency.contributing(in: recipe).count, masks.count,
                       "the walk must still terminate over the whole chain")
    }

    /// What a mask's RASTER depends on, which is the cache's question rather than the
    /// fetch's. A reference is a live view, so the thing that keys a baked raster has to
    /// name the mask it points at or the loupe serves a picture from before the edit.
    func testAMasksRasterDependsOnEverythingItPointsAt() {
        let sky = Mask(id: "sky", name: "Sky", components: [radial(0.3)])
        let person = Mask(id: "person", name: "Person", components: [radial(0.7)])
        let both = Mask(id: "both", name: "Sky ∩ Person",
                        components: [reference("sky"), reference("person", op: .intersect)])
        let unrelated = Mask(id: "u", name: "Other", components: [radial(0.5)])
        let all = [sky, person, both, unrelated]

        XCTAssertEqual(MaskDependency.closure(of: both, in: all).map(\.id),
                       ["sky", "person", "both"],
                       "a raster key built on this walk would miss an edit to a source")
        XCTAssertEqual(MaskDependency.closure(of: sky, in: all).map(\.id), ["sky"],
                       "a mask that points at nothing must not be keyed on the recipe")

        // A cycle is a finite key, not a hang, and a dangling name adds nothing.
        let loop = Mask(id: "l", name: "L", components: [reference("l")])
        XCTAssertEqual(MaskDependency.closure(of: loop, in: [loop]).map(\.id), ["l"])
        let orphan = Mask(id: "o", name: "O", components: [reference("gone")])
        XCTAssertEqual(MaskDependency.closure(of: orphan, in: [orphan]).map(\.id), ["o"])
    }

    // MARK: - One resolver, called by both

    /// The loupe and the export do not each resolve a reference; they call the same
    /// function with the same list.
    ///
    /// `MaskRaster.combine` is the only door — `ReferenceRenderer` calls it for every
    /// mask, `PipelineRenderer` calls it for every mask the closed-form GPU path
    /// declines, and `MaskGPU.isParametric` declines `.maskRef` outright — and the list
    /// it is given is `RenderPlan.allMasks`, which is built the same way at every
    /// fidelity a plan comes in. So the three plans a photograph is rendered through
    /// (a draft frame mid-drag, the settle behind it, the delivery) cannot disagree.
    func testTheLoupeAndTheExportResolveTheDependencyThroughOneResolver() {
        let recipe = switchedOffDependency()
        let mattes = [MaskKind.aiSubject.rawValue: subjectMatte()]
        let pointer = recipe.masks[1]

        let draft = RenderPlan(recipe: recipe, lutSize: LUT3D.interactiveSize,
                               allowStaleTables: true)
        let settle = RenderPlan(recipe: recipe, lutSize: LUT3D.interactiveSize)
        let delivery = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)

        var alphas: [Plane] = []
        for plan in [draft, settle, delivery] {
            XCTAssertEqual(plan.masks.map(\.id), ["b"],
                           "the switched-off mask's own adjustments must stay out")
            XCTAssertEqual(plan.allMasks.map(\.id), ["a", "b"],
                           "and it must still be there to be pointed at")
            alphas.append(MaskRaster.combine(mask: pointer, size: size, aiMattes: mattes,
                                             masks: plan.allMasks))
        }

        XCTAssertGreaterThan(area(alphas[0]), 0.3, "the fixture selects nothing")
        for (index, alpha) in alphas.enumerated() {
            for i in 0..<alpha.values.count {
                XCTAssertEqual(alpha.values[i], alphas[0].values[i], accuracy: 0,
                               "plan \(index) resolved the dependency differently at "
                                   + "pixel \(i)")
            }
        }

        // And the INPUT roster is one function too, which is where the two paths
        // actually parted company: the resolver's promise is only keepable if whatever
        // fetches mattes and blobs followed the same reference.
        XCTAssertEqual(MaskDependency.wantedMattes(in: recipe, from: .vision),
                       [.aiSubject])
        XCTAssertEqual(MaskDependency.contributing(in: recipe).map(\.id), ["a", "b"])
    }

    /// The roster is narrowed to ONE PROVIDER at the walk rather than at the caller,
    /// and the narrowing is load-bearing: `VisionMattes.kinds(in:)` is asked "what
    /// should the segmenter generate", and a kind no on-device framework can serve has
    /// no business in that answer. Handing `.aiSky` to a Vision pass records an ATTEMPT
    /// for a request never issued, and an attempt with nothing found is exactly what
    /// the panel prints as "Vision found no clear subject" — a specific, actionable
    /// error message about a model that is not bundled and never ran.
    func testTheRosterIsNarrowedToTheProviderThatWasAskedFor() {
        var sky = Mask(id: "sky", name: "Sky",
                       components: [MaskComponent(op: .add, kind: .aiSky)])
        sky.enabled = false
        let subject = Mask(id: "s", name: "Subject",
                           components: [MaskComponent(op: .add, kind: .aiSubject)])
        let user = Mask(id: "b", name: "Skin",
                        components: [reference("sky"), reference("s", op: .intersect),
                                     radial(0.5)])
        var recipe = Recipe()
        recipe.masks = [sky, subject, user]

        XCTAssertEqual(MaskDependency.wantedMattes(in: recipe, from: .vision),
                       [.aiSubject],
                       "a kind no on-device framework can serve reached the segmenter's "
                           + "roster, which records an attempt for a request never made")
        XCTAssertEqual(MaskDependency.wantedMattes(in: recipe, from: .model), [.aiSky],
                       "the un-bundled half of the same reference went missing, so "
                           + "nothing can say which model the mask is waiting for")
        XCTAssertEqual(MaskDependency.wantedMattes(in: recipe), [.aiSky, .aiSubject],
                       "unnarrowed, the roster is every matte the render needs")

        // And a kind that needs no matte at all is in neither answer, whatever it is
        // reached through.
        XCTAssertFalse(MaskDependency.wantedMattes(in: recipe).contains(.radial))
        XCTAssertFalse(MaskDependency.wantedMattes(in: recipe).contains(.maskRef))
    }

    /// End to end, on pixels, through the renderer the goldens and the headless tooling
    /// use: B's exposure lift has to land where the switched-off A selects.
    func testTheEditLandsOnThePixelsTheSwitchedOffMaskSelects() {
        let recipe = switchedOffDependency()
        let flat = ImageBuffer(width: size.width, height: size.height) { _, _ in
            RGB(gray: 0.18)
        }
        let inputs = ReferenceRenderer.Inputs(
            aiMattes: [MaskKind.aiSubject.rawValue: subjectMatte()])

        let out = ReferenceRenderer.render(flat, plan: RenderPlan(recipe: recipe),
                                           inputs: inputs)
        let inside = out[size.width / 4, size.height / 2]
        let outside = out[(size.width * 3) / 4, size.height / 2]
        XCTAssertGreaterThan(inside.g, outside.g * 1.2,
                             "the mask built on the switched-off mask changed no pixel")

        // With no matte in hand — the state the roster used to leave the render in —
        // nothing moves anywhere, which is the whole complaint.
        let starved = ReferenceRenderer.render(flat, plan: RenderPlan(recipe: recipe),
                                               inputs: ReferenceRenderer.Inputs())
        XCTAssertEqual(starved[size.width / 4, size.height / 2].g,
                       starved[(size.width * 3) / 4, size.height / 2].g, accuracy: 1e-6,
                       "the fixture cannot show the defect it was built for")
    }
}

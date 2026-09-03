// MaskDependencyAdversarialTests.swift
// TRYING TO BREAK "a disable is not a delete".
//
// Everything here is written to REFUTE `MaskDependency`, not to confirm it: the folder
// fold, cycles, dangling references under every op and every invert, the provider
// narrowing, the two rosters agreeing, and — the property that subsumes most of them —
// FETCHING EXACTLY THE ROSTER MUST RENDER THE SAME PIXELS AS FETCHING EVERYTHING, over
// randomly generated recipes rather than hand-picked ones.

import XCTest
@testable import LumenCore

final class MaskDependencyAdversarialTests: XCTestCase {

    private let size = (width: 24, height: 16)

    // MARK: - Fixtures

    private func radial(_ cx: Double, op: MaskOp = .add, invert: Bool = false)
        -> MaskComponent {
        var c = MaskComponent(op: op, kind: .radial, invert: invert)
        c.center = [cx, 0.5]
        c.radii = [0.3, 0.45]
        c.feather = 0
        return c
    }

    private func reference(_ id: String, op: MaskOp = .add, invert: Bool = false)
        -> MaskComponent {
        var c = MaskComponent(op: op, kind: .maskRef, invert: invert)
        c.maskRef = id
        return c
    }

    private func brush(_ ref: String, op: MaskOp = .add) -> MaskComponent {
        var c = MaskComponent(op: op, kind: .brush)
        c.strokesRef = ref
        return c
    }

    private func matteComponent(_ kind: MaskKind, op: MaskOp = .add) -> MaskComponent {
        var c = MaskComponent(op: op, kind: kind)
        switch kind {
        case .aiObject: c.prompt = [[0.5, 0.5]]
        case .depthRange:
            c.depthLo = 0
            c.depthHi = 1
        default: break
        }
        return c
    }

    private static let visionKinds: [MaskKind] = [.aiSubject, .aiBackground, .aiPerson]
    private static let modelKinds: [MaskKind] = [.aiSky, .aiObject, .aiLandscape,
                                                 .depthRange]
    private static var matteKinds: [MaskKind] { visionKinds + modelKinds }

    private func matte(_ shift: Double) -> Plane {
        Plane(width: size.width, height: size.height) { x, _ in x < shift ? 1 : 0 }
    }

    /// Every matte a recipe here could possibly ask for, including the depth map's
    /// alternate key.
    private func allMattes() -> [String: Plane] {
        var out: [String: Plane] = [:]
        for kind in Self.matteKinds { out[kind.rawValue] = matte(0.6) }
        out["depth"] = matte(0.6)
        return out
    }

    private func strokeSet() -> BrushStrokeSet {
        BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.5, y: 0.5),
                                                      BrushPoint(x: 0.55, y: 0.55)],
                                             size: 40)])
    }

    private func area(_ p: Plane) -> Double {
        p.values.reduce(0.0) { $0 + Double($1) } / Double(p.values.count)
    }

    private func assertSamePixels(_ a: Plane, _ b: Plane, _ what: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.width, b.width, what, file: file, line: line)
        XCTAssertEqual(a.height, b.height, what, file: file, line: line)
        guard a.values.count == b.values.count else { return }
        for i in 0..<a.values.count where abs(a.values[i] - b.values[i]) > 1e-6 {
            XCTFail("\(what): pixel \(i) is \(a.values[i]) not \(b.values[i])",
                    file: file, line: line)
            return
        }
    }

    // MARK: - 1 · The folder fold

    /// The roots of the walk must be EXACTLY the masks the plan renders — not the masks
    /// whose own `enabled` is true, and not every member of an enabled folder. Anything
    /// the plan renders and the walk does not root is a mask whose own inputs go
    /// unfetched.
    func testTheRootsOfTheWalkAreExactlyTheMasksThePlanRenders() {
        // Sixteen configurations: mask on/off × folder on/off/absent/unknown-id.
        var recipe = Recipe()
        recipe.maskGroups = [MaskGroup(id: "on", enabled: true),
                             MaskGroup(id: "off", enabled: false)]
        var masks: [Mask] = []
        for (index, group) in [nil, "on", "off", "ghost"].enumerated() {
            for enabled in [true, false] {
                var m = Mask(id: "m\(index)\(enabled)", name: "m",
                             components: [radial(0.5)])
                m.enabled = enabled
                m.group = group
                masks.append(m)
            }
        }
        recipe.masks = masks

        let plan = RenderPlan(recipe: recipe)
        XCTAssertEqual(MaskDependency.contributing(in: recipe).map(\.id),
                       plan.masks.map(\.id),
                       "with no references in the recipe the roster and the plan's "
                           + "render list must be the same list")
        // Named, so a regression says which cell moved.
        XCTAssertEqual(Set(plan.masks.map(\.id)),
                       ["m0true", "m1true", "m3true"],
                       "the fixture no longer covers the fold it was built for")
    }

    /// The over-inclusion half, one level up from the existing brush case: a member of a
    /// switched-off folder that NOTHING points at must not reach the segmenter. An
    /// attempted pass with nothing found is what the panel prints as "found no clear
    /// subject" about a mask that is simply off.
    func testAMemberOfASwitchedOffFolderNobodyPointsAtStaysOutOfTheRoster() {
        var member = Mask(id: "a", name: "Subject",
                          components: [matteComponent(.aiSubject)])
        member.group = "g"                       // its OWN enabled is true
        let other = Mask(id: "b", name: "Sky", components: [radial(0.5)])
        var recipe = Recipe()
        recipe.masks = [member, other]
        recipe.maskGroups = [MaskGroup(id: "g", enabled: false)]

        XCTAssertTrue(member.enabled, "the fixture needs a mask that is on by itself")
        XCTAssertEqual(MaskDependency.contributing(in: recipe).map(\.id), ["b"])
        XCTAssertEqual(MaskDependency.wantedMattes(in: recipe, from: .vision), [],
                       "the segmenter was asked for a matte no render will read")
    }

    /// And the same folder, with something pointing into it: the whole chain below the
    /// reference has to be fetched, however deep and however switched off.
    func testAReferenceReachesThroughASwitchedOffFolderAndKeepsGoing() {
        var deep = Mask(id: "c", name: "deep", components: [matteComponent(.aiSubject)])
        deep.enabled = false
        var middle = Mask(id: "b", name: "middle", components: [reference("c")])
        middle.group = "g"
        let user = Mask(id: "a", name: "user", components: [reference("b")])
        var recipe = Recipe()
        recipe.masks = [deep, middle, user]
        recipe.maskGroups = [MaskGroup(id: "g", enabled: false)]

        XCTAssertEqual(MaskDependency.contributing(in: recipe).map(\.id),
                       ["c", "b", "a"],
                       "the walk stopped at the folder wall")
        XCTAssertEqual(MaskDependency.wantedMattes(in: recipe, from: .vision),
                       [.aiSubject])

        // And it actually renders: two hops, both off, one through a folder.
        let alpha = MaskRaster.combine(mask: user, size: size, aiMattes: allMattes(),
                                       masks: RenderPlan(recipe: recipe).allMasks)
        XCTAssertGreaterThan(area(alpha), 0.3,
                             "a mask built two hops above a switched-off folder "
                                 + "rendered as nothing")
    }

    // MARK: - 2 · Dangling and unresolvable references, under every op

    /// THE TABLE. A reference that cannot be resolved must be INERT — identical pixels
    /// to the same mask with that component deleted — under add, subtract and intersect,
    /// with the component's own invert either way and the whole mask's invert either
    /// way, and in either stack position.
    ///
    /// `.subtract` is the cell that matters most: a zero plane subtracted is a no-op and
    /// hides the bug, but a zero plane INVERTED and subtracted is `min(a, 0)` — the
    /// whole frame emptied — and an absent one inverted and ADDED is `max(a, 1)`, the
    /// whole frame selected.
    func testAnUnresolvableReferenceIsInertUnderEveryOpAndEveryInvert() {
        var deadEnd = Mask(id: "z", name: "waiting",
                           components: [matteComponent(.aiSubject)])
        deadEnd.enabled = false

        // Four ways a reference has nothing to lend.
        let refs: [(String, String)] = [("gone", "a deleted mask"),
                                        ("z", "a mask whose matte never arrived"),
                                        ("self", "a mask that names itself")]

        for (target, why) in refs {
            for op in [MaskOp.add, .subtract, .intersect] {
                for componentInvert in [false, true] {
                    for maskInvert in [false, true] {
                        for refFirst in [false, true] {
                            let ref = reference(target, op: op, invert: componentInvert)
                            var with = Mask(id: "self", name: "user",
                                            components: refFirst
                                                ? [ref, radial(0.5)]
                                                : [radial(0.5), ref])
                            with.invert = maskInvert
                            var without = Mask(id: "self", name: "user",
                                               components: [radial(0.5)])
                            without.invert = maskInvert

                            var recipe = Recipe()
                            recipe.masks = [with, deadEnd]
                            let all = RenderPlan(recipe: recipe).allMasks
                            let got = MaskRaster.combine(mask: with, size: size,
                                                         masks: all)
                            let expected = MaskRaster.combine(mask: without, size: size,
                                                              masks: all)
                            assertSamePixels(got, expected,
                                             "\(why) under .\(op) "
                                                 + "(component invert \(componentInvert), "
                                                 + "mask invert \(maskInvert), "
                                                 + "reference first \(refFirst))")
                        }
                    }
                }
            }
        }
    }

    /// The one case where "inert" is the wrong answer and ABSENT is the right one: the
    /// unresolvable reference is the mask's ONLY component. There is nothing to invert,
    /// so an inverted empty stack must not become the whole photograph.
    func testAMaskWhoseOnlyReferenceIsUnresolvableSelectsNothingEvenInverted() {
        for target in ["gone", "z", "self"] {
            var z = Mask(id: "z", name: "waiting", components: [matteComponent(.aiSky)])
            z.enabled = false
            for maskInvert in [false, true] {
                for op in [MaskOp.add, .subtract, .intersect] {
                    var only = Mask(id: "self", name: "user",
                                    components: [reference(target, op: op)])
                    only.invert = maskInvert
                    var recipe = Recipe()
                    recipe.masks = [only, z]
                    let alpha = MaskRaster.combine(
                        mask: only, size: size,
                        masks: RenderPlan(recipe: recipe).allMasks)
                    XCTAssertEqual(alpha.values.max().map(Double.init) ?? 1, 0,
                                   accuracy: 0,
                                   "\(target) under .\(op) with mask invert "
                                       + "\(maskInvert) selected something")
                }
            }
        }
    }

    // MARK: - 3 · Cycles

    /// A cycle that is entirely switched off and that nothing points at must cost
    /// nothing: no matte, no blob, no roster entry.
    func testACycleThatIsEntirelySwitchedOffIsNotFetched() {
        var a = Mask(id: "a", name: "a",
                     components: [matteComponent(.aiSubject), reference("b")])
        a.enabled = false
        var b = Mask(id: "b", name: "b", components: [brush("blob:b"), reference("a")])
        b.enabled = false
        let live = Mask(id: "live", name: "live", components: [radial(0.5)])
        var recipe = Recipe()
        recipe.masks = [a, b, live]

        XCTAssertEqual(MaskDependency.contributing(in: recipe).map(\.id), ["live"])
        XCTAssertEqual(MaskDependency.wantedMattes(in: recipe, from: .vision), [])
        XCTAssertEqual(BrushStrokes.references(in: recipe), [])
    }

    /// A cycle something DOES point at is fetched whole — the rasterizer will decline
    /// the loop, but which member it declines at is not knowable from here, so both
    /// members' inputs have to be in hand.
    func testASwitchedOffCycleSomethingPointsAtIsFetchedWhole() {
        var a = Mask(id: "a", name: "a",
                     components: [matteComponent(.aiSubject), reference("b")])
        a.enabled = false
        var b = Mask(id: "b", name: "b", components: [brush("blob:b"), reference("a")])
        b.enabled = false
        let user = Mask(id: "u", name: "u", components: [reference("a")])
        var recipe = Recipe()
        recipe.masks = [a, b, user]

        XCTAssertEqual(MaskDependency.contributing(in: recipe).map(\.id), ["a", "b", "u"])
        XCTAssertEqual(MaskDependency.wantedMattes(in: recipe, from: .vision),
                       [.aiSubject])
        XCTAssertEqual(BrushStrokes.references(in: recipe), ["blob:b"])

        // And the mask on top of the loop still selects what the loop's non-cyclic
        // components select, rather than nothing.
        let alpha = MaskRaster.combine(mask: user, size: size, aiMattes: allMattes(),
                                       masks: RenderPlan(recipe: recipe).allMasks)
        XCTAssertGreaterThan(area(alpha), 0.3,
                             "the mask above the cycle rendered empty")
    }

    /// A long ring — every mask points at the next, the last points back at the first —
    /// must terminate in the WALK, not merely in the rasterizer. The visit-once guard is
    /// the only thing standing between this and a non-terminating queue, so the test is
    /// a real hang if it regresses; the wall-clock assertion turns a hang into a
    /// failure rather than a stuck lane.
    func testALongRingThatClosesOnItselfTerminates() {
        var recipe = Recipe()
        var masks: [Mask] = []
        let n = 4000
        for i in 0..<n {
            var m = Mask(id: "r\(i)", name: "r",
                         components: [reference("r\((i + 1) % n)"),
                                      reference("r\((i + 7) % n)", op: .intersect)])
            m.enabled = i == 0            // one root; everything else is off
            masks.append(m)
        }
        recipe.masks = masks

        let started = Date()
        let walked = MaskDependency.contributing(in: recipe)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(walked.count, n, "the ring is reachable in full")
        XCTAssertEqual(walked.map(\.id), masks.map(\.id),
                       "the walk must hand back stack order, not discovery order")
        XCTAssertLessThan(elapsed, 20, "the walk took \(elapsed)s over \(n) masks")

        // The closure walk closes on the same ring.
        XCTAssertEqual(MaskDependency.closure(of: masks[0], in: masks).count, n)
    }

    // MARK: - 4 · Ordering

    /// Stack order, not discovery order, and the difference is visible only when the
    /// dependency sits BELOW the mask that names it — which is the normal case, since a
    /// mask is built on one that already existed.
    func testTheRosterIsStackOrderEvenWhenTheDependencyIsBelowIt() {
        var recipe = Recipe()
        let top = Mask(id: "top", name: "top",
                       components: [reference("bottom"), brush("blob:top")])
        var middle = Mask(id: "middle", name: "middle", components: [brush("blob:mid")])
        middle.enabled = false
        var bottom = Mask(id: "bottom", name: "bottom", components: [brush("blob:bot")])
        bottom.enabled = false
        recipe.masks = [top, middle, bottom]

        XCTAssertEqual(MaskDependency.contributing(in: recipe).map(\.id),
                       ["top", "bottom"])
        XCTAssertEqual(BrushStrokes.references(in: recipe), ["blob:top", "blob:bot"],
                       "the blob roster promises the order the render fetches in")
        XCTAssertEqual(BrushStrokes.unresolvedReferences(in: recipe) { _ in false },
                       ["blob:top", "blob:bot"])
    }

    // MARK: - 5 · The narrowing

    /// Can `wantedMattes(from:)` hand back a kind belonging to a provider nobody asked
    /// for? Every matte kind is in this recipe, each in its own switched-off mask, all
    /// of them reached only through references — the state the narrowing is least likely
    /// to survive.
    func testTheNarrowedRosterNeverNamesAKindFromAnotherProvider() {
        var recipe = Recipe()
        var masks: [Mask] = []
        var refs: [MaskComponent] = []
        for (index, kind) in Self.matteKinds.enumerated() {
            var m = Mask(id: kind.rawValue, name: kind.rawValue,
                         components: [matteComponent(kind)])
            m.enabled = false
            masks.append(m)
            refs.append(reference(kind.rawValue,
                                  op: index == 0 ? .add : .intersect))
        }
        masks.append(Mask(id: "user", name: "user", components: refs + [radial(0.5)]))
        recipe.masks = masks

        let vision = MaskDependency.wantedMattes(in: recipe, from: .vision)
        let model = MaskDependency.wantedMattes(in: recipe, from: .model)
        let everything = MaskDependency.wantedMattes(in: recipe)

        XCTAssertEqual(vision, Set(Self.visionKinds))
        XCTAssertEqual(model, Set(Self.modelKinds))
        XCTAssertEqual(everything, Set(Self.matteKinds))
        XCTAssertTrue(vision.isDisjoint(with: model),
                      "a narrowed roster named a kind from the other provider")
        XCTAssertEqual(vision.union(model), everything,
                       "the two narrowings must partition the unnarrowed answer")
        for kind in vision { XCTAssertEqual(kind.matteProvider, .vision, "\(kind)") }
        for kind in model { XCTAssertEqual(kind.matteProvider, .model, "\(kind)") }
        XCTAssertFalse(everything.contains(.radial))
        XCTAssertFalse(everything.contains(.maskRef))
        XCTAssertFalse(everything.contains(.brush))

        // Asking for the provider that IS no provider is empty rather than everything,
        // which is the one way the narrowing could invert its own meaning.
        XCTAssertEqual(
            MaskDependency.wantedMattes(in: recipe, from: MaskKind.MatteProvider.none),
            [], "narrowing to the no-matte provider must be empty, not everything")

        // AND THE SPELLING IS A TRAP. The parameter is `MatteProvider?`, so a bare
        // `.none` at a call site resolves to `Optional.none` — nil, "do not narrow" —
        // and hands back EVERY kind including the ones the caller meant to exclude.
        // The compiler warns; it does not refuse. Written down because the whole point
        // of narrowing here is that a `.model` kind must never reach the segmenter.
        let bareDotNone: Set<MaskKind> = MaskDependency.wantedMattes(in: recipe,
                                                                     from: .none)
        XCTAssertEqual(bareDotNone, everything,
                       "if this is now empty the ambiguity has been closed")
    }

    // MARK: - 6 · The property that subsumes the rest

    private struct Rand {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        mutating func chance(_ oneIn: Int) -> Bool { next(oneIn) == 0 }
    }

    /// FETCHING EXACTLY THE ROSTER MUST RENDER THE SAME PIXELS AS FETCHING EVERYTHING.
    ///
    /// That is the whole promise in one sentence, and it is the one an example-based
    /// test cannot cover: the defect this file is about was a recipe shape nobody had
    /// written a fixture for. So the recipes are generated — switched-off masks,
    /// switched-off folders, references to switched-off masks, to deleted masks, to
    /// themselves, cycles, brush blobs and mattes both — and every mask the plan renders
    /// is folded twice: once with every input in hand, once with only what the two
    /// rosters asked for.
    func testFetchingOnlyTheRosterRendersTheSamePixelsAsFetchingEverything() {
        var rand = Rand(state: 0x5EED_1234)
        let ids = ["a", "b", "c", "d", "e"]
        var checked = 0

        for _ in 0..<160 {
            var recipe = Recipe()
            recipe.maskGroups = [MaskGroup(id: "g0", enabled: rand.chance(2)),
                                 MaskGroup(id: "g1", enabled: rand.chance(2))]
            var masks: [Mask] = []
            for id in ids where !rand.chance(6) {
                var components: [MaskComponent] = []
                for _ in 0..<(1 + rand.next(3)) {
                    let op = [MaskOp.add, .subtract, .intersect][rand.next(3)]
                    let invert = rand.chance(3)
                    switch rand.next(5) {
                    case 0: components.append(radial(0.3 + 0.1 * Double(rand.next(5)),
                                                     op: op, invert: invert))
                    case 1: components.append(matteComponent(
                        Self.matteKinds[rand.next(Self.matteKinds.count)], op: op))
                    case 2: components.append(brush("blob:\(ids[rand.next(ids.count)])",
                                                    op: op))
                    default:
                        let target = rand.chance(4)
                            ? "gone" : ids[rand.next(ids.count)]
                        components.append(reference(target, op: op, invert: invert))
                    }
                }
                var m = Mask(id: id, name: id, components: components)
                m.enabled = !rand.chance(2)
                m.invert = rand.chance(3)
                switch rand.next(4) {
                case 0: m.group = "g0"
                case 1: m.group = "g1"
                case 2: m.group = "ghost"
                default: m.group = nil
                }
                masks.append(m)
            }
            guard !masks.isEmpty else { continue }
            recipe.masks = masks

            let plan = RenderPlan(recipe: recipe)
            var everyStrokeSet: [String: BrushStrokeSet] = [:]
            for id in ids { everyStrokeSet["blob:\(id)"] = strokeSet() }

            // Exactly what the two rosters ask for, and nothing else.
            var rosterMattes: [String: Plane] = [:]
            for kind in MaskDependency.wantedMattes(in: recipe) {
                rosterMattes[kind.rawValue] = matte(0.6)
                if kind == .depthRange { rosterMattes["depth"] = matte(0.6) }
            }
            var rosterStrokes: [String: BrushStrokeSet] = [:]
            for ref in BrushStrokes.references(in: recipe) {
                rosterStrokes[ref] = strokeSet()
            }

            for mask in plan.masks {
                let full = MaskRaster.combine(mask: mask, size: size,
                                              strokeSets: everyStrokeSet,
                                              aiMattes: allMattes(),
                                              masks: plan.allMasks)
                let rostered = MaskRaster.combine(mask: mask, size: size,
                                                  strokeSets: rosterStrokes,
                                                  aiMattes: rosterMattes,
                                                  masks: plan.allMasks)
                assertSamePixels(rostered, full,
                                 "mask \(mask.id) renders differently when only the "
                                     + "roster is fetched — recipe: "
                                     + describe(recipe))
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 200, "the generator produced almost nothing")
    }

    private func describe(_ recipe: Recipe) -> String {
        let groups = recipe.maskGroups.map { "\($0.id):\($0.enabled)" }.joined(separator: ",")
        let masks = recipe.masks.map { m -> String in
            let cs = m.components.map { c -> String in
                let target = c.kind == .maskRef ? "→\(c.maskRef ?? "")"
                    : (c.kind == .brush ? "(\(c.strokesRef ?? ""))" : "")
                return "\(c.op.rawValue).\(c.kind.rawValue)\(target)\(c.invert ? "!" : "")"
            }.joined(separator: "+")
            return "\(m.id)[on=\(m.enabled),inv=\(m.invert),g=\(m.group ?? "-")]{\(cs)}"
        }.joined(separator: " ")
        return "groups(\(groups)) \(masks)"
    }

    // MARK: - 7 · Two masks carrying one identity

    /// The walk resolves a duplicate id FIRST-WINS; the renderer renders BOTH rows. So a
    /// second mask carrying an id already in the stack has its dependencies walked from
    /// the OTHER mask's components — and its own reference goes unfetched.
    ///
    /// Colliding ids are re-issued on paste (`Recipe.appendingMasks`), so this is a
    /// hand-edited sidecar or a future writer, not an everyday path. It is here because
    /// it is the one shape where the roster and the renderer disagree about which mask
    /// is which.
    func testTwoMasksCarryingOneIdentityLeaveTheSecondOnesDependencyUnfetched() {
        var subject = Mask(id: "src", name: "Subject",
                           components: [matteComponent(.aiSubject)])
        subject.enabled = false
        let first = Mask(id: "dup", name: "first", components: [radial(0.3)])
        let second = Mask(id: "dup", name: "second", components: [reference("src")])
        var recipe = Recipe()
        recipe.masks = [subject, first, second]

        let plan = RenderPlan(recipe: recipe)
        XCTAssertEqual(plan.masks.count, 2, "both rows render")

        // The walk never reaches the Subject mask, because it looked up "dup" and got
        // the OTHER row's components.
        // These two PASS and record the mechanism; the pixel assertion below is the harm.
        XCTAssertEqual(MaskDependency.contributing(in: recipe).map(\.id),
                       ["dup", "dup"],
                       "the walk resolved \"dup\" to the first row's components, so the "
                           + "Subject mask the second row points at is not in the roster")
        let wanted = MaskDependency.wantedMattes(in: recipe, from: .vision)
        XCTAssertEqual(wanted, [],
                       "the matte the second row's reference needs was never asked for")
        var rosterMattes: [String: Plane] = [:]
        for kind in wanted { rosterMattes[kind.rawValue] = matte(0.6) }

        let full = MaskRaster.combine(mask: second, size: size,
                                      aiMattes: allMattes(), masks: plan.allMasks)
        let rostered = MaskRaster.combine(mask: second, size: size,
                                          aiMattes: rosterMattes, masks: plan.allMasks)
        XCTAssertGreaterThan(area(full), 0.3,
                             "the fixture cannot show what it was built for")
        assertSamePixels(rostered, full,
                         "the second row carrying a duplicate id renders differently "
                             + "when only the roster is fetched")
    }

    // MARK: - 8 · Over-inclusion past the depth limit

    /// The walk deliberately ignores `referenceDepthLimit`, so a chain longer than the
    /// resolver will follow still puts its far end's matte on the segmenter's roster —
    /// the same over-inclusion the roster is careful to avoid for a switched-off mask
    /// nobody points at, arriving through the other door. Measured, not argued: find the
    /// depth at which the resolver stops, then show the roster still asks.
    func testTheRosterAsksForMattesPastTheDepthTheResolverWillFollow() {
        func chain(_ length: Int) -> Recipe {
            var recipe = Recipe()
            var masks: [Mask] = []
            var leaf = Mask(id: "leaf", name: "leaf",
                            components: [matteComponent(.aiSubject)])
            leaf.enabled = false
            masks.append(leaf)
            var previous = "leaf"
            for step in 0..<length {
                var m = Mask(id: "n\(step)", name: "n",
                             components: [reference(previous)])
                m.enabled = step == length - 1
                masks.append(m)
                previous = "n\(step)"
            }
            recipe.masks = masks
            return recipe
        }

        var firstDeadLength: Int?
        for length in 1...14 {
            let recipe = chain(length)
            let head = recipe.masks[recipe.masks.count - 1]
            let alpha = MaskRaster.combine(mask: head, size: size,
                                           aiMattes: allMattes(),
                                           masks: RenderPlan(recipe: recipe).allMasks)
            let alive = area(alpha) > 0.3
            XCTAssertTrue(MaskDependency.wantedMattes(in: recipe, from: .vision)
                .contains(.aiSubject),
                          "the roster stopped asking at length \(length)")
            if !alive, firstDeadLength == nil { firstDeadLength = length }
        }
        XCTAssertNotNil(firstDeadLength,
                        "no chain in range hit the resolver's depth limit")
        if let dead = firstDeadLength {
            // Recorded rather than asserted-at-a-number, so the limit can move without
            // this failing for the wrong reason.
            print("[adversarial] resolver stops following at chain length \(dead); "
                      + "the roster still asks for the matte at every length tested")
        }
    }

    // MARK: - 9 · The cache walk

    /// `closure(of:in:)` is asked what a mask's RASTER depends on. When the list holds a
    /// STALE copy of the same id — the mask being edited, against the plan built one
    /// frame ago — the walk follows the stale copy's components and hands back the stale
    /// copy, so a reference the photographer just added is not in the answer.
    ///
    /// Nothing in the shipped app calls this function yet, so this is a note for
    /// whatever wires it into a raster key rather than a live defect.
    func testTheCacheWalkFollowsTheStaleCopyOfTheMaskItWasAskedAbout() {
        let sky = Mask(id: "sky", name: "Sky", components: [radial(0.3)])
        let before = Mask(id: "b", name: "B", components: [radial(0.7)])
        var after = before
        after.components.append(reference("sky", op: .intersect))

        // The list is one edit behind, which is exactly the state a cache lookup is in.
        let stale = [sky, before]
        XCTAssertEqual(MaskDependency.closure(of: after, in: stale).map(\.id), ["b"],
                       "if this now says [sky, b] the walk has been fixed")
        XCTAssertEqual(MaskDependency.closure(of: after, in: stale).map(\.components),
                       [before.components],
                       "the walk handed back the stale definition of the mask it was "
                           + "asked about, so a key built on it cannot see the edit")

        // With a current list it is right, which is why this is a latent shape rather
        // than a visible one.
        XCTAssertEqual(MaskDependency.closure(of: after, in: [sky, after]).map(\.id),
                       ["sky", "b"])
    }
}

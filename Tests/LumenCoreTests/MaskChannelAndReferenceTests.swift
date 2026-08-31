// MaskChannelAndReferenceTests.swift
// docs/36 §3, bets 2 and 3 — the two selection capabilities no raw editor has.
//
// CHANNELS. The Photoshop luminosity-mask tradition is built on channels, not on
// luminance alone: red separates skin and sunset cloud a luma band cannot, and Min
// finds where EVERY channel is down, which is the mask for lifting a shadow without
// pulling its colour cast with it. ON1 ships luminosity masks; we shipped one luma band.
// The property that makes six channels usable through one band control is that all six
// read the same fixed −10…+4 EV axis, so changing the channel does not change the units
// under the handles.
//
// REFERENCES. Component algebra only ever worked INSIDE one mask, so "Sky ∩ Person"
// meant rebuilding both stacks in a third mask and keeping three copies in step by hand.
// A reference takes the other mask's FINISHED alpha and follows it — which is the half
// Capture One's Combine Masks does not do, since it merges sources and forgets them.
//
// The tests that matter most here are the ones about what a reference must NOT do:
// terminate on a cycle, and select nothing rather than everything when it cannot resolve.

import XCTest
@testable import LumenCore

final class MaskChannelAndReferenceTests: XCTestCase {

    private let w = 32
    private let h = 24

    // MARK: - Channels

    /// Left half is red-dominant, right half blue-dominant, both at the same luminance
    /// to within the weights — so a LUMA band cannot tell them apart and a channel band
    /// can. That is the whole claim, stated as a fixture.
    private func twoHues() -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, _ in
            u < 0.5 ? RGB(0.40, 0.05, 0.05) : RGB(0.05, 0.05, 0.40)
        }
    }

    private func band(_ channel: MaskChannel?, lo: Double, hi: Double) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .lumaRange)
        c.lo = lo
        c.hi = hi
        c.smooth = 20
        c.channel = channel
        return c
    }

    private func plane(_ c: MaskComponent, _ src: ImageBuffer) -> Plane {
        MaskRaster.rasterize(component: c, size: (width: w, height: h), source: src)
    }

    private func at(_ p: Plane, _ u: Double) -> Double { p[Int(u * Double(w)), h / 2] }

    func testARedBandSeparatesWhatALumaBandCannot() {
        let src = twoHues()
        // 0.40 linear is about −1.3 EV; the band sits around it on the red axis.
        let red = plane(band(.red, lo: MaskPanel_evNorm(-2.5), hi: MaskPanel_evNorm(0.5)), src)
        XCTAssertGreaterThan(at(red, 0.25), 0.9, "the red-dominant half is in")
        XCTAssertLessThan(at(red, 0.75), 0.05, "and the blue-dominant half is out")

        let blue = plane(band(.blue, lo: MaskPanel_evNorm(-2.5), hi: MaskPanel_evNorm(0.5)), src)
        XCTAssertLessThan(at(blue, 0.25), 0.05)
        XCTAssertGreaterThan(at(blue, 0.75), 0.9, "the same band on blue is the mirror")
    }

    func testTheDarkestChannelFindsWhereEveryChannelIsDown() {
        let src = twoHues()
        // Both halves have a channel at 0.05, so Min selects both; Max selects neither
        // at the same band, which is what makes the two different tools.
        let low = MaskPanel_evNorm(-5.5), high = MaskPanel_evNorm(-3.5)
        let min = plane(band(.min, lo: low, hi: high), src)
        XCTAssertGreaterThan(at(min, 0.25), 0.9)
        XCTAssertGreaterThan(at(min, 0.75), 0.9)

        let max = plane(band(.max, lo: low, hi: high), src)
        XCTAssertLessThan(at(max, 0.25), 0.05)
        XCTAssertLessThan(at(max, 0.75), 0.05)
    }

    func testAnAbsentChannelIsLumaSoOldBandsSelectWhatTheyAlwaysSelected() {
        let src = twoHues()
        let implied = plane(band(nil, lo: 0.2, hi: 0.8), src)
        let stated = plane(band(.luma, lo: 0.2, hi: 0.8), src)
        for i in 0..<implied.values.count {
            XCTAssertEqual(implied.values[i], stated.values[i], accuracy: 0)
        }
    }

    func testTheChannelRoundTripsAndAnOldRecipeStillDecodes() throws {
        var r = Recipe()
        r.masks = [Mask(id: "m", name: "band",
                        components: [band(.min, lo: 0.1, hi: 0.9)])]
        let back = try CanonicalJSON.decodeRecipe(
            from: Data(CanonicalJSON.canonicalRecipeJSON(r).utf8))
        XCTAssertEqual(back.masks[0].components[0].channel, .min)

        let old = """
        {"pipelineVersion":1,"masks":[{"id":"m","components":[\
        {"op":"add","kind":"lumaRange","lo":0.2,"hi":0.8}]}]}
        """
        let decoded = try CanonicalJSON.decodeRecipe(from: Data(old.utf8))
        XCTAssertNil(decoded.masks[0].components[0].channel)
    }

    /// The band handles are normalized on the fixed −10…+4 EV axis; this is the same
    /// mapping the panel's own slider uses, written out so the fixtures above read as
    /// EV rather than as magic fractions.
    private func MaskPanel_evNorm(_ ev: Double) -> Double { (ev + 10) / 14 }

    // MARK: - References

    private func radial(_ cx: Double) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [cx, 0.5]
        c.radii = [0.25, 0.35]
        c.feather = 0
        return c
    }

    private func reference(_ id: String, op: MaskOp = .add) -> MaskComponent {
        var c = MaskComponent(op: op, kind: .maskRef)
        c.maskRef = id
        return c
    }

    private func combine(_ mask: Mask, _ all: [Mask]) -> Plane {
        MaskRaster.combine(mask: mask, size: (width: w, height: h), masks: all)
    }

    func testAReferenceSelectsWhatTheMaskItPointsAtSelects() {
        let left = Mask(id: "left", name: "L", components: [radial(0.3)])
        let pointer = Mask(id: "p", name: "P", components: [reference("left")])
        let all = [left, pointer]

        let direct = combine(left, all)
        let via = combine(pointer, all)
        for i in 0..<direct.values.count {
            XCTAssertEqual(direct.values[i], via.values[i], accuracy: 0,
                           "a reference IS the other mask's alpha, not an approximation")
        }
    }

    func testAReferenceCarriesTheOtherMasksInvertAndRefinement() {
        // "Finished, not raw" — the property that makes an intersection mean what a
        // photographer can see rather than what the stack happened to fold to.
        var left = Mask(id: "left", name: "L", components: [radial(0.3)])
        left.invert = true
        left.refine.blur = 40
        let pointer = Mask(id: "p", name: "P", components: [reference("left")])
        let all = [left, pointer]

        let direct = combine(left, all)
        let via = combine(pointer, all)
        for i in 0..<direct.values.count {
            XCTAssertEqual(direct.values[i], via.values[i], accuracy: 0)
        }
        XCTAssertGreaterThan(direct.values.map(Double.init).reduce(0, +), 1,
                             "the fixture must select something after the invert")
    }

    func testTheIntersectionOfTwoMasksIsOneComponentEach() {
        // The use case, end to end: two overlapping shapes, and a third mask that is
        // exactly where they meet — without rebuilding either stack.
        let left = Mask(id: "left", name: "L", components: [radial(0.4)])
        let right = Mask(id: "right", name: "R", components: [radial(0.6)])
        let both = Mask(id: "both", name: "∩",
                        components: [reference("left"), reference("right", op: .intersect)])
        let all = [left, right, both]

        let p = combine(both, all)
        XCTAssertGreaterThan(p[w / 2, h / 2], 0.9, "the overlap is selected")
        XCTAssertLessThan(p[3, h / 2], 0.01, "outside both is not")
        XCTAssertLessThan(p[w - 4, h / 2], 0.01)
    }

    func testAReferenceFollowsTheOtherMaskWhenItChanges() {
        let pointer = Mask(id: "p", name: "P", components: [reference("left")])
        let near = combine(pointer, [Mask(id: "left", name: "L",
                                          components: [radial(0.25)]), pointer])
        let far = combine(pointer, [Mask(id: "left", name: "L",
                                         components: [radial(0.75)]), pointer])
        XCTAssertGreaterThan(near[Int(0.25 * Double(w)), h / 2], 0.9)
        XCTAssertLessThan(far[Int(0.25 * Double(w)), h / 2], 0.01,
                          "it is a live reference, not a copy taken at creation")
    }

    func testADisabledMaskStillLendsItsSelection() {
        // `enabled` says whether a mask's ADJUSTMENTS reach the picture. Turning the Sky
        // mask off to look at something must not silently empty every mask built on it.
        var left = Mask(id: "left", name: "L", components: [radial(0.3)])
        left.enabled = false
        let pointer = Mask(id: "p", name: "P", components: [reference("left")])
        let p = combine(pointer, [left, pointer])
        XCTAssertGreaterThan(p.values.max().map(Double.init) ?? 0, 0.9)
    }

    // MARK: - What a reference must refuse

    func testAMaskThatReferencesItselfSelectsNothing() {
        let loop = Mask(id: "loop", name: "L", components: [reference("loop")])
        let p = combine(loop, [loop])
        XCTAssertEqual(p.values.max().map(Double.init) ?? 1, 0, accuracy: 0,
                       "a cyclic definition has no fixed point to be right about")
    }

    func testATwoStepCycleTerminates() {
        let a = Mask(id: "a", name: "A", components: [reference("b")])
        let b = Mask(id: "b", name: "B", components: [reference("a")])
        let p = combine(a, [a, b])
        XCTAssertEqual(p.values.max().map(Double.init) ?? 1, 0, accuracy: 0)
    }

    func testALongChainResolvesAndAnAbsurdOneStops() {
        // Eight is the limit; a chain within it must still work, and one past it must
        // stop rather than grow a stack.
        var chain: [Mask] = [Mask(id: "leaf", name: "leaf", components: [radial(0.5)])]
        var previous = "leaf"
        for step in 0..<5 {
            let id = "n\(step)"
            chain.append(Mask(id: id, name: id, components: [reference(previous)]))
            previous = id
        }
        let head = chain.last!
        XCTAssertGreaterThan(combine(head, chain).values.max().map(Double.init) ?? 0, 0.9)

        var long: [Mask] = [Mask(id: "leaf", name: "leaf", components: [radial(0.5)])]
        previous = "leaf"
        for step in 0..<20 {
            let id = "l\(step)"
            long.append(Mask(id: id, name: id, components: [reference(previous)]))
            previous = id
        }
        let deep = long.last!
        XCTAssertEqual(combine(deep, long).values.max().map(Double.init) ?? 1, 0, accuracy: 0)
    }

    func testAReferenceToNothingSelectsNothingRatherThanEverything() {
        let orphan = Mask(id: "o", name: "O", components: [reference("gone")])
        XCTAssertEqual(combine(orphan, [orphan]).values.max().map(Double.init) ?? 1, 0,
                       accuracy: 0)
        // And with no list supplied at all — the default — the same answer.
        let noList = MaskRaster.combine(mask: orphan, size: (width: w, height: h))
        XCTAssertEqual(noList.values.max().map(Double.init) ?? 1, 0, accuracy: 0)
    }

    func testAReferenceWithNoTargetIsReportedIncomplete() {
        var c = MaskComponent(op: .add, kind: .maskRef)
        XCTAssertNotNil(c.validationError())
        c.maskRef = "something"
        XCTAssertNil(c.validationError())
    }

    func testTheReferenceRoundTripsThroughTheRecipeFormat() throws {
        var r = Recipe()
        r.masks = [Mask(id: "m", name: "ref", components: [reference("other")])]
        let back = try CanonicalJSON.decodeRecipe(
            from: Data(CanonicalJSON.canonicalRecipeJSON(r).utf8))
        XCTAssertEqual(back.masks[0].components[0].kind, .maskRef)
        XCTAssertEqual(back.masks[0].components[0].maskRef, "other")
    }
}

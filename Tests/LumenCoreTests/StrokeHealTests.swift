// StrokeHealTests.swift
// Painted heal strokes (docs/09 §Heal / Clone): a stroke healed along its length from
// one offset. The maths of the tube, its membrane and its search, the blob plumbing that
// gets the strokes to the renderer and the sidecar — and the byte identity owed to
// everything that has no heal stroke.

import XCTest
@testable import LumenCore

final class StrokeHealTests: XCTestCase {

    private func stroke(_ points: [(Double, Double)], size: Double, mode: HealMode = .heal,
                        dx: Double, dy: Double, feather: Double = 50,
                        opacity: Double = 100) -> BrushStroke {
        BrushStroke(points: points.map { BrushPoint(x: $0.0, y: $0.1) }, size: size,
                    feather: feather, density: opacity,
                    retouch: StrokeRetouch(mode: mode, dx: dx, dy: dy))
    }

    private func texture(_ w: Int, _ h: Int) -> ImageBuffer {
        var image = ImageBuffer(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                image[x, y] = RGB(0.3 + 0.05 * spotNoise(x, y), 0.25 + 0.05 * spotNoise(x, y, 5),
                                  0.2 + 0.1 * Double(x) / Double(w))
            }
        }
        return image
    }

    // MARK: The tube

    /// Clone: inside the flat core every pixel IS the borrowed one; outside the radius
    /// nothing moves, to the bit.
    func testCloneCopiesAlongTheWholeStrokeAndTouchesNothingElse() {
        let input = texture(200, 120)
        let s = stroke([(0.2, 0.5), (0.5, 0.45), (0.8, 0.5)], size: 0.06, mode: .clone,
                       dx: 0, dy: 0.25, feather: 0)
        guard let g = StrokeHeal.resolve(s, width: 200, height: 120) else {
            return XCTFail("did not resolve")
        }
        let out = StrokeHeal.apply(input, strokes: [s])
        var inside = 0
        for y in 0..<120 {
            for x in 0..<200 {
                let p = StrokeHeal.Point(Double(x) + 0.5, Double(y) + 0.5)
                let d = StrokeHeal.distance(p, to: g.vertices)
                if d >= g.radius {
                    XCTAssertEqual(out[x, y], input[x, y], "(\(x), \(y)) outside moved")
                } else if d < g.radius * 0.9 {
                    inside += 1
                    let borrowed = input.bilinear(p.x + g.dx, p.y + g.dy)
                    XCTAssertLessThan(out[x, y].maxAbsDifference(borrowed), 1e-6,
                                      "(\(x), \(y)) is not the borrowed pixel")
                }
            }
        }
        XCTAssertGreaterThan(inside, 500, "the tube covered almost nothing")
    }

    /// The membrane across a straight tube is linear interpolation wall to wall — the
    /// harmonic solution for a strip. So a vertical ramp under a horizontal scratch,
    /// healed from a FLAT source, comes back as the ramp in the stroke's middle; a
    /// Clone from the same source is the flat level.
    func testHealRebuildsARampTheSourceDoesNotHave() {
        let w = 240, h = 160
        var input = ImageBuffer(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let ramp = 0.2 + 0.004 * Double(y)
                // The top band (y < 40) is flat: that is where the source sits.
                var v = y < 40 ? 0.5 : ramp
                if abs(Double(y) + 0.5 - 100) < 2 && x > 30 && x < 210 { v = 0.05 }
                input[x, y] = RGB(gray: v)
            }
        }
        let s = stroke([(20.0 / 240, 100.0 / 160), (220.0 / 240, 100.0 / 160)],
                       size: 16.0 / 240, dx: 0, dy: -80.0 / 160, feather: 0)
        let healed = StrokeHeal.apply(input, strokes: [s])
        var clone = s
        clone.retouch?.mode = .clone
        let cloned = StrokeHeal.apply(input, strokes: [clone])
        var worstHeal = 0.0, worstClone = 0.0
        for y in 93..<107 {
            for x in 90..<150 {
                let truth = 0.2 + 0.004 * Double(y)
                worstHeal = Swift.max(worstHeal, abs(healed[x, y].g - truth))
                worstClone = Swift.max(worstClone, abs(cloned[x, y].g - truth))
            }
        }
        XCTAssertLessThan(worstHeal, 0.004, "the heal did not rebuild the ramp")
        XCTAssertGreaterThan(worstClone, 0.05, "the fixture does not separate the modes")
    }

    /// Rim samples that fall inside the tube — the inside of a bend — are dropped; every
    /// kept one is on or outside the tube's edge.
    func testRimSamplesInsideABendAreDropped() {
        let s = stroke([(0.3, 0.3), (0.3, 0.6), (0.4, 0.66), (0.5, 0.6), (0.5, 0.3)],
                       size: 0.12, dx: 0.3, dy: 0)
        guard let g = StrokeHeal.resolve(s, width: 300, height: 300) else {
            return XCTFail("did not resolve")
        }
        let possible = 2 * g.vertices.count + 2 * StrokeHeal.capSamples
        XCTAssertLessThan(g.rim.count, possible, "nothing was dropped inside the bend")
        for p in g.rim {
            XCTAssertGreaterThanOrEqual(StrokeHeal.distance(p, to: g.vertices),
                                        g.radius * (1 - 1e-6))
        }
        XCTAssertLessThanOrEqual(g.rim.count, StrokeHeal.maxBoundarySamples)
    }

    /// A dab — one point — is a disc whose rim is 16 evenly spaced samples.
    func testADabIsADisc() {
        let s = stroke([(0.5, 0.5)], size: 0.2, dx: 0.3, dy: 0)
        guard let g = StrokeHeal.resolve(s, width: 100, height: 100) else {
            return XCTFail("did not resolve")
        }
        XCTAssertEqual(g.vertices.count, 1)
        XCTAssertEqual(g.rim.count, 2 + 2 * StrokeHeal.capSamples)
        let angles = g.rim.map { atan2($0.y - 50, $0.x - 50) }.sorted()
        for i in 1..<angles.count {
            XCTAssertEqual(angles[i] - angles[i - 1], 2 * Double.pi / 16, accuracy: 1e-9)
        }
    }

    /// The same stroke at twice the size resolves to the same vertices, scaled: the
    /// vertex spacing is in radii, never in pixels.
    func testTheGeometryIsResolutionIndependent() {
        let s = stroke([(0.1, 0.2), (0.4, 0.35), (0.7, 0.3), (0.9, 0.6)], size: 0.03,
                       dx: 0.05, dy: -0.1)
        guard let one = StrokeHeal.resolve(s, width: 300, height: 200),
              let two = StrokeHeal.resolve(s, width: 600, height: 400) else {
            return XCTFail("did not resolve")
        }
        XCTAssertEqual(one.vertices.count, two.vertices.count)
        XCTAssertEqual(one.rim.count, two.rim.count)
        for (a, b) in zip(one.vertices, two.vertices) {
            XCTAssertEqual(b.x, a.x * 2, accuracy: 1e-9)
            XCTAssertEqual(b.y, a.y * 2, accuracy: 1e-9)
        }
        XCTAssertEqual(two.radius, one.radius * 2, accuracy: 1e-12)
        XCTAssertEqual(two.dx, one.dx * 2, accuracy: 1e-12)
        // And a long stroke is capped, not unbounded.
        var wiggle: [(Double, Double)] = []
        for i in 0...400 {
            let t = Double(i)
            wiggle.append((t / 400, 0.5 + 0.2 * sin(t)))
        }
        let long = stroke(wiggle, size: 0.002, dx: 0, dy: 0.1)
        XCTAssertLessThanOrEqual(StrokeHeal.resolve(long, width: 4000, height: 3000)?
                                    .vertices.count ?? .max, StrokeHeal.maxVertices)
    }

    // MARK: The search

    /// Horizontal stripes, a scratch along one: the offset must land the band in PHASE
    /// with the stripes (a whole number of periods up or down), never overlap the
    /// stroke, and be the same every run.
    ///
    /// Run twice: over a visible scratch, and over clean stripes — where a shift ALONG
    /// the stroke matches perfectly and is the nearest candidate, so only the overlap
    /// rule stands between the stroke and borrowing from itself.
    func testTheOffsetLandsInPhaseAndNeverOverlaps() {
        for scratched in [true, false] {
            offsetLandsInPhaseAndNeverOverlaps(scratched: scratched)
        }
    }

    private func offsetLandsInPhaseAndNeverOverlaps(scratched: Bool) {
        let period = 9.0
        var image = ImageBuffer(width: 220, height: 160)
        for y in 0..<160 {
            for x in 0..<220 {
                var v = 0.3 + 0.08 * sin(2 * Double.pi * (Double(y) + 0.5) / period)
                if scratched && abs(Double(y) + 0.5 - 80) < 1.5 && x > 60 && x < 160 {
                    v = 0.9
                }
                image[x, y] = RGB(v, v * 0.9, v * 1.05)
            }
        }
        let points = [StrokeHeal.Point(60, 80), StrokeHeal.Point(110, 80),
                      StrokeHeal.Point(160, 80)]
        for mode in HealMode.allCases {
            guard let a = StrokeSourceSearch.bestOffset(in: image, points: points, radius: 5,
                                                        mode: mode),
                  let b = StrokeSourceSearch.bestOffset(in: image, points: points, radius: 5,
                                                        mode: mode) else {
                return XCTFail("no offset for \(mode)")
            }
            XCTAssertEqual(a.dx, b.dx)
            XCTAssertEqual(a.dy, b.dy)
            var phase = a.dy.truncatingRemainder(dividingBy: period)
            if phase > period / 2 { phase -= period }
            if phase < -period / 2 { phase += period }
            XCTAssertLessThan(abs(phase), 0.15 * period, "\(mode): \(a) is out of phase")
            let line = StrokeHeal.resample(points, spacing: 2.5)
            for v in line {
                XCTAssertGreaterThanOrEqual(
                    StrokeHeal.distance(StrokeHeal.Point(v.x + a.dx, v.y + a.dy), to: line),
                    2 * 5 - 1e-9, "\(mode): the source tube overlaps the stroke")
            }
        }
    }

    /// The windowed search the app runs maps back to the whole-frame answer.
    func testTheWindowedOffsetIsTheWholeFrameOffset() {
        let frame = texture(400, 300)
        let s = stroke([(0.4, 0.5), (0.6, 0.52)], size: 10.0 / 400, dx: 0, dy: 0)
        let window = StrokeSourceSearch.window(for: s, sourceWidth: 400, sourceHeight: 300)
        XCTAssertEqual(window.scale, 1)
        XCTAssertLessThan(window.width, 400)
        var cut = ImageBuffer(width: window.width, height: window.height)
        for y in 0..<window.height {
            for x in 0..<window.width { cut[x, y] = frame[x + window.x, y + window.y] }
        }
        guard let windowed = StrokeSourceSearch.autoOffset(for: s, in: cut, window: window,
                                                           sourceWidth: 400,
                                                           sourceHeight: 300),
              let whole = StrokeSourceSearch.autoOffset(for: s, in: frame) else {
            return XCTFail("no offset")
        }
        XCTAssertEqual(windowed.dx * 400, whole.dx * 400, accuracy: 0.5)
        XCTAssertEqual(windowed.dy * 300, whole.dy * 300, accuracy: 0.5)
    }

    // MARK: The press grammar

    func testAPressInsideAStrokeSelectsTheTopmost() {
        let a = stroke([(0.2, 0.5), (0.8, 0.5)], size: 0.04, dx: 0, dy: 0.1)
        let b = stroke([(0.5, 0.2), (0.5, 0.8)], size: 0.04, dx: 0.1, dy: 0)
        XCTAssertEqual(StrokeHandles.hit(x: 0.5, y: 0.5, strokes: [a, b], sourceWidth: 100,
                                         sourceHeight: 100), 1, "the later stroke is on top")
        XCTAssertEqual(StrokeHandles.hit(x: 0.3, y: 0.51, strokes: [a, b], sourceWidth: 100,
                                         sourceHeight: 100), 0)
        XCTAssertNil(StrokeHandles.hit(x: 0.3, y: 0.7, strokes: [a, b], sourceWidth: 100,
                                       sourceHeight: 100))
        var mask = a
        mask.retouch = nil
        XCTAssertNil(StrokeHandles.hit(x: 0.3, y: 0.5, strokes: [mask], sourceWidth: 100,
                                       sourceHeight: 100), "a mask stroke is not a heal")
        // The provisional offset is perpendicular and toward the frame's middle.
        let o = StrokeHandles.provisionalOffset(points: a.points, size: 0.04,
                                                sourceWidth: 100, sourceHeight: 100)
        XCTAssertEqual(o.dx, 0, accuracy: 1e-12)
        XCTAssertEqual(abs(o.dy) * 100, 2.6 * 2, accuracy: 1e-9)
        let low = StrokeHandles.provisionalOffset(
            points: [BrushPoint(x: 0.2, y: 0.9), BrushPoint(x: 0.8, y: 0.9)], size: 0.04,
            sourceWidth: 100, sourceHeight: 100)
        XCTAssertLessThan(low.dy, 0, "a stroke near the bottom borrowed from off the frame")
    }

    // MARK: Plumbing and byte identity

    /// A mask stroke encodes exactly as before `retouch` existed: no mask blob, and so
    /// no content address, moves.
    func testAMaskStrokeBlobIsByteIdentical() throws {
        let set = BrushStrokeSet(strokes: [BrushStroke(points: [BrushPoint(x: 0.1, y: 0.2)])])
        let json = String(decoding: try set.encode(), as: UTF8.self)
        XCTAssertEqual(json, #"{"strokes":[{"density":100,"feather":50,"flow":100,"#
                       + #""points":[[0.1,0.2,1,0]],"size":0.05}],"version":1}"#)
        let heal = BrushStrokeSet(strokes: [stroke([(0.1, 0.2)], size: 0.05, mode: .clone,
                                                   dx: 0.25, dy: -0.5)])
        let decoded = try BrushStrokeSet.decode(heal.encode())
        XCTAssertEqual(decoded, heal)
        XCTAssertEqual(decoded.strokes[0].retouch, StrokeRetouch(mode: .clone, dx: 0.25,
                                                                 dy: -0.5))
    }

    /// The renderer, the export's refusal roster, the blob store and the sidecar payload
    /// all see the heal blob — any one missing is a frame delivered or restored with its
    /// retouching silently absent.
    func testTheHealBlobReachesEveryReader() throws {
        let set = BrushStrokeSet(strokes: [stroke([(0.3, 0.5), (0.6, 0.5)], size: 0.05,
                                                  dx: 0, dy: 0.2)])
        let ref = try set.blobRef()
        var recipe = Recipe()
        recipe.develop.heal.strokesRef = ref
        recipe.develop.heal.count = 1

        XCTAssertEqual(BrushStrokes.references(in: recipe), [ref])
        XCTAssertEqual(BrushStrokes.unresolvedReferences(in: recipe) { _ in false }, [ref])
        XCTAssertEqual(BrushStrokes.unresolvedReferences(in: recipe) { _ in true }, [])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrokeHealTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BlobStore(directory: directory)
        XCTAssertEqual(try store.store(set), ref)
        XCTAssertEqual(store.strokeSets(for: recipe), [ref: set])

        guard let payload = BrushStrokeSidecar.payload(for: recipe,
                                                       blob: { store.strokeSet(for: $0) })
        else { return XCTFail("the sidecar carries no heal strokes") }
        XCTAssertEqual(BrushStrokeSidecar.decode(payload), [ref: set])

        XCTAssertEqual(StrokeHeal.strokes(for: recipe.develop.heal, strokeSets: [ref: set]),
                       set.strokes)
        XCTAssertEqual(StrokeHeal.strokes(for: recipe.develop.heal, strokeSets: [:]), [],
                       "a missing blob must heal nothing, not something else")
    }

    /// The reference renderer heals with the strokes when it has their set, and without
    /// the set — or without a reference — the render is the input's own bytes.
    func testTheReferenceRendererRendersStrokesAndIsIdentityWithout() throws {
        let input = texture(96, 64)
        let set = BrushStrokeSet(strokes: [stroke([(0.2, 0.5), (0.8, 0.5)], size: 0.08,
                                                  mode: .clone, dx: 0, dy: 0.3)])
        let ref = try set.blobRef()
        var recipe = Recipe()
        recipe.develop.heal.strokesRef = ref
        recipe.develop.heal.count = 1
        let plain = ReferenceRenderer.render(input, plan: RenderPlan(recipe: Recipe()))
        let missing = ReferenceRenderer.render(input, plan: RenderPlan(recipe: recipe))
        XCTAssertEqual(missing.pixels, plain.pixels, "a missing blob changed the picture")
        let healed = ReferenceRenderer.render(
            input, plan: RenderPlan(recipe: recipe),
            inputs: ReferenceRenderer.Inputs(strokeSets: [ref: set]))
        let direct = ReferenceRenderer.render(
            StrokeHeal.apply(input, strokes: set.strokes), plan: RenderPlan(recipe: Recipe()))
        XCTAssertEqual(healed.pixels, direct.pixels,
                       "S5 strokes are not the first thing the reference does")
        XCTAssertGreaterThan(healed.maxAbsDifference(plain), 0.01, "the stroke did nothing")
    }
}

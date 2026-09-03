// MaskKeyTests.swift
//
// The two costs on the mask SETTLE path that no cache could remove, pinned so they
// cannot come back. Both are about the same complaint — masks do not update quickly
// enough — and neither of them is in the rasterizer.
//
//   A. `PipelineRenderer.image(from:)` turned every mask's single-channel plane into an
//      RGBAf interleave, one pixel at a time, through a `Double` round trip. 723 ms at
//      4096 against 97 ms for handing `Plane.values` to Core Image as `CIFormat.Rf`.
//      It ran after the raster cache's lookup, on the HIT as well as the miss, which is
//      what made it the floor under every settle no matter how good the cache got.
//
//   B. The picture-source fingerprint was ONE string for the whole mask stack, pasted
//      into every mask's raster key. So a single Luma Range mask made an unrelated
//      brush mask's raster miss on every exposure nudge and rebake something
//      byte-identical to what the cache already held.
//
// WHY THESE ARE SOURCE SCANS. `LumenPipeline` is `#if os(macOS)` — there is no Core
// Image on the Linux lane, so a test that calls `image(from:)` or `maskReadsPicture`
// cannot run where most of this repository's checking happens. `KernelRosterTests` made
// the same trade for the same reason. What CAN be executed anywhere is the arithmetic
// the per-mask predicate is composed of, all of which lives in `LumenCore`: the kind
// table, the refine threshold, and the reference walk. So this file does both — it
// checks the shipped code is assembled from those parts, and it checks the parts.
//
// Deliberately NOT guarded by `#if os(macOS)`: text and `LumenCore` are all it touches,
// so it is one of the few things in this target that runs on every lane.

import Foundation
import XCTest
@testable import LumenCore

final class MaskKeyTests: XCTestCase {

    // MARK: - A. the alpha image is the plane, not a copy of it four times over

    func testTheMaskAlphaImageIsHandedOverAsASingleChannelPlane() throws {
        let body = try Self.body(of: "static func image(from plane: Plane",
                                 in: Self.source("PipelineRenderer.swift"))

        XCTAssertTrue(body.contains("format: .Rf"),
                      "the mask alpha must reach Core Image as a single-channel image; "
                      + "every consumer reads .r and nothing else")
        XCTAssertFalse(body.contains("RGBAf"),
                       "an RGBAf interleave is four times the bytes and three quarters "
                       + "of them are written for no reader")
        XCTAssertTrue(body.contains("plane.values"),
                      "`Plane.values` is already the contiguous f32 bitmap Core Image "
                      + "wants; repacking it is the whole cost this removed")
        // The loop is the 723 ms. Its absence is the fix, so its absence is the test:
        // a `Plane` subscript returns `Double`, so any per-pixel walk here reintroduces
        // the round trip whatever it is spelled.
        XCTAssertFalse(body.contains("for y in"),
                       "no per-pixel loop belongs in this function any more")
        XCTAssertFalse(body.contains("plane["),
                       "the `Double`-returning subscript is the round trip; the buffer "
                       + "is handed over whole instead")
    }

    /// And the claim that licences it, checked against the kernels rather than trusted.
    ///
    /// A single-channel image is a drop-in ONLY while every kernel that samples a mask
    /// reads its red channel. The day one wants `.a`, this fails here rather than in a
    /// picture: the kernel would sample a channel the format does not carry.
    func testEveryKernelThatSamplesAMaskReadsOnlyItsRedChannel() throws {
        let source = Self.stripComments(try Self.source("Kernels.swift"))

        var checked: [String] = []
        for chunk in source.components(separatedBy: "kernel vec4 ").dropFirst() {
            guard chunk.contains("__sample mask") else { continue }
            let name = String(chunk.prefix(while: { $0 != "(" }))
            checked.append(name)
            XCTAssertEqual(Self.channels(of: "mask", in: chunk), ["r"],
                           "\(name) samples a mask through a channel a single-channel "
                           + "image does not carry")
        }

        // A scan that matches nothing passes loudest, so the roster is asserted too:
        // `blendMask` and `blendMaskMode` are the pair `RenderGraph.applyLocal` and
        // `applyLocalCurves` hand `maskImages[...]` to, and they are the only two.
        XCTAssertEqual(checked.sorted(), ["lumenBlendMask", "lumenBlendMaskMode"],
                       "the set of kernels that consume a mask image changed; each new "
                       + "one has to be re-checked against `CIFormat.Rf`")
    }

    // MARK: - B. the picture term belongs to the mask that reads the picture

    func testAMaskThatReadsNoPictureCarriesNoPictureTermInItsKey() throws {
        let renderer = Self.stripComments(try Self.source("PipelineRenderer.swift"))
        let loop = try Self.slice(of: renderer,
                                  from: "for mask in plan.masks {",
                                  to: "graph.maskImages[mask.id] = image")

        XCTAssertTrue(loop.contains("maskReadsPicture("),
                      "the picture term has to be decided per mask; deciding it once "
                      + "for the stack is what made one Luma Range mask invalidate "
                      + "every brush mask beside it")

        // The fingerprint is one serialization of one recipe: computing it per mask
        // would trade the miss for a different waste. It stays outside the loop, and
        // reaches a key only through the conditional below.
        XCTAssertFalse(loop.contains("maskSourceFingerprint("),
                       "the fingerprint is computed once, above the loop")

        let binding = loop.split(separator: "\n")
            .first { $0.contains("let sourceKey") }
        let line = try XCTUnwrap(binding.map(String.init),
                                 "no per-mask `sourceKey` binding in the loop")
        XCTAssertTrue(line.contains("pictureKey"),
                      "a mask that reads the picture must still carry the fingerprint")
        XCTAssertTrue(line.contains("\"-\""),
                      "a mask that reads no picture must carry the absent term, not a "
                      + "term it does not depend on")
    }

    /// The predicate must ask every way a mask reaches the picture, including through a
    /// mask it merely NAMES. Dropping any one of these four is a wrong raster, not a
    /// slow one, so each is named here.
    func testThePerMaskPredicateAsksEveryWayAMaskReachesThePicture() throws {
        let body = try Self.body(of: "static func maskReadsPicture(",
                                 in: Self.source("PipelineRenderer.swift"))
        for term in ["MaskDependency.closure",   // a reference reads what it names
                     "readsSourceImage",         // a kind that samples the picture
                     "automask",                 // a brush stroke gated on the picture
                     "refineRadius"] {           // the guided filter's guide
            XCTAssertTrue(body.contains(term),
                          "`maskReadsPicture` no longer asks about \(term), so a mask "
                          + "that reads the picture that way keys as if it did not")
        }
    }

    // MARK: - the arithmetic the predicate is composed of, executed

    func testTheMaskKindsThatReadNoPicture() {
        // Geometry, and a brush without Automask: nothing here samples the photograph,
        // so nothing here is invalidated by a tone edit. The matte-backed kinds join
        // them — a matte is generated from a DEFAULT recipe (`matteSourceImage`), so it
        // does not move when tone does either, and which photograph it belongs to is a
        // different term of the key, and an unconditional one.
        let geometry: [MaskKind] = [.brush, .linear, .radial, .polygon,
                                    .aiSubject, .aiSky, .aiBackground, .aiObject,
                                    .aiPerson, .aiLandscape, .depthRange]
        for kind in geometry {
            XCTAssertFalse(kind.readsSourceImage, "\(kind.rawValue)")
        }
        // And the ones that genuinely sample it, which must keep the fingerprint.
        let readers: [MaskKind] = [.lumaRange, .colorRange, .similarity,
                                   .similarityLine, .luminosity]
        for kind in readers {
            XCTAssertTrue(kind.readsSourceImage, "\(kind.rawValue)")
        }
    }

    func testRefineDecidesWhetherAGeometryMaskReadsThePicture() {
        // Refine 0 — the value a mask row resets to — runs no guided filter, so a
        // polygon at Refine 0 touches the picture nowhere.
        XCTAssertEqual(MaskRaster.refineRadius(feather: 0, longEdge: 4096), 0)
        // 2% of the long edge per unit of Refine: 2 at the 1024 proxy rounds to nothing,
        // which is the case the old whole-stack key could not distinguish from 10.
        XCTAssertEqual(MaskRaster.refineRadius(feather: 2, longEdge: 1024), 0)
        // And once it bites, the picture is a real input again.
        XCTAssertGreaterThanOrEqual(MaskRaster.refineRadius(feather: 10, longEdge: 4096), 1)
    }

    /// "Sky ∩ Person" reads the picture exactly when Sky or Person does, because
    /// `combine` resolves the reference by evaluating the other stack against the same
    /// stage input. The walk that has to notice is `MaskDependency.closure`.
    func testAReferenceReachesThePictureThroughTheMaskItNames() {
        var band = MaskComponent(op: .add, kind: .lumaRange)
        band.lo = 0.2
        band.hi = 0.8
        let reader = Mask(id: "reader", components: [band])

        var reference = MaskComponent(op: .intersect, kind: .maskRef)
        reference.maskRef = "reader"
        var outline = MaskComponent(op: .add, kind: .polygon)
        outline.points = [[0, 0], [1, 0], [1, 1]]
        let referring = Mask(id: "referring", components: [outline, reference])

        let all = [reader, referring]
        XCTAssertTrue(Self.readsPicture(referring, in: all),
                      "a mask whose reference lands on a Luma Range reads the picture")
        XCTAssertTrue(Self.readsPicture(reader, in: all))

        // Cut the reference and the same mask reads nothing: pure geometry, and its
        // raster is not a function of any tone the photographer moves.
        let alone = Mask(id: "referring", components: [outline])
        XCTAssertFalse(Self.readsPicture(alone, in: [alone]))
    }

    /// The shipped predicate's shape, restated over `LumenCore` so it can be executed on
    /// a lane with no Core Image. `testThePerMaskPredicateAsksEveryWay…` is what keeps
    /// this from drifting away from the code it mirrors.
    private static func readsPicture(_ mask: Mask, in masks: [Mask],
                                     longEdge: Int = 1024) -> Bool {
        MaskDependency.closure(of: mask, in: masks).contains { linked in
            if MaskRaster.refineRadius(feather: linked.refine.feather,
                                       longEdge: longEdge) >= 1 { return true }
            return linked.components.contains { $0.kind.readsSourceImage }
        }
    }

    // MARK: - scanning helpers

    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenPipeline")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// Whole-line comments only. Enough to keep a paragraph ABOUT `RGBAf` from reading
    /// as a use of it, and it cannot mangle a line of code the way a general stripper
    /// can — the kernel sources are string literals, and `//` inside one is still text.
    private static func stripComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// A declaration's body: from its opening line to the first line that closes at the
    /// declaration's own indentation. Crude, and sufficient — every declaration this
    /// file looks at is a method on a type, closed by `    }`.
    private static func body(of declaration: String, in text: String) throws -> String {
        let stripped = stripComments(text)
        let start = try XCTUnwrap(stripped.range(of: declaration),
                                  "`\(declaration)` is gone; this test now checks nothing")
        let rest = stripped[start.lowerBound...]
        let end = rest.range(of: "\n    }\n")?.upperBound ?? rest.endIndex
        return String(rest[..<end])
    }

    private static func slice(of text: String, from: String, to: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: from), "`\(from)` is gone")
        let rest = text[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: to), "`\(to)` is gone")
        return String(rest[..<end.lowerBound])
    }

    /// Every channel `name.<channels>` is read through in `text`, letter by letter, so
    /// `mask.rgb` reports r, g and b rather than passing as an unrecognised accessor.
    private static func channels(of name: String, in text: String) -> Set<String> {
        var found: Set<String> = []
        var rest = Substring(text)
        while let hit = rest.range(of: name + ".") {
            let after = rest[hit.upperBound...]
            for letter in after.prefix(while: { "rgba".contains($0) }) {
                found.insert(String(letter))
            }
            rest = after
        }
        return found
    }
}

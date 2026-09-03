// MaskCostTests.swift
// What a mask costs at the SETTLE rung, and the rules that decide whether that cost can
// be held rather than paid again. The stall behind them is the owner's "the mask isn't
// updating quick enough" — the half `AppState.refreshMaskOverlay` did not answer, which
// is the picture's own settle rather than the overlay's: 1.7–3.0 s after a mask edit,
// worse the more the photographer had already painted.
//
// THE ARITHMETIC OF WHY THE SETTLE RUNG IS WHERE THE COST WENT. A draft rasterizes at
// `PipelineRenderer.maskRasterLongEdge` (1024). A settle rasterizes at the render
// target's own resolution (docs/31 round two §3), bounded for any interactive surface by
// `DraftLadder.interactiveLongEdgeCeiling` (4096). That is sixteen times the pixels
// through a fold that is O(pixels) and a stroke painter that is O(stamps × stamp area),
// with the stamp radius growing with the long edge on top of it. Both mask caches
// refused to hold anything above the proxy, so all of it was paid again on every settle.
//
// WHAT IS PROVED HERE AND WHAT IS PROVED NEXT DOOR. `LumenPipeline` is `#if os(macOS)`
// and has no test target on this lane, so the caches themselves are exercised in
// `MaskPerfTests`. Two things can be proved here and are:
//
//   * THE PROPERTY THE SETTLE RUNG RESTS ON, run for real against `LumenCore`: a session
//     of resumed settles is bit-identical to one cold paint, and a plane from the WRONG
//     rung is refused rather than trusted. The second is newly reachable — until the
//     settle rung was held, only one size was ever in the brush cache, and a cache that
//     now holds two sizes is one mis-keyed entry away from painting a 1024 plane into a
//     4096 mask.
//   * THE RETENTION RULES THEMSELVES, as a source scan with comments stripped — the same
//     device `MaskRasterKeyTests` uses on the same target, and stripped for the same
//     reason: both cache files argue this defect at length in prose naming every symbol
//     below, so a scan over the raw text would be satisfied by the explanation of the
//     code rather than by the code. That mistake has been made twice in this repository.
//
// The two caches are deliberately NOT symmetric, and the last scan is the guard on the
// asymmetry rather than an omission. `BrushPlaneCache` COMPARES the strokes an entry was
// painted from against the strokes being asked for, so its held plane is verified rather
// than trusted, and holding it at any rung is safe. `MaskRasterCache` trusts its key
// completely — and the key does not name the masks a `maskRef` component resolves
// against, so editing mask A changes mask B's raster without moving B's key. That
// under-key is survivable today only because every settle re-folds from nothing and
// repairs it; holding the raster's settle rung would turn a one-frame draft artefact
// into a frozen selection in the delivered file.

import XCTest
@testable import LumenCore

final class MaskCostTests: XCTestCase {

    /// A rung above the 1024 proxy and one at it, in miniature. Small enough to paint in
    /// a test, different enough that a plane from one cannot pass for a plane from the
    /// other.
    private let settleSize = (width: 160, height: 104)
    private let draftSize = (width: 128, height: 84)

    private func strokeSet(count: Int) -> BrushStrokeSet {
        var strokes: [BrushStroke] = []
        for i in 0..<count {
            let t = Double(i) / Double(Swift.max(count - 1, 1))
            let y = 0.25 + 0.5 * t
            let points = (0...6).map { step -> BrushPoint in
                let u = Double(step) / 6
                return BrushPoint(x: 0.15 + 0.7 * u,
                                  y: y + 0.06 * sin(u * 6.2 + Double(i)),
                                  pressure: 1, t: step * 8)
            }
            strokes.append(BrushStroke(points: points, size: 0.10,
                                       feather: i.isMultiple(of: 2) ? 60 : 10,
                                       flow: 55, density: 90,
                                       erase: i.isMultiple(of: 5) && i > 0,
                                       automask: false))
        }
        return BrushStrokeSet(strokes: strokes)
    }

    private func worstDifference(_ a: Plane, _ b: Plane) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        var worst: Double = 0
        for i in 0..<a.values.count {
            worst = Swift.max(worst, abs(Double(a.values[i]) - Double(b.values[i])))
        }
        return worst
    }

    // MARK: - The property the settle rung rests on

    /// A SESSION, PAINTED THE WAY THE APP PAINTS IT: one stroke committed per gesture, a
    /// settle after each, every settle resuming from the last one's plane. The result
    /// after the last stroke must equal a single cold paint of the whole set, exactly.
    ///
    /// `BrushAccumulationTests` proves the fold's split property for one resume; this is
    /// the same property carried across a whole session, which is what the cache
    /// actually does and where an off-by-one in the resume count would show up as a
    /// stroke painted twice — invisible for a paint stroke over an already-dense region,
    /// and a doubled bite for an eraser.
    func testASessionOfResumedSettlesEqualsOneColdPaint() throws {
        let set = strokeSet(count: 8)
        let cold = MaskRaster.accumulatedBrushPlane(strokes: set, size: settleSize,
                                                    source: nil, resuming: nil)

        var held: Plane? = nil
        for n in 1...set.strokes.count {
            let sofar = BrushStrokeSet(strokes: Array(set.strokes.prefix(n)))
            let resume = held.map { (plane: $0, strokes: n - 1) }
            held = MaskRaster.accumulatedBrushPlane(strokes: sofar, size: settleSize,
                                                    source: nil, resuming: resume)
        }

        XCTAssertEqual(worstDifference(cold, try XCTUnwrap(held)), 0, accuracy: 0,
                       "a settle reached by resuming stroke by stroke is not the "
                       + "picture a cold render produces. That equality is the whole "
                       + "safety of holding the settle rung; without it the cache is "
                       + "not an optimisation, it is a different mask.")
    }

    /// A PLANE FROM THE WRONG RUNG IS REFUSED, NOT TRUSTED. Newly reachable: the brush
    /// cache now holds a draft-rung and a settle-rung entry for the same component at
    /// the same time, and the only thing keeping them apart is the size term in the key.
    ///
    /// The failure this closes is silent — a 1024 plane resumed into a 4096 paint would
    /// be the right mask at the wrong scale, which reads as a mask that moved.
    func testAPlaneFromTheDraftRungIsRefusedByASettleRungPaint() {
        let set = strokeSet(count: 5)
        let draft = MaskRaster.accumulatedBrushPlane(strokes: set, size: draftSize,
                                                     source: nil, resuming: nil)
        let out = MaskRaster.accumulatedBrushPlane(
            strokes: set, size: settleSize, source: nil,
            resuming: (plane: draft, strokes: set.strokes.count))

        XCTAssertEqual(out.width, settleSize.width)
        XCTAssertEqual(out.height, settleSize.height)
        let cold = MaskRaster.accumulatedBrushPlane(strokes: set, size: settleSize,
                                                    source: nil, resuming: nil)
        XCTAssertEqual(worstDifference(cold, out), 0, accuracy: 0,
                       "a resume from the wrong rung must degrade to a full repaint, "
                       + "never to a mask at the wrong scale")
    }

    /// The cost claim, stated as the thing that is actually true: resuming does not
    /// repaint what it was handed. Proved with a base no prefix of the set could have
    /// produced, at the settle rung, where the saving is worth seconds rather than
    /// milliseconds.
    func testASettleRungResumeDoesNotRepaintTheStrokesItWasHandedFor() {
        let set = strokeSet(count: 6)
        let base = Plane(width: settleSize.width, height: settleSize.height, fill: 0.5)
        let out = MaskRaster.accumulatedBrushPlane(
            strokes: set, size: settleSize, source: nil,
            resuming: (plane: base, strokes: set.strokes.count - 1))

        XCTAssertGreaterThan(out.values.min().map(Double.init) ?? 0, 0,
                             "a zero means the whole set was repainted, which is the "
                             + "cost the settle rung exists to remove")
        var expected = base
        MaskRaster.paint(stroke: set.strokes[set.strokes.count - 1], into: &expected,
                         width: settleSize.width, height: settleSize.height,
                         longEdge: Double(Swift.max(settleSize.width, settleSize.height)),
                         source: nil)
        XCTAssertEqual(worstDifference(expected, out), 0, accuracy: 0)
    }

    // MARK: - The retention rules, read off the caches

    /// THE BRUSH CACHE'S SETTLE RUNG IS REACHABLE. It used to refuse outright to hold
    /// anything above `PipelineRenderer.maskRasterLongEdge`, which is the draft proxy —
    /// so the rung every settle actually paints at was thrown away on every frame, and
    /// every settle repainted the whole stroke set. The file's own header claimed "two
    /// rungs (draft and settle)" while `store` made the second unreachable.
    ///
    /// The scan looks for the ceiling that separates an interactive surface from a
    /// delivery, because that is the distinction the rule has to make: an export paints
    /// at the export target and a single 45 MP plane is ~180 MB, which is the one thing
    /// the original long-edge rule was right about.
    func testTheBrushCacheHoldsTheSettleRung() throws {
        let body = try Self.storeBody(of: "BrushPlaneCache.swift")
        XCTAssertTrue(body.contains("DraftLadder.interactiveLongEdgeCeiling"),
                      "BrushPlaneCache's retention rule does not mention the "
                      + "interactive ceiling, so it cannot be distinguishing a settle "
                      + "from a delivery. If it is back to refusing everything above "
                      + "the 1024 draft proxy, every settle repaints every stroke ever "
                      + "drawn on that mask at up to sixteen times the proxy's pixels — "
                      + "docs/36 §1.2, quadratic in the strokes a photographer has "
                      + "painted, on the pass they are actually waiting for. store "
                      + "body was:\n" + body)
    }

    /// AND IT IS BOUNDED IN BYTES. A count cap cannot bound this rung: the same twelve
    /// entries are 34 MB at the draft proxy and 537 MB at the interactive ceiling, and
    /// which one you get depends on the size of the photographer's display.
    func testTheSettleRungIsBoundedInBytes() throws {
        let source = try Self.pipelineSource("BrushPlaneCache.swift")
        XCTAssertTrue(source.contains("settleResidencyBudget"),
                      "BrushPlaneCache no longer bounds its settle rung by bytes. A "
                      + "long edge is a poor proxy for the thing being bounded — the "
                      + "argument DraftLadder already makes about held decodes — and it "
                      + "is why the old rule threw away the rung the app rests at in "
                      + "order to keep out a rung it meets once per export.")
    }

    /// A BUDGET THAT ADMITS NOTHING IS NOT A BUDGET. Whatever the number is tuned to, it
    /// must hold at least one plane at the interactive ceiling, or the settle rung is
    /// held in name and refused in fact — the shipped behaviour with an extra branch in
    /// front of it.
    ///
    /// Read out of the source and multiplied out here rather than restated, so tuning
    /// the constant down past the point of usefulness fails instead of passing quietly.
    func testTheSettleBudgetAdmitsAPlaneAtTheInteractiveCeiling() throws {
        let source = try Self.pipelineSource("BrushPlaneCache.swift")
        let budget = try XCTUnwrap(Self.budgetBytes(in: source),
                                   "settleResidencyBudget is no longer a literal this "
                                   + "scan can read; if it moved, move the scan")

        // A 3:2 frame at the ceiling — the largest plane an interactive surface can ask
        // for, and the shape nearly every camera writes.
        let long = DraftLadder.interactiveLongEdgeCeiling
        let short = Int((Double(long) * 2 / 3).rounded())
        let bytes = long * short * MemoryLayout<Float>.stride
        XCTAssertGreaterThanOrEqual(budget, bytes,
            "the settle budget is \(budget) bytes and one plane at the interactive "
            + "ceiling is \(bytes). A rung whose budget cannot hold a single entry "
            + "evicts on every store, so every settle repaints from nothing — the "
            + "defect this rung exists to end, arrived at by tuning instead of by a "
            + "guard.")
    }

    /// THE ASYMMETRY IS LOAD-BEARING. `MaskRasterCache` must keep refusing the settle
    /// rung for as long as its key omits the masks a `maskRef` component reads.
    ///
    /// This is the one test here that guards an absence, and it is written as an
    /// implication rather than a flat prohibition so that it stays green through the
    /// fix: fix the key — make `maskJSON` a raster identity closed over every mask
    /// reachable through `maskRef` and their stroke sets — and the scan stops
    /// requiring the refusal. Remove the refusal without fixing the key and it fails,
    /// which is the substitution the fix must not be able to skip.
    ///
    /// What is at stake if it is skipped: `MaskRaster.referenced` lends a mask's
    /// finished alpha to any `maskRef` pointing at it, deliberately including masks
    /// that are switched off — and a switched-off mask is not in `plan.masks`, so it is
    /// never a client of the raster cache and can never announce that it changed. Edit
    /// it and the referencing mask's held raster is simply wrong, with nothing to
    /// invalidate it. Today the settle re-folds from nothing and repairs that within
    /// one frame; a held settle raster would leave it in the delivered file.
    func testTheRasterCacheRefusesTheSettleRungWhileItsKeyIsIncomplete() throws {
        let renderer = try Self.pipelineSource("PipelineRenderer.swift")
        // Does the key's mask term reach past THIS mask? The shipped term is
        // `CanonicalJSON.tree(of: mask)` — one mask, serialized whole, and nothing it
        // points at. While that is what the key is made of, the key is incomplete, and
        // the refusal below is the only thing standing between a held settle raster and
        // a frozen referenced selection. Replace that term with an identity that closes
        // over `maskRef` and this scan steps aside of its own accord.
        let keyIsOneMaskWhole = renderer.contains("CanonicalJSON.tree(of: mask)")
        guard keyIsOneMaskWhole else { return }

        let body = try Self.storeBody(of: "MaskRasterCache.swift")
        XCTAssertTrue(body.contains("PipelineRenderer.maskRasterLongEdge"),
                      "MaskRasterCache is holding rasters above the draft proxy while "
                      + "its key still names only THIS mask. A maskRef component's "
                      + "alpha is another mask's finished alpha, and neither that "
                      + "mask's definition nor its strokes are anywhere in the key — so "
                      + "editing mask A changes mask B's raster without moving B's key. "
                      + "The settle re-folding from nothing is the only thing repairing "
                      + "that today. Fix `maskRasterKey` first: a raster identity "
                      + "closed over every mask reachable through maskRef, which also "
                      + "removes `adjust`, `amount`, `enabled`, `blend`, `name` and "
                      + "`group` from a key none of them can change a pixel of. store "
                      + "body was:\n" + body)
    }

    // MARK: - helpers

    /// The braces, named once as a BALANCED PAIR rather than written as three loose
    /// literals. Not a flourish, and not a style preference:
    /// `scripts/check-swift-surface.py` finds a type's body by counting brace
    /// characters with comments stripped and STRINGS LEFT IN PLACE, so a file holding
    /// an odd number of brace literals hands it an unbalanced count, its whole member
    /// index for that type comes back empty, and every property this class reads off
    /// `self` is then reported as unbound — fourteen such reports came from the first
    /// draft of this file, which spent `open` twice against `close` once.
    ///
    /// The findings were noise; the coverage lost behind them was not. A type whose
    /// members the checker cannot see is a type whose renames it cannot catch, which
    /// is most of what that script is for.
    private static let brace: (open: Character, close: Character) = ("{", "}")

    /// The body of `store` in one of the pipeline's mask caches, braces matched,
    /// comments already gone.
    private static func storeBody(of file: String) throws -> String {
        let source = try pipelineSource(file)
        guard let declaration = source.range(of: "private func store(") else {
            XCTFail("\(file) has no `store` — if retention moved, move this scan with "
                    + "it rather than deleting it")
            return ""
        }
        guard let open = source.range(of: String(brace.open),
                                      range: declaration.upperBound..<source.endIndex)
        else {
            XCTFail("\(file)'s store has no body")
            return ""
        }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            if source[index] == brace.open { depth += 1 }
            if source[index] == brace.close {
                depth -= 1
                if depth == 0 { break }
            }
            index = source.index(after: index)
        }
        return String(source[open.upperBound..<index])
    }

    /// The `settleResidencyBudget` literal, multiplied out. Written as
    /// `N * 1024 * 1024` in the source, which is the form worth reading and the only
    /// form this parses — anything else fails the unwrap at the call site rather than
    /// being guessed at.
    private static func budgetBytes(in source: String) -> Int? {
        guard let declaration = source.range(of: "settleResidencyBudget = ") else {
            return nil
        }
        let line = source[declaration.upperBound...].prefix { $0 != "\n" }
        let factors = line.split(separator: "*").compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        guard !factors.isEmpty else { return nil }
        return factors.reduce(1, *)
    }

    private static func pipelineSource(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenPipeline/" + file)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Sources/LumenPipeline/\(file) not found — if it moved, move this "
                    + "scan with it")
            return ""
        }
        return strippingComments(raw)
    }

    /// Comments out before anything is looked for. Both cache files argue this defect
    /// at length in prose containing every symbol above, so a scan over the raw text
    /// would be satisfied by the argument for the code rather than by the code — the
    /// mistake `MaskRasterKeyTests`' header records having been made twice here.
    private static func strippingComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") { inBlock = false; index = source.index(index, offsetBy: 2) }
                else { index = source.index(after: index) }
                continue
            }
            if rest.hasPrefix("/*") { inBlock = true; index = source.index(index, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }
}

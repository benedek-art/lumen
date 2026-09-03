// DecodeResidencyPlanTests.swift
// I3-02: the process-wide decode budget advertised 768 MiB and its enforceable floor
// was 1792 MiB — 2.333x — and nothing could notice, because both numbers lived in
// LumenApp, which no lane on this machine builds.
//
// That is the shape of the defect and it is why the fix is not a smaller constant. The
// budget is now DERIVED, in `DecodeResidency`, from the two per-source bounds it has to
// accommodate; the trim's release order is a pure function beside it; and the bound the
// pair are supposed to guarantee is a theorem this file proves by walking the order
// against modelled holdings, for every source count and live-set size the app can
// reach.
//
// Three kinds of assertion here, and they are load-bearing in different ways:
//
// · THE ARITHMETIC. `sourceCeilingBytes` against `processBudgetBytes`, and the old
//   constant against both. 768 MiB was below what ONE photograph is allowed to hold,
//   which is why no trim could ever have reached it; that is a fact about two constants
//   and it is asserted as one.
// · THE THEOREM. Walk the order from any holdings and the residual is under budget.
//   The old order is modelled beside it so the 1792 MiB floor is reproduced rather than
//   quoted, and the delta between them is the fix, stated in bytes.
// · THE DRIFT PINS. Two of the four numbers live in targets this lane cannot compile,
//   so they are read as text with comments stripped. Stripping is the whole proof:
//   `DecodeResidency`'s own doc comments name `AppleRawSource.decodeCacheByteBudget`
//   and quote the 768 that was there, so an unstripped scan would pass on prose.

import XCTest
@testable import LumenCore

final class DecodeResidencyPlanTests: XCTestCase {

    private static let mib = 1024 * 1024

    /// What the constant used to say, kept as a number so the correction can be argued
    /// against it rather than around it.
    private static let advertisedBefore = 768 * 1024 * 1024

    // MARK: - The arithmetic

    /// THE FINDING, AS A FACT ABOUT TWO CONSTANTS: the old budget was smaller than the
    /// residency of a single source, so no trim could have met it.
    ///
    /// `AppleRawSource` lets one source hold an interactive working set AND one native
    /// inspection plane exempt from that budget. 320 + 512 is 832 MiB before a second
    /// photograph is considered at all, and the trim never takes from the newest source
    /// — so 768 was unreachable by construction, whatever the loops did.
    func testTheAdvertisedBudgetWasBelowWhatOnePhotographMayHold() {
        XCTAssertLessThan(Self.advertisedBefore, DecodeResidency.sourceCeilingBytes,
                          "if 768 MiB had covered one source the old constant would "
                          + "merely have been tight; it did not, so it was a claim")
        XCTAssertFalse(DecodeResidency.budgetCoversOneSource(Self.advertisedBefore))

        // Even under the audit's kinder reading of the per-source rules — the byte
        // budget taken as binding on the interactive class — one source is 832 MiB.
        let nominalSource = DecodeResidency.interactiveWorkingSetBytes
            + DraftLadder.materializedDecodeByteCeiling
        XCTAssertEqual(nominalSource / Self.mib, 832)
        XCTAssertLessThan(Self.advertisedBefore, nominalSource)
    }

    /// The per-source ceiling, spelled out. It is a `max` and not the interactive budget
    /// because `evictDecodes`' byte loop refuses to evict below one entry, so a single
    /// oversized interactive entry survives it and is bounded only by
    /// `mayHoldAsPixels`. A 4096 px ask whose scale factor the decoder declines delivers
    /// exactly that on a 60 MP body.
    func testOneSourcesCeilingIsBothClassesAtTheirOwnLimits() {
        XCTAssertEqual(DecodeResidency.interactiveWorkingSetBytes / Self.mib, 320)
        XCTAssertEqual(DraftLadder.materializedDecodeByteCeiling / Self.mib, 512)
        XCTAssertEqual(DecodeResidency.sourceCeilingBytes / Self.mib, 1024)
        XCTAssertEqual(DecodeResidency.Holding.ceiling.total,
                       DecodeResidency.sourceCeilingBytes)

        // The declined-scale entry that makes the `max` real, priced from the sensor.
        let declined = 9504 * 6336 * 8
        XCTAssertEqual(declined / Self.mib, 459)
        XCTAssertGreaterThan(declined, DecodeResidency.interactiveWorkingSetBytes)
        XCTAssertTrue(DraftLadder.mayHoldAsPixels(width: 9504, height: 6336,
                                                  bytesPerPixel: 8),
                      "under the materialization ceiling, so it really is held")
    }

    /// THE BUDGET AND THE LADDER CANNOT DRIFT APART: the number is computed from the
    /// constants rather than written beside them.
    ///
    /// One photograph entire plus one compare pane's working set — the policy the old
    /// comment stated and the arithmetic it never did.
    func testTheBudgetIsDerivedFromTheBoundsItHasToCover() {
        XCTAssertEqual(DecodeResidency.processBudgetBytes,
                       DecodeResidency.sourceCeilingBytes
                           + DecodeResidency.interactiveWorkingSetBytes)
        XCTAssertEqual(DecodeResidency.processBudgetBytes / Self.mib, 1344)
        XCTAssertTrue(DecodeResidency.budgetCoversOneSource(),
                      "a budget below one source's ceiling is unenforceable: the trim "
                      + "never takes from the newest")
        XCTAssertGreaterThan(DecodeResidency.processBudgetBytes, Self.advertisedBefore,
                             "the honest number is larger than the one it replaces — "
                             + "768 MiB was never held")
    }

    // MARK: - The theorem

    /// THE ASSERTION THE WHOLE FILE EXISTS FOR: from any state the app can be in, the
    /// walk ends under budget.
    ///
    /// Twelve is `RenderCoordinator.sourceCacheLimit`; the live-set size is swept past
    /// the app's 4 so that changing that constant alone cannot break the bound. Every
    /// source is loaded to its ceiling, which is the worst case by construction.
    func testTheWalkGetsUnderBudgetFromEverySourceCountAndLiveSetSize() {
        let budget = DecodeResidency.processBudgetBytes
        for sourceCount in 1...12 {
            for live in 1...6 {
                let holdings = Array(repeating: DecodeResidency.Holding.ceiling,
                                     count: sourceCount)
                let residual = DecodeResidency.residualBytes(holdings: holdings,
                                                             budget: budget,
                                                             liveSources: live)
                XCTAssertLessThanOrEqual(
                    residual, budget,
                    "\(sourceCount) sources with a live set of \(live) left "
                    + "\(residual / Self.mib) MiB against a \(budget / Self.mib) MiB "
                    + "budget")
            }
        }
    }

    /// The audit's named test, at the sizes it named: four sources each holding a full
    /// interactive working set and the owner's own inspection plane.
    ///
    /// Under the old order this left 1529 MiB (the audit prints 1542, mixing decimal MB
    /// into binary MiB). Under the new one it is the newest source alone.
    func testTheResidencyPlanGetsUnderBudgetWithFourLiveSources() {
        let plane = 7008 * 4672 * 8                     // the owner's 33 MP ARW
        XCTAssertEqual(plane, 261_931_008)
        let holdings = Array(repeating: DecodeResidency.Holding(
            interactive: DecodeResidency.interactiveWorkingSetBytes,
            inspection: plane), count: 4)

        let before = Self.residual(order: Self.orderBeforeTheFix(sourceCount: 4,
                                                                 liveSources: 4),
                                   holdings: holdings,
                                   budget: Self.advertisedBefore)
        XCTAssertEqual(before / Self.mib, 1529,
                       "the floor the audit measured, re-derived from the constants")
        XCTAssertGreaterThan(before, Self.advertisedBefore)

        let after = DecodeResidency.residualBytes(
            holdings: holdings, budget: DecodeResidency.processBudgetBytes,
            liveSources: 4)
        XCTAssertLessThanOrEqual(after, DecodeResidency.processBudgetBytes)
        XCTAssertEqual(after / Self.mib, 1209,
                       "the newest source entire and two panes' working sets — the walk "
                       + "took one working set, stopped the moment it was under, and "
                       + "left the alternation the live set exists to protect")
        XCTAssertLessThan(after, before)
    }

    /// THE 1792 MiB FLOOR, REPRODUCED RATHER THAN QUOTED. Twelve sources at their
    /// ceilings, walked by the order as it stood: pass one spared `sourceOrder.last`
    /// and pass two spared `sourceOrder.suffix(4)`, so what survived was one source
    /// entire and three more working sets, and no amount of paging could persuade the
    /// trim to take them.
    ///
    /// Priced twice, because the two per-source readings differ and both are over: with
    /// the interactive class taken as bounded by its byte budget it is the audit's
    /// 1792 MiB, and with the one-entry escape hatch counted it is worse.
    func testTheOldOrderStoppedWhileStillOverBudget() {
        let order = Self.orderBeforeTheFix(sourceCount: 12, liveSources: 4)

        let nominal = DecodeResidency.Holding(
            interactive: DecodeResidency.interactiveWorkingSetBytes,
            inspection: DraftLadder.materializedDecodeByteCeiling)
        let audited = Self.residual(order: order,
                                    holdings: Array(repeating: nominal, count: 12),
                                    budget: Self.advertisedBefore)
        XCTAssertEqual(audited / Self.mib, 1792, "the number the audit reported")
        XCTAssertEqual(Double(audited) / Double(Self.advertisedBefore), 2.3333,
                       accuracy: 0.0001)

        let strict = Self.residual(
            order: order,
            holdings: Array(repeating: DecodeResidency.Holding.ceiling, count: 12),
            budget: Self.advertisedBefore)
        XCTAssertGreaterThan(strict, audited)

        // And the same twelve sources under the order that replaced it.
        let fixed = DecodeResidency.residualBytes(
            holdings: Array(repeating: DecodeResidency.Holding.ceiling, count: 12),
            budget: DecodeResidency.processBudgetBytes, liveSources: 4)
        XCTAssertLessThanOrEqual(fixed, DecodeResidency.processBudgetBytes)
        XCTAssertLessThan(fixed, strict)
    }

    /// The two everyday shapes where the old trim ran and freed nothing. Both are now
    /// simply INSIDE the budget — which is the right answer, because in both of them
    /// every byte held belongs to a photograph somebody is looking at. The fix for
    /// these cases was the honest number, not a more aggressive trim: taking the live
    /// pane's decode is the 457 ms-per-frame defect the cache exists to prevent.
    func testTheTwoCasesTheOldTrimCouldNotHelpAreNowWithinBudget() {
        let interactive = DecodeResidency.interactiveWorkingSetBytes
        let budget = DecodeResidency.processBudgetBytes

        // Two-up compare, on the owner's file. `sourceOrder` is 2, so the old pass one
        // dropped the older pane's plane and pass two's filter was empty.
        let arw = 7008 * 4672 * 8
        let twoUp = [DecodeResidency.Holding(interactive: interactive, inspection: 0),
                     DecodeResidency.Holding(interactive: interactive, inspection: arw)]
        let twoUpTotal = twoUp.reduce(0) { $0 + $1.total }
        XCTAssertEqual(twoUpTotal / Self.mib, 889)
        XCTAssertGreaterThan(twoUpTotal, Self.advertisedBefore,
                             "over the old budget with nothing the old trim could take")
        XCTAssertEqual(DecodeResidency.residualBytes(holdings: twoUp, budget: budget,
                                                     liveSources: 4),
                       twoUpTotal, "within budget, so nothing is released")

        // One loupe on a 60 MP body. The single source IS the newest, so the old
        // `dropLast()` emptied the list before either pass began.
        let single = [DecodeResidency.Holding(interactive: interactive,
                                              inspection: 9504 * 6336 * 8)]
        XCTAssertEqual(single[0].total / Self.mib, 779)
        XCTAssertGreaterThan(single[0].total, Self.advertisedBefore)
        XCTAssertEqual(DecodeResidency.releaseOrder(sourceCount: 1, liveSources: 4), [],
                       "there is nothing to release when one photograph is open, which "
                       + "is why the budget has to cover one photograph")
        XCTAssertEqual(DecodeResidency.residualBytes(holdings: single, budget: budget,
                                                     liveSources: 4),
                       single[0].total)
    }

    // MARK: - The order

    /// The newest source is in no phase. Everything else in the bound rests on it.
    func testTheNewestSourceIsNeverReleased() {
        for sourceCount in 0...12 {
            for live in 1...6 {
                let order = DecodeResidency.releaseOrder(sourceCount: sourceCount,
                                                         liveSources: live)
                for step in order {
                    XCTAssertLessThan(step.index, sourceCount - 1,
                                      "the newest source is about to be rendered")
                    XCTAssertGreaterThanOrEqual(step.index, 0)
                }
            }
        }
    }

    /// Exhaustive, which is what the old order was not: every source but the newest
    /// eventually gives up everything, and the planes go before the working sets.
    func testEveryColderSourceIsEventuallyReleasedEntirely() {
        let order = DecodeResidency.releaseOrder(sourceCount: 12, liveSources: 4)
        for index in 0..<11 {
            XCTAssertTrue(order.contains(.inspection(index)), "\(index) keeps its plane")
            XCTAssertTrue(order.contains(.everything(index)),
                          "\(index) keeps its working set however far over budget the "
                          + "process is — which is what made 768 a floor of 1792")
        }
        let firstEverything = order.firstIndex { if case .everything = $0 { return true }
                                                 else { return false } }
        let lastInspection = order.lastIndex { if case .inspection = $0 { return true }
                                               else { return false } }
        XCTAssertEqual(lastInspection.map { $0 + 1 }, firstEverything,
                       "every plane goes before any working set does")
    }

    /// Coldest first inside each phase, and the live set last inside the blunt one — so
    /// the walk's early exit spends the cheapest losses first.
    func testTheOrderIsColdestFirstAndTheLiveSetGoesLast() {
        let order = DecodeResidency.releaseOrder(sourceCount: 8, liveSources: 4)
        let planes = order.compactMap { step -> Int? in
            if case .inspection(let i) = step { return i } else { return nil }
        }
        XCTAssertEqual(planes, Array(0..<7))

        let everything = order.compactMap { step -> Int? in
            if case .everything(let i) = step { return i } else { return nil }
        }
        // Cold first (0…3), then the live set bar the newest (4…6).
        XCTAssertEqual(everything, [0, 1, 2, 3, 4, 5, 6])

        // With a live set larger than the roll of sources, everything is "live" and the
        // order is still exhaustive — it just has no cold phase to run first.
        let small = DecodeResidency.releaseOrder(sourceCount: 3, liveSources: 9)
        XCTAssertEqual(small, [.inspection(0), .inspection(1),
                               .everything(0), .everything(1)])
    }

    /// A walk that is already under budget releases nothing, and one source or none has
    /// nothing to walk.
    func testAProcessUnderBudgetIsLeftAlone() {
        let budget = DecodeResidency.processBudgetBytes
        let small = Array(repeating: DecodeResidency.Holding(interactive: 8 * Self.mib,
                                                             inspection: 0),
                          count: 12)
        XCTAssertEqual(DecodeResidency.residualBytes(holdings: small, budget: budget,
                                                     liveSources: 4),
                       96 * Self.mib)
        XCTAssertEqual(DecodeResidency.releaseOrder(sourceCount: 0, liveSources: 4), [])
        XCTAssertEqual(DecodeResidency.residualBytes(holdings: [], budget: budget,
                                                     liveSources: 4), 0)
    }

    /// The walk stops the MOMENT it is under budget rather than emptying the list — the
    /// property that keeps a trim from manufacturing the re-demosaic it exists to
    /// prevent. Twelve sources one byte over: the coldest plane alone settles it.
    func testTheWalkStopsAsSoonAsItIsUnderBudget() {
        let budget = DecodeResidency.processBudgetBytes
        let plane = 64 * Self.mib
        var holdings = Array(repeating: DecodeResidency.Holding(interactive: 0,
                                                                inspection: 0),
                             count: 12)
        holdings[0] = DecodeResidency.Holding(interactive: 0, inspection: plane)
        holdings[11] = DecodeResidency.Holding(interactive: budget + 1 - plane,
                                               inspection: 0)
        XCTAssertEqual(DecodeResidency.residualBytes(holdings: holdings, budget: budget,
                                                     liveSources: 4),
                       budget + 1 - plane,
                       "one release put it under; the other eleven sources keep theirs")
    }

    // MARK: - Drift pins for the two constants this lane cannot compile

    /// `DecodeResidency.interactiveWorkingSetBytes` is a MIRROR of
    /// `AppleRawSource.decodeCacheByteBudget`, which is `private` inside
    /// `#if os(macOS)`. If the mirror stops matching, the derived budget is derived
    /// from a number that is no longer true — which is the whole class of defect I3-02
    /// belongs to.
    func testThePerSourceInteractiveBudgetStillMatchesThePipeline() throws {
        let raw = Self.stripped(try Self.source("LumenPipeline/AppleRawSource.swift"))
        XCTAssertTrue(raw.contains("decodeCacheByteBudget = 320 * 1024 * 1024"),
                      "the per-source interactive budget moved; "
                      + "DecodeResidency.interactiveWorkingSetBytes must move with it")
        XCTAssertEqual(DecodeResidency.interactiveWorkingSetBytes, 320 * Self.mib)

        // The exemption the ceiling stands for is still one entry, still uncounted
        // against that budget — the clause that makes `sourceCeilingBytes` a sum of two
        // limits rather than one.
        XCTAssertTrue(raw.contains("func releaseInspectionDecodes()"),
                      "the trim releases planes by name")
        XCTAssertTrue(raw.contains("func releaseDecodes()"))
        XCTAssertTrue(raw.contains("var heldDecodeBytes"),
                      "the coordinator sums this to know where it stands")
    }

    /// The app-side executor, read as text: it must take its budget from the derived
    /// number and its order from `releaseOrder`, and it must trim AFTER an allocation
    /// as well as before one. A literal byte budget back in the coordinator is I3-02
    /// returning.
    func testTheCoordinatorTakesBothItsNumbersFromThisFile() throws {
        let text = Self.stripped(try Self.source("LumenApp/RenderCoordinator.swift"))
        XCTAssertTrue(
            text.contains("decodeResidencyBudget = DecodeResidency.processBudgetBytes"),
            "the coordinator names its own byte count again")
        XCTAssertTrue(text.contains("DecodeResidency.releaseOrder(sourceCount:"),
                      "the trim's order must come from the rule that is tested")
        XCTAssertFalse(text.contains("768 * 1024 * 1024"),
                       "the advertised budget that was never a bound is back")
        XCTAssertFalse(text.contains("Array(sourceOrder.suffix("),
                       "the live set is a preference in the order now, not a clause "
                       + "that exempts four sources from being trimmed at all")

        // Trimmed on the way out of every path that decodes, not only on the way in —
        // the second half of the finding. Each member's text is cut at the NEXT member
        // declaration, so a `defer` belonging to the function after it cannot satisfy
        // the assertion, which is what a fixed-size window would eventually allow.
        for path in ["func produce(", "func warmDecode(", "func renderFullSize(",
                     "func export("] {
            let start = try XCTUnwrap(text.range(of: path)).upperBound
            let rest = text[start...]
            let next = ["\n    func ", "\n    private func ", "\n    nonisolated "]
                .compactMap { rest.range(of: $0)?.lowerBound }
                .min() ?? rest.endIndex
            XCTAssertTrue(String(rest[..<next])
                            .contains("defer { trimDecodeResidency() }"),
                          "\(path) can leave the process over budget and idle")
        }
    }

    /// The stripper is what makes the three scans above proofs rather than prose
    /// searches — this file's own doc comments contain every string it looks for.
    func testTheCommentStripperIsWhatMakesTheScansAProof() {
        let sample = """
        /// decodeCacheByteBudget = 320 * 1024 * 1024, and 768 * 1024 * 1024 before.
        // defer { trimDecodeResidency() } is claimed here.
        /* DecodeResidency.releaseOrder(sourceCount: */
        let kept = "Array(sourceOrder.suffix("
        """
        let stripped = Self.stripped(sample)
        XCTAssertFalse(stripped.contains("decodeCacheByteBudget"))
        XCTAssertFalse(stripped.contains("768 * 1024 * 1024"))
        XCTAssertFalse(stripped.contains("defer { trimDecodeResidency() }"))
        XCTAssertFalse(stripped.contains("DecodeResidency.releaseOrder"))
        XCTAssertTrue(stripped.contains("let kept = \"Array(sourceOrder.suffix(\""))
    }

    // MARK: - helpers

    /// The order as `trimDecodeResidency` walked it before the fix: planes from every
    /// source but the newest, then everything from the sources OUTSIDE the live set —
    /// and then nothing, however far over budget the process still was.
    private static func orderBeforeTheFix(sourceCount: Int,
                                          liveSources: Int) -> [DecodeResidency.Step] {
        guard sourceCount > 1 else { return [] }
        let colder = 0..<(sourceCount - 1)
        let liveFrom = max(0, sourceCount - liveSources)
        return colder.map { .inspection($0) }
            + colder.filter { $0 < liveFrom }.map { .everything($0) }
    }

    /// Walk any order with the app's early exit. `DecodeResidency.residualBytes` is
    /// this against `releaseOrder`, and the first assertion below is what keeps the two
    /// from drifting — a model that does not agree with the shipped one proves nothing
    /// about the shipped one.
    private static func residual(order: [DecodeResidency.Step],
                                 holdings: [DecodeResidency.Holding],
                                 budget: Int) -> Int {
        var remaining = holdings
        var total = remaining.reduce(0) { $0 + $1.total }
        guard total > budget else { return total }
        for step in order {
            guard total > budget else { return total }
            let held = remaining[step.index]
            switch step {
            case .inspection(let i):
                total -= held.inspection
                remaining[i] = DecodeResidency.Holding(interactive: held.interactive,
                                                       inspection: 0)
            case .everything(let i):
                total -= held.total
                remaining[i] = DecodeResidency.Holding(interactive: 0, inspection: 0)
            }
        }
        return total
    }

    /// The model above, driven by the shipped order, must equal the shipped walk.
    func testTheModelAgreesWithTheShippedWalk() {
        for sourceCount in 0...12 {
            for live in 1...6 {
                let holdings = (0..<sourceCount).map { index in
                    DecodeResidency.Holding(interactive: (index + 1) * 37 * Self.mib,
                                            inspection: index % 3 == 0
                                                ? 200 * Self.mib : 0)
                }
                let budget = DecodeResidency.processBudgetBytes
                XCTAssertEqual(
                    Self.residual(order: DecodeResidency.releaseOrder(
                                      sourceCount: sourceCount, liveSources: live),
                                  holdings: holdings, budget: budget),
                    DecodeResidency.residualBytes(holdings: holdings, budget: budget,
                                                  liveSources: live),
                    "the model and the rule disagree at \(sourceCount)/\(live)")
            }
        }
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        return try String(contentsOf: root.appendingPathComponent(relative),
                          encoding: .utf8)
    }

    /// `DeliveryNameTests.strippingComments`, copied so this file stands on its own —
    /// the same reason `PreviewRungTests` carries its own.
    private static func stripped(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") {
                    inBlock = false
                    index = source.index(index, offsetBy: 2)
                } else {
                    index = source.index(after: index)
                }
                continue
            }
            if rest.hasPrefix("/*") {
                inBlock = true
                index = source.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }
}

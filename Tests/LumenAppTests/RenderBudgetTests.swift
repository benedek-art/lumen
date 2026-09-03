// RenderBudgetTests.swift
// I3-02, on the lane that can see LumenApp: the process-wide decode budget and the trim
// that is supposed to enforce it.
//
// The arithmetic is `DecodeResidencyPlanTests` in LumenCore, because the arithmetic is
// what a lane without a Mac can run and because leaving it here is how the defect
// happened — a budget and a trim that lived only in a target no CI job builds, so
// "768 MiB" and "1792 MiB" could sit forty lines apart for a release. What is left for
// this file is everything about the budget that is a fact about THE APP: which
// constants the coordinator multiplies, where the trim is called from, and that the
// worst case the source cache can assemble is bounded by it.
//
// The coordinator's numbers are `private static`, which `@testable` does not reach, so
// they are read as text with comments stripped. Stripping is load-bearing rather than
// tidy: `RenderCoordinator`'s own doc comment quotes the `768 * 1024 * 1024` it
// replaced and names every symbol below, so an unstripped scan would pass on prose in
// both directions. `testTheStripperIsWhatMakesTheseScansProofs` is the foundation.

#if os(macOS)
import XCTest
import LumenCore
@testable import LumenApp

final class RenderBudgetTests: XCTestCase {

    private static let mib = 1024 * 1024

    // MARK: - What the coordinator enforces

    /// THE BUDGET IS NOT A NUMBER IN THIS FILE ANY MORE, which is the whole correction.
    ///
    /// It read `768 * 1024 * 1024` beside a trim whose floor was 1792 MiB. Both were
    /// constants in a target no lane builds, so neither could be multiplied out against
    /// the other. The budget is now `DecodeResidency.processBudgetBytes`, derived from
    /// the per-source bounds it has to cover, and any byte literal reappearing here is
    /// the defect coming back.
    func testTheCoordinatorsBudgetIsDerivedRatherThanDeclared() throws {
        let text = Self.stripped(try Self.coordinator())
        XCTAssertTrue(
            text.contains("decodeResidencyBudget = DecodeResidency.processBudgetBytes"),
            "the budget must be the derived one or it can drift from the ladder again")
        XCTAssertFalse(text.contains("768 * 1024 * 1024"),
                       "the advertised figure that was never a bound is back")
        XCTAssertFalse(text.contains("* 1024 * 1024"),
                       "a byte budget written as a literal in this file is how I3-02 "
                       + "happened; it belongs in DecodeResidency where it is tested")
    }

    /// The trim takes its order from LumenCore and nothing else. A second rule spelled
    /// out here would be a rule with no test, which is what the two hand-written passes
    /// were.
    func testTheTrimIsAnExecutorAndNotAPolicy() throws {
        let text = Self.stripped(try Self.coordinator())
        XCTAssertTrue(text.contains("DecodeResidency.releaseOrder(sourceCount:"),
                      "the release order must come from the rule that has a test")
        XCTAssertTrue(text.contains("releaseInspectionDecodes()"))
        XCTAssertTrue(text.contains("releaseDecodes()"))

        // The two clauses that made the budget advisory. `dropLast()` spared the newest
        // source's inspection plane AND its working set from both passes; `suffix(4)`
        // spared three more working sets from the only pass that could have taken them.
        // Together they were the 1792 MiB floor.
        XCTAssertFalse(text.contains("Array(sourceOrder.dropLast())"),
                       "the newest source is excluded by releaseOrder now, which is "
                       + "where the argument for excluding it is written down")
        XCTAssertFalse(text.contains("Array(sourceOrder.suffix("),
                       "the live set is a preference inside the order, not four "
                       + "sources exempt from being trimmed at all")
    }

    /// Called on BOTH doors of the source cache — the hit and the miss — because that
    /// is the one line every consumer passes through, and called again on the way out
    /// of every path that decodes.
    ///
    /// The second half is the other thing I3-02 named: the trim ran only BEFORE the
    /// allocation that grows the cache. A newest source holding nothing at the check
    /// can hold `DecodeResidency.sourceCeilingBytes` by the time the frame is
    /// delivered, and if the app then goes idle nothing reconsiders it — read-ahead in
    /// particular runs precisely when the photographer has stopped.
    func testTheTrimRunsBeforeTheDecodeAndAfterIt() throws {
        let text = Self.stripped(try Self.coordinator())
        let acquire = try XCTUnwrap(text.range(of: "private func source(for url: URL)"))
        let inAcquire = String(text[acquire.upperBound...])
        XCTAssertGreaterThanOrEqual(
            inAcquire.components(separatedBy: "trimDecodeResidency()").count - 1, 2,
            "the cache hit and the cache miss must both trim on the way in")

        for path in ["func produce(", "func warmDecode(", "func renderFullSize(",
                     "func export("] {
            XCTAssertTrue(try Self.body(of: path, in: text)
                            .contains("defer { trimDecodeResidency() }"),
                          "\(path) decodes and can leave the process over budget while "
                          + "nothing else is going to ask for a source")
        }
    }

    // MARK: - The worst case the app can assemble

    /// THE ASSERTION THE BUDGET EXISTS FOR, computed from the app's own constants
    /// rather than asserted about them: twelve sources at their ceilings is what the
    /// source cache can hold, and the trim brings it under the budget.
    ///
    /// The source-cache limit is read from the coordinator so that raising it cannot
    /// silently raise the memory ceiling — which is exactly what happened when the
    /// per-source inspection exemption was written as "one native plane per photograph
    /// the user actually zoomed into" without multiplying by the twelve sources this
    /// actor holds.
    func testTwelveSourcesAtTheirCeilingsAreBroughtUnderTheBudget() throws {
        let text = Self.stripped(try Self.coordinator())
        XCTAssertTrue(text.contains("sourceCacheLimit = 12"),
                      "the source cache moved; the untrimmed worst case below is stale")
        XCTAssertTrue(text.contains("residencyLiveSources = 4"),
                      "the live set moved; the residual below is stale")

        let sources = 12
        let holdings = Array(repeating: DecodeResidency.Holding.ceiling, count: sources)
        let untrimmed = holdings.reduce(0) { $0 + $1.total }
        XCTAssertEqual(untrimmed / Self.mib, 12_288,
                       "twelve gigabytes of wired half-float buffers is what the "
                       + "per-source rules permit with nothing bounding the process")

        let residual = DecodeResidency.residualBytes(
            holdings: holdings, budget: DecodeResidency.processBudgetBytes,
            liveSources: 4)
        XCTAssertLessThanOrEqual(residual, DecodeResidency.processBudgetBytes)
        XCTAssertEqual(residual, DecodeResidency.sourceCeilingBytes,
                       "what survives is the photograph being rendered, and nothing "
                       + "else — which is why the budget has to cover one photograph")
    }

    /// And the bound does not depend on the source-cache limit at all. Whatever twelve
    /// becomes, the trim's residual is one source; the limit is a bound on file handles
    /// and metadata, not on pixels.
    func testTheResidualDoesNotDependOnHowManySourcesAreCached() {
        let budget = DecodeResidency.processBudgetBytes
        for sources in 2...64 {
            let holdings = Array(repeating: DecodeResidency.Holding.ceiling,
                                 count: sources)
            XCTAssertEqual(DecodeResidency.residualBytes(holdings: holdings,
                                                          budget: budget,
                                                          liveSources: 4),
                           DecodeResidency.sourceCeilingBytes,
                           "\(sources) sources left something other than one behind")
        }
    }

    /// The budget covers the one thing the trim will never take. False here means the
    /// app advertises a ceiling it can only meet by evicting the decode of the
    /// photograph on screen — 768 MiB's exact failure, restated so a future edit to
    /// either constant cannot reintroduce it quietly.
    func testTheBudgetCoversThePhotographOnScreen() {
        XCTAssertTrue(DecodeResidency.budgetCoversOneSource())
        XCTAssertGreaterThanOrEqual(DecodeResidency.processBudgetBytes,
                                    DecodeResidency.sourceCeilingBytes)
        XCTAssertFalse(DecodeResidency.budgetCoversOneSource(768 * Self.mib),
                       "the figure this file used to advertise")
    }

    // MARK: - the scans' foundation

    /// Every string the scans above look for appears in this file's own comments and in
    /// the coordinator's. Without the stripper each assertion would pass or fail on
    /// prose, which this project has shipped twice.
    func testTheStripperIsWhatMakesTheseScansProofs() {
        let sample = """
        /// It read 768 * 1024 * 1024 and Array(sourceOrder.dropLast()).
        // defer { trimDecodeResidency() } is claimed in a line comment.
        /* sourceCacheLimit = 12 */
        let kept = DecodeResidency.releaseOrder(sourceCount: 3, liveSources: 4)
        """
        let stripped = Self.stripped(sample)
        XCTAssertFalse(stripped.contains("768 * 1024 * 1024"))
        XCTAssertFalse(stripped.contains("Array(sourceOrder.dropLast())"))
        XCTAssertFalse(stripped.contains("defer { trimDecodeResidency() }"))
        XCTAssertFalse(stripped.contains("sourceCacheLimit = 12"))
        XCTAssertTrue(stripped.contains("let kept = DecodeResidency.releaseOrder("))
    }

    // MARK: - helpers

    /// One member's text, cut at the next member declaration — so "this function trims
    /// on the way out" cannot be satisfied by a `defer` belonging to the function after
    /// it, which a fixed-size window would eventually allow.
    private static func body(of declaration: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: declaration),
                                  "\(declaration) is gone from the coordinator").upperBound
        let rest = text[start...]
        let next = ["\n    func ", "\n    private func ", "\n    nonisolated "]
            .compactMap { rest.range(of: $0)?.lowerBound }
            .min() ?? rest.endIndex
        return String(rest[..<next])
    }

    private static func coordinator() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        return try String(contentsOf: root.appendingPathComponent(
                            "LumenApp/RenderCoordinator.swift"), encoding: .utf8)
    }

    /// `DeliveryNameTests.strippingComments`, copied so this file stands on its own.
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
#endif

// SettleGateTests.swift
// The one line in the viewer that decides whether a settle render happens again.
//
// `PhotoRenderModel.loadAndRender`'s quality loop retries a FULL-RESOLUTION graph on
// every pass, up to `qualityAttempts` times, and one boolean decides. It cannot be
// tested by construction — `Sources/LumenApp` is `#if os(macOS)` and no test in the
// package can build a view — so it is read as text, the way `KeyGrammarTests`,
// `CanvasEditScopeTests` and `DesignSystemTests` read the rules they guard.
//
// What is pinned here is not the wording but the two facts the gate must consult. Each
// was absent once, each cost the photographer whole renders, and each is invisible in
// review because the line reads perfectly well without it.

import XCTest
@testable import LumenCore

final class SettleGateTests: XCTestCase {

    /// The quality loop's retry gate, comments stripped.
    private func settleGate() -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
            .appendingPathComponent("Sources/LumenApp/LoupeView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("LoupeView.swift not found — if it moved, move this scan with it")
            return ""
        }
        // The gate is the `if` that ends the quality loop's body. Anchor on the call
        // rather than on line numbers, and take the statement around it.
        guard let call = text.range(of: "anyBakePending(") else {
            XCTFail("the settle loop no longer asks PlanTableCache whether a bake is "
                    + "outstanding — if the question moved, move this scan with it")
            return ""
        }
        // Back up to the `if` that opens the statement, forward to its brace.
        let head = text[..<call.lowerBound]
        guard let ifStart = head.range(of: "if image != nil", options: .backwards),
              let close = text.range(of: "{", range: call.upperBound..<text.endIndex)
        else {
            XCTFail("the settle gate's shape changed past what this scan can read")
            return ""
        }
        let statement = String(text[ifStart.lowerBound..<close.upperBound])
        // Blank `//` comments so the prose explaining the rule cannot satisfy it,
        // then collapse whitespace: the gate wraps across three lines and an argument
        // label sitting at the head of one is still an argument label.
        let code = statement
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[..<slashes.lowerBound]
            }
            .joined(separator: " ")
        return code.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// A BAKE BELONGING TO ANOTHER PHOTOGRAPH MUST NOT HOLD THIS ONE'S LOOP AWAKE.
    /// The unqualified `anyBakePending` answered for the whole cache, so the compare
    /// pane's other half and the tail of the drag on the photograph just stepped away
    /// from both kept this loop re-settling — at a full-resolution render a pass, for
    /// a table that by the stale door's own contract can never touch this frame.
    func testTheSettleGateAsksAboutThisPhotographOnly() {
        let gate = settleGate()
        XCTAssertFalse(gate.isEmpty)
        XCTAssertTrue(gate.contains("anyBakePending( for:")
                        || gate.contains("anyBakePending(for:"),
                      "the settle gate is asking whether ANY photograph has a bake "
                          + "outstanding again — pass the identity of the photograph "
                          + "on screen (PlanTableCache.renderIdentity(for: url)):\n"
                          + gate)
        XCTAssertTrue(gate.contains("renderIdentity(for: url)"),
                      "the identity handed to the gate is not the one the renderer "
                          + "stamps — two spellings of one identity means the question "
                          + "answers false for every photograph:\n" + gate)
    }

    /// AND A FRAME THAT IS NOT A DRAFT CANNOT BE RIDING A STALE TABLE. Settle and
    /// export go through `PlanTableCache.table`, which blocks or joins on the exact
    /// bake; the stale door is draft-only by construction. So an exact frame on
    /// screen is exact whatever else is baking, and re-settling cannot improve it.
    func testTheSettleGateOnlyRetriesForADraftFrame() {
        let gate = settleGate()
        XCTAssertFalse(gate.isEmpty)
        XCTAssertTrue(gate.contains("isDraft"),
                      "the settle gate retries a full-resolution render even when an "
                          + "exact frame is already on screen — a settle never comes "
                          + "through the stale door, so nothing baking can improve "
                          + "it:\n" + gate)
    }

    /// The identity the gate uses and the identity the renderer stamps are the same
    /// function, so they cannot drift into two spellings.
    func testTheRendererStampsTheIdentityTheCacheDefines() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenPipeline/PipelineRenderer.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("PipelineRenderer.swift not found — if it moved, move this scan "
                    + "with it")
            return
        }
        guard let range = text.range(of: "setRenderIdentity(") else {
            XCTFail("the renderer no longer stamps a photograph identity")
            return
        }
        let site = String(text[range.lowerBound...].prefix(80))
        XCTAssertTrue(site.contains("renderIdentity(for:"),
                      "the renderer is spelling the identity itself again — the cache "
                          + "owns the spelling because the viewer has to reproduce it: "
                          + site)
    }

    /// The spelling itself, so a change to it fails here rather than silently making
    /// every `anyBakePending(for:)` answer false.
    func testTheIdentityIsTheFileURL() {
        let url = URL(fileURLWithPath: "/pictures/DSCF1234.RAF")
        XCTAssertEqual(PlanTableCache.renderIdentity(for: url), url.absoluteString)
    }
}

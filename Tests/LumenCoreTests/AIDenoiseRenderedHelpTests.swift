import Foundation
import XCTest
@testable import LumenCore

/// E1-02 (September audit), the part still open. Rendered files can no longer CHOOSE the
/// AI stand-in (`DenoiseControlAvailability`), but a pasted or older recipe can carry it,
/// and the Amount row's tooltip on such a file said "Classic is the engine that runs".
/// In `.ai` mode it is not: the coupling zeroes every Classic master that was not set
/// by hand, so on a rendered file nothing but Hot Pixels and hand-set levels runs.
///
/// The engine half of this test is the fact; the panel half is the sentence about it.
/// Both run on Linux. If the coupling is ever changed so Classic does run in AI mode
/// on a rendered file, the first assertion goes red and says to revisit the words.
final class AIDenoiseRenderedHelpTests: XCTestCase {

    func testAModeThatZeroesClassicDoesNotClaimClassicRuns() throws {
        // The fact: a fresh recipe's Classic block, in AI mode, resolves to no luma and
        // no colour denoise.
        let resolved = ISODefaults.classic(for: Denoise(mode: .ai, classic: ClassicNR()))
        XCTAssertEqual(resolved.luma, 0)
        XCTAssertEqual(resolved.chroma, 0,
                       "AI mode now keeps Classic's colour default; the rendered-file "
                           + "tooltip in DetailPanel.aiAmountHelp can say Classic runs again")

        // The sentence: the rendered-file branch of the AI Amount tooltip.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LumenCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <package>
        let panel = blankingComments(in: try String(contentsOf: root.appendingPathComponent(
            "Sources/LumenApp/DetailPanel.swift"), encoding: .utf8))
        let help = try XCTUnwrap(panel.components(separatedBy: "private var aiAmountHelp: String {").last)
        let rendered = try XCTUnwrap(help.components(separatedBy: "if isRenderedFile {").dropFirst().first)
        let branch = try XCTUnwrap(rendered.components(separatedBy: "\n        }").first)
        // Code only: the fix's own comment quotes the old sentence. Comments are blanked
        // above, trailing ones included; the lines they leave empty are dropped so the
        // continuation join below still meets one string piece after another.
        let strings = branch.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
        XCTAssertTrue(strings.contains("return \"The stand-in is part of the raw decode"),
                      "The rendered-file branch of aiAmountHelp moved; move this scan with it")
        XCTAssertFalse(strings.replacingOccurrences(of: "\"\n                + \"", with: "")
                           .contains("Classic is the engine that runs"),
                       "The tooltip claims Classic runs in AI mode on a rendered file")
        XCTAssertTrue(strings.contains("Hot Pixels"),
                      "The tooltip must say what does run: Hot Pixels and hand-set levels")
    }
}

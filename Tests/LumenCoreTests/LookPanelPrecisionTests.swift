import Foundation
import XCTest
@testable import LumenCore

/// THE ROW THAT ADVERTISED NINE THOUSAND VALUES AND COULD REACH ABOUT A FIFTH OF THEM.
///
/// Black target is `0…9` on the track and `0…15` by typing, and it used to declare
/// `step: 0.001, decimals: 3`. That is 9,000 values, against a best gesture — the
/// readout scrub under ⇧, 426 points of travel at `FineDrag.scale` — of 1,704 points:
/// 0.189 pt per step. The readout printed a third decimal that no drag, no scrub and no
/// keyboard nudge could land on, which is `LumenControls.swift`'s own "58 of the 201
/// integer values could not be landed on by dragging at all" one order finer.
///
/// A TEXT SCAN, because `LookPanel` is LumenApp — macOS only, no test target here — and
/// because the defect is a pair of literals at one call site rather than anything a type
/// can express. `LookAmountTests` guards the same panel the same way and says why; this
/// file copies its two helpers rather than sharing them, for the reason
/// `CaptureSharpenScopeTests` gives: a helper shared between two files that assert
/// unrelated things is a third thing to keep true.
final class LookPanelPrecisionTests: XCTestCase {

    // MARK: - The gesture that has to reach it

    /// Every value the readout prints, reachable by SOME gesture.
    ///
    /// The slider contract is explicit that there are two instruments — "the readout is
    /// the precision instrument and the track is the coarse one" — so the honest
    /// question is not what the track can do but whether anything can. Both ends of the
    /// arithmetic are READ: the step and the range from the panel, the scrub's travel
    /// from `LumenSlider.scrubTrack`, the fine gear from `FineDrag` in this module. The
    /// day any of the three moves this recomputes instead of reassuring.
    func testTheBlackTargetRowCanReachEveryValueItsReadoutPrints() throws {
        let row = try Self.blackTargetRow()
        let controls = Self.strippingComments(try Self.appSource("LumenControls.swift"))

        let scrub = try XCTUnwrap(Self.literal("SliderTrack(width: ", in: controls),
                                  "the scrub's travel is gone from LumenSlider")
        let travel = scrub / FineDrag.scale
        let steps = (row.upper - row.lower) / row.step

        XCTAssertGreaterThanOrEqual(
            travel / steps, 1.0,
            "Black target advertises \(Int(steps)) values across "
            + "\(row.lower)…\(row.upper) at step \(row.step), and the widest gesture the "
            + "app has — \(scrub) pt of scrub at the \(FineDrag.scale) fine gear, so "
            + "\(travel) pt — moves \(travel / steps) pt per step. A readout printing a "
            + "precision no gesture can address is a readout lying about the control")
    }

    /// The step and the decimals, which have to be the same statement twice.
    ///
    /// A readout with more decimals than the step has is the defect above; a readout
    /// with fewer is worse, because two adjacent reachable values then print the same
    /// string and the control looks stuck. So the smallest increment the row can make
    /// must survive a round trip through the format the readout uses — which is exactly
    /// `String(format: "%.<decimals>f", value)`, `LumenSlider.formatted`.
    func testTheBlackTargetReadoutPrintsExactlyTheStepItMoves() throws {
        let row = try Self.blackTargetRow()
        let printed = String(format: "%.\(row.decimals)f", row.step)
        XCTAssertEqual(try XCTUnwrap(Double(printed)), row.step,
                       accuracy: row.step / 1_000,
                       "the row steps by \(row.step) and prints \(row.decimals) decimals, "
                       + "so its own quantum reads back as \(printed)")

        // And the hard range is what keeps the precision that the step gave up: a
        // typed value is not snapped, so the preset's own 0.0152 is still enterable.
        XCTAssertEqual(row.hard, "0...15",
                       "the typed range is what makes a coarser step affordable; "
                       + "without it two decimals would be the only precision there is")
    }

    // MARK: - helpers

    private struct Row {
        let lower: Double
        let upper: Double
        let step: Double
        let decimals: Int
        let hard: String
    }

    /// The one call site, parsed out of the panel with its comments removed.
    ///
    /// Comments first, for the reason `LookAmountTests` records: this file's subject is
    /// a pair of numbers that the paragraph above them also discusses, and an unstripped
    /// scan is satisfied by the prose explaining the line it is meant to find missing.
    private static func blackTargetRow() throws -> Row {
        let panel = strippingComments(try appSource("LookPanel.swift"))
        let anchor = try XCTUnwrap(panel.range(of: "title: \"Black target\""),
                                   "the film lab no longer draws a Black target row")
        let tail = panel[anchor.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "onReset:"),
                                "the Black target row no longer clears its override")
        let slice = String(tail[..<end.lowerBound])

        // " range: " with the leading space, so it cannot match `hardRange:`.
        let range = try XCTUnwrap(argument(" range: ", in: slice))
        let bounds = range.components(separatedBy: "...")
        XCTAssertEqual(bounds.count, 2, "the row's range is not a closed range: \(range)")
        return Row(lower: try XCTUnwrap(Double(bounds[0])),
                   upper: try XCTUnwrap(Double(bounds[1])),
                   step: try XCTUnwrap(Double(try XCTUnwrap(argument("step: ", in: slice)))),
                   decimals: try XCTUnwrap(Int(try XCTUnwrap(argument("decimals: ",
                                                                      in: slice)))),
                   hard: try XCTUnwrap(argument("hardRange: ", in: slice)))
    }

    /// One labelled argument's text, up to the comma or newline that ends it.
    private static func argument(_ name: String, in slice: String) -> String? {
        guard let start = slice.range(of: name) else { return nil }
        let rest = slice[start.upperBound...]
        let stop = rest.firstIndex { $0 == "," || $0 == ")" || $0 == "\n" } ?? rest.endIndex
        return rest[..<stop].trimmingCharacters(in: .whitespaces)
    }

    /// A `let NAME = <number>` written in a source file, read back as a number.
    private static func literal(_ prefix: String, in source: String) -> Double? {
        guard let start = source.range(of: prefix) else { return nil }
        let rest = source[start.upperBound...]
        let digits = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }

    private static func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

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

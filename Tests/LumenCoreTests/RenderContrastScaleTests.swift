import Foundation
import XCTest
@testable import LumenCore

/// K-039 — THE SLOPE CONTROL THAT SPENT NINE TENTHS OF ITS TRACK ABOVE ANY USEFUL VALUE.
///
/// Render Contrast is a slope at mid-grey: 1.0 is the identity, 2.0 doubles a difference
/// and 0.5 halves it, so 2.0 and 0.5 are the same distance from 1.0 and the axis that
/// says so is the logarithm. It shipped on a LINEAR 0.1…10 track. The default of 1.5 sat
/// at 14.1% of the travel, the band anyone actually works in — call it 1.0…1.9 — was
/// 9.1% of it, and everything above 1.9 was nine tenths of a track nobody has a use for.
///
/// `docs/04-spec-tone.md:302` has specified "0.1–10.0, log-scaled" since it was written.
/// `SliderScale` had `linear` and `reciprocal` and no third case, and this call site
/// passed no `scale:` at all, so it took the default. Two halves of one unapplied fix.
///
/// A TEXT SCAN, because `LookPanel` is LumenApp — macOS only, no test target on this
/// lane — and because the defect is one missing argument at one call site rather than
/// anything a type can express. `LookPanelPrecisionTests` guards the same panel the same
/// way and states the reason; this file copies its two helpers rather than sharing them,
/// for the reason that file gives in turn: a helper shared between two files asserting
/// unrelated things is a third thing to keep true.
///
/// The MATHS of the axis is `SliderScaleTests`. This is only the wiring, which is the
/// half that was missing and the half no compiler on any lane checks.
final class RenderContrastScaleTests: XCTestCase {

    func testTheRenderContrastRowAsksForTheLogAxis() throws {
        let slice = try Self.renderContrastRow()
        XCTAssertEqual(Self.argument("scale: ", in: slice), ".log",
                       "the Render Contrast row is back on a linear track: its default "
                           + "of 1.5 then sits at 14.1% of the travel and the 1.0…1.9 "
                           + "band is 9.1% of it, which is K-039")
    }

    /// The scale and the range are one statement, not two.
    ///
    /// A log axis is undefined at and below zero — `SliderTrack.isUsable` says so and
    /// hands every entry point the value back rather than dividing by it — so a range
    /// edited to start at 0 would not make the row linear again, it would make the row
    /// INERT, and it would do it silently. The pair is asserted together so that moving
    /// either one has to answer for the other.
    func testTheRowsRangeIsOneTheLogAxisCanRepresent() throws {
        let slice = try Self.renderContrastRow()
        let range = try XCTUnwrap(Self.argument(" range: ", in: slice),
                                  "the Render Contrast row has no range")
        let bounds = range.components(separatedBy: "...")
        XCTAssertEqual(bounds.count, 2, "the row's range is not a closed range: \(range)")
        let lower = try XCTUnwrap(Double(bounds[0]))
        let upper = try XCTUnwrap(Double(bounds[1]))
        XCTAssertTrue(SliderScale.log.canRepresent(lowerBound: lower, upperBound: upper),
                      "\(range) cannot be put on a log axis, so the row would report "
                          + "itself unusable and stop responding to a drag entirely")

        // And the geometry the fix exists to produce, computed from the row's own
        // numbers rather than restated: the identity lands mid-track, and the default
        // lands past the middle instead of in the first seventh.
        let track = SliderTrack(width: 158, lowerBound: lower, upperBound: upper,
                                step: 0.05, scale: .log)
        XCTAssertEqual(track.fraction(of: 1.0), 0.5, accuracy: 1e-9,
                       "1.0 is the identity of a slope and should sit at the middle of "
                           + "a range that is symmetric in ratio around it")
        XCTAssertGreaterThan(track.fraction(of: 1.5), 0.5)
    }

    // MARK: - helpers

    /// The one call site, parsed out of the panel with its comments removed. Comments
    /// first because the paragraph above this row now explains the very argument the
    /// scan is looking for, and an unstripped scan would be satisfied by the prose.
    private static func renderContrastRow() throws -> String {
        let panel = strippingComments(try appSource("LookPanel.swift"))
        let anchor = try XCTUnwrap(panel.range(of: "\"render.contrast\""),
                                   "the Look panel no longer draws a Render Contrast row")
        let tail = panel[anchor.upperBound...]
        let end = try XCTUnwrap(tail.range(of: "onReset:"),
                                "the Render Contrast row no longer clears its override")
        return String(tail[..<end.lowerBound])
    }

    /// One labelled argument's text, up to the comma or newline that ends it.
    private static func argument(_ name: String, in slice: String) -> String? {
        guard let start = slice.range(of: name) else { return nil }
        let rest = slice[start.upperBound...]
        let stop = rest.firstIndex { $0 == "," || $0 == ")" || $0 == "\n" } ?? rest.endIndex
        return rest[..<stop].trimmingCharacters(in: .whitespaces)
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

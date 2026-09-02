// SurroundPaintTests.swift
// H1-01: the value `⌘B` and `L` write had one writer and six painters over it.
//
// `ViewingConditionsTests` pins the ARITHMETIC — the cycle, the ISO 12646 mid-grey,
// assessment beating lights-out, and (the half this defect turned into a lie) that
// neither control moves anything when both are off. All of it was correct, and none of
// it reached the screen.
//
// `AppState.surroundValue` is the one value both keys write. `ContentView` painted it
// once, on the outermost stack. Then `LoupeView` laid `Lumen.viewerBackground` — a
// `let` of `NSColor(white: 0.165)` — over that stack as the first layer of the viewer
// ZStack and again as the `GeometryReader`'s background, and `CompareView` did the same
// in its group background, its empty second pane, `ComparePane` and `SurveyCell`. Every
// one of them opaque, every one of them above the only place the value was painted. (The
// audit that raised this counted five and missed the empty second pane; the count is why
// this test counts rather than merely checking the constant is gone.) So
// the field immediately around the photograph — the ONLY region ISO 12646 is about —
// stayed at 0.165 in both modes.
//
// The half that did fire made it worse than a no-op: the status bar said "Assessment
// surround on — ISO 12646 mid-grey", and `LoupeView.plate` drew the standard's
// diffuse-white anchor around the picture. On the mid-grey field that anchor is a
// reference for the eye; on the 0.165 field that was actually there it is a
// maximum-contrast white border, and a photographer trusting the announcement was
// judging tone against a reference that did not exist.
//
// `Sources/LumenApp` is `#if os(macOS)` and has no test target on this lane, so the
// wiring is checked as TEXT. Comments are stripped first, and here that is not a
// formality: the fix leaves the words `Lumen.viewerBackground` in the comments at the
// call sites, explaining what used to be there. An unstripped scan would find them and
// report the defect that was just fixed — and, worse, an unstripped scan for
// `state.surroundColor` would be satisfied by prose after the code was reverted. This
// project has been bitten by exactly that twice (see `EditRevisionRuleTests`).

import XCTest
@testable import LumenCore

final class SurroundPaintTests: XCTestCase {

    /// The surfaces the photograph is actually drawn on, with the number of grounds
    /// each one paints. Counted rather than merely present, because "the constant is
    /// gone" and "the surround arrives" are different facts: a call site deleted
    /// outright satisfies the first and fails the photographer.
    ///
    ///   · `LoupeView` — the viewer ZStack's first layer, and the `GeometryReader`
    ///     background under it.
    ///   · `CompareView` — the group background, the empty second pane of a 2-up,
    ///     `ComparePane`'s ground and `SurveyCell`'s.
    private static let viewerGrounds = ["LoupeView.swift": 2, "CompareView.swift": 4]

    // MARK: - The six painters

    func testNoViewerSurfacePaintsTheFieldAsAConstant() throws {
        for (file, _) in Self.viewerGrounds.sorted(by: { $0.key < $1.key }) {
            let source = Self.strippingComments(try Self.appSource(file))
            XCTAssertFalse(
                source.contains("Lumen.viewerBackground"),
                "\(file) paints Lumen.viewerBackground — a `let` of 0.165 — on the "
                + "field the photograph sits on. That constant is opaque and it is "
                + "ABOVE the one place AppState.surroundColor is painted, so ⌘B's ISO "
                + "12646 mid-grey and L's black never reach the region the standard "
                + "is about. The status bar still announces the surround, and "
                + "LoupeView.plate still draws the diffuse-white anchor onto whatever "
                + "is really there — which on 0.165 is a maximum-contrast border sold "
                + "as a reference. Read the ground from the state, as every other "
                + "viewer ground does.")
        }
    }

    func testEveryViewerGroundReadsTheOneValueTheKeysWrite() throws {
        for (file, expected) in Self.viewerGrounds.sorted(by: { $0.key < $1.key }) {
            let source = Self.strippingComments(try Self.appSource(file))
            let found = source.components(separatedBy: "state.surroundColor").count - 1
            XCTAssertGreaterThanOrEqual(
                found, expected,
                "\(file) reads state.surroundColor \(found) time(s); \(expected) "
                + "grounds in it have to. A ground that stopped reading it is a "
                + "region of the field that will not follow ⌘B or L — and a field "
                + "that is mid-grey in one half and 0.165 in the other is worse for "
                + "judging tone than one that is wrong everywhere, because the eye "
                + "adapts to the brighter half.")
        }
    }

    // MARK: - The anchor and the field

    /// The white anchor needs no change now that the field is real — it is already
    /// gated on assessment mode alone and already `strokeBorder`, so it grows inward
    /// and cannot move the picture. What it does need is for the field under it to be
    /// the field the standard prescribes, and that is a fact about the SAME file: an
    /// anchor drawn in `LoupeView` while `LoupeView` paints a constant ground is the
    /// worse-than-nothing case H1-01 was raised for. So the two are asserted together.
    func testTheAnchorIsNeverDrawnOnAFieldThatCannotFollowTheMode() throws {
        let source = Self.strippingComments(try Self.appSource("LoupeView.swift"))
        XCTAssertTrue(
            source.contains("ViewingConditions.showsWhiteAnchor(assessment:"),
            "the ISO 12646 diffuse-white anchor has to be gated on the rule in "
            + "LumenCore, not on a local reading of assessmentMode")
        XCTAssertTrue(
            source.contains("state.surroundColor"),
            "LoupeView draws the diffuse-white anchor but does not read the surround, "
            + "so in assessment mode it puts a white line around the photograph on a "
            + "near-black field. The anchor exists to stop the eye adapting to the "
            + "picture; without the mid-grey under it, it does the opposite.")
    }

    // MARK: - One writer

    /// The other half of the invariant. Routing five painters through a value is only
    /// worth anything if that value is the one the two keys move, so this pins the
    /// derivation rather than trusting the name: `AppState.surroundColor` must come
    /// from `ViewingConditions.surround`, which is where the precedence — assessment
    /// wins over lights-out's black — is argued and where `ViewingConditionsTests`
    /// tests it.
    func testTheValueTheViewerReadsIsTheOneTheKeysWrite() throws {
        let source = Self.strippingComments(try Self.appSource("AppState.swift"))
        XCTAssertTrue(source.contains("var surroundColor"),
                      "the viewer grounds read AppState.surroundColor; it has to exist")
        XCTAssertTrue(
            source.contains("ViewingConditions.surround("),
            "AppState.surroundColor no longer derives from ViewingConditions.surround, "
            + "so the viewer is now routed through a value that does not move under ⌘B "
            + "or L. That is the same defect as painting the constant, one file up, and "
            + "it would leave the assessment announcement in the status bar unbacked.")
    }

    // MARK: - helpers

    private static func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// Line and block comments out, so no assertion here can be satisfied by prose
    /// about the thing it is looking for. See this file's header: the fixed call sites
    /// name `Lumen.viewerBackground` in their comments on purpose.
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

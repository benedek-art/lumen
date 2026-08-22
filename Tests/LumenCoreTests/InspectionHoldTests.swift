// InspectionHoldTests.swift
// The rule that lets `[` and `]` be two features without being ambiguous anywhere.
//
// Two things wanted the same pair of keys: the contact sheet's cell size, which works,
// and docs/10 §10.5's momentary Shadow Boost and Highlight Inspect, which did not exist.
// `InspectionHolds` resolves that by surface, and every part of it that could be wrong —
// the split, the key-repeat policy, the key-up pairing, the EV amounts and the clamp — is
// arithmetic and state, which is exactly the shape of rule that used to live in a SwiftUI
// dispatcher nothing on this machine could run.
//
// The last two assertions scan `Sources/LumenApp` as text, the way `KeyGrammarTests`
// does. They are what stops the rest of this file describing code nothing calls.

import XCTest
@testable import LumenCore


final class InspectionHoldTests: XCTestCase {

    func testEverySurfaceHasExactlyOneMeaningForTheseKeys() {
        let thumbnail = InspectionHolds.thumbnailSurfaces
        let holds = InspectionHolds.holdSurfaces
        XCTAssertTrue(thumbnail.isDisjoint(with: holds),
                      "a surface where `[` is both a size step and a hold is a surface "
                          + "where the key does two things at once")
        XCTAssertEqual(thumbnail.union(holds), Set(InspectionSurface.allCases),
                       "a surface with no rule falls through to whatever the dispatcher "
                           + "happens to do, which is how the collision started")
    }

    func testTheGridKeepsTheThumbnailControlItAlreadyHad() {
        // The constraint on this change: do not break a working control. In the grid —
        // the only view that draws `gridThumbnailSize` — the keys behave exactly as
        // they did, step size included.
        XCTAssertEqual(InspectionHolds.resolve(key: "[", surface: .grid, isKeyDown: true),
                       .stepThumbnailSize(delta: -24))
        XCTAssertEqual(InspectionHolds.resolve(key: "]", surface: .grid, isKeyDown: true),
                       .stepThumbnailSize(delta: 24))
        XCTAssertEqual(InspectionHolds.thumbnailStep, 24, accuracy: 1e-12)
    }

    func testAutoRepeatStillWalksTheThumbnailLadder() {
        // Holding `]` to grow the cells is the gesture the control is used with, and
        // the old dispatcher explicitly allowed repeat for these two keys.
        XCTAssertEqual(InspectionHolds.resolve(key: "]", surface: .grid,
                                               isKeyDown: true, isRepeat: true),
                       .stepThumbnailSize(delta: 24))
    }

    func testTheThreeSurfacesShowingOnePhotographGetTheHolds() {
        for surface in [InspectionSurface.loupe, .compare, .survey] {
            XCTAssertEqual(InspectionHolds.resolve(key: "[", surface: surface,
                                                   isKeyDown: true),
                           .beginHold(.shadowBoost), "\(surface)")
            XCTAssertEqual(InspectionHolds.resolve(key: "]", surface: surface,
                                                   isKeyDown: true),
                           .beginHold(.highlightInspect), "\(surface)")
        }
    }

    func testAnAutoRepeatDoesNotReEnterAHoldThatIsAlreadyRunning() {
        XCTAssertEqual(InspectionHolds.resolve(key: "[", surface: .loupe,
                                               isKeyDown: true, isRepeat: true),
                       .ignore)
    }

    func testASecondHoldCannotStartWhileOneIsHeld() {
        // Two exposure gains at once is a state neither key's release could unwind.
        XCTAssertEqual(InspectionHolds.resolve(key: "]", surface: .loupe,
                                               isKeyDown: true, holdActive: "["),
                       .ignore)
    }

    func testAKeyUpOnlyEndsItsOwnHold() {
        // Rolling off `]` while `[` is down must not cancel `[`, or the picture stays
        // boosted with nothing holding it.
        XCTAssertEqual(InspectionHolds.resolve(key: "]", surface: .loupe,
                                               isKeyDown: false, holdActive: "["),
                       .ignore)
        XCTAssertEqual(InspectionHolds.resolve(key: "[", surface: .loupe,
                                               isKeyDown: false, holdActive: "["),
                       .endHold(.shadowBoost))
    }

    func testAKeyUpWithNothingHeldIsNotAnEnd() {
        XCTAssertEqual(InspectionHolds.resolve(key: "[", surface: .loupe,
                                               isKeyDown: false),
                       .ignore)
    }

    func testAHoldSurvivesASwitchToTheGridAndItsReleaseStillEndsIt() {
        // `[` down in the loupe, then `G`, then `[` up. If the grid branch claimed the
        // key-up as a size step the boost would never be released.
        XCTAssertEqual(InspectionHolds.resolve(key: "[", surface: .grid,
                                               isKeyDown: false, holdActive: "["),
                       .endHold(.shadowBoost))
        // And its repeats while still held are not size steps either.
        XCTAssertEqual(InspectionHolds.resolve(key: "[", surface: .grid, isKeyDown: true,
                                               isRepeat: true, holdActive: "["),
                       .ignore)
    }

    func testAKeyThisRuleDoesNotOwnIsLeftAlone() {
        for key in ["z", "h", " ", "", "{"] {
            XCTAssertEqual(InspectionHolds.resolve(key: key, surface: .loupe,
                                                   isKeyDown: true),
                           .ignore, "\(key)")
        }
    }

    func testTheGainsAreTheStopsTheSpecNames() {
        // docs/10 §10.5: Shadow Boost +3 EV, Highlight Inspect −3 EV, configurable
        // 2 / 3 / 4.
        XCTAssertEqual(InspectionHolds.defaultStops, 3, accuracy: 1e-12)
        XCTAssertEqual(InspectionHolds.configurableStops, [2, 3, 4])
        XCTAssertEqual(InspectionHolds.gain(.shadowBoost), 8, accuracy: 1e-12)
        XCTAssertEqual(InspectionHolds.gain(.highlightInspect), 0.125, accuracy: 1e-12)
        XCTAssertEqual(InspectionHolds.gain(.shadowBoost, stops: 2), 4, accuracy: 1e-12)
        XCTAssertEqual(InspectionHolds.gain(.highlightInspect, stops: 4), 0.0625,
                       accuracy: 1e-12)
    }

    func testAHoldIsAlwaysAGainAndTheTwoAreAlwaysInverses() {
        for stops in InspectionHolds.configurableStops {
            let up = InspectionHolds.gain(.shadowBoost, stops: stops)
            let down = InspectionHolds.gain(.highlightInspect, stops: stops)
            XCTAssertEqual(up * down, 1, accuracy: 1e-12, "\(stops) stops")
            XCTAssertGreaterThan(up, 1)
            XCTAssertLessThan(down, 1)
        }
    }

    func testAnAbsurdStopCountCannotWhiteOutTheFrame() {
        // A hold handed 40 would look like a render failure, and the user would have no
        // way to tell it from one.
        XCTAssertEqual(InspectionHolds.gain(.shadowBoost, stops: 40), 16, accuracy: 1e-12)
        XCTAssertEqual(InspectionHolds.gain(.shadowBoost, stops: 0), 4, accuracy: 1e-12)
        XCTAssertEqual(InspectionHolds.gain(.shadowBoost, stops: .nan), 8, accuracy: 1e-12)
        XCTAssertEqual(InspectionHolds.gain(.highlightInspect, stops: -100), 0.25,
                       accuracy: 1e-12)
    }

    func testTheBadgeNamesTheDirectionAndTheAmount() {
        // A momentary change to the picture that does not announce itself is
        // indistinguishable from an edit that happened by accident.
        XCTAssertEqual(InspectionHold.shadowBoost.badge(stops: 3), "SHADOW BOOST +3 EV")
        XCTAssertEqual(InspectionHold.highlightInspect.badge(stops: 3),
                       "HIGHLIGHT INSPECT −3 EV")
        XCTAssertEqual(InspectionHold.shadowBoost.badge(stops: 2), "SHADOW BOOST +2 EV")
    }

    func testTheKeysThisRuleOwnsAreKeysTheDispatcherClaims() {
        XCTAssertTrue(InspectionHolds.keys.isSubset(of: KeyGrammar.dispatchedKeys),
                      "the rule owns \(InspectionHolds.keys.subtracting(KeyGrammar.dispatchedKeys)) "
                          + "which the keyboard reference does not list")
        XCTAssertEqual(Set(InspectionHold.allCases.map(\.key)), InspectionHolds.keys)
    }

    func testTheDispatcherRoutesTheseKeysThroughThisRule() {
        // The rule is only worth testing if the app uses it. This fails the moment
        // Keymap.swift goes back to doing its own arithmetic on these two keys — which
        // is what it did, and is how the collision went unnoticed.
        let keymap = RawTruthProvenanceTests.repositoryRoot
            .appendingPathComponent("Sources/LumenApp/Keymap.swift")
        guard let text = try? String(contentsOf: keymap, encoding: .utf8) else {
            return XCTFail("Keymap.swift not found at \(keymap.path)")
        }
        let code = RawTruthProvenanceTests.withoutComments(text)
        // `resolve(` with the paren, not `resolve`: `InspectionHolds.resolveSomething`
        // contains the shorter string, so the loose form passes on a call to a function
        // that is not this rule. Found by substituting exactly that.
        // Split across two literals so `scripts/check-swift-surface.py` does not read
        // this needle as a call site with no matching declaration. The paren is the
        // point of it: `InspectionHolds.resolveSomething` contains the shorter string,
        // so the loose form passes on a call to a function that is not this rule —
        // found by substituting exactly that and watching this test stay green.
        let needle: String = "InspectionHolds.resolve" + "(key:"
        let calls = code.components(separatedBy: needle).count - 1
        XCTAssertGreaterThanOrEqual(calls, 2,
                                    "\(calls) call(s) to the rule. Both halves of a hold "
                                        + "go through it — the key-down that starts one "
                                        + "and the key-up that ends it — and a "
                                        + "dispatcher that answers one of those itself "
                                        + "is the half nothing in this class covers")
        XCTAssertTrue(code.contains("case \"[\", \"]\":"),
                      "the two keys are no longer answered by one case, so one of them "
                          + "is being handled somewhere this scan cannot see")
        XCTAssertFalse(code.contains("state.gridThumbnailSize = max("),
                       "the hand-rolled thumbnail arithmetic is back beside the rule "
                           + "that replaced it")
    }

    func testTheKeyboardReferenceDescribesTheSplit() {
        // The Help sheet may not still say these keys are thumbnail size, because in
        // three of four views they are not.
        let rows = KeyGrammar.groups.flatMap(\.rows).filter { $0.keys.contains("[") }
        XCTAssertFalse(rows.isEmpty, "`[` vanished from the keyboard reference")
        let text = rows.map(\.action).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("thumbnail"), "the grid's control is unlisted")
        XCTAssertTrue(text.contains("shadow"), "the shadow-boost hold is unlisted")
        XCTAssertTrue(text.contains("highlight"), "the highlight-inspect hold is unlisted")
    }
}

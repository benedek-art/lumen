// MaskFilterTests.swift
// docs/36 §1.5's second half — a mask list that survives fifteen masks.
//
// Folders took the first bite. This is the other one: past eight masks the list stops
// being scannable, and the only reliable way to find one is to describe it.
//
// The property worth testing is WHAT IS SEARCHABLE. Matching only `Mask.name` is the
// obvious implementation and it is useless, because the masks you cannot find are
// exactly the ones you never bothered to name — and "the radial one" is how people
// describe those. Everything a row DISPLAYS is matched: the typed name, the automatic
// name, the stack summary underneath it, and the folder it sits in.

#if os(macOS)

import XCTest
@testable import LumenApp
@testable import LumenCore

final class MaskFilterTests: XCTestCase {

    private func mask(_ name: String, _ kinds: [MaskKind] = [.radial]) -> Mask {
        var m = Mask(id: UUID().uuidString, name: name)
        m.components = kinds.map { MaskComponent(op: .add, kind: $0) }
        return m
    }

    private func matches(_ m: Mask, _ query: String, index: Int = 0,
                         group: MaskGroup? = nil) -> Bool {
        MaskPanel.matches(m, index: index, group: group, query: query)
    }

    func testAnEmptyQueryShowsEverything() {
        XCTAssertTrue(matches(mask("sky"), ""))
        XCTAssertTrue(matches(mask(""), "   "))
    }

    func testItFindsTheNameThePhotographerTyped() {
        XCTAssertTrue(matches(mask("Sky over the ridge"), "ridge"))
        XCTAssertFalse(matches(mask("Sky over the ridge"), "face"))
    }

    func testItIsCaseInsensitiveAndIgnoresSurroundingSpace() {
        XCTAssertTrue(matches(mask("Sky"), "SKY"))
        XCTAssertTrue(matches(mask("Sky"), "  sky  "))
    }

    func testItFindsAnUNNAMEDMaskByWhatItIs() {
        // The case that makes the feature work. A mask you never named is exactly the
        // one you cannot find, and "the radial one" is how you would ask for it.
        let unnamed = mask("", [.radial])
        XCTAssertTrue(matches(unnamed, "radial"))
        XCTAssertTrue(matches(unnamed, "gradient"))
        XCTAssertFalse(matches(unnamed, "brush"))
    }

    func testItFindsAMaskByWhatIsInItsStack() {
        // The summary line under the name — `∪ Brush ∖ Linear Gradient` — is on screen,
        // so it is searchable. "Which one had the brush in it" is a real question.
        let stacked = mask("Ridge", [.linear, .brush])
        XCTAssertTrue(matches(stacked, "brush"))
        XCTAssertTrue(matches(stacked, "ridge"))
    }

    func testItFindsEveryMaskInAFolderByTheFoldersName() {
        let group = MaskGroup(id: "g", name: "Retouch")
        XCTAssertTrue(matches(mask("cheek"), "retouch", group: group))
        XCTAssertFalse(matches(mask("cheek"), "retouch", group: nil))
    }

    func testTheAutomaticNameCarriesTheIndexSoMaskSevenIsFindable() {
        let plain = Mask(id: "m", name: "")
        XCTAssertTrue(MaskPanel.matches(plain, index: 6, group: nil, query: "Mask 7"))
        XCTAssertFalse(MaskPanel.matches(plain, index: 6, group: nil, query: "Mask 8"))
    }

    func testTheThresholdIsWhereAListStopsBeingScannable() {
        // A search field over four masks costs a row and saves nothing. The number is
        // written down so moving it is deliberate.
        XCTAssertEqual(MaskPanel.searchAppearsAt, 8)
    }
}

#endif

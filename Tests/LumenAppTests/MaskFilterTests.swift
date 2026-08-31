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
        // The summary line under the name — `Linear Gradient plus Brush` — is on
        // screen, so it is searchable. "Which one had the brush in it" is a real
        // question.
        let stacked = mask("Ridge", [.linear, .brush])
        XCTAssertTrue(matches(stacked, "brush"))
        XCTAssertTrue(matches(stacked, "ridge"))
    }

    /// The owner read the component row as one word and asked what "Ubrush" was.
    ///
    /// It was `∪ Brush` — U+222A, the set-union operator, in a monospaced face at 11pt,
    /// five points from a word set in the same grey. At that size ∪ is a capital U with
    /// no crossbar and no serifs, so the eye bound the two runs together; in the row's
    /// caption-sized subtitle it read as "a Brush" instead.
    ///
    /// This asserts the register rather than the exact wording: no set-theory operator
    /// may appear in a string a photographer reads. Rewording the phrases is free;
    /// putting an operator back is not.
    func testTheStackSummaryUsesWordsAndNotSetTheory() {
        let stacked = mask("Ridge", [.linear, .brush])
        let line = MaskPanel.stackSummary(stacked)
        for operatorGlyph in ["∪", "∖", "∩", "\\"] {
            XCTAssertFalse(line.contains(operatorGlyph),
                           "the summary still prints \(operatorGlyph): \(line)")
        }
        XCTAssertTrue(line.contains("Brush"), line)
        XCTAssertTrue(line.contains("Linear Gradient"), line)
    }

    /// A stack begins by selecting something, so the leading Add was always ceremony.
    ///
    /// What a photographer needs to pick out of a three-row stack is the row that
    /// SUBTRACTS. Marking every row equally is the same as marking none.
    func testALeadingAddIsNotAnnounced() {
        let single = mask("Sky", [.linear])
        XCTAssertEqual(MaskPanel.stackSummary(single), "Linear Gradient")
        XCTAssertFalse(MaskPanel.stackSummary(single).lowercased().contains("plus"))
    }

    /// Every operation still has to be sayable, or the badge on a subtracting row has
    /// nothing to print.
    func testEveryOperationHasAWordInBothRegisters() {
        for op in [MaskOp.add, .subtract, .intersect] {
            XCTAssertFalse(MaskPanel.opName(op).isEmpty)
            XCTAssertFalse(MaskPanel.opPhrase(op).isEmpty)
            XCTAssertEqual(MaskPanel.opName(op).first?.isUppercase, true)
        }
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

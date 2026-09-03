// MaskSelectionTests.swift
// The panel discloses many masks and edits one.

import XCTest
@testable import LumenCore

final class MaskSelectionTests: XCTestCase {

    /// The defect, in one assertion: mask B is open but not selected, so nothing in it
    /// is being edited — however many components A's index happens to be valid for.
    func testADisclosedButUnselectedMaskHasNoActiveComponent() {
        XCTAssertNil(MaskSelection.activeComponent(maskID: "B", componentCount: 3,
                                                   selectedMaskID: "A",
                                                   selectedComponent: 1),
                     "an unselected mask drew its parts at the SELECTED mask's index — "
                     + "highlighting the wrong row, opening an editor on it, and moving "
                     + "the other mask's selection when tapped")
    }

    func testTheSelectedMaskEditsTheChosenComponent() {
        XCTAssertEqual(MaskSelection.activeComponent(maskID: "A", componentCount: 3,
                                                     selectedMaskID: "A",
                                                     selectedComponent: 1), 1)
    }

    /// A stale index must clamp, not trap: a component can be removed between the click
    /// that chose it and the next pass over the list.
    func testAStaleIndexClampsIntoTheMask() {
        XCTAssertEqual(MaskSelection.activeComponent(maskID: "A", componentCount: 2,
                                                     selectedMaskID: "A",
                                                     selectedComponent: 9), 1)
        XCTAssertEqual(MaskSelection.activeComponent(maskID: "A", componentCount: 2,
                                                     selectedMaskID: "A",
                                                     selectedComponent: -4), 0)
    }

    func testAMaskWithNoPartsHasNothingToEdit() {
        XCTAssertNil(MaskSelection.activeComponent(maskID: "A", componentCount: 0,
                                                   selectedMaskID: "A",
                                                   selectedComponent: 0))
    }

    func testNothingSelectedMeansNothingActive() {
        XCTAssertNil(MaskSelection.activeComponent(maskID: "A", componentCount: 3,
                                                   selectedMaskID: nil,
                                                   selectedComponent: 0))
    }

    /// Two masks open at once: exactly one of them is editing.
    func testAcrossEveryDisclosedMaskExactlyOneIsEditing() {
        let disclosed = ["A", "B", "C"]
        let editing = disclosed.filter {
            MaskSelection.activeComponent(maskID: $0, componentCount: 4,
                                          selectedMaskID: "B",
                                          selectedComponent: 2) != nil
        }
        XCTAssertEqual(editing, ["B"],
                       "with three chevrons open, only the selected mask edits")
    }
}

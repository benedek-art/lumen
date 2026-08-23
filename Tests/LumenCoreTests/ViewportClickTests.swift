// ViewportClickTests.swift
// Which presses on the image viewer mean "zoom here" and which mean nothing.
//
// The defect this pins: the viewer's press gesture asked one question — did the pointer
// move less than three points? — and toggled the zoom whenever the answer was yes. The
// gesture covers the whole canvas and at fit its pan branch returns immediately, so at
// fit the gesture was a zoom toggle and nothing else: a press on the grey surround
// beside the photograph, a click to bring the window forward, a press held while
// thinking, a modifier-click, all of them jumped the viewer to 1:1 and the next one
// dropped it back. That is the "lots of zoom in, zoom out things" the owner reported,
// and `zoomLevel` having exactly one writer is why looking at the writer found nothing.

import XCTest
@testable import LumenCore

final class ViewportClickTests: XCTestCase {

    private func press(travel: Double = 0, duration: Double = 0.08,
                       onImage: Bool = true, modifier: Bool = false) -> ViewportPress {
        ViewportPress(travel: travel, duration: duration, landedOnImage: onImage,
                      hadModifier: modifier)
    }

    func testAnOrdinaryClickOnThePhotographStillZooms() {
        // The behaviour being kept. Click-to-zoom is fifteen years of muscle memory and
        // the viewer's own header promises it; the fix is about aim, not about removing
        // the verb.
        XCTAssertTrue(ViewportClick.togglesZoom(press()))
        XCTAssertTrue(ViewportClick.togglesZoom(press(travel: 2, duration: 0.2)))
    }

    func testAPressOnTheSurroundBesideThePhotographDoesNotZoom() {
        // A fitted frame letterboxes on one axis and the gesture covers the whole
        // canvas, so this was reachable on every single photograph that is not exactly
        // the window's aspect — which is nearly all of them.
        XCTAssertFalse(ViewportClick.togglesZoom(press(onImage: false)))
        XCTAssertFalse(ViewportClick.togglesZoom(press(travel: 1, onImage: false)))
    }

    func testAPressHeldRatherThanClickedDoesNotZoom() {
        // Pressing to steady the eye, pressing while deciding where to drag, pressing
        // and changing your mind. None of those are a request to zoom, and all of them
        // ended in one, because the only thing measured was distance.
        XCTAssertFalse(ViewportClick.togglesZoom(press(duration: 1.2)))
        XCTAssertFalse(ViewportClick.togglesZoom(press(duration: 0.51)))
        XCTAssertTrue(ViewportClick.togglesZoom(press(duration: 0.49)))
    }

    func testAModifierClickIsNeverAZoom() {
        // ⌘, ⌥, ⇧ and ⌃ over an image mean other things everywhere else in this
        // application. None of them mean zoom, and all of them did.
        XCTAssertFalse(ViewportClick.togglesZoom(press(modifier: true)))
        XCTAssertTrue(ViewportClick.togglesZoom(press(modifier: false)))
    }

    func testADragIsADragAndNotAClick() {
        XCTAssertFalse(ViewportClick.togglesZoom(press(travel: 4)))
        XCTAssertFalse(ViewportClick.togglesZoom(press(travel: 200)))
        XCTAssertTrue(ViewportClick.togglesZoom(press(travel: 3)))
    }

    func testEveryConditionIsRequiredAndNotMerelyPreferred() {
        // Each of the four alone is enough to refuse. Written out because a rule made
        // of four `guard`s is exactly the shape that survives one of them being deleted
        // without anything noticing.
        XCTAssertFalse(ViewportClick.togglesZoom(press(travel: 99)))
        XCTAssertFalse(ViewportClick.togglesZoom(press(duration: 99)))
        XCTAssertFalse(ViewportClick.togglesZoom(press(onImage: false)))
        XCTAssertFalse(ViewportClick.togglesZoom(press(modifier: true)))
        XCTAssertTrue(ViewportClick.togglesZoom(press()))
    }

    func testANonFinitePressIsRefusedRatherThanCompared() {
        // Every comparison against NaN is false, so a threshold written the other way
        // round admits it. A gesture that produced one must not zoom.
        XCTAssertFalse(ViewportClick.togglesZoom(press(travel: .nan)))
        XCTAssertFalse(ViewportClick.togglesZoom(press(duration: .nan)))
        XCTAssertFalse(ViewportClick.togglesZoom(press(travel: .infinity)))
    }

    func testTheToleranceIsTheOneTheViewerAlreadyUsed() {
        // Three points was not the bug and is not changed here; what it was missing was
        // everything else.
        XCTAssertEqual(ViewportClick.travelTolerance, 3)
    }
}

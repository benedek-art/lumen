// ShortcutParityTests.swift
// The Lightroom-habit keys: the J overlay's classification and toggle, what ⌘= / ⌘−
// mean per surface, Tab / ⇧Tab's hide-and-restore, and the `I` overlay's notation.
// The last test reads Sources/LumenApp as text, the way `KeyGrammarTests` does, so the
// rules here cannot be tested while nothing calls them.

import XCTest
@testable import LumenCore

final class ShortcutParityTests: XCTestCase {

    // MARK: J

    func testBothEndsPaintsRedForBlownAndBlueForCrushed() {
        let mode = ClippingOverlay.Mode.bothEnds
        XCTAssertEqual(ClippingOverlay.classify(RGB(gray: 1), mode: mode),
                       ClippingOverlay.bothEndsHighColour)
        XCTAssertEqual(ClippingOverlay.classify(RGB(gray: 0), mode: mode),
                       ClippingOverlay.bothEndsLowColour)
        XCTAssertNil(ClippingOverlay.classify(RGB(gray: 0.5), mode: mode))
    }

    func testBothEndsIgnoresSingleChannelClipping() {
        // A saturated jersey: R at the ceiling, B at the floor. Neither end is gone.
        XCTAssertNil(ClippingOverlay.classify(RGB(1, 0.4, 0), mode: .bothEnds))
        XCTAssertEqual(ClippingOverlay.bothEndsMask(RGB(1, 0.4, 0)), 0)
    }

    func testTheSingleEndedModesAreUnchanged() {
        // The triangles' channel-diagnostic modes never produce the J-only mask.
        XCTAssertEqual(ClippingOverlay.classify(RGB(gray: 1), mode: .whites), RGB.one)
        XCTAssertEqual(ClippingOverlay.classify(RGB(gray: 0), mode: .blacks), RGB.zero)
        XCTAssertEqual(ClippingOverlay.classify(RGB(1, 0.5, 0.5), mode: .whites), RGB(1, 0, 0))
        for mode in ClippingOverlay.Mode.allCases where mode != .bothEnds {
            XCTAssertLessThan(ClippingOverlay.mask(RGB(gray: 0), mode: mode),
                              ClippingOverlay.bothEndsLowMask)
            XCTAssertLessThan(ClippingOverlay.mask(RGB(gray: 1), mode: mode),
                              ClippingOverlay.bothEndsLowMask)
        }
    }

    func testJTogglesBothEndsAndAlwaysTurnsAnOverlayOff() {
        XCTAssertEqual(ClippingOverlay.toggledByJ(nil), .bothEnds)
        XCTAssertNil(ClippingOverlay.toggledByJ(.bothEnds))
        XCTAssertNil(ClippingOverlay.toggledByJ(.whites), "a locked triangle is turned off")
        XCTAssertEqual(ClippingOverlay.Mode.bothEnds.rawValue.uppercased(), "BOTH ENDS")
    }

    // MARK: ⌘= / ⌘−

    func testZoomChordsPerSurface() {
        XCTAssertEqual(ZoomChord.resolve(zoomIn: true, surface: .loupe), .loupeZoomIn)
        XCTAssertEqual(ZoomChord.resolve(zoomIn: false, surface: .loupe), .loupeZoomOut)
        XCTAssertEqual(ZoomChord.resolve(zoomIn: true, surface: .grid),
                       .stepThumbnails(delta: InspectionHolds.thumbnailStep))
        XCTAssertEqual(ZoomChord.resolve(zoomIn: false, surface: .grid),
                       .stepThumbnails(delta: -InspectionHolds.thumbnailStep))
        XCTAssertEqual(ZoomChord.resolve(zoomIn: true, surface: .compare), .unavailable)
        XCTAssertEqual(ZoomChord.resolve(zoomIn: false, surface: .survey), .unavailable)
    }

    // MARK: Tab / ⇧Tab

    func testTabHidesBothSidePanelsAndRestoresWhatWasShowing() {
        var toggle = PanelChromeToggle()
        let start = PanelVisibility(sidebar: false, developColumn: true, filmstrip: true)
        let hidden = toggle.apply(.sidePanels, to: start)
        XCTAssertEqual(hidden, PanelVisibility(sidebar: false, developColumn: false,
                                               filmstrip: true))
        let back = toggle.apply(.sidePanels, to: hidden)
        XCTAssertEqual(back, start, "the sidebar the photographer had closed stays closed")
        XCTAssertNil(toggle.remembered)
    }

    func testTabWithNothingRememberedShowsBoth() {
        var toggle = PanelChromeToggle()
        let bare = PanelVisibility(sidebar: false, developColumn: false, filmstrip: false)
        XCTAssertEqual(toggle.apply(.sidePanels, to: bare),
                       PanelVisibility(sidebar: true, developColumn: true, filmstrip: false))
    }

    func testShiftTabHidesEverythingAndRestoresIt() {
        var toggle = PanelChromeToggle()
        let start = PanelVisibility(sidebar: true, developColumn: false, filmstrip: true)
        let hidden = toggle.apply(.allPanels, to: start)
        XCTAssertEqual(hidden, PanelVisibility(sidebar: false, developColumn: false,
                                               filmstrip: false))
        XCTAssertEqual(toggle.apply(.allPanels, to: hidden), start)
        // And from an all-hidden state nobody remembers, everything comes back.
        var fresh = PanelChromeToggle()
        XCTAssertEqual(fresh.apply(.allPanels, to: hidden), .all)
    }

    func testARestoreNeverRestoresNothing() {
        var toggle = PanelChromeToggle(remembered: PanelVisibility(sidebar: false,
                                                                   developColumn: false,
                                                                   filmstrip: false))
        let bare = PanelVisibility(sidebar: false, developColumn: false, filmstrip: false)
        XCTAssertEqual(toggle.apply(.allPanels, to: bare), .all)
    }

    // MARK: The app calls these

    func testTheAppWiresEveryKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/LumenApp/\(name)"),
                       encoding: .utf8)
        }
        let keymap = try source("Keymap.swift")
        for call in ["ParityKeys.pageChord(", "ParityKeys.panelChord(",
                     "ParityKeys.toggleClippingOverlay(", "ParityKeys.toggleNeutralPick(",
                     "ParityKeys.cycleCaptureInfo(", "state.cancelPick()"] {
            XCTAssertTrue(keymap.contains(call), "Keymap.swift no longer calls \(call)")
        }
        // ⌘← / ⌘→ must be offered before the ⌘ guard returns every chord to the menu.
        let page = try XCTUnwrap(keymap.range(of: "ParityKeys.pageChord("))
        let guardLine = try XCTUnwrap(keymap.range(of: "if flags.contains(.command) { return false }"))
        XCTAssertLessThan(page.lowerBound, guardLine.lowerBound)

        let menu = try source("LumenApp.swift")
        XCTAssertTrue(menu.contains("ParityKeys.zoomChord(zoomIn: true"))
        XCTAssertTrue(menu.contains("ParityKeys.zoomChord(zoomIn: false"))
        XCTAssertTrue(try source("ContentView.swift").contains("!state.developColumnHidden"))
        XCTAssertTrue(try source("LoupeView.swift").contains("CaptureInfoOverlay(photo: photo)"))
    }
}

final class CaptureInfoFormatTests: XCTestCase {

    func testShutterNotation() {
        XCTAssertEqual(CaptureInfoFormat.shutter(1.0 / 2000), "1/2000 s")
        XCTAssertEqual(CaptureInfoFormat.shutter(1.0 / 500), "1/500 s")
        XCTAssertEqual(CaptureInfoFormat.shutter(0.25), "1/4 s")
        XCTAssertEqual(CaptureInfoFormat.shutter(0.5), "0.5 s")
        XCTAssertEqual(CaptureInfoFormat.shutter(1.3), "1.3 s")
        XCTAssertEqual(CaptureInfoFormat.shutter(2), "2 s")
        XCTAssertEqual(CaptureInfoFormat.shutter(30), "30 s")
        XCTAssertNil(CaptureInfoFormat.shutter(nil))
        XCTAssertNil(CaptureInfoFormat.shutter(0))
        XCTAssertNil(CaptureInfoFormat.shutter(.nan))
    }

    func testApertureFocalAndISO() {
        XCTAssertEqual(CaptureInfoFormat.aperture(2.8), "f/2.8")
        XCTAssertEqual(CaptureInfoFormat.aperture(8), "f/8")
        XCTAssertEqual(CaptureInfoFormat.aperture(11), "f/11")
        XCTAssertEqual(CaptureInfoFormat.aperture(1.4), "f/1.4")
        XCTAssertEqual(CaptureInfoFormat.focalLength(200), "200 mm")
        XCTAssertEqual(CaptureInfoFormat.focalLength(14.2), "14 mm")
        XCTAssertEqual(CaptureInfoFormat.focalLength(4.3), "4.3 mm")
        XCTAssertEqual(CaptureInfoFormat.iso(6400), "ISO 6400")
        XCTAssertNil(CaptureInfoFormat.iso(0))
    }

    func testCaptureTime() {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 8; c.hour = 4; c.minute = 2; c.second = 7
        XCTAssertEqual(CaptureInfoFormat.captureTime(c), "2026-10-08 04:02:07")
        c.hour = nil
        XCTAssertEqual(CaptureInfoFormat.captureTime(c), "2026-10-08")
        XCTAssertNil(CaptureInfoFormat.captureTime(nil))
    }

    func testTheCycleAndItsLines() {
        XCTAssertEqual(CaptureInfoMode.off.next, .exposure)
        XCTAssertEqual(CaptureInfoMode.exposure.next, .full)
        XCTAssertEqual(CaptureInfoMode.full.next, .off)

        let metadata = PhotoMetadata(camera: "Sony ILCE-7M4", lens: "FE 70-200mm F2.8 GM OSS II",
                                     iso: 3200, shutterSeconds: 1.0 / 2000,
                                     aperture: 2.8, focalMM: 200)
        XCTAssertEqual(CaptureInfoFormat.lines(mode: .off, fileName: "DSC01.ARW",
                                               metadata: metadata), [])
        XCTAssertEqual(CaptureInfoFormat.lines(mode: .exposure, fileName: "DSC01.ARW",
                                               metadata: metadata),
                       ["DSC01.ARW", "1/2000 s · f/2.8 · ISO 3200 · 200 mm"])
        var time = DateComponents()
        time.year = 2026; time.month = 10; time.day = 18
        time.hour = 14; time.minute = 32; time.second = 7
        XCTAssertEqual(CaptureInfoFormat.lines(mode: .full, fileName: "DSC01.ARW",
                                               metadata: metadata, captureTime: time),
                       ["DSC01.ARW", "1/2000 s · f/2.8 · ISO 3200 · 200 mm",
                        "Sony ILCE-7M4 · FE 70-200mm F2.8 GM OSS II", "2026-10-18 14:32:07"])
        XCTAssertEqual(CaptureInfoFormat.lines(mode: .full, fileName: "scan.tif",
                                               metadata: PhotoMetadata()),
                       ["scan.tif", "No exposure data"])
    }
}

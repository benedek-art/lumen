// KG-03: a portrait photograph that already carries a crop never had its orientation
// reconciled. The answer was one flag on AppState, reset on every selection change and
// learned only from a WHOLE-FRAME delivery — which a cropped or straightened recipe
// never produces outside the crop tool. The overlays, the mask conversions and the crop
// arithmetic of every framing write then laid themselves out against the landscape
// sensor while the renderer and export drew the decoded, oriented picture.
//
// These tests state the disagreement as arithmetic on the shared LumenCore rules
// (`CropGeometry.resolve`, which `geometryRects` is built from, and `BatchFraming`),
// and pin that the fix is the identity everywhere the old rule already had an answer.
import XCTest
@testable import LumenCore

final class FrameOrientationMemoryTests: XCTestCase {

    private let rawURL = URL(fileURLWithPath: "/roll/portrait.NEF")
    private let otherURL = URL(fileURLWithPath: "/roll/landscape.NEF")

    /// A RAW reports its sensor readout; the decode applies EXIF 6 and delivers portrait.
    private let sensor = CGSize(width: 6000, height: 4000)
    private let oriented = CGSize(width: 4000, height: 6000)

    private let cropped = Geometry(crop: Crop(x: 0.1, y: 0.15, w: 0.6, h: 0.5), angle: 3)

    /// What the renderer (and export) delivers for `geometry` on the oriented extent —
    /// the same `resolve` `PipelineRenderer.geometryRects` is built from.
    private func delivered(_ geometry: Geometry, frame: CGSize) -> CGSize {
        let r = CropGeometry.resolve(sourceWidth: Double(frame.width),
                                     sourceHeight: Double(frame.height), geometry: geometry)
        return CGSize(width: r.width, height: r.height)
    }

    private func frame(_ size: CGSize) -> BatchFraming.Frame {
        BatchFraming.Frame(width: Double(size.width), height: Double(size.height))!
    }

    // MARK: the defect

    /// The reported case: a cropped portrait visited with the crop tool closed. Every
    /// delivery is cropped and so inadmissible, but the catalog's frame — stored extent
    /// turned by EXIF — describes the whole photograph, and it reconciles the overlay's
    /// frame with the one the renderer uses.
    func testACroppedPortraitIsReconciledWithoutOpeningTheCropTool() throws {
        var memory = FrameOrientation.Memory()
        let catalog = try XCTUnwrap(BatchFraming.catalogFrame(width: 6000, height: 4000,
                                                              exifOrientation: 6))
        let whole = FrameOrientation.deliversWholeFrame(cropped, cropToolLive: false)
        XCTAssertFalse(whole, "a cropped, straightened recipe never delivers the whole frame")

        memory.learn(rawURL, reported: sensor,
                     delivered: delivered(cropped, frame: oriented), wholeFrame: whole)
        memory.learn(rawURL, reported: sensor, catalog: catalog)

        let overlayFrame = memory.sourceSize(for: rawURL, reported: sensor)
        XCTAssertEqual(overlayFrame, oriented)

        // Overlay and render agree on every rectangle of the crop…
        let overlay = CropGeometry.resolve(sourceWidth: Double(overlayFrame.width),
                                           sourceHeight: Double(overlayFrame.height),
                                           geometry: cropped)
        let render = CropGeometry.resolve(sourceWidth: Double(oriented.width),
                                          sourceHeight: Double(oriented.height),
                                          geometry: cropped)
        XCTAssertEqual(overlay, render)

        // …and a framing write on the primary lands what the same write lands on a
        // non-primary target (which has always used the catalog frame) and what the
        // render's frame says: the straighten keeps the crop's pixel shape.
        let primary = BatchFraming.apply(.angle(7), to: cropped, frame: frame(overlayFrame))
        let secondary = BatchFraming.apply(.angle(7), to: cropped, frame: catalog)
        let truth = BatchFraming.apply(.angle(7), to: cropped, frame: frame(oriented))
        XCTAssertEqual(primary, truth)
        XCTAssertEqual(secondary, truth)
        for edit in [BatchFraming.Edit.aspect(4.0 / 5.0), .swapOrientation] {
            XCTAssertEqual(BatchFraming.apply(edit, to: cropped, frame: frame(overlayFrame)),
                           BatchFraming.apply(edit, to: cropped, frame: frame(oriented)),
                           "\(edit)")
        }
    }

    /// The answer is a fact about the photograph: leaving it and coming back must not
    /// throw it away (the old flag was reset on every selection change, so a portrait
    /// learned in the crop tool was forgotten the moment the photographer moved on).
    func testAnAnswerSurvivesVisitingAnotherPhotograph() {
        var memory = FrameOrientation.Memory()
        let open = FrameOrientation.deliversWholeFrame(cropped, cropToolLive: true)
        XCTAssertTrue(open, "the crop tool renders the whole frame by construction")
        memory.learn(rawURL, reported: sensor, delivered: CGSize(width: 1707, height: 2560),
                     wholeFrame: open)
        memory.learn(otherURL, reported: sensor, delivered: CGSize(width: 2560, height: 1707),
                     wholeFrame: true)
        XCTAssertEqual(memory.transposed(for: rawURL), true)
        XCTAssertEqual(memory.transposed(for: otherURL), false)
        XCTAssertEqual(memory.sourceSize(for: rawURL, reported: sensor), oriented)
    }

    /// A cropped delivery is never evidence: it can neither set an answer nor clear
    /// one, whichever way its crop happens to be shaped.
    func testACroppedDeliveryNeverSetsOrClearsAnAnswer() {
        var memory = FrameOrientation.Memory()
        XCTAssertFalse(memory.learn(rawURL, reported: sensor,
                                    delivered: CGSize(width: 1000, height: 3000),
                                    wholeFrame: false))
        XCTAssertNil(memory.transposed(for: rawURL))

        memory.learn(rawURL, reported: sensor, delivered: oriented, wholeFrame: true)
        for strip in [CGSize(width: 3000, height: 1000), CGSize(width: 1000, height: 3000)] {
            XCTAssertFalse(memory.learn(rawURL, reported: sensor, delivered: strip,
                                        wholeFrame: false))
            XCTAssertEqual(memory.transposed(for: rawURL), true)
        }
    }

    /// The screen outranks the catalog: a stale or wrong row cannot overrule a
    /// whole-frame delivery, while a delivery does overrule the row.
    func testAWholeFrameDeliveryOutranksTheCatalog() throws {
        var memory = FrameOrientation.Memory()
        let staleRow = try XCTUnwrap(BatchFraming.catalogFrame(width: 6000, height: 4000,
                                                               exifOrientation: 1))
        memory.learn(rawURL, reported: sensor, catalog: staleRow)
        XCTAssertEqual(memory.transposed(for: rawURL), false)
        XCTAssertTrue(memory.learn(rawURL, reported: sensor, delivered: oriented,
                                   wholeFrame: true))
        XCTAssertFalse(memory.learn(rawURL, reported: sensor, catalog: staleRow))
        XCTAssertEqual(memory.transposed(for: rawURL), true)
    }

    // MARK: identity where the old rule already answered

    /// The old rule, transcribed: a fresh flag per visit, set only by a whole-frame
    /// delivery, no catalog evidence.
    private func oldFrame(reported: CGSize, deliveredWhole: CGSize?,
                          geometry: Geometry, cropToolLive: Bool) -> CGSize {
        var flag = false
        if FrameOrientation.deliversWholeFrame(geometry, cropToolLive: cropToolLive),
           let whole = deliveredWhole {
            flag = FrameOrientation.isTransposed(reported: reported, delivered: whole)
        }
        return FrameOrientation.sourceSize(reported: reported, transposed: flag)
    }

    /// Sweep sensor shapes × EXIF orientations × source kinds × geometries × crop tool.
    /// Every uncropped case, and every landscape case cropped or not, must resolve to
    /// exactly the frame the old rule produced, so overlays, the crop arithmetic and the
    /// rectangles built from them are byte-identical there. The ONLY cases allowed to
    /// move are cropped transposed exposures, and they must move onto the truth.
    func testUncroppedAndLandscapeCasesAreByteIdentical() throws {
        let sensors = [CGSize(width: 6000, height: 4000), CGSize(width: 5184, height: 3888),
                       CGSize(width: 8256, height: 5504), CGSize(width: 3000, height: 3000)]
        let geometries = [Geometry(), Geometry(crop: Crop(x: 0.2, y: 0, w: 0.5, h: 1)),
                          Geometry(angle: -4.5), cropped, Geometry(flipH: true)]
        var identical = 0, moved = 0, croppedPortraits = 0
        for sensor in sensors {
            for exif in [1, 3, 6, 8] {
                let turns = (5...8).contains(exif)
                let truth = turns ? FrameOrientation.transposed(sensor) : sensor
                // A RAW reports the sensor readout; a rendered file is decoded with its
                // orientation applied and reports the oriented extent.
                for reported in [sensor, truth] {
                    for geometry in geometries {
                        for live in [false, true] {
                            let whole = FrameOrientation.deliversWholeFrame(geometry,
                                                                            cropToolLive: live)
                            let catalog = try XCTUnwrap(BatchFraming.catalogFrame(
                                width: Int(sensor.width), height: Int(sensor.height),
                                exifOrientation: exif))
                            var memory = FrameOrientation.Memory()
                            memory.learn(rawURL, reported: reported,
                                         delivered: whole ? truth : delivered(geometry, frame: truth),
                                         wholeFrame: whole)
                            memory.learn(rawURL, reported: reported, catalog: catalog)
                            let new = memory.sourceSize(for: rawURL, reported: reported)
                            let old = oldFrame(reported: reported, deliveredWhole: truth,
                                               geometry: geometry, cropToolLive: live)

                            // The new answer is always the truth (a square sensor is the
                            // same frame either way round).
                            if sensor.width != sensor.height {
                                XCTAssertEqual(new, truth, "\(sensor) exif \(exif) \(reported)")
                            }
                            if whole || reported == truth {
                                XCTAssertEqual(new, old, "\(sensor) exif \(exif) \(geometry)")
                                let a = CropGeometry.resolve(sourceWidth: Double(new.width),
                                    sourceHeight: Double(new.height), geometry: geometry)
                                let b = CropGeometry.resolve(sourceWidth: Double(old.width),
                                    sourceHeight: Double(old.height), geometry: geometry)
                                XCTAssertEqual(a, b)
                                identical += 1
                            } else {
                                croppedPortraits += 1
                                if new != old { moved += 1 }
                            }
                        }
                    }
                }
            }
        }
        // Not vacuous: the sweep visited both kinds, and every case the old rule got
        // wrong is one that moved.
        XCTAssertGreaterThan(identical, 100)
        XCTAssertGreaterThan(croppedPortraits, 0)
        XCTAssertEqual(moved, croppedPortraits)
    }

    // MARK: the app wiring (LumenApp compiles only on macOS; pinned as text)

    /// AppState keeps the answer per photograph and reads it back on a selection
    /// change instead of resetting it, and learns from the catalog's frame.
    func testAppStateRemembersAndConsultsTheCatalog() throws {
        let code = try ShellSource.code("Sources/LumenApp/AppState.swift")
        let didSet = try XCTUnwrap(ShellSource.body(
            after: "@Published var primarySelection: PhotoItem?", in: code))
        XCTAssertFalse(ShellSource.squashed(didSet).contains("primaryFrameTransposed = false"),
                       "a selection change must not throw the photograph's answer away")
        XCTAssertTrue(ShellSource.squashed(didSet)
            .contains("frameOrientations.transposed(for: $0.id)"))
        let refresh = try XCTUnwrap(ShellSource.body(
            after: "private func refreshPrimaryFrameSize()", in: code))
        XCTAssertTrue(refresh.contains("catalog.frames(photoIDs:"))
        XCTAssertTrue(ShellSource.squashed(refresh)
            .contains("frameOrientations.learn(url, reported: reported, catalog: frame)"))
        XCTAssertTrue(code.contains("FrameOrientation.Memory()"))
    }

    /// The loupe offers EVERY delivery to the memory and lets LumenCore's rule decide
    /// admissibility, rather than deciding it in the view.
    func testTheLoupeHandsDeliveriesToTheSharedRule() throws {
        let code = try ShellSource.code("Sources/LumenApp/LoupeView.swift")
        let learn = try XCTUnwrap(ShellSource.body(
            after: "private func learnSourceOrientation(", in: code))
        XCTAssertTrue(ShellSource.squashed(learn).contains("state.noteFrameDelivered(url,"))
        XCTAssertFalse(learn.contains("guard uncropped"))
        let whole = try XCTUnwrap(ShellSource.body(
            after: "private var deliveringWholeFrame: Bool", in: code))
        XCTAssertTrue(whole.contains("FrameOrientation.deliversWholeFrame("))
    }
}

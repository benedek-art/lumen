// ExposureMatchTests.swift
// Match Total Exposures: the stop arithmetic from shutter, aperture and ISO, the
// slider values it produces against a reference, and what it does with frames that
// record too little to be matched.

import XCTest
@testable import LumenCore

final class ExposureMatchTests: XCTestCase {

    private func capture(_ t: Double?, _ n: Double?, _ iso: Int?) -> ExposureMatch.Capture {
        ExposureMatch.Capture(shutterSeconds: t, aperture: n, iso: iso)
    }

    private func frame(_ id: String, _ t: Double?, _ n: Double?, _ iso: Int?,
                       exposure: Double = 0) -> ExposureMatch.Frame<String> {
        ExposureMatch.Frame(id: id, capture: capture(t, n, iso), exposure: exposure)
    }

    func testCapturedStopsFollowTheExposureTriangle() throws {
        // 1 s, f/1, ISO 100 is the zero point.
        XCTAssertEqual(try XCTUnwrap(ExposureMatch.capturedStops(capture(1, 1, 100))),
                       0, accuracy: 1e-12)
        // Doubling the shutter, doubling ISO, or opening one full stop (×√2 smaller N)
        // each adds one stop.
        let base = try XCTUnwrap(ExposureMatch.capturedStops(capture(1.0 / 500, 4, 100)))
        let slower = try XCTUnwrap(ExposureMatch.capturedStops(capture(1.0 / 250, 4, 100)))
        let higherISO = try XCTUnwrap(ExposureMatch.capturedStops(capture(1.0 / 500, 4, 200)))
        let wider = try XCTUnwrap(ExposureMatch.capturedStops(
            capture(1.0 / 500, 4 / 2.0.squareRoot(), 100)))
        XCTAssertEqual(slower - base, 1, accuracy: 1e-9)
        XCTAssertEqual(higherISO - base, 1, accuracy: 1e-9)
        XCTAssertEqual(wider - base, 1, accuracy: 1e-9)
    }

    func testMissingOrZeroSettingsAreNotACapture() {
        XCTAssertNil(ExposureMatch.capturedStops(capture(nil, 2.8, 100)))
        XCTAssertNil(ExposureMatch.capturedStops(capture(1.0 / 100, nil, 100)))
        XCTAssertNil(ExposureMatch.capturedStops(capture(1.0 / 100, 2.8, nil)))
        // EXIF's "unknown" is often a zero, and an adapted lens reports FNumber 0.
        XCTAssertNil(ExposureMatch.capturedStops(capture(1.0 / 100, 0, 100)))
        XCTAssertNil(ExposureMatch.capturedStops(capture(0, 2.8, 100)))
        XCTAssertNil(ExposureMatch.capturedStops(capture(1.0 / 100, 2.8, 0)))
        XCTAssertNil(ExposureMatch.capturedStops(capture(.nan, 2.8, 100)))
    }

    func testCaptureReadsPhotoMetadata() {
        let metadata = PhotoMetadata(iso: 6400, shutterSeconds: 20, aperture: 2.8)
        XCTAssertEqual(ExposureMatch.Capture(metadata: metadata), capture(20, 2.8, 6400))
    }

    /// A soccer burst in shutter priority with auto ISO: the camera moved ISO between
    /// frames, and matching undoes exactly that move.
    func testAutoISOBurstIsMatchedToThePrimary() {
        let frames = [
            frame("ref", 1.0 / 2000, 2.8, 800, exposure: 0.3),
            frame("brighter", 1.0 / 2000, 2.8, 1600),       // one stop more ISO
            frame("darker", 1.0 / 2000, 2.8, 400),          // one stop less
            frame("faster", 1.0 / 4000, 2.8, 800, exposure: 2),  // slider ignored
        ]
        let plan = ExposureMatch.plan(referenceID: "ref", frames: frames)
        XCTAssertEqual(plan.outcomes?["ref"], .reference)
        XCTAssertEqual(plan.outcomes?["brighter"], .set(exposure: -0.7, clamped: false))
        XCTAssertEqual(plan.outcomes?["darker"], .set(exposure: 1.3, clamped: false))
        XCTAssertEqual(plan.outcomes?["faster"], .set(exposure: 1.3, clamped: false))
        XCTAssertEqual(plan.matchedCount, 3)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertNil(plan.exposures["ref"], "the reference's own slider is never written")
    }

    func testApertureChangeCountsTwoStopsPerDoublingOfTheFNumber() {
        let frames = [frame("ref", 1.0 / 250, 4, 100), frame("f8", 1.0 / 250, 8, 100)]
        let plan = ExposureMatch.plan(referenceID: "ref", frames: frames)
        XCTAssertEqual(plan.outcomes?["f8"], .set(exposure: 2, clamped: false))
    }

    /// Astro: long exposures traded against ISO cancel; a shorter sub gets the
    /// difference back; a manual lens with no aperture on either frame still matches.
    func testAstroLongExposures() {
        let frames = [
            frame("ref", 30, 2.8, 3200),
            frame("equivalent", 15, 2.8, 6400),
            frame("short", 10, 2.8, 3200),
            frame("trail", 240, 2.8, 400),     // 8× time, 1/8 ISO: equivalent
        ]
        let plan = ExposureMatch.plan(referenceID: "ref", frames: frames)
        XCTAssertEqual(plan.outcomes?["equivalent"], .set(exposure: 0, clamped: false))
        XCTAssertEqual(plan.outcomes?["short"], .set(exposure: 1.58, clamped: false))
        XCTAssertEqual(plan.outcomes?["trail"], .set(exposure: 0, clamped: false))

        let manual = [frame("ref", 20, nil, 6400), frame("sub", 10, nil, 6400),
                      frame("autoLens", 10, 1.8, 6400)]
        let manualPlan = ExposureMatch.plan(referenceID: "ref", frames: manual)
        XCTAssertEqual(manualPlan.outcomes?["sub"], .set(exposure: 1, clamped: false))
        // Aperture on one side only: different glass, distance unknown.
        XCTAssertEqual(manualPlan.outcomes?["autoLens"], .skipped)
    }

    func testFramesWithoutMetadataAreSkippedAndLeftAlone() {
        let frames = [frame("ref", 1.0 / 100, 5.6, 100),
                      frame("scan", nil, nil, nil, exposure: 0.5),
                      frame("noISO", 1.0 / 100, 5.6, nil),
                      frame("ok", 1.0 / 200, 5.6, 100)]
        let plan = ExposureMatch.plan(referenceID: "ref", frames: frames)
        XCTAssertEqual(plan.outcomes?["scan"], .skipped)
        XCTAssertEqual(plan.outcomes?["noISO"], .skipped)
        XCTAssertEqual(plan.exposures, ["ok": 1])
        XCTAssertEqual(plan.skippedCount, 2)
        XCTAssertEqual(ExposureMatch.summary(plan, referenceName: "A.ARW"),
                       "Matched 1 photo to A.ARW — 2 skipped (no shutter, aperture or ISO)")
    }

    func testAReferenceWithoutMetadataMatchesNothing() {
        let frames = [frame("ref", nil, 2.8, 100), frame("other", 1.0 / 100, 2.8, 100)]
        let plan = ExposureMatch.plan(referenceID: "ref", frames: frames)
        XCTAssertNil(plan.outcomes)
        XCTAssertTrue(plan.exposures.isEmpty)
        XCTAssertTrue(ExposureMatch.summary(plan, referenceName: "R.ARW")
            .hasPrefix("R.ARW has no shutter speed or ISO recorded"))
        // And a reference id that is not among the frames is the same answer.
        XCTAssertNil(ExposureMatch.plan(referenceID: "missing", frames: frames).outcomes)
    }

    func testResultsClampToTheSliderAndSaySo() {
        let frames = [frame("ref", 1.0 / 4000, 2.8, 100, exposure: 1),
                      frame("night", 30, 2.8, 100)]        // ~16.9 stops brighter
        let plan = ExposureMatch.plan(referenceID: "ref", frames: frames)
        XCTAssertEqual(plan.outcomes?["night"], .set(exposure: -5, clamped: true))
        XCTAssertEqual(plan.clampedCount, 1)
        XCTAssertEqual(ExposureMatch.summary(plan, referenceName: "R"),
                       "Matched 1 photo to R — 1 at the slider's limit")
    }

    func testRoundingLandsOnTheSlidersHundredths() {
        // 1/320 vs 1/250 is a third of a stop in name and log2(320/250) in fact.
        let frames = [frame("ref", 1.0 / 250, 4, 100), frame("third", 1.0 / 320, 4, 100)]
        let plan = ExposureMatch.plan(referenceID: "ref", frames: frames)
        XCTAssertEqual(plan.outcomes?["third"], .set(exposure: 0.36, clamped: false))
    }

    func testNothingMatchableSaysSo() {
        let frames = [frame("ref", 1.0 / 100, 2.8, 100), frame("bare", nil, nil, nil)]
        let plan = ExposureMatch.plan(referenceID: "ref", frames: frames)
        XCTAssertEqual(ExposureMatch.summary(plan, referenceName: "R"),
                       "No frame could be matched — none records shutter, aperture and ISO")
    }
}

// MARK: - WS-10: measured on the shared view

final class ExposureMatchMeasuredTests: XCTestCase {

    /// A deterministic scene texture in EV, sampled on a normalized field position.
    private func scene(_ x: Double, _ y: Double) -> Double {
        -1.5 + 1.2 * sin(9 * x + 2 * y) + 0.8 * cos(13 * y - 3 * x) + 0.6 * sin(31 * x * y)
    }

    private func grid(cols: Int, rows: Int, field: (x0: Double, y0: Double, w: Double),
                      offset: Double = 0) -> ExposureMatch.LumaGrid {
        let h = field.w * Double(rows) / Double(cols)
        var ev: [Double?] = []
        for y in 0..<rows {
            for x in 0..<cols {
                let fx = field.x0 + field.w * (Double(x) + 0.5) / Double(cols)
                let fy = field.y0 + h * (Double(y) + 0.5) / Double(rows)
                ev.append(scene(fx, fy) + offset)
            }
        }
        return ExposureMatch.LumaGrid(columns: cols, rows: rows, ev: ev)
    }

    /// The 6929/6933 shape: the frame is a 1.5x crop of the reference, re-aimed off
    /// centre, and 0.39 EV brighter. Whole-frame averages see composition; the overlap
    /// sees exposure.
    func testOverlapMeasuresACroppedReaimedFrame() throws {
        let reference = grid(cols: 64, rows: 43, field: (0, 0, 1))
        let frame = grid(cols: 64, rows: 43, field: (0.27, 0.2, 1 / 1.5), offset: 0.39)
        let o = try XCTUnwrap(ExposureMatch.measureOverlap(reference: reference, frame: frame))
        XCTAssertEqual(o.stopsBrighter, 0.39, accuracy: 0.05)
        XCTAssertGreaterThan(o.correlation, 0.9)
        // And the other way round: the reference is the narrower view.
        let back = try XCTUnwrap(ExposureMatch.measureOverlap(reference: frame, frame: reference))
        XCTAssertEqual(back.stopsBrighter, -0.39, accuracy: 0.05)
    }

    func testFramesThatShareNoViewAreNotMeasured() {
        let reference = grid(cols: 64, rows: 43, field: (0, 0, 1))
        let other = ExposureMatch.LumaGrid(columns: 64, rows: 43, ev: (0..<(64 * 43)).map {
            Double(($0 * 7919) % 97) / 20 - 2.4     // unrelated texture
        })
        XCTAssertNil(ExposureMatch.measureOverlap(reference: reference, frame: other))
    }

    /// Two different scenes with the same composition — bright above, dark below, the
    /// shape of nearly every outdoor frame — must not match. Level correlation scored
    /// unrelated corpus frames up to 0.87 on exactly this; gradients do not.
    func testSameCompositionDifferentSceneIsNotMeasured() {
        func outdoor(_ seed: Double) -> ExposureMatch.LumaGrid {
            var ev: [Double?] = []
            for y in 0..<43 {
                for x in 0..<64 {
                    let sky = y < 18 ? 1.5 : -2.0
                    ev.append(sky + 0.5 * sin(Double(x) * (0.9 + seed) + Double(y) * seed * 3)
                              * cos(Double(y) * (1.7 - seed)))
                }
            }
            return ExposureMatch.LumaGrid(columns: 64, rows: 43, ev: ev)
        }
        XCTAssertNil(ExposureMatch.measureOverlap(reference: outdoor(0.1), frame: outdoor(0.45)))
    }

    /// A pan at the same focal length: the frame shifted by a fifth of its width.
    func testOverlapMeasuresAPanAtTheSameFocalLength() throws {
        let reference = grid(cols: 64, rows: 43, field: (0, 0, 1))
        let frame = grid(cols: 64, rows: 43, field: (0.2, 0.05, 1), offset: -0.5)
        let o = try XCTUnwrap(ExposureMatch.measureOverlap(reference: reference, frame: frame))
        XCTAssertEqual(o.stopsBrighter, -0.5, accuracy: 0.05)
    }

    func testAMeasuredFrameIsMatchedOnItsMeasurementNotItsEXIF() {
        // 6929 (1/50, f/5.6, ISO 250) against 6933 (1/80, f/5.6, ISO 640): EXIF says
        // +0.68 EV, the shared view says +0.36.
        let ref = ExposureMatch.Frame(id: "6929", capture: .init(shutterSeconds: 1.0 / 50,
                                      aperture: 5.6, iso: 250), exposure: 0)
        let exifOnly = ExposureMatch.Frame(id: "6933", capture: .init(
            shutterSeconds: 1.0 / 80, aperture: 5.6, iso: 640), exposure: 0)
        var measured = exifOnly
        measured.measuredStopsBrighter = 0.36
        XCTAssertEqual(ExposureMatch.plan(referenceID: "6929", frames: [ref, exifOnly])
            .exposures["6933"], -0.68)
        let plan = ExposureMatch.plan(referenceID: "6929", frames: [ref, measured])
        XCTAssertEqual(plan.exposures["6933"], -0.36)
        XCTAssertEqual(plan.measuredCount, 1)
        XCTAssertEqual(ExposureMatch.summary(plan, referenceName: "6929.ARW"),
                       "Matched 1 photo to 6929.ARW by measured brightness")
    }

    func testAReferenceWithoutEXIFStillMatchesMeasuredFrames() {
        let ref = ExposureMatch.Frame(id: "scan", capture: .init(), exposure: 0.5)
        let other = ExposureMatch.Frame(id: "b", capture: .init(), exposure: 0,
                                        measuredStopsBrighter: -1)
        XCTAssertEqual(ExposureMatch.plan(referenceID: "scan", frames: [ref, other])
            .exposures["b"], 1.5)
    }
}

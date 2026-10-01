// BatchFramingTests.swift
// S-11 / KG-01: with more than one photograph selected, the crop, angle, ratio and
// orientation writes were computed from the PRIMARY's frame and stamped on every target.

import XCTest
@testable import LumenCore

// File scope rather than instance properties: the KG-01 selection, shared by every case.
private let landscape = BatchFraming.Frame(width: 3000, height: 2000)!
private let portrait = BatchFraming.Frame(width: 2000, height: 3000)!
private let crop = Crop(x: 0.1, y: 0.1, w: 0.8, h: 0.8)

final class BatchFramingTests: XCTestCase {

    private func pixelAspect(_ g: Geometry, _ f: BatchFraming.Frame) -> Double {
        CropGeometry.displayedAspect(g.crop, sourceWidth: f.width, sourceHeight: f.height,
                                     degrees: g.angle) ?? .nan
    }

    // MARK: The reproducer — what the old writers did

    /// KG-01's measured case, reproduced with the arithmetic the writers called: the
    /// primary is a 3000 × 2000 landscape, the second frame a 2000 × 3000 portrait, both
    /// cropped (0.1, 0.1, 0.8, 0.8), and the primary is straightened 0° → 5°. The old
    /// writers ran `reangled` with the PRIMARY's frame for both and stamped the result.
    func testThePrimarysFrameStampedOnAPortraitBreaksItsAspect() {
        let before = pixelAspect(Geometry(crop: crop), portrait)
        XCTAssertEqual(before, 2.0 / 3.0, accuracy: 1e-9)
        let stamped = CropGeometry.reangled(crop, sourceWidth: landscape.width,
                                            sourceHeight: landscape.height, from: 0, to: 5)
        let after = pixelAspect(Geometry(crop: stamped, angle: 5), portrait)
        // The audit measured 0.5675:1 — a 15 % error on a photograph nobody touched.
        XCTAssertEqual(after, 0.5675, accuracy: 0.0005)
    }

    // MARK: The repair — every target against its own frame

    /// The same selection through `BatchFraming`: each frame keeps ITS OWN pixel aspect
    /// through the angle change, to 1e-9. Hand both targets the primary's frame (the old
    /// writers' behaviour) and the portrait assertion reads 0.5675 against 0.6667.
    func testAnAngleChangeKeepsEveryTargetsOwnPixelAspect() throws {
        let targets: [(BatchFraming.Frame, String)] = [(landscape, "landscape primary"),
                                                       (portrait, "portrait second")]
        for (frame, name) in targets {
            let start = Geometry(crop: crop)
            let before = pixelAspect(start, frame)
            for angle in [-12.0, -5, 0.5, 5, 17, 44] {
                let next = try XCTUnwrap(BatchFraming.apply(.angle(angle), to: start,
                                                            frame: frame))
                XCTAssertEqual(next.angle, angle)
                XCTAssertEqual(pixelAspect(next, frame), before, accuracy: 1e-9,
                               "\(name) at \(angle)°")
            }
        }
    }

    /// A ratio picked over a mixed selection lands as THAT ratio in pixels on every
    /// frame — the old writers refit each target against the primary's frame, so on a
    /// portrait a "3:2" came out 2:3-squashed into something else.
    func testARatioLandsAsThatRatioOnEveryFrame() throws {
        for frame in [landscape, portrait, BatchFraming.Frame(width: 4000, height: 3000)!] {
            for angle in [0.0, 7.5] {
                let start = Geometry(crop: crop, angle: angle)
                for ratio in [1.0, 3.0 / 2, 16.0 / 9, 4.0 / 5] {
                    let next = try XCTUnwrap(BatchFraming.apply(.aspect(ratio), to: start,
                                                                frame: frame))
                    XCTAssertEqual(pixelAspect(next, frame), ratio, accuracy: 1e-9,
                                   "\(frame) at \(angle)° wanted \(ratio)")
                    XCTAssertEqual(next.angle, angle, "a ratio does not turn the picture")
                }
            }
        }
    }

    /// The orientation swap is the reciprocal pixel ratio on each frame's own terms.
    func testTheOrientationSwapIsTheReciprocalOnEveryFrame() throws {
        for frame in [landscape, portrait] {
            let start = Geometry(crop: Crop(x: 0.25, y: 0.3, w: 0.4, h: 0.3), angle: 3)
            let before = pixelAspect(start, frame)
            let next = try XCTUnwrap(BatchFraming.apply(.swapOrientation, to: start,
                                                        frame: frame))
            XCTAssertEqual(pixelAspect(next, frame), 1 / before, accuracy: 1e-9)
        }
    }

    // MARK: When a target cannot be computed, it is left alone

    func testAnUnknownFrameLeavesTheTargetUntouched() {
        let start = Geometry(crop: crop, angle: 2)
        XCTAssertNil(BatchFraming.apply(.angle(5), to: start, frame: nil))
        XCTAssertNil(BatchFraming.apply(.aspect(1.5), to: start, frame: nil))
        XCTAssertNil(BatchFraming.apply(.swapOrientation, to: start, frame: nil))
    }

    /// M12 per target: a ratio one frame can hold and another cannot is written on the
    /// first and declined on the second, rather than floored into some other shape.
    func testARatioOneTargetCannotHoldIsDeclinedForThatTargetOnly() {
        let start = Geometry(crop: crop)
        let wide = BatchFraming.Frame(width: 12000, height: 2000)!   // holds 120:1 … 0.3
        XCTAssertNotNil(BatchFraming.apply(.aspect(40), to: start, frame: wide))
        XCTAssertNil(BatchFraming.apply(.aspect(40), to: start, frame: landscape),
                     "40:1 on a 3:2 frame bottoms out at 30:1")
    }

    // MARK: Every writer goes through it (source contracts; the app is macOS-only)

    private static func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/\(name).swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// No framing arithmetic is called directly from the two files that write it: the
    /// angle slider, the ratio menu, the custom ratio, the orientation swap, the rotate
    /// drag and the ruler all reach `BatchFraming.apply` with the TARGET's frame. Put
    /// any one writer back on `CropGeometry.reangled`/`refit`/`swappingOrientation` with
    /// the primary's size and this goes red.
    func testEveryFramingWriterComputesAgainstTheTargetsOwnFrame() throws {
        let panel = try Self.appSource("CropPanel")
        let loupe = try Self.appSource("LoupeView")
        for (name, text) in [("CropPanel", panel), ("LoupeView", loupe)] {
            for call in ["CropGeometry.reangled(", "CropGeometry.refit(",
                         "CropGeometry.swappingOrientation(", "CropGeometry.centred("] {
                XCTAssertFalse(text.contains(call),
                               "\(name) calls \(call) directly — a fan-out write with one "
                               + "frame for every target")
            }
        }
        XCTAssertTrue(panel.contains("let frame = state.framingFrame(for: photo,"),
                      "the panel's framing write does not resolve the frame per target")
        XCTAssertTrue(panel.contains("BatchFraming.apply(edit, to: recipe.develop.geometry,"))
        for edit in ["applyFraming(.aspect(ratio)", "applyFraming(.swapOrientation",
                     "CropSection.applyFraming(.angle(angle), key: \"geometry.angle\""] {
            XCTAssertTrue(panel.contains(edit), "CropPanel lost \(edit)")
        }
        XCTAssertTrue(loupe.contains("CropSection.applyFraming(.angle(angle), key: \"straighten\""),
                      "the rotate drag and the ruler no longer go through the per-target rule")
        // The hand-dragged rectangle is drawn on one picture and writes that one.
        XCTAssertTrue(loupe.contains("state.updateRecipe(coalescingKey: \"crop\", targets: [photo])"),
                      "the crop drag fans out over the selection again")
    }

    /// The resolver: the primary keeps the decoded frame it always used, and every OTHER
    /// target answers with its own catalog frame or nothing — never a fallback borrowed
    /// from the primary.
    func testTheFrameResolverNeverHandsATargetThePrimarysFrame() throws {
        let state = try Self.appSource("AppState")
        let start = try XCTUnwrap(state.range(of: "func framingFrame(for photo: PhotoItem,"))
        let body = String(state[start.upperBound...].prefix(900))
        XCTAssertTrue(body.contains("if photo.id == primarySelection?.id {"))
        XCTAssertTrue(body.contains("return selectionFrames[photo.id] ?? primaryFallback"))
        let tail = try XCTUnwrap(body.range(of: "return selectionFrames[photo.id] ?? primaryFallback"))
        XCTAssertTrue(body[tail.upperBound...].contains("return selectionFrames[photo.id]\n"),
                      "a non-primary target is resolved with something other than its own frame")
    }

    // MARK: Frames from the catalog

    func testCatalogFramesTurnForTheFourTransposingOrientations() {
        for orientation in [nil, 1, 2, 3, 4] {
            XCTAssertEqual(BatchFraming.catalogFrame(width: 6000, height: 4000,
                                              exifOrientation: orientation),
                           BatchFraming.Frame(width: 6000, height: 4000))
        }
        for orientation in [5, 6, 7, 8] {
            XCTAssertEqual(BatchFraming.catalogFrame(width: 6000, height: 4000,
                                              exifOrientation: orientation),
                           BatchFraming.Frame(width: 4000, height: 6000))
        }
        XCTAssertNil(BatchFraming.catalogFrame(width: nil, height: 4000, exifOrientation: 1))
        XCTAssertNil(BatchFraming.catalogFrame(width: 0, height: 4000, exifOrientation: 1))
    }
}

// CropRatioLimitTests.swift
// M12: a typed crop ratio the frame cannot hold was accepted, padlocked, and written as
// a different ratio.
//
// The parser's bounds (1:60 … 60:1) are a typo guard. The geometry has its own, tighter
// limit — no crop thinner than `minimumCropFraction` of the usable frame on either axis —
// and nothing reconciled the two. On a 6000 × 4000 frame `60:1` wrote 30:1 and `1:60`
// wrote 0.075:1, with the padlock still reading the typed ratio. The repair gates every
// ratio write on `CropGeometry.canHold`, and the frame-aware parser on the same rule.

import XCTest
@testable import LumenCore

final class CropRatioLimitTests: XCTestCase {

    /// The audit's own reproducer: the two extreme entries on a 6000 × 4000 frame.
    func testTheAuditsExtremeEntriesAreDeclinedOnASixThousandByFourThousandFrame() {
        for text in ["60:1", "1:60", "60", "1/60"] {
            XCTAssertNotNil(CropGeometry.aspect(fromText: text),
                            "\(text) is inside the typo guard; the frame is what refuses it")
            XCTAssertNil(CropGeometry.aspect(fromText: text, sourceWidth: 6000,
                                             sourceHeight: 4000, degrees: 0),
                         "\(text) was accepted on a frame that cannot hold it")
        }
        // The bounds the frame does have, stated as numbers.
        let range = try? XCTUnwrap(CropGeometry.achievableAspects(
            sourceWidth: 6000, sourceHeight: 4000, degrees: 0))
        XCTAssertEqual(range?.upperBound ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(range?.lowerBound ?? 0, 0.075, accuracy: 1e-12)
    }

    /// The property, swept: every ratio the frame-aware gate accepts is the ratio the
    /// rectangle then holds, to 1e-6 — across frames of both orientations, angles that
    /// change the usable frame's shape, and ratios from the typo guard's floor to its
    /// ceiling. Substitute a gate that accepts everything the plain parser does and the
    /// extreme ratios land on the floor's ratio instead, which is M12 exactly.
    func testEveryAcceptedRatioIsTheRatioTheRectangleHolds() {
        let frames: [(Double, Double)] = [(6000, 4000), (4000, 6000), (6000, 6000),
                                          (12000, 2000), (3000, 2000)]
        let angles: [Double] = [0, 2.5, -7, 15, 44]
        var accepted = 0, refused = 0
        var failures: [String] = []
        for (w, h) in frames {
            for angle in angles {
                for step in 0...80 {
                    // Log-spaced over 1/60 … 60.
                    let ratio = exp(log(1.0 / 60) + Double(step) / 80 * 2 * log(60.0))
                    let text = String(format: "%.6f", ratio)
                    guard let parsed = CropGeometry.aspect(fromText: text, sourceWidth: w,
                                                           sourceHeight: h,
                                                           degrees: angle) else {
                        refused += 1
                        continue
                    }
                    accepted += 1
                    for start in [Crop(), Crop(x: 0.3, y: 0.2, w: 0.2, h: 0.4)] {
                        let crop = CropGeometry.refit(start, aspect: parsed, sourceWidth: w,
                                                      sourceHeight: h, degrees: angle)
                        guard let held = CropGeometry.displayedAspect(
                            crop, sourceWidth: w, sourceHeight: h, degrees: angle) else {
                            failures.append("\(w)×\(h) @\(angle)° \(text): no aspect")
                            continue
                        }
                        if abs(held / parsed - 1) > 1e-6 {
                            failures.append("\(Int(w))×\(Int(h)) @\(angle)° typed \(text) "
                                            + "holds \(held)")
                        }
                        let centred = CropGeometry.centred(aspect: parsed, sourceWidth: w,
                                                           sourceHeight: h, degrees: angle)
                        let centredHeld = CropGeometry.displayedAspect(
                            centred, sourceWidth: w, sourceHeight: h, degrees: angle) ?? 0
                        if abs(centredHeld / parsed - 1) > 1e-6 {
                            failures.append("centred \(Int(w))×\(Int(h)) @\(angle)° "
                                            + "typed \(text) holds \(centredHeld)")
                        }
                    }
                }
            }
        }
        // Both halves have to be exercised or the sweep proves nothing.
        XCTAssertGreaterThan(accepted, 1000)
        XCTAssertGreaterThan(refused, 50)
        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) accepted ratios did not hold:\n"
                      + failures.prefix(12).joined(separator: "\n"))
    }

    /// Every preset the menu offers is holdable on an ordinary frame, so the gate is
    /// identity for every ratio a photographer can pick rather than type.
    func testTheGateRefusesNoPresetOnAnOrdinaryFrame() {
        let presets: [Double] = [1, 5.0 / 4, 4.0 / 3, 3.0 / 2, 7.0 / 5, 16.0 / 9, 16.0 / 10]
        for (w, h) in [(6000.0, 4000.0), (4000.0, 6000.0), (4000.0, 3000.0)] {
            for angle in [0.0, 10, -45] {
                for ratio in presets + presets.map({ 1 / $0 }) {
                    XCTAssertTrue(CropGeometry.canHold(aspect: ratio, sourceWidth: w,
                                                       sourceHeight: h, degrees: angle),
                                  "\(ratio) refused on \(w)×\(h) at \(angle)°")
                }
            }
        }
    }

    /// The panel half, which is macOS-only, as a source contract that runs on Linux:
    /// the custom field may not read the frame-blind parser any more, and the one
    /// function every ratio write goes through refuses what `canHold` refuses.
    func testTheCropPanelGatesEveryRatioWriteOnTheFrame() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/CropPanel.swift")
        let panel = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(panel.contains("CropGeometry.aspect(fromText: customRatio)"),
                       "the custom field reads the parser that does not know the frame")
        XCTAssertTrue(panel.contains("CropGeometry.aspect(fromText: customRatio, sourceWidth:"),
                      "the custom field does not ask the frame")
        let apply = try XCTUnwrap(panel.range(of: "private func applyAspect("))
        let body = panel[apply.upperBound...].prefix(900)
        XCTAssertTrue(body.contains("guard canHold(ratio) else { return }"),
                      "applyAspect writes ratios the frame cannot hold")
    }

    func testDegenerateFramesHoldNothing() {
        XCTAssertNil(CropGeometry.achievableAspects(sourceWidth: 0, sourceHeight: 4000,
                                                    degrees: 0))
        XCTAssertFalse(CropGeometry.canHold(aspect: 1.5, sourceWidth: .nan,
                                            sourceHeight: 4000, degrees: 0))
        XCTAssertFalse(CropGeometry.canHold(aspect: .infinity, sourceWidth: 6000,
                                            sourceHeight: 4000, degrees: 0))
    }
}

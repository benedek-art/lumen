// DecodeDragTests.swift
// Draft sizing while a gesture moves a control the RAW decoder reads: full size until
// a decode-paying frame is measured over budget, then one step down and no further,
// and never for any other gesture or for a request made at rest.

import Foundation
import XCTest
@testable import LumenCore

final class DecodeDragTests: XCTestCase {

    private func inputs(_ strength: Double, lens: Bool = true) -> DecodeInputs {
        DecodeInputs(captureStrength: strength, luminanceNR: 0, colorNR: 0,
                     lensProfile: lens, decoderVersion: nil)
    }

    // MARK: Which recipe fields are decode inputs

    func testTheThreeDecoderControlsMoveTheInputsAndNothingElseDoes() {
        let base = Recipe()
        var exposure = base
        exposure.develop.tone.exposure += 1
        XCTAssertEqual(exposure.decodeInputs, base.decodeInputs)

        var sharpening = base
        sharpening.develop.detail.capture.auto = true
        sharpening.develop.detail.capture.amount = 40
        var stronger = sharpening
        stronger.develop.detail.capture.amount = 41
        XCTAssertNotEqual(sharpening.decodeInputs, stronger.decodeInputs)

        var ai = base
        ai.develop.denoise.mode = .ai
        ai.develop.denoise.amount = 30
        var more = ai
        more.develop.denoise.amount = 31
        XCTAssertNotEqual(ai.decodeInputs, more.decodeInputs)

        var classic = base
        classic.develop.denoise.mode = .classic
        classic.develop.denoise.amount = 30
        var classicMore = classic
        classicMore.develop.denoise.amount = 90
        XCTAssertEqual(classic.decodeInputs, classicMore.decodeInputs,
                       "Classic runs in the graph; its amount is not the decoder's")

        var lens = base
        lens.develop.geometry.lens.profile.toggle()
        XCTAssertNotEqual(lens.decodeInputs, base.decodeInputs)
    }

    /// The decoder keys its cache on these same inputs, so "this gesture moved a decode
    /// input" and "this frame will pay a decode" cannot come to mean different things.
    func testTheDecoderKeysItsCacheOnTheSameInputs() throws {
        let code = try ShellSource.code("Sources/LumenPipeline/AppleRawSource.swift")
        let key = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "private struct DecodeKey: Equatable", in: code)))
        let fields = key.components(separatedBy: "let ").dropFirst()
            .compactMap { $0.split(separator: ":").first.map(String.init) }
        XCTAssertEqual(fields, ["draft", "scaleFactor", "captureStrength", "luminanceNR",
                                "colorNR", "lensProfile", "decoderVersion"],
                       "a new decode-key field needs a place in DecodeInputs")
        let decode = ShellSource.squashed(try XCTUnwrap(
            ShellSource.body(after: "public func decode(recipe: Recipe", in: code)))
        XCTAssertTrue(decode.contains("let inputs = recipe.decodeInputs"))
        for field in ["captureStrength: inputs.captureStrength",
                      "luminanceNR: inputs.luminanceNR", "colorNR: inputs.colorNR",
                      "lensProfile: inputs.lensProfile"] {
            XCTAssertTrue(decode.contains(field), field)
        }
    }

    // MARK: Sizing

    func testAGestureThatMovesNoDecodeInputIsNeverReduced() {
        var drag = DecodeDrag()
        for _ in 0..<50 {
            XCTAssertEqual(drag.longEdge(for: 3328, inputs: inputs(1), midGesture: true), 3328)
            drag.record(milliseconds: 400, paidDecode: true, divisor: 1)
        }
        XCTAssertFalse(drag.isReducing)
        XCTAssertEqual(drag.divisor, 1)
    }

    func testADecodeDragKeepsItsFullSizeWhileTheDecodeIsAffordable() {
        var drag = DecodeDrag()
        _ = drag.longEdge(for: 3328, inputs: inputs(1.00), midGesture: false)
        for step in 1...40 {
            let edge = drag.longEdge(for: 3328, inputs: inputs(1 + Double(step) / 100),
                                     midGesture: true)
            XCTAssertEqual(edge, 3328)
            drag.record(milliseconds: DecodeDrag.budgetMilliseconds - 1, paidDecode: true,
                        divisor: drag.divisor)
        }
        XCTAssertFalse(drag.isReducing)
    }

    func testOneMeasuredSlowDecodeFrameDropsOneStepAndNoFurther() {
        var drag = DecodeDrag()
        _ = drag.longEdge(for: 3328, inputs: inputs(1.00), midGesture: false)
        XCTAssertEqual(drag.longEdge(for: 3328, inputs: inputs(1.01), midGesture: true), 3328)
        drag.record(milliseconds: 180, paidDecode: true, divisor: 1)
        XCTAssertTrue(drag.isReducing)
        for step in 2...30 {
            let edge = drag.longEdge(for: 3328, inputs: inputs(1 + Double(step) / 100),
                                     midGesture: true)
            XCTAssertEqual(edge, 1664)
            // Still slow at half size: there is no second step.
            drag.record(milliseconds: 180, paidDecode: true, divisor: drag.divisor)
        }
        XCTAssertEqual(drag.divisor, DecodeDrag.maxDivisor)
        // A pause on a value: same inputs, still this gesture, still the same size.
        XCTAssertEqual(drag.longEdge(for: 3328, inputs: inputs(1.30), midGesture: true), 1664)
    }

    func testAReducedDraftNeverGoesBelowTheFloorOrAboveItsAsk() {
        XCTAssertEqual(DecodeDrag.reduced(1536, by: 2), DecodeDrag.floorLongEdge)
        XCTAssertEqual(DecodeDrag.reduced(900, by: 2), 900)
        XCTAssertEqual(DecodeDrag.reduced(7008, by: 2), 3504)
        XCTAssertEqual(DecodeDrag.reduced(3328, by: 1), 3328)
    }

    func testCacheHitsAndFramesAtAnotherSizeTeachNothing() {
        var drag = DecodeDrag()
        _ = drag.longEdge(for: 3328, inputs: inputs(1.00), midGesture: false)
        _ = drag.longEdge(for: 3328, inputs: inputs(1.01), midGesture: true)
        drag.record(milliseconds: 500, paidDecode: false, divisor: 1)
        XCTAssertEqual(drag.divisor, 1, "a slow frame that paid no decode is not this lever's")
        drag.record(milliseconds: 500, paidDecode: true, divisor: 1)
        XCTAssertEqual(drag.divisor, 2)
        // A full-size frame that was already in flight lands late: not evidence about 2.
        drag.record(milliseconds: 500, paidDecode: true, divisor: 1)
        XCTAssertEqual(drag.divisor, 2)
    }

    func testARequestAtRestIsFullSizeAndTheLearnedStepWaitsForTheNextDecodeDrag() {
        var drag = DecodeDrag()
        _ = drag.longEdge(for: 3328, inputs: inputs(1.00), midGesture: false)
        _ = drag.longEdge(for: 3328, inputs: inputs(1.01), midGesture: true)
        drag.record(milliseconds: 180, paidDecode: true, divisor: 1)
        XCTAssertEqual(drag.longEdge(for: 3328, inputs: inputs(1.02), midGesture: true), 1664)
        drag.gestureEnded()
        // The release, and a discrete edit: never reduced.
        XCTAssertEqual(drag.longEdge(for: 3328, inputs: inputs(1.02), midGesture: false), 3328)
        XCTAssertEqual(drag.longEdge(for: 3328, inputs: inputs(1.05), midGesture: false), 3328)
        // An exposure drag afterwards: decode inputs still, full size.
        XCTAssertEqual(drag.longEdge(for: 3328, inputs: inputs(1.05), midGesture: true), 3328)
        drag.gestureEnded()
        // The next sharpening drag starts where the measurement left it.
        _ = drag.longEdge(for: 3328, inputs: inputs(1.05), midGesture: false)
        XCTAssertEqual(drag.longEdge(for: 3328, inputs: inputs(1.06), midGesture: true), 1664)
    }

    func testTheFullSizeIsEarnedBackBetweenGesturesOnly() {
        var drag = DecodeDrag()
        _ = drag.longEdge(for: 3328, inputs: inputs(1.00), midGesture: false)
        _ = drag.longEdge(for: 3328, inputs: inputs(1.01), midGesture: true)
        drag.record(milliseconds: 180, paidDecode: true, divisor: 1)
        // Reduced frames so cheap that four times their cost still fits.
        let cheap = DecodeDrag.budgetMilliseconds / 4 - 1
        _ = drag.longEdge(for: 3328, inputs: inputs(1.02), midGesture: true)
        drag.record(milliseconds: cheap, paidDecode: true, divisor: 2)
        XCTAssertEqual(drag.longEdge(for: 3328, inputs: inputs(1.03), midGesture: true), 1664,
                       "no change of sharpness under a moving hand")
        drag.gestureEnded()
        _ = drag.longEdge(for: 3328, inputs: inputs(1.03), midGesture: false)
        XCTAssertEqual(drag.longEdge(for: 3328, inputs: inputs(1.04), midGesture: true), 3328)

        // Not earned when the reduced frames only just fit.
        var tight = DecodeDrag()
        _ = tight.longEdge(for: 3328, inputs: inputs(1.00), midGesture: false)
        _ = tight.longEdge(for: 3328, inputs: inputs(1.01), midGesture: true)
        tight.record(milliseconds: 180, paidDecode: true, divisor: 1)
        tight.record(milliseconds: DecodeDrag.budgetMilliseconds - 1, paidDecode: true,
                     divisor: 2)
        tight.gestureEnded()
        XCTAssertEqual(tight.divisor, 2)
    }

    func testANewPhotographStartsOver() {
        var drag = DecodeDrag()
        _ = drag.longEdge(for: 3328, inputs: inputs(1.00), midGesture: false)
        _ = drag.longEdge(for: 3328, inputs: inputs(1.01), midGesture: true)
        drag.record(milliseconds: 180, paidDecode: true, divisor: 1)
        drag.reset()
        XCTAssertEqual(drag, DecodeDrag())
        XCTAssertEqual(drag.longEdge(for: 3328, inputs: inputs(1.5), midGesture: true), 3328)
    }

    func testADecodeTimeUnderTheHitCeilingIsAHit() {
        XCTAssertFalse(DecodeDrag.paidDecode(decodeMilliseconds: 0.2))
        XCTAssertFalse(DecodeDrag.paidDecode(decodeMilliseconds: .nan))
        XCTAssertTrue(DecodeDrag.paidDecode(decodeMilliseconds: 12))
    }
}

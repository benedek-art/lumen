// CurveStageWiringTests.swift
//
// WS-01, carrying out WS-12b N1: the tone curve runs as its own stage after the finish
// table (`RenderPlan.curveStage`, applied in `finishedColor` and by the GPU's
// `applyCurveStage`), instead of being baked into the 33³/65³ cube where its lattice
// put a steep curve 33 codes and a dip 101 codes away from the curve drawn. These hold
// the wiring: what is in the table and what is not, the proof exception, and the
// rendered curve against the exact one.

import XCTest
@testable import LumenCore

final class CurveStageWiringTests: XCTestCase {

    private func recipe(_ curve: CurveSet) -> Recipe {
        var r = Recipe()
        r.develop.curve = curve
        return r
    }

    private var steep: CurveSet {
        var c = CurveSet()
        c.point = [[0, 0], [0.4, 0.1], [0.6, 0.9], [1, 1]]
        return c
    }

    private var dip: CurveSet {
        var c = CurveSet()
        c.point = [[0, 0], [0.3, 0.8], [0.35, 0.2], [1, 1]]
        return c
    }

    private let proof = SoftProof(enabled: true, space: .srgb, intent: .perceptual,
                                  showGamutWarning: true, simulatePaperWhite: true)

    func testTheCurveIsAStageAndNotInTheFinishTable() {
        let flat = RenderPlan(recipe: recipe(CurveSet()))
        let curved = RenderPlan(recipe: recipe(steep))
        XCTAssertNil(flat.curveStage, "an identity curve runs no stage")
        XCTAssertNotNil(curved.curveStage)
        XCTAssertFalse(curved.curveIsInFinishTable)
        // The point of the move: a curve drag leaves the 33³ table bit-identical.
        XCTAssertEqual(flat.finishLUT, curved.finishLUT,
                       "the curve is still being baked into the finish table")
    }

    func testASoftProofKeepsTheCurveInTheTableSoItProofsTheCurvedPicture() {
        let flat = RenderPlan(recipe: recipe(CurveSet()), softProof: proof)
        let curved = RenderPlan(recipe: recipe(steep), softProof: proof)
        XCTAssertTrue(curved.curveIsInFinishTable)
        XCTAssertNil(curved.curveStage, "with a proof on the curve must not run twice")
        XCTAssertNotEqual(flat.finishLUT, curved.finishLUT,
                          "with a proof on, the proofed table has to carry the curve")
    }

    /// The defect N1 names, measured through the reference's own composition: a grey
    /// ramp through `referenceColor` (tables as rendered) against `exactColor` (every
    /// stage exact). The curve inside the cube put the steep curve 33 codes and the dip
    /// 101 codes off at the interactive size; out of it, what is left is the display
    /// transform's own table error, the same for every curve.
    func testTheRenderedCurveIsTheDrawnCurveAtThePreviewTableSize() {
        func worstCodes(_ curve: CurveSet) -> Double {
            let plan = RenderPlan(recipe: recipe(curve))
            var worst = 0.0
            for i in 0...400 {
                let scene = RGB(gray: 0.18 * pow(2, -8 + 12 * Double(i) / 400))
                let enc = { (c: RGB) in c.map { TransferFunction.srgb.encode(Num.saturate($0)) } }
                let d = enc(plan.referenceColor(scene)) - enc(plan.exactColor(scene))
                worst = Swift.max(worst, Swift.max(abs(d.r), Swift.max(abs(d.g), abs(d.b))))
            }
            return worst * 255
        }
        let baseline = worstCodes(CurveSet())
        for (name, curve) in [("steep", steep), ("dip", dip)] {
            let off = worstCodes(curve)
            // A steep curve multiplies the table's own error by its slope (4× here, and
            // up to 12× across the dip's fall), so the bound is the identity's error
            // times the curve's slope plus a code — not the 33 and 101 codes of the cube.
            XCTAssertLessThan(off, baseline * 12 + 1,
                              "\(name): rendered curve \(off) codes off the drawn one")
        }
    }

    func testTheMemoHandsBackTheSameStageAndNilForTheIdentity() {
        XCTAssertNil(CurveStageMemo.stage(for: CurveSet()))
        let a = CurveStageMemo.stage(for: steep)
        let b = CurveStageMemo.stage(for: steep)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.master, b?.master)
        XCTAssertEqual(a?.master, CurveStage(CurveStack(steep)).master,
                       "the memo must hand back exactly the stage the set builds")
    }

    /// The GPU table image and its uniforms describe the stage they came from.
    func testTheKernelAtlasCarriesEveryRowInOrder() {
        var set = steep
        set.r = [[0, 0], [0.5, 0.6], [1, 1]]
        let stage = CurveStage(CurveStack(set))
        let n = stage.atlasWidth
        let atlas = stage.atlasRGBA
        XCTAssertEqual(atlas.count, n * CurveStage.rows * 4)
        let rows: [[Float]?] = [stage.master, stage.luma] + stage.channels
        for (k, row) in rows.enumerated() {
            for i in stride(from: 0, to: n, by: 997) {
                let want = row?[i] ?? Float(Double(i) / Double(n - 1))
                XCTAssertEqual(atlas[(k * n + i) * 4], want, "row \(k) sample \(i)")
            }
        }
        let u = stage.kernelUniforms(white: 1, space: .rec2020)
        XCTAssertEqual(u.on[0], stage.master == nil ? 0 : 1)
        XCTAssertEqual(u.ch, [1, 0, 0])
        XCTAssertEqual(u.p[1], 1, "SDR top is 1")
    }
}

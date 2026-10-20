// ProofAdaptationTests.swift
// The soft proof has to adapt white the way the exported file is adapted.
//
// ProPhoto is the one export space whose white is D50; every other one shares the
// working space's D65, so for them a proof is a pure primaries change and none of this
// matters. For ProPhoto the white has to move, and there are two defensible ways to
// move it:
//
//   · CAT16 — what Lumen uses for white balance (docs/04, D9), where matching human
//     adaptation is the point;
//   · Bradford — what the ICC profile connection space uses (ICC.1:2010 Annex E), and
//     therefore what ColorSync does when `PipelineRenderer.write` hands Core Image
//     `CGColorSpace(name: .rommrgb)` and lets it convert the Rec.2020 render.
//
// The proof is a promise about the FILE (docs/11: "what is on screen is the export, not
// an approximation"), so it has to use the second. It used the first: the proof
// matrices came from `RGBColorSpace.matrix(to:)`, which always adapted with CAT16, while
// the comment beside `ChromaticAdaptation.bradford` said it was "kept for ICC-compatible
// profile conversions on export" and nothing called it. The two matrices differ by up
// to 0.022 in a coefficient, and on a 41³ sweep of the Rec.2020 cube the CAT16 proof
// flagged 0.32% of colours — saturated deep reds and oranges — as unstorable in a
// ProPhoto file that in fact stores them.

import XCTest
@testable import LumenCore

final class ProofAdaptationTests: XCTestCase {

    private static let proPhotoProof = SoftProof(enabled: true, space: .proPhoto,
                                                 intent: .relativeColorimetric)

    /// What ColorSync computes: Rec.2020 to XYZ, Bradford from D65 to D50 in the PCS,
    /// then out through the ProPhoto (ROMM) profile, which is natively D50.
    private static let iccRec2020ToProPhoto: Mat3 =
        RGBColorSpace.proPhoto.fromXYZ
        * ChromaticAdaptation.bradford(from: WhitePoint.d65, to: WhitePoint.d50)
        * RGBColorSpace.rec2020.toXYZ

    func testTheBradfordAdaptationIsTheICCChromaticAdaptationTag() {
        // The `chad` tag every D65 matrix/TRC ICC profile carries (sRGB, Display P3),
        // quoted to four decimals. The xy D50 here and the PCS's 0.9642/1/0.8249 differ
        // in the fourth decimal, which is why this is 2e-4 and not tighter.
        let chad = Mat3(1.0479, 0.0229, -0.0502,
                        0.0296, 0.9904, -0.0171,
                        -0.0092, 0.0151, 0.7519)
        let bradford = ChromaticAdaptation.bradford(from: WhitePoint.d65, to: WhitePoint.d50)
        XCTAssertLessThan(bradford.maxAbsDifference(chad), 2e-4)
    }

    func testTheProPhotoProofConvertsTheWayColorSyncWritesTheFile() {
        let proof = SoftProofTransform(Self.proPhotoProof)
        XCTAssertLessThan(proof.workingToProof.maxAbsDifference(Self.iccRec2020ToProPhoto), 1e-12,
                          "workingToProof = \(proof.workingToProof.m)")
        XCTAssertEqual(proof.workingToProof.m[0][0], 0.83521, accuracy: 1e-4,
                       "Rec.2020 red's ProPhoto red — CAT16 puts it at 0.81351")
        // The way back has to be the exact inverse, or the colorimetric proof would
        // move every in-gamut colour it hands back to the working space.
        let round = proof.proofToWorking * proof.workingToProof
        XCTAssertLessThan(round.maxAbsDifference(.identity), 1e-12)
    }

    func testADeepRedTheProPhotoFileHoldsIsNotFlagged() {
        // CAT16 sends this to ProPhoto (0.16419, 0.03155, -0.00027) — past the 1e-4
        // epsilon — while the file ColorSync writes holds (0.16826, 0.03403, 0.00044).
        let red = RGB(0.2, 0.025, 0)
        XCTAssertFalse(SoftProof.isOutOfGamut(red, working: .rec2020, proof: .proPhoto))
        XCTAssertFalse(SoftProofTransform(Self.proPhotoProof).isOutOfGamut(red))
        // And it still reaches the file untouched, so the proof is not clipping it.
        let mapped = SoftProofTransform(Self.proPhotoProof).mapped(red)
        XCTAssertLessThan(mapped.maxAbsDifference(red), 1e-12)
    }

    func testThePerceptualProofMeasuresHueInTheSameOKLabAsTheWorkingSpace() {
        // The perceptual intent compresses chroma along constant OKLab hue in the
        // proof's own context. That context has to adapt D50 back to D65 with the same
        // transform the proof used to get to D50, or the two adaptations do not cancel
        // and a colour has a different hue in the proof than it had on screen before
        // anything was mapped.
        let context = ProofGamut.context(.proPhoto)
        let proof = SoftProofTransform(Self.proPhotoProof)
        for c in [RGB(0.2, 0.025, 0), RGB(0.1, 0.5, 0.2), RGB(0.05, 0.1, 0.6), RGB(0.4, 0.4, 0.4)] {
            let onScreen = OKLabTransform.working.toLab(c)
            let inProof = context.toLab(proof.workingToProof.apply(c))
            XCTAssertEqual(inProof.L, onScreen.L, accuracy: 1e-6, "\(c)")
            XCTAssertEqual(inProof.a, onScreen.a, accuracy: 1e-6, "\(c)")
            XCTAssertEqual(inProof.b, onScreen.b, accuracy: 1e-6, "\(c)")
        }
    }

    func testTheD65ProofsAreUnchanged() {
        // No white to move, so the choice of adaptation cannot reach them.
        for space in [ExportColorSpace.srgb, .displayP3, .adobeRGB, .rec2020] {
            let proof = SoftProofTransform(SoftProof(enabled: true, space: space))
            XCTAssertEqual(proof.workingToProof, RGBColorSpace.rec2020.matrix(to: space.space),
                           "\(space)")
        }
        // And white balance keeps CAT16: the default conversion is untouched.
        let cat16 = RGBColorSpace.proPhoto.fromXYZ
            * ChromaticAdaptation.cat16(from: WhitePoint.d65, to: WhitePoint.d50)
            * RGBColorSpace.rec2020.toXYZ
        XCTAssertLessThan(RGBColorSpace.rec2020.matrix(to: .proPhoto).maxAbsDifference(cat16), 1e-12)
    }
}

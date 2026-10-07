import XCTest
import LumenCore

final class ProofNumericalDiagnosticsTests: XCTestCase {
    func testFingerprintFrontSettingMatchesTheExistingCumulativeIndexContract() {
        let sweep = ProofMetrics.Sweep(stepDeltas: Array(repeating: 1, count: 20),
                                       cumulative: (1...20).map(Double.init))
        XCTAssertEqual(sweep.frontLoading, 0.55)
        XCTAssertEqual(ProofNumericalDiagnostics.frontLoadingFraction(steps: 21),
                       sweep.frontLoading)
    }

    func testOutputULPPerturbationHasTheStatedDirectionAndPreservesAlpha() {
        let baseline = ImageBuffer(width: 1, height: 1, pixels: [0.5, 0.5, 0.5, 0.25])
        let source = ImageBuffer(width: 1, height: 1, pixels: [0.75, 0.25, 0.5, 0.125])
        let result = ProofNumericalDiagnostics.nudgedAway(source, from: baseline)
        XCTAssertEqual(result.pixels, [Float(0.75).nextUp, Float(0.25).nextDown,
                                      Float(0.5).nextUp, 0.125])
        XCTAssertGreaterThan(ProofMetrics.meanSeparation(baseline, result),
                             ProofMetrics.meanSeparation(baseline, source))
    }

    func testPerturbationDoesNotLaunderNonfiniteOutput() {
        let baseline = ImageBuffer(width: 1, height: 1)
        let source = ImageBuffer(width: 1, height: 1, pixels: [.nan, .infinity, -.infinity, 1])
        let result = ProofNumericalDiagnostics.nudgedAway(source, from: baseline)
        XCTAssertTrue(result.pixels[0].isNaN)
        XCTAssertEqual(result.pixels[1], .infinity)
        XCTAssertEqual(result.pixels[2], -.infinity)
        XCTAssertEqual(result.pixels[3], 1)
    }

    func testMaterialRegressionsStayRejectedInEveryAffectedField() throws {
        for id in ["color.protectSkin", "mixer.red.hue", "bw.red"] {
            let committed = try XCTUnwrap(ProofRecordStore.read(id))
            for key in [\ProofRecord.frontLoading, \ProofRecord.meanSeparation] {
                for delta in [-1e-5, 1e-5, -0.01, 0.01] {
                    var changed = committed
                    changed[keyPath: key] += delta
                    XCTAssertFalse(changed.agrees(with: committed), "\(id): \(key), \(delta)")
                }
            }
        }
    }
}

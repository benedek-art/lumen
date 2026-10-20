// RawDenoiseStdMapTests.swift
// The Swift std map must equal train.py `std_map` — the conditioning input the network
// was trained on — including the zero-padded /9 dip at borders and the clamp of negative
// channel means. Goldens are from the REAL torch function via
// Denoise/scripts/gen_swift_fixtures_noise.py; regenerate there, never edit by hand.

import XCTest
@testable import LumenCore

final class RawDenoiseStdMapTests: XCTestCase {

    // a: 4x6x7, K=0.0005291546151965842, r=3.187782079431725e-07
    static let aK: Double = 0.0005291546151965842
    static let aR: Double = 3.187782079431725e-07
    static let aH = 6, aW = 7
    static let aInput: [Float] = [
        -0.019999999552965164, 0.077392578125, 0.767333984375, 0.303955078125, 0.6279296875,
        0.801513671875, 0.0361328125, 0.819580078125, 0.16748046875, 0.64599609375, 0.895751953125,
        0.321044921875, 0.209228515625, 0.4375, 0.46826171875, 0.499755859375, 0.676513671875,
        -0.03999999910593033, 0.455810546875, 0.4931640625, 0.291015625, 0.653564453125,
        0.599853515625, -0.005126953125, -0.03999999910593033, 0.323974609375, 0.318115234375,
        0.28271484375, 0.618896484375, 0.535888671875, 0.821533203125, 0.40478515625, 0.685546875,
        0.661865234375, 0.142578125, 0.4072265625, 0.590087890625, 0.638916015625, 0.549560546875,
        0.75732421875, 0.123291015625, 0.47216796875, -0.019999999552965164, 0.595947265625,
        0.360595703125, 0.229736328125, 0.12548828125, -0.011962890625, 0.002197265625,
        0.818603515625, 0.119384765625, 0.84912109375, 0.768798828125, 0.053466796875,
        0.150146484375, 0.324951171875, 0.3203125, 0.527099609375, 0.059814453125,
        -0.03999999910593033, -0.03857421875, 0.26806640625, 0.8994140625, -0.001708984375,
        0.387939453125, 0.841552734375, -0.03999999910593033, 0.546875, 0.5263671875,
        0.638427734375, 0.59912109375, 0.722900390625, -0.030517578125, 0.865966796875,
        0.380126953125, 0.2119140625, 0.280029296875, 0.811767578125, 0.636474609375, 0.6689453125,
        0.344970703125, 0.025634765625, 0.140625, 0.0009765625, -0.019999999552965164,
        0.2490234375, 0.189208984375, 0.617431640625, 0.185302734375, 0.778076171875,
        0.775146484375, 0.359619140625, 0.337646484375, 0.17724609375, 0.047607421875,
        0.490478515625, 0.41162109375, 0.52001953125, 0.690185546875, 0.3310546875, 0.5849609375,
        -0.03999999910593033, 0.099365234375, 0.316650390625, 0.233642578125, 0.134033203125,
        0.75927734375, 0.2470703125, -0.03999999910593033, 0.795166015625, 0.1484375,
        0.41455078125, 0.772216796875, 0.393310546875, 0.612548828125, 0.055908203125,
        -0.042236328125, 0.56494140625, -0.04541015625, -0.008056640625, -0.031982421875,
        0.265380859375, 0.56103515625, 0.0712890625, 0.80859375, 0.83447265625,
        -0.019999999552965164, 0.197998046875, 0.445556640625, 0.626708984375, 0.221435546875,
        0.3564453125, 0.643310546875, 0.730712890625, 0.445556640625, 0.314208984375,
        0.411376953125, 0.42138671875, 0.8994140625, 0.616943359375, 0.08203125, 0.255126953125,
        0.442626953125, -0.03999999910593033, 0.181884765625, 0.84912109375, -0.048095703125,
        0.41455078125, 0.301513671875, 0.154052734375, -0.03999999910593033, 0.134765625,
        0.663330078125, 0.17822265625, 0.78662109375, 0.0224609375, 0.1748046875, 0.259033203125,
        0.870849609375, 0.032958984375, 0.89794921875, 0.486328125, 0.7685546875, 0.561279296875,
        -0.009033203125, 0.00390625, 0.886474609375, 0.448974609375,
    ]
    static let aExpected: [Float] = [
        0.008521799929440022, 0.011301795020699501, 0.012040349654853344, 0.012195671908557415,
        0.012102035805583, 0.011766308918595314, 0.01012349035590887, 0.010921187698841095,
        0.014153062365949154, 0.013950159773230553, 0.013598846271634102, 0.01360333152115345,
        0.014045016840100288, 0.012289616279304028, 0.012270329520106316, 0.014962581917643547,
        0.013206050731241703, 0.012668627314269543, 0.012821797281503677, 0.01426821481436491,
        0.012162966653704643, 0.012655306607484818, 0.015082260593771935, 0.013014583848416805,
        0.012470925226807594, 0.012747835367918015, 0.014156992547214031, 0.01165507361292839,
        0.0129347899928689, 0.015494321472942829, 0.014185733161866665, 0.013586041517555714,
        0.01365966908633709, 0.014451021328568459, 0.01191240455955267, 0.010933995246887207,
        0.013195721432566643, 0.012366609647870064, 0.011828817427158356, 0.011652147397398949,
        0.011651840060949326, 0.009762578643858433,
    ]
    // b: 4x3x2, K=0.01, r=0.0001
    static let bK: Double = 0.01
    static let bR: Double = 0.0001
    static let bH = 3, bW = 2
    static let bInput: [Float] = [
        -0.0751953125, -0.0244140625, 0.1142578125, 0.3798828125, 0.9892578125, 0.3134765625,
        0.4736328125, -0.0859375, 0.2861328125, 0.1513671875, 0.6259765625, 0.96875, -0.0029296875,
        0.142578125, 0.2314453125, -0.03515625, -0.05078125, 0.0439453125, 0.5810546875, 0.3203125,
        0.7705078125, 0.7646484375, 0.5751953125, 0.3583984375,
    ]
    static let bExpected: [Float] = [
        0.034769825637340546, 0.034769825637340546, 0.04765735939145088, 0.04765735939145088,
        0.04361225664615631, 0.04361225664615631,
    ]
    // c: 4x1x1, K=0.002424997492933292, r=1.0998329844935948e-05
    static let cK: Double = 0.002424997492933292
    static let cR: Double = 1.0998329844935948e-05
    static let cH = 1, cW = 1
    static let cInput: [Float] = [0.5, 0.25, 0.75, 1.0]
    static let cExpected: [Float] = [0.013394063338637352]

    private func check(_ input: [Float], _ h: Int, _ w: Int, _ k: Double, _ r: Double,
                       _ expected: [Float], file: StaticString = #filePath, line: UInt = #line) {
        let out = RawDenoiseStdMap.compute(packed: input, width: w, height: h,
                                           params: RawDenoiseNoiseParams(k: k, readVar: r))
        XCTAssertEqual(out.count, h * w, file: file, line: line)
        XCTAssertEqual(expected.count, h * w, "fixture shape", file: file, line: line)
        for i in 0..<Swift.min(out.count, expected.count) {
            XCTAssertLessThanOrEqual(abs(out[i] - expected[i]), 1e-6 * abs(expected[i]),
                                     "pixel (\(i / w), \(i % w)): \(out[i]) vs \(expected[i])",
                                     file: file, line: line)
        }
    }

    /// 4x6x7 with negative pixels (corner and interior) and real ILCE-7M4 ISO 3200 params.
    func testMatchesPythonWithBordersAndNegatives() {
        check(Self.aInput, Self.aH, Self.aW, Self.aK, Self.aR, Self.aExpected)
    }

    /// 4x3x2 with a large K so the shot term dominates; every pixel is a border pixel.
    func testMatchesPythonOnNarrowImage() {
        check(Self.bInput, Self.bH, Self.bW, Self.bK, Self.bR, Self.bExpected)
    }

    /// 1x1: the window is one real pixel and eight zero pads, so sig = mean / 9.
    func testSinglePixelIsDividedByNine() {
        check(Self.cInput, Self.cH, Self.cW, Self.cK, Self.cR, Self.cExpected)
        let out = RawDenoiseStdMap.compute(packed: Self.cInput, width: 1, height: 1,
                                           params: .init(k: Self.cK, readVar: Self.cR))
        XCTAssertEqual(Double(out[0]), (Self.cK * 0.625 / 9 + Self.cR).squareRoot(), accuracy: 1e-7)
    }

    /// An all-negative signal clamps to zero: the map is sqrt(readVar) everywhere.
    func testNegativeSignalFloorsAtReadNoise() {
        let out = RawDenoiseStdMap.compute(packed: [Float](repeating: -0.01, count: 4 * 5 * 3),
                                           width: 3, height: 5, params: .init(k: 0.5, readVar: 4e-6))
        XCTAssertEqual(out.count, 15)
        for v in out { XCTAssertEqual(v, 2e-3, accuracy: 1e-9) }
    }

    func testEmptyImage() {
        XCTAssertEqual(RawDenoiseStdMap.compute(packed: [], width: 0, height: 0,
                                                params: .init(k: 1, readVar: 1)), [])
    }
}

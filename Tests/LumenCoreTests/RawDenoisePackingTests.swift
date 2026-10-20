// RawDenoisePackingTests.swift
// RawDenoisePacking against the Python it ports. Every literal below was printed by
// Denoise/scripts/gen_swift_fixtures_packing.py, which runs the REAL raw.pack /
// raw.unpack / prepare.to_rggb / prepare.from_rggb (normalization: a verbatim copy of
// raw.load's numpy expression). If one fails, the layout the network was trained on
// and the one Lumen feeds it have diverged — fix the Swift, not the literal.

import XCTest
@testable import LumenCore

final class RawDenoisePackingTests: XCTestCase {

    /// arange(35).reshape(5, 7): odd in BOTH dimensions, so the dropped trailing
    /// row and column are exercised along with the plane order.
    private let width = 7
    private let height = 5
    private var cfa: [Float] { (0..<35).map(Float.init) }

    private let expectedPacked: [CFAPattern: [Float]] = [
        .rggb: [0, 2, 4, 14, 16, 18, 1, 3, 5, 15, 17, 19, 7, 9, 11, 21, 23, 25, 8, 10, 12, 22, 24, 26],
        .bggr: [8, 10, 12, 22, 24, 26, 1, 3, 5, 15, 17, 19, 7, 9, 11, 21, 23, 25, 0, 2, 4, 14, 16, 18],
        .grbg: [1, 3, 5, 15, 17, 19, 0, 2, 4, 14, 16, 18, 8, 10, 12, 22, 24, 26, 7, 9, 11, 21, 23, 25],
        .gbrg: [7, 9, 11, 21, 23, 25, 0, 2, 4, 14, 16, 18, 8, 10, 12, 22, 24, 26, 1, 3, 5, 15, 17, 19],
    ]

    /// Unpacked into a -1 canvas: the last row and column must survive untouched.
    private let expectedUnpackedCanvas: [Float] = [
        0, 1, 2, 3, 4, 5, -1, 7, 8, 9, 10, 11, 12, -1, 14, 15, 16, 17, 18, 19, -1,
        21, 22, 23, 24, 25, 26, -1, -1, -1, -1, -1, -1, -1, -1,
    ]

    func testPackMatchesPythonForEveryPattern() {
        for pattern in CFAPattern.allCases {
            let packed = RawDenoisePacking.pack(cfa: cfa, width: width, height: height, pattern: pattern)
            XCTAssertEqual(packed.width, 3, "\(pattern)")
            XCTAssertEqual(packed.height, 2, "\(pattern)")
            XCTAssertEqual(packed.planes, expectedPacked[pattern], "\(pattern)")
        }
    }

    func testUnpackWritesOnlyEvenCroppedRegionLikePython() {
        for pattern in CFAPattern.allCases {
            var canvas = [Float](repeating: -1, count: width * height)
            RawDenoisePacking.unpack(planes: expectedPacked[pattern]!, width: 3, height: 2,
                                     pattern: pattern, into: &canvas,
                                     cfaWidth: width, cfaHeight: height)
            XCTAssertEqual(canvas, expectedUnpackedCanvas, "\(pattern)")
        }
    }

    func testRoundTripOnEvenAndOddFrames() {
        for (w, h) in [(8, 6), (9, 7), (2, 2), (3, 5)] {
            let src = (0..<(w * h)).map { Float($0) * 0.25 - 3 }
            for pattern in CFAPattern.allCases {
                let p = RawDenoisePacking.pack(cfa: src, width: w, height: h, pattern: pattern)
                var back = src
                // Scramble the even region first so the round trip has to restore it.
                for y in 0..<(h / 2 * 2) { for x in 0..<(w / 2 * 2) { back[y * w + x] = .nan } }
                RawDenoisePacking.unpack(planes: p.planes, width: p.width, height: p.height,
                                         pattern: pattern, into: &back, cfaWidth: w, cfaHeight: h)
                XCTAssertEqual(back, src, "\(w)x\(h) \(pattern)")
                let fresh = RawDenoisePacking.unpack(planes: p.planes, width: p.width,
                                                     height: p.height, pattern: pattern)
                XCTAssertEqual(fresh.count, (w / 2 * 2) * (h / 2 * 2))
            }
        }
    }

    /// The point of to_rggb: whatever the sensor layout, plane 0 is red and plane 3 is
    /// blue. Paint each colour a constant and check the planes come out ordered.
    func testPlanesAreRGGBOrderedRegardlessOfSensorLayout() {
        let colours: [CFAPattern: [Float]] = [  // tile order (0,0),(0,1),(1,0),(1,1); R=1 G=2 B=3
            .rggb: [1, 2, 2, 3], .bggr: [3, 2, 2, 1], .grbg: [2, 1, 3, 2], .gbrg: [2, 3, 1, 2],
        ]
        for (pattern, tile) in colours {
            let src = (0..<(4 * 6)).map { i -> Float in tile[((i / 6) & 1) * 2 + ((i % 6) & 1)] }
            let p = RawDenoisePacking.pack(cfa: src, width: 6, height: 4, pattern: pattern).planes
            let n = 6
            XCTAssertEqual(Array(p[0..<n]), Array(repeating: 1, count: n), "\(pattern) R")
            XCTAssertEqual(Array(p[n..<(3 * n)]), Array(repeating: 2, count: 2 * n), "\(pattern) G")
            XCTAssertEqual(Array(p[(3 * n)...]), Array(repeating: 3, count: n), "\(pattern) B")
        }
    }

    func testPatternParsesPythonSpelling() {
        XCTAssertEqual(CFAPattern(string: "BGGR"), .bggr)
        XCTAssertEqual(CFAPattern(string: "gbrg"), .gbrg)
        XCTAssertNil(CFAPattern(string: "RGBG"))
    }

    // MARK: Normalization

    private let dn: [UInt16] = [0, 16383, 11208, 14699, 9474, 12708, 13657, 3689, 909, 4917,
                                4670, 14311, 14951, 86, 8188]
    private let black: [Float] = [512, 510, 514, 511]
    private let white: Float = 16383

    func testNormalizeMatchesRawLoadBitExactly() {
        let expected: [Float] = [
            -0.032259587198495865, 1.0001102685928345, 0.6739229559898376, 0.8940064311027527,
            0.5646688342094421, 0.7683074474334717, 0.8282901644706726, 0.20004725456237793,
            0.025076789781451225, 0.2774198651313782, 0.26198315620422363, 0.8695597648620605,
            0.9097582101821899, -0.026714971289038658, 0.4836418032646179,
        ]
        let got = RawDenoisePacking.normalize(raw: dn, width: 5, height: 3,
                                              blackPerTile: black, whiteLevel: white)
        XCTAssertEqual(got.map(\.bitPattern), expected.map(\.bitPattern))
    }

    func testDenormalizeMatchesInferRequantization() {
        // normalized + 0.62 DN, with two pixels pushed outside [0, white] to hit the clip.
        let nudged: [Float] = [
            -0.20000000298023224, 1.2999999523162842, 0.6739619970321655, 0.8940454721450806,
            0.56470787525177, 0.7683464884757996, 0.8283292055130005, 0.2000863254070282,
            0.025115855038166046, 0.27745893597602844, 0.2620222270488739, 0.8695988059043884,
            0.9097972512245178, -0.026675906032323837, 0.4836808741092682,
        ]
        let expected: [UInt16] = [0, 16383, 11209, 14700, 9475, 12709, 13658, 3690, 910, 4918,
                                  4671, 14312, 14952, 87, 8189]
        XCTAssertEqual(RawDenoisePacking.denormalize(cfa: nudged, width: 5, height: 3,
                                                     blackPerTile: black, whiteLevel: white),
                       expected)
    }

    func testNormalizeDenormalizeRoundTripsEveryDN() {
        let n = RawDenoisePacking.normalize(raw: dn, width: 5, height: 3,
                                            blackPerTile: black, whiteLevel: white)
        XCTAssertEqual(RawDenoisePacking.denormalize(cfa: n, width: 5, height: 3,
                                                     blackPerTile: black, whiteLevel: white), dn)
    }
}

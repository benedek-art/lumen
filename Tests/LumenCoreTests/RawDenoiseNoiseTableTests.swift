// RawDenoiseNoiseTableTests.swift
// The Swift noise table must hand the raw denoiser the same (K, read variance) the Python
// trained and infers with. Goldens are the REAL train.NoiseTable.params after infer.py's
// ISO clamp, from Denoise/scripts/gen_swift_fixtures_noise.py — regenerate there, never
// edit by hand.

import XCTest
@testable import LumenCore

final class RawDenoiseNoiseTableTests: XCTestCase {

    // (model, iso, k, readVar) from train.NoiseTable.params after infer.py's ISO clamp
    static let golden: [(String, Double, Double, Double)] = [
        ("ILCE-7M4", 50.0, 8.26804086244663e-06, 1.2593963240665394e-07),
        ("ILCE-7M4", 100.0, 1.6536081724893263e-05, 1.2608090608836563e-07),
        ("ILCE-7M4", 3200.0, 0.0005291546151965842, 3.187782079431725e-07),
        ("ILCE-7M4", 51200.0, 0.008466473843145342, 4.9504623232700886e-05),
        ("ILCE-7M4", 75.0, 1.2402061293669937e-05, 1.2602225298560577e-07),
        ("ILCE-7M4", 140.0, 2.3150514414850547e-05, 1.262730851366546e-07),
        ("ILCE-7M4", 2300.0, 0.00038032987967254504, 2.2682894850869225e-07),
        ("ILCE-7M4", 12801.0, 0.0021167838216035874, 3.2125583365283203e-06),
        ("ILCE-7M4", 30000.0, 0.004960824517467978, 1.724318143636887e-05),
        ("ILCE-7M4", 25.0, 8.26804086244663e-06, 1.2593963240665394e-07),
        ("ILCE-7M4", 1.0, 8.26804086244663e-06, 1.2593963240665394e-07),
        ("ILCE-7M4", 102400.0, 0.008466473843145342, 4.9504623232700886e-05),
        ("ILCE-7M4", 204800.0, 0.008466473843145342, 4.9504623232700886e-05),
        ("DMC-GX85", 100.0, 3.789058582708267e-05, 1.0266072505979885e-07),
        ("DMC-GX85", 200.0, 7.578117165416534e-05, 1.1064290023919518e-07),
        ("DMC-GX85", 1600.0, 0.0006062493732333229, 7.811456153084962e-07),
        ("DMC-GX85", 25600.0, 0.00969998997173317, 0.00017447327751897505),
        ("DMC-GX85", 150.0, 5.683587874062397e-05, 1.072572984203371e-07),
        ("DMC-GX85", 333.0, 0.00012617565080418546, 1.2985462797015272e-07),
        ("DMC-GX85", 4500.0, 0.0017050763622187214, 5.51227392899972e-06),
        ("DMC-GX85", 9000.0, 0.0034101527244374463, 2.167655066132292e-05),
        ("DMC-GX85", 20000.0, 0.007578117165416538, 0.00010655521336392117),
        ("DMC-GX85", 50.0, 3.789058582708267e-05, 1.0266072505979885e-07),
        ("DMC-GX85", 80.0, 3.789058582708267e-05, 1.0266072505979885e-07),
        ("DMC-GX85", 51200.0, 0.00969998997173317, 0.00017447327751897505),
    ]
    // isoRange("ILCE-7M4") = 50.0...51200.0
    // isoRange("DMC-GX85") = 100.0...25600.0

    private static var calibURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Denoise/weights/calib.json")
    }

    private func realTable() throws -> RawDenoiseNoiseTable {
        try RawDenoiseNoiseTable(jsonData: Data(contentsOf: Self.calibURL))
    }

    private func assertRel(_ a: Double, _ b: Double, _ msg: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(abs(a - b), 1e-9 * abs(b), "\(msg): \(a) vs \(b)",
                                 file: file, line: line)
    }

    func testParsesRealCalibJSON() throws {
        let t = try realTable()
        XCTAssertEqual(Set(t.cameras.keys), ["ILCE-7M4", "DMC-GX85"])
        XCTAssertEqual(t.cameras["ILCE-7M4"]?.count, 24)
        XCTAssertEqual(t.cameras["DMC-GX85"]?.count, 17)
        XCTAssertEqual(t.isoRange(model: "ILCE-7M4"), 50.0...51200.0)
        XCTAssertEqual(t.isoRange(model: "DMC-GX85"), 100.0...25600.0)
        XCTAssertEqual(t.cameras["ILCE-7M4"]?[1],
                       .init(iso: 100, k: 1.6536081724893253e-05, readVar: 1.260809060883656e-07))
        for rows in t.cameras.values {
            XCTAssertEqual(rows.map(\.iso), rows.map(\.iso).sorted())
        }
    }

    /// Exact points, between points, and clamped below/above range, both cameras.
    func testMatchesPythonGoldens() throws {
        let t = try realTable()
        for (model, iso, k, r) in Self.golden {
            guard let p = t.params(model: model, iso: iso) else {
                XCTFail("\(model) @ \(iso): nil"); continue
            }
            assertRel(p.k, k, "\(model) K @ ISO \(iso)")
            assertRel(p.readVar, r, "\(model) r @ ISO \(iso)")
        }
    }

    func testClampHoldsEndpointValues() throws {
        let t = try realTable()
        for model in ["ILCE-7M4", "DMC-GX85"] {
            let range = try XCTUnwrap(t.isoRange(model: model))
            let lo = t.params(model: model, iso: range.lowerBound)
            let hi = t.params(model: model, iso: range.upperBound)
            XCTAssertEqual(t.params(model: model, iso: range.lowerBound / 4), lo)
            XCTAssertEqual(t.params(model: model, iso: range.upperBound * 4), hi)
            // ISO 0, negative and +inf clamp too (an unclamped log would be -inf/NaN).
            XCTAssertEqual(t.params(model: model, iso: 0), lo)
            XCTAssertEqual(t.params(model: model, iso: -5), lo)
            XCTAssertEqual(t.params(model: model, iso: .infinity), hi)
        }
    }

    func testUnknownModelAndNaNAreNil() throws {
        let t = try realTable()
        XCTAssertNil(t.params(model: "ILCE-7M3", iso: 800))
        XCTAssertNil(t.isoRange(model: "ILCE-7M3"))
        XCTAssertNil(t.params(model: "ILCE-7M4", iso: .nan))
    }

    /// Log-log interpolation: a power law between two points is reproduced exactly, and
    /// rows arrive sorted whatever order the file lists them in.
    func testInterpolatesLogLog() throws {
        let json = #"{"X": [[400, 4e-4, 1e-6], [100, 1e-4, 1e-7]]}"#
        let t = try RawDenoiseNoiseTable(jsonData: Data(json.utf8))
        XCTAssertEqual(t.cameras["X"]?.map(\.iso), [100, 400])
        let p = try XCTUnwrap(t.params(model: "X", iso: 200))
        assertRel(p.k, 2e-4, "K")                             // K ∝ ISO
        assertRel(p.readVar, 1e-7 * 10.0.squareRoot(), "r")   // geometric midpoint
    }

    func testSingleRowTableIsConstant() throws {
        let t = try RawDenoiseNoiseTable(jsonData: Data(#"{"S": [[800, 1e-3, 2e-6]]}"#.utf8))
        for iso in [1.0, 800, 1e6] {
            let p = try XCTUnwrap(t.params(model: "S", iso: iso))
            assertRel(p.k, 1e-3, "K")
            assertRel(p.readVar, 2e-6, "r")
        }
    }

    func testRejectsMalformedTables() {
        typealias E = RawDenoiseNoiseTable.ParseError
        XCTAssertThrowsError(try RawDenoiseNoiseTable(jsonData: Data(#"{"A": []}"#.utf8))) {
            XCTAssertEqual($0 as? E, .empty(model: "A"))
        }
        XCTAssertThrowsError(try RawDenoiseNoiseTable(jsonData: Data(#"{"A": [[100, 1e-4]]}"#.utf8))) {
            XCTAssertEqual($0 as? E, .badRow(model: "A", index: 0))
        }
        XCTAssertThrowsError(try RawDenoiseNoiseTable(jsonData: Data(#"{"A": [[100, 0, 1e-7]]}"#.utf8))) {
            XCTAssertEqual($0 as? E, .nonPositive(model: "A", index: 0))
        }
        XCTAssertThrowsError(try RawDenoiseNoiseTable(jsonData: Data("[1, 2]".utf8)))
    }

    /// numpy's interp at, between and beyond the knots, on a hand-checkable table.
    func testInterpMatchesNumpySemantics() {
        let xp = [0.0, 1, 3], fp = [10.0, 20, 0]
        XCTAssertEqual(RawDenoiseNoiseTable.interp(-1, xp, fp), 10)
        XCTAssertEqual(RawDenoiseNoiseTable.interp(0, xp, fp), 10)
        XCTAssertEqual(RawDenoiseNoiseTable.interp(0.5, xp, fp), 15)
        XCTAssertEqual(RawDenoiseNoiseTable.interp(1, xp, fp), 20)
        XCTAssertEqual(RawDenoiseNoiseTable.interp(2, xp, fp), 10)
        XCTAssertEqual(RawDenoiseNoiseTable.interp(3, xp, fp), 0)
        XCTAssertEqual(RawDenoiseNoiseTable.interp(9, xp, fp), 0)
    }
}

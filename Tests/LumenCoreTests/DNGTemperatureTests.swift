// DNGTemperatureTests.swift
// Pins `DNGTemperature` to the two things it claims to be: the DNG SDK's
// `dng_temperature`, and the convention `CIRAWFilter.neutralTemperature`/`neutralTint`
// are reported in. The Apple numbers are measured (raw-corpus run 39152441459, corpus
// 1087, `corpus-mono-props` line); the SDK numbers come from an independent Python port
// of `dng_temperature.cpp` checked row by row against the SDK source.

import XCTest
@testable import LumenCore

final class DNGTemperatureTests: XCTestCase {

    // MARK: - Apple's readback

    /// Apple reported 5454.0087890625 K / -12.993514060974121 with neutralChromaticity
    /// 0.33333414793014526 / 0.3333340287208557 for the same file. The port lands
    /// within 5e-9 of Apple's chromaticity; 1e-7 is the Float32 spacing Apple's own
    /// numbers carry at 1/3 (3e-8) with room for the K/tint Floats' rounding.
    func testApplesAsShotPairMapsToApplesChromaticity() {
        let c = DNGTemperature.chromaticity(kelvin: 5454.0087890625, tint: -12.993514060974121)
        XCTAssertEqual(c.x, 0.33333414793014526, accuracy: 1e-7)
        XCTAssertEqual(c.y, 0.3333340287208557, accuracy: 1e-7)
        // And it is equal-energy white, the camera-neutral of a sensor with no CFA.
        XCTAssertEqual(c.x, 1.0 / 3.0, accuracy: 2e-6)
        XCTAssertEqual(c.y, 1.0 / 3.0, accuracy: 2e-6)
    }

    /// The other direction. The SDK's inverse gives 5453.990 K / -12.993503 (it is not an
    /// exact inverse off the table rows; see DNGTemperature.swift), so 0.05 K and 0.001
    /// tint, the audit's tolerances, hold with a 2.5x and 80x margin.
    func testApplesChromaticityMapsToApplesAsShotPair() {
        let tt = DNGTemperature.temperatureAndTint(x: 0.33333414793014526, y: 0.3333340287208557)
        XCTAssertEqual(tt.kelvin, 5454.009, accuracy: 0.05)
        XCTAssertEqual(tt.tint, -12.9935, accuracy: 0.001)
    }

    // MARK: - SDK reference points

    /// The table's own rows are the one place both directions are exact: on a row the
    /// interpolation weight is 0 or 1, so the blackbody point is the row's (u, v).
    func testTableRowsAreExactInBothDirections() {
        for row in DNGTemperature.table.dropFirst() {
            let kelvin = 1.0e6 / row.r
            let uv = DNGTemperature.chromaticity(kelvin: kelvin, tint: 0).uv
            XCTAssertEqual(uv.u, row.u, accuracy: 1e-12, "r=\(row.r)")
            XCTAssertEqual(uv.v, row.v, accuracy: 1e-12, "r=\(row.r)")
            let back = DNGTemperature.temperatureAndTint(
                for: Chromaticity.fromUV(u: row.u, v: row.v))
            XCTAssertEqual(back.kelvin / kelvin, 1, accuracy: 1e-9, "r=\(row.r)")
            XCTAssertEqual(back.tint, 0, accuracy: 1e-9, "r=\(row.r)")
        }
    }

    /// CIE illuminant A is a 2856 K Planckian radiator, so the SDK must call it 2856 K
    /// with no tint. The Python port gives 2855.7553 K / +0.0080; the 1 K and 0.05 bounds
    /// are the physical claim, the 1e-6 ones the cross-implementation agreement.
    func testIlluminantAIsAPlanckian2856K() {
        let tt = DNGTemperature.temperatureAndTint(x: 0.44757, y: 0.40745)
        XCTAssertEqual(tt.kelvin, 2856, accuracy: 1)
        XCTAssertEqual(tt.tint, 0, accuracy: 0.05)
        XCTAssertEqual(tt.kelvin, 2855.7553370077117, accuracy: 1e-6)
        XCTAssertEqual(tt.tint, 0.008021080057189106, accuracy: 1e-6)
    }

    /// D65 and D50 sit about 0.003 above the Planckian locus in uv (greener), which the
    /// SDK reports as roughly +10 tint: the reason ACR's Daylight preset is 5500/+10.
    /// Values from the Python port of dng_temperature.cpp.
    func testDaylightIlluminantsReadAsTheSDKReportsThem() {
        let d65 = DNGTemperature.temperatureAndTint(x: 0.3127, y: 0.3290)
        XCTAssertEqual(d65.kelvin, 6503.70718479529, accuracy: 1e-6)
        XCTAssertEqual(d65.tint, 9.769990121404899, accuracy: 1e-6)
        let d50 = DNGTemperature.temperatureAndTint(x: 0.3457, y: 0.3585)
        XCTAssertEqual(d50.kelvin, 5000.706605070579, accuracy: 1e-6)
        XCTAssertEqual(d50.tint, 9.562965495510433, accuracy: 1e-6)

        let c = DNGTemperature.chromaticity(kelvin: 6500, tint: 0)
        XCTAssertEqual(c.x, 0.3135279229340494, accuracy: 1e-12)
        XCTAssertEqual(c.y, 0.32353408205098605, accuracy: 1e-12)
    }

    /// Positive tint moves the white toward green (+v), negative toward magenta.
    func testTintSignMatchesTheSDK() {
        let base = DNGTemperature.chromaticity(kelvin: 5500, tint: 0).uv
        let green = DNGTemperature.chromaticity(kelvin: 5500, tint: 50).uv
        let magenta = DNGTemperature.chromaticity(kelvin: 5500, tint: -50).uv
        XCTAssertGreaterThan(green.v, base.v)
        XCTAssertLessThan(magenta.v, base.v)
        // 50 units is 50/3000 of uv distance along the isotherm.
        let du = green.u - base.u, dv = green.v - base.v
        XCTAssertEqual((du * du + dv * dv).squareRoot(), 50.0 / 3000.0, accuracy: 1e-4)
    }

    // MARK: - Round trips

    /// The SDK's two directions interpolate differently (linear in reciprocal
    /// temperature one way, by distance to two non-parallel isotherms the other), so a
    /// round trip is not the identity off the table rows. Measured over this grid with
    /// the Python port: temperature moves at most 1.085e-4 relative, tint at most
    /// 0.00162, and the re-projected xy at most 1.57e-5. The bounds below sit just
    /// above those maxima, so a transcription error in one table row, which moves
    /// these by orders of magnitude, cannot hide inside them.
    func testRoundTripsAcrossTheSliderRange() {
        var kelvins: [Double] = stride(from: 2000.0, through: 50000.0, by: 50).map { $0 }
        kelvins += stride(from: 20.0, through: 500.0, by: 1).map { 1.0e6 / $0 + 0.5 }
        var worstK = 0.0, worstTint = 0.0, worstXY = 0.0
        for kelvin in kelvins {
            for tint in stride(from: -150.0, through: 150.0, by: 5) {
                let c = DNGTemperature.chromaticity(kelvin: kelvin, tint: tint)
                let back = DNGTemperature.temperatureAndTint(for: c)
                let again = DNGTemperature.chromaticity(kelvin: back.kelvin, tint: back.tint)
                worstK = max(worstK, abs(back.kelvin - kelvin) / kelvin)
                worstTint = max(worstTint, abs(back.tint - tint))
                worstXY = max(worstXY, abs(again.x - c.x), abs(again.y - c.y))
            }
        }
        XCTAssertLessThan(worstK, 1.2e-4)
        XCTAssertLessThan(worstTint, 2e-3)
        XCTAssertLessThan(worstXY, 2e-5)
    }
}

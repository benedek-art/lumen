// DNGTemperature.swift
// Adobe's temperature/tint convention: a port of the DNG SDK's `dng_temperature`
// (`Set_xy_coord` / `Get_xy_coord`, the 31-row Robertson isotemperature table and
// `kTintScale = -3000`), checked row by row and line by line against the SDK's
// `dng_temperature.cpp` as vendored by digiKam (core/libs/dngwriter/extra/dng_sdk).
//
// WHY THIS EXISTS SEPARATELY FROM `ColorTemperature`. `CIRAWFilter.neutralTemperature`
// and `neutralTint` are numbers in THIS convention, not in Lumen's. Measured, raw-corpus
// run 39152441459, corpus 1087 (Leica M Monochrom): Apple reports 5454.0087890625 K /
// -12.993514060974121 alongside `neutralChromaticity` 0.33333414793014526 /
// 0.3333340287208557. This port maps that pair to xy within 5e-9 of Apple's own
// chromaticity; `ColorTemperature.chromaticity` (daylight locus above 4500 K, tint as a
// constant-u v offset) puts it at (0.32745, 0.33752), about 0.006 off in x. The Robertson
// isotherm at ~5500 K runs about 45 degrees off the v axis (table slope ≈ -0.85 to -1.0),
// so "tint" is not the same axis in the two models either. RawCorpusTests pins Apple's
// convention against this type on every corpus file.
//
// This type is the conversion only. Which convention the white-balance engine speaks is
// decided in `WhiteBalanceEngine` / `ColorTemperature`, not here.
//
// FAITHFUL, NOT TIDIED. The table is the SDK's, including its row 325 u = 0.24702,
// which breaks the table's smooth u progression (steps of 0.00763, 0.00692, 0.00889;
// 0.24792 would give 0.00782, 0.00799) and looks like a transcription slip. It stays:
// the point is to agree with the numbers ACR and Apple report, and "correcting" it
// would move every value between 2857 K and 3333 K away from them. Likewise the two
// directions are NOT exact inverses away from the table's rows — the forward direction interpolates linearly in
// reciprocal temperature, the inverse by perpendicular distance to two non-parallel
// isotherms. Measured over 2000–50000 K × ±150 tint: a round trip moves temperature by
// at most 1.1e-4 relative (0.35 K at 3200 K) and tint by at most 0.0016. ACR shows
// both rounded to integers, so that is below anything a photographer can see; it is
// pinned in DNGTemperatureTests so a transcription error cannot hide inside it.

import Foundation

public enum DNGTemperature {

    /// One row of the SDK's `kTempTable`: reciprocal megakelvin, CIE 1960 (u, v) of the
    /// blackbody point, and the isotherm's slope dv/du.
    struct Row {
        let r: Double
        let u: Double
        let v: Double
        let t: Double
    }

    /// `dng_temperature.cpp` `kTempTable`, verbatim. Source: Wyszecki & Stiles,
    /// "Color Science", 2nd ed., p. 228, as transcribed by Adobe.
    static let table: [Row] = [
        Row(r: 0, u: 0.18006, v: 0.26352, t: -0.24341),
        Row(r: 10, u: 0.18066, v: 0.26589, t: -0.25479),
        Row(r: 20, u: 0.18133, v: 0.26846, t: -0.26876),
        Row(r: 30, u: 0.18208, v: 0.27119, t: -0.28539),
        Row(r: 40, u: 0.18293, v: 0.27407, t: -0.30470),
        Row(r: 50, u: 0.18388, v: 0.27709, t: -0.32675),
        Row(r: 60, u: 0.18494, v: 0.28021, t: -0.35156),
        Row(r: 70, u: 0.18611, v: 0.28342, t: -0.37915),
        Row(r: 80, u: 0.18740, v: 0.28668, t: -0.40955),
        Row(r: 90, u: 0.18880, v: 0.28997, t: -0.44278),
        Row(r: 100, u: 0.19032, v: 0.29326, t: -0.47888),
        Row(r: 125, u: 0.19462, v: 0.30141, t: -0.58204),
        Row(r: 150, u: 0.19962, v: 0.30921, t: -0.70471),
        Row(r: 175, u: 0.20525, v: 0.31647, t: -0.84901),
        Row(r: 200, u: 0.21142, v: 0.32312, t: -1.0182),
        Row(r: 225, u: 0.21807, v: 0.32909, t: -1.2168),
        Row(r: 250, u: 0.22511, v: 0.33439, t: -1.4512),
        Row(r: 275, u: 0.23247, v: 0.33904, t: -1.7298),
        Row(r: 300, u: 0.24010, v: 0.34308, t: -2.0637),
        Row(r: 325, u: 0.24702, v: 0.34655, t: -2.4681),
        Row(r: 350, u: 0.25591, v: 0.34951, t: -2.9641),
        Row(r: 375, u: 0.26400, v: 0.35200, t: -3.5814),
        Row(r: 400, u: 0.27218, v: 0.35407, t: -4.3633),
        Row(r: 425, u: 0.28039, v: 0.35577, t: -5.3762),
        Row(r: 450, u: 0.28863, v: 0.35714, t: -6.7262),
        Row(r: 475, u: 0.29685, v: 0.35823, t: -8.5955),
        Row(r: 500, u: 0.30505, v: 0.35907, t: -11.324),
        Row(r: 525, u: 0.31320, v: 0.35968, t: -15.628),
        Row(r: 550, u: 0.32129, v: 0.36011, t: -23.325),
        Row(r: 575, u: 0.32931, v: 0.36038, t: -40.770),
        Row(r: 600, u: 0.33724, v: 0.36051, t: -116.45),
    ]

    /// `kTintScale`. Tint is the signed uv distance along the isotherm times this;
    /// positive tint is a greener illuminant (which ACR's slider renders as magenta
    /// correction), so the daylight locus sits near +10.
    public static let tintScale: Double = -3000

    /// `dng_temperature::Get_xy_coord`. Outside 1667 K (r = 600) the last table segment
    /// is extrapolated, as the SDK does; `kelvin` must be positive.
    public static func chromaticity(kelvin: Double, tint: Double) -> Chromaticity {
        let r = 1.0e6 / kelvin
        let offset = tint * (1.0 / tintScale)
        let last = table.count - 2
        var index = 0
        while index < last, !(r < table[index + 1].r) { index += 1 }
        let lo = table[index]
        let hi = table[index + 1]

        // Relative weight of the first line.
        let f = (hi.r - r) / (hi.r - lo.r)
        var u = lo.u * f + hi.u * (1.0 - f)
        var v = lo.v * f + hi.v * (1.0 - f)

        // Unit vectors along each isotherm, blended and renormalized.
        let len1 = (1.0 + lo.t * lo.t).squareRoot()
        let len2 = (1.0 + hi.t * hi.t).squareRoot()
        let uu1 = 1.0 / len1, vv1 = lo.t / len1
        let uu2 = 1.0 / len2, vv2 = hi.t / len2
        var uu3 = uu1 * f + uu2 * (1.0 - f)
        var vv3 = vv1 * f + vv2 * (1.0 - f)
        let len3 = (uu3 * uu3 + vv3 * vv3).squareRoot()
        uu3 /= len3
        vv3 /= len3

        u += uu3 * offset
        v += vv3 * offset
        let d = u - 4.0 * v + 2.0
        return Chromaticity(1.5 * u / d, v / d)
    }

    /// `dng_temperature::Set_xy_coord`.
    public static func temperatureAndTint(x: Double, y: Double) -> (kelvin: Double, tint: Double) {
        let denominator = 1.5 - x + 6.0 * y
        let u = 2.0 * x / denominator
        let v = 3.0 * y / denominator

        var lastDt = 0.0, lastDu = 0.0, lastDv = 0.0
        let final = table.count - 1
        for index in 1...final {
            let row = table[index]
            // The isotherm as a unit vector.
            let len = (1.0 + row.t * row.t).squareRoot()
            let du = 1.0 / len
            let dv = row.t / len

            // Signed distance of the point from this isotherm.
            var uu = u - row.u
            var vv = v - row.v
            var dt = -uu * dv + vv * du

            guard dt <= 0.0 || index == final else {
                lastDt = dt
                lastDu = du
                lastDv = dv
                continue
            }

            // Between this line and the previous one: weight by distance.
            if dt > 0.0 { dt = 0.0 }
            dt = -dt
            let f = index == 1 ? 0.0 : dt / (lastDt + dt)
            let prev = table[index - 1]
            let kelvin = 1.0e6 / (prev.r * f + row.r * (1.0 - f))

            uu = u - (prev.u * f + row.u * (1.0 - f))
            vv = v - (prev.v * f + row.v * (1.0 - f))
            var iu = du * (1.0 - f) + lastDu * f
            var iv = dv * (1.0 - f) + lastDv * f
            let ilen = (iu * iu + iv * iv).squareRoot()
            iu /= ilen
            iv /= ilen
            return (kelvin, (uu * iu + vv * iv) * tintScale)
        }
        // Unreachable: the loop always returns at `final`.
        return (.nan, .nan)
    }

    /// `temperatureAndTint(x:y:)` for a `Chromaticity`.
    public static func temperatureAndTint(for chroma: Chromaticity) -> (kelvin: Double, tint: Double) {
        temperatureAndTint(x: chroma.x, y: chroma.y)
    }
}

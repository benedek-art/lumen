// Strokes.swift — `lumen-render strokes`: rasterize a brush stroke set and SHOW it.
//
// The render path has no stroke blobs (main.swift, "Not rendered"), so until this
// command nobody on Linux could look at what a brush stroke paints. This rasterizes a
// `BrushStrokeSet` JSON with the shipping `MaskRaster.accumulatedBrushPlane` (the same
// call `BrushPlaneCache` makes), optionally over a photograph so Automask has pixels to
// read, and writes:
//
//   --out overlay.png     the photo (default recipe) or mid-grey, mask tinted red
//                         the way Lightroom's overlay shows it
//   --mask-out mask.png   the plane as 8-bit grey
//   --pfm-out mask.pfm    the plane as float ("Pf", bottom row first), for measuring
//   --metrics m.json      timing: whole set, and stroke by stroke (each stroke resumed
//                         onto the plane of the ones before it — the cache's path)
//
//   lumen-render strokes --strokes s.json [--input photo.lfi] [--long-edge 1024]
//                        [--width 1024 --height 683] --out overlay.png
//                        [--mask-out m.png] [--pfm-out m.pfm] [--metrics m.json]
//                        [--repeat 3]
//
// Stroke coordinates are the blob's own: x/y fractions of the image, size a diameter as
// a fraction of the long edge. Without --input the extent is --width × --height.

import Foundation
import LumenCore

extension LumenRenderCLI {

    struct StrokeTiming: Encodable {
        let stroke: Int
        let points: Int
        let radiusPx: Double
        let lengthPx: Double
        /// Median wall time to paint this one stroke onto the plane of the ones before.
        let ms: Double
        /// `ms` over the stroke's length in radii: the cost of one radius of travel,
        /// which is what a mouse event of ordinary speed adds.
        let msPerRadius: Double
    }

    struct StrokesReport: Encodable {
        let size: [Int]
        let strokes: Int
        let totalMs: Double
        let perStroke: [StrokeTiming]
        let maxAlpha: Double
        let meanAlpha: Double
    }

    static func strokes(_ args: Args) throws {
        let path = try args.require("strokes"), out = try args.require("out")
        guard let data = FileManager.default.contents(atPath: path) else {
            throw InputError.message("cannot read strokes '\(path)'")
        }
        let set = try BrushStrokeSet.decode(data)
        let repeats = Swift.max(try args.int("repeat") ?? 1, 1)

        var source: ImageBuffer? = nil
        var backdrop: [UInt8]
        var w: Int, h: Int
        if let input = args.string("input") {
            let longEdge = try args.int("long-edge") ?? 1024
            let settings = try args.settings()
            let prepared = try Renderer.prepare(path: input, longEdge: longEdge,
                                                needBandHues: false)
            source = prepared.image
            w = prepared.image.width
            h = prepared.image.height
            let (encoded, _) = Renderer.render(prepared, recipe: Recipe(), settings: settings)
            backdrop = encoded.bytes
        } else {
            w = try args.int("width") ?? 1024
            h = try args.int("height") ?? 683
            backdrop = [UInt8](repeating: 118, count: w * h * 3)
        }

        func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

        // Whole set, cold.
        var totals: [Double] = []
        var plane = Plane(width: w, height: h)
        for _ in 0..<repeats {
            let t0 = Date()
            plane = MaskRaster.accumulatedBrushPlane(strokes: set, size: (width: w, height: h),
                                                     source: source)
            totals.append(Date().timeIntervalSince(t0) * 1000)
        }

        // Stroke by stroke, resumed: what one mouse-up costs.
        var perStroke: [StrokeTiming] = []
        var held = Plane(width: w, height: h)
        let long = Double(Swift.max(w, h))
        for index in set.strokes.indices {
            let prefix = BrushStrokeSet(strokes: Array(set.strokes.prefix(index + 1)))
            var times: [Double] = []
            var next = held
            for _ in 0..<repeats {
                let t0 = Date()
                next = MaskRaster.accumulatedBrushPlane(strokes: prefix,
                                                        size: (width: w, height: h),
                                                        source: source,
                                                        resuming: (plane: held, strokes: index))
                times.append(Date().timeIntervalSince(t0) * 1000)
            }
            held = next
            let s = set.strokes[index]
            let r = s.size / 2 * long
            var length = 0.0
            for (a, b) in zip(s.points, s.points.dropFirst()) {
                let dx = (b.x - a.x) * Double(w), dy = (b.y - a.y) * Double(h)
                length += (dx * dx + dy * dy).squareRoot()
            }
            let ms = median(times)
            perStroke.append(StrokeTiming(stroke: index, points: s.points.count,
                                          radiusPx: r, lengthPx: length, ms: ms,
                                          msPerRadius: length > 0 ? ms / (length / r) : ms))
        }

        // Overlay: red at 60 % of the mask, over the backdrop.
        var rgb = backdrop
        var grey = [UInt8](repeating: 0, count: w * h * 3)
        var sum = 0.0, peak = 0.0
        for i in 0..<(w * h) {
            let a = Double(Swift.min(Swift.max(plane.values[i], 0), 1))
            sum += a
            peak = Swift.max(peak, a)
            let k = 0.6 * a
            let red: [Double] = [230, 40, 40]
            for c in 0..<3 {
                let v = Double(rgb[i * 3 + c]) * (1 - k) + red[c] * k
                rgb[i * 3 + c] = UInt8(Swift.min(Swift.max(v.rounded(), 0), 255))
            }
            let g = UInt8((a * 255).rounded())
            grey[i * 3] = g; grey[i * 3 + 1] = g; grey[i * 3 + 2] = g
        }
        try write(PNG.encode(width: w, height: h, rgb: rgb, space: .srgb), to: out)
        if let m = args.string("mask-out") {
            try write(PNG.encode(width: w, height: h, rgb: grey, space: .srgb), to: m)
        }
        if let m = args.string("pfm-out") {
            var pfm = Data("Pf\n\(w) \(h)\n-1.0\n".utf8)
            var floats = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w { floats[(h - 1 - y) * w + x] = plane.values[y * w + x] }
            }
            floats.withUnsafeBytes { pfm.append(contentsOf: $0) }
            try write(pfm, to: m)
        }
        let report = StrokesReport(size: [w, h], strokes: set.strokes.count,
                                   totalMs: median(totals), perStroke: perStroke,
                                   maxAlpha: peak, meanAlpha: sum / Double(w * h))
        print("painted \(set.strokes.count) strokes at \(w)x\(h) in "
              + "\(fmt(median(totals), 1)) ms → \(out)")
        for t in perStroke {
            print("  stroke \(t.stroke): r \(fmt(t.radiusPx, 1)) px, \(fmt(t.lengthPx, 0)) px long, "
                  + "\(fmt(t.ms, 2)) ms (\(fmt(t.msPerRadius, 3)) ms per radius of travel)")
        }
        if let m = args.string("metrics") { try writeJSON(report, to: m) }
    }
}

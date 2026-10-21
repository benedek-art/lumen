// UprightCommand.swift — `lumen-render upright`: what the automatic perspective modes
// see and do on one input. Detects lines (`UprightDetector`) on the prepared input,
// solves every mode (`UprightSolver`), and reports the residual tilt of the verticals
// and horizontals before and after — by carrying the detected segments through the map
// AND by detecting again on the corrected pixels, which is the honest version.
//
//   lumen-render upright --input in.lfi [--long-edge 1024] [--modes vertical,full]
//                        [--out-dir dir]     (writes <mode>.png renders when given)

import Foundation
import LumenCore

extension LumenRenderCLI {

    static func upright(_ args: Args) throws {
        let input = try args.require("input")
        let longEdge = try args.int("long-edge") ?? 1024
        let settings = try args.settings()
        let modes: [Upright.Mode] = try (args.string("modes") ?? "level,vertical,full,auto")
            .split(separator: ",").map {
                guard let m = Upright.Mode(rawValue: String($0)) else {
                    throw InputError.message("--modes: '\($0)' is not an Upright mode")
                }
                return m
            }
        let prepared = try Renderer.prepare(path: input, longEdge: longEdge, needBandHues: false)
        let image = prepared.image
        let segments = UprightDetector.detect(image)
        let identity = GeometryMap(geometry: Geometry(), sourceWidth: image.width,
                                   sourceHeight: image.height)
        let before = UprightSolver.residual(segments, map: identity)
        print("\(input): \(image.width)x\(image.height), \(segments.count) segments "
              + "(\(before.verticals) near-vertical, \(before.horizontals) near-horizontal)")
        print("  uncorrected: vertical RMS \(fmt(before.verticalRMS, 3))° median "
              + "\(fmt(before.verticalMedian, 3))°  "
              + "horizontal RMS \(fmt(before.horizontalRMS, 3))°")
        for mode in modes {
            let u = Upright(mode: mode, segments: segments)
            let s = UprightSolver.solve(u, sourceWidth: Double(image.width),
                                        sourceHeight: Double(image.height))
            let geometry = Geometry(upright: u)
            let map = GeometryMap(geometry: geometry, sourceWidth: image.width,
                                  sourceHeight: image.height)
            let carried = UprightSolver.residual(segments, map: map)
            let corrected = GeometryStage.apply(image, geometry: geometry)
            let found = UprightDetector.detect(corrected)
            let redetected = UprightSolver.residual(
                found,
                map: GeometryMap(geometry: Geometry(), sourceWidth: corrected.width,
                                 sourceHeight: corrected.height))
            let d = 180 / Double.pi
            print("  \(mode.rawValue): roll \(fmt(s.roll * d, 2))° pitch \(fmt(s.pitch * d, 2))° "
                  + "yaw \(fmt(s.yaw * d, 2))° shear \(fmt(s.shear, 4)); zoom "
                  + "\(fmt(1 / map.minification, 3))×")
            print("      carried: vertical RMS \(fmt(carried.verticalRMS, 3))°  horizontal "
                  + "\(fmt(carried.horizontalRMS, 3))°   re-detected: vertical "
                  + "\(fmt(redetected.verticalRMS, 3))° median \(fmt(redetected.verticalMedian, 3))° "
                  + "(\(redetected.verticals))  horizontal "
                  + "\(fmt(redetected.horizontalRMS, 3))° (\(redetected.horizontals))")
            if let dir = args.string("out-dir") {
                var recipe = Recipe()
                recipe.develop.geometry = geometry
                let (encoded, _) = Renderer.render(prepared, recipe: recipe, settings: settings)
                let path = (dir as NSString).appendingPathComponent("\(mode.rawValue).png")
                try write(PNG.encode(width: encoded.width, height: encoded.height,
                                     rgb: encoded.bytes, space: settings.space), to: path)
                // The re-detected lines, so a sheet can show what the number measured.
                try writeJSON(found, to: (dir as NSString)
                    .appendingPathComponent("\(mode.rawValue).lines.json"))
            }
        }
    }
}

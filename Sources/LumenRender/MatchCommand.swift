// MatchCommand.swift — `lumen-render match`: Match Total Exposures, headless.
//
//   lumen-render match --input ref.lfi --input other.lfi [...]
//                      [--shutter 1/50 --aperture 5.6 --iso-exif 250 per input, in order]
//                      [--as-shot-kelvin K --as-shot-tint T per input, in order]
//                      [--long-edge 1024] [--out-dir dir] [--report out.json]
//
// The first input is the reference. Each frame is measured the way the app measures it
// (a 512-px proxy with the tone sliders at zero, read back into a scene-EV grid), each
// is located in the reference (`ExposureMatch.measureOverlap`), and `ExposureMatch.plan`
// is run with both the measurement and the EXIF, so the report carries the measured and
// the EXIF-only answers side by side. With --out-dir
// every frame is rendered at its matched exposure.

import Foundation
import LumenCore

extension LumenRenderCLI {

    struct MatchFrameReport: Encodable {
        let input: String
        let measuredStopsBrighter: Double?
        let overlapCorrelation: Double?
        let exifExposure: Double?
        let matchedExposure: Double?
        let renderedMedianEncoded: Double?
        let renderedMeanEncoded: Double?
    }

    static func shutter(_ text: String) throws -> Double {
        let parts = text.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 {
            return n / d
        }
        guard let v = Double(text) else { throw InputError.message("bad shutter '\(text)'") }
        return v
    }

    static func match(_ args: Args) throws {
        let inputs = args.all("input")
        guard inputs.count >= 2 else { throw InputError.message("match needs two --input") }
        let shutters = args.all("shutter"), apertures = args.all("aperture")
        let isos = args.all("iso-exif")
        let kelvins = args.all("as-shot-kelvin"), tints = args.all("as-shot-tint")
        let (base, _) = try recipe(args, baseKey: "base")
        var probe = base
        probe.develop.tone = Tone()
        var frames: [ExposureMatch.Frame<Int>] = []
        var exifFrames: [ExposureMatch.Frame<Int>] = []
        var settingsList: [RenderSettings] = []
        var grids: [ExposureMatch.LumaGrid] = []
        var overlaps: [ExposureMatch.Overlap?] = []
        for (i, path) in inputs.enumerated() {
            var settings = try args.settings()
            if i < kelvins.count, let k = Double(kelvins[i]) { settings.asShotKelvin = k }
            if i < tints.count, let t = Double(tints[i]) { settings.asShotTint = t }
            settingsList.append(settings)
            let capture = ExposureMatch.Capture(
                shutterSeconds: i < shutters.count ? try shutter(shutters[i]) : nil,
                aperture: i < apertures.count ? Double(apertures[i]) : nil,
                iso: i < isos.count ? Int(isos[i]) : nil)
            let (proxy, transform) = try measurementProxy(path: path, probe: probe,
                                                          settings: settings)
            let grid = ExposureMatch.LumaGrid(encodedSRGB: proxy.bytes, width: proxy.width,
                                              height: proxy.height, channels: 3,
                                              transform: transform,
                                              displayWhite: transform.white)
            grids.append(grid)
            let overlap = i == 0 ? nil
                : ExposureMatch.measureOverlap(reference: grids[0], frame: grid)
            overlaps.append(overlap)
            frames.append(.init(id: i, capture: capture, exposure: 0,
                                measuredStopsBrighter: overlap?.stopsBrighter))
            exifFrames.append(.init(id: i, capture: capture, exposure: 0))
        }
        let plan = ExposureMatch.plan(referenceID: 0, frames: frames)
        let exifPlan = ExposureMatch.plan(referenceID: 0, frames: exifFrames)
        print(ExposureMatch.summary(plan, referenceName: inputs[0]))
        let longEdge = try args.int("long-edge") ?? 1024
        var reports: [MatchFrameReport] = []
        for (i, path) in inputs.enumerated() {
            let exposure = i == 0 ? 0 : plan.exposures[i]
            var median: Double?, mean: Double?
            if let dir = args.string("out-dir"), let exposure {
                var r = probe
                r.develop.tone.exposure = exposure
                let prepared = try Renderer.prepare(path: path, longEdge: longEdge,
                                                    needBandHues: false)
                let (img, sec) = Renderer.render(prepared, recipe: r, settings: settingsList[i])
                try write(PNG.encode(width: img.width, height: img.height, rgb: img.bytes,
                                     space: settingsList[i].space),
                          to: "\(dir)/match_\(i).png")
                let (m, _) = Metrics.measure(img, space: settingsList[i].space, seconds: sec)
                median = m.luminance.medianEncoded
                mean = m.luminance.meanEncoded
            }
            reports.append(MatchFrameReport(
                input: path, measuredStopsBrighter: frames[i].measuredStopsBrighter,
                overlapCorrelation: overlaps[i]?.correlation,
                exifExposure: i == 0 ? 0 : exifPlan.exposures[i],
                matchedExposure: exposure, renderedMedianEncoded: median,
                renderedMeanEncoded: mean))
            print("\(i) measured \(frames[i].measuredStopsBrighter.map { fmt($0, 3) } ?? "-") EV"
                  + " (ncc \(overlaps[i].map { fmt($0.correlation, 3) } ?? "-"))  matched "
                  + "\(exposure.map { fmt($0, 2) } ?? "-")  exif-only "
                  + "\((i == 0 ? 0 : exifPlan.exposures[i]).map { fmt($0, 2) } ?? "-")"
                  + (median.map { "  rendered median \(fmt($0, 3))" } ?? ""))
        }
        if let p = args.string("report") { try writeJSON(reports, to: p) }
    }
}

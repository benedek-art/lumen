// AutoCommand.swift — `lumen-render auto`: Auto Tone as the app runs it, headless.
//
// The app's path (AppStateActions.applyAutoTone): render a 512-px proxy with the tone
// sliders at zero, read it back through the display transform into scene EV
// (`AutoTone.statistics`), and suggest. This does the same on the input, then renders
// the before (tone at zero) and after (Auto's values) at --long-edge and reports both.
//
//   lumen-render auto --input in.lfi [--base r.json] [--set key=value ...]
//                     [--long-edge 1024] [--out-before b.png] [--out-after a.png]
//                     [--report out.json] [--legacy]

import Foundation
import LumenCore

extension LumenRenderCLI {

    struct AutoReport: Encodable {
        let input: String
        let suggestion: [String: Double]
        let statistics: [String: Double]
        /// Auto's own prediction of the after render's encoded luminance, per percentile.
        let predicted: [String: Double]
        let before: ImageMetrics
        let after: ImageMetrics
    }

    /// The 512-px proxy Auto and Match Total Exposures read: `probe` rendered, plus the
    /// transform it went through.
    static func measurementProxy(path: String, probe: Recipe,
                                 settings: RenderSettings) throws
        -> (EncodedImage, DisplayTransform) {
        let proxy = try Renderer.prepare(
            path: path, longEdge: 512,
            needBandHues: ColorEngine.needsMeasuredBandHues(probe.develop.mixer))
        let (encoded, _) = Renderer.render(proxy, recipe: probe, settings: settings)
        return (encoded, DisplayTransform.forRecipe(probe))
    }

    /// The statistics Auto reads, from a 512-px render of `probe`.
    static func autoStatistics(path: String, probe: Recipe,
                               settings: RenderSettings) throws -> AutoTone.Statistics {
        let (encoded, transform) = try measurementProxy(path: path, probe: probe,
                                                        settings: settings)
        guard let stats = AutoTone.statistics(encodedSRGB: encoded.bytes, channels: 3,
                                              transform: transform,
                                              displayWhite: transform.white)
        else { throw InputError.message("auto: empty proxy") }
        return stats
    }

    static func auto(_ args: Args) throws {
        let input = try args.require("input")
        let longEdge = try args.int("long-edge") ?? 1024
        let settings = try args.settings()
        let (base, _) = try recipe(args, baseKey: "base")
        var probe = base
        probe.develop.tone = Tone()
        probe.develop.color.vibrance = 0
        let stats = try autoStatistics(path: input, probe: probe, settings: settings)
        // --legacy: the pre-WS-09 heuristic (`suggest`), for before/after evidence.
        var result = args.flag("legacy")
            ? AutoTone.Result(tone: AutoTone.suggest(from: stats))
            : AutoTone.auto(from: stats, render: probe.look.render.resolved())
        // The app's closed loop: render the proxy with the answer, count the clip.
        var refinements = 0
        while !args.flag("legacy"), refinements < AutoTone.maxClipRefinements {
            var trial = probe
            result.apply(to: &trial)
            let check = try autoStatistics(path: input, probe: trial, settings: settings)
            guard let next = AutoTone.refine(result, probe: stats,
                                             render: probe.look.render.resolved(),
                                             measuredClip: check.clippedFraction ?? 0,
                                             measuredCrush: check.crushedFraction ?? 0)
            else { break }
            result = next
            refinements += 1
        }
        var after = probe
        result.apply(to: &after)

        let prepared = try Renderer.prepare(
            path: input, longEdge: longEdge,
            needBandHues: ColorEngine.needsMeasuredBandHues(base.develop.mixer))
        let (b, bs) = Renderer.render(prepared, recipe: probe, settings: settings)
        let (a, asec) = Renderer.render(prepared, recipe: after, settings: settings)
        if let p = args.string("out-before") {
            try write(PNG.encode(width: b.width, height: b.height, rgb: b.bytes,
                                 space: settings.space), to: p)
        }
        if let p = args.string("out-after") {
            try write(PNG.encode(width: a.width, height: a.height, rgb: a.bytes,
                                 space: settings.space), to: p)
        }
        let (mb, _) = Metrics.measure(b, space: settings.space, seconds: bs)
        let (ma, _) = Metrics.measure(a, space: settings.space, seconds: asec)
        let t = result.tone
        let suggestion: [String: Double] = [
            "exposure": t.exposure, "contrast": t.contrast, "highlights": t.highlights,
            "shadows": t.shadows, "whites": t.whites, "blacks": t.blacks,
            "contrastPivot": t.contrastPivot, "vibrance": result.vibrance,
            "clipRefinements": Double(refinements)]
        let ps = [0.002, 0.01, 0.05, 0.5, 0.95, 0.99, 0.998]
        let predicted = AutoTone.predictEncoded(stats, tone: result.tone,
                                                render: probe.look.render.resolved(),
                                                percentiles: ps)
        print("predicted " + zip(ps, predicted).map { "p\($0.0) \(fmt($0.1, 3))" }
            .joined(separator: " "))
        var statistics: [String: Double] = [
            "p005": stats.percentileEV(0.005), "p50": stats.percentileEV(0.5),
            "p995": stats.percentileEV(0.995), "meanEV": stats.meanEV]
        statistics["meanChroma"] = stats.meanChroma ?? -1
        print("auto " + suggestion.sorted { $0.key < $1.key }
            .map { "\($0.key) \(fmt($0.value, 2))" }.joined(separator: "  "))
        print("before:"); printSummary(mb)
        print("after:"); printSummary(ma)
        let pe = ma.luminance.percentilesEncoded
        print("actual    p0.01 \(fmt(pe.p1, 3)) p0.05 \(fmt(pe.p5, 3)) p0.5 \(fmt(pe.p50, 3)) "
              + "p0.95 \(fmt(pe.p95, 3)) p0.99 \(fmt(pe.p99, 3))")
        if let j = args.string("report") {
            var pmap: [String: Double] = [:]
            for (p, v) in zip(ps, predicted) { pmap["\(p)"] = v }
            try writeJSON(AutoReport(input: input, suggestion: suggestion,
                                     statistics: statistics, predicted: pmap,
                                     before: mb, after: ma), to: j)
        }
    }
}

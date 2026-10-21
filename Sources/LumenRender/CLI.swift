// CLI.swift — argument parsing and the four commands. See main.swift for the manual.

import Foundation
import LumenCore

struct RenderSettings {
    var asShotKelvin = 5500.0
    var asShotTint = 0.0
    var iso: Double? = nil
    var space = OutputSpace.srgb
    var dither = true
    var lutSize = LUT3D.interactiveSize
    /// S16's filter. Lanczos-3 is the stage; the other two exist for comparison sheets.
    var resampler = GeometryResample.Filter.lanczos3
}

/// The input, downsampled once, with what every render of it shares.
struct PreparedInput {
    let image: ImageBuffer
    /// Downsample ratio (≤ 1) from the file's own size — the decode scale factor the
    /// app's S3 noise model is told about.
    let scale: Double
    let sourceWidth: Int
    let sourceHeight: Int
    /// Uniformity's measured band hues, from the neutral input, computed on first need.
    let bandHues: [Double]?
}

enum Renderer {

    static func prepare(path: String, longEdge: Int, needBandHues: Bool) throws -> PreparedInput {
        let full = try InputImage.load(path: path)
        let small = InputImage.downsample(full, longEdge: longEdge)
        let scale = Double(Swift.max(small.width, small.height))
            / Double(Swift.max(full.width, full.height))
        return PreparedInput(image: small, scale: scale, sourceWidth: full.width,
                             sourceHeight: full.height,
                             bandHues: needBandHues ? ColorEngine.measureBandMeanHues(small) : nil)
    }

    /// `PipelineRenderer.renderReference`, minus the decode, plus the export's dither.
    static func render(_ input: PreparedInput, recipe: Recipe,
                       settings: RenderSettings) -> (EncodedImage, Double) {
        let start = Date()
        let plan = RenderPlan(recipe: recipe, asShotKelvin: settings.asShotKelvin,
                              asShotTint: settings.asShotTint,
                              lutSize: settings.lutSize,
                              captureISO: settings.iso,
                              bandMeanHues: ColorEngine.needsMeasuredBandHues(
                                  recipe.develop.mixer) ? input.bandHues : nil)
        var staged = input.image
        let noiseScale = input.scale * input.scale
        if !plan.denoiseIsIdentity {
            staged = plan.classicalDenoise.scaled(noiseScale: noiseScale)
                .apply(staged)
        }
        // The same scale to S11, where a mask's Noise rows obey S3's preview rule.
        let rendered = ReferenceRenderer.render(
            staged, plan: plan, inputs: ReferenceRenderer.Inputs(noiseScale: noiseScale))
        // S16, as `PipelineRenderer.renderReference` runs it: after the render, before
        // the encode, in display-linear light. An automatic Upright with no stored lines
        // is solved from lines detected on this input, which is what the app does once
        // when the mode is picked (`UprightDetector`), so the CLI renders what the app
        // would have stored.
        var geometry = recipe.develop.geometry
        if var upright = geometry.upright, upright.segments.isEmpty,
           [.auto, .level, .vertical, .full].contains(upright.mode) {
            upright.segments = UprightDetector.detect(input.image)
            geometry.upright = upright
        }
        let framed = GeometryStage.apply(rendered, geometry: geometry,
                                         filter: settings.resampler)
        let encoded = OutputEncode.encode(framed, space: settings.space,
                                          dither: settings.dither)
        return (encoded, Date().timeIntervalSince(start))
    }
}

// MARK: - Arguments

struct Args {
    var command: String
    private var values: [String: [String]] = [:]
    private var flags: Set<String> = []

    static let flagNames: Set<String> = ["no-dither", "json", "help", "legacy"]

    init(_ argv: [String]) throws {
        guard let first = argv.first else { throw InputError.message(LumenRenderCLI.usage) }
        command = first
        var i = 1
        while i < argv.count {
            let a = argv[i]
            guard a.hasPrefix("--") else {
                throw InputError.message("unexpected argument '\(a)'")
            }
            var name = String(a.dropFirst(2))
            if let eq = name.firstIndex(of: "=") {
                let v = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
                values[name, default: []].append(v)
                i += 1
                continue
            }
            if Args.flagNames.contains(name) { flags.insert(name); i += 1; continue }
            guard i + 1 < argv.count else { throw InputError.message("--\(name) needs a value") }
            values[name, default: []].append(argv[i + 1])
            i += 2
        }
    }

    func string(_ k: String) -> String? { values[k]?.last }
    func all(_ k: String) -> [String] { values[k] ?? [] }
    func flag(_ k: String) -> Bool { flags.contains(k) }
    func require(_ k: String) throws -> String {
        guard let v = string(k) else { throw InputError.message("missing --\(k)") }
        return v
    }
    func double(_ k: String) throws -> Double? {
        guard let s = string(k) else { return nil }
        guard let d = Double(s), d.isFinite else { throw InputError.message("--\(k): '\(s)' is not a number") }
        return d
    }
    func int(_ k: String) throws -> Int? {
        guard let s = string(k) else { return nil }
        guard let d = Int(s) else { throw InputError.message("--\(k): '\(s)' is not an integer") }
        return d
    }

    func settings() throws -> RenderSettings {
        var s = RenderSettings()
        if let v = try double("as-shot-kelvin") { s.asShotKelvin = v }
        if let v = try double("as-shot-tint") { s.asShotTint = v }
        s.iso = try double("iso")
        if let sp = string("space") {
            guard let o = OutputSpace(rawValue: sp.lowercased()) else {
                throw InputError.message("--space must be srgb or p3")
            }
            s.space = o
        }
        s.dither = !flag("no-dither")
        if let n = try int("lut-size") {
            guard (2...129).contains(n) else { throw InputError.message("--lut-size 2…129") }
            s.lutSize = n
        }
        if let r = string("resampler") {
            switch r.lowercased() {
            case "lanczos3": s.resampler = .lanczos3
            case "bicubic": s.resampler = .bicubic
            case "bilinear": s.resampler = .bilinear
            default: throw InputError.message("--resampler must be lanczos3, bicubic or bilinear")
            }
        }
        return s
    }
}

// MARK: - Commands

enum LumenRenderCLI {

    static let usage = """
    usage:
      lumen-render render --input in.lfi [--recipe r.json] [--set key=value ...]
                          [--long-edge 1600] --out out.png [--metrics out.json]
      lumen-render sweep  --input in.lfi [--base r.json] [--set key=value ...]
                          --key develop.tone.exposure --values -2,-1,0,1,2
                          [--long-edge 512] [--columns 5] --out sheet.png
                          [--metrics sweep.json] [--tiles-dir dir]
      lumen-render keys   [--base r.json] [--json]
      lumen-render synth  --out test.lfi [--width 960] [--height 540]
      lumen-render upright --input in.lfi [--long-edge 1024] [--modes level,vertical]
                          [--out-dir dir]   (Upright lines, solve and residual tilt)
      lumen-render auto   --input in.lfi [--base r.json] [--long-edge 1024]
                          [--out-before b.png] [--out-after a.png] [--report r.json]
      lumen-render match  --input ref.lfi --input other.lfi [...] [--shutter 1/50
                          --aperture 5.6 --iso-exif 250, once per input] [--out-dir d]
    shared: --as-shot-kelvin 5500 --as-shot-tint 0 --iso N --space srgb|p3
            --no-dither --lut-size 33 --resampler lanczos3|bicubic|bilinear
    (full manual: the header of Sources/LumenRender/main.swift)
    """

    static func main(_ argv: [String]) {
        do {
            let args = try Args(argv)
            switch args.command {
            case "render": try render(args)
            case "sweep": try sweep(args)
            case "keys": try keys(args)
            case "synth": try synth(args)
            case "upright": try upright(args)
            case "auto": try auto(args)
            case "match": try match(args)
            case "help", "--help", "-h": print(usage)
            default: throw InputError.message("unknown command '\(args.command)'\n\(usage)")
            }
        } catch {
            FileHandle.standardError.write(Data("lumen-render: \(error)\n".utf8))
            exit(1)
        }
    }

    static func write(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func writeJSON<T: Encodable>(_ value: T, to path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(enc.encode(value), to: path)
    }

    /// Base recipe plus every `--set`, each verified by read-back.
    static func recipe(_ args: Args, baseKey: String) throws -> (Recipe, [String: JSONValue]) {
        var r = try RecipeKeys.loadRecipe(path: args.string(baseKey))
        var applied: [String: JSONValue] = [:]
        for s in args.all("set") {
            guard let eq = s.firstIndex(of: "=") else {
                throw InputError.message("--set expects key=value, got '\(s)'")
            }
            let key = String(s[..<eq]), raw = String(s[s.index(after: eq)...])
            let out = try RecipeKeys.assign(r, path: key, to: RecipeKeys.parseValue(raw))
            r = out.recipe
            applied[key] = out.effective
        }
        return (r, applied)
    }

    static func fmt(_ v: Double, _ digits: Int = 4) -> String {
        String(format: "%.\(digits)f", v)
    }

    // MARK: render

    struct RenderReport: Encodable {
        let input: String
        let sourceSize: [Int]
        let recipe: String
        let sets: [String: Double]
        let settings: [String: String]
        let metrics: ImageMetrics
    }

    static func render(_ args: Args) throws {
        let input = try args.require("input"), out = try args.require("out")
        let longEdge = try args.int("long-edge") ?? 1600
        let settings = try args.settings()
        let (recipe, applied) = try self.recipe(args, baseKey: "recipe")
        let prepared = try Renderer.prepare(
            path: input, longEdge: longEdge,
            needBandHues: ColorEngine.needsMeasuredBandHues(recipe.develop.mixer))
        let (encoded, seconds) = Renderer.render(prepared, recipe: recipe, settings: settings)
        try write(PNG.encode(width: encoded.width, height: encoded.height, rgb: encoded.bytes,
                             space: settings.space), to: out)
        let (metrics, _) = Metrics.measure(encoded, space: settings.space, seconds: seconds)
        print("rendered \(encoded.width)x\(encoded.height) in \(fmt(seconds, 2)) s → \(out)")
        printSummary(metrics)
        if let m = args.string("metrics") {
            let report = RenderReport(
                input: input, sourceSize: [prepared.sourceWidth, prepared.sourceHeight],
                recipe: try CanonicalJSON.canonicalRecipeJSON(recipe),
                sets: applied.compactMapValues { if case .number(let d) = $0 { return d }; return nil },
                settings: settingsDict(settings, longEdge: longEdge),
                metrics: metrics)
            try writeJSON(report, to: m)
            print("metrics → \(m)")
        }
    }

    static func settingsDict(_ s: RenderSettings, longEdge: Int) -> [String: String] {
        ["asShotKelvin": fmt(s.asShotKelvin, 1), "asShotTint": fmt(s.asShotTint, 2),
         "iso": s.iso.map { fmt($0, 0) } ?? "none", "space": s.space.displayName,
         "dither": s.dither ? "on" : "off", "lutSize": "\(s.lutSize)",
         "longEdge": "\(longEdge)",
         "inputConvention": "scene-linear Rec.2020 D65, camera-reference WB (neutral = R=G=B)"]
    }

    static func printSummary(_ m: ImageMetrics) {
        let l = m.luminance
        print("  luminance encoded mean \(fmt(l.meanEncoded)) median \(fmt(l.medianEncoded))"
              + "  p1 \(fmt(l.percentilesEncoded.p1)) p99 \(fmt(l.percentilesEncoded.p99))"
              + "  | linear mean \(fmt(l.meanLinear))")
        print("  clipped any \(fmt(m.clipping.highlightsPct.any, 2))%  crushed any "
              + "\(fmt(m.clipping.shadowsPct.any, 2))%  mean OKLab chroma "
              + "\(fmt(m.colour.meanChroma)) (chromatic \(fmt(m.colour.chromaticPct, 1))%)")
    }

    // MARK: sweep

    struct SweepTile: Encodable {
        let value: Double
        let effectiveValue: JSONValueBox
        let isReference: Bool
        let metrics: ImageMetrics
        /// Nil when the tile is a different size from the reference (a geometry sweep):
        /// a per-pixel comparison between two framings measures nothing.
        let deltaE2000VsReference: Metrics.DeltaE?
        let meanEncodedLuminanceDelta: Double
        let meanLinearLuminanceDeltaEV: Double
    }

    struct ZoneTable: Encodable {
        let definition: String
        let zoneEdgesEncoded: [Double]
        let referencePixelCounts: [Int]
        let referenceMeanEncoded: [Double?]
        /// [value index][zone]: mean change in encoded luminance, 0…1 (×255 = codes).
        let deltaEncoded: [[Double?]]
        /// [value index][zone]: change in stops of the zone's mean linear luminance.
        let deltaEV: [[Double?]]
    }

    struct SweepReport: Encodable {
        let input: String
        let sourceSize: [Int]
        let key: String
        let values: [Double]
        let referenceValue: Double
        let referenceRule: String
        let baseRecipe: String
        let settings: [String: String]
        let tiles: [SweepTile]
        let zones: ZoneTable
    }

    /// JSONValue is Codable but not pretty in a report; this writes it as itself.
    struct JSONValueBox: Encodable {
        let value: JSONValue
        func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
    }

    final class Slots<T>: @unchecked Sendable {
        private var items: [T?]
        private let lock = NSLock()
        init(_ n: Int) { items = Array(repeating: nil, count: n) }
        func store(_ i: Int, _ v: T) { lock.lock(); items[i] = v; lock.unlock() }
        var values: [T] { items.map { $0! } }
    }

    static func sweep(_ args: Args) throws {
        let input = try args.require("input"), out = try args.require("out")
        let key = try args.require("key")
        let valuesText = try args.require("values")
        let values: [Double] = try valuesText.split(separator: ",").map {
            let t = $0.trimmingCharacters(in: .whitespaces)
            guard let d = Double(t), d.isFinite else {
                throw InputError.message("--values: '\(t)' is not a number")
            }
            return d
        }
        guard !values.isEmpty else { throw InputError.message("--values is empty") }
        let longEdge = try args.int("long-edge") ?? 512
        let columns = try args.int("columns") ?? Swift.min(values.count, 5)
        let settings = try args.settings()
        let (base, _) = try recipe(args, baseKey: "base")

        // Every recipe first, so a bad path fails before any pixel is rendered.
        var recipes: [Recipe] = []
        var effective: [JSONValue] = []
        for v in values {
            let r = try RecipeKeys.assign(base, path: key, to: .number(v))
            recipes.append(r.recipe)
            effective.append(r.effective)
        }
        let baseTree = try CanonicalJSON.tree(of: base)
        let baseValue: Double? = {
            if case .number(let d)? = RecipeKeys.value(at: RecipeKeys.segments(key), in: baseTree) {
                return d
            }
            return nil
        }()
        let refIndex: Int
        let refRule: String
        if let i = values.firstIndex(of: 0) {
            refIndex = i; refRule = "the tile whose value is 0"
        } else if let bv = baseValue, let i = values.firstIndex(of: bv) {
            refIndex = i; refRule = "the tile equal to the base recipe's value (\(bv))"
        } else {
            refIndex = values.count / 2
            refRule = "no 0 and no base-value tile: the middle tile"
        }

        let needHues = recipes.contains { ColorEngine.needsMeasuredBandHues($0.develop.mixer) }
        let prepared = try Renderer.prepare(path: input, longEdge: longEdge,
                                            needBandHues: needHues)
        let start = Date()
        let results = Slots<(EncodedImage, ImageMetrics, PixelPlanes)>(values.count)
        // Tiles in parallel: a plan is a value, the table caches are lock-guarded, and
        // `ReferenceRenderer` holds no state. The renderer itself is serial inside, so
        // tile-level parallelism is where the cores are.
        DispatchQueue.concurrentPerform(iterations: values.count) { i in
            let (enc, secs) = Renderer.render(prepared, recipe: recipes[i], settings: settings)
            let (m, planes) = Metrics.measure(enc, space: settings.space, seconds: secs)
            results.store(i, (enc, m, planes))
        }
        let tilesOut = results.values
        let wall = Date().timeIntervalSince(start)

        // Zone table, fixed by the reference tile.
        let ref = tilesOut[refIndex].2
        let n = ref.encodedLuminance.count
        var zoneOf = [Int](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: 10)
        for i in 0..<n {
            let z = Swift.min(Swift.max(Int(Double(ref.encodedLuminance[i]) * 10), 0), 9)
            zoneOf[i] = z
            counts[z] += 1
        }
        func zoneMeans(_ p: [Float]) -> [Double] {
            guard p.count == n else { return [Double](repeating: .nan, count: 10) }
            var s = [Double](repeating: 0, count: 10)
            for i in 0..<n { s[zoneOf[i]] += Double(p[i]) }
            return (0..<10).map { counts[$0] > 0 ? s[$0] / Double(counts[$0]) : .nan }
        }
        let refEnc = zoneMeans(ref.encodedLuminance)
        let refLin = zoneMeans(ref.linearLuminance)
        func opt(_ d: Double) -> Double? { d.isFinite ? d : nil }
        var dEnc: [[Double?]] = [], dEV: [[Double?]] = []
        for t in tilesOut {
            let e = zoneMeans(t.2.encodedLuminance), l = zoneMeans(t.2.linearLuminance)
            dEnc.append((0..<10).map { opt(e[$0] - refEnc[$0]) })
            dEV.append((0..<10).map { z in
                opt(refLin[z] > 1e-7 && l[z] > 1e-7 ? log2(l[z] / refLin[z]) : .nan)
            })
        }

        var tiles: [SweepTile] = []
        for (i, t) in tilesOut.enumerated() {
            let de = t.2.lab.count == ref.lab.count ? Metrics.deltaE(ref, t.2) : nil
            let meanRef = tilesOut[refIndex].1.luminance
            tiles.append(SweepTile(
                value: values[i], effectiveValue: JSONValueBox(value: effective[i]),
                isReference: i == refIndex, metrics: t.1, deltaE2000VsReference: de,
                meanEncodedLuminanceDelta: t.1.luminance.meanEncoded - meanRef.meanEncoded,
                meanLinearLuminanceDeltaEV: meanRef.meanLinear > 0 && t.1.luminance.meanLinear > 0
                    ? log2(t.1.luminance.meanLinear / meanRef.meanLinear) : 0))
        }

        // The sheet.
        let sheetTiles = tilesOut.enumerated().map { i, t -> ContactSheet.Tile in
            var label = label(values[i])
            if case .number(let e) = effective[i], e != values[i] { label += " (=" + self.label(e) + ")" }
            return ContactSheet.Tile(image: t.0, label: label, highlighted: i == refIndex)
        }
        let (sw, sh, sheet) = ContactSheet.compose(sheetTiles, columns: columns,
                                                   header: key)
        try write(PNG.encode(width: sw, height: sh, rgb: sheet, space: settings.space), to: out)
        if let dir = args.string("tiles-dir") {
            for (i, t) in tilesOut.enumerated() {
                try write(PNG.encode(width: t.0.width, height: t.0.height, rgb: t.0.bytes,
                                     space: settings.space),
                          to: (dir as NSString).appendingPathComponent(
                              "tile_\(i)_\(label(values[i])).png"))
            }
        }

        print("swept \(key) over \(values.count) values at "
              + "\(prepared.image.width)x\(prepared.image.height) in \(fmt(wall, 2)) s → \(out)")
        print("reference: \(refRule)")
        print(pad("value", 10) + ["meanEnc", "dMeanEV", "dE00", "dE00p95", "clip%"]
                .map { " " + pad($0, 8) }.joined())
        for t in tiles {
            print(pad(label(t.value), 10) + String(format: " %8.4f %8.3f %8.3f %8.3f %8.2f",
                         t.metrics.luminance.meanEncoded, t.meanLinearLuminanceDeltaEV,
                         t.deltaE2000VsReference?.mean ?? .nan,
                         t.deltaE2000VsReference?.p95 ?? .nan,
                         t.metrics.clipping.highlightsPct.any))
        }
        print("zone table: mean Δ encoded luminance ×255 (codes), zones of the reference tile")
        var head = "     value"
        for z in 0..<10 { head += " " + pad("z\(z)", 6) }
        print(head)
        var cnt = "    pixels"
        for z in 0..<10 { cnt += String(format: " %6d", counts[z]) }
        print(cnt)
        for (i, row) in dEnc.enumerated() {
            var line = pad(label(values[i]), 10)
            for v in row { line += v.map { String(format: " %6.1f", $0 * 255) } ?? "      -" }
            print(line)
        }

        if let m = args.string("metrics") {
            let report = SweepReport(
                input: input, sourceSize: [prepared.sourceWidth, prepared.sourceHeight],
                key: key, values: values, referenceValue: values[refIndex],
                referenceRule: refRule,
                baseRecipe: try CanonicalJSON.canonicalRecipeJSON(base),
                settings: settingsDict(settings, longEdge: longEdge),
                tiles: tiles,
                zones: ZoneTable(
                    definition: "10 equal bins of the REFERENCE tile's encoded luminance "
                        + "(sRGB-encoded Y, 0-1); membership fixed by the reference; each row "
                        + "is one value, each entry that zone's mean change vs the reference",
                    zoneEdgesEncoded: (0...10).map { Double($0) / 10 },
                    referencePixelCounts: counts,
                    referenceMeanEncoded: refEnc.map(opt),
                    deltaEncoded: dEnc, deltaEV: dEV))
            try writeJSON(report, to: m)
            print("metrics → \(m)")
        }
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }

    static func label(_ v: Double) -> String {
        var s = CanonicalJSON.canonicalNumber(v)
        if v > 0 { s = "+" + s }
        return s
    }

    // MARK: keys

    static func keys(_ args: Args) throws {
        let list = try RecipeKeys.numericKeys()
        if args.flag("json") {
            try FileHandle.standardOutput.write(
                { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
                  return try e.encode(list) }())
            print("")
            return
        }
        print("# key path  default  [min … max]  (range source) — notes")
        for k in list {
            var line = k.path + "  "
            line += k.defaultValue.map(CanonicalJSON.canonicalNumber) ?? "(absent)"
            if let lo = k.min, let hi = k.max {
                line += "  [\(CanonicalJSON.canonicalNumber(lo)) … \(CanonicalJSON.canonicalNumber(hi))]"
            }
            if k.isInteger { line += "  integer" }
            if let s = k.rangeSource { line += "  (\(s))" }
            if let n = k.note { line += "  — \(n)" }
            print(line)
        }
    }

    // MARK: synth

    static func synth(_ args: Args) throws {
        let out = try args.require("out")
        let w = try args.int("width") ?? 960, h = try args.int("height") ?? 540
        try write(InputImage.encodeLFI(InputImage.synth(width: w, height: h)), to: out)
        print("wrote \(w)x\(h) synthetic frame → \(out)")
    }
}

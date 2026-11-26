// RenderLabRunner.swift
// Expands a manifest, renders through a backend, measures, and writes PNGs, stats,
// contact sheets and an index. The backend decides which renderer produces pixels:
// `PipelineRenderer` on macOS (shipping) or `ReferenceRenderer` (reference).

import Foundation

public struct RenderLabRender {
    public var image: RenderLabImage
    public var timings: [String: Double]
    public var note: String?
    public init(image: RenderLabImage, timings: [String: Double], note: String? = nil) {
        self.image = image
        self.timings = timings
        self.note = note
    }
}

public protocol RenderLabBackend: AnyObject {
    /// "shipping" or "reference"; printed on every sheet and in every stats file.
    var kind: String { get }
    /// The path this backend renders for a requested one; nil skips it.
    func resolve(path: String) -> String?
    func baseRecipe(photo: String, base: String) throws -> Recipe
    /// Chart patches at the delivered frame, or nil for a photograph.
    func patches(photo: String) -> [RenderLabPatch]?
    /// `crop` is the job's 1:1 crop ([x, y, w, h], unit, top-left), or nil.
    func render(photo: String, recipe: Recipe, path: String, longEdge: Int,
                draftLongEdge: Int?, crop: [Double]?) throws -> RenderLabRender
    func encodePNG(_ image: RenderLabImage) throws -> Data
}

public final class RenderLabRunner {

    public struct Row: Codable {
        public var job: String
        public var photo: String
        public var path: String
        public var label: String
        public var png: String?
        public var stats: String?
        public var width: Int = 0
        public var height: Int = 0
        public var ms: Double = 0
        public var lumaMean: Double = 0
        public var lumaMedian: Double = 0
        public var clip0: Double = 0
        public var clip255: Double = 0
        public var chroma: Double = 0
        public var dMeanAbs: Double?
        public var dLuma: Double?
        public var dHue: Double?
        public var dChroma: Double?
        public var yRatio: Double?
        public var patchRatio: Double?
        public var error: String?
    }

    public struct Series: Codable {
        public var job: String
        public var photo: String
        public var path: String
        public var renderer: String
        public var description: String
        public var sheet: String?
        public var rows: [Row]
    }

    public let backend: RenderLabBackend
    public let manifest: RenderLabManifest
    public let out: URL
    public private(set) var series: [Series] = []
    public private(set) var errors: [String] = []
    public var log: (String) -> Void = { print($0) }
    /// Photos for which this returns false are skipped with a log line.
    public var include: (String) -> Bool = { _ in true }
    /// Runs only every `count`-th (job, photo, path) series starting at `index`.
    public var shard: (index: Int, count: Int)?

    /// Where relative LUT paths in the manifest resolve first.
    public var manifestDirectory: URL?
    public private(set) var comparisons: [String] = []

    public init(backend: RenderLabBackend, manifest: RenderLabManifest, out: URL) {
        self.backend = backend
        self.manifest = manifest
        self.out = out
    }

    func registerLUTs() throws {
        for (ref, path) in manifest.luts {
            // CI copies manifests elsewhere, so committed manifests' relative paths are
            // also tried against renderlab/manifests under the working directory.
            var candidates = [URL(fileURLWithPath: path),
                              URL(fileURLWithPath: "renderlab/manifests").appendingPathComponent(path)]
            if let dir = manifestDirectory {
                candidates.insert(dir.appendingPathComponent(path), at: 0)
            }
            guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let cube = CreativeLUTImport.parse(try Data(contentsOf: url)) else {
                throw RenderLabError.badManifest("LUT \(ref): \(path) is missing or not a .cube")
            }
            CreativeLUTLibrary.shared.register(cube, for: ref)
        }
    }

    static func pct(_ f: Double) -> String { String(format: "%.2f%%", f * 100) }
    static func num(_ d: Double, _ p: Int = 1) -> String { String(format: "%.\(p)f", d) }

    private func write(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private struct StatsFile: Encodable {
        var renderer: String
        var path: String
        var job: String
        var photo: String
        var label: String
        var recipePatch: RenderLabJSON
        var recipeAdjusted: [String]
        var timingsMs: [String: Double]
        var note: String?
        var stats: RenderLabStats
        var deltaFromReference: RenderLabDelta?
    }

    public func run() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: out.appendingPathComponent("sheets"),
                               withIntermediateDirectories: true)
        let started = Date()
        try registerLUTs()
        var ordinal = -1
        for job in manifest.jobs {
            if job.crop != nil, backend.kind == "reference" {
                log("renderlab: skipping \(job.id): 1:1 crops need the shipping path "
                    + "(use crop plate ids on the reference path)")
                continue
            }
            for photo in job.photos {
                guard include(photo) else {
                    log("renderlab: skipping \(photo) in \(job.id) on the \(backend.kind) path")
                    continue
                }
                ordinal += 1
                if let shard, ordinal % shard.count != shard.index { continue }
                var images: [String: [String: RenderLabImage]] = [:]
                for requested in job.paths {
                    guard let path = backend.resolve(path: requested) else { continue }
                    if series.contains(where: { $0.job == job.id && $0.photo == photo && $0.path == path }) {
                        continue
                    }
                    let (one, pixels) = runSeries(job: job, photo: photo, path: path)
                    series.append(one)
                    images[path] = pixels
                }
                if let pair = job.compare, let a = images[pair[0]], let b = images[pair[1]] {
                    compare(job: job, photo: photo, pair: pair, a, b)
                }
            }
        }
        if !comparisons.isEmpty {
            let text = (["job\tphoto\tlabel\tpaths\tsizes\tdMAE\tp99\tmax\tdLuma\tdHue\tdChroma\tchanged"]
                + comparisons).joined(separator: "\n") + "\n"
            try text.write(to: out.appendingPathComponent("compare.tsv"), atomically: true,
                           encoding: .utf8)
            log("RENDERLAB_COMPARE_BEGIN")
            log(text)
            log("RENDERLAB_COMPARE_END")
        }
        let rows = series.flatMap(\.rows)
        let index: [String: RenderLabJSON] = [
            "manifest": .string(manifest.name),
            "renderer": .string(backend.kind),
            "seconds": .number(Date().timeIntervalSince(started)),
            "renders": .number(Double(rows.filter { $0.error == nil }.count)),
            "errors": .array(errors.map { .string($0) }),
        ]
        try write(index, to: out.appendingPathComponent("run.json"))
        try write(series, to: out.appendingPathComponent("index.json"))
        let table = Self.table(rows)
        try table.write(to: out.appendingPathComponent("summary.tsv"), atomically: true,
                        encoding: .utf8)
        log("RENDERLAB_TABLE_BEGIN")
        log(table)
        log("RENDERLAB_TABLE_END")
        log("renderlab: \(rows.count) renders, \(errors.count) errors, "
            + "\(Self.num(Date().timeIntervalSince(started))) s, renderer=\(backend.kind)")
    }

    public static func table(_ rows: [Row]) -> String {
        var lines = ["job\tphoto\tpath\tlabel\tsize\tms\tL_mean\tL_p50\tclip0\tclip255\tchroma\tdMAE\tdLuma\tdHue\tYratio\tpatchRatio\tpng"]
        for r in rows {
            if let e = r.error {
                lines.append("\(r.job)\t\(r.photo)\t\(r.path)\t\(r.label)\tERROR: \(e)")
                continue
            }
            func o(_ d: Double?, _ p: Int = 2) -> String { d.map { num($0, p) } ?? "-" }
            lines.append([r.job, r.photo, r.path, r.label, "\(r.width)x\(r.height)",
                          num(r.ms, 0), num(r.lumaMean), num(r.lumaMedian, 0), pct(r.clip0),
                          pct(r.clip255), num(r.chroma, 4), o(r.dMeanAbs), o(r.dLuma),
                          o(r.dHue), o(r.yRatio, 3), o(r.patchRatio, 3), r.png ?? "-"]
                            .joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Same recipe, two paths, matched scale: what was seen against what was delivered.
    private func compare(job: RenderLabManifest.Job, photo: String, pair: [String],
                         _ a: [String: RenderLabImage], _ b: [String: RenderLabImage]) {
        var cells: [RenderLabSheet.Cell] = []
        let labels = (["reference"] + job.variants.map(\.label)).filter { a[$0] != nil && b[$0] != nil }
        for label in labels {
            let ia = a[label]!
            var ib = b[label]!
            let sizes = "\(ia.width)x\(ia.height)/\(ib.width)x\(ib.height)"
            if ib.width != ia.width || ib.height != ia.height {
                ib = RenderLabSheet.downscale(ib, to: ia.width, ia.height)
            }
            let d = RenderLabDelta(ib, against: ia)
            comparisons.append([job.id, photo, label, "\(pair[1]) vs \(pair[0])", sizes,
                                Self.num(d.meanAbs, 2), Self.num(d.p99Abs, 0), "\(d.maxAbs)",
                                Self.num(d.meanLumaShift, 2), Self.num(d.meanAbsHueShift, 2),
                                Self.num(d.meanChromaShift, 4), Self.pct(d.changedFraction)]
                                .joined(separator: "\t"))
            cells.append(RenderLabSheet.Cell(image: ia, lines: ["\(label)", pair[0].uppercased()]))
            cells.append(RenderLabSheet.Cell(image: ib, lines: [
                pair[1].uppercased(),
                "ΔMAE \(Self.num(d.meanAbs, 2)) P99 \(Self.num(d.p99Abs, 0)) MAX \(d.maxAbs)",
                "ΔL \(Self.num(d.meanLumaShift, 2)) ΔH \(Self.num(d.meanAbsHueShift, 2))°"]))
        }
        guard !cells.isEmpty else { return }
        let photoSlug = RenderLabManifest.slug(photo.replacingOccurrences(of: "chart:", with: "chart-"))
        let sheet = RenderLabSheet.compose(
            title: ["\(job.id)  \(photo)  \(pair[0].uppercased()) vs \(pair[1].uppercased()) at matched scale",
                    job.description],
            cells: cells, columns: 4, tile: job.tile)
        do {
            try backend.encodePNG(sheet).write(to: out.appendingPathComponent(
                "sheets/\(job.id)__\(photoSlug)__\(pair[0])-vs-\(pair[1]).png"))
        } catch {
            errors.append("\(job.id) \(photo) compare sheet: \(error)")
        }
    }

    private func runSeries(job: RenderLabManifest.Job, photo: String, path: String)
        -> (Series, [String: RenderLabImage])
    {
        var pixels: [String: RenderLabImage] = [:]
        let photoSlug = RenderLabManifest.slug(photo.replacingOccurrences(of: "chart:", with: "chart-"))
        let dirRel = "\(job.id)/\(photoSlug)/\(path)"
        let dir = out.appendingPathComponent(dirRel)
        var result = Series(job: job.id, photo: photo, path: path, renderer: backend.kind,
                            description: job.description, sheet: nil, rows: [])
        func fail(_ label: String, _ error: Error) {
            let message = "\(job.id) \(photo) \(path) \(label): \(error)"
            errors.append(message)
            log("renderlab: ERROR \(message)")
            var row = Row(job: job.id, photo: photo, path: path, label: label)
            row.error = "\(error)"
            result.rows.append(row)
        }
        let base: Recipe
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            base = try backend.baseRecipe(photo: photo, base: job.base)
        } catch {
            fail("setup", error)
            return (result, pixels)
        }
        let patches = backend.patches(photo: photo)
        var cache: [(recipe: Recipe, render: RenderLabRender)] = []

        func render(_ patch: RenderLabJSON) throws -> (RenderLabRender, RecipePatch.Applied) {
            let applied = try RecipePatch.apply(patch, to: base)
            if let hit = cache.first(where: { $0.recipe == applied.recipe }) {
                return (hit.render, applied)
            }
            let r = try backend.render(photo: photo, recipe: applied.recipe, path: path,
                                       longEdge: job.longEdge, draftLongEdge: job.draftLongEdge,
                                       crop: job.crop)
            cache.append((applied.recipe, r))
            return (r, applied)
        }

        var reference: RenderLabRender?
        var cells: [RenderLabSheet.Cell] = []
        if let refPatch = job.reference {
            do {
                let (r, applied) = try render(refPatch)
                reference = r
                pixels["reference"] = r.image
                let stats = RenderLabStats(r.image, patches: patches)
                let name = "00_reference"
                try backend.encodePNG(r.image).write(to: dir.appendingPathComponent(name + ".png"))
                try write(StatsFile(renderer: backend.kind, path: path, job: job.id, photo: photo,
                                    label: "reference", recipePatch: refPatch,
                                    recipeAdjusted: applied.adjusted, timingsMs: r.timings,
                                    note: r.note, stats: stats, deltaFromReference: nil),
                          to: dir.appendingPathComponent(name + ".json"))
                var row = Self.row(job.id, photo, path, "reference", r, stats, nil)
                row.png = "\(dirRel)/\(name).png"
                row.stats = "\(dirRel)/\(name).json"
                result.rows.append(row)
                if job.y == nil {
                    cells.append(Self.cell("REFERENCE", r, stats, nil))
                }
            } catch {
                fail("reference", error)
            }
        }

        for (k, variant) in job.variants.enumerated() {
            let name = String(format: "%02d_", k + 1) + RenderLabManifest.slug(variant.label)
            do {
                let (r, applied) = try render(variant.patch)
                pixels[variant.label] = r.image
                let stats = RenderLabStats(r.image, patches: patches)
                let delta = reference.map { RenderLabDelta(r.image, against: $0.image, patches: patches) }
                try backend.encodePNG(r.image).write(to: dir.appendingPathComponent(name + ".png"))
                try write(StatsFile(renderer: backend.kind, path: path, job: job.id, photo: photo,
                                    label: variant.label, recipePatch: variant.patch,
                                    recipeAdjusted: applied.adjusted, timingsMs: r.timings,
                                    note: r.note, stats: stats, deltaFromReference: delta),
                          to: dir.appendingPathComponent(name + ".json"))
                var row = Self.row(job.id, photo, path, variant.label, r, stats, delta)
                row.png = "\(dirRel)/\(name).png"
                row.stats = "\(dirRel)/\(name).json"
                result.rows.append(row)
                log("renderlab: \(job.id) \(photo) \(path) \(variant.label) "
                    + "\(r.image.width)x\(r.image.height) \(Self.num(r.timings["total"] ?? 0, 0)) ms "
                    + "L=\(Self.num(stats.luma.mean)) clip255=\(Self.pct(stats.clipping.anyChannelAt255))"
                    + (applied.adjusted.isEmpty ? "" : " ADJUSTED: \(applied.adjusted)"))
                cells.append(Self.cell(variant.label, r, stats, delta))
            } catch {
                fail(variant.label, error)
            }
        }

        if job.isSeries, !cells.isEmpty {
            let pathName: String
            switch path {
            case "export": pathName = "SHIPPING EXPORT (PipelineRenderer.export)"
            case "settled": pathName = "SHIPPING VIEWER SETTLED (renderPreviewDelivery draft=false)"
            case "draft": pathName = "SHIPPING VIEWER DRAFT (renderPreviewDelivery draft=true)"
            default: pathName = "REFERENCE PATH - NOT SHIPPING (ReferenceRenderer)"
            }
            var recipeText = job.recipe.leaves().map { "\($0.path)=\($0.value.compactText)" }
                .joined(separator: " ")
            if recipeText.isEmpty { recipeText = "(none)" }
            let title = ["\(job.id)  \(photo)  \(pathName)",
                         "\(job.description)  base=\(job.base)  long edge \(job.longEdge)",
                         "fixed: " + String(recipeText.prefix(150))]
            let sheet = RenderLabSheet.compose(title: title, cells: cells, columns: job.columns,
                                               tile: job.tile)
            let sheetRel = "sheets/\(job.id)__\(photoSlug)__\(path).png"
            do {
                try backend.encodePNG(sheet).write(to: out.appendingPathComponent(sheetRel))
                result.sheet = sheetRel
            } catch {
                fail("sheet", error)
            }
        }
        do {
            try write(result, to: dir.appendingPathComponent("series.json"))
        } catch {
            fail("series", error)
        }
        return (result, pixels)
    }

    static func cell(_ label: String, _ r: RenderLabRender, _ s: RenderLabStats,
                     _ d: RenderLabDelta?) -> RenderLabSheet.Cell {
        var lines = [label,
                     "L \(num(s.luma.mean, 0)) P50 \(num(s.luma.median, 0)) C \(num(s.colour.meanChroma * 100, 1))",
                     "CLIP \(pct(s.clipping.anyChannelAt0)) / \(pct(s.clipping.anyChannelAt255))"]
        if let d, d.comparable {
            lines.append("ΔMAE \(num(d.meanAbs)) ΔL \(d.meanLumaShift >= 0 ? "+" : "")\(num(d.meanLumaShift))")
            lines.append("ΔH \(num(d.meanAbsHueShift))° ΔC \(num(d.meanChromaShift * 100, 2))"
                + (d.patchRatioMedian.map { " Y×\(num($0, 2))" } ?? ""))
        }
        return RenderLabSheet.Cell(image: r.image, lines: lines, histogram: s.histogram.luma)
    }

    static func row(_ job: String, _ photo: String, _ path: String, _ label: String,
                    _ r: RenderLabRender, _ s: RenderLabStats, _ d: RenderLabDelta?) -> Row {
        var row = Row(job: job, photo: photo, path: path, label: label)
        row.width = s.width
        row.height = s.height
        row.ms = r.timings["total"] ?? 0
        row.lumaMean = s.luma.mean
        row.lumaMedian = s.luma.median
        row.clip0 = s.clipping.anyChannelAt0
        row.clip255 = s.clipping.anyChannelAt255
        row.chroma = s.colour.meanChroma
        if let d, d.comparable {
            row.dMeanAbs = d.meanAbs
            row.dLuma = d.meanLumaShift
            row.dHue = d.meanAbsHueShift
            row.dChroma = d.meanChromaShift
            row.yRatio = d.linearYRatio
            row.patchRatio = d.patchRatioMedian
        }
        return row
    }
}

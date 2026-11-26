// RenderLabManifest.swift
// The job manifest the render lab reads, and its expansion into concrete renders.
// Format reference: renderlab/README.md.

import Foundation

public struct RenderLabManifest {

    public struct Axis {
        /// Recipe paths that all receive the same value (usually one).
        public var paths: [String]
        public var values: [RenderLabJSON]
        public var label: String
        /// The value the reference render uses; nil leaves the base recipe's value.
        public var neutral: RenderLabJSON?
    }

    public struct Variant {
        public var label: String
        public var patch: RenderLabJSON
        /// Grid position (column, row); sweeps use row 0.
        public var column: Int
        public var row: Int
    }

    public struct Job {
        public var id: String
        public var photos: [String]
        public var base: String
        public var recipe: RenderLabJSON
        public var paths: [String]
        public var longEdge: Int
        public var draftLongEdge: Int?
        public var tile: Int
        public var columns: Int
        public var x: Axis?
        public var y: Axis?
        public var variants: [Variant]
        /// The patch the deltas are measured against; nil for a single render.
        public var reference: RenderLabJSON?
        public var description: String
        /// Unit rectangle [x, y, w, h], top-left origin: a 1:1 crop (export: recipe crop
        /// at native scale; viewer: a region render at native scale).
        public var crop: [Double]?
        /// Two paths to render at matched scale and diff, e.g. ["settled", "export"].
        public var compare: [String]?

        public var isSeries: Bool { reference != nil }
    }

    public var name: String
    public var jobs: [Job]
    /// Creative LUT refs to register before rendering: ref -> .cube path (relative to
    /// the manifest's directory, or to the repository root).
    public var luts: [String: String] = [:]

    public static let knownPaths = ["export", "settled", "draft", "reference"]

    public init(data: Data, defaultName: String = "manifest") throws {
        let root: RenderLabJSON
        do {
            root = try RenderLabJSON.parse(data)
        } catch {
            throw RenderLabError.badManifest("not valid JSON: \(error)")
        }
        try self.init(json: root, defaultName: defaultName)
    }

    public init(json root: RenderLabJSON, defaultName: String = "manifest") throws {
        var rootObject: [String: RenderLabJSON]
        if let a = root.array {
            rootObject = ["jobs": .array(a)]
        } else if let o = root.object {
            rootObject = o
        } else {
            throw RenderLabError.badManifest("top level must be an object or an array of jobs")
        }
        if rootObject["jobs"] == nil, rootObject["id"] != nil {
            rootObject = ["jobs": .array([root])]
        }
        name = rootObject["name"]?.string ?? defaultName
        for (ref, path) in rootObject["luts"]?.object ?? [:] {
            guard let p = path.string else {
                throw RenderLabError.badManifest("luts.\(ref) must be a path string")
            }
            luts[ref] = p
        }
        let defaults = rootObject["defaults"]?.object ?? [:]
        guard let jobList = rootObject["jobs"]?.array, !jobList.isEmpty else {
            throw RenderLabError.badManifest("no jobs")
        }
        var seen = Set<String>()
        jobs = try jobList.enumerated().map { index, raw in
            let job = try Self.job(raw, index: index, defaults: defaults,
                                   sharedPhotos: rootObject["photos"])
            guard seen.insert(job.id).inserted else {
                throw RenderLabError.badManifest("duplicate job id \(job.id)")
            }
            return job
        }
    }

    static func slug(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+")
        var out = String(s.map { allowed.contains($0) ? $0 : "_" })
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }
        return String(out.prefix(80))
    }

    private static let knownJobKeys: Set<String> = [
        "id", "photo", "photos", "base", "recipe", "paths", "path", "longEdge",
        "draftLongEdge", "tile", "columns", "sweep", "grid", "variants", "description",
        "crop", "compare",
    ]

    private static func job(_ raw: RenderLabJSON, index: Int,
                            defaults: [String: RenderLabJSON],
                            sharedPhotos: RenderLabJSON?) throws -> Job {
        guard let o = raw.object else {
            throw RenderLabError.badManifest("job \(index) is not an object")
        }
        let unknown = Set(o.keys).subtracting(knownJobKeys)
        let id = o["id"]?.string ?? "job\(index)"
        guard unknown.isEmpty else {
            throw RenderLabError.badManifest("job \(id): unknown keys \(unknown.sorted()); "
                + "known: \(knownJobKeys.sorted())")
        }
        guard slug(id) == id else {
            throw RenderLabError.badManifest("job id \"\(id)\" may use only letters, digits, . _ - +")
        }
        func pick(_ key: String) -> RenderLabJSON? { o[key] ?? defaults[key] }

        var photos: [String] = []
        if let p = o["photo"]?.string { photos = [p] }
        if let list = o["photos"]?.array { photos += list.compactMap(\.string) }
        if photos.isEmpty, let list = (defaults["photos"] ?? sharedPhotos)?.array {
            photos = list.compactMap(\.string)
        }
        if photos.isEmpty, let p = defaults["photo"]?.string { photos = [p] }
        guard !photos.isEmpty else {
            throw RenderLabError.badManifest("job \(id): no photo")
        }

        var paths: [String] = ["export"]
        if let p = pick("paths") {
            paths = p.array?.compactMap(\.string) ?? (p.string.map { [$0] } ?? paths)
        } else if let p = pick("path")?.string {
            paths = [p]
        }
        for p in paths where !knownPaths.contains(p) {
            throw RenderLabError.badManifest("job \(id): unknown path \"\(p)\"; known: \(knownPaths)")
        }

        let base = pick("base")?.string ?? "imported"
        guard ["imported", "blank"].contains(base) else {
            throw RenderLabError.badManifest("job \(id): base must be \"imported\" or \"blank\"")
        }
        let recipe = try (o["recipe"] ?? .object([:])).normalizedPatch()
        guard recipe.object != nil else {
            throw RenderLabError.badManifest("job \(id): recipe must be an object")
        }
        let longEdge = Int(pick("longEdge")?.number ?? 1024)
        guard (16...8192).contains(longEdge) else {
            throw RenderLabError.badManifest("job \(id): longEdge \(longEdge) outside 16…8192")
        }
        let draftLongEdge = pick("draftLongEdge")?.number.map { Int($0) }
        var crop: [Double]?
        if let c = o["crop"] {
            let values = c.array?.compactMap(\.number)
                ?? ["x", "y", "w", "h"].compactMap { c[$0]?.number }
            guard values.count == 4, values[2] > 0, values[3] > 0,
                  values[0] >= 0, values[1] >= 0, values[0] + values[2] <= 1.0001,
                  values[1] + values[3] <= 1.0001 else {
                throw RenderLabError.badManifest("job \(id): crop must be [x, y, w, h] inside the unit square")
            }
            crop = values
        }
        var compare: [String]?
        if let c = o["compare"] {
            let list = c.array?.compactMap(\.string) ?? []
            guard list.count == 2, list.allSatisfy({ knownPaths.contains($0) }) else {
                throw RenderLabError.badManifest("job \(id): compare must name two paths, e.g. [\"settled\", \"export\"]")
            }
            compare = list
            for p in list where !paths.contains(p) { paths.append(p) }
        }
        let tile = Int(pick("tile")?.number ?? 320)
        let columnsAsked = pick("columns")?.number.map { Int($0) }

        var x: Axis?
        var y: Axis?
        var variants: [Variant] = []
        var reference: RenderLabJSON?

        if let sweep = o["sweep"] {
            x = try axis(sweep, job: id, what: "sweep")
        }
        if let grid = o["grid"] {
            guard x == nil else {
                throw RenderLabError.badManifest("job \(id): use sweep or grid, not both")
            }
            guard let gx = grid["x"], let gy = grid["y"] else {
                throw RenderLabError.badManifest("job \(id): grid needs x and y")
            }
            x = try axis(gx, job: id, what: "grid.x")
            y = try axis(gy, job: id, what: "grid.y")
        }
        if let list = o["variants"]?.array {
            guard x == nil else {
                throw RenderLabError.badManifest("job \(id): variants cannot be combined with sweep or grid")
            }
            for (i, v) in list.enumerated() {
                let patch = try (v["recipe"] ?? .object([:])).normalizedPatch()
                guard patch.object != nil else {
                    throw RenderLabError.badManifest("job \(id): variant \(i) recipe must be an object")
                }
                variants.append(Variant(label: v["label"]?.string ?? "v\(i)",
                                        patch: merge(recipe, patch), column: i, row: 0))
            }
            reference = recipe
        }

        if let x {
            reference = recipe
            for (path, value) in neutralLeaves(x) + (y.map(neutralLeaves) ?? []) {
                reference = try assigning(reference!, path, value)
            }
            let ys: [RenderLabJSON?] = y.map { $0.values.map { Optional($0) } } ?? [nil]
            for (row, yv) in ys.enumerated() {
                for (column, xv) in x.values.enumerated() {
                    var patch = recipe
                    for p in x.paths { patch = try assigning(patch, p, xv) }
                    var label = "\(x.label) \(signed(xv))"
                    if let y, let yv {
                        for p in y.paths { patch = try assigning(patch, p, yv) }
                        label += " / \(y.label) \(signed(yv))"
                    }
                    variants.append(Variant(label: label, patch: patch,
                                            column: column, row: row))
                }
            }
        }
        if variants.isEmpty {
            variants = [Variant(label: "render", patch: recipe, column: 0, row: 0)]
        }
        let columns = columnsAsked
            ?? (y != nil ? x!.values.count : Swift.min(variants.count + 1, 7))

        var description = id
        if let x { description = x.paths.joined(separator: "+") }
        if let y { description += " × " + y.paths.joined(separator: "+") }
        if let d = o["description"]?.string { description = d }

        return Job(id: id, photos: photos, base: base, recipe: recipe, paths: paths,
                   longEdge: longEdge, draftLongEdge: draftLongEdge, tile: tile,
                   columns: Swift.max(1, columns), x: x, y: y, variants: variants,
                   reference: reference, description: description, crop: crop,
                   compare: compare)
    }

    private static func neutralLeaves(_ axis: Axis) -> [(String, RenderLabJSON)] {
        guard let n = axis.neutral else { return [] }
        return axis.paths.map { ($0, n) }
    }

    static func signed(_ v: RenderLabJSON) -> String {
        if let d = v.number { return d > 0 ? "+" + RenderLabJSON.format(d) : RenderLabJSON.format(d) }
        if let s = v.string { return s.split(separator: "/").last.map(String.init) ?? s }
        return v.compactText
    }

    private static func axis(_ raw: RenderLabJSON, job: String, what: String) throws -> Axis {
        var paths: [String] = []
        if let p = raw["path"]?.string { paths = [p] }
        if let list = raw["paths"]?.array { paths += list.compactMap(\.string) }
        guard !paths.isEmpty else {
            throw RenderLabError.badManifest("job \(job): \(what) needs path or paths")
        }
        var values = raw["values"]?.array ?? []
        if values.isEmpty, let from = raw["from"]?.number, let to = raw["to"]?.number {
            let steps = Swift.max(2, Int(raw["steps"]?.number ?? 5))
            values = (0..<steps).map { i in
                let v = from + (to - from) * Double(i) / Double(steps - 1)
                return .number((v * 1e6).rounded() / 1e6)
            }
        }
        guard !values.isEmpty else {
            throw RenderLabError.badManifest("job \(job): \(what) needs values, or from/to/steps")
        }
        let label = raw["label"]?.string
            ?? paths[0].split(separator: ".").suffix(2).joined(separator: ".")
        return Axis(paths: paths, values: values, label: label, neutral: raw["neutral"])
    }

    static func assigning(_ patch: RenderLabJSON, _ path: String, _ value: RenderLabJSON) throws
        -> RenderLabJSON
    {
        var copy = patch
        try copy.assign(value, at: path)
        return copy
    }

    /// Deep merge; `top` wins. Dotted keys stay dotted and are resolved at apply time.
    static func merge(_ base: RenderLabJSON, _ top: RenderLabJSON) -> RenderLabJSON {
        guard case .object(var a) = base, case .object(let b) = top else { return top }
        for (k, v) in b {
            if let existing = a[k], existing.object != nil, v.object != nil {
                a[k] = merge(existing, v)
            } else {
                a[k] = v
            }
        }
        return .object(a)
    }
}

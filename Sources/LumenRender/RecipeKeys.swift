// RecipeKeys.swift — setting a recipe value by dotted key path, generically, through
// the recipe's canonical JSON tree; and the `keys` listing.

import Foundation
import LumenCore

enum RecipeKeys {

    // MARK: Loading

    static func loadRecipe(path: String?) throws -> Recipe {
        guard let path else { return Recipe() }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw InputError.message("cannot read recipe '\(path)'")
        }
        do {
            return try CanonicalJSON.decodeRecipe(from: data)
        } catch {
            throw InputError.message("recipe '\(path)' does not decode: \(error)")
        }
    }

    // MARK: Paths

    static func segments(_ path: String) -> [String] {
        path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    static func value(at path: [String], in tree: JSONValue) -> JSONValue? {
        var node = tree
        for seg in path {
            switch node {
            case .object(let o):
                guard let next = o[seg] else { return nil }
                node = next
            case .array(let a):
                guard let i = Int(seg), a.indices.contains(i) else { return nil }
                node = a[i]
            default:
                return nil
            }
        }
        return node
    }

    /// Write `value` at `path`, creating missing OBJECT levels (an optional subtree such
    /// as `look.grain` is absent until set). Array indices must exist.
    static func setting(_ value: JSONValue, at path: [String], in tree: JSONValue,
                        fullPath: String) throws -> JSONValue {
        guard let head = path.first else { return value }
        let rest = Array(path.dropFirst())
        switch tree {
        case .object(var o):
            let child = o[head] ?? (rest.isEmpty ? .null : .object([:]))
            if case .null = child, !rest.isEmpty {
                o[head] = try setting(value, at: rest, in: .object([:]), fullPath: fullPath)
            } else {
                o[head] = try setting(value, at: rest, in: child, fullPath: fullPath)
            }
            return .object(o)
        case .array(var a):
            guard let i = Int(head), a.indices.contains(i) else {
                throw InputError.message("'\(fullPath)': index '\(head)' is outside an "
                    + "array of \(a.count)")
            }
            a[i] = try setting(value, at: rest, in: a[i], fullPath: fullPath)
            return .array(a)
        default:
            throw InputError.message("'\(fullPath)': '\(head)' descends into a scalar")
        }
    }

    static func parseValue(_ text: String) -> JSONValue {
        if let d = Double(text), d.isFinite { return .number(d) }
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if text == "null" { return .null }
        return .string(text)
    }

    /// Set one key: tree → write → decode → re-encode → read back. Returns the recipe and
    /// the value the model actually holds at the path afterwards.
    static func assign(_ recipe: Recipe, path: String, to value: JSONValue) throws
        -> (recipe: Recipe, effective: JSONValue) {
        let segs = segments(path)
        guard !segs.isEmpty, !segs.contains(where: \.isEmpty) else {
            throw InputError.message("'\(path)' is not a key path")
        }
        if case .number(let d) = value, d != d.rounded(),
           Ranges.integerFields.contains(where: { Ranges.matches($0, path) }) {
            throw InputError.message("'\(path)' is an integer field; \(d) is not an integer")
        }
        let tree = try CanonicalJSON.tree(of: recipe)
        let written = try setting(value, at: segs, in: tree, fullPath: path)
        let decoded: Recipe
        do {
            decoded = try CanonicalJSON.decodeRecipe(
                from: Data(CanonicalJSON.serialize(written).utf8))
        } catch {
            throw InputError.message("'\(path)' = \(describe(value)): the recipe model "
                + "rejects it (\(shortError(error)))")
        }
        let back = try CanonicalJSON.tree(of: decoded)
        guard let effective = RecipeKeys.value(at: segs, in: back) else {
            throw InputError.message("'\(path)' does not exist in the recipe model: the "
                + "decoder ignored it." + suggestion(for: path))
        }
        return (decoded, effective)
    }

    static func describe(_ v: JSONValue) -> String {
        CanonicalJSON.serialize(v)
    }

    private static func shortError(_ e: Error) -> String {
        if let d = e as? DecodingError {
            switch d {
            case .typeMismatch(let t, let c): return "type mismatch, expected \(t) at "
                + c.codingPath.map(\.stringValue).joined(separator: ".")
            case .dataCorrupted(let c): return c.debugDescription
            case .keyNotFound(let k, _): return "missing key \(k.stringValue)"
            case .valueNotFound(let t, _): return "missing \(t)"
            @unknown default: return "\(d)"
            }
        }
        return "\(e)"
    }

    private static func suggestion(for path: String) -> String {
        let all = (try? numericKeys())?.map(\.path) ?? []
        let ranked = all.map { ($0, editDistance($0.lowercased(), path.lowercased())) }
            .filter { $0.1 <= 4 }.sorted { $0.1 < $1.1 }.prefix(5).map(\.0)
        let last = segments(path).last?.lowercased() ?? ""
        let near = ranked.isEmpty
            ? Array(all.filter { $0.lowercased().hasSuffix("." + last) }.prefix(8)) : ranked
        return near.isEmpty ? " Run `lumen-render keys` for the list."
            : " Did you mean: " + near.joined(separator: ", ") + " ?"
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf8), b = Array(b.utf8)
        var row = Array(0...b.count)
        for i in 1...Swift.max(a.count, 1) where !a.isEmpty {
            var prev = row[0]
            row[0] = i
            for j in 1...Swift.max(b.count, 1) where !b.isEmpty {
                let cur = row[j]
                row[j] = Swift.min(row[j] + 1, row[j - 1] + 1,
                                   prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    // MARK: Listing

    struct KeyInfo: Codable {
        let path: String
        /// The default recipe's value, nil when the key lives in an optional subtree that
        /// a default recipe does not carry.
        let defaultValue: Double?
        let optional: Bool
        let isInteger: Bool
        let min: Double?
        let max: Double?
        let rangeSource: String?
        let note: String?
    }

    /// A recipe with every optional numeric subtree populated, so their keys can be
    /// listed. The values are the decoders' defaults (or the preset's own numbers).
    static func probeRecipe() -> Recipe {
        var r = Recipe()
        r.develop.raw.temp = 5500
        r.develop.raw.tint = 0
        r.look.filmLab = FilmLab(stock: "lumen/portra400", amount: 0, halationSize: 1.0,
                                 halationRedness: 50)
        r.look.bw = BlackAndWhite(enabled: false)
        r.look.grain = CreativeGrain()
        let p = DisplayTransformParams.preset(named: r.look.render.preset)
        r.look.render.contrast = p.contrast
        r.look.render.skew = p.skew
        r.look.render.huePreservation = p.huePreservation
        r.look.render.blackTarget = p.blackTarget
        r.look.render.whiteTarget = p.whiteTarget
        r.develop.detail.capture.radius = 0.8
        r.develop.detail.capture.amount = 0
        return r
    }

    static func numericKeys() throws -> [KeyInfo] {
        let defaults = try CanonicalJSON.tree(of: Recipe())
        let probe = try CanonicalJSON.tree(of: probeRecipe())
        var leaves: [(String, Double)] = []
        collect(probe, prefix: "", into: &leaves)
        let skip: Set<String> = ["pipelineVersion", "develop.raw.decoderVersion"]
        return leaves.filter { !skip.contains($0.0) }.map { path, probeValue in
            var dv: Double? = nil
            if case .number(let d)? = value(at: segments(path), in: defaults) { dv = d }
            let range = Ranges.lookup(path)
            let intField = Ranges.integerFields.contains { Ranges.matches($0, path) }
            return KeyInfo(path: path, defaultValue: dv, optional: dv == nil,
                           isInteger: intField,
                           min: range?.min, max: range?.max, rangeSource: range?.source,
                           note: range?.note ?? Ranges.unrenderedNote(path) ?? (dv == nil
                               ? "absent by default; setting it creates the subtree "
                                 + "(probe value \(CanonicalJSON.canonicalNumber(probeValue)))"
                               : nil))
        }
    }

    private static func collect(_ node: JSONValue, prefix: String,
                                into out: inout [(String, Double)]) {
        switch node {
        case .number(let d): out.append((prefix, d))
        case .object(let o):
            for k in o.keys.sorted() {
                collect(o[k]!, prefix: prefix.isEmpty ? k : prefix + "." + k, into: &out)
            }
        case .array(let a):
            for (i, v) in a.enumerated() { collect(v, prefix: prefix + ".\(i)", into: &out) }
        default: break
        }
    }
}

/// Slider ranges. The recipe model states almost none of these as values — they live in
/// field comments (Recipe.swift, RecipeLook.swift), in the panels, and in the proof
/// registry (Tests/LumenCoreTests/Proof/ProofRegistry.swift, which sweeps each control
/// over its PANEL range). This table transcribes them; where LumenCore exposes the number
/// as a constant, the constant is read instead of copied. `*` matches one path segment.
enum Ranges {
    struct Range {
        let min: Double
        let max: Double
        let source: String
        let note: String?
    }

    static let integerFields = ["look.printerLights.*"]

    static let table: [(String, Double, Double, String, String?)] = [
        ("develop.raw.temp", 2000, 50000, "Recipe.swift RawParams", "Kelvin; nil = as shot"),
        ("develop.raw.tint", -150, 150, "Recipe.swift RawParams", "soft ±150, hard ±300"),
        ("develop.tone.exposure", -5, 5, "ProofRegistry (panel)", "hard ±10"),
        ("develop.tone.contrast", -100, 100, "ProofRegistry", nil),
        ("develop.tone.highlights", -100, 100, "ProofRegistry", nil),
        ("develop.tone.shadows", -100, 100, "ProofRegistry", nil),
        ("develop.tone.whites", -100, 100, "ProofRegistry", nil),
        ("develop.tone.blacks", -100, 100, "ProofRegistry", nil),
        ("develop.tone.contrastPivot", -4, 4, "ProofRegistry", "EV; needs contrast ≠ 0"),
        ("develop.zones.*.ev", -3, 3, "ProofRegistry", "stops"),
        ("develop.zones.pivots.*", 0, 1, "Recipe.swift Zones", "ascending"),
        ("develop.curve.parametric.highlights", -100, 100, "Recipe.swift ParametricCurve", nil),
        ("develop.curve.parametric.lights", -100, 100, "Recipe.swift ParametricCurve", nil),
        ("develop.curve.parametric.darks", -100, 100, "Recipe.swift ParametricCurve", nil),
        ("develop.curve.parametric.shadows", -100, 100, "Recipe.swift ParametricCurve", nil),
        ("develop.curve.parametric.splits.*", 0, 1, "Recipe.swift ParametricCurve", nil),
        ("develop.color.vibrance", -100, 100, "Recipe.swift ColorAdjust", nil),
        ("develop.color.saturation", -100, 100, "Recipe.swift ColorAdjust", nil),
        ("develop.color.density", 0, 100, "Recipe.swift ColorAdjust", nil),
        ("develop.color.protectSkin", 0, 100, "Recipe.swift ColorAdjust", nil),
        ("develop.mixer.uniformity", 0, 100, "Recipe.swift Mixer", nil),
        ("develop.mixer.bands.*.hue", -100, 100, "Recipe.swift MixerBand", nil),
        ("develop.mixer.bands.*.sat", -100, 100, "ProofRegistry", nil),
        ("develop.mixer.bands.*.lum", -100, 100, "ProofRegistry", nil),
        ("develop.detail.texture", -100, 100, "Recipe.swift Detail", nil),
        ("develop.detail.clarity", -100, 100, "ProofRegistry", nil),
        ("develop.detail.dehaze", -100, 100, "ProofRegistry", nil),
        ("develop.detail.sharpen.amount", 0, 150, "Recipe.swift ManualSharpen", nil),
        ("develop.detail.sharpen.radius", 0.5, 3, "Recipe.swift ManualSharpen", nil),
        ("develop.detail.sharpen.detail", 0, 100, "Recipe.swift ManualSharpen", nil),
        ("develop.detail.sharpen.masking", 0, 100, "Recipe.swift ManualSharpen", nil),
        ("develop.detail.sharpen.haloSuppression", 0, 100, "Recipe.swift ManualSharpen", nil),
        ("develop.denoise.amount", 0, 100, "Recipe.swift Denoise", "AI blend; no AI here"),
        ("develop.denoise.classic.*", 0, 100, "Recipe.swift ClassicNR", "S3, needs --iso"),
        ("look.vignette", DetailEngine.vignetteAmountRange.lowerBound,
         DetailEngine.vignetteAmountRange.upperBound, "DetailEngine.vignetteAmountRange", "EV"),
        ("look.vignetteFeather", 0, 100, "RecipeLook.swift Look", nil),
        ("look.wheels.*.hue", 0, 360, "RecipeLook.swift Wheel", "degrees"),
        ("look.wheels.*.sat", 0, 1, "RecipeLook.swift Wheel", nil),
        ("look.wheels.*.lum", -1, 1, "RecipeLook.swift Wheel", nil),
        ("look.wheels.blending", 0, 100, "RecipeLook.swift GradingWheels", nil),
        ("look.wheels.balance", -100, 100, "RecipeLook.swift GradingWheels", nil),
        ("look.wheels.pivots.0", 0, 0.65, "ProofRegistry", "shadow pivot"),
        ("look.wheels.pivots.1", 0.35, 1, "ProofRegistry", "highlight pivot"),
        ("look.wheels.colorBalance.hueShift", -180, 180, "GradeEngine ColorBalanceParams", nil),
        ("look.wheels.colorBalance.vibrance", -100, 100, "GradeEngine ColorBalanceParams", nil),
        ("look.wheels.colorBalance.*.*", -100, 100, "ProofRegistry", nil),
        ("look.printerLights.master", -GradeEngine.masterPointLimit,
         GradeEngine.masterPointLimit, "GradeEngine.masterPointLimit", "integer points"),
        ("look.printerLights.*", -GradeEngine.trimPointLimit, GradeEngine.trimPointLimit,
         "GradeEngine.trimPointLimit", "integer points"),
        ("look.primaries.*", -100, 100, "ProofRegistry", nil),
        ("look.bw.bands.*", -100, 100, "RecipeLook.swift BlackAndWhite",
         "needs look.bw.enabled=true"),
        ("look.filmLab.amount", 0, 100, "RecipeLook.swift FilmLab", "strength"),
        ("look.filmLab.exposure", -2, 3, "ProofRegistry", nil),
        ("look.filmLab.pushPull", -1, 2, "RecipeLook.swift FilmLab", "stops"),
        ("look.filmLab.halation", 0, 100, "RecipeLook.swift FilmLab", nil),
        ("look.filmLab.halationSize", 0.5, 2, "ProofRegistry", nil),
        ("look.filmLab.halationRedness", 0, 100, "ProofRegistry", nil),
        ("look.filmLab.grain.amount", 0, 100, "RecipeLook.swift FilmGrain", nil),
        ("look.filmLab.grain.size", 0.5, 2, "ProofRegistry", nil),
        ("look.grain.amount", 0, 100, "Recipe.swift CreativeGrain", nil),
        ("look.grain.size", 0, 100, "Recipe.swift CreativeGrain", nil),
        ("look.grain.roughness", 0, 100, "Recipe.swift CreativeGrain", nil),
        ("look.render.contrast", 0.1, 10, "RecipeLook.swift RenderParams", "log-scaled"),
        ("look.render.skew", -1, 1, "RecipeLook.swift RenderParams", nil),
        ("look.render.huePreservation", 0, 100, "RecipeLook.swift RenderParams", nil),
        ("look.render.blackTarget", 0, 15, "RecipeLook.swift RenderParams", "% of SDR white"),
        ("look.render.whiteTarget", 100, 400, "RecipeLook.swift RenderParams",
         "% of SDR white; above 100 is HDR and an SDR PNG clips"),
    ]

    /// Keys whose stage this headless path does not run, so a sweep of them is flat by
    /// construction rather than by defect.
    static func unrenderedNote(_ path: String) -> String? {
        if path.hasPrefix("develop.geometry.") {
            return "geometry is not rendered by the reference path (GEO-17)"
        }
        if path.hasPrefix("develop.heal.") { return "needs heal spots/strokes" }
        if path.hasPrefix("develop.detail.capture.") {
            return "capture sharpening (S4) runs upstream of ReferenceRenderer, not here"
        }
        if path.hasPrefix("develop.denoise.raw.") { return "RAW-domain denoise, not here" }
        return nil
    }

    static func matches(_ pattern: String, _ path: String) -> Bool {
        let p = pattern.split(separator: "."), s = path.split(separator: ".")
        guard p.count == s.count else { return false }
        return zip(p, s).allSatisfy { $0 == "*" || $0 == $1 }
    }

    static func lookup(_ path: String) -> Range? {
        // Exact entries win over wildcard ones.
        if let e = table.first(where: { $0.0 == path }) {
            return Range(min: e.1, max: e.2, source: e.3, note: e.4)
        }
        if let e = table.first(where: { matches($0.0, path) }) {
            return Range(min: e.1, max: e.2, source: e.3, note: e.4)
        }
        return nil
    }
}

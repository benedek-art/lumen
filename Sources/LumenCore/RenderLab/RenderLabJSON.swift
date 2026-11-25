// RenderLabJSON.swift
// A JSON value type and the sparse recipe patch the render lab applies.
// A patch is applied to the recipe's own Codable encoding, so field names are the
// recipe's JSON keys and cannot drift from the model.

import Foundation

public enum RenderLabJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RenderLabJSON])
    case object([String: RenderLabJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool before Double: a JSON number must not decode as a Bool.
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([RenderLabJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: RenderLabJSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public static func parse(_ data: Data) throws -> RenderLabJSON {
        try JSONDecoder().decode(RenderLabJSON.self, from: data)
    }

    public static func of<T: Encodable>(_ value: T) throws -> RenderLabJSON {
        try parse(JSONEncoder().encode(value))
    }

    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    public var object: [String: RenderLabJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }
    public var array: [RenderLabJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }
    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var number: Double? {
        if case .number(let d) = self { return d }
        return nil
    }
    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public subscript(key: String) -> RenderLabJSON? {
        object?[key]
    }

    /// Compact text for labels and logs.
    public var compactText: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let d): return RenderLabJSON.format(d)
        case .string(let s): return s
        case .array(let a): return "[" + a.map(\.compactText).joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { "\($0):\(o[$0]!.compactText)" }
                .joined(separator: ",") + "}"
        }
    }

    public static func format(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e9 { return String(Int(d)) }
        var s = String(format: "%.3f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    // MARK: - Paths

    static func segments(_ path: String) -> [String] {
        path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    /// Value at a dotted path; numeric segments index arrays.
    public func value(at path: String) -> RenderLabJSON? {
        var node: RenderLabJSON? = self
        for seg in Self.segments(path) {
            guard let current = node else { return nil }
            switch current {
            case .object(let o): node = o[seg]
            case .array(let a):
                guard let i = Int(seg), a.indices.contains(i) else { return nil }
                node = a[i]
            default: return nil
            }
        }
        return node
    }

    /// Set a value at a dotted path, creating objects on the way. Array indices must exist.
    public mutating func assign(_ value: RenderLabJSON, at path: String) throws {
        try Self.assign(value, segments: Self.segments(path)[...], in: &self, path: path)
    }

    private static func assign(_ value: RenderLabJSON, segments: ArraySlice<String>,
                            in node: inout RenderLabJSON, path: String) throws {
        guard let head = segments.first else { node = value; return }
        let rest = segments.dropFirst()
        switch node {
        case .array(var a):
            guard let i = Int(head), a.indices.contains(i) else {
                throw RenderLabError.badPatch("\(path): index \(head) is not in an array of \(a.count)")
            }
            try assign(value, segments: rest, in: &a[i], path: path)
            node = .array(a)
        case .object(var o):
            var child = o[head] ?? .null
            if case .null = child, !rest.isEmpty { child = .object([:]) }
            try assign(value, segments: rest, in: &child, path: path)
            o[head] = child
            node = .object(o)
        case .null:
            var child: RenderLabJSON = rest.isEmpty ? .null : .object([:])
            try assign(value, segments: rest, in: &child, path: path)
            node = .object([head: child])
        default:
            throw RenderLabError.badPatch("\(path): \(head) is inside a \(node.compactText), not an object")
        }
    }

    /// Flatten a patch to (dotted path, leaf) pairs. Keys may themselves be dotted.
    /// Arrays are leaves (they replace), objects recurse.
    public func leaves(prefix: String = "") -> [(path: String, value: RenderLabJSON)] {
        guard case .object(let o) = self else { return [(prefix, self)] }
        var out: [(String, RenderLabJSON)] = []
        for key in o.keys.sorted() {
            let path = prefix.isEmpty ? key : prefix + "." + key
            let child = o[key]!
            if case .object(let inner) = child, !inner.isEmpty {
                out.append(contentsOf: child.leaves(prefix: path))
            } else {
                out.append((path, child))
            }
        }
        return out
    }

    /// The same patch with every dotted key expanded into nested objects, so later
    /// writes to a path replace earlier ones whatever spelling either used.
    public func normalizedPatch() throws -> RenderLabJSON {
        guard object != nil else { return self }
        var out: RenderLabJSON = .object([:])
        for leaf in leaves() { try out.assign(leaf.value, at: leaf.path) }
        return out
    }

    func approximatelyEquals(_ other: RenderLabJSON) -> Bool {
        switch (self, other) {
        case (.number(let a), .number(let b)):
            return abs(a - b) <= 1e-9 * Swift.max(1, abs(a), abs(b))
        case (.array(let a), .array(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.approximatelyEquals($1) }
        case (.object(let a), .object(let b)):
            return a.keys.allSatisfy { k in b[k].map { a[k]!.approximatelyEquals($0) } ?? false }
        default:
            return self == other
        }
    }
}

public enum RenderLabError: Error, CustomStringConvertible {
    case badManifest(String)
    case badPatch(String)
    case missingPhoto(String)
    case render(String)

    public var description: String {
        switch self {
        case .badManifest(let s): return "manifest: \(s)"
        case .badPatch(let s): return "recipe patch: \(s)"
        case .missingPhoto(let s): return "photo: \(s)"
        case .render(let s): return "render: \(s)"
        }
    }
}

/// Applying a sparse patch to a recipe.
public enum RecipePatch {

    /// What an optional block holds when a patch creates it.
    public static var optionalTemplate: Recipe {
        var t = Recipe()
        t.look.filmLab = FilmLab(stock: "", amount: 100, grain: FilmGrain(size: 1, amount: 0))
        t.look.grain = CreativeGrain()
        t.look.bw = BlackAndWhite()
        return t
    }

    public struct Applied {
        public var recipe: Recipe
        /// Leaves whose value the recipe decoder changed (clamped, normalised).
        public var adjusted: [String]
    }

    /// `patch` is an object whose keys are recipe JSON keys, nested or dotted
    /// ("develop.tone.exposure"). Unknown paths throw: the recipe decoder is tolerant
    /// and would otherwise drop a typo silently.
    public static func apply(_ patch: RenderLabJSON, to base: Recipe) throws -> Applied {
        guard patch.object != nil else {
            throw RenderLabError.badPatch("a patch must be a JSON object, got \(patch.compactText)")
        }
        var tree = try RenderLabJSON.of(base)
        let seed = try RenderLabJSON.of(optionalTemplate)
        let leaves = patch.leaves()
        for leaf in leaves {
            // An absent optional block (film lab, grain, B&W) is seeded whole, so a patch
            // can index into its arrays ("look.bw.bands.2").
            let segments = RenderLabJSON.segments(leaf.path)
            for n in 1..<Swift.max(1, segments.count) {
                let prefix = segments.prefix(n).joined(separator: ".")
                if tree.value(at: prefix) == nil || tree.value(at: prefix) == .null,
                   let block = seed.value(at: prefix), block.object != nil {
                    try tree.assign(block, at: prefix)
                }
            }
            try tree.assign(leaf.value, at: leaf.path)
        }
        let recipe: Recipe
        do {
            recipe = try tree.decoded(as: Recipe.self)
        } catch {
            throw RenderLabError.badPatch("the patched recipe does not decode: \(error)")
        }
        let echoed = try RenderLabJSON.of(recipe)
        var adjusted: [String] = []
        for leaf in leaves {
            guard let got = echoed.value(at: leaf.path) else {
                if case .null = leaf.value { continue }
                throw RenderLabError.badPatch(
                    "\(leaf.path) is not a recipe field (the decoder dropped it). "
                        + "Field names are listed in renderlab/CONTROLS.md")
            }
            if !got.approximatelyEquals(leaf.value) {
                adjusted.append("\(leaf.path): asked \(leaf.value.compactText), recipe holds \(got.compactText)")
            }
        }
        return Applied(recipe: recipe, adjusted: adjusted)
    }
}

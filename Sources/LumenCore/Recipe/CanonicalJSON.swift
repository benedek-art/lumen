// CanonicalJSON.swift
// Canonical + sparse recipe serialization (docs/15 §15.4 rule 2):
//  - sparse: only keys that differ from the default Recipe serialize, so adding a
//    field in a future version does not change the fingerprint of unedited photos;
//  - canonical: object keys sorted, numbers formatted by one fixed rule, no whitespace
//    variance — so `recipe_fp` is stable and every cache keyed on it invalidates
//    exactly when content changes.
//
// The number rule: integers render without a fraction; other finite doubles render
// with C printf "%.6g" (shared by Swift's String(format:) and the Python reference
// generator, so fixtures match cross-language); "-0" normalizes to "0"; non-finite
// numbers are a programming error and trap in debug.
//
// The Python mirror of this file is scripts/gen-fixtures.py — change both together.

import Foundation

/// A portable JSON tree. Decoding goes through Codable (not JSONSerialization) so
/// Bool-vs-number distinction is identical on macOS and Linux.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let b = try? single.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? single.decode(Double.self) {
            self = .number(d)
        } else if let s = try? single.decode(String.self) {
            self = .string(s)
        } else if let a = try? single.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? single.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: single, debugDescription: "Unrecognized JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let b): try single.encode(b)
        case .number(let d): try single.encode(d)
        case .string(let s): try single.encode(s)
        case .array(let a): try single.encode(a)
        case .object(let o): try single.encode(o)
        }
    }
}

public enum CanonicalJSON {

    /// Encode any Encodable into a JSONValue tree.
    public static func tree<T: Encodable>(of value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// The canonical serialized form of a tree: sorted keys, fixed number formatting,
    /// no insignificant whitespace.
    public static func serialize(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    /// Sparse form of `value` against `defaults`: any object key whose subtree deep-equals
    /// the corresponding subtree in `defaults` is dropped. Arrays are atomic (kept or
    /// dropped whole). Top level must be an object.
    public static func sparse(_ value: JSONValue, defaults: JSONValue) -> JSONValue {
        guard case .object(let obj) = value, case .object(let defObj) = defaults else {
            return value
        }
        var pruned: [String: JSONValue] = [:]
        for (key, sub) in obj {
            if let defSub = defObj[key] {
                if sub == defSub { continue }
                if case .object = sub, case .object = defSub {
                    let sparsed = sparse(sub, defaults: defSub)
                    if case .object(let inner) = sparsed, inner.isEmpty { continue }
                    pruned[key] = sparsed
                    continue
                }
            }
            pruned[key] = sub
        }
        return .object(pruned)
    }

    /// Canonical sparse serialization of a full recipe: the string that gets fingerprinted
    /// and stored in the catalog's `edit.recipe` column.
    public static func canonicalRecipeJSON(_ recipe: Recipe) throws -> String {
        let full = try tree(of: recipe)
        let defaults = try tree(of: Recipe())
        var sparsed = sparse(full, defaults: defaults)
        // pipelineVersion always serializes, sparse or not: readers must know how to render.
        if case .object(var obj) = sparsed {
            obj["pipelineVersion"] = .number(Double(recipe.pipelineVersion))
            sparsed = .object(obj)
        }
        return serialize(sparsed)
    }

    /// Decode a recipe from (possibly sparse) JSON: missing keys fall back to defaults,
    /// unknown keys are ignored — forward compatibility for free.
    public static func decodeRecipe(from json: Data) throws -> Recipe {
        let sparseTree = try JSONDecoder().decode(JSONValue.self, from: json)
        let defaults = try tree(of: Recipe())
        let merged = merge(defaults: defaults, overlay: sparseTree)
        let data = Data(serialize(merged).utf8)
        return try JSONDecoder().decode(Recipe.self, from: data)
    }

    /// Deep-merge an overlay onto defaults: overlay object keys replace or recurse;
    /// arrays and scalars replace wholesale.
    static func merge(defaults: JSONValue, overlay: JSONValue) -> JSONValue {
        guard case .object(let defObj) = defaults, case .object(let ovObj) = overlay else {
            return overlay
        }
        var result = defObj
        for (key, ovSub) in ovObj {
            if let defSub = defObj[key], case .object = defSub, case .object = ovSub {
                result[key] = merge(defaults: defSub, overlay: ovSub)
            } else {
                result[key] = ovSub
            }
        }
        return .object(result)
    }

    // MARK: - Writer

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .number(let d):
            out += canonicalNumber(d)
        case .string(let s):
            writeEscaped(s, into: &out)
        case .array(let a):
            out += "["
            for (i, item) in a.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            // Sort by Unicode code point (== UTF-8 byte order), matching Python's
            // sorted() exactly; Swift's default String sort uses canonical-equivalence
            // ordering, which diverges on some non-ASCII keys. (Canonically-equivalent
            // but distinct keys still collapse on decode — inherent to [String: _].)
            let sortedKeys = o.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (i, key) in sortedKeys.enumerated() {
                if i > 0 { out += "," }
                writeEscaped(key, into: &out)
                out += ":"
                write(o[key]!, into: &out)
            }
            out += "}"
        }
    }

    /// The shared number rule. Mirrored in scripts/gen-fixtures.py — keep in sync.
    public static func canonicalNumber(_ d: Double) -> String {
        assert(d.isFinite, "non-finite number in recipe JSON")
        if d == d.rounded() && abs(d) < 1e15 {
            let i = Int64(d)
            return i == 0 ? "0" : String(i)   // also normalizes -0
        }
        return String(format: "%.6g", d)
    }

    private static func writeEscaped(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

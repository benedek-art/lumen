// FingerprintCoverageTests.swift
// Every field a recipe encodes reaches `recipe_fp`, unless it is on the cosmetic list.
//
// `Recipe.renderIdentity` strips fields by hand. Strip one too many and every cached
// preview is served stale for that control, with no other test noticing. So the
// fields are not listed here: they come from the encoded JSON of
// `RecipeSamples.fingerprintSample()`, one leaf at a time, and a field added to the
// recipe is covered as soon as the sample populates it (which
// `RecipeCodecToleranceTests` already requires).

import XCTest
@testable import LumenCore

final class FingerprintCoverageTests: XCTestCase {

    private enum Step { case key(String), index(Int) }

    /// Paths `renderIdentity` drops on purpose: labels and panel state. They must NOT
    /// move the fingerprint.
    ///
    /// `masks[1].id` is here because nothing references mask 1, so the reference-bearing
    /// projection replaces it with its index. Mask 0's id is referenced and is not here.
    private static let cosmetic: Set<String> = [
        "masks[0].name", "masks[1].name", "masks[1].id",
        "maskGroups[0].name", "maskGroups[0].collapsed",
        "look.lut.name",
    ]

    private static func describe(_ path: [Step]) -> String {
        var out = ""
        for step in path {
            switch step {
            case .key(let k): out += out.isEmpty ? k : "." + k
            case .index(let i): out += "[\(i)]"
            }
        }
        return out
    }

    private static func leaves(_ value: JSONValue, at path: [Step] = []) -> [[Step]] {
        switch value {
        case .object(let o):
            return o.keys.sorted().flatMap { leaves(o[$0]!, at: path + [.key($0)]) }
        case .array(let a):
            return a.indices.flatMap { leaves(a[$0], at: path + [.index($0)]) }
        default:
            return [path]
        }
    }

    private static func replacing(_ value: JSONValue, at path: ArraySlice<Step>,
                                  with leaf: JSONValue) -> JSONValue {
        guard let step = path.first else { return leaf }
        switch (step, value) {
        case (.key(let k), .object(var o)):
            o[k] = replacing(o[k]!, at: path.dropFirst(), with: leaf)
            return .object(o)
        case (.index(let i), .array(var a)):
            a[i] = replacing(a[i], at: path.dropFirst(), with: leaf)
            return .array(a)
        default:
            preconditionFailure("path does not match the tree")
        }
    }

    private static func leaf(_ value: JSONValue, at path: [Step]) -> JSONValue {
        var node = value
        for step in path {
            switch (step, node) {
            case (.key(let k), .object(let o)): node = o[k]!
            case (.index(let i), .array(let a)): node = a[i]
            default: preconditionFailure("path does not match the tree")
            }
        }
        return node
    }

    /// Raw values to try on a string leaf after the free-text edits: an enum rejects
    /// "x". A new enum none of these fits shows up as unprobed; add one of its cases.
    private static let enumCases = ["classic", "heal", "display", "normal", "luma",
                                    "color", "add", "subtract", "radial", "lights"]

    /// Candidate replacements for one leaf, tried in order until one decodes to a
    /// different recipe. Two directions for numbers, so a field sampled at a clamp
    /// bound is still probed.
    private static func perturbations(of leaf: JSONValue) -> [JSONValue] {
        switch leaf {
        case .number(let v):
            let step = v == v.rounded() ? 1 : 1e-3 * (abs(v) + 1)
            return [.number(v + step), .number(v - step)]
        case .bool(let b): return [.bool(!b)]
        case .string(let s): return ([s + "x", ""] + enumCases).map(JSONValue.string)
        case .null, .array, .object: return []
        }
    }

    func testEveryEncodedFieldReachesTheFingerprint() throws {
        let sample = RecipeSamples.fingerprintSample()
        let tree = try CanonicalJSON.tree(of: sample)
        let decode = { (t: JSONValue) throws -> Recipe in
            try CanonicalJSON.decodeRecipe(from: Data(CanonicalJSON.serialize(t).utf8))
        }
        XCTAssertEqual(try decode(tree), sample, "the sample does not survive the wire")
        let original = try RecipeFingerprint.fingerprint(sample)

        let paths = Self.leaves(tree)
        XCTAssertGreaterThan(paths.count, 200, "the walk reached almost nothing")

        var unreached: [String] = []
        var cosmeticMoved: [String] = []
        var unprobed: [String] = []
        var cosmeticSeen: Set<String> = []
        for path in paths {
            let name = Self.describe(path)
            var probed = false
            for candidate in Self.perturbations(of: Self.leaf(tree, at: path)) {
                guard let changed = try? decode(Self.replacing(tree, at: path[...],
                                                               with: candidate)),
                      changed != sample
                else { continue }
                probed = true
                let moved = try RecipeFingerprint.fingerprint(changed) != original
                if Self.cosmetic.contains(name) {
                    cosmeticSeen.insert(name)
                    if moved { cosmeticMoved.append(name) }
                } else if !moved {
                    unreached.append(name)
                }
                break
            }
            if !probed { unprobed.append(name) }
        }

        XCTAssertEqual(unreached, [],
                       "a changed field left recipe_fp where it was — the cache would "
                       + "serve the previous picture")
        XCTAssertEqual(cosmeticMoved, [],
                       "a cosmetic field moved recipe_fp — editing it re-renders")
        XCTAssertEqual(cosmeticSeen, Self.cosmetic,
                       "a cosmetic path no longer exists in the sample")
        XCTAssertEqual(unprobed, [],
                       "no perturbation of these leaves changed the decoded recipe, "
                       + "so the walk could not test them")
    }
}

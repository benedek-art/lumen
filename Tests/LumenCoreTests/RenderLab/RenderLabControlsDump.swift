// RenderLabControlsDump.swift
// Writes the data behind renderlab/CONTROLS.md: every ProofRegistry control mapped to the
// recipe JSON paths it writes (found by diffing encodings, not by transcription), the
// default recipe's leaves, and the enumerated values. Inert unless
// LUMEN_RENDERLAB_CONTROLS names an output file; renderlab/gen-controls.py renders it.

import Foundation
import XCTest
@testable import LumenCore

final class RenderLabControlsDump: XCTestCase {

    func testDumpControls() throws {
        guard let path = RenderLabReferenceHarness.flag("LUMEN_RENDERLAB_CONTROLS") else {
            throw XCTSkip("set LUMEN_RENDERLAB_CONTROLS=<out.json> to dump the control reference")
        }
        let base = try RenderLabJSON.of(Recipe())
        let baseLeaves = Dictionary(base.flatLeaves().map { ($0.path, $0.value) },
                                    uniquingKeysWith: { a, _ in a })

        func changed(_ setting: Double, _ spec: ControlSpec) throws -> [String: RenderLabJSON] {
            var r = Recipe()
            spec.apply(&r, setting)
            var out: [String: RenderLabJSON] = [:]
            for leaf in try RenderLabJSON.of(r).flatLeaves() where baseLeaves[leaf.path] != leaf.value {
                out[leaf.path] = leaf.value
            }
            return out
        }

        let templateLeaves = Dictionary(
            try RenderLabJSON.of(RecipePatch.optionalTemplate).flatLeaves().map { ($0.path, $0.value) },
            uniquingKeysWith: { a, _ in a })
        var controls: [RenderLabJSON] = []
        for spec in ProofRegistry.all {
            let lo = try changed(spec.low, spec)
            let hi = try changed(spec.high, spec)
            let paths = Set(lo.keys).union(hi.keys).sorted()
            let moving = paths.filter { lo[$0] != hi[$0] }
            // Values a patch would get anyway (optional-block defaults) are not worth listing.
            let fixed = paths.filter { lo[$0] == hi[$0] && templateLeaves[$0] != hi[$0] }
            controls.append(.object([
                "id": .string(spec.id),
                "name": .string(spec.displayName),
                "panel": .string(spec.panel),
                "low": .number(spec.low),
                "high": .number(spec.high),
                "neutral": .number(spec.neutral),
                "paths": .array(moving.map { .string($0) }),
                "defaults": .object(Dictionary(uniqueKeysWithValues: moving.map {
                    ($0, baseLeaves[$0] ?? .null)
                })),
                "alsoSets": .object(Dictionary(uniqueKeysWithValues: fixed.map { ($0, hi[$0]!) })),
                "lowValues": .object(lo.filter { moving.contains($0.key) }),
                "highValues": .object(hi.filter { moving.contains($0.key) }),
            ]))
        }

        let withOptionals = RecipePatch.optionalTemplate
        let optionalLeaves = try RenderLabJSON.of(withOptionals).flatLeaves()
            .filter { baseLeaves[$0.path] == nil }

        let document: RenderLabJSON = .object([
            "controls": .array(controls),
            "defaultRecipe": .array(base.flatLeaves().map {
                .object(["path": .string($0.path), "default": $0.value])
            }),
            "optionalBlocks": .array(optionalLeaves.map {
                .object(["path": .string($0.path), "whenPresent": $0.value])
            }),
            "importedDenoise": .object(Dictionary(uniqueKeysWithValues: [100, 800, 3200, 6400, 12800].map {
                ("iso\($0)", (try? RenderLabJSON.of(
                    Recipe.asImported(from: Recipe.SourceFile(iso: $0)).develop.denoise)) ?? .null)
            })),
            "enums": .object([
                "look.filmLab.stock": .array(FilmStock.all.map { .string($0.id) }),
                "look.filmLab.stockNames": .array(FilmStock.all.map { .string($0.name) }),
                "look.render.preset": .array(DisplayTransformParams.presetNames.map { .string($0) }),
                "develop.denoise.mode": .array(["off", "classic", "ai"].map { .string($0) }),
                "look.lut.tap": .array(["display", "log"].map { .string($0) }),
            ]),
            "charts": .array(RenderLabCharts.names.map { .string("chart:" + $0) }),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: URL(fileURLWithPath: path))
    }
}

extension RenderLabJSON {
    /// Every leaf with arrays expanded by index (unlike `leaves`, which keeps arrays whole).
    func flatLeaves(prefix: String = "") -> [(path: String, value: RenderLabJSON)] {
        switch self {
        case .object(let o):
            return o.keys.sorted().flatMap { k in
                o[k]!.flatLeaves(prefix: prefix.isEmpty ? k : prefix + "." + k)
            }
        case .array(let a) where !a.isEmpty:
            return a.enumerated().flatMap { i, v in v.flatLeaves(prefix: prefix + ".\(i)") }
        default:
            return [(prefix, self)]
        }
    }
}

// RenderLabReferenceHarness.swift
// The render lab's Linux side: the same manifest, rendered through ReferenceRenderer on
// the synthetic charts. Outputs are labelled reference-path; they are not what the app
// ships. Inert unless LUMEN_RENDERLAB names a manifest (see renderlab/README.md).
//
//   LUMEN_RENDERLAB=renderlab/manifests/smoke.json LUMEN_RENDERLAB_OUT=/tmp/rl \
//     swift test --filter RenderLabReferenceHarness

import Foundation
import XCTest
@testable import LumenCore

final class RenderLabReferenceHarness: XCTestCase {

    /// Absent, empty, "0", "false", "no", "off" mean no; same guard as ControlProbeHarness.
    static func flag(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        return ["0", "false", "no", "off"].contains(v.lowercased()) ? nil : v
    }

    func testRunManifestOnTheReferencePath() throws {
        guard let list = Self.flag("LUMEN_RENDERLAB") else {
            throw XCTSkip("set LUMEN_RENDERLAB=<manifest.json>[,<more>] to run the render lab")
        }
        let urls = list.split(separator: ",").map {
            URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces))
        }
        let root = URL(fileURLWithPath: Self.flag("LUMEN_RENDERLAB_OUT") ?? "renderlab-out/reference",
                       isDirectory: true)
        let lut = Int(Self.flag("LUMEN_RENDERLAB_LUT") ?? "") ?? LUT3D.exportSize
        let cap = Int(Self.flag("LUMEN_RENDERLAB_MAX_EDGE") ?? "") ?? 2048
        let plates = Self.flag("LUMEN_RENDERLAB_PLATES").map {
            RenderLabReferenceBackend.directoryLoader(URL(fileURLWithPath: $0, isDirectory: true))
        }
        var shard: (Int, Int)?
        if let text = Self.flag("LUMEN_RENDERLAB_SHARD") {
            let parts = text.split(separator: "/").compactMap { Int($0) }
            guard parts.count == 2, parts[1] > 0, (0..<parts[1]).contains(parts[0]) else {
                return XCTFail("LUMEN_RENDERLAB_SHARD must be k/n, got \(text)")
            }
            shard = (parts[0], parts[1])
        }
        var errors: [String] = []
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let manifest = try RenderLabManifest(data: Data(contentsOf: url), defaultName: name)
            let backend = RenderLabReferenceBackend(lutSize: lut, maxLongEdge: cap,
                                                    plateLoader: plates)
            let out = root.appendingPathComponent(name)
            let runner = RenderLabRunner(backend: backend, manifest: manifest, out: out)
            runner.manifestDirectory = url.deletingLastPathComponent()
            if plates == nil { runner.include = { $0.hasPrefix("chart:") } }
            runner.shard = shard
            try runner.run()
            errors += runner.errors
        }
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
    }
}

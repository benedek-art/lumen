// GrainParityScanTests.swift
// WS-40, SPEC lines 12 and 13: the grain is ONE formula, declared once in LumenCore and
// transcribed once into the GPU kernel, and the tiled plate it replaced is gone.
//
// Read as text because `Sources/LumenPipeline` is `#if os(macOS)` and no test in this
// package can call into it — the same reason `KernelRosterTests` reads `Kernels.swift`.
// What this file cannot see is whether the kernel COMPUTES what the reference computes;
// `KernelGoldenTests.testGrainMatchesTheReferenceRenderer` checks that on the macOS
// gpu-parity lane, against `ReferenceRenderer.applyGrain`, at < 1e-3.
//
// COMMENTS ARE STRIPPED FIRST, and that is not hygiene: every file scanned here has
// paragraphs about the names being scanned for sitting directly above the code that uses
// them, so an unstripped scan would be satisfied by the prose. String literals are kept
// for searching (the kernels are string literals) and blanked for brace matching.
//
// The retired plate's names are spelled here in pieces, so that SPEC line 13's own grep
// over `Sources` and `Tests` (which reads comments too) does not find them in the test
// that checks they are gone.

import XCTest
@testable import LumenCore

final class GrainParityScanTests: XCTestCase {

    /// Functions whose NAME contains "plate" in the pipeline and which are not grain
    /// builders, each with the reason. `ditherPlate` is the 8×8 Bayer cell
    /// `PipelineRenderer` tiles for output dither: no noise, no `GrainPlan`, no seed.
    /// `testTheDitherPlateIsNotAGrainBuilder` checks that rather than taking this
    /// comment's word for it.
    private static let plateNamesThatAreNotGrainBuilders: Set<String> = ["ditherPlate"]

    /// The functions in the whole tree that may ask a plan for its grain field:
    /// `ReferenceRenderer.applyGrain` and the GPU builder `RenderGraph.grainPlate`.
    private static let functionsAllowedToBuildAField: Set<String> = ["applyGrain", "grainPlate"]

    /// The tiled plate's vocabulary (SPEC line 13). Split so this file is not a hit.
    private static let retiredNames: [String] = [
        "GrainPlate" + "Memo", "plateEncode" + "Scale", "lattice" + "Value",
        "plate" + "Size", "FilmGrainProfile.sam" + "ple(", "FilmGrainProfile.pl" + "ate(",
        ".plate(" + "channel", "renderPixels" + "PerCell", "default" + "Persistence",
    ]

    // MARK: - The names this file scans for, written as Swift

    /// Every name the scans below search for is also used here as real Swift, so a
    /// rename is a compile error rather than a scan that quietly finds nothing.
    func testTheNamesThisFileScansForStillExist() {
        let chain = FilmChain(FilmChain.defaultRecipe(for: FilmStock.triX400),
                              displayWhite: 1.0)
        let plan = GrainPlan.film(chain)
        let field = plan.field(longEdge: 2000)
        XCTAssertEqual(field.channels.count, 1, "a monochrome stock is one field")
        XCTAssertGreaterThan(GrainField.primeA, 0)
        XCTAssertGreaterThan(GrainField.primeB, 0)
        XCTAssertGreaterThan(GrainField.maxGrains, 0)
        XCTAssertGreaterThan(GrainField.pixelAperture, 0)
        XCTAssertEqual(plan.noiseLumaWeight + plan.noiseOwnWeight, 1.0, accuracy: 1e-9,
                       "a monochrome profile's mix is the identity — luma 0, own 1")
        XCTAssertFalse(plan.luminanceOnly)
        let frame = ImageBuffer(width: 4, height: 4) { _, _ in RGB(gray: 0.18) }
        let grained = ReferenceRenderer.applyGrain(
            frame, grain: plan, seed: FilmGrainProfile.defaultPlateSeed, longEdge: 2000)
        XCTAssertEqual(grained.width, 4)
    }

    // MARK: - SPEC 13: the plate is gone

    func testNoPlateCodeIsLeft() throws {
        var hits: [String] = []
        for root in ["Sources", "Tests"] {
            let base = Self.repositoryRoot().appendingPathComponent(root)
            let names = try FileManager.default.subpathsOfDirectory(atPath: base.path)
            for name in names.sorted() where name.hasSuffix(".swift") {
                let text = try String(contentsOf: base.appendingPathComponent(name),
                                      encoding: .utf8)
                for needle in Self.retiredNames where text.contains(needle) {
                    hits.append("\(root)/\(name): \(needle)")
                }
            }
        }
        XCTAssertEqual(hits, [], "the tiled plate's code is back:\n"
                           + hits.joined(separator: "\n"))
        let graph = try String(contentsOf: Self.pipelineFile("RenderGraph.swift"),
                               encoding: .utf8)
        XCTAssertFalse(graph.contains("affine" + "Tile"),
                       "RenderGraph tiles something again — the grain was a tiled plate")
        let film = try String(contentsOf: Self.engineFile("FilmLab.swift"), encoding: .utf8)
            .lowercased()
        XCTAssertFalse(film.contains("oct" + "ave") || film.contains("persis" + "tence"),
                       "FilmLab.swift speaks of octaves again")
    }

    // MARK: - SPEC 12: one formula, its constants declared once

    /// The kernel interpolates every constant of the hash and the field from
    /// `GrainField`, and carries no literal copy of either modulus.
    func testTheGrainFieldKernelInterpolatesItsConstants() throws {
        let sources = try Self.swiftSources(under: "Sources/LumenPipeline")
        guard let kernels = sources.first(where: { $0.path.hasSuffix("Kernels.swift") })
        else { return XCTFail("Kernels.swift not found by the walk") }
        guard let body = Self.stringLiteral(after: "grainFieldSource", in: kernels) else {
            return XCTFail("no `grainFieldSource` string literal in Kernels.swift")
        }
        XCTAssertTrue(body.contains("lumenGrainField"),
                      "the literal after `grainFieldSource` is not the grain field kernel")
        for name in ["GrainField.primeA", "GrainField.primeB", "GrainField.maxGrains",
                     "GrainField.pixelAperture"] {
            XCTAssertTrue(body.contains("\\(" + name) || body.contains("\\(1 / " + name),
                          "the kernel does not interpolate `\(name)`")
        }
        for literal in ["4091", "4079", "0.825", "0.680625"] {
            XCTAssertFalse(body.contains(literal),
                           "the kernel carries a literal copy (`\(literal)`) of a constant "
                               + "`GrainField` declares — the shape of every grain "
                               + "parity defect this project has had")
        }
        guard let apply = Self.stringLiteral(after: "grainSource", in: kernels) else {
            return XCTFail("no `grainSource` string literal in Kernels.swift")
        }
        XCTAssertTrue(apply.contains("lumenGrain(") && apply.contains("luminanceOnly"),
                      "`lumenGrain` lost its luminance-only mode")
    }

    /// Both renderers get their field from the plan — the one door, `GrainPlan.field`.
    func testBothRenderersGetTheFieldFromThePlan() throws {
        let graph = try Self.read(Self.pipelineFile("RenderGraph.swift"),
                                  path: "Sources/LumenPipeline/RenderGraph.swift")
        let gpu = try Self.functionBody("grainPlate", in: graph)
        XCTAssertTrue(gpu.contains(".field(longEdge:"), "the GPU builder does not ask the plan")
        XCTAssertTrue(gpu.contains("KernelLibrary.grainField"),
                      "the GPU builder does not run the grain field generator")
        let reference = try Self.functionBody(
            "applyGrain",
            in: try Self.read(Self.engineFile("ReferenceRenderer.swift"),
                              path: "Sources/LumenCore/Engine/ReferenceRenderer.swift"))
        XCTAssertTrue(reference.contains(".field(longEdge:"),
                      "the reference does not ask the plan for its field")

        // And nothing else in the tree builds one.
        var strays: [String] = []
        for source in try Self.swiftSources(under: "Sources") {
            let spans = Self.functions(in: source.structure)
            for offset in Self.offsets(of: ".field(longEdge:", in: source.code) {
                let function = Self.enclosing(offset, spans)?.name ?? "<no function>"
                if !Self.functionsAllowedToBuildAField.contains(function) {
                    strays.append("\(source.path):\(Self.line(at: offset, in: source.raw)) "
                                      + "in \(function)")
                }
            }
        }
        XCTAssertEqual(strays, [], "a grain field is built outside "
                           + "\(Self.functionsAllowedToBuildAField.sorted()):\n"
                           + strays.joined(separator: "\n"))
    }

    /// Both renderers read the two mix weights and the luminance-only flag off the
    /// plan, by name, rather than each computing its own.
    func testBothRenderersReadTheLayerMixOffThePlan() throws {
        let gpu = try Self.functionBody("applyGrain",
                                        in: try Self.read(
                                            Self.pipelineFile("RenderGraph.swift"),
                                            path: "Sources/LumenPipeline/RenderGraph.swift"))
        let reference = try Self.functionBody(
            "applyGrain",
            in: try Self.read(Self.engineFile("ReferenceRenderer.swift"),
                              path: "Sources/LumenCore/Engine/ReferenceRenderer.swift"))
        for (label, body) in [("RenderGraph", gpu), ("ReferenceRenderer", reference)] {
            for name in ["noiseLumaWeight", "noiseOwnWeight", "luminanceOnly",
                         "GrainPlan.luminanceWeights"] {
                XCTAssertTrue(body.contains(name),
                              "\(label).applyGrain does not read `\(name)` off the plan")
            }
        }
    }

    /// A second grain builder in the pipeline does not have to call the plan to be a
    /// second builder, so the name is checked too.
    func testTheOnlyPlateNamedFunctionsInThePipelineAreTheTwoThatAreArguedFor() throws {
        let sources = try Self.swiftSources(under: "Sources/LumenPipeline")
        var named: [String] = []
        for source in sources {
            for span in Self.functions(in: source.structure)
            where span.name.lowercased().contains("plate") {
                named.append(span.name)
            }
        }
        XCTAssertEqual(named.filter { !Self.plateNamesThatAreNotGrainBuilders.contains($0) },
                       ["grainPlate"],
                       "the pipeline declares \(named.sorted()) — one grain builder, plus "
                           + "whatever is listed in `plateNamesThatAreNotGrainBuilders`")
    }

    /// The exemption above, verified rather than asserted.
    func testTheDitherPlateIsNotAGrainBuilder() throws {
        let sources = try Self.swiftSources(under: "Sources/LumenPipeline")
        var checked = 0
        for source in sources {
            for span in Self.functions(in: source.structure) where span.name == "ditherPlate" {
                let body = String(source.code[span.bodyStart...span.bodyEnd])
                XCTAssertFalse(body.contains("GrainPlan") || body.contains("GrainField"),
                               "the dither plate reaches the grain; it is a Bayer cell and "
                                   + "the exemption is no longer true")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 1,
                       "`ditherPlate` is exempted and was found \(checked) times — an "
                           + "exemption for a function that is gone is a hole")
    }

    // MARK: - Reading Swift as text

    /// One source in the two views this file needs, at the SAME character offsets.
    private struct Source {
        let path: String
        let raw: [Character]
        /// Comments blanked, string bodies kept — what a text search runs on.
        let code: [Character]
        /// Comments AND string bodies blanked — what brace matching runs on, because
        /// `Kernels.swift` is thirty-eight shader bodies inside string literals and a
        /// `{` in a kernel would otherwise close a Swift function.
        let structure: [Character]
    }

    private struct FunctionSpan {
        let name: String
        let bodyStart: Int
        let bodyEnd: Int
    }

    /// EVERY overload's body, joined.
    ///
    /// `ReferenceRenderer` declares `applyGrain` twice — a `FilmChain` front door that
    /// delegates, and the implementation — and taking the first would read the door.
    /// Joining asks "does the grain stage read this name anywhere", which is the
    /// question: delete the weights from the one that computes and the union loses them.
    private static func functionBody(_ name: String, in source: Source) throws -> String {
        let spans = functions(in: source.structure).filter { $0.name == name }
        XCTAssertGreaterThan(spans.count, 0,
                             "no `func \(name)` in \(source.path) — the scan is reading "
                                 + "a file that no longer declares it, and every "
                                 + "assertion about its body would be vacuous")
        return spans.map { String(source.code[$0.bodyStart...$0.bodyEnd]) }
            .joined(separator: "\n")
    }

    /// The first `"""…"""` literal after `name`, with its delimiters.
    private static func stringLiteral(after name: String, in source: Source) -> String? {
        guard let start = offsets(of: name, in: source.code).first else { return nil }
        // The fence is spelled with escapes rather than as three escaped quote
        // characters: `check-swift-surface.py` reads argument labels by scanning
        // the call text, and an argument that is nothing but quotes reads to it as
        // the end of the call.
        let fence = "\u{22}\u{22}\u{22}"
        let quotes = offsets(of: fence, in: source.code).filter { $0 > start }
        guard quotes.count >= 2 else { return nil }
        return String(source.code[quotes[0]...(quotes[1] + 2)])
    }

    private static func functions(in structure: [Character]) -> [FunctionSpan] {
        var spans: [FunctionSpan] = []
        for start in offsets(of: "func ", in: structure) {
            if start > 0 {
                let before = structure[start - 1]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            var i = start + 5
            while i < structure.count, structure[i] == " " { i += 1 }
            var name = ""
            while i < structure.count,
                  structure[i].isLetter || structure[i].isNumber || structure[i] == "_" {
                name.append(structure[i])
                i += 1
            }
            guard !name.isEmpty else { continue }   // an operator, which builds no plate
            // The body opens at the first brace outside the signature's parentheses.
            var depth = 0
            var open = -1
            while i < structure.count {
                let c = structure[i]
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1 }
                if c == "{" && depth <= 0 { open = i; break }
                i += 1
            }
            guard open >= 0, let end = bodyEnd(openBrace: open, in: structure) else {
                continue
            }
            spans.append(FunctionSpan(name: name, bodyStart: open, bodyEnd: end))
        }
        return spans
    }

    /// The OUTERMOST span containing `offset` — the declared function that owns the
    /// call, not the local helper it happens to sit in.
    ///
    /// `RenderGraph.grainPlate` builds each layer's tile through a nested
    /// `func tile(channel:)`, so the innermost answer for its first plate call is
    /// `tile`, and a rule written on innermost names would have reported two builders
    /// in the one function that is the builder. Outermost is also the stricter reading
    /// of the rule this file enforces: a plate call inside a local `func noisePlate()`
    /// buried in some unrelated method still resolves to that method, which is not on
    /// the allowed list, so hiding a builder inside a helper does not hide it.
    private static func enclosing(_ offset: Int, _ spans: [FunctionSpan]) -> FunctionSpan? {
        var best: FunctionSpan?
        for span in spans where offset > span.bodyStart && offset < span.bodyEnd {
            if let current = best, current.bodyStart <= span.bodyStart { continue }
            best = span
        }
        return best
    }

    private static func bodyEnd(openBrace: Int, in structure: [Character]) -> Int? {
        var depth = 0
        var i = openBrace
        while i < structure.count {
            if structure[i] == "{" { depth += 1 }
            if structure[i] == "}" {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func offsets(of needle: String, in characters: [Character]) -> [Int] {
        let pattern = Array(needle)
        guard !pattern.isEmpty, characters.count >= pattern.count else { return [] }
        var found: [Int] = []
        var i = 0
        let last = characters.count - pattern.count
        while i <= last {
            var k = 0
            while k < pattern.count, characters[i + k] == pattern[k] { k += 1 }
            if k == pattern.count { found.append(i) }
            i += 1
        }
        return found
    }

    private static func line(at offset: Int, in raw: [Character]) -> Int {
        var number = 1
        var i = 0
        while i < offset && i < raw.count {
            if raw[i] == "\n" { number += 1 }
            i += 1
        }
        return number
    }

    // MARK: - The stripper

    /// Comments and string literals, classified in one pass.
    ///
    /// One pass rather than a sequence of searches because the two constructs nest into
    /// each other and a search for either alone is wrong in the presence of the other —
    /// `check-swift-surface.py`'s `_scan` makes the same argument and this is its shape.
    /// Block comments NEST in Swift, so the depth is counted rather than flagged.
    ///
    /// Newlines survive in both views, so an offset in either names the same line in the
    /// original.
    private static func read(_ url: URL, path: String) throws -> Source {
        let raw = Array(try String(contentsOf: url, encoding: .utf8))
        var kind = [UInt8](repeating: 0, count: raw.count)   // 0 code, 1 comment, 2 string
        var i = 0
        var block = 0
        while i < raw.count {
            let c = raw[i]
            let next: Character = i + 1 < raw.count ? raw[i + 1] : " "
            if block > 0 {
                kind[i] = 1
                if c == "/" && next == "*" {
                    block += 1; kind[i + 1] = 1; i += 2; continue
                }
                if c == "*" && next == "/" {
                    block -= 1; kind[i + 1] = 1; i += 2; continue
                }
                i += 1
                continue
            }
            if c == "/" && next == "*" {
                block = 1; kind[i] = 1; kind[i + 1] = 1; i += 2; continue
            }
            if c == "/" && next == "/" {
                while i < raw.count, raw[i] != "\n" { kind[i] = 1; i += 1 }
                continue
            }
            if c == "\"" {
                let third: Character = i + 2 < raw.count ? raw[i + 2] : " "
                if next == "\"" && third == "\"" {
                    kind[i] = 2; kind[i + 1] = 2; kind[i + 2] = 2
                    var j = i + 3
                    while j < raw.count {
                        if raw[j] == "\\" {
                            kind[j] = 2
                            if j + 1 < raw.count { kind[j + 1] = 2 }
                            j += 2
                            continue
                        }
                        if raw[j] == "\"" && j + 2 < raw.count
                            && raw[j + 1] == "\"" && raw[j + 2] == "\"" {
                            kind[j] = 2; kind[j + 1] = 2; kind[j + 2] = 2
                            j += 3
                            break
                        }
                        kind[j] = 2
                        j += 1
                    }
                    i = j
                    continue
                }
                kind[i] = 2
                var j = i + 1
                while j < raw.count, raw[j] != "\n" {
                    if raw[j] == "\\" {
                        kind[j] = 2
                        if j + 1 < raw.count { kind[j + 1] = 2 }
                        j += 2
                        continue
                    }
                    kind[j] = 2
                    j += 1
                    if raw[j - 1] == "\"" { break }
                }
                i = j
                continue
            }
            i += 1
        }
        var code = raw
        var structure = raw
        var k = 0
        while k < raw.count {
            if raw[k] != "\n" {
                if kind[k] == 1 { code[k] = " " }
                if kind[k] != 0 { structure[k] = " " }
            }
            k += 1
        }
        return Source(path: path, raw: raw, code: code, structure: structure)
    }

    // MARK: - The walk

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func pipelineFile(_ name: String) -> URL {
        repositoryRoot().appendingPathComponent("Sources/LumenPipeline")
            .appendingPathComponent(name)
    }

    private static func engineFile(_ name: String) -> URL {
        repositoryRoot().appendingPathComponent("Sources/LumenCore/Engine")
            .appendingPathComponent(name)
    }

    /// RECURSIVE, which the scan this file replaces is not: `contentsOfDirectory` stops
    /// at the top level, so a builder one directory down was invisible to it.
    private static func swiftSources(under relative: String) throws -> [Source] {
        let root = repositoryRoot().appendingPathComponent(relative)
        let names = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        var out: [Source] = []
        for name in names.sorted() where name.hasSuffix(".swift") {
            out.append(try read(root.appendingPathComponent(name),
                                path: relative + "/" + name))
        }
        return out
    }
}

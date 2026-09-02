// GrainParityScanTests.swift
// I2-05, and the half of I2-04 that text can hold.
//
// C2-01b IS A LANDING THIS PROJECT HAS MADE TWICE. Once in `GrainPlan` — a plate is
// band-limited to the resolution it is about to be sampled at, so a preview is the
// low-pass of the export rather than a differently pitched pattern — and once again in
// the GPU builder, because the film path had its own copy that did not go through the
// plan and went on handing the kernel every octave. Nothing failed either time.
//
// `GrainPlateTests.testThereIsOneGPUPlateBuilderAndItAsksThePlanForItsScale` was written
// to stop the third time. Its name has two clauses and it asserts the first: that one
// builder is declared, and that nothing calls `FilmGrainProfile.plate` directly. It
// never asks whether the builder passes `renderPixelsPerCell:`. Delete that argument
// from both call sites in `RenderGraph.grainPlate` — which is precisely C2-01b — and
// that test stays green, `testAPlateBuiltForARenderIsNotTheUnlimitedPlate` stays green
// (it exercises `GrainPlan` directly and never reaches the GPU builder),
// `testGrainPlateCarriesThreeLayersOnAColourStock` stays green (the channels still
// decorrelate) and `testGrainIsAppliedOnTheGridThatIsDelivered` stays green (both of
// its deliveries come from the same builder). The whole suite is green with C2-01b
// restored. This file is the second clause.
//
// WHAT MADE THE FIRST VERSION WEAK IS ENUMERATION BY NAME. It counts lines matching
// `func …GrainPlate` or `func grainPlate(`, so a second builder called `noisePlate`
// that reached `GrainPlan.plate(channel:)` without a scale is invisible to both of its
// assertions — and that is exactly the call the duplicate made. The rule here is
// name-free instead: every `.plate(` CALL in the shipping pipeline must carry a render
// scale, and every plate call anywhere in the tree must live in one of the three
// functions allowed to make one. A builder can be called anything; it cannot avoid
// calling `plate`.
//
// Read as text because `Sources/LumenPipeline` is `#if os(macOS)` and no test in this
// package can call into it — the same reason `KernelRosterTests` reads `Kernels.swift`
// and `SettleGateTests` reads the viewer's settle gate.
//
// COMMENTS ARE STRIPPED FIRST, and that is not hygiene. `DeliveryNameTests` records the
// first draft of this class of test passing its own substitution proof because a doc
// comment above the deleted property explained the rule and contained the symbol being
// scanned for; `EditRevisionRuleTests` records the same. Every file scanned here has
// paragraphs about `renderPixelsPerCell` and `plateScale` sitting directly above the
// code that uses them, so an unstripped scan would be satisfied by the prose that
// justifies the line it is meant to find missing. String literals are stripped too, but
// only for brace matching — `Kernels.swift` is thirty-eight shader bodies inside string
// literals, and a `{` in a kernel would otherwise close a Swift function.
//
// WHAT THIS FILE CANNOT SEE, so a green run is not read as more than it is:
//   · whether the two renderers SAMPLE the plate at the same coordinates. Text cannot
//     answer that; `KernelGoldenTests.testGrainMatchesTheReferenceRenderer` does, on
//     the gpu-parity lane, and it is the only thing that can.
//   · whether the scale passed is the right CHANNEL's. The channel guard below is the
//     closest text gets: every `plateScale(` in a grain stage must ask for a channel.
//   · a plate built in a module this file does not walk. It walks all of `Sources`.
//   · a raw string literal (`#"…"#`), which the stripper does not model. There are none
//     in the tree today and a kernel would have no reason to be one.

import XCTest
@testable import LumenCore

final class GrainParityScanTests: XCTestCase {

    /// Functions whose NAME contains "plate" and which are not plate builders, each
    /// with the reason. The list exists so that an exemption has to be argued in the
    /// commit that makes it rather than being invisible — `KernelRosterTests.exempt`'s
    /// doctrine, and the same reason it is a fixed set rather than a filter.
    ///
    /// `ditherPlate` is the 8×8 Bayer cell `PipelineRenderer` tiles for output dither.
    /// It shares the bias-into-(0,1) convention with `grainPlate` and nothing else: no
    /// noise, no `GrainPlan`, no seed. `testTheDitherPlateIsNotAGrainBuilder` checks
    /// that rather than taking this comment's word for it.
    private static let plateNamesThatAreNotGrainBuilders: Set<String> = ["ditherPlate"]

    /// The three functions in the whole tree that may call `plate`.
    ///
    /// `plate` is `GrainPlan.plate` itself, the one door onto the generator;
    /// `applyGrain` is `ReferenceRenderer`'s stage; `grainPlate` is the GPU builder. A
    /// fourth name here means a fourth place that decides what a plate is, which is the
    /// defect this file exists for.
    private static let functionsAllowedToBuildAPlate: Set<String> =
        ["plate", "applyGrain", "grainPlate"]

    // MARK: - The names this file scans for, written as Swift

    /// Every string the scans below search for is also called here as real Swift.
    ///
    /// This is the answer to "what would the scan MISS". A text search for
    /// `renderPixelsPerCell:` that stops matching because the label was renamed does
    /// not fail — it finds nothing, concludes nothing, and goes green. Writing the same
    /// name as a call makes a rename a COMPILE error in the file that depends on it, so
    /// the scan cannot quietly become a check on a name that no longer exists.
    ///
    /// `grainPlate` is the one name that cannot be anchored: it lives in
    /// `LumenPipeline`, which does not build on this lane at all. That is why the rules
    /// below are written about plate CALLS rather than about the builder's name.
    func testTheNamesThisFileScansForStillExist() {
        let chain = FilmChain(FilmChain.defaultRecipe(for: FilmStock.triX400),
                              displayWhite: 1.0)
        let plan = GrainPlan.film(chain)

        // `renderPixelsPerCell:` and `plateScale(longEdgePixels:channel:)` — the pair
        // the whole file is about.
        let scale = plan.plateScale(longEdgePixels: 2000, channel: 0)
        XCTAssertGreaterThan(scale, 0, "a plate scale is a positive cell size")
        let limited = plan.plate(channel: 0, renderPixelsPerCell: scale)
        XCTAssertEqual(limited.count, GrainPlan.plateSize * GrainPlan.plateSize)

        // `FilmGrainProfile.plate(` — the raw generator nothing outside `GrainPlan` may
        // reach — and `plateEncodeScale`, the constant the kernel divides back out.
        let raw = FilmGrainProfile.plate(size: 8, seed: 1, sigma: 1)
        XCTAssertEqual(raw.count, 64)
        XCTAssertGreaterThan(FilmGrainProfile.plateEncodeScale, 0)

        // The two mix weights, by the names the scan looks for on both renderers.
        XCTAssertEqual(plan.noiseLumaWeight + plan.noiseOwnWeight, 1.0, accuracy: 1e-9,
                       "a monochrome profile's mix is the identity — luma 0, own 1")

        // And `ReferenceRenderer.applyGrain`, by label.
        let frame = ImageBuffer(width: 4, height: 4) { _, _ in RGB(gray: 0.18) }
        let grained = ReferenceRenderer.applyGrain(
            frame, grain: plan, seed: FilmGrainProfile.defaultPlateSeed, longEdge: 2000)
        XCTAssertEqual(grained.width, 4)
    }

    // MARK: - I2-05, the second clause of the other test's name

    /// EVERY plate the shipping pipeline builds is band-limited to the render, and asks
    /// the plan for the number.
    ///
    /// Four rules, and each one is a way the two renderers came apart before:
    ///   a. every `.plate(` call passes `renderPixelsPerCell:` — deleting it is C2-01b;
    ///   b. the value is not a literal and not `nil` — passing `nil` builds every octave
    ///      under a label that says otherwise, and a literal is a second opinion about
    ///      the cell size;
    ///   c. the enclosing function asks `plateScale(longEdgePixels:` for it — the same
    ///      call `ReferenceRenderer.applyGrain` makes, which is what "the same value
    ///      from the same function" means;
    ///   d. every `plateScale(` in that function passes `channel:` — the un-channelled
    ///      overload is the whole-plate cell size, and `sizeScale` is (0.8, 1.0, 2.0),
    ///      so using it would give the red and blue records the green one's pitch.
    func testEveryPlateTheShippingPipelineBuildsCarriesTheRenderScale() throws {
        let sources = try Self.swiftSources(under: "Sources/LumenPipeline")
        XCTAssertGreaterThan(sources.count, 5,
                             "the walk found \(sources.count) Swift files under "
                                 + "Sources/LumenPipeline — it is reading the wrong "
                                 + "directory, and every assertion below would pass by "
                                 + "checking nothing")

        let calls = Self.plateCalls(in: sources)
        XCTAssertGreaterThan(calls.count, 1,
                             "no `.plate(` call was found anywhere in "
                                 + "Sources/LumenPipeline. Either the GPU stopped "
                                 + "building a plate — in which case film grain is gone "
                                 + "from every preview and every export — or the pattern "
                                 + "has stopped matching and this test is vacuous, which "
                                 + "is the failure KernelRosterTests records shipping in "
                                 + "its own first draft")

        var missingScale: [String] = []
        var literalScale: [String] = []
        for call in calls {
            if call.scaleArgument.isEmpty {
                missingScale.append(call.site)
            } else if call.scaleArgument == "nil"
                        || Double(call.scaleArgument) != nil {
                literalScale.append("\(call.site): \(call.scaleArgument)")
            }
        }
        XCTAssertEqual(missingScale, [],
                       "a plate is built for the GPU WITHOUT `renderPixelsPerCell:`, so "
                           + "it carries the octaves the render cannot resolve while "
                           + "`ReferenceRenderer.applyGrain` band-limits — the preview "
                           + "and the export go back to aliasing and no golden compares "
                           + "them (C2-01b, the landing this project made twice):\n"
                           + missingScale.joined(separator: "\n"))
        XCTAssertEqual(literalScale, [],
                       "a plate's render scale is a literal or `nil` rather than the "
                           + "plan's own `plateScale`, which is a second opinion about "
                           + "the cell size — the shape of every grain defect in "
                           + "FilmLab's history, from the seed to the encode scale:\n"
                           + literalScale.joined(separator: "\n"))

        var builders = Set(calls.map { $0.function })
        builders.remove("<no enclosing function>")
        XCTAssertEqual(builders.count, 1,
                       "plates are being built in \(builders.count) different functions "
                           + "in Sources/LumenPipeline — \(builders.sorted()). There is "
                           + "one builder; a second one is how the film path kept an "
                           + "unlimited plate after C2-01b, and it does not have to be "
                           + "called anything in particular to do it again")

        for call in calls {
            XCTAssertTrue(call.enclosingBody.contains("plateScale(longEdgePixels:"),
                          "\(call.site) builds a plate in a function that never asks "
                              + "`plateScale(longEdgePixels:…)` for the render's cell "
                              + "size, so whatever it passes came from somewhere else")
            let scales = Self.offsets(of: "plateScale(", in: Array(call.enclosingBody))
            XCTAssertGreaterThan(scales.count, 0, "\(call.site): no plateScale call")
            for scale in scales {
                let text = Self.callText(open: scale + 10,
                                         code: Array(call.enclosingBody),
                                         structure: Array(call.enclosingBody))
                XCTAssertTrue(text.contains("channel:"),
                              "\(call.site) asks for a plate scale without a channel. "
                                  + "`sizeScale` is (0.8, 1.0, 2.0), so the un-channelled "
                                  + "overload gives the red and blue records the green "
                                  + "one's pitch — and the reference renderer would keep "
                                  + "asking per channel: \(text)")
            }
        }
    }

    /// And the reference renderer band-limits through the same call, so "the same value
    /// from the same function" is a fact rather than a comment.
    ///
    /// Asserted here rather than left to the GPU golden because it is the other half of
    /// the pair: if this side stopped band-limiting, every parity comparison would go
    /// green again by agreeing on the wrong plate.
    func testTheReferenceRendererBandLimitsThroughTheSameCall() throws {
        let source = try Self.read(Self.engineFile("ReferenceRenderer.swift"),
                                   path: "Sources/LumenCore/Engine/ReferenceRenderer.swift")
        let calls = Self.plateCalls(in: [source])
        XCTAssertEqual(calls.count, 1,
                       "the reference's grain stage builds \(calls.count) plates; it "
                           + "builds one per layer through one call, and a second site "
                           + "is a second opinion")
        for call in calls {
            XCTAssertEqual(call.function, "applyGrain",
                           "\(call.site): the reference builds plates outside its grain "
                               + "stage")
            XCTAssertFalse(call.scaleArgument.isEmpty,
                           "\(call.site): the reference renderer stopped band-limiting, "
                               + "so both renderers would agree again — on the wrong "
                               + "plate, and every gpu-parity comparison would say so")
            XCTAssertTrue(call.enclosingBody.contains("plateScale(longEdgePixels:"),
                          "\(call.site): the scale did not come from the plan")
            XCTAssertTrue(call.enclosingBody.contains("channel:"),
                          "\(call.site): the reference's scale is not per channel")
        }
    }

    /// Nothing anywhere in the tree builds a plate outside the three functions allowed
    /// to, and nothing but `GrainPlan.plate` touches the generator.
    ///
    /// This is the walk `GrainPlateTests` does with `contentsOfDirectory(atPath:)`,
    /// which is not recursive and stops at `Sources/LumenPipeline`. A builder one
    /// directory down, or in `LumenApp`, was invisible to it.
    func testNothingElseInTheTreeBuildsAPlate() throws {
        let sources = try Self.swiftSources(under: "Sources")
        XCTAssertGreaterThan(sources.count, 50,
                             "the recursive walk found \(sources.count) Swift files "
                                 + "under Sources — it is not walking the tree")
        let calls = Self.plateCalls(in: sources)
        XCTAssertGreaterThan(calls.count, 2,
                             "the tree builds \(calls.count) plates in total, which is "
                                 + "fewer than the reference renderer, the GPU builder "
                                 + "and the generator's own door — the pattern has "
                                 + "stopped matching")

        let strays = calls
            .filter { !Self.functionsAllowedToBuildAPlate.contains($0.function) }
            .map { "\($0.site) — \($0.text.prefix(80))" }
        XCTAssertEqual(strays, [],
                       "a plate is being built outside "
                           + "\(Self.functionsAllowedToBuildAPlate.sorted()). A second "
                           + "builder produced identical bytes for a year and then "
                           + "silently stopped, because band-limiting was added to the "
                           + "plan and the copy did not go through the plan:\n"
                           + strays.joined(separator: "\n"))

        var rawGenerator: [String] = []
        for source in sources {
            let spans = Self.functions(in: source.structure)
            for offset in Self.offsets(of: "FilmGrainProfile.plate(", in: source.code) {
                let function = Self.enclosing(offset, spans)?.name ?? "<no function>"
                guard function != "plate" else { continue }
                rawGenerator.append(
                    "\(source.path):\(Self.line(at: offset, in: source.raw)) in \(function)")
            }
        }
        XCTAssertEqual(rawGenerator, [],
                       "a caller is building a plate straight from `FilmGrainProfile` "
                           + "instead of through `GrainPlan`, so it carries neither the "
                           + "profile's persistence — which is Roughness — nor the "
                           + "render's band limit:\n" + rawGenerator.joined(separator: "\n"))
    }

    /// A second builder does not have to call `plate` to be a second builder, so the
    /// name is checked too — and every "plate" in the pipeline that is not the grain
    /// builder has to be argued for.
    func testTheOnlyPlateNamedFunctionsInThePipelineAreTheTwoThatAreArguedFor() throws {
        let sources = try Self.swiftSources(under: "Sources/LumenPipeline")
        var named: [String] = []
        for source in sources {
            for span in Self.functions(in: source.structure)
            where span.name.lowercased().contains("plate") {
                named.append(span.name)
            }
        }
        XCTAssertEqual(Set(named).subtracting(Self.plateNamesThatAreNotGrainBuilders),
                       ["grainPlate"],
                       "the pipeline declares \(named.sorted()) — one grain plate "
                           + "builder, plus whatever is listed in "
                           + "`plateNamesThatAreNotGrainBuilders` with a reason. A new "
                           + "one is either the second builder this file exists to "
                           + "prevent or an exemption that has to be written down")
    }

    /// The exemption above, verified rather than asserted.
    func testTheDitherPlateIsNotAGrainBuilder() throws {
        let sources = try Self.swiftSources(under: "Sources/LumenPipeline")
        var checked = 0
        for source in sources {
            for span in Self.functions(in: source.structure) where span.name == "ditherPlate" {
                let body = String(source.code[span.bodyStart...span.bodyEnd])
                XCTAssertFalse(body.contains("GrainPlan"),
                               "the dither plate reaches the grain plan; it is a Bayer "
                                   + "cell and the exemption is no longer true")
                XCTAssertFalse(body.contains(".plate("),
                               "the dither plate builds a noise plate")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 1,
                       "`ditherPlate` is exempted from the builder count and was found "
                           + "\(checked) times — an exemption for a function that is "
                           + "gone is a hole with a comment over it")
    }

    // MARK: - I2-04, the half of the parity claim text can hold

    /// `Kernels.swift:614` says the grain kernel's layer mix is performed "identically
    /// in `ReferenceRenderer.applyGrain`, which is what gpu-parity checks", and
    /// `ReferenceRenderer.applyGrain` says "gpu-parity is what holds them together"
    /// twice, about `plateScale` and about the two mix weights. Until
    /// `KernelGoldenTests.testGrainMatchesTheReferenceRenderer` there was no such check
    /// at all. That golden needs a GPU; these two facts do not, and they are the two the
    /// comments actually name.
    ///
    /// FIRST: the kernel recovers the plate with the named constant, interpolated. It
    /// was a hardcoded `2.0` against a store that divided by 4, so the GPU laid half the
    /// amplitude the reference defines — in every preview and every export — and clamped
    /// away the strongest 3.4% of the grains on the way. A literal here is that defect.
    func testTheGrainKernelRecoversThePlateWithTheNamedEncodeScale() throws {
        let sources = try Self.swiftSources(under: "Sources/LumenPipeline")
        guard let kernels = sources.first(where: { $0.path.hasSuffix("Kernels.swift") })
        else { return XCTFail("Kernels.swift not found by the walk") }
        guard let body = Self.stringLiteral(after: "grainSource", in: kernels) else {
            return XCTFail("no `grainSource` string literal in Kernels.swift")
        }
        XCTAssertTrue(body.contains("lumenGrain"),
                      "the literal found after `grainSource` is not the grain kernel, so "
                          + "this test is reading the wrong block")
        XCTAssertTrue(body.contains("FilmGrainProfile.plateEncodeScale"),
                      "the grain kernel recovers the plate with something other than "
                          + "`FilmGrainProfile.plateEncodeScale`. The store and the "
                          + "recovery lived in different files and did not agree once "
                          + "already; interpolating the one constant is what stops the "
                          + "pair drifting again")
    }

    /// SECOND: both renderers read the two mix weights off the plan, by name, rather
    /// than each computing its own. "The way for two renderers to disagree about a
    /// number is for each to be handed it separately" is `RenderGraph.applyGrain`'s own
    /// comment; this is that sentence as a check.
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
            XCTAssertTrue(body.contains("noiseLumaWeight"),
                          "\(label).applyGrain does not read `noiseLumaWeight` off the "
                              + "plan, so the two renderers are each deciding how much "
                              + "of the three dye layers' independence reaches the "
                              + "picture (C2-02)")
            XCTAssertTrue(body.contains("noiseOwnWeight"),
                          "\(label).applyGrain does not read `noiseOwnWeight` off the plan")
        }
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

    /// One `.plate(` call site, with everything an assertion needs to name it.
    private struct PlateCall {
        let path: String
        let line: Int
        let function: String
        /// The call, from its opening parenthesis to the matching close.
        let text: String
        /// The value passed as `renderPixelsPerCell:`, trimmed; empty when absent.
        let scaleArgument: String
        /// The body of the function the call sits in.
        let enclosingBody: String

        /// `path:line in function`, which is every failure message's first line.
        var site: String { "\(path):\(line) in \(function)" }
    }

    private static func plateCalls(in sources: [Source]) -> [PlateCall] {
        var calls: [PlateCall] = []
        for source in sources {
            let spans = functions(in: source.structure)
            for offset in offsets(of: ".plate(", in: source.code) {
                let open = offset + 6
                let text = callText(open: open, code: source.code,
                                    structure: source.structure)
                let characters = Array(text)
                var scale = ""
                if let label = offsets(of: "renderPixelsPerCell:", in: characters).first {
                    scale = argument(after: label + 20, in: characters)
                }
                let span = enclosing(offset, spans)
                var body = ""
                if let span = span {
                    body = String(source.code[span.bodyStart...span.bodyEnd])
                }
                calls.append(PlateCall(
                    path: source.path,
                    line: line(at: offset, in: source.raw),
                    function: span?.name ?? "<no enclosing function>",
                    text: text,
                    scaleArgument: scale.trimmingCharacters(in: .whitespacesAndNewlines),
                    enclosingBody: body))
            }
        }
        return calls
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
        let quotes = offsets(of: "\"\"\"", in: source.code).filter { $0 > start }
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

    /// From an opening parenthesis to its match. Depth is counted on `structure`, where
    /// a parenthesis inside a string literal has already been blanked; the characters
    /// come from `code`, so the caller reads the call as written.
    private static func callText(open: Int, code: [Character],
                                 structure: [Character]) -> String {
        var depth = 0
        var i = open
        var out = ""
        while i < code.count && i < structure.count {
            if structure[i] == "(" { depth += 1 }
            if structure[i] == ")" { depth -= 1 }
            out.append(code[i])
            if depth == 0 { break }
            i += 1
        }
        return out
    }

    /// The argument value beginning at `from`, up to the comma or close that ends it.
    private static func argument(after from: Int, in characters: [Character]) -> String {
        var depth = 0
        var i = from
        var out = ""
        while i < characters.count {
            let c = characters[i]
            if c == "(" || c == "[" { depth += 1 }
            if c == ")" || c == "]" {
                if depth == 0 { break }
                depth -= 1
            }
            if c == "," && depth == 0 { break }
            out.append(c)
            i += 1
        }
        return out
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

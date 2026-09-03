// ExportCancelAdversarialTests.swift — an attack on the four claims made for export
// cancellation, not a demonstration of them.
//
// The subject is `AppState.exportCancelRequested` / `cancelExport()` /
// `clearExportCancel()`, the `batch:` labelled loop in `AppStateActions.export(to:)`,
// the Cancel affordance in `ExportSheet`, and the decision that the export sheet now
// STAYS UP for the length of a run. Every claim below was written down in prose beside
// the code it describes, which is the reason these tests read the sources with the
// comments STRIPPED: the prose argues for the property in words that a naive `contains`
// scan would find whether or not the property is there. `withoutComments` is ported
// unchanged from `CullScaleTests`, which ported it from `KeyGrammarTests`; see that
// file's header for why the two constructs have to be handled in one pass.
//
// THE THREE DEFECTS THIS FILE RECORDED ARE NOW FIXED, and the tests that recorded them
// are green against the tree rather than deleted from it. They were written as ordinary
// failing assertions rather than `XCTExpectFailure` on purpose — a defect parked behind
// an expectation is a defect nobody sees again — and that is exactly how they were paid
// off: the halted branch is guarded so a complete delivery cancelled on its final file
// no longer reports as interrupted, the halted message names its first failure, and the
// always-visible status bar says "Stopping — finishing this file" instead of a
// percentage that keeps climbing. Their doc comments still say DEFECT and still describe
// the failure in the past tense, because the argument for each is the reason its
// assertion is worth keeping.
//
// One warning for anyone editing them. These scans run over source with comments blanked
// to SPACES OF THE SAME LENGTH, so offsets survive — which means prose sits in the scan
// as whitespace and still takes up room. An assertion that looks at "the next N
// characters" is measuring length, not scope, and the eight lines of comment explaining
// a fix will push that fix outside the window. That is not hypothetical: it is how
// `testTheStatusBarSaysWhenAStopIsPending` came to fail against a tree that already did
// what it asked. Anchor on a brace-matched body.
//
// Structural rather than behavioural because the properties at issue are ABSENCES — no
// path out of the inner loop that skips a cancel check, no second writer of the flag, no
// message that says "Stopped" for a delivery that is whole — and an absence has no API
// to call. The parts that DO have an API (the delivered proof, the disambiguator) are
// exercised through LumenCore, which builds everywhere.
#if os(macOS)
import XCTest
import LumenCore

final class ExportCancelAdversarialTests: XCTestCase {

    // MARK: Reading the sources

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    private static func appSource(_ name: String) -> URL {
        repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("LumenApp", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func code(_ name: String) throws -> String {
        let text = try String(contentsOf: Self.appSource(name), encoding: .utf8)
        return Self.withoutComments(text)
    }

    /// Comments blanked, string bodies kept, length and newlines preserved — so every
    /// offset stays valid and a line number can still be counted off the result.
    /// Ported verbatim from `CullScaleTests`.
    private static func withoutComments(_ text: String) -> String {
        var out = Array(text)
        var i = 0
        let n = out.count
        func blank(_ from: Int, _ to: Int) {
            for k in from..<to where out[k] != "\n" { out[k] = " " }
        }
        while i < n {
            let c = out[i]
            let next: Character? = i + 1 < n ? out[i + 1] : nil
            if c == "/" && next == "/" {
                var j = i
                while j < n && out[j] != "\n" { j += 1 }
                blank(i, j)
                i = j
            } else if c == "/" && next == "*" {
                var j = i + 2
                while j + 1 < n && !(out[j] == "*" && out[j + 1] == "/") { j += 1 }
                let end = Swift.min(j + 2, n)
                blank(i, end)
                i = end
            } else if c == "\"" {
                var j = i + 1
                while j < n {
                    if out[j] == "\\" { j += 2; continue }
                    if out[j] == "\"" { j += 1; break }
                    if out[j] == "\n" { break }
                    j += 1
                }
                i = j
            } else {
                i += 1
            }
        }
        return String(out)
    }

    /// The head of the halted-status branch, as the source actually spells it.
    ///
    /// Three tests below anchor on this line, and it used to be written `if stopped {`
    /// in each of them. When the branch gained its guard — a run whose written count
    /// reached the total FINISHED, whatever was clicked on the way — all three stopped
    /// finding their anchor and failed on the unwrap, reporting "expected non-nil value
    /// of type Range<Index>" and naming nothing. Three tests failing with an unwrap
    /// message that cannot say what moved is the argument for the constant: the anchor
    /// is now in one place, and a branch that is renamed again fails once, here.
    static let haltedBranchHead = "if stopped, written < Int(total) {"

    /// The brace-delimited body that opens at the first `{` at or after `marker`.
    private func body(from marker: String, in code: String) -> String? {
        guard let markerRange = code.range(of: marker) else { return nil }
        let characters = Array(code)
        let start = code.distance(from: code.startIndex, to: markerRange.lowerBound)
        var i = start
        var opening: Int?
        while i < characters.count {
            if characters[i] == "{" { opening = i; break }
            i += 1
        }
        guard let open = opening else { return nil }
        var depth = 0
        var j = open
        while j < characters.count {
            if characters[j] == "{" { depth += 1 }
            if characters[j] == "}" {
                depth -= 1
                if depth == 0 { return String(characters[open...j]) }
            }
            j += 1
        }
        return nil
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var cursor = text.startIndex
        while let found = text.range(of: needle, range: cursor..<text.endIndex) {
            count += 1
            cursor = found.upperBound
        }
        return count
    }

    private func lines(containing needle: String, in text: String) -> [String] {
        text.components(separatedBy: "\n")
            .filter { $0.contains(needle) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - A. No path out of the loop skips a cancel check

    /// Both checks exist, and each one is the guard on its own `break batch`.
    ///
    /// The label is the whole mechanism: `break` without it leaves the INNER loop and
    /// the outer one carries on to the next photograph, which is a Cancel that skips one
    /// frame and keeps exporting. Nothing in the code's shape would show that up, so it
    /// is pinned here.
    func testEveryStopIsALabelledBreakGuardedByTheFlag() throws {
        let source = try code("AppStateActions.swift")
        let loop = try XCTUnwrap(body(from: "batch: for job in jobs", in: source),
                                "the labelled batch loop was renamed or removed")

        XCTAssertEqual(occurrences(of: "break batch", in: loop), 2,
                       "expected exactly two labelled breaks — one in the refusal "
                       + "branch and one in the write branch")
        XCTAssertEqual(occurrences(of: "break ", in: loop),
                       occurrences(of: "break batch", in: loop),
                       "an UNLABELLED break leaves the inner recipe loop only; the "
                       + "outer photo loop would keep exporting")

        // Every `break batch` is immediately preceded by the two statements that make it
        // a cancellation rather than an arbitrary early exit.
        for fragment in loop.components(separatedBy: "break batch").dropLast() {
            let tail = String(fragment.suffix(220))
            XCTAssertTrue(tail.contains("stopped = true"),
                          "a labelled break that does not set `stopped` reports the "
                          + "halted run as a finished one")
            XCTAssertTrue(tail.contains("exportCancelRequested"),
                          "a labelled break that is not guarded on the flag stops a "
                          + "batch nobody asked to stop")
        }
    }

    /// The refusal branch's `continue` cannot outrun its check.
    ///
    /// A photograph whose masking cannot be resolved is skipped with `continue`, which is
    /// the one statement in the loop that can leave an iteration without falling off the
    /// end of it. If the check ever moves below that `continue`, a batch of two hundred
    /// refused frames becomes uncancellable — the exact "unstoppable half hour" the
    /// button exists to end, arriving on the path where no work is even being done.
    func testTheRefusalBranchChecksBeforeItContinues() throws {
        let source = try code("AppStateActions.swift")
        let loop = try XCTUnwrap(body(from: "batch: for job in jobs", in: source))
        let refusal = try XCTUnwrap(body(from: "if let refusal = job.refusal", in: loop),
                                    "the refusal branch was renamed or removed")

        let checkIndex = try XCTUnwrap(refusal.range(of: "exportCancelRequested"),
                                       "the refusal branch no longer checks the flag; a "
                                       + "batch of refused photographs cannot be stopped")
        let continueIndex = try XCTUnwrap(refusal.range(of: "continue"))
        XCTAssertTrue(checkIndex.lowerBound < continueIndex.lowerBound,
                      "the check must precede the `continue`, or the branch skips it")

        // And `continue` appears once: a second one anywhere in the loop is another
        // uninspected way out.
        XCTAssertEqual(occurrences(of: "continue", in: loop), 1,
                       "every `continue` in the batch loop is a path that can skip the "
                       + "cancel check; there must be exactly the one, and it must be "
                       + "the refusal branch's")
    }

    /// The check in the write branch sits AFTER the write, not before it.
    ///
    /// The safety claim is "stopping can never leave a partial delivery on disk", and it
    /// is bought entirely by position: the encoder has already renamed its temp into
    /// place by the time the flag is read. A check hoisted above `renderCoordinator
    /// .export` would still stop the batch and would still be between files, and it
    /// would also be a check that never sees a cancel arriving during the long part of
    /// the iteration — which is the only part long enough for a photographer to click in.
    func testTheWriteBranchChecksAfterTheRename() throws {
        let source = try code("AppStateActions.swift")
        let loop = try XCTUnwrap(body(from: "batch: for job in jobs", in: source))
        // PAST THE REFUSAL BRANCH FIRST. `for exportRecipe in active` appears twice in
        // this loop — the refusal branch names every checked recipe in its failure list
        // before it skips the photograph — and the first match is the one that does no
        // writing at all. A scan that took it would assert the write-branch property
        // against a branch with no write in it and pass on an empty subject.
        let refusal = try XCTUnwrap(body(from: "if let refusal = job.refusal", in: loop))
        let afterRefusal = try XCTUnwrap(loop.range(of: refusal))
        let writeBranch = String(loop[afterRefusal.upperBound...])
        let inner = try XCTUnwrap(body(from: "for exportRecipe in active",
                                       in: writeBranch),
                                  "the write branch's recipe loop was renamed")

        let write = try XCTUnwrap(inner.range(of: "renderCoordinator.export"))
        let check = try XCTUnwrap(inner.range(of: "exportCancelRequested"))
        XCTAssertTrue(write.lowerBound < check.lowerBound,
                      "the flag must be read after the delivery has been renamed into "
                      + "place, not before it")

        // The check is the last statement of the iteration: anything after it is work
        // that a stopped run would still do.
        let afterCheck = String(inner[check.upperBound...])
        XCTAssertFalse(afterCheck.contains("renderCoordinator.export"),
                       "a second write below the check would run after a stop")
        XCTAssertFalse(afterCheck.contains("createDirectory"),
                       "a directory created below the check is residue a stopped run "
                       + "leaves in the delivery folder")
    }

    /// The encoder writes to a temp and the delivery is a rename — the property the
    /// whole cancel design rests on, asserted where it actually lives.
    func testTheDeliveredPathIsOnlyEverCreatedByARename() throws {
        let renderer = Self.repositoryRoot
            .appendingPathComponent("Sources/LumenPipeline/PipelineRenderer.swift")
        let source = Self.withoutComments(
            try String(contentsOf: renderer, encoding: .utf8))
        let write = try XCTUnwrap(body(from: "private func write(_ image: CIImage",
                                       in: source),
                                  "PipelineRenderer.write was renamed")

        XCTAssertTrue(write.contains("Self.partialURL(for: destination)"),
                      "the encode must go to a sibling temp")
        for encoder in ["writeJPEGRepresentation", "writeHEIFRepresentation",
                        "writeHEIF10Representation", "writePNGRepresentation",
                        "writeTIFFRepresentation"] {
            for line in lines(containing: encoder, in: write) where line.contains("to:") {
                XCTAssertTrue(line.contains("to: partial"),
                              "\(encoder) writes straight to the delivery path: a "
                              + "cancelled or failed run leaves a truncated file under "
                              + "the name a photographer will ship — \(line)")
            }
        }
        XCTAssertTrue(write.contains("moveItem(at: partial, to: destination)"),
                      "the delivery must arrive by a same-directory rename")
    }

    // MARK: - B. A stale click cannot cancel the next run

    /// Two writers of the flag, both in `AppState.swift`, both named verbs.
    ///
    /// `private(set)` is file-scoped in Swift, not declaration-scoped: any code in
    /// `AppState.swift` can write this property. The guard that makes a stale click
    /// harmless lives in ONE of those two functions, so a third writer anywhere in that
    /// file is a way to arm the flag without passing it.
    func testOnlyTheTwoNamedVerbsWriteTheFlag() throws {
        let source = try code("AppState.swift")
        // The DECLARATION is not one of the two verbs. `@Published private(set) var
        // exportCancelRequested = false` carries an `=` and would otherwise be counted
        // as a third writer, which is what this assertion used to do — it read three,
        // asserted two, and failed while describing the very shape it was looking at.
        let writes = lines(containing: "exportCancelRequested", in: source)
            .filter { $0.contains("=") && !$0.contains("==") }
            .filter { !$0.contains("var exportCancelRequested") }
        XCTAssertEqual(writes.count, 2,
                       "the declaration's initialiser must be joined by exactly two "
                       + "assignments, one per named verb — found: \(writes)")

        let arm = try XCTUnwrap(body(from: "func cancelExport()", in: source))
        XCTAssertTrue(arm.contains("guard isExporting else { return }"),
                      "the arming verb must refuse when no batch is running, or a click "
                      + "left over from the last run cancels the next one")
        let armIndex = try XCTUnwrap(arm.range(of: "exportCancelRequested"))
        let guardIndex = try XCTUnwrap(arm.range(of: "guard isExporting"))
        XCTAssertTrue(guardIndex.lowerBound < armIndex.lowerBound)

        XCTAssertNil(body(from: "func clearExportCancel()", in: source)?
                        .range(of: "isExporting"),
                     "disarming is unconditional on purpose; a guard here would leave "
                     + "the flag set across the end of a batch")
    }

    /// Both ends of a batch disarm, and the disarm at the far end shares one main-actor
    /// hop with `isExporting = false`.
    ///
    /// This is the interleaving that beats a naive guard: the batch takes its last look
    /// at the flag, finds it clear, and falls out of the loop — and the photographer
    /// clicks Cancel in the window before the run is marked finished. `isExporting` is
    /// still true, so the click arms the flag for a run that is already over. What makes
    /// it harmless is that the closing hop clears the flag in the SAME main-actor block
    /// that clears `isExporting`, with no `await` between them for the click to land in.
    func testTheClosingHopDisarmsWithoutSuspendingMidway() throws {
        let source = try code("AppStateActions.swift")
        let export = try XCTUnwrap(body(from: "func export(to directory: URL)",
                                        in: source))

        // On the way in, before the Task is made.
        let taskIndex = try XCTUnwrap(export.range(of: "Task {"))
        let head = String(export[..<taskIndex.lowerBound])
        XCTAssertTrue(head.contains("clearExportCancel()"),
                      "a restarted batch would inherit the stop that ended the last one")
        XCTAssertTrue(head.contains("isExporting = true"))

        // On the way out, in one uninterrupted block.
        let closing = try XCTUnwrap(
            export.components(separatedBy: "await MainActor.run {").last,
            "the closing main-actor hop was restructured")
        let finished = try XCTUnwrap(closing.range(of: "self.isExporting = false"))
        let disarmed = try XCTUnwrap(closing.range(of: "self.clearExportCancel()"))
        let between = String(closing[finished.upperBound..<disarmed.lowerBound])
        XCTAssertFalse(between.contains("await"),
                       "a suspension between marking the run finished and disarming is "
                       + "a window in which a click arms the flag and nothing clears it")
    }

    /// Nothing but the sheet's own button reaches the arming verb, and the button that
    /// STARTS a run is dead while one is running.
    ///
    /// The sheet stays up for the length of the batch now, so the Export button is on
    /// screen and clickable throughout — and `export(to:)` has no re-entrancy guard of
    /// its own. A second batch started over the first would run with its own `claimed`
    /// set (two runs can therefore claim the same delivery path and one silently
    /// replaces the other), and the first run to finish would set `isExporting = false`
    /// under the second, putting the second beyond the reach of `cancelExport()`
    /// entirely. The ONLY thing standing between the photographer and that is this
    /// `.disabled`.
    func testTheExportButtonIsDeadWhileABatchRuns() throws {
        let sheet = try code("ExportSheet.swift")
        XCTAssertTrue(sheet.contains("let exportDisabled: Bool = fileCount == 0 "
                                     + "|| state.isExporting"),
                      "the Export button's disable no longer mentions `isExporting`: "
                      + "with the sheet staying up for the run, that is a second batch "
                      + "one click away")
        let actions = try XCTUnwrap(body(from: "private var footerActions", in: sheet))
        XCTAssertTrue(actions.contains(".disabled(exportDisabled)"),
                      "the computed flag must actually reach the button")

        // And `export(to:)` really does have no guard of its own — pinned so that if the
        // `.disabled` above is ever the only thing holding the line, that fact is stated
        // here rather than discovered from a folder of half-overwritten deliveries.
        let source = try code("AppStateActions.swift")
        let export = try XCTUnwrap(body(from: "func export(to directory: URL)",
                                        in: source))
        let head = try XCTUnwrap(export.components(separatedBy: "Task {").first)
        XCTAssertFalse(head.contains("guard !isExporting"),
                       "if a re-entrancy guard is ever added, delete this assertion and "
                       + "the note above it")
    }

    // MARK: - C. The batch says what happened

    /// `stopped` starts false and turns true only on the way to a labelled break.
    func testStoppedIsSetNowhereButAtACancellation() throws {
        let source = try code("AppStateActions.swift")
        let export = try XCTUnwrap(body(from: "func export(to directory: URL)",
                                        in: source))
        XCTAssertTrue(export.contains("var stopped = false"),
                      "the flag must start false, or a run nobody halted reports a halt")
        XCTAssertEqual(occurrences(of: "stopped = true", in: export), 2)
        XCTAssertEqual(occurrences(of: "stopped =", in: export), 3,
                       "declaration plus the two cancellations, and nothing else")
    }

    /// The three status branches are mutually exclusive and `stopped` wins.
    func testAHaltedRunCannotReportAFinishedOne() throws {
        let source = try code("AppStateActions.swift")
        let export = try XCTUnwrap(body(from: "func export(to directory: URL)",
                                        in: source))
        let stoppedBranch = try XCTUnwrap(export.range(of: Self.haltedBranchHead))
        let cleanBranch = try XCTUnwrap(export.range(of: "} else if failures.isEmpty {"))
        XCTAssertTrue(stoppedBranch.lowerBound < cleanBranch.lowerBound,
                      "`Exported N files` must be unreachable for a halted run")
        XCTAssertTrue(export.contains("\"Stopped — \\(written) file\""),
                      "the halted message must lead with the fact of the halt")
    }

    /// DEFECT — a cancel that lands on the last file of a batch reports a COMPLETE
    /// delivery as "Stopped".
    ///
    /// The check after the final file runs whether or not there is another file behind
    /// it, so clicking Cancel while the last frame encodes sets `stopped` and breaks out
    /// of a loop that was ending anyway. Every file was written; nothing was skipped; the
    /// status line says `Stopped — 200 files of 200 written`. The photographer is now
    /// holding a whole delivery that the app says was interrupted, and the only way to
    /// find out otherwise is to read the two numbers and notice they match — which is
    /// precisely the arithmetic the message exists to save them.
    ///
    /// The fix is one condition: a run whose written count reached the total finished,
    /// whatever was clicked on the way. Asserted here as the shipped prose's own
    /// standard — "the whole point of the button is that they know it did not finish".
    func testStoppedIsNotClaimedForADeliveryThatIsWhole() throws {
        let source = try code("AppStateActions.swift")
        let export = try XCTUnwrap(body(from: "func export(to directory: URL)",
                                        in: source))
        let condition = try XCTUnwrap(export.range(of: Self.haltedBranchHead))
        let head = String(export[..<condition.upperBound])
        let guarded = head.contains("stopped && written < Int(total)")
            || head.contains("stopped, written < Int(total)")
            || head.contains("Double(written) < total")
        XCTAssertTrue(guarded,
                      "`if stopped` alone reports a halt for a batch cancelled during "
                      + "its final file, in which every planned file was written")

        // And the anchor is not free to drift back: an `if stopped {` with nothing
        // after the flag is the defect returning, and would satisfy neither the
        // constant above nor this.
        XCTAssertFalse(export.contains("if stopped {"),
                       "the bare `if stopped {` is back — a complete delivery "
                       + "cancelled on its final file will report as interrupted")
    }

    /// DEFECT — the halted message counts failures without naming one.
    ///
    /// The branch below it makes the argument in its own comment: "'2 failed' leaves a
    /// photographer with no way to tell a disk error from masking that could not be
    /// read, and the second one is the one that decides whether the delivery can go out
    /// at all" — and then names `failures.first`. The stopped branch appends
    /// `" — \(failures.count) failed"` and stops there, so the one run that most needs
    /// the detail (halted early, part-delivered, something also went wrong) is the one
    /// run that does not get it.
    func testTheHaltedMessageNamesItsFirstFailureToo() throws {
        let source = try code("AppStateActions.swift")
        let export = try XCTUnwrap(body(from: "func export(to directory: URL)",
                                        in: source))
        let stoppedBranch = try XCTUnwrap(export.range(of: Self.haltedBranchHead))
        let elseBranch = try XCTUnwrap(export.range(of: "} else if failures.isEmpty {"))
        let halted = String(export[stoppedBranch.upperBound..<elseBranch.lowerBound])
        XCTAssertTrue(halted.contains("failures.first"),
                      "the halted status line counts failures but names none, against "
                      + "the rule the branch two lines below it states and follows")
    }

    // MARK: - D. The soft proof that travels with the batch

    /// Captured once, on the main actor, before the batch — and it is the accessor the
    /// viewer reads, not a second reading of the same settings.
    ///
    /// Re-reading per file is the WRONG answer even though it sounds more responsive: a
    /// batch is one command with one set of terms, and a proof re-read per frame would
    /// deliver the first fifty files through the print profile and the rest through the
    /// working space depending on when a key happened to be pressed — a folder no one
    /// could reproduce or reason about. Every other term of the run is snapshotted the
    /// same way (`jobs`, `active`, `total`), and this is the one that decides what the
    /// pixels ARE.
    func testTheProofIsSnapshotOnceFromTheAccessorTheViewerUses() throws {
        let source = try code("AppStateActions.swift")
        let export = try XCTUnwrap(body(from: "func export(to directory: URL)",
                                        in: source))
        XCTAssertEqual(occurrences(of: "activeSoftProof", in: export), 1,
                       "a second reading inside the loop would make the delivery depend "
                       + "on when a keystroke landed relative to a file boundary")
        let capture = try XCTUnwrap(export.range(of: "let proof = activeSoftProof"))
        let task = try XCTUnwrap(export.range(of: "Task {"))
        XCTAssertTrue(capture.lowerBound < task.lowerBound,
                      "the capture must happen on the main actor before the batch")
        XCTAssertTrue(export.contains("softProof: proof)"),
                      "the captured value must actually reach the renderer")

        // The same accessor, not a parallel reading of `softProof`.
        for view in ["LoupeView.swift", "CompareView.swift", "RenderRequest.swift"] {
            let text = try code(view)
            XCTAssertTrue(text.contains("softProof: state.activeSoftProof"),
                          "\(view) stopped rendering through `activeSoftProof`, so the "
                          + "picture on screen and the picture in the file are no longer "
                          + "the same picture by construction")
        }
    }

    /// Neither instrument can be baked into a file.
    ///
    /// `showGamutWarning` paints flat grey over every pixel the destination cannot hold —
    /// in a delivery that is grey blocks where the flowers were. `simulatePaperWhite`
    /// compresses the picture into ink-black-to-paper-white so the screen can show how
    /// flat the print will look; a file that arrives already compressed gets compressed
    /// again by the paper and prints muddy. Both are pictures OF the medium.
    func testTheDeliveredProofDropsBothInstrumentsAndKeepsTheMapping() throws {
        let renderer = Self.repositoryRoot
            .appendingPathComponent("Sources/LumenPipeline/PipelineRenderer.swift")
        let source = Self.withoutComments(
            try String(contentsOf: renderer, encoding: .utf8))
        let delivered = try XCTUnwrap(
            body(from: "static func deliveredProof(_ viewing: SoftProof?)", in: source),
            "deliveredProof was renamed; the export path's only filter on the proof")

        XCTAssertTrue(delivered.contains("delivered.showGamutWarning = false"))
        XCTAssertTrue(delivered.contains("delivered.simulatePaperWhite = false"))
        XCTAssertTrue(delivered.contains("guard let viewing, viewing.enabled else "
                                         + "{ return nil }"),
                      "a disabled proof must not cost a table bake")
        XCTAssertFalse(delivered.contains("delivered.space ="),
                       "the destination primaries are a decision about DATA and must "
                       + "survive into the file")
        XCTAssertFalse(delivered.contains("delivered.intent ="),
                       "the photographer approved the compressed rendition; dropping "
                       + "the intent ships a per-channel clip instead")

        // And the export plan is the only plan that filters — the viewer's must not.
        let exportPlan = try XCTUnwrap(
            body(from: "func exportPlan(source: any ImageSource", in: source))
        XCTAssertTrue(exportPlan.contains("softProof: Self.deliveredProof(softProof)"))
    }

    // MARK: - E. The sheet stays up

    /// The run's outcome is announced somewhere the photographer is looking.
    ///
    /// DEFECT, and it is the cost of the sheet staying up: the status line the batch
    /// writes — "Stopped — 4 files of 200 written", the sentence the whole of claim C is
    /// about — goes to `AppState.statusMessage`, which only `ContentView`'s status bar
    /// draws, and the sheet is still covering the window when it lands. The sheet's own
    /// progress section is `if state.isExporting`, so at the moment there is something
    /// to say it has just disappeared, leaving a dialog that looks exactly as it did
    /// before Export was pressed.
    ///
    /// Related and pinned in the same test: while a stop is PENDING, the always-visible
    /// surface still reads "Exporting N%" and the percentage keeps climbing through the
    /// file being finished. `exportCancelRequested` is `@Published` and no view reads
    /// it; only the sheet's own local `cancelRequested` says "Cancelling", and that is
    /// the surface the photographer may well have closed.
    func testTheStatusBarSaysWhenAStopIsPending() throws {
        let content = try code("ContentView.swift")
        // THE WHOLE BODY, not a window of characters. This assertion used to take the
        // 320 characters after the `if`, and `withoutComments` blanks a comment to
        // SPACES OF THE SAME LENGTH so that offsets and line numbers survive. The eight
        // lines of prose arguing for this fix therefore sat between the `if` and the
        // code, and pushed `exportCancelRequested` to 626 characters out — so the test
        // failed against a tree in which the thing it asks for was already there, and
        // it failed BECAUSE the fix had been explained. A window measured in characters
        // over stripped source is a length measurement dressed up as a scope; the
        // brace-matched body is the scope.
        let bar = try XCTUnwrap(body(from: "if state.isExporting", in: content),
                                "the status bar's export readout was moved")
        XCTAssertTrue(bar.contains("exportCancelRequested"),
                      "the one always-visible sign of a running export claims "
                      + "\"Exporting N%\" for a batch that is already stopping, and it "
                      + "is the only sign left once the sheet is closed")
    }

    /// The sheet does not shut itself, and Close is not wired to the stop.
    ///
    /// ⎋ is the sheet's Close. The stop deliberately carries no shortcut, so a
    /// photographer who hits ⎋ meaning "put this dialog away" cannot thereby throw away
    /// twenty minutes of finished exports. Both halves are pinned: a Close that
    /// cancelled, or a stop that answered ⎋, would be the same mistake from either end.
    func testTheSheetStaysUpAndEscapeDoesNotStopTheBatch() throws {
        let source = try code("AppStateActions.swift")
        let chooser = try XCTUnwrap(body(from: "func chooseExportDestination()",
                                         in: source))
        XCTAssertFalse(chooser.contains("showExportSheet"),
                       "the sheet must not dismiss itself: closing it puts the progress "
                       + "readout and the stop behind a door that shut itself")
        XCTAssertTrue(chooser.contains("export(to: url)"))

        let sheet = try code("ExportSheet.swift")
        let cancel = try XCTUnwrap(body(from: "private var cancelButton", in: sheet))
        XCTAssertFalse(cancel.contains("keyboardShortcut"),
                       "the stop must not answer a key; ⎋ already means Close here")
        XCTAssertTrue(cancel.contains("state.cancelExport()"))
        XCTAssertTrue(cancel.contains(".disabled(cancelRequested)"),
                      "a stop that can be pressed five times is a control that looks "
                      + "broken for the one photograph the batch takes to notice")

        let close = try XCTUnwrap(lines(containing: "Button(\"Close\")", in: sheet).first)
        XCTAssertTrue(close.contains("state.showExportSheet = false"))
        XCTAssertFalse(close.contains("cancelExport"),
                       "putting the dialog away must never end the delivery")
    }

    /// The one-presenter sheet slot means any other sheet takes the stop off screen.
    ///
    /// `activeSheet` holds exactly one sheet, and the Help menu's ⌘/ and the ingest
    /// sheet both write it unconditionally. With the export sheet now up for the length
    /// of a run, either of them replaces the only Cancel button in the app while the
    /// batch keeps writing. Recoverable — ⌘E brings it back — but the recovery is not
    /// something the photographer is told about, and the sheet comes back with its local
    /// `cancelRequested` reset, so a stop already asked for reads as un-asked.
    func testTheStopSurvivesOnlyBecauseTheExportSheetHoldsTheOnePresenterSlot() throws {
        let state = try code("AppState.swift")
        XCTAssertTrue(state.contains("@Published var activeSheet: SheetKind?"),
                      "one presenter, one sheet at a time — the premise of this test")
        let app = try code("LumenApp.swift")
        XCTAssertTrue(app.contains("state.showKeyReference = true"),
                      "⌘/ writes the same slot the running export's sheet occupies")

        // What would make this safe is either a re-entrancy-proof stop outside the sheet
        // or a guard on the other presenters while a batch runs. Neither exists; pinned
        // so the absence is stated rather than assumed.
        XCTAssertFalse(state.contains("guard !isExporting else { return }\n"
                                      + "        activeSheet"),
                       "if the presenters ever learn about a running batch, this "
                       + "assertion and the note above it should be replaced")
    }

    // MARK: - Cancel and resume

    /// Restarting a cancelled batch into the same folder duplicates every file the
    /// first run delivered.
    ///
    /// This is not a bug in `disambiguated` — refusing to overwrite is deliberate and
    /// right — but it is the shape of the ONE workflow the stop button creates: halt,
    /// change something, run it again. The second run sees the first run's deliveries on
    /// disk, renames around every one of them, and the folder ends up holding
    /// `frame.jpg` and `frame-1.jpg` for each frame the first run got through. Asserted
    /// through LumenCore, which runs everywhere, so the behaviour is stated in a test
    /// rather than discovered in a delivery folder.
    func testResumingACancelledRunRenamesAroundItsOwnEarlierDeliveries() {
        let already: Set<String> = ["frame.jpg"]
        let first = ExportRecipe.disambiguated(URL(fileURLWithPath: "/out/frame.jpg")) {
            already.contains($0.lastPathComponent)
        }
        XCTAssertNotEqual(first.lastPathComponent, "frame.jpg",
                          "the resumed run must not silently replace what the halted "
                          + "run delivered")
        XCTAssertEqual(first.deletingLastPathComponent().path, "/out")
        XCTAssertTrue(first.pathExtension == "jpg",
                      "the extension has to survive the disambiguation, or the resumed "
                      + "run writes files no photo application will open")
    }
}
#endif

// RawCorpusTests.swift
// The first tests in this project's history that open a file a camera made.
//
// Everything else in Tests/ uses a synthetic frame or a stub ImageSource — correctly,
// because those tests are about the graph. The consequence is that CIRAWFilter,
// CGImageSourceCopyPropertiesAtIndex and the whole decode path have never seen a byte
// this repository did not generate. A camera whose orientation tag we mishandle, a
// decode that returns unexpected dimensions, EXIF that does not land, a cast on one
// manufacturer's files: none of it is visible to any existing lane.
//
// THESE ARE INVARIANTS, NOT GOLDENS, and the distinction is the whole design. A golden
// per camera is sixteen maintenance obligations that go stale the first time Apple ships
// a decoder update, and a lane whose failures are usually noise is a lane people learn
// to ignore. Every assertion below is either a property that must hold of any photograph
// from any camera, or a cross-check between two independent readers of the same bytes.
// The one pinned number is the EXIF orientation tag, which is in the file's bytes, and
// the file is pinned by sha256 — see docs/audit-2026-09/w6/raw-corpus-plan.md §5.1.
//
// The corpus is not in the repository. It is 234 MB of CC0 RAW files fetched and cached
// by .github/workflows/raw-corpus.yml, which points LUMEN_RAW_CORPUS at the directory.
// Without that variable every test here SKIPS, so `swift test` on a developer machine
// and the gpu-parity lane (which runs `--filter LumenPipelineTests` and does not set the
// variable) are unaffected. The corpus lane greps its own log for the expected file
// count, because a check that skips silently is a check that cannot fail.
//
// THREE MECHANICAL CONTRACTS WITH THE WORKFLOW. Break one and the lane reports green
// having proved nothing, or fails for a reason that is not a defect:
//
//   1. THE CLASS IS NAMED `RawCorpusTests`, because the lane runs
//      `swift test --filter RawCorpusTests`. Run 2 of this lane fetched all sixteen
//      files, verified all eighteen manifest rows, built the package — and printed
//      "Executed 0 tests", because this file did not exist. A rename here is a rename
//      in raw-corpus.yml in the same commit.
//   2. EVERY ROW OF THE MANIFEST GETS A `corpus-file: <id>` LINE AT LINE START, emitted
//      before anything that could hang. The workflow's last step counts those lines and
//      fails when the count is under the manifest's row count. `ci.yml` names this trap
//      about CSQLite3 — "a green run that had never built a third of LumenCore is the
//      same shape as a check that cannot fail" — and a test class gated on an
//      environment variable is exactly that shape.
//   3. THE INVENTORY IS PRINTED FIRST, from `class setUp`, before a single assertion.
//      Plan §9.2: the only question everything downstream is conditional on is which of
//      the sixteen files CIRAWFilter opened at all.
//
// AND TWO THRESHOLDS SHIP LOOSE ON PURPOSE. R-5's preview correlation floor (0.6) and
// R-7's neutral-patch chroma ceiling (20) are first guesses, and both are treated as
// one: the measured value for every file is logged on EVERY run, passes included, into
// the log and into the evidence sheet. After the first green run they get set from
// sixteen real numbers instead of being guessed at a second time. R-11's decoder version
// is logged and never asserted against a constant, because it legitimately moves when
// Apple ships a decoder and pinning it would make a runner-image bump a red build with
// no defect behind it.

#if os(macOS)

import CoreGraphics
import CoreImage
import Dispatch
import Foundation
import ImageIO
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// A result slot a background worker can fill while the test thread waits on a
/// semaphore. A class rather than a captured `var` so the watchdog does not need to
/// mutate a local from concurrently-executing code, which is the shape the compiler
/// rejects outright under Swift 6 and grumbles about under 5.
private final class ResultBox<Value>: @unchecked Sendable {
    var value: Value?
}

final class RawCorpusTests: XCTestCase {

    // MARK: - The manifest

    /// One row of corpus.tsv. Deliberately thin: a path, a digest, a manufacturer token,
    /// the EXIF orientation exiv2 read, and flags. No dimensions, no colours — see the
    /// plan §5.1 for why every number that could go stale is measured on the runner.
    struct CorpusEntry {
        let id: String
        let local: String
        let sha: String
        let bytes: Int
        /// The token `CaptureMetadataReader.joinCamera`'s output must contain, matched
        /// case-insensitively. "-" for the synthetic negatives.
        let makeToken: String
        /// What exiv2 read. Nil when the manifest records none — then the test reads the
        /// file's own tag and does not cross-check, which is the honest thing to do with
        /// a number nobody has a second opinion on.
        let orientation: Int?
        let flags: Set<String>
        let licence: String
        let label: String
        let url: URL

        var isNegative: Bool { flags.contains("negative") }
        var isHardNegative: Bool { flags.contains("hard") }
        var isMono: Bool { flags.contains("mono") }
    }

    /// Width and height as one value, so a transpose is a comparison rather than four
    /// index errors.
    struct Dim {
        let w: Int
        let h: Int
        var pixels: Double { Double(w) * Double(h) }
        var isLandscape: Bool { w > h }
        var isSquare: Bool { w == h }
        var longEdge: Int { Swift.max(w, h) }
        var text: String { "\(w)x\(h)" }
    }

    /// Everything measured about one file, filled once and read by every test.
    ///
    /// A class, so the memoized instance handed to eight tests is the one that got
    /// filled. Nothing here holds pixels: the buffers are reduced to scalars and to a
    /// 32×32 grid and then dropped, because sixteen 40 MP frames held simultaneously is
    /// how a rationed runner starts swapping.
    final class Probe {
        let id: String
        init(id: String) { self.id = id }

        var existsOnDisk = false
        var measured = false

        /// Which operations did not finish inside the watchdog's ceiling (R-1).
        var hung: [String] = []

        // Tier 0
        var openFailure: String?
        var opened = false
        var decodeReturnedNil = false
        var decodedExtent: CGRect?
        var extentUsable: Bool?

        // Tier 1
        var exif: Dim?
        var exifOrientation: Int?
        var native: Dim?
        var delivered: Dim?
        var renderFailure: String?

        // R-5
        var previewCorrelation: Double?
        var previewSource = "-"
        var previewSize = "-"
        var previewNote = "-"

        // R-6
        var floatSamples = 0
        var nonFiniteSamples = 0
        var nonFiniteFirst: String?
        var floatReadbackNote = "-"
        var meanLuma: Double?
        var p5: Double?
        var p95: Double?
        var nearBlackFraction: Double?
        var nearWhiteFraction: Double?

        // R-7 / R-7b
        var minChroma: Double?
        var medianChroma: Double?
        var chromaNote = "-"

        // R-8
        var exportError: String?
        var exportBytes: Int?
        var exportPixels: Dim?
        var exportClaimed: Dim?
        var exportOrientation: Int?
        var exportRan = false

        // R-10
        var metadataRead = false
        var camera: String?
        var metaWidth: Int?
        var metaHeight: Int?
        var metaOrientation: Int?
        var captureAt: Int64?
        var iso: Int?

        // R-11
        var pin: Int?
        var pinSecond: Int?
        var pinReadTwice = false

        /// The one-word answer the inventory leads with.
        var verdict: String {
            if !existsOnDisk { return "MISSING" }
            if !hung.isEmpty {
                let names = hung.joined(separator: RawCorpusTests.comma)
                return "HUNG(" + names + ")"
            }
            if openFailure != nil { return "refused-at-open" }
            if decodeReturnedNil { return "refused-at-decode" }
            if extentUsable == false { return "BAD-EXTENT" }
            if delivered != nil { return "decoded" }
            if opened { return "opened-not-rendered" }
            return "unknown"
        }

        var decodedCleanly: Bool {
            existsOnDisk && hung.isEmpty && openFailure == nil
                && !decodeReturnedNil && extentUsable == true
        }
    }

    // MARK: - Shared state

    // A `swift test` process runs this class once, sequentially. These are filled by
    // `class setUp` and completed lazily by whichever test asks for a file first, so no
    // test depends on XCTest's method ordering to find its measurements.
    private static var entries: [CorpusEntry] = []
    private static var probes: [String: Probe] = [:]
    private static var loadFailure: String?
    private static var corpusRoot: URL?

    private static let renderer = PipelineRenderer()

    /// Exports go to the process's temp directory, NOT into the corpus directory — that
    /// one is `actions/cache`'s, and sixteen TIFFs written into it would be cached
    /// alongside the RAWs on the next miss.
    private static let exportDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lumen-raw-corpus-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The preview render size, and the export's long edge. 1024 keeps sixteen renders
    /// inside a rationed runner; the export deliberately runs at full decode scale
    /// because that is the path a delivered file actually takes.
    private static let previewLongEdge = 1024
    private static let exportLongEdge = 1600

    /// R-1's ceiling. A hung decoder otherwise eats the job's whole 45 minutes and
    /// reports nothing at all, which is strictly worse than a red build: a cancelled
    /// lane tells you the runner died, not which file killed it.
    private static let watchdogSeconds: TimeInterval = 120
    /// The export decodes at scaleFactor 1.0 — a full-sensor demosaic and a full-sensor
    /// materialization, which is a different order of work from a 1024 px preview and
    /// deserves its own ceiling rather than making the 40 MP file trip the preview's.
    private static let exportWatchdogSeconds: TimeInterval = 300

    // MARK: - Output

    /// Write one whole line, unbuffered, starting at column zero.
    ///
    /// `print` goes through stdio, which FULLY buffers when stdout is a pipe — and the
    /// workflow pipes it through `tee`. XCTest's own progress lines arrive on the same
    /// merged stream. So: one `fputs` of a complete string, flushed immediately, with a
    /// leading newline so that `grep -E '^corpus-file: '` still matches even if
    /// something else left a line half-written.
    /// Separators as named constants, and the reason is not style.
    ///
    /// `scripts/check-swift-surface.py` strips string literals before it walks a call's
    /// arguments, and a literal nested INSIDE a string interpolation defeats that strip:
    /// `"\(xs.joined(separator: ", "))"` reads to it as a two-argument call, and
    /// `"\(ok ? "yes" : "NO")"` reads as a reference to a type called `NO`. Both are
    /// false positives, both fail `ci.yml`'s surface check, and the cheapest fix is on
    /// this side — so nothing in this file puts a quote inside an interpolation.
    static let dash = "-"
    static let comma = ","
    static let commaSpace = ", "

    private static func emit(_ line: String) {
        fputs("\n" + line + "\n", stdout)
        fflush(stdout)
    }

    private static func fmt(_ value: Double?, _ digits: Int = 4) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.\(digits)f", value)
    }

    private static func fmt(_ value: Int?) -> String {
        guard let value else { return "-" }
        return String(value)
    }

    // MARK: - Class setup: the inventory, before anything else

    override class func setUp() {
        super.setUp()
        let raw = ProcessInfo.processInfo.environment["LUMEN_RAW_CORPUS"] ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty is refused as well as missing, for the same reason
        // `ControlProofTests.isRecording` refuses empty: GitHub sets an unset expression
        // to "", and a check that reads mere presence reads that as yes.
        guard !trimmed.isEmpty else { return }

        let root = URL(fileURLWithPath: trimmed, isDirectory: true)
        corpusRoot = root
        let manifest = root.appendingPathComponent("corpus.tsv")

        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else {
            let note = "LUMEN_RAW_CORPUS is \(trimmed) but \(manifest.path) could not be "
                + "read. The lane writes that file before it runs the tests; if it is "
                + "absent the corpus was never assembled."
            loadFailure = note
            emit("corpus-error: \(note)")
            return
        }

        // CONTRACT 2, and it happens BEFORE anything that could hang or trap. ONE
        // `corpus-file:` line per line the workflow's `grep -c ';'` counts — including a
        // line this parser could not read, which is reported as unparseable rather than
        // silently dropped: a row that vanishes between the YAML's count and this
        // suite's would fail the guard with no explanation of which row it was.
        var parsed: [CorpusEntry] = []
        var seenIDs = Set<String>()
        var duplicates: [String] = []
        for (index, line) in countedLines(text).enumerated() {
            guard let row = parseRow(line, root: root) else {
                emit("corpus-file: line-\(index + 1) UNPARSEABLE — ten "
                    + "semicolon-separated columns expected; got \(line)")
                continue
            }
            let exists = FileManager.default.fileExists(atPath: row.url.path)
            let presence = exists ? "yes" : "no (the fetch step did not leave it)"
            emit("corpus-file: \(row.id) file=\(row.local) "
                + "exists=\(presence) bytes=\(row.bytes) "
                + "licence=\(row.licence) · \(row.label)")
            // A repeated id is not a reason to test the same file twice.
            //
            // It is also not hypothetical: the lane APPENDS the two synthetic negatives
            // to corpus.tsv, and corpus.tsv lives inside the directory `actions/cache`
            // saves — so a cache hit can restore a manifest that already carries them
            // and the append runs again. The `corpus-file:` line above is still emitted
            // for the duplicate, so the guard's count stays right; the suite below sees
            // each file once.
            if seenIDs.contains(row.id) {
                duplicates.append(row.id)
                continue
            }
            seenIDs.insert(row.id)
            let probe = Probe(id: row.id)
            probe.existsOnDisk = exists
            probes[row.id] = probe
            parsed.append(row)
        }
        if !duplicates.isEmpty {
            let list = duplicates.joined(separator: commaSpace)
            emit("corpus-note: corpus.tsv carries repeated ids (\(list)); each file is "
                + "tested once. See raw-corpus.yml's negatives step and the cache.")
        }
        entries = parsed
        guard !entries.isEmpty else {
            let note = "\(manifest.path) parsed to zero rows — the manifest is "
                + "semicolon-separated with ten columns; see raw-corpus.yml."
            loadFailure = note
            emit("corpus-error: \(note)")
            return
        }

        // CONTRACT 3. Opening is cheap — `CIRAWFilter(imageURL:)` plus one
        // `CGImageSourceCopyPropertiesAtIndex`, no demosaic — so the answer to "which of
        // the sixteen did CIRAWFilter open at all" is on screen in seconds, before the
        // first assertion and before the first full-sensor decode.
        emit("=== RAW corpus inventory · which files CIRAWFilter opened at all ===")
        let gpuPath = renderer.isGPUPathAvailable ? "available" : "not available"
        emit("corpus-inventory: dir=\(root.path) rows=\(entries.count) "
            + "gpu-path=\(gpuPath)")
        var openedCount = 0
        for entry in entries {
            guard let probe = probes[entry.id] else { continue }
            guard probe.existsOnDisk else {
                emit("corpus-open: \(entry.id) MISSING")
                continue
            }
            if let geometry = containerGeometry(entry.url) {
                probe.exif = geometry.dim
                probe.exifOrientation = geometry.orientation
            }
            do {
                let source = try AppleRawSource(url: entry.url)
                probe.opened = true
                probe.pin = source.pinnedDecoderVersion
                let size = source.nativePixelSize
                probe.native = Dim(w: size.width, h: size.height)
                openedCount += 1
            } catch {
                probe.openFailure = String(describing: error)
            }
            let opening = probe.opened ? "opened" : "refused"
            let readE = probe.exif?.text ?? dash
            let readN = probe.native?.text ?? dash
            emit("corpus-open: \(entry.id) \(opening) "
                + "E=\(readE) N=\(readN) "
                + "exif-orient=\(fmt(probe.exifOrientation)) "
                + "manifest-orient=\(fmt(entry.orientation)) "
                + "pin=\(fmt(probe.pin)) · \(entry.label)")
        }
        emit("corpus-inventory: CIRAWFilter opened \(openedCount) of \(entries.count) files")

        // A stale evidence directory would otherwise be restored from the cache and
        // uploaded next to this run's log. Fresh every run.
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        try? FileManager.default.removeItem(at: evidence)
        try? FileManager.default.createDirectory(at: evidence,
                                                 withIntermediateDirectories: true)
    }

    /// The evidence sheet, written after every test in the class has run.
    ///
    /// This is what turns R-5's and R-7's guessed thresholds into measured ones, and it
    /// is where R-11's decoder pin is reported rather than enforced. It is also echoed to
    /// stdout, because an artifact upload that does not happen (a crashed process, a
    /// cancelled job) must not take the measurements with it.
    override class func tearDown() {
        defer { super.tearDown() }
        guard !entries.isEmpty else { return }

        var rows: [String] = []
        let header: [String] = [
            "id", "verdict", "label", "E", "N", "D",
            "manifest_orient", "exif_orient", "export_orient",
            "preview_r", "preview_src", "preview_px",
            "chroma_min", "chroma_median",
            "mean_luma", "p5", "p95", "near_black", "near_white",
            "nonfinite", "float_samples",
            "export_bytes", "export_px", "export_claimed",
            "camera", "iso", "capture_at", "decoder_pin", "decoder_pin_2",
            "hung", "note",
        ]
        rows.append(header.joined(separator: "\t"))
        for entry in entries {
            guard let p = probes[entry.id] else { continue }
            var cells: [String] = []
            cells.append(entry.id)
            cells.append(p.verdict)
            cells.append(entry.label)
            cells.append(p.exif?.text ?? "-")
            cells.append(p.native?.text ?? "-")
            cells.append(p.delivered?.text ?? "-")
            cells.append(fmt(entry.orientation))
            cells.append(fmt(p.exifOrientation))
            cells.append(fmt(p.exportOrientation))
            cells.append(fmt(p.previewCorrelation))
            cells.append(p.previewSource)
            cells.append(p.previewSize)
            cells.append(fmt(p.minChroma, 3))
            cells.append(fmt(p.medianChroma, 3))
            cells.append(fmt(p.meanLuma))
            cells.append(fmt(p.p5))
            cells.append(fmt(p.p95))
            cells.append(fmt(p.nearBlackFraction))
            cells.append(fmt(p.nearWhiteFraction))
            cells.append(String(p.nonFiniteSamples))
            cells.append(String(p.floatSamples))
            cells.append(fmt(p.exportBytes))
            cells.append(p.exportPixels?.text ?? "-")
            cells.append(p.exportClaimed?.text ?? "-")
            cells.append(p.camera ?? "-")
            cells.append(fmt(p.iso))
            if let captureAt = p.captureAt { cells.append(String(captureAt)) }
            else { cells.append("-") }
            cells.append(fmt(p.pin))
            cells.append(fmt(p.pinSecond))
            cells.append(p.hung.isEmpty ? "-" : p.hung.joined(separator: ","))
            var notes: [String] = [p.previewNote, p.chromaNote, p.floatReadbackNote]
            if let failure = p.renderFailure { notes.append(failure) }
            if let failure = p.exportError { notes.append(failure) }
            cells.append(notes.filter { $0 != "-" }.joined(separator: " | "))
            rows.append(cells.joined(separator: "\t"))
        }
        let sheet = rows.joined(separator: "\n") + "\n"

        if let root = corpusRoot {
            let evidence = root.appendingPathComponent("evidence", isDirectory: true)
            try? FileManager.default.createDirectory(at: evidence,
                                                     withIntermediateDirectories: true)
            try? sheet.write(to: evidence.appendingPathComponent("raw-corpus.tsv"),
                             atomically: true, encoding: .utf8)
        }

        emit("=== RAW corpus evidence · every measurement, passes included ===")
        for row in rows { emit("corpus-evidence: " + row) }
        emit("=== RAW corpus · thresholds ship LOOSE; set them from the numbers above ===")
        let correlations = entries.compactMap { probes[$0.id]?.previewCorrelation }
        let chromas = entries.compactMap { probes[$0.id]?.minChroma }
        if let worst = correlations.min() {
            emit("corpus-threshold: R-5 preview correlation floor is 0.60 by guess; "
                + "\(correlations.count) files measured, worst r = \(fmt(worst))")
        }
        if let worst = chromas.max() {
            emit("corpus-threshold: R-7 neutral-patch chroma ceiling is 20 by guess; "
                + "\(chromas.count) files measured, worst chroma = \(fmt(worst, 3))")
        }
        try? FileManager.default.removeItem(at: exportDir)
    }

    /// The lines the workflow's skip-guard counts.
    ///
    /// It runs `grep -c ';'` over corpus.tsv, so the set of rows this suite must report
    /// reaching is exactly "non-empty lines containing a semicolon" — matched here
    /// character for character rather than approximated, because a mismatch either
    /// fails a green run or lets a silent skip through.
    private static func countedLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains(";") }
    }

    /// Semicolon-separated, ten columns; the label is joined back up so a stray `;`
    /// inside it shifts nothing. Every field but the label is trimmed, because the
    /// manifest is written by a heredoc and a leading space in an id is exactly the
    /// class of defect that cost this lane its first run (BSD `wc` right-aligns).
    private static func parseRow(_ line: String, root: URL) -> CorpusEntry? {
        let parts = line.components(separatedBy: ";")
        guard parts.count >= 10 else { return nil }
        func field(_ index: Int) -> String {
            parts[index].trimmingCharacters(in: .whitespaces)
        }
        let id = field(0)
        let local = field(1)
        guard !id.isEmpty, !local.isEmpty else { return nil }
        let flags = Set(field(6).components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != dash })
        let label = parts[8..<(parts.count - 1)].joined(separator: ";")
            .trimmingCharacters(in: .whitespaces)
        return CorpusEntry(
            id: id,
            local: local,
            sha: field(2),
            bytes: Int(field(3)) ?? 0,
            makeToken: field(4),
            orientation: Int(field(5)),
            flags: flags,
            licence: field(7),
            label: label,
            url: root.appendingPathComponent(local))
    }

    /// Skips the whole class when the corpus is absent, and fails loudly when it is
    /// present but unreadable — those are different situations. Absent is a developer's
    /// machine or the gpu-parity lane; present-but-unreadable is this lane broken.
    private func corpus() throws -> [CorpusEntry] {
        let raw = ProcessInfo.processInfo.environment["LUMEN_RAW_CORPUS"] ?? ""
        try XCTSkipUnless(
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "LUMEN_RAW_CORPUS unset — the RAW corpus lane is the only lane that sets it")
        if let failure = RawCorpusTests.loadFailure {
            XCTFail(failure)
            return []
        }
        return RawCorpusTests.entries
    }

    // MARK: - The watchdog (R-1)

    /// Run `work` on a background queue and give up on it after `seconds`.
    ///
    /// Returns nil ONLY on a timeout, so an operation that legitimately answers nil
    /// (a decode that refused) is still distinguishable from one that never answered.
    /// This does NOT attempt to kill the hung thread — it cannot do that safely — it
    /// gives up, and the caller stops touching that file so the leaked worker cannot
    /// race the next measurement against the same source.
    private static func watched<Value>(_ label: String,
                                       seconds: TimeInterval,
                                       _ work: @escaping () -> Value) -> Value? {
        let box = ResultBox<Value>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success else {
            emit("corpus-hang: \(label) — still running after \(Int(seconds))s. "
                + "Hung, not slow; the file is abandoned and the thread leaked.")
            return nil
        }
        return box.value
    }

    // MARK: - Measuring one file, once

    private func probe(for entry: CorpusEntry) -> Probe {
        let existing = RawCorpusTests.probes[entry.id] ?? Probe(id: entry.id)
        RawCorpusTests.probes[entry.id] = existing
        if !existing.measured {
            existing.measured = true
            measure(entry, into: existing)
            RawCorpusTests.emit(measurementLine(entry, existing))
        }
        return existing
    }

    private func measurementLine(_ entry: CorpusEntry, _ p: Probe) -> String {
        var parts: [String] = []
        parts.append("corpus-measure: \(entry.id)")
        parts.append(p.verdict)
        let readE = p.exif?.text ?? RawCorpusTests.dash
        let readN = p.native?.text ?? RawCorpusTests.dash
        let readD = p.delivered?.text ?? RawCorpusTests.dash
        parts.append("E=\(readE)")
        parts.append("N=\(readN)")
        parts.append("D=\(readD)")
        parts.append("orient-manifest=\(RawCorpusTests.fmt(entry.orientation))")
        parts.append("orient-file=\(RawCorpusTests.fmt(p.exifOrientation))")
        parts.append("orient-export=\(RawCorpusTests.fmt(p.exportOrientation))")
        parts.append("r=\(RawCorpusTests.fmt(p.previewCorrelation))")
        parts.append("preview=\(p.previewSource)/\(p.previewSize)")
        parts.append("chroma-min=\(RawCorpusTests.fmt(p.minChroma, 3))")
        parts.append("chroma-med=\(RawCorpusTests.fmt(p.medianChroma, 3))")
        parts.append("mean=\(RawCorpusTests.fmt(p.meanLuma))")
        parts.append("p5=\(RawCorpusTests.fmt(p.p5))")
        parts.append("p95=\(RawCorpusTests.fmt(p.p95))")
        parts.append("black=\(RawCorpusTests.fmt(p.nearBlackFraction))")
        parts.append("white=\(RawCorpusTests.fmt(p.nearWhiteFraction))")
        parts.append("nonfinite=\(p.nonFiniteSamples)/\(p.floatSamples)")
        parts.append("pin=\(RawCorpusTests.fmt(p.pin))/\(RawCorpusTests.fmt(p.pinSecond))")
        let camera = p.camera ?? RawCorpusTests.dash
        parts.append("camera=\(camera)")
        parts.append("· \(entry.label)")
        return parts.joined(separator: " ")
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func measure(_ entry: CorpusEntry, into p: Probe) {
        p.existsOnDisk = FileManager.default.fileExists(atPath: entry.url.path)
        guard p.existsOnDisk else { return }

        if p.exif == nil,
           let geometry = RawCorpusTests.containerGeometry(entry.url) {
            p.exif = geometry.dim
            p.exifOrientation = geometry.orientation
        }

        // R-10's reader runs whatever happens: EXIF is readable from a file that will
        // not decode, and that is worth knowing about the negatives too.
        if let metadata = CaptureMetadataReader.read(url: entry.url) {
            p.metadataRead = true
            p.camera = metadata.camera
            p.metaWidth = metadata.width
            p.metaHeight = metadata.height
            p.metaOrientation = metadata.orientation
            p.captureAt = metadata.captureAt
            p.iso = metadata.iso
        }

        guard let openAttempt = RawCorpusTests.watched(
            "open \(entry.id)", seconds: RawCorpusTests.watchdogSeconds, {
            () -> Result<AppleRawSource, Error> in
            do {
                let opened = try AppleRawSource(url: entry.url)
                return .success(opened)
            } catch {
                return .failure(error)
            }
        }) else {
            p.hung.append("open")
            return
        }
        let source: AppleRawSource
        switch openAttempt {
        case .success(let opened):
            source = opened
        case .failure(let error):
            p.openFailure = String(describing: error)
            return
        }
        p.opened = true
        p.pin = source.pinnedDecoderVersion
        let nativeSize = source.nativePixelSize
        p.native = Dim(w: nativeSize.width, h: nativeSize.height)

        let recipe = Recipe()
        let native = source.nativeLongEdge
        let scale = native > 0
            ? Swift.min(1.0, Double(RawCorpusTests.previewLongEdge) / native)
            : 1.0

        // R-2. The decode itself, at the same scale `renderPreview` will ask for, so
        // this costs the demosaic once and the render below hits the source's cache.
        guard let decoded = RawCorpusTests.watched(
            "decode \(entry.id)", seconds: RawCorpusTests.watchdogSeconds, {
            source.decode(recipe: recipe, draft: false, scaleFactor: scale)
        }) else {
            p.hung.append("decode")
            return
        }
        guard let decodedImage = decoded else {
            p.decodeReturnedNil = true
            _ = source.releaseDecodes()
            return
        }
        let extent = decodedImage.extent
        p.decodedExtent = extent
        // `CGRect.infinite` is legitimate for a Core Image generator, and an infinite
        // extent that reaches the graph is how an allocation of infinite size happens.
        // `DecodeMaterializer` guards it; this is the assertion that the guard is
        // reached from a real file rather than from a synthetic one.
        p.extentUsable = !extent.isInfinite
            && extent.minX.isFinite && extent.minY.isFinite
            && extent.width.isFinite && extent.height.isFinite
            && extent.width >= 1 && extent.height >= 1
        guard p.extentUsable == true else {
            _ = source.releaseDecodes()
            return
        }

        // R-6's finiteness half, on the SCENE-LINEAR decode rather than on the delivered
        // 8-bit frame — see `testTheRenderIsNeitherBlankNorPoisoned` for why that is the
        // surface where a NaN is still a NaN.
        RawCorpusTests.readFiniteness(decodedImage, into: p)

        // R-3/R-4/R-5/R-6/R-7 all read the same delivered frame, rendered once.
        guard let renderAttempt = RawCorpusTests.watched(
            "render \(entry.id)", seconds: RawCorpusTests.watchdogSeconds, {
            () -> Result<CGImage, Error> in
            do {
                let image = try RawCorpusTests.renderer.renderPreview(
                    source: source, recipe: recipe,
                    maxLongEdge: RawCorpusTests.previewLongEdge,
                    draft: false, coarseDecode: false)
                return .success(image)
            } catch {
                return .failure(error)
            }
        }) else {
            p.hung.append("render")
            return
        }
        let delivered: CGImage
        switch renderAttempt {
        case .success(let image):
            delivered = image
        case .failure(let error):
            p.renderFailure = String(describing: error)
            _ = source.releaseDecodes()
            return
        }
        p.delivered = Dim(w: delivered.width, h: delivered.height)

        if let frame = RawCorpusTests.rgbaBytes(delivered) {
            RawCorpusTests.readToneStatistics(frame, into: p)
            RawCorpusTests.readNeutralPatch(frame, into: p)
        } else {
            p.chromaNote = "the delivered frame could not be read back into bytes"
        }

        RawCorpusTests.correlateWithEmbeddedPreview(entry: entry, delivered: delivered,
                                                    into: p)

        // R-8. A full-decode export, which is the path a delivered file actually takes.
        RawCorpusTests.exportAndReopen(entry: entry, source: source, recipe: recipe,
                                       into: p)
        // The export decodes at scaleFactor 1.0, so the source is now holding a
        // full-sensor half-float plane — 330 MB on the 40 MP X-H2. Sixteen of those
        // outliving each other on a 7 GB runner is how this lane starts swapping
        // instead of measuring, and nothing below reads the decode again.
        _ = source.releaseDecodes()

        // R-11's stability half: a second reader over the same bytes must report the
        // same pin. The VALUE is never asserted — it moves when Apple ships a decoder.
        if let secondAttempt = RawCorpusTests.watched(
            "reopen \(entry.id)", seconds: RawCorpusTests.watchdogSeconds, {
            try? AppleRawSource(url: entry.url)
        }), let second = secondAttempt {
            p.pinReadTwice = true
            p.pinSecond = second.pinnedDecoderVersion
            _ = second.releaseDecodes()
        }

        _ = source.releaseDecodes()
    }

    // MARK: - Readers

    /// E — the container's own claim about how big the picture is, from the same
    /// dictionary `CaptureMetadataReader` reads, plus the EXIF orientation tag.
    private static func containerGeometry(_ url: URL) -> (dim: Dim, orientation: Int?)? {
        guard let container = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (dim: Dim(w: width, h: height),
                orientation: properties[kCGImagePropertyOrientation] as? Int)
    }

    /// Every sample of the decode, checked for NaN and infinity.
    ///
    /// Bounded: a decoder is free to DECLINE a scale factor, and a declined one on a
    /// 40 MP frame would ask for a 650 MB float buffer here. Above the cap the frame is
    /// resampled down first — a NaN survives a resample and spreads, so the alarm still
    /// rings — and the fact is recorded rather than hidden.
    private static func readFiniteness(_ image: CIImage, into p: Probe) {
        let extent = image.extent
        let pixels = Double(extent.width) * Double(extent.height)
        let cap = 6_000_000.0
        var subject = image
        if pixels > cap {
            let factor = CGFloat((cap / pixels).squareRoot())
            subject = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            p.floatReadbackNote = "finiteness read at \(fmt(Double(factor), 3))x — the "
                + "decoder declined the scale factor and the native buffer was too "
                + "large to read whole"
        }
        guard let buffer = PipelineRenderer.buffer(from: subject,
                                                   context: DecodeMaterializer.context)
        else {
            p.floatReadbackNote = "the decode could not be read back as RGBAf"
            return
        }
        p.floatSamples = buffer.pixels.count
        var nonFinite = 0
        var first: String?
        for index in 0..<buffer.pixels.count where !buffer.pixels[index].isFinite {
            nonFinite += 1
            if first == nil {
                let pixel = index / 4
                first = "(x \(pixel % buffer.width), y \(pixel / buffer.width), "
                    + "channel \(index % 4)) = \(buffer.pixels[index])"
            }
        }
        p.nonFiniteSamples = nonFinite
        p.nonFiniteFirst = first
    }

    /// The delivered frame as 8-bit sRGB bytes. This is what `renderPreview` hands the
    /// viewer, so it is what "display-referred" means here.
    private static func rgbaBytes(_ image: CGImage) -> (w: Int, h: Int, px: [UInt8])? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width * height <= 40_000_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let drew: Bool = px.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0,
                                       width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        return drew ? (width, height, px) : nil
    }

    private static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// R-6's statistics: the mean, the P5–P95 spread, and how much of the frame is
    /// pinned at either end. A 1024-bin histogram rather than a sort of 700 000 doubles.
    private static func readToneStatistics(_ frame: (w: Int, h: Int, px: [UInt8]),
                                           into p: Probe) {
        let count = frame.w * frame.h
        guard count > 0 else { return }
        var histogram = [Int](repeating: 0, count: 1024)
        var total = 0.0
        var nearBlack = 0
        var nearWhite = 0
        for index in 0..<count {
            let base = index * 4
            let value = luma(Double(frame.px[base]) / 255.0,
                             Double(frame.px[base + 1]) / 255.0,
                             Double(frame.px[base + 2]) / 255.0)
            total += value
            if value <= 1.0 / 255.0 { nearBlack += 1 }
            if value >= 254.0 / 255.0 { nearWhite += 1 }
            let bin = Swift.min(1023, Swift.max(0, Int(value * 1023.0)))
            histogram[bin] += 1
        }
        p.meanLuma = total / Double(count)
        p.nearBlackFraction = Double(nearBlack) / Double(count)
        p.nearWhiteFraction = Double(nearWhite) / Double(count)

        func percentile(_ fraction: Double) -> Double {
            let target = Int((Double(count) * fraction).rounded())
            var seen = 0
            for bin in 0..<histogram.count {
                seen += histogram[bin]
                if seen >= target { return Double(bin) / 1023.0 }
            }
            return 1.0
        }
        p.p5 = percentile(0.05)
        p.p95 = percentile(0.95)
    }

    /// R-7. The patch is FOUND, not addressed — raw.pixls.us explicitly refuses colour
    /// targets, so there is no grey card and no coordinate worth trusting.
    ///
    /// A 16×16 grid of blocks; keep the mid-luminance ones; keep the flattest quartile
    /// of those; report the least chromatic (R-7) and the median (R-7b).
    private static func readNeutralPatch(_ frame: (w: Int, h: Int, px: [UInt8]),
                                         into p: Probe) {
        let grid = 16
        guard frame.w >= grid, frame.h >= grid else {
            p.chromaNote = "frame smaller than the 16x16 block grid"
            return
        }
        struct Block {
            let luma: Double
            let variance: Double
            let chroma: Double
        }
        var blocks: [Block] = []
        blocks.reserveCapacity(grid * grid)
        for by in 0..<grid {
            let y0 = by * frame.h / grid
            let y1 = Swift.max(y0 + 1, (by + 1) * frame.h / grid)
            for bx in 0..<grid {
                let x0 = bx * frame.w / grid
                let x1 = Swift.max(x0 + 1, (bx + 1) * frame.w / grid)
                var sr = 0.0, sg = 0.0, sb = 0.0, sl = 0.0, sl2 = 0.0
                var n = 0
                for y in y0..<Swift.min(y1, frame.h) {
                    for x in x0..<Swift.min(x1, frame.w) {
                        let base = (y * frame.w + x) * 4
                        let r = Double(frame.px[base]) / 255.0
                        let g = Double(frame.px[base + 1]) / 255.0
                        let b = Double(frame.px[base + 2]) / 255.0
                        let l = luma(r, g, b)
                        sr += r; sg += g; sb += b; sl += l; sl2 += l * l
                        n += 1
                    }
                }
                guard n > 0 else { continue }
                let denominator = Double(n)
                let meanLuma = sl / denominator
                let lab = labFromSRGB(sr / denominator, sg / denominator, sb / denominator)
                blocks.append(Block(
                    luma: meanLuma,
                    variance: Swift.max(0, sl2 / denominator - meanLuma * meanLuma),
                    chroma: (lab.a * lab.a + lab.b * lab.b).squareRoot()))
            }
        }
        guard !blocks.isEmpty else { return }

        var midtones = blocks.filter { $0.luma >= 0.20 && $0.luma <= 0.60 }
        if midtones.isEmpty {
            midtones = blocks
            p.chromaNote = "no block fell in the 0.20-0.60 midtone window; measured "
                + "over the whole frame instead"
        }
        midtones.sort { $0.variance < $1.variance }
        let flatCount = Swift.max(1, midtones.count / 4)
        let flat = Array(midtones.prefix(flatCount))
        let chromas = flat.map { $0.chroma }.sorted()
        p.minChroma = chromas.first
        p.medianChroma = chromas[chromas.count / 2]
    }

    /// sRGB (display-referred, 0…1) to CIELAB under D65. Hand-rolled on purpose: the
    /// arithmetic is six lines and it borrows nothing that could change underneath it.
    private static func labFromSRGB(_ r: Double, _ g: Double,
                                    _ b: Double) -> (L: Double, a: Double, b: Double) {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let lr = linear(r), lg = linear(g), lb = linear(b)
        let x = 0.4124564 * lr + 0.3575761 * lg + 0.1804375 * lb
        let y = 0.2126729 * lr + 0.7151522 * lg + 0.0721750 * lb
        let z = 0.0193339 * lr + 0.1191920 * lg + 0.9503041 * lb
        func f(_ t: Double) -> Double {
            t > 0.008856451679035631 ? cbrt(t) : (7.787037037037035 * t + 16.0 / 116.0)
        }
        let fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// R-5. The camera's own embedded preview is a second opinion about the same
    /// photograph, and it costs nothing to ask for it.
    ///
    /// The embedded preview is tried first, because that JPEG is what the camera itself
    /// decided the picture looks like. When there is no embedded preview big enough,
    /// ImageIO's own decode of the same file is used instead and SAID SO — that is still
    /// a second implementation reading the same bytes, and a correlation measured
    /// against nothing at all is worth less than one measured against a labelled proxy.
    private static func correlateWithEmbeddedPreview(entry: CorpusEntry,
                                                     delivered: CGImage,
                                                     into p: Probe) {
        guard let container = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else {
            p.previewNote = "no CGImageSource for the preview comparison"
            return
        }
        func thumbnail(fromImage: Bool) -> CGImage? {
            var options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 512,
                // The preview carries its own EXIF orientation, and the camera meant it.
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if fromImage {
                options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            }
            return CGImageSourceCreateThumbnailAtIndex(container, 0,
                                                       options as CFDictionary)
        }
        var source = "embedded"
        var preview = thumbnail(fromImage: false)
        if preview == nil || Swift.max(preview?.width ?? 0, preview?.height ?? 0) < 256 {
            if let fallback = thumbnail(fromImage: true),
               Swift.max(fallback.width, fallback.height) >= 256 {
                preview = fallback
                source = "imageio-decode"
            }
        }
        guard let chosen = preview,
              Swift.max(chosen.width, chosen.height) >= 256 else {
            // The absence of a preview is that file's property, not a defect in ours.
            p.previewNote = "no preview >= 256 px — R-5 skipped, not failed"
            return
        }
        p.previewSource = source
        p.previewSize = "\(chosen.width)x\(chosen.height)"
        guard let a = lumaGrid(chosen, side: 32), let b = lumaGrid(delivered, side: 32)
        else {
            p.previewNote = "could not reduce one of the two frames to a 32x32 grid"
            return
        }
        p.previewCorrelation = pearson(a, b)
        if p.previewCorrelation == nil {
            p.previewNote = "one of the two 32x32 grids is flat — correlation undefined"
        }
    }

    /// Both frames squashed into the same square grid, which is what makes the
    /// comparison about STRUCTURE rather than about aspect — aspect is R-4's job.
    private static func lumaGrid(_ image: CGImage, side: Int) -> [Double]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let drew: Bool = px.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0,
                                       width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        guard drew else { return nil }
        var out = [Double](repeating: 0, count: side * side)
        for index in 0..<(side * side) {
            let base = index * 4
            out[index] = luma(Double(px[base]) / 255.0,
                              Double(px[base + 1]) / 255.0,
                              Double(px[base + 2]) / 255.0)
        }
        return out
    }

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count > 1 else { return nil }
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n
        let mb = b.reduce(0, +) / n
        var numerator = 0.0, da = 0.0, db = 0.0
        for index in 0..<a.count {
            let x = a[index] - ma
            let y = b[index] - mb
            numerator += x * y
            da += x * x
            db += y * y
        }
        guard da > 0, db > 0 else { return nil }
        let r = numerator / (da * db).squareRoot()
        return r.isFinite ? r : nil
    }

    /// R-8. Export, then reopen the written file with a FRESH `CGImageSource` and ask it
    /// what it thinks it contains.
    private static func exportAndReopen(entry: CorpusEntry, source: AppleRawSource,
                                        recipe: Recipe, into p: Probe) {
        let exportRecipe = ExportRecipe(name: "raw-corpus", format: .tiff, bitDepth: 16,
                                        colorSpace: .srgb, resizeMode: .longEdge,
                                        resizeValue: Double(exportLongEdge))
        let destination = exportDir.appendingPathComponent("\(entry.id).tif")
        guard let outcome = watched(
            "export \(entry.id)", seconds: exportWatchdogSeconds, { () -> String? in
            do {
                _ = try renderer.export(source: source, recipe: recipe,
                                        to: destination, using: exportRecipe)
                return nil
            } catch {
                return String(describing: error)
            }
        }) else {
            p.hung.append("export")
            return
        }
        p.exportRan = true
        if let failure = outcome {
            p.exportError = failure
            return
        }
        if let attributes = try? FileManager.default
            .attributesOfItem(atPath: destination.path),
           let size = attributes[.size] as? NSNumber {
            p.exportBytes = size.intValue
        }
        // The CLAIM comes from the container's property dictionary and the PIXELS
        // from a second, independent read of the same file — the point of R-8 is that
        // those two can disagree, so they must not come from one call.
        guard let container = CGImageSourceCreateWithURL(destination as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(container, 0, nil)
                as? [CFString: Any],
              let reopened = CIImage(contentsOf: destination)
        else {
            p.exportError = "the written file could not be reopened"
            return
        }
        let pixelExtent = reopened.extent
        guard !pixelExtent.isInfinite, pixelExtent.width.isFinite,
              pixelExtent.height.isFinite, pixelExtent.width >= 1,
              pixelExtent.height >= 1
        else {
            p.exportError = "the reopened file has no usable extent"
            return
        }
        p.exportPixels = Dim(w: Int(pixelExtent.width.rounded()),
                             h: Int(pixelExtent.height.rounded()))
        if let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            p.exportClaimed = Dim(w: width, h: height)
        }
        p.exportOrientation = properties[kCGImagePropertyOrientation] as? Int
        try? FileManager.default.removeItem(at: destination)
    }

    // MARK: - Tier 0 — liveness

    /// R-0, R-1 and R-2. Every file lands in exactly one of two states: refused, or an
    /// image with a finite, non-empty extent. There is no third state, and
    /// `CGRect.infinite` — which `CIImage` produces legitimately elsewhere — is the
    /// third state this catches.
    ///
    /// R-0 is structural rather than an `XCTAssert`: a trap kills the test binary and
    /// XCTest reports the abort. It is listed because it is the FIRST thing this lane
    /// buys — nothing in the tree has ever handed `CIRAWFilter` a byte it did not
    /// generate itself.
    ///
    /// What this does NOT assert: which files decode. The X3F and the GPR are in the
    /// corpus because Apple probably cannot open them, and asserting that would be
    /// asserting Apple's support matrix — which moves in the direction of MORE support,
    /// so pinning it would turn a good macOS update into a red build. The outcome per
    /// file goes to the inventory and the evidence sheet, where a change shows as a diff.
    func testEveryFileEitherDecodesCleanlyOrRefusesCleanly() throws {
        let entries = try corpus()
        var decoded = 0
        var refused: [String] = []
        for entry in entries {
            let p = probe(for: entry)
            XCTAssertTrue(p.existsOnDisk,
                          "\(entry.id) (\(entry.local)) is in the manifest and not on "
                              + "disk. The fetch step verified sixteen digests; if this "
                              + "fires, the corpus directory the tests were pointed at "
                              + "is not the one the lane filled.")
            guard p.existsOnDisk else { continue }

            // R-1.
            let stalled = p.hung.joined(separator: RawCorpusTests.commaSpace)
            XCTAssertTrue(p.hung.isEmpty,
                          "\(entry.id) · \(entry.label): \(stalled)"
                              + " did not finish inside "
                              + "\(Int(RawCorpusTests.watchdogSeconds))s. Hung, not slow.")
            guard p.hung.isEmpty else { continue }

            // R-2: exactly one of the two states.
            if p.openFailure != nil || p.decodeReturnedNil {
                refused.append(entry.id)
                continue
            }
            decoded += 1
            XCTAssertEqual(p.extentUsable, true,
                           "\(entry.id) · \(entry.label): the decode returned an image "
                               + "whose extent is \(String(describing: p.decodedExtent)) "
                               + "— not refused and not a usable picture, which is the "
                               + "third state R-2 says does not exist. An infinite "
                               + "extent reaching the graph is an allocation of "
                               + "infinite size.")
        }
        let refusedList = refused.isEmpty
            ? "none"
            : refused.joined(separator: RawCorpusTests.commaSpace)
        RawCorpusTests.emit("corpus-summary: \(decoded) of \(entries.count) files "
            + "decoded; refused: \(refusedList)")
    }

    // MARK: - Tier 1 — geometry

    /// R-3. Two independent readings of the same file must agree about how big the
    /// picture is: ImageIO's EXIF dictionary, and `CIRAWFilter.nativeSize`.
    ///
    /// Within 10%, and only up to a transpose. Both slacks are measured, not guessed:
    /// the Sony A450 in this corpus reports 4608×3072 in its CFA IFD and 4592×3056 in
    /// PixelXDimension — a masked sensor border, 1.0%. Ten percent is five times the
    /// worst real case and still refuses a factor of two, which is what a draft decode
    /// leaking into the settle path looks like. The transpose is left to R-4 so the two
    /// failures are distinguishable in the log rather than one confused message.
    func testDeliveredDimensionsArePlausibleAgainstTheFilesOwnEXIF() throws {
        let entries = try corpus()
        for entry in entries where !entry.isNegative {
            let p = probe(for: entry)
            guard p.decodedCleanly, let native = p.native else { continue }

            XCTAssertTrue(native.w >= 1 && native.w <= 65535
                          && native.h >= 1 && native.h <= 65535,
                          "\(entry.id) · \(entry.label): nativePixelSize is "
                              + "\(native.text) — zero, negative or garbage.")

            guard let exif = p.exif else {
                RawCorpusTests.emit("corpus-note: \(entry.id) carries no "
                    + "kCGImagePropertyPixelWidth/Height — R-3 has nothing to compare "
                    + "against and is skipped for this file, not failed.")
                continue
            }
            guard exif.pixels > 0, native.pixels > 0 else { continue }

            let ratio = native.pixels / exif.pixels
            XCTAssertTrue(ratio >= 0.90 && ratio <= 1.11,
                          "\(entry.id) · \(entry.label): CIRAWFilter says "
                              + "\(native.text) and the container says \(exif.text) — "
                              + "a pixel-count ratio of "
                              + "\(RawCorpusTests.fmt(ratio, 3)). Ten percent is five "
                              + "times the widest real sensor-border gap in this "
                              + "corpus; this is a different picture, not a border.")

            func within(_ a: Int, _ b: Int) -> Bool {
                guard a > 0, b > 0 else { return false }
                let r = Double(a) / Double(b)
                return r >= 0.90 && r <= 1.11
            }
            let straight = within(native.w, exif.w) && within(native.h, exif.h)
            let transposed = within(native.w, exif.h) && within(native.h, exif.w)
            XCTAssertTrue(straight || transposed,
                          "\(entry.id) · \(entry.label): \(native.text) does not match "
                              + "\(exif.text) under either pairing. Orientation-blind on "
                              + "purpose — 'same picture, same size, possibly sideways'. "
                              + "Whether it is the right way up is R-4.")
        }
    }

    /// R-4. THE ONE THIS LANE WAS BUILT FOR.
    ///
    /// `PipelineRenderer.applyMetadataPolicy` states, in a comment, that the pixels it
    /// delivers "are already the right way up… by construction". That is a claim about
    /// CIRAWFilter's output convention, and until this test runs it has never been
    /// checked against a file whose orientation tag is anything but 1.
    ///
    /// Four files carry a 90°-class tag, from four manufacturers, in BOTH directions:
    /// Nikon Z 30 (8), Sony A450 (6), Fujifilm X-H2 (6), Apple iPhone 12 Pro (6). One
    /// direction cannot tell "rotated correctly" from "rotated backwards". Two can.
    /// Applying the rotation twice is a 180° transform, which restores the aspect — so a
    /// double-apply fails here too.
    ///
    /// The limit, stated rather than hidden: a double-applied MIRROR (orientation 2, the
    /// GoPro) or 180° (orientation 3, the Pixel 7 Pro) is invisible to an aspect test,
    /// because both are self-inverse in aspect. R-5 is what covers those two.
    func testAPortraitFrameComesOutPortrait() throws {
        let entries = try corpus()
        var rotatedSeen = 0
        for entry in entries where !entry.isNegative {
            let p = probe(for: entry)
            guard p.decodedCleanly, let exif = p.exif, let delivered = p.delivered
            else { continue }

            // The one pinned number in the corpus, and §5.1's argument for it: it lives
            // in bytes a sha256 already froze, and exiv2 read it with an implementation
            // that shares no code with ImageIO.
            if let expected = entry.orientation, let read = p.exifOrientation {
                XCTAssertEqual(read, expected,
                               "\(entry.id) · \(entry.label): exiv2 read orientation "
                                   + "\(expected) from these bytes and ImageIO reads "
                                   + "\(read). The file is pinned by sha256, so one of "
                                   + "the two readers is wrong about the same bytes.")
            }
            let orientation = p.exifOrientation ?? entry.orientation ?? 1

            guard !exif.isSquare, !delivered.isSquare else {
                RawCorpusTests.emit("corpus-note: \(entry.id) is square (E "
                    + "\(exif.text), D \(delivered.text)) — an aspect test cannot see a "
                    + "rotation in it. R-4 skipped for this file; R-5 covers it.")
                continue
            }

            if (5...8).contains(orientation) {
                rotatedSeen += 1
                XCTAssertEqual(delivered.isLandscape, !exif.isLandscape,
                               "\(entry.id) · \(entry.label): EXIF orientation "
                                   + "\(orientation) is a 90°-class transform, so the "
                                   + "long edge MUST swap. The container is \(exif.text) "
                                   + "and the renderer delivered \(delivered.text). "
                                   + "Either the rotation was not applied, or it was "
                                   + "applied twice.")
            } else {
                XCTAssertEqual(delivered.isLandscape, exif.isLandscape,
                               "\(entry.id) · \(entry.label): EXIF orientation "
                                   + "\(orientation) is not a 90°-class transform, so "
                                   + "the long edge must NOT swap. The container is "
                                   + "\(exif.text) and the renderer delivered "
                                   + "\(delivered.text).")
            }
        }
        RawCorpusTests.emit("corpus-summary: R-4 checked \(rotatedSeen) file(s) carrying "
            + "a 90°-class orientation tag. Below two, in both directions, this "
            + "invariant cannot tell 'rotated correctly' from 'rotated backwards'.")
    }

    /// R-5. The camera's own embedded preview is a second opinion about the same
    /// photograph, and it costs nothing to ask for it.
    ///
    /// Both reduced to a 32×32 luma grid, normalised, correlated; r ≥ 0.6. Loose on
    /// values on purpose — the preview carries the camera's tone curve and our render is
    /// flat and scene-referred, so the numbers differ a great deal and the STRUCTURE
    /// does not. A 90° error takes r to near zero; a mirror or a 180° takes it hard
    /// negative on anything not accidentally symmetric.
    ///
    /// 0.6 IS A FIRST GUESS AND IS TREATED AS ONE: the measured r for every file is
    /// emitted on every run, passes included, and lands in the evidence sheet, so the
    /// threshold gets set from sixteen real numbers rather than guessed at twice. A file
    /// with no preview ≥ 256 px skips with a note — the absence of a preview is that
    /// file's property, not a defect in ours.
    func testTheRenderAgreesWithTheCamerasOwnPreview() throws {
        let entries = try corpus()
        var measured: [Double] = []
        for entry in entries where !entry.isNegative {
            let p = probe(for: entry)
            guard p.decodedCleanly else { continue }
            guard let r = p.previewCorrelation else {
                RawCorpusTests.emit("corpus-note: \(entry.id) · R-5 skipped — "
                    + "\(p.previewNote)")
                continue
            }
            measured.append(r)
            XCTAssertGreaterThanOrEqual(
                r, 0.6,
                "\(entry.id) · \(entry.label): the render correlates r = "
                    + "\(RawCorpusTests.fmt(r)) with the file's own \(p.previewSource) "
                    + "preview (\(p.previewSize)). Near zero is a 90° error; hard "
                    + "negative is a mirror or a 180°. NOTE: 0.6 is a first guess — "
                    + "check the corpus-evidence rows before treating this as a defect.")
        }
        RawCorpusTests.emit("corpus-summary: R-5 measured \(measured.count) "
            + "correlations; min \(RawCorpusTests.fmt(measured.min())), "
            + "max \(RawCorpusTests.fmt(measured.max())). The floor is 0.6 BY GUESS.")
    }

    // MARK: - Tier 2 — the render is a picture

    /// R-6. Every sample finite — all of them, not a spot check, because NaN arrives
    /// from edge handling and from `0/0` in a normalisation and lives at the borders
    /// where a spot check does not look. Then: mean luminance in [0.02, 0.85]; P95−P5 ≥
    /// 0.02, because a flat grey frame passes a mean test and is still a dead decode;
    /// and under 90% of pixels pinned at either end.
    ///
    /// WHERE THE FINITENESS IS MEASURED, stated rather than glossed. `renderPreview`
    /// hands back a `CGImage` in 8-bit sRGB, and a NaN cannot survive that quantization
    /// — by the time the delivered frame exists, a poisoned sample has already become a
    /// byte. So finiteness is asserted one stage earlier, on an RGBAf readback of the
    /// scene-referred decode, which is the surface a decoder's NaN is actually born on;
    /// a NaN introduced later in the graph still shows up here as the black or clamped
    /// frame the four statistics below refuse.
    ///
    /// These are alarms, not measurements. They are safe this wide because the corpus is
    /// drawn from a pool raw.pixls.us curates for "well-lit… daylight landscape…
    /// properly exposed" — its words. A genuinely dark scene passes; a zeroed buffer, a
    /// clamped buffer and a NaN-poisoned graph do not.
    func testTheRenderIsNeitherBlankNorPoisoned() throws {
        let entries = try corpus()
        for entry in entries {
            let p = probe(for: entry)
            guard p.decodedCleanly, p.delivered != nil else { continue }

            let firstBad = p.nonFiniteFirst ?? "an unrecorded coordinate"
            XCTAssertEqual(p.nonFiniteSamples, 0,
                           "\(entry.id) · \(entry.label): \(p.nonFiniteSamples) of "
                               + "\(p.floatSamples) scene-linear samples are not finite; "
                               + "the first is at \(firstBad). NaN "
                               + "propagates through every stage below the decode.")

            guard let mean = p.meanLuma, let p5 = p.p5, let p95 = p.p95,
                  let black = p.nearBlackFraction, let white = p.nearWhiteFraction
            else {
                XCTFail("\(entry.id) · \(entry.label): the delivered frame could not be "
                        + "read back for tone statistics.")
                continue
            }
            XCTAssertTrue(mean >= 0.02 && mean <= 0.85,
                          "\(entry.id) · \(entry.label): mean display-referred luminance "
                              + "is \(RawCorpusTests.fmt(mean)). Outside [0.02, 0.85] is "
                              + "a zeroed or clamped buffer, not a daylight photograph.")
            XCTAssertGreaterThanOrEqual(
                p95 - p5, 0.02,
                "\(entry.id) · \(entry.label): P95 − P5 is "
                    + "\(RawCorpusTests.fmt(p95 - p5)). A flat frame passes a mean test "
                    + "and is still a dead decode; this is what says it has content.")
            XCTAssertLessThan(black, 0.90,
                              "\(entry.id) · \(entry.label): "
                                  + "\(RawCorpusTests.fmt(black * 100, 1))% of the frame "
                                  + "is within 1/255 of black.")
            XCTAssertLessThan(white, 0.90,
                              "\(entry.id) · \(entry.label): "
                                  + "\(RawCorpusTests.fmt(white * 100, 1))% of the frame "
                                  + "is within 1/255 of white.")
        }
    }

    /// R-7. The patch is FOUND, not addressed: raw.pixls.us explicitly refuses colour
    /// targets, so there is no grey card and no coordinate worth trusting. 16×16 blocks;
    /// keep mid-luminance ones; keep the flattest quartile; take the least chromatic;
    /// require CIELAB chroma < 20.
    ///
    /// Twenty is enormous, and that is the point — this is a CAST ALARM, not a colour
    /// accuracy claim. A swapped red/blue (this corpus carries RGGB, GRBG and BGGR), a
    /// missing camera matrix, or a white balance applied twice moves the frame's most
    /// neutral block far past 20. A warm sunset does not, because we take the minimum
    /// over the whole frame.
    ///
    /// This is the assertion most likely to fail for an uninteresting reason, so it gets
    /// R-5's discipline: the measured chroma for every file is emitted on every run,
    /// passes included, and the real ceiling gets set from data after the first green
    /// run. Shipping it loose and tightening from evidence is the only version of this
    /// that neither misses the defect nor cries wolf.
    func testTheMostNeutralPatchInEachFrameIsNeutral() throws {
        let entries = try corpus()
        var measured: [Double] = []
        for entry in entries where !entry.isNegative && !entry.isMono {
            let p = probe(for: entry)
            guard p.decodedCleanly else { continue }
            guard let chroma = p.minChroma else {
                RawCorpusTests.emit("corpus-note: \(entry.id) · R-7 skipped — "
                    + "\(p.chromaNote)")
                continue
            }
            measured.append(chroma)
            XCTAssertLessThan(
                chroma, 20.0,
                "\(entry.id) · \(entry.label): the most neutral flat mid-tone block in "
                    + "the frame has CIELAB chroma \(RawCorpusTests.fmt(chroma, 2)). "
                    + "Twenty is a cast alarm, not an accuracy claim — a swapped "
                    + "red/blue, a missing camera matrix or a doubly-applied white "
                    + "balance is what gets past it. NOTE: 20 is a first guess; read "
                    + "the corpus-evidence rows before calling this a defect.")
        }
        RawCorpusTests.emit("corpus-summary: R-7 measured \(measured.count) neutral-patch "
            + "chromas; min \(RawCorpusTests.fmt(measured.min(), 3)), "
            + "max \(RawCorpusTests.fmt(measured.max(), 3)). The ceiling is 20 BY GUESS.")
    }

    /// R-7b. The Leica M Monochrom has no colour filter array — exiv2 confirms no
    /// CFAPattern and a Linear Raw photometric interpretation. So the assertion is not a
    /// tolerance, it is close to an identity: the MEDIAN block's chroma < 2, not the
    /// minimum's. A monochrome sensor cannot produce colour, and if this frame has any,
    /// something downstream is inventing it — which would be invisible on every other
    /// file in the corpus.
    func testAMonochromeSensorProducesNoColour() throws {
        let entries = try corpus()
        let mono = entries.filter { $0.isMono }
        XCTAssertFalse(mono.isEmpty,
                       "No manifest row carries the `mono` flag. The Leica M Monochrom "
                           + "is the only file in this corpus where 'a neutral patch "
                           + "stays neutral' is a near-identity rather than a tolerance; "
                           + "without it R-7b tests nothing.")
        for entry in mono {
            let p = probe(for: entry)
            guard p.decodedCleanly else {
                RawCorpusTests.emit("corpus-note: \(entry.id) · R-7b skipped — the "
                    + "monochrome file did not decode (\(p.verdict))")
                continue
            }
            guard let median = p.medianChroma else {
                RawCorpusTests.emit("corpus-note: \(entry.id) · R-7b skipped — "
                    + "\(p.chromaNote)")
                continue
            }
            XCTAssertLessThan(
                median, 2.0,
                "\(entry.id) · \(entry.label): the MEDIAN flat mid-tone block has "
                    + "CIELAB chroma \(RawCorpusTests.fmt(median, 3)). This sensor has "
                    + "no colour filter array; any colour in this frame was invented "
                    + "downstream, and it would be invisible on every other file here.")
        }
    }

    // MARK: - Tier 3 — export and metadata

    /// R-8. Export to 16-bit TIFF at 1600 px, reopen through a fresh CGImageSource, and
    /// require the container's claimed dimensions to equal its own pixels'.
    ///
    /// This is the assertion `applyMetadataPolicy` most needs. It reconciles those
    /// fields deliberately — its comment warns that carrying the source's forward makes
    /// "a resized file that claims the original's size and a straightened file that
    /// viewers rotate a second time" — and no test has ever put that through an encoder
    /// and read it back. The orientation check is the other half: the renderer writes 1
    /// on purpose, and a container that round-trips anything else means every viewer
    /// rotates a Lumen export a second time.
    func testAnExportReopensWithTheDimensionsItClaims() throws {
        let entries = try corpus()
        XCTAssertTrue(RawCorpusTests.renderer.isGPUPathAvailable,
                      "The core kernels did not compile on this runner, so `export` "
                          + "refuses by design (RenderError.kernelsUnavailable) and R-8 "
                          + "cannot say anything about the metadata policy. Unavailable: "
                          + "\(RawCorpusTests.renderer.unavailableKernels)")
        for entry in entries where !entry.isNegative {
            let p = probe(for: entry)
            guard p.decodedCleanly else { continue }
            guard p.exportRan else { continue }

            if let failure = p.exportError {
                XCTFail("\(entry.id) · \(entry.label): the export failed — \(failure)")
                continue
            }
            guard let bytes = p.exportBytes, let pixels = p.exportPixels else {
                XCTFail("\(entry.id) · \(entry.label): the written file could not be "
                        + "measured or reopened.")
                continue
            }
            XCTAssertGreaterThan(bytes, 0,
                                 "\(entry.id) · \(entry.label): the export wrote an "
                                     + "empty file.")

            guard let claimed = p.exportClaimed else {
                XCTFail("\(entry.id) · \(entry.label): the reopened container carries no "
                        + "kCGImagePropertyPixelWidth/Height at all.")
                continue
            }
            XCTAssertEqual(claimed.w, pixels.w,
                           "\(entry.id) · \(entry.label): the written TIFF CLAIMS "
                               + "\(claimed.text) and CONTAINS \(pixels.text). A file "
                               + "that lies about its own geometry is exactly what "
                               + "applyMetadataPolicy's reconcile step exists to "
                               + "prevent, and nothing has ever checked it through an "
                               + "encoder.")
            XCTAssertEqual(claimed.h, pixels.h,
                           "\(entry.id) · \(entry.label): claimed \(claimed.text), "
                               + "contains \(pixels.text).")

            if let orientation = p.exportOrientation {
                XCTAssertEqual(orientation, 1,
                               "\(entry.id) · \(entry.label): the written file carries "
                                   + "EXIF orientation \(orientation). The renderer "
                                   + "delivers pixels already the right way up and "
                                   + "writes 1 on purpose; anything else means every "
                                   + "viewer in the world rotates a Lumen export a "
                                   + "second time.")
            }

            guard let delivered = p.delivered else { continue }
            // The ask is measured against the SOURCE, not against `delivered`. The
            // export decodes at scaleFactor 1.0 while `delivered` is the 1024 px
            // preview these tests share, so comparing the two would assert that a
            // 1600 px file is 1024 px wide on every single row of the corpus.
            let sourceLongEdge = p.native?.longEdge ?? 0
            if sourceLongEdge >= RawCorpusTests.exportLongEdge {
                XCTAssertLessThanOrEqual(
                    abs(pixels.longEdge - RawCorpusTests.exportLongEdge), 1,
                    "\(entry.id) · \(entry.label): asked for a long edge of "
                        + "\(RawCorpusTests.exportLongEdge) and got \(pixels.longEdge).")
            } else {
                // `allowUpscale` is false, so a frame already shorter than the ask must
                // come back at its own size rather than stretched.
                XCTAssertEqual(pixels.longEdge, sourceLongEdge,
                               "\(entry.id) · \(entry.label): the sensor frame is "
                                   + "\(sourceLongEdge) px on the long edge, shorter "
                                   + "than the \(RawCorpusTests.exportLongEdge) px ask, "
                                   + "and allowUpscale is false — so the export must "
                                   + "not have resized it. It wrote \(pixels.text).")
            }
            let deliveredAspect = Double(delivered.w) / Double(delivered.h)
            let writtenAspect = Double(pixels.w) / Double(pixels.h)
            if deliveredAspect > 0, writtenAspect > 0 {
                XCTAssertLessThan(
                    abs(writtenAspect / deliveredAspect - 1.0), 0.01,
                    "\(entry.id) · \(entry.label): the delivered frame is "
                        + "\(delivered.text) and the written file is \(pixels.text) — "
                        + "the aspect moved by more than 1%.")
            }
        }
    }

    /// R-9. Two negatives at two severities, and the split is deliberate.
    ///
    /// The 512-byte stub gets a HARD refusal: there is no photograph in 512 bytes, so a
    /// decoder that returns an image is definitively wrong and so is a Lumen that takes
    /// it. The 40%-truncated file gets the softer form — refused, OR a picture that
    /// passes Tier 2 — because I cannot assert that Apple never recovers a partial
    /// frame, only what Lumen does with the result. A half-decoded frame is 60% black,
    /// and R-6's near-zero rule is what forbids it. Which branch was taken is logged
    /// either way: a change there is a change in Apple's decoder.
    func testATruncatedFileIsRefusedRatherThanHalfDecoded() throws {
        let entries = try corpus()
        let negatives = entries.filter(\.isNegative)
        XCTAssertEqual(negatives.count, 2,
                       "The lane builds two synthetic negatives from file 1346 and "
                           + "appends them to the manifest; this run found "
                           + "\(negatives.count).")
        for entry in negatives {
            let p = probe(for: entry)
            guard p.existsOnDisk else {
                XCTFail("\(entry.id): the negative was not built — see the "
                        + "'Build the two synthetic negatives' step.")
                continue
            }
            let stalled = p.hung.joined(separator: RawCorpusTests.commaSpace)
            XCTAssertTrue(p.hung.isEmpty,
                          "\(entry.id): \(stalled) hung on "
                              + "malformed input. On a truncated file the watchdog is "
                              + "the assertion most likely to earn its keep.")
            let refused = p.openFailure != nil || p.decodeReturnedNil
            let branch = refused ? "refused" : "decoded"
            RawCorpusTests.emit("corpus-negative: \(entry.id) "
                + "\(branch) · \(p.verdict) · \(entry.label)")

            if entry.isHardNegative {
                XCTAssertTrue(refused,
                              "\(entry.id) · \(entry.label): 512 bytes is a header and "
                                  + "nothing else. There is no photograph in it, so a "
                                  + "decoder that returns an image here is definitively "
                                  + "wrong — and so is a Lumen that accepts it. The "
                                  + "decode returned "
                                  + "\(String(describing: p.decodedExtent)).")
            } else if !refused {
                // The soft form. Nothing special-cased: a half-decoded frame is 60%
                // black, and Tier 2's own rule is what refuses it.
                XCTAssertEqual(p.extentUsable, true,
                               "\(entry.id): the truncated file produced an image with "
                                   + "an unusable extent.")
                if let black = p.nearBlackFraction {
                    XCTAssertLessThan(
                        black, 0.90,
                        "\(entry.id) · \(entry.label): Apple recovered something from a "
                            + "40%-truncated file, and "
                            + "\(RawCorpusTests.fmt(black * 100, 1))% of it is black. "
                            + "Refusing is fine and delivering a picture is fine; "
                            + "delivering most of a picture is not.")
                }
            }
        }
    }

    /// R-10. `joinCamera` has a de-stutter rule that has never seen a real Make/Model
    /// pair. This corpus has sixteen.
    ///
    /// The camera assertion is deliberately only the manufacturer TOKEN, matched
    /// case-insensitively, because that is what the manifest can vouch for. The joined
    /// string itself is written to the evidence sheet for every file rather than
    /// asserted: whether "OM Digital Solutions" + "OM-1" should collapse to "OM-1" is a
    /// product question with a defensible answer either way, and a lane is the wrong
    /// place to settle it — but sixteen real Make/Model pairs in a table is the right
    /// way to have the argument.
    ///
    /// The date is asserted as a WINDOW (1998 → now + 1 day), not a value: a parse that
    /// fails silently leaves nil and an offset bug lands in 1970 or 2038, and both are
    /// caught without pinning anything that could go stale. ISO is asserted only if
    /// present — `AppleRawSource` already documents nil as the honest answer.
    func testTheMetadataReaderGetsRealFilesRight() throws {
        let entries = try corpus()
        let epoch1998: Int64 = 883_612_800
        let ceiling = Int64(Date().timeIntervalSince1970) + 86_400
        var isoAnswered = 0
        var isoAsked = 0
        for entry in entries where !entry.isNegative {
            let p = probe(for: entry)
            guard p.decodedCleanly else { continue }
            isoAsked += 1

            XCTAssertTrue(p.metadataRead,
                          "\(entry.id) · \(entry.label): CaptureMetadataReader.read "
                              + "returned nil for a file CIRAWFilter decoded. Nil means "
                              + "'no CGImageSource could open it', which cannot be true "
                              + "of a file that just rendered.")

            let camera = p.camera ?? ""
            XCTAssertFalse(camera.isEmpty,
                           "\(entry.id) · \(entry.label): no camera string. Make and "
                               + "Model are both in the TIFF dictionary of every file "
                               + "in this corpus.")
            if entry.makeToken != "-" && !camera.isEmpty {
                XCTAssertTrue(camera.lowercased().contains(entry.makeToken.lowercased()),
                              "\(entry.id) · \(entry.label): joinCamera produced "
                                  + "\"\(camera)\", which does not contain the "
                                  + "manufacturer token \"\(entry.makeToken)\" the "
                                  + "file's own Exif.Image.Make carries. The de-stutter "
                                  + "rule has eaten the make.")
            }

            if let exif = p.exif {
                let readWidth = RawCorpusTests.fmt(p.metaWidth)
                let readHeight = RawCorpusTests.fmt(p.metaHeight)
                XCTAssertEqual(p.metaWidth, exif.w,
                               "\(entry.id): the reader says width \(readWidth) and "
                                   + "the same dictionary says \(exif.w). These come "
                                   + "from one read, so this is the plumbing, not the "
                                   + "decoder.")
                XCTAssertEqual(p.metaHeight, exif.h,
                               "\(entry.id): the reader says height \(readHeight) and "
                                   + "the same dictionary says \(exif.h).")
            }

            if let expected = entry.orientation {
                XCTAssertEqual(p.metaOrientation, expected,
                               "\(entry.id) · \(entry.label): the manifest records "
                                   + "orientation \(expected), read by exiv2 from bytes "
                                   + "a sha256 froze; CaptureMetadataReader read "
                                   + "\(String(describing: p.metaOrientation)). This is "
                                   + "the one pinned number in the corpus and it cannot "
                                   + "go stale without the file changing.")
            }

            if let captureAt = p.captureAt {
                XCTAssertTrue(captureAt > epoch1998 && captureAt < ceiling,
                              "\(entry.id) · \(entry.label): captureAt is \(captureAt), "
                                  + "outside 1998-01-01…now+1d. A silent parse failure "
                                  + "leaves nil; an offset bug lands in 1970 or 2038.")
            } else {
                XCTFail("\(entry.id) · \(entry.label): no capture date. Every file in "
                        + "this corpus came straight off a card with its EXIF intact.")
            }

            if let iso = p.iso {
                isoAnswered += 1
                XCTAssertTrue(iso >= 25 && iso <= 409_600,
                              "\(entry.id) · \(entry.label): ISO \(iso) is outside "
                                  + "25…409600. Not required to be present — but a "
                                  + "present one has to be a number a camera could set.")
            }
        }
        RawCorpusTests.emit("corpus-summary: R-10 read ISO from \(isoAnswered) of "
            + "\(isoAsked) decodable files; nil is the honest answer and falls back to "
            + "the base-ISO noise profile.")
    }

    /// R-11. The pin exists and does not move within a run. Its VALUE is written to the
    /// evidence sheet and NEVER asserted against a constant: it legitimately changes
    /// when Apple ships a new decoder, and pinning it would make a runner-image bump a
    /// red build with no defect behind it. Visible, not enforced — which is what D50
    /// actually needs.
    func testTheDecoderVersionPinIsPresentAndStable() throws {
        let entries = try corpus()
        var pins: [String] = []
        for entry in entries where !entry.isNegative {
            let p = probe(for: entry)
            guard p.decodedCleanly else { continue }
            pins.append("\(entry.id)=\(RawCorpusTests.fmt(p.pin))")

            XCTAssertNotNil(p.pin,
                            "\(entry.id) · \(entry.label): pinnedDecoderVersion is nil "
                                + "for a file that decoded. The recipe records this "
                                + "number and the fingerprint hashes it, so nil means "
                                + "three years of renders are pinned to nothing.")
            if p.pinReadTwice {
                XCTAssertEqual(p.pin, p.pinSecond,
                               "\(entry.id) · \(entry.label): two AppleRawSource "
                                   + "instances over the same bytes report "
                                   + "\(RawCorpusTests.fmt(p.pin)) and "
                                   + "\(RawCorpusTests.fmt(p.pinSecond)). The pin is "
                                   + "allowed to move between macOS versions; it is not "
                                   + "allowed to move inside one run.")
            }
        }
        // Logged, never asserted against a constant — the whole point of R-11.
        let pinList = pins.joined(separator: " ")
        RawCorpusTests.emit("corpus-decoder-pins: \(pinList)")
    }
}

#endif

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Pure queue logic (Foundation only, Linux-testable): item types, error translation, ISO strength bands,
// output naming, chunk planning, skip-done, throughput/ETA and queue persistence.

// MARK: - Queue item

enum ItemState: String, Codable { case queued, working, done, skipped, failed, cancelled }

struct QueueItem: Identifiable, Codable, Equatable {
    var id: UUID
    var source: String            // absolute path
    var output: String            // planned final DNG path (assigned by assignOutputs)
    var state: ItemState
    var iso: Int?                 // from EXIF at enqueue, overwritten by engine result
    var camera: String?
    var strengthOverride: Double? // 0...1, per-item override from the preview panel
    var usedStrength: Double?     // strength actually used for the finished output
    var seconds: Double?          // engine total_s
    var error: UserFacingError?
    var finishedAt: Date?

    init(source: String) {
        id = UUID(); self.source = source; output = ""; state = .queued
    }
}

// MARK: - Error translation

/// What the user sees for a failed photo or batch: short title, one-sentence fix, raw engine text for "Copy error".
struct UserFacingError: Codable, Equatable { var title: String; var detail: String; var raw: String }

/// Titles are fixed strings so `isFatal` can recognise them.
enum ErrorTitle {
    static let cancelled = "Cancelled"
    static let python = "Python environment not found"
    static let engineFolder = "Engine folder not found"
    static let launch = "Couldn't start the engine"
    static let module = "Python package missing"           // + ": torch"
    static let engineCode = "Engine code not found"
    static let exiftool = "exiftool not installed"
    static let converter = "Adobe DNG Converter not found"
    static let converterFailed = "Adobe DNG Converter failed"
    static let weights = "Model weights not found"
    static let diskFull = "Output disk is full"
    static let offload = "Output is on the Offload Drive"
    static let memory = "Ran out of memory"
    static let permission = "No permission to access the file"
    static let unsupported = "Unsupported or damaged RAW file"
    static let notFound = "File not found"
    static let crashed = "Engine crashed"
    static let unknown = "Engine error"
    static let sourceMissing = "Source missing"
    static let noResult = "No result"
}

/// Translate engine stderr / launch errors into a short title + one-sentence fix. `code` < 0 means the process
/// never started (stderr is then the launch message). `uncaughtSignal` means `code` is a signal number.
func translateError(stderr: String, code: Int32, uncaughtSignal: Bool) -> UserFacingError {
    let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let raw = text.isEmpty ? (uncaughtSignal ? "Terminated by signal \(code)" : "Exit code \(code)") : text
    let low = text.lowercased()
    let last = lastExceptionLine(text)
    let lastLow = last.lowercased()
    let hasTraceback = text.contains("Traceback (most recent call last)")
    func e(_ title: String, _ detail: String) -> UserFacingError { UserFacingError(title: title, detail: detail, raw: raw) }
    let settings = "Set the engine folder in Settings (⌘,)."

    if uncaughtSignal && (code == 15 || code == 2) {
        return e(ErrorTitle.cancelled, "Stopped before this photo finished. No file was written.")
    }
    // Exact engine refusal only: source paths on the Offload Drive (reading is fine) appear in other errors too.
    if low.contains("refusing to write onto the offload drive") {
        return e(ErrorTitle.offload, "That drive is read-only for Lumen Denoise. Choose another output folder (⇧⌘O).")
    }
    // Launch problems (no Python traceback): missing venv, missing engine folder, exec failure.
    let missing = ["not found", "no such file", "does not exist", "doesn't exist", "not executable", "isn't executable"]
        .contains { low.contains($0) }
    if !hasTraceback && missing && low.contains("python") && !low.contains("no module named") {
        let path = firstPath(in: text, containing: "python")
        // Keep the launcher's fix-it sentence ("In <root> run: python3 -m venv ...") when it gave one.
        var fix = ""
        if let dot = text.range(of: ". "), text[dot.upperBound...].contains(" run: ") {
            fix = String(text[dot.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !fix.hasSuffix(".") { fix += "." }
            fix += " Or s" + settings.dropFirst()
        }
        return e(ErrorTitle.python, "Expected \(path ?? ".venv/bin/python in the engine folder"). " + (fix.isEmpty ? settings : fix))
    }
    if !hasTraceback && (code == 127 || code < 0) {
        if missing || code == 127 {
            return e(ErrorTitle.engineFolder, (firstPath(in: text).map { "Expected \($0). " } ?? "") + settings)
        }
        return e(ErrorTitle.launch, (last.isEmpty ? "" : clip(last) + " ") + settings)
    }
    if let mod = quoted(after: "No module named ", in: text) {
        let top = mod.split(separator: ".").first.map(String.init) ?? mod
        if top == "lumen_denoise" { return e(ErrorTitle.engineCode, "Python can't import lumen_denoise. " + settings) }
        return e("\(ErrorTitle.module): \(top)",
                 "Install it into the engine's Python (.venv/bin/pip install \(top)) or pick the right engine folder in Settings (⌘,).")
    }
    if lastLow.hasPrefix("importerror") {
        return e(ErrorTitle.module, "\(clip(last)). Reinstall the engine's Python packages or check Settings (⌘,).")
    }
    if low.contains("dng converter not found") {
        return e(ErrorTitle.converter, "Install the free Adobe DNG Converter into /Applications, or set LUMEN_DNG_CONVERTER.")
    }
    if lastLow.contains("no such file or directory: 'exiftool'") {
        return e(ErrorTitle.exiftool, "The engine reads ISO and camera with exiftool. Install it (brew install exiftool) and try again.")
    }
    if lastLow.hasPrefix("filenotfounderror"), let path = quoted(after: "No such file or directory: ", in: last),
       path.hasSuffix(".pt") || path.hasSuffix(".pth") || path.contains("/weights/") || path.hasSuffix("calib.json") {
        return e(ErrorTitle.weights, "Expected \(path). Copy the trained weights there or set the engine folder in Settings (⌘,).")
    }
    if low.contains("no space left on device") || low.contains("[errno 28]") {
        return e(ErrorTitle.diskFull, "Free up space on the output drive or choose another output folder (⇧⌘O).")
    }
    if lastLow.hasPrefix("memoryerror") || low.contains("out of memory") || (uncaughtSignal && code == 9) {
        return e(ErrorTitle.memory, "macOS stopped the engine. Quit other apps and re-run this photo; very large files need more free memory.")
    }
    if lastLow.hasPrefix("permissionerror") || low.contains("operation not permitted") || low.contains("permission denied") {
        let path = quoted(after: ": ", in: last).map { " (\($0))" } ?? ""
        return e(ErrorTitle.permission, "macOS blocked access\(path). Give Lumen Denoise Full Disk Access in System Settings › Privacy & Security, or use another folder.")
    }
    if low.contains("librawfileunsupportederror") || low.contains("librawioerror") || low.contains("librawdataerror")
        || low.contains("rawpy._rawpy.libraw") || low.contains("unsupported file format") {
        return e(ErrorTitle.unsupported, "LibRaw couldn't read this photo. Check that it opens in Lightroom, or convert it to DNG first.")
    }
    if lastLow.hasPrefix("filenotfounderror") {
        let path = quoted(after: "No such file or directory: ", in: last)
        return e(ErrorTitle.notFound, path.map { "Couldn't find \($0). Was it moved or is its drive unplugged?" }
                 ?? "A file the engine needs is missing. See the log (⌥⌘L).")
    }
    if lastLow.hasPrefix("subprocess.calledprocesserror") && lastLow.contains("dng converter") {
        return e(ErrorTitle.converterFailed, "The converter couldn't process this photo. Check that it opens in Lightroom, then re-run it.")
    }
    if uncaughtSignal {
        return e(ErrorTitle.crashed, "The engine stopped with signal \(code). Try again; if it repeats, check the log (⌥⌘L).")
    }
    return e(ErrorTitle.unknown, last.isEmpty ? "Exited with code \(code). See the log (⌥⌘L)." : clip(last))
}

/// isFatal == the remaining files would fail the same way (env problems: python/module/weights/converter/disk full).
func isFatal(_ e: UserFacingError) -> Bool {
    let fatal = [ErrorTitle.python, ErrorTitle.engineFolder, ErrorTitle.launch, ErrorTitle.engineCode, ErrorTitle.exiftool,
                 ErrorTitle.converter, ErrorTitle.weights, ErrorTitle.diskFull, ErrorTitle.offload]
    return fatal.contains(e.title) || e.title.hasPrefix(ErrorTitle.module)
}

/// Last Python exception line ("ValueError: ..."), else the last non-empty line.
private func lastExceptionLine(_ s: String) -> String {
    let lines = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let exc = lines.last { line in
        guard let colon = line.firstIndex(of: ":") else { return false }
        let name = line[..<colon]
        return !name.contains(" ") && (name.hasSuffix("Error") || name.hasSuffix("Exception") || name.hasSuffix("Exit")
                                       || name.hasSuffix("Interrupt"))
    }
    return exc ?? lines.last ?? ""
}

/// The text inside quotes right after `marker`: No module named 'torch' -> torch.
/// Uses the last occurrence that is followed by a quote.
private func quoted(after marker: String, in s: String) -> String? {
    var found: String?
    var from = s.startIndex
    while let r = s.range(of: marker, range: from..<s.endIndex) {
        from = r.upperBound
        let rest = s[r.upperBound...]
        guard let q = rest.first, q == "'" || q == "\"" else { continue }
        let body = rest.dropFirst()
        if let end = body.firstIndex(of: q) { found = String(body[..<end]) }
    }
    return found
}

/// First absolute path in `s` (quoted, or up to whitespace), optionally containing `needle`.
private func firstPath(in s: String, containing needle: String = "") -> String? {
    for q in ["'", "\""] {
        for part in s.components(separatedBy: q).enumerated() where part.offset % 2 == 1 {
            if part.element.hasPrefix("/") && (needle.isEmpty || part.element.lowercased().contains(needle)) { return part.element }
        }
    }
    let tokens = s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;()")) }
    return tokens.first { $0.hasPrefix("/") && (needle.isEmpty || $0.lowercased().contains(needle)) }
}

private func clip(_ s: String, _ n: Int = 200) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }

// MARK: - Strength by ISO

struct ISOBand: Codable, Equatable, Identifiable {
    var id: UUID
    var maxISO: Int               // inclusive upper bound
    var strength: Double
    init(id: UUID = UUID(), maxISO: Int, strength: Double) { self.id = id; self.maxISO = maxISO; self.strength = strength }
}

struct StrengthSettings: Codable, Equatable {
    var global: Double = 1.0
    var autoByISO: Bool = true
    var bands: [ISOBand]

    static let `default` = StrengthSettings(bands: [
        ISOBand(maxISO: 800, strength: 0.55), ISOBand(maxISO: 3200, strength: 0.75),
        ISOBand(maxISO: 12800, strength: 0.9), ISOBand(maxISO: Int.max, strength: 1.0),
    ])

    /// Band strength for an ISO: first band (by maxISO) that contains it; above every band -> the highest band.
    func bandStrength(iso: Int) -> Double? {
        let sorted = bands.sorted { $0.maxISO < $1.maxISO }
        return (sorted.first { iso <= $0.maxISO } ?? sorted.last)?.strength
    }

    /// override ?? (autoByISO && iso != nil ? band : global), clamped 0...1, rounded to 0.05.
    func strength(for item: QueueItem) -> Double {
        var s = global
        if let o = item.strengthOverride { s = o }
        else if autoByISO, let iso = item.iso, let b = bandStrength(iso: iso) { s = b }
        guard s.isFinite else { return 1 }
        return min(1, max(0, (s * 20).rounded() / 20))
    }
}

// MARK: - Output naming

private func stem(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
private func normDir(_ path: String) -> String {
    var p = (path as NSString).standardizingPath
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    return p.lowercased()
}

/// Extended attribute on each finished DNG naming the source it was made from (written by Model.moveIntoPlace).
/// Linux only accepts namespaced names ("user."), which keeps the Linux tests able to exercise it.
#if canImport(Darwin)
let outputOwnerXattr = "com.lumen.denoise.source"
#else
let outputOwnerXattr = "user.com.lumen.denoise.source"
#endif

/// Source path recorded on an output DNG, nil if the file or the attribute is absent (e.g. v0.1 outputs).
func outputOwner(_ path: String) -> String? {
    var buf = [UInt8](repeating: 0, count: 4096)
    #if canImport(Darwin)
    let n = getxattr(path, outputOwnerXattr, &buf, buf.count, 0, 0)
    #else
    // Glibc's Swift module doesn't export <sys/xattr.h>; look the libc symbol up instead (Linux tests only).
    typealias GetXattr = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafeMutableRawPointer?, Int) -> Int
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), "getxattr") else { return nil }
    let n = unsafeBitCast(sym, to: GetXattr.self)(path, outputOwnerXattr, &buf, buf.count)
    #endif
    guard n > 0 else { return nil }
    return String(decoding: buf.prefix(n), as: UTF8.self)
}

/// True when `path` exists on disk and its recorded owner is a different source.
private func ownedByOther(_ path: String, source: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path), let owner = outputOwner(path) else { return false }
    return (owner as NSString).standardizingPath != (source as NSString).standardizingPath
}

/// Final output names: "<outDir>/<stem>-Denoised.dng"; if another item (different source) already claims that name,
/// or a file on disk records (xattr) a different source, "<stem>-2-Denoised.dng", "-3" ... (case-insensitive, APFS is
/// case-insensitive; the "-Denoised.dng" suffix is kept so collectInputs still skips our outputs). Stable: items that already have an output in outDir keep it; finished
/// (done/skipped) items keep an output in another folder untouched.
func assignOutputs(_ items: inout [QueueItem], outDir: String) {
    let dir = normDir(outDir)
    var claims: [String: String] = [:]          // lowercased output path -> source
    var needs: [Int] = []
    for i in items.indices {
        let out = items[i].output
        if !out.isEmpty && normDir((out as NSString).deletingLastPathComponent) == dir {
            let key = out.lowercased()
            if let owner = claims[key], owner != items[i].source { needs.append(i) } else { claims[key] = items[i].source }
        } else if !out.isEmpty && (items[i].state == .done || items[i].state == .skipped) {
            continue
        } else {
            needs.append(i)
        }
    }
    let base = (outDir as NSString).standardizingPath
    for i in needs {
        let s = stem(items[i].source)
        var n = 1
        while true {
            let name = n == 1 ? "\(s)-Denoised.dng" : "\(s)-\(n)-Denoised.dng"
            let path = (base as NSString).appendingPathComponent(name)
            let key = path.lowercased()
            if let owner = claims[key], owner != items[i].source { n += 1; continue }
            if ownedByOther(path, source: items[i].source) { n += 1; continue }
            claims[key] = items[i].source
            items[i].output = path
            break
        }
    }
}

// MARK: - Chunk planning

struct Chunk: Equatable { var itemIDs: [UUID]; var strength: Double }

/// Queued items grouped by strength (not just consecutive ones, so Auto by ISO on a mixed-ISO shoot doesn't reload the
/// model for every photo). Each chunk takes the first remaining item's strength and every later remaining item with the
/// same strength, skipping stems already in the chunk (case-insensitive; the engine names by stem inside staging), up
/// to 60 items. Chunks come out in first-appearance order of their strength; queue order is kept within a chunk.
func planChunks(_ items: [QueueItem], settings: StrengthSettings) -> [Chunk] {
    let maxChunk = 60
    var rest = items.filter { $0.state == .queued }.map { ($0.id, settings.strength(for: $0), stem($0.source).lowercased()) }
    var chunks: [Chunk] = []
    while let first = rest.first {
        var chunk = Chunk(itemIDs: [], strength: first.1)
        var stems = Set<String>()
        var left: [(UUID, Double, String)] = []
        for r in rest {
            if r.1 == chunk.strength && chunk.itemIDs.count < maxChunk && !stems.contains(r.2) {
                chunk.itemIDs.append(r.0); stems.insert(r.2)
            } else {
                left.append(r)
            }
        }
        chunks.append(chunk)
        rest = left
    }
    return chunks
}

// MARK: - Skip already done

/// True when output exists, is non-empty, is newer than the source and (if it records one) was made from this source.
func isAlreadyDone(source: String, output: String) -> Bool {
    let fm = FileManager.default
    guard !output.isEmpty, !ownedByOther(output, source: source),
          let o = try? fm.attributesOfItem(atPath: output), let s = try? fm.attributesOfItem(atPath: source),
          (o[.type] as? FileAttributeType) == .typeRegular,
          let size = (o[.size] as? NSNumber)?.int64Value, size > 0,
          let om = o[.modificationDate] as? Date, let sm = s[.modificationDate] as? Date else { return false }
    return om > sm
}

// MARK: - Throughput / ETA

/// Exponential moving average (alpha 0.3) of wall-clock seconds between successive results, seeded by the first
/// result of a run (which includes model load). reset() at run start so pauses between runs don't count.
struct Throughput: Equatable {
    private var last: Date?
    private var avg: Double?
    private(set) var count = 0
    init() {}

    mutating func reset(now: Date) { last = now; avg = nil; count = 0 }
    /// Next result only starts the clock (each engine run reloads the model); the average is kept.
    mutating func restartClock() { last = nil }
    mutating func record(now: Date) {
        defer { last = now; count += 1 }
        guard let l = last else { return }
        let dt = max(0, now.timeIntervalSince(l))
        avg = avg.map { 0.3 * dt + 0.7 * $0 } ?? dt
    }
    var secondsPerFile: Double? { avg }
    var filesPerMinute: Double? { avg.flatMap { $0 > 0 ? 60 / $0 : nil } }
    func eta(remaining: Int) -> TimeInterval? { avg.map { Double(max(0, remaining)) * $0 } }
}

/// "42 s", "3 min", "1 h 05 min".
func formatDuration(_ s: TimeInterval) -> String {
    guard s.isFinite, s > 0 else { return "0 s" }
    if s.rounded() < 60 { return "\(Int(s.rounded())) s" }
    let minutes = Int((s / 60).rounded())
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60) h " + String(format: "%02d", minutes % 60) + " min"
}

// MARK: - Persistence

/// ~/Library/Application Support/Lumen Denoise/queue.json (directory passed in so tests can use a temp dir).
struct SavedQueue: Codable { var version: Int = 1; var items: [QueueItem]; var outDir: String }

private let queueFile = "queue.json"

/// Atomic write of `dir/queue.json`, creating `dir` if needed.
func saveQueue(_ q: SavedQueue, to dir: String) throws {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    try enc.encode(q).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(queueFile)), options: .atomic)
}

/// Loads and repairs the saved queue: working -> queued; done/skipped whose output is gone -> queued; unfinished
/// items whose source no longer exists -> failed("Source missing"). nil if absent, unreadable or a newer version.
func loadQueue(from dir: String) -> SavedQueue? {
    let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(queueFile))
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: url), var q = try? dec.decode(SavedQueue.self, from: data), q.version <= 1
    else { return nil }
    let fm = FileManager.default
    for i in q.items.indices {
        var it = q.items[i]
        if it.state == .working { it.state = .queued }
        if (it.state == .done || it.state == .skipped) && !fm.fileExists(atPath: it.output) {
            it.state = .queued; it.usedStrength = nil; it.seconds = nil; it.finishedAt = nil
        }
        if it.state != .done && it.state != .skipped && !fm.fileExists(atPath: it.source) {
            it.state = .failed
            it.error = UserFacingError(title: ErrorTitle.sourceMissing,
                                       detail: "The original was moved or deleted, or its drive is not connected.",
                                       raw: it.source)
        }
        q.items[i] = it
    }
    return q
}

import SwiftUI
import AppKit
import ImageIO
import UserNotifications

// The app's state: the queue, settings and the batch runner that glues Core (pure logic) to Engine (processes).
// Everything here runs on the main actor; engine callbacks arrive on the main queue (EngineRun contract).

/// A batch-level problem shown as an alert.
struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// EXIF facts read at enqueue time (off-main).
private struct FileMeta: Sendable { let path: String; let iso: Int?; let camera: String? }

@MainActor
final class QueueModel: ObservableObject {
    // MARK: Published state
    @Published var items: [QueueItem] = [] { didSet { scheduleSave() } }
    @Published var selection: Set<UUID> = []
    @Published var outDir: String { didSet { if !autotest { UserDefaults.standard.set(outDir, forKey: Keys.outDir) }; scheduleSave() } }
    @Published var strength: StrengthSettings { didSet { persistStrength() } }
    @Published var skipDone: Bool { didSet { if !autotest { UserDefaults.standard.set(skipDone, forKey: Keys.skipDone) } } }
    @Published var notifyWhenDone: Bool { didSet { if !autotest { UserDefaults.standard.set(notifyWhenDone, forKey: Keys.notify) } } }
    @Published private(set) var running = false
    @Published private(set) var cancelling = false
    @Published var alert: AlertInfo?
    @Published private(set) var log: [String] = []
    @Published private(set) var throughput = Throughput()
    /// Number of add() calls still reading folders / EXIF.
    @Published private(set) var reading = 0
    /// One-line summary of the last finished batch (shown in the idle status line).
    @Published private(set) var lastSummary: String?

    // MARK: Private state
    private enum Keys { static let outDir = "outDir", strength = "strength", skipDone = "skipDone", notify = "notifyWhenDone" }
    private let autotest: Bool
    private var saveTask: Task<Void, Never>?

    private var run: EngineRun?
    private var runToken: UUID?                  // callbacks carrying another token are stale and ignored
    private var chunkStrength = 1.0
    private var chunkPending: [UUID] = []        // items of the current chunk without a result yet, in engine order
    private var batchOut = ""
    private var batchStart = Date()
    private var batchDone = 0, batchFailed = 0, batchSkipped = 0
    private var forceIDs = Set<UUID>()           // reprocess(): ignore skipDone for these
    private var batchScope: Set<UUID>?           // nil = whole queue; else only these (reprocess / retry while idle)
    private var rerunAfterResult = Set<UUID>()   // override changed while already in the running chunk
    private var chunkResults = 0                 // results delivered by the current engine run
    private var lastEmptyFailure: String?        // error title of the previous run that died before any result
    private var stopReason: String?              // alert title of a fatal stop (for the notification)
    private var prepToken: UUID?                 // the off-main same-shot check started by start()
    private var shotCache: [String: Bool] = [:]  // "source\0output" -> output is a denoise of this source
    private var askedNotify = false

    private var autotestCancelAfter: Int?
    private var autotestPreview: String?
    private var autotestWaiting = false
    private var autotestFinished = false

    private static var queueDir: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Library/Application Support"
        return (base as NSString).appendingPathComponent("Lumen Denoise")
    }

    // MARK: Init
    init() {
        let env = ProcessInfo.processInfo.environment
        let auto = env["LUMEN_AUTOTEST_FILES"] != nil && env["LUMEN_AUTOTEST_OUT"] != nil
        autotest = auto
        let d = UserDefaults.standard
        var out = Cfg.defaultOut
        var st = StrengthSettings.default
        var skip = true, notify = true
        var loaded: [QueueItem] = []
        if !auto {
            let saved = loadQueue(from: QueueModel.queueDir)
            if let o = d.string(forKey: Keys.outDir) ?? saved?.outDir, !o.isEmpty, !isForbiddenOutput(o) { out = o }
            if let data = d.data(forKey: Keys.strength), let s = try? JSONDecoder().decode(StrengthSettings.self, from: data) { st = s }
            skip = d.object(forKey: Keys.skipDone) as? Bool ?? true
            notify = d.object(forKey: Keys.notify) as? Bool ?? true
            loaded = saved?.items ?? []
        }
        outDir = out; strength = st; skipDone = skip; notifyWhenDone = notify
        items = loaded
        if !auto && FileManager.default.fileExists(atPath: out) { sweepStaleStaging(in: out) }   // crash recovery
    }

    // MARK: Derived state
    var selectedItem: QueueItem? { items.first { selection.contains($0.id) } }

    var counts: (total: Int, done: Int, skipped: Int, failed: Int, remaining: Int) {
        var done = 0, skipped = 0, failed = 0, remaining = 0
        for it in items {
            switch it.state {
            case .done: done += 1
            case .skipped: skipped += 1
            case .failed: failed += 1
            case .queued, .working: remaining += 1
            case .cancelled: break
            }
        }
        return (items.count, done, skipped, failed, remaining)
    }

    private var batchFinished: Int { batchDone + batchFailed + batchSkipped }

    private func inScope(_ it: QueueItem) -> Bool { batchScope?.contains(it.id) ?? true }

    /// Queued + working items the running batch will still process.
    private var batchRemaining: Int { items.filter { ($0.state == .queued || $0.state == .working) && inScope($0) }.count }

    var progressFraction: Double {
        let c = counts
        if running {
            let total = batchFinished + batchRemaining
            return total > 0 ? Double(batchFinished) / Double(total) : 0
        }
        return c.total > 0 ? Double(c.total - c.remaining) / Double(c.total) : 0
    }

    var statusLine: String {
        let c = counts
        var parts: [String] = []
        if reading > 0 { parts.append("Reading files…") }
        if cancelling { return (parts + ["Cancelling…"]).joined(separator: " · ") }
        if running {
            let left = batchRemaining
            parts.append("\(batchFinished) of \(batchFinished + left)")
            if let fpm = throughput.filesPerMinute, let eta = throughput.eta(remaining: left) {
                let end = Date().addingTimeInterval(eta).formatted(date: .omitted, time: .shortened)
                parts.append(String(format: "%.1f photos/min", fpm))
                parts.append("about \(formatDuration(eta)) left, finishes ≈\(end)")
            } else {
                parts.append("loading model…")
            }
            return parts.joined(separator: " · ")
        }
        if c.total == 0 { return (parts + ["Drop ARW, RW2 or DNG files or folders"]).joined(separator: " · ") }
        parts.append(c.total == 1 ? "1 photo" : "\(c.total) photos")
        if c.done > 0 { parts.append("\(c.done) done") }
        if c.skipped > 0 { parts.append("\(c.skipped) skipped") }
        if c.failed > 0 { parts.append("\(c.failed) failed") }
        if c.remaining > 0 { parts.append("\(c.remaining) to do") }
        if let s = lastSummary { parts.append("last batch: \(s)") }
        return parts.joined(separator: " · ")
    }

    func strengthFor(_ item: QueueItem) -> Double { strength.strength(for: item) }

    // MARK: Adding files
    /// Collects files (recursively) and reads EXIF ISO/camera off-main; items appear in batches. Allowed while running.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        reading += 1
        Task { [weak self] in                              // main actor; file system work hops to detached tasks
            let found = await Task.detached(priority: .userInitiated) { collectInputs(urls) }.value
            let step = 40
            var start = 0, added = 0
            while start < found.count {
                let slice = Array(found[start..<min(start + step, found.count)])
                let metas = await Task.detached(priority: .userInitiated) { slice.map(readMeta) }.value
                start += step
                added += self?.append(metas) ?? 0
            }
            self?.finishAdd(found: found.count, added: added)
        }
    }

    /// Appends new items (deduped by path); returns how many were added.
    private func append(_ metas: [FileMeta]) -> Int {
        var have = Set(items.map { ($0.source as NSString).standardizingPath })
        var new: [QueueItem] = []
        for m in metas where have.insert((m.path as NSString).standardizingPath).inserted {
            var it = QueueItem(source: m.path)
            it.iso = m.iso; it.camera = m.camera
            new.append(it)
        }
        if !new.isEmpty { items.append(contentsOf: new) }
        return new.count
    }

    /// End of one add(): feedback when nothing (or not everything) was added, then the autotest hand-off.
    private func finishAdd(found: Int, added: Int) {
        reading = max(0, reading - 1)
        if added < found { appendLog("Added \(added), \(found - added) already queued") }
        if added == 0 && !autotest {
            alert = AlertInfo(title: "Nothing added",
                              message: found == 0 ? "No ARW, RW2 or DNG files were found in what you dropped."
                                                  : "All \(found) photo\(found == 1 ? " is" : "s are") already in the queue.")
        }
        if reading == 0 && autotestWaiting { autotestWaiting = false; autotestStart() }
    }

    func addViaPanel() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        p.message = "Choose ARW, RW2 or DNG files, or folders containing them"
        p.prompt = "Add"
        if p.runModal() == .OK { add(p.urls) }
    }

    // MARK: Output folder
    func chooseOut() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Choose"
        p.directoryURL = URL(fileURLWithPath: outDir)
        if p.runModal() == .OK, let u = p.url { setOut(u.path) }
    }

    func setOut(_ path: String) {
        guard !running else {
            alert = AlertInfo(title: "Batch in progress", message: "Change the output folder after the batch finishes or is cancelled.")
            return
        }
        guard !path.isEmpty else { return }
        if isForbiddenOutput(path) { alert = offloadAlert(path); return }
        outDir = (path as NSString).standardizingPath
    }

    /// isForbiddenOutput is also true when a folder in the path can't be read (privacy), so say both.
    private func offloadAlert(_ dir: String) -> AlertInfo {
        AlertInfo(title: "Can't write to the Offload Drive",
                  message: "\(dir) is on \(Cfg.forbiddenRoot) (or links to it), or a folder in its path can't be read. "
                    + "Lumen Denoise never writes to that drive; if this isn't the Offload Drive, give the app access in "
                    + "System Settings › Privacy & Security › Files and Folders / Full Disk Access, or choose another folder (⇧⌘O).")
    }

    // MARK: Queue editing
    /// Removes items, except the working one and the rest of the running chunk (the engine already has them).
    func remove(_ ids: Set<UUID>) {
        let busy = Set(chunkPending)
        items.removeAll { ids.contains($0.id) && $0.state != .working && !busy.contains($0.id) }
        let gone = ids.filter { id in !items.contains { $0.id == id } }
        selection.subtract(gone)
        forceIDs.subtract(gone)
        rerunAfterResult.subtract(gone)
    }

    func clearFinished() {
        let gone = Set(items.filter { $0.state == .done || $0.state == .skipped }.map(\.id))
        remove(gone)
    }

    func clearAll() {
        guard !running else { return }
        items.removeAll(); selection.removeAll(); forceIDs.removeAll(); lastSummary = nil
    }

    /// Re-queues failed and cancelled items. When idle, runs only those (other queued photos stay queued).
    func retryFailed() {
        var ids = Set<UUID>()
        for i in items.indices where items[i].state == .failed || items[i].state == .cancelled {
            items[i].state = .queued; items[i].error = nil; ids.insert(items[i].id)
        }
        runScoped(ids)
    }

    /// Force a re-run even if the output already exists (ignores skipDone for these items). When idle, runs only these.
    func reprocess(_ ids: Set<UUID>) {
        let busy = Set(chunkPending)
        var requeued = Set<UUID>()
        for i in items.indices where ids.contains(items[i].id) && items[i].state != .working && !busy.contains(items[i].id) {
            items[i].state = .queued; items[i].error = nil
            forceIDs.insert(items[i].id); requeued.insert(items[i].id)
        }
        runScoped(requeued)
    }

    /// Idle: start a batch limited to `ids`. Running: widen a limited batch so it includes them.
    private func runScoped(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if running { batchScope?.formUnion(ids) } else { beginBatch(scope: ids) }
    }

    /// A photo the running engine already has keeps the chunk strength; if the override changes it, re-run it afterwards.
    func setOverride(_ id: UUID, _ s: Double?) {
        guard let i = index(id) else { return }
        items[i].strengthOverride = s.map { min(1, max(0, $0)) }
        guard running, chunkPending.contains(id) else { return }
        if abs(strength.strength(for: items[i]) - chunkStrength) > 0.001 {
            if rerunAfterResult.insert(id).inserted {
                appendLog("\((items[i].source as NSString).lastPathComponent): new strength applies after this run; it will be re-run")
            }
        } else {
            rerunAfterResult.remove(id)
        }
    }

    // MARK: Finder / pasteboard
    func reveal(_ id: UUID?) {
        let fm = FileManager.default
        if let id, let it = items.first(where: { $0.id == id }) {
            let path = fm.fileExists(atPath: it.output) ? it.output : it.source
            if fm.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                return
            }
        }
        if fm.fileExists(atPath: outDir) { NSWorkspace.shared.open(URL(fileURLWithPath: outDir, isDirectory: true)) }
    }

    func openOutput(_ id: UUID) {
        guard let it = items.first(where: { $0.id == id }), FileManager.default.fileExists(atPath: it.output) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: it.output))
    }

    func copyError(_ id: UUID) {
        guard let it = items.first(where: { $0.id == id }), let e = it.error else { return }
        let text = "\(e.title)\n\(e.detail)\n\nFile: \(it.source)\n\n\(e.raw)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Batch: start / cancel
    /// Runs all queued items (failed and cancelled ones are re-queued) chunk by chunk.
    func start() { beginBatch(scope: nil) }

    /// scope nil: the whole queue, failed/cancelled re-queued. Otherwise only the (already queued) items in `scope`.
    private func beginBatch(scope: Set<UUID>?) {
        guard !running else { return }
        let rerun: Set<ItemState> = scope == nil ? [.queued, .failed, .cancelled] : [.queued]
        guard items.contains(where: { rerun.contains($0.state) && (scope?.contains($0.id) ?? true) }) else { return }
        if let problem = validateOutput(outDir) { alert = problem; return }
        if scope == nil {
            for i in items.indices where items[i].state == .failed || items[i].state == .cancelled {
                items[i].state = .queued; items[i].error = nil
            }
        }
        sweepStaleStaging(in: outDir)
        requestNotificationPermission()

        batchScope = scope
        batchOut = outDir
        batchStart = Date()
        batchDone = 0; batchFailed = 0; batchSkipped = 0
        lastEmptyFailure = nil; stopReason = nil
        throughput.reset(now: batchStart)
        lastSummary = nil
        running = true; cancelling = false
        appendLog("— Batch started → \(batchOut)")

        // Same-name outputs from an earlier shoot: read their EXIF off-main before the first chunk (prepareQueued uses it).
        let pairs = unverifiedOutputPairs()
        guard !pairs.isEmpty else { runNextChunk(); return }
        let token = UUID()
        prepToken = token
        Task { [weak self] in
            let checked = await Task.detached(priority: .userInitiated) { pairs.map { ($0.key, sameShot($0.source, $0.output)) } }.value
            guard let self, self.prepToken == token, self.running else { return }
            self.prepToken = nil
            for (k, same) in checked { self.shotCache[k] = same }
            self.runNextChunk()
        }
    }

    /// (source, planned output) of queued in-scope items whose output name already exists and isn't verified yet.
    private func unverifiedOutputPairs() -> [ShotPair] {
        var copy = items
        assignOutputs(&copy, outDir: batchOut)
        let fm = FileManager.default
        return copy.filter { $0.state == .queued && inScope($0) }
            .map { ShotPair(source: $0.source, output: $0.output) }
            .filter { shotCache[$0.key] == nil && fm.fileExists(atPath: $0.output) }
    }

    func cancel() {
        guard running, !cancelling else { return }
        cancelling = true
        appendLog("— Cancelling…")
        if let r = run { r.cancel() } else { prepToken = nil; finishBatch() }
    }

    /// Guard, create, re-check (a symlink could have appeared) and write-test the output folder.
    private func validateOutput(_ dir: String) -> AlertInfo? {
        if isForbiddenOutput(dir) { return offloadAlert(dir) }
        // An unplugged external drive: never create "/Volumes/<name>/…" on the boot disk.
        let comps = (dir as NSString).standardizingPath.split(separator: "/").map(String.init)
        if comps.count >= 2, comps[0].lowercased() == "volumes" {
            let vol = "/Volumes/" + comps[1]
            let isVolume = (try? URL(fileURLWithPath: vol).resolvingSymlinksInPath().resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
            if !isVolume {
                return AlertInfo(title: "Output drive not connected",
                                 message: "“\(comps[1])” isn't mounted. Connect it or choose another output folder (⇧⌘O).")
            }
        }
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch { return AlertInfo(title: "Can't create the output folder", message: "\(dir): \(error.localizedDescription)") }
        if isForbiddenOutput(dir) { return offloadAlert(dir) }
        let probe = (dir as NSString).appendingPathComponent(Cfg.stagingPrefix + "write-test-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: probe, contents: Data("ok".utf8)) else {
            return AlertInfo(title: "Output folder isn't writable",
                             message: "Lumen Denoise can't write to \(dir). Check its permissions, or give the app Full Disk Access in System Settings › Privacy & Security.")
        }
        try? FileManager.default.removeItem(atPath: probe)
        return nil
    }

    /// Assigns outputs to newly queued items, marks already-done ones skipped and missing sources failed.
    /// An existing output that is a different shot (Sony numbering repeats across cards) gets a fresh
    /// "<stem>-N-Denoised.dng" instead of being skipped or overwritten.
    private func prepareQueued() {
        var copy = items
        assignOutputs(&copy, outDir: batchOut)
        let fm = FileManager.default
        var claimed = Set(copy.map { $0.output.lowercased() })
        for i in copy.indices where copy[i].state == .queued && inScope(copy[i]) {
            if fm.fileExists(atPath: copy[i].output) && !isSameShot(copy[i].source, copy[i].output) {
                let old = copy[i].output
                copy[i].output = freeOutputName(for: copy[i].source, claimed: claimed)
                claimed.insert(copy[i].output.lowercased())
                appendLog("\((old as NSString).lastPathComponent) belongs to a different photo; saving as \((copy[i].output as NSString).lastPathComponent)")
            }
            if !fm.fileExists(atPath: copy[i].source) {
                copy[i].state = .failed
                copy[i].error = UserFacingError(title: ErrorTitle.sourceMissing,
                                                detail: "The original was moved or deleted, or its drive is not connected.",
                                                raw: copy[i].source)
                batchFailed += 1
            } else if skipDone && !forceIDs.contains(copy[i].id) && isAlreadyDone(source: copy[i].source, output: copy[i].output) {
                copy[i].state = .skipped
                copy[i].finishedAt = Date()
                batchSkipped += 1
            }
        }
        if copy != items { items = copy }
    }

    /// Cached sameShot (EXIF capture time + camera); computed synchronously for pairs the start() pre-check missed.
    private func isSameShot(_ source: String, _ output: String) -> Bool {
        let key = ShotPair(source: source, output: output).key
        if let v = shotCache[key] { return v }
        let v = sameShot(source, output)
        shotCache[key] = v
        return v
    }

    /// First "<stem>-N-Denoised.dng" (N ≥ 2) not claimed in the queue and either free on disk or already this shot's output.
    private func freeOutputName(for source: String, claimed: Set<String>) -> String {
        let base = (batchOut as NSString).standardizingPath
        let s = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        var n = 2
        while true {
            let p = (base as NSString).appendingPathComponent("\(s)-\(n)-Denoised.dng")
            if !claimed.contains(p.lowercased()) && (!FileManager.default.fileExists(atPath: p) || isSameShot(source, p)) { return p }
            n += 1
        }
    }

    // MARK: Batch: chunks
    private func runNextChunk() {
        guard running else { return }
        if cancelling { finishBatch(); return }
        // Re-check every chunk: the folder (or a link in its path) may have changed since start().
        if isForbiddenOutput(batchOut) {
            failRemaining(UserFacingError(title: ErrorTitle.offload, detail: "That drive is read-only for Lumen Denoise. Choose another output folder (⇧⌘O).",
                                          raw: batchOut), alertTitle: "Stopped: output is on the Offload Drive")
            return
        }
        if stopIfOutputGone() { return }
        prepareQueued()
        guard let chunk = planChunks(items.filter { inScope($0) }, settings: strength).first else { finishBatch(); return }
        let files = chunk.itemIDs.compactMap { id in items.first { $0.id == id }?.source }

        let r = EngineRun(files: files, outDir: batchOut, strength: chunk.strength)
        let token = UUID()
        r.onResult = { [weak self] res in MainActor.assumeIsolated { self?.handleResult(res, token: token) } }
        r.onLog = { [weak self] line in MainActor.assumeIsolated { self?.appendLog(line) } }
        r.onExit = { [weak self] e in MainActor.assumeIsolated { self?.handleExit(e, token: token) } }
        run = r; runToken = token
        chunkStrength = chunk.strength
        chunkPending = chunk.itemIDs
        chunkResults = 0
        markNextWorking()
        appendLog("— \(files.count) photo\(files.count == 1 ? "" : "s") at \(Int((chunk.strength * 100).rounded()))%")
        updateBadge()
        throughput.restartClock()                        // this run's first result includes model load
        do {
            try r.start()
            if autotestCancelAfter == 0 {                // cancel during model load / first file (cleanup test)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.cancel()
                }
            }
        } catch {
            r.removeStaging()
            run = nil; runToken = nil; chunkPending = []
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            appendLog(msg)
            let e = translateError(stderr: msg, code: -1, uncaughtSignal: false)
            failRemaining(e, alertTitle: e.title)
        }
    }

    /// Output drive ejected or folder deleted mid-batch: stop with one alert instead of failing every photo.
    private func stopIfOutputGone() -> Bool {
        guard batchRemaining > 0 else { return false }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: batchOut, isDirectory: &isDir) && isDir.boolValue { return false }
        failRemaining(UserFacingError(title: "Output folder is gone",
                                      detail: "\(batchOut) disappeared (drive ejected or folder deleted). Reconnect it and press Denoise to continue.",
                                      raw: batchOut),
                      alertTitle: "Stopped: output folder is gone")
        return true
    }

    /// The engine works through its files in order: the first pending one is the one being denoised.
    private func markNextWorking() {
        for id in chunkPending {
            guard let i = index(id) else { continue }
            if items[i].state == .queued { items[i].state = .working }
            if items[i].state == .working { return }
        }
    }

    private func handleResult(_ res: EngineResult, token: UUID) {
        guard token == runToken, let r = run else { return }
        let resStem = stemOf(res.file)
        let candidates = chunkPending.compactMap { id in index(id) }
        guard let i = candidates.first(where: { items[$0].source == res.file })
                ?? candidates.first(where: { stemOf(items[$0].source) == resStem }) else {
            appendLog("Ignoring result for \(res.file) (no longer in the queue)")
            return
        }
        let id = items[i].id
        chunkPending.removeAll { $0 == id }
        forceIDs.remove(id)
        chunkResults += 1
        lastEmptyFailure = nil

        do {
            try moveIntoPlace(staged: res.out, stagingDir: r.stagingDir, final: items[i].output, source: items[i].source)
            items[i].state = .done
            items[i].error = nil
            if let iso = res.iso { items[i].iso = iso }
            if let m = res.model, !m.isEmpty { items[i].camera = m }
            items[i].usedStrength = chunkStrength
            items[i].seconds = res.total_s ?? res.denoise_s
            items[i].finishedAt = Date()
            shotCache[ShotPair(source: items[i].source, output: items[i].output).key] = true
            batchDone += 1
            throughput.record(now: Date())
            if rerunAfterResult.remove(id) != nil {            // override changed while the engine had it
                items[i].state = .queued
                batchDone -= 1
                forceIDs.insert(id)
                batchScope?.insert(id)
            }
        } catch {
            if stopIfOutputGone() { return }
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            var e = translateError(stderr: msg, code: 1, uncaughtSignal: false)
            if e.title == ErrorTitle.unknown { e = UserFacingError(title: "Couldn't save the denoised file", detail: msg, raw: "\(error)") }
            items[i].state = .failed; items[i].error = e
            batchFailed += 1
            appendLog("Couldn't move \(res.out): \(msg)")
        }
        markNextWorking()
        updateBadge()
        if let n = autotestCancelAfter, batchDone >= n, !cancelling { cancel() }
    }

    private struct MoveError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Moves a finished staged DNG to its final name. Refuses anything not directly inside the staging dir, any final
    /// path outside the batch output folder, the Offload Drive, and an existing output of a different shot or source.
    /// Records `source` on the final file (outputOwnerXattr) so later naming / skip-done can tell shoots apart.
    private func moveIntoPlace(staged: String, stagingDir: String, final: String, source: String) throws {
        let fm = FileManager.default
        let name = (staged as NSString).lastPathComponent
        let expected = (stagingDir as NSString).appendingPathComponent(name)
        func resolved(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }
        guard !name.isEmpty, name != ".", name != "..", resolved(staged) == resolved(expected) else {
            throw MoveError("The engine reported an output outside its staging folder (\(staged)).")
        }
        guard let attrs = try? fm.attributesOfItem(atPath: expected), (attrs[.type] as? FileAttributeType) == .typeRegular,
              ((attrs[.size] as? NSNumber)?.int64Value ?? 0) > 0 else {
            throw MoveError("The engine reported \(name) but the file is missing or empty.")
        }
        let norm = { (p: String) in (p as NSString).standardizingPath.lowercased() }
        guard !final.isEmpty, norm((final as NSString).deletingLastPathComponent) == norm(batchOut) else {
            throw MoveError("Refusing to write \(final): it is outside the output folder.")
        }
        guard !isForbiddenOutput(final) else {
            throw MoveError("Refusing to write \(final): \(Cfg.forbiddenRoot) is read-only for Lumen Denoise.")
        }
        if (try? fm.attributesOfItem(atPath: final)) != nil {
            let owner = outputOwner(final).map { ($0 as NSString).standardizingPath }
            if !sameShot(expected, final) || (owner != nil && owner != (source as NSString).standardizingPath) {
                throw MoveError("A different photo already uses the name \((final as NSString).lastPathComponent); it was left untouched.")
            }
        }
        // POSIX rename: atomic on one volume (staging is inside the output folder), works on exFAT/SMB, replaces a file
        // or a symlink without following it, and refuses to replace a folder.
        if rename(expected, final) != 0 {
            throw MoveError("Couldn't save \(final): \(String(cString: strerror(errno)))")
        }
        let owner = Array(source.utf8)
        _ = setxattr(final, outputOwnerXattr, owner, owner.count, 0, 0)   // best effort (exFAT/SMB may refuse)
    }

    private func handleExit(_ e: EngineExit, token: UUID) {
        guard token == runToken else { return }
        run?.removeStaging()
        run = nil; runToken = nil
        let unfinished = chunkPending.compactMap { id in index(id) }
            .filter { items[$0].state == .queued || items[$0].state == .working }
        chunkPending = []
        rerunAfterResult.removeAll()                       // unfinished ones re-plan at their new strength anyway

        if e.cancelled || cancelling {
            finishBatch()                                  // marks working + queued as cancelled
            return
        }
        if e.code != 0 || e.uncaughtSignal {
            let err = translateError(stderr: e.stderrTail, code: e.code, uncaughtSignal: e.uncaughtSignal)
            appendLog("Engine exited (\(e.uncaughtSignal ? "signal" : "code") \(e.code)): \(err.title)")
            if stopIfOutputGone() { return }
            if isFatal(err) { failRemaining(err, alertTitle: err.title); return }
            // Died before its first result twice in a row with the same error: every launch will, so stop now
            // instead of relaunching once per photo. (Per-file errors are exempt: two bad files in a row happen.)
            let perFile: Set<String> = [ErrorTitle.unsupported, ErrorTitle.notFound]
            if chunkResults == 0 && !perFile.contains(err.title) {
                if lastEmptyFailure == err.title { failRemaining(err, alertTitle: err.title); return }
                lastEmptyFailure = err.title
            } else {
                lastEmptyFailure = nil
            }
            if let first = unfinished.first {
                items[first].state = .failed; items[first].error = err
                forceIDs.remove(items[first].id)
                batchFailed += 1
            }
            for i in unfinished.dropFirst() where items[i].state == .working { items[i].state = .queued }
        } else {
            for i in unfinished {
                items[i].state = .failed
                items[i].error = UserFacingError(title: ErrorTitle.noResult, detail: "Engine finished without a result for this file.",
                                                 raw: e.stderrTail)
                batchFailed += 1
            }
        }
        runNextChunk()
    }

    /// Fatal problem: every remaining queued item gets `err`, the batch stops, one alert.
    private func failRemaining(_ err: UserFacingError, alertTitle: String) {
        var n = 0
        for i in items.indices where (items[i].state == .queued || items[i].state == .working) && inScope(items[i]) {
            items[i].state = .failed; items[i].error = err; n += 1
        }
        batchFailed += n
        alert = AlertInfo(title: alertTitle, message: err.detail + (n > 0 ? "\n\n\(n) photo\(n == 1 ? " was" : "s were") not processed." : ""))
        stopReason = alertTitle
        finishBatch()
    }

    private func finishBatch() {
        let wasCancelled = cancelling
        if let r = run { r.cancel(); r.removeStaging() }
        run = nil; runToken = nil; chunkPending = []; prepToken = nil
        for i in items.indices where items[i].state == .working || (wasCancelled && items[i].state == .queued && inScope(items[i])) {
            items[i].state = .cancelled
        }
        batchScope = nil; rerunAfterResult.removeAll()
        if !batchOut.isEmpty { sweepStaleStaging(in: batchOut) }
        running = false; cancelling = false
        updateBadge()

        let elapsed = Date().timeIntervalSince(batchStart)
        let verb = stopReason != nil ? "Stopped after" : wasCancelled ? "Cancelled after" : "Denoised"
        var parts = ["\(verb) \(batchDone) photo\(batchDone == 1 ? "" : "s")"]
        if batchFailed > 0 { parts.append("\(batchFailed) failed") }
        if batchSkipped > 0 { parts.append("\(batchSkipped) skipped") }
        parts.append(formatDuration(elapsed))
        let summary = parts.joined(separator: " · ")
        lastSummary = summary
        appendLog("— \(summary)")
        saveNow()

        if autotest { autotestFinish(); return }
        if batchFinished > 0 && !NSApp.isActive {
            if notifyWhenDone { notify(title: stopReason.map { "Batch stopped: \($0)" } ?? (wasCancelled ? "Batch cancelled" : "Batch finished"), body: summary) }
            _ = NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: Termination
    /// Cancel, hard-kill every engine group, remove staging and save. Interrupted items resume on next launch.
    func appWillTerminate() {
        let r = run
        runToken = nil; run = nil
        r?.cancel()
        killAllRunningEngines()
        r?.removeStaging()
        for i in items.indices where items[i].state == .working { items[i].state = .queued }
        running = false; cancelling = false
        NSApp.dockTile.badgeLabel = nil
        saveTask?.cancel()
        saveNow()
    }

    // MARK: Notifications / dock
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && !autotest }   // `swift run` has no bundle id

    private func requestNotificationPermission() {
        guard notifyWhenDone, canNotify, !askedNotify else { return }
        askedNotify = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { _ in }
    }

    private func updateBadge() {
        let remaining = batchRemaining
        NSApp.dockTile.badgeLabel = running && remaining > 0 ? "\(remaining)" : nil
    }

    // MARK: Log / persistence
    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func persistStrength() {
        guard !autotest, let data = try? JSONEncoder().encode(strength) else { return }
        UserDefaults.standard.set(data, forKey: Keys.strength)
    }

    /// Debounced (0.5 s) queue save.
    private func scheduleSave() {
        guard !autotest else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard !autotest else { return }
        do { try saveQueue(SavedQueue(items: items, outDir: outDir), to: QueueModel.queueDir) }
        catch { appendLog("Couldn't save the queue: \(error.localizedDescription)") }
    }

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    // MARK: Autotest (env-driven, used on the Mac to smoke-test without clicking)
    /// LUMEN_AUTOTEST_FILES (colon-separated files/folders) + LUMEN_AUTOTEST_OUT; optional LUMEN_AUTOTEST_CANCEL_AFTER,
    /// LUMEN_AUTOTEST_STRENGTH, LUMEN_AUTOTEST_PREVIEW. Writes <OUT>/autotest.json, then quits. Never touches saved state.
    func autotestIfRequested() {
        guard autotest, !autotestFinished, !autotestWaiting, !running else { return }
        let env = ProcessInfo.processInfo.environment
        guard let files = env["LUMEN_AUTOTEST_FILES"], let out = env["LUMEN_AUTOTEST_OUT"] else { return }
        autotestCancelAfter = env["LUMEN_AUTOTEST_CANCEL_AFTER"].flatMap { Int($0) }
        autotestPreview = env["LUMEN_AUTOTEST_PREVIEW"].flatMap { $0.isEmpty ? nil : $0 }
        if let s = env["LUMEN_AUTOTEST_STRENGTH"].flatMap({ Double($0) }) {
            strength.global = min(1, max(0, s)); strength.autoByISO = false
        }
        setOut(out)
        guard outDir == (out as NSString).standardizingPath else { autotestFinish(); return }
        let urls = files.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        guard !urls.isEmpty else { autotestFinish(); return }
        autotestWaiting = true
        add(urls)
    }

    private func autotestStart() {
        start()
        if !running && !autotestFinished { autotestFinish() }
    }

    private func autotestFinish() {
        guard autotest, !autotestFinished else { return }
        autotestFinished = true
        if let png = autotestPreview, !isForbiddenOutput(png), let it = items.first(where: { $0.state == .done }) {
            writePreviewPNG(before: URL(fileURLWithPath: it.source), after: URL(fileURLWithPath: it.output), to: png) { [weak self] ok in
                MainActor.assumeIsolated {
                    self?.appendLog(ok ? "Preview written to \(png)" : "Preview FAILED for \(it.output)")
                    self?.writeAutotestReport(previewOK: ok)
                    NSApp.terminate(nil)
                }
            }
            return
        }
        writeAutotestReport(previewOK: nil)
        NSApp.terminate(nil)
    }

    private func writeAutotestReport(previewOK: Bool?) {
        guard let out = ProcessInfo.processInfo.environment["LUMEN_AUTOTEST_OUT"] else { return }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: out)) ?? []
        let finished = Set(items.filter { $0.state == .done || $0.state == .skipped }
            .map { ($0.output as NSString).lastPathComponent.lowercased() })
        let previewName = autotestPreview.map { ($0 as NSString).lastPathComponent.lowercased() }
        let stale = names.filter { $0.hasPrefix(Cfg.stagingPrefix) }.map { (out as NSString).appendingPathComponent($0) }
        let partial = names.filter { n in
            let l = n.lowercased()
            return !n.hasPrefix(Cfg.stagingPrefix) && l != "autotest.json" && l != ".ds_store" && l != previewName && !finished.contains(l)
        }.map { (out as NSString).appendingPathComponent($0) }

        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        let rows: [[String: Any]] = items.map { it -> [String: Any] in
            [
                "file": it.source,
                "output": it.output,
                "status": it.state.rawValue,
                "seconds": opt(it.seconds),
                "iso": opt(it.iso),
                "strength": it.usedStrength ?? strengthFor(it),
                "error": opt(it.error.map { "\($0.title): \($0.detail)" }),
            ]
        }
        var obj: [String: Any] = [
            "outDir": outDir,
            "alert": opt(alert.map { "\($0.title): \($0.message)" }),
            "staleStagingDirs": stale,
            "partialFilesOutsideStaging": partial,
            "items": rows,
        ]
        if let ok = previewOK { obj["preview"] = ok }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        guard !isForbiddenOutput(out) else {                // never write to the Offload Drive, not even the report
            print("autotest: refusing to write report to \(out)")
            print(String(decoding: data, as: UTF8.self))
            return
        }
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: (out as NSString).appendingPathComponent("autotest.json")))
    }
}

// MARK: - Helpers (nonisolated)

private func stemOf(_ path: String) -> String {
    (((path as NSString).lastPathComponent as NSString).deletingPathExtension).lowercased()
}

/// ISO and camera model from the RAW's EXIF/TIFF headers via ImageIO (no decode). Runs on a background queue.
private func readMeta(_ url: URL) -> FileMeta {
    var iso: Int?, camera: String?
    let opts = [kCGImageSourceShouldCache: false] as CFDictionary
    if let src = CGImageSourceCreateWithURL(url as CFURL, opts),
       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [String: Any] {
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        if let v = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.intValue, v > 0 { iso = v }
        // ISOSpeedRatings saturates at 65535; RecommendedExposureIndex carries the real value above that.
        if iso == nil || iso == 65535, let rei = (exif?[kCGImagePropertyExifRecommendedExposureIndex as String] as? NSNumber)?.intValue,
           rei > 0 { iso = rei }
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        camera = (tiff?[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return FileMeta(path: url.path, iso: iso, camera: camera)
}

/// A (source, existing output) pair whose capture identity is checked before skipping or replacing.
private struct ShotPair: Sendable {
    let source: String, output: String
    var key: String { source + "\u{0}" + output.lowercased() }
}

/// Capture time + sub-seconds + camera model from EXIF/TIFF (the engine copies EXIF into its DNG).
private func shotID(_ path: String) -> (date: String, subsec: String?, model: String?)? {
    let opts = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, opts),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [String: Any],
          let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
          let date = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, !date.isEmpty else { return nil }
    func text(_ v: Any?) -> String? {
        let s = (v as? String ?? (v as? NSNumber)?.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }
    let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
    return (date, text(exif[kCGImagePropertyExifSubsecTimeOriginal as String]), text(tiff?[kCGImagePropertyTIFFModel as String]))
}

/// False only when both files carry a capture time and they (or sub-seconds / camera, where both have them) differ.
/// Unreadable metadata counts as the same shot, i.e. the old name-only behaviour.
private func sameShot(_ a: String, _ b: String) -> Bool {
    guard let x = shotID(a), let y = shotID(b) else { return true }
    if x.date != y.date { return false }
    if let s = x.subsec, let t = y.subsec, s != t { return false }
    if let m = x.model, let n = y.model, m.caseInsensitiveCompare(n) != .orderedSame { return false }
    return true
}

import SwiftUI
import AppKit

enum Status: Equatable {
    case queued, working
    case done(seconds: Double, iso: Int?)
    case failed(String)
}

struct Item: Identifiable {
    let id = UUID()
    let url: URL
    var status: Status = .queued
}

@MainActor
final class QueueModel: ObservableObject {
    @Published var items: [Item] = []
    @Published var strength = 100.0
    @Published var outDir = Cfg.defaultOut
    @Published var running = false
    @Published var alert: String?
    private var run: EngineRun?
    private var cancelled = false
    private var autotestOut: String?

    var finished: Int { items.filter { if case .done = $0.status { return true }; if case .failed = $0.status { return true }; return false }.count }

    func add(_ urls: [URL]) {
        guard !running else { return }
        let have = Set(items.map(\.url.path))
        for u in collectInputs(urls) where !have.contains(u.path) { items.append(Item(url: u)) }
    }

    func clear() { if !running { items.removeAll() } }

    func chooseOut() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { setOut(u.path) }
    }

    func setOut(_ path: String) {
        if isForbiddenOutput(path) { alert = "Output can't be on \(Cfg.forbiddenRoot) — that drive is read-only for this app."; return }
        outDir = path
    }

    func reveal() { NSWorkspace.shared.open(URL(fileURLWithPath: outDir, isDirectory: true)) }

    func start() {
        guard !running else { return }
        let todo = items.indices.filter { items[$0].status != .working }
        for i in todo { items[i].status = .queued }
        guard !items.isEmpty else { return }
        if isForbiddenOutput(outDir) { alert = "Output can't be on \(Cfg.forbiddenRoot)."; return }
        do { try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
        catch { alert = "Can't create output folder: \(error.localizedDescription)"; return }
        // Re-check after creation so a symlink created in the meantime can't slip through.
        if isForbiddenOutput(outDir) { alert = "Output can't be on \(Cfg.forbiddenRoot)."; return }

        running = true; cancelled = false
        items[0].status = .working
        let r = EngineRun(); run = r
        do {
            try r.start(files: items.map(\.url.path), out: outDir, strength: strength / 100,
                        onResult: { [weak self] res in MainActor.assumeIsolated { self?.got(res) } },
                        onExit: { [weak self] code, err in MainActor.assumeIsolated { self?.exited(code, err) } })
        } catch { running = false; fail(error.localizedDescription) }
    }

    func cancel() { cancelled = true; run?.cancel() }

    private func got(_ r: EngineResult) {
        let name = URL(fileURLWithPath: r.file).lastPathComponent
        guard let i = items.firstIndex(where: { $0.url.path == r.file })
                ?? items.firstIndex(where: { $0.url.lastPathComponent == name && !isTerminal($0.status) }) else { return }
        items[i].status = .done(seconds: r.total_s ?? r.denoise_s ?? 0, iso: r.iso)
        if let n = items.firstIndex(where: { $0.status == .queued }) { items[n].status = .working }
    }

    private func exited(_ code: Int32, _ err: String) {
        running = false; run = nil
        let msg = cancelled ? "Cancelled" : (err.isEmpty ? "Engine exited with code \(code)" : err)
        if code != 0 || cancelled {
            for i in items.indices where !isTerminal(items[i].status) { items[i].status = .failed(msg) }
        } else {
            for i in items.indices where !isTerminal(items[i].status) { items[i].status = .failed("No result from engine") }
        }
        if let out = autotestOut { writeAutotest(out); NSApp.terminate(nil) }
    }

    private func fail(_ m: String) { for i in items.indices { items[i].status = .failed(m) } }
    private func isTerminal(_ s: Status) -> Bool { if case .done = s { return true }; if case .failed = s { return true }; return false }

    // MARK: hidden debug path
    func autotestIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let files = env["LUMEN_AUTOTEST_FILES"], let out = env["LUMEN_AUTOTEST_OUT"] else { return }
        autotestOut = out
        setOut(out)
        add(files.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        start()
        if !running { writeAutotest(out); NSApp.terminate(nil) }
    }

    private func writeAutotest(_ out: String) {
        let rows: [[String: Any]] = items.map { it in
            var d: [String: Any] = ["file": it.url.path]
            switch it.status {
            case .done(let s, let iso): d["status"] = "done"; d["seconds"] = s; d["iso"] = iso ?? NSNull()
            case .failed(let m): d["status"] = "failed"; d["error"] = m
            default: d["status"] = "\(it.status)"
            }
            return d
        }
        let obj: [String: Any] = ["outDir": outDir, "alert": alert ?? NSNull(), "items": rows]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: out + "/autotest.json"))
        }
    }
}

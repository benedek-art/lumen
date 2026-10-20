import Foundation

// MARK: - Constants (the only place that knows about the Python engine)
enum Cfg {
    static let projectRoot = "/Users/benedekpurnhauser/Projects/lumen-denoise"
    static let python = projectRoot + "/.venv/bin/python"
    static let module = "lumen_denoise.infer"
    static let forbiddenRoot = "/Volumes/Offload Drive"   // archive drive: never write here
    static let defaultOut = NSHomeDirectory() + "/Pictures/Lumen Denoise"
    static let exts: Set<String> = ["arw", "rw2", "dng"]
}

// MARK: - Output-folder safety guard
/// True if `path` (lexically standardized AND symlink-resolved) is inside the archive drive.
func isForbiddenOutput(_ path: String) -> Bool {
    let roots = [Cfg.forbiddenRoot, realPath(Cfg.forbiddenRoot)].map { $0.lowercased() }
    func inside(_ p: String) -> Bool {
        let q = p.lowercased()
        return roots.contains { q == $0 || q.hasPrefix($0 + "/") }
    }
    let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
    // Check lexical ("a/link/../b" -> "a/b") and kernel-resolved (follows the link before "..") forms.
    return inside(lexical) || inside(realPath(path)) || inside(realPath(lexical))
}

/// realpath() of the deepest existing ancestor + the not-yet-existing remainder.
private func realPath(_ path: String) -> String {
    var rest: [String] = []
    var cur = path
    while true {
        if let r = realpath(cur, nil) {
            defer { free(r) }
            let full = String(cString: r) + (rest.isEmpty ? "" : "/" + rest.reversed().joined(separator: "/"))
            return URL(fileURLWithPath: full).standardizedFileURL.path
        }
        let parent = (cur as NSString).deletingLastPathComponent
        if parent == cur || parent.isEmpty { return URL(fileURLWithPath: path).standardizedFileURL.path }
        rest.append((cur as NSString).lastPathComponent)
        cur = parent
    }
}

func selfTest() -> Bool {
    let fm = FileManager.default
    let tmp = NSTemporaryDirectory() + "lumen-guard-\(getpid())"
    try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: tmp + "/link", withDestinationPath: Cfg.forbiddenRoot)
    defer { try? fm.removeItem(atPath: tmp) }
    let cases: [(String, Bool)] = [
        (Cfg.forbiddenRoot + "/x", true),
        (Cfg.forbiddenRoot, true),
        (Cfg.forbiddenRoot.lowercased() + "/x", true),
        (Cfg.forbiddenRoot + " Two/x", false),
        (NSHomeDirectory() + "/Pictures/Lumen Denoise", false),
        (NSHomeDirectory() + "/Pictures/../../../Volumes/Offload Drive/y", true),
        (tmp + "/link/out", true),
        (tmp + "/link/../Offload Drive/out", true),   // link/.. = /Volumes, so this really is the drive
        (tmp + "/link/../out", false),                // = /Volumes/out, not on the drive
        (tmp + "/nolink/../link/out", true),
        (tmp + "/link", true),
    ]
    var ok = true
    for (p, want) in cases {
        let got = isForbiddenOutput(p)
        print(got == want ? "PASS" : "FAIL", p, "refused=\(got)")
        ok = ok && got == want
    }
    return ok
}

// MARK: - File discovery
func collectInputs(_ urls: [URL]) -> [URL] {
    var out: [URL] = []
    for u in urls {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            while let f = e?.nextObject() as? URL {
                if Cfg.exts.contains(f.pathExtension.lowercased()) { out.append(f) }
            }
        } else if Cfg.exts.contains(u.pathExtension.lowercased()) { out.append(u) }
    }
    return out
}

// MARK: - Engine runner
struct EngineResult: Decodable {
    let file: String, out: String, iso: Int?, model: String?, denoise_s: Double?, total_s: Double?
}

/// Runs one batch. Callbacks arrive on the main queue.
final class EngineRun {
    private let proc = Process()
    private var buf = Data()
    private var err = Data()
    private let lock = NSLock()

    func start(files: [String], out: String, strength: Double,
               onResult: @escaping (EngineResult) -> Void,
               onExit: @escaping (Int32, String) -> Void) throws {
        proc.executableURL = URL(fileURLWithPath: Cfg.python)
        proc.currentDirectoryURL = URL(fileURLWithPath: Cfg.projectRoot)
        proc.arguments = ["-m", Cfg.module] + files + ["--out", out, "--strength", String(format: "%.2f", strength)]
        let o = Pipe(), e = Pipe()
        proc.standardOutput = o; proc.standardError = e
        func emit(_ lines: [Data]) {
            for l in lines {
                if let r = try? JSONDecoder().decode(EngineResult.self, from: l) { DispatchQueue.main.async { onResult(r) } }
            }
        }
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let d = h.availableData; if d.isEmpty { return }
            self.lock.lock(); self.buf.append(d)
            var lines: [Data] = []
            while let i = self.buf.firstIndex(of: 10) { lines.append(Data(self.buf[..<i])); self.buf.removeSubrange(...i) }
            self.lock.unlock()
            emit(lines)
        }
        e.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData; if d.isEmpty { return }
            self?.lock.lock(); self?.err.append(d); self?.lock.unlock()
        }
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            o.fileHandleForReading.readabilityHandler = nil; e.fileHandleForReading.readabilityHandler = nil
            let rest = o.fileHandleForReading.readDataToEndOfFile()
            let tail = e.fileHandleForReading.readDataToEndOfFile()
            self.lock.lock(); self.buf.append(rest); self.err.append(tail)
            let last = self.buf; let msg = String(decoding: self.err, as: UTF8.self); self.lock.unlock()
            emit(last.split(separator: 10).map { Data($0) })
            let t = msg.split(separator: "\n").suffix(6).joined(separator: "\n")
            DispatchQueue.main.async { onExit(p.terminationStatus, t) }
        }
        try proc.run()
    }

    func cancel() { if proc.isRunning { proc.terminate() } }
}

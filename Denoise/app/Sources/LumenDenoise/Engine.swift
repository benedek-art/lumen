import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Constants (the only place that knows about the Python engine)
enum Cfg {
    /// Engine checkout. Computed (not cached) so tests and the Settings picker take effect immediately.
    static var projectRoot: String {
        if let e = ProcessInfo.processInfo.environment["LUMEN_DENOISE_ROOT"], !e.isEmpty { return e }
        if let d = UserDefaults.standard.string(forKey: "engineRoot"), !d.isEmpty { return d }
        return "/Users/benedekpurnhauser/Projects/lumen-denoise"
    }
    static var python: String {
        if let e = ProcessInfo.processInfo.environment["LUMEN_PYTHON"], !e.isEmpty { return e }
        return projectRoot + "/.venv/bin/python"
    }
    static let module = "lumen_denoise.infer"
    static let forbiddenRoot = "/Volumes/Offload Drive"   // archive drive: never write here
    static let defaultOut = NSHomeDirectory() + "/Pictures/Lumen Denoise"
    static let exts: Set<String> = ["arw", "rw2", "dng"]
    static let stagingPrefix = ".lumen-staging-"
}

// MARK: - Output-folder safety guard
/// True if `path` is (or would be, once created) inside the archive drive. Checks the lexical form and a
/// component-wise symlink resolution that keeps working when the drive is not mounted (a dangling link to
/// "/Volumes/Offload Drive" is still refused). Case- and normalization-insensitive like APFS. Any link loop,
/// more than 40 hops or an unreadable component counts as forbidden. "/Volumes/Offload Drive 1" (how macOS mounts
/// the drive when a stale "/Volumes/Offload Drive" folder is left over) is refused too, and on macOS so is any
/// path whose volume is named "Offload Drive".
func isForbiddenOutput(_ path: String) -> Bool {
    let roots = Set([Cfg.forbiddenRoot, "/System/Volumes/Data" + Cfg.forbiddenRoot,   // firmlinked alias on macOS
                     resolvePath(Cfg.forbiddenRoot) ?? Cfg.forbiddenRoot].map(foldPath))
    func inside(_ p: String) -> Bool {
        let q = foldPath(p)
        return roots.contains { root in
            guard q.hasPrefix(root) else { return false }
            var rest = q.dropFirst(root.count)
            if rest.first == " " {                                      // "<root> <digits>" = renumbered mount
                rest = rest.dropFirst()
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard !digits.isEmpty else { return false }
                rest = rest.dropFirst(digits.count)
            }
            return rest.isEmpty || rest.hasPrefix("/")
        }
    }
    guard let resolved = resolvePath(path) else { return true }
    return inside(lexicalPath(path)) || inside(resolved) || onDriveVolume(resolved) || onDriveByName(resolved)
}

private func foldPath(_ p: String) -> String { p.precomposedStringWithCanonicalMapping.lowercased() }

private func absolutePath(_ p: String) -> String {
    p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
}

/// "a/./b/../c/" -> "/a/c" without touching the disk.
private func lexicalPath(_ p: String) -> String {
    var out: [Substring] = []
    for c in absolutePath(p).split(separator: "/") where c != "." {
        if c == ".." { _ = out.popLast() } else { out.append(c) }
    }
    return "/" + out.joined(separator: "/")
}

/// Kernel-style resolution, one component at a time: ".." applies to the already-resolved prefix, symlinks are
/// expanded with readlink. Components that don't exist (yet, or because the drive is unmounted) are kept
/// lexically and resolution continues. nil = loop / too many hops / error other than "doesn't exist".
private func resolvePath(_ path: String) -> String? {
    var pending = Array(absolutePath(path).split(separator: "/").map(String.init).reversed())
    var out: [String] = []
    var hops = 0
    while let c = pending.popLast() {
        if c == "." { continue }
        if c == ".." { _ = out.popLast(); continue }
        out.append(c)
        let p = "/" + out.joined(separator: "/")
        var st = stat()
        if lstat(p, &st) != 0 {
            if errno == ENOENT || errno == ENOTDIR { continue }
            return nil
        }
        guard st.st_mode & S_IFMT == S_IFLNK else { continue }
        hops += 1
        guard hops <= 40, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: p) else { return nil }
        out.removeLast()
        if target.hasPrefix("/") { out.removeAll() }
        pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
    }
    return "/" + out.joined(separator: "/")
}

/// While the drive is mounted: is the deepest existing ancestor of `resolved` on the drive's volume?
/// Catches aliases we can't see lexically (other mount points, firmlinks).
private func onDriveVolume(_ resolved: String) -> Bool {
    var root = stat(), parent = stat()
    let parentPath = (Cfg.forbiddenRoot as NSString).deletingLastPathComponent
    guard stat(Cfg.forbiddenRoot, &root) == 0, stat(parentPath, &parent) == 0,
          root.st_dev != parent.st_dev else { return false }               // not a mount point => not mounted
    var p = resolved
    while true {
        var s = stat()
        if stat(p, &s) == 0 { return s.st_dev == root.st_dev }
        let up = (p as NSString).deletingLastPathComponent
        if up == p || up.isEmpty { return false }
        p = up
    }
}

/// macOS only: is the deepest existing ancestor on a volume named like the drive (mounted anywhere)?
private func onDriveByName(_ resolved: String) -> Bool {
    #if canImport(Darwin)
    var p = resolved
    while !FileManager.default.fileExists(atPath: p) {
        let up = (p as NSString).deletingLastPathComponent
        if up == p || up.isEmpty { return false }
        p = up
    }
    let want = foldPath((Cfg.forbiddenRoot as NSString).lastPathComponent)
    if let name = (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.volumeNameKey]))?.volumeName {
        return foldPath(name) == want
    }
    #endif
    return false
}

/// Guard regression cases; prints PASS/FAIL per case. Runs on Linux too, where /Volumes does not exist, which is
/// exactly the "drive not mounted" situation.
func guardSelfTest() -> Bool {
    let fm = FileManager.default
    let tmp = NSTemporaryDirectory() + "lumen-guard-\(getpid())-\(UUID().uuidString.prefix(8))"
    try? fm.createDirectory(atPath: tmp + "/real", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmp) }
    let links: [(String, String)] = [
        ("link", Cfg.forbiddenRoot),
        ("upper", "/VOLUMES/offload drive/Sub"),
        ("rel", "link/deeper"),
        ("chain1", "chain2"), ("chain2", "rel"),
        ("vol", "/Volumes"),
        ("two", Cfg.forbiddenRoot + " Two"),
        ("loopA", "loopB"), ("loopB", "loopA"),
        ("safe", tmp + "/real"),
    ]
    for (name, dest) in links { try? fm.createSymbolicLink(atPath: tmp + "/" + name, withDestinationPath: dest) }
    let cases: [(String, Bool)] = [
        (Cfg.forbiddenRoot + "/x", true),
        (Cfg.forbiddenRoot, true),
        (Cfg.forbiddenRoot + "/", true),
        ("/Volumes/./Offload Drive/x", true),
        (Cfg.forbiddenRoot.lowercased() + "/x", true),
        (Cfg.forbiddenRoot.uppercased() + "/x", true),
        (Cfg.forbiddenRoot + " Two/x", false),
        (Cfg.forbiddenRoot + "Two", false),
        (Cfg.forbiddenRoot + " 1/x", true),             // renumbered mount after a stale mount-point folder
        (Cfg.forbiddenRoot.lowercased() + " 12", true),
        (Cfg.forbiddenRoot + " 1a/x", false),
        (Cfg.forbiddenRoot + " /x", false),
        (NSHomeDirectory() + "/Pictures/Lumen Denoise", false),
        (NSHomeDirectory() + "/Pictures/../../../Volumes/Offload Drive/y", true),
        (tmp + "/link/out", true),
        (tmp + "/link/../Offload Drive/out", true),   // link/.. = /Volumes, so this really is the drive
        (tmp + "/link/../out", false),                // = /Volumes/out, not on the drive
        (tmp + "/nolink/../link/out", true),
        (tmp + "/link", true),
        (tmp + "/upper/x", true),                     // case-insensitive link target
        (tmp + "/rel", true),                         // relative link -> link -> drive
        (tmp + "/chain1/a/b", true),                  // two-hop relative chain
        (tmp + "/vol/Offload Drive/x", true),
        (tmp + "/vol/offload drive", true),
        (tmp + "/vol/Offload Drive Two/x", false),
        (tmp + "/two/x", false),
        (tmp + "/loopA/x", true),                     // loop => refuse
        (tmp + "/safe/x", false),
        (tmp + "/real/new/sub", false),
    ]
    // The volume-name check (drive mounted under another path) needs the real drive: Mac checklist only.
    var ok = true
    for (p, want) in cases {
        let got = isForbiddenOutput(p)
        print(got == want ? "PASS" : "FAIL", "guard", p, "refused=\(got)")
        ok = ok && got == want
    }
    return ok
}

// MARK: - File discovery
/// Raw files from dropped files/folders: recursive, skips hidden files, package contents, AppleDouble "._" files,
/// our own "*-Denoised.dng" outputs and staging dirs. Sorted per dropped folder, deduplicated.
func collectInputs(_ urls: [URL]) -> [URL] {
    let fm = FileManager.default
    func wanted(_ u: URL) -> Bool {
        let name = u.lastPathComponent
        guard Cfg.exts.contains(u.pathExtension.lowercased()), !name.hasPrefix("._"),
              !name.lowercased().hasSuffix("-denoised.dng"),
              !u.pathComponents.contains(where: { $0.hasPrefix(Cfg.stagingPrefix) }) else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: u.path, isDirectory: &isDir) && !isDir.boolValue
    }
    var out: [URL] = []
    var seen = Set<String>()
    func append(_ u: URL) { if seen.insert(u.standardizedFileURL.path).inserted { out.append(u.standardizedFileURL) } }
    for u in urls {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            var found: [URL] = []
            let e = fm.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let f = e?.nextObject() as? URL {
                if f.lastPathComponent.hasPrefix(Cfg.stagingPrefix) { e?.skipDescendants(); continue }
                if wanted(f) { found.append(f) }
            }
            found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            found.forEach(append)
        } else if wanted(u) { append(u) }
    }
    return out
}

// MARK: - Engine runner
struct EngineResult: Decodable, Equatable {
    let file: String, out: String, iso: Int?, model: String?, denoise_s: Double?, total_s: Double?
}

extension EngineResult {
    private enum Keys: String, CodingKey { case file, out, iso, model, denoise_s, total_s }
    /// Tolerant: the engine prints iso as a float ("iso": 3200.0); non-finite numbers become nil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func num(_ k: Keys) -> Double? { ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil).flatMap { $0.isFinite ? $0 : nil } }
        self.init(file: try c.decode(String.self, forKey: .file), out: try c.decode(String.self, forKey: .out),
                  iso: num(.iso).map { Int($0.rounded()) }, model: try? c.decodeIfPresent(String.self, forKey: .model),
                  denoise_s: num(.denoise_s), total_s: num(.total_s))
    }
}

struct EngineExit {
    let code: Int32
    let cancelled: Bool
    let stderrTail: String       // last ~40 stderr lines
    let uncaughtSignal: Bool
}

enum EngineError: Error, LocalizedError {
    case launch(String)
    var errorDescription: String? { if case .launch(let m) = self { return m }; return nil }
}

/// Runs the module in its own process group (so cancel also reaches the DNG Converter child) and kills the group
/// if the app dies (parent pid changes).
private let bootstrap = """
import os, sys, runpy, signal, threading, time
try: os.setpgrp()
except OSError: pass
_ppid = os.getppid()
def _watch():
    while os.getppid() == _ppid: time.sleep(1)
    os.killpg(0, signal.SIGTERM)
threading.Thread(target=_watch, daemon=True).start()
sys.argv = sys.argv[1:]
runpy.run_module(sys.argv[0], run_name="__main__", alter_sys=True)
"""

/// One python process for one chunk of files with one strength. Writes into a private staging dir inside the
/// output folder; the caller moves each finished file into place. All callbacks are delivered on the MAIN queue,
/// in order, and `onExit` is delivered exactly once, after every `onResult`/`onLog`.
final class EngineRun: @unchecked Sendable {
    let files: [String], outDir: String, strength: Double
    let stagingDir: String
    var onResult: ((EngineResult) -> Void)?
    var onLog: ((String) -> Void)?
    var onExit: ((EngineExit) -> Void)?

    private let proc = Process()
    private let lock = NSLock()
    private var started = false, terminated = false, cancelled = false, finished = false
    private var exitDelivered = false            // main queue only
    private var stderrLines: [String] = []

    private static let registryLock = NSLock()
    private static var live: [ObjectIdentifier: EngineRun] = [:]

    init(files: [String], outDir: String, strength: Double) {
        self.files = files; self.outDir = outDir; self.strength = strength
        // The owner pid in the name lets sweepStaleStaging spare another live app instance's staging dir.
        stagingDir = (outDir as NSString).appendingPathComponent(Cfg.stagingPrefix + "p\(getpid())-" + UUID().uuidString)
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return started && !terminated }

    // MARK: Start
    func start() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let root = Cfg.projectRoot, python = Cfg.python
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            throw EngineError.launch("Engine folder not found at \(root). Choose the lumen-denoise folder in Settings.")
        }
        guard fm.isExecutableFile(atPath: python) else {
            throw EngineError.launch("Python not found at \(python). In \(root) run: python3 -m venv .venv && .venv/bin/pip install torch rawpy numpy tifffile")
        }
        lock.lock()
        let early = cancelled; started = true
        if early { terminated = true; finished = true }
        lock.unlock()
        if early {                                       // cancelled before start: report, launch nothing
            DispatchQueue.main.async { self.deliverExit(code: 0, signal: false) }
            return
        }
        do { try fm.createDirectory(atPath: stagingDir, withIntermediateDirectories: true) }
        catch { throw EngineError.launch("Can't write to the output folder \(outDir): \(error.localizedDescription)") }

        proc.executableURL = URL(fileURLWithPath: python)
        proc.currentDirectoryURL = URL(fileURLWithPath: root)
        proc.arguments = ["-c", bootstrap, Cfg.module] + files
            + ["--out", stagingDir, "--strength", String(format: "%.3f", strength)]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"; env["PYTHONIOENCODING"] = "utf-8"
        // Finder/Dock launches get PATH=/usr/bin:/bin:...; the engine runs exiftool by bare name (Homebrew).
        let extra = [(python as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        // Python temp files (the DNG Converter intermediates) live in staging, so cancel/crash cleanup removes them.
        env["TMPDIR"] = stagingDir
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        proc.standardInput = FileHandle.nullDevice

        let group = DispatchGroup()
        group.enter()                                    // process termination
        proc.terminationHandler = { [self] _ in
            lock.lock(); terminated = true; lock.unlock()
            group.leave()
            // A grandchild that inherited stdout/stderr may keep the pipes open: give up waiting after 2 s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                guard !exitDelivered else { return }
                killGroup(SIGKILL)
                deliverExit(code: proc.terminationStatus, signal: proc.terminationReason == .uncaughtSignal)
            }
        }
        EngineRun.registryLock.lock(); EngineRun.live[ObjectIdentifier(self)] = self; EngineRun.registryLock.unlock()
        do { try proc.run() } catch {
            EngineRun.registryLock.lock(); EngineRun.live[ObjectIdentifier(self)] = nil; EngineRun.registryLock.unlock()
            lock.lock(); terminated = true; lock.unlock()
            removeStaging()
            throw EngineError.launch("Couldn't start \(python): \(error.localizedDescription)")
        }
        let dec = JSONDecoder()
        dec.allowsJSON5 = true                           // json.dumps writes NaN/Infinity for odd noise estimates
        read(out.fileHandleForReading, group: group) { [self] line in
            if line.hasPrefix("{"), let r = try? dec.decode(EngineResult.self, from: Data(line.utf8)) {
                deliver { self.onResult?(r) }
            } else if !line.isEmpty {
                deliver { self.onLog?(line) }
            }
        }
        read(err.fileHandleForReading, group: group) { [self] line in
            lock.lock(); stderrLines.append(line); if stderrLines.count > 200 { stderrLines.removeFirst(100) }; lock.unlock()
            if !line.isEmpty { deliver { self.onLog?(line) } }
        }
        group.notify(queue: .main) { [self] in
            deliverExit(code: proc.terminationStatus, signal: proc.terminationReason == .uncaughtSignal)
        }
    }

    /// Blocking read loop on its own thread until EOF; splits on "\n" with carry-over, flushes the tail at EOF.
    private func read(_ h: FileHandle, group: DispatchGroup, line: @escaping (String) -> Void) {
        group.enter()
        let fd = h.fileDescriptor
        Thread.detachNewThread {
            var carry = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buf.withUnsafeMutableBytes { sysRead(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                carry.append(contentsOf: buf[0..<n])
                while let i = carry.firstIndex(of: 10) {
                    line(String(decoding: carry[carry.startIndex..<i], as: UTF8.self).trimmingCharacters(in: .init(charactersIn: "\r")))
                    carry.removeSubrange(carry.startIndex...i)
                }
            }
            if !carry.isEmpty { line(String(decoding: carry, as: UTF8.self)) }
            withExtendedLifetime(h) {}
            group.leave()
        }
    }

    /// Main-queue delivery that is dropped once onExit has fired (late lines after the 2 s fallback).
    private func deliver(_ f: @escaping () -> Void) {
        DispatchQueue.main.async { [self] in if !exitDelivered { f() } }
    }

    private func deliverExit(code: Int32, signal: Bool) {
        guard !exitDelivered else { return }
        exitDelivered = true
        proc.terminationHandler = nil
        EngineRun.registryLock.lock(); EngineRun.live[ObjectIdentifier(self)] = nil; EngineRun.registryLock.unlock()
        lock.lock()
        let tail = stderrLines.suffix(40).joined(separator: "\n"), wasCancelled = cancelled
        finished = true
        lock.unlock()
        onExit?(EngineExit(code: code, cancelled: wasCancelled, stderrTail: tail, uncaughtSignal: signal))
        onResult = nil; onLog = nil; onExit = nil         // break retain cycles with the caller
    }

    // MARK: Cancel / cleanup
    /// SIGTERM the whole process group, SIGKILL after 3 s if anything in it is still alive. Idempotent.
    func cancel() {
        lock.lock()
        let first = !cancelled; cancelled = true
        let live = started && !terminated
        lock.unlock()
        guard first, live else { return }
        killGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in killGroup(SIGKILL) }
    }

    /// Signals the group (pgid == pid thanks to setpgrp). Falls back to the pid itself while python has not
    /// called setpgrp yet. Never signals after onExit (the pid could have been reused by then).
    private func killGroup(_ sig: Int32) {
        lock.lock(); let ok = started && !finished, done = terminated; lock.unlock()
        let pid = proc.processIdentifier
        guard ok, pid > 0 else { return }
        if kill(-pid, sig) != 0 && !done { kill(pid, sig) }
    }

    /// rm -rf the staging dir (only if it really is one of ours).
    func removeStaging() {
        guard (stagingDir as NSString).lastPathComponent.hasPrefix(Cfg.stagingPrefix) else { return }
        try? FileManager.default.removeItem(atPath: stagingDir)
    }

    static var liveStagingDirs: Set<String> {
        registryLock.lock(); defer { registryLock.unlock() }
        return Set(live.values.map(\.stagingDir))
    }

    static func killAll() {
        registryLock.lock(); let runs = Array(live.values); registryLock.unlock()
        for r in runs { r.lock.lock(); r.cancelled = true; r.lock.unlock(); r.killGroup(SIGKILL) }
    }
}

/// libc read(2), named so it doesn't clash with EngineRun.read.
private func sysRead(_ fd: Int32, _ p: UnsafeMutableRawPointer?, _ n: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.read(fd, p, n)
    #else
    return Glibc.read(fd, p, n)
    #endif
}

/// Removes leftover ".lumen-staging-*" dirs from a previous crash: never one a live run of this process is using,
/// nor one named ".lumen-staging-p<pid>-..." whose owner is another process that is still alive.
func sweepStaleStaging(in outDir: String) {
    let fm = FileManager.default
    let live = EngineRun.liveStagingDirs
    for name in (try? fm.contentsOfDirectory(atPath: outDir)) ?? [] where name.hasPrefix(Cfg.stagingPrefix) {
        let p = (outDir as NSString).appendingPathComponent(name)
        if live.contains(p) { continue }
        let tag = name.dropFirst(Cfg.stagingPrefix.count)
        if tag.first == "p", let dash = tag.firstIndex(of: "-"), let pid = Int32(tag[tag.index(after: tag.startIndex)..<dash]),
           pid > 0, pid != getpid(), kill(pid, 0) == 0 || errno == EPERM { continue }
        try? fm.removeItem(atPath: p)
    }
}

/// For applicationWillTerminate: SIGKILL every live EngineRun process group.
func killAllRunningEngines() { EngineRun.killAll() }

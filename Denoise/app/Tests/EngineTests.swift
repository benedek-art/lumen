import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Engine tests: run the real EngineRun against Tests/fake_engine (same CLI as lumen_denoise.infer).
// Callbacks arrive on the main queue, so every wait spins the main run loop.

// MARK: - Harness

private var engineTestsOK = true

private func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    let d = detail()
    print(cond ? "PASS" : "FAIL", "engine", name, d.isEmpty || cond ? "" : "-- " + d)
    if !cond { engineTestsOK = false }
}

/// Spins the main run loop until `cond` or the timeout; returns whether `cond` became true.
@discardableResult
private func spin(_ timeout: TimeInterval, until cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !cond() && Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    return cond()
}

/// Alive and not a zombie (a reparented zombie still answers kill(pid, 0) in some containers).
private func processAlive(_ pid: pid_t) -> Bool {
    guard kill(pid, 0) == 0 else { return false }
    #if os(Linux)
    if let s = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
       let close = s.lastIndex(of: ")"), s[s.index(after: close)...].hasPrefix(" Z") { return false }
    #endif
    return true
}

private func withEnv<T>(_ vars: [String: String], _ body: () throws -> T) rethrows -> T {
    let old = vars.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
    for (k, v) in vars { setenv(k, v, 1) }
    defer { for (k, v) in old { if let v { setenv(k, v, 1) } else { unsetenv(k) } } }
    return try body()
}

/// Everything one run delivered, in delivery order.
private final class Recorder {
    enum Event { case result(EngineResult), log(String), exit(EngineExit) }
    var events: [Event] = []
    var results: [EngineResult] { events.compactMap { if case .result(let r) = $0 { return r }; return nil } }
    var logs: [String] { events.compactMap { if case .log(let l) = $0 { return l }; return nil } }
    var exits: [EngineExit] { events.compactMap { if case .exit(let e) = $0 { return e }; return nil } }
    var exitedLast: Bool { if case .exit = events.last { return true }; return false }
    var childPID: pid_t? {
        logs.lazy.compactMap { $0.hasPrefix("child pid ") ? pid_t($0.dropFirst(10)) : nil }.first
    }
    func attach(_ r: EngineRun) {
        r.onResult = { self.events.append(.result($0)) }
        r.onLog = { self.events.append(.log($0)) }
        r.onExit = { self.events.append(.exit($0)) }
    }
}

private func makeTemp(_ tag: String) -> String {
    let p = NSTemporaryDirectory() + "lumen-engine-\(tag)-\(UUID().uuidString.prefix(8))"
    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    return p
}

/// Dummy input files (the fake engine never reads them, but they make the paths realistic).
private func makeInputs(_ dir: String, _ names: [String]) -> [String] {
    names.map { n in
        let p = dir + "/" + n
        _ = FileManager.default.createFile(atPath: p, contents: Data("raw".utf8))
        return p
    }
}

private func contents(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
}

// MARK: - Tests

func runEngineTests() -> Bool {
    engineTestsOK = true
    let fakeRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fake_engine").path
    var python = ProcessInfo.processInfo.environment["LUMEN_PYTHON"] ?? ""
    if python.isEmpty {
        python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "python3"
    }
    setenv("LUMEN_DENOISE_ROOT", fakeRoot, 1)
    setenv("LUMEN_PYTHON", python, 1)
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1)          // keep __pycache__ out of Tests/fake_engine
    check(Cfg.projectRoot == fakeRoot && Cfg.python == python, "Cfg reads env at call time", "\(Cfg.projectRoot) \(Cfg.python)")

    check(guardSelfTest(), "guardSelfTest")
    testLaunchErrors()
    testNormalRun()
    testSplitJSON()
    testFailureMidChunk()
    testCancelKillsGroup()
    testSigkillEscalation()
    testGrandchildHoldsPipe()
    testCancelBeforeStart()
    testNaNAndTempFiles()
    testSweepStaleStaging()
    testCollectInputs()
    return engineTestsOK
}

private func testLaunchErrors() {
    let out = makeTemp("launch"); defer { try? FileManager.default.removeItem(atPath: out) }
    func launchMessage() -> String? {
        do { try EngineRun(files: ["/x.ARW"], outDir: out, strength: 1).start(); return nil }
        catch { return error.localizedDescription }
    }
    let noPy = withEnv(["LUMEN_PYTHON": "/nonexistent/python"]) { launchMessage() }
    check(noPy?.contains("/nonexistent/python") == true, "missing python -> launch error", noPy ?? "no error")
    let noRoot = withEnv(["LUMEN_DENOISE_ROOT": "/nonexistent/engine", "LUMEN_PYTHON": "/bin/sh"]) { launchMessage() }
    check(noRoot?.contains("/nonexistent/engine") == true, "missing engine folder -> launch error", noRoot ?? "no error")
    check(contents(out).isEmpty, "failed launch leaves no staging dir", "\(contents(out))")
}

private func testNormalRun() {
    let dir = makeTemp("normal"); defer { try? FileManager.default.removeItem(atPath: dir) }
    let files = makeInputs(dir, ["DSC0001.ARW", "P1000002.RW2", "IMG_3.dng"])
    let out = dir + "/out"
    let rec = Recorder()
    let run = EngineRun(files: files, outDir: out, strength: 0.75)
    rec.attach(run)
    withEnv(["FAKE_NOISE": "1"]) {
        do { try run.start() } catch { check(false, "normal: start", "\(error)") }
    }
    check(run.isRunning, "normal: isRunning after start")
    spin(15) { !rec.exits.isEmpty }
    check(rec.results.map(\.file) == files, "normal: 3 results in order", "\(rec.results.map(\.file))")
    check(rec.results.allSatisfy { $0.out.hasPrefix(run.stagingDir + "/") && $0.iso == 3200 && $0.model == "ILCE-7M4" },
          "normal: outputs inside staging, fields decoded")
    check(contents(run.stagingDir) == ["DSC0001-Denoised.dng", "IMG_3-Denoised.dng", "P1000002-Denoised.dng"],
          "normal: staging holds the 3 DNGs", "\(contents(run.stagingDir))")
    let body = (try? String(contentsOfFile: run.stagingDir + "/IMG_3-Denoised.dng", encoding: .utf8)) ?? ""
    check(body.contains("strength=0.75"), "normal: strength passed", body)
    check(rec.logs.contains("Loading model (fake)...") && rec.logs.contains("warning: fake stderr chatter")
          && rec.logs.contains { $0.hasPrefix("progress:") }, "normal: non-JSON stdout + stderr go to onLog", "\(rec.logs)")
    check(!rec.logs.contains { $0.hasPrefix("{") }, "normal: no JSON in log")
    check(rec.exits.count == 1 && rec.exits[0].code == 0 && !rec.exits[0].cancelled && !rec.exits[0].uncaughtSignal,
          "normal: clean exit")
    check(rec.exitedLast, "normal: onExit after all results/logs")
    check(!run.isRunning, "normal: not running after exit")
    spin(0.5) { false }
    check(rec.exits.count == 1 && rec.exitedLast, "normal: onExit exactly once")
    run.removeStaging()
    check(contents(out).isEmpty, "normal: removeStaging", "\(contents(out))")
}

private func testSplitJSON() {
    let dir = makeTemp("split"); defer { try? FileManager.default.removeItem(atPath: dir) }
    let files = makeInputs(dir, ["A.ARW", "B.ARW"])
    let rec = Recorder()
    let run = EngineRun(files: files, outDir: dir + "/out", strength: 1)
    rec.attach(run)
    withEnv(["FAKE_SPLIT_JSON": "1"]) { try? run.start() }
    spin(15) { !rec.exits.isEmpty }
    check(rec.results.map(\.file) == files, "split JSON lines decode", "results \(rec.results.count) logs \(rec.logs)")
    check(rec.logs.isEmpty, "split JSON: no halves in log", "\(rec.logs)")
    run.removeStaging()
}

private func testFailureMidChunk() {
    let dir = makeTemp("fail"); defer { try? FileManager.default.removeItem(atPath: dir) }
    let files = makeInputs(dir, ["a.ARW", "b.ARW", "c.ARW"])
    let rec = Recorder()
    let run = EngineRun(files: files, outDir: dir + "/out", strength: 1)
    rec.attach(run)
    withEnv(["FAKE_FAIL_ON": "b."]) { try? run.start() }
    spin(15) { !rec.exits.isEmpty }
    let e = rec.exits.first
    check(rec.results.map(\.file) == [files[0]], "failure: only the first result", "\(rec.results.map(\.file))")
    check(e != nil && e!.code != 0 && !e!.cancelled, "failure: nonzero exit", "code \(e?.code ?? -1)")
    check(e?.stderrTail.contains("Traceback") == true && e?.stderrTail.contains("RuntimeError: fake failure on b.ARW") == true,
          "failure: traceback tail", e?.stderrTail ?? "")
    check(rec.exitedLast && rec.exits.count == 1, "failure: onExit once, last")
    run.removeStaging()
}

private func testCancelKillsGroup() {
    let dir = makeTemp("cancel"); defer { try? FileManager.default.removeItem(atPath: dir) }
    let files = makeInputs(dir, (1...6).map { "C\($0).ARW" })
    let out = dir + "/out"
    let rec = Recorder()
    let run = EngineRun(files: files, outDir: out, strength: 1)
    rec.attach(run)
    withEnv(["FAKE_SLEEP": "1", "FAKE_SPAWN_CHILD": "1"]) { try? run.start() }
    spin(15) { !rec.results.isEmpty }
    let child = rec.childPID
    check(child.map(processAlive) == true, "cancel: grandchild running before cancel", "\(String(describing: child))")
    let t0 = Date()
    run.cancel(); run.cancel()                       // idempotent
    spin(6) { !rec.exits.isEmpty }
    let dt = Date().timeIntervalSince(t0)
    check(rec.exits.count == 1 && rec.exits[0].cancelled, "cancel: onExit(cancelled)", "exits \(rec.exits.count)")
    check(dt < 5, "cancel: onExit within 5 s", String(format: "%.2f s", dt))
    check(rec.results.count < files.count, "cancel: stopped mid-run", "\(rec.results.count)")
    if let child { check(spin(3) { !processAlive(child) }, "cancel: grandchild killed (process group)", "pid \(child)") }
    check(!run.isRunning, "cancel: not running")
    run.removeStaging()
    check(contents(out).isEmpty, "cancel: no files left after removeStaging", "\(contents(out))")
    spin(0.3) { false }
    check(rec.exits.count == 1 && rec.exitedLast, "cancel: onExit exactly once, last")
}

private func testSigkillEscalation() {
    let dir = makeTemp("sigkill"); defer { try? FileManager.default.removeItem(atPath: dir) }
    let rec = Recorder()
    let run = EngineRun(files: makeInputs(dir, ["S1.ARW", "S2.ARW"]), outDir: dir + "/out", strength: 1)
    rec.attach(run)
    withEnv(["FAKE_SLEEP": "5", "FAKE_IGNORE_TERM": "1", "FAKE_NOISE": "1"]) { try? run.start() }
    spin(10) { !rec.logs.isEmpty }                   // engine is up and has installed SIG_IGN
    let t0 = Date()
    run.cancel()
    spin(7) { !rec.exits.isEmpty }
    let dt = Date().timeIntervalSince(t0)
    let e = rec.exits.first
    check(e?.cancelled == true && e?.uncaughtSignal == true && e?.code == SIGKILL,
          "sigkill: SIGTERM-ignoring engine is killed", "\(String(describing: e))")
    check(dt >= 2.5 && dt < 5.5, "sigkill: after the 3 s grace period", String(format: "%.2f s", dt))
    run.removeStaging()
}

private func testGrandchildHoldsPipe() {
    let dir = makeTemp("eof"); defer { try? FileManager.default.removeItem(atPath: dir) }
    let rec = Recorder()
    let run = EngineRun(files: makeInputs(dir, ["G.ARW"]), outDir: dir + "/out", strength: 1)
    rec.attach(run)
    let t0 = Date()
    withEnv(["FAKE_SPAWN_CHILD": "1"]) { try? run.start() }
    spin(10) { !rec.exits.isEmpty }
    let dt = Date().timeIntervalSince(t0)
    check(rec.results.count == 1 && rec.exits.count == 1 && rec.exits[0].code == 0 && rec.exitedLast,
          "eof fallback: result then clean onExit", "results \(rec.results.count) exits \(rec.exits.count)")
    check(dt < 6, "eof fallback: onExit ~2 s after engine exit despite open pipe", String(format: "%.2f s", dt))
    if let child = rec.childPID { check(spin(3) { !processAlive(child) }, "eof fallback: leftover grandchild killed") }
    else { check(false, "eof fallback: child pid logged") }
    spin(0.3) { false }
    check(rec.exits.count == 1 && rec.exitedLast, "eof fallback: onExit exactly once, last")
    run.removeStaging()
}

private func testCancelBeforeStart() {
    let dir = makeTemp("early"); defer { try? FileManager.default.removeItem(atPath: dir) }
    let rec = Recorder()
    let run = EngineRun(files: makeInputs(dir, ["E.ARW"]), outDir: dir + "/out", strength: 1)
    rec.attach(run)
    run.cancel()
    try? run.start()
    spin(3) { !rec.exits.isEmpty }
    check(rec.exits.count == 1 && rec.exits[0].cancelled && rec.results.isEmpty, "cancel before start: cancelled exit, no launch")
    check(!FileManager.default.fileExists(atPath: dir + "/out"), "cancel before start: nothing written")
    check(!run.isRunning, "cancel before start: not running")
}

/// NaN/Infinity in a result line still decodes; the engine's temp files live in staging, so cancel cleans them up.
private func testNaNAndTempFiles() {
    let dir = makeTemp("tmpfiles"); defer { try? FileManager.default.removeItem(atPath: dir) }
    let files = makeInputs(dir, ["N1.ARW", "N2.ARW", "N3.ARW", "N4.ARW"])
    let rec = Recorder()
    let run = EngineRun(files: files, outDir: dir + "/out", strength: 1)
    rec.attach(run)
    withEnv(["FAKE_NAN": "1", "FAKE_TMPFILE": "1", "FAKE_SLEEP": "1"]) { try? run.start() }
    spin(15) { !rec.results.isEmpty }
    check(rec.results.first?.iso == 3200 && rec.results.first?.file == files[0], "NaN/Infinity line decodes",
          "results \(rec.results.count) logs \(rec.logs)")
    run.cancel()
    spin(6) { !rec.exits.isEmpty }
    let tmps = rec.logs.compactMap { $0.hasPrefix("tmp dir ") ? String($0.dropFirst(8)) : nil }
    check(!tmps.isEmpty && tmps.allSatisfy { $0.hasPrefix(run.stagingDir + "/") }, "engine temp files go to staging", "\(tmps)")
    run.removeStaging()
    check(tmps.allSatisfy { !FileManager.default.fileExists(atPath: $0) } && contents(dir + "/out").isEmpty,
          "cancel: no temp or partial files left", "\(contents(dir + "/out"))")
}

private func testSweepStaleStaging() {
    let out = makeTemp("sweep"); defer { try? FileManager.default.removeItem(atPath: out) }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: out + "/\(Cfg.stagingPrefix)old/sub", withIntermediateDirectories: true)
    _ = fm.createFile(atPath: out + "/\(Cfg.stagingPrefix)old/x-Denoised.dng", contents: Data("p".utf8))
    _ = fm.createFile(atPath: out + "/keep-Denoised.dng", contents: Data("k".utf8))
    let alive = Cfg.stagingPrefix + "p1-x"                         // pid 1 is always alive: another app instance
    let mine = Cfg.stagingPrefix + "p\(getpid())-x", dead = Cfg.stagingPrefix + "p2147480000-x"
    for d in [alive, mine, dead] { try? fm.createDirectory(atPath: out + "/" + d, withIntermediateDirectories: true) }
    sweepStaleStaging(in: out)
    check(contents(out) == [alive, "keep-Denoised.dng"].sorted(), "sweepStaleStaging removes stale staging dirs only",
          "\(contents(out))")
}

private func testCollectInputs() {
    let d = makeTemp("collect"); defer { try? FileManager.default.removeItem(atPath: d) }
    let fm = FileManager.default
    for sub in ["shoot/sub", "shoot/.hidden", "shoot/\(Cfg.stagingPrefix)x", "shoot/folder.dng", "other"] {
        try? fm.createDirectory(atPath: d + "/" + sub, withIntermediateDirectories: true)
    }
    for f in ["shoot/img10.ARW", "shoot/img2.arw", "shoot/b.RW2", "shoot/notes.txt", "shoot/.dot.ARW", "shoot/._img2.arw",
              "shoot/img2-Denoised.dng", "shoot/IMG2-DENOISED.DNG", "shoot/sub/c.DNG", "shoot/.hidden/h.ARW",
              "shoot/\(Cfg.stagingPrefix)x/s.ARW", "other/z.arw", "loose.RW2"] {
        _ = fm.createFile(atPath: d + "/" + f, contents: Data("r".utf8))
    }
    let got = collectInputs([URL(fileURLWithPath: d + "/shoot"), URL(fileURLWithPath: d + "/loose.RW2"),
                             URL(fileURLWithPath: d + "/shoot/img2.arw"),            // duplicate of a folder member
                             URL(fileURLWithPath: d + "/shoot/sub/../img10.ARW"),    // duplicate, unstandardized
                             URL(fileURLWithPath: d + "/other/"), URL(fileURLWithPath: d + "/missing.ARW")])
        .map { u -> String in      // relative to the temp dir (robust to /var -> /private/var on macOS)
            let base = "/" + (d as NSString).lastPathComponent + "/"
            return u.path.range(of: base).map { String(u.path[$0.upperBound...]) } ?? u.path
        }
    let want = ["shoot/b.RW2", "shoot/img2.arw", "shoot/img10.ARW", "shoot/sub/c.DNG", "loose.RW2", "other/z.arw"]
    check(got == want, "collectInputs filters, sorts per folder, dedups", "\(got)")
}

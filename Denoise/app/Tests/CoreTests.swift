import Foundation

// Tests for Core.swift (pure queue logic). Called from Tests/main.swift; prints PASS/FAIL lines.

func runCoreTests() -> Bool {
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ info: @autoclosure () -> String = "") {
        print(ok ? "PASS" : "FAIL", "core:", name, ok ? "" : info())
        if !ok { failures += 1 }
    }
    let fm = FileManager.default
    let tmp = NSTemporaryDirectory() + "lumen-core-\(getpid())-\(UUID().uuidString.prefix(8))"
    try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: tmp) }

    // MARK: translateError
    func tb(_ frames: String, _ last: String) -> String {
        "Traceback (most recent call last):\n  File \"<frozen runpy>\", line 198, in _run_module_as_main\n\(frames)\n\(last)\n"
    }
    let cases: [(String, String, Int32, Bool, String, Bool)] = [   // name, stderr, code, signal, expected title prefix, fatal
        ("unsupported raw", tb("  File \"/p/lumen_denoise/raw.py\", line 20, in load\n    with rawpy.imread(str(path)) as r:\n  File \"rawpy/_rawpy.pyx\", line 427, in rawpy._rawpy.RawPy.open_file",
                               "rawpy._rawpy.LibRawFileUnsupportedError: b'Unsupported file format or not RAW file'"),
         1, false, ErrorTitle.unsupported, false),
        ("no torch", tb("  File \"/p/lumen_denoise/infer.py\", line 9, in <module>\n    import torch", "ModuleNotFoundError: No module named 'torch'"),
         1, false, "Python package missing: torch", true),
        ("dotted module", tb("    import rawpy._rawpy", "ModuleNotFoundError: No module named 'rawpy._rawpy'"),
         1, false, "Python package missing: rawpy", true),
        ("no engine code", "/p/.venv/bin/python: No module named lumen_denoise.infer\n"
            + tb("", "ModuleNotFoundError: No module named 'lumen_denoise'"), 1, false, ErrorTitle.engineCode, true),
        ("weights", tb("  File \"/p/.venv/lib/python3.12/site-packages/torch/serialization.py\", line 1065, in load\n    with _open_file_like(f, \"rb\") as opened_file:",
                       "FileNotFoundError: [Errno 2] No such file or directory: '/Users/b/Projects/lumen-denoise/runs/A/best.pt'"),
         1, false, ErrorTitle.weights, true),
        ("default weights", tb("", "FileNotFoundError: [Errno 2] No such file or directory: '/p/weights/lumen_denoise.pt'"),
         1, false, ErrorTitle.weights, true),
        ("dng converter", tb("  File \"/p/lumen_denoise/dng.py\", line 48, in write_cfa_dng_adobe\n    raise FileNotFoundError(\"Adobe DNG Converter not found (set LUMEN_DNG_CONVERTER)\")",
                             "FileNotFoundError: Adobe DNG Converter not found (set LUMEN_DNG_CONVERTER)"),
         1, false, ErrorTitle.converter, true),
        ("exiftool", tb("  File \"/usr/lib/python3.12/subprocess.py\", line 1955, in _execute_child\n    raise child_exception_type(errno_num, err_msg, err_filename)",
                        "FileNotFoundError: [Errno 2] No such file or directory: 'exiftool'"), 1, false, ErrorTitle.exiftool, true),
        ("disk full", tb("  File \"/p/lumen_denoise/dng.py\", line 60, in write_cfa_dng_adobe\n    f.write(buf)", "OSError: [Errno 28] No space left on device"),
         1, false, ErrorTitle.diskFull, true),
        ("permission", tb("  File \"/p/lumen_denoise/raw.py\", line 20, in load", "PermissionError: [Errno 1] Operation not permitted: '/Users/b/Desktop/DSC01234.ARW'"),
         1, false, ErrorTitle.permission, false),
        ("memory", tb("  File \"/p/lumen_denoise/infer.py\", line 34, in denoise_packed", "MemoryError: Unable to allocate 1.47 GiB for an array with shape (4, 3500, 5264) and data type float32"),
         1, false, ErrorTitle.memory, false),
        ("mps oom", tb("", "RuntimeError: MPS backend out of memory (MPS allocated: 17.8 GB, other allocations: 1.2 GB)"),
         1, false, ErrorTitle.memory, false),
        ("signal 9", "", 9, true, ErrorTitle.memory, false),
        ("cancel", "", 15, true, ErrorTitle.cancelled, false),
        ("offload", "refusing to write onto the Offload Drive\n", 1, false, ErrorTitle.offload, true),
        ("python missing", "Python not found at /Users/b/Projects/lumen-denoise/.venv/bin/python", -1, false, ErrorTitle.python, true),
        ("exec 127", "env: python3: No such file or directory", 127, false, ErrorTitle.python, true),
        ("engine folder", "Engine folder not found: /Users/b/Projects/lumen-denoise", -1, false, ErrorTitle.engineFolder, true),
        ("source missing", tb("", "FileNotFoundError: [Errno 2] No such file or directory: '/Volumes/SD/DSC1.ARW'"),
         1, false, ErrorTitle.notFound, false),
        ("other signal", "", 11, true, ErrorTitle.crashed, false),
        ("unknown", tb("", "ValueError: cfa shape (10, 10) matches neither visible nor full raw size"), 1, false, ErrorTitle.unknown, false),
        ("empty", "", 3, false, ErrorTitle.unknown, false),
    ]
    for (name, err, code, sig, title, fatal) in cases {
        let e = translateError(stderr: err, code: code, uncaughtSignal: sig)
        check("translateError \(name)", e.title.hasPrefix(title) && !e.detail.isEmpty && !e.raw.isEmpty, "\(e)")
        check("isFatal \(name)", isFatal(e) == fatal, "\(e.title)")
    }
    let py = translateError(stderr: "Python not found at /x/.venv/bin/python", code: -1, uncaughtSignal: false)
    check("python detail names path + fix", py.detail.contains("/x/.venv/bin/python") && py.detail.contains("⌘,"), py.detail)
    let unk = translateError(stderr: tb("", "ValueError: boom"), code: 1, uncaughtSignal: false)
    check("unknown detail = last exception", unk.detail == "ValueError: boom", unk.detail)
    check("weights detail names file", translateError(stderr: cases[4].1, code: 1, uncaughtSignal: false).detail.contains("best.pt"))
    check("short titles", cases.allSatisfy { translateError(stderr: $0.1, code: $0.2, uncaughtSignal: $0.3).title.count <= 40 })

    // MARK: StrengthSettings
    var st = StrengthSettings.default
    func item(_ src: String, iso: Int? = nil, ov: Double? = nil, state: ItemState = .queued) -> QueueItem {
        var i = QueueItem(source: src); i.iso = iso; i.strengthOverride = ov; i.state = state; return i
    }
    check("band <=800", st.strength(for: item("/a", iso: 800)) == 0.55)
    check("band 801", st.strength(for: item("/a", iso: 801)) == 0.75)
    check("band 3200", st.strength(for: item("/a", iso: 3200)) == 0.75)
    check("band 12800", st.strength(for: item("/a", iso: 12800)) == 0.9)
    check("band 51200", st.strength(for: item("/a", iso: 51200)) == 1.0)
    check("no iso -> global", st.strength(for: item("/a")) == 1.0)
    check("override wins", st.strength(for: item("/a", iso: 100, ov: 0.3)) == 0.3)
    st.global = 0.62
    st.autoByISO = false
    check("auto off -> global rounded", st.strength(for: item("/a", iso: 100)) == 0.6)
    check("override rounds", st.strength(for: item("/a", ov: 0.68)) == 0.7)
    check("clamp", st.strength(for: item("/a", ov: 1.7)) == 1.0 && st.strength(for: item("/a", ov: -1)) == 0.0)
    var unsorted = StrengthSettings(bands: [ISOBand(maxISO: 6400, strength: 0.8), ISOBand(maxISO: 400, strength: 0.4)])
    check("unsorted bands", unsorted.strength(for: item("/a", iso: 200)) == 0.4 && unsorted.strength(for: item("/a", iso: 1000)) == 0.8)
    check("above all bands -> top band", unsorted.strength(for: item("/a", iso: 25600)) == 0.8)
    unsorted.bands = []
    check("no bands -> global", unsorted.strength(for: item("/a", iso: 25600)) == 1.0)
    if let d = try? JSONEncoder().encode(StrengthSettings.default),
       let back = try? JSONDecoder().decode(StrengthSettings.self, from: d) {
        check("settings codable", back == StrengthSettings.default)
    } else { check("settings codable", false) }

    // MARK: assignOutputs
    var items = [item("/a/DSC1.ARW"), item("/b/DSC1.ARW"), item("/c/dsc1.rw2"), item("/a/P2.RW2")]
    assignOutputs(&items, outDir: "/out/")
    check("names", items.map(\.output) == ["/out/DSC1-Denoised.dng", "/out/DSC1-2-Denoised.dng",
                                            "/out/dsc1-3-Denoised.dng", "/out/P2-Denoised.dng"], "\(items.map(\.output))")
    var again = items
    again.remove(at: 0)
    again.insert(item("/z/DSC1.ARW"), at: 0)
    assignOutputs(&again, outDir: "/out")
    check("stable", Array(again.dropFirst().map(\.output)) == Array(items.dropFirst().map(\.output))
          && again[0].output == "/out/DSC1-Denoised.dng", "\(again.map(\.output))")
    var moved = items
    assignOutputs(&moved, outDir: "/other")
    check("new outDir renames queued", moved[0].output == "/other/DSC1-Denoised.dng")
    var mixed = items
    mixed[0].state = .done
    mixed[1].state = .done
    assignOutputs(&mixed, outDir: "/other")
    check("done keeps old output", mixed[0].output == "/out/DSC1-Denoised.dng" && mixed[2].output == "/other/dsc1-Denoised.dng",
          "\(mixed.map(\.output))")
    var dup = [item("/a/X.ARW"), item("/b/X.ARW")]
    dup[0].output = "/out/X-Denoised.dng"; dup[1].output = "/out/x-denoised.dng"
    assignOutputs(&dup, outDir: "/out")
    check("duplicate claim resolved", dup[0].output == "/out/X-Denoised.dng" && dup[1].output == "/out/X-2-Denoised.dng",
          "\(dup.map(\.output))")

    // MARK: planChunks
    let auto = StrengthSettings.default
    var plan = [item("/a/1.ARW", iso: 100), item("/a/2.ARW", iso: 200), item("/a/3.ARW", iso: 6400),
                item("/a/4.ARW", iso: 100, state: .done), item("/a/5.ARW", iso: 6400), item("/b/5.arw", iso: 6400),
                item("/a/6.ARW", iso: 6400, state: .failed)]
    var chunks = planChunks(plan, settings: auto)
    check("chunks grouped", chunks.map { $0.itemIDs } == [[plan[0].id, plan[1].id], [plan[2].id, plan[4].id], [plan[5].id]]
          && chunks.map(\.strength) == [0.55, 0.9, 0.9], "\(chunks)")
    plan = (0..<130).map { item("/a/\($0).ARW") }
    chunks = planChunks(plan, settings: auto)
    check("max 60", chunks.map { $0.itemIDs.count } == [60, 60, 10]
          && chunks.flatMap(\.itemIDs) == plan.map(\.id))
    check("empty plan", planChunks([], settings: auto).isEmpty)

    // MARK: isAlreadyDone
    let src = tmp + "/A.ARW", out = tmp + "/A-Denoised.dng", empty = tmp + "/E-Denoised.dng"
    _ = fm.createFile(atPath: src, contents: Data([1]))
    _ = fm.createFile(atPath: out, contents: Data([1, 2]))
    _ = fm.createFile(atPath: empty, contents: Data())
    let old = Date(timeIntervalSinceNow: -3600)
    try? fm.setAttributes([.modificationDate: old], ofItemAtPath: src)
    check("done when newer", isAlreadyDone(source: src, output: out))
    check("not done when empty", !isAlreadyDone(source: src, output: empty))
    check("not done when missing", !isAlreadyDone(source: src, output: tmp + "/nope.dng") && !isAlreadyDone(source: src, output: ""))
    try? fm.setAttributes([.modificationDate: old.addingTimeInterval(-60)], ofItemAtPath: out)
    check("not done when older", !isAlreadyDone(source: src, output: out))

    // MARK: Throughput / formatDuration
    var tp = Throughput()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    check("tp empty", tp.secondsPerFile == nil && tp.eta(remaining: 5) == nil && tp.filesPerMinute == nil)
    tp.reset(now: t0)
    tp.record(now: t0.addingTimeInterval(10))
    check("tp seed", tp.secondsPerFile == 10 && tp.filesPerMinute == 6)
    tp.record(now: t0.addingTimeInterval(14))
    let ema = 0.3 * 4 + 0.7 * 10
    check("tp ema", abs((tp.secondsPerFile ?? 0) - ema) < 1e-9, "\(String(describing: tp.secondsPerFile))")
    check("tp eta", abs((tp.eta(remaining: 10) ?? 0) - ema * 10) < 1e-9 && tp.eta(remaining: 0) == 0)
    tp.reset(now: t0.addingTimeInterval(1000))
    check("tp reset", tp.secondsPerFile == nil)
    tp.record(now: t0.addingTimeInterval(1003))
    check("tp ignores pause", tp.secondsPerFile == 3)
    let fd: [(TimeInterval, String)] = [(0, "0 s"), (42, "42 s"), (59.4, "59 s"), (60, "1 min"), (179, "3 min"),
                                        (3600, "1 h 00 min"), (3900, "1 h 05 min"), (36000, "10 h 00 min"), (-5, "0 s")]
    for (s, want) in fd { check("formatDuration \(s)", formatDuration(s) == want, formatDuration(s)) }

    // MARK: saveQueue / loadQueue
    let qdir = tmp + "/support"
    let s1 = tmp + "/S1.ARW", s2 = tmp + "/S2.ARW", s3 = tmp + "/S3.ARW", o1 = tmp + "/S1-Denoised.dng"
    for p in [s1, s2, s3, o1] { _ = fm.createFile(atPath: p, contents: Data([1])) }
    var q = [item(s1, iso: 3200, ov: 0.7, state: .done), item(s2, state: .working), item(s3, state: .done),
             item(tmp + "/gone.ARW"), item(tmp + "/gone2.ARW", state: .done)]
    q[0].output = o1; q[0].usedStrength = 0.7; q[0].seconds = 3.4; q[0].camera = "ILCE-7M4"
    q[0].finishedAt = Date(timeIntervalSince1970: 1_700_000_000)
    q[1].error = UserFacingError(title: "t", detail: "d", raw: "r")
    q[2].output = tmp + "/S3-Denoised.dng"            // output missing on disk
    q[4].output = o1
    do {
        try saveQueue(SavedQueue(items: q, outDir: "/out"), to: qdir)
        let l = loadQueue(from: qdir)
        check("load", l != nil && l?.outDir == "/out" && l?.version == 1 && l?.items.count == 5)
        if let l = l {
            check("done kept intact", l.items[0] == q[0], "\(l.items[0])")
            check("working -> queued", l.items[1].state == .queued && l.items[1].id == q[1].id)
            check("done w/o output -> queued", l.items[2].state == .queued)
            check("missing source -> failed", l.items[3].state == .failed && l.items[3].error?.title == ErrorTitle.sourceMissing)
            check("done with output, source gone -> kept", l.items[4].state == .done)
        }
        try saveQueue(SavedQueue(items: [], outDir: "/o2"), to: qdir)
        check("overwrite", loadQueue(from: qdir)?.items.isEmpty == true)
    } catch { check("save", false, "\(error)") }
    check("load missing dir", loadQueue(from: tmp + "/nothing") == nil)
    try? "not json".write(toFile: qdir + "/queue.json", atomically: true, encoding: .utf8)
    check("load garbage", loadQueue(from: qdir) == nil)

    // MARK: Integration cases (v0.2 review fixes)
    let offSrc = "/Volumes/Offload Drive/DCIM/DSC01234.ARW"
    let conv = translateError(stderr: tb("  File \"/p/lumen_denoise/dng.py\", line 40, in write",
        "subprocess.CalledProcessError: Command '['/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter', '-c', '\(offSrc)']' returned non-zero exit status 1."),
        code: 1, uncaughtSignal: false)
    check("converter failure on Offload source", conv.title == ErrorTitle.converterFailed && !isFatal(conv), conv.title)
    let nf = translateError(stderr: tb("    with rawpy.imread(str(path)) as r:",
        "FileNotFoundError: [Errno 2] No such file or directory: '\(offSrc)'"), code: 1, uncaughtSignal: false)
    check("missing Offload source is not the Offload refusal", nf.title == ErrorTitle.notFound && !isFatal(nf), nf.title)
    let pyMsg = translateError(stderr: "Python not found at /x/.venv/bin/python. In /x run: python3 -m venv .venv && .venv/bin/pip install torch",
                               code: -1, uncaughtSignal: false)
    check("python fix-it kept", pyMsg.title == ErrorTitle.python && pyMsg.detail.contains("python3 -m venv") && pyMsg.detail.contains("⌘,"),
          pyMsg.detail)

    let mixed2 = [1600, 6400, 1600, 6400, 400, 1600].enumerated().map { item("/m/\($0.offset).ARW", iso: $0.element) }
    let mc = planChunks(mixed2, settings: auto)
    check("interleaved ISOs grouped by strength", mc.map { $0.itemIDs } == [[mixed2[0].id, mixed2[2].id, mixed2[5].id],
          [mixed2[1].id, mixed2[3].id], [mixed2[4].id]] && mc.map(\.strength) == [0.75, 0.9, 0.55], "\(mc)")

    var tc = Throughput()
    tc.reset(now: t0); tc.record(now: t0.addingTimeInterval(10)); tc.record(now: t0.addingTimeInterval(14))
    let kept = tc.secondsPerFile
    tc.restartClock(); tc.record(now: t0.addingTimeInterval(100))      // next run's first result (model load)
    check("tp restartClock keeps average, skips load", tc.secondsPerFile == kept, "\(String(describing: tc.secondsPerFile))")

    // Output ownership (xattr written by Model.moveIntoPlace). Skipped if the temp file system has no user xattrs.
    let own = tmp + "/own", ownSrc = own + "/card2/DSC1.ARW", ownOut = own + "/out/DSC1-Denoised.dng"
    try? fm.createDirectory(atPath: own + "/card2", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: own + "/out", withIntermediateDirectories: true)
    _ = fm.createFile(atPath: ownSrc, contents: Data([1]))
    _ = fm.createFile(atPath: ownOut, contents: Data([1, 2]))
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: ownSrc)
    let setx = Process()
    setx.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    setx.arguments = ["python3", "-c", "import os,sys; os.setxattr(sys.argv[1], sys.argv[2], b'/card1/DSC1.ARW')", ownOut, outputOwnerXattr]
    setx.standardError = FileHandle.nullDevice
    if (try? setx.run()) != nil { setx.waitUntilExit() }
    if setx.terminationStatus == 0 && outputOwner(ownOut) == "/card1/DSC1.ARW" {
        var ow = [item(ownSrc)]
        assignOutputs(&ow, outDir: own + "/out")
        check("output of another source -> -2", ow[0].output == own + "/out/DSC1-2-Denoised.dng", ow[0].output)
        check("other source's output is not 'already done'", !isAlreadyDone(source: ownSrc, output: ownOut))
    } else {
        print("SKIP core: output ownership (no user xattrs on \(tmp))")
    }

    print(failures == 0 ? "PASS core: all" : "FAIL core: \(failures) failure(s)")
    return failures == 0
}

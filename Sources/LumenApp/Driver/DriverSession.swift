// DriverSession.swift
// One scenario run: setup, the step loop, the report, the watchdog.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI

struct DriverError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// One step of a scenario: a JSON object with a `do` verb.
struct DriverStep {
    let raw: [String: Any]
    let index: Int

    var verb: String { raw["do"] as? String ?? "" }
    var id: String { raw["id"] as? String ?? "s\(index)" }

    func has(_ key: String) -> Bool { raw[key] != nil && !(raw[key] is NSNull) }
    func string(_ key: String) -> String? { raw[key] as? String }
    func double(_ key: String) -> Double? { (raw[key] as? NSNumber)?.doubleValue }
    func int(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue }
    func bool(_ key: String) -> Bool? { (raw[key] as? NSNumber)?.boolValue }
    func doubles(_ key: String) -> [Double]? {
        (raw[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
    }
    func strings(_ key: String) -> [String] {
        (raw[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

/// What the render model put on screen, and when.
struct DriverFrame {
    let t: Double
    let recipe: Recipe
    let isDraft: Bool
    let width: Int
    let height: Int
    let generation: UInt64
    let embedded: Bool
    let region: Bool
    let nativeLongEdge: Int
    let model: Int
}

/// The recipe as it stood just after one input event was handled.
struct DriverSample {
    let t: Double
    let recipe: Recipe
}

/// Main-thread liveness, readable from the watchdog thread.
final class DriverHeartbeat {
    private let lock = NSLock()
    private var beat = DriverClock.now()
    private var stepIndex = -1
    private var stepVerb = ""

    func touch() {
        lock.lock()
        beat = DriverClock.now()
        lock.unlock()
    }

    func enterStep(_ step: Int, verb: String) {
        lock.lock()
        stepIndex = step
        stepVerb = verb
        lock.unlock()
    }

    func read() -> (beat: Double, step: Int, verb: String) {
        lock.lock()
        defer { lock.unlock() }
        return (beat, stepIndex, stepVerb)
    }
}

@MainActor
final class DriverSession {

    let state: AppState
    let scenarioPath: String
    var scenario: [String: Any] = [:]
    let outDir: URL
    let shotsDir: URL

    var window: NSWindow?
    var input: DriverInput?
    let heartbeat = DriverHeartbeat()

    var frames: [DriverFrame] = []
    var samples: [DriverSample] = []
    var hitches: [(t: Double, ms: Double)] = []
    var commits: [Double] = []
    var uncommittedFrames = 0

    var stepResults: [[String: Any]] = []
    var shotRows: [[String: Any]] = []
    var values: [String: Any] = [:]
    var keptShots: [String: CGImage] = [:]
    var keptOrder: [String] = []
    var expectFailures = 0
    var expectPasses = 0
    var errors = 0
    var setupError: String?
    var captureMethod: DriverCapture.Method = .windowList
    var defaultVia: String = "auto"
    var hidWorks: Bool?
    var startedAt = DriverClock.now()
    lazy var machine: [String: Any] = DriverMachine.facts()
    var displayNote = ""

    init(state: AppState, scenarioPath: String) {
        self.state = state
        self.scenarioPath = scenarioPath
        let environment = ProcessInfo.processInfo.environment
        let out = environment["LUMEN_DRIVER_OUT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("lumen-driver-out").path
        outDir = URL(fileURLWithPath: out, isDirectory: true)
        shotsDir = outDir.appendingPathComponent("shots", isDirectory: true)
    }

    // MARK: Timing

    func sleep(_ seconds: Double) async {
        guard seconds > 0 else {
            await Task.yield()
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    /// Polls `condition` every 20 ms. False when `timeout` passes first.
    func wait(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = DriverClock.now() + timeout
        while !condition() {
            if DriverClock.now() >= deadline { return false }
            await sleep(0.02)
        }
        return true
    }

    // MARK: Run

    func run() async {
        try? FileManager.default.createDirectory(at: shotsDir,
                                                 withIntermediateDirectories: true)
        DriverTimeline.shared.openLog(at: outDir.appendingPathComponent("timeline.jsonl"))
        startedAt = DriverClock.now()

        guard let data = FileManager.default.contents(atPath: scenarioPath),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            setupError = "cannot read scenario at \(scenarioPath)"
            finish()
            return
        }
        scenario = parsed
        defaultVia = parsed["via"] as? String ?? "auto"
        if let name = parsed["capture"] as? String,
           let method = DriverCapture.Method(rawValue: name) {
            captureMethod = method
        }

        startWatchdog()
        installRunLoopObserver()

        do {
            try await setUpWindow()
            try await openFixture()
        } catch let error as DriverError {
            setupError = error.message
            finish()
            return
        } catch {
            setupError = String(describing: error)
            finish()
            return
        }

        let steps = (parsed["steps"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        for (index, raw) in steps.enumerated() {
            let step = DriverStep(raw: raw, index: index)
            heartbeat.enterStep(index, verb: step.verb)
            let began = DriverClock.now()
            DriverTimeline.shared.add("step", ["i": index, "do": step.verb, "id": step.id])
            var row: [String: Any] = ["i": index, "do": step.verb, "id": step.id,
                                      "t0": began]
            if let note = step.string("note") { row["note"] = note }
            var stop = false
            do {
                let detail = try await perform(step)
                for (key, value) in detail { row[key] = value }
                if row["status"] == nil { row["status"] = "ok" }
            } catch let error as DriverError {
                row["status"] = "error"
                row["error"] = error.message
                errors += 1
                stop = step.bool("fatal") ?? false
            } catch {
                row["status"] = "error"
                row["error"] = String(describing: error)
                errors += 1
            }
            row["ms"] = (DriverClock.now() - began) * 1000
            DriverTimeline.shared.add("stepEnd", ["i": index,
                                                  "status": row["status"] ?? "ok"])
            stepResults.append(row)
            writeReport(status: "running")
            DriverTimeline.shared.flush()
            if stop { break }
        }
        finish()
    }

    private func setUpWindow() async throws {
        let found = await wait(timeout: 20) {
            NSApp.windows.contains { $0.isVisible && $0.contentView != nil }
        }
        guard found, let window = NSApp.windows.first(where: {
            $0.isVisible && $0.contentView != nil
        }) else {
            throw DriverError("no window appeared within 20 s")
        }
        self.window = window
        let size = scenario["window"] as? [String: Any]
        let width = (size?["width"] as? NSNumber)?.doubleValue ?? 1440
        let height = (size?["height"] as? NSNumber)?.doubleValue ?? 900
        // Room for the menu bar above the window.
        displayNote = DriverDisplay.ensure(width: Int(width), height: Int(height) + 40)
        await sleep(displayNote.hasPrefix("switched") ? 1.5 : 0)
        let screen = NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        // Bottom-left on the display's origin: window and screen coordinates then
        // coincide, which is what an in-process event with no window attached needs.
        let fitted = Swift.min(CGFloat(height), visible.maxY)
        let frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: fitted)
        window.setFrame(frame, display: true)
        window.acceptsMouseMovedEvents = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let input = DriverInput(window: window)
        input.refreshGeometry()
        input.calibrateWindowFields()
        input.startMonitor()
        input.onReceive = { [weak self] event in
            self?.received(event)
        }
        self.input = input
        await sleep(0.5)
        input.refreshGeometry()
        hidWorks = await probeHID(input)
        DriverTimeline.shared.add("setup", [
            "window": DriverJSON.rect(window.frame), "active": NSApp.isActive,
            "key": window.isKeyWindow, "hid": hidWorks ?? false, "display": displayNote,
        ])
    }

    /// Posts one HID mouse move and reports whether this process received it.
    private func probeHID(_ input: DriverInput) async -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        let before = input.receivedCount("mouseMoved")
        let previous = input.via
        input.via = .hid
        let centre = CGPoint(x: input.geometry.frame.width / 2,
                             y: input.geometry.frame.height / 2)
        input.move(to: CGPoint(x: centre.x - 3, y: centre.y))
        await sleep(0.05)
        input.move(to: centre)
        let arrived = await wait(timeout: 1.0) {
            input.receivedCount("mouseMoved") > before
        }
        input.via = previous
        return arrived
    }

    private func openFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = (scenario["folder"] as? String)
                ?? environment["LUMEN_DRIVER_PHOTOS"], !folder.isEmpty else {
            return
        }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DriverError("fixture folder \(folder) does not exist")
        }
        state.openFolder(url)
        let scanned = await wait(timeout: 60) {
            !self.state.isScanning && !self.state.allPhotos.isEmpty
        }
        guard scanned else {
            throw DriverError("no photos appeared from \(folder) within 60 s "
                                  + "(status: \(state.statusMessage ?? "none"))")
        }
        await sleep(0.3)
    }

    // MARK: Hooks

    func noteFrame(_ result: RenderResult, recipe: Recipe, model: AnyObject) {
        let frame = DriverFrame(
            t: DriverClock.now(), recipe: recipe, isDraft: result.isDraft,
            width: result.image.width, height: result.image.height,
            generation: result.generation, embedded: result.usedEmbeddedPreview,
            region: result.regionUnit != nil, nativeLongEdge: result.nativeLongEdge,
            model: ObjectIdentifier(model).hashValue & 0xFFFF)
        frames.append(frame)
        uncommittedFrames += 1
        DriverTimeline.shared.add("frame", [
            "f": frames.count - 1, "draft": frame.isDraft, "w": frame.width,
            "h": frame.height, "gen": Int(truncatingIfNeeded: frame.generation),
            "embedded": frame.embedded, "region": frame.region, "model": frame.model,
        ], at: frame.t)
    }

    /// Samples the recipe once the event that just arrived has been handled.
    private func received(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .keyDown:
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.samples.append(DriverSample(t: DriverClock.now(),
                                                 recipe: self.state.currentRecipe))
            }
        default:
            break
        }
    }

    private var runLoopWokeAt = DriverClock.now()

    /// After Core Animation's own commit observer (order 2 000 000), so `commit` rows
    /// mark frames that have left for the render server.
    private func installRunLoopObserver() {
        let activities = CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities, true, 2_500_000
        ) { [weak self] _, activity in
            MainActor.assumeIsolated {
                self?.runLoopTick(activity)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private func runLoopTick(_ activity: CFRunLoopActivity) {
        let now = DriverClock.now()
        heartbeat.touch()
        if activity == .afterWaiting {
            runLoopWokeAt = now
            return
        }
        let busy = (now - runLoopWokeAt) * 1000
        if busy > 25 {
            hitches.append((t: now, ms: busy))
            DriverTimeline.shared.add("hitch", ["ms": busy], at: now)
        }
        if uncommittedFrames > 0 {
            commits.append(now)
            DriverTimeline.shared.add("commit", ["frames": uncommittedFrames], at: now)
            uncommittedFrames = 0
        }
    }

    // MARK: Watchdog

    /// A scenario may not outlive `timeoutSeconds`, and the main thread may not stall
    /// longer than `hangSeconds`. Either writes what is known and exits.
    private func startWatchdog() {
        let timeout = (scenario["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 300
        let hang = (scenario["hangSeconds"] as? NSNumber)?.doubleValue ?? 30
        let deadline = DriverClock.now() + timeout
        let heartbeat = self.heartbeat
        let out = outDir
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                let now = DriverClock.now()
                let state = heartbeat.read()
                let stalled = now - state.beat
                let reason: String
                let code: Int32
                if stalled > hang {
                    reason = "hang"
                    code = 3
                } else if now > deadline {
                    reason = "timeout"
                    code = 4
                } else {
                    continue
                }
                DriverTimeline.shared.add("watchdog", ["reason": reason,
                                                       "stalledSeconds": stalled,
                                                       "step": state.step])
                DriverTimeline.shared.flush()
                let verdict: [String: Any] = [
                    "reason": reason, "stalledSeconds": stalled, "step": state.step,
                    "do": state.verb, "limitSeconds": reason == "hang" ? hang : timeout,
                ]
                DriverJSON.write(verdict, to: out.appendingPathComponent("watchdog.json"))
                let sample = Process()
                sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sample.arguments = [String(ProcessInfo.processInfo.processIdentifier),
                                    "2", "-file",
                                    out.appendingPathComponent("watchdog-sample.txt").path]
                if (try? sample.run()) != nil { sample.waitUntilExit() }
                exit(code)
            }
        }
        thread.name = "lumen.driver.watchdog"
        thread.start()
    }

    // MARK: Report

    func writeReport(status: String) {
        var report: [String: Any] = [
            "name": scenario["name"] as? String
                ?? URL(fileURLWithPath: scenarioPath).deletingPathExtension().lastPathComponent,
            "description": scenario["description"] as? String ?? "",
            "status": status,
            "seconds": DriverClock.now() - startedAt,
            "expect": ["pass": expectPasses, "fail": expectFailures] as [String: Any],
            "errors": errors,
            "steps": stepResults,
            "values": values,
            "shots": shotRows,
            "frames": frames.count,
            "input": ["default": defaultVia, "hidWorks": hidWorks ?? false,
                      "windowFields": input?.windowFields ?? []] as [String: Any],
            "window": DriverJSON.rect(window?.frame ?? .zero),
            "display": displayNote,
            "capture": captureMethod.rawValue,
            "machine": machine,
            "build": Bundle.main.object(forInfoDictionaryKey: "LumenBuildCommit")
                as? String ?? "unknown",
        ]
        if let setupError { report["setupError"] = setupError }
        DriverJSON.write(report, to: outDir.appendingPathComponent("report.json"))
    }

    /// 0 every expectation held · 1 an expectation failed · 2 the driver could not do
    /// what the scenario asked · 3 hang · 4 timeout (the last two from the watchdog).
    private func finish() {
        let status: String
        let code: Int32
        if setupError != nil || errors > 0 {
            status = "error"
            code = 2
        } else if expectFailures > 0 {
            status = "fail"
            code = 1
        } else {
            status = "pass"
            code = 0
        }
        DriverJSON.write(snapshot(), to: outDir.appendingPathComponent("state-final.json"))
        writeReport(status: status)
        DriverTimeline.shared.add("end", ["status": status])
        DriverTimeline.shared.flush()
        DriverCapture.drain()
        input?.setModifiers([])
        state.prepareToQuit()
        exit(code)
    }
}

#endif

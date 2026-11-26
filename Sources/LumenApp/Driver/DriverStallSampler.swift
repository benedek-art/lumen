// DriverStallSampler.swift
// Where a long main-thread turn was spent: once a run-loop turn has been busy longer
// than `thresholdMs`, a background thread suspends the main thread every `intervalMs`,
// walks its frame pointers and resumes it. Each stall's stacks go to `stalls.json`
// and a `stall` row to the timeline. See driver/README.md.

#if os(macOS)

import Foundation
import Darwin
import MachO

final class DriverStallSampler: @unchecked Sendable {

    private struct Stall {
        let serial: UInt64
        let start: Double
        var firstSample: Double
        var lastSample: Double
        var stacks: [[UInt]: Int] = [:]
        var samples = 0
    }

    private let lock = NSLock()
    private var turnStart: Double?
    private var turnSerial: UInt64 = 0

    private let mainThread: thread_act_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private let threshold: Double
    private let interval: Double
    private let out: URL
    // Filled while the main thread is suspended, so nothing there may allocate.
    private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: 160)
    private let capacity = 160

    private var current: Stall?
    private var finished: [[String: Any]] = []
    private var symbols: [UInt: String] = [:]
    private var appAddresses: Set<UInt> = []
    private var symbolNames: [String] = []
    private var symbolIndex: [String: Int] = [:]
    private static let mainHeader = UnsafeRawPointer(_dyld_get_image_header(0))
    private var stopped = false

    /// Call on the main thread.
    init(out: URL, thresholdMs: Double, intervalMs: Double) {
        mainThread = mach_thread_self()
        let me = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(me))
        stackHigh = top
        stackLow = top &- UInt(pthread_get_stacksize_np(me))
        threshold = thresholdMs / 1000
        interval = intervalMs / 1000
        self.out = out
    }

    func turnBegan(at time: Double) {
        lock.lock()
        turnStart = time
        turnSerial &+= 1
        lock.unlock()
    }

    func turnEnded() {
        lock.lock()
        turnStart = nil
        lock.unlock()
    }

    func start() {
        let thread = Thread { [self] in self.loop() }
        thread.name = "lumen.driver.stalls"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Writes what is held. Call from the main thread at the end of the run.
    func finish() {
        lock.lock()
        stopped = true
        lock.unlock()
        Thread.sleep(forTimeInterval: interval * 3)
        lock.lock()
        if let stall = current { close(stall) }
        current = nil
        let rows = finished
        let published = publishRows()
        let pending = appAddresses.sorted()
        let names = symbolNames
        lock.unlock()
        write(rows, symbols: names, publishes: published, resolving: Self.atos(pending))
    }

    // MARK: Publishes

    private var publishes: [String: [[UInt]: Int]] = [:]

    /// An `objectWillChange` of `name`, with the stack that sent it. Main thread.
    func notePublish(_ name: String, duringDrag: Bool) {
        var stack: [UInt] = []
        for (i, address) in Thread.callStackReturnAddresses.enumerated() where i >= 2 {
            if stack.count == 28 { break }
            stack.append(Self.strip(address.uintValue) &- 1)
        }
        let key = duringDrag ? name + " (drag)" : name
        lock.lock()
        publishes[key, default: [:]][stack, default: 0] += 1
        lock.unlock()
        DriverTimeline.shared.add("pub", ["o": name])
    }

    /// Called with `lock` held.
    private func publishRows() -> [[String: Any]] {
        publishes.map { name, stacks -> [String: Any] in
            [
                "o": name, "n": stacks.values.reduce(0, +),
                "stacks": stacks.sorted { $0.value > $1.value }.prefix(12).map {
                    [$0.value, $0.key.map { index(of: symbol($0)) }] as [Any]
                },
            ]
        }.sorted { ($0["n"] as? Int ?? 0) > ($1["n"] as? Int ?? 0) }
    }

    /// The app's own symbols are not exported, so `dladdr` names the nearest public
    /// one; `atos` reads the symbol table.
    private static func atos(_ addresses: [UInt]) -> [String: String] {
        guard !addresses.isEmpty, let executable = Bundle.main.executablePath,
              let header = _dyld_get_image_header(0) else { return [:] }
        let base = UInt(bitPattern: header)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
        process.arguments = ["-o", executable, "-l", String(format: "0x%lx", base)]
            + addresses.map { String(format: "0x%lx", $0) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        var out: [String: String] = [:]
        for (address, line) in zip(addresses, lines) {
            out[placeholder(address)] = "Lumen`" + String(line.prefix(400))
        }
        return out
    }

    private static func placeholder(_ address: UInt) -> String {
        String(format: "Lumen@0x%lx", address)
    }

    private func loop() {
        while true {
            Thread.sleep(forTimeInterval: interval)
            let now = DriverClock.now()
            lock.lock()
            if stopped {
                lock.unlock()
                return
            }
            let start = turnStart
            let serial = turnSerial
            if let open = current, open.serial != serial || start == nil {
                close(open)
                current = nil
            }
            guard let start, now - start > threshold else {
                lock.unlock()
                continue
            }
            lock.unlock()
            let depth = sampleMain()
            guard depth > 0 else { continue }
            let stack = Array(UnsafeBufferPointer(start: buffer, count: depth))
            lock.lock()
            if current == nil {
                current = Stall(serial: serial, start: start, firstSample: now,
                                lastSample: now)
            }
            current?.stacks[stack, default: 0] += 1
            current?.samples += 1
            current?.lastSample = now
            lock.unlock()
        }
    }

    /// Suspends the main thread, copies its pc and frame-pointer chain into `buffer`,
    /// resumes it. Returns the depth.
    private func sampleMain() -> Int {
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return 0 }
        var depth = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, thread_state_flavor_t(ARM_THREAD_STATE64),
                                 $0, &count)
            }
        }
        if read == KERN_SUCCESS {
            buffer[0] = Self.strip(UInt(state.__pc))
            depth = 1
            depth = walk(from: UInt(state.__fp), depth: depth)
        }
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let read = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, thread_state_flavor_t(x86_THREAD_STATE64),
                                 $0, &count)
            }
        }
        if read == KERN_SUCCESS {
            buffer[0] = UInt(state.__rip)
            depth = 1
            depth = walk(from: UInt(state.__rbp), depth: depth)
        }
        #endif
        thread_resume(mainThread)
        return depth
    }

    private func walk(from framePointer: UInt, depth start: Int) -> Int {
        var depth = start
        var fp = framePointer
        while depth < capacity, fp >= stackLow, fp &+ 16 <= stackHigh, fp & 7 == 0 {
            guard let frame = UnsafePointer<UInt>(bitPattern: fp) else { break }
            let next = frame[0]
            let ret = Self.strip(frame[1])
            if ret == 0 { break }
            // A return address points after the call; look up the call itself.
            buffer[depth] = ret &- 1
            depth += 1
            if next <= fp { break }
            fp = next
        }
        return depth
    }

    /// Clears pointer-authentication bits above the 47-bit user address space.
    private static func strip(_ address: UInt) -> UInt {
        address & 0x0000_7FFF_FFFF_FFFF
    }

    // MARK: Output

    /// Called with `lock` held.
    private func close(_ stall: Stall) {
        let busyMs = (stall.lastSample - stall.start) * 1000
        let ranked = stall.stacks.sorted { $0.value > $1.value }
        var inclusive: [String: Int] = [:]
        var leaves: [String: Int] = [:]
        for (stack, hits) in stall.stacks {
            let names = stack.map(symbol)
            if let leaf = names.first { leaves[leaf, default: 0] += hits }
            for name in Set(names) { inclusive[name, default: 0] += hits }
        }
        let top = { (table: [String: Int], n: Int) -> [[String: Any]] in
            table.sorted { $0.value > $1.value }.prefix(n).map {
                ["n": $0.value, "f": $0.key] as [String: Any]
            }
        }
        let row: [String: Any] = [
            "t": stall.start, "busyMsAtLastSample": busyMs, "samples": stall.samples,
            "leaves": top(leaves, 15),
            "inclusive": top(inclusive, 60),
            "stacks": ranked.prefix(8).map { entry -> [String: Any] in
                ["n": entry.value, "frames": entry.key.prefix(80).map(symbol)]
            },
            // Every stack, as indices into the file's `symbols`.
            "all": ranked.map { entry -> [Any] in
                [entry.value, entry.key.prefix(120).map { index(of: symbol($0)) }]
            },
        ]
        finished.append(row)
        let firstLeaf = top(leaves, 1).first?["f"] as? String ?? ""
        DriverTimeline.shared.add("stall", ["start": stall.start, "ms": busyMs,
                                            "samples": stall.samples, "leaf": firstLeaf],
                                  at: stall.lastSample)
        if finished.count % 4 == 1 {
            let rows = finished
            let names = symbolNames
            DispatchQueue.global(qos: .utility).async { [self] in
                self.write(rows, symbols: names)
            }
        }
    }

    /// Called with `lock` held.
    private func index(of name: String) -> Int {
        if let known = symbolIndex[name] { return known }
        symbolIndex[name] = symbolNames.count
        symbolNames.append(name)
        return symbolNames.count - 1
    }

    private func write(_ rows: [[String: Any]], symbols table: [String],
                       publishes: [[String: Any]] = [],
                       resolving names: [String: String] = [:]) {
        var resolved = rows
        let symbolTable = table.map { names[$0] ?? $0 }
        if !names.isEmpty {
            func swap(_ value: Any) -> Any {
                if let text = value as? String { return names[text] ?? text }
                if let list = value as? [Any] { return list.map(swap) }
                if let table = value as? [String: Any] { return table.mapValues(swap) }
                return value
            }
            resolved = rows.map { row in row.mapValues(swap) }
        }
        DriverJSON.write(["stalls": resolved, "symbols": symbolTable, "publishes": publishes,
                          "thresholdMs": threshold * 1000, "intervalMs": interval * 1000],
                         to: out.appendingPathComponent("stalls.json"))
    }

    /// Called with `lock` held.
    private func symbol(_ address: UInt) -> String {
        if let known = symbols[address] { return known }
        var info = Dl_info()
        var name = String(format: "0x%lx", address)
        if let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0,
           info.dli_fbase == UnsafeMutableRawPointer(mutating: Self.mainHeader) {
            name = Self.placeholder(address)
            appAddresses.insert(address)
        } else if let pointer = UnsafeRawPointer(bitPattern: address),
                  dladdr(pointer, &info) != 0 {
            let image = info.dli_fname.map {
                URL(fileURLWithPath: String(cString: $0)).lastPathComponent
            } ?? "?"
            if let raw = info.dli_sname {
                let mangled = String(cString: raw)
                let offset = address &- UInt(bitPattern: info.dli_saddr)
                name = "\(image)`\(Self.demangle(mangled)) +\(offset)"
            } else {
                let offset = address &- UInt(bitPattern: info.dli_fbase)
                name = "\(image) +0x\(String(offset, radix: 16))"
            }
        }
        if name.count > 400 { name = String(name.prefix(400)) + "…" }
        symbols[address] = name
        return name
    }

    private typealias Demangler = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
        UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    private static let demangler: Demangler? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let found = dlsym(handle, "swift_demangle") else { return nil }
        return unsafeBitCast(found, to: Demangler.self)
    }()

    private static func demangle(_ name: String) -> String {
        guard let demangler, name.hasPrefix("$s") || name.hasPrefix("_$s") else {
            return name
        }
        let trimmed = name.hasPrefix("_") ? String(name.dropFirst()) : name
        return trimmed.withCString { pointer in
            guard let result = demangler(pointer, strlen(pointer), nil, nil, 0) else {
                return name
            }
            defer { free(result) }
            return String(cString: result)
        }
    }
}

#endif

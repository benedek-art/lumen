// DriverTimeline.swift
// Monotonic clock, JSON helpers and the JSONL event log. See driver/README.md.

#if os(macOS)

import Foundation
import CoreGraphics

enum DriverClock {
    /// Mach uptime at process start of the driver; every `t` in the outputs is seconds
    /// since this.
    static let zero: UInt64 = DispatchTime.now().uptimeNanoseconds

    static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- zero) / 1e9
    }

    /// Converts an `NSEvent.timestamp` (system uptime seconds) to driver time.
    static func fromUptime(_ seconds: Double) -> Double {
        seconds - Double(zero) / 1e9
    }
}

enum DriverJSON {

    /// Makes a value safe for `JSONSerialization`: no NaN, no CG types.
    static func clean(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if let d = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in d { out[k] = clean(v) }
            return out
        }
        if let a = value as? [Any] { return a.map { clean($0) } }
        if let s = value as? String { return s }
        if value is NSNull { return NSNull() }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            let d = n.doubleValue
            guard d.isFinite else { return NSNull() }
            if d == d.rounded(), abs(d) < 1e15 { return n }
            return (d * 100_000).rounded() / 100_000
        }
        return String(describing: value)
    }

    static func data(_ value: Any, pretty: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        let cleaned = clean(value)
        guard JSONSerialization.isValidJSONObject(cleaned),
              let data = try? JSONSerialization.data(withJSONObject: cleaned, options: options)
        else { return Data("{}".utf8) }
        return data
    }

    static func write(_ value: Any, to url: URL) {
        try? data(value, pretty: true).write(to: url, options: .atomic)
    }

    static func rect(_ r: CGRect) -> [String: Any] {
        ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)]
    }

    static func point(_ p: CGPoint) -> [String: Any] {
        ["x": Double(p.x), "y": Double(p.y)]
    }

    /// Flattens nested objects to dotted keys; arrays become `key.0`, `key.1`, plus
    /// `key.count`.
    static func flatten(_ value: Any, prefix: String = "", into out: inout [String: Any]) {
        if let d = value as? [String: Any] {
            for (k, v) in d {
                flatten(v, prefix: prefix.isEmpty ? k : prefix + "." + k, into: &out)
            }
        } else if let a = value as? [Any] {
            out[prefix + ".count"] = a.count
            for (i, v) in a.enumerated() {
                flatten(v, prefix: prefix + "." + String(i), into: &out)
            }
        } else {
            out[prefix] = value
        }
    }
}

/// Append-only event log. Any thread may append; `flush` rewrites nothing, it appends.
final class DriverTimeline {

    static let shared = DriverTimeline()
    private init() {}

    private let lock = NSLock()
    private var pending: [[String: Any]] = []
    private var handle: FileHandle?
    private(set) var count = 0

    func openLog(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    /// `kind` is the row's `k`. `t` defaults to now.
    func add(_ kind: String, _ fields: [String: Any] = [:], at time: Double? = nil) {
        var row = fields
        row["k"] = kind
        row["t"] = time ?? DriverClock.now()
        lock.lock()
        pending.append(row)
        count += 1
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let rows = pending
        pending.removeAll(keepingCapacity: true)
        let handle = self.handle
        lock.unlock()
        guard let handle, !rows.isEmpty else { return }
        var blob = Data()
        for row in rows {
            blob.append(DriverJSON.data(row))
            blob.append(0x0A)
        }
        handle.write(blob)
    }
}

#endif

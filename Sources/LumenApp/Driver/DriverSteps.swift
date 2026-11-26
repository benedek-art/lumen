// DriverSteps.swift
// The scenario verbs. Each returns the fields it adds to its row in report.json.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI

/// One synthesized event, due `at` seconds after its gesture starts.
struct DriverTick {
    let at: Double
    let fire: () -> Void
}

enum DriverPacer {

    /// How well a gesture kept to its schedule: lateness of each event when posted.
    struct PacerQuality {
        var worstLateMs = 0.0
        var meanLateMs = 0.0
        var worstPostMs = 0.0
    }

    /// Asks the scheduler to treat this thread like an audio thread, so a 60 Hz event
    /// stream stays 60 Hz while the app's own threads are busy.
    private static func makeCurrentThreadPunctual() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerMs = 1_000_000.0 * Double(timebase.denom) / Double(Swift.max(timebase.numer, 1))
        var policy = thread_time_constraint_policy_data_t(
            period: UInt32(8 * ticksPerMs), computation: UInt32(1 * ticksPerMs),
            constraint: UInt32(4 * ticksPerMs), preemptible: 1)
        let count = mach_msg_type_number_t(
            MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<Int32>.size)
        _ = withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: Int32.self, capacity: Int(count)) { raw in
                thread_policy_set(mach_thread_self(),
                                  thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), raw, count)
            }
        }
    }

    /// Fires the ticks on their own thread, on schedule whatever the main thread is
    /// doing, the way a real device keeps reporting while the app is busy.
    static func run(_ ticks: [DriverTick]) async -> PacerQuality {
        await withCheckedContinuation { (continuation: CheckedContinuation<PacerQuality, Never>) in
            let thread = Thread {
                makeCurrentThreadPunctual()
                var quality = PacerQuality()
                var lateTotal = 0.0
                var fired = 0
                // Ticks due at zero go first and the clock starts after them: the first
                // post on a thread can take a while and must not bunch what follows.
                for tick in ticks where tick.at <= 0 { tick.fire() }
                let start = DispatchTime.now().uptimeNanoseconds
                var previousDue = 0.0
                var lastFired = start
                for tick in ticks where tick.at > 0 {
                    // The schedule is absolute, so a late event is followed sooner and
                    // the gesture keeps its length; but never closer than half the
                    // intended gap (20 ms at most), so a click's press and release
                    // cannot collapse into one instant.
                    let floorGap = UInt64(Swift.min((tick.at - previousDue) * 0.5, 0.02) * 1e9)
                    let scheduled = start &+ UInt64(tick.at * 1e9)
                    let due = Swift.max(scheduled, lastFired &+ floorGap)
                    var now = DispatchTime.now().uptimeNanoseconds
                    if due > now {
                        usleep(useconds_t(Swift.min((due - now) / 1000, 10_000_000)))
                        now = DispatchTime.now().uptimeNanoseconds
                    }
                    let late = now > scheduled ? Double(now - scheduled) / 1e6 : 0
                    tick.fire()
                    previousDue = tick.at
                    lastFired = DispatchTime.now().uptimeNanoseconds
                    quality.worstLateMs = Swift.max(quality.worstLateMs, late)
                    quality.worstPostMs = Swift.max(quality.worstPostMs,
                                                    Double(lastFired - now) / 1e6)
                    lateTotal += late
                    fired += 1
                }
                quality.meanLateMs = fired > 0 ? lateTotal / Double(fired) : 0
                continuation.resume(returning: quality)
            }
            thread.name = "lumen.driver.pacer"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }
}

extension DriverSession {

    // MARK: Targets

    /// A step's target as a rectangle in window-frame points (origin top-left).
    func resolveFrame(_ target: Any?) throws -> CGRect {
        guard let input, let window else { throw DriverError("no window") }
        if target == nil || target is NSNull {
            return CGRect(origin: input.cursor, size: .zero)
        }
        if let name = target as? String {
            if name == "window" {
                return CGRect(origin: .zero, size: window.frame.size)
            }
            if name == "cursor" {
                return CGRect(origin: input.cursor, size: .zero)
            }
            return try anchorFrame(id: name, index: 0, within: nil)
        }
        guard let spec = target as? [String: Any] else {
            throw DriverError("target must be a string or an object")
        }
        if let point = spec["point"] as? [Any], point.count == 2,
           let x = (point[0] as? NSNumber)?.doubleValue,
           let y = (point[1] as? NSNumber)?.doubleValue {
            return CGRect(x: x, y: y, width: 0, height: 0)
        }
        if let id = spec["anchor"] as? String {
            return try anchorFrame(id: id,
                                   index: (spec["index"] as? NSNumber)?.intValue ?? 0,
                                   within: spec["within"] as? String)
        }
        if let label = spec["ax"] as? String {
            let matches = DriverAccessibility.find(label: label,
                                                   role: spec["role"] as? String,
                                                   in: window)
            let index = (spec["index"] as? NSNumber)?.intValue ?? 0
            guard index < matches.count else {
                throw DriverError("no accessibility element labelled \"\(label)\" "
                                      + "(found \(matches.count))")
            }
            return input.windowFrameRect(fromScreen: matches[index].frame)
        }
        if let wanted = spec["text"] as? String {
            // What a person would do: find the words on screen.
            let lowered = wanted.lowercased()
            let seen = screenTexts()
            var hits = seen.filter { ($0["text"] as? String)?.lowercased() == lowered }
            if hits.isEmpty {
                hits = seen.filter {
                    ($0["text"] as? String)?.lowercased().contains(lowered) ?? false
                }
            }
            var frames: [CGRect] = hits.compactMap { row in
                guard let x = row["x"] as? Double, let y = row["y"] as? Double,
                      let w = row["w"] as? Double, let h = row["h"] as? Double else { return nil }
                return CGRect(x: x, y: y, width: w, height: h)
            }
            if let within = spec["within"] as? String {
                let container = try anchorFrame(id: within, index: 0, within: nil)
                frames = frames.filter { container.insetBy(dx: -2, dy: -2).contains($0) }
            }
            let index = (spec["index"] as? NSNumber)?.intValue ?? 0
            guard index < frames.count else {
                throw DriverError("the text \"\(wanted)\" is not on screen "
                                      + "(found \(frames.count))")
            }
            return frames[index]
        }
        throw DriverError("target needs one of: anchor, text, point")
    }

    private func anchorFrame(id: String, index: Int, within: String?) throws -> CGRect {
        guard let input else { throw DriverError("no window") }
        var frames = DriverAnchors.shared.frames(id: id)
        if let within {
            guard let container = DriverAnchors.shared.frames(id: within).first else {
                throw DriverError("no anchor \"\(within)\" on screen")
            }
            frames = frames.filter { container.insetBy(dx: -1, dy: -1).contains($0) }
        }
        guard index < frames.count else {
            let known = DriverAnchors.shared.all().map { $0.id }
            let unique = Array(Set(known)).sorted().joined(separator: ", ")
            throw DriverError("no anchor \"\(id)\" index \(index) on screen "
                                  + "(\(frames.count) found). On screen: \(unique)")
        }
        return input.windowFrameRect(fromGlobal: frames[index])
    }

    /// `at` is a fraction of the target frame (default its centre); `offset` is points.
    func resolvePoint(_ step: DriverStep, target: String = "target", at: String = "at",
                      offset: String = "offset") async throws -> CGPoint {
        let frame = try await settledFrame(step.raw[target])
        let fraction = step.doubles(at) ?? [0.5, 0.5]
        let shift = step.doubles(offset) ?? [0, 0]
        guard fraction.count == 2, shift.count == 2 else {
            throw DriverError("\(at) and \(offset) take two numbers")
        }
        return CGPoint(x: frame.minX + frame.width * CGFloat(fraction[0]) + CGFloat(shift[0]),
                       y: frame.minY + frame.height * CGFloat(fraction[1]) + CGFloat(shift[1]))
    }

    /// Picks the backend for a step: its own `via`, else the scenario's, else `auto`:
    /// HID when this process can post and receive HID events and every point the step
    /// touches is on the display, in-process otherwise.
    func backend(for step: DriverStep, points: [CGPoint]) -> DriverInput.Via {
        switch step.string("via") ?? defaultVia {
        case "hid": return .hid
        case "app": return .app
        default:
            guard hidWorks == true, let input else { return .app }
            return points.allSatisfy { input.isOnScreen($0) } ? .hid : .app
        }
    }

    // MARK: Dispatch

    func perform(_ step: DriverStep) async throws -> [String: Any] {
        input?.refreshGeometry()
        switch step.verb {
        case "open": return try await open(step)
        case "direct": return try await direct(step)
        case "wait":
            await sleep(step.double("seconds") ?? 0.5)
            return [:]
        case "waitSettled": return await waitSettled(step)
        case "waitFor": return await waitFor(step)
        case "expect": return expect(step)
        case "shot": return try await shot(step)
        case "compare": return try compare(step)
        case "state": return dumpState(step)
        case "mark":
            DriverTimeline.shared.add("mark", ["name": step.string("name") ?? step.id])
            return [:]
        case "probe": return await probe(step)
        case "menu": return try await menu(step)
        case "scrollTo": return try await scrollTo(step)
        case "move", "click", "drag", "scroll", "swipe", "pinch", "smartMagnify", "key",
             "type", "modifiers":
            return try await gesture(step)
        default:
            throw DriverError("unknown verb \"\(step.verb)\"")
        }
    }

    // MARK: Setup verbs (direct)

    /// Selects a photo and enters a workspace by calling the app, not by clicking.
    private func open(_ step: DriverStep) async throws -> [String: Any] {
        let photos = state.photos
        var chosen: PhotoItem?
        if let name = step.string("photo") {
            chosen = photos.first { $0.id.lastPathComponent == name }
                ?? photos.first { $0.id.lastPathComponent.contains(name) }
            guard chosen != nil else {
                let names = photos.map { $0.id.lastPathComponent }.joined(separator: ", ")
                throw DriverError("no photo matching \"\(name)\" in: \(names)")
            }
        } else if let index = step.int("index") {
            guard index >= 0, index < photos.count else {
                throw DriverError("photo index \(index) out of range 0..<\(photos.count)")
            }
            chosen = photos[index]
        } else {
            chosen = photos.first
        }
        guard let photo = chosen else { throw DriverError("the folder has no photos") }
        state.select(photo)
        let workspaceName = step.string("workspace") ?? "develop"
        guard let workspace = Workspace(rawValue: workspaceName) else {
            throw DriverError("unknown workspace \"\(workspaceName)\"")
        }
        state.enter(workspace)
        if step.bool("masking") == true { state.enterMasking() }
        LoupeViewport.shared.fit()
        await sleep(0.2)
        var out = await waitSettled(step)
        out["via"] = "direct"
        out["photo"] = photo.id.lastPathComponent
        return out
    }

    /// App verbs called directly. Second tier: every use is marked `via: direct`.
    private func direct(_ step: DriverStep) async throws -> [String: Any] {
        guard let call = step.string("call") else {
            throw DriverError("direct needs a call")
        }
        let viewport = LoupeViewport.shared
        switch call {
        case "enterMasking": state.enterMasking()
        case "toggleMasking": state.toggleMasking()
        case "fit": viewport.fit()
        case "oneToOne": viewport.setZoom(LoupeZoom.oneToOne, at: nil)
        case "setZoom": viewport.setZoom(step.double("value") ?? 1, at: nil)
        case "showLoupe": state.showLoupe()
        case "showGrid": state.showGrid()
        case "resetRecipe": state.updateRecipe(coalescingKey: nil) { $0 = Recipe() }
        case "undo": state.undo()
        case "selectNext": state.selectNext()
        case "selectPrevious": state.selectPrevious()
        case "showLatencyHUD": state.showLatencyHUD = step.bool("value") ?? true
        default: throw DriverError("unknown direct call \"\(call)\"")
        }
        await sleep(0.05)
        return ["via": "direct"]
    }

    /// Scrolls a container (default the develop column) with wheel events until the
    /// target sits in its upper half.
    private func scrollTo(_ step: DriverStep) async throws -> [String: Any] {
        guard let input else { throw DriverError("no window") }
        let containerID = step.string("in") ?? "develop.column"
        var previous: CGRect?
        var stuck = 0
        for attempt in 0..<60 {
            input.refreshGeometry()
            let container = try resolveFrame(containerID)
            let target = try? resolveFrame(step.raw["target"])
            let aim = container.minY + container.height * 0.4
            var distance = 300.0
            if let target {
                distance = Double(target.midY - aim)
                let inView = target.midY > container.minY + 30
                    && target.midY < container.minY + container.height * 0.7
                if inView || (stuck >= 2 && container.contains(CGPoint(x: target.midX,
                                                                        y: target.midY))) {
                    await sleep(0.2)
                    return ["scrolls": attempt, "frame": DriverJSON.rect(target)]
                }
                stuck = target == previous ? stuck + 1 : 0
                if stuck >= 4 { break }
                previous = target
            }
            let centre = CGPoint(x: container.midX, y: container.midY)
            input.via = backend(for: step, points: [centre])
            // A wheel line moves a scroll view a few points; ask for the distance in
            // lines and look again.
            let lines = Swift.max(-12, Swift.min(12, (-distance / 12).rounded()))
            input.move(to: centre)
            input.scroll(dx: 0, dy: lines == 0 ? (distance > 0 ? -1 : 1) : lines,
                         precise: false, phase: 0, momentum: 0, at: centre)
            await sleep(0.25)
        }
        throw DriverError("could not scroll the target into view in \(containerID)")
    }

    /// A target's frame once it has stopped moving: panels animate in, and a frame read
    /// mid-animation is somewhere the control no longer is.
    func settledFrame(_ target: Any?) async throws -> CGRect {
        var frame = try resolveFrame(target)
        // Only named views move; a point is a point, and OCR is too slow to repeat.
        let spec = target as? [String: Any]
        let named = target is String || spec?["anchor"] != nil
        guard named, (target as? String) != "cursor" else { return frame }
        for _ in 0..<25 {
            await sleep(0.06)
            let again = try resolveFrame(target)
            if abs(again.minX - frame.minX) < 0.5, abs(again.minY - frame.minY) < 0.5,
               abs(again.width - frame.width) < 0.5, abs(again.height - frame.height) < 0.5 {
                return again
            }
            frame = again
        }
        return frame
    }

    // MARK: Input verbs

    private func ease(_ x: Double, _ name: String) -> Double {
        name == "inout" ? x * x * (3 - 2 * x) : x
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ x: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * CGFloat(x), y: a.y + (b.y - a.y) * CGFloat(x))
    }

    private func gesture(_ step: DriverStep) async throws -> [String: Any] {
        guard let input else { throw DriverError("no window") }
        var touched: [CGPoint] = []
        let hz = Swift.max(step.double("hz") ?? 60, 1)
        let duration = Swift.max(step.double("duration") ?? 0, 0)
        let easing = step.string("ease") ?? "linear"
        var ticks: [DriverTick] = []
        var endEvent = ""
        var out: [String: Any] = [:]

        let held = DriverInput.flags(step.strings("modifiers"))
        let holdsModifiers = step.has("modifiers") && step.verb != "modifiers"

        switch step.verb {
        case "modifiers":
            input.via = backend(for: step, points: [])
            input.setModifiers(DriverInput.flags(step.strings("hold")))
            await sleep(0.05)
            return ["via": input.via.rawValue]

        case "move":
            let from = input.cursor
            let to = try await resolvePoint(step)
            touched = [to]
            let count = Swift.max(Int((duration * hz).rounded()), 1)
            for k in 1...count {
                let x = ease(Double(k) / Double(count), easing)
                let p = lerp(from, to, x)
                ticks.append(DriverTick(at: Double(k - 1) / hz) { input.move(to: p) })
            }
            endEvent = "mouseMoved"
            out["to"] = DriverJSON.point(to)

        case "click":
            let p = try await resolvePoint(step)
            touched = [p]
            let count = Swift.max(step.int("count") ?? 1, 1)
            let right = step.string("button") == "right"
            let hold = step.double("hold") ?? 0.04
            let interval = step.double("interval") ?? 0.09
            ticks.append(DriverTick(at: 0) { input.move(to: p) })
            var t = 0.05
            for k in 1...count {
                ticks.append(DriverTick(at: t) { input.down(at: p, right: right, clickCount: k) })
                ticks.append(DriverTick(at: t + hold) {
                    input.up(at: p, right: right, clickCount: k)
                })
                t += hold + interval
            }
            endEvent = right ? "rightMouseUp" : "leftMouseUp"
            out["at"] = DriverJSON.point(p)

        case "drag":
            let frame = try await settledFrame(step.raw["target"])
            let fromFraction = step.doubles("from") ?? [0.5, 0.5]
            let toFraction = step.doubles("to") ?? [0.5, 0.5]
            guard fromFraction.count == 2, toFraction.count == 2 else {
                throw DriverError("drag from/to take two numbers")
            }
            func point(_ f: [Double]) -> CGPoint {
                CGPoint(x: frame.minX + frame.width * CGFloat(f[0]),
                        y: frame.minY + frame.height * CGFloat(f[1]))
            }
            var waypoints = [point(fromFraction)]
            if let path = step.raw["path"] as? [Any] {
                for item in path {
                    let f = (item as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                    guard f.count == 2 else { throw DriverError("path takes [x, y] pairs") }
                    waypoints.append(point(f))
                }
            }
            if step.has("toTarget") {
                waypoints.append(try await resolvePoint(step, target: "toTarget", at: "toAt",
                                                        offset: "toOffset"))
            } else {
                waypoints.append(point(toFraction))
            }
            let right = step.string("button") == "right"
            let settleBefore = step.double("pressHold") ?? 0.05
            let hold = step.double("hold") ?? 0.05
            let count = Swift.max(Int((duration * hz).rounded()), 1)
            let start = waypoints[0]
            let last = waypoints[waypoints.count - 1]
            touched = waypoints
            ticks.append(DriverTick(at: 0) { input.move(to: start) })
            ticks.append(DriverTick(at: 0.05) { input.down(at: start, right: right) })
            let segments = waypoints.count - 1
            for k in 1...count {
                let x = ease(Double(k) / Double(count), easing) * Double(segments)
                let segment = Swift.min(Int(x), segments - 1)
                let p = lerp(waypoints[segment], waypoints[segment + 1], x - Double(segment))
                ticks.append(DriverTick(at: 0.05 + settleBefore + Double(k - 1) / hz) {
                    input.drag(to: p, right: right)
                })
            }
            let released = 0.05 + settleBefore + Double(count - 1) / hz + hold
            ticks.append(DriverTick(at: released) { input.up(at: last, right: right) })
            endEvent = right ? "rightMouseUp" : "leftMouseUp"
            out["from"] = DriverJSON.point(start)
            out["to"] = DriverJSON.point(last)

        case "scroll":
            let p = try await resolvePoint(step)
            touched = [p]
            let lines = step.doubles("lines") ?? [0, step.double("dy") ?? 1]
            guard lines.count == 2 else { throw DriverError("lines takes [dx, dy]") }
            let count = Swift.max(step.int("count") ?? 1, 1)
            let interval = step.double("interval") ?? 0.05
            ticks.append(DriverTick(at: 0) { input.move(to: p) })
            for k in 0..<count {
                ticks.append(DriverTick(at: 0.05 + Double(k) * interval) {
                    input.scroll(dx: lines[0], dy: lines[1], precise: false, phase: 0,
                                 momentum: 0, at: p)
                })
            }
            endEvent = "scrollWheel"
            out["at"] = DriverJSON.point(p)

        case "swipe":
            // A two-finger trackpad scroll: began, changed…, ended, then momentum.
            let p = try await resolvePoint(step)
            touched = [p]
            let total = step.doubles("by") ?? [step.double("dx") ?? 0, step.double("dy") ?? 0]
            guard total.count == 2 else { throw DriverError("by takes [dx, dy]") }
            let count = Swift.max(Int((Swift.max(duration, 1 / hz) * hz).rounded()), 2)
            ticks.append(DriverTick(at: 0) { input.move(to: p) })
            var sentX = 0.0, sentY = 0.0
            for k in 1...count {
                let x = ease(Double(k) / Double(count), easing)
                let dx = (total[0] * x).rounded() - sentX
                let dy = (total[1] * x).rounded() - sentY
                sentX += dx
                sentY += dy
                let phase = k == 1 ? 1 : 2
                ticks.append(DriverTick(at: 0.05 + Double(k - 1) / hz) {
                    input.scroll(dx: dx, dy: dy, precise: true, phase: phase, momentum: 0,
                                 at: p)
                })
            }
            var t = 0.05 + Double(count) / hz
            ticks.append(DriverTick(at: t) {
                input.scroll(dx: 0, dy: 0, precise: true, phase: 4, momentum: 0, at: p)
            })
            if let momentum = step.raw["momentum"] as? [String: Any] {
                let extra = (momentum["by"] as? [Any])?
                    .compactMap { ($0 as? NSNumber)?.doubleValue } ?? [0, 0]
                let seconds = (momentum["duration"] as? NSNumber)?.doubleValue ?? 0.5
                guard extra.count == 2 else { throw DriverError("momentum.by takes [dx, dy]") }
                let steps = Swift.max(Int((seconds * hz).rounded()), 2)
                var mx = 0.0, my = 0.0
                for k in 1...steps {
                    // Ease-out: a flick decays.
                    let x = 1 - pow(1 - Double(k) / Double(steps), 2)
                    let dx = (extra[0] * x).rounded() - mx
                    let dy = (extra[1] * x).rounded() - my
                    mx += dx
                    my += dy
                    t += 1 / hz
                    let phase = k == 1 ? 1 : 2
                    ticks.append(DriverTick(at: t) {
                        input.scroll(dx: dx, dy: dy, precise: true, phase: 0,
                                     momentum: phase, at: p)
                    })
                }
                t += 1 / hz
                ticks.append(DriverTick(at: t) {
                    input.scroll(dx: 0, dy: 0, precise: true, phase: 0, momentum: 3, at: p)
                })
            }
            endEvent = "scrollWheel"
            out["at"] = DriverJSON.point(p)

        case "pinch":
            // `scale` is the whole gesture's factor. Each event's magnification d is the
            // same, chosen so the product of (1 + d) is `scale`: AppKit's convention,
            // where a handler multiplies its scale by 1 + magnification per event.
            let p = try await resolvePoint(step)
            touched = [p]
            var deltas = step.doubles("deltas") ?? []
            if deltas.isEmpty {
                let scale = step.double("scale") ?? 2
                let count = Swift.max(Int((Swift.max(duration, 1 / hz) * hz).rounded()), 1)
                let each = pow(Swift.max(scale, 0.01), 1 / Double(count)) - 1
                deltas = [Double](repeating: each, count: count)
            }
            ticks.append(DriverTick(at: 0) { input.move(to: p) })
            ticks.append(DriverTick(at: 0.05) { input.pinchEvent(0, phase: 1, at: p) })
            for (k, delta) in deltas.enumerated() {
                ticks.append(DriverTick(at: 0.05 + Double(k + 1) / hz) {
                    input.pinchEvent(delta, phase: 2, at: p)
                })
            }
            ticks.append(DriverTick(at: 0.05 + Double(deltas.count + 1) / hz) {
                input.pinchEvent(0, phase: 4, at: p)
            })
            endEvent = "magnify"
            out["at"] = DriverJSON.point(p)
            out["deltaSum"] = deltas.reduce(0, +)

        case "smartMagnify":
            let p = try await resolvePoint(step)
            touched = [p]
            ticks.append(DriverTick(at: 0) { input.move(to: p) })
            ticks.append(DriverTick(at: 0.05) { input.smartMagnifyEvent(at: p) })
            endEvent = "smartMagnify"
            out["at"] = DriverJSON.point(p)

        case "key":
            guard let name = step.string("key"), DriverInput.knowsKey(name) else {
                throw DriverError("key needs a known key name")
            }
            let count = Swift.max(step.int("count") ?? 1, 1)
            let interval = step.double("interval") ?? 0.08
            for k in 0..<count {
                ticks.append(DriverTick(at: Double(k) * interval) {
                    input.key(name, down: true)
                })
                ticks.append(DriverTick(at: Double(k) * interval + 0.03) {
                    input.key(name, down: false)
                })
            }
            endEvent = "keyUp"

        case "type":
            guard let text = step.string("text"), !text.isEmpty else {
                throw DriverError("type needs text")
            }
            let interval = step.double("interval") ?? 0.04
            for (k, character) in text.enumerated() {
                ticks.append(DriverTick(at: Double(k) * interval) {
                    input.typeCharacter(character)
                })
            }
            endEvent = "keyUp"

        default:
            throw DriverError("unknown gesture \(step.verb)")
        }

        let via = backend(for: step, points: touched)
        input.via = via
        out["via"] = via.rawValue
        let previousModifiers = input.modifiers
        if holdsModifiers {
            input.setModifiers(held)
            await sleep(0.03)
        }

        let framesBefore = frames.count
        let samplesBefore = samples.count
        let hitchesBefore = hitches.count
        let receivedBefore = endEvent.isEmpty ? 0 : input.receivedCount(endEvent)
        var film: DriverFilm?
        if let hz = step.double("film"), let window {
            let region = anchorRect(step.string("filmRegion") ?? "viewer")
                ?? CGRect(origin: .zero, size: window.frame.size)
            let started = DriverFilm(windowNumber: window.windowNumber, region: region,
                                     windowWidth: window.frame.width, hz: hz)
            started.start()
            film = started
            await sleep(0.15)
        }
        let began = DriverClock.now()
        DriverTimeline.shared.add("gesture", ["id": step.id, "do": step.verb,
                                              "ticks": ticks.count], at: began)

        // `capture` trades timing for evidence: the events are sent one at a time from
        // the main actor with a screenshot after each (or each Nth).
        var captured = 0
        if let every = captureInterval(step) {
            let pause = step.double("captureDelay") ?? 0.05
            for (k, tick) in ticks.enumerated() {
                tick.fire()
                await sleep(pause)
                if k % every == 0 || k == ticks.count - 1 {
                    _ = try await takeShot(name: String(format: "%@-%03d", step.id, captured),
                                           group: step.id, keep: false)
                    captured += 1
                }
            }
        } else {
            let quality = await DriverPacer.run(ticks)
            // How late the driver's own events were. Large numbers mean the gesture
            // sent was not the gesture asked for, and its timings should not be read.
            out["postLateWorstMs"] = quality.worstLateMs
            out["postLateMeanMs"] = quality.meanLateMs
            out["postCallWorstMs"] = quality.worstPostMs
        }
        let posted = DriverClock.now()

        var delivered = true
        if !endEvent.isEmpty {
            delivered = await wait(timeout: step.double("deliveryTimeout") ?? 2) {
                input.receivedCount(endEvent) > receivedBefore
            }
        }
        // One more turn so the handler of the last event has run and been sampled.
        await sleep(0.03)
        // The gesture ends when the app receives its last event, not when this task
        // next gets the main thread.
        var ended = DriverClock.now()
        if delivered, let at = input.lastReceived(endEvent), at >= began { ended = at }

        if holdsModifiers {
            input.setModifiers(previousModifiers)
        }

        var settledAt: Double?
        if let limit = step.double("settle") {
            settledAt = await settled(timeout: limit, quiet: step.double("quiet") ?? 0.4)
        }

        if let film {
            if settledAt == nil { await sleep(step.double("filmTail") ?? 1.0) }
            let seen = film.stop()
            for (key, value) in filmMetrics(seen.changes, samples: seen.samples,
                                            began: began, ended: ended) {
                out[key] = value
            }
        }
        out["delivered"] = delivered
        out["events"] = ticks.count
        if captured > 0 { out["captured"] = captured }
        let metrics = gestureMetrics(began: began, posted: posted, ended: ended,
                                     settledAt: settledAt, framesFrom: framesBefore,
                                     samplesFrom: samplesBefore, hitchesFrom: hitchesBefore,
                                     watch: step.string("watch"))
        for (key, value) in metrics { out[key] = value }
        values["last"] = out
        values["steps." + step.id] = out
        if !delivered {
            throw DriverError("\(step.verb) via \(via.rawValue): the app never received "
                                  + "the closing \(endEvent) event")
        }
        return out
    }

    private func captureInterval(_ step: DriverStep) -> Int? {
        if step.string("capture") == "each" { return 1 }
        if let every = step.int("capture"), every > 0 { return every }
        return nil
    }
}

#endif

// DriverInput.swift
// Synthesized user input. Two backends: `hid` posts CGEvents at the HID tap (the window
// server routes them, the real cursor moves); `app` posts NSEvents into this process's
// queue. Both go through NSApp's normal dispatch. See driver/README.md.

#if os(macOS)

import AppKit
import CoreGraphics

/// Not actor-isolated on purpose: a gesture's events are posted from a pacing thread so
/// their timing does not depend on how busy the main thread is. Geometry is a snapshot
/// taken on the main thread (`refreshGeometry`) for that reason.
final class DriverInput {

    enum Via: String {
        case hid, app
    }

    struct WindowGeometry {
        var frame: CGRect = .zero
        var number: Int = 0
        var primaryHeight: CGFloat = 0
    }

    let window: NSWindow
    var via: Via = .app
    private(set) var geometry = WindowGeometry()
    /// Pointer position in window-frame points, origin top-left of the window frame.
    private(set) var cursor: CGPoint = .zero
    private(set) var modifiers: NSEvent.ModifierFlags = []
    /// Called on the main thread for every event the app receives.
    var onReceive: ((NSEvent) -> Void)?
    private var eventNumber = 0
    private var sequence = 0
    private var monitor: Any?
    private let source = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    private var received: [String: Int] = [:]
    /// CGEvent integer fields that make `NSEvent(cgEvent:)` name this window; found by
    /// trial at start. Empty: in-process scroll and gesture events are handed to the
    /// view under them directly (`intercept`).
    private(set) var windowFields: [Int] = []
    private var pendingPoints: [Int64: CGPoint] = [:]
    private var pendingTag: Int64 = 0x4C55_0000

    init(window: NSWindow) {
        self.window = window
    }

    /// Main thread only.
    func refreshGeometry() {
        geometry = WindowGeometry(frame: window.frame, number: window.windowNumber,
                            primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    /// Whether a window-frame point is on the display, where HID events can reach it.
    func isOnScreen(_ wf: CGPoint) -> Bool {
        let p = quartz(wf)
        guard let screen = NSScreen.screens.first?.frame else { return false }
        return p.x >= 1 && p.y >= 1 && p.x < screen.width - 1 && p.y < screen.height - 1
    }

    /// Main thread only. Tries each CGEvent field as the carrier of the window number.
    func calibrateWindowFields() {
        var found: [Int] = []
        for raw in 0..<256 {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                      wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)
            else { continue }
            event.setIntegerValueField(unsafeBitCast(UInt32(raw), to: CGEventField.self),
                                       value: Int64(geometry.number))
            if let converted = NSEvent(cgEvent: event), converted.type == .scrollWheel,
               converted.windowNumber == geometry.number {
                found.append(raw)
            }
        }
        windowFields = found
    }

    func receivedCount(_ type: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return received[type] ?? 0
    }

    // MARK: Geometry

    /// The view whose flipped coordinate space SwiftUI calls `.global`.
    private var hostingView: NSView? {
        guard let content = window.contentView else { return nil }
        return DriverInput.findHosting(content) ?? content
    }

    private static func findHosting(_ view: NSView) -> NSView? {
        if String(describing: type(of: view)).contains("HostingView") { return view }
        for sub in view.subviews {
            if let found = findHosting(sub) { return found }
        }
        return nil
    }

    func windowFramePoint(fromGlobal p: CGPoint) -> CGPoint {
        guard let host = hostingView else { return p }
        let local = host.isFlipped ? p : CGPoint(x: p.x, y: host.bounds.height - p.y)
        let base = host.convert(local, to: nil)
        return CGPoint(x: base.x, y: geometry.frame.height - base.y)
    }

    func windowFrameRect(fromGlobal r: CGRect) -> CGRect {
        let a = windowFramePoint(fromGlobal: CGPoint(x: r.minX, y: r.minY))
        let b = windowFramePoint(fromGlobal: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: Swift.min(a.x, b.x), y: Swift.min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func base(_ wf: CGPoint) -> CGPoint {
        CGPoint(x: wf.x, y: geometry.frame.height - wf.y)
    }

    /// Quartz global display point (origin top-left of the primary display).
    private func quartz(_ wf: CGPoint) -> CGPoint {
        let cocoaY = geometry.frame.maxY - wf.y
        return CGPoint(x: geometry.frame.minX + wf.x, y: geometry.primaryHeight - cocoaY)
    }

    private func windowFramePoint(fromBase p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: geometry.frame.height - p.y)
    }

    /// Accessibility frames are Cocoa screen rectangles (origin bottom-left).
    func windowFrameRect(fromScreen r: CGRect) -> CGRect {
        CGRect(x: r.minX - geometry.frame.minX, y: geometry.frame.maxY - r.maxY,
               width: r.width, height: r.height)
    }

    // MARK: What the app actually received

    func startMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .any) { [weak self] event in
            guard let self else { return event }
            self.record(received: event)
            self.onReceive?(event)
            return self.intercept(event)
        }
    }

    /// An in-process scroll or gesture event that AppKit could not tie to a window is
    /// given to the view under its intended point, as `NSWindow.sendEvent` would.
    private func intercept(_ event: NSEvent) -> NSEvent? {
        guard event.type == .scrollWheel || event.type == .magnify
                || event.type == .smartMagnify,
              event.windowNumber != geometry.number, let cg = event.cgEvent else {
            return event
        }
        let tag = cg.getIntegerValueField(.eventSourceUserData)
        lock.lock()
        let point = pendingPoints.removeValue(forKey: tag)
        lock.unlock()
        guard let point, let content = window.contentView else { return event }
        let inWindow = base(point)
        let inParent = content.superview?.convert(inWindow, from: nil) ?? inWindow
        guard let target = content.hitTest(inParent) else { return nil }
        switch event.type {
        case .scrollWheel: target.scrollWheel(with: event)
        case .magnify: target.magnify(with: event)
        default: target.smartMagnify(with: event)
        }
        return nil
    }

    private func record(received event: NSEvent) {
        let typeName = DriverInput.name(event.type)
        lock.lock()
        received[typeName, default: 0] += 1
        lock.unlock()
        var row: [String: Any] = ["type": typeName,
                                  "et": DriverClock.fromUptime(event.timestamp),
                                  "flags": Int(event.modifierFlags.rawValue & 0xFFFF_0000)]
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
             .rightMouseDragged, .mouseMoved, .otherMouseDown, .otherMouseUp:
            let p = windowFramePoint(fromBase: event.locationInWindow)
            row["x"] = Double(p.x)
            row["y"] = Double(p.y)
            if event.type != .mouseMoved { row["clicks"] = event.clickCount }
            row["win"] = event.windowNumber
        case .scrollWheel:
            let p = windowFramePoint(fromBase: event.locationInWindow)
            row["x"] = Double(p.x)
            row["y"] = Double(p.y)
            row["dx"] = Double(event.scrollingDeltaX)
            row["dy"] = Double(event.scrollingDeltaY)
            row["precise"] = event.hasPreciseScrollingDeltas
            row["phase"] = Int(event.phase.rawValue)
            row["momentum"] = Int(event.momentumPhase.rawValue)
            row["win"] = event.windowNumber
        case .magnify:
            let p = windowFramePoint(fromBase: event.locationInWindow)
            row["x"] = Double(p.x)
            row["y"] = Double(p.y)
            row["mag"] = Double(event.magnification)
            row["phase"] = Int(event.phase.rawValue)
            row["win"] = event.windowNumber
        case .smartMagnify, .gesture, .beginGesture, .endGesture, .swipe, .rotate:
            row["win"] = event.windowNumber
        case .keyDown, .keyUp:
            row["key"] = Int(event.keyCode)
            row["chars"] = event.charactersIgnoringModifiers ?? ""
        case .flagsChanged:
            row["key"] = Int(event.keyCode)
        default:
            break
        }
        DriverTimeline.shared.add("rx", row)
    }

    static func name(_ type: NSEvent.EventType) -> String {
        switch type {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .leftMouseDragged: return "leftMouseDragged"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .rightMouseDragged: return "rightMouseDragged"
        case .mouseMoved: return "mouseMoved"
        case .mouseEntered: return "mouseEntered"
        case .mouseExited: return "mouseExited"
        case .cursorUpdate: return "cursorUpdate"
        case .scrollWheel: return "scrollWheel"
        case .magnify: return "magnify"
        case .smartMagnify: return "smartMagnify"
        case .gesture: return "gesture"
        case .beginGesture: return "beginGesture"
        case .endGesture: return "endGesture"
        case .swipe: return "swipe"
        case .rotate: return "rotate"
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        case .flagsChanged: return "flagsChanged"
        case .appKitDefined: return "appKitDefined"
        case .systemDefined: return "systemDefined"
        case .applicationDefined: return "applicationDefined"
        case .pressure: return "pressure"
        default: return "type\(type.rawValue)"
        }
    }

    // MARK: Posting

    private func log(_ what: String, _ wf: CGPoint, _ extra: [String: Any] = [:]) {
        sequence += 1
        var row = extra
        row["ev"] = what
        row["seq"] = sequence
        row["via"] = via.rawValue
        row["x"] = Double(wf.x)
        row["y"] = Double(wf.y)
        DriverTimeline.shared.add("in", row)
    }

    private func cgFlags() -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    private func postNS(_ event: NSEvent?) {
        guard let event else {
            DriverTimeline.shared.add("error", ["what": "could not build NSEvent"])
            return
        }
        NSApplication.shared.postEvent(event, atStart: false)
    }

    /// Sends a CGEvent by the current backend. For `app` it is converted and queued
    /// in-process, tagged with this window so AppKit can route it.
    private func postCG(_ event: CGEvent?, at wf: CGPoint) {
        guard let event else {
            DriverTimeline.shared.add("error", ["what": "could not build CGEvent"])
            return
        }
        event.location = quartz(wf)
        event.flags = cgFlags()
        switch via {
        case .hid:
            event.post(tap: .cghidEventTap)
        case .app:
            let number = Int64(geometry.number)
            for raw in windowFields {
                event.setIntegerValueField(unsafeBitCast(UInt32(raw), to: CGEventField.self),
                                           value: number)
            }
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            pendingTag += 1
            let tag = pendingTag
            pendingPoints[tag] = wf
            if pendingPoints.count > 4096 { pendingPoints.removeAll() }
            lock.unlock()
            event.setIntegerValueField(.eventSourceUserData, value: tag)
            postNS(NSEvent(cgEvent: event))
        }
    }

    private func mouse(_ ns: NSEvent.EventType, _ cg: CGEventType, button: CGMouseButton,
                       at wf: CGPoint, clickCount: Int) {
        cursor = wf
        switch via {
        case .hid:
            let event = CGEvent(mouseEventSource: source, mouseType: cg,
                                mouseCursorPosition: quartz(wf), mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            event?.flags = cgFlags()
            event?.post(tap: .cghidEventTap)
        case .app:
            eventNumber += 1
            let pressed = ns == .leftMouseDown || ns == .leftMouseDragged
                || ns == .rightMouseDown || ns == .rightMouseDragged
            postNS(NSEvent.mouseEvent(
                with: ns, location: base(wf), modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: geometry.number, context: nil,
                eventNumber: eventNumber, clickCount: clickCount,
                pressure: pressed ? 1 : 0))
        }
    }

    /// Moves the real cursor without posting an event, so `NSEvent.mouseLocation` and
    /// the `app` backend agree. Needs no permission.
    func warpCursor(to wf: CGPoint) {
        CGWarpMouseCursorPosition(quartz(wf))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func move(to wf: CGPoint) {
        log("move", wf)
        if via == .app { warpCursor(to: wf) }
        mouse(.mouseMoved, .mouseMoved, button: .left, at: wf, clickCount: 0)
    }

    func down(at wf: CGPoint, right: Bool = false, clickCount: Int = 1) {
        log(right ? "rightDown" : "down", wf, ["clicks": clickCount])
        mouse(right ? .rightMouseDown : .leftMouseDown,
              right ? .rightMouseDown : .leftMouseDown,
              button: right ? .right : .left, at: wf, clickCount: clickCount)
    }

    func drag(to wf: CGPoint, right: Bool = false) {
        log("drag", wf)
        if via == .app { warpCursor(to: wf) }
        mouse(right ? .rightMouseDragged : .leftMouseDragged,
              right ? .rightMouseDragged : .leftMouseDragged,
              button: right ? .right : .left, at: wf, clickCount: 1)
    }

    func up(at wf: CGPoint, right: Bool = false, clickCount: Int = 1) {
        log(right ? "rightUp" : "up", wf, ["clicks": clickCount])
        mouse(right ? .rightMouseUp : .leftMouseUp,
              right ? .rightMouseUp : .leftMouseUp,
              button: right ? .right : .left, at: wf, clickCount: clickCount)
    }

    /// `phase`: 0 none (a wheel), 1 began, 2 changed, 4 ended, 128 may-begin.
    /// `momentum`: 0 none, 1 begin, 2 continue, 3 end.
    func scroll(dx: Double, dy: Double, precise: Bool, phase: Int, momentum: Int,
                at wf: CGPoint) {
        log("scroll", wf, ["dx": dx, "dy": dy, "precise": precise,
                           "phase": phase, "momentum": momentum])
        let event = CGEvent(scrollWheelEvent2Source: source,
                            units: precise ? .pixel : .line, wheelCount: 2,
                            wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()),
                            wheel3: 0)
        if precise {
            event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        event?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum))
        postCG(event, at: wf)
    }

    // Undocumented CGEvent gesture fields, the layout WebKit's own tests synthesize.
    private static let gestureEventType = unsafeBitCast(UInt32(29), to: CGEventType.self)
    private static let gestureHIDTypeField = unsafeBitCast(UInt32(110), to: CGEventField.self)
    private static let gestureZoomValueField = unsafeBitCast(UInt32(113), to: CGEventField.self)
    private static let gesturePhaseField = unsafeBitCast(UInt32(132), to: CGEventField.self)

    private func gesture(hidType: Int64, phase: Int, magnification: Double?,
                         at wf: CGPoint) {
        let event = CGEvent(source: source)
        event?.type = DriverInput.gestureEventType
        event?.setIntegerValueField(DriverInput.gestureHIDTypeField, value: hidType)
        if let magnification {
            event?.setDoubleValueField(DriverInput.gestureZoomValueField, value: magnification)
        }
        event?.setIntegerValueField(DriverInput.gesturePhaseField, value: Int64(phase))
        postCG(event, at: wf)
    }

    /// One pinch event. `phase`: 1 began, 2 changed, 4 ended. `magnification` is the
    /// per-event delta, as `NSEvent.magnification` reports it.
    func magnify(_ magnification: Double, phase: Int, at wf: CGPoint) {
        log("magnify", wf, ["mag": magnification, "phase": phase])
        gesture(hidType: 8, phase: phase, magnification: magnification, at: wf)
    }

    func smartMagnify(at wf: CGPoint) {
        log("smartMagnify", wf)
        gesture(hidType: 22, phase: 0, magnification: nil, at: wf)
    }

    // MARK: Keys

    func setModifiers(_ flags: NSEvent.ModifierFlags) {
        guard flags != modifiers else { return }
        let changes: [(NSEvent.ModifierFlags, CGKeyCode)] = [
            (.shift, 56), (.control, 59), (.option, 58), (.command, 55),
        ]
        for (flag, code) in changes where flags.contains(flag) != modifiers.contains(flag) {
            let pressed = flags.contains(flag)
            if pressed { modifiers.insert(flag) } else { modifiers.remove(flag) }
            DriverTimeline.shared.add("in", ["ev": "modifier", "key": Int(code),
                                             "down": pressed, "via": via.rawValue])
            switch via {
            case .hid:
                let event = CGEvent(keyboardEventSource: source, virtualKey: code,
                                    keyDown: pressed)
                event?.flags = cgFlags()
                event?.post(tap: .cghidEventTap)
            case .app:
                postNS(NSEvent.keyEvent(
                    with: .flagsChanged, location: base(cursor), modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: geometry.number, context: nil,
                    characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: code))
            }
        }
    }

    static func flags(_ names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "shift": flags.insert(.shift)
            case "control", "ctrl": flags.insert(.control)
            case "option", "alt", "opt": flags.insert(.option)
            case "command", "cmd": flags.insert(.command)
            default: break
            }
        }
        return flags
    }

    private struct DriverKey {
        let code: CGKeyCode
        let plain: String
        let shifted: String
        let function: Bool
    }

    private static let keys: [String: DriverKey] = {
        var table: [String: DriverKey] = [:]
        let letters: [(String, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
            ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
            ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37),
            ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ]
        for (name, code) in letters {
            table[name] = DriverKey(code: code, plain: name, shifted: name.uppercased(),
                                   function: false)
        }
        let symbols: [(String, CGKeyCode, String)] = [
            ("1", 18, "!"), ("2", 19, "@"), ("3", 20, "#"), ("4", 21, "$"), ("5", 23, "%"),
            ("6", 22, "^"), ("7", 26, "&"), ("8", 28, "*"), ("9", 25, "("), ("0", 29, ")"),
            ("=", 24, "+"), ("-", 27, "_"), ("]", 30, "}"), ("[", 33, "{"), ("'", 39, "\""),
            (";", 41, ":"), ("\\", 42, "|"), (",", 43, "<"), ("/", 44, "?"), (".", 47, ">"),
            ("`", 50, "~"),
        ]
        for (name, code, shifted) in symbols {
            table[name] = DriverKey(code: code, plain: name, shifted: shifted, function: false)
        }
        func special(_ name: String, _ code: CGKeyCode, _ scalar: Int, function: Bool = false) {
            let character = UnicodeScalar(scalar).map { String(Character($0)) } ?? ""
            table[name] = DriverKey(code: code, plain: character, shifted: character,
                                   function: function)
        }
        special("return", 36, 13)
        special("tab", 48, 9)
        special("space", 49, 32)
        special("delete", 51, 127)
        special("escape", 53, 27)
        special("left", 123, NSLeftArrowFunctionKey, function: true)
        special("right", 124, NSRightArrowFunctionKey, function: true)
        special("down", 125, NSDownArrowFunctionKey, function: true)
        special("up", 126, NSUpArrowFunctionKey, function: true)
        return table
    }()

    static func knowsKey(_ name: String) -> Bool {
        keys[name.lowercased()] != nil
    }

    /// One key event. `name` is a US-layout key: a letter, a digit, a symbol, or
    /// return/tab/space/delete/escape/left/right/up/down.
    func key(_ name: String, down: Bool) {
        guard let key = DriverInput.keys[name.lowercased()] else {
            DriverTimeline.shared.add("error", ["what": "unknown key \(name)"])
            return
        }
        DriverTimeline.shared.add("in", ["ev": down ? "keyDown" : "keyUp", "name": name,
                                         "key": Int(key.code), "via": via.rawValue,
                                         "flags": Int(modifiers.rawValue)])
        switch via {
        case .hid:
            let event = CGEvent(keyboardEventSource: source, virtualKey: key.code,
                                keyDown: down)
            event?.flags = cgFlags()
            event?.post(tap: .cghidEventTap)
        case .app:
            var flags = modifiers
            if key.function { flags.insert([.function, .numericPad]) }
            let plain = key.plain
            let typed = modifiers.contains(.shift) ? key.shifted : key.plain
            postNS(NSEvent.keyEvent(
                with: down ? .keyDown : .keyUp, location: base(cursor),
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: geometry.number, context: nil,
                characters: typed, charactersIgnoringModifiers: plain,
                isARepeat: false, keyCode: key.code))
        }
    }
}

#endif

// DriverProbe.swift
// In-process accessibility lookup, and the `probe` verb: one step that reports which
// input and capture mechanisms work on the machine it runs on.

#if os(macOS)

import AppKit
import ApplicationServices
import LumenCore
import Metal
import SwiftUI

/// Which machine produced a report. Numbers from different machines are not comparable.
enum DriverMachine {

    private static func text(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    private static func flag(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname(name, &value, &size, nil, 0)
        return value != 0
    }

    @MainActor
    static func facts() -> [String: Any] {
        let info = ProcessInfo.processInfo
        var out: [String: Any] = [
            "model": text("hw.model"),
            "chip": text("machdep.cpu.brand_string"),
            "cores": info.activeProcessorCount,
            "memoryGB": Double(info.physicalMemory) / 1_073_741_824,
            "os": info.operatingSystemVersionString,
            "gpu": MTLCreateSystemDefaultDevice()?.name ?? "none",
            "virtualMachine": flag("kern.hv_vmm_present"),
            "runner": info.environment["RUNNER_NAME"] ?? "",
        ]
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            out["displayScale"] = Double(screen.backingScaleFactor)
            out["displayWidth"] = Double(screen.frame.width)
            out["displayHeight"] = Double(screen.frame.height)
            out["displayHz"] = screen.maximumFramesPerSecond
        }
        return out
    }
}

enum DriverAccessibility {

    struct Element {
        let role: String
        let label: String
        let title: String
        let help: String
        let value: String
        /// Cocoa screen coordinates.
        let frame: CGRect
        let depth: Int
    }

    /// Walks this process's own accessibility tree. No permission is involved.
    @MainActor
    static func elements(in window: NSWindow, limit: Int = 4000) -> [Element] {
        var out: [Element] = []
        var queue: [(Any, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            let (item, depth) = queue.removeFirst()
            visited += 1
            guard let node = item as? NSAccessibilityProtocol else { continue }
            let role = node.accessibilityRole()?.rawValue ?? ""
            let label = node.accessibilityLabel() ?? ""
            let title = node.accessibilityTitle() ?? ""
            let help = node.accessibilityHelp() ?? ""
            var value = ""
            if let raw = node.accessibilityValue() {
                value = String(describing: raw)
            }
            let frame = node.accessibilityFrame()
            if !(label.isEmpty && title.isEmpty && help.isEmpty) {
                out.append(Element(role: role, label: label, title: title, help: help,
                                   value: String(value.prefix(80)), frame: frame,
                                   depth: depth))
            }
            if depth < 60, let children = node.accessibilityChildren() {
                for child in children { queue.append((child, depth + 1)) }
            }
        }
        return out
    }

    /// Elements whose label, title or help equals `label` (else contains it), in
    /// reading order.
    @MainActor
    static func find(label: String, role: String?, in window: NSWindow) -> [Element] {
        let all = elements(in: window).filter {
            $0.frame.width > 0 && $0.frame.height > 0
                && (role == nil || $0.role == role)
        }
        func matches(_ element: Element, exact: Bool) -> Bool {
            for text in [element.label, element.title, element.help] {
                if exact ? text == label : text.localizedCaseInsensitiveContains(label) {
                    return true
                }
            }
            return false
        }
        var found = all.filter { matches($0, exact: true) }
        if found.isEmpty { found = all.filter { matches($0, exact: false) } }
        return found.sorted { a, b in
            // Cocoa y grows upward: larger maxY is higher on screen.
            if abs(a.frame.maxY - b.frame.maxY) > 0.5 { return a.frame.maxY > b.frame.maxY }
            return a.frame.minX < b.frame.minX
        }
    }
}

extension DriverSession {

    /// Tries every mechanism once and writes probe.json. For diagnosing a new machine.
    func probe(_ step: DriverStep) async -> [String: Any] {
        guard let window, let input else { return ["status": "error"] }
        var out: [String: Any] = [:]

        var screens: [[String: Any]] = []
        for screen in NSScreen.screens {
            var row = DriverJSON.rect(screen.frame)
            row["scale"] = Double(screen.backingScaleFactor)
            screens.append(row)
        }
        out["screens"] = screens
        let windowFacts: [String: Any] = [
            "frame": DriverJSON.rect(window.frame), "number": window.windowNumber,
            "key": window.isKeyWindow, "main": window.isMainWindow,
            "appActive": NSApp.isActive, "occluded": !window.occlusionState.contains(.visible),
            "contentView": window.contentView.map { String(describing: type(of: $0)) } ?? "nil",
            "styleFullSize": window.styleMask.contains(.fullSizeContentView),
        ]
        out["window"] = windowFacts
        let permissions: [String: Any] = [
            "postEvent": CGPreflightPostEventAccess(),
            "screenCapture": CGPreflightScreenCaptureAccess(),
            "accessibility": AXIsProcessTrusted(),
        ]
        out["permissions"] = permissions

        // Capture: each method, with enough statistics to tell a picture from a blank.
        var captures: [String: Any] = [:]
        for method in [DriverCapture.Method.windowList, .cacheDisplay, .screencapture] {
            let began = DriverClock.now()
            let image = DriverCapture.image(window: window, method: method)
            var row: [String: Any] = ["ms": (DriverClock.now() - began) * 1000,
                                      "ok": image != nil]
            if let image {
                row["width"] = image.width
                row["height"] = image.height
                if let pixels = DriverPixels(image) {
                    row["stats"] = pixels.stats(
                        in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                DriverCapture.write(
                    image, to: shotsDir.appendingPathComponent("probe-\(method.rawValue).png"))
            }
            captures[method.rawValue] = row
        }
        out["capture"] = captures

        // Input: for each backend, post one of everything at the viewer and count what
        // the app's own event monitor saw arrive.
        let target = anchorRect("viewer") ?? CGRect(origin: .zero, size: window.frame.size)
        let point = CGPoint(x: target.midX, y: target.midY)
        let kinds = ["mouseMoved", "leftMouseDown", "leftMouseDragged", "leftMouseUp",
                     "scrollWheel", "magnify", "smartMagnify", "keyDown", "flagsChanged",
                     "rightMouseDown"]
        var delivery: [String: Any] = [:]
        for via in [DriverInput.Via.app, .hid] {
            input.via = via
            var before: [String: Int] = [:]
            for kind in kinds { before[kind] = input.receivedCount(kind) }
            let hoverBefore = LoupeViewport.shared.lastCursor
            input.move(to: CGPoint(x: point.x + 20, y: point.y + 10))
            await sleep(0.1)
            input.move(to: point)
            await sleep(0.15)
            let hoverAfter = LoupeViewport.shared.lastCursor
            input.down(at: point)
            await sleep(0.05)
            input.drag(to: CGPoint(x: point.x + 4, y: point.y))
            await sleep(0.05)
            input.up(at: CGPoint(x: point.x + 4, y: point.y))
            await sleep(0.1)
            input.scroll(dx: 0, dy: 1, precise: false, phase: 0, momentum: 0, at: point)
            await sleep(0.1)
            input.scroll(dx: 0, dy: 3, precise: true, phase: 1, momentum: 0, at: point)
            await sleep(0.03)
            input.scroll(dx: 0, dy: 0, precise: true, phase: 4, momentum: 0, at: point)
            await sleep(0.1)
            let zoomBefore = LoupeViewport.shared.zoom
            input.magnify(0, phase: 1, at: point)
            await sleep(0.03)
            input.magnify(0.05, phase: 2, at: point)
            await sleep(0.03)
            input.magnify(0.05, phase: 2, at: point)
            await sleep(0.03)
            input.magnify(0, phase: 4, at: point)
            await sleep(0.2)
            let zoomAfter = LoupeViewport.shared.zoom
            input.smartMagnify(at: point)
            await sleep(0.1)
            input.setModifiers([.shift])
            await sleep(0.05)
            let globalShift = NSEvent.modifierFlags.contains(.shift)
            input.setModifiers([])
            await sleep(0.05)
            input.key("i", down: true)
            await sleep(0.03)
            input.key("i", down: false)
            await sleep(0.1)
            input.key("i", down: true)
            await sleep(0.03)
            input.key("i", down: false)
            await sleep(0.1)
            LoupeViewport.shared.fit()
            await sleep(0.3)
            var row: [String: Any] = [:]
            for kind in kinds { row[kind] = input.receivedCount(kind) - (before[kind] ?? 0) }
            row["hoverReachedViewer"] = hoverAfter != nil && hoverAfter != hoverBefore
            if let hoverAfter {
                row["hoverX"] = Double(hoverAfter.x)
                row["hoverY"] = Double(hoverAfter.y)
                row["expectedHoverX"] = Double(point.x - target.minX)
                row["expectedHoverY"] = Double(point.y - target.minY)
            }
            row["pinchChangedZoom"] = zoomAfter != zoomBefore
            row["zoomBefore"] = zoomBefore
            row["zoomAfter"] = zoomAfter
            row["globalModifierFlagsFollow"] = globalShift
            let mouse = NSEvent.mouseLocation
            row["globalMouseX"] = Double(mouse.x)
            row["globalMouseY"] = Double(mouse.y)
            delivery[via.rawValue] = row
        }
        out["delivery"] = delivery

        // Accessibility, in process.
        let elements = DriverAccessibility.elements(in: window)
        var listed: [[String: Any]] = []
        for element in elements.prefix(400) {
            var row = DriverJSON.rect(input.windowFrameRect(fromScreen: element.frame))
            row["role"] = element.role
            row["label"] = element.label
            row["title"] = element.title
            row["help"] = String(element.help.prefix(60))
            row["value"] = element.value
            listed.append(row)
        }
        let accessibility: [String: Any] = ["count": elements.count, "elements": listed]
        out["accessibility"] = accessibility

        var anchors: [[String: Any]] = []
        for anchor in DriverAnchors.shared.all() {
            var row = DriverJSON.rect(input.windowFrameRect(fromGlobal: anchor.frame))
            row["id"] = anchor.id
            anchors.append(row)
        }
        out["anchors"] = anchors

        DriverJSON.write(out, to: outDir.appendingPathComponent("probe.json"))
        return ["file": "probe.json", "permissions": permissions]
    }
}

#endif

// DriverTargets.swift
// Finding things to aim at, in every window: named anchors, the accessibility tree,
// window roles. Also the verbs built on that: listTargets, press, filePanel, files.

#if os(macOS)

import AppKit
import ApplicationServices

extension DriverSession {

    static let windowRoles: Set<String> = ["sheet", "popover", "alert", "filePanel", "colors",
                                           "panel", "child", "menu", "keyWindow"]

    private static func readingOrder(_ a: CGRect, _ b: CGRect) -> Bool {
        if abs(a.minY - b.minY) > 0.5 { return a.minY < b.minY }
        return a.minX < b.minX
    }

    // MARK: Anchors

    /// Every live anchor in main-window points, with the window it is in.
    func liveAnchors() -> [(id: String, rect: CGRect, window: NSWindow?)] {
        guard let input else { return [] }
        typealias Live = (id: String, rect: CGRect, window: NSWindow?)
        // A presented view whose window was not recorded is in the frontmost presentation.
        var frontmost: NSWindow?
        if let window {
            let presentation = DriverWindows.list(main: window).first {
                $0.role == "sheet" || $0.role == "popover"
            }
            frontmost = presentation?.window
        }
        return DriverAnchors.shared.live().compactMap { (entry) -> Live? in
            let home = entry.window ?? (entry.presented ? frontmost : nil)
            if let other = home, !other.isVisible { return nil }
            return (entry.id, input.windowFrameRect(fromGlobal: entry.frame, in: home), home)
        }
    }

    /// Frames of the anchor `id` in reading order, in main-window points.
    func anchorRects(id: String) -> [CGRect] {
        liveAnchors().filter { $0.id == id }.map { $0.rect }.sorted(by: DriverSession.readingOrder)
    }

    // MARK: Windows

    func windowRect(role: String, index: Int) -> CGRect? {
        guard let window else { return nil }
        let windows = DriverWindows.list(main: window)
        let matching = role == "keyWindow"
            ? windows.filter { $0.isKey }
            : windows.filter { $0.role == role }
        return index < matching.count ? matching[index].frame : nil
    }

    // MARK: Accessibility

    func axRect(_ node: DriverAXNode) -> CGRect {
        guard let window else { return node.quartz }
        return DriverWindows.fromQuartz(node.quartz, main: window)
    }

    /// Accessibility nodes named `kind/label` (or just a label), in reading order, with
    /// elements that repeat a parent's name and frame dropped.
    func axMatches(_ name: String, nodes: [DriverAXNode]) -> [DriverAXNode] {
        var kind = "*"
        var label = name
        if let slash = name.firstIndex(of: "/") {
            kind = String(name[..<slash])
            label = String(name[name.index(after: slash)...])
        }
        var seen: [(String, CGRect)] = []
        var out: [DriverAXNode] = []
        for node in DriverAX.find(kind: kind, label: label, in: nodes) {
            let rect = axRect(node)
            if seen.contains(where: { $0.0 == node.name && $0.1.insetBy(dx: -1, dy: -1).contains(rect) }) {
                continue
            }
            seen.append((node.name, rect))
            out.append(node)
        }
        return out.sorted { DriverSession.readingOrder(axRect($0), axRect($1)) }
    }

    // MARK: Resolution

    /// A named target: `window`, `cursor`, a window role, an anchor, else an
    /// accessibility name. `within` keeps only those whose centre is inside it.
    func resolveName(_ name: String, index: Int, within: Any?) async throws -> CGRect {
        guard let input, let window else { throw DriverError("no window") }
        if name == "window" { return CGRect(origin: .zero, size: window.frame.size) }
        if name == "cursor" { return CGRect(origin: input.cursor, size: .zero) }
        var container: CGRect?
        if let within, !(within is NSNull) { container = try await resolveFrame(within) }
        func inside(_ rect: CGRect) -> Bool {
            guard let container else { return true }
            return container.insetBy(dx: -2, dy: -2).contains(CGPoint(x: rect.midX, y: rect.midY))
        }
        if DriverSession.windowRoles.contains(name) {
            if let rect = windowRect(role: name, index: index) {
                lastTarget = ["source": "window", "name": name]
                return rect
            }
            throw DriverError("no \(name) window is open. Windows: "
                                  + windowSummary())
        }
        let anchors = anchorRects(id: name).filter(inside)
        if index < anchors.count {
            lastTarget = ["source": "anchor", "name": name]
            return anchors[index]
        }
        let snapshot = await DriverAX.snapshot()
        let nodes = axMatches(name, nodes: snapshot.nodes).filter { inside(axRect($0)) }
        if index < nodes.count {
            lastTarget = ["source": "ax", "name": nodes[index].name, "role": nodes[index].role]
            return axRect(nodes[index])
        }
        throw DriverError(missMessage(name, index: index, anchors: anchors.count,
                                      ax: nodes.count, snapshot: snapshot))
    }

    private func windowSummary() -> String {
        guard let window else { return "" }
        return DriverWindows.list(main: window).map { "\($0.role) \"\($0.title)\"" }
            .joined(separator: ", ")
    }

    private func missMessage(_ name: String, index: Int, anchors: Int, ax: Int,
                             snapshot: DriverAX.Result) -> String {
        var text = "no target \"\(name)\" index \(index) (\(anchors) anchors, \(ax) "
            + "accessibility matches)."
        let label = name.split(separator: "/", maxSplits: 1).last.map { String($0) } ?? name
        let wanted = DriverAX.normal(label)
        var near = Set(liveAnchors().map { $0.id }.filter { DriverAX.normal($0).contains(wanted) })
        for node in snapshot.nodes where !node.label.isEmpty
            && DriverAX.normal(node.label).contains(wanted) {
            near.insert(node.name)
        }
        if !near.isEmpty {
            text += " Similar: " + near.sorted().prefix(20).joined(separator: ", ") + "."
        }
        if let error = snapshot.error { text += " Accessibility: \(error)." }
        text += " Windows: " + windowSummary() + ". A listTargets step lists every name."
        return text
    }

    /// The accessibility node a target names, for `press`.
    func resolveNode(_ target: Any?) async throws -> DriverAXNode {
        var name = target as? String
        var index = 0
        var within: Any?
        if let spec = target as? [String: Any] {
            name = spec["name"] as? String ?? spec["anchor"] as? String
            if let label = spec["ax"] as? String { name = label }
            index = (spec["index"] as? NSNumber)?.intValue ?? 0
            within = spec["within"]
        }
        guard let name else { throw DriverError("press needs a target name") }
        var container: CGRect?
        if let within, !(within is NSNull) { container = try await resolveFrame(within) }
        let snapshot = await DriverAX.snapshot()
        let nodes = axMatches(name, nodes: snapshot.nodes).filter { node in
            guard let container else { return true }
            let rect = axRect(node)
            return container.insetBy(dx: -2, dy: -2).contains(CGPoint(x: rect.midX, y: rect.midY))
        }
        guard index < nodes.count else {
            throw DriverError(missMessage(name, index: index, anchors: 0, ax: nodes.count,
                                          snapshot: snapshot))
        }
        return nodes[index]
    }

    // MARK: Verbs

    /// Writes `targets-<name>.json` and `.txt`: every window, every anchor and every named
    /// accessibility element on screen, with the name a step would use for it.
    func listTargets(_ step: DriverStep) async -> [String: Any] {
        guard let window else { return ["status": "error", "error": "no window"] }
        let name = step.string("name") ?? step.id
        let windows = DriverWindows.list(main: window)
        func windowIndex(_ rect: CGRect, _ hint: NSWindow?) -> Int {
            if let hint, let i = windows.firstIndex(where: { $0.window === hint }) { return i }
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            return windows.firstIndex { $0.frame.contains(centre) } ?? -1
        }
        func boxWindowIndex(_ box: CGRect, _ rect: CGRect) -> Int {
            if box.width > 0 {
                let frame = DriverWindows.fromQuartz(box, main: window)
                if let i = windows.firstIndex(where: {
                    abs($0.frame.minX - frame.minX) < 4 && abs($0.frame.minY - frame.minY) < 4
                        && abs($0.frame.width - frame.width) < 4
                }) { return i }
            }
            return windowIndex(rect, nil)
        }
        func visible(_ rect: CGRect, _ index: Int) -> Bool {
            guard index >= 0 else { return false }
            return windows[index].frame.insetBy(dx: -1, dy: -1)
                .contains(CGPoint(x: rect.midX, y: rect.midY))
        }
        var anchorRows: [[String: Any]] = []
        var lines: [(window: Int, rect: CGRect, text: String)] = []
        for anchor in liveAnchors().sorted(by: { DriverSession.readingOrder($0.rect, $1.rect) }) {
            let w = windowIndex(anchor.rect, anchor.window ?? window)
            var row = DriverJSON.rect(anchor.rect)
            row["name"] = anchor.id
            row["window"] = w
            row["visible"] = visible(anchor.rect, w)
            anchorRows.append(row)
            lines.append((w, anchor.rect, anchor.id + "  (anchor)"))
        }
        let snapshot = await DriverAX.snapshot()
        var axRows: [[String: Any]] = []
        var unnamed = 0
        var seen = Set<String>()
        for node in snapshot.nodes {
            guard node.quartz.width > 0, node.quartz.height > 0, !node.label.isEmpty else {
                unnamed += 1
                continue
            }
            let rect = axRect(node)
            let dedupe = "\(node.name)@\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
            guard seen.insert(dedupe).inserted else { continue }
            let w = boxWindowIndex(node.containerBox, rect)
            var row = DriverJSON.rect(rect)
            row["name"] = node.name
            row["role"] = node.role
            if !node.subrole.isEmpty { row["subrole"] = node.subrole }
            for (key, value) in [("title", node.title), ("description", node.desc),
                                 ("help", node.help), ("identifier", node.ident),
                                 ("value", node.value)] where !value.isEmpty {
                row[key] = String(value.prefix(120))
            }
            row["enabled"] = node.enabled
            row["container"] = node.container
            row["window"] = w
            row["visible"] = visible(rect, w)
            axRows.append(row)
            var text = node.name + "  (" + node.role
            if !node.enabled { text += ", disabled" }
            if !node.value.isEmpty, node.role != "AXStaticText" {
                text += ", value " + String(DriverAX.tidy(node.value).prefix(30))
            }
            lines.append((w, rect, text + ")"))
        }
        var document: [String: Any] = [
            "windows": windows.enumerated().map { $0.element.json(index: $0.offset) },
            "anchors": anchorRows, "ax": axRows, "axUnnamed": unnamed, "axMs": snapshot.ms,
        ]
        if let error = snapshot.error { document["axError"] = error }
        DriverJSON.write(document, to: outDir.appendingPathComponent("targets-\(name).json"))

        var text = "# targets-\(name): \(anchorRows.count) anchors, \(axRows.count) "
            + "accessibility names, \(windows.count) windows. Coordinates are main-window "
            + "points [x y w h]; ~ marks a target whose centre is outside its window "
            + "(scrolled away).\n"
        if let error = snapshot.error { text += "# accessibility: \(error)\n" }
        for (index, info) in windows.enumerated() {
            text += "\n== window \(index): \(info.role) \"\(info.title)\" "
                + "[\(Int(info.frame.minX)) \(Int(info.frame.minY)) "
                + "\(Int(info.frame.width)) \(Int(info.frame.height))]\n"
            for line in lines.filter({ $0.window == index })
                .sorted(by: { DriverSession.readingOrder($0.rect, $1.rect) }) {
                let r = line.rect
                text += (visible(r, index) ? "  " : "~ ") + line.text
                    + "  [\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height))]\n"
            }
        }
        let orphans = lines.filter { $0.window < 0 }
        if !orphans.isEmpty {
            text += "\n== outside every window\n"
            for line in orphans { text += "~ " + line.text + "\n" }
        }
        try? Data(text.utf8).write(to: outDir.appendingPathComponent("targets-\(name).txt"))
        let summary: [String: Any] = ["anchors": anchorRows.count, "ax": axRows.count,
                                      "windows": windows.count]
        values["targets." + name] = summary
        var out: [String: Any] = ["file": "targets-\(name).txt", "anchors": anchorRows.count,
                                  "ax": axRows.count, "windows": windows.count,
                                  "axMs": snapshot.ms]
        if let error = snapshot.error { out["axError"] = error }
        return out
    }

    /// Performs an accessibility action on a named element: no pointer, `via: ax`.
    func press(_ step: DriverStep) async throws -> [String: Any] {
        let node = try await resolveNode(step.raw["target"])
        let action = step.string("action") ?? "AXPress"
        _ = await DriverAX.perform(action, on: node.element)
        await sleep(step.double("after") ?? 0.3)
        return ["via": "ax", "name": node.name, "role": node.role]
    }

    /// `$OUT`, `$PHOTOS` and `$TMP` in a path.
    func expandPath(_ path: String) -> String {
        let environment = ProcessInfo.processInfo.environment
        return path.replacingOccurrences(of: "$OUT", with: outDir.path)
            .replacingOccurrences(of: "$PHOTOS", with: environment["LUMEN_DRIVER_PHOTOS"] ?? "")
            .replacingOccurrences(of: "$TMP", with: NSTemporaryDirectory())
    }

    /// Points the open or save panel that is up at a folder (and a file name). Setup by
    /// direct call: the button that confirms it is still for a click or a key.
    func filePanel(_ step: DriverStep) async throws -> [String: Any] {
        var panel: NSSavePanel?
        _ = await wait(timeout: step.double("timeout") ?? 10) {
            panel = NSApp.windows.compactMap { $0 as? NSSavePanel }.first { $0.isVisible }
            return panel != nil
        }
        guard let panel else { throw DriverError("no open or save panel appeared") }
        var out: [String: Any] = ["via": "direct", "prompt": panel.prompt ?? ""]
        if let folder = step.string("folder") {
            let path = expandPath(folder)
            try? FileManager.default.createDirectory(atPath: path,
                                                     withIntermediateDirectories: true)
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            out["folder"] = path
        }
        if let name = step.string("fileName") { panel.nameFieldStringValue = name }
        await sleep(step.double("after") ?? 0.6)
        if step.string("confirm") == "direct" {
            panel.ok(nil)
            await sleep(0.3)
            out["confirmed"] = "direct"
        }
        return out
    }

    /// Lists a folder: `steps.<id>.count`, `.bytes`.
    func files(_ step: DriverStep) -> [String: Any] {
        let path = expandPath(step.string("dir") ?? "$OUT")
        let manager = FileManager.default
        let names = ((try? manager.contentsOfDirectory(atPath: path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        var bytes = 0
        var rows: [[String: Any]] = []
        for name in names {
            let size = (try? manager.attributesOfItem(
                atPath: (path as NSString).appendingPathComponent(name)))?[.size] as? NSNumber
            bytes += size?.intValue ?? 0
            rows.append(["name": name, "bytes": size?.intValue ?? 0])
        }
        let summary: [String: Any] = ["count": names.count, "bytes": bytes]
        values["steps." + step.id] = summary
        return ["dir": path, "count": names.count, "bytes": bytes, "files": Array(rows.prefix(60))]
    }
}

#endif

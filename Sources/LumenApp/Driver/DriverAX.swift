// DriverAX.swift
// This process's accessibility tree, read the way an outside client reads it: through
// AXUIElement from a background thread while the main thread stays free to answer.
// Gives every button, checkbox, popup, field, menu-bar item and text its role and label,
// in every window. Needs the accessibility permission (the hosted runner grants it).

#if os(macOS)

import AppKit
import ApplicationServices

struct DriverAXNode {
    let role: String
    let subrole: String
    let title: String
    let desc: String
    let help: String
    let ident: String
    let value: String
    let enabled: Bool
    /// Quartz screen points (origin top-left of the primary display).
    let quartz: CGRect
    let depth: Int
    /// The nearest enclosing window-like element: AXWindow, AXSheet, AXPopover, AXMenu…
    let container: String
    let element: AXUIElement

    var kind: String { DriverAX.kind(role: role, subrole: subrole) }

    /// What a person would call it: the title, else the description, else for text its
    /// value, else the tooltip, else the identifier.
    var label: String {
        for text in [title, desc, role == "AXStaticText" ? value : "", help, ident] {
            let clean = DriverAX.tidy(text)
            if !clean.isEmpty { return clean }
        }
        return ""
    }

    var name: String { kind + "/" + label }

    /// Every text this element answers to, for matching.
    var labels: [String] {
        [title, desc, role == "AXStaticText" || role == "AXTextField" ? value : "", help, ident]
            .map(DriverAX.tidy).filter { !$0.isEmpty }
    }
}

enum DriverAX {

    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased, "..." as "…", runs of spaces as one: how two labels are compared.
    static func normal(_ text: String) -> String {
        tidy(text).lowercased().replacingOccurrences(of: "...", with: "…")
            .split(separator: " ").joined(separator: " ")
    }

    static func kind(role: String, subrole: String) -> String {
        switch role {
        case "AXButton": return "button"
        case "AXCheckBox": return subrole == "AXSwitch" || subrole == "AXToggle" ? "toggle" : "checkbox"
        case "AXRadioButton": return "radio"
        case "AXPopUpButton": return "popup"
        case "AXMenuButton": return "menubutton"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return "field"
        case "AXStaticText": return "text"
        case "AXSlider": return "slider"
        case "AXIncrementor": return "stepper"
        case "AXMenuBarItem": return "menubar"
        case "AXMenuItem": return "menuitem"
        case "AXImage": return "image"
        case "AXRow": return "row"
        case "AXCell": return "cell"
        case "AXSheet": return "sheet"
        case "AXWindow": return "window"
        case "AXPopover": return "popover"
        case "AXDisclosureTriangle": return "disclosure"
        case "AXLink": return "link"
        case "AXTabGroup": return "tabs"
        case "AXRadioGroup": return "radiogroup"
        default:
            return role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
        }
    }

    private static let attributes = [
        "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXHelp", "AXIdentifier",
        "AXValue", "AXPosition", "AXSize", "AXEnabled", "AXChildren", "AXSelected",
    ]

    private static func string(_ value: AnyObject?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text }
        if CFGetTypeID(value) == AXValueGetTypeID() { return "" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "1" : "0" }
            return number.stringValue
        }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return "" }
        return String(String(describing: value).prefix(80))
    }

    private static func point(_ value: AnyObject?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var p = CGPoint.zero
        guard AXValueGetType(ax) == .cgPoint, AXValueGetValue(ax, .cgPoint, &p) else { return nil }
        return p
    }

    private static func size(_ value: AnyObject?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        var s = CGSize.zero
        guard AXValueGetType(ax) == .cgSize, AXValueGetValue(ax, .cgSize, &s) else { return nil }
        return s
    }

    private static func elements(_ value: AnyObject?) -> [AXUIElement] {
        guard let list = value as? [AnyObject] else { return [] }
        return list.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    private static func flag(_ value: AnyObject?, default fallback: Bool) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        return fallback
    }

    /// Breadth-first over the whole application. Menu-bar menus are entered only while
    /// open. Runs on the calling thread, which must not be the main thread.
    struct Result {
        var nodes: [DriverAXNode]
        var error: String?
        var ms: Double = 0
    }

    private static func walk(limit: Int, seconds: Double) -> Result {
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        let deadline = Date().addingTimeInterval(seconds)
        var nodes: [DriverAXNode] = []
        var queue: [(AXUIElement, Int, String, Bool)] = [(app, 0, "AXApplication", false)]
        var head = 0
        var firstError: String?
        var visited = 0
        while head < queue.count, visited < limit {
            if Date() > deadline {
                firstError = firstError ?? "stopped after \(seconds) s"
                break
            }
            let (element, depth, container, inMenuBar) = queue[head]
            head += 1
            visited += 1
            var raw: CFArray?
            let status = AXUIElementCopyMultipleAttributeValues(
                element, attributes as CFArray, AXCopyMultipleAttributeOptions(), &raw)
            guard status == .success, let values = raw as? [AnyObject],
                  values.count == attributes.count else {
                if firstError == nil {
                    firstError = "AX error \(status.rawValue)"
                        + (status == .apiDisabled ? " (accessibility not granted)" : "")
                }
                continue
            }
            let role = string(values[0])
            let subrole = string(values[1])
            var frame = CGRect.zero
            if let p = point(values[7]), let s = size(values[8]) {
                frame = CGRect(origin: p, size: s)
            }
            let selected = flag(values[11], default: false)
            if depth > 0 {
                nodes.append(DriverAXNode(
                    role: role, subrole: subrole, title: string(values[2]),
                    desc: string(values[3]), help: string(values[4]), ident: string(values[5]),
                    value: string(values[6]), enabled: flag(values[9], default: true),
                    quartz: frame, depth: depth, container: container, element: element))
            }
            let windowLike: Set<String> = ["AXWindow", "AXSheet", "AXPopover", "AXMenu",
                                           "AXDrawer", "AXDialog"]
            let here = windowLike.contains(role) ? role : container
            let menuBar = inMenuBar || role == "AXMenuBar"
            // A closed menu-bar menu is hundreds of items nobody can click.
            if role == "AXMenuBarItem" && !selected { continue }
            guard depth < 60 else { continue }
            for child in elements(values[10]) {
                queue.append((child, depth + 1, here, menuBar))
            }
        }
        return Result(nodes: nodes, error: nodes.isEmpty ? (firstError ?? "the tree is empty") : nil)
    }

    /// The tree, read off the main thread. The main actor awaits without blocking, so
    /// its run loop answers the requests.
    static func snapshot(limit: Int = 6000, seconds: Double = 10) async -> Result {
        let began = DriverClock.now()
        var result = await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
            let thread = Thread {
                continuation.resume(returning: walk(limit: limit, seconds: seconds))
            }
            thread.name = "lumen.driver.ax"
            thread.start()
        }
        result.ms = (DriverClock.now() - began) * 1000
        return result
    }

    /// Performs an accessibility action (`AXPress` by default) off the main thread.
    static func perform(_ action: String, on element: AXUIElement) async -> AXError {
        await withCheckedContinuation { (continuation: CheckedContinuation<AXError, Never>) in
            let thread = Thread {
                continuation.resume(returning: AXUIElementPerformAction(element, action as CFString))
            }
            thread.name = "lumen.driver.ax.action"
            thread.start()
        }
    }

    /// Nodes named `kind/label` (`kind` may be `*`), best match first: exact label, then
    /// any label equal ignoring case, then any label starting with it.
    static func find(kind: String, label: String, in nodes: [DriverAXNode]) -> [DriverAXNode] {
        let wanted = normal(label)
        let candidates = nodes.filter { node in
            guard node.quartz.width > 0, node.quartz.height > 0 else { return false }
            if kind == "*" || kind.isEmpty { return true }
            if node.kind == kind { return true }
            // Toggle and checkbox are one thing to a person.
            return (kind == "checkbox" || kind == "toggle")
                && (node.kind == "checkbox" || node.kind == "toggle")
        }
        let exact = candidates.filter { $0.label == label }
        if !exact.isEmpty { return exact }
        let equal = candidates.filter { node in
            node.labels.contains { text in normal(text) == wanted }
        }
        if !equal.isEmpty { return equal }
        return candidates.filter { node in
            node.labels.contains { text in normal(text).hasPrefix(wanted) }
        }
    }
}

#endif

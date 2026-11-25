// DriverReflect.swift
// State nobody wrote a getter for: a depth-limited reflection of the app's objects, the
// menu bar as AppKit holds it, and the text on screen as OCR reads it.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI
import Vision

enum DriverReflect {

    /// Any value as JSON-ready data. Structs and classes become objects of their stored
    /// properties down to `depth`; below that, a short description.
    static func value(_ any: Any, depth: Int, limit: Int = 24) -> Any {
        if let text = any as? String { return String(text.prefix(400)) }
        if let number = any as? NSNumber { return number }
        if let url = any as? URL { return url.lastPathComponent }
        if let date = any as? Date { return date.timeIntervalSince1970 }
        let mirror = Mirror(reflecting: any)
        let typeName = String(describing: type(of: any))
        if typeName.hasPrefix("Published<") {
            guard let inner = published(any, depth: 0) else { return typeName }
            return value(inner, depth: depth, limit: limit)
        }
        guard let style = mirror.displayStyle else {
            return String(String(describing: any).prefix(160))
        }
        switch style {
        case .optional:
            guard let child = mirror.children.first else { return NSNull() }
            return value(child.value, depth: depth, limit: limit)
        case .collection, .set:
            var out: [String: Any] = ["count": mirror.children.count]
            if depth > 0 {
                var items: [Any] = []
                for child in mirror.children.prefix(limit) {
                    items.append(value(child.value, depth: depth - 1, limit: limit))
                }
                out["items"] = items
            }
            return out
        case .dictionary:
            var out: [String: Any] = ["count": mirror.children.count]
            if depth > 0 {
                var entries: [String: Any] = [:]
                for child in mirror.children.prefix(limit) {
                    let pair = Array(Mirror(reflecting: child.value).children)
                    guard pair.count == 2 else { continue }
                    let key = value(pair[0].value, depth: 0, limit: limit)
                    entries[String(describing: key)] = value(pair[1].value, depth: depth - 1,
                                                             limit: limit)
                }
                out["entries"] = entries
            }
            return out
        case .enum:
            return String(String(describing: any).prefix(200))
        case .struct, .class, .tuple:
            if depth <= 0 {
                if style == .class { return typeName }
                return String(String(describing: any).prefix(160))
            }
            var out: [String: Any] = [:]
            for child in mirror.children {
                guard let label = child.label else { continue }
                let key = label.hasPrefix("_") ? String(label.dropFirst()) : label
                out[key] = value(child.value, depth: depth - 1, limit: limit)
            }
            return out
        default:
            return String(String(describing: any).prefix(160))
        }
    }

    /// The current value inside a `Published` wrapper, whichever storage it is using.
    private static func published(_ any: Any, depth: Int) -> Any? {
        guard depth < 6 else { return nil }
        for child in Mirror(reflecting: any).children {
            if child.label == "value" || child.label == "currentValue" { return child.value }
            if let found = published(child.value, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: Menus

    struct MenuEntry {
        let path: [String]
        let item: NSMenuItem
        let menu: NSMenu
    }

    @MainActor
    static func menuEntries() -> [MenuEntry] {
        var out: [MenuEntry] = []
        func walk(_ menu: NSMenu, _ path: [String]) {
            menu.update()
            for item in menu.items where !item.isSeparatorItem {
                let here = path + [item.title]
                out.append(MenuEntry(path: here, item: item, menu: menu))
                if let submenu = item.submenu { walk(submenu, here) }
            }
        }
        if let main = NSApp.mainMenu { walk(main, []) }
        return out
    }

    @MainActor
    static func menus() -> [[String: Any]] {
        menuEntries().filter { $0.item.submenu == nil }.map { entry in
            var keys = ""
            let flags = entry.item.keyEquivalentModifierMask
            if flags.contains(.control) { keys += "ctrl+" }
            if flags.contains(.option) { keys += "opt+" }
            if flags.contains(.shift) { keys += "shift+" }
            if flags.contains(.command) { keys += "cmd+" }
            let row: [String: Any] = [
                "path": entry.path.joined(separator: " > "),
                "enabled": entry.item.isEnabled,
                "checked": entry.item.state == .on,
                "key": entry.item.keyEquivalent.isEmpty ? "" : keys + entry.item.keyEquivalent,
            ]
            return row
        }
    }

    // MARK: Text on screen

    struct TextHit {
        let text: String
        /// Pixels in the image handed to `texts`, origin top-left.
        let rect: CGRect
    }

    /// OCR over a screenshot. Slow (around a second); small type is read at 2x.
    static func texts(in image: CGImage) -> [TextHit] {
        let factor = image.width < 2400 ? 2 : 1
        var source = image
        if factor > 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
           let context = CGContext(data: nil, width: image.width * factor,
                                   height: image.height * factor, bitsPerComponent: 8,
                                   bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * factor,
                                           height: image.height * factor))
            if let scaled = context.makeImage() { source = scaled }
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }
        var out: [TextHit] = []
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        for observation in observations {
            guard let best = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            out.append(TextHit(text: best.string,
                               rect: CGRect(x: box.minX * width, y: (1 - box.maxY) * height,
                                            width: box.width * width,
                                            height: box.height * height)))
        }
        return out.sorted { a, b in
            if abs(a.rect.minY - b.rect.minY) > 4 { return a.rect.minY < b.rect.minY }
            return a.rect.minX < b.rect.minX
        }
    }
}

extension DriverSession {

    /// The sections of the state dump that come from reflection. `expect` reads them
    /// under these same names: `app.autoAdvance`, `panel.workspace`, `loupe.beforeMode`.
    func reflectedState() -> [String: Any] {
        var out: [String: Any] = [:]
        out["app"] = DriverReflect.value(state, depth: 3)
        out["panel"] = DriverReflect.value(PanelLayout.shared.layout, depth: 2)
        out["loupe"] = DriverReflect.value(LoupeViewport.shared, depth: 2)
        out["heal"] = DriverReflect.value(HealTool.shared, depth: 2)
        out["crop"] = DriverReflect.value(CropTool.shared, depth: 2)
        out["brush"] = DriverReflect.value(MaskBrushStore.shared, depth: 2)
        out["info"] = DriverReflect.value(CaptureInfoDisplay.shared, depth: 2)
        out["history"] = DriverReflect.value(state.history, depth: 2, limit: 60)
        return out
    }

    static let reflectedPrefixes = ["app.", "panel.", "loupe.", "heal.", "crop.", "brush.",
                                    "info.", "history."]

    /// The XMP sidecar beside the selected photo, if one has been written.
    func sidecar() -> [String: Any] {
        guard let photo = state.primarySelection else { return ["exists": false] }
        let folder = photo.id.deletingLastPathComponent()
        let stem = photo.id.deletingPathExtension().lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        guard let name = names.first(where: {
            $0.lowercased().hasSuffix(".xmp") && $0.hasPrefix(stem)
        }) else { return ["exists": false] }
        let url = folder.appendingPathComponent(name)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let out: [String: Any] = ["exists": true, "name": name, "bytes": text.utf8.count,
                                  "text": String(text.prefix(20_000))]
        return out
    }

    /// Chooses a menu item through AppKit: the item's own action and enabled state,
    /// without the pointer. Reported as `via: menu`.
    func menu(_ step: DriverStep) async throws -> [String: Any] {
        var path = step.strings("path")
        if path.isEmpty, let joined = step.string("path") {
            path = joined.components(separatedBy: ">").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        guard !path.isEmpty else { throw DriverError("menu needs a path") }
        let entries = DriverReflect.menuEntries()
        guard let entry = entries.first(where: { $0.path == path })
                ?? entries.first(where: { candidate in
                    candidate.path.count == path.count
                        && zip(candidate.path, path).allSatisfy { $0.hasPrefix($1) }
                }) else {
            let tops = Set(entries.compactMap { $0.path.first }).sorted()
            throw DriverError("no menu item \(path.joined(separator: " > ")). Menus: "
                                  + tops.joined(separator: ", "))
        }
        let out: [String: Any] = ["via": "menu", "title": entry.item.title,
                                  "enabled": entry.item.isEnabled,
                                  "checked": entry.item.state == .on]
        guard entry.item.isEnabled else {
            if step.bool("allowDisabled") == true { return out }
            throw DriverError("menu item \(path.joined(separator: " > ")) is disabled")
        }
        let index = entry.menu.index(of: entry.item)
        entry.menu.performActionForItem(at: index)
        await sleep(step.double("after") ?? 0.15)
        return out
    }
}

#endif

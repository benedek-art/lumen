// DriverWindows.swift
// Every window of this process on screen (sheets, popovers, panels, alerts, menus), the
// conversions between their coordinates, and screenshots that composite them.
// All rectangles here are in main-window points: origin the main window's top-left.

#if os(macOS)

import AppKit
import CoreGraphics

struct DriverWindowInfo {
    let number: Int
    /// nil for a window AppKit does not list (an open menu, a remote panel's parts).
    let window: NSWindow?
    /// main sheet popover alert filePanel colors panel child menu tooltip other
    let role: String
    let title: String
    let frame: CGRect
    let level: Int
    let isKey: Bool

    func json(index: Int) -> [String: Any] {
        var row = DriverJSON.rect(frame)
        row["index"] = index
        row["number"] = number
        row["role"] = role
        row["title"] = title
        row["level"] = level
        row["key"] = isKey
        if let window { row["class"] = String(describing: type(of: window)) }
        return row
    }
}

enum DriverWindows {

    /// The primary display's height: Cocoa and Quartz screen y run in opposite directions
    /// from its edges.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Cocoa screen rectangle (origin bottom-left) to main-window points.
    static func fromCocoa(_ r: CGRect, main: NSWindow) -> CGRect {
        CGRect(x: r.minX - main.frame.minX, y: main.frame.maxY - r.maxY,
               width: r.width, height: r.height)
    }

    /// Quartz screen rectangle (origin top-left of the primary display) to main-window
    /// points. Accessibility and the window server use this one.
    static func fromQuartz(_ r: CGRect, main: NSWindow) -> CGRect {
        let top = primaryHeight - main.frame.maxY
        return CGRect(x: r.minX - main.frame.minX, y: r.minY - top,
                      width: r.width, height: r.height)
    }

    static func quartzFrame(of window: NSWindow) -> CGRect {
        CGRect(x: window.frame.minX, y: primaryHeight - window.frame.maxY,
               width: window.frame.width, height: window.frame.height)
    }

    static func role(of window: NSWindow?, main: NSWindow, layer: Int) -> String {
        guard let window else {
            if layer >= Int(CGWindowLevelForKey(.popUpMenuWindow)) { return "menu" }
            return "other"
        }
        if window === main { return "main" }
        let name = String(describing: type(of: window))
        if window is NSColorPanel { return "colors" }
        if window is NSSavePanel { return "filePanel" }
        if name.contains("Alert") { return "alert" }
        if window.isSheet { return "sheet" }
        if name.contains("Popover") { return "popover" }
        if name.contains("ToolTip") || name.contains("Tooltip") { return "tooltip" }
        if name.contains("Menu") { return "menu" }
        if window.parent != nil { return "child" }
        if window is NSPanel { return "panel" }
        return "other"
    }

    /// This process's windows on screen, front to back.
    static func list(main: NSWindow) -> [DriverWindowInfo] {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        var out: [DriverWindowInfo] = []
        var seen = Set<Int>()
        for row in info {
            guard (row[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == pid,
                  let number = (row[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            let alpha = (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01, quartz.width >= 4, quartz.height >= 4 else { continue }
            let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let window = NSApp.window(withWindowNumber: number)
            let kind = role(of: window, main: main, layer: layer)
            seen.insert(number)
            out.append(DriverWindowInfo(
                number: number, window: window, role: kind,
                title: window?.title ?? (row[kCGWindowName as String] as? String ?? ""),
                frame: fromQuartz(quartz, main: main), level: layer,
                isKey: window?.isKeyWindow ?? false))
        }
        // The main window even when the window server's list leaves it out.
        if !seen.contains(main.windowNumber) {
            out.append(DriverWindowInfo(number: main.windowNumber, window: main, role: "main",
                                        title: main.title,
                                        frame: CGRect(origin: .zero, size: main.frame.size),
                                        level: 0, isKey: main.isKeyWindow))
        }
        return out
    }

    // MARK: Screenshots

    /// The main window with every other window of this process that overlaps it drawn
    /// over it in their on-screen order, at the main window's size and scale. `extra`
    /// gets the windows that were drawn, and is empty when only the main window is up.
    static func composite(main: NSWindow, extra: inout [DriverWindowInfo]) -> CGImage? {
        extra = []
        guard let base = DriverCapture.windowList(windowNumber: main.windowNumber) else {
            return nil
        }
        let others = list(main: main).filter {
            $0.number != main.windowNumber && $0.role != "tooltip"
                && $0.frame.intersects(CGRect(origin: .zero, size: main.frame.size))
        }
        guard !others.isEmpty else { return base }
        let scale = CGFloat(base.width) / Swift.max(main.frame.width, 1)
        let width = base.width
        let height = base.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Back to front, so the frontmost lands last.
        for other in others.reversed() {
            guard let image = DriverCapture.windowList(windowNumber: other.number) else {
                continue
            }
            // The capture is the window's frame without its shadow; place it there.
            let w = CGFloat(image.width)
            let h = CGFloat(image.height)
            let x = other.frame.minX * scale
            let yTop = other.frame.minY * scale
            context.draw(image, in: CGRect(x: x, y: CGFloat(height) - yTop - h,
                                           width: w, height: h))
            extra.append(other)
        }
        return context.makeImage() ?? base
    }

    /// One window alone, for a window that reaches past the main window's edges.
    static func single(_ info: DriverWindowInfo) -> CGImage? {
        DriverCapture.windowList(windowNumber: info.number)
    }
}

#endif

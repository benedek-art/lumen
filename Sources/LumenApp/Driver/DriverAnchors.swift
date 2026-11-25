// DriverAnchors.swift
// Named screen rectangles the automation driver can aim at. See driver/README.md.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI

/// Frames reported by `.driverAnchor(_:)`, in SwiftUI global (window content) points.
/// Lock-protected so no caller needs an actor.
final class DriverAnchors {

    static let shared = DriverAnchors()
    private init() {}

    private struct Entry {
        let id: String
        var frame: CGRect
        var visible: Bool
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var nextToken = 0

    func makeToken() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextToken += 1
        return nextToken
    }

    func noteAnchor(id: String, token: Int, frame: CGRect) {
        lock.lock()
        defer { lock.unlock() }
        entries[token] = Entry(id: id, frame: frame, visible: true)
    }

    func hide(token: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries[token]?.visible = false
    }

    private func live() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { $0.visible && $0.frame.width > 0 && $0.frame.height > 0 }
    }

    private static func readingOrder(_ a: CGRect, _ b: CGRect) -> Bool {
        if abs(a.minY - b.minY) > 0.5 { return a.minY < b.minY }
        return a.minX < b.minX
    }

    /// Every live frame registered under `id`, top-to-bottom then left-to-right.
    func frames(id: String) -> [CGRect] {
        live().filter { $0.id == id }.map(\.frame).sorted(by: DriverAnchors.readingOrder)
    }

    /// Ids matching a `*`-suffixed prefix or an exact id.
    func ids(matching pattern: String) -> [String] {
        let all = Set(live().map(\.id))
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return all.filter { $0.hasPrefix(prefix) }.sorted()
        }
        return all.contains(pattern) ? [pattern] : []
    }

    func all() -> [(id: String, frame: CGRect)] {
        live().map { (id: $0.id, frame: $0.frame) }.sorted { a, b in
            if a.id != b.id { return a.id < b.id }
            return DriverAnchors.readingOrder(a.frame, b.frame)
        }
    }
}

private struct DriverAnchorModifier: ViewModifier {
    let id: String
    @State private var token: Int = DriverAnchors.shared.makeToken()

    func body(content: Content) -> some View {
        content
            .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        DriverAnchors.shared.noteAnchor(id: id, token: token,
                                                 frame: proxy.frame(in: .global))
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        DriverAnchors.shared.noteAnchor(id: id, token: token, frame: frame)
                    }
                    .onChange(of: id) { _, newID in
                        DriverAnchors.shared.noteAnchor(id: newID, token: token,
                                                 frame: proxy.frame(in: .global))
                    }
                    .onDisappear { DriverAnchors.shared.hide(token: token) }
            }
        )
    }
}

extension LumenSlider {
    /// `slider/<label>`; the track alone is the same id with `#track`.
    var driverID: String {
        "slider/" + SliderAccessibility.label(title: title, name: accessibilityName)
    }
}

extension View {
    /// Registers this view's frame under `id` while the driver is active; otherwise
    /// returns the view untouched.
    @ViewBuilder
    func driverAnchor(_ id: String) -> some View {
        if LumenDriver.isActive {
            modifier(DriverAnchorModifier(id: id))
        } else {
            self
        }
    }
}

#endif

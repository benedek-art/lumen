// DriverAnchors.swift
// Named screen rectangles the automation driver can aim at. See driver/README.md.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI

/// Frames reported by `.driverAnchor(_:)`, in SwiftUI global points of the window the
/// view is in (nil: the main window). Lock-protected so no caller needs an actor.
final class DriverAnchors {

    static let shared = DriverAnchors()
    private init() {}

    struct Entry {
        let id: String
        var frame: CGRect
        var visible: Bool
        weak var window: NSWindow?
        /// Inside a sheet or popover, whether or not its window is known yet.
        var presented = false
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

    func noteAnchor(id: String, token: Int, frame: CGRect, presented: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let window = entries[token]?.window
        entries[token] = Entry(id: id, frame: frame, visible: true, window: window,
                               presented: presented)
    }

    func noteWindow(token: Int, window: NSWindow?) {
        lock.lock()
        defer { lock.unlock() }
        if entries[token] == nil {
            entries[token] = Entry(id: "", frame: .zero, visible: false, window: window)
        } else {
            entries[token]?.window = window
        }
    }

    func hide(token: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries[token]?.visible = false
    }

    /// Every live entry, in no particular order.
    func live() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter {
            $0.visible && !$0.id.isEmpty && $0.frame.width > 0 && $0.frame.height > 0
        }
    }
}

/// Records which window an anchor inside a sheet or popover is in. Zero-sized, draws
/// nothing, takes no clicks.
private struct DriverWindowProbe: NSViewRepresentable {
    let token: Int

    final class ProbeView: NSView {
        var token = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DriverAnchors.shared.noteWindow(token: token, window: window)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(frame: .zero)
        view.token = token
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        if view.token != token {
            view.token = token
            DriverAnchors.shared.noteWindow(token: token, window: view.window)
        }
    }
}

private struct DriverAnchorModifier: ViewModifier {
    let id: String
    /// True inside a sheet or popover: only those anchors pay for a window probe.
    @Environment(\.isPresented) private var presented
    @State private var token: Int = DriverAnchors.shared.makeToken()

    func body(content: Content) -> some View {
        content
            .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        DriverAnchors.shared.noteAnchor(id: id, token: token,
                                                 frame: proxy.frame(in: .global),
                                                 presented: presented)
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        DriverAnchors.shared.noteAnchor(id: id, token: token, frame: frame,
                                                 presented: presented)
                    }
                    .onChange(of: id) { _, newID in
                        DriverAnchors.shared.noteAnchor(id: newID, token: token,
                                                 frame: proxy.frame(in: .global),
                                                 presented: presented)
                    }
                    .onDisappear { DriverAnchors.shared.hide(token: token) }
            }
        )
            .background {
                if presented {
                    DriverWindowProbe(token: token).frame(width: 0, height: 0)
                }
            }
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

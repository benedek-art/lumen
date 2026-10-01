#if os(macOS)
import AppKit
import Combine
import XCTest
@testable import LumenApp

/// F4-03: the mask panel's Add/Intersect title polled ⌥ and nothing re-bodied the panel
/// when ⌥ changed, so the title went stale. `ModifierKeys` is the change signal.
final class ModifierKeysTests: XCTestCase {
    func testOptionPublishesOnlyWhenItChanges() {
        let keys = ModifierKeys()
        var signals = 0
        let watcher = keys.objectWillChange.sink { signals += 1 }
        defer { watcher.cancel() }
        keys.update([.option])
        XCTAssertTrue(keys.optionHeld)
        XCTAssertEqual(signals, 1, "⌥ going down must invalidate observers")
        keys.update([.option, .shift])
        XCTAssertEqual(signals, 1, "⇧ alone must not re-body every observer")
        keys.update([])
        XCTAssertFalse(keys.optionHeld)
        XCTAssertEqual(signals, 2, "⌥ coming up must invalidate observers")
    }

    /// The wiring, which a unit test of the object cannot see: a monitor must feed it
    /// and the panel must observe it, or the object is a signal nobody sends or hears.
    func testTheMonitorFeedsItAndTheMaskPanelObservesIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func code(_ file: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent("Sources/LumenApp/\(file)"),
                       encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let keymap = try code("Keymap.swift")
        XCTAssertTrue(keymap.contains("matching: [.flagsChanged]"))
        XCTAssertTrue(keymap.contains("ModifierKeys.shared.update(event.modifierFlags)"))
        let panel = try code("MaskPanel.swift")
        XCTAssertTrue(panel.contains("@ObservedObject private var modifiers: ModifierKeys = ModifierKeys.shared"))
    }
}
#endif

// PointColorPickTests.swift
// The point-colour eyedropper cannot arm with no photograph (B3-09).
//
// The mixer's eyedropper pill was `.disabled(state.primarySelection == nil)`; the
// point-colour one was not, so with nothing selected it armed a pick, wrote "Click the
// colour to work on." to the status bar and opened a loupe with nothing on it — and the
// pick could never resolve. `ColorPanel` compiles on macOS only, so this reads it as
// text, comments stripped.

import XCTest

final class PointColorPickTests: XCTestCase {

    private func colorPanel() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/ColorPanel.swift")
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    func testTheSwatchEyedropperIsDeadWithNoPhotograph() throws {
        let source = try colorPanel()
        guard let start = source.range(of: "private func addSwatch()") else {
            return XCTFail("ColorPanel.addSwatch moved")
        }
        let body = source[start.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("state.primarySelection != nil"),
                      "addSwatch arms a pick with no photograph to resolve it on")

        // Every eyedropper's enabled state asks the same question the mixer's does.
        let disabled = source.components(separatedBy: ".disabled(").dropFirst()
            .map { String($0.prefix(160)) }
        let pickers = disabled.filter { $0.contains("pickIsArmed") }
        XCTAssertEqual(pickers.count, 1, "expected one point-colour eyedropper")
        for expression in pickers {
            XCTAssertTrue(expression.contains("state.primarySelection == nil"),
                          "the point-colour eyedropper is live with no photograph: "
                              + expression)
        }
    }
}

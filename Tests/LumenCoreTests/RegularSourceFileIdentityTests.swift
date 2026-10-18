import Foundation
import XCTest
@testable import LumenCore

final class RegularSourceFileIdentityTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-regular-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.raw")
        try Data([1, 2, 3, 4]).write(to: original)
        try body(root, original)
    }

    func testRegularOriginalAndSymlinkUseTheSameGeneration() throws {
        try fixture { root, original in
            let link = root.appendingPathComponent("linked.raw")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            let expected = try XCTUnwrap(SourceFileIdentity.read(original))
            XCTAssertEqual(SourceFileIdentity.readRegularFile(original), expected)
            XCTAssertEqual(SourceFileIdentity.readRegularFile(link), expected)
            XCTAssertEqual(SourceFileIdentity.read(link), expected)
        }
    }

    func testDirectoriesDevicesAndMissingPlaceholdersDoNotBindImplicitly() throws {
        try fixture { root, _ in
            XCTAssertNotNil(SourceFileIdentity.read(root), "existing read still accepts a directory")
            XCTAssertNil(SourceFileIdentity.readRegularFile(root))
            let device = URL(fileURLWithPath: "/dev/null")
            XCTAssertNotNil(SourceFileIdentity.read(device), "existing read still accepts the device")
            XCTAssertNil(SourceFileIdentity.readRegularFile(device))
            let missing = root.appendingPathComponent("missing.raw")
            XCTAssertNil(SourceFileIdentity.read(missing))
            XCTAssertNil(SourceFileIdentity.readRegularFile(missing))
            XCTAssertNil(SourceFileIdentity.readRegularFile(URL(fileURLWithPath: "/dev/null/placeholder")))
        }
    }

    func testReplacementStillChangesGenerationAndBrokenSymlinkIsUnbound() throws {
        try fixture { root, original in
            let link = root.appendingPathComponent("linked.raw")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            let expected = try XCTUnwrap(SourceFileIdentity.readRegularFile(original))
            try Data([5, 6, 7, 8]).write(to: original, options: .atomic)
            let replacement = try XCTUnwrap(SourceFileIdentity.readRegularFile(original))
            XCTAssertFalse(SourceFileIdentity.sameGeneration(stored: expected.token, current: replacement.token))
            XCTAssertEqual(SourceFileIdentity.readRegularFile(link), replacement)
            try FileManager.default.removeItem(at: original)
            XCTAssertNil(SourceFileIdentity.readRegularFile(original))
            XCTAssertNil(SourceFileIdentity.readRegularFile(link))
        }
    }
}

#if os(macOS)
import Foundation
import XCTest
@testable import LumenApp

final class FolderScanFileKindTests: XCTestCase {
    func testImageExtensionDirectoriesAreTraversedButNeverReturnedAsPhotos() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lumen-scan-kind-" + UUID().uuidString)
        let directory = root.appendingPathComponent("album.jpg", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let nested = directory.appendingPathComponent("inside.PNG")
        let regular = root.appendingPathComponent("photo.jpg")
        try Data([1]).write(to: nested)
        try Data([2]).write(to: regular)
        try Data([3]).write(to: root.appendingPathComponent("notes.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("missing.jpg"),
                                  withDestinationURL: root.appendingPathComponent("absent"))
        let found = AppState.scan(url: root, extensions: ["jpg", "png"])
        XCTAssertEqual(Set(found), Set([nested, regular]))
        XCTAssertFalse(found.contains(directory))
    }
}
#endif

// ResponsivenessGridTests.swift — the contact sheet's thumbnail path under scrolling.
//
// Two halves. The behavioural half drives a real `ThumbnailLoader` against a PNG in a
// scratch directory: a prefetch must leave the decode joinable and the result cached
// under the key the cell will ask for, and a request whose task is already cancelled —
// a cell that scrolled away before its slot came up — must come back empty rather than
// paying for a decode. The textual half pins two properties that have no API to call:
// a cell's load does not assign pixels after its task was superseded, and the loader
// builds one key (one `stat` on the main actor) per question rather than two.
#if os(macOS)
import CoreGraphics
import ImageIO
import XCTest
import LumenCore
@testable import LumenApp

final class ResponsivenessGridTests: XCTestCase {

    // MARK: Fixtures

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-grid-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let target = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(target, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(target))
    }

    // MARK: Behaviour

    /// The ring's keys and the cell's keys must be the same keys: a prefetch whose
    /// decode a visible cell cannot join, or whose result lands under a key the cell
    /// never asks for, is work paid twice.
    @MainActor func testAPrefetchedDecodeIsJoinedAndThenServedFromMemory() async throws {
        let root = try scratch()
        let anchor = root.appendingPathComponent("frame-0.png")
        let url = root.appendingPathComponent("frame-1.png")
        try writePNG(width: 40, height: 30, to: anchor)
        try writePNG(width: 40, height: 30, to: url)
        let loader = ThumbnailLoader()
        // The cursor is on frame 0; frame 1 is in the ring's ahead half, so the only
        // thing that can have put a decode of it in flight is the prefetch.
        let photos = [PhotoItem(id: anchor), PhotoItem(id: url)]
        loader.prefetch(around: anchor, in: photos, revision: 1, size: 256, surface: .grid)

        let joined = await loader.image(for: url, size: 256)
        XCTAssertNotNil(joined, "the prefetched decode never produced pixels")
        let served = loader.thumbnail(for: url, size: 256)
        XCTAssertNotNil(served, "the prefetch's result is not under the cell's key")
        XCTAssertTrue(joined === served,
                      "the cell's synchronous question decoded again instead of reusing")
    }

    /// A cell that scrolled away before its task ran asks for nothing.
    @MainActor func testACancelledRequestReturnsNothing() async throws {
        let url = try scratch().appendingPathComponent("frame.png")
        try writePNG(width: 40, height: 30, to: url)
        let loader = ThumbnailLoader()
        // The test runs on the main actor, so this task cannot start until the
        // `await` below — by which point it has already been cancelled.
        let task = Task { @MainActor in
            await loader.image(for: url, size: 256) == nil
        }
        task.cancel()
        let cameBackEmpty = await task.value
        XCTAssertTrue(cameBackEmpty, "a cancelled request still waited for a decode")
        XCTAssertNil(loader.thumbnail(for: url, size: 256),
                     "a cancelled request still scheduled a decode that landed")
    }

    // MARK: Text

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    private func code(_ name: String) throws -> String {
        let url = Self.repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("LumenApp", isDirectory: true)
            .appendingPathComponent(name)
        return blankingComments(in: try String(contentsOf: url, encoding: .utf8))
    }

    /// The text from `marker` to the next `func ` declaration (or the end).
    private func section(after marker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: marker),
                                  "\(marker) is gone").upperBound
        let rest = source[start...]
        let end = rest.range(of: "func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// A superseded `.task(id:)` — the slider crossed a bucket, the source was replaced
    /// — can resume with the OLD request's pixels when the decode finished before the
    /// cancellation's `abandon` reached the queue. Assigning them then puts a stale
    /// image over the one the newer request already showed.
    func testACellDoesNotAssignPixelsAfterItsTaskWasSuperseded() throws {
        let body = try section(after: "func loadThumbnail()", in: try code("GridView.swift"))
        let awaited = try XCTUnwrap(body.range(of: "await loader.image(for:"),
                                  "the cell no longer awaits the loader")
        let tail = body[awaited.upperBound...]
        let guardRange = try XCTUnwrap(tail.range(of: "Task.isCancelled"),
                                       "a cell assigns its awaited pixels without "
                                           + "checking that its task is still current")
        let assign = try XCTUnwrap(tail.range(of: "image = loaded"))
        XCTAssertTrue(guardRange.lowerBound < assign.lowerBound,
                      "the cancellation check must come before the assignment")
    }

    /// Building a key `stat`s the file on the main actor. One question, one key.
    func testTheLoaderBuildsOneKeyPerQuestion() throws {
        let source = try code("ThumbnailLoader.swift")
        let image = try section(after: "func image(for url: URL", in: source)
        XCTAssertEqual(image.components(separatedBy: "Key(url:").count - 1, 1,
                       "image(for:size:) builds its key more than once")
        XCTAssertFalse(image.contains("thumbnail(for:"),
                       "image(for:size:) re-enters thumbnail(for:size:), which builds "
                           + "a second key for the same question")
    }
}

#endif

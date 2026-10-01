import Foundation
import XCTest
@testable import LumenCore

/// R-2 on Linux: a RAW decode is refused, or it is a usable picture.
///
/// The RAW corpus lane found the third state on real files: the Sigma X3F (1116) and
/// the 512-byte stub both opened with native size 0 x 0 and decoded to an image whose
/// extent was (inf, inf, 0, 0), i.e. `CGRect.null`, and `AppleRawSource.decode` handed
/// it on because it only checked for nil. The macOS integration check is
/// `RawCorpusTests.testEveryFileEitherDecodesCleanlyOrRefusesCleanly` and
/// `testATruncatedFileIsRefusedRatherThanHalfDecoded`.
final class RawDecodeAcceptanceTests: XCTestCase {

    private let native = CGSize(width: 4368, height: 2912)

    /// Exactly what the lane logged for both files: extent (inf, inf, 0, 0), N=0x0.
    func testTheCorpusThirdStateIsRefused() {
        let logged = CGRect(x: CGFloat.infinity, y: CGFloat.infinity, width: 0, height: 0)
        XCTAssertFalse(RawDecodeAcceptance.accepts(extent: logged, nativeSize: .zero))
        XCTAssertFalse(RawDecodeAcceptance.accepts(extent: .null, nativeSize: .zero))
        // Either half alone is enough to refuse.
        XCTAssertFalse(RawDecodeAcceptance.accepts(extent: .null, nativeSize: native))
        XCTAssertFalse(RawDecodeAcceptance.accepts(
            extent: CGRect(x: 0, y: 0, width: 4368, height: 2912), nativeSize: .zero))
    }

    func testEveryUnusableExtentIsRefused() {
        let unusable: [(String, CGRect)] = [
            ("null", .null),
            ("infinite", .infinite),
            ("zero", .zero),
            ("zero width", CGRect(x: 0, y: 0, width: 0, height: 100)),
            ("zero height", CGRect(x: 0, y: 0, width: 100, height: 0)),
            ("sub-pixel", CGRect(x: 0, y: 0, width: 0.5, height: 100)),
            ("NaN width", CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)),
            ("NaN origin", CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)),
            ("infinite width", CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)),
            ("huge origin", CGRect(x: -CGFloat.infinity, y: 0, width: 100, height: 100)),
        ]
        for (name, extent) in unusable {
            XCTAssertFalse(RawDecodeAcceptance.accepts(extent: extent, nativeSize: native),
                           name)
        }
    }

    func testANativeSizeTheSourceCannotStateIsRefused() {
        let extent = CGRect(x: 0, y: 0, width: 1024, height: 683)
        for size in [CGSize.zero, CGSize(width: 0, height: 2912),
                     CGSize(width: 4368, height: 0),
                     CGSize(width: CGFloat.nan, height: 2912),
                     CGSize(width: CGFloat.infinity, height: 2912)] {
            XCTAssertFalse(RawDecodeAcceptance.accepts(extent: extent, nativeSize: size),
                           "\(size)")
        }
    }

    /// Every file the lane decodes must still pass: a scaled preview, a native decode,
    /// a nonzero origin (Core Image extents need not start at zero), and the IIQ whose
    /// whole native frame is 296 x 220.
    func testRealDecodesAreAccepted() {
        XCTAssertTrue(RawDecodeAcceptance.accepts(
            extent: CGRect(x: 0, y: 0, width: 1024, height: 683), nativeSize: native))
        XCTAssertTrue(RawDecodeAcceptance.accepts(
            extent: CGRect(x: 0, y: 0, width: 4368, height: 2912), nativeSize: native))
        XCTAssertTrue(RawDecodeAcceptance.accepts(
            extent: CGRect(x: -12, y: 8, width: 1024, height: 683), nativeSize: native))
        XCTAssertTrue(RawDecodeAcceptance.accepts(
            extent: CGRect(x: 0, y: 0, width: 296, height: 220),
            nativeSize: CGSize(width: 296, height: 220)))
        XCTAssertTrue(RawDecodeAcceptance.accepts(
            extent: CGRect(x: 0, y: 0, width: 1, height: 1),
            nativeSize: CGSize(width: 1, height: 1)))
    }

    /// The predicate only protects the graph if the decode path calls it on the image
    /// it is about to cache and return. Code only: comments are stripped first.
    func testTheRawDecodeGoesThroughTheAcceptanceRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LumenCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <package>
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/LumenPipeline/AppleRawSource.swift"), encoding: .utf8)
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[..<range.lowerBound]
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let guardCall = "guardletimageelse{returnnil}"
            + "guardRawDecodeAcceptance.accepts(extent:image.extent,"
            + "nativeSize:originalNativeSize)else{returnnil}"
        XCTAssertTrue(code.contains(guardCall),
                      "AppleRawSource.decode must refuse, right after its nil check and "
                      + "before caching, any image RawDecodeAcceptance does not accept")
    }
}

import Foundation
import XCTest
@testable import LumenCore

/// AI-01's residual gap: the RAW9 colour boundary was chosen by `rawValue == "9"`.
///
/// Apple spells its DNG decoders with a suffix (`CIRAWDecoderVersion.version8DNG` is
/// "8.dng"), and every other decoder comparison in `AppleRawSource` already normalized to
/// digits. A RAW9 DNG decoder named "9.dng" would have skipped the boundary and been
/// evaluated lazily in the Rec2020 working context: the cyan decode AI-01 reproduced.
///
/// The predicate is LumenCore so this runs on Linux. The macOS twin, through the
/// `CIRAWDecoderVersion` type itself, is `RawDecodeBoundaryTests`.
final class RawDecoderNumberTests: XCTestCase {

    func testTheRaw9BoundaryIsChosenByDecoderNumberInEverySpelling() {
        XCTAssertTrue(RawParams.needsRaw9ColourBoundary("9"))
        XCTAssertTrue(RawParams.needsRaw9ColourBoundary("9.dng"),
                      "A DNG RAW9 decoder must get the colour boundary too")
        for other in ["8", "8.dng", "7", "7.dng", "6.dng", "19", "None", ""] {
            XCTAssertFalse(RawParams.needsRaw9ColourBoundary(other), other)
        }
    }

    /// The pin a recipe stores is this number. It must not change meaning for any
    /// identifier Apple has shipped, or every pinned recipe would resolve differently.
    func testDecoderNumbersMatchThePinsRecipesAlreadyCarry() {
        let cases: [(String, Int?)] = [
            ("5", 5), ("6", 6), ("7", 7), ("8", 8),
            ("6.dng", 6), ("7.dng", 7), ("8.dng", 8), ("9", 9), ("9.dng", 9),
            ("None", nil), ("", nil),
        ]
        for (identifier, number) in cases {
            XCTAssertEqual(RawParams.decoderNumber(identifier), number, identifier)
        }
    }

    /// The RAW corpus lane's 2767 (Phase One P65+ IIQ): CIRAWFilter reported default ""
    /// and supported ["None"], decoded the container's 296 x 220 RGB thumbnail, and Lumen
    /// accepted it with a nil decoder pin. Only an identifier carrying a decoder number
    /// is a RAW decode, and AppleRawSource's init must refuse through this predicate.
    func testOnlyANumberedDecoderIsARawDecode() throws {
        for identifier in ["5", "6", "7", "8", "9", "6.dng", "8.dng", "9.dng"] {
            XCTAssertTrue(RawParams.selectsRawDecoder(identifier), identifier)
        }
        for identifier in ["", "None", "dng"] {
            XCTAssertFalse(RawParams.selectsRawDecoder(identifier), identifier)
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/LumenPipeline/AppleRawSource.swift"), encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let range = line.range(of: "//") else { return line }
                return line[..<range.lowerBound]
            }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains(
            "guard RawParams.selectsRawDecoder(filter.decoderVersion.rawValue) else {\n"
            + "            throw RawSourceError.undecodable(url)"),
            "AppleRawSource.init must refuse a file for which CIRAWFilter selected no decoder")
    }

    /// The helper only helps if the decode path and the private RAW tests USE it. A
    /// literal spelling comparison anywhere in either file is the defect coming back.
    /// Code only: comments are stripped first, since the fix's own explanation quotes
    /// the old comparison.
    func testNoDecoderComparisonBypassesTheSharedNormalization() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LumenCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <package>
        for path in ["Sources/LumenPipeline/AppleRawSource.swift",
                     "Tests/LumenPipelineTests/AuditRawAccuracyTests.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    guard let range = line.range(of: "//") else { return line }
                    return line[..<range.lowerBound]
                }
                .joined(separator: "\n")
            XCTAssertFalse(code.isEmpty, path)
            for forbidden in ["rawValue == \"", "rawValue != \"", "filter(\\.isNumber)"] {
                XCTAssertFalse(code.contains(forbidden),
                               "\(path) compares decoder identifiers with `\(forbidden)`; "
                               + "use RawParams.decoderNumber / needsRaw9ColourBoundary")
            }
        }
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/LumenPipeline/AppleRawSource.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("if Self.needsRaw9Boundary(filter.decoderVersion) {"),
                      "The decode's boundary branch must select RAW9 through the shared predicate")
    }
}

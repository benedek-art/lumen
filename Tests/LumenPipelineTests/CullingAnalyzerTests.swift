// CullingAnalyzerTests.swift
// The platform half of the culling pass: a file in, a frame score out. macOS only; the
// arithmetic itself is pinned on Linux by `CullingAssistTests`.

#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenPipeline

final class CullingAnalyzerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-culling-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A 1800 x 1200 JPEG of a checker-and-discs scene, optionally blurred by drawing it
    /// at a quarter size and scaling it back up with interpolation.
    private func writeJPEG(named name: String, soft: Bool) throws -> URL {
        let width = 1800, height = 1200
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        func draw(_ w: Int, _ h: Int) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let cell = CGFloat(w) / 60
            for row in 0..<40 {
                for column in 0..<60 where (row + column) % 2 == 0 {
                    context.setFillColor(CGColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1))
                    context.fill(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                        width: cell, height: cell))
                }
            }
            return try XCTUnwrap(context.makeImage())
        }
        var image = try draw(width, height)
        if soft {
            let small = try draw(width / 6, height / 6)
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .high
            context.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
            image = try XCTUnwrap(context.makeImage())
        }
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.95]
                                       as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testAJPEGIsMeasuredAtTheAnalysisEdge() throws {
        let url = try writeJPEG(named: "sharp.jpg", soft: false)
        let result = CullingAnalyzer.analyze(url: url, photoID: 7, detectFaces: false)
        XCTAssertEqual(result.score.photoID, 7)
        XCTAssertNotNil(result.score.sharpness)
        XCTAssertNotNil(result.score.perceptualHash)
        XCTAssertEqual(result.score.analysedLongEdge, SharpnessScorer.analysisLongEdge)
        XCTAssertNil(result.faces, "the face pass was not asked for")
    }

    /// The same scene, soft, scores lower and hashes close — a burst's blurred frame.
    func testASoftCopyScoresLowerAndHashesAsTheSamePicture() throws {
        let sharp = CullingAnalyzer.analyze(url: try writeJPEG(named: "a.jpg", soft: false),
                                            photoID: 1, detectFaces: false).score
        let soft = CullingAnalyzer.analyze(url: try writeJPEG(named: "b.jpg", soft: true),
                                           photoID: 2, detectFaces: false).score
        XCTAssertGreaterThan(try XCTUnwrap(sharp.sharpness), try XCTUnwrap(soft.sharpness))
        XCTAssertLessThanOrEqual(PerceptualHash.distance(try XCTUnwrap(sharp.perceptualHash),
                                                         try XCTUnwrap(soft.perceptualHash)),
                                 BurstGrouper.maxHashDistance)
    }

    /// A file with no decodable preview still gets a row — with nothing measured — so
    /// the backlog stops offering it and no chip reads it as soft.
    func testAFileWithNoPreviewGetsAnEmptyRowRatherThanNone() throws {
        let url = root.appendingPathComponent("broken.arw")
        try Data("not a raw file".utf8).write(to: url)
        let result = CullingAnalyzer.analyze(url: url, photoID: 3, detectFaces: true)
        XCTAssertNil(result.score.sharpness)
        XCTAssertNil(result.score.perceptualHash)
        XCTAssertNil(result.faces)
    }

    /// The face pass never invents a face on a checkerboard. Vision may be unable to run
    /// at all on a headless CI host, in which case `faces` is nil ("did not look"), which
    /// is the documented degradation — what must never happen is a face that is not there.
    func testTheFacePassInventsNoFaceOnAFacelessPicture() throws {
        let result = CullingAnalyzer.analyze(url: try writeJPEG(named: "c.jpg", soft: false),
                                             photoID: 4, detectFaces: true)
        XCTAssertEqual(result.faces?.count ?? 0, 0)
        XCTAssertNotNil(result.score.sharpness, "the face pass must not cost the frame score")
    }
}
#endif

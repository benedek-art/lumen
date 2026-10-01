// CullingAnalyzer.swift
// The platform half of the culling pass (docs/10 §10.6): pixels in, evidence out.
//
// LumenCore owns every number — `SharpnessScorer`, `PerceptualHash`, `EyeOpenness` — and
// pins them on Linux. This file only does what needs Apple frameworks: decode the
// camera's embedded preview through ImageIO (never a demosaic: the browse path's Law 14
// applies to the analysis pass too), turn it into a luma `Plane`, and, where Vision is
// present, find faces and their eye landmarks.
//
// It is a pure function of a file. No state, no actor, no queue: the caller decides
// where it runs (`CatalogService` runs it on a background-QoS lane, one photograph at a
// time, never on the main actor and never on the catalog's serial queue).

#if os(macOS)

import CoreGraphics
import Foundation
import ImageIO
import LumenCore
#if canImport(Vision)
import Vision
#endif

public enum CullingAnalyzer {

    /// One frame's evidence.
    public struct Result: Sendable {
        public var score: FrameScoreRow
        /// nil when the face pass did not run (Vision unavailable, the request failed,
        /// or the caller did not ask) — distinct from `[]`, "looked and found nobody".
        public var faces: [FaceEvidenceRow]?
    }

    /// The preview is decoded with this long edge, half again the analysis edge, so the
    /// area resample down to `SharpnessScorer.analysisLongEdge` has pixels to average
    /// and the scale every frame is read at is the same whatever the camera embedded.
    public static let decodeLongEdge = SharpnessScorer.analysisLongEdge * 3 / 2

    /// Measure one file. Always returns a row: a frame with no usable preview gets a
    /// row with no sharpness, so the backlog query stops offering it and the filters
    /// read it as "not measured" rather than as soft.
    public static func analyze(url: URL, photoID: Int64, detectFaces: Bool) -> Result {
        guard let image = decodePreview(url: url), let plane = luma(of: image) else {
            return Result(score: FrameScoreRow(photoID: photoID, sharpness: nil, noise: nil,
                                               perceptualHash: nil, analysedLongEdge: nil),
                          faces: nil)
        }
        let measurement = SharpnessScorer.measure(plane)
        let row = FrameScoreRow(photoID: photoID, sharpness: measurement.score,
                                noise: measurement.noiseSigma,
                                perceptualHash: PerceptualHash.hash(plane),
                                analysedLongEdge: measurement.analysedLongEdge)
        return Result(score: row,
                      faces: detectFaces ? faceEvidence(image: image, plane: plane) : nil)
    }

    // MARK: Decode

    /// The embedded preview, oriented, at most `decodeLongEdge` on its long side. For a
    /// raw file with no embedded preview this is nil — the same answer the grid gets,
    /// and for the same reason.
    static func decodePreview(url: URL) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      sourceOptions as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: PhotoFormats.isRendered(url),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeLongEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Rec. 709 luma of the preview, drawn once into an sRGB 8-bit buffer so every
    /// source pixel format arrives in one known byte order.
    static func luma(of image: CGImage) -> Plane? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return Plane(rgba8: bytes, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    // MARK: Faces

    /// Per-face evidence: where, how open the eyes read, how sharp the face is, and
    /// Vision's capture-quality score. nil when Vision is not available or fails.
    static func faceEvidence(image: CGImage, plane: Plane) -> [FaceEvidenceRow]? {
        #if canImport(Vision)
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        let landmarks = VNDetectFaceLandmarksRequest()
        do {
            try handler.perform([landmarks])
        } catch {
            return nil
        }
        let faces = landmarks.results ?? []
        guard !faces.isEmpty else { return [] }

        // Capture quality for the same faces, matched by position in the list only when
        // Vision hands back the same number — a mismatch leaves the column NULL rather
        // than attaching one person's score to another.
        var qualities: [Double?] = Array(repeating: nil, count: faces.count)
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = faces
        if (try? handler.perform([quality])) != nil,
           let scored = quality.results, scored.count == faces.count {
            qualities = scored.map { $0.faceCaptureQuality.map { Double($0) } }
        }

        let size = CGSize(width: image.width, height: image.height)
        return faces.enumerated().map { index, face in
            // Vision's box is normalised with its origin at the BOTTOM left; the
            // catalog's (and `Plane`'s) is the top left.
            let box = face.boundingBox
            let rect = NormalizedRect(x: Double(box.minX), y: Double(1 - box.maxY),
                                      width: Double(box.width), height: Double(box.height))
            // Points in IMAGE pixels, not the face box's normalised space, whose x and
            // y scales differ — the axis ratio would otherwise depend on the box shape.
            func openness(_ region: VNFaceLandmarkRegion2D?) -> Double? {
                guard let points = region?.pointsInImage(imageSize: size),
                      let ratio = EyeOpenness.axisRatio(
                        of: points.map { (x: Double($0.x), y: Double($0.y)) })
                else { return nil }
                return EyeOpenness.openness(aspectRatio: ratio)
            }
            let eyes = EyeOpenness.faceOpenness(left: openness(face.landmarks?.leftEye),
                                                right: openness(face.landmarks?.rightEye))
            let focus = SharpnessScorer.measure(plane, region: rect)?.score
            return FaceEvidenceRow(rect: rect, eyesOpen: eyes, focus: focus,
                                   captureQuality: qualities[index])
        }
        #else
        return nil
        #endif
    }
}

#endif

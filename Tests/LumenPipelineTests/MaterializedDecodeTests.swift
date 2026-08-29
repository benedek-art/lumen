// The decode is materialized now (see `DecodeMaterializer`), and materializing is a
// round trip through a pixel buffer. This is the test that the round trip does not
// quietly cost the photograph its highlights.
//
// WHY THIS IS THE TEST WORTH HAVING. The RAW stage's whole contract is that what leaves
// it is scene-referred: Apple's tone curve, shadow boost and gamut mapping are switched
// off so that a 4.0 in a specular highlight reaches Lumen's own display transform intact
// (docs/14 §1.1). Materializing through an 8-bit surface, or through a non-extended
// colour space, clamps that to 1.0 — and NOTHING downstream would fail. The goldens use
// a stub source and never touch this path. The GPU/reference parity tests compare two
// renderers that would both be reading the same clamped input. The picture would simply
// lose its highlights on every photograph, and the loss would look like the photograph.
//
// So the assertions here are deliberately about the values a photograph carries and a
// display cannot: above 1.0, and below 0.0.
#if os(macOS)
import CoreImage
import XCTest
@testable import LumenPipeline

final class MaterializedDecodeTests: XCTestCase {

    /// Read one pixel back through the same working space it was written in.
    private func sample(_ image: CIImage, at point: CGPoint) -> [Float]? {
        guard let working = DecodeMaterializer.workingSpace else { return nil }
        var out = [Float](repeating: 0, count: 4)
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        out.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            DecodeMaterializer.context.render(
                image, toBitmap: base, rowBytes: 16, bounds: rect,
                format: .RGBAf, colorSpace: working)
        }
        return out
    }

    /// One known colour in the working space. `CIColor`'s colour-space initializer is
    /// failable, so the unwrap lives here rather than at six call sites.
    private func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) throws -> CIColor {
        let working = try XCTUnwrap(DecodeMaterializer.workingSpace)
        return try XCTUnwrap(CIColor(red: r, green: g, blue: b, alpha: 1,
                                     colorSpace: working))
    }

    /// A flat image of one known colour, so the assertion is about the round trip and
    /// not about interpolation.
    private func flat(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat,
                      size: CGFloat = 8) throws -> CIImage {
        CIImage(color: try colour(r, g, b))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    }

    func testAHighlightAboveDisplayWhiteSurvivesMaterialization() throws {
        // 4.0 is two stops above display white — an ordinary specular highlight in a
        // scene-referred RAW, and exactly what Apple's stages are turned off to keep.
        let input = try flat(4.0, 2.5, 1.75)
        let out = try XCTUnwrap(DecodeMaterializer.materialize(input),
                                "an 8×8 image is far inside the size limit")
        let read = try XCTUnwrap(sample(out.image, at: CGPoint(x: 4, y: 4)))

        // Half float carries ~3 decimal digits; the tolerance is precision, not policy.
        XCTAssertEqual(Double(read[0]), 4.0, accuracy: 0.01,
                       "the red highlight came back as \(read[0]) — if it is 1.0 the "
                           + "materialization clamped, and every photograph in the app "
                           + "has silently lost its highlights")
        XCTAssertEqual(Double(read[1]), 2.5, accuracy: 0.01)
        XCTAssertEqual(Double(read[2]), 1.75, accuracy: 0.01)
    }

    /// The other end of the extended range. A linear working space legitimately carries
    /// negatives — they are what a colour outside the encoding gamut looks like before
    /// the gamut stage decides what to do about it — and clamping them at zero would
    /// change which colours the soft clip has to work on.
    func testAValueBelowZeroSurvivesMaterialization() throws {
        let input = try flat(-0.25, 0.5, 1.0)
        let out = try XCTUnwrap(DecodeMaterializer.materialize(input))
        let read = try XCTUnwrap(sample(out.image, at: CGPoint(x: 4, y: 4)))
        XCTAssertEqual(Double(read[0]), -0.25, accuracy: 0.01,
                       "a negative came back as \(read[0]); the buffer or the colour "
                           + "space is not extended")
    }

    /// The geometry has to survive too: the graph downstream crops to rectangles
    /// expressed in the decode's own coordinates, so an image that comes back at a
    /// different origin or size silently shifts every crop and every mask.
    func testTheExtentIsPreserved() throws {
        let input = try flat(0.5, 0.5, 0.5, size: 32)
            .transformed(by: CGAffineTransform(translationX: 7, y: 11))
        let out = try XCTUnwrap(DecodeMaterializer.materialize(input))
        XCTAssertEqual(out.image.extent.origin.x, 7, accuracy: 0.5)
        XCTAssertEqual(out.image.extent.origin.y, 11, accuracy: 0.5)
        XCTAssertEqual(out.image.extent.width, 32, accuracy: 0.5)
        XCTAssertEqual(out.image.extent.height, 32, accuracy: 0.5)
    }

    /// What it reports having allocated must be what it actually allocated, because the
    /// cache's byte budget is spent against this number and nothing else checks it.
    func testTheReportedWeightIsTheBufferItAllocated() throws {
        let out = try XCTUnwrap(DecodeMaterializer.materialize(
            try flat(0.2, 0.2, 0.2, size: 64)))
        XCTAssertEqual(out.bytes, 64 * 64 * 8,
                       "four half-float channels is 8 bytes a pixel")
    }

    /// An export-sized decode is used once and would cost half a gigabyte to hold, so
    /// it must stay lazy — the caller falls back to the unmaterialized image.
    func testAnImageAboveTheLimitStaysLazy() throws {
        let big = try flat(0.5, 0.5, 0.5,
                           size: CGFloat(DecodeMaterializer.longEdgeLimit + 1))
        XCTAssertNil(DecodeMaterializer.materialize(big),
                     "above the limit this must decline rather than allocate")
    }

    /// An infinite extent — what `CIImage(color:)` has before it is cropped — must be
    /// declined rather than turned into an allocation of infinite size.
    func testAnInfiniteExtentIsDeclined() throws {
        let unbounded = CIImage(color: try colour(0.5, 0.5, 0.5))
        XCTAssertNil(DecodeMaterializer.materialize(unbounded))
    }
}
#endif

import Foundation
import XCTest
@testable import LumenCore

/// The gate and the verdict behind `RawSourceError.blankDecode`: macOS 15 decodes the
/// Leica M Monochrom (Typ 246) DNG (raw-corpus 1087) to an all-zero frame, and the app
/// showed it as a black photograph.
final class BlankDecodeGateTests: XCTestCase {

    /// A minimal TIFF: IFD0 (a reduced-resolution RGB preview carrying DNGVersion) and
    /// one SubIFD holding the raw image's NewSubfileType, Photometric and SamplesPerPixel.
    private func dng(little: Bool, photometric: Int, samples: Int,
                     dngVersion: Bool = true, rawInIFD0: Bool = false) -> Data {
        var b: [UInt8] = []
        func u16(_ v: Int) { b += little ? [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]
                                        : [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func u32(_ v: Int) {
            if little { u16(v & 0xFFFF); u16(v >> 16 & 0xFFFF) }
            else { u16(v >> 16 & 0xFFFF); u16(v & 0xFFFF) }
        }
        func entry(_ tag: Int, _ type: Int, _ value: Int) {
            u16(tag); u16(type); u32(1)
            if type == 3 { u16(value); u16(0) } else if type == 1 {
                b += [UInt8(value), 0, 0, 0]
            } else { u32(value) }
        }
        b += little ? [0x49, 0x49] : [0x4D, 0x4D]
        u16(42); u32(8)
        // IFD0 at 8
        var tags: [(Int, Int, Int)] = [(0x00FE, 4, rawInIFD0 ? 0 : 1),
                                       (0x0106, 3, rawInIFD0 ? photometric : 6),
                                       (0x0115, 3, rawInIFD0 ? samples : 3)]
        if !rawInIFD0 { tags.append((0x014A, 4, 0)) }
        if dngVersion { tags.append((0xC612, 1, 1)) }
        let ifd0Size = 2 + 12 * tags.count + 4
        let subAt = 8 + ifd0Size
        u16(tags.count)
        for (tag, type, value) in tags { entry(tag, type, tag == 0x014A ? subAt : value) }
        u32(0)
        u16(3)
        entry(0x00FE, 4, 0); entry(0x0106, 3, photometric); entry(0x0115, 3, samples)
        u32(0)
        return Data(b)
    }

    func testAMonochromeLinearRawDNGIsSinglePlane() {
        for little in [true, false] {
            let layout = DNGRawPlanes.layout(prefix: dng(little: little, photometric: 34892,
                                                         samples: 1))
            XCTAssertEqual(layout, .init(photometric: 34892, samplesPerPixel: 1))
            XCTAssertEqual(layout?.isSinglePlaneLinear, true)
        }
        XCTAssertEqual(DNGRawPlanes.layout(prefix: dng(little: true, photometric: 34892,
                                                       samples: 1, rawInIFD0: true))?
            .isSinglePlaneLinear, true)
    }

    func testColourDNGsAreNot() {
        // A Bayer DNG (Pixel 7 Pro): CFA, one sample. ProRAW (iPhone): LinearRaw, three.
        XCTAssertEqual(DNGRawPlanes.layout(prefix: dng(little: true, photometric: 32803,
                                                       samples: 1))?.isSinglePlaneLinear,
                       false)
        XCTAssertEqual(DNGRawPlanes.layout(prefix: dng(little: true, photometric: 34892,
                                                       samples: 3))?.isSinglePlaneLinear,
                       false)
    }

    func testNonDNGAndDamagedBytesAreUnknown() {
        XCTAssertNil(DNGRawPlanes.layout(prefix: dng(little: true, photometric: 34892,
                                                     samples: 1, dngVersion: false)))
        let whole = dng(little: true, photometric: 34892, samples: 1)
        for cut in [0, 4, 7, 12, 40, whole.count - 8] {
            XCTAssertNil(DNGRawPlanes.layout(prefix: whole.prefix(cut)), "cut at \(cut)")
        }
        XCTAssertNil(DNGRawPlanes.layout(prefix: Data("FUJIFILMCCD-RAW 0201".utf8)))
    }

    func testABlankDecodeCarriesNoSignal() {
        // What the corpus lane read from 1087: every colour sample 0, or -1.3e-10 with
        // Apple's defaults. Alpha is 1 and must not count.
        XCTAssertFalse(RawDecodeAcceptance.carriesSignal(
            rgba: Array(repeating: [0, 0, 0, 1], count: 500).flatMap { $0 }))
        XCTAssertFalse(RawDecodeAcceptance.carriesSignal(
            rgba: Array(repeating: [-1.3e-10, -1.3e-10, -1.3e-10, 1], count: 500)
                .flatMap { $0 }))
        XCTAssertFalse(RawDecodeAcceptance.carriesSignal(rgba: [.nan, .infinity, 0, 1]))
        XCTAssertFalse(RawDecodeAcceptance.carriesSignal(rgba: []))
    }

    func testADarkFrameStillCarriesSignal() {
        // One pixel of read noise (~1e-3 of white) is a photograph, however dark.
        var frame: [Float] = Array(repeating: [Float(0), 0, 0, 1], count: 500).flatMap { $0 }
        frame[4 * 321 + 2] = 1e-3
        XCTAssertTrue(RawDecodeAcceptance.carriesSignal(rgba: frame))
    }
}

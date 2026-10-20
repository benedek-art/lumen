// PhotoMetadataISOTests.swift
// The capture ISO above 65535 (metadata audit #0). EXIF 0x8827 is a SHORT and CIPA
// DC-008 §4.6.5 records 65535 for anything at or above it; the real value is in the
// LONG tag SensitivityType names. The A7 IV sample ARWs (DSC06673/06674/06679) all
// carry SensitivityType=2 with RecommendedExposureIndex equal to 0x8827, measured by a
// TIFF walk, so the in-range cases below are the files as written.

import XCTest
@testable import LumenCore

final class PhotoMetadataISOTests: XCTestCase {

    func testSaturatedRatingsTakeTheTagSensitivityTypeNames() {
        // Extended ISO on the A7 IV: 0x8827 pinned at 65535, REI carries the value.
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65535, sensitivityType: 2,
                                                recommendedExposureIndex: 102_400), 102_400)
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65535, sensitivityType: 2,
                                                recommendedExposureIndex: 204_800), 204_800)
        // The named tag wins over another that is also present.
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65535, sensitivityType: 3,
                                                recommendedExposureIndex: 100_000,
                                                isoSpeed: 102_400), 102_400)
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65535, sensitivityType: 1,
                                                standardOutputSensitivity: 80_000,
                                                recommendedExposureIndex: 102_400), 80_000)
        // Combined types: 4 = SOS+REI, 6 = REI+ISOSpeed — first present one.
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65535, sensitivityType: 4,
                                                recommendedExposureIndex: 102_400), 102_400)
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65535, sensitivityType: 6,
                                                isoSpeed: 204_800), 204_800)
    }

    func testInRangeRatingsAreUnchanged() {
        // The measured A7 IV files: 250/2/250 and 640/2/640.
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 250, sensitivityType: 2,
                                                recommendedExposureIndex: 250), 250)
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 640, sensitivityType: 2,
                                                recommendedExposureIndex: 640), 640)
        // A positive 0x8827 below 65535 is never second-guessed by a disagreeing tag.
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65534, sensitivityType: 2,
                                                recommendedExposureIndex: 70_000), 65534)
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 100), 100)
        XCTAssertNil(PhotoMetadata.resolveISO(speedRatings: nil))
    }

    func testMissingOrUnusableRatingsFallBack() {
        // No 0x8827 at all, REI only.
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: nil,
                                                recommendedExposureIndex: 1600), 1600)
        // Unknown or absent SensitivityType: REI, then ISOSpeed, then SOS.
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65535, sensitivityType: 0,
                                                standardOutputSensitivity: 90_000,
                                                isoSpeed: 102_400), 102_400)
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65535,
                                                standardOutputSensitivity: 90_000), 90_000)
        // Named tag missing: fall through to whatever else is positive.
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65535, sensitivityType: 2,
                                                isoSpeed: 102_400), 102_400)
        // Saturated with nothing else: the file's own answer stands, as before.
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65535), 65535)
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 65535, sensitivityType: 2,
                                                recommendedExposureIndex: 0), 65535)
        // Zero ratings: a positive fallback is used, otherwise the old value is kept.
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 0, sensitivityType: 2,
                                                recommendedExposureIndex: 400), 400)
        XCTAssertEqual(PhotoMetadata.resolveISO(speedRatings: 0), 0)
        XCTAssertNil(PhotoMetadata.resolveISO(speedRatings: nil, sensitivityType: 2,
                                              recommendedExposureIndex: -5))
    }

    func testExifIntegerAcceptsTheShapesImageIOReturns() {
        XCTAssertEqual(PhotoMetadata.exifInteger([NSNumber(value: 65535)]), 65535)
        XCTAssertEqual(PhotoMetadata.exifInteger([250]), 250)
        XCTAssertEqual(PhotoMetadata.exifInteger(NSNumber(value: 102_400)), 102_400)
        XCTAssertEqual(PhotoMetadata.exifInteger(NSNumber(value: 204_800.0)), 204_800)
        XCTAssertEqual(PhotoMetadata.exifInteger(1600), 1600)
        XCTAssertEqual(PhotoMetadata.exifInteger(3200.0), 3200)
        XCTAssertNil(PhotoMetadata.exifInteger(nil))
        XCTAssertNil(PhotoMetadata.exifInteger([Int]()))
        XCTAssertNil(PhotoMetadata.exifInteger("400"))
        XCTAssertNil(PhotoMetadata.exifInteger(Double.nan))
    }
}

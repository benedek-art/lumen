// PhotoMetadata.swift
// What a file says about how it was made: the capture metadata the catalog stores and
// the library sorts, filters and groups by.
//
// A pure value type, in LumenCore, because reading it needs ImageIO and storing it
// needs SQLite and neither should have to know about the other. The reader lives in
// LumenPipeline (`CaptureMetadataReader`); the writer is
// `CatalogStore.setMetadata(_:photoID:)`.
//
// Every field is optional and means it. A scan writes none of them, a background pass
// fills what the file actually carries, and a JPEG stripped of EXIF legitimately has
// nothing to say — which is different from "not read yet" only in that the pass will
// try again next launch. That re-read costs one file open, which is cheaper than a
// "we looked" column that can quietly disagree with the file it describes.

import Foundation

public struct PhotoMetadata: Equatable, Sendable {

    /// Seconds since the epoch, from EXIF DateTimeOriginal interpreted in the camera's
    /// own offset when it recorded one.
    public var captureAt: Int64?
    /// EXIF SubsecTimeOriginal, needed to order a burst: nine frames a second all carry
    /// the same whole second, so sorting by `captureAt` alone shuffles them.
    public var captureSubsec: Int?

    public var camera: String?
    public var cameraSerial: String?
    public var lens: String?

    public var iso: Int?
    public var shutterSeconds: Double?
    public var aperture: Double?
    public var focalMM: Double?

    public var width: Int?
    public var height: Int?
    /// EXIF orientation 1…8. Stored rather than applied, because the develop pipeline
    /// needs to know the frame was rotated in order to place a crop against it.
    public var orientation: Int?

    public var gpsLatitude: Double?
    public var gpsLongitude: Double?

    public init(captureAt: Int64? = nil, captureSubsec: Int? = nil,
                camera: String? = nil, cameraSerial: String? = nil, lens: String? = nil,
                iso: Int? = nil, shutterSeconds: Double? = nil,
                aperture: Double? = nil, focalMM: Double? = nil,
                width: Int? = nil, height: Int? = nil, orientation: Int? = nil,
                gpsLatitude: Double? = nil, gpsLongitude: Double? = nil) {
        self.captureAt = captureAt
        self.captureSubsec = captureSubsec
        self.camera = camera
        self.cameraSerial = cameraSerial
        self.lens = lens
        self.iso = iso
        self.shutterSeconds = shutterSeconds
        self.aperture = aperture
        self.focalMM = focalMM
        self.width = width
        self.height = height
        self.orientation = orientation
        self.gpsLatitude = gpsLatitude
        self.gpsLongitude = gpsLongitude
    }

    /// True when the file said nothing at all. The background pass writes it anyway so
    /// a photo without EXIF is not re-read forever — except that `captureAt` is the
    /// resume marker, so a file with no capture time genuinely is retried. That is the
    /// accepted cost of not carrying a second column that can lie.
    public var isEmpty: Bool { self == PhotoMetadata() }

    /// EXIF's own date format, which is not ISO-8601 and not what `ISO8601DateFormatter`
    /// parses: `2026:08:20 14:55:35`, colons in the date, local to wherever the camera
    /// thought it was. Parsed by hand because the alternative is a DateFormatter whose
    /// locale and time zone both have to be pinned to stop it drifting with the user's
    /// settings — a photo does not change the moment it was taken because someone flew.
    public static func parseEXIFDate(_ text: String, offsetSeconds: Int = 0) -> Int64? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" })
        guard parts.count >= 6 else { return nil }
        let numbers = parts.prefix(6).compactMap { Int($0) }
        guard numbers.count == 6 else { return nil }
        var components = DateComponents()
        components.year = numbers[0]
        components.month = numbers[1]
        components.day = numbers[2]
        components.hour = numbers[3]
        components.minute = numbers[4]
        components.second = numbers[5]
        guard (1900...9999).contains(numbers[0]), (1...12).contains(numbers[1]),
              (1...31).contains(numbers[2]), (0...23).contains(numbers[3]),
              (0...59).contains(numbers[4]), (0...61).contains(numbers[5])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        // UTC plus the camera's stated offset, rather than the machine's zone: the
        // catalog stores an instant, and the same file must land on the same instant
        // whichever laptop imports it.
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = calendar.date(from: components) else { return nil }
        return Int64(date.timeIntervalSince1970) - Int64(offsetSeconds)
    }

    /// EXIF OffsetTimeOriginal: `+02:00`, `-05:00`, or `Z`.
    public static func parseEXIFOffset(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "Z" { return 0 }
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let body = trimmed.dropFirst().split(separator: ":")
        guard body.count == 2, let hours = Int(body[0]), let minutes = Int(body[1]),
              (0...23).contains(hours), (0...59).contains(minutes)
        else { return nil }
        let magnitude = hours * 3600 + minutes * 60
        return sign == "-" ? -magnitude : magnitude
    }
}

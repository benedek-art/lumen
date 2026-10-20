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
    /// Microseconds into `captureAt`, needed to order a burst: nine frames a second all
    /// carry the same whole second, so sorting by `captureAt` alone shuffles them.
    ///
    /// Microseconds, not the raw EXIF digits. SubsecTimeOriginal is a fraction with the
    /// decimal point left out, so its digit width is part of its value and the raw field
    /// is not comparable across files — see `parseEXIFSubsec`, which is the only thing
    /// that should ever fill this from EXIF.
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

    /// EXIF SubsecTimeOriginal, as microseconds into the second.
    ///
    /// The tag is a FRACTION written without its decimal point: the digits sit after an
    /// implied one. So `"7"` means 0.7 s and `"070"` means 0.07 s — and reading either
    /// as a plain integer inverts them, because 7 sorts below 70 while the instants run
    /// the other way. One body writing a variable-width field, or two bodies on the same
    /// job, is all it takes; the burst comes back in the wrong order and nothing says so.
    ///
    /// Normalised to microseconds by right-padding to six digits, so the values are
    /// comparable as integers — which is what the capture-time sort needs, since it
    /// orders on `COALESCE(photo.capture_subsec, 0)` and cannot see how wide the field
    /// was. Six digits is finer than any camera's clock, and digits past the sixth are
    /// truncated rather than rounded: they are below the resolution of what wrote them,
    /// and rounding could carry a value into the next microsecond and swap a pair that
    /// truncation leaves in order.
    ///
    /// Anything that is not a run of ASCII digits returns nil rather than a guess. A
    /// field this small has no room for a partial read to be better than none: an
    /// unparseable subsecond sorts as 0 and ties, which is the pre-EXIF behaviour, while
    /// a guess would confidently order frames wrongly.
    ///
    /// Lives here, not in the reader, for the reason the header gives: `PhotoMetadata`
    /// is pure and runs on Linux, and `CaptureMetadataReader` needs ImageIO, a macOS
    /// toolchain and a file on disk to exercise at all.
    public static func parseEXIFSubsec(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        let digits = trimmed.prefix(6)
        var value = 0
        for character in digits { value = value * 10 + (character.wholeNumberValue ?? 0) }
        for _ in digits.count..<6 { value *= 10 }
        return value
    }

    /// The ISO a frame was shot at, from the EXIF sensitivity tags.
    ///
    /// PhotographicSensitivity (0x8827, the old ISOSpeedRatings) is a SHORT, and CIPA
    /// DC-008-2016 §4.6.5 says "when the value is 65535 or more, 65535 shall be
    /// recorded". The real value then lives in the LONG tag SensitivityType (0x8830)
    /// names: 1 SOS; 2 REI; 3 ISOSpeed; 4 SOS+REI; 5 SOS+ISOSpeed; 6 REI+ISOSpeed;
    /// 7 all three. Reading 0x8827 alone stored 65535 for the A7 IV's extended ISO
    /// 102400/204800, and `NoiseProfile.forISO(65535)` sits ~36% (shot) and ~50% (read)
    /// under the 102400 anchor — the noisiest frames got the weakest denoise. Measured
    /// on the sample A7 IV ARWs (DSC06673/06674/06679, TIFF walk): every one writes
    /// SensitivityType=2 with a LONG RecommendedExposureIndex equal to 0x8827 (250/250,
    /// 640/640), so REI is where Sony puts the number.
    ///
    /// A positive 0x8827 below 65535 wins outright, so nothing at or below ISO 65534
    /// changes. Only a saturated, missing or non-positive value consults the other
    /// tags — the named ones first, then whichever of REI, ISOSpeed, SOS is positive —
    /// and with none of them the old answer (`speedRatings`, as written) stands.
    public static func resolveISO(speedRatings: Int?,
                                  sensitivityType: Int? = nil,
                                  standardOutputSensitivity: Int? = nil,
                                  recommendedExposureIndex: Int? = nil,
                                  isoSpeed: Int? = nil) -> Int? {
        if let ratings = speedRatings, ratings > 0, ratings < 65535 { return ratings }
        func positive(_ value: Int?) -> Int? {
            guard let value, value > 0 else { return nil }
            return value
        }
        let sos = positive(standardOutputSensitivity)
        let rei = positive(recommendedExposureIndex)
        let speed = positive(isoSpeed)
        let named: Int?
        switch sensitivityType {
        case 1: named = sos
        case 2: named = rei
        case 3: named = speed
        case 4: named = sos ?? rei
        case 5: named = sos ?? speed
        case 6: named = rei ?? speed
        case 7: named = sos ?? rei ?? speed
        default: named = nil
        }
        return named ?? rei ?? speed ?? sos ?? speedRatings
    }

    /// An EXIF integer as ImageIO hands it over: an `NSNumber` (integer- or
    /// float-backed), a Swift `Int`/`Double`, or a one-element array of either — the
    /// standard makes 0x8827 an array and plenty of files write it as a scalar. Takes
    /// the first element; anything non-finite or out of `Int` range is nil.
    public static func exifInteger(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let array = value as? [Any] { return exifInteger(array.first) }
        if let int = value as? Int { return int }
        let double: Double
        if let number = value as? NSNumber { double = number.doubleValue }
        else if let raw = value as? Double { double = raw }
        else { return nil }
        guard double.isFinite, abs(double) < 9.0e15 else { return nil }
        return Int(double.rounded())
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

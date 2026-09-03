// RawTruthTests.swift
// The cull-time raw-truth instrument, pinned.
//
// `RawStatistics` had full binning, encode and decode, and its only two callers were
// blob round-trip tests — tests that stayed green whether or not the feature ever
// reached a user. Everything measured here is the opposite: the provenance the numbers
// carry, the arithmetic that decides how much of a file to measure, the verdict the
// panel prints, and the cache that stops the second look recomputing.
//
// The assertion this file exists for is the honesty one:
// `testNothingInTheRepositoryClaimsSensorRawStatistics`. Lumen has no CFA reader, so no
// code here may label a measurement as the sensor's mosaic. That is a claim a scan can
// check, and it is exactly the claim the feature would otherwise drift into making.

import XCTest
@testable import LumenCore

final class RawTruthProvenanceTests: XCTestCase {

    // MARK: - Provenance says something, and says it differently each time

    func testEveryProvenanceHasItsOwnLabelAndCeiling() {
        var labels: Set<String> = []
        var ceilings: Set<String> = []
        for provenance in RawStatistics.Provenance.allCases {
            XCTAssertFalse(provenance.label.isEmpty, "\(provenance) has no label")
            XCTAssertFalse(provenance.ceilingMeaning.isEmpty,
                           "\(provenance) does not say what its ceiling is")
            labels.insert(provenance.label)
            ceilings.insert(provenance.ceilingMeaning)
        }
        XCTAssertEqual(labels.count, RawStatistics.Provenance.allCases.count,
                       "two provenances print the same label, so the panel cannot "
                           + "distinguish them")
        XCTAssertEqual(ceilings.count, RawStatistics.Provenance.allCases.count)
    }

    func testOnlyTheMosaicCountsAsSensorTruth() {
        for provenance in RawStatistics.Provenance.allCases {
            XCTAssertEqual(provenance.isSensorTruth, provenance == .sensorCFA,
                           "\(provenance) disagrees with itself about being sensor truth")
        }
        // The label a person reads has to carry the same distinction the flag does.
        XCTAssertTrue(RawStatistics.Provenance.sceneLinearDecode.label
            .contains("post-demosaic"))
        XCTAssertFalse(RawStatistics.Provenance.sceneLinearDecode.label
            .lowercased().contains("sensor"))
    }

    // MARK: - Provenance survives the blob

    func testEveryProvenanceRoundTripsThroughTheBlob() {
        for provenance in RawStatistics.Provenance.allCases {
            let stats = RawStatistics.compute(Self.ramp(), provenance: provenance)
            XCTAssertEqual(stats.provenance, provenance)
            guard let decoded = RawStatistics.decode(stats.encoded()) else {
                XCTFail("\(provenance) did not decode")
                continue
            }
            XCTAssertEqual(decoded.provenance, provenance,
                           "\(provenance) did not survive the blob")
            XCTAssertEqual(decoded.sourceIsCFA, provenance == .sensorCFA,
                           "the CFA bit and the provenance field disagree for "
                               + "\(provenance)")
        }
    }

    func testALegacyBlobThatOnlyHasTheCFABitStillReads() {
        // Bits 1…3 zero is what every blob written before the field looks like. The CFA
        // bit is then the only evidence there is, and it is read rather than discarded.
        XCTAssertEqual(RawStatistics.provenance(fromFlags: 0), .unspecified)
        XCTAssertEqual(RawStatistics.provenance(fromFlags: 1), .sensorCFA)
    }

    func testAFlagsWordThatContradictsItselfReadsAsUnrecorded() {
        // Field says CFA, bit 0 says it is not. One of the two was written by hand and
        // there is no way to know which, so the narrower claim wins.
        let cfaFieldWithoutBit: UInt32 = (RawStatistics.Provenance.sensorCFA.rawValue << 1)
        XCTAssertEqual(RawStatistics.provenance(fromFlags: cfaFieldWithoutBit), .unspecified)

        // And the other way: bit 0 set, field says decoded RGB.
        let decodeFieldWithBit: UInt32 =
            1 | (RawStatistics.Provenance.sceneLinearDecode.rawValue << 1)
        XCTAssertEqual(RawStatistics.provenance(fromFlags: decodeFieldWithBit), .unspecified)
    }

    func testAProvenanceThisBuildDoesNotKnowIsNotGuessedAt() {
        // A newer writer using a value this build has never heard of. Reporting it as
        // the nearest known case would put a caption on numbers that does not describe
        // them; reporting it as unrecorded is true.
        let unknown: UInt32 = (7 << 1)
        XCTAssertEqual(RawStatistics.provenance(fromFlags: unknown), .unspecified)
    }

    func testTheLegacySpellingStillMeansExactlyWhatItMeant() {
        // The memberwise init predates provenance and is still called with
        // `sourceIsCFA:` alone. `true` is a CFA claim; `false` is the absence of any
        // claim, NOT a silent upgrade to "decoded scene-linear".
        let cfa = Self.blank(sourceIsCFA: true)
        XCTAssertEqual(cfa.provenance, .sensorCFA)
        let plain = Self.blank(sourceIsCFA: false)
        XCTAssertEqual(plain.provenance, .unspecified)
        XCTAssertFalse(plain.provenance.isSensorTruth)
    }

    func testARenderedFileIsNeverCalledSceneLinear() {
        // A JPEG's pixels have been through a camera's tone curve. Core Image converts
        // them into linear Rec.2020 on the way in, which makes them dimensionally
        // correct and does NOT put the clipped headroom back — so measuring one is the
        // rendered reading, and the panel has to say so.
        XCTAssertEqual(RawTruth.provenance(isRenderedFile: true), .renderedProxy)
        XCTAssertEqual(RawTruth.provenance(isRenderedFile: false), .sceneLinearDecode)
        XCTAssertNotEqual(RawTruth.provenance(isRenderedFile: true),
                          RawTruth.provenance(isRenderedFile: false),
                          "one label for both kinds of file means one of them is wrong")

        // And what each then prints, so this is pinned to the words rather than to the
        // case names.
        XCTAssertTrue(RawTruth.readout(Self.blankScene(RawTruth.provenance(
            isRenderedFile: true))).qualifications.contains { $0.contains("post-tone-curve") })
        XCTAssertTrue(RawTruth.readout(Self.blankScene(RawTruth.provenance(
            isRenderedFile: false))).qualifications.contains(RawTruth.sensorGapNote))
    }

    private static func blankScene(_ provenance: RawStatistics.Provenance) -> RawStatistics {
        RawStatistics.compute(ramp(), provenance: provenance, subsample: 1)
    }

    // MARK: - The honesty scan

    /// Lumen has no CFA reader. No code in this repository may therefore produce
    /// statistics labelled as the sensor's mosaic — that label is reserved for a
    /// measurement nothing here can take.
    ///
    /// This is the assertion the whole feature turns on. Everything else could be
    /// correct and the panel would still be a fourth false claim if some call site
    /// quietly passed `.sensorCFA`, and a code review would not catch it, because the
    /// line would look exactly like the honest one.
    func testNothingInTheRepositoryClaimsSensorRawStatistics() {
        let sources = Self.swiftSources(under: "Sources")
        XCTAssertGreaterThan(sources.count, 40,
                             "the scan found \(sources.count) files — it has stopped "
                                 + "seeing the sources and would pass on an empty set")

        // The two spellings that produce a sensor claim at a call site. The enum's own
        // declaration and the switches over it are not claims; `provenance: .sensorCFA`
        // and `sourceIsCFA: true` are.
        let forbidden: [String] = ["provenance: .sensorCFA", "sourceIsCFA: true"]
        for file in sources {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                XCTFail("could not read \(file.lastPathComponent)")
                continue
            }
            let code = Self.withoutComments(text)
            for phrase in forbidden {
                XCTAssertFalse(code.contains(phrase),
                               "\(file.lastPathComponent) writes \"\(phrase)\" — that "
                                   + "labels a measurement as the sensor's CFA data, "
                                   + "and nothing in LumenPipeline can read a mosaic. "
                                   + "Either a raw reader landed, in which case this "
                                   + "test's exemption list is the thing to change, or "
                                   + "the claim is false.")
            }
        }
    }

    func testTheScanWouldSeeTheClaimIfItWereThere() {
        // A scan that matches nothing passes the test above for the wrong reason. This
        // is the same matcher, run on text that does contain the claim.
        let sample = """
        // provenance: .sensorCFA in a comment is prose, not a claim
        let stats = RawStatistics.compute(buffer, provenance: .sensorCFA)
        """
        let code = Self.withoutComments(sample)
        XCTAssertTrue(code.contains("provenance: .sensorCFA"))
        XCTAssertEqual(code.components(separatedBy: "provenance: .sensorCFA").count - 1, 1,
                       "the comment stripper is not removing the commented claim")
    }

    // MARK: - Fixtures

    /// A grey ramp over the working range. The generator takes NORMALIZED coordinates,
    /// so `u` is already the ramp.
    static func ramp(width: Int = 32, height: Int = 8) -> ImageBuffer {
        ImageBuffer(width: width, height: height) { u, _ in RGB(u, u, u) }
    }

    static func blank(sourceIsCFA: Bool) -> RawStatistics {
        RawStatistics(bins: [UInt32](repeating: 0,
                                     count: RawStatistics.channelCount
                                         * RawStatistics.binCount),
                      clippedHighPercent: [0, 0, 0, 0],
                      nearClippedHighPercent: [0, 0, 0, 0],
                      clippedLowPercent: [0, 0, 0, 0],
                      nearClippedLowPercent: [0, 0, 0, 0],
                      sampleCount: 100,
                      subsample: 1,
                      blackLevel: 0,
                      saturation: [1, 1, 1, 1],
                      analyzerRevision: RawStatistics.currentAnalyzerRevision,
                      sourceIsCFA: sourceIsCFA)
    }

    /// The repository root, from this file's own path.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    static func swiftSources(under relativePath: String) -> [URL] {
        let root = repositoryRoot.appendingPathComponent(relativePath, isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Comments blanked, string bodies kept, offsets preserved. Same one-pass shape as
    /// `KeyGrammarTests` uses, and for the same reason: a `//` inside a string and a
    /// quote inside a comment each break the other's regex.
    static func withoutComments(_ text: String) -> String {
        var out = Array(text)
        let n = out.count
        var i = 0
        func blank(_ from: Int, _ to: Int) {
            for k in from..<to where out[k] != "\n" { out[k] = " " }
        }
        while i < n {
            let c = out[i]
            let next: Character? = i + 1 < n ? out[i + 1] : nil
            if c == "/" && next == "/" {
                var j = i
                while j < n && out[j] != "\n" { j += 1 }
                blank(i, j)
                i = j
            } else if c == "/" && next == "*" {
                var j = i + 2
                while j + 1 < n && !(out[j] == "*" && out[j + 1] == "/") { j += 1 }
                let end = Swift.min(j + 2, n)
                blank(i, end)
                i = end
            } else if c == "\"" {
                var j = i + 1
                while j < n {
                    if out[j] == "\\" { j += 2; continue }
                    if out[j] == "\"" { j += 1; break }
                    if out[j] == "\n" { break }
                    j += 1
                }
                i = j
            } else {
                i += 1
            }
        }
        return String(out)
    }
}

// MARK: - The plan

final class RawTruthPlanTests: XCTestCase {

    func testAFortyFiveMegapixelFileIsMeasuredInsideItsMemoryBudget() {
        // 8192 × 5464 is a 45 MP full-frame file. Pulled whole into f32 RGBA that is
        // 716 MB, which is why the decode is scaled first.
        let plan = RawTruth.plan(nativeWidth: 8192, nativeHeight: 5464)
        XCTAssertEqual(plan.proxyLongEdge, RawTruth.decodeLongEdge)
        XCTAssertEqual(plan.decodeScaleFactor, 2048.0 / 8192.0, accuracy: 1e-12)
        XCTAssertEqual(plan.siteStride, 4)
        XCTAssertTrue(plan.averagesSites)

        // docs/10 §10.5 budgets 1/16 of the sensor. 45 MP / 16 is about 2.8 M.
        XCTAssertGreaterThan(plan.approximateSampleCount, 2_000_000)
        XCTAssertLessThan(plan.approximateSampleCount, 4_000_000)

        // And the thing that actually has to hold: the buffer fits in tens of MB, not
        // hundreds. Sixteen bytes per sample, RGBA f32.
        let bytes = plan.approximateSampleCount * 16
        XCTAssertLessThan(bytes, 64 * 1024 * 1024,
                          "the proxy is \(bytes / 1_048_576) MB — the whole reason for "
                              + "scaling the decode was to stay well under that")
    }

    func testAFrameSmallEnoughToMeasureWholeIsMeasuredWhole() {
        let plan = RawTruth.plan(nativeWidth: 1600, nativeHeight: 1200)
        XCTAssertEqual(plan.proxyLongEdge, 1600)
        XCTAssertEqual(plan.decodeScaleFactor, 1, accuracy: 1e-12)
        XCTAssertEqual(plan.siteStride, 1)
        XCTAssertFalse(plan.averagesSites)
        XCTAssertEqual(plan.samplingNote, "",
                       "nothing was averaged, so there is nothing to caption — and a "
                           + "caption that appears when it is not true is noise the "
                           + "reader learns to skip")
        XCTAssertEqual(plan.approximateSampleCount, 1600 * 1200)
    }

    func testTheSiteStrideRoundsTowardTheCoarserClaim() {
        // 3000 → 2048 is about 1.47 sites per sample. Recording 1 would describe the
        // measurement as finer than it is; recording 2 under-claims, which is the only
        // direction an honest caption may err in.
        let plan = RawTruth.plan(nativeWidth: 3000, nativeHeight: 2000)
        XCTAssertEqual(plan.proxyLongEdge, 2048)
        XCTAssertTrue(plan.averagesSites)
        XCTAssertEqual(plan.siteStride, 2)
        XCTAssertTrue(plan.samplingNote.contains("2×2"))
    }

    func testADegenerateSizeStillProducesAUsablePlan() {
        // A source that cannot report its size must not produce a scale factor of
        // infinity, a stride of zero or a division by zero. The instrument declines to
        // measure; it does not take the app down.
        for size in [(0, 0), (-4, 10), (0, 512)] {
            let plan = RawTruth.plan(nativeWidth: size.0, nativeHeight: size.1)
            XCTAssertTrue(plan.decodeScaleFactor.isFinite, "\(size) produced a bad scale")
            XCTAssertGreaterThan(plan.decodeScaleFactor, 0)
            XCTAssertLessThanOrEqual(plan.decodeScaleFactor, 1)
            XCTAssertGreaterThanOrEqual(plan.siteStride, 1)
            XCTAssertGreaterThanOrEqual(plan.bufferStride, 1)
            XCTAssertGreaterThanOrEqual(plan.approximateSampleCount, 0)
        }
    }

    func testTheScaleNeverAsksTheDecoderForMoreThanTheFileHas() {
        for longEdge in [64, 512, 2047, 2048, 2049, 6000, 11_664] {
            let plan = RawTruth.plan(nativeWidth: longEdge, nativeHeight: longEdge / 2)
            XCTAssertLessThanOrEqual(plan.decodeScaleFactor, 1,
                                     "long edge \(longEdge) asked for an upscale")
            XCTAssertLessThanOrEqual(plan.proxyLongEdge, longEdge)
            XCTAssertLessThanOrEqual(plan.proxyLongEdge, RawTruth.decodeLongEdge)
        }
    }

    func testThePlannedStrideIsWhatTheRowRecords() {
        // `RawStatistics.subsample`'s contract is a stride in SENSOR SITES. The binner
        // walks a proxy, so the two numbers differ, and the row must carry the site one
        // or it describes a 2048 px proxy of an 8192 px file as a full-resolution
        // measurement.
        let plan = RawTruth.plan(nativeWidth: 8192, nativeHeight: 5464)
        let stats = RawStatistics.compute(RawTruthProvenanceTests.ramp(),
                                          provenance: .sceneLinearDecode,
                                          subsample: plan.bufferStride,
                                          recordedSiteStride: plan.siteStride)
        XCTAssertEqual(stats.subsample, 4)
        XCTAssertEqual(plan.bufferStride, 1)

        // And with no site stride given, the field means the buffer stride, exactly as
        // it did before.
        let plain = RawStatistics.compute(RawTruthProvenanceTests.ramp(),
                                          provenance: .sceneLinearDecode,
                                          subsample: 3)
        XCTAssertEqual(plain.subsample, 3)
    }
}

// MARK: - The readout

final class RawTruthReadoutTests: XCTestCase {

    private func stats(high: [Double],
                       nearHigh: [Double] = [0, 0, 0, 0],
                       low: [Double] = [0, 0, 0, 0],
                       subsample: Int = 1,
                       provenance: RawStatistics.Provenance = .sceneLinearDecode)
    -> RawStatistics {
        RawStatistics(bins: [UInt32](repeating: 0,
                                     count: RawStatistics.channelCount
                                         * RawStatistics.binCount),
                      clippedHighPercent: high,
                      nearClippedHighPercent: nearHigh,
                      clippedLowPercent: low,
                      nearClippedLowPercent: [0, 0, 0, 0],
                      sampleCount: 1_000_000,
                      subsample: subsample,
                      blackLevel: 0,
                      saturation: [1, 1, 1, 1],
                      analyzerRevision: RawStatistics.currentAnalyzerRevision,
                      sourceIsCFA: provenance == .sensorCFA,
                      provenance: provenance)
    }

    func testACleanFrameReadsIntact() {
        let readout = RawTruth.readout(stats(high: [0, 0, 0, 0]))
        XCTAssertEqual(readout.verdict, .intact)
        XCTAssertEqual(readout.headline, "R 0.0%, G 0.0%, B 0.0% clipped")
        XCTAssertTrue(readout.channels.allSatisfy { !$0.isClipped })
    }

    func testATraceOfClippingIsNotAVerdict() {
        // 0.05% of 2.8 M samples is about fourteen hundred pixels of specular. Calling
        // that "clipped" would fire the verdict on every frame with a highlight in it.
        let readout = RawTruth.readout(stats(high: [0.05, 0.02, 0.01, 0.03]))
        XCTAssertEqual(readout.verdict, .intact)
    }

    func testOneChannelAtTheCeilingIsRecoverable() {
        // docs/10 §10.5's own example: the sunset question, answered numerically.
        let readout = RawTruth.readout(stats(high: [2.1, 0.0, 0.0, 0.7]))
        XCTAssertEqual(readout.verdict, .recoverable)
        XCTAssertEqual(readout.headline, "R 2.1%, G 0.0%, B 0.0% clipped")
        XCTAssertTrue(readout.channels[0].isClipped)
        XCTAssertFalse(readout.channels[1].isClipped)
        XCTAssertFalse(readout.channels[2].isClipped)
        XCTAssertTrue(readout.verdict.summary.lowercased().contains("recoverable"))
    }

    func testTwoChannelsGoneStillLeavesOneToReconstructFrom() {
        let readout = RawTruth.readout(stats(high: [6.0, 4.0, 0.2, 3.0]))
        XCTAssertEqual(readout.verdict, .recoverable)
    }

    func testAllThreeChannelsOverARegionIsNotRecoverable() {
        let readout = RawTruth.readout(stats(high: [5.0, 4.0, 3.0, 4.0]))
        XCTAssertEqual(readout.verdict, .gone)
        XCTAssertTrue(readout.verdict.summary.lowercased().contains("not recoverable"))
    }

    func testThreeChannelsBarelyClippedIsNotCalledUnrecoverable() {
        // Every channel is over the noise threshold and none is over a percent. There
        // is far too little here to call the frame lost, and a verdict that said so
        // would send a keeper to the reject pile.
        let readout = RawTruth.readout(stats(high: [0.3, 0.3, 0.3, 0.3]))
        XCTAssertEqual(readout.verdict, .recoverable)
    }

    func testTheThresholdsAreTheOnesTheVerdictNames() {
        XCTAssertEqual(RawTruth.significantPercent, 0.1, accuracy: 1e-12)
        XCTAssertEqual(RawTruth.regionPercent, 1.0, accuracy: 1e-12)
        // Exactly at the threshold counts, which is the only reading of ">= 1%" that
        // matches the sentence the summary prints.
        XCTAssertEqual(RawTruth.readout(stats(high: [1.0, 1.0, 1.0, 1.0])).verdict, .gone)
        XCTAssertEqual(RawTruth.readout(stats(high: [0.1, 0.0, 0.0, 0.0])).verdict,
                       .recoverable)
    }

    func testAScenelinearReadoutAlwaysCarriesTheGapToTheSensor() {
        let readout = RawTruth.readout(stats(high: [2.1, 0, 0, 0]))
        XCTAssertEqual(readout.provenanceLabel, "Scene-linear (post-demosaic)")
        XCTAssertFalse(readout.isSensorTruth)
        XCTAssertTrue(readout.qualifications.contains(RawTruth.sensorGapNote),
                      "a scene-linear readout that does not say it is post-demosaic is "
                          + "the overstatement this whole instrument was built to avoid")
        XCTAssertTrue(readout.qualifications.contains(RawTruth.againstTheRenderNote))
        XCTAssertTrue(readout.ceilingNote.contains("scene-linear 1.0"))
    }

    func testTheGapNoteNamesTheMechanismAndClaimsNoDirection() {
        let note = RawTruth.sensorGapNote.lowercased()
        XCTAssertTrue(note.contains("demosaic"))
        XCTAssertTrue(note.contains("reconstruction"))
        // Claiming which way the reconstruction moves the number would be a measurement
        // this build has not taken.
        for word in ["under-report", "over-report", "always", "never"] {
            XCTAssertFalse(note.contains(word),
                           "the gap note claims \"\(word)\", which nothing here measured")
        }
    }

    func testAnUnrecordedRowSaysItIsNotEvidence() {
        let readout = RawTruth.readout(stats(high: [9.0, 9.0, 9.0, 9.0],
                                             provenance: .unspecified))
        XCTAssertEqual(readout.provenanceLabel, "Unrecorded source")
        XCTAssertFalse(readout.isSensorTruth)
        XCTAssertTrue(readout.qualifications.contains { $0.contains("Recompute") },
                      "an unlabelled row with a dramatic number is exactly the case "
                          + "that must not read as a finding")
    }

    func testARenderedProxyReadoutSaysItIsTheHistogramThisInstrumentBeats() {
        let readout = RawTruth.readout(stats(high: [1, 1, 1, 1], provenance: .renderedProxy))
        XCTAssertEqual(readout.provenanceLabel, "Rendered proxy")
        XCTAssertTrue(readout.qualifications.contains { $0.contains("post-tone-curve") })
    }

    func testAStoredRowRebuildsItsSamplingNoteFromTheStrideItCarries() {
        // The panel reading a cached row has no plan in hand — only the row. It still
        // has to say how coarse the numbers are.
        let readout = RawTruth.readout(stats(high: [0, 0, 0, 0], subsample: 4))
        XCTAssertTrue(readout.qualifications.contains { $0.contains("4×4") },
                      "a cached row lost the caption that says what it measured")

        let fine = RawTruth.readout(stats(high: [0, 0, 0, 0], subsample: 1))
        XCTAssertFalse(fine.qualifications.contains { $0.contains("×") })
    }

    func testAPlanOverridesTheStoredNoteWhenTheMeasurementIsFresh() {
        let plan = RawTruth.plan(nativeWidth: 8192, nativeHeight: 5464)
        let readout = RawTruth.readout(stats(high: [0, 0, 0, 0], subsample: 4), plan: plan)
        XCTAssertTrue(readout.qualifications.contains { $0.contains("2048 px proxy") })
    }

    func testTheCFASlotIsNamedForWhatItHolds() {
        XCTAssertEqual(RawTruth.readout(stats(high: [0, 0, 0, 0])).luma.name, "Y")
        XCTAssertEqual(
            RawTruth.readout(stats(high: [0, 0, 0, 0], provenance: .sensorCFA)).luma.name,
            "G2")
    }

    func testANonFinitePercentageNeverReachesTheReader() {
        let poisoned = stats(high: [Double.nan, .infinity, 0, 0])
        // The struct sanitises on the way in, so the reader sees zeros rather than a
        // "nan%" line or a crash in the formatter.
        let readout = RawTruth.readout(poisoned)
        XCTAssertEqual(readout.verdict, .intact)
        XCTAssertFalse(readout.headline.lowercased().contains("nan"))
        XCTAssertFalse(readout.headline.lowercased().contains("inf"))
        XCTAssertEqual(RawTruth.percent(.nan), "—")
        XCTAssertEqual(RawTruth.percent(-5), "0.0%")
        XCTAssertEqual(RawTruth.percent(1000), "100.0%")
    }

    func testAClippedFrameActuallyBinsAsClipped() {
        // End to end through the real binner, not a hand-built struct: a frame whose
        // red channel is at the ceiling and whose green and blue are not.
        let frame = ImageBuffer(width: 32, height: 8) { _, _ in RGB(1.4, 0.5, 0.25) }
        let measured = RawStatistics.compute(frame, provenance: .sceneLinearDecode,
                                             subsample: 1)
        let readout = RawTruth.readout(measured)
        XCTAssertEqual(readout.channels[0].clippedPercent, 100, accuracy: 1e-6)
        XCTAssertEqual(readout.channels[1].clippedPercent, 0, accuracy: 1e-6)
        XCTAssertEqual(readout.channels[2].clippedPercent, 0, accuracy: 1e-6)
        XCTAssertEqual(readout.verdict, .recoverable)
    }

    func testTheInstrumentSeesHeadroomTheRenderedHistogramCannot() {
        // The whole argument for this feature, in one assertion, on numbers rather than
        // on a claim in a doc.
        //
        // The frame: half of it a ramp from 0.6 to 0.94 in scene-linear light, half of
        // it genuinely over the ceiling at 1.6. Only the second half is clipped, and
        // that is what a scene-linear reading reports.
        //
        // The render: a display transform whose shoulder puts scene 0.9 at display
        // white — an ordinary amount of shoulder, and far less than the 0.3–2 EV
        // docs/10 §10.5 attributes to a camera JPEG. Every pixel from 0.9 upward now
        // reads as clipped, including a band that still holds detail. That band is the
        // headroom the develop histogram cannot show, and this is the measurement that
        // makes "the histogram that lies" a number instead of an assertion.
        let displayWhiteInScene: Double = 0.9
        let scene = ImageBuffer(width: 64, height: 8) { u, _ in
            let v: Double = u < 0.5 ? 0.6 + u * 0.7 : 1.6
            return RGB(v, v, v)
        }
        let sceneLinear = RawStatistics.compute(scene, provenance: .sceneLinearDecode,
                                                subsample: 1)
        XCTAssertEqual(sceneLinear.clippedHighPercent[0], 50, accuracy: 0.1,
                       "only the half that is actually over the ceiling is clipped")

        var rendered = scene
        for y in 0..<rendered.height {
            for x in 0..<rendered.width {
                let scaled = rendered[x, y] * (1 / displayWhiteInScene)
                rendered[x, y] = scaled.clamped(0, 1)
            }
        }
        let displayed = RawStatistics.compute(rendered, provenance: .renderedProxy,
                                              subsample: 1)
        XCTAssertGreaterThan(displayed.clippedHighPercent[0],
                             sceneLinear.clippedHighPercent[0] + 5,
                             "the rendered reading has to report clipping where the "
                                 + "scene data still holds detail — if it does not, "
                                 + "this instrument is measuring what the develop "
                                 + "histogram already measured and is not worth having")
        XCTAssertEqual(RawTruth.readout(sceneLinear).verdict, .gone)
        XCTAssertEqual(RawTruth.readout(displayed).verdict, .gone)
    }
}


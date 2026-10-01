// ExportNamingTests.swift
// docs/11 §Naming against `ExportNaming`: J3-05 (`{date}` was the file's creation
// date) and J3-08 (no sequence token, so a template without `{name}` collapsed a batch
// onto one name-chain), plus the promise that a template which named files before
// names them identically now.

import XCTest
@testable import LumenCore

final class ExportNamingTests: XCTestCase {

    private static let nef: URL = URL(fileURLWithPath: "/Volumes/Card/DCIM/DSC_0001.NEF")

    private func components(_ y: Int, _ mo: Int, _ d: Int,
                            _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> DateComponents {
        DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    private func render(_ template: String, _ context: ExportNamingContext) -> String {
        ExportNaming.render(template: template, context: context)
    }

    // MARK: - J3-05: the date is when the shutter fired

    func testTheDateTokenIsWhenTheShutterFiredNotWhenTheFileWasCopied() {
        let context = ExportNamingContext(source: Self.nef, recipeName: "web",
                                          captureDate: components(2026, 6, 14, 18, 30, 5),
                                          fileDate: components(2026, 6, 18, 9, 0, 0))
        XCTAssertEqual(render("{date}_{name}", context), "2026-06-14_DSC_0001",
                       "the delivery was named after the day the card was copied")
        XCTAssertEqual(render("{time}", context), "183005")
        XCTAssertEqual(render("{yyyy}{mm}{dd}", context), "20260614")
    }

    /// No EXIF date: the file's own date, which is what `{date}` always meant on the
    /// export side — a file with nothing better names exactly as it used to.
    func testWithoutACaptureDateTheFileDateStands() {
        let context = ExportNamingContext(source: Self.nef, recipeName: "web",
                                          fileDate: components(2026, 6, 18, 9, 7, 0))
        XCTAssertEqual(render("{date}", context), "2026-06-18")
        XCTAssertEqual(render("{time}", context), "090700")
    }

    func testTheEXIFStampIsReadAsTheWallClockItStates() {
        XCTAssertEqual(PhotoMetadata.parseEXIFDateComponents("2026:08:20 14:55:35"),
                       components(2026, 8, 20, 14, 55, 35))
        XCTAssertNil(PhotoMetadata.parseEXIFDateComponents("0000:00:00 00:00:00"),
                     "the all-zero stamp cameras write for an unset clock is not a date")
        XCTAssertNil(PhotoMetadata.parseEXIFDateComponents("garbage"))
        // The same six fields `parseEXIFDate` turns into an instant at UTC + 0.
        let instant = PhotoMetadata.parseEXIFDate("2026:08:20 14:55:35")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let back = utc.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                      from: Date(timeIntervalSince1970: TimeInterval(instant!)))
        XCTAssertEqual(back, components(2026, 8, 20, 14, 55, 35))
    }

    // MARK: - J3-08: a sequence

    func testSequenceTokensUseTheIngestRenamersWidths() {
        var context = ExportNamingContext(source: Self.nef, recipeName: "web", sequence: 7)
        XCTAssertEqual(render("{seq}", context), "0007", "ingest's {seq} is four wide")
        XCTAssertEqual(render("{seq3}", context), "007")
        XCTAssertEqual(render("{seq4}", context), "0007")
        XCTAssertEqual(render("{seq:6}", context), "000007")
        context.sequence = 12345
        XCTAssertEqual(render("{seq3}", context), "12345", "a width is a minimum")
        // `RenameTemplate` agrees about the spelling both homes share.
        let ingest = RenameContext(originalBasename: "x", captureDate: DateComponents())
        XCTAssertEqual(RenameTemplate.render("{seq}-{seq:6}", context: ingest, seq: 7),
                       ExportNaming.render(template: "{seq}-{seq:6}",
                                           context: ExportNamingContext(
                                            source: Self.nef, recipeName: "", sequence: 7)))
    }

    func testTheSequenceCountsPhotosFromTheRecipesStart() {
        var recipe = ExportRecipe(name: "web")
        XCTAssertEqual(recipe.sequenceNumber(forPhotoAt: 0), 1)
        XCTAssertEqual(recipe.sequenceNumber(forPhotoAt: 4), 5)
        recipe.sequenceStart = 101
        XCTAssertEqual(recipe.sequenceNumber(forPhotoAt: 0), 101)
        XCTAssertEqual(recipe.sequenceNumber(forPhotoAt: 9), 110)
        recipe.sequenceStart = 0
        XCTAssertEqual(recipe.sequenceNumber(forPhotoAt: 0), 1,
                       "a stored 0 or negative start must not render {seq} as 0000 or -001")
        recipe.sequenceStart = -40
        XCTAssertEqual(recipe.sequenceNumber(forPhotoAt: 2), 3)
    }

    func testATemplateWithoutNameOrSeqIsFlaggedBeforeTheRunStarts() {
        let contexts = (1...5).map { i in
            ExportNamingContext(source: URL(fileURLWithPath: "/x/DSC_000\(i).NEF"),
                                recipeName: "web", captureDate: components(2026, 6, 14),
                                sequence: i)
        }
        XCTAssertEqual(ExportNaming.distinctNames(template: "{date}", contexts: contexts), 1)
        XCTAssertEqual(ExportNaming.distinctNames(template: "{seq:4}-{date}",
                                                  contexts: contexts), 5)
        XCTAssertFalse(ExportNaming.identifiesEachPhoto("{date}"))
        XCTAssertFalse(ExportNaming.identifiesEachPhoto("{recipe}-{camera}"))
        XCTAssertTrue(ExportNaming.identifiesEachPhoto("{date}-{seq}"))
        XCTAssertTrue(ExportNaming.identifiesEachPhoto("{seq:3}"))
        XCTAssertTrue(ExportNaming.identifiesEachPhoto("{name}-print"))
        XCTAssertTrue(ExportNaming.identifiesEachPhoto(""), "empty renders {name}")
        XCTAssertTrue(ExportNaming.usesSequence("a{seq3}"))
        XCTAssertFalse(ExportNaming.usesSequence("{name}{seq:0}"),
                       "a width outside 1…9 is not a sequence token")
    }

    // MARK: - The rest of docs/11's list

    func testCameraLensISORatingAndLabel() {
        let context = ExportNamingContext(source: Self.nef, recipeName: "web",
                                          camera: "NIKON Z 8", lens: " 24-70mm f/2.8 ",
                                          iso: 800, rating: 4, label: "Red")
        XCTAssertEqual(render("{camera}_{iso}_{rating}_{label}", context),
                       "NIKON Z 8_800_4_Red")
        XCTAssertEqual(render("{lens}", context), "24-70mm f-2.8",
                       "the lens's slash is a separator and is mapped like any other")
        let bare = ExportNamingContext(source: Self.nef, recipeName: "web")
        XCTAssertEqual(render("{name}{camera}{iso}", bare), "DSC_0001",
                       "a value the file does not state renders as nothing, not as text")
    }

    func testAnUnknownTokenStaysVisibleAndIsReported() {
        let context = ExportNamingContext(source: Self.nef, recipeName: "web")
        XCTAssertEqual(render("{name}-{whatever}", context), "DSC_0001-{whatever}")
        XCTAssertEqual(ExportNaming.unknownTokens(in: "{name}-{whatever}{seq:4}{seq:x}"),
                       ["whatever", "seq:x"])
        XCTAssertEqual(render("{name}{unclosed", context), "DSC_0001{unclosed")
    }

    // MARK: - Nothing that named a file before names it differently now

    /// The renderer this replaced (`AppState.renderFilename` before this change),
    /// transcribed with its date supplied rather than read from the filesystem.
    private func legacy(_ template: String, source: URL, recipeName: String,
                        date: String) -> String {
        let name = source.deletingPathExtension().lastPathComponent
        var out = template.isEmpty ? "{name}" : template
        out = out.replacingOccurrences(of: "{name}", with: name)
        out = out.replacingOccurrences(of: "{date}", with: date)
        out = out.replacingOccurrences(of: "{recipe}", with: recipeName)
        out = out.replacingOccurrences(of: "{ext}", with: source.pathExtension)
        let rendered = out.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return RenameTemplate.usableBasename(rendered)
            ?? RenameTemplate.usableBasename(name) ?? "Untitled"
    }

    func testEveryTemplateTheOldGrammarKnewRendersTheSameName() {
        let templates = ["", "{name}", "{name}-print", "{name}-hdr", "{date}_{name}",
                         "{recipe}/{name}", "{name}.{ext}", "client: {name}", "  {name}  ",
                         "{recipe}", "{date}", "{name}-{nope}", "a  b {name}", "{name"]
        let sources = [Self.nef, URL(fileURLWithPath: "/x/IMG 0042.HEIC"),
                       URL(fileURLWithPath: "/x/no-extension")]
        for template in templates {
            for file in sources {
                for recipeName in ["Web sRGB 2048 q90", "", "a:b"] {
                    let context = ExportNamingContext(source: file, recipeName: recipeName,
                                                      fileDate: components(2026, 3, 9))
                    XCTAssertEqual(
                        ExportNaming.render(template: template, context: context),
                        legacy(template, source: file, recipeName: recipeName,
                               date: "2026-03-09"),
                        "\(template) / \(file.lastPathComponent) / \(recipeName)")
                }
            }
        }
    }

    // MARK: - Stored presets

    func testAPresetStoredBeforeSequenceStartExistedCountsFromOne() throws {
        let json = #"{"id":"a","name":"web","filenameTemplate":"{seq}"}"#
        let recipe = try JSONDecoder().decode(ExportRecipe.self, from: Data(json.utf8))
        XCTAssertEqual(recipe.sequenceStart, 1)
        let round = try JSONDecoder().decode(
            ExportRecipe.self,
            from: JSONEncoder().encode(ExportRecipe(name: "x", sequenceStart: 250)))
        XCTAssertEqual(round.sequenceStart, 250)
    }
}

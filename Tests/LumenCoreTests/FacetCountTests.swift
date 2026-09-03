// FacetCountTests.swift
// The one property a filter bar has to have: the number beside a facet is the number of
// rows you get when you click it.
//
// It did not have it. The counts were computed three different ways, none of which was
// the grid's own query, and every one of them was wrong in its own direction:
//
//   · keyword counts came from `allKeywords()`, which groups `photo_keyword` over the
//     WHOLE CATALOG — every folder ever opened — while the grid shows one folder. On a
//     library with a season in it that is two orders of magnitude.
//   · camera and lens counts were folder-scoped but chip-blind: they counted the folder,
//     never the folder as the lit chips had already narrowed it.
//   · flag, rating and label counts were an unfiltered pass over the roll in memory,
//     which is the "★4 · 37" that clicks through to six frames.
//
// So the assertion in here is not a pinned number, it is the EQUALITY: for every facet
// the bar can show, the displayed count and `photos(matching:)`.count of the same click
// are compared to each other. Pinned numbers appear only to prove the fixture actually
// separates the honest answer from the three wrong ones — a fixture where they coincide
// would let this file pass against the code it was written to fail.
//
// Two folders on purpose, and a keyword that lives only in the second one, because a
// single-folder fixture cannot see the scope half of the bug at all.

#if canImport(SQLite3)

import XCTest
@testable import LumenCore

final class FacetCountTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-facets-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() throws -> CatalogStore {
        try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                         cachePath: directory.appendingPathComponent("cache.db").path)
    }

    /// One folder of `count` frames, registered and scanned, ids in scan order.
    private func seed(_ store: CatalogStore, path: String, prefix: String,
                      count: Int) throws -> (Int64, [Int64]) {
        let folderID = try store.registerFolder(path: path)
        let files = (0..<count).map {
            ScannedFile(filename: String(format: "\(prefix)%04d.ARW", $0),
                        fileSize: Int64(40_000_000 + $0),
                        fileMTime: 1_700_000_000, ext: "arw")
        }
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())
        var ids: [Int64] = []
        for file in files {
            if let row = try store.photo(folderID: folderID, filename: file.filename) {
                ids.append(row.id)
            }
        }
        return (folderID, ids)
    }

    /// One facet as the bar draws it: the number it shows, and the click it promises.
    private struct FacetProbe {
        let name: String
        let displayed: Int
        let click: (inout PhotoQuery) -> Void
    }

    // MARK: - The invariant

    func testEveryFacetCountEqualsTheRowsThatFacetReturns() throws {
        let store = try makeStore()
        let (shoot, day) = try seed(store, path: "/Volumes/Shoots/2026-08-20",
                                    prefix: "DSC", count: 6)
        let (_, second) = try seed(store, path: "/Volumes/Shoots/2026-08-21",
                                   prefix: "DSD", count: 5)

        // The folder on screen. Deliberately mixed on every axis at once, so that no
        // single criterion can stand in for another: the Nikon frames are not the
        // low-rated ones, the rejects are not the unlabelled ones, and "portrait" is
        // carried by frames on both sides of the rating threshold.
        let cameras = ["Sony A7 IV", "Sony A7 IV", "Sony A7 IV",
                       "Sony A7 IV", "Nikon Z8", "Nikon Z8"]
        let lenses = ["FE 85mm F1.4 GM", "FE 85mm F1.4 GM", "FE 35mm F1.4 GM",
                      "FE 85mm F1.4 GM", "FE 35mm F1.4 GM", "FE 35mm F1.4 GM"]
        let ratings = [5, 4, 4, 4, 5, 0]
        let flags: [PhotoFlag] = [.pick, .pick, .reject, .unflagged, .pick, .unflagged]
        let labels: [ColorLabel?] = [.red, .green, nil, .red, .blue, nil]
        for (index, id) in day.enumerated() {
            try store.setMetadata(PhotoMetadata(camera: cameras[index],
                                                lens: lenses[index],
                                                iso: 100 * (index + 1)),
                                  photoID: id)
            try store.setRating(ratings[index], photoID: id)
            try store.setFlag(flags[index], photoID: id)
            try store.setLabel(labels[index], photoID: id)
        }
        _ = try store.addKeyword("portrait", photoIDs: [day[0], day[1], day[3], day[5]])
        _ = try store.addKeyword("studio", photoIDs: [day[0], day[4]])
        _ = try store.addKeyword("landscape", photoIDs: [day[2], day[4]])

        // The OTHER folder, which the bar must not count and must not offer. Every
        // frame here is a five-star Sony portrait, so a count that leaks across the
        // folder boundary leaks large and visibly rather than by one or two.
        for id in second {
            try store.setMetadata(PhotoMetadata(camera: "Sony A7 IV",
                                                lens: "FE 85mm F1.4 GM", iso: 400),
                                  photoID: id)
            try store.setRating(5, photoID: id)
            try store.setFlag(.pick, photoID: id)
            try store.setLabel(.red, photoID: id)
        }
        _ = try store.addKeyword("portrait", photoIDs: second)
        _ = try store.addKeyword("wedding", photoIDs: second)

        // The filter the photographer already has on: ★4 and up, shot on the Sony.
        // Two lit criteria, because one is not enough to catch a count that honours
        // some of the bar and not the rest.
        var live = PhotoQuery()
        live.rating = 4
        live.ratingComparison = .atLeast
        live.cameras = ["Sony A7 IV"]
        live.includeMissing = false

        let counts = try store.facetCounts(for: live, folderID: shoot)

        // Every facet the bar draws, in the order the popover draws them.
        var probes: [FacetProbe] = []
        for flag in PhotoFlag.allCases {
            probes.append(FacetProbe(name: "flag \(flag)",
                                     displayed: counts.flags[flag] ?? -1,
                                     click: { $0.flags = [flag] }))
        }
        for stars in 1...5 {
            probes.append(FacetProbe(name: "★\(stars) or better",
                                     displayed: counts.ratingAtLeast[stars],
                                     click: {
                                         $0.rating = stars
                                         $0.ratingComparison = .atLeast
                                     }))
        }
        for label in ColorLabel.allCases {
            probes.append(FacetProbe(name: "label \(label.rawValue)",
                                     displayed: counts.labels[label] ?? -1,
                                     click: {
                                         $0.labels = [label]
                                         $0.includeUnlabeled = false
                                     }))
        }
        probes.append(FacetProbe(name: "unlabelled",
                                 displayed: counts.unlabeled,
                                 click: {
                                     $0.labels = []
                                     $0.includeUnlabeled = true
                                 }))
        for value in counts.cameras {
            probes.append(FacetProbe(name: "camera \(value.value)",
                                     displayed: value.count,
                                     click: { $0.cameras = [value.value] }))
        }
        for value in counts.lenses {
            probes.append(FacetProbe(name: "lens \(value.value)",
                                     displayed: value.count,
                                     click: { $0.lenses = [value.value] }))
        }
        for value in counts.keywords {
            probes.append(FacetProbe(name: "keyword \(value.value)",
                                     displayed: value.count,
                                     click: { $0.keywords = [value.value] }))
        }

        // Twenty-one facets, not three: a bar that got the ratings right and the
        // keywords wrong would still be a bar whose numbers cannot be trusted. Three
        // flags, five stars, five labels, unlabelled, two bodies, two lenses and three
        // keywords is every number the popover puts on screen for this fixture.
        XCTAssertEqual(probes.count, 21,
                       "the fixture stopped offering every facet the bar draws")

        for probe in probes {
            var clicked = live
            probe.click(&clicked)
            let rows = try store.photos(matching: clicked, folderID: shoot).count
            XCTAssertEqual(probe.displayed, rows,
                           "\(probe.name) shows \(probe.displayed) and returns \(rows) "
                               + "— the count and the grid are two different queries")
        }
    }

    // MARK: - That the fixture can tell the honest answer from the wrong ones

    /// Without this, the equality above could pass on a catalog where every wrong
    /// answer happens to coincide with the right one, and would never have caught the
    /// defect it was written for. Each number here is one the bar actually showed.
    func testTheFixtureSeparatesTheHonestCountFromTheOnesTheBarUsedToShow() throws {
        let store = try makeStore()
        let (shoot, day) = try seed(store, path: "/Volumes/Shoots/2026-08-20",
                                    prefix: "DSC", count: 6)
        let (_, second) = try seed(store, path: "/Volumes/Shoots/2026-08-21",
                                   prefix: "DSD", count: 5)
        let cameras = ["Sony A7 IV", "Sony A7 IV", "Sony A7 IV",
                       "Sony A7 IV", "Nikon Z8", "Nikon Z8"]
        let ratings = [5, 4, 4, 4, 5, 0]
        for (index, id) in day.enumerated() {
            try store.setMetadata(PhotoMetadata(camera: cameras[index],
                                                lens: "FE 85mm F1.4 GM",
                                                iso: 100),
                                  photoID: id)
            try store.setRating(ratings[index], photoID: id)
        }
        _ = try store.addKeyword("portrait", photoIDs: [day[0], day[1], day[3], day[5]])
        for id in second {
            try store.setMetadata(PhotoMetadata(camera: "Sony A7 IV",
                                                lens: "FE 85mm F1.4 GM", iso: 400),
                                  photoID: id)
            try store.setRating(5, photoID: id)
        }
        _ = try store.addKeyword("portrait", photoIDs: second)
        _ = try store.addKeyword("wedding", photoIDs: second)

        var live = PhotoQuery()
        live.rating = 4
        live.ratingComparison = .atLeast
        live.cameras = ["Sony A7 IV"]
        live.includeMissing = false
        let counts = try store.facetCounts(for: live, folderID: shoot)

        // THE KEYWORD, across the whole library, is what the chip used to say.
        XCTAssertEqual(try store.allKeywords()
                        .first(where: { $0.value == "portrait" })?.count, 9,
                       "the vocabulary list is library-wide and should stay that way")
        // The folder alone would be four. The folder as ★4-and-Sony has narrowed it is
        // three, and three is what clicking returns.
        XCTAssertEqual(counts.keywords.first(where: { $0.value == "portrait" })?.count, 3,
                       "the keyword count is neither the library's 9 nor the folder's 4")

        // A keyword that exists only in the OTHER folder is not a value this folder's
        // menu may offer at all — a row that returns nothing is a control that does
        // nothing, and it is only there because the domain was read library-wide.
        XCTAssertNil(counts.keywords.first(where: { $0.value == "wedding" }),
                     "a keyword from another folder was offered in this folder's menu")

        // The camera the lit rating excludes: two frames carry it, one survives ★4.
        XCTAssertEqual(counts.cameras.first(where: { $0.value == "Nikon Z8" })?.count, 1,
                       "the camera count ignored the rating chip that is already lit")

        // And the star that started the report: the roll holds five frames at ★4 or
        // better, but only four of them are Sony, and Sony is lit.
        XCTAssertEqual(counts.ratingAtLeast[4], 4,
                       "the rating count ignored the camera chip that is already lit")
        XCTAssertEqual(counts.ratingAtLeast[5], 1,
                       "the rating count ignored the camera chip that is already lit")
    }
}

#endif

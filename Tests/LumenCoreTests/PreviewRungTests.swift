// PreviewRungTests.swift
// I3-01: a settled develop frame was filed at the `fit` rung whatever size it was, so
// the disk cache could serve a preview softer than the rung it was stored under — and
// I3-02: the process-wide decode budget advertised at 768 MB whose enforceable floor is
// 1792 MB.
//
// The fixes for both were written before any test existed for either, which is the
// situation this file is here to end. What each half can be proved by is different and
// the difference is the whole design of the file:
//
// · The WRITER'S RULE is `PreviewCache.pixelsFilled(byPayloadLongEdge:)`, in LumenCore,
//   so it is tested BEHAVIOURALLY — not "the function is called somewhere" but the
//   property itself: a small payload filed by the rule is never afterwards SERVED by
//   `decide` to a request larger than the pixels it actually holds. That closes the
//   loop the defect ran round, because `decide`'s "never upward" rule was never wrong;
//   it was being enforced against a rung number that had stopped being true.
//
// · The CALL SITE is `ThumbnailLoader.recordDeveloped`, in LumenApp, which has no test
//   target on this lane, so it is read as TEXT with comments stripped. Stripping is
//   load-bearing rather than tidy: the fixed function's own doc comment names
//   `PreviewCache.pixelsFilled(byPayloadLongEdge:)` AND quotes the defective
//   `ThumbnailLadder.pixels(for: .fit)` it replaced, so an unstripped scan would pass
//   its positive assertion on prose alone and fail its negative one on prose alone.
//   The helper is `DeliveryNameTests`', copied rather than shared so this file stands on
//   its own.
//
// · I3-02 has NO FIX IN THE TREE — `RenderCoordinator.trimDecodeResidency` is untouched
//   — so the second class below does not test a fix. It re-derives the floor from the
//   four constants the trim is built out of, pins them where they live, and states the
//   arithmetic as assertions so the number stops being a claim in a document.

import XCTest
@testable import LumenCore

// MARK: - I3-01

final class PreviewRungTests: XCTestCase {

    // MARK: The rule

    /// The boundaries, one on each side. A rung is FILLED by a payload that holds at
    /// least the rung's pixels; one pixel short of a rung is the rung below, and one
    /// pixel short of `thumb` is no row at all.
    func testARungIsFilledOnlyByAPayloadThatHoldsItsPixels() {
        XCTAssertNil(PreviewCache.rungFilled(byPayloadLongEdge: 255))
        XCTAssertNil(PreviewCache.rungFilled(byPayloadLongEdge: 1))
        XCTAssertEqual(PreviewCache.rungFilled(byPayloadLongEdge: 256), .thumb)
        XCTAssertEqual(PreviewCache.rungFilled(byPayloadLongEdge: 1023), .thumb)
        XCTAssertEqual(PreviewCache.rungFilled(byPayloadLongEdge: 1024), .grid)
        XCTAssertEqual(PreviewCache.rungFilled(byPayloadLongEdge: 2559), .grid)
        XCTAssertEqual(PreviewCache.rungFilled(byPayloadLongEdge: 2560), .fit)
        XCTAssertEqual(PreviewCache.rungFilled(byPayloadLongEdge: 9000), .fit)

        // Degenerate sizes answer "no rung" rather than the bottom one. A caller that
        // cannot say how big its image is has not earned a row.
        XCTAssertNil(PreviewCache.rungFilled(byPayloadLongEdge: 0))
        XCTAssertNil(PreviewCache.rungFilled(byPayloadLongEdge: -1))
        XCTAssertNil(PreviewCache.pixelsFilled(byPayloadLongEdge: 0))

        // The size form and the level form are the same rule. They have to be: the
        // writer names a size, `PreviewStore.plan` turns it straight back into a level,
        // and the defect's shape was exactly a rung and a pixel count chosen apart.
        for edge in [0, 1, 255, 256, 700, 1024, 2559, 2560, 5000] {
            let level = PreviewCache.rungFilled(byPayloadLongEdge: edge)
            XCTAssertEqual(PreviewCache.pixelsFilled(byPayloadLongEdge: edge),
                           level.flatMap { ThumbnailLadder.pixels(for: $0) },
                           "the level and the size disagree at \(edge)")
        }
    }

    /// `oneToOne` has no size, so no payload can fill it however large — which is what
    /// keeps this rule from inventing the one rung the app does not build.
    func testNoPayloadEverFillsTheUnbuiltRung() {
        for edge in [256, 2560, 8000, 45_000, Int.max / 2] {
            XCTAssertNotEqual(PreviewCache.rungFilled(byPayloadLongEdge: edge), .oneToOne)
        }
        XCTAssertNil(ThumbnailLadder.pixels(for: .oneToOne))
    }

    // MARK: The writer, as the app performs it

    /// The audit's named test. `recordDeveloped` hands a 900-px settle to
    /// `pixelsFilled`, `PreviewStore.plan` turns that into a level and
    /// `PreviewStore.persist` files the row — so this is the whole write path, minus
    /// the disk.
    func testALumenRowIsNeverFiledAtARungItsPixelsCannotFill() throws {
        let settle = try XCTUnwrap(Self.filed(payloadLongEdge: 900, fingerprint: "xxh64:new"))
        XCTAssertNotEqual(settle.level, .fit,
                          "a 900 px settle was filed at the 2560 rung; decide will "
                          + "serve it to a fit request and report a hit")
        XCTAssertEqual(settle.level, .thumb, "900 px fills 256 and not 1024")
        XCTAssertEqual(settle.recipeFP, "xxh64:new",
                       "a Lumen render is the user's recipe or it is nothing")
        XCTAssertEqual(settle.source, .lumen)

        // The windowed-loupe band the finding is about, end to end.
        XCTAssertEqual(Self.filed(payloadLongEdge: 640, fingerprint: "f")?.level, .thumb)
        XCTAssertEqual(Self.filed(payloadLongEdge: 1600, fingerprint: "f")?.level, .grid)
        XCTAssertEqual(Self.filed(payloadLongEdge: 2560, fingerprint: "f")?.level, .fit)

        // And a frame too small to fill anything is not filed at all, rather than filed
        // at the bottom rung it cannot fill either.
        XCTAssertNil(Self.filed(payloadLongEdge: 200, fingerprint: "f"))
    }

    /// THE PROPERTY, which is the point of doing this in LumenCore rather than by
    /// reading LumenApp: for every payload size a viewer can settle at, and every
    /// request a reader can make, a row filed by the rule is served only to a request
    /// the payload's own pixels can answer.
    ///
    /// `decide` refuses to answer a big request with a small ROW; this asserts the half
    /// `decide` cannot see, that the row's rung is not itself a claim the payload
    /// cannot back. The two together are "never upward" as a fact about pixels rather
    /// than about enum cases.
    func testNoFiledPayloadIsEverServedToARequestLargerThanItself() {
        let fingerprint = "xxh64:new"
        for payload in 1...3000 {
            guard let row = Self.filed(payloadLongEdge: payload,
                                       fingerprint: fingerprint) else { continue }
            for request in PreviewLevel.allCases {
                guard case .serve(let served) = PreviewCache.decide(request: request,
                                                                    fingerprint: fingerprint,
                                                                    stored: [row])
                else { continue }
                guard let wanted = ThumbnailLadder.pixels(for: request) else {
                    XCTFail("\(request) has no size and was served anyway")
                    continue
                }
                XCTAssertLessThanOrEqual(
                    wanted, payload,
                    "a \(payload) px payload filed at \(served.level) was served to a "
                    + "\(request) request for \(wanted) px — softer than the ask, and "
                    + "the cache reports a hit")
                // The reader asks the payload for `readPixels`, so that is the number
                // that must be inside the payload, not merely the rung's.
                guard let read = PreviewCache.readPixels(request: request, served: served) else {
                    XCTFail("a served row has no read size at \(request)")
                    continue
                }
                XCTAssertLessThanOrEqual(read, payload,
                                         "the reader will ask for \(read) px from a "
                                         + "\(payload) px payload")
            }
        }
    }

    /// The owner's symptom, stated as an assertion: the photograph he EDITED must not
    /// come back softer than the one he did not.
    ///
    /// The camera's own embedded `fit` row is full size. Before the fix, a 900 px settle
    /// was filed as a `fit` row under the current fingerprint, scored `.current`, and
    /// won `decide`'s tie against it — so the loupe's instant path asked for 2560 and
    /// received 900, on the one rung where the 50 ms goal is measured.
    func testASoftSettleDoesNotDisplaceTheCamerasOwnFitRow() throws {
        let fingerprint = "xxh64:new"
        let camera = PreviewRow(photoID: 1, level: .fit, recipeFP: "", source: .embedded,
                                path: "previews/ab/camera.heic", bytes: 4_000_000)
        let settle = try XCTUnwrap(Self.filed(payloadLongEdge: 900,
                                              fingerprint: fingerprint))

        for stored in [[camera, settle], [settle, camera]] {
            XCTAssertEqual(PreviewCache.decide(request: .fit, fingerprint: fingerprint,
                                               stored: stored),
                           .serve(camera),
                           "the loupe's fit request was answered by the settle instead "
                           + "of the camera's full-size row")
        }
        XCTAssertEqual(PreviewCache.readPixels(request: .fit, served: camera), 2560)
    }

    /// …and the fix is not a no-op that simply stops writing. A settle big enough to
    /// fill a rung still reaches the cache at that rung, and still wins the handoff
    /// docs/10 §10.1 describes: at one rung, Lumen's render of the CURRENT recipe is
    /// preferred to the camera's.
    ///
    /// Worth pinning because the old writer broke this too, in the other direction: a
    /// 1600 px settle filed at `fit` did not answer a `grid` request at all, since
    /// `decide` takes the smallest servable rung and the camera's grid row is smaller.
    func testASettleThatFillsARungStillReachesTheContactSheetAtThatRung() throws {
        let fingerprint = "xxh64:new"
        let cameraGrid = PreviewRow(photoID: 1, level: .grid, recipeFP: "",
                                    source: .embedded, path: "previews/ab/camera.heic",
                                    bytes: 400_000)
        let settle = try XCTUnwrap(Self.filed(payloadLongEdge: 1600,
                                              fingerprint: fingerprint))
        XCTAssertEqual(settle.level, .grid)

        for stored in [[cameraGrid, settle], [settle, cameraGrid]] {
            XCTAssertEqual(PreviewCache.decide(request: .grid, fingerprint: fingerprint,
                                               stored: stored),
                           .serve(settle),
                           "the user's own render of the current recipe lost the "
                           + "handoff at its own rung")
        }
        // Read down to the rung, which the payload covers with 576 px to spare.
        XCTAssertEqual(PreviewCache.readPixels(request: .grid, served: settle), 1024)
    }

    // MARK: What the downgrade costs, pinned rather than argued

    /// A consequence of choosing "file at the rung it fills" over "refuse", and the one
    /// a reviewer should look at hardest: the rung a windowed settle lands on is
    /// `thumb`, and `thumb` is the rung NOTHING ever reclaims.
    ///
    /// `invalidatePreviews` deletes `level >= 2`, so it never sees this row;
    /// `freshness` calls it `.browsable` rather than `.stale` after the next edit, so
    /// nothing marks its payload for unlinking; and `pruneCache` evicts 1:1 → fit → grid
    /// and stops (docs/15 §15.6: level 0 is permanent). One settle per gesture under a
    /// new fingerprint is therefore one permanent row and one permanent file, for a
    /// payload of the window's size that no `thumb` request will ever need more than
    /// 256 px of.
    ///
    /// Not a defect in the never-upward rule — nothing wrong is ever shown — which is
    /// exactly why it needs pinning somewhere a person will read it.
    func testTheRungAWindowedSettleLandsOnIsTheOneNothingReclaims() throws {
        let settle = try XCTUnwrap(Self.filed(payloadLongEdge: 640,
                                              fingerprint: "xxh64:one"))
        XCTAssertEqual(settle.level, .thumb)
        XCTAssertTrue(PreviewCache.isBrowseRung(settle.level))
        XCTAssertEqual(PreviewCache.freshness(of: settle, against: "xxh64:two"),
                       .browsable,
                       "a superseded settle at thumb is never stale, so nothing ever "
                       + "unlinks its payload")
        XCTAssertLessThan(settle.level.rawValue, PreviewLevel.fit.rawValue,
                          "invalidatePreviews' `level >= 2` predicate does not reach it")
    }

    /// The second consequence, and the reason the first is not merely wasteful: this
    /// fix makes `.lumen` rows reachable at the BROWSE rungs for the first time, and at
    /// a browse rung two rows can now be `.browsable` at once — the camera's, and a
    /// render of a recipe the user has moved past. `decide` ranks them equally and takes
    /// whichever it met first, so which picture the contact sheet shows is decided by
    /// the order SQLite returned the rows in.
    ///
    /// Pinned as behaviour, not endorsed. If this goes red because `decide` grew a
    /// tie-break for equal-rank rows, that is the right fix and this test should be
    /// rewritten to assert it.
    func testTwoBrowsableRowsAtOneRungAreDecidedByArrivalOrder() throws {
        let camera = PreviewRow(photoID: 1, level: .grid, recipeFP: "", source: .embedded,
                                path: "previews/ab/camera.heic", bytes: 400_000)
        let supersededEdit = try XCTUnwrap(Self.filed(payloadLongEdge: 1600,
                                                      fingerprint: "xxh64:one"))
        let now = "xxh64:two"
        XCTAssertEqual(PreviewCache.freshness(of: camera, against: now), .browsable)
        XCTAssertEqual(PreviewCache.freshness(of: supersededEdit, against: now), .browsable)

        XCTAssertEqual(PreviewCache.decide(request: .grid, fingerprint: now,
                                           stored: [camera, supersededEdit]),
                       .serve(camera))
        XCTAssertEqual(PreviewCache.decide(request: .grid, fingerprint: now,
                                           stored: [supersededEdit, camera]),
                       .serve(supersededEdit),
                       "the contact sheet's picture depends on row order")
    }

    // MARK: The call site (LumenApp, read as text)

    /// `ThumbnailLoader.recordDeveloped` must derive its rung from the payload's own
    /// pixels. Comments stripped first — the function's doc comment names both the rule
    /// it now uses and the constant it used to use, so an unstripped scan proves
    /// nothing in either direction.
    func testTheDevelopWriterDerivesItsRungFromThePayloadsOwnPixels() throws {
        let source = stripComments(try Self.source("LumenApp/ThumbnailLoader.swift"))
        let start = try XCTUnwrap(source.range(of: "func recordDeveloped(")).upperBound
        let body = String(source[start...].prefix(600))

        XCTAssertTrue(body.contains("image.width"),
                      "recordDeveloped never reads the image it is filing")
        XCTAssertTrue(body.contains("image.height"),
                      "a portrait settle's long edge is its height")
        XCTAssertTrue(body.contains("PreviewCache.pixelsFilled(byPayloadLongEdge:"),
                      "the rung must come from the LumenCore rule, which is the only "
                      + "half of this that can be tested")
        XCTAssertFalse(source.contains("ThumbnailLadder.pixels(for: .fit)"),
                       "the loader names the 2560 rung again; that constant is what "
                       + "I3-01 was")
    }

    /// The rule is a convention, not a type — `rowForDecode` still takes a bare
    /// `pixels:` and cannot tell a settle from an extraction made at the ask. So the
    /// invariant is "there is exactly one writer of `.lumen` rows in the app, and it is
    /// the one above". A second one is how this comes back.
    func testThereIsExactlyOneDevelopWriterInTheApp() throws {
        var writers: [String] = []
        for file in try Self.appFiles() {
            let text = stripComments(try Self.source("LumenApp/\(file)"))
            if text.contains("source: .lumen") { writers.append(file) }
        }
        XCTAssertEqual(writers, ["ThumbnailLoader.swift"],
                       "a second writer of Lumen-render rows exists; it must pick its "
                       + "size with PreviewCache.pixelsFilled(byPayloadLongEdge:) or it "
                       + "reintroduces I3-01")
    }

    /// The stripper is the proof's foundation, so it is asserted rather than assumed —
    /// this project has twice had a text scan pass on a doc comment.
    func testTheCommentStripperIsWhatMakesTheScanAProof() {
        let sample = """
        /// Files at PreviewCache.pixelsFilled(byPayloadLongEdge:) rather than at
        /// ThumbnailLadder.pixels(for: .fit), which is what I3-01 was.
        // image.width is read here.
        /* ThumbnailLadder.pixels(for: .fit) */
        let kept = image.height
        """
        let stripped = stripComments(sample)
        XCTAssertFalse(stripped.contains("pixelsFilled"))
        XCTAssertFalse(stripped.contains("ThumbnailLadder.pixels(for: .fit)"))
        XCTAssertFalse(stripped.contains("image.width"))
        XCTAssertTrue(stripped.contains("let kept = image.height"))
    }

    // MARK: helpers

    /// The app's write path with the disk taken out: `recordDeveloped` picks the size
    /// from the payload, `PreviewStore.plan` turns it back into a level, and
    /// `PreviewStore.persist` builds the row from it.
    ///
    /// THE SUBSTITUTION for the LumenCore half goes in here, at `pixelsFilled` — put
    /// `ThumbnailLadder.pixels(for: .fit)` back and every behavioural test above fails.
    private static func filed(payloadLongEdge: Int, fingerprint: String) -> PreviewRow? {
        guard let pixels = PreviewCache.pixelsFilled(byPayloadLongEdge: payloadLongEdge)
        else { return nil }
        return PreviewCache.rowForDecode(photoID: 1, pixels: pixels,
                                         currentFingerprint: fingerprint,
                                         source: .lumen,
                                         path: "previews/cd/settle.heic",
                                         bytes: 1)
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: repositorySources.appendingPathComponent(relative),
                   encoding: .utf8)
    }

    private static func appFiles() throws -> [String] {
        let directory = repositorySources.appendingPathComponent("LumenApp")
        return try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
    }

    private static var repositorySources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }
}

// MARK: - I3-02

/// The process-wide decode budget, BEFORE it was fixed. Kept as the record of what the
/// floor was, not as a claim about what it is.
///
/// These three compute from literals and never read a source, so they stay green while
/// describing a world that no longer exists — which is why they are labelled here rather
/// than left to be mistaken for live assertions. The fix landed: the trim is exhaustive,
/// the budget is derived instead of declared, and the enforceable ceiling is 1344 MiB
/// reachable where this class measured 1792 MiB unreachable.
///
/// The reason 768 MiB was never met is worth keeping too, because it is the whole shape
/// of the finding: a single source may legally hold a 320 MiB interactive working set
/// PLUS a budget-exempt inspection plane of up to 512 MiB, and the trim must never take
/// from the photograph being rendered — that is the 457 ms re-demosaic the decode cache
/// exists to prevent. 832 > 768 at ONE source, so no trim, however exhaustive, could
/// have reached the advertised number. The policy was right; the multiplication had
/// never been done.
///
/// What is live now is `DecodeResidencyPlanTests` in LumenCore, which sweeps every
/// source count against every live-set size at their ceilings and proves the residual
/// is under budget.
final class DecodeResidencyBudgetTests: XCTestCase {

    private static let mib = 1024 * 1024
    // `testTheConstantsTheFloorIsBuiltFromAreStillTheseOnes` used to sit here, and it
    // did exactly what it promised: it went red the day the trim was made exhaustive,
    // and it said so. Its three assertions asserted that the budget was still the
    // unreachable 768 MiB, that pass one still spared the newest source, and that pass
    // two still spared the alternating four. All three are now false by design.
    //
    // Deleted rather than updated, because its job is finished and
    // `DecodeResidencyPlanTests` in LumenCore does the same work properly — it sweeps
    // 1–12 sources against 1–6 live sets at their ceilings and proves the residual is
    // under budget, which is a theorem rather than four constants multiplied by hand.

    func testTheEnforceableResidencyFloorIsTwoAndAThirdTimesTheAdvertisedBudget() {
        let advertised = 768 * Self.mib
        let interactive = 320 * Self.mib
        let plane = DraftLadder.materializedDecodeByteCeiling
        let live = 4

        let newest = interactive + plane
        let alsoSpared = (live - 1) * interactive
        let floor = newest + alsoSpared

        XCTAssertEqual(newest / Self.mib, 832)
        XCTAssertEqual(alsoSpared / Self.mib, 960)
        XCTAssertEqual(floor / Self.mib, 1792)
        XCTAssertEqual(floor, 1792 * Self.mib)
        XCTAssertGreaterThan(floor, advertised,
                             "a budget the trim cannot get under is not a budget")
        XCTAssertEqual(Double(floor) / Double(advertised), 2.3333, accuracy: 0.0001)
    }

    /// The realistic floor, on the file the owner actually works on. Reported as
    /// 1542 MB by the audit, which adds a decimal-MB plane (262) to binary-MiB budgets;
    /// in one unit it is 1529 MiB. The conclusion is unchanged and the number is not, so
    /// the number is written here in the unit the constants are in.
    func testTheOwnersOwnFileLeavesFifteenHundredMegabytesBehind() {
        let interactive = 320 * Self.mib
        let plane = 7008 * 4672 * 8          // half-float RGBA, the owner's 33 MP ARW
        XCTAssertEqual(plane, 261_931_008)
        XCTAssertTrue(DraftLadder.mayHoldAsPixels(width: 7008, height: 4672,
                                                  bytesPerPixel: 8),
                      "the plane must be holdable, or the exemption never applies")

        let floor = (interactive + plane) + 3 * interactive
        XCTAssertEqual(floor / Self.mib, 1529)
        XCTAssertGreaterThan(floor, 768 * Self.mib)
    }

    /// The two everyday shapes where the trim runs and frees nothing at all — the part
    /// of the finding that is not about a headline number.
    func testTheTwoOrdinaryCasesWhereTheTrimCanFreeNothing() {
        let advertised = 768 * Self.mib
        let interactive = 320 * Self.mib
        let ceiling = DraftLadder.materializedDecodeByteCeiling

        // Two-up compare. `sourceOrder` is 2, so `cold` is one URL and `alternating` is
        // both: pass one drops the older pane's plane, and pass two's `where` clause is
        // empty. What is left is the newest source entire plus the older's interactive
        // set.
        let twoUp = (interactive + ceiling) + interactive
        XCTAssertEqual(twoUp / Self.mib, 1152)
        XCTAssertGreaterThan(twoUp, advertised)

        let arwPlane = 7008 * 4672 * 8
        let twoUpReal = (interactive + arwPlane) + interactive
        XCTAssertEqual(twoUpReal / Self.mib, 889)   // the audit prints 902, mixing units
        XCTAssertGreaterThan(twoUpReal, advertised,
                             "over budget with nothing the trim is allowed to take")

        // One loupe on a 60 MP body. The single source IS `sourceOrder.last`, so
        // `dropLast()` empties the list before either pass begins: `trimDecodeResidency`
        // iterates nothing and returns while the process is over budget.
        let sixtyPlane = 9504 * 6336 * 8
        XCTAssertEqual(sixtyPlane, 481_738_752)
        XCTAssertTrue(DraftLadder.mayHoldAsPixels(width: 9504, height: 6336,
                                                  bytesPerPixel: 8),
                      "under the 512 MiB ceiling, so this plane really is held")
        let single = sixtyPlane + interactive
        XCTAssertEqual(single / Self.mib, 779)      // the audit prints 801, mixing units
        XCTAssertGreaterThan(single, advertised)
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        return try String(contentsOf: root.appendingPathComponent(relative),
                          encoding: .utf8)
    }
}

// MARK: - the scan's foundation

/// `DeliveryNameTests.strippingComments`, copied. A scan that reads doc comments proves
/// only that somebody wrote the symbol's name down.
private func stripComments(_ source: String) -> String {
    var out = ""
    var index = source.startIndex
    var inBlock = false
    while index < source.endIndex {
        let rest = source[index...]
        if inBlock {
            if rest.hasPrefix("*/") { inBlock = false; index = source.index(index, offsetBy: 2) }
            else { index = source.index(after: index) }
            continue
        }
        if rest.hasPrefix("/*") { inBlock = true; index = source.index(index, offsetBy: 2); continue }
        if rest.hasPrefix("//") {
            while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
            continue
        }
        out.append(source[index])
        index = source.index(after: index)
    }
    return out
}

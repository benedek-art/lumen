// BackupPolicyTests.swift
// J1-04 / K-019: the restore path that exists and works had, on a typical install, zero
// inputs. `backup()`'s only caller was a menu item, nothing pruned what it wrote, and
// `recoverIfNeeded` walked an empty directory.
//
// Three things are pinned here, in the order they have to be true:
//
//   1. the retention policy, as a pure function over dated filenames — including the
//      one rule that makes it safe to run at all, that the newest is never deleted;
//   2. the once-per-N-hours stamp, which is what turns "back up on quit" into "back up
//      on quit, once a day" rather than "back up nine times during an import session";
//   3. `recoverIfNeeded` against exactly what the backup path now leaves in `backups/`
//      — not against a directory a test hand-built to be convenient.
//
// (3) is the one that would have caught the defect. A prune policy that passes its own
// unit test and leaves behind names the restore walk skips is worth nothing, so the
// recovery test here builds its directory by running the real snapshot path and the
// real prune plan, and then damages the catalog.

import XCTest
@testable import LumenCore

final class BackupPolicyTests: XCTestCase {

    // MARK: - Fixture

    /// Twelve dated snapshots, six weeks of a photographer who backs up most evenings.
    /// 2026-08-31 is a Monday, so the newest four straddle a week boundary — the case
    /// where "newest K" and "one per week" disagree about a file, which is the only
    /// case where having both rules means anything.
    private static let twelve = [
        "lumen-2026-09-02T21-00-00Z.db",   // newest         week 2957
        "lumen-2026-09-02T09-00-00Z.db",   //                week 2957
        "lumen-2026-09-01T21-00-00Z.db",   //                week 2957
        "lumen-2026-08-31T21-00-00Z.db",   // Monday         week 2957
        "lumen-2026-08-28T21-00-00Z.db",   //                week 2956
        "lumen-2026-08-26T21-00-00Z.db",   //                week 2956
        "lumen-2026-08-21T21-00-00Z.db",   //                week 2955
        "lumen-2026-08-19T21-00-00Z.db",   //                week 2955
        "lumen-2026-08-14T21-00-00Z.db",   //                week 2954
        "lumen-2026-08-07T21-00-00Z.db",   //                week 2953
        "lumen-2026-07-31T21-00-00Z.db",   //                week 2952
        "lumen-2026-07-24T21-00-00Z.db",   //                week 2951
    ]

    // MARK: - The policy, as arithmetic

    /// The whole retained set, named. Not a count and not a spot check: the assertion
    /// is that the policy keeps *these six and no others*, so a change to K, to W or to
    /// the week boundary has to be argued for here before it can ship.
    ///
    /// Substitution proof — drop rule 3 (the weekly tier) and keep only the newest K:
    /// the first assertion fails with
    ///   XCTAssertEqual failed: ("["lumen-2026-09-02T21-00-00Z.db",
    ///   "lumen-2026-09-02T09-00-00Z.db", "lumen-2026-09-01T21-00-00Z.db"]") is not
    ///   equal to ("[... , "lumen-2026-08-28T21-00-00Z.db",
    ///   "lumen-2026-08-21T21-00-00Z.db", "lumen-2026-08-14T21-00-00Z.db"]")
    /// — three weekly representatives missing. Drop rule 2 instead and keep only one
    /// per week, and the same assertion fails the other way: 09-02T09 and 09-01T21 are
    /// gone from `retained` and have appeared in `victims`.
    func testTwelveDatedSnapshotsRetainExactlyThePolicysSet() {
        let plan = BackupRetention.plan(names: Self.twelve)

        XCTAssertEqual(plan.retained, [
            // the newest three (rule 2)
            "lumen-2026-09-02T21-00-00Z.db",
            "lumen-2026-09-02T09-00-00Z.db",
            "lumen-2026-09-01T21-00-00Z.db",
            // one per week for the three weeks behind them (rule 3); the fourth week's
            // representative is the newest file itself, which rule 2 already keeps
            "lumen-2026-08-28T21-00-00Z.db",
            "lumen-2026-08-21T21-00-00Z.db",
            "lumen-2026-08-14T21-00-00Z.db",
        ])

        XCTAssertEqual(plan.victims, [
            // in the newest week but neither in the newest three nor its newest member
            "lumen-2026-08-31T21-00-00Z.db",
            "lumen-2026-08-26T21-00-00Z.db",
            "lumen-2026-08-19T21-00-00Z.db",
            // past the four-week cap
            "lumen-2026-08-07T21-00-00Z.db",
            "lumen-2026-07-31T21-00-00Z.db",
            "lumen-2026-07-24T21-00-00Z.db",
        ])

        // Every input is accounted for exactly once. A policy that silently drops a
        // name from both lists would leave a file nobody ever deletes and nobody ever
        // counts, which is how the unbounded directory in the audit happened.
        XCTAssertEqual(Set(plan.retained).union(plan.victims), Set(Self.twelve))
        XCTAssertTrue(Set(plan.retained).isDisjoint(with: Set(plan.victims)))
        XCTAssertEqual(plan.retained.count + plan.victims.count, Self.twelve.count)
    }

    /// The rule that makes the policy safe to run: whatever else happens, the newest
    /// snapshot is still there afterwards.
    ///
    /// "Newest" is checked under BOTH orderings that matter, because they are not the
    /// same ordering and only one of them is the one a restore uses: the newest by the
    /// timestamp in the name, and the first name `CatalogStore.recoverIfNeeded` reaches
    /// (it sorts the directory descending and walks it).
    ///
    /// Substitution proof — delete the unconditional `keep.insert` for the newest and
    /// lean on K ≥ 1 instead, then set `keepNewest` to 0 somewhere: the "keep nothing"
    /// case below fails with
    ///   XCTAssertFalse failed - keeping nothing deleted the newest snapshot
    ///   (lumen-2026-09-02T21-00-00Z.db)
    /// Substitute the whole plan for `victims = names` and every case here fails, the
    /// empty one excepted.
    func testTheNewestIsNeverAVictimAcrossEveryDegenerateInput() {
        let cases: [(String, [String])] = [
            ("nothing at all", []),
            ("one file", ["lumen-2026-09-02T21-00-00Z.db"]),
            ("the twelve", Self.twelve),
            ("the twelve, listed oldest first", Array(Self.twelve.reversed())),
            ("nine snapshots on one day", (0..<9).map {
                String(format: "lumen-2026-09-02T%02d-00-00Z.db", $0)
            }),
            ("two names for one instant", [
                "lumen-2026-09-02T21-00-00Z.db",
                "lumen-2026-09-02T21-00-00Z-copy.db",
                "lumen-2026-09-01T21-00-00Z.db",
                "lumen-2026-08-01T21-00-00Z.db",
            ]),
            ("names this policy cannot date", [
                "lumen-2026-09-02T21-00-00Z.db", "handmade.db", "lumen-.db",
            ]),
            ("nothing datable at all", ["handmade.db", "zzz.db"]),
        ]

        for (label, names) in cases {
            let plan = BackupRetention.plan(names: names)
            assertNewestSurvives(plan, names, label)

            // And with a caller that asked for the smallest policy the type allows.
            let minimal = BackupRetention.plan(names: names, keepNewest: 0, keepWeeks: 0)
            assertNewestSurvives(minimal, names, label + ", keeping nothing")
        }
    }

    /// A caller cannot ask for a policy that keeps nothing. `keepNewest: 0` is clamped
    /// to one, and the one it keeps is the newest.
    ///
    /// Substitution proof — remove the `max(keepNewest, 1)` clamp AND the unconditional
    /// newest rule: this fails with
    ///   XCTAssertEqual failed: ("[]") is not equal to
    ///   ("["lumen-2026-09-02T21-00-00Z.db"]")
    func testTheNewestSurvivesEvenWhenTheCallerAsksToKeepNothing() {
        let plan = BackupRetention.plan(names: Self.twelve, keepNewest: 0, keepWeeks: 0)
        XCTAssertEqual(plan.retained, ["lumen-2026-09-02T21-00-00Z.db"])
        XCTAssertEqual(plan.victims.count, 11)
    }

    /// A file this code did not write is not this code's to delete — and the directory
    /// a damaged catalog is restored from is the last place to be clever about tidying.
    ///
    /// Substitution proof — make `plan` treat an unparseable name as infinitely old
    /// instead of retaining it: the first assertion fails with
    ///   XCTAssertEqual failed: ("["handmade.db"]") is not equal to ("[]")
    /// reported through `plan.victims`.
    func testANameThePolicyCannotDateIsNeverDeleted() {
        let names = Self.twelve + ["handmade.db", "lumen-not-a-date.db", "notes.txt.db"]
        let plan = BackupRetention.plan(names: names)

        XCTAssertTrue(plan.retained.contains("handmade.db"))
        XCTAssertTrue(plan.retained.contains("lumen-not-a-date.db"))
        XCTAssertTrue(plan.retained.contains("notes.txt.db"))
        XCTAssertFalse(plan.victims.contains(where: {
            BackupRetention.timestamp(inBackupName: $0) == nil
        }), "an undatable name was deleted")

        // The datable ones are pruned exactly as before — one stray file does not
        // change anybody else's fate.
        XCTAssertEqual(plan.victims, BackupRetention.plan(names: Self.twelve).victims)
    }

    /// The weekly tier: one representative per week, newest of that week, capped.
    ///
    /// The cap is this project's addition to the audit's rule, and it is the difference
    /// between a bounded directory and one full copy of a multi-gigabyte catalog per
    /// week forever. Pinned here so removing it is a test change, not a silent one.
    ///
    /// Substitution proof — drop the `weeksSeen.count < weeksKept` guard so the tier is
    /// unbounded: with `keepNewest: 1` every one of the six weeks behind the newest
    /// keeps a representative, and the first assertion fails with a seven-element
    /// `retained` against the two named below, followed by
    ///   XCTAssertEqual failed: ("7") is not equal to ("2")
    func testTheWeeklyTierIsCappedAndKeepsTheNewestOfEachWeek() {
        let plan = BackupRetention.plan(names: Self.twelve, keepNewest: 1, keepWeeks: 2)

        XCTAssertEqual(plan.retained, [
            "lumen-2026-09-02T21-00-00Z.db",   // newest, and week 2957's representative
            "lumen-2026-08-28T21-00-00Z.db",   // week 2956's newest, not 08-26
        ])
        XCTAssertEqual(plan.retained.count, 2)
        XCTAssertFalse(plan.retained.contains("lumen-2026-08-26T21-00-00Z.db"),
                       "the weekly tier kept the older member of a week")

        let capped = BackupRetention.plan(names: Self.twelve, keepNewest: 3, keepWeeks: 4)
        XCTAssertEqual(capped.retained.count, 6)
    }

    /// `FileManager.contentsOfDirectory` promises no order. The plan must not depend on
    /// one it did not sort itself.
    func testTheOrderOfTheDirectoryListingDoesNotChangeThePlan() {
        let forwards = BackupRetention.plan(names: Self.twelve)
        let backwards = BackupRetention.plan(names: Array(Self.twelve.reversed()))
        let shuffled = BackupRetention.plan(names: Self.twelve.sorted())
        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards, shuffled)
    }

    /// The name shapes the parser accepts, and one it must not: a stamp it cannot read
    /// has to come back nil rather than as an arbitrary instant, because a name dated
    /// wrongly is a name deleted in the wrong order.
    func testBackupNamesAreDatedFromTheNameAndNeverFromTheFilesystem() {
        XCTAssertEqual(BackupRetention.timestamp(
            inBackupName: "lumen-1970-01-01T00-00-00Z.db"), 0)
        XCTAssertEqual(BackupRetention.timestamp(
            inBackupName: "lumen-1970-01-02T00-00-01Z.db"), 86_401)
        // The compact form `CatalogStore.backup(to:)`'s own comment names.
        XCTAssertEqual(BackupRetention.timestamp(inBackupName: "lumen-19700102.db"),
                       86_400)
        // Ordering by name and ordering by parsed stamp agree, which is the property
        // `recoverIfNeeded`'s `sorted(by: >)` quietly depends on.
        let byName = Self.twelve.sorted(by: >)
        let byStamp = BackupRetention.snapshots(in: Self.twelve).map { $0.name }
        XCTAssertEqual(byName, byStamp)

        for bad in ["handmade.db", "lumen-.db", "lumen-2026-13-02T00-00-00Z.db",
                    "lumen-2026-09-32T00-00-00Z.db", "lumen-2026-09-02T24-00-00Z.db",
                    "lumen-2026-09-02T21-00-00Z.db.partial", "lumen-1969-12-31.db"] {
            XCTAssertNil(BackupRetention.timestamp(inBackupName: bad),
                         "\(bad) was dated as if it were a snapshot")
        }
    }

    private func assertNewestSurvives(_ plan: BackupRetention.RetentionPlan,
                                      _ names: [String],
                                      _ label: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        XCTAssertEqual(Set(plan.retained).union(plan.victims), Set(names),
                       "\(label): a name went missing from the plan",
                       file: file, line: line)

        if names.isEmpty {
            XCTAssertTrue(plan.retained.isEmpty, "\(label)", file: file, line: line)
            XCTAssertTrue(plan.victims.isEmpty, "\(label)", file: file, line: line)
            return
        }
        XCTAssertFalse(plan.retained.isEmpty,
                       "\(label): the policy kept nothing at all",
                       file: file, line: line)

        // (a) the first name the restore walk reaches.
        if let firstReached = names.max() {
            XCTAssertFalse(plan.victims.contains(firstReached),
                           "\(label): deleted the snapshot recoverIfNeeded tries first "
                               + "(\(firstReached))",
                           file: file, line: line)
        }
        // (b) the newest by the date in the name.
        if let newest = BackupRetention.snapshots(in: names).first {
            XCTAssertFalse(plan.victims.contains(newest.name),
                           "\(label): deleted the newest snapshot (\(newest.name))",
                           file: file, line: line)
        }
    }

#if canImport(SQLite3)

    // MARK: - Against a real catalog

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-backup-tests-" + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var catalogPath: String {
        directory.appendingPathComponent("lumen.db").path
    }

    private func backupDirectory() -> URL {
        directory.appendingPathComponent("backups", isDirectory: true)
    }

    private func makeStore() throws -> CatalogStore {
        try CatalogStore(path: catalogPath,
                         cachePath: directory.appendingPathComponent("cache.db").path)
    }

    @discardableResult
    private func seed(_ store: CatalogStore) throws -> Int64 {
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/2026-08-20")
        let files = (0..<5).map {
            ScannedFile(filename: String(format: "DSC%04d.ARW", $0),
                        fileSize: Int64(40_000_000 + $0),
                        fileMTime: 1_700_000_000, ext: "arw")
        }
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())
        return folderID
    }

    /// Exactly what `CatalogService.close()` does about backups, with the clock made
    /// explicit: ask the stamp, and only if it says yes take a snapshot and stamp it.
    /// Returns whether a snapshot was written.
    ///
    /// The clock comes from the filename, so the two cannot drift apart in the fixture.
    @discardableResult
    private func quit(_ store: CatalogStore, named name: String) throws -> Bool {
        guard let now = BackupRetention.timestamp(inBackupName: name) else {
            XCTFail("fixture name is not a backup name: \(name)")
            return false
        }
        guard try store.isBackupDue(now: now) else { return false }
        try FileManager.default.createDirectory(at: backupDirectory(),
                                                withIntermediateDirectories: true)
        try CatalogStore.snapshot(
            from: catalogPath,
            to: backupDirectory().appendingPathComponent(name).path)
        try store.noteBackupTaken(at: now)
        return true
    }

    private func snapshotNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: backupDirectory().path))
            ?? []).filter { $0.hasSuffix(".db") }.sorted(by: >)
    }

    /// Overwrite a page past the header, leaving the file openable. That is what
    /// `PRAGMA quick_check` exists to notice.
    private func corrupt(_ path: String) throws {
        let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        XCTAssertGreaterThan(size, 40_000, "the catalog is too small to damage")
        // Past the header and the schema, across several pages — and past page 2,
        // which under `auto_vacuum=INCREMENTAL` is the pointer map that `quick_check`
        // does not read. Damage there would leave the check passing and the test
        // proving nothing, which is why the offset is the one `CatalogTests` already
        // demonstrates is noticed.
        try handle.seek(toOffset: 16_384)
        handle.write(Data(repeating: 0x5A, count: 16_384))
    }

    // MARK: The stamp

    /// N is a real gate, in both directions: an afternoon of launch-cull-quit cycles
    /// leaves one snapshot, and tomorrow's quit leaves a second.
    ///
    /// This is the shape of `close()`, not `close()` itself — `CatalogService` lives in
    /// `LumenApp`, which this target cannot import — so it exercises the two calls
    /// `close()` makes and the clock they are asked about.
    ///
    /// Substitution proof — remove the stamp gate and back up on every quit: the second
    /// assertion fails with
    ///   XCTAssertEqual failed: ("2") is not equal to ("1") - a second quit twelve
    ///   hours later wrote a second snapshot
    /// Substitute the other way — stamp on every close whether or not a snapshot was
    /// written, or widen N past a day — and the fourth fails with
    ///   XCTAssertTrue failed - a quit 21 hours later did not back up
    func testTwoQuitsInsideTheWindowMakeOneBackupAndOutsideItMakeTwo() throws {
        let store = try makeStore()
        try seed(store)

        XCTAssertTrue(try store.isBackupDue(now: 0),
                      "a catalog that has never been backed up is not owed one")
        XCTAssertNil(try store.lastBackupAt())

        XCTAssertTrue(try quit(store, named: "lumen-2026-09-02T09-00-00Z.db"),
                      "the first quit did not back up")
        XCTAssertEqual(snapshotNames().count, 1)

        // Twelve hours later — the same working day, a second cull session.
        XCTAssertFalse(try quit(store, named: "lumen-2026-09-02T21-00-00Z.db"),
                       "a second quit inside the window backed up again")
        XCTAssertEqual(snapshotNames().count, 1,
                       "a second quit twelve hours later wrote a second snapshot")

        // Twenty-one hours after the first, which is past N = 20.
        XCTAssertTrue(try quit(store, named: "lumen-2026-09-03T06-00-00Z.db"),
                      "a quit 21 hours later did not back up")
        XCTAssertEqual(snapshotNames(), ["lumen-2026-09-03T06-00-00Z.db",
                                         "lumen-2026-09-02T09-00-00Z.db"])

        XCTAssertEqual(try store.lastBackupAt(),
                       BackupRetention.timestamp(
                        inBackupName: "lumen-2026-09-03T06-00-00Z.db"))
        store.close()
    }

    /// A stamp from the future — a clock that was wrong and got corrected — must not
    /// wedge backups off until the calendar catches up.
    func testAStampInTheFutureStillLeavesABackupOwed() throws {
        let store = try makeStore()
        try seed(store)
        try store.noteBackupTaken(at: 4_000_000_000)
        XCTAssertTrue(try store.isBackupDue(now: 1_800_000_000),
                      "a stamp in the future suppressed every future backup")
        store.close()
    }

    /// The stamp moves only when a snapshot actually lands. A backup that threw must be
    /// owed again at the next opportunity, not silently deferred for N hours.
    func testAFailedBackupLeavesTheStampAloneSoItIsOwedAgain() throws {
        let store = try makeStore()
        try seed(store)
        let before = try store.lastBackupAt()
        XCTAssertNil(before)

        // A destination inside a file, which cannot be a directory: the snapshot throws.
        let wall = directory.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: wall)
        XCTAssertThrowsError(try CatalogStore.snapshot(
            from: catalogPath, to: wall.appendingPathComponent("lumen.db").path))

        XCTAssertNil(try store.lastBackupAt(),
                     "a failed backup stamped itself as done")
        XCTAssertTrue(try store.isBackupDue(now: CatalogStore.now()))
        store.close()
    }

    // MARK: The gate

    /// §15.8's rule, and the reason the gate moved inside `snapshot(from:to:)`: a
    /// corrupt catalog that backs itself up rotates the last readable snapshot out of
    /// existence, and then there is nothing left to restore from.
    ///
    /// Substitution proof — drop the `integrity_check` from `snapshot`: the throw
    /// assertion fails with
    ///   XCTAssertThrowsError failed: did not throw an error - a corrupt catalog was
    ///   snapshotted over the good copies
    /// and, because `VACUUM INTO` will often succeed on a damaged file, the directory
    /// assertion after it fails too — the new snapshot exists and is the newest.
    func testACorruptCatalogIsRefusedABackupSoTheGoodCopiesSurvive() throws {
        let store = try makeStore()
        try seed(store)
        try FileManager.default.createDirectory(at: backupDirectory(),
                                                withIntermediateDirectories: true)
        let good = backupDirectory().appendingPathComponent("lumen-2026-09-01T21-00-00Z.db")
        try CatalogStore.snapshot(from: catalogPath, to: good.path)
        store.close()

        try corrupt(catalogPath)
        XCTAssertFalse(CatalogStore.probeQuickCheck(path: catalogPath),
                       "the damage did not take, so the rest of this proves nothing")

        let doomed = backupDirectory().appendingPathComponent("lumen-2026-09-02T21-00-00Z.db")
        XCTAssertThrowsError(try CatalogStore.snapshot(from: catalogPath,
                                                       to: doomed.path),
                             "a corrupt catalog was snapshotted over the good copies")
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.path))
        XCTAssertEqual(snapshotNames(), ["lumen-2026-09-01T21-00-00Z.db"])
    }

    // MARK: Recovery, against what the backup path actually leaves behind

    /// The end-to-end claim: damage the catalog and the newest snapshot the policy kept
    /// comes back, with its contents.
    ///
    /// The directory here is built by running the real snapshot path twelve times and
    /// then applying the real prune plan — not hand-assembled — because the defect this
    /// file exists for was a mismatch between what one half wrote and what the other
    /// half could find. A generation counter in `meta` says *which* snapshot came back,
    /// so "restored" cannot pass by restoring any old file.
    ///
    /// Substitution proof — make the prune keep the OLDEST K instead of the newest: the
    /// generation assertion fails with
    ///   XCTAssertEqual failed: ("Optional("0")") is not equal to ("Optional("11")")
    /// Substitute the naming instead — write snapshots as `lumen-<stamp>.backup`, say —
    /// and the outcome assertion fails first with
    ///   XCTFail - a corrupt catalog was not restored: unrecoverable(backupsTried: 0)
    /// which is the audit's finding stated as a test.
    func testACorruptCatalogIsRestoredFromTheNewestSnapshotThePolicyKept() throws {
        let store = try makeStore()
        let folderID = try seed(store)
        try FileManager.default.createDirectory(at: backupDirectory(),
                                                withIntermediateDirectories: true)

        // Twelve evenings. Each one stamps the catalog with its own generation first,
        // so the snapshot's contents identify it.
        for (generation, name) in Self.twelve.reversed().enumerated() {
            try store.setMetaValue("test_generation", String(generation))
            try CatalogStore.snapshot(
                from: catalogPath,
                to: backupDirectory().appendingPathComponent(name).path)
        }
        // The thirteenth session's work, which no snapshot holds.
        try store.setMetaValue("test_generation", "after the last backup")
        store.close()

        // The prune, exactly as `CatalogService` runs it.
        let plan = BackupRetention.plan(names: snapshotNames())
        for victim in plan.victims {
            try FileManager.default.removeItem(
                at: backupDirectory().appendingPathComponent(victim))
        }
        XCTAssertEqual(snapshotNames(), plan.retained)
        XCTAssertEqual(snapshotNames().count, 6)

        // Debris from a snapshot a killed process never finished, named so the restore
        // walk cannot mistake it for the newest good one. It sorts above everything.
        let halfWritten = backupDirectory()
            .appendingPathComponent("lumen-2026-09-09T21-00-00Z.db.partial")
        try Data(repeating: 0x00, count: 40_000).write(to: halfWritten)

        try corrupt(catalogPath)
        XCTAssertFalse(CatalogStore.probeQuickCheck(path: catalogPath),
                       "the damage did not take, so the rest of this proves nothing")

        let recovery = CatalogStore.recoverIfNeeded(path: catalogPath,
                                                    backupDirectory: backupDirectory().path)

        guard case .restored(let from, let setAside) = recovery.outcome else {
            return XCTFail("a corrupt catalog was not restored: \(recovery.outcome)")
        }
        XCTAssertEqual(URL(fileURLWithPath: from).lastPathComponent,
                       "lumen-2026-09-02T21-00-00Z.db",
                       "the restore did not take the newest snapshot the policy kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: setAside),
                      "the damaged catalog was destroyed instead of set aside")
        XCTAssertNotNil(recovery.notice, "the user was not told")
        XCTAssertTrue(FileManager.default.fileExists(atPath: halfWritten.path),
                      "the restore consumed the half-written file")

        let reopened = try makeStore()
        XCTAssertTrue(try reopened.quickCheck())
        XCTAssertEqual(try reopened.photos(folderID: folderID).count, 5)
        XCTAssertEqual(try reopened.metaValue("test_generation"), "11",
                       "the catalog that came back is not the newest snapshot")
        reopened.close()
    }

    /// The half-written case on its own, because it is the thing that makes a
    /// quit-time or launch-time backup safe to be killed mid-write: a snapshot is
    /// published by a rename, and until then it carries a name the restore walk does
    /// not look at.
    ///
    /// Substitution proof — write the snapshot straight to `lumen-<stamp>.db` and let a
    /// killed process leave it there: this test's outcome assertion fails with
    ///   XCTAssertEqual failed: ("lumen-2026-09-09T21-00-00Z.db") is not equal to
    ///   ("lumen-2026-09-02T21-00-00Z.db")
    /// only if the truncated file happens to fail `quick_check`; if it happens to pass,
    /// the row-count assertion fails instead and the catalog silently came back short.
    func testAHalfWrittenSnapshotIsInvisibleToTheRestore() throws {
        let store = try makeStore()
        let folderID = try seed(store)
        try FileManager.default.createDirectory(at: backupDirectory(),
                                                withIntermediateDirectories: true)
        let good = backupDirectory()
            .appendingPathComponent("lumen-2026-09-02T21-00-00Z.db")
        try CatalogStore.snapshot(from: catalogPath, to: good.path)
        store.close()

        // A snapshot cut off half way, under the name it is written to before the
        // rename that publishes it. Newer than the good one under every ordering.
        let partial = backupDirectory()
            .appendingPathComponent("lumen-2026-09-09T21-00-00Z.db.partial")
        let truncated = try Data(contentsOf: good).prefix(16_384)
        try truncated.write(to: partial)

        try corrupt(catalogPath)
        let recovery = CatalogStore.recoverIfNeeded(path: catalogPath,
                                                    backupDirectory: backupDirectory().path)
        guard case .restored(let from, _) = recovery.outcome else {
            return XCTFail("a corrupt catalog was not restored: \(recovery.outcome)")
        }
        XCTAssertEqual(URL(fileURLWithPath: from).lastPathComponent,
                       "lumen-2026-09-02T21-00-00Z.db")

        let reopened = try makeStore()
        XCTAssertEqual(try reopened.photos(folderID: folderID).count, 5)
        reopened.close()
    }

    /// A snapshot taken beside a live, open catalog is a usable catalog. This is the
    /// property that lets the backup run off the app's serial queue on a connection of
    /// its own instead of holding the browser still for the duration.
    func testASnapshotTakenBesideALiveStoreIsAWholeCatalog() throws {
        let store = try makeStore()
        let folderID = try seed(store)
        try store.setMetaValue("test_generation", "live")

        let target = directory.appendingPathComponent("beside.db")
        try CatalogStore.snapshot(from: catalogPath, to: target.path)

        // The original is still open and still working afterwards.
        XCTAssertEqual(try store.photos(folderID: folderID).count, 5)
        XCTAssertTrue(try store.quickCheck())

        let copy = try CatalogStore(path: target.path, cachePath: nil)
        XCTAssertEqual(try copy.photos(folderID: folderID).count, 5)
        XCTAssertEqual(try copy.metaValue("test_generation"), "live")
        copy.close()
        store.close()
    }

#endif
}

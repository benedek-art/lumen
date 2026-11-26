# Ingest (AREAS 2) and Sources sidebar (AREAS 3): findings

Tester: test-ingest. Code under test: `claude/loving-cray-d58nrb-integration` at a7f3c8dc.

## How the proof was made

**Ingest, Linux lane.** A small harness (`harness/Sources/IngestHarness/main.swift`) runs the real
`LumenCore` ingest code, `IngestPlanner.plan` and then `VerifiedCopyDriver.run`, on synthetic card
folders. `ingest_lab.py` and `ingest_lab2.py` build the cards, run the harness, and then check
everything independently with Python `sha256` and `os.stat`.

Two pieces of the ingest are not in `LumenCore`. The card scan (`ingestScan`) and the capture-date
read (`ingestCreationDate`) are private, macOS-only functions in `IngestSheet.swift`. The harness
copies them line for line: a recursive enumerator with `.skipsHiddenFiles`, filtered to
`PhotoFormats.browsable` and sorted by filename with `localizedStandardCompare`. So findings 1, 6
and 7 depend on that copy matching the app. Every other result runs the shipped core code
unchanged.

**Sidebar persistence, Linux lane.** `harness/Sources/CatalogHarness/main.swift` drives the real
`CatalogStore` on a real SQLite file. It then opens a second, fresh `CatalogStore` on the same
files, which is what a relaunch does, and reads everything back.

**Sidebar UI, macOS driver.** The request is `scenarios/batch1.json`: albums, keywords, stacks,
flag rows, smart album, and keys pressed while the ingest sheet is up. It went in as driver run
45752999580 (request commit 6230132a). It was still queued at 05:05 UTC and never started; see "Could not
test". Another request from the same area, `test-ingest-sidebar1` (run 45753444460, commit
a20c06a4), is also queued on the driver branch. It is not mine; possibly a duplicate tester.

**The ingest sheet** could not be reached by the driver. `driver/README.md` on the driver branch
still did not document sheet capture or `list-targets` (checked up to the time of writing). No
finding below comes from a screenshot of the sheet.

### Repro (Linux, about 30 s each)

```
export PATH=/opt/swift/usr/bin:$PATH
cd harness && swift build      # Package.swift depends on the test-ingest worktree by path
python3 ingest_lab.py  harness/.build/debug/IngestHarness <workdir>
python3 ingest_lab2.py harness/.build/debug/IngestHarness <workdir> <12 MB tmpfs mount>
harness/.build/debug/CatalogHarness <workdir>
```

Saved outputs: `lab-output.txt`, `lab2-output.txt`, `checks.json`, `checks2.json`,
`t1-tree.json`, `t5-tree.json`, `t9-order.json`, `catalog-output.txt`.

---

## Findings (ranked by harm)

### 1. Videos, voice memos and other non-photo files on the card are skipped silently, and the run still says "every copy verified", which unlocks Eject

- **Severity:** major
- **What I did:** `ingest_lab.py` test T1. The card held 15 photo files (RAW and JPEG). It also held
  `DCIM/100MSDCF/DSC00009.MOV`, `PRIVATE/M4ROOT/CLIP/C0001.MP4`, a `DSC00003.WAV` voice memo and a
  camera-written `DSC00003.XMP`. Ingest ran to a primary and a backup with the default templates.
- **What I saw:**
  - The scan keeps only `PhotoFormats.browsable` extensions. The MOV, MP4, WAV and XMP were never
    planned or copied (`t1-tree.json`, key `not_ingested`).
  - The report said `Ingested 16 frames, every copy verified.` and `allVerified == true`. That is
    the condition that lets "Eject when done" eject the card.
  - No word anywhere says that 4 files were left on the card. The readiness line counts frames
    only. No skipped-file count exists in the `IngestSheet.swift` source.
- **Why it matters:** the sheet's whole promise is "the card is verified and safe to format". A
  photographer who also shot clips or voice notes formats the card and loses them. Lightroom's
  import copies video. Photo Mechanic copies every file type by default.
- **What correct would be:** either copy every file under DCIM and the camera's clip folders, or
  say what is left behind, for example "4 files that are not photos (2 videos, 1 audio, 1 XMP)
  will NOT be copied". Then do not word the result, or offer Eject, as if the card were fully
  drained.
- **Repro:** `ingest_lab.py` (T1).
- **Run:** Linux lane, `lab-output.txt`.
- **Confidence:** high for the core behaviour. Medium-high for "the sheet shows no other
  warning": I read the sheet source but could not screenshot it.

### 2. The card itself is accepted as the destination: copies land on the card, the run reports "every copy verified" (unlocking Eject), and the next ingest re-imports those copies

- **Severity:** major
- **What I did:** `ingest_lab.py` test T6. A card with 3 NEFs, with the primary destination set to
  the card root.
- **What I saw:**
  - No refusal. Three new files were written to the source:
    `2026/20261126/20261126-000{1,2,3}-DSC_000N.NEF`.
  - The summary said `Ingested 3 frames, every copy verified.` with `allVerified == true`. The
    only alias check, `destinationAliasesSource`, compares each copy with its own source file. A
    copy elsewhere on the same card passes it.
  - Running the same ingest again scanned **6** frames: the app re-imported its own copies as new
    photos (`Ingested 6 frames, every copy verified.`).
- **Why it matters:** the source is modified. Worse, the only "verified copy" sits on the card the
  photographer is about to format.
- **What correct would be:** as AREAS 2 journey 4 says, refuse a destination that is the source or
  is inside it, with a sentence saying why. Never report such a run as verified.
- **Repro:** `ingest_lab.py` (T6).
- **Run:** Linux lane.
- **Confidence:** high. The sheet's `canStart` and `start()` do not check for this either (read
  from source).

### 3. Re-ingesting a card after deleting a frame in camera silently duplicates every later frame under new `{seq}` names

- **Severity:** major
- **What I did:** `ingest_lab.py` test T5.
  1. A card with IMG_0001 to IMG_0006, ingested with rename `{date}-{seq:4}-{orig}`.
  2. IMG_0002 deleted "in camera"; IMG_0007 and IMG_0008 shot.
  3. The same card ingested into the same job again. This is the incremental re-ingest docs/10
     promises.
- **What I saw:**
  - `{seq}` is the frame's position in *this* batch. Removing one frame shifted every later
    number, so the planned names no longer matched the earlier copies.
  - 4 frames were copied a second time. For example `20261126-0002-IMG_0003.CR3` now sits beside
    `20261126-0003-IMG_0003.CR3`, and the same happened for IMG_0004, 0005 and 0006. The pairs are
    byte-identical by sha256 (`t5-tree.json`).
  - The report said `Ingested 7 frames, every copy verified. · 1 already on disk`. Nothing says
    that 4 of the 7 are duplicates.
  - The "already on disk" check (`holdsThisFrame`) only looks at the planned name and its `-1`,
    `-2`, … variants.
- **What correct would be:** AREAS 2 journey 5 says the second run must not double-copy silently.
  Any of these would do: recognise an earlier copy by its content or source name under any
  destination name; keep the counter per job; or at least report "4 frames already exist under
  other names".
- **Repro:** `ingest_lab.py` (T5).
- **Run:** Linux lane.
- **Confidence:** high.

### 4. A backup on the same disk as the primary is accepted without a word and reported as "every copy verified"

- **Severity:** major, for the photographer who believes there are now two copies.
- **What I did:** `ingest_lab.py` test T8. Primary and backup were two folders on one filesystem
  (`st_dev` 65024 for both).
- **What I saw:**
  - `Ingested 16 frames, every copy verified.` and `allVerified == true`, with no mention that both
    copies are on one device.
  - The help text on the backup toggle says "A second volume, verified independently of the
    primary". But only the *same folder* is refused (`IngestLocation.sameDirectory`). The same
    device is never checked.
- **What correct would be:** AREAS 2 journey 4: a backup on the same volume as the primary is
  refused or gets a clear error. The core already reads the device number (`IngestLocation` reads
  `systemNumber`). At minimum, say "both copies are on <volume>".
- **Repro:** `ingest_lab.py` (T8).
- **Run:** Linux lane.
- **Confidence:** high. The sheet shows `report.summary` as its result, and the summary carries no
  such warning.

### 5. Copies do not keep the original file dates

- **Severity:** minor
- **What I did:** `ingest_lab.py` test T1, comparing each source's and copy's `mtime`.
- **What I saw:**
  - 0 of 16 copies kept the source's modification time. Example: source
    `Mon Nov 24 16:01:59 2025`, copy `Thu Nov 26 03:57:29 2026`, the moment of ingest.
  - The engine writes through a `FileHandle` and never sets file attributes. On macOS a new file's
    creation date is also "now". This is inferred from the same code path, not measured on a Mac.
- **Why it matters:** these all see the ingest day instead of the shooting day:
  - Finder's Date Created and Date Modified sorting, and other tools that read file dates.
  - Lumen's own export `{date}` fallback for files without EXIF, which uses the creation date
    (`AppStateActions.namingContext`).
  - A second ingest from the destination, such as a copy to a third disk: every `{date}` folder
    gets the copy day.
- **What correct would be:** set the copy's modification date (and creation date on macOS) from
  the source before the rename, as Lightroom and Photo Mechanic do.
- **Repro:** `ingest_lab.py` (T1).
- **Run:** Linux lane.
- **Confidence:** high for mtime; medium for the macOS creation date.

### 6. `{seq}` follows filename order, not shooting order: after a counter rollover the newest frames get 0001

- **Severity:** minor
- **What I did:** `ingest_lab2.py` test T9. The card had `100MSDCF/DSC09998` and `DSC09999`, shot
  first, then `101MSDCF/DSC00001` and `DSC00002`, shot after the camera's counter wrapped. Rename
  template `{seq:4}-{orig}`.
- **What I saw:**
  - Result: `0001-DSC00001`, `0002-DSC00002`, `0003-DSC09998`, `0004-DSC09999` (`t9-order.json`).
    The later frames are numbered first, because the scan sorts by filename and ignores the folder.
  - With the same filenames in two folders (T1), numbering interleaves the folders: 0002 is
    100/DSC00001 and 0003 is 101/DSC00001.
- **What correct would be:** number by capture time, or by folder and then name, so the sequence
  matches the order the pictures were taken.
- **Repro:** `ingest_lab2.py` (T9).
- **Run:** Linux lane.
- **Confidence:** high, given that the copied scan sort matches `ingestScan`.

### 7. Camera-made video thumbnails are ingested as photographs and take seq 0001

- **Severity:** minor
- **What I did:** `ingest_lab.py` test T1, with a Sony-style
  `PRIVATE/M4ROOT/THMBNL/C0001T01.JPG` on the card.
- **What I saw:** the scan walks the whole volume, not just DCIM. The thumbnail was copied as a
  photo and named `20261126-0001-C0001T01.JPG`, ahead of every real frame. The clip it belongs to
  was skipped (finding 1).
- **What correct would be:** on a card (one with a DCIM folder), ingest the DCIM tree and the
  known clip folders, and do not treat thumbnails as photos.
- **Repro:** `ingest_lab.py` (T1).
- **Run:** Linux lane.
- **Confidence:** high, given that the copied scan matches `ingestScan`.

No sidebar defect was proven. The catalog layer passed every persistence and count check (see
below). The UI journeys are pending driver run 45752999580.

---

## Taste and documentation (not defects)

- **Default rename template.** In code, the field starts as `{date}-{seq:4}-{orig}`
  (`IngestSheet.swift:172`).
  - The header comment at lines 15–19 still says the sheet *starts* on the broken `{seq4}`. That
    comment is stale.
  - `{seq4}` is reported as an unknown token (`RenameTemplate.unknownTokens` returns `["seq4"]`).
    The sheet then blocks Start and offers "Rewrite {seqN} as {seq:N}".
  - Had it got through, `{seq4}` would render empty: `20261126--DSC00001.ARW` (T2).
  - `{seq}` (4 digits), `{seq:4}` and `{seq:2}` all render correctly (T2).
  - Not seen on screen, because the driver cannot capture the sheet.
- **Hierarchical keywords use `>`, not `/`.** Typing `travel/japan/kyoto` creates one flat keyword
  with that literal name (`catalog-output.txt`). The field's help says "Type Parent > Child". But
  AREAS 3 journey 4 writes its example with slashes, and Lightroom users type `|` or use the
  keyword tree. A hint when the typed text contains `/` would help.
- **Duplicate album names are allowed.** Two albums called "Selects" can coexist, and nothing in
  the sidebar tells them apart (catalog layer).

## Tested and working

**Ingest copy engine (Linux):**
- Every copy matches its source by sha256: 32 of 32 (primary and backup, T1) and 16 of 16 with
  name collisions (T3).
- Source untouched: every file's size, mtime and sha256 are identical after ingest, and no new
  entries, hidden ones included, appear on the card (T1).
- The backup tree has the same names and bytes as the primary (T1).
- RAW+JPEG pairs land under one stem and one seq number, also through collision renames (T1, T3).
- A stranger file already at the destination is never overwritten; the card frame goes to `-1`,
  `-2` (T3).
- Same filenames in two card folders with rename off: all 16 land, as distinct files, with nothing
  overwritten (T3).
- Stop 10 MB into a 40 MB frame: "Stopped after 9 of 16 frames". No `.part` or hidden files are
  left, and every file on disk is a reported, verified, full-size copy (T4).
- Re-run after that stop: 18 copies reported already present (not copied again), the other 14
  copied, `allVerified`, and exactly one copy per frame (T4).
- A frame that disappears after the scan is reported failed by name, the rest verify, and the run
  is not `allVerified` (T12).
- Primary fills up mid-run (12 MB tmpfs): no partial file is left, the backup still gets all 5
  frames, and the summary names the frame and says "There isn't enough space" (T13).
- With Verify off, the summary says "UNVERIFIED" and `allVerified` is false, so Eject stays locked.
- `{seq4}` is flagged as an unknown token, and `{seq:4}` and `{seq}` render 4-digit counters (T2).

**Existing tests:** 176 existing ingest, catalog, album, smart-album and keyword tests pass on
Linux (`swift test --filter …`).

**Catalog relaunch persistence (Linux, `catalog-output.txt`, 21 of 21 checks):** these survive a
reopen:
- An album's new name, a deleted album staying deleted, the target album, and album membership.
- Smart albums, keywords and synonyms.
- A stack with its pick and its collapsed state.

**Catalog counts (Linux, same run):**
- Pressing B again on overlapping photos does not double count.
- Removing a keyword from a mixed selection removes it only where it was present.
- A smart album's count follows a rating change.
- Unstack keeps all photos.
- An album's count drops when one of its photos is removed from the catalog.

## Could not test, and why

- **Sidebar UI on macOS.** Album create and target, B, rename on Return and cancel on Esc, delete;
  ⇧⌘K with the sidebar hidden and bare keys swallowed by the keyword field; synonyms; ⌘G and ⇧⌘G
  with the sidebar hidden; promote and collapse; Picked, Unflagged and Rejected counts; saving a
  smart album and its live count; a 60-character album name; X, P and 3 pressed under the ingest
  sheet. All of this is in `scenarios/batch1.json`, request 6230132a, run 45752999580. The run
  was still queued (about 10 jobs ahead of it) when this was written.
- **The ingest sheet UI:** previews, the field's actual text on open, the repair button, the
  progress caption, Stop, the Recent results popover and Eject. The driver gained sheet capture
  and `listTargets` only at about 05:04 UTC. With the macOS queue about an hour long, no run could
  come back before the deadline, so none was requested. A ready, unrun scenario is in
  `scenarios/ingest-sheet-ready.json`: open the sheet, record the field's text, set the source
  and both destinations through the real open panels, ingest, and count the files on both
  destinations. Its control names are guesses; run its `listTargets` step first and correct them.
  Until then, the engine was checked from Linux instead.
- **Real removable media:** eject, a card pulled mid-copy, exFAT creation dates. There was no
  hardware. These were simulated with a vanished file (T12) and a full tmpfs (T13).
- **App relaunch in the driver:** each scenario gets a fresh catalog, so persistence was proven on
  the catalog layer on Linux instead.
- **Note, not a finding:** album ids are SQLite rowids without AUTOINCREMENT, so a deleted album's
  id goes to the next album created (seen: deleted id 2, and the next smart album got id 2). I
  found no symptom. It matters only if something stores an album id across a delete.

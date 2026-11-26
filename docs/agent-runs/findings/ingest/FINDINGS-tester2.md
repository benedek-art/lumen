# Ingest (area 2) + sources sidebar (area 3) — tester `ingest`

All proofs are on the Linux lane: LumenCore at integration 6e9fa461, built with Swift 6.1.2. The harness calls the real
`IngestPlanner` + `VerifiedCopyDriver` + `OperationReport.finishIngest` exactly as `VerifiedCopyIngestDriver` and
`IngestSheet.start` call them. The card scan is a verbatim copy of `IngestSheet.ingestScan`, which is App-target-only.
The catalog harness uses the real `CatalogStore` (SQLite). I checked every landed file with sha256, independently of
the engine's xxHash64. No macOS driver run finished. Sidebar request run 45753444460 was still queued at 05:13 UTC,
and the ingest sheet cannot be driven (the driver README on origin/claude/loving-cray-d58nrb-driver still documents
neither sheets nor list-targets).

Repro: `harness/` (SwiftPM; `swift build -c release`), `run_ingest.py`, `run_ingest2.py` and `run_ingest3.py`
(arguments: corpus dir, work dir, harness binary; corpus = scratchpad/rawfix/raws). Results:
`linux-results-run{1,2,3}.json`, `stop-durable.json`, `catalog-harness.out`.

## Findings (ranked)

1. **Card files that are not photos are never copied, yet the run says "every copy verified" and allows eject**. Severity: blocker (possible data loss).
   - What I did: ran a simulated card holding .ARW/.JPG/.CR2/.NEF/.DNG plus `DSC00001.XMP`, `DSC00003.xmp`, `C0005.MP4` and `DSC00003.WAV` through every journey.
   - What I saw: every run left out the 4 non-photo files (`card_files_never_copied` in `linux-results-run1.json`). The summary still reads "Ingested 8 frames, every copy verified." and `allVerified=true`, which is the condition that unlocks Eject.
   - Cause: the scan filters on `PhotoFormats.browsable`. Nothing in the sheet lists what was skipped.
   - Why it matters: a photographer who formats the card after that sentence loses their videos, voice memos and in-camera/Lightroom XMP sidecars.
   - Correct: copy sidecars and videos, or name the skipped files and withhold "every copy verified" and eject.
   - Confidence: high for the engine and plan. The app path uses the same scan code copied verbatim; the screen itself is not yet proven on the Mac.
2. **The backup is not a name-for-name mirror of the primary: the same filename holds a different photograph on each destination**. Severity: major.
   - What I did: ran s7b in `run_ingest2.py` with rename off and a stranger `DSC00001.JPG` already in the primary's dated folder. The card has `100MSDCF/DSC00001.ARW+JPG` and `101MSDCF/DSC00001.ARW`.
   - Primary got: card 101's ARW as `DSC00001.ARW`, sitting beside the stranger JPG so the two read as a RAW+JPEG pair, and card 100's pair as `DSC00001-1.ARW/.JPG`.
   - Backup got the opposite: `DSC00001.ARW` = card 100 and `DSC00001-1.ARW` = card 101.
   - sha256 of every copy matches its own source. But primary/DSC00001.ARW ≠ backup/DSC00001.ARW, and both are reported verified.
   - Correct: one frame gets one name on every destination, so the backup can restore the primary file for file. Never put a card RAW beside a stranger's JPEG of the same stem.
   - Evidence: `linux-results-run2.json` → `s7b-collision`. Confidence: high.
3. **`{seq}` numbers frames in filename order across DCIM folders, not in shooting order**. Severity: minor-major.
   - What I did: on a card that rolled over from 100MSDCF/DSC09998-9 to 101MSDCF/DSC00001-2, renamed with `{seq:4}-{orig}`.
   - What I saw: 0001 and 0002 went to the LAST two frames (101/DSC00001, DSC00002) and 0003/0004 to the first two.
   - Within one card, the folders' files also interleave (100/DSC00001, 101/DSC00001, 100/DSC00001.JPG …), so a Stop can land between a RAW and its JPEG. s9 stopped after `DSC00001.ARW` with its JPG not copied.
   - Correct: order by capture time (or folder, then name).
   - Evidence: `linux-results-run3.json`, `linux-results-run1.json` s9. Confidence: high.
4. **Dated folders and `{date}` come from the file creation date, not the capture date**. Severity: minor.
   - What I saw: card files with mtime 2026-09-02 went into `2026/20261126` (the copy date) on Linux, where creation = birth time.
   - Platform note (inference): on macOS a real card gives the camera time, but "Choose Folder…" on files that were copied with `cp`/rsync or downloaded gets the copy day. The sheet text admits "Dates come from each file's creation date".
   - Evidence: all `preview` values in `linux-results-run1.json`. Confidence: medium (platform-dependent).
5. **Keywords are case-sensitive: "Kyoto" and "kyoto" become two keywords and two chips**. Severity: minor.
   - What I saw: `allKeywords` = ["Kyoto(1)", "kyoto(1)"]. The chip "Kyoto" finds 1 photo, while the text search finds both.
   - Also: `addSynonym("kyoto" → "Travel > Japan > Kyoto")` returns true while a root keyword "kyoto" exists, so the synonym is silently shadowed.
   - Correct: Lightroom matches keyword names case-insensitively.
   - Evidence: `catalog-harness.out`. Confidence: high.
6. **Duplicate album names are allowed, by both create and rename**. Severity: minor.
   - What I saw: two albums both named "Selects", and renaming to an existing name returns true. The sidebar would show two identical rows, and B's target becomes ambiguous.
   - Evidence: `catalog-harness.out`.
7. **Stop text contradicts itself**. Severity: minor (from reading the code, not proven on screen).
   - The tooltip says "Stop after the frame being copied … the one in flight is discarded", and AREAS expects "finishes the current frame".
   - The engine discards the in-flight frame (s9b: stop inside the first frame → "Stopped after 0 of 8 frames", destination empty).

## Proven working (Linux, real Core code)
- Each template: rename off, `{date}-{seq:4}-{orig}` (the code's actual default), `{orig}`, `{date}` (forced collisions → -1/-2, pair stays together), `{job}`-empty (all 8 refused with a sentence, nothing written). Every landed copy matches its source by sha256, on primary and backup.
- `{seq4}`: flagged as "Filename template: unknown token {seq4}". It would render `20261126--DSC00001.ARW`, and the sheet blocks it. The code's state default is `{seq:4}` (IngestSheet.swift:172); its file header still claims it starts on `{seq4}`. What the field shows on open still needs a sheet screenshot.
- Source never modified or deleted in any of 20 runs (sha256 + size + mtime of the card before and after).
- No leftover `.part` files. A pre-existing different file is never overwritten; one with the same size but other bytes is stepped round (-1); one identical is recognised as "already present".
- Re-ingest copies nothing twice: 16 already on disk, including the earlier -1 names (S-04 holds).
- Stop mid-run at 4 MB, 30 MB and 110 MB: the destination holds exactly the frames reported, and the durable report says cancelled, lists the verified ones and marks the rest notAttempted.
- A backup that is a symlink to the primary is refused. Job "../../escape" stays inside the destination as `..-..-escape`.
- With verify off, the summary says "UNVERIFIED".
- Two cards with the same names into one job: no overwrite (second card → `-1`).
- Hierarchical keywords, parent chip and search, synonym search (case-insensitive), typing a synonym tags the real keyword, smart filter picks + ≥3★.

## Could not test / unfinished (one line each)
- Ingest sheet UI (default field contents, repair button, Stop button, progress, Recent results, eject, X/P while the sheet is up): the driver cannot capture sheets yet.
- Sidebar UI journeys (album create/rename/delete, B, smart album save/live update, ⇧⌘K with the sidebar hidden, synonym field, stacks with the sidebar hidden, truncation): scenarios ready in `sidebar-run1.json` (`sidebar_run1.py`), request a20c06a4 / run 45753444460, still queued. Fetch with `python3 driver/tools/results.py 45753444460`.
- Suspected from reading the code, unproven: after Rename… the rename field gets no focus (`SidebarRenameField` has no `.focused`), so typing a name may fire cull keys. `sb-albums` tests exactly this.
- Destination full or unplugged mid-copy, real removable volumes, eject: need hardware.
- The `state.openFolder(primary)` root after ingest (opens the whole destination root, which includes the nested backup in s13): not checked in the UI.

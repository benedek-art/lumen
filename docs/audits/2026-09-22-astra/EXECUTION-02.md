# Verified repairs — execution record 02

Continuation on 22 September 2026. Draft implementation PR: [#5](https://github.com/benedek-art/lumen/pull/5), based on the latest audited Claude branch. The owner explicitly approved publishing repair source/tests/CI in the public repository, without merging, releasing or uploading personal photographs.

## REL-02 — sidecar ownership transitions

The first transition regressions executed **6 tests with 7 assertion failures**. They covered DNG→NEF, NEF→DNG, two native RAW formats, a legacy DNG sidecar, ambiguous unowned Lumen metadata, and an Adobe-style sidecar compatibility control. Failures included wrong-photo recipe inheritance and loss of the first photo's sidecar-only recovery.

Changes:

- Persist the source extension in Lumen XMP ownership metadata. This survives renaming the photograph and its sidecar together.
- Respect an existing qualified sidecar even after a sibling disappears. Respect explicit ownership of a bare sidecar before applying naming conventions.
- Backfill legacy ownership only when exactly one existing catalog row matches both the sidecar timestamp and recipe fingerprint. Preserve foreign XMP fields and the recorded timestamp.
- Leave ambiguous legacy documents intact, report the ambiguity, and do not import their edits into either RAW while the collision remains unresolved.
- Reject a qualified sidecar explicitly owned by another RAW format, including at write time.

The initial focused green run was **21 tests, zero failures**. A broader sidecar/brush compatibility run passed all its sidecar checks; its sole failure was the separately planted legacy-backup regression below. These checks exercise actual temporary libraries and catalog-free reimport, not only filename arithmetic.

Limits: untagged legacy metadata with no catalog provenance cannot be attributed with certainty. No automatic guess or universal migration claim is made. A dedicated interactive owner-resolution UI is not implemented; ambiguous files require review and explicit qualified naming. Cross-process XMP modification and power-loss matrices remain unexhausted.

## REL-08 — legacy snapshots and damaged live payloads

Publishing new snapshots safely does not repair incomplete snapshots left by old builds. A regression showed that recovery chose a newer database missing its brush over an older complete snapshot: **77 tests, one assertion failure**, all other sidecar/backup controls passing.

Recovery now checks stored stroke references and content-address hashes. Missing or damaged required payloads are recovered before the database is replaced; failed payload preparation cannot authorize restoring a brushless catalog. Existing damaged bytes are preserved under a unique `.damaged-…` name. Processing retains one painting's bytes at a time rather than the entire blob store.

A second regression injected corrupt bytes at the live brush's expected filename. Before repair: **one test, five assertion failures (one unexpected unwrap failure)**. The old restore skipped that file merely because it existed. After repair, the actual 64×64 painted alpha raster matches the original, and the damaged bytes remain recoverable.

Combined ownership/recovery green run: **160 tests, zero failures**. After adding multi-photo undo and partial-scan/album/duplicate-signature controls, the final focused run passed **168 tests**. The complete optimized suite passed **2,424 tests, 14 skipped, zero failures** (151 seconds wall-clock). The previously failing timing probe passed this run; this does not establish that its timing variability is resolved. An intermediate multi-photo fixture failure compared `/var` and `/private/var` aliases; the fixture now resolves symlinks before comparing URLs.

The opt-in RAW accuracy test draft is not part of this safety checkpoint or these counts. RAW, referenced-mask and preview-cache repairs are the next parallel implementation lanes, with independent checkouts and integrated regression checks before acceptance.

## CI and publication

The initial hosted run built both the package and app bundle successfully, and passed the release-policy negative controls. Its source-checker lane failed: the checker did not recognize three genuine platform APIs (`SQLITE_OPEN_READONLY`, `RENAME_EXCL`, `NSBitmapImageRep`) or typed `for` bindings in two tests. The platform allowlist now names those APIs; tests use explicitly typed arrays and ordinary loop bindings. An intermediate test-array typing error was corrected; no compiler error is counted as a product regression.

The workflow defaults to read-only repository permission, with write access isolated to the gated publisher. The offline policy checker now rejects **eight unsafe mutations**. Hosted checks and their results must be rechecked for each published code revision; one successful local run does not imply hosted CI is green.

No image goldens, numerical tolerances or performance thresholds were relaxed. Originals and the live library remain untouched. Only generated temporary fixtures underwent corruption, deletion or permission-denial tests.

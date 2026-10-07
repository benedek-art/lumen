# Persistence repair implementation

Branch `codex/lumen-oct07-persistence`, baseline main `5643497`, final HEAD `868774b`. Exclusive worktree `work/lumen-persistence`. No push/merge; no catalog schema or numerical rendering changes. Initial sidecar repair is commit `3988a39`; subsequent metadata changes are listed below.

## Implemented PS-01 through PS-05

- Sidecar reads distinguish proven no-such-file from access/I/O failure. Access failures leave existing bytes untouched, retain the owed edit and produce one actionable notice per outage.
- Malformed XML, unsupported encoding, ownership mismatch and nonspliceable documents remain untouched. Their edits now remain in the retry queue and durable unsaved records instead of being dropped. The current document is reread before every attempt, so a repaired document can settle previously blocked work.
- Actual pending keyword additions/removals survive quit/reopen in an optional Codable field, compatible with existing records. Recovery reconciles deltas against current catalog membership to prevent an outlived durable record reversing a later edit.
- Pending keyword deltas are projected before additive sidecar import, preventing an owed removal from being reintroduced from stale XMP.
- Flat keyword recovery uses leaves rather than hierarchy display paths. Removing a nested keyword only removes its flat leaf when no remaining catalog membership on that photo requires that leaf.
- Write refusals are retried on the existing 15-second schedule and reported once, reset by successful writes. Launch notice also describes safety refusal rather than implying every failure is an offline disk.

## Verification

Native macOS `swift test --build-system native --jobs 2`, isolated scratch/cache/module caches under `/private/tmp/lumen-oct07-persistence-*`, `--disable-sandbox`.

Before repairs, new shared-leaf/nested-recovery/removal-replay regressions ran against baseline: three tests failed, four failed assertions. Existing round-trip tests passed.

Initial repaired targeted run: 18 tests, zero failures.

Final expanded run: **68 tests, zero failures**, including:

- `SidecarKeywordRoundTripTests`: original interoperability, shared leaves, lost removals, foreign additions, hierarchy leaf replay, stale durable record, malformed/UTF-16/ownership refusals, injected I/O refusal followed by safe retry.
- `UnsavedSidecarRecordTests`: database reopen, delta codec/time-order composition, legacy record compatibility and notices.
- `AuditPersistenceSafetyTests`, `AuditSidecarOwnershipTests`, `AuditSidecarScalingTests`.
- `SidecarReseedTests`, `SidecarKeywordTests`, `SidecarNamingTests`, `KeywordHierarchyTests`.

Final log `/private/tmp/lumen-oct07-persistence-final.log`; red log `/private/tmp/lumen-oct07-persistence-red-native.log`. Final test runtime ~39 seconds; scaling exercises included 20,000 synthetic RAW filename classifications and a 1,001-file synthetic registration. None required private RAW photographs or decoding.

`git diff --check` passed. The first surface checker identified five real Foundation/POSIX globals missing from its platform allowlist; commit `90e3d65` added those narrowly. The next complete checker run passed. A final checker run covering the frozen export correction is in progress and its result will be supplied to the integration owner.

## Residual limits

- Old unsaved records never stored removed words. A historical removal already lost before this repair cannot be reconstructed; legacy records still replay additions, now correctly flattened.
- External keyword deletion is still additive-only on normal import. Full hierarchical `lr:hierarchicalSubject` interoperability and authoritative removal of embedded source IPTC tags remain future work.
- Existing documents remain subject to the small cross-process read/write race inherent in the baseline atomic merge strategy. This repair does not claim interprocess locking or conflict resolution.
- No guarantee of a durable record before an arbitrary process kill at every possible instruction boundary; failed writes are persisted asynchronously on the catalog queue and synchronously recorded at normal close.
- Repeated `close()` idempotence remains a low-priority audit item; this patch keeps lifecycle scope unchanged.
- PS-06 case-insensitive ingest identity belongs to the integration owner and is outside this commit.


## Follow-up commits and final validation

Cherry-pick in this order: `3988a39`, `a5169c8`, `90e3d65`, `608de1e`, `2077e6c`, `868774b`.

- `a5169c8`: catalog keyword snapshot flows through the actual app export job, coordinator, renderer and IPTC metadata policy. This initial commit's replacement semantics are corrected by `868774b` below; integrate the complete chain.
- `90e3d65`: a failed flush now merges older owed fields with newer queued entries. Newer scalar fields win and keyword deltas compose in time order. Deterministic reentrant read fault reproduced lost OlderKeyword with newer rating retained before this repair; fixed run passes. Added snapshot leaf-dedup/closed-catalog failure tests and checker platform globals.
- `608de1e`: a catalog keyword read failure refuses only recipes that include keywords, while stripped recipes proceed. Two actual AppState export tests use isolated catalogs/generated JPEG and restore the exact original preset preference object afterward.
- `2077e6c`: recovery restores all current catalog leaves, not just the old record's addition set. A stronger stale-removal regression first deletes Kept from XMP, then proves the newer catalog re-add restores it. Red before repair, green afterward.
- `868774b`: preserves original embedded IPTC while adding catalog leaves; empty/nil snapshots preserve embedded tags. CatalogService does not import embedded source IPTC, so treating the catalog as authority to remove those tags was unsafe. Missing/deleted photo IDs now throw instead of returning empty tags. String, [String] and bridged NSArray keyword forms merge; unfamiliar representations remain unchanged rather than being erased. Unsupported keyword representation therefore does not gain catalog additions; this is an intentional preservation limitation.

**Final OUT02 status: partial feature implemented—catalog additions are delivered; embedded-source deletions still require an imported baseline or tombstones.** Full hierarchical serialization is unchanged. The Include Keywords off policy remains the existing strip policy. Source bytes are never modified.

Final native targeted run: **46 tests, zero failures** (sidecar safety/recovery, stale records, missing/closed snapshot reads, cancellation and conventional/unfamiliar metadata forms). Log `/private/tmp/lumen-oct07-persistence-freeze-final.log`.

Final direct xctest run with macOS encoder services available: **15 tests, zero failures**, comprising all 13 AuditExportMetadataTests and both real AppState CatalogKeywordExportTests. It reads generated JPEG/HEIC/TIFF/PNG delivery metadata back through ImageIO and verifies source preservation, added catalog leaves, privacy stripping, unrelated contact preservation, print density, collision safety, and actual per-recipe handling of failed catalog reads. Runtime ~41 seconds; log `/private/tmp/lumen-oct07-persistence-export-freeze-direct.log`.

Why direct xctest: a sandboxed full renderer metadata run failed nine encoder cases, including preexisting unchanged density/contact/source tests, with writeFailed. The same compiled test bundle passed through direct xctest with approved access to macOS encoder services. No tests were skipped or weakened to hide those failures.

Final code frozen at `868774b`; temporary images/catalogs only, no private RAWs required.

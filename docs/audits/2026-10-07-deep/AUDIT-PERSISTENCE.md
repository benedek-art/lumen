# Lumen persistence, ingest, library and delivery audit

Baseline: main `5643497`; read-only inspection of current source and October stream reports. No builds/tests run by this reviewer. All findings below are source-confirmed; reproductions are proposed acceptance tests, not claimed executed results. Private RAW photographs are unnecessary for these tests: temporary byte files, SQLite fixtures, XMP documents and generated JPEG/PNG images suffice.

## Highest-priority actionable findings

### PS-01 — P1: a failed XMP read is treated as permission to replace the document

`Sources/LumenApp/CatalogService.swift:1540` calls `XMPSidecar.classify(try? Data(contentsOf: path))`. `Sources/LumenCore/XMP/XMPSidecar.swift:557` maps nil to `.absent`, and `CatalogService.swift:1598` authors a fresh document for absence. Nil can represent access denial, transient filesystem errors or an unavailable file, rather than ENOENT. A directory can permit atomic replacement while the existing file itself forbids reads. In that situation a rating edit can replace unread third-party settings with Lumen's new document. The same error can occur after enqueue when the fresh read fails, despite the older successful read.

Fix: represent the filesystem read as missing / readable / failed, with only a proven no-such-file error permitting creation. Preserve the existing document on every other error. Inject a small sidecar I/O adapter or extracted read helper so failure is deterministic in tests. Keep the owed edit durable and surface a useful status. Regression: arrange writable parent and unreadable existing XMP (or injected permission error), enqueue rating, flush, assert original bytes unchanged and pending/durable edit retained. Also test transient error followed by successful merge preserving foreign fields.

### PS-02 — P1: safe-write refusals silently discard portable edits

`CatalogService.swift:1485–1487` removes the pending batch before processing. Refusal branches `1532–1536` (stale incomplete parse), `1541–1545` (encoding), `1560–1564` (ownership), `1570–1574` (fresh parse), and `1591–1595` (splicer refusal) simply continue. Only thrown write failures enter `failed` and retry. `close()` at `2183–2194` derives durable unsaved records exclusively from still-pending entries. Therefore refusal protects the foreign document but loses the owed sidecar edit and omits it from the next-launch notice. Repairing the XMP later cannot automatically settle the lost edit. Most branches only NSLog.

Fix: classify outcome as saved / temporarily blocked / refused with durable owed fields. Keep refusals as owed, notify once with reason, and avoid a tight repeating loop. Retrying after changed document/explicit retry/next launch is sufficient. Never auto-overwrite ambiguous ownership. Tests: malformed, UTF-16, ownership mismatch, nonspliceable XML; assert byte preservation, retained edit, quit record, accurate next-launch notice, and successful replay after correction. Make `close()` idempotent as a small adjacent improvement.

### PS-03 — P1: failed-at-quit keyword removals are not recoverable

`CatalogService.swift:221–226` explicitly rebuilds failed keyword edits as additions only. `UnsavedSidecarRecord` stores field bits without the keyword delta. Removing `Dawn`, failing XMP flush, then quitting leaves `Dawn` in XMP. On reopen the catalog's empty list cannot remove it; additive import at `CatalogService.swift:811–819` can reattach it. This is a user edit reversal across launch, not just an interoperability preference.

Fix: persist pending keyword deltas, compose additions/removals in time order, and replay them against the latest disk bag. Keep ordinary rating/recipe replay rebuilt from current catalog. Version/backward compatibility for existing unsaved records is required. Tests: failed remove + reopen; add/remove/add composition; removal alongside another tool's new keyword; record surviving a successful flush/crash must not resurrect stale tags. This belongs with PS-02 under one owner because both change durable unsaved state.

### PS-04 — P2: quit recovery writes hierarchy display paths into flat keywords

`CatalogStore.swift:3352–3357` returns display paths from `keywords(photoID:)`, but recovery at `CatalogService.swift:225–226` passes those directly to `SidecarKeywordEdit(added:)`. Normal add at `1307–1315` correctly writes `keywordName` (leaf). A failed addition of `Places > Iceland` therefore replays as literal `Places > Iceland`, potentially beside an existing `Iceland`. Recovery and normal operation serialize different keyword identities.

Fix: use an explicit flat leaf accessor for dc:subject or normalize with `KeywordPath.leaf` and stable deduplication, while implementing PS-03. Test nested tag + failed quit + successful reopen flush equals ordinary successful write exactly, and foreign unrelated keywords survive.

### PS-05 — P2: removing one nested keyword deletes a still-needed flat keyword

`CatalogService.swift:1325–1330` removes the specified catalog keyword and unconditionally removes its leaf from XMP. A photo can legitimately carry `People > Alex` and `Places > Alex`; removing the first should retain `Alex` in dc:subject for the second. Current code removes it. Catalog reconstruction loses the remaining flat evidence, and another tool sees no Alex.

Fix: derive per-photo leaf set before/after the membership operation and enqueue only the leaf-set delta; do not use one unconditional delta across all selected photos. Test two same-leaf branches, remove one, keep bag value; remove last branch, remove bag value; batch selected photos having differing remaining branch memberships.

### PS-06 — P1/P2: ingest twin safety ignores case-insensitive filename identity

`Sources/LumenCore/Ingest/IngestPlan.swift:235–236` identifies a file as directory identity + literal lastPathComponent. `VerifiedCopy.swift:462,470–471` uses this identity for claims; report validation uses it at `264`. On standard case-insensitive macOS volumes `A.RAF` and `a.raf` can be the same file but different keys. Two distinct byte-identical source frames mapped to those names can share one existing destination, bypass twin checks and still claim verification/eject eligibility. This unresolved October finding is still present in current code.

Fix: existing-file identity should incorporate actual device/inode (and resolve links); nonexistent planned-name identity needs filesystem-aware case sensitivity or a conservative canonicalization only where the volume is insensitive. Do not globally lowercase on case-sensitive volumes. Acceptance: use a temporary case-insensitive APFS image/destination or identity adapter to ingest identical twins with differently cased names and assert two files or explicit refusal, never false allVerified. Also test case-sensitive volume and hard-link aliases. No RAW decode required.

## Remaining improvements and scope decisions

1. **Hierarchical XMP interoperability (P2):** current source only imports/writes flat dc:subject. A fresh catalog cannot reconstruct parent paths, and same-leaf branches become ambiguous. Implement lr:hierarchicalSubject parsing/merging without damaging foreign namespaces, with precedence between flat and hierarchical tags and migration/backward compatibility documented. Fixture tests can cover Lightroom-style XMP; compare fixtures to a real external tool later. Synonyms remain catalog-only; explicitly state that portability boundary.
2. **Catalog keywords in exports (P2):** `AppStateActions.swift:389–392` passes image/recipe/strokes/proof but no catalog keyword list; `PipelineRenderer.swift:1201–1205,1220–1222` metadata filtering reads original source properties. Tags added in Lumen therefore do not reach IPTC deliveries, even with Include Keywords selected. Add metadata snapshot to export jobs, merge catalog/sidecar keyword policy intentionally, then generated-image readback tests across supported formats. Do not blanket-delete all IPTC fields just to remove Keywords without reviewing caption/copyright preservation.
3. **Missing-file relinking (P2):** implement explicit folder/photo relink with size/signature validation, identity collision refusal, transaction rollback and offline originals kept intact. Existing scan/adoption is partial, not a substitute for user-directed relink. Test simulated rename/move, mixed similar names, wrong same-size file, cancellation and sidecar association.
4. **Smart album scope (P2):** current semantics are saved filter over the currently open folder. Expose clear scope (current folder/subtree/all catalog) and persist it; ensure displayed count matches clicked results. Test different folders and empty/offline scopes. This changes UI/query model, so give a separate owner from persistence safety.
5. **Source identity and preview churn (P3):** October P2's remaining ctime-driven cache scope invalidation and per-scan legacy ownership reads remain worth a focused current-path profiling pass. `CatalogService.swift:1713–1719` still reads bare XMP once per RAW stem each scan. Cache by reliable mtime/size/generation, retain explicit invalidation. Benchmark generated hundreds/thousands of sidecars and repeated scan; assert changed sidecar reprocessed.
6. **Backup discoverability/recovery UI (P2/P3):** add storage health, last successful backup/time, size, reveal backups, and deliberate restore preview. Automatic snapshot at `CatalogService.swift:2073–2075` already snapshots DB then backs up blobs and only publishes DB last; do not reintroduce partial snapshots. Test missing blob refusal and rollback using synthetic catalog/blob fixtures. Further investigate concurrent blob collection/change during backup rather than claim a defect without evidence.
7. **Metadata editing (P3):** IPTC title/caption/copyright/job and ingestion metadata presets need schema/UI/XMP/export consistency. Stage after safety repairs; generated metadata readbacks suffice today.
8. **Export controls (P3):** fit-within dimensions/% resize, TIFF compression, reveal/open result, recipe sets and persistent queue. Keep render-changing output sharpening/gamut mapping as explicit versioned or opt-in work with synthetic reference images and later real-photo review.
9. **Export collision names (P2 investigation):** current batch claim set is `Set<URL>` (`AppStateActions.swift:374,383`), which may similarly fail to classify case variants as in-run collisions. ExclusivePublish prevents ordinary overwrite, but selected Overwrite can potentially replace an earlier batch delivery if paths differ only in case. Reproduce on a case-insensitive temporary volume before assigning severity. Reuse a shared tested filesystem identity design with PS-06.
10. **Quit/cancel messaging (P3):** skipped exports versus written counts can mislabel stopped/completed run; October F6 documents it. Tests must assert behavioural totals/outcomes, not source-string structure.

## Parallel implementation boundaries

- Owner A: PS-01/02/03/04/05, all sidecar durable queue and keyword changes together. Start with fault-injected reproduction tests, then repairs. Avoid competing writers to CatalogService.
- Owner B: PS-06 and case-insensitive export investigation; filesystem identity utilities + ingest/export tests, coordinate shared helper API with A.
- Owner C: export metadata snapshot and generated readbacks; avoid changing render numerical behaviour in the same patch.
- Later wave: relink and smart scopes need CatalogStore migrations/query/UI, so schedule separately or assign precise nonoverlapping ownership. Hierarchical XMP can follow A's delta architecture.

## What can be proven today versus deferred

Today: SQLite migrations/recovery, all sidecar safety cases, independent ingest identity, cancellation and collision behaviour, metadata serialization/readback, queue/report state, offline relink transactions and synthetic backup recovery. These do not depend on private RAWs.

Later: real-volume disconnect behaviour, practical external-tool interoperability, actual camera metadata quirks, owner-facing library ergonomics and delivered photo colour/quality. A passing fixture suite must not be presented as full RAW or visual acceptance.

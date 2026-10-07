# APP-13 durable operation reports — 2026-10-07

Implemented a bounded first release of durable ingest/export result evidence on `codex/lumen-durable-reports`, starting from `origin/main a4f646e`.

## Contract and behavior

- Each operation owns a UUID-named schema-1 JSON file under the catalog's `reports/` directory. Only source/destination paths, labels, outcome details and execution timestamps are recorded; no image bytes, EXIF, recipes or image digests.
- The actor serializes atomic writes, validates supported schema/record identity/revision/count/size, refuses to overwrite unreadable or unsupported existing files, and rejects stale checkpoints. Independent IDs cannot overwrite another run's results.
- Export saves a start checkpoint, settles each attempted photo/recipe, coalesces intermediate writes to one second or 50 outcomes, and forces the final checkpoint. Confirmed publication alone sets `actualDestination`; skip/failure/remaining work never claims delivery. Collision rename/replace and reduced-kernel details are recorded. Cancel after a skipped file retains the skip and marks remaining deliveries not attempted. A completed operation can have failures; its summary says so.
- Ingest saves start and final checkpoints with separate requested primary/backup roles. Final result projection records verified, unverified copied, proven existing and failed outcomes; absent source/role results remain explicitly not attempted with no invented paths. Verification cleanup is described as attempted, never guaranteed.
- On relaunch, persisted running operations are presented as Interrupted. Unsettled entries become Unknown, because the process may have published files after its last checkpoint. Their planned paths are never promoted to actual destinations.
- Retention keeps up to 50 supported terminal reports and a 32 MiB history budget (always preserving the newest, with a 16 MiB per-file limit). Unfinished/interrupted/malformed/unsupported evidence is never automatically deleted. Terminal throttle entries are removed. UI terminal history is count-bounded too.
- Actor report I/O occurs off the main actor. Persistence failures appear separately in Recent results and do not reverse a successful image delivery. The UI offers run summaries and Finder reveal of existing saved JSON only; it labels older saved checkpoints. Startup merges UUID/revision history with newer in-flight results and guards delayed save completions from regressing saved revision bookkeeping.

## Validation

All fixtures were generated temporary JPEGs/catalogs/JSON; no private RAW files or installed app data were used.

- Native debug SwiftPM: **26 tests passed**, 0 failures: 9 OperationReportTests plus 17 existing ExportCancelAdversarialTests. Log `/private/tmp/lumen-durable-reports-finalcore.log`.
- Direct native xctest outside the sandbox (actual ImageIO/Metal synthetic export): **4 CatalogKeywordExportTests passed**, 0 failures. Existing catalog keyword tests now verify durable delivery/reopen and partial failure records; new tests cover skip-then-cancel and report-write failure without reversing publication. Log `/private/tmp/lumen-durable-reports-app.log`.
- Meaningful core regressions cover relaunch unknown versus confirmed actual destinations, concurrent separate operation IDs, stale terminal protection, malformed/newer JSON preservation, terminal retention excluding unfinished evidence, disk failure without phantom report paths, throttled versus forced final saves, digest-free ingest projection, invalid outgoing records, and missing backup-role cancellation.
- Existing cancellation source checker was updated to the enumerated recipe loop; its after-publication cancellation requirement is preserved.
- `git diff --check` passed. Existing Swift 6 isolation warnings are unchanged elsewhere. No full suite or release build performed in this worktree; parent owns integrated validation.
- Independent app agent reviewed the report wiring and found no blocker.

## Explicit limitations / next work

APP-13 now has durable result files and minimal access, not a polished per-file viewer. Manual UI/relaunch inspection remains useful. Ingest's existing driver exposes only a final report, so a mid-run crash leaves all ingest roles unknown even if earlier copies finished; improving that granularity requires an engine settled-result callback in a later wave. Export can lose up to the coalescing window's latest settled outcomes on abrupt process death; these become unknown, never guessed deliveries. Report I/O cannot be transactionally coupled to image publication across volumes. Oversized/unwritable report storage leaves visible warnings and in-memory results; recovery may only retain the last successful checkpoint. Preserving unsupported/unfinished evidence deliberately exempts those files from terminal retention.

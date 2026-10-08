# Lumen current state — 7 October 2026

Lumen has a substantial working macOS editor and a connected catalog, ingest, develop and delivery workflow. Three audit/repair waves now combine on `codex/lumen-third-wave` at `f7ec1d6`; the full optimized app suite and source checks are running. GitHub main currently contains the first two waves through PR #8 (`c4923aa` including the subsequent audit update). Publication of the third wave follows combined qualification.

## What is built

| Area | Connected capabilities | Remaining practical gate or gap |
|---|---|---|
| Library | SQLite catalog, scans, culling metadata, filters/manual albums, keywords, scoped smart albums and explicit original relinking | Native scope/relink dialogs; catalog-wide paging and memory; safer per-photo unreadable-recipe containment |
| Ingest | Streaming primary/backup copy, digest readback, independent landing identities, cancellation/eject refusal and durable results | Real disconnected/full/removable volumes and independent physical backup; per-file crash checkpoint depth |
| Develop | White balance, tone/zones/curves, presence, detail, film, mixer/B&W and exact S9 color path | Owner RAWs and camera/display acceptance; spatial color-model and capture-detail product decisions |
| Local edits | Painted masks, healing, source search, local controls and reusable blobs | Hard tiny-brush resolution boundary and endpoint semantics; manual heal-source interaction; real-image edge quality |
| Framing | Batch crop, angle, reset, Original and orientation controls with source preflight | Native interaction; perspective and chromatic-aberration feature projects |
| History | Undo/redo, durable edits and per-photo named snapshots with dependency validation | Photographer acceptance of restore/delete flows; process-level restart validation beyond AppState reconstruction |
| Portable edits | Conservative XMP merge, hierarchical catalog tags, durable sidecar debt/removal recovery | Full hierarchical Lightroom interoperability; explicit authority before removing source-embedded delivery tags |
| Delivery | Multiple formats, density metadata, HDR path, contact-sheet support and durable per-file reports | Persistent cancellable queue and additional controls; real HDR/delivery output qualification |
| Updater | Digest/signature checks, bundle staging, launch-failure handling and recovery-aware release publisher | Actual candidate promotion, installation/relaunch and volume behavior; no release was published |
| Engineering | macOS optimized app tests, Linux portable core, GPU parity, proof registry and UI-layout checks | Final exact-source hosted integration; owner/native acceptance and existing physical/corpus gates |

## Repairs and additions made during this run

The first wave repaired data preservation, ingest aliases, crop safety, updater responsiveness/cleanup, healing geometry, output collisions and macOS kernel syntax. The second added durable ingest/export reports, interrupted-gesture Reset undo, and a mocked release recovery publisher. The third adds named snapshots, explicit missing-original relinking, complete smart-album scope acquisition, sparse-selection indexing, a read-only curve-limiter caption and a connected generated-shoot lifecycle regression.

Further adversarial review repaired misleading ingest cleanup reports, replaced/mutated verification destinations, relink-time gesture persistence, recycled smart-source IDs and source reads returning stale paths after relink. Each has a causal regression and focused verification. The master ledger records confidence rather than treating a feature implementation, full test pass and photographer acceptance as the same milestone. It retains the original 84-item roadmap and two additionally discovered ingest defects.

## Numerical proof and measured performance

The old proof failure is understood and corrected. Linux/Darwin atan2f returned neighboring Float values for one chart hue input; a 90-digit independent oracle selected the Darwin value. Evaluating the same angle in Double before rounding to Float makes that input agree across platforms. All 144 hosted controls were measured on the same patched source. Only three records/four fields were corrected; the remaining 141 records and the existing `1e-6` tolerance were retained. Both hosted snapshots satisfy the corrected ruler; the original optimized six-test complete proof suite passed. See the separate proof-numerics report for raw differences, artifact digests and source/toolchain provenance.

Generated 20k-photo navigation bookkeeping improved from median 23.57 ms and p99 51.27 ms to 0.079 ms and 0.770 ms. This measures main-actor selection/order bookkeeping, not displayed-frame or RAW decode latency. The earlier baseline predates snapshots, so it is not an otherwise identical-source performance comparison. Scan/sort/release costs and ending RSS remain separately recorded; two RSS readings do not prove bounded memory. The index preserves source order, hidden selections, duplicate-ID fallback and metadata freshness.

The connected two-photo generated lifecycle passes verified primary/backup ingest, AppState culling/gesture edits, brush/heal/LUT references, snapshots, actual exports, quit backup and reconstructed AppState. Source/copy bytes remain unchanged; exported decoded pixels match exactly before/after reconstruction. This does not replace a new-process, real-card or real-RAW test.

## Qualification currently available

First/second-wave combined optimized testing reached 3,174 tests: 3,151 passes, 22 intentional skips and the old proof failure. Hosted main CI reproduced only that failure; GPU parity, UI layout and full proof sweep passed. Third-wave combined workflow testing passed 25 tests; the color/curve/relink/generated lifecycle lane passed 20, with all ten recorded pre-readout LUT fingerprints unchanged. Independent final scope review passed 52 tests and ingest ownership review 45. Thirty-nine source-checker positive/negative fixtures pass. The full third-wave optimized run and exact-source source checks are in progress; their final counts will replace this pending statement after completion.

## What still needs work

1. Owner acceptance: camera decode, skin/highlights/noise/foliage/B&W/HDR, local-edge/brush/heal quality, native keyboard/pointer/accessibility and update installation. Record device, source, revision and delivery format.
2. Recipe compatibility: a malformed current recipe currently refuses an entire scoped source. Preserve this explicit safe refusal until a per-photo unavailable/read-only model guards editing/export and retains raw edit/payloads; a nil/default fallback would hide the problem.
3. Scale: broad smart sources materialize catalog rows/recipes; paging, first-card latency, cold/settled rendering and bounded residency need further qualification. The selection scan repair does not settle these other costs.
4. Metadata/delivery: hierarchical interoperability, IPTC editing, source-tag removal authority and persistent queue behavior remain concrete independent projects.
5. Rendering product choices: tiny-brush deposition/resolution, spatial Uniformity/Variance, deconvolution and AI models need compatibility decisions and useful image corpora. Avoid changing saved looks solely to improve synthetic metrics.

The master plan gives each remaining item acceptance criteria and its synthetic or owner/hardware gate. No private RAWs, user catalogs, installed app or updater release were changed by this audit.

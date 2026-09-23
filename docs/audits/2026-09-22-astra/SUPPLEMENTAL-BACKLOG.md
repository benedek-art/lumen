# Supplemental repair backlog and expected-failure inventory

Checkpoint: `6c9c026`, 22 September 2026. The original 47 findings retain their IDs and denominator. This document carries additional work without silently renumbering that historical ledger. Items below are not all newly discovered: the original [test results](details/test-results.md) already recorded the 32 inherited expected assertions.

The combined optimized run executed 2,538 tests, skipped 14 and had zero **unexpected** failures. It reproduced **36 expected assertions**. An expected assertion is evidence of a remaining failure or unsettled contract, not a passing product guarantee. Counts below are assertions, not unique bugs.

| Suite | Expected assertions | Scope / next action |
|---|---:|---|
| ColorTableAccuracy | 4 | Original AI-03; actual GPU table output differs materially from intended colour. Non-enabled exact-stage prerequisites do not repair production. |
| CurveAdversarial | 8 | S-05/S-06 below; distinguish ordinary floating-point exactness, malformed-state policy and real discrete undo coalescing. |
| IngestAdversarial | 16 | S-01 through S-04 below; prioritize identity and false redundancy/ejection claims. |
| LayoutMetric | 3 | Existing narrow-column slider travel and source-comment contracts; carry with UX-03 interaction/accessibility qualification, without claiming source checks measure actual dragging. |
| MaskDependencyAdversarial | 2 | S-07: duplicate mask IDs resolve dependency roots inconsistently. |
| RollCursorAdversarial | 3 | S-08: duplicate photo URL fast path can disagree with first-index search and depend on cursor history. |

## Safety and state follow-ups

- **S-01 — ingest frame identity / eject, P1, implementing.** Two distinct source frames with identical bytes and the same rendered destination name collapse to one file and still report all verified. Preserve both identities or explicitly refuse; never overwrite an existing file. Astra safety lane owns the bounded repair and real-filesystem regressions.
- **S-02 — ingest aliased destinations, P1, implementing.** A backup root symlinked to primary produces duplicate files in one directory and claims two verified copies. Detect aliasing and refuse the redundancy claim. Same lane as S-01. Separate directories on one volume are not independent physical backups; do not overstate what directory-identity checks establish.
- **S-03 — ingest reporting/accounting, P2, queued.** Planned bytes are counted when already present, absent, failed or without destinations; failed frames can bring progress to 100%; summaries count attempted frames as ingested, and cancellation hides prior destination failure. Fresh short-read rejection and no-destination `allVerified == false` already pass: their remaining expected assertions concern accounting. The short-read test uses a `-1` missing-file sentinel as a byte oracle; replace that with an explicit missing-file assertion and a zero-copied-byte contract when implementing, not a product count of −1.
- **S-04 — renamed re-ingest idempotence, P2, queued.** After collision disambiguation, re-ingest repeatedly creates another suffixed copy instead of recognizing the existing copy. Preserve identity across collisions and reruns; do not deduplicate two different source frames solely by equal content.
- **S-05 — curve deletion history, P2, queued.** Two separate deletions at the same point index share a coalescing key and become one Undo. Separate discrete actions while preserving place-then-drag coalescing. Add an actual application/history regression, not only fabricated key strings.
- **S-06 — group movement numerical and malformed-state contract, P3, queued.** Three exactness assertions expose sub-ULP round-trip/rigidity differences (including a zero returning as −7.1e−15 and a persistent modified dot); three assertions cover out-of-range sets losing spread/reversibility or freezing; one covers NaN shown as zero while movement refuses. The NaN case is latent: no current decoder admits it. Define legal-state/UI reset semantics and malformed-state refusal before demanding impossible general bit-exact floating-point translation. Do not mislabel tiny roundoff as a perceptually large image error.
- **S-07 — duplicate mask IDs, P2, queued.** Dependency traversal resolves the first duplicate row and omits a Subject matte required by the other. Decide validation/repair of ambiguous imported identity; do not silently attach a different mask. Two expected assertions remain outside the already repaired current-root and normal reference-generation cases.
- **S-08 — duplicate roll entries, P2, queued.** Memoized index returns a later equal URL while `firstIndex` returns the first, with history-dependent results. Verify whether app ingress permits duplicates, then establish deterministic identity/navigation semantics and preserve fast-path performance.

## New deeper boundaries awaiting integration

- **S-09 — Uniformity antipodal boundary, open.** The non-enabled exact-colour investigation found a valid positive-RGB, measured-target, recipe-round-tripped case where CPU/GPU take opposite sides of a half-turn. Ordinary accuracy passes do not qualify this boundary. Track the forthcoming exact-prefix execution record; no creative-model redesign or production activation is authorized by the owner's Film Exposure decision.
- **S-10 — brush mask-wide subpixel composition, open, related to M04.** Retaining per-component paint/erase state does not make coarse-resolution Intersect of separately projected components correct. Multi-component algebra still needs shared fine-state qualification. Pending brush work must be described as partial, with memory and worst-case latency disclosed.
- **S-11 — batch angle/ruler dimensions, source-confirmed follow-up.** Crop-ratio work identified existing batch geometry paths using the primary image's dimensions for other selected images. The bounded M12 repair addresses ratio actions; rotation/ruler needs its own reproducer and evidence before being called fixed.

## Reporting rules

Record a tested code revision, red/green evidence, remaining expected assertions and skips for each checkpoint. Broad `XCTExpectFailure` blocks in inherited suites are not release waivers; remove or narrowly scope each when repaired, and ensure Linux actually executes repaired cases instead of returning early. A reduction in expected-assertion count alone is not proof of correctness. Native interaction, interrupted persistence, wider cameras, long-session memory and matched Lightroom comparisons remain separate work.

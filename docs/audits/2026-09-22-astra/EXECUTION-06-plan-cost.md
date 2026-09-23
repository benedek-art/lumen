# Execution 06 — Plan construction regression gate

Date: 2026-09-22. Implementation: `91d3a2c294be9602809db2d16b85d4879c213e74`.

**Outcome: a test correction, not a product speed improvement.** No shipping rendering, cache policy, table values or pixels changed. The old timing ratio inferred a synchronous table bake where actual counters showed none. Its replacement tests the intended operation and pixel contract directly; measured timings and ratios remain visible.

## Historical failures retained

The integration run reported two timing assertions among 2,493 tests: Whites draft approximately 7.4 ms versus settle 13.9 ms, and Saturation draft approximately 2.1 ms versus settle 7.3 ms. The isolated two-test run still failed Whites: draft 3.214 ms versus settle 9.769 ms. The former requirement was `draft < settle / 4`.

Evidence identifiers: `integration-full-02.log` and `integration-plan-cost-03.log`. These and the diagnostic logs named below are retained in the local audit evidence, not published as repository files. Personal and machine-local absolute paths are intentionally omitted here.

## Diagnosis: the ratio did not measure the asserted property

A standalone optimized probe linked the actual native LumenCore implementation and read its per-slot counters. In the first instrumented, cache-isolated Whites run, draft p50 was 5.330 ms versus settle 7.047 ms: ratio 0.756, failing the old gate. **Both finish and colorGrade nevertheless recorded 12 stale serves and zero synchronous bakes.** ToneGain recorded the intended 12 synchronous exact bakes. This directly contradicts the old assertion's claim that its ratio proves the expensive tables baked on the render path; it is not merely an assertion that the environment was noisy.

The initial probe ran during other audit work. It is causal counter evidence, not a quiet machine performance claim. Evidence: `lumen-plan-cost-diagnosis-first.log`.

Two measurement-state issues also mattered:

1. The old ratio test ran settle then draft over the same 12 keys without clearing the cache. Eight entries fit per slot. In the retained-cache probe, the draft finish slot had 8 exact hits / 4 stale serves and the color slot had 2 exact hits / 10 stale serves. That is not the same workload as a fresh-key drag. Deferred completion further changes residency.
2. `PlanTableCache.clear()` deliberately does not cancel an in-flight bake. That worker can repopulate an already-cleared cache. A cold measurement must drain **all slots before clearing**. `resetStats()` clears counters, not entries. The ambient photograph identity also remains until explicitly stamped.

Whites changes tone, finish anchors and the conservative color key. The original timing fixture has no live grade, so its color key can change without changing its color samples. The deterministic fixture activates a highlight wheel to exercise an actual color-output change. An initial new-test failure exposed that fixture weakness; it was not counted as a product defect.

## Replacement gate

The regression still constructs real `RenderPlan` values. A test-owned semaphore occupies the existing serial deferred worker in the unrelated proof slot; the tested recipes do not enable proofing. No production hook or globally suspended queue is introduced. Both waits are bounded, and `defer` releases and drains the worker on every exit, including assertion failure.

For 12 distinct same-photo values:

- Each changed finish/color slot must record exactly 12 stale serves, no hits, and **zero synchronous bakes**. While held, no deferred target bake may have completed.
- Draft tables must equal the prior same-photo plan's actual tables, including the finish normalization scalar. The current recipe still travels with the plan.
- Whites must retain its 12 exact synchronous tone-cube bakes. Saturation must hit the unchanged tone and finish entries. The tone cube must not become stale to satisfy a performance ratio.
- After worker release, each changed slot must publish one newest-request bake. This exact count applies because the target slot had no bake already in flight; existing cache tests separately cover in-flight work plus the newest pending request.
- Settle must hit the published exact key without synchronously repairing missing publication. Its complete tables and scalars must equal a fresh cold exact plan. The relevant controls must demonstrably change output samples.

Additional controls establish cold-draft costs, unchanged warm hits, and rejection of cross-photo stale borrowing. Setup/teardown use an explicit test identity and drain all slots. The timing probe independently drains and clears every row, prints per-slot counters and draft/settle ratios, and retains its 30-second sanity ceiling. The invalid ratio assertion was replaced, not loosened.

## Mutation checks and native qualification

Four temporary faults were injected into the actual cache and tested with the real XCTest regression:

| Deliberate fault | Expected assertion failures | What detected it |
| --- | ---: | --- |
| Synchronous color bake | 30 | Per-slot counts and stale table values |
| Synchronous finish bake | 15 | Per-slot counts and stale table values |
| Dropped deferred publication | 6 | Settle must hit; no repair bake allowed |
| Wrong published pixels | 3 | Complete settled tables versus fresh cold tables |

All four runs had zero unexpected errors. Evidence identifiers: `lumen-plan-cost-mutation-sync-color.log`, `lumen-plan-cost-mutation-sync-finish.log`, `lumen-plan-cost-mutation-drop-publish.log`, `lumen-plan-cost-mutation-wrong-publish.log`, and `lumen-plan-cost-mutations-summary.log`.

Harness correction recorded for transparency: a core-only build updates `LumenCore.o`, not a previously saved static archive. An initial attempt linked that old archive and did not activate the fault; it was rejected as invalid evidence. The reported mutation runs explicitly linked the newly built object. All temporary fault-injection source was then removed.

Final native optimized command:

```sh
swift test -c release --jobs 2 \
  --filter 'PlanCostProbeTests|PlanTableCacheTests|AccuracyProbeTests'
```

Result: **39 passed, 0 failed, 0 skipped**: 12 AccuracyProbe, 3 PlanCostProbe and 24 PlanTableCache tests. Build 269.80 seconds; tests 5.95 seconds. This includes existing tone/finish scalar pairing, key/eviction, in-flight joining, newest-request and photograph-identity controls. Evidence: `lumen-plan-cost-broad-green.log`. The final implementation commit modifies only `Tests/LumenCoreTests/PlanCostProbeTests.swift`; `git diff --check` passed.

## Coordinated quiet CPU measurements

All four audit lanes paused build/test/GPU work for three runs. Normal macOS activity was not disabled. Hardware/runtime: Apple M4, macOS 27, optimized native code. The probe linked the restored, freshly built core object. Only synthetic recipes and tables were used: no personal photograph, file-backed source, GPU render or UI event. “Cold” means plan-table-cache cold, not an OS/process/hardware-cache reset.

Each run measured 12 recipes per path and 200 samples per isolated stage. The normally running deferred worker remained part of whole-plan timing. Separate color/finish stage closures had to compare bit-for-bit with the real plan's tables before measurement. The following ranges describe the **three per-run percentiles**, not percentiles pooled across runs.

| CPU stage | Per-run p50 range (ms) | Per-run p95 range (ms) |
| --- | ---: | ---: |
| Tone gain LUT | 0.0168–0.0170 | 0.0303–0.0564 |
| Tone cube | 0.0562–0.0820 | 0.1268–0.2113 |
| Color cube bake | 1.7698–3.2959 | 3.3298–15.2261 |
| Finish cube bake | 1.8613–3.1908 | 2.7153–12.7687 |
| Canonical color key | 0.2483–0.3994 | 0.3978–1.4145 |
| Canonical finish key | 0.0255–0.0300 | 0.0386–0.1292 |
| Canonical tone key | 0.1023–0.1357 | 0.2309–0.3950 |
| Unchanged warm exact plan | 0.4565–0.5645 | 0.8080–1.3691 |
| Unchanged warm draft plan | 0.4485–0.4820 | 0.8277–1.2676 |

Whites' isolated draft/settle p50 ratios were **0.249, 1.037 and 0.571**. The last two fail the former threshold even in this coordinated window. Every run nevertheless recorded 12 stale serves / zero synchronous bakes in each expensive slot, with 12 intentional exact tone bakes. Deferred completions varied with worker scheduling: 1–11 finish bakes and 7–11 color bakes across the 12 events after draining. Key construction and exact tone work remain on the caller, and background CPU/coalescing affects the measured whole-plan ratio.

The controlled lifecycle probe also passed all three times: clearing during a bake allowed its key to reappear; draining then clearing made that request cold. Pending-work queries remained scoped to the originating identity. This confirms documented cache behavior, not a new corruption finding. Evidence: `lumen-plan-cost-quiet-1.log`, `lumen-plan-cost-quiet-2.log`, `lumen-plan-cost-quiet-3.log`; probe sources `PlanCostDiagnosis.swift` and `PlanCostTestRunner.swift` are retained locally.

## Limits

No speedup, end-to-end drag latency guarantee, full concurrency audit, local Linux execution or universal hardware threshold is claimed. This native qualification supports a stronger regression gate without changing application behavior. Hosted integration remains responsible for Linux execution and the full combined suite. The measurements above are observations, not release performance promises.

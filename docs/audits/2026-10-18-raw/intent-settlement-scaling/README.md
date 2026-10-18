# Portable intent settlement scaling prototype

8376b33's optional native workflow audit passed all final-XMP/history checks but
observed synchronous 1,000-target flush calls of 48,044 ms and 43,990 ms for the
5k/20k generated rolls. These are separate hosted observations, not controlled
before/after comparisons or owner-storage/RAW latency measurements.

The existing final publication block strictly decodes the complete durable journal
for its generation check. After writing the file and SQL observations, singular
`settleSidecarIntent` strictly decodes the journal again, removes one record,
sorts/encodes all remaining records, and writes the JSON inside a transaction.
Repeatedly processing a shrinking N-record array is at least quadratic aggregate
work. There is no schema/format change in this prototype.

## Witnesses and results

Both scripts use actual CatalogStore methods, synthetic metadata rows, generated
absolute paths, and tiny generated sidecar bytes. No photographs, image decoding,
AppState, CatalogService XML preparation, SHA hashing, render/display latency,
private storage, or owner-machine power-loss guarantee is measured. The driver
uses `-O` but links **debug LumenCore objects**. Timing cells are single observations,
with no latency thresholds. Setup and post-run correctness checks are excluded.

`SidecarSettlementScaling.swift` isolates existing operations. Milliseconds:

| Records | Strict generation check + settlement | Atomic file + SQL observation control | Combined |
|---:|---:|---:|---:|
| 40 | 29.386 | 29.613 | 74.525 |
| 200 | 698.854 | 157.839 | 1,044.280 |
| 500 | 3,831.340 | 377.052 | 4,557.928 |
| 1,000 | 16,554.780 | 808.766 | 19,121.767 |

The baseline control uses an arbitrary synthetic observation metadata key; it
measures the same metadata SQL API rather than the app's exact key spelling.
Raw TSV also records settlement alone and initial journal bytes. The result
supports journal processing as a substantial independent scaling cost, without
assigning an exact fraction of the native 44–48 second flush to it.

`SidecarBatchSettlementScaling.swift` compares existing singular settlement against
64-record final guards, physical writes, then the candidate atomic observation
and batch settlement helper, in one process with fresh sibling stores. This second
witness uses the actual v1 observation key in both arms. Milliseconds:

| Records | Existing guard/write/observe/settle | Prototype chunk64 |
|---:|---:|---:|
| 40 | 94.474 | 50.715 |
| 200 | 1,111.555 | 178.652 |
| 500 | 5,328.771 | 392.206 |
| 1,000 | 19,282.915 | 1,159.471 |

This combines less journal work with batched observation SQL transactions; it
does not isolate those two effects or qualify native service behavior. The helper is integrated into the isolated candidate CatalogService, with native
qualification still outstanding. The measured witness does not execute that service. Source/module/object/binary/witness
and result SHA-256 inventories are retained in the provenance files. Original
baseline links clean 8376b33 core; prototype source is identified by its hashes.

Reproduce with frozen source and an ordinary Swift installation:

```sh
swift build --scratch-path /tmp/lumen-settlement-build --configuration debug --target LumenCore
python3 scripts/probe-sidecar-settlement-scaling.py \
  --build-path /tmp/lumen-settlement-build --output-dir /tmp/lumen-settlement-existing
python3 scripts/probe-sidecar-settlement-scaling.py \
  --build-path /tmp/lumen-settlement-build --prototype --output-dir /tmp/lumen-settlement-prototype
```

The wrapper records fresh provenance; `--swiftc` supports a compiler outside PATH.
Cloud bootstrap also needed LD_LIBRARY_PATH/LIBRARY_PATH for its Swift dependencies.

## Core semantics and remaining integration gate

`settleSidecarIntents` independently reads and strictly validates current debt inside
one SQL transaction. Exact path, photo ID and optional generation must match an
existing record; a nil generation matches only an explicit legacy record. Only
matched publications update observations and disappear from the journal. Duplicate
publication paths are refused. An observation or final journal SQL failure rolls
back every observation and debt change in the group. Previously written physical
bytes remain intact and all unsettled intent survives for retry. Observation nil
preserves an unacknowledged external recipe's previous byte baseline.

Six focused core tests completed on Linux (0 failures, 0.249 seconds), covering exact
identity/legacy presence, stale generation, suppressed external acknowledgment,
observation and journal SQL rollback/retry with exact physical bytes, and malformed
journal/duplicate-path refusal, and partial-group journal UPSERT rollback. These
do not certify the native publisher. One final SwiftPM launch stopped with SIGILL
before output; unchanged-source retry printed six passed tests but its wrapper
exited nonzero with signal 4. Direct execution of the same built selected XCTest
class subsequently passed all six tests with exit 0 (0.305 seconds). Both logs remain distinct.

The candidate keeps injected external reads on their current caller
context, stages at most 64 publications and 8 MiB of nominal output Data, and
revalidates each exact prepared base
against current disk bytes immediately before writing. An oversized document
publishes alone without truncation. This byte limit is not an RSS bound: staged
source bytes, XML/content and the current input also consume memory. Later reads can otherwise
change an earlier staged file. Generation checks, dependency/availability rechecks, physical publication and atomic
batch observation/settlement share the catalog queue block; no SQL transaction
spans physical I/O. Fresh debt is not reused across queue blocks. Failures retain
whole owed fields, and failure callbacks remain outside the settlement queue block
(on the flush caller context, which may itself already be the catalog queue).
All existing interleaving, future-document, conflict-byte, restart, retry, close and
legacy-generation native acceptance remains required. This does not provide a lock
against another process writing in the remaining final read/write interval.

Nine native candidate tests cover later-reader base rewrites, removed painting
blobs, blocked physical destinations, stale culling observation permission,
unavailable markers, observation/journal SQL failure and retry, a three-entry
close during preparation, nominal prepared-byte bounds including a 9 MiB document,
and restart after already-written but unsettled SQL failure. They are source-only
until hosted macOS execution. The restart fixture normalizes only the required
writeStamp element because recovery legitimately publishes a new timestamp;
every other XML byte, including a foreign comment, remains compared exactly.
Existing ten durable-intent methods and all future-document/external-byte tests
remain unchanged acceptance gates.

The multi-entry reader-close cleanup exposure also existed in the earlier
per-file loop: a later entry could try the closed store and enqueue retries after
close. The candidate stops after a reader closes, retains full durable debt and
quit names, and guards retry persistence against closure. This is not evidence
that an earlier shipping run lost those edits; the journal remained durable.

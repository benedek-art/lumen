# S-03 — honest ingest accounting, progress and summaries

2026-09-22. Branch `codex/lumen-ingest-accounting`, based on `d698965` and retaining
the S-01/S-02 identity/ejection repair. S-04 suffix re-ingest recognition is not
changed. All filesystem fixtures are generated in temporary directories.

## Counter contract

The old driver added each frame's scanned byte count after every attempt. Failed
reads, already-present copies and short reads were therefore included in “copied”
bytes; failed attempts were described as ingested frames. Progress used that same
counter, so a run with missing data could reach 100%. Cancellation omitted known
backup failures from the summary.

The counters now have separate meanings:

| Field | Meaning |
| --- | --- |
| `bytesCopied` | Logical source bytes newly and successfully landed at least once, counted once per planned frame, not multiplied by backup count. |
| `bytesCompleted` | Source bytes belonging to frames complete on every requested destination, including proven already-present copies. |
| `bytesInFlight` | Tentative source-read/write activity for the current frame; not a delivery or verification claim. |
| `filesAttempted` | Attempts concluded, including failed frames; excludes destination-less refusals and a frame interrupted mid-copy. |
| `filesIngested` | Frames with at least one successful new or existing landing; a retained primary counts even if its backup fails. |
| `filesCompleted` | Frames successful on every requested destination. |
| progress `isComplete` | Every requested frame/destination finished, with no cancellation or refusals; this does **not** claim verification. |

`bytesCopied` uses retained `.verified`/`.copied` outcome digests, taking one logical
byte count per frame. It excludes `.alreadyPresent`, refused frames and frames
that fail everywhere. Zero-byte frames legitimately add zero bytes while still
counting as successful files. Failed readback removes the new file and contributes
zero delivered bytes; a failed/deleted disambiguated file is not listed as a
successful rename. The existing copy/read-back and source-protection logic remain
unchanged.

Verification-off `.copied` outcomes may complete copy progress and count as
available files, but the report remains **UNVERIFIED**, cannot claim “every copy
verified,” and cannot unlock eject. Only the original `isProven` plus identity
checks feed the eject gate.

## Progress and UI

Tentative activity receives 95% of the current frame's completion credit, reserving
5% for final landing/read-back. The displayed fraction is the lesser of byte
completion and frame completion; the latter prevents a failed zero-byte frame
from disappearing inside a byte-weighted 100%. Non-complete runs are capped at
99%; only an explicit complete state reaches 100%. With all-zero-byte inputs the
frame fraction is used. This weighting is progress presentation, not an estimate
of remaining elapsed time.

Successful uninterrupted runs are monotonic. On failure/cancellation, speculative
activity may roll back to the retained completion state; newly delivered
`bytesCopied` never includes that provisional amount. A settled terminal event is
published even when cancellation interrupts a frame. All-already-present runs can
reach 100% with **zero newly copied bytes**, as they should.

The ingest caption now labels newly copied bytes and in-flight activity separately,
and calls the frame counter complete rather than merely attempted. The primary
folder opens only when a successful primary result exists, not when an attempt
was made or only the backup succeeded. These are the only sheet changes.

Summaries use `filesIngested` rather than attempted counts. Partial destination
failure is still named even though one safe copy of that frame may exist.
Cancellation retains failure counts, destination roles and causes. A report with
all failed files says zero ingested, not that every attempted file was ingested.

The driver's exact per-planned-frame count handles repeated source entries. For
backward-compatible manually constructed reports, the optional new initializer
argument defaults to the number of distinct successful source URLs; callers that
manually represent repeated entries must supply the exact count. These public
report counters remain mutable, as before; they do not replace the stricter
identity/verification eject predicate.

## Qualification

Native macOS 27, arm64, Swift 6.4, optimized tests:

```sh
swift test -c release --jobs 2 --scratch-path <isolated-scratch> --filter Ingest
```

Ordinary-red qualification ran 28 accounting/adversarial tests and produced 17
failed assertions: ten in new cases and seven in inherited S-03 cases. Four
unrelated S-04 assertions remained expected. The first repaired all-ingest run
passed 78 tests with only those four unchanged expected assertions.

Final expanded native qualification: **85 tests, zero unexpected failures, zero
skips**, exit 0. The same four S-04 assertions remain expected across two tests.

Fourteen new real-filesystem tests cover logical counting across two destinations,
partial/universal write failures, existing copies, zero-byte successes/failures,
mixed sizes and monotonicity, cancellation, verification-off negative controls,
read-back rejection and stranger-file preservation, refused/destination-less
plans, backup-only success, and repeated planned source entries. Progress checks
distinguish provisional activity from retained bytes and assert that incomplete
events remain below 100%.

Six inherited expected-failure blocks are removed only after their assertions
pass ordinarily. The short-read test's former `-1` missing-file sentinel was not
a byte-count oracle: it now explicitly requires no landed file and zero delivered
bytes. Existing in-flight cancellation/race tests trigger on `bytesInFlight`;
the after-failed-attempt cancellation test uses `filesAttempted`, while successful
frame-completion tests retain `filesCompleted`.

## Limits and remaining work

S-04 remains open: a later run can fail to recognize an earlier disambiguated
`-1` copy and genuinely write a new duplicate. Its newly delivered byte count is
therefore still nonzero; setting that counter to zero without preventing the copy
would be another accounting lie. Both inherited S-04 tests and their four
expected assertions are retained unchanged.

S-01/S-02's filesystem lookup cost in `allVerified`, lack of atomic protection
against hostile retargeting, and lack of a distinct-physical-device guarantee
remain as documented. No durability, throughput or network-filesystem benchmark
is claimed. The app target compiles with the narrow sheet changes; this lane's
runtime qualification is filesystem/core testing, not a new native UI smoke test.

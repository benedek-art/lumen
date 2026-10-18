# Durable sidecar intent scaling witness

This synthetic Linux comparison uses the real `CatalogStore.saveRecipe` and
`withSidecarIntent` APIs with SQLite. It creates metadata rows, recipes, and
absolute synthetic paths; it reads no photographs and performs no XMP publication.
There are no timing assertions or acceptance thresholds.

Freeze source before building and running. With an ordinary Swift installation:

```sh
swift build --scratch-path /tmp/lumen-intent-build --configuration debug --target LumenCore
python3 scripts/probe-sidecar-intent-scaling.py \
  --build-path /tmp/lumen-intent-build --configuration debug \
  --output-dir /tmp/lumen-intent-results --max-count 1000
```

The wrapper resolves built module/object paths, compiles the witness, verifies
recipe and debt outcomes, and saves raw TSV, stderr, and SHA-256 provenance. Use
`--swiftc` if the compiler is outside PATH. Our cloud bootstrap additionally needed
LD_LIBRARY_PATH and LIBRARY_PATH pointing at its Swift dependency directory.
The witness driver uses `-O`; the recorded LumenCore objects were **debug** builds.
It is not a release-app latency measurement. Source/module/object hashes in each
provenance file identify the exact linked implementation, including a dirty tree.

## Measurements

The original accumulating two-arm probe and its exact output are retained as
`original-*`. The three-arm probe added a single whole-request transaction;
`three-arm-*` preserves that exact witness and results. `chunk-*` records the final
five-arm witness now available at `scripts/SidecarIntentScaling.swift`.

Final five-arm run (milliseconds; one run, not statistical estimates):

| Pending records | Bare saves total | Per-photo intent total | One batch total | Chunk64 total / first commit | Chunk128 total / first commit | Journal bytes |
|---:|---:|---:|---:|---:|---:|---:|
| 40 | 93.201 | 123.483 | 79.312 | 97.474 / 97.474 | 83.652 / 83.651 | 5,513 |
| 200 | 435.573 | 871.192 | 464.648 | 473.153 / 140.183 | 346.196 / 223.379 | 27,695 |
| 500 | 1,453.680 | 4,705.333 | 1,188.420 | 1,221.475 / 147.220 | 1,210.370 / 312.494 | 69,395 |
| 1,000 | 2,153.149 | 10,940.483 | 1,822.037 | 1,853.543 / 107.299 | 1,879.087 / 204.017 | 138,897 |

Bare and per-photo controls are interleaved in the same process; batch/chunk arms
follow. Setup and warmup are excluded. First commit measures completion of the
first SQLite transaction, not a power-loss or physical-device guarantee. The
unbounded 1,000-photo batch withholds its entire accepted prefix until its final
commit (1.717 seconds in the preceding three-arm run, 1.822 seconds here).
Chunk64 consistently shortened first-prefix time versus Chunk128 for 200–1,000
records in this witness. Total times vary with host load; this does not establish
64 as a universal optimum.

## Candidate behavior and limits

The service candidate uses at most 64 inputs per transaction. It sorts immutable
input once, then prevalidates and inspects painting for **each chunk** before that
chunk's SQL transaction. Individual photo failures roll back their savepoint.
Recipe rows and accepted intent records commit atomically; only committed chunks
are enqueued for XMP. Callbacks run after SQL has committed or rolled back.

If a later journal write fails, earlier committed chunks remain durable, accepted
rows in the failing chunk roll back, and the unattempted tail is refused with
counts. A process killed between chunks similarly retains only its committed
prefix. All chunks execute inside one already-enqueued catalog queue block, so
close cannot overtake an asynchronously scheduled tail. This still occupies the
queue for the full request: it does not make an entire large selection instantly
durable or responsive.

Per-photo journal updates decode/validate the whole JSON array, linearly locate
records, then sort/encode and rewrite it. Accumulating N records therefore repeats
whole-array work at least quadratically (sorting can add another factor).
Batching removes repeated decode/encode within each chunk while retaining the
format/schema, generations, merged field intent and rollback contract. The batch
core still uses linear record matching, and chunking still rewrites the growing
journal. A 20,000-photo selection, release-app scheduling, painting inspection,
XMP I/O, physical owner storage and UI responsiveness are unmeasured. This work
neither certifies those cases nor changes creative/rendering mathematics.

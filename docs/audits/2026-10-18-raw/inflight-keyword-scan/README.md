# In-flight keyword removal versus scan import

FD source keeps a durable delta until publication settles, but the scan's additive
keyword import projected only `pendingSidecars`. An explicit flush temporarily
removes that entry into its private batch. A one-shot publication reader that
rescans the photo can therefore re-import an intentionally removed tag from the
old XMP. Publication then removes the tag from XMP and settles the debt, leaving
catalog membership incorrectly resurrected. This exposure preceded the bounded
publisher; it is not evidence of a previously executed private-photo loss.

The candidate falls back to the matching photo's durable keyword delta. Before
projection it applies the same current-catalog membership filtering as recovery:
obsolete additions and outlived removals are not replayed. No journal format,
recipe, pixel mathematics, or unrelated external tag removal policy changes.
There is one `importKeywords` callsite in CatalogService, inside registerAndLoad;
folder and query-source acquisition share it.

## Executed portable causal evidence

`extract-witness.py` extracts the actual scan overlay and additive importer method
bodies from candidate CatalogService source. Only the importer's private access
modifier is removed to call it in a standalone Foundation wrapper. The witness
uses actual optimized CatalogStore mutation, keyword, and settlement methods.
The normal flow models an empty pending dictionary while a durable modern removal
remains owed. The legacy flow models startup recovery's empty queued delta for an
obsolete addition, while its raw legacy durable record still contains that addition.
The native fixture executes the real queue/recovery/publication lifecycle instead.

| Variant | Modern removal | Outlived legacy addition |
|---|---:|---:|
| Candidate | exit 0 | exit 0 |
| Remove only durable fallback | exit 1 | exit 0 |
| Remove only current-membership filter | exit 0 | exit 1 |

The fallback mutant produces catalog `[Kept, Private]`, published `[Kept]`, and
zero remaining debt. The filter mutant produces catalog `[Kept, Removed]`,
published `[Kept]`, and zero debt. Successful cases retain `[Kept]` throughout.
These are genuine witnessed integrity failures, not compiler failures, but are
**not a compiled macOS CatalogService or asynchronous runtime qualification**.

All six cases link the existing fresh optimized Core build at
`build-final-core/x86_64-unknown-linux-gnu/release`; no Core rebuild occurred.
Every Core source in the isolated FD checkout matches the archived built-source
manifest, with zero mismatches or extra files. The source manifest is a recorded
post-build snapshot, not a compiler-generated build-time attestation. Object and
module hashes identify the actual linked artifacts. The earlier preliminary
debug-object observation had a SourceFileIdentity mismatch and is not represented
as full-FD source identity. Root's later unrelated BrushStabilizer edits do not
change this detached FD snapshot or authorize treating new objects as old ones.

Provenance contains exact extraction/compiler/execution commands, environment,
source/module/object/binary hashes, expected and actual exits. Each executed Swift
source, compiler output and stdout/stderr log is retained. `executed-runner.py`
is the exact cloud orchestration script with its original scratch paths. To
reproduce elsewhere, build matching Core in release and substitute local paths in
that script, or use the explicit per-case commands from provenance. Extraction:

```sh
python3 extract-witness.py --source-root /path/to/candidate \
  --output /tmp/keyword-candidate.swift --mutant none
```

Compile/link that output against the matching Core module and all Core object files
as recorded. Run it without arguments for the modern removal and with `--legacy`
for the legacy control. Mutants are `no-fallback` and `no-filter`; they operate only
on extracted witness source and do not modify production files.

## Native gate

`InflightKeywordScanTests.testScanDuringInflightRemovalCannotResurrectCatalogKeyword`
uses the actual one-shot reader/scan seam with no intervening local edit, and
checks during-scan/catalog/reopened membership, published XMP and settled debt.
`testInflightLegacyAdditionThatOutlivedCatalogMembershipIsNotReimported` exercises
actual startup recovery before the same seam. Syntax parsing and diff checks
passed; hosted native GREEN plus independently controlled assertion RED remain
required. A past divergence whose debt was already settled is not automatically
repaired: guessing which historical catalog tags to delete would be unsafe.

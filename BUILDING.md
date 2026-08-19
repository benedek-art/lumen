# Building Lumen

Phase 1 (walking skeleton) is in progress. This file is the honest ledger of what
exists, what has been verified where, and what to do first on a Mac.

## Current state

| Piece | Status |
|---|---|
| `Sources/LumenCore` | Written **and machine-verified on Linux** via the fixture system below: recipe model, canonical sparse JSON + fingerprints, curves, zone weights, mask algebra, XMP sidecars, rename templates, catalog DDL (executed in real SQLite, grid query proven index-backed) |
| `Tests/LumenCoreTests` | Written; replays the verified fixtures. **Not yet executed** (written on a Linux box with no Swift toolchain — see "First run on a Mac") |
| `Sources/LumenPipeline` | Written, **untested**: CIRAWFilter wrapper (decoder pinned, draft mode), preview/export renderer (one graph for both — docs/13) |
| `Sources/LumenApp` | Written, **untested**: three-pane shell, embedded-preview grid, loupe with draft-render + embedded fallback badge, develop panel (exposure/WB/highlights/shadows/NR), JPEG export, G/E + arrow keys |

## First run on a Mac (Xcode 16+ / Swift 6 toolchain)

```sh
swift test          # runs LumenCoreTests against the golden fixtures
swift run LumenApp  # launches the walking skeleton
```

Expectations, honestly stated:

1. **Compile errors are likely on first build** — all Swift here was written without a
   compiler. They should be shallow (API signatures, imports), not structural.
2. **A failing `LumenCoreTests` test is the system working.** Every expected value in
   `Tests/LumenCoreTests/Fixtures/` was computed and property-checked by
   `scripts/gen-fixtures.py` (curve monotonicity, zone partition-of-unity, xxh64 vs the
   reference C implementation, XMP round-trip through a real XML parser, DDL executed
   in SQLite). A red test means the **Swift port** diverges from the verified
   reference — fix the Swift, not the fixture. Change a fixture only for an
   intentional format change, and say so in the commit.
3. The fastest way to iterate is running Claude Code **locally on the Mac** in this
   repo — it can compile, see errors, and fix them in a loop this cloud session cannot.

## The fixture system

`scripts/gen-fixtures.py` (Python 3, `pip install xxhash`) is the executable mirror of
LumenCore's algorithms. It generates `Tests/LumenCoreTests/Fixtures/*.json` and
self-verifies on the spot. Mirrored pairs — **change both sides together**:

| Swift | Python mirror |
|---|---|
| `CanonicalJSON.swift` | `canonical_number` / `canonical_serialize` / `sparse` / `merge` |
| `MonotoneCubic.swift` | `MonotoneCubic` |
| `ZoneWeights.swift` | `zone_weights` / `exposure_stops` |
| `MaskAlgebra.swift` | `mask_combined` |
| `XMPSidecar.swift` | `xmp_serialize` (byte-exact template) |
| `RenameTemplate.swift` | `rename_render` |
| `Schema.swift` DDL | extracted by regex and executed in SQLite |

`Tests/LumenCoreTests/Fixtures/default-recipe.json` is the committed statement of
`Recipe()`'s full default JSON; the suite fails if the Swift structs drift from it.

## Known deviations & Phase-1 placeholders (deliberate, tracked)

- **xxh64, not xxh3** for `recipe_fp` and blob refs (docs/15 says xxh3). The `xxh64:`
  prefix makes the algorithm self-describing; upgrading later is a migration, not a
  breakage. Rationale: xxh64 is portable and was verified against the reference
  implementation tonight; xxh3 was not implementable-with-verification on this box.
- **Highlights/shadows in Phase 1** ride Apple's `localToneMapAmount` /
  `boostShadowAmount` as approximations (`AppleRawSource.swift`). Lumen's own EV-zone
  engine (docs/04) replaces them in Phase 3 — behind the same recipe fields.
- **The loupe is a SwiftUI Image**, not the Metal/EDR layer yet. The render plumbing
  (draft decode, coordinator actor, one-graph-for-preview-and-export) is the real
  architecture; only the view swaps later (docs/16 Phase 1 calls the Metal loupe
  load-bearing — build it right once the skeleton runs).
- Per-photo recipes live in memory (`AppState.recipes`); the catalog (Phase 2) gives
  them the schema already shipped in `Schema.swift` + XMP sidecars already shipped in
  `XMPSidecar.swift`.

## Linux verification loop (what this repo's cloud sessions can run)

```sh
python3 scripts/gen-fixtures.py   # regenerates fixtures + runs all Linux-side checks
```

Exit code 0 means: canonical/sparse serialization behaves, hashes match xxhash's C
implementation, curves are monotone, zone weights sum to 1, mask semantics hold, XMP
parses, and both databases' DDL executes with the cull query on its index.

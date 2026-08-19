# Building Lumen

Phase 1 (walking skeleton) is in progress. This file is the honest ledger of what
exists, what has been verified where, and what to do first on a Mac.

## Current state

| Piece | Status |
|---|---|
| `Sources/LumenCore` | Written, machine-verified on Linux via the fixture system below, **compiled green and all tests passing on the CI macOS runner** |
| `Tests/LumenCoreTests` | **21 tests, all passing on macOS CI** (see Actions tab) |
| `Sources/LumenPipeline` | **Compiles on macOS CI**; runtime behavior reviewed by a 4-lens adversarial pass (decoder pinning, cached-filter state, crop axis all fixed from findings) — first *visual* verification happens on your Mac |
| `Sources/LumenApp` | **Compiles on macOS CI**; UI behavior reviewed (focus routing, loupe state reset, thumbnail cache) — first launch happens on your Mac |
| CI | `.github/workflows/ci.yml`: macos-15 `swift build` + `swift test`, plus a Linux job that regenerates fixtures with the Python reference and fails on drift |

## Running it on a Mac (Xcode 16+ / Swift 6 toolchain)

```sh
swift test               # the golden-fixture suite (green on CI as of this commit)
swift run LumenApp       # launch the walking skeleton directly
scripts/build-app.sh     # or build dist/Lumen.app and `open` it
```

What the walking skeleton does today: open a folder of RAWs (Cmd+O), browse the
grid on embedded previews, double-click or `E` into the loupe (draft-quality RAW
render with an honest EMBEDDED PREVIEW badge until the real render lands), arrow
keys to move, `G` back to grid, edit exposure / WB Kelvin+tint / highlights /
shadows / NR toggle, export a JPEG. That is the docs/16 Phase-1 slice.

Notes:

1. **CI compiles and tests this code on every push** — but no one has *seen* the
   app run yet. UI glitches, layout issues, and CIRAWFilter rendering surprises on
   real camera files are expected discoveries for the first Mac session.
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

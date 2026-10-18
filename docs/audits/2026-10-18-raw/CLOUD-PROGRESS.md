# Cloud continuation evidence

Starting checkpoint: `0f57d65710e8f13b919a06257825507bdd6ff1b4`, branch `codex/raw-accuracy-qualification`. Read CLOUD-HANDOFF.md for executed private-photo evidence and interruptions. No private assets are available here. No release, installation or main merge is authorized.

## Reviewed repairs awaiting native execution

1. Pending sidecar debt recovery used `currentRecipe` and clamped future pipeline versions on reopen, bypassing ordinary load containment. Recovery now uses the same checked recipe reader and leaves unreadable/future debt and sidecar bytes intact. New regression covers malformed JSON, future database version and future embedded version. Quit reports debt rejected before it could be queued.
2. New conflict-snapshot database work in `flushSidecars` could run outside the catalog serial queue. That block now hops onto the queue with a reentrant queue-specific guard. Filesystem reader adapters retain their existing concurrency behavior. Source-confirmed race repair; no executed race reproduction claimed.
3. Opening a rounded slider readout and submitting unchanged text converted a stored value such as 1.234 to 1. Sessions now retain initial text and return the original value for untouched submissions; no-op submission emits no edit events. Two new session tests cover precision, stale targets/values, real edits, arithmetic and preservation of existing out-of-range values. Native focus/pointer ordering remains unqualified.

No pixel algorithm, math tolerance, golden or creative default was changed. Slider source citations remapped once from the checkpoint baseline (two moved, zero unplaced).

## Public RAW first/cache investigation

Hosted RAW corpus lane now selects only its existing SHA-verified CC0 Sony A450 and Panasonic GH5S fixtures for native precision measurements and the unchanged exact displayed Off/AI-zero/Off-return check. These are public camera files, not the owner's A7 IV/GX85 acceptance set. Diagnostic logs measure lazy repeat, explicit half-float materialization, cache promotion and cached repeat before RenderPlan/display/dither. Raw first/cache differences are observations; the display exact-zero assertion is not weakened. Repeated evaluation of the same lazy/cached graph is asserted identical. Public-only evidence is uploaded by the existing corpus lane.

No decoder production fix has been justified yet. Half-float promotion remains a hypothesis until hosted evidence is available.

## Executed cloud checks

- `python3 scripts/test-check-swift-surface.py`: all 41 positive/negative fixtures passed.
- `python3 scripts/check-swift-surface.py`: passed on the starting checkout; rerun owed after integrated edits.
- `python3 scripts/test-gen-slider-atlas.py`: all canonical-file precedence cases passed.
- `python3 scripts/test-publish-staged-release.py`: 18 offline tests passed. No release action occurred.
- `git diff --check`: passed after repairs/citation remap.
- Native Swift and Ruby are absent from this Linux runtime. No native compilation, full suite, camera acceptance or release-policy Ruby pass is claimed locally.

## Outstanding gates

Complete exact-source optimized macOS suite and proof/GPU/layout/corpus results must be inspected, including discovered counts and skips. Public RAW fixture fetch/runner availability can block measurements. Existing second-resolution sidecar change detection, no recovery pruning, per-field culling partial transactions and unavailable-photo count/grid differences remain limitations. Do not present fixes as passed until causal native tests execute.

Tomorrow: private A7 IV/GX85 first-native and cached/Off-return reproduction, copied-shoot preview/export roundtrip, masks/texture/heal edges and detail/noise review, keyboard/focus/target-switch/undo ordering, physical removable-volume failures and original-byte preservation. Camera/colorimetric calibration and subjective aesthetics remain independent of mathematical/GPU agreement.

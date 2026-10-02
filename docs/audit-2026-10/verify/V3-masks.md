# V3: masks and local adjustments (PR #5 verification)

Verifier: V3. Worktree branch: `worktree-agent-aa352166c85ceb411`. I reset it to `claude/jolly-sagan-k7ch7z` @ a9a1d47 because it had been created from `main` 99c3727, which does not contain PR #5.
Build: `/tmp/lumen-build-v3`. LumenPipeline and LumenApp do not compile on Linux, so I checked every hunk in those modules by reading the source. The macOS-only regression tests (`Tests/LumenPipelineTests/*`, `Tests/LumenAppTests/*`) were reviewed but could not be run.
`python3 scripts/check-swift-surface.py` exit code: 0.

## Verdict table

| Finding | Commit | Verdict | Evidence |
|---|---|---|---|
| M01: disabled image-dependent donor supplies no source | 9b14267 | CONFIRMED (pipeline: source-verified only) | `maskSource` now ORs `maskReadsPicture` over the full `MaskDependency.closure` in `plan.allMasks`, and the overlay path passes `masks: [mask]`. The CPU reference always passes `source: image` (ReferenceRenderer:81), so this was a GPU-only defect and only the GPU needed changing. `MaskReferencePipelineTests` (macOS) covers direct, transitive, inverted, overlay, 256/1152 exports, cycles and switched-off groups, and compares against the enabled-donor render. Core hunk: reverting `closure()` makes `MaskDependencyTests` go red (2 failures) and `MaskDependencyAdversarialTests` go red (2 failures). Restored: 14/14 and 14/14. |
| M02: donor edits do not invalidate the borrower's alpha cache | 9b14267 | CONFIRMED (source-verified only) | The key is now `maskSelectionFingerprint(closure)`, which covers components, invert and refine across the whole closure, disabled donors included. It also carries stroke ref:count over the whole closure (refs are content-addressed: MaskCanvas:2089 stores before assigning) and a matte generation. I looked for an under-key on a duplicate-id root, e.g. `[x:A, x:A2→y, y→x]`. The resolver treats y→x as a cycle through `resolving`, and `closure` also stops there, so the key and the raster agree. I found no hole. Tests cover repeated small exports after a donor polygon edit, brush arrival, and a same-kind matte replacement. |
| M03: local curves ignore the Brightness-only / Colour-only blend | b00df8d | CONFIRMED, with a Linux test added | The fix is in both renderers: CPU `applyLocalCurves` uses `MaskAlgebra.blended`, and GPU S15b uses the same `compositeLocal` as S11 (rec2020 weights on both sides). The macOS test checks both against independent algebra. **Before my commit, no Linux test caught a CPU-only revert:** with the CPU hunk reverted, MaskingTests (24), MaskBlendTests (14) and RobustnessTests (40) all stayed green. Added in c1578b2. |
| M05: negative local Sharpness uses a fixed 2.5 px blur | d597019, d835ec8 | CONFIRMED, with a Linux test added | CPU and GPU both use `frameDenominatedSigma(2.5·s, longEdge)`. The GPU uses an exact 9-tap kernel below σ=1 to match the CPU's exact Gaussian, and keeps CIGaussianBlur at σ≥1, so the result at 2560 is unchanged. The macOS test checks CPU and GPU agree within 0.015 at 512–4096. d835ec8 only moves RobustnessTests' liveness fixture, which is legitimate. Same Linux gap as M03 (RobustnessTests stays green with the CPU hunk reverted). Covered in c1578b2. |
| M11: Strength >100 scales Texture/Clarity only on GPU | 6c9c026 | CONFIRMED, with a Linux test added | Both renderers use `scaledPresenceAmount` (clamp the control to ±100, then × strength clamped to [0,2]). CPU `applyTexture`/`applyClarity` take `strength:`. Dehaze clamps at ±100 in both renderers, so they agree on it. `LocalPresenceAmountTests` tests only the helper: with the ReferenceRenderer hunk reverted it stayed green 2/2. Covered in c1578b2. The disclosed limitation (CPU and GPU magnitudes differ) still stands. |
| M15: AI Amount enabled on rendered inputs | 4ba50e1 | CONFIRMED (source-verified only) | `DenoiseControlAvailability` drops `.ai` from the segmented options and disables Amount for rendered files. A saved AI recipe is kept, with a notice. I found no other UI writer of `denoise.mode`. Paste Settings from a RAW can still put AI on a JPEG. That case gets the same notice and is covered by the ledger's stated limitation. The tests are a struct test plus a source-string check (macOS). |
| 51c1ca1: mask/Automask cache invalidation on source replacement | 51c1ca1 | CONFIRMED (source-verified only), with collateral regression | The `MaskRasterCache` generation guard is correct. `clear()` also empties `inFlight`, old drains return without consuming new-generation work, and `store` refuses old-generation results. The picture key carries `source-generation`, and `brushPlanes.clear()` drops Automask prefixes. The macOS tests cover publishing during a running bake and during a synchronous bake. **Collateral:** see below. |
| S-07: the 2 expected assertions in MaskDependencyAdversarial | (3aa0370 / 94789a7) | WEAK-TEST, fixed locally | See the S-07 section below. Fixed in 5dff5ff. |

## S-07: what the "2 expected assertions" are

I re-enabled the body on Linux and ran it. The two failing assertions are the **mechanism-recording** ones, and they fail because the defect is fixed:
- `contributing(...)` returns `["src","dup","dup"]`, while the test expected `["dup","dup"]`.
- `wantedMattes(.vision)` returns `{aiSubject}`, while the test expected `[]`.

The pixel ("harm") assertion passes. The macOS evidence log `docs/audits/2026-09-22-astra/evidence/native-tests.log:5557-5560` shows the same two values as "Expected failure". `contributing()` has walked its roots by row since 3aa0370.

So the test **could not fail**:
- On macOS, the fixed state produces 2 expected failures. A regression would make the pixel assertion fail instead, and XCTExpectFailure would absorb that too.
- On Linux, the test returned before running.

5dff5ff rewrites it to assert the repaired roster with no wrapper, so it now runs on Linux. With the old id-seeded root walk substituted back, it fails 3 times (roster, matte roster, pixels). Restored, all 14 pass.

What remains of S-07 is a DECISION NEEDED for the owner, not a defect. A third mask's `maskRef: "dup"` resolves first-wins, consistently in every resolver. Whether duplicate ids should be repaired or flagged on load is the owner's call. `SUPPLEMENTAL-BACKLOG.md:13,24` should be updated: its two expected assertions no longer exist, and the stated defect ("omits a Subject matte required by the other") is fixed.

## Collateral regression from 51c1ca1 (performance, not correctness)

`PipelineRenderer.forgetMattes(for:)` now also runs `brushPlanes.clear()`, which clears every photo's brush planes, not just this URL's. It is called from:
- `RenderCoordinator.invalidate(url:)`;
- **every source cache miss** in `RenderCoordinator.source(for:)` (RenderCoordinator.swift:766-770), which covers a first open, re-acquisition after the 12-entry LRU, and `warmDecode` neighbour prefetch.

So browsing to an uncached photo, or a neighbour prefetch, throws away the edited photo's brush-plane prefixes. The BrushPlaneCache header puts these at about 8.5 s of settle for a 60-stroke mask. Before 51c1ca1, only `maskRasters` were cleared there (also coarse, but cheap to rebuild).

### Phase 2 spec
- Files: `Sources/LumenPipeline/PipelineRenderer.swift` (`forgetMattes`), `Sources/LumenPipeline/BrushPlaneCache.swift`, `Sources/LumenApp/RenderCoordinator.swift`.
- Change: drop only the entries whose `sourceKey != "-"` (the Automask, picture-dependent ones). The `source-generation` term in `pictureKey` already isolates them anyway. Optionally, call `forgetMattes` from `source(for:)` only when an identity was previously held for that URL (a real replacement), not on a first acquisition.
- Acceptance test (macOS, LumenPipelineTests): paint a non-Automask brush mask and render. Call `forgetMattes(for: otherURL)` and render again. Assert `BrushPlaneCache` reports no repaint for the untouched plane. Keep `testForgettingSameURLSourceAlsoForgetsAutomaskedBrushPixels` green.

## Phase 2 notes for the WEAK-TEST items fixed locally (M03, M05, M11)

Each fix itself is correct in both renderers. The gap was that only macOS tests guarded them, so a CPU-only revert passed the Linux lane.

`Tests/LumenCoreTests/LocalStageReferenceContractTests.swift` (c1578b2) now pins:
- the curve blend for Normal, Brightness-only and Colour-only at alpha 1 and 0.6, against independent algebra;
- softening retention spread under 0.06 across 512–4096 px, with the 2560 px result bit-identical to σ=2.5;
- Strength 200 ≠ Strength 100 for ±Texture and ±Clarity.

Substitution result: 9 failures with the three ReferenceRenderer hunks reverted, 3/3 pass restored. The 0.06 tolerance on retention spread is for discrete sampling at 512 px (0.79 there against 0.73 above it). The defect it guards spread those values from about 0.15 to 0.99.

## Smaller observations (no action taken)
- The mask thumbnail key in `AppState.refreshMaskThumbnails` (AppState.swift:1031) has no source-replacement generation and no stroke-availability term. After a same-path source replacement, thumbnails can stay stale until the next mask edit. Low impact.
- Global (non-mask) Texture/Clarity outside ±100 from a hand-edited sidecar: the CPU clamps, the GPU `applyPresence(detail:)` does not. This predates PR #5 and is not covered by M11.

## Pixels
My commits change tests only, so no proof record moves. The PR #5 fixes I verified move pixels in these cases, as their own commits already disclose by bumping `PreviewCache.renderingRevision`:
- local curves with a non-Normal blend (b00df8d);
- negative local Sharpness at any render long edge ≠ 2560 (d597019);
- local Texture/Clarity at combined Strength >100 on the CPU path (6c9c026).

## Local commits (not pushed)
- `5dff5ff`: The duplicate-id roster case asserted a defect that was already fixed, so it could not fail
- `c1578b2`: The reference renderer's halves of three local-stage repairs had no test on the Linux lane
- plus a commit adding this report (the worktree sandbox refused a write to the main-tree path)

Worktree branch: `worktree-agent-aa352166c85ceb411`

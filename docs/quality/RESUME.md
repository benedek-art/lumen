# Quality programme: state at pause and how to resume

Paused by the owner on 2026-10-21 at about 13:10 UTC, after one overnight run (00:30 to 13:10 UTC,
with a forced stop from 05:40 to 08:10 when the account's 5-hour usage window ran out).

This file is the single place to start from. Everything else it points to is in git.

## 1. Where things stand, in one table

| State | Count | Lanes |
|---|---|---|
| Merged into `claude/inspiring-dirac-ulgpch` (head `552412c`) | 29 | WS-04, WS-06, T1 (WS-07), T2 (WS-11/12b), T3 (WS-17/18), T4 (WS-19/20/21), T5 (WS-09/10), WS-03, C1 (WS-23/24), C2 (WS-25), C3 (WS-28), K1 (WS-35/36), K3 (WS-32/33), K4 (WS-29/30/37), WS-40, F1 (WS-39), M1 (WS-42), M2 (WS-44), M3 (WS-45/46), M4 (WS-47/48), M5 (WS-49), M6 (WS-50/43), M7 (WS-51/52), M8 (WS-53/54/55), M9, U1, U2, U3, plus the integrator's WS-01 wiring (`07244ae`) |
| Verified READY, not merged | 3 | WS-05 zonal tone `202088f` (waivers granted, see 4.1), K2 colour mixer `0583d65`, WS-16 saturation/vibrance `89aef97` |
| Paused mid-work | 10 | WS-13 display transform, WS-38 film stocks, WS-15 dehaze, WS-14 texture/clarity, WS-41 vignette, WS-02/08 eyedroppers and Zones, WS-56/57 heal, T1-fix (tone-mask GPU parity), M8-fix (local softening scale), M9b (range masks back on GPU) |
| Waiting on the owner | 1 | WS-05 white anchor, branch `quality/ws-05-white-anchor` (`04cc6cc` or later). Do not merge without sign-off. |
| Never started | 5 | WS-22 AI Denoise, WS-12 finish/soft proof, WS-34 exact colour plumbing, WS-58 recipe schema/registries, Lightroom pixel comparison |

The owner-facing report with images, per-lane verdicts and the Mac checklist:
https://claude.ai/artifact/Jx7huCtkq7iEkz7MKepuJU (its source is regenerated from lane REPORT.md files;
it reflects the state at about 10:30 UTC).

## 2. The integration branch

- Branch: `claude/inspiring-dirac-ulgpch`, head `552412c` ("After M5: surface check clean again").
- Linux: `swift build` clean, LumenCoreTests 3379/3379 (Swift 6.1.2, `--parallel --skip ControlProofTests`,
  the way CI's engine-linux job runs it), `scripts/check-swift-surface.py` exit 0. Proof sweep green on macOS.
- macOS CI on `552412c` (CI, GPU parity, UI layout, UI snapshots) had not reported at pause. Expected:
  - GPU parity RED on two known, lane-owned failures, both found at `4d7098e` (run 39575451037):
    1. `ToneMaskGPUParityTests.testTheGPUToneMaskMatchesTheReferenceOnANoisyModerateEdge`: GPU tone mask
       vs CPU definition mean 0.0383 EV (limit 0.02), worst 0.1383 EV (limit 0.06). Cause: T1 (WS-07).
       Fix in progress on `quality/t1-fix-gpu-parity`.
    2. `LocalSofteningScaleTests.testNegativeLocalSharpnessRetainsTheSameSceneContrastAcrossRenderSizes`:
       0.0275 / 0.0278 vs limit 0.025. Cause: M8 (WS-53) or T3 (sharpening radius in sensor pixels).
       Fix in progress on `quality/m8-fix-local-softening`.
  - Two merges whose own macOS CI never completed before merge: K3 point colour (watch GPU parity on
    point colour) and M5 AI masks (watch the macOS build on VisionMattes/SkyModel). If either is red,
    back that merge out (`git revert -m 1 <merge>`) and record why.
- Temporary fallback: `MaskGPU.rangeKindsOnGPU = false` (commit `84698be`). Range masks render on the CPU
  with M4's corrected picture, so drags with a range mask lag like before M9. Six range tests skip on that
  flag (none deleted). M9b restores the GPU path. See `docs/quality/lanes/M9/NEEDS.md` item 6.

First thing on resume: read the macOS results for `552412c`
(`mcp__github__actions_list list_workflow_runs branch=claude/inspiring-dirac-ulgpch`). Leave the branch
untouched for about 90 minutes whenever you need a full macOS verdict: every push cancels runs in progress.

## 3. Decisions waiting on the owner

1. **White anchor +5 EV to +3.0 EV** (WS-05). Sensor white renders at 242 instead of 221, median unchanged,
   nothing clips. Comparison: `docs/quality/lanes/WS-05/evidence/white-anchor-owner.png` on
   `quality/ws-05-white-anchor`. If approved, a follow-up lane must adapt WS-08's Bright pivot (lands at
   1.083, past the axis end), WS-09's AutoTone recovery threshold (+3.0 EV no longer reachable), 8
   ControlProof failures and about 132 proof records, on top of the integration branch.
2. **Grain taste** (WS-40): Roughness 0 to 75 look alike, only 100 clumps; Tri-X at grain 100 is very strong
   (16 codes on mid grey, 31 at push +2).
3. **Rotation kernel** (WS-25): Lanczos-3 is sharper (MTF 1.01 vs bicubic 0.95) but overshoots 3.15% on soft
   edges vs 1.9%. Keep, or soften?
4. **Upright Level on 4213** follows a field path, 1.4 degrees off. Make Level decline on frames like this?
5. **Brush Auto Mask** (WS-44): outline leak 5.3 / 13.4 / 4.3% vs 3% target, stroke 102 ms (5 to 7x faster
   than before vs 10x target). Merged as an improvement; accept or send back.
6. **Lens CA** (WS-28): 0.1 to 0.2 px corner over-correction on 3437/6001 (invisible). Per-lens TCA profiles
   would fix it; worth a lane?
7. **Point Colour speckle** (WS-32): on noisy high-ISO frames, plus rim selectivity 0.88x vs 0.80x. Needs a
   smoothed reference image for the point pass (WS-34 follow-up).
8. **Match Total Exposures** (WS-10 M7): misses on pans and odd zoom ratios, falls back to EXIF safely.
9. **WS-05 halo trades** (waived by the director, owner may overrule): Whites -100 halo 12 to 24 px (4213 sky
   3.2 to 5.4 codes), Shadows +100 29 to 33 px; Whites +100 improved 34 to 14 px. Root cause WS-07 N2/N9.
10. **AI Sky** (WS-49): selects pale walls or bokeh at the top of non-sky frames (1346 33%, 1332 16%,
    3582 13%). Fix is a licensed sky model. No people sub-parts: Vision on macOS 15 has none.
11. **White balance extreme tint** (WS-03): gamut clipping at Tint -150 / 2000 K (sRGB output clips instead
    of compressing). Needs a gamut-compression owner (WS-12 or WS-13).
12. Smaller calls listed in each lane REPORT.md "For the owner" section and collected in the report page:
    U1 default column width 390 pt, T3 fit-view sharpening preview, M6 grey octagons from Expand, K1 Balance
    strength, T5 dusk frame 1840 turned to daylight, WS-06 flatter -3 to -5 EV band at Contrast +100.

## 4. Resume work, lane by lane

Each lane's own branch holds `docs/quality/lanes/<LANE>/{AUDIT,SPEC,REPORT,NEEDS}.md` and `evidence/`.
At pause every lane was told to push what it had with an honest status line at the top of REPORT.md;
read that line first. Cloud sessions can be resumed with `send_message` to the session id below (they keep
their context), or a fresh session can start from the branch plus these docs.

### 4.1 Ready to merge (do these first; about one integrator run)

| Lane | Branch @ sha | Session | Merge notes |
|---|---|---|---|
| WS-05 Highlights/Shadows/Whites/Blacks | `quality/ws-05-zonal-tone` @ `202088f` | session_01Qsi359QYLkNX5yPKeKeE2s | 28/32 lines pass. Director waived HA1/HA3 (halo trades above) and S3 (metric mixes in-shadow texture with border contrast). A1/A2 are the white anchor, NOT in this branch. No renderer file touched. Whites now adds 0 degrees of hue drift (was up to 14). |
| K2 Colour Mixer | `quality/k2-color-mixer` @ `0583d65` | session_01JM6f8BH6mfmDWZTHi5Budz | Check GPU parity is green on that exact sha before merging. Touches ColorPanel/LookPanel (U1 already merged: expect conflicts, keep U1 tokens). |
| WS-16 Saturation/Vibrance/Density/B&W | `quality/ws-16-saturation-vibrance` @ `89aef97` | session_01HqeACYbwSAtwumsv8wzxX9 | All macOS green incl. GPU parity. On merge: NEEDS N5 bump the preview-cache revision; N6 ProofRegistry `bw.*` floor 107 to 44, check it keeps the same ratio to newly measured authority (as F1's did) and is not a loosening. |

### 4.2 Paused mid-work

| Lane | Branch | Session | Where it was | What's left |
|---|---|---|---|---|
| WS-13 Display transform (owner's "blue highlights"; overall look) | `quality/ws-13-display-transform` | session_01E3YFY7oX8coNWkYKcE7khw | Round 2 build/verify. Spec lines 3.1 to 3.9: blue probes and the full hue ring within 5 degrees (p95 4) from -2 to +3 EV on huePreservation-100 presets, chroma still rolls to white. Fix route: the outset fully undoes the inset rotation (AgX inverse), shoulder bleaches toward neutral at constant hue instead of the max-channel per-channel fade. Also display mid-grey 0.18 to 0.25 (ACR3 curve maps 0.18 to 0.388; justified scene-referred, not by Linux decode darkness) and CC chroma 0.92 to 1.05-1.20. | Finish verify, macOS GPU parity, merge. Highest priority remaining: it fixes WS-04's open items too (skin yellowing +20 to +33 degrees at +3 EV, deep blue +15 degrees at +2 EV). Every other lane's renders depend on it, so re-check K1/K3/WS-38 evidence after it lands. |
| WS-38 Film stocks (owner: "film looks are horrific") | `quality/ws-38-film-stocks` | session_01NSZ8jC1zDU1MQ7Ce5F2FNb | Round 2 builder. Audit + spec + measure.py pushed. | Finish, verify, merge. Then F1 halation's M10 (Cine 250D default halo too strong; no CineStill stock) unblocks. |
| WS-15 Dehaze | `quality/ws-15-dehaze` | session_015tfYb6QnrVwMgWro3EVWre | Builder rewriting the dehaze files (round 2). Only audit/spec pushed before pause. | Finish, verify, macOS parity, merge. |
| WS-14 Texture/Clarity | `quality/ws-14-texture-clarity` | session_01F3GskHJonXKetaca3ACpkV | Rebuilt as edge-gated bands, same algorithm on CPU and GPU; 46/51 lines passed; not verified. | Verifier, macOS GPU parity, merge. |
| WS-41 Vignette (owner: "mediocre, needs customizability") | `quality/ws-41-vignette` | session_018PontP9prxGpaNVdsCs4S5 | Style, Midpoint, Roundness, Highlights built with per-line measurements; no report or verifier yet. | Verifier, UI snapshot check, macOS, merge. |
| WS-02/08 Eyedroppers + Zones | `quality/ws-02-08-pickers-zones` | session_01KxH5NYKMvCTj5BvQQCy29C | WS-02 verifier PASS; WS-08 Zones audited, dead wheel/sat/falloff fields decision pending. | Finish WS-08, merge. |
| WS-56/57 Heal, clone, dust | `quality/ws-56-57-heal` | session_0188XexB26uEdJ1h6GBS945G | Report drafted; default spot no longer blends half the blemish back; heal ΔE at most 0.06; new Remove Dust button. Open: Remove Dust marks plaster pits on smooth walls (10 on 6929). | Verifier, macOS, merge. |
| T1-fix Tone-mask GPU parity | `quality/t1-fix-gpu-parity` | session_018MutzbmRr36tXSokPguG1W | Making `RenderGraph.applyTone` / the GPU guided filter match the CPU reference again (see 2). | Green gpu-parity on its own branch, merge. Do not loosen the test. If it can't be fixed, revert merge `da0ed57` instead. |
| M8-fix Local softening scale | `quality/m8-fix-local-softening` | session_01QZU4juWwtmMFt4GiSDPAw6 | Finding whether M8's applyLocalSoftening or T3's sensor-pixel radius causes the size dependence (see 2). | Green gpu-parity, merge. If unfixable, revert the M8 merge `41d0690`. |
| M9b Range masks back on GPU | `quality/m9b-range-gpu` | session_019KYf7nydGKiFYKErwzurdg | Porting M9's range kernels to M4's CPU definition (centred shoulders, guided denoise of the measurement on the GPU, colour range shading-invariant). | Turn `rangeKindsOnGPU` back on, un-skip the six tests, MaskRangeGPUParityTests (full and half float) and MaskSpeedTests green on macOS, merge. |

### 4.2b Exact state each paused lane reported at 13:11 UTC (supersedes "Where it was" above)

Several verifiers were cut off by the account usage limit just before the pause, so "unverified" below
means "built, never checked", not "failed".

| Lane | Pushed head | Status at pause | First step on resume |
|---|---|---|---|
| M8-fix | `quality/m8-fix-local-softening` @ `f3ec6a5` | **Fixed.** `LocalSofteningScaleTests` now passes on macOS (run 39586420398). Cause was M8's sqrt radius putting sigma below 1 on a sampled Gaussian, not T3; fixed with a discrete Gaussian on both CPU and GPU. Run is red only on the T1 tone-mask test, which M8 doesn't touch. | Merge (it clears one of the two integration-branch reds). |
| M9b | `quality/m9b-range-gpu` @ `1cfad55` | Code done, `rangeKindsOnGPU` back on. macOS gpu-parity passed every range test (6 un-skipped plus new denoise/noise-table tests) on `eb75b22`; only the two known reds remained. Verifier cut off; final-sha CI not checked. | Run the verifier, confirm gpu-parity on `1cfad55`, merge. |
| T1-fix | `quality/t1-fix-gpu-parity` @ `6deaf1a` | **Not fixed yet.** Centred variance cut the tone-mask parity error from mean 0.0383 to 0.0244 EV (limit 0.02); the worst-case assert now passes. Next suspects: fp16 storage of the guided filter's a/b coefficients, or CIBoxBlur rounding. Linux gates and spec S1-S7 green. | Try float32 for the a/b planes first. If it can't reach 0.02, decide between reverting merge `da0ed57` and keeping T1's visible halo improvement with a documented parity tolerance (owner/director call; don't silently loosen). |
| WS-13 Display transform | `quality/ws-13-display-transform` @ `d37998d` | Blue fix built: inset rotation undone, constant-hue path to white. Last tested commit `5a1b43d` passes 3055/3055 on Linux but fails one proof floor; round 3 (gPurity floor) is unverified WIP. No verifier has run. Density/mid-grey change waits on WS-05's white anchor (NEEDS.md). | Run the verifier on `5a1b43d` vs `d37998d`; resolve the proof floor honestly; macOS parity; produce an owner before/after sheet (it changes every photo). |
| WS-38 Film stocks | `quality/ws-38-film-stocks` @ `ecaa7b4` | Round 2 committed, 36/39 spec lines pass, 3057 core tests pass. Verifier FAIL on: Film Exposure -2 combined with Push +2 gives green shadows; 33³ LUT accuracy for Ektar and Velvia; Portra vs Cine 250D not distinct enough (S38/S39). **Do not merge as is.** | Round 3 on those three; then owner taste check with a stock-by-photo sheet. |
| WS-41 Vignette | `quality/ws-41-vignette` @ `d0fc9c6` | Round 2 (`627245c`) verified 31/32 with CI green (except the pre-existing surface check). Round 3 (lines 31-34: Colour Priority bright-colour monotonicity, tiny-frame identity, Paint Overlay hot pixels, feather kink) is unverified WIP. | Either merge `627245c` (verified, 31/32) now, or verify round 3 first. |
| WS-14 Texture/Clarity | `quality/ws-14-texture-clarity` @ `7e9f8d6` | Round 1 (`e406d6e`) verifier FAIL 46/51 and 2 GPU parity tests red; tip is unverified round 2 WIP. | Verify round 2, fix GPU parity, macOS. |
| WS-15 Dehaze | `quality/ws-15-dehaze` @ `576dbf2` | Round 1 (CPU+GPU) at head passes 33/44 spec lines but is too weak: U2 and the `detail.dehaze` authority floor (9.8 vs 68) will fail CI. Round 2 is stored as an unapplied patch in the lane folder. Verifier never ran. | Apply the round-2 patch, verify, macOS. |
| WS-56/57 Heal | `quality/ws-56-57-heal` @ `68559fa` | Round 2 pushed, unverified (verifier hit the usage limit). Round-1 CI fix in. C3 2/5 and C5 8/9 still fail by spec; spots straddling an edge are a known limit. | Verifier on `68559fa`, macOS, merge with C3/C5 as open items if the rest passes. |
| WS-02/08 Eyedroppers + Zones | `quality/ws-02-08-pickers-zones` @ `4e4b171` | WS-02 done and verified PASS. WS-08 round 3 built and pushed (Linux 3105/0), verifier cut off. | Re-run the WS-08 verifier on `3454637`, then merge. |

### 4.3 Not started (write a lane brief from `docs/quality/workstreams.md` when resuming)

- **WS-22 AI Denoise.** The trained weights live only on the owner's machine (`Denoise/README.md`: "photos and
  weights stay local, never in git"), so no cloud lane can run or evaluate the model. Options: (a) owner runs the
  release gate locally (`python -m lumen_denoise.eval.gate --model net:runs/A/best.pt ...`, see
  `Denoise/docs/RELEASE_GATE.md`) and shares the verdict; (b) upload weights somewhere a session can fetch them;
  (c) a supervised session on the owner's Mac. Today the AI Amount slider drives Apple's decoder NR as a stand-in
  and `AIDenoiseSplice` has no caller.
- **WS-34 exact colour plumbing.** Needed for Point Colour's smoothed reference (decision 7).
- **WS-12 finish/soft proof.** Owner of output gamut compression (decision 11).
- **WS-58 recipe schema and registries.** Owed several roster rows and floors listed in lane NEEDS.md files
  (C3, K4, F1, WS-16); also recipe versioning, which the camera-log LUT tap (K4 L7) waits on.
- **Follow-ups created by merged lanes** (each in that lane's NEEDS.md):
  - Contrast saturation term (WS-06 S20, needs WS-07).
  - Multi-scale (local Laplacian) tone application, to stop the HDR combo losing ~20% foliage contrast (T1).
  - Per-photo grain seed (WS-40, needs WS-01).
  - Perceptual (EV-domain) local mask blending (WS-45 N1; changes every mask's picture, owner call).
  - Subtract over soft areas removes nothing / Intersect at Amount 0 wipes the mask (M6; patches written).
  - Brush, polygon, AI and refined masks still re-rasterize on CPU after a global tone edit (M9).
  - Camera model in the NR noise profile (T4: full-frame bodies get ~1.5x more smoothing than needed).
  - Camera-log LUTs (S-Log3 to 709) render wrong (K4).
  - Constrain-to-Image uses an inscribed rect, up to 25% smaller than Lightroom at 10 degrees; no vertical flip (C1).
  - Local Sharpness still uses the old radius scale (T3); negative local Noise not built (M8).
  - Tapping a component row of an unselected mask doesn't show its overlay (M1, one line for WS-43).
  - Paste stays lit with an empty clipboard; two-pane before/after ignores surround (U3).
  - Esc in a value field doesn't undo ↑/↓ nudges (U2).
- **Lightroom pixel comparison.** No exports were received, so every "like Lightroom" claim is from Adobe's docs.
  The 58 presets and checklist are in `docs/quality/lightroom-reference/`. Put the exports under `corpus/lightroom/`
  with the same photo ids and every lane can measure ΔE against them.

## 5. How the machinery works (for whoever resumes)

- **Brief every lane follows:** `docs/quality/LANE-BRIEF.md` (setup, four roles, gates, outputs, UI snapshot use).
- **Control inventory and lane ownership:** `docs/quality/controls.md`, `controls.json` (256 controls with recipe
  paths and CPU/GPU call sites), `workstreams.md` (57 workstreams, owned functions, collision hot spots).
- **Seeing images on Linux:** `swift build -c release --product lumen-render`, then
  `lumen-render render|sweep|keys` (manual in `Sources/LumenRender/main.swift`). Setup:
  `bash scripts/proof/cloud-setup.sh`. Corpus: `bash scripts/proof/fetch_corpus.sh` (25 CC0 RAWs incl. A7 IV and
  GX85, plus synthetic frames; conventions and the 0.2 to 0.4 EV darker-than-Apple decode in
  `scripts/proof/CORPUS.md`).
- **Seeing the UI:** every push renders panels on macOS to branch `ui-snapshots`
  (`git show origin/ui-snapshots:<branch-with-dashes>/LATEST`).
- **Integration:** one integrator merges READY lanes in batches of 4 to 5, builds after each merge, runs
  LumenCoreTests once per batch, `check-swift-surface.py`, and pushes every 30 to 40 minutes. Helper scripts used
  overnight: `docs/quality/integrator-tools/` (`mergeone.sh`, `gate.sh`, `coretest.sh`). The director's raw
  overnight ledger (every session id, READY sha and decision, in time order) is `docs/quality/ledger-2026-10-21.md`. Re-cite the LayoutMetric inventory after UI merges
  with `recite-slider-inventory.py HEAD --write`.

### Rules learned the hard way (keep them)

1. **READY needs a green macOS gpu-parity run on the lane's final sha.** Overnight, lanes reported READY on Linux
   while macOS was queued; T1 and M8 then broke GPU parity on the integration branch.
2. **Two lanes that change the same definition must merge together and re-check parity together.** M4 changed the
   range-mask definition that M9's GPU kernels copied; each was green alone, red together.
3. **Push rarely.** Each push starts five macOS workflows and the runner queue reached 51. Lanes push only when they
   need a macOS result and once at the end. Leave the integration branch quiet to get a verdict.
4. **The 5-hour usage window is the real throughput cap.** About 38 parallel sessions exhausted it in roughly 2.5
   hours. Run fewer lanes (15 to 20), prioritised, or stagger them.
5. **Never loosen a test to get green.** Lowered floors were accepted only where the new value kept the same ratio
   to newly measured authority (F1 halation).
6. **Owner-visible look changes (white anchor, display transform) need a before/after sheet and sign-off.**

## 6. Suggested order when resuming

1. Read macOS CI on `552412c`; back out K3 or M5 only if they are the cause of a new red.
2. Collect each paused lane's PAUSED line and pushed sha (REPORT.md top line on its branch).
3. One integrator run: WS-16, WS-05 (zonal), K2, M8-fix (already green on its test), then M9b after its
   verifier, WS-41 at `627245c` if you take the verified round 2. T1-fix only once its parity passes.
4. Resume WS-13 and WS-38 first (largest visible effect: blue highlights, base look, film looks), then WS-41,
   WS-15, WS-14, WS-56/57, WS-02/08.
5. White anchor once the owner signs off, as its own follow-up lane.
6. Wave 2 from the owner's Mac checklist notes, plus WS-34, WS-12, WS-58, AI Denoise when weights are reachable.

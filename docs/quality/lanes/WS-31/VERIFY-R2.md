# WS-31 Colour Mixer, verifier round 2 (sha 3dc4f91)

**Verdict: FAIL.** This is a narrow fail. The engine is cleared.

All three round-1 engine defects are fixed, and I re-measured each one independently:
- Blue and Purple hue authority now passes the ControlProof floor.
- The Hue move follows the Band range ring.
- Uniformity combined with Hue no longer folds the hue circle.

The GPU kernel and its twin match the CPU line by line. ControlProof, GPU parity, Proof sweep and UI snapshots are green.

Three things block a pass:
1. **The Band range fold, now visible for the first time, has a real UI defect.** At the new default geometry the two core handles of the selected band touch or overlap. The "bright arc" that the caption tells the user to drag is not visible.
2. **CI (`ci.yml`) and UI layout have not run.** Both were still queued on 3dc4f91 at 10:06 UTC. T4 and U9 cannot be signed off.
3. **REPORT.md is still missing.** It is required by brief §3 and was item 5 on the round-1 fix list.

## Setup

| what | where |
|---|---|
| Worktree (detached 3dc4f91, corpus symlinked) | `/tmp/claude-0/verify2` |
| Binaries | `/tmp/claude-0/vbin2/{new,base}` |
| Tool outputs | `/tmp/claude-0/vout2-3dc4f91/` |
| Breaks | `.../brk/` |
| Crops | `.../crops/` |
| Stage probe (SwiftPM against this worktree's LumenCore) | `/tmp/claude-0/probe2` |
| Snapshots | `/tmp/claude-0/vsnaps2` (origin/ui-snapshots) |

CENT = `17.2,60.925,102.25,143.225,203.7,253.25,295.75,336.3`, read from `ColorEngine.bandHueCentres` by the probe.

## 1. Gates

| gate | result |
|---|---|
| `swift build --target LumenCore --target LumenRender` | clean. No warnings in ColorEngine or ExactColorStage |
| `swift build -c release --product lumen-render` | OK |
| `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` | 3068/3068, exit 0 |
| `swift test -c release --filter ControlProofTests`, CHECK mode, no LUMEN_RECORD_PROOFS | 6 tests, 0 failures. The worktree is clean afterwards, so nothing was re-recorded |
| `swiftc -parse` on every changed .swift | 0 errors |
| `check-swift-surface.py` against surface-base.log | only count drift. Same 6 pre-existing init mismatches; no new failures |
| Proof records `git diff --stat 9068ded..3dc4f91` | 25 files, all `mixer.*`: 24 band records plus `mixer.uniformity`. No other record changed |
| `mixer.blue.hue` authority | 13.0 → **20.06** (floor 17) |
| `mixer.purple.hue` authority | 28.23 |

## 2. SPEC lines (fresh run, judged per amendments R1–R8)

| line | measured | verdict |
|---|---|---|
| G1 | 0.892 | PASS |
| G2 / G2b | 0.659 / 0.417 | PASS |
| G3 | 1.000 | PASS |
| G4 | Green 0.637, G+Y 0.912 | PASS |
| G5 | 0.039 | PASS |
| G0, G6 | `MixerBandGeometryTests` green | PASS |
| H1 (display) | 0.105 | PASS, thin margin (round 1 was 0.121; worst is Yellow −100) |
| H2 / H3 (display, informational per R1) | 4.07 / 25.4–35.9° | informational |
| H2 / H3 via H6 (stage, my probe, 0.05° grid, 12 rows) | slope 0.260–1.740; centre shift 28.24–33.17° | PASS |
| H3b, H4 | | PASS |
| H5 | 1.08% / 0.0012 | PASS |
| H6 | tests green; probe as above | PASS |
| L1 | −1.10 / −1.46 / −1.20 EV | PASS |
| L2 | +1.18 / +1.12 / +0.88 EV | PASS |
| L3 | 0% | PASS |
| L4 | 1.16 / 1.26 / 1.01 | PASS |
| L5 | 0.264 | PASS |
| L6 | monotone | PASS |
| L7 | 1.07 / 0.77 / 0.73 | PASS |
| K1 | monotone | PASS |
| K2 (R2, stage) | Sat and Lum leave h untouched (h = converged + hueMove; both are 0 without Uniformity or Hue). Display 14.0° is informational | PASS |
| K3 | 0.413 | PASS |
| K4 (R3: MST 3–8 + CC skins) | min \|dL\| 0.052 | PASS. MST 1, 2, 9, 10 are static: known limitation |
| K5 (R4: MST 5–8) | 1.71 (MST 3–8: 3.94, informational) | PASS |
| N1 / N2 / N3 / N4 | 1 / 0.00 / 1.30 / 0.0253 | PASS |
| X1 | finite | PASS |
| X2 | 3.18% | PASS |
| X3 | 1.404 | PASS, no margin |
| X4 | 0 | PASS |
| X5 | hue 0.062 / sat 0.100 / lum 0.095 | PASS (sat exactly at the limit) |
| X6 | 0 | PASS |
| T1 | twin and kernel review clean (§4) | PASS |
| T2 | 3068 tests, 0 failures. **No REPORT.md** | number PASS; deliverable **FAIL** |
| T3 | RobustnessTests floor 0.2 → 0.1 is still a disclosed spec conflict | owner decision |
| T4 | gpu-parity green; ci.yml **queued** | **PENDING** |
| T5 | explicit wire defaults with Orange lum −100: bit-identical to no keys on 6933, 6929, 2545, 1569 | PASS |
| R5 | as in §1 | PASS |
| R6 | §3a | PASS (see caveat) |
| R7 / R8 | §3b | PASS |
| V1 | Green sector rotates as one piece, with no crease (`crops/hw_green_base_r1_r2_pm100.png`: rows base / R1 / R2). 1569: foliage goes olive or yellow-green at −100 and cooler green at +100, with no orange or teal blotches (`crops/1569_green_m100_0_p100_crop.png`) | PASS |
| V2 | sheets byte-identical to round 1. Deeper slate sky; faint leaf outline at 3× | PASS (marginal, as in R1) |
| V3 | sheets byte-identical to R1. See note below | PASS, with the R3 caveat |
| U1–U4, U6–U8 | §5 | PASS |
| U5 | §5 | **FAIL (design)** |
| U9 | snapshots green; ui-layout **queued** | **PENDING** |
| E1, E2 | unchanged from R1 | PASS |

V3 note (judged differently from R1):
- The Blue-lum "radial apex" follows the hue wheel's own high-chroma blue spoke.
- At r = 20 px the blue wedge has C 0.048 (above the gate), where the median chroma at that radius is 0.041. The spoke is also visible in the untouched tile.
- So this comes from the content geometry, not from a wedge in the engine.

## 3. Re-check of the round-1 fix items

### a. R6: Hue follows the Band range ring

Wire units are relative: 22.5/15 is the default. Columns are input-hue span moved by more than 1° / largest move.

| band | narrow (0,0) | default | wide (45,30) | max (1000) |
|---|---|---|---|---|
| Red | 72.4 / 23.3° | 91.6 / 29.7° | 174.7 / 35° | 266.9 / 35° |
| Orange | 72.7 | 96.9 | 189.2 | 267 |
| Yellow | 71.0 | 85.0 | 169.0 | 267 |
| Green | 82.8 | 113.9 | 187.3 | 267 |
| Aqua | 88.6 | 120.9 | 189.1 | 267 |
| Blue | 77.1 | 101.4 | 188.8 | 267 |
| Purple | 71.4 | 89.6 | 173.0 | 267 |
| Magenta | 70.5 | 91.1 | 173.1 | 267 |

- Every ring stays monotone: engine min 0.260, twin min 0.258.
- **Caveats for the owner** (not gated):
  - The Hue move reaches **1.35×** further than the drawn ring. At max ring an Orange Hue +100 moves 267° of the circle, and 2545's green tree and lawn go teal (`brk/2545_ringmax_or_hue.png`, `crops/2545_strip.png` panel 3).
  - Narrowing the ring also weakens the move (29° → 23°).
  - "Half" and "narrow" are identical because of the minimum-reach floor.
  - At the default ring, a band's Hue ±100 now moves its **neighbours' centres by 1.8–5.6°**. Round 1 moved them 0°. Example: Orange +100 moves the Yellow centre +5.6° and the Red centre +4.9°; Blue −100 moves Purple −5.1°. This is Lightroom-like spill, but it is a selectivity change.

### b. R7 / R8: Uniformity with Hue

Probe: every band ±100, alternating in both phases, all +100, an opposing pair, narrow, wide and mixed rings. Rows L/C 0.6/0.06, 0.4/0.12, 0.8/0.2, 0.5/0.03; 0.05° grid.

| Uniformity | engine min | twin min | verdict |
|---|---|---|---|
| 0 | 0.260 | 0.251 | PASS |
| 50 | 0.130 | 0.123 | PASS |
| 100 | −1.6e-11 | −0.0093 | PASS against R8's ±0.01 twin floor, with little margin |

- Not gated: Uniformity 75 floors at 0.065 and Uniformity 25 at 0.195. H6's 0.10 is not met at 75. Expected from slope = U′ · warp′, but the spec only names 0, 50 and 100.

### c. Things round 2 could have broken

None found:
- X4, X5, X6 and N1–N4 are unchanged or still passing.
- The sky L-lines and the V2/V3 sheets are byte-identical to R1.
- Twin parity holds (below).

## 4. GPU vs CPU

Engine vs `ExactColorStage.apply` on 4 rows × 720 hues, for these cases: narrow-ring Orange hue, max-ring Blue hue −100, asymmetric Green ring, U50 alternating, U100 all, the scaled pair. Max RGB diff ≤ 2.65e-6, max hue diff ≤ 0.0007°.

I reviewed the generated CIKernel string (`probe metal`) line by line against `ColorEngine.hueDisplacement` and `applyMixer`:

| item | finding |
|---|---|
| Arc packing | `v(cb, ca, fb, fa)` → `ar.x/y/z/w` |
| Below falloff | `1.35*(ar.x+ar.z) - ar.x` = reach·(cb+fb) − cb |
| Above falloff | uses (y, w), the mirror of the below side |
| Clamping | `clamp((|dl| - core)/fall, 0, 1)` |
| Hue transfer | `lumenHueTransfer` emitted with ramp 0.1, peak 1.1111111111111112, 0.2, 0.9, 0.05. The twin reads `ColorEngine.hueRampFraction` |
| Order | uniformity → `hc` → warp evaluated at `hc` → `wrap(hc + g*warp)` |
| Sat and Lum hue | still read the input h (same on CPU) |
| Recipe-wide scaling | done on CPU in `resolvedHueShifts`; the scaled shifts are what get packed (`hueShifts[i]`) |
| Division by zero | `fall` cannot be 0: feather ≥ 12° |

**No divergence.** gpu-parity run 39577077975 is green.

## 5. Break attempts, extra frames, breakdown of clipping

Frames: 6933 and 6929 (A7 IV), 2545 (GX85), 1569 (GX80). All 1200 px renders are in `brk/`.

| attempt | result |
|---|---|
| all ±100 / alt / opposing neighbours / sat −100 + lum +100 | finite; 0–0.04% newly code-0, except 1569 all+100 at 3.3% |
| U50 + Orange +100, U100 alt, U50 + Green −100 | clean |
| Green hue ±100 on 6933 | olive-yellow and cool green, clean (`crops/6933_strip.png`) |
| Blue −100 + Presence sat/vib +100 | 43–75% newly code-0. **Presence alone gives 43.0 / 73.9%**; the Mixer adds ≤ 0.7%. This belongs to the Presence lane |
| WB 2000 K + mixer | WB alone 56.6 / 79.5% code-0; the mixer adds 10–18% because the frame turns blue. Expected |
| old-wire explicit defaults | bit-identical |

## 6. CI (GitHub Actions, head 3dc4f910…)

| run | id | state |
|---|---|---|
| Proof sweep | 39577077860 | success |
| GPU parity | 39577077975 | success |
| UI snapshots | 39577077847 | success |
| CI | 39577077790 | **queued** at 10:06 UTC |
| UI layout | 39577077818 | **queued** at 10:06 UTC |

Previous lane sha: CI red, Proof red (ControlProof). Both of those failures are fixed locally and in Proof sweep.

## 7. UI

Snapshots: `/tmp/claude-0/vsnaps2/quality-k2-color-mixer/3dc4f91/`. Earlier sets: `.../30df1b6/` and the baseline `/tmp/claude-0/snaps/claude-inspiring-dirac-ulgpch/a93efb2/` (no longer on the branch tip).

index.md has no "could not find" message for any colour state. The remaining ones are Noise Reduction, Zones and the mask folds, which belong to other lanes.

Round-1 UI fixes confirmed:
- **Band range opens.** `panel-grade-colour-mixer-band-range.png` (md5 96b1a32e) is now distinct from point-colour/all-bands (6f104d59). It shows the ring, the ribbon, the caption, and "Every band".
- **H/S/L band labels are full strength** (`-mixer-hue.png`, `-saturation.png`). Readouts still dim at rest.
- **"EVERY BAND" label** replaces "ALL BANDS".
- **Swatches read as their names.** Red is crimson, Yellow is clean yellow (L 0.85), Green is bright, Magenta is orchid-magenta.
  - `swatch_hues.py` on point-colour: worst 0.2°.
  - Saturation tracks at x 470 / 560 / 605: worst 0.2 / 0.3 / 0.8°.
- **U8** pitch is still 64 px, and label x and pill width match.

**New defect (U5, design).** In the expanded ring, the selected band's two core handles touch:
- At arcRadius 60 pt, the core spans are: Yellow 7° (7.3 pt), Red 9.2° (9.6 pt), Purple 8.5°, Magenta 8.6°. The dots are about 6–7 pt across.
- The "bright arc" between them is therefore invisible, yet the caption says "Drag the ends of the bright arc…". Compare with the baseline's clear ±22° white arc: `crops/ring_base_vs_r2_2x.png`.
- Hit-testing picks the nearest handle, so it still works functionally, but the primary affordance is unreadable at the default for 4 of 8 bands.

**Minor:**
- The Hue tracks still end in the neighbour's colour while ±100 moves 28–33° (better than R1's 26°).
- The point-colour and all-bands states are identical (accepted under U4).

**Scope note:**
- `LumenControls.swift` gained `LumenSlider.labelAtFullStrength`. This is a shared-kit edit; it is additive and disclosed in NEEDS §8.
- `AppState` gained a second `@Published` (`mixerRangeExpanded`).

## 8. Fix list (ordered)

1. **Band range ring legibility.** When the core span is under roughly 20°, draw the core arc at a minimum visible length (or as a bright band on the ring itself), and offset or merge the two core handles so they do not overlap. Alternatively reword the caption. Re-snapshot `panel-grade-colour-mixer-band-range`.
2. **Wait for `ci.yml` and `ui-layout.yml` on the final sha.** Both must be green (T4, U9). If either fails, fetch the job logs.
3. **Write REPORT.md** (brief §3). Include:
   - verdict per line with the numbers above;
   - the R1–R8 rulings;
   - the RobustnessTests floor conflict;
   - the 25 re-recorded proof records;
   - the owner-judgement items: 1.35× hue reach beyond the ring, 1.8–5.6° neighbour-centre spill, Uniformity 75 slope 0.065, the MST 1/2/9/10 limitation, lawn speckle, the shared-kit edit.
4. Optional: report H1 display 0.105, X3 1.404 and X5 sat 0.100 as sitting at their thresholds.

## Best evidence images

- `/tmp/claude-0/vout2-3dc4f91/crops/sky983_base0_base-100_r2-100.png`: 983, base / base Blue −100 / R2 Blue −100.
- `/tmp/claude-0/vout2-3dc4f91/crops/hw_green_base_r1_r2_pm100.png`: Green hue ±100 on the hue wheel, base / R1 / R2.
- `/tmp/claude-0/vout2-3dc4f91/crops/ring_base_vs_r2_2x.png`: Band range ring, baseline vs R2. This is the remaining UI defect.

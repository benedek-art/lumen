> Round-2 verification of 9b39825 (FAIL on F1). Kept for the record; the final verdict is VERIFY.md.

# WS-08 verify: Zones register, 9b39825

Verifier: a fresh agent. It read LANE-BRIEF §1/§3b/§4, SPEC.md (with the round 2/2b amendments) and the WS-08 part of
`git diff c170432 9b39825`. BUILD-NOTES.md was read only after the per-line verdicts below were formed.
Scratch: `/tmp/claude-0/verify08` (branch/base binaries in `bin/`, probes in `probe/` and `probebase/`, which are
SwiftPM packages linking LumenCore from the branch and from a c170432 worktree).

## Overall: **FAIL**

Every numbered SPEC line that can be measured on Linux passes. The FAIL comes from the break-it pass. LANE-BRIEF §4
asks for a smooth, monotonic response across the whole slider range, and the spec's touched/untouched split breaks
that. When one zone is spilling, nudging an untouched neighbour off zero by 0.05 EV collapses the spill, so the
picture jumps by up to 2 EV. This behaviour is spec-conformant under Z1.8 round 2b, so the fix needs a lead decision
on the rule, not only a code change. See F1.

## Gates

| gate | result |
|---|---|
| `swift build --target LumenCore --target LumenRender` | clean |
| `swift build -c release --product lumen-render` (branch and base) | clean |
| `core-tests.sh` (full suite) | **3104 tests, 6 skipped, 0 failures** (base 3058/0 per lead). Working tree clean afterwards. |
| macOS: Proof sweep, UI layout, UI snapshots for 9b39825 | success (GitHub Actions runs 39580484926, 39580485113, 39580484930) |
| macOS: CI (39580484874) | success (completed 10:59 UTC) |
| macOS: GPU parity (39580485164) | queued since 09:53 UTC, **PENDING** |

## Per line

| line | verdict | measured |
|---|---|---|
| Z1.1 floor ≥ 0.25 | PASS | Test passes. My probe covered 30 lone cases, 32 adjacent opposite pairs, 11 specials, 20 extreme/min-gap pivot cases, 2 legacy 0.02-gap cases and 300 random (pivots with gap ≥ 1 EV, ev ∈ {−3, −1.7, 0, 0.6, 3}, global ∈ {0, 3, −2}). Worst min slope **0.250001**. |
| Z1.2 slope break ≤ 0.01 | PASS | Same set: worst \|y'(t⁺) − y'(t⁻)\| **2.6e-4**. |
| Z1.3 no overshoot | PASS | Worst overshoot **4.4e-16**. `testEachZoneMovesItsOwnPivotAndNoOther` passes with carried = 1 − L for the next pivot up. |
| Z1.4 small moves exact | PASS | Each zone alone at ±0.5: applied = ev, at-pivot = ev, other pivots 0. ±0.75 holds in the test. |
| Z1.5 small moves match old | PASS | Test passes (base and branch share one formula below L). |
| Z1.6 never dead | PASS | Each zone alone, −3…+3 in 0.05 steps: delivered at its own pivot = v with **max error 0.0**, every step exactly **0.05000**. |
| Z1.6b spill | PASS | Darks +3 at the pivots: **3.000 / 2.045 / 1.090 / 0.135 / 0**. Brights −3 mirrors it: 0 / −0.135 / −1.090 / −2.045 / −3.000. |
| Z1.7 readout | PASS | Darks +3 gives exactly three entries: "Shadows: +2.05 EV carried from Darks", "Midtones: +1.09 …", "Lights: +0.14 …". Darks +3 with Mid −3 gives "Applied +0.95 of +3.00 EV (conflicts with Midtones)" and "Applied −0.95 of −3.00 EV (conflicts with Darks)". Darks +0.75 gives an empty list. |
| Z1.8 locality / 2b cap | PASS (as written) | Darks +3 with Lights +0.5: 3.000 / 2.045 / 1.090 / **0.500**. Mid −3 with Brights +1: Brights **1.000**, Mid −3.000. `testTheConflictCapIsContinuousAndMonotone` passes. **But see F1:** the cap is continuous in the touched zone's own slider, not in the neighbour's slider across 0. |
| Z1.8b conflict | PASS | Darks +3 with Mid −3 applies +0.955 / 0 / −0.955. Min slope 0.2500. |
| Z1.9 clamp idle | PASS | `zoneFlattening()` was nil on every Zones-only case I ran, including the 300 random ones and the legacy 0.02 gap. |
| Z1.10 ramp, EV domain | PASS | `ramp_ev_kink.py`: minSlope ≥ **0.15** on all 9 recipes (floor 0.10). kinkFall ≤ **0.33** (limit 0.5; base up to 0.94). kinkRise ≤ base on 8 of 9 (Mid −3 1.16 vs 2.43; Lights −3 0.77 vs 1.81; Sh/Mid/Li 0.94 vs 4.39; the others equal). Brights −3 reads 0.06 against a base of 0.00. I accept that as noise because the applied set 0 / −0.135 / −1.09 / −2.045 / −3 is non-increasing, so du/dt ≤ 1 analytically and there is no rising seam. `ramp_check.py` display-code flatEV is 0.00 on 8 recipes and 0.24 on Mid −3 (recorded by the amendment as a display-toe effect). The base numbers reproduce the spec's "today" values (Darks +3 −0.12 / 0.94; Mid −3 −0.12 / 2.59; Sh/Mid/Li −0.11 / 4.86). |
| Z1.11 one definition | PASS (code); macOS PENDING | The WS-08 diff touches nothing in `Sources/LumenPipeline` (the PipelineRenderer change is WS-02's sampler code, with no tone or zone lines). The only `ToneEngine(tone:zones:)` that feeds rendering is `RenderPlan.swift:201`, and it bakes `toneGainLUT`. The GPU reads `plan.toneGainCubeBaked ?? plan.toneGainCube()` (RenderGraph.swift:897), which is built from that LUT. No GPU path evaluates `zonePanelStops`, `ZoneWeights` or the zone EVs. Mask engines use `Zones()`. `gpu-parity.yml` is still queued. |
| Z1.12 test rewrites | PASS | Each rewrite reaches the clamp through Contrast −100 + Darks +3, or asserts nil. The ToneTwinClamp assertions are kept. ProofRegistry passed under the proof sweep. Nit: `AppliedReadoutTests.testThePlacementFollowsTheAnchorsWhitesAndBlacksMove` now asserts the opposite of its name, and `ZoneFlatteningTests.testDarksAloneFlattensTheBandTheAuditMeasured` now asserts nil. Rename both. |
| Z2 data | PASS | `scene_percentiles.py` on 25 frames: p99.9 ≤ **+2.5 EV on 25/25**, at most **2.3 %** above +2 EV. On the branch, Brights ±1 at the default pivots on the 8 frames has a min-of-signs mean ΔE of **0.000–0.005**. |
| Z2.1 pivots unchanged | PASS | `defaultPivots` untouched. `AccuracyProbeTests.testTheDefaultZonePivotsSitAtTheirDocumentedEVs` passes. |
| Z3.1 fixed stops | PASS | With Mid +1, Darks +3, Mid −3 and Darks +3/Mid −3, each under Whites ±100 and Blacks ±100: max \|Δ zonePanelStops\| = **0.0**. `testWhitesAndBlacksDoNotMoveTheZones` passes. |
| Z4.1 1-stop gap | PASS | `minimumPivotGap = 1/14`. `movingPivot` is used by `ZonesPanel.movePivot`. Test passes. The snapshot strip shows the Shadows pivot at −2.75 EV, 1.25 EV from Darks. |
| Z4.2 decoded identity | PASS | Test passes. On the legacy 0.02-gap list, Darks +3 and Darks +3/Shadows −3 keep the floor (min slope 0.2500/0.2516), with no clamp. |
| Z5.1 identity | PASS | `cmp` of base vs branch default render is byte-identical on **grey_ramp, colorchecker, 6929, 2545, 4694, 1840**. A pivots-only edit (pivot 1 at 0.45) on 6929 is byte-identical to the default. |
| Z7.1 dead fields gone | PASS | `lumen-render keys \| grep -c 'zones.*\(sat\|falloff\|wheel\)'` gives **0** (base 24). |
| Z7.2 legacy JSON | PASS | A recipe with mid/dark carrying sat/wheel/falloff (plus bright sat 80) renders **byte-identical** to the same recipe without them, on 6929 and 4694. The test passes. |
| Z7.3 canonical / fingerprint | PASS | The probe on base and on branch prints identical output: `{"pipelineVersion":2}`, `xxh64:fd50cceee634dfb4`, and for Dark −1/Mid 0.4 `xxh64:af93655829ef2012`. `CanonicalJSONTests` passes. (`RawDenoiseRecipeTests.defaultFullTreeDigest` changes because the full default tree loses the three keys. This is expected.) |
| Z7.4 data-only tests | PASS | ResetSemantics, SavedLook and RecipeCodecTolerance drop the arguments. |
| Z8.1 snapshot cases | PASS | Both PNGs are in `ui-snapshots/quality-ws-02-08-pickers-zones/9b39825/`, with no failure note in `index.md`. UI layout passed. |
| V1 default panel | PASS (human to confirm) | Five labelled rows plus Global. Five distinct, grabbable white pivot bars with the crossfade bumps drawn. Nothing is clipped at 380 pt. |
| V2 darks3-pivot | PASS (human to confirm) | Darks reads 3.00, which is what it applies (under the round-2 rule it carries no caption). Shadows shows "+2.40 EV carried from Darks", which is correct for the 1.25 EV gap (L = 0.597). Midtones shows +1.09 and Lights +0.14. The moved Shadows bar is visible. |
| V3 R5 texture | PASS | My own 100 % crops (`photo/r5-cropA.png`, `photo/r5-cropB.png`): at Darks +3, potato skin and avocado texture survive. The base build posterises the avocado and the shadowed potato. I saw no halo at the potato/table or avocado/bowl edges. |

### Other break-it results (no spec line, all fine)

- **Hue (colorchecker, OKLab, 18 chromatic patches):** zone edits shift hue by a mean of 0.85–1.18° and at most 3.4°.
  Exposure ±1 alone shifts it by a mean of 1.21–1.41° and at most 4.24°, so this is the display rendering, not the
  register.
- **Halos at 100 %** (A7 IV 6929 Shadows +3 on the wall/gate/foliage; GX85 2545 Darks +3/Brights −3 and Mid −3 on the
  roof/sky and trunk; R5 4694 Darks +3): none visible. Detail survives better than base everywhere I looked.
- **Global combined** (Darks +3 with global −3, Brights −3 with global +3, Mid −3 with global +3): the floor holds and
  the response shifts flat.
- **Contrast/Blacks with zones:** Contrast −100 with any zone ≥ 1 EV, and **Blacks +100 with Darks +3 or Mid −3**
  (a band of −3.67…−1.98 EV at min slope −0.31), still reach the bake clamp. NEEDS.md hands this to WS-07 for
  Contrast and "the six sliders"; Blacks +100 is one instance of that. It is not WS-08's to fix.

## FAIL items

**F1. Touching a spilled-into neighbour collapses the spill (a discontinuity and a non-monotone slider).**
`Sources/LumenCore/Engine/ToneEngine.swift:778` (`let touched = requested.indices.filter { requested[$0] != 0 }`) and
the positive/negative passes at :805–823. A zone becomes "touched" at any non-zero value, and from that moment its
request is a hard target the spill may not exceed. Measured with the probe (pivot response of the swept zone, with the
fixed zone in brackets):

- Darks +3, Shadows slider at 0 gives Shadows **+2.045** (Darks +3.000).
  - At +0.05 it gives Shadows **+0.050** (Darks **+1.005**).
  - At −0.05 it gives Shadows −0.016 (Darks +0.939).
  - One 0.05 slider step moves the picture by **2.0 EV** at two pivots. The Shadows slider runs +2.045 → +0.05 → +2.05
    over 0 … +2.05, so moving it UP first darkens the shadows by 2 EV.
- The same 2.06 EV jump occurs for every zone adjacent to a ±3 zone on its spill side (S|D+3, M|S+3, L|M+3, B|L+3,
  D|S−3, S|M−3, M|L−3, L|B−3).
  - Two zones away the jump is 1.12 EV (e.g. Darks +3 and Midtones 0 → 0.05 moves Darks 3.00 → 1.96).
  - Three away it is 0.18 EV.
- Rendered on R5 4694 at 100 % (`/tmp/claude-0/verify08/photo/r5-cropA.png`, 4th panel): Darks +3 with Shadows
  +0.05 looks almost like Darks +1, next to Darks +3 alone.
- The panel makes the trap worse. Its snapshot shows Shadows at 0.00 with "+2.40 EV carried from Darks" under it,
  and the natural next move is to nudge that slider.

What is expected: per LANE-BRIEF §4, every slider is monotone and continuous with respect to the rendered picture,
across 0 as well. Two ways to get there; the lead has to choose, since Z1.8 2b defines the current behaviour:

- (a) Let each zone take the value nearest its OWN request inside the spill bounds, the way an untouched zone takes
  the value nearest 0. A touched zone downhill of a spill is then raised to the bound and captioned "Applied +2.05
  of +0.05 EV (carried from Darks)". This is continuous at 0 and monotone, but leaves that slider inert until it
  passes the bound.
- (b) Make a touched zone's request additive on top of its carried amount.

A test for this should sweep each neighbour of a ±3 zone across 0 in 0.01 steps and require no step > 0.01 at any
pivot.

**F2. One evidence file is over the 400 KB rule (LANE-BRIEF §3).** `docs/quality/lanes/WS-08/evidence/r5-darks-after-crop100.png`
is 419,877 B. Expected < 400 KB.

## For a human to judge

1. **The spill changes what a zone slider means.** Shadows +3 lifts Midtones +2.05 and Lights +1.09. On the A7 IV
   6929 frame the wall goes near white (`photo/a7-s3-small.png`). Mid −3 takes Shadows to −2.05 and Darks to −1.09,
   so the GX85 frame goes almost black (`photo/gx-crop2.png`). In Lightroom terms, the top of each slider now behaves
   like a broad exposure move. This is the lead's decision (round 2). It deserves a look on real frames.
2. **Opposite neighbours cap hard.** Any adjacent "+a then −a" pair with a ≥ 0.5 delivers only **±0.477 EV**
   (D+3/S−3, D+0.5/S−0.5 alike). Darks +3 with Brights −3 delivers ±1.91. This is correct under the rule and is
   reported in the captions, but it is a strong limit for a "split-tone the exposure" move.
3. **Panel captions.** "+2.40 EV carried from Darks" sits midway between the Shadows and Midtones rows (about 48 pt
   below Shadows and 50 pt above Midtones), so a reader can attach it to the wrong row. A smaller gap above the
   caption, or putting the caption on the value field, would fix that. The value fields read "3.00" and "0.00" with
   no sign and no "EV", while the captions are signed and in EV. The snapshot card header says "Tone", not "Zones".
   The strip's level shading barely shows Darks +3. These are not FAIL by spec. No control that does nothing is
   shown: wheel/sat/falloff are gone, and Global works.
4. **Snapshot baseline.** `claude-inspiring-dirac-ulgpch/a93efb2/` is not on the `ui-snapshots` branch (only c8e5f46,
   4d7098e and 6f9d032 are, and none is an ancestor of c170432). I compared against this lane's own pre-WS-08 sets
   (f3a869e, 61b7afd) instead. Against those, `panel-develop-tone`, `panel-develop-tone-zones-open`,
   `column-develop-tone-open` and `column-develop-all-open` are pixel-identical. The window shots differ only in the
   shoot-id label and the histogram.
5. **macOS GPU parity for 9b39825 is still queued** (CI passed; see Gates). Z1.11's macOS half is PENDING until they go
   green.

# WS-31 Colour Mixer, verifier round 1 (sha 30df1b6)

**Verdict: FAIL.**

The engine work is a large improvement over the baseline (9068ded). Folds are gone, sky luminance is sane, the sat roll-off works, membership is honest, and the GPU twin matches the CPU line by line. The lane still fails on four counts:

- CI is red on the lane's sha (ControlProofTests).
- The Hue move ignores the Band range ring.
- Uniformity combined with a Hue edit still folds the hue circle.
- One required UI state was never captured.

The remaining SPEC FAILs (H2, H3, K2, K4, K5) were checked independently. They trace mainly to the display transform and to spec conflicts, as the builder says, and they need a spec-owner decision.

Setup:
- Fresh worktree `/tmp/claude-0/verify`.
- Release binaries: new `/tmp/claude-0/vbin/new`, base `/tmp/claude-0/vbin/base`.
- Tool outputs: `/tmp/claude-0/vout-30df1b6/`.
- Break renders: `/tmp/claude-0/vout-30df1b6/brk/`.
- Stage probe (scratch SwiftPM package against LumenCore): `/tmp/claude-0/probe`.

## 1. Gates

| gate | result |
|---|---|
| `swift build --target LumenCore --target LumenRender` | clean. No warnings in the changed files; the warnings that remain were there before |
| `swift build -c release --product lumen-render` | OK |
| `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` | 3066 tests, exit 0, 0 failures |
| `swiftc -parse` | 0 errors |
| `check-swift-surface.py` against surface-base.log | no new failures, only line-number shifts |
| GitHub Actions on 30df1b6 | GPU parity **green**; UI layout **green**; UI snapshots **green**; **CI red**; **Proof sweep red**. Both red runs fail on `ControlProofTests`: `mixer.blue.hue` authority is 13.0 against a floor of 17.0, and the committed proof records are stale (every mixer control moved) |

The SPEC's Linux suite command skips ControlProofTests, so the builder never saw this failure.

## 2. SPEC lines (measured fresh, CENT=17.2,60.925,102.25,143.225,203.7,253.25,295.75,336.3)

| line | measured | verdict |
|---|---|---|
| G0 | `MixerBandGeometryTests` green; gaps 40.55–60.5° | PASS |
| G1 | min 0.892 (sRGB red) | PASS |
| G2 / G2b | 0.659 / 0.417 | PASS / PASS |
| G3 | 1.000 | PASS |
| G4 | Green 0.637, G+Y 0.912 | PASS |
| G5 | 0.039 | PASS |
| G6 | geometry tests green | PASS |
| H1 | 0.121 | PASS |
| H2 | 3.908 | **FAIL** (cause: display; see §3) |
| H3 | 21.6–32.5° (stage 25.85–30.0°) | **FAIL** (cause: display, plus the 0.6375·gap cap) |
| H3b, H4 | all pass | PASS |
| H5 | 1.05% / 0.0012 | PASS |
| H6 | `MixerHueMonotoneTests` green. My probe: stage slope min 0.250, max 1.750; shift 25.85–30.0° | PASS |
| L1 | −1.10 / −1.45 / −1.20 EV | PASS |
| L2 | +1.17 / +1.12 / +0.88 EV | PASS |
| L3 | 0% | PASS |
| L4 | 1.16 / 1.26 / 1.01 | PASS |
| L5 | 0.264 (≤ 0.342) | PASS |
| L6 | monotone | PASS |
| L7 | 1.07 / 0.77 / 0.73 | PASS |
| K1 | monotone | PASS |
| K2 | 14.0° (MST 8, sat) | **FAIL** (cause: display; see §3) |
| K3 | 0.413 | PASS |
| K4 | 0.000 (MST 1, 2, 9, 10 do not move) | **FAIL** (conflicts with N4) |
| K5 | 3.94 | **FAIL** |
| N1 / N2 / N3 / N4 | 1 / 0.00 / 1.30 / 0.0253 | PASS (N3 and N4 sit exactly at baseline) |
| X1 | finite | PASS |
| X2 | 3.18% | PASS |
| X3 | 1.404 (threshold 1.4, no margin) | PASS |
| X4 | 0 codes | PASS |
| X5 | 0.065 / 0.100 / 0.095 | PASS (sat sits exactly on 0.100) |
| X6 | 0 | PASS |
| T1 | twin tests green; code review clean (§5) | PASS |
| T2 | 3066 tests, 0 failures. **No REPORT.md** in the lane folder; the reasons are only in BUILD-NOTES.md | PASS on the number, **FAIL** on the deliverable |
| T3 | suites green, but `RobustnessTests` floor loosened 0.2→0.1 (forced by L1, disclosed in BUILD-NOTES, but T3 says no tolerance loosened) | **FAIL** as written; spec conflict |
| T4 | gpu-parity green; ci.yml **red** | **FAIL** |
| T5 | NEEDS E-1 present. Explicit `core [22.5,22.5]` / `feather [15,15]` renders bit-identical to no keys (hue_wheel, 6933, 2545) | PASS |
| V1 | Green sector rotates cleanly; foliage goes yellow-green or cooler, with no orange or teal blotches. See notes below | PASS |
| V2 | −100 sky deeper slate blue; grain clean. A faint pale outline remains at 6× (`crop_1840_edge_6x.png`), about 4× weaker than base | PASS (marginal) |
| V3 | Orange sat sectors have soft sides. **Blue lum ±100 still shows a radial apex near the wheel centre** (`crop_hw_b5_lum.png` against `crop_audit_hw_b5_lum.png`; softer than before). MST row does not move evenly: MST 1, 2, 9, 10 are static | **FAIL** |
| U1 | one row; icon eyedropper; `Hue | Saturation | Luminance | Band`; "Pick a colour" gone | PASS |
| U2 | 8 rows in order; tracks coloured as specified | PASS |
| U3 | round swatches; 2 px white ring clear; 10 px edited dot on Yellow; YELLOW label; 3 sliders | PASS |
| U4 | group mode removed; no dimmed swatches; all-bands state shows Band view | PASS |
| U5 | Band view about 142 px (≤ 160); H/S/L about 20 px (≤ 60). **The expanded state was never captured**: `panel-grade-colour-mixer-band-range.png` is byte-identical to `-point-colour.png` and `-all-bands.png` because `press: ["Band range"]` did not open the fold. The ring, ribbon and caption in the new layout cannot be judged | **FAIL** |
| U6 | grep returns 1 hit, Point Colour's "feathers into" (another lane's string, NEEDS UI-2). No degree caption | FAIL as written (out of lane) |
| U7 | swatches worst 0.3°; Saturation-track midpoint worst 0.2–0.4° | PASS |
| U8 | pitch 64 px, the same as Point Colour; label x and pill width match | PASS |
| U9 | ui-layout and ui-snapshots green; ColorPanelTests ran in the red CI job without failing (only ControlProof failed) | PASS |
| E1 | `DominantBandTests` green; row highlight on pick from code | PASS |
| E2 | NEEDS UI-5 contract present | PASS (conditional) |

V1 notes:
- At −100 a soft gate ring is visible at C ≈ 0.03 (`crop_hw_green.png`).
- The radial green ridge is the display's own and is present at 0.
- Before: `audit/crops/hw_b3hue_crops.png`. 1569 shows foliage shifting cleanly at thumbnail size.

## 3. H2, H3 and K2: is it the display or the engine?

**H2 / H3.** I measured the scene-hue warp in the stage with a probe that links LumenCore and runs `ColorEngine.apply`:

- Slope runs 0.25–1.75 over every band at ±100 and every row.
- Centre shift is 25.85–30.0°.

On the untouched base render, d(display hue)/d(scene hue) runs 0.54–1.51 on the C 0.06 rows (0.41–2.1 at C 0.03). The 3.91 maximum occurs on Blue −100 at scene hue 265°, where the display gain is 0.58; the stage slope there is ≤ 1.75, which is consistent with 1.75 × 1.3 / 0.58. **The builder's claim holds.**

My judgement on the spec: the display-level H2 and H3 thresholds are partly flawed, because they ask a scene-referred stage to cancel a display hue gain with a range of about 2.8×. They are not impossible, though. The engine uses the maximum fraction its own design allows (0.6375·gap, min slope 0.25), and Purple and Magenta sit at 25.85° in the stage, right at H3's floor. The engine could compensate per band (as it already does for Luminance stops) or relax the 0.25 floor. A spec-owner decision is needed.

**K2.** The stage holds hue exactly: L and C scale with h untouched. On the base binary with no Mixer at all:
- Presence Saturation −60 moves MST 8's displayed hue by −14.0°.
- Exposure −1 moves MST 6 by −10° and MST 9 by −6.6°; Exposure +1 moves MST 9 by −23°.

This is the same size as the new Mixer's 14.0°. **The builder's claim holds**: K2's ≤ 3° at display cannot be met by a hue-preserving stage, and the spec line is flawed. Measure it at the stage, or relative to Presence Saturation.

**K4 against N4.** I confirmed this independently. MST 10 has L 0.18. The ratio kernel needs about full gate at C 0.006 to move it ΔL 0.015. N4 caps all-band moves on C 0.01–0.02 hue-wheel pixels at ΔOK 0.03, and with a gate monotone in C that rules out the full gate at C 0.006. The conflict is real for this kernel family.

**K5** (3.94) comes from MST 3/4's Orange share (0.42) together with the mixer gate (MST 3 at C ≈ 0.026 gets a gate of about 0.13). This is an engine/spec trade-off. It is not caused by the display.

## 4. Break attempts

Photos used:
- 6933 (A7 IV, not used by the tools)
- 4144 (A7C, not used by the tools)
- 2348 (G9, not used by the tools)
- 7301 (X100VI, not used by the tools)
- 2545 (GX85)

All renders are at 1200 px in `brk/`. Stage probes are in `/tmp/claude-0/probe`.

| attempt | result |
|---|---|
| all 24 at +100, at −100, alternating | finite, no new clipping on any photo, stage slope 0.93–1.08. Alternating gives an expected posterised yellow/grey foliage split (`c_6933.png`) |
| opposite neighbours ±100 hue | stage slope min 0.250, max 1.75; no fold (the `resolvedHueShifts` scaling works) |
| sat −100 then lum +100 | clean grey; no hue noise in the low-chroma areas I checked |
| **Uniformity together with Hue** | **FOLDS.** Uniformity 50 with Orange hue +100 gives stage slope **−0.25**; Uniformity 50 with Blue −100 gives −0.13; Uniformity 100 with alternating hue gives −0.75. Cause: `h + hueMove + converge` adds two displacements computed from the same input hue instead of composing them, so the slopes add (1 + w′ + c′) rather than multiplying. Uniformity alone is ≥ 0 |
| **Ring handles against Hue** | **The ring has no effect on the Hue slider.** Orange hue +100 with ring at min (wire 0), default, or max (wire 1000): identical hue displacement at every hue (`probe arcs`). Sat and Lum do follow the ring (sat −100 at 40° gives C 0.0387 default against 0.0602 narrow). The Band range caption promises "change which hues Orange takes in". The pre-WS-31 hue move followed the arcs, so this is a regression |
| ring min/max on Orange lum | smooth, no crease; the sanitizer widens the feathers as designed |
| Presence sat/vib +100 with Blue −100 | clipping comes from Presence (6933: 43% with Presence alone); the Mixer adds about 0 |
| WB 2000 K / 50000 K with mixer edits | finite. Under 2000 K the frame turns blue, so Blue −100 darkens most of it (6933: 74% code-0 against 57% from WB alone). Expected |
| B&W on with mixer edits | B&W stays on the legacy grid as designed; renders clean |
| Orange lum −100 on 2545 dry lawn | lawn texture contrast ×1.46, against ×1.19 for an equal exposure drop and ×2.37 on base. Pale low-chroma blades stay bright, giving a mild salt speckle (`c4_2545.png`). L4 covers skies only; this is the gate ramp 0.022–0.04 acting on low-chroma subjects |
| old recipe with explicit default core/feather | bit-identical |
| non-finite / huge / negative inputs, absurd arcs (1e6) | finite everywhere |

## 5. GPU vs CPU review (ExactColorTwin.mixer, ExactColorKernelSource.mixer, ExactColorStage.init)

**Packing order.** `conversion(0–8) + mixer centres(9–10) + arcs(11–18) + moves(19–24, per band hue°, sat, lumStops) + targets(25–26) + q(q, ref 0.5, exp 0.9, cap 1.0)` matches `e(u,36+i)`, `u[11+i]`, `e(u,76+3i…)`, `e(u,100+i)`, `q.x/y/z/w` and the Metal `u()` map. The B&W finish pass packs `uniformBandHueCentres` with hard-coded 22.5/15 arcs, which is consistent with `uniformBandWeights`.

**Matching formulas and constants:**
- Gate: smoothstep(0.022, 0.04).
- Pull ungated, push gated.
- `mixerSatGain` guards in the same order; NaN behaviour matches through `!(x > 0)`.
- Fourier series with the same coefficients.
- `hueTransfer` constants: Float rounding of 0.85 differs by 3e-8, and the function is continuous at that point.
- Warp spans use `wrapHue(next − ck)`, which equals `bandGapAbove`.
- Lightness kernel guards `L > 0 && stops != 0`.
- Final h = wrap(h + g·warp + converge).

No divergence found. The twin's `mixerReference` allocates an array per pixel (`.map { Float($0) }`), which costs CPU-twin speed only.

**CI.** gpu-parity.yml run 39544141590 on 30df1b6 is **green**.

## 6. UI (snapshots `origin/ui-snapshots:quality-k2-color-mixer/30df1b6/`, baseline `claude-inspiring-dirac-ulgpch/a93efb2/`)

Compared with the baseline, the panel is much calmer:
- The ring, ribbon and OKLCh caption are folded away.
- The swatches are round, evenly spread, and carry a legible selection ring and edited dot.
- The band name is a caps label.
- The rows sit on the house 64 px pitch, and label x and readout pills match Point Colour.

The owner's "bands look odd" complaint is largely answered. As a demanding product designer, I still see these issues:

1. **The Band range expanded state is unverified.** The snapshot did not open the fold (U5 FAIL). Nobody has seen the ring and ribbon in the new layout.
2. **In H/S/L views, 7 of 8 labels are dimmed** (the zero-value treatment). The block reads as disabled, and in Hue view the only bright label is the edited one. Consider not dimming band labels in these views; Lightroom never dims them.
3. **The "ALL BANDS" caps label over "Even out hues" reuses the name of the mode that was just removed.** Something like "Every band" or "Across bands" would avoid the echo.
4. **Swatch colours are the honest OKLCh centres, but some do not read as their names:**
   - Red (17°) reads coral/crimson.
   - Yellow (L 0.77, C 0.145) reads mustard/olive next to brighter neighbours.
   - Magenta reads pink.

   They are accurate (U7 0.3°) but less legible as names. A higher-lightness yellow would help.
5. **Hue tracks end in the neighbour's colour, but ±100 only reaches about 26°**, roughly 60% of the gap. The track overstates the move (documented by the builder).
6. **No snapshot shows a pick-highlighted row (E1).** The grey surface on the first row is the existing focus treatment and appears in the baseline too.

## 7. Fix list (by severity)

1. **CI red.** `ControlProofTests.testEveryRegisteredControlHasVisibleAuthority`: `mixer.blue.hue` authority is 13.0, below the floor of 17. Purple sits at 19.9. Raise Blue and Purple hue authority (they are capped by the 0.6375·gap rule and further compressed by the display near 260–300°). Then re-record the proof records with a commit message that names the change as a fix. Run ControlProofTests locally; the SPEC command skips them.
2. **The Hue slider ignores the Band range ring.** Make the hue warp respect each band's arcs (for example, knot extent from coreCentre and feather reach), or remove and relabel the ring's promise for Hue. Add a test that a narrowed ring narrows the Hue move.
3. **Uniformity combined with Hue folds the hue circle** (stage slope down to −0.75). Compose the two instead of adding them: apply converge on the warped hue, or warp the converged hue. Extend `MixerHueMonotoneTests` to cover Uniformity 0/50/100 × single-band ±100.
4. **U5: the Band range snapshot does not open the fold.** Fix the `press:` target (or set the state) and re-judge the expanded ring, ribbon and caption.
5. **Missing REPORT.md** (brief §3, T2). The T3 "PASS" hides the loosened RobustnessTests floor; mark it as a spec conflict.
6. **Spec owner decisions** (do not loosen quietly):
   - H2, H3 and K2 thresholds are display-level and largely display-bound; my evidence is in §3.
   - K4 conflicts with N4.
   - K5 needs a decision too.
   - Consider per-band hue magnitude compensation so H3 reaches 25° on the display.
7. **Design and polish:**
   - Undim band labels in the H/S/L views.
   - Rename the "ALL BANDS" group label.
   - Brighten the Yellow swatch.
   - Lawn speckle under Orange lum (gate ramp on low-chroma subjects).
   - The V3 radial apex on Blue lum.

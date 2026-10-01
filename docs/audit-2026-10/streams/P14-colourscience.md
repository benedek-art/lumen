# P14-colourscience: the September colour-science group, and three Astra colour rows

Stream agent P14-colourscience. Base: `claude/jolly-sagan-k7ch7z` at `0896556`. Worktree branch
`worktree-agent-a8330061c8b71a04a`. Build dir `/tmp/lumen-build-p14`, Linux. Inputs:
`docs/audit-2026-09/w2/B1.md` B1-04…B1-08, and `docs/audits/2026-09-22-astra/findings.json` AI-07,
AI-08 and AI-10.

Every number below was measured on this Linux box against the shipped f64 engine (`ColorEngine`,
`ToneEngine`, `ReferenceRenderer`). None was re-derived by hand. Stream P5 is rebuilding how S9 is
evaluated at the same time, so this stream touched only the maths inside `ColorEngine` and
`ToneEngine` functions. It touched no table, cube, graph or GPU-kernel code.

## Items

| Item | Status | Commit | Red / green | Proof records that move |
|---|---|---|---|---|
| B1-05 Density hue rotation | **FIXED** (the part that was still open) | `7f03f8c` | `HuePreservationTests.testDensityHoldsHueAcrossItsWholeTravelOnTheTonalWedge`: 20 red with the old weight (0.58° … 12.95°), green with the fix | `color.density` meanSeparation 7.052192491191278 → 7.054667578635864. `color.saturation` meanSeparation 30.36553485843083 → 30.365273627740102. No other field and no other record |
| AI-07 zone flattening | **PARTIAL**: the engine now measures the flattening. The panel does not show it yet (DECISION 3) | `9f1fbd9` | `ZoneFlatteningTests`: 2 red with `zoneFlattening` forced to nil, 4/4 green | none: `bakeGainLUT` output is bit-identical |
| B1-06 H-K magnitude | **NOT-FIXED**: re-measured. The comment at the constant now states the magnitude. DECISION 4 | `b0cdd0d` (comment only) | – | none |
| B1-04 band ring authority | **NOT-FIXED**: re-measured. Patch under DECISION 1 | – | – | none (the patch is identity at default arcs) |
| B1-07 B&W level normalisation | **NOT-FIXED**: re-measured. DECISION 2 | – | – | the patch would move all eight `bw.*` |
| B1-08 / AI-10 band naming | **NOT-FIXED**: re-measured after `000d345`. Membership is unchanged. DECISION 5 | – | – | a re-anchor moves every `mixer.*` and `bw.*` |
| AI-08 Uniformity / Point Variance local mean | **NOT-FIXED**: re-measured. Needs a spatial input to S9, which is P5's graph. DECISION 6 | – | – | – |

I merged `origin/claude/jolly-sagan-k7ch7z` at `064525e` (merge commit `15c06a9`). It merged cleanly.
Nothing it brought touches `ColorEngine`, `ToneEngine`, `Perceptual` or the colour records, and P5's
S9 work was not on the branch yet. After the merge:
- `swift build --build-tests` is clean.
- 109 tests passed with 0 failures, across HuePreservation, ZoneFlattening, ColorScience, ProofSmoke,
  BlackAndWhiteMix, DominantBand and MixerBandName.
- `check-swift-surface.py` exits 0.

## B1-05: Density's hue rotation (`7f03f8c`)

**What was still open.** The 3 September fix (`d3f9524`) restores hue after the additive/subtractive
blend. It weighted the restore by `chromaGate`, which only opens fully at OKLab C 0.06. Above 0.06
the rotation measures 0.000000° at every setting, so that part held.

The band 0.02–0.06 is not near-neutral, though. OKLab chroma falls with the cube root of exposure, so
every coloured surface a few stops under mid-grey sits there. On `tonalColourWedge`, the worst
rotation over pixels at C > 0.02 (the proof metric's own hue floor) was:

| | Density 50 (shipped default) | Density 100 |
|---|---|---|
| Saturation +50 | 3.05° | 6.52° |
| Saturation +100 | 6.03° | **12.94°** |

`colourChart` barely shows this (0.24° worst at +100/50) because it has few dark chromatic patches.
That is why the existing grid tests stayed green.

**Fix.** The restore weight is now `smoothstep(0, gateLoChroma, C)`. It restores hue fully from 0.02
up and eases to nothing at the neutral axis. The same wedge now measures 0.0000° at every setting.
Saturation ≤ 0 and Density 0 never reach this code, so an untouched recipe is unchanged.
`testTheColourTableConverges` and the 65-cube 0.085 EV bound still pass (Robustness 40/40).

**Red/green.** `testDensityHoldsHueAcrossItsWholeTravelOnTheTonalWedge` sweeps Density 0…100 in steps
of 10, at Saturation +50 and +100. With the old weight it fails 20 times (0.58° … 12.95°). With the
fix it is green.

**Proof records.** The changed line runs only for specs with Saturation > 0 and Density > 0, and the
registry has two such specs. One field moves in each:

- `color.density` meanSeparation 7.052192491191278 → 7.054667578635864
- `color.saturation` meanSeparation 30.36553485843083 → 30.365273627740102

Authority, hueRotation, deadSteps, frontLoading and every other field are unchanged to the last
digit.

How they were re-pinned:
1. `ControlProbeHarness` runs `ProofRunner.measure`, the same sweep the drift test uses. On the
   unfixed tree it reproduced both committed records exactly (`agrees: true`), so this Linux box
   computes the same records as the lane.
2. I measured both records with the fix, edited only the two changed numbers, and probed again. Both
   returned `agrees: true`.

I did not run the full `ControlProofTests` sweep of all 144 records: it takes about 80 minutes, and
this box was at load 33. The claim that nothing else moves rests on reachability: the changed
statement runs only when `satAmount > 0 && density > 0`, only those two registry specs write
Saturation or Density, and the local adjustments at `Recipe.swift:401` have no record. The lane will
confirm it.

Note for P5: if the exact S9 kernel ports `applyVibranceSaturation`, it needs this one-line change to
the restore weight.

**Not changed:** `color.density`'s record `hueRotation` of 3.59°. That metric is measured after the
full render. On the same chart, the engine-only rotation between Density 0 and 50 was 0.15° before
the fix and 3e-13 after. The rendered figure is 3.5877 in both cases, so those 3.59° come from the
stages after S9, not from Density. See FOUND-WHILE-FIXING 1.

## AI-07: zone exposure flattening (`9f1fbd9`)

Re-measured on the 1024-sample bake at the default pivots, other zones at 0:

| Darks | samples clamped | input that renders flat | worst deviation from request |
|---|---|---|---|
| +2 EV | 75 / 1024 | −3.531 … −1.795 EV (1.74 EV) | 0.421 EV |
| +3 EV | 121 / 1024 | −3.695 … −0.880 EV (2.82 EV) | 1.274 EV |
| +4 EV | 165 / 1024 | −3.765 … +0.082 EV (3.85 EV) | 2.204 EV |

This is still a defect, and the +4 EV worst case matches Astra's 2.204 EV exactly.

`bakeGainLUT`'s own comment says the panel is unlimited on purpose ("the explicit power tool").
Replacing the clamp with a limiter would change what the panel promises, so that choice is the
owner's (DECISION 3). What landed is the measurement the panel needs to warn about it:
- `ToneEngine.zoneFlattening()` returns the flattened band's two ends, the worst deviation and the
  share of the bake. It returns nil when nothing was flattened.
- It shares one `clampedResponse` function with `bakeGainLUT`, so the two cannot drift apart.
- The bake runs the same operations in the same order, so its output is bit-identical. No pixel and
  no record moves.

`ZoneFlatteningTests` has 4 tests:
- Darks alone flattens the band the audit measured.
- The reported band is flat in the baked table.
- An untouched tone stack reports nil.
- None of the 243 corners of the five zonal tone sliders at −100/0/+100 reaches the clamp.

Forcing the function to return nil turns 2 of them red. With the real function, 4/4 are green.

## B1-06: H-K term magnitude (`b0cdd0d`, comment only)

Re-measured `brightnessFactor`:

| colour | this engine | audit's published VAC value |
|---|---|---|
| blue sky | 1.00506 | 1.090 |
| red, C 0.20 | 1.00787 | 1.439 |
| sRGB blue | 1.01479 | 1.272 |
| all hues at C 0.40 | 1.0110…1.0195 | – |

Nothing has changed since September. The comment at the constant now states these numbers. Running
the model at its published strength is DECISION 4.

## B1-04: band ring authority (not fixed)

Re-measured: the weight each band has at its own centre, `bandWeights(hue: centre[i], arcs:)[i]`.

| geometry | own-centre weights |
|---|---|
| default | 1.0000 × 8 |
| Red core 44° both sides | Orange **0.5027**, Magenta **0.5027**, the rest 1 |
| Red feather 60° both sides | Orange 0.5912, Magenta 0.5912 |
| all cores 30° | 1.0000 × 8 |
| all cores 31° | 0.9786 × 8 |
| all cores 44° | **0.3358** × 8 |

Orange Saturation +100, measured at Orange's centre, gives a chroma gain of 2.000 with the default
arcs and 1.503 with Red widened. The defect is unchanged.

Not landed, for two reasons:
- It changes what a widened handle means, which is a contract decision.
- `Sources/LumenPipeline/ExactMixerGPU.swift`'s `membership()` mirrors `bandWeights`.
  `ExactMixerGPUTests` drives cores of 44° and feathers of 60° and compares the result to
  `ColorEngine.apply`, so a CPU-only change would turn that macOS test red. That kernel is P5's
  ground.

DECISION 1 carries the patch.

## B1-07: B&W mix level (not fixed)

Re-measured at the stage only, as the displayed grey code:

| patch | all bands 0 | +50 | +100 | −100 |
|---|---|---|---|---|
| blue sky | 163 | 195 | 222 | 0 |
| neutral grey | 127 | 127 | 127 | 127 |
| pale skin | 177 | 212 | 241 | 0 |

These differ from the audit's numbers because the patch values differ and this is the stage alone,
without the display transform. The finding is the same: moving all bands together brightens colour
and leaves greys exactly where they were. DECISION 2.

## B1-08 / AI-10: band naming after `000d345` (not fixed)

`000d345` renamed Green to Mint and Blue to Azure. Membership is unchanged (canonical arcs):

| colour | OKLCh h | top band | second |
|---|---|---|---|
| sRGB green | 142.50° | Mint 0.502 | Yellow 0.498 |
| foliage (0.15, 0.35, 0.08) | 138.91° | **Yellow 0.522** | Mint 0.478 |
| sRGB orange | 52.78° | Orange 0.503 | Red 0.497 |
| skin (0.85, 0.65, 0.55) | 47.78° | **Red 0.544** | Orange 0.456 |
| sRGB cyan | 194.77° | Aqua 0.693 | Mint 0.307 |
| sRGB magenta | 328.36° | Magenta 0.629 | Purple 0.371 |
| sRGB yellow | 109.77° | Yellow 0.960 | Orange 0.040 |
| sRGB blue | 264.05° | Azure 0.945 | Purple 0.055 |

After the rename, no band is labelled "Green" without owning green. The split itself is unchanged:
- pure green and orange are still almost exact 50/50 splits;
- foliage still leans Yellow;
- a typical skin tone leans Red.

DECISION 5.

## AI-08: Uniformity / Point Variance local mean (not fixed)

Re-measured with Point Variance −100 on a swatch at 29.23°, inputs at 24.23°, 29.23° and 34.23°:
- `apply(pixel)` returns **29.23°, 29.23°, 29.23°**.
- `apply(pixel, localMean: swatch)` returns 24.23°, 29.23°, 34.23°.

Mixer Uniformity 100 behaves the same way: all three inputs come out at 29.23°. The shipping path
works per pixel, so ±5° of hue texture collapses to one hue. The fix needs a spatial local mean fed
into S9, which is graph and kernel plumbing in P5's area. DECISION 6.

## DECISIONS

1. **B1-04: cap each band's reach at its neighbour's centre.**
   - It is identity at the default geometry, so no record moves. The default reach is core 22.5° +
     feather 15° = 37.5°, which is exactly where the cap's ramp starts, and every raw membership is
     already 0 there.
   - With the cap, a band always weighs 1 at its own centre.
   - The cost: a feather dragged past about 22.5°, or a core past 37.5°, has no effect beyond the
     neighbour's centre. The ring would need to draw the capped extent.

   The patch goes in `bandWeights(hue:arcs:)` after `v` is computed, and the same line goes in
   `ExactMixerGPU.membership`:
   ```swift
   let ramp = bandSpacingDegrees - (bandCoreDegrees + bandFeatherDegrees)  // 7.5°
   let past = abs(d) - (bandSpacingDegrees - ramp)                          // from 37.5°
   if past > 0 { v *= featherFalloff(past, extent: ramp) }                  // 0 at 45°
   ```
   Its test: `bandWeights(hue: centre[i], arcs:)[i] >= 0.99` for every band over a grid of legal
   cores and feathers. Today it fails at 0.3358.

   The alternative is the audit's option (a): draw the normalised weights on the ring and leave the
   engine alone.
2. **B1-07: normalise the B&W mix level.**
   - The patch: `gain = 1 + Σ wᵢ·gate·(bandᵢ − b̄)/100·κ`, where b̄ is the mean of the eight bands. A
     uniform move becomes a no-op, which is what the audit asks for.
   - The cost: a single band at +100 then acts as +87.5 on its own hue and −12.5 on every other hue.
     All eight `bw.*` records move, and every saved B&W look renders differently.

   This is a look change, so it is not implemented. Optionally, add a separate "overall" control if
   a uniform brighten is still wanted.
3. **AI-07: warn about the flattening, or limit it.** Two options:
   - (a) `ZonesPanel` reads `ToneEngine.zoneFlattening()` and, whenever it is non-nil, shows
     "flattening −3.8…+0.1 EV" or tints the zone curve. This is UI only and moves no pixel.
   - (b) A solved limiter like `solveZonalLimits`. This moves the `zones.*.ev` records and breaks
     the panel's "power tool" contract.

   I recommend (a).
4. **B1-06: how strong the H-K term should be.** Either keep the current 40× damping, now
   documented, or derive `S` from the pixel's actual CIE 1960 saturation (S_uv). The second moves
   every saturation, vibrance, mixer-saturation and colour-balance record, and changes every edit
   that uses those sliders.
5. **B1-08 / AI-10: band naming.** Either re-anchor the band centres on measured colour-name
   centroids, with a `pipelineVersion` bump and a migration (every `mixer.*` and `bw.*` record
   moves), or keep the geometry and make the eyedropper (`dominantBand(for:)`) the main way into the
   Mixer.
6. **AI-08: a spatial local mean for Uniformity and Point Variance.** Feed a blurred working-space
   image into S9 as `localMean`; the blur radius is a taste parameter. A colour cube cannot carry
   it, so this belongs with P5's exact S9 kernel. Until then, the panel should say that these tools
   converge per pixel and flatten hue texture.

## FOUND-WHILE-FIXING

1. The `hueRotation` in the committed `color.density` and `color.saturation` records (3.59° and
   8.38°) does not come from the colour stage. Engine-only on the same chart, Density's rotation was
   0.15° before this fix and 3e-13 after, and the rendered figure did not change by a single digit.
   The rotation comes from the stages after S9 acting on more saturated colour. It is worth checking
   separately whether the display transform's tone curve holds hue: the existing
   `HuePreservationTests.testTheDisplaySpaceGamutClipHoldsHueAndIsMonotone` covers only the gamut
   clip.
2. `ExactMixerGPU.membership` duplicates `bandWeights` but leaves out its `sum < 1e-6` nearest-band
   fallback; its comment says sanitised arcs make that case unreachable. Anyone who changes
   `bandWeights` (DECISION 1) has to change both.

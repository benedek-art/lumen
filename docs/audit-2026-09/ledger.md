# The ledger

One row per finding. `K-nnn` rows are the KNOWN-OPEN backlog carried in from docs/31,
docs/36, docs/37, docs/27, docs/30, docs/33, docs/34, docs/32 §4 and BUILDING.md as of
`cc82116`. W2 auditors re-verify each K row in their area (STILL-OPEN / FIXED-SINCE /
CHANGED) before reporting anything new; new findings get area ids (`A1-07`) and are
appended by the W4 synthesis. Disposition is filled in W4–W6.

Severity: S1 data loss / crash / wrong pixels / silent no-op control · S2 visible
defect or parity gap · S3 polish. Area codes match the W2 partition (A tone, B colour,
C film/grain, D looks/effects, E detail, F masks, G UI, H viewer/scopes, I pipeline,
J library/export, K crop/lens, L state, M recipe).

## Known-open backlog

| id | area | sev | source | finding | W2 verdict | disposition |
|---|---|---|---|---|---|---|
| K-001 | F4 | S2 | docs/37 §5.1 | Overlay precedence still expressed by write-order across nine writers of `soloMaskOverlay`; only three guards live in `MaskOverlayRule` | | |
| K-002 | F4 | S3 | docs/37 §5.2 | Navigator split blocked on `refreshMaskThumbnails` rebuilding serially, one `await` per mask | | |
| K-003 | F4 | S2 | docs/37 §5.3 | Edge controls are a Levels dialog on alpha; should be one transfer graph; Follow → Off/Gentle/Strong; Expand+Soften → one overlay drag | | |
| K-004 | F1 | S2 | docs/37 §5.4 | Brush masks have no pin — `MaskCanvas.anchor(of:)` hits `default: continue` for `.brush`; Strength scrub on pin never built | re-verified W2 | STILL-OPEN (F1 re-verified: `anchor(of:)` `default: continue`) |
| K-005 | G3 | S2 | docs/37 §5.5 | No next/previous-mask key; isolating 1 of 3 masks costs 4 toggles; no held-key solo | | |
| K-006 | F4/G2 | S2 | docs/37 §5.6 | Control-register bundle: toggle rows identical to a slider at zero; 9 label-left rows with no value column; 22/28/33 pt pitch; 6 radii vs 3 tokens; Light & Colour lack modified dot + Reset; mask Temp on linear Kelvin axis; mask Exposure/Contrast missing coloured tracks; `autoName` wired to unreachable placeholder | re-verified W2 | CHANGED (G2 + F4: pitch now 22/28/30, radii 9-vs-4; `autoName` FIXED-SINCE) |
| K-007 | F2 | S2 | docs/36 open | Overlay should read the render's alpha instead of rasterizing a second time | | |
| K-008 | F2 | S2 | docs/36 open | Bounded local adjust — crop spatial stages to the mask's box | | |
| K-009 | F4 | — | docs/36 open | Per-component refinement: do NOT build as specified (12 sliders on 3 components); open design question | | owner decision |
| K-010 | D1 | S3 | docs/36 open | Develop presets carrying masks — blocked on AI kinds | | |
| K-011 | F3 | S3 | docs/36 open | Alpha PNG export/import of a mask — not built | | |
| K-012 | F4 | S3 | docs/36 open | Density toggle: filter landed, compact row height did not | | |
| K-013 | F5 | — | docs/36 open | Six model-dependent mask kinds need licence review, model conversion, download UX, app-size decision | | deferred: model |
| K-014 | tooling | S3 | docs/36 open | `check-swift-surface.py` cannot see protocol conformance | | |
| K-015 | J | **S1** | docs/31 r1 data-loss | Two RAWs with the same base name share one `NAME.xmp`; NEF+DNG editing destroys the NEF recipe and `sidecarWins` writes it into the catalog | re-verified W2 | STILL-OPEN, patch sketch in `w2/J1.md` — queued |
| K-016 | J | **S1** | docs/31 r1 data-loss | Export presets decoded with `try?` against a strict codec — one new field reverts the whole preset list to the stock four | | |
| K-017 | J | S2 | docs/31 r1 data-loss | Losing the catalog loses the session; only notice is 10 pt text in a hideable sidebar | | |
| K-018 | J/F3 | **S1** | docs/31 r1 data-loss | Brush strokes in neither backup (blob store outside `VACUUM INTO` and outside the sidecar) — restored catalog gives masks that rasterize empty | re-verified W2 | CHANGED (F3 + J1: sidecar half fixed; `BlobStore` still outside `VACUUM main INTO`) |
| K-019 | J | S2 | docs/31 r1 data-loss | `recoverIfNeeded` has nothing to recover from; `backup()`'s only caller is a menu item; nothing prunes | | |
| K-020 | M | **S1** | docs/31 r1 data-loss | A recipe written by a newer build is silently downgraded in place (guard compares carried-forward version, not this build's) | | |
| K-021 | G3 | S2 | docs/31 r1 correctness | ⌘C/⌘V/⌘A taken from every text field by `CommandGroup(replacing: .pasteboard)`; ⌘V pastes develop settings into 10 text fields | | |
| K-022 | F1 | S2 | docs/31 r1 correctness | Radial ellipse rotates in per-axis normalized units while `MaskRaster` rotates in long-edge units — handle 1.5× off in y on 3:2 at 45° (partly addressed by `radialOffset` this session; re-verify) | re-verified W2 | **FIXED-SINCE** (F1: handles, CPU `radialPlane` and the GPU kernel all in long-edge units) |
| K-023 | K | S2 | docs/31 r1 correctness | A ratio lock is silently broken by any change of angle (16:9 at 0° → 1.83:1 at 2°) | | |
| K-024 | J3 | S2 | docs/31 r1 correctness | "Don't resize" resamples anyway (~0.9999×), one pixel short per axis on cropped/straightened photos | | |
| K-025 | J3 | S2 | docs/31 r1 correctness | `scaled()` runs Lanczos with no edge clamp — darkened semi-transparent rim; golden test insets 6 px to avoid it | | |
| K-026 | J3 | S2 | docs/31 r1 correctness | Metadata policy reads its base dictionary from the rendered image after ~40 kernels — no-op or stale orientation/dimensions | | |
| K-027 | D1 | S2 | docs/31 r1 correctness | Reset on the Looks header applies a second tone map to every JPEG (rendered file starts "Linear", `RenderParams()` is "Neutral") | | |
| K-028 | E1 | S2 | docs/31 r1 correctness | Detail header Reset gives every selected photo the primary's ISO denoise baseline (wrong overload) | | |
| K-029 | K/G3 | S2 | docs/31 r1 correctness | ⌘K → "Lens Corrections" arms the crop rectangle with no crop panel; Escape can't revert | | |
| K-030 | L | S2 | docs/31 r1 perf | `zoomLevel` publishes on `AppState` per pinch/scrub — whole-window + `Scene` rebuild, 7 menus | re-verified W2 | STILL-OPEN (L: `AppState:1577` published, `LoupeView:130` writes unguarded per pinch) |
| K-031 | H1 | S2 | docs/31 r1 perf | `InspectionGain` runs a full-res Core Image render inside `body`, memoised one deep; N panes = N renders on main; two static caches never cleared | | |
| K-032 | H1 | S2 | docs/31 r1 perf | Draft ladder taught the size it asked for, not the size it got — guard is a tautology; settle-recovery a no-op on any cropped photo | | |
| K-033 | J3 | S2 | docs/31 r1 perf | Export holds the serial render actor for the whole batch with no cancellation point; loupe freezes | | |
| K-034 | L | S2 | docs/31 r1 perf | `AppUpdater` blocks main through `ditto` + deep `codesign`; failure message may be wrong | | needs Mac; frozen file |
| K-035 | G2 | S3 | docs/31 r1 perf | `NSCursor` push/pop unbalanced in `ContentView` divider and `lumenScrubCursor`/`lumenClickCursor` | re-verified W2 | STILL-OPEN (G2: `LumenHover.swift:47-70`, 29 call sites) |
| K-036 | I3 | S2 | docs/31 r1 perf | Decode memory bounded per file but twelve files cached — up to ~3.8 GB (partly bounded since by `trimDecodeResidency` 768 MB; re-verify) | | |
| K-037 | G3 | S3 | docs/31 r1 smaller | View menu's first inner `Group` sits at exactly 10 children; arity guard scans only top-level builders | | |
| K-038 | L | S2 | docs/31 r1 smaller | Coalescing keys shared between distinct decisions (two WB presets, two curve points, two aspect ratios fold into one undo step) | re-verified W2 | STILL-OPEN (L + A2: curve key carries channel but no point index; two new collisions found) |
| K-039 | A1 | S2 | docs/31 r1 smaller | Contrast is linear where docs/04 specifies log-scaled — usable band is 9% of the track | | |
| K-040 | A1 | S2 | docs/31 r1 smaller | Zones sliders run 2.5× past monotonicity; one zone at +3 EV flattens 11.9% of the tonal axis | | |
| K-041 | A2 | S3 | docs/31 r1 smaller | `wand` (per-slider Auto) declared and passed by 0 of 88 call sites; `showReadout` is `@Published` with no writer | re-verified W2 | CHANGED (A2: `wand` still 0 of 94 call sites; `showReadout` FIXED-SINCE) |
| K-042 | B3 | S3 | docs/31 r1 smaller | Mixer "All bands" readout is a mean and the thumb springs back on release when bands have spread | | |
| K-043 | M | S3 | docs/31 r1 smaller | Five `LocalAdjust` fields and eight `Upright` fields round-trip meaning nothing | | owner decision (delete vs surface) |
| K-044 | B2 | **S1** | docs/31 r2 | Grading wheels: Luminance inverts the tone response at shipped defaults — `scaleBrightness` scales OKLab L (linear = L³); limiter 2.85× too permissive; 345 of 810 sampled combinations invert; `ColorBalanceGrid` has no limiter | | |
| K-045 | C1 | **S1** | docs/31 r2 | Film Lab discards the user's display transform, rebuilding Neutral and copying only `whiteTarget`; Strength 0→1 is a discontinuity (51 code values on Linear); Black target dropped | re-verified W2 | **FIXED-SINCE** (C1: `RenderPlan:267` passes `base: transform`, five substitution-proof tests) |
| K-046 | F2 | **S1** | docs/31 r2 | Every masked export delivers a mask edge resolved to 1/1024 of the frame — rasterized at 1024 and bilinearly upsampled; the CPU reference rasterizes full-res so the renderers disagree | | |
| K-047 | I1 | **S1** | docs/31 r2 | The stale-table door hands a new photograph the previous photograph's picture formation (partly guarded by `setRenderIdentity`; re-verify) | re-verified W2 | CHANGED (I1) |
| K-048 | I2 | S2 | docs/31 r2 | GPU log-luminance plane has no floor; reference clamps at zero — −0.01 encodes to −4.83 vs +0.0024; drives guided filter `a` 0.087→0.917 | | |
| K-049 | B2 | S2 | docs/31 r2 | Grading zone pivots guessed `[0.33, 0.67]` = −4.38/+0.38 EV against a spec of −2.0/+1.5 | | |
| K-050 | I2 | S2 | docs/31 r2 | Every spatial stage runs on an fp16 log plane whose quantum (0.0117 EV) exceeds the presence regulariser's √ε threshold basis; fix is a change of denomination | | too wide; report |
| K-051 | J3 | S2 | docs/31 r2 | Soft proof perceptual intent degrades to a per-channel clip near white; mean hue rotation 28° above L=1, worst 171° | | |
| K-052 | J1 | **S1** | docs/31 r2 | Text filter returns nothing permanently once `cache.db` is recreated — `photo_fts` lives in the disposable DB, nothing rebuilds it | re-verified W2 | STILL-OPEN, patch sketch in `w2/J1.md` — queued |
| K-053 | J1 | **S1** | docs/31 r2 | A colour label Lumen cannot name is deleted from the sidecar on the first culling keystroke | re-verified W2 | **LANDED 7bd7fdf** — `SidecarLabelPolicy.write`; a flag/rating keystroke no longer speaks about the label |
| K-054 | J1 | **S1** | docs/31 r2 | `xmp:Rating="-1"` (LR reject) silently rewritten as 0 | re-verified W2 | **LANDED (read half) 7bd7fdf** — −1 reads as `flag = .reject`. Write half REFUSED: it broke `testFlagAndRatingSurviveEachOther`, a pinned contract. LR-interop-on-write → report |
| K-055 | J1 | S2 | docs/31 r2 | Grid query materializes every row with no LIMIT per keystroke — 350 ms for 50k rows on the thumbnail queue, no debounce | | |
| K-056 | J1 | S2 | docs/31 r2 | First open of a card ≈1 s at 5k frames, ≈10 s at 50k, inside one `queue.sync` | | |
| K-057 | J1 | S3 | docs/31 r2 | Text chip is prefix-only on FTS and infix on the fallback | | |
| K-058 | misc | S3 | docs/31 r2 | Texture GPU gain has no ±4 EV limit; gamut flag on opposite sides of grain in the two renderers; album counts offline frames; `rebuild` writes bare LFs into CRLF sidecar; a Lumen element name stripped inside foreign provenance | | |
| K-059 | M | S2 | docs/31 r2 | Non-finite zone pivot indexes past the pivot array; short foreign pivot array padded with defaults' tail → unsorted array accepted | | |
| K-060 | I1 | S2 | docs/31 r2 | Untouched recipe is not a passthrough — finish table costs 3.5 code values at preview vs 0.9 at export | re-verified W2 | STILL-OPEN (I1) |
| K-061 | A1 | S2 | docs/31 r2 | `CurveStack.bakeChannelLUTs` has zero callers and would drop `preserveLuminance` + luma curve if wired | | |
| K-062 | G3 | S2 | docs/30 §7.7 | Cull is a one-way door for the mouse (believed fixed by the edge rail; verify) | | |
| K-063 | I1 | S2 | docs/33 B2 | Region render still pays a whole-sensor decode — `renderPreviewDelivery` decodes before computing the raster rect | re-verified W2 | STILL-OPEN (I1) |
| K-064 | F2 | S2 | docs/33 B2 | A masked settle at zoom rasterizes an 11 MP mask on the CPU (`maskRasterCeiling` 4096) | | |
| K-065 | C2/J3 | S2 | docs/33 B2 | Creative grain on export is laid before the resize (`plan.grain` not `plan.filmChain` in `exportedImage`) | re-verified W2 | STILL-OPEN (C2: `PipelineRenderer:697` reads `plan.filmChain`; grain lands on the decode grid, before geometry and resize) |
| K-066 | J2 | S3 | docs/34 §5 | Grid scrolling and thumbnail decode never profiled | | |
| K-067 | J3 | S3 | docs/34 §5 | Export never profiled | | |
| K-068 | I3 | S3 | docs/34 §5 | Cold open vs warm unmeasured | | |
| K-069 | F2 | S3 | docs/34 §5 | Masked settles at zoom unmeasured | | |
| K-070 | E1 | — | docs/32 §4 | Open-source denoise integration — **deferral lifted**; R6 decides | | |
| K-071 | C1 | — | docs/32 §4 | Film-stock expansion + grain customisation — **deferral lifted** | | |
| K-072 | F | — | docs/32 §4 | Masks polish round two — **deferral lifted** | | |
| K-073 | — | — | docs/32 §4 | Everything else stays ranked in docs/31 | | |
| K-074 | E1 | — | docs/34 §5b | Classical NR not tuned further pending a real denoiser; `contributingNoiseScale` is the one number to move | | |
| K-075 | E2 | S2 | docs/27 §3 | `detail.capture.radius` stored and not applied — Richardson–Lucy has no caller; wire-or-remove | | |
| K-076 | E | S3 | docs/27 §3 | `detail.capture.amount` and `denoise.amount` (AI) measurable only on macOS lane | | |
| K-077 | F | S3 | docs/27 §3 | Masked adjustment proofs deferred — runner needs mask-raster support | | |
| K-078 | A1 | S3 | docs/27 §4 | Owed: Lightroom reference exports from the owner | | owner input |
| K-079 | A1 | S3 | docs/27 §4 | Owed: Highlights/Shadows range-compression targets vs dt/RT | | |
| K-080 | A1 | S3 | docs/27 §4 | Owed: Temp-writes-the-Kelvin-it-shows as a full-pipeline contract (needs RAW fixtures) | | |
| K-081 | B2 | S3 | docs/27 §4 | Owed: Colour Balance semantic contracts (chroma holds L and h; brilliance holds ratio) | | |
| K-082 | E2 | S2 | docs/27 §4 | Sharpen radius in OUTPUT pixels; preview/export disagreement recorded | | |
| K-083 | H1 | S3 | BUILDING | Loupe is a SwiftUI image view, not Metal/EDR; HDR viewport not built | | too wide |
| K-084 | F5 | S2 | BUILDING | Sky, Object, Landscape, Depth Range have no model and rasterize to nothing (now unoffered in picker; verify no path reaches them) | re-verified W2 | CHANGED (F5: verified no in-app creation path; foreign recipes only) |
| K-085 | F5 | S2 | BUILDING | Vision path never run on hardware — matte orientation argued from convention | | needs Mac |
| K-086 | E1 | S2 | BUILDING | AI denoise Tier 2 modelled, not wired; `.ai` drives decoder NR as stand-in — reaches RAW only; on JPEG/HEIC `.ai` = every denoise stage off | | |
| K-087 | E1 | S3 | BUILDING | `ReferenceRenderer.render` starts at S6; Tier-1 CPU denoise runs one level up | | |
| K-088 | E2 | S2 | BUILDING | Capture sharpening (S4) unchanged; `richardsonLucy` uncalled and untested | | |
| K-089 | H2 | S2 | BUILDING | `⇧H` clipping is scene-linear post-demosaic, not CFA; measured on 2048 proxy; `photosMissingRawStatistics` sweep has no driver; `O` raw-clipping overlay not built | | |
| K-090 | D2 | S2 | BUILDING | Dehaze sky guard reference-only — per-pixel transmission floor missing on GPU | | |
| K-091 | A1 | S2 | BUILDING | JPEG/HEIC/PNG/TIFF get the display transform on top of the baked-in one; nothing auto-selects Linear; their Temp/Tint relative to 5500 K | | |
| K-092 | A1 | S2 | BUILDING | `ZoneAdjust.wheel/.sat/.falloff` are a wire format no stage reads; don't force re-render | | |
| K-093 | K | — | BUILDING | Heal/clone does not exist on any path; `Heal` participates in `renderIdentity`; Upright same | | owner decision (delete vs build) |
| K-094 | G3 | S3 | BUILDING | Speed Edit (D44) not implemented | | |
| K-095 | B3 | S3 | BUILDING | Eyedropper wired, never exercised by a human | | needs Mac |
| K-096 | J3 | S2 | BUILDING | A kernel failing outside the core four degrades one stage silently in EXPORT | | |
| K-097 | E2 | S2 | BUILDING | Creative sharpening not resolution-scaled — export less sharpened than judged; no surface shows it | | |
| K-098 | F2 | S3 | BUILDING | Mask COLOUR table runs at 33³ on export; waveform blank columns on crops < 256 proxy px | | |
| K-099 | D2 | S2 | BUILDING | Texture well under specified strength — band shape 1.8×–17× weak; port reverted twice (coherence gate) | | too wide; report |
| K-100 | J3 | S2 | BUILDING | Verified-copy ingest engine not built; sheet refuses | | ship-or-remove |
| K-101 | J2 | S3 | BUILDING | `cache.frame_score` has no writer; sort-by-score "not built yet" | | |
| K-102 | tooling | S3 | docs/audit/library-ux | LumenAppTests exists (9 files) but no CI lane runs it under a filter | re-verified W2 | CHANGED (L: `test-fast` does run LumenAppTests unfiltered — the gap is a *named* lane, not coverage) |
| K-103 | J3 | S3 | docs/11 | Watermarking — deferred, stated | | |
| K-104 | G3 | S2 | docs/29 | Keymap: `L`→Lights Out, `B`→album, `⌘B`→assessment, `F` stays, `S` stays — **decided**, not yet implemented; docs/12 amendments owed | | |

## New findings (appended by W4 synthesis; N-rows below were found in W0 from CI evidence)

| id | area | sev | source | finding | verdict | disposition |
|---|---|---|---|---|---|---|
| N-001 | F2/I2 | **S1** | gpu-parity log run 33553464942 + `Kernels.swift:472,491` | `lumenMaskLinear` and `lumenMaskRadial` use `float long` — a reserved word in the CI Kernel Language — so neither compiled on any macOS build; `parametricMasksAvailable` false → `MaskGPU.isParametric` false → every gradient mask rasterized on the CPU. `testEveryKernelCompiles` could not see it (the four mask kernels were in no roster) and `MaskGPUParityTests` skipped 3/5 as "kernels unavailable". Green lane, dead fast path; the direct cause of "the mask is still delayed when I drag it". | CONFIRMED (log + grep) | **LANDED W0.7** in three pushes: d5d7136 `long`→`edge`; 64ae6da `out`→`folded` + checker pass 13; then the parity tests ran for the first time and found the GPU alpha **vertically mirrored** (kernels read `destCoord()` bottom-up, the reference indexes rows from the top) — fixed by `h − (y − oy)` in both generators. 64ae6da's dev build drew mirrored gradient masks for ~8 min. **fce5936: gpu-parity GREEN** — 20 cases × 3 resolutions + mirror + offset-extent all pass; the parametric fast path is live and correct for the first time. CLOSED. |
| N-002 | I1 | S2 | `w0/perf-baseline.md` DRAGPROBE | Settle path bakes tables on every frame with zero cache hits for Whites (`0h/36b`, p50 388 ms vs 69 ms draft) and Saturation (p50 269 ms vs 24 ms draft) — the settle frame after a drag costs 7–11× the drafts that preceded it. | PARTLY REJECTED by I1: the `0h` is a probe artifact (disjoint sample sets + `resetStats` not clearing entries); the `36b` is real and is a double/triple bake | **LANDED cf9fb58** (I1-01 + I1-03): `table` joins an in-flight bake for its key or steals a queued one; `drainPending` counts `deferredBakes`; `resetStats` zeroes `slotTraffic`. Still open: I1-02 (fix the probe so the row can be re-measured) and I1-04 (the settle loop). Re-measure on gpu-parity's DragProbe after I1-02. |
| N-003 | C1/I2 | S3 | `w0/perf-baseline.md` HALATION | Halation mass on the GPU is 6.4517 vs 6.8944 in the reference — 6% light, while spread matches (52.31 vs 52.74). | measured | → C1 audit |

## W5 landings from W2 findings (batch 2, 2026-09-02)

Findings that live in `w2/<code>.md` rather than as K-rows, dispositioned here so the
close-out can walk one table.

| Finding | Area | Sev | Landed | Note |
|---|---|---|---|---|
| L-01 / A2-01 | L, A2 | S1 | **31ef62a** | gesture epoch as the first coalescing clause; window rule untouched |
| B1-02 | B1 | S1 | **3fbb096** | chroma gate applied to Point Colour's hue shift; `pointColor.hue` record may need re-pinning |
| I1-01 | I1 | S2 | **cf9fb58** | join / steal; bounded 0.5 s wait so a missed broadcast degrades to a redundant bake, never a hang |
| I1-03 | I1 | S2 | **cf9fb58** | `deferredBakes`, `joinedBakes` on `Stats` and the HUD (`d`, `j`) |
| C2-01 | C2 | S2 | **56008bf** | CORRECTED: blue record only (Velvia 17 %, Ektar 0.45 % → 0). Red/green divergence is the floor itself → **C2-01b open**: band-limited plate per R7 C.2.3 |
| G2-05 / K-035 | G2 | S2 | U1 (pending) | one balanced `LumenCursorModifier` for all three cursors |
| G2-02 | G2 | S2 | U1 (pending) | `.lumenHeading` adopted at 53 headers |
| G2-11 | G2 | S3 | U1 (pending) | `LumenCapsLabel` at one size |
| G2-12 | G2 | S3 | **REJECTED** | 2.5 on an 8 pt drawn box is the correct proportion; `radiusChip` makes a capsule |
| G2-03 | G2 | S1 | **REJECTED as a change** | radii 6/9/14 stand per the owner's recorded request; `radiusTab` stays on the rail tab's own argument |
| G2-01 | G2 | S1 | resolved by correction | no thumb-on-hover; the modified/unmodified fill separation does the job |

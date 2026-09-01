# Lumen — the full audit and upgrade grind

## Context

The owner has ~24 hours of unconstrained model usage and wants the whole app audited and
improved: every area, faster, better-looking, better-functioning — with competitors
researched first so the bar is theirs, not ours. He has never run anything at this scale
and wants an orchestrator with a bulletproof plan.

Decisions already taken (his answers):
- **Find first, fix second.** Wave 1 is read-only. Nothing is edited until findings are
  verified and triaged.
- **Competitors:** Lightroom Classic (the stated reference), Capture One, DxO PhotoLab,
  Darktable + RawTherapee, Luminar Neo / ON1 / Radiant.
- **Release lane:** keep pushing to the rolling dev release (every CI-green merge reaches
  his app within minutes).
- **His involvement: only at the end.** One report, one set of landed changes. This is
  the constraint that shapes everything below: no human checks anything mid-run, so the
  run has to check itself, and it must not make taste decisions on his behalf.

Hard constraints of this environment (learned this session):
- LumenApp and LumenPipeline **cannot be compiled here**. `scripts/check-swift-surface.py`
  (12 static passes) is the only local feedback; CI `build-macos` is the real compile.
- CI has `concurrency: cancel-in-progress: true` — two pushes in flight cancel the
  first. Landings must be **serialized**.
- The container has reset **three times** this session, each time losing the working
  tree. Anything not committed and pushed is gone. Every wave's output is committed.
- Engine tests must be substitution-proof (break the fix, watch red, restore).
- No model identifiers in anything pushed.

## The shape of the run

Six waves. Each wave's output is a set of files under `docs/audit-2026-09/`, committed and
pushed before the next wave starts, so a container reset or a context compaction costs at
most one wave's work.

```
W0 Brief      me        freeze areas, write briefs, ledger, perf baseline     h 0–0.5
W1 Research   7 + 1     competitor dossiers + denoise decision + film/grain
                        science → gap table (background)                      h 0.5–2
U0 Mockup     me        high-def mockup + pitch → THE ONE CHECKPOINT          h 0.5–2
W2 Audit      30        read-only, evidence-backed findings per area          h 2–4
W3 Verify     ~30       adversarial re-check, pipelined behind W2             h 2.5–5
W4 Triage     me        ledger, streams, merge order                          h 5–6
W5 Implement  16 streams worktrees, serialized CI-gated landings; UI streams
                        start on the U0 yes                                   h 6–21
W6 Close      3 + me    re-audit, perf after, docs/38, decisions list         h 21–23
```

Agent counts are targets, not caps; W5's count follows what W3 confirms. If the U0 yes
comes late, non-UI streams keep landing and the UI phases compress toward the end —
U1 (design system) is one landing and changes every panel at once, so even a late yes
buys most of the visible change.

### Why every wave is separated by a commit
Container resets ×3 this session. A wave that finishes writes its results to disk and I
commit them. If the environment dies, the next session reads the ledger and resumes from
the last committed wave instead of re-spending the usage.

### Why W3 (verification) exists at all
At 24 parallel auditors, some findings will be wrong — misread code, a "bug" that is
deliberate and documented, a performance claim with no number behind it. This session's
own audits produced findings that turned out to be already-fixed or by-design. A finding
that is implemented without verification becomes a regression with a confident commit
message. Every finding gets a fresh agent whose job is to **disprove** it. Rejected
findings never reach W5.

### The UI rebuild, and the one checkpoint
The owner overruled a UI shape twice this session ("you disregarded what I said"), and
has now asked for a large UI rebuild — "modern and beautiful… not a tool built in the
2000s… follow your own thought" — with **one** early checkpoint: *"make a high-def
mockup and sell me the UI."* So the direction is pinned **before** any UI stream runs:

- **U0** (hour 1–2, while research runs in the background): a high-fidelity HTML mockup
  artifact of the window in the proposed direction, with a current/proposed toggle and
  live hover/focus/drag states, plus the pitch. The owner says yes or adjusts once.
- Until that yes, only non-UI streams run (data-loss, recipe safety, engine window 1).
  UI streams start on the yes and then build to the mockup unattended. Anything a
  stream wants that is **outside** the approved direction goes to the report, not the
  app. The masks panel is already specified by him ("copy Lightroom bar for bar").

## Decisions already taken (nothing below needs the owner mid-run)

| Decision | Answer | Source |
|---|---|---|
| Find vs fix | Find first, verify, then fix | owner |
| Competitors | LrC, C1, DxO (+FilmPack), DT+RT(+ART), Luminar/ON1/Radiant/Dehancer/Filmbox/RNI | owner |
| Release lane | Keep publishing `dev-latest` on every green landing | owner |
| Involvement | U0 mockup checkpoint only; report at the end | owner |
| Deferrals (docs/32 §4) | All lifted: film & grain (implement), masks round two (implement), denoise (research → decide → integrate if a free, licence-clean model wins; timing mine) | owner |
| Backlog | Known-open S1/S2 land before new findings of equal severity | owner |
| UI direction | Option B "Modern pro", executed whole (below) | owner, via U0 |
| Row pitch | **24 pt**, one pitch everywhere | owner |
| Keymap (docs/29 ⚑) | `L`→Lights Out, `B`→add-to-album, `⌘B`→assessment mode, `F` stays filmstrip, `S`/`⇧S` stay; ratings `1–5`, palette `⌘K` | owner |
| Denoise delivery | Download on first use from a release asset, hash-verified, progress UI (keeps the app small; no size cap needed) | mine, under "up to you" |
| Denoise timing | R6 decides adopt/build/hybrid; integration lands in engine window 2 only if a CoreML-convertible free model exists and the scaffold passes the triad; otherwise a scaffold + proposal | mine |
| Chrome value | Keep the elevation ladder's values (14 code sites, docs/25/28 decided); lower text contrast for long sessions; build the real Law-7 answer — `⌘B` ISO 12646 assessment mode + D46 canvas-surround control — rather than repaint panels mid-grey | mine |
| IA | Stays: rail + five workspaces + accordions. The rebuild is surface, type, state, rhythm, motion — not another IA change | mine ("not too much") |
| Cull one-way door (docs/30 §7.7) | Already fixed by the rail on the window edge (`ContentView` "THE RAIL… outside the `if`"); verify in G3, no decision needed | inventory |
| `⌘C`/`⌘V` stolen from text fields (docs/31 #21) | Fix contextually — settings copy/paste only when no text field has focus; keys unchanged | mine |

## The UI direction (what U0 sells, what U1–U5 build)

**Thesis**: the 2008 read comes from edges, noise and sameness — hairlines everywhere,
five different row pitches, six radii, caps labels three ways, twenty same-weight targets,
prose in panels, state as a grey wash, no hover, no focus, white text at 11:1 for ten
hours. Modern pro tools (C1, Resolve) read as calm instruments because depth is *value*,
rhythm is *one grid*, state is *legible*, and the photograph is the only thing with
colour or contrast. Law 7 (zero-chroma chrome) is therefore not an obstacle to beauty —
it is the discipline that produces it.

1. **Light, not lines**: no hairlines anywhere; the five-step ladder does all dividing
   (surround 0.165 · base 0.18 · panel 0.20 · well 0.145 · control 0.24/0.27/0.31). Wells
   carve down, controls step up, cards get a 1 px white@4% top edge ("lit from above").
2. **One rhythm**: 4 pt grid; **24 pt rows**; three radii — **6 chip · 9 control ·
   14 card, the values already in `LumenSurface.swift`** — 12 pt panel inset on both
   sides; 16 pt section gap; nothing below 10 pt.

   > **CORRECTED after the G2 audit.** This said 3 / 6 / 10, and that would have
   > silently reverted a request of the owner's recorded verbatim at
   > `LumenSurface.swift:145-160`: *"I'd love if we can maybe make the corner radius a
   > little higher, so a little bit more circular, especially for the Cull, Develop,
   > Crop, Grade, Deliver items, as well as the independent items like the Curves tab,
   > the White Balance, Tone."* The ladder was moved UP to 6/9/14 on that request. The
   > mockup rendered the smaller set and the approval was of the direction, not of a
   > number he had already asked to raise; his words win. Radii are not changing.
3. **Type with a scale**: 12 pt semibold mixed-case section titles (caps retire to the
   sidebar), 11 pt labels, 11 pt mono values in **pills** that advertise click-to-type,
   10 pt notes. Primary text 0.86 (≈8:1) not 0.92, secondary 0.62, tertiary 0.48.
4. **State you can see**: focus = 1.5 px accent ring @60%; modified = fill 0.72 +
   accent dot + pill border. **Hover paints only things you can click** — headers,
   chevrons, tabs, buttons, chips — and never a slider row.

   > **CORRECTED after the G2 audit.** This said hover on every row and the thumb
   > hidden until row-hover. Both contradict a request recorded verbatim at
   > `LumenFocus.swift:35-38`: *"I would remove a bunch of the hover effects, like
   > hovering over the white balance or the temperature or tint, stuff like that. I
   > really don't like the fact that I can get that hover effect."* The file's own
   > argument is Law 4: eleven rows lighting up as the pointer crosses them is motion in
   > the peripheral vision of a colour judgement. A thumb appearing per row on hover is
   > the same wave by another means, so it goes too — the modified/unmodified fill
   > separation already does that job without motion. Focus keeps its surface, because
   > it is the one state with nothing else to show it.
5. **The viewer is the hero**: chrome recedes (thinner bars, rail icons 14 pt with 9 pt
   labels), overlays and the floating Masks panel share one **HUD material** (black @72%,
   radius 10, no border), badges are pills not boxes.
6. **Motion with intent, ≤120 ms**: disclosure, hover lift, thumb lift on drag, panel
   collapse. Nothing decorative.
7. **Direct manipulation is the fun**: on-canvas mask handles ("everything in the
   circle"), draggable histogram zones, hue ring, scrubby pills — fewer trips to a slider.
8. **The Law-7 answer, built**: `⌘B` toggles ISO 12646 assessment (chrome to 18% grey,
   surround to mid-grey, overlays off); right-click surround: white/light/mid/dark/black
   (D46); `L` cycles Lights Out.

### U0 — the mockup and the pitch (hour 1–2, artifact; load `artifact-design` first)
Screens, each with a **current ↔ proposed** toggle: (a) Develop — rail, column with Tone
and Colour open, one slider modified, one hovered, one focused-and-typing, the viewer
with a synthetic photograph (no image assets exist in the repo; a canvas-drawn scene);
(b) Masking — the floating panel in HUD material, a radial on the canvas with the new
handles, the collapsed thumbnail column; (c) Cull — grid, the filter popover with live
counts, the query sentence in the status bar; (d) Assessment mode on. Live CSS hover /
focus / drag states so the "state you can see" claim is demonstrated, not described.
The pitch sits above the screens: the thesis, the eight moves, what does **not** change
(keymap, D45 slider contract, IA, honesty affordances, zero-chroma), and what it costs
(one row per screen). Published private; link in STATUS.md.

### U1 — design system (one landing, global effect; first UI landing after the yes)
`Lumen*.swift` ×11: tokens (pitch, radii, text values, HUD material), `LumenSlider`
anatomy (pill value, thumb-on-hover, hover lift, focus ring, modified state),
`LumenSectionHeader` (12 pt mixed-case, reset-on-hover, no hairline),
`LumenMenu`/`LumenSwitch`/`LumenSegmented` in the pill-in-well system, `LumenSurface`
(no hairlines; card top-edge), `LumenType` (the scale). Every panel changes look with
this landing and no panel file is touched by it. `PanelLayoutBroadcastTests` and
`DragBroadcastTests` guard that none of it costs a publish per event.

### U2 — panels and rhythm (after engine window 1 has landed its panel-side edits)
`BasicPanel`, `ZonesPanel`, `CurveEditorView`, `DetailPanel`, `EffectsPanel`,
`LookPanel`, `ColorPanel`, `CropPanel`, `DevelopPanel`, `DevelopColumn`: every row on
the grid, box-in-box removed, one-sided insets fixed, every label fits at 320 pt (G1's
measured list is the checklist), prose → ⓘ-collapse except the four honesty notes,
per-section Reset and modified dot everywhere they are missing (docs/37 §5.6).

### U3 — shell
`ContentView` (sidebar regroup, status bar with the query sentence, empty state), the
filter bar → popover with live counts, `GridView`/`FilmstripView` cells (hover overlays,
selection border in accent), `WorkspaceRail` icons+labels, `LumenApp` menus, sheets
(`ExportSheet`, `IngestSheet`) on the same system, the three key moves + `⌘B` + `L` in
`Keymap` + `KeyGrammar` + help sheet in one commit, `⌘C`/`⌘V` made contextual.

### U4 — viewer and masks chrome (H and F1/F2 streams, after U1)
HUD material on every overlay and badge, the floating Masks panel and its collapsed
column re-skinned, on-canvas radial/linear handles drawn to the mockup, assessment mode
+ canvas-surround control (H + U3 paired landing), before/after and compare chrome.

### U5 — polish and motion (last UI landing)
Hover/focus audit across every control (G2's list), disclosure and thumb-lift motion,
empty states and the help sheet in the new type, the keyboard reference regenerated.

## What the app actually is (from the inventory)

76k lines: LumenApp 36k (54 files), LumenCore 33k (74), LumenPipeline 6.8k (11). No
`.metal` — all 33+ GPU kernels are CIKernel strings in `Sources/LumenPipeline/Kernels.swift`.
`Sources/LumenCore/Engine/ReferenceRenderer.swift` is the golden CPU pipeline the GPU
must match. Biggest files: `AppState.swift` 3620, `CatalogStore.swift` 3616,
`MaskPanel.swift` 3133, `LoupeView.swift` 2295, `PipelineRenderer.swift` 2240.

Model-without-UI (audit must decide: surface, or delete): `Upright`, `LensCorrections
.removeCA/.defringe`, `look.lut`, `Heal` (no render stage), `MaskKind.depthRange` + 4
CoreML kinds, `IngestSheet`'s copy engine (stubbed).

## W2 — The audit partition (30 agents)

One agent = one brief = one findings file. Each brief names its files exhaustively so no
two auditors read the same code for the same question; where a file serves two areas
(`MaskPanel.swift`, `LumenControls.swift`) the brief says which QUESTION each owns.

| # | Area | Agents | Files (primary) | The question each answers |
|---|---|---:|---|---|
| A1 | Tone engine | 1 | `Engine/ToneEngine` 703, `CurveStack` 392, `DisplayTransform` 381, `Recipe.Tone/Zones/CurveSet`, `ZonesPanel`, `CurveEditorView` 1085 | Is every tone control doing what its name says, monotonic, hue-stable, and matched to the CPU reference? How does it compare to filmic/sigmoid (DT), LR's PV5 tone, C1's? |
| A2 | Slider feel | 1 | `LumenControls.LumenSlider` (D45 contract), `Interaction/SliderDrag` 461, `SliderEntry`, `SpeedEdit`, `DraftLadder` 709, `EventRate`, `HistoryCoalescing`, `RecipeBinder` in `DevelopPanel` | Drag precision, modifier keys, type-in, double-click reset, arrow nudge, undo granularity — against LR/C1's slider grammar. Is one drag one undo step everywhere? |
| B1 | Colour science | 1 | `Engine/WhiteBalanceEngine` (CAT16), `Color/*` 1529, `Engine/ColorEngine` 1255 (primaries, mixer, point colour, vibrance, B&W) | Correctness of adaptation, OKLab use, band shapes, point-colour range/variance, skin protection — against C1 Color Editor and LR HSL/Point Color/Calibration. |
| B2 | Grading | 1 | `Engine/GradeEngine` 911, `GradingWheels`, `PrinterLights`, `Primaries`, `LookPanel` grading sections, `LumenColorWheel` | Wheel math, zone weights, blending/balance semantics — against LR Color Grading, C1 Color Balance, DT color balance rgb. |
| B3 | Colour panel UI | 1 | `ColorPanel` 1273 (`MixerHueRing`, `MixerBandRibbon`, point-colour swatches, B&W) | Can a photographer find and drive every colour control? Ring/ribbon usability, swatch sampling, layout defects. |
| C1 | Film engine | 1 | `Engine/FilmLab` 1627 (negative→inversion→print, halation), `Kernels.AddGlow/HighlightEnergy`, `RenderGraph` S13 | Physical plausibility, stock roster, push/pull, halation radius/threshold — against Dehancer, DxO FilmPack, RNI, Luminar/ON1 film. |
| C2 | Grain & halation UI | 1 | `Recipe.CreativeGrain` + `RecipeLook.FilmGrain` (TWO grain systems), `Kernels.Grain`, `EffectsPanel` §Grain, `LookPanel` §Film Lab, `CreativeGrainTests` | Why two grain systems; size/roughness realism at export scale; resolution independence; does grain match preview↔export. |
| D1 | Looks & presets | 1 | `Recipe/LookSubset`, `AppState` §Saved looks, `CatalogStore` §Looks, `LookPanel` §Saved Looks, Copy/Paste Look, `RenderParams` presets, unreachable `look.lut` | Preset amount slider? Preset previews? LUT import? — against LR presets, C1 styles, Luminar templates. What a "look" should carry. |
| D2 | Effects | 1 | `DetailEngine` S8 (texture/clarity/dehaze) + S13 vignette, `SpatialOps` dark-channel, `Kernels.Dehaze/DetailGain*/Vignette`, `EffectsPanel`, `BasicPanel` §Presence | Halo behaviour, dehaze colour cast, vignette shape/feather/midpoint options — against LR effects, DxO ClearView, ON1. |
| E1 | Denoise | 1 | `Image/DenoiseEngine` 1898 (VST + à-trous + AI splice), `ClassicNR`, `DetailPanel` §NR, `Kernels.Denoise*`, `Proof/DenoiseQualityTests` | Quality vs DxO DeepPRIME / LR Denoise / DT; ISO-aware defaults; chroma blotch; speed. |
| E2 | Sharpening | 1 | `DetailEngine` S4/S12, `SpatialOps` Richardson–Lucy, `ManualSharpen`, `CaptureSharpen`, `OutputSharpen`, `DetailPanel` | Capture-sharpen auto radius, masking, halo suppression, output sharpening per medium — against RT capture sharpening, C1 diffraction, LR. |
| F1 | Mask canvas | 1 | `MaskCanvas` 1786, `Interaction/MaskHandles` 447, `BrushStabilizer`, `ViewerOverlays.MaskOverlayView` | **"Do everything in the circle."** LR's on-canvas grammar for radial/linear (rotate on edge, feather ring, drag inside to move, invert, duplicate); brush cursor, pressure, stabiliser; polygon self-intersection. |
| F2 | Mask engine & perf | 1 | `Image/MaskRaster` 1513, `Pipeline/MaskGPU` 155, `MaskRasterCache`, `BrushPlaneCache`, `PipelineRenderer.renderMaskAlpha`, `RenderGraph` S11 | Preview↔export parity of feather/refine/edge; `renderMaskAlpha` bypassing every cache; `guidePlane` percentile sort; per-stroke cost growth. |
| F3 | Mask persistence | 1 | `XMP/XMPSidecar` 543, `XMPMerge` 324, `Model/BrushStroke` 283, `Catalog/BlobStore`, paste-masks path | The three data-loss bugs (strokes >26,300 pts deleted; multi-photo paint overwrites; inverted-missing-input selects all); round-trip fidelity; sidecar size. |
| F4 | Mask panel (post-rebuild) | 1 | `MaskPanel` 3133, `MaskFloatingPanel` 323, `AppState` §mask overlay | Line-by-line Lightroom parity checklist of the panel that just shipped (`cc82116`): every control present in LR's Masks panel, present here or not, and every defect visible in the code. |
| F5 | AI & range masks | 1 | `Pipeline/VisionMattes` 178, range kinds in `MaskRaster`, `lumaRange` vs `luminosity` duplication, unoffered depth/CoreML kinds | Select Subject/Sky/Background quality and speed; Objects/People parts; colour/luma range UX — against LR, C1, Luminar. |
| G1 | Panel layout & hierarchy | 1 | `DevelopColumn` 715, `WorkspaceSectionView`, `BasicPanel` 679, `DetailPanel` 554, `EffectsPanel` 548, `LookPanel` 1396, `CropPanel` 747 | Measured widths at 320/380/520; every truncation, overflow, one-sided inset, orphan heading, box-in-box. Against docs/25, /28 laws. Defects vs redesign proposals, kept apart. |
| G2 | Design system | 1 | `Lumen*.swift` ×11 (4,895) — `LumenControls` 1753, `LumenMenu`, `LumenSwitch`, `LumenSurface`, `LumenType`, `LumenBehaviourGlyph`, `LumenFocus`, `LumenHover` | Consistency (sizes, radii, type scale), contrast ratios, focus rings, hover states, dead components, duplicated primitives. The "2008 Lightroom" feel — what specifically dates it. |
| G3 | Navigation & discoverability | 1 | `Keymap` 624, `Interaction/KeyGrammar` 260, `ControlPalette`/`ControlIndex`, `WorkspaceRail`, `FilterBar` 684, Sidebar in `ContentView`, empty states, help sheet, `LumenApp` menus | Can every feature be reached and learned? Shortcut collisions, missing LR/C1 defaults, menu completeness, empty-state guidance. |
| H1 | Viewer | 1 | `LoupeView` 2295, `ViewerOverlays` 1819, `CompareView` 532, `DraftLadder/DraftResolution/RefineBudget/FrameDelivery/ZoomLadder/ContinuousZoom` | Zoom grammar, progressive refine, before/after modes, pan feel, latency budget — against LR/C1 loupe. |
| H2 | Histogram & scopes | 1 | `Image/Scopes` 1657, `HistogramView` 657, `ScopesView` 388, `ScopeData` 226, `RawTruth*` | Correctness of every readout (what space, what clip thresholds), draggable zones, vectorscope skin line; speed of the feed. |
| I1 | Render path | 1 | `RenderCoordinator` 753, `PipelineRenderer` 2240, `RenderGraph` 1857, `RenderPlan` 668, `PlanTableCache` 379, `RenderRequest` | Edit→frame path: redundant passes, cache misses, over-rendering, actor contention, `@Published` fan-out re-bodies. Numbers, not impressions. |
| I2 | Kernels | 1 | `Kernels.swift` 1064 (every CIKernel string) vs `ReferenceRenderer` 567 | Per-kernel: matches reference? precision (half vs float), clamping, edge handling, fusable passes. |
| I3 | Decode & memory | 1 | `AppleRawSource` 549, `DecodeMaterializer`, `ImageSource`, `ThumbnailLoader` 496, `PreviewStore` 303, `Catalog/PreviewCache` 299, `DecodeWarming` | Cold-open time, memory ceiling on 45 MP, cache keying and eviction, embedded-preview path. |
| J1 | Catalog store | 1 | `Catalog/CatalogStore` 3616, `SQLite` 645, `Schema` 235, migrations, `CatalogService` 1269 | Data safety (transactions, WAL, crash mid-write), 10k+ photo query cost, scan reconciliation correctness. |
| J2 | Library & culling UX | 1 | `GridView`, `FilmstripView`, `FilterBar`, Sidebar, ratings/flags/labels/keywords/stacks/albums, `ArrowNavigation`, `ThumbnailLadder` | Cull speed grammar against Photo Mechanic / LR Library / C1; filter completeness; selection model. |
| J3 | Export & ingest | 1 | `ExportSheet` 958, `Export/*` 954, `AppStateActions`, `IngestSheet` 731 (stub), `Ingest/RenameTemplate` | Export presets, resize modes, output sharpening, metadata policy, watermark, HDR; the stubbed ingest — ship or remove. |
| K | Crop, lens, geometry | 1 | `Model/CropGeometry` 580, `Straighten`, `CropPanel` 747, `CropOverlayView`, `StraightenOverlayView`, `Upright` (model only), `LensCorrections`/`Defringe` (model only) | Crop tool grammar vs LR; Upright/perspective and CA/defringe — surface or delete. |
| L | State & integrity | 1 | `AppState` 3620, `HistoryStack` 213, `HistoryCoalescing`, `EditRevision`, `CommandState`, `AppUpdater` 282 | Undo correctness, "deliberately not published" rules honoured, force-unwraps, main-thread blocking, updater safety. |
| M | Recipe & serialization | 1 | `Recipe.swift` 1408, `RecipeLook`, `RecipeMasks`, `CanonicalJSON`, `Fingerprint`, `RecipeDecoding`, XMP | Forward/backward compatibility, dead fields, version migration, paste-settings subsets, fingerprint stability. |

Totals: **30 auditors** (masks ×5, colour ×3, UI/UX ×3, pipeline ×3, library ×3, the
rest ×1–2). The owner asked for "a couple" per named area and "a few" for masks; this
gives masks five because it has the most known-open defects and the most explicit target.

## What is already known (and must not be re-found)

The repo carries **~104 ranked, known-open findings** — docs/31 (34 + 18 carried forward,
incl. 6 data-loss), docs/36 "Still open", docs/37 §5 (6 items), BUILDING.md "Known gaps"
+ "Still open", docs/27 §3–4 — plus prior competitor research (docs/02 LrC teardown,
docs/03 the field) and prior per-domain audits (`docs/audit/*`, 257 findings). The
owner's decision: **backlog first, then new.** So:

- W1 research agents read docs/02, /03, /01, /17 first and fill gaps; they do not restart.
- W2 auditors receive their area's slice of the known-open list and must mark each
  STILL-OPEN / FIXED-SINCE / CHANGED with evidence before reporting anything new.
- W5 lands the backlog's S1/S2 items before new findings of equal severity.

Scope lifted by the owner (docs/32 §4 deferrals): **film & grain** (implement), **masks
round two** (implement), **denoise** (research + a decision: adopt an open-source
denoiser or build on the classical engine — a proposal, not a shipped model, in 24h).

## W0 — Brief (me, ~30 min)

1. `git fetch origin && git reset --hard origin/claude/photo-editor-design-plan-8ahzmm`
   (the sandbox lies — docs/32 §0 rule 2).
2. Create `docs/audit-2026-09/` with `STATUS.md`, `briefs/`, `w1/ … w6/`, `ledger.md`.
   Commit. **Every wave appends to STATUS.md and commits** — the resume point after a
   container reset or a context compaction.
3. Probe web access for research agents (WebSearch + WebFetch through the proxy). If
   blocked, W1 runs on docs/01–03 + model knowledge only, and the report says so.
4. **Perf baseline**: pull PerfProbe / DragProbe / TextureSpectrum lines from the
   gpu-parity job that ran on `cc82116` into `w0/perf-baseline.md`. No committed perf
   record exists today (docs/23 deferred the perf lane); W6 compares against this.
5. Write every agent brief as a file under `briefs/` so a relaunch after a reset uses the
   identical prompt. Briefs carry docs/32 §0's ground rules verbatim.
6. Extract the known-open list into `ledger.md` as rows `K-001 … K-104` (area, source
   doc, one line) so auditors and streams cite ids, not prose.

## W1 — Research (7 agents + 1 synthesis, ~1.5 h)

Each writes `w1/<name>.md` **structured by area A–M** so an auditor reads only its
section. Prior art first, then gaps. "How it works" — control ranges, defaults, modifier
keys, on-canvas grammar, what the algorithm visibly does — not marketing.

| Agent | Subject | Emphasis |
|---|---|---|
| R1 | Lightroom Classic (current) | Refresh docs/02 where stale. **Masking on-canvas grammar in detail** (radial/linear handles, feather ring, rotate-on-edge, invert, duplicate, pin behaviour); Point Color; Lens Blur; AI Denoise; preset Amount; Adaptive presets. |
| R2 | Capture One | Color Editor (basic/advanced/skin), Luma Range, layers, Styles, Speed Edit, Magic Brush, AI masks, catalog/sessions, cull speed. |
| R3 | DxO PhotoLab + FilmPack | DeepPRIME XD2/XD3 behaviour, lens modules, ClearView, Smart Lighting; **FilmPack's film stocks, grain model and halation** — the closest shipping analogue to Film Lab. |
| R4 | Darktable + RawTherapee (+ ART) | filmic/sigmoid, color balance rgb, capture sharpening, diffuse-or-sharpen, denoise (profiled), local Laplacian — with **source references**, since these are the only competitors whose maths can be read. |
| R5 | Luminar Neo / ON1 / Radiant / Dehancer / Filmbox / RNI | Creative bar: film emulation approaches (LUT vs physical), grain and halation models, bloom, relight/sky, preset UX. |
| R6 | **Denoise decision** | Survey open-source denoisers — algorithmic (profiled NLM, wavelet, BM3D) and learned (NAFNet, Restormer, KBNet, SCUNet, DRUNet, raw-domain PMRID-class) — for licence, model size, CoreML convertibility, raw-vs-RGB domain, Apple-silicon cost, published quality. Recommend: adopt X / build on the classical engine / hybrid, with the integration steps and what it costs in app size and licence. |
| R7 | **Film & grain science** | Physical emulation (spectral sensitivity, density curves, dye layers, negative→print), the datasheet route (Kodak/Fuji curves), and grain synthesis (Newson et al. 2017 stochastic model, Boolean/Poisson models, resolution-independent grain, chroma grain, grain-before-vs-after print). Feeds C1/C2 audits and the W5 film/grain stream directly. |
| R-S | Synthesis | `w1/gap-table.md`: rows = capabilities by area; columns = LrC / C1 / DxO / DT+RT / creative; cells = how it works + **Lumen status** (present / partial / absent, with file) using the inventory. This is the parity source for every auditor. |

## W2 — Audit (30 agents, read-only, ~2 h)

Mechanism: the Workflow tool, three runs of ~10 areas each (engine A–E; masks +
pipeline F, I; UI + library + rest G, H, J–M), so one failed run loses a third and the
default ≤15-agent guideline holds per run. Each run pipelines W3 verification behind
each audit as it completes (`pipeline()`), so verification is not a separate wall-clock
wave. Fallback if the Workflow tool misbehaves: plain Agent fan-out with the same briefs
— outputs are files either way.

**The brief** (`briefs/w2-<area>.md`), identical shape for all 30:

1. Area, the question, the exhaustive file list, the shared files and which question
   this area owns in them.
2. Read first: docs/00 (laws), docs/12 (UX law), docs/20 (proof standard), the area's
   spec (docs/04–11), the area's section of `w1/gap-table.md`, the area's rows of
   `ledger.md`.
3. Read **every line** of the owned files. Read-only. No edits, no git.
4. Known-open rows first: each → STILL-OPEN / FIXED-SINCE / CHANGED, with file:line.
5. New findings, ≤20, ranked. Each carries: id `A1-07`; title; **severity** S1 (data
   loss / crash / wrong pixels / silent no-op control) · S2 (visible defect, or a parity
   gap against the gap table) · S3 (polish); **confidence** measured / traced / inferred;
   evidence as quoted code with file:line; how the owner would see it; proposed fix
   (files, approach, the test that would go red with the defect substituted back);
   size S/M/L; **class** defect · parity-gap · proposal(taste). Perf claims need a
   number or a traced call count — "slow" is not a finding.
6. Output: `w2/<area>.md`, then a ≤150-word return with counts by severity. The file is
   the deliverable; the return is a receipt.

## W3 — Verify (~1.5 h, pipelined behind W2)

Every S1 and S2 finding gets a **fresh agent whose job is to disprove it**: re-read the
code, run it on Linux where LumenCore allows, check it is not by-design (grep the doc
comment — this codebase explains its deviations in prose, 210 "deliberately"s), check it
is not already fixed. Verdict: CONFIRMED / PLAUSIBLE-NEEDS-MAC / REJECTED with reason.
S3 findings are verified one agent per area in batch. Rejected findings never reach W5;
PLAUSIBLE-NEEDS-MAC ones may land only with a test that CI's macOS lanes will run.
Output `w3/<area>.md`. This is the wave that turns "30 auditors" from a liability into
an asset.

## W4 — Triage (me, ~1 h)

A synthesis agent merges `w2/*` + `w3/*` + the known-open re-verification into
`ledger.md`: one row per finding, sorted by severity → confidence → size, deduplicated
(the same defect seen from two areas gets one row and two citations). I then:

- assign every CONFIRMED S1 to a stream (all of them land);
- assign CONFIRMED S2 defects and parity-gaps by area budget;
- assign S3 only where a stream is already in that file;
- route every `proposal(taste)` to the report, **never to a stream** (see "Why UI taste
  does not land unattended");
- write `w5/streams.md`: stream → files owned → finding ids → merge order.

## W5 — Implement (16 streams in worktrees, serialized landings, ~15 h)

**The UI rebuild adds three streams and time-slices panel ownership.** The design
pass's single "G nav+design" stream becomes:
- **U-DS** — owns `Lumen*.swift` ×11 only. Builds U1. Lands first among UI streams.
- **U-SHELL** — owns `ContentView`, `FilterBar`, `GridView`, `FilmstripView`,
  `WorkspaceEntry`, `PanelLayout`, `ControlPalette`, `LumenApp`, `Keymap`,
  `ExportSheet`, `IngestSheet`, `Interaction/{KeyGrammar,Workspace,
  WorkspaceModification,ControlIndex,SpeedEdit,ArrowNavigation,InspectionHolds,
  SliderDrag,SliderEntry}`, the docs/28 §5.1 table, the four tripwire tests. Builds U3.
  (J keeps the catalog/export **logic**; the sheets' and grid's **look** are U-SHELL's.)
- **U-PANELS** — owns the nine panel files **from the moment U1 lands**; before that
  they belong to their engine streams (A/B/CD/E/K) for functional edits. Builds U2.
  Engine window 1 therefore lands its panel-side edits *before* U1, and engine window 2
  (F3, I, film/grain engine) touches no panel file.
- U4 is done inside **H** (viewer/HUD, assessment mode + surround, paired with
  U-SHELL for the keys) and **F1/F2** (masks panel and canvas), all after U1.
- U5 is U-DS + U-SHELL, last.

UI streams do not start until the U0 yes; everything else does.

Measured CI (run 33553464948): build-macos 1m10s, test-fast 7m20s, engine-linux 6m,
fixtures-linux 1m50s, gpu-parity **3–4 min**, whole `ci.yml` ≈10.5 min. **Proof sweep
is 75 min** and is cancelled by any push touching `Sources/LumenCore/**` — it needs
quiet windows. Throughput is bounded by the lead: local triad (~10 min) for push N+1
overlaps CI for push N → **2–3 pushes/hour**, each carrying 1–3 stream branches →
~30–40 pushes, ~50–60 stream commits landed in 14 h.

### Mechanics
- Each stream: Agent with `isolation: "worktree"`, branch `audit/<stream>` from the
  post-L0 SHA, commits one-per-finding on its own branch, **never pushes, never touches
  another branch** (docs/32 §0 rule 10, made safe by worktree isolation).
- The lead merges serially into `claude/photo-editor-design-plan-8ahzmm`, runs the triad
  (`swiftc -parse` all Sources → `check-swift-surface.py` → `swift test --skip
  ControlProofTests`) plus `gen-fixtures.py --check` after every merge, pushes, waits
  for every lane green, then the next. Never merge the next branch onto a red push.
- LumenApp-only branches batch 2–3 per push. Branches touching `Sources/LumenCore/**`
  land only inside **engine windows**, because each restarts the 75-min proof sweep.

### L0 — foundation landing (lead, first)
Split three hot files by `extension` so streams are file-disjoint. Stored properties,
`@Published` + `didSet`, and `@State` cannot move; `private` members crossing the new
boundary become internal; new files sit **flat** in `Sources/LumenApp/` (the text-scan
tripwires `KeyGrammarTests:33`, `WorkspaceEntryTests:42` read that directory
non-recursively) and wrap in `#if os(macOS)`:
`AppState+MaskOverlay.swift` (overlay/mattes/thumbnails/strokes → F2),
`AppState+Library.swift` (query/scan/selection/culling → J), `AppState+Editing.swift`
(recipe/undo/copy-paste → L), `AppState+Looks.swift` (→ CD),
`ViewerOverlays+Crop.swift` (→ K), `ViewerOverlays+Mask.swift` (→ F2),
`PipelineRenderer+Export.swift` (→ J), `PipelineRenderer+Masks.swift` (→ F3),
`RenderGraph+Local.swift` (→ F3). Wait for build-macos + test-fast green; every
worktree branches from that SHA.

### Ownership (exclusive; requests to the owner for anything else)
| Stream | Owns |
|---|---|
| A tone | `Engine/{ToneEngine,CurveStack,WhiteBalanceEngine}`, `Model/{ZoneWeights,MonotoneCubic}`, `BasicPanel`, `ZonesPanel`, `CurveEditorView` |
| B colour | `Engine/{ColorEngine,GradeEngine}`, `Color/*`, `ColorPanel` |
| CD grade-UI + film | `Engine/{FilmLab,DisplayTransform}`, `LookPanel`, `EffectsPanel`, `AppState+Looks` |
| E detail | `Image/{DetailEngine,DenoiseEngine,SpatialOps}`, `DetailPanel` |
| F1 mask panel | `MaskPanel` (one 3k-line View with 12 `@State` — cannot split), `MaskFloatingPanel`, `LumenBehaviourGlyph` |
| F2 mask canvas | `MaskCanvas`, `ViewerOverlays+Mask`, `AppState+MaskOverlay`, `Interaction/{MaskHandles,MaskOverlayRule,BrushStabilizer}` |
| F3 mask engine | `Image/MaskRaster`, `Model/{MaskAlgebra,BrushStroke}`, `Recipe/RecipeMasks`, `Pipeline/{MaskGPU,MaskRasterCache,BrushPlaneCache,VisionMattes}`, `PipelineRenderer+Masks`, `RenderGraph+Local` |
| G nav + design | `ContentView`, `DevelopPanel`, `DevelopColumn`, `PanelLayout`, `WorkspaceEntry`, all `Lumen*.swift`, `ControlPalette`, `LumenApp`, **`Keymap`** (read as one text file by `KeyGrammarTests`), `Interaction/{KeyGrammar,Workspace,WorkspaceModification,SliderDrag,SliderEntry,ControlIndex,SpeedEdit,ArrowNavigation,InspectionHolds}`, the docs/28 §5.1 table |
| H viewer + scopes | `LoupeView`, `ViewerOverlays` (remainder), `CompareView`, `HistogramView`, `ScopesView`, `ScopeData`, `RawTruth*`, `InspectionGain`, `LatencyHUD`, `Image/{Scopes,RawTruth}`, `Interaction/{DraftLadder,DraftResolution,ZoomLadder,ContinuousZoom,ViewerScroll,FrameDelivery,EventRate,DecodeWarming,RefineBudget,ThumbnailLadder,ZoomRegion}` |
| I pipeline | `Kernels`, `RenderGraph` (rem.), `PipelineRenderer` (rem.), `AppleRawSource`, `DecodeMaterializer`, `ImageSource`, `Engine/{RenderPlan,PlanTableCache,ReferenceRenderer}`, `RenderCoordinator`, `RenderRequest` |
| J library + export | `Catalog/*` (**`CatalogStore` has a Linux stub twin at :3290 — no extension**), `Export/*`, `XMP/*`, `Ingest/*`, `CatalogService`, `GridView`, `FilmstripView`, `FilterBar`, `IngestSheet`, `ExportSheet`, `ThumbnailLoader`, `PreviewStore`, `AppStateActions`, `AppState+Library`, `PipelineRenderer+Export` |
| K crop + lens | `CropPanel`, `ViewerOverlays+Crop`, `Model/{CropGeometry,Straighten}`, `Interaction/FrameOrientation` |
| L state + recipe | `AppState` (remainder), `HistoryStack`, `EditRevision`, `CommandState`, `AppState+Editing`, `Recipe/{Recipe,RecipeDecoding,RecipeLook,LookSubset,CanonicalJSON,Fingerprint}`, `HistoryCoalescing`, `gen-fixtures.py` recipe mirror |

Lead-only, frozen: `Tests/LumenCoreTests/Proof/**`, `.github/workflows/**`,
`Package.swift`, `AppUpdater.swift` (the owner's install path). Each stream owns its
sources' test files. **Paired landings**: an engine fix with a kernel twin ships as the
engine stream's LumenCore half + I's `Kernels`/`RenderGraph` half, merged into one push,
because gpu-parity compares the two.

### Merge order
0. **U0 mockup published** (no code). Non-UI streams start regardless.
1. **L0** foundation split.
2. **J data-loss batch** — docs/31 #1 sidecar name collision, #2 export-preset `try?`,
   #4 strokes outside backup, #5 `backup()` never pruned; round-two #9 FTS never
   rebuilt, #10/#11 label and rating loss. One push.
3. **L recipe-safety batch** — #6 silent downgrade, #29 shared coalescing keys, #34
   dead wire-field decision; ships with regenerated fixtures.
4. **Engine window 1** — A, B, CD, E engine halves + I twins, ONE push. Must-land:
   round-two #1 grading-luminance inversion (345/810 combos invert), #6 guessed pivots,
   #2 Film Lab discarding the display transform, #5 log-luminance floor, docs/31
   #30 Contrast linear-not-log, #31 Zones past monotonicity. Then the proof ceremony;
   freeze `LumenCore/**` 80 min.
5. **During the freeze** (given the U0 yes): **U1 design system** first — one push,
   every panel changes look. Then U-PANELS (U2), U-SHELL (U3), H (U4 viewer + `⌘B`
   assessment, paired with U-SHELL's key moves), F1/F2 (U4 masks panel + canvas —
   the Lightroom-parity work, "everything in the circle"), K — 2–3 branches per push.
   Without the yes yet: F2 canvas logic, K, H non-visual, app-only J/CD commits.
6. **Engine window 2** — F3 (round-two #3 every masked export at 1/1024 resolution,
   docs/36 overlay-reads-render-alpha, bounded local adjust), I round-two #4 stale-table
   cross-photo door, second-round A/B/E, **film & grain** engine changes from R7/C1/C2,
   the denoise scaffold if R6 found a model, plus window-1's committed records.
   Ceremony; freeze.
7. **During freeze 2**: remaining UI landings, then **U5 polish and motion** last.
8. **Final quiet window** — window-2 records committed; no LumenCore pushes until
   `proof-linux` completes green; every lane green; `dev-latest` published.

### The proof-record ceremony (any landing that intentionally moves a control's response)
1. Stream commit message: `Proof: <ids> move deliberately — <reason>`; stream runs
   `swift test --filter ProofSmokeTests` locally (must stay green). Never sets
   `LUMEN_RECORD_PROOFS`.
2. Lead merges, triad, push, waits for `ci.yml` + gpu-parity green. The push-triggered
   `proof-linux` will go red on the declared ids after 75 min — expected, not a revert.
3. Lead dispatches **Proof sweep** on the branch with `record_proofs=true` (via the
   Actions API — no `gh` here). Freeze LumenCore pushes 80 min.
4. Download artifact `proof-records-linux`; unzip over `Tests/LumenCoreTests/Proof/records/`.
   `git status` must list **exactly** the declared ids — an undeclared file is a
   regression: revert that stream's commit, re-dispatch.
5. Commit the records alone, standard trailers, push. Fallback if the artifact is
   unreachable: the red check log prints each drifted record between
   `--- <id>.json ---` / `--- end <id>.json ---` (`ControlProofTests.swift:247–252`).

### The fixtures ceremony (any edit to the 20 mirrored files)
The 18 in `gen-fixtures.py`'s header **plus** `Catalog/Schema.swift` (DDL scraped as
text, `:1284`) and `Recipe/Recipe.swift` when `currentPipelineVersion` or any `Recipe()`
default moves (`:328–333`). In one commit: update the Python mirror; `python3
scripts/gen-fixtures.py`; `--check` must say "All fixtures match"; run the fixture
tests. New wire fields are **L-only** (mirror edit + regeneration + a `pipelineVersion`
decision); other streams request them.

### Per-stream brief (`briefs/w5-<stream>.md`)
Identity (worktree, branch, base SHA, never push) · files owned / read-only / forbidden
with owner id · findings by id with source, W3 verdict, and the acceptance test to
write · rules (docs/32 §0 rules 3,4,7,8,9 verbatim; no `pipelineVersion` bump; no new
wire field; no rename of any test in `ci.yml --skip`; no `provenance: .sensorCFA`
outside its one site; declare proof moves; rewrite tripwires with intent, never delete)
· local checks in order (parse → checker → `swift test --skip ControlProofTests` →
`--check` if mirrored → `ProofSmokeTests` if engine → `KeyGrammarTests|WorkspaceEntry
Tests|WorkspaceTests` if LumenApp; **check every `LumenSlider` call's argument order
against `LumenControls.swift:286`** — the checker cannot) · one commit per finding,
message names the id and states `response change: yes/no` · output ≤150 words + one
"owner should test:" line per fix + requests to other owners + anything abandoned.

### Failure protocol
- **build-macos red** (~2 min): fix-forward only if one file and mechanical; otherwise
  `git revert -m 1` within 15 min, hand the error to the stream. The revert is the next
  push.
- **test-fast / engine-linux red**: a tripwire → revert, stream rewrites the guard with
  intent; a behavioural test → the stream skipped the triad; revert, note it.
- **fixtures-linux red**: JSON merely stale with mirror updated → lead regenerates;
  else revert. **gpu-parity red**: reference and kernel diverged → revert, relaunch as a
  paired landing. **proof-linux red**: declared ids → ceremony; undeclared → revert.
- Waiting: poll at 2, 8, 12 min; if runners have not started by 20 min keep merging
  locally but do not push; cap 30 min.
- **Abandon a stream** after two reverts, two triad failures, or two edits outside
  ownership. Keep its branch; report it as "attempted, not landed".

### Deferred — not attempted unattended
Owner decisions (docs/29 ⚑ keymap rows; docs/36 #3 per-component refinement; docs/37
§5.3 Edge transfer graph; grain amplitude by eye; wire-field deletion) · model-dependent
(Sky/Object/Landscape/Depth kinds, AI denoise Tier 2 — R6 delivers the decision, not
the model; presets carrying masks) · needs a Mac in hand (Vision matte orientation,
eyedropper landing, `AppUpdater`, `InspectionGain` profiling, export holding the render
actor) · too wide for one lane (round-two #7 fp16 denomination; Texture band shape,
reverted twice; capture sharpening / Richardson–Lucy; navigator split blocked on
`refreshMaskThumbnails`; heal/clone; HDR viewport).

## How we know it worked

- **Per finding**: its test goes red with the defect substituted back and green with the
  fix (the stream proves it; the W6 re-audit checks it).
- **Per landing**: five `ci.yml` lanes + gpu-parity green on the pushed SHA before the
  next merge; `--check` clean; the `dev-latest` release body carries the SHA.
- **Per engine window**: proof records re-recorded for exactly the declared ids;
  `proof-linux` green in the final quiet window.
- **Whole grind**: `w0/perf-baseline.md` vs the W6 re-run (PerfProbe, DragProbe) — no
  regression; every landed change has a what-to-test line the owner can act on; every
  known-open row in `ledger.md` has a disposition (LANDED / STILL-OPEN-with-reason /
  DEFERRED-owner-decision / REJECTED-was-not-a-bug).
- **What the owner does**: install `dev-latest`, work down the what-to-test list in
  `docs/38-the-grind.md`, and answer the decisions section.

## W6 — Close (3 agents + me, ~2 h)

1. **Re-audit of landed work**: one agent per landed stream reads each fix against its
   finding: does the change do what the finding asked, is the test present and does it
   go red with the defect substituted back, is the checker clean, does the landing's
   "what to test" line describe something the owner can actually see.
2. **Perf after**: dispatch gpu-parity on the final commit; compare PerfProbe / DragProbe
   against `w0/perf-baseline.md`; regressions are S1 and get fixed or reverted before
   the report.
3. **The report** (`docs/38-the-grind.md` + a published artifact): per area — what
   landed with a what-to-test line each; what was found and not landed, with the
   proposal and the reason; **decisions only the owner can make** (keymap `1–4` vs
   ratings and ⌘K vs keyword from docs/29; Cull's one-way door from docs/30 §7.7; the
   denoise direction from R6; model-dependent mask kinds); perf before/after; the
   risk list. STATUS.md closes with the final commit.

## Resilience — how it survives a reset, a compaction, or a bad landing

- **Everything is a file in the repo.** Agent outputs, briefs, ledger, stream states,
  STATUS.md. Committed at every wave boundary and after every landing. A reset costs at
  most one in-flight wave; a compaction costs nothing (the next me reads STATUS.md).
- **Resume protocol** (top of STATUS.md): fetch origin → reset to origin branch → read
  STATUS.md → relaunch the named briefs whose outputs are missing.
- **Agents never push.** Only the lead pushes, only to the designated branch, only
  after the triad, only when CI is green on the previous landing.
- **Timeboxes**: research 25 min, audit 30 min, verify 10 min per finding, implement
  60 min per stream. An agent past its box is stopped; its partial file is kept and
  marked PARTIAL.
- **Usage**: observed cost this session ≈130–180k tokens per thorough explorer. Rough
  total: research ≈1.2M, audit ≈4.5M, verify ≈2.5M, implement ≈4–5M, close ≈1M — well
  inside the owner's stated budget, with headroom for re-runs.

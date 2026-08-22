# 11 — Output & Export

Export is where three of Lumen's bets pay off at once. First, the **multi-recipe export model**
(D40): Capture One's Process Recipes are the single best workflow idea in pro raw software that
Lightroom Classic has never copied — one click, every deliverable. Second, **automated output
sharpening** (D24/D41): the Fraser/PhotoKit doctrine that output sharpening is a computation from
size and medium, not a parameter farm — the pattern Adobe itself licensed into Lightroom. Third,
**HDR stills as a headline feature** (D42): gain-map authoring with a deliberate SDR rendition and
an honest delivery preview, built on macOS APIs that no cross-platform competitor can match and
that Capture One 16.8.4 does not attempt at all.

Scope boundaries: the sharpening *model* (three-pass doctrine, RL deconvolution, halo suppression)
is owned by `docs/06-spec-detail.md`; this doc owns the output pass only. The display transform and
its peak parameterization are owned by `docs/04-spec-tone.md` and staged in `docs/14-pipeline.md`.
Gamut-mapping math is owned by `docs/05-spec-color.md`. Export-recipe storage, naming-token grammar
shared with ingest, and the queue's persistence live in `docs/15-catalog.md` and
`docs/10-spec-library.md`. Latency doctrine (nothing synchronous on the input path, D43) is
`docs/12-spec-ux.md`; this doc states the budgets it owes that contract.

Five commitments govern everything below:

1. **One click, many outputs.** An Export click renders every checked recipe. Delivering a wedding
   as full-res TIFF archive + 2048px client JPEG + HDR HEIC is one gesture, not three passes
   through a dialog.
2. **Output sharpening is automated.** The user picks medium and strength (Screen/Matte/Glossy ×
   Low/Standard/High); the engine computes radius and halo energy from final pixel dimensions.
   No sharpening sliders exist in the export UI.
3. **The SDR rendition is always deliberate.** Every HDR export carries an SDR base image the user
   has seen and can trim — never an automatic tone-map surprise. "Great HDR requires a great SDR
   in the gain map" (Greg Benz's doctrine, adopted verbatim).
4. **Export is a pure function that never blocks.** Rendering an export is the same pure
   recipe→pixels function as the viewport (D49: export reuses the interactive pipeline-prefix
   cache), run on a background queue. The UI thread never waits on an encode.
5. **One display transform, peak-parameterized (D8).** SDR export renders at peak 1.0; HDR export
   renders the identical transform at peak >1.0. HDR is not a second pipeline bolted on — that is
   the architectural fact that makes everything in the HDR section cheap.

The Export window, structurally:

```
┌─ EXPORT ──────────────────────────────────────────────────────────┐
│ RECIPES                      │ SETTINGS — "Client JPEG 2048"      │
│ ☑ Client JPEG 2048           │  Format   JPEG   Quality 90        │
│ ☑ TIFF 16-bit archive        │  Size     Long edge 2048 px        │
│ ☑ HDR HEIC                   │  Color    sRGB                     │
│ ☐ Ultra HDR JPEG             │  Sharpen  Screen · Standard        │
│ ☐ Web 1600 watermarked*      │  Naming   {date}_{name}_{seq3}     │
│   [+ New] [Duplicate]        │  Into     ~/Deliveries/{job}/jpeg  │
│                              │  Metadata Copyright only · GPS ✗   │
│ 214 photos · est. 1.9 GB     │  After    Open in Finder           │
│                    [Export]  │  *watermark: reserved, post-v1     │
├───────────────────────────────────────────────────────────────────┤
│ QUEUE  ▶ TIFF archive 87/214 ━━━━━━━──── ‖ ⨯   ↑↓ reorder        │
└───────────────────────────────────────────────────────────────────┘
```

---

### Export recipes

**What it is.** A recipe is a stored, named output definition — format, quality, size, color
space, output sharpening, naming, destination, metadata policy, and a reserved watermark slot.
Recipes appear as a checkbox list; one Export click renders every checked recipe for every
selected photo (D40). This is Capture One's Process Recipe model, adopted whole.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Recipe checkboxes | 0–n checked | last used | Checked set persists per catalog |
| Format | JPEG / HEIF / TIFF / PNG | JPEG | Per-recipe; see Output formats |
| Quality | 0–100 | JPEG 90, HEIF 85 | Hidden for TIFF/PNG |
| Size | none / long edge / short edge / W×H / MP / % | none | "Don't enlarge" on by default |
| Color space | sRGB / Display P3 / Adobe RGB / Rec.2020 / custom ICC | sRGB | Custom ICC unlocks intent + BPC controls |
| Output sharpening | Screen–Matte–Glossy × Low–Std–High, or Off | Screen · Standard | See Output sharpening |
| Naming | token template | `{name}` | Shared token engine with ingest (D38) |
| Destination | folder / subfolder-of-original / ask | ask | Path accepts tokens |
| Metadata | All / Copyright+contact / Copyright only / None | Copyright+contact | Separate "Strip GPS" toggle, default on |
| After export | nothing / reveal in Finder / open with app | reveal | Per-recipe open-with, C1 parity |

**How it works.** Recipes are rows in the catalog (schema in `docs/15-catalog.md`), distinct from
*edit* recipes — an edit recipe describes pixels, an export recipe describes containers. Four
starter recipes ship: Full-size JPEG (sRGB), Client JPEG 2048, TIFF 16-bit archive, HDR HEIC.
Rendering is shared across checked recipes per photo: the pipeline renders the full-resolution
master once (reusing the interactive cache when warm, D49), then forks per recipe at the resize
node — resize, output-sharpen, gamut-map, encode. Three checked recipes cost one develop render
plus three cheap tails, not three renders.

> **Not built.** The gesture ships; the sharing does not. `AppStateActions.export` loops photos ×
> recipes and each iteration calls `PipelineRenderer.export`, which builds a fresh `RenderGraph`
> and renders the full develop chain end to end — three checked recipes cost three full renders.
> Only the decoded `CIImage` is reused, from `ImageSource`'s cache. Three shipping files asserted
> the sharing as fact until this was checked, so the note is here rather than in a comment
> somewhere: this paragraph is the design, and it is still wanted.
>
> The fork point is already the right one — everything from `applyGeometry` down in
> `PipelineRenderer.export` is the tail. What makes it more than a refactor is that `RenderPlan`
> is built from `exportRecipe.renderWhiteTargetPercent`, so recipes with different HDR white
> targets cannot share a master and the reuse has to be keyed on that. And the payoff needs
> measuring on a Mac before any number is claimed for it: Core Image's own intermediate caching
> may already recover some of the sharing at runtime, which would make the saving smaller than
> the graph structure suggests.

**How it feels.** `⌘⇧E` opens Export (LrC muscle memory); `⌥⌘⇧E` exports again with the last
checked set and no dialog — the daily-driver gesture once recipes are set up. The recipe list
shows a live estimate of file count and total size for the current selection. Editing a recipe
edits it everywhere; there is no dialog-local state to lose. Checkbox toggles and setting edits
are instant (<100 ms, D43 discrete-action budget).

**Vs. the field.** **Better than Lightroom Classic 15.5 because** LrC's single-dialog export
renders one output definition per pass; multiple deliverables mean re-opening the dialog or
juggling plugins, and working photographers have asked for simultaneous multi-format export for
over a decade. **Equal to Capture One 16.8.4 because** this is C1's model matched feature-for-
feature (per-recipe format/ICC/resize/naming/destination/sharpening/open-with, background queue) —
and better in one respect: Lumen recipes can be HDR (gain-map HEIC/JPEG), which C1 cannot produce
at all.

---

### The export queue

**What it is.** A background queue that renders and encodes all export jobs with per-job pause,
cancel, and drag-reorder — visible as a toolbar progress pill that expands into a queue drawer.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Reorder | drag rows | — | Priority changes take effect at the next photo boundary |
| Pause / resume / cancel | per job | — | Cancel keeps already-written files |
| Parallel workers | 1–4 | 2 | Advanced preference; workers = full render lanes |

**How it works.** Jobs run at utility QoS on dedicated Metal command queues so viewport rendering
always wins contention (D43: nothing synchronous on the input path; the D30 rule that background
work never blocks the UI applies verbatim). Budget: a 45MP JPEG export completes in ≤2 s per
worker with a warm cache — an 800-frame event delivery in roughly 13 minutes on two workers while
the user keeps culling the next job. The queue persists in the catalog: quitting mid-export resumes
on relaunch, with already-written files verified by size + mtime before skipping. Failures surface
per photo with the actual reason (disk full, permission denied, unwritable ICC) and a retry button
— honest error surfaces, never "Something went wrong" (D30).

**How it feels.** Export never takes over the app. The pill shows aggregate progress; the drawer
shows per-recipe rows with thumbnails of the photo currently encoding. A completion notification
(macOS Notification Center) links to the destination folder.

**Vs. the field.** **Equal to Capture One 16.8.4 because** C1's background processing queue with
reorder/pause is the reference and Lumen matches it, adding crash-safe resume. **Better than
Lightroom Classic 15.5 because** LrC's export progress bar offers cancel-only control, no reorder,
no pause, and no persistence across relaunch.

---

### Output formats

**What it is.** The container matrix: JPEG for universality, HEIF for the Apple ecosystem and
10-bit, TIFF for archival and round trips, PNG as a niche lossless option.

**Controls.** (Per-recipe; only options meaningful for the chosen format are shown.)

| Format | Bit depth | Options | Notes |
|---|---|---|---|
| JPEG | 8-bit | Quality 0–100 (default 90); 4:4:4 chroma at ≥90, 4:2:0 below | Optional Ultra HDR gain map (HDR section) |
| HEIF (HEIC) | 8- or 10-bit | Quality 0–100 (default 85); 10-bit toggle | Gain-map HDR or 10-bit PQ (HDR section) |
| TIFF | 8- or 16-bit | ZIP / LZW / none (default 16-bit ZIP) | The archive and round-trip master |
| PNG | 8- or 16-bit | — | Lossless interchange; 16-bit PNG is legal ISO HDR |

**How it works.** All encodes go through ImageIO/Core Image: 8-bit targets are dithered from the
f32 pipeline during quantization to prevent gradient banding; 10-bit HEIF uses
`CIContext.writeHEIF10RepresentationOfImage` (macOS 12+). **AVIF status:** ImageIO encode
availability is unverified on the target OS — checked at runtime via
`CGImageDestinationCopyTypeIdentifiers`, with a libavif/libaom fallback planned only if demand
materializes; AVIF gain-map encode exists in libultrahdr v2.0.0 if we want it later. **JPEG XL
status:** LrC exports HDR JXL, but decode support outside Adobe's ecosystem remains thin; Lumen
watches and does not ship JXL in v1. **No DNG export, no PSD:** Lumen has no layers to serialize,
and portability of edits is the job of recipes + XMP sidecars (`docs/15-catalog.md`), not
LrC 15.5-style flattened render-to-DNG; a 16-bit TIFF covers every interop case a DNG would.

**How it feels.** Format is one popup per recipe. No format decision ever appears outside the
recipe editor.

**Vs. the field.** **Equal to Capture One 16.8.4** (JPEG/TIFF/PNG parity; C1 adds DNG/PSD out,
which Lumen consciously skips as stated above). **Consciously narrower than Lightroom Classic 15.5
because** LrC exports PSD, DNG, AVIF, and JXL; Lumen trades that breadth for first-class HEIF —
which LrC still lacks as an export format — and bets that JPEG/HEIF/TIFF covers 100% of a working
photographer's deliveries. The tradeoff is explicit and revisitable per format.

---

### Naming, destination, and metadata

**What it is.** Token-template file naming and destination paths, plus a per-recipe metadata
policy — the same token engine the ingest renamer uses (D38, `docs/10-spec-library.md`).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Name template | token string | `{name}` | Live preview against the first selected photo |
| Sequence start | 1–999999 | 1 | `{seq}`/`{seq3}`/`{seq4}` zero-padded variants |
| Destination path | folder + optional token subpath | — | e.g. `~/Deliveries/{job}/{recipe}` |
| Collision policy | rename / overwrite / skip | rename | Rename appends `-2`, `-3`… |
| Metadata level | All / Copyright+contact / Copyright only / None | Copyright+contact | IPTC template written on export |
| Strip GPS | on / off | on | Client-safe by default |

**How it works.** About a dozen tokens: `{name}` `{seq}` `{date}` `{time}` `{yyyy}` `{mm}` `{dd}`
`{camera}` `{lens}` `{iso}` `{rating}` `{label}` `{recipe}` `{job}` plus literal text. One grammar,
two homes (ingest rename and export naming), one implementation. Metadata writes are IPTC/XMP via
ImageIO from a write-on-export template (owner identity, copyright line, contact) — Lumen has no
in-catalog IPTC editing UI in v1, per the v1 scope call that a write-on-export template is enough.

**How it feels.** The template field autocompletes tokens on `{`; the preview row updates on every
keystroke. Bad templates (illegal characters, empty result) refuse the Export button with the
reason inline.

**Vs. the field.** **Equal to Capture One 16.8.4** (token naming + token destinations are C1's
strength, matched). **Better than Lightroom Classic 15.5 because** LrC's rename template editor is
a modal sub-dialog with clumsy custom-text handling, and its export cannot token-build destination
subfolders.

---

### Output sharpening

**What it is.** The third Fraser pass (D24): fully automated sharpening computed from final output
size, medium, and strength choice at export time. Nine states — Screen/Matte/Glossy ×
Low/Standard/High — and Off. No radius, no amount, by design.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Medium | Screen / Matte / Glossy | Screen | Per-recipe |
| Strength | Low / Standard / High | Standard | Per-recipe |
| Off | toggle | off (i.e. sharpening on) | For files headed to further retouching |

**How it works.** This is the PhotoKit Sharpener lineage — the engine Fraser built and Adobe
licensed into Lightroom's export, which is the strongest possible validation that a 3×3 choice
matrix is the right surface. Sharpening runs *after* resize, on final pixels, in the luminance
channel of the resized image. Radius is computed from output pixel density: the print target is
Fraser's halo rule — halos ~1/50"–1/100" wide at the print's PPI — so a 300 PPI matte print gets a
larger radius and more aggressive edge contrast (matte paper's ink spread eats fine halos) than
glossy, which gets tighter halos, while Screen targets ~1-pixel halos at display scale. Internally
the light and dark halo contours carry independent weights (dark halos offend more than light
ones — PhotoKit's core insight) tuned per medium; that asymmetry is deliberately never surfaced
(D25's lesson: ship the presets, never the math). Strength scales halo energy ±1 perceptual step.
Downscaling itself is Lanczos-3 in linear light before sharpening, per Poynton's rule that
resampling is physical math and belongs in linear.

**How it feels.** Two popups in the recipe editor. The soft-proofing print-size preview (next
entries) renders the *actual* resized-and-sharpened result so the choice can be judged before
export, at Schewe's 50%/25% zoom doctrine — never at 100%, where output sharpening always looks
overdone.

**Vs. the field.** **Equal to Lightroom Classic 15.5 by design** — LrC ships this exact licensed
pattern (Screen/Matte/Glossy × Low/Standard/High) and matching it preserves a proven contract.
**Better than Capture One 16.8.4 because** C1's per-recipe output sharpening exposes amount-style
controls that reintroduce the parameter farm Fraser's research closed, and Lumen's print-size
proofing loop lets the user *see* the Standard-vs-High decision instead of guessing.

---

### Color-managed export

**What it is.** Per-recipe destination color space with correct, hue-preserving gamut mapping from
the linear Rec.2020 working space — and no color-management picker anywhere else in the app (D21).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Color space | sRGB / Display P3 / Adobe RGB (1998) / Rec.2020 / custom ICC | sRGB | Custom ICC targets printer/paper profiles |
| Rendering intent | Perceptual / Relative Colorimetric | Rel. Colorimetric | Shown only for custom ICC |
| Black point compensation | on / off | on | Shown only for custom ICC |

**How it works.** The pipeline runs the display/output transform at the recipe's peak (1.0 for
SDR), then gamut-maps into the destination space using the ACES-2.0-style hue-preserving
compressor specified in `docs/05-spec-color.md` — compression along constant-hue lines toward a
per-hue focus point, so saturated blues do not go purple on the way to sRGB. Matrix spaces
(sRGB/P3/Adobe RGB/Rec.2020) are tagged with standard ICC profiles; custom ICC output goes through
ColorSync with the chosen intent + BPC for print workflows. 8-bit encodes are dithered.

**How it feels.** One popup for most users, who never leave sRGB. The print controls appear only
when a custom profile is chosen — progressive disclosure per D3.

**Vs. the field.** **Equal to Lightroom Classic 15.5 and Capture One 16.8.4** on the checkbox
level (all three export to arbitrary ICC), **better in rendering quality because** neither
competitor documents or guarantees hue-preserving gamut compression on export; LrC's
relative-colorimetric clip visibly hue-shifts deep blues and saturated reds delivered to sRGB, a
long-standing complaint Lumen's compressor removes by construction.

---

### Soft proofing and print-size preview

**What it is.** A viewport mode that previews a specific export recipe — profile, intent, resize,
and output sharpening — with out-of-gamut warnings and a physically honest print-size zoom. Schewe
doctrine (*The Digital Print*), implemented whole.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Soft proof toggle | on / off | off | Key: `S` in develop |
| Proof target | any export recipe or bare profile | last used | Proofing a recipe includes its resize + sharpening |
| Gamut warning | on / off | off | Destination-gamut overlay, marching-ants-free solid tint |
| Display gamut warning | on / off | off | Flags colors the *monitor* cannot show |
| Simulate paper & ink | on / off | off | Paper-white + black-density simulation for print ICC |
| Zoom presets | Fit / 100% / 50% / 25% / Print size | Fit | Print size maps print inches to screen inches via display PPI |

**How it works.** Soft proof renders the normal pipeline, then the proof transform
(working → output profile → intent/BPC → back to display), so what is on screen is the export,
not an approximation. Proofing a *recipe* additionally runs the resize + output-sharpening tail at
the recipe's pixel dimensions, cached and recomputed asynchronously on parameter change. Gamut
warnings compute per-pixel in the destination space. "Print size" zoom uses the recipe's PPI and
the display's physical PPI so a 360mm print edge occupies 360mm of screen.

**How it feels.** `S` toggles instantly (≤100 ms; the proof transform is a cached LUT). The proof
state is a viewing mode, not an edit — Lumen creates no LrC-style "proof copy" ceremony; if the
user wants a print-specific variant, virtual copies (D39) are one keystroke. The gamut overlay
plus the Zones panel makes fixing an out-of-gamut red a 10-second operation.

**Vs. the field.** **Better than Lightroom Classic 15.5 because** LrC's soft proofing nags the
user into creating proof copies, cannot preview output sharpening at all, and hides print-size
judgment behind manual zoom math. **Better than Capture One 16.8.4 because** C1's recipe proofing
previews resize and compression but ships no print-size zoom and no display-gamut warning. Nobody
in the field implements Schewe's full doctrine; Lumen does.

---

## HDR output — the headline

The market context, verified: LrC's HDR editing is praised and its HDR *delivery* is the pain —
exports "look flat/washed out" in non-HDR apps, browser support is fragmented, Instagram handling
is flaky, and photographers discover this after shipping. Capture One has no HDR stills story at
all. Meanwhile every iPhone photo carries a gain map, Apple's Adaptive HDR APIs (macOS 15+) are
complete, and displays with 2–16× headroom are the Mac default. A macOS-native editor that authors
gain maps correctly *and shows the photographer exactly what every viewer will see* wins this
category outright. The r11 synthesis — the five things an editor must do — is the spec here:
scene-referred unclamped pipeline; deliberate SDR base + derived HDR rendition + computed gain
map; the full export matrix; live headroom-adaptive preview; an SDR-proof toggle.

### HDR export (gain-map authoring)

**What it is.** Per-recipe HDR output in four containers: gain-map HEIC (primary), Ultra HDR JPEG
(universal), 10-bit PQ HEIF and 16-bit TIFF (secondary, absolute HDR). The SDR rendition is the
base image in the gain-map formats and is always the deliberate, user-visible SDR grade — never an
automatic tone-map.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| HDR format | Gain-map HEIC / Ultra HDR JPEG / PQ HEIF 10-bit / TIFF 16-bit | Gain-map HEIC | Per-recipe |
| HDR peak | +0.5…+4.0 EV above SDR white | +2.0 EV (4×) | The rendered HDR rendition's ceiling; maps to max_content_boost |
| SDR trim — Exposure | ±1.0 EV | 0 | Applied to the SDR rendition only |
| SDR trim — Contrast | ±50 | 0 | SDR rendition only |
| SDR trim — Highlights | ±50 | 0 | SDR rendition only |
| Gain map resolution | full / half / quarter | quarter | Quarter-res ≈ 10–15% file overhead at quality 85–90 |

**How it works.** Apple's WWDC24 edit-strategy #3, the one they recommend for pro editors: render
the SDR and HDR renditions separately, recompute the gain map on save. Both renditions come from
the *same* display transform (D8) — SDR at peak 1.0 (plus trims), HDR at the recipe's peak — so
they agree by construction; the gain map then encodes per-pixel
`recovery = clamp((log2(pixel_gain) − log2(min_boost)) / (log2(max_boost) − log2(min_boost)))^map_gamma`
with `pixel_gain = (Y_hdr + 1/64)/(Y_sdr + 1/64)`, map_gamma 1.0 — the ISO 21496-1 / Ultra HDR
math exactly. Encoders: **HEIC** via Core Image's
`writeHEIFRepresentation(... options: [.HDRImage:])`, which computes and embeds the ISO 21496-1
gain map from the SDR/HDR pair (macOS 15+ Adaptive HDR); **Ultra HDR JPEG** via libultrahdr
v2.0.0 (Aug 2026; permissive Apache-2.0-family — exact dual-licensing wording to be pinned in the
`docs/17-appendix.md` license ledger), writing both ISO 21496-1 and legacy XMP metadata so Android
15+ and older readers both resolve it; **PQ HEIF** via `writeHEIF10RepresentationOfImage` with a
BT.2100 PQ color space, and **16-bit TIFF** — both legal ISO/TS 22028-5 absolute-HDR containers
(BT.2020, ≥10-bit, diffuse white 203 cd/m²; 8-bit JPEG is excluded from 22028-5, which is exactly
why the JPEG path must be a gain map). Note ISO 21496-1 was at Committee Draft as of WWDC24 and is
implemented by Apple, Adobe, and Android; its final publication date was not re-verified this
research cycle.

**How it feels.** An "HDR" badge on the recipe row makes gain-map recipes recognizable at a
glance. The SDR trim sliders live under a disclosure with a split preview: left SDR rendition,
right HDR rendition, so the photographer grades the pair as a pair. The **delivery preview** popup
in soft-proof mode renders the export through the actual decode math — the file is encoded, then
decoded at a simulated display headroom using the Ultra HDR weight_factor formula
(`clamp((log2(max_display_boost) − hdr_capacity_min)/(hdr_capacity_max − hdr_capacity_min))`) —
with three stops: *This display* (live headroom), *Low headroom* (2×, a typical SDR-panel-plus
laptop), and *SDR only* (1.0, what a non-HDR-aware app shows: exactly the base rendition). What
LrC users discover on Instagram, Lumen users see before export.

**Vs. the field.** **Better than Lightroom Classic 15.5 because** LrC's editing side is matched
(deliberate SDR via its "Preview for SDR display" sliders) but its delivery side is not: LrC has
no simulated-headroom preview, no decode-what-you-encoded verification, and its gain-map JPEG
flavor has documented ecosystem mismatches — Lumen previews the failure modes instead of shipping
them. HEIC gain-map export with Apple's own encoder also lands correctly in Photos/Quick
Look/Messages, where Adobe's flavor has historically been inconsistent. **Better than Capture One
16.8.4 because** C1 has no HDR output whatsoever — a deal-breaker C1's own landscape users cite.

---

### The EDR editing viewport

**What it is.** The requirement that makes HDR authoring honest: the develop viewport renders
fp16 extended-linear through a `CAMetalLayer` with EDR enabled, tone-mapping live against the
display's actual headroom — so the photographer edits real HDR, not a simulation.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| SDR-proof toggle | on / off | off | Clamps tone-map peak to 1.0; toolbar button + `⌥H` |
| Visualize HDR | on / off | off | False-color overlay: stops above SDR white |
| Headroom readout | display | — | Current display headroom in stops, in the histogram header |

**How it works.** The viewport layer sets `wantsExtendedDynamicRangeContent = true` and renders
fp16 extended-linear (D42/D48). CAMetalLayer does **no** tone mapping — values beyond the
display's max simply clamp — so Lumen's display transform is responsible: it runs at
`min(image peak, display headroom)` where headroom is
`NSScreen.maximumExtendedDynamicRangeColorComponentValue`, re-read on
`NSApplication.didChangeScreenParametersNotification`. Because the transform is peak-parameterized
(D8), "adapt to headroom" is a parameter change, not a code path. When the OS steps headroom
(ambient light, window moved between displays, EDR ramp-up from 1.0 when HDR content first
appears), Lumen interpolates its peak target over ≤300 ms so the image slews smoothly instead of
jumping — the D43 one-frame rule holds throughout because the transform runs per frame anyway.
Typical panels: ~2× headroom on SDR-class displays, 8–16× on XDR MacBook Pro panels.

**How it feels.** HDR photos simply look HDR while editing, on any Mac with headroom — no mode
switch, no "HDR button" ceremony (LrC requires one). The histogram extends above SDR white with a
marked boundary (histogram spec: `docs/04-spec-tone.md`). `⌥H` snaps to the SDR rendition for
grading the base image; Visualize HDR answers "how far above white is that window?" in false
color. The Zones panel's stop-denominated controls (D7) make pulling an HDR peak down one stop a
literal −1.0 entry.

**Vs. the field.** **Better than Lightroom Classic 15.5 because** LrC's HDR mode is opt-in per
photo, its EDR handling on macOS is a compatibility layer over a cross-platform renderer, and it
offers no smooth-slew guarantee (headroom changes visibly pop). **Better than Capture One 16.8.4
because** C1 has no EDR viewport at all. This is the purest macOS-native advantage in the product:
the entire feature is four Apple APIs and a parameter Lumen's transform already has.

---

### Batch export and export presets

**What it is.** Export over any selection, collection, or filter result — and the recognition that
recipes *are* the presets. There is no separate "export preset" object to manage.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Scope | selection / collection / filter result | selection | Export acts on what the grid shows selected |
| Recipe sets | named groups of checked recipes | — | e.g. "Wedding delivery" checks 3 recipes at once |

**How it works.** One recipe list, one checkbox state, optional named sets for one-gesture recall
of a checked combination. Because recipes live in the catalog, they sync nowhere and export
everywhere — no LrC-style divergence between "export presets," "publish services," and "print
module" as three different serializations of the same intent. Virtual copies (D39) export as their
own photos; a filter-bar query (`docs/10-spec-library.md`) plus `⌥⌘⇧E` is the "export all 5-star
picks as client JPEGs" gesture, four keys total.

**How it feels.** Identical to single-photo export; scale changes the queue, not the UI.

**Vs. the field.** **Better than Lightroom Classic 15.5 because** LrC splits batch delivery
across Export, Publish Services, and plugins; Lumen has one grammar. **Equal to Capture One
16.8.4**, whose recipe model this extends with named recipe sets.

---

### External-editor round trip

**What it is.** `⌘E` renders a 16-bit TIFF and opens it in a chosen external editor (Photoshop,
Affinity-successor, Pixelmator-lineage apps); the saved result lands back in the catalog, stacked
with the original.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Editor | any app accepting TIFF | asked once, remembered | Per-catalog setting |
| Bit depth / space | 16-bit TIFF, Rec.2020 / Display P3 / Adobe RGB | 16-bit Rec.2020 | ICC-tagged; ZIP-compressed |

**How it works.** The round-trip file is display-referred SDR (the external editor edits what the
user saw), rendered at full resolution with output sharpening off, written as
`{name}-Edit.tif` beside the original, auto-imported, and stacked (D39). A file-presence watcher
re-generates the preview when the external editor saves. The TIFF is a new master: subsequent
Lumen edits apply on top of it non-destructively like any other file. HDR round-tripping
(float TIFF) is explicitly out of scope for v1.

**How it feels.** `⌘E`, edit, `⌘S`, switch back — the stack badge shows the pair; no re-import
ceremony.

**Vs. the field.** **Consciously worse than Lightroom Classic 15.5 because** LrC's Photoshop
integration re-opens layered PSDs and offers "Edit Original" semantics; Lumen ships a flattened
TIFF hand-off, accepting the tradeoff because a one-photographer workflow needs the round trip
weekly, not the layer fidelity — and building PSD round-tripping would tax the schedule of
features that differentiate. Revisit if usage proves otherwise. **Equal to Capture One 16.8.4**,
whose Edit With / Open With is the same flattened-file pattern.

---

### Watermarking — deferred, stated

**What it is.** Not in v1. The recipe schema reserves a watermark slot (type, text/graphic asset,
anchor position, opacity, scale) so recipes never migrate when it ships; the roadmap phase is
owned by `docs/16-roadmap.md`.

**Controls.** None in v1; the recipe editor shows the slot as "Watermark: none (planned)".

**How it works.** When built: compositing after resize and before output sharpening, so the mark
is sharpened with the image and sized in output pixels. Until then, the per-recipe open-with hook
covers the rare need via an external tool.

**How it feels.** Absent, honestly — a labeled gap, not a hidden one.

**Vs. the field.** **Consciously worse than Lightroom Classic 15.5 and Capture One 16.8.4** —
both ship per-export watermarking today. The owner's delivery workflow does not watermark;
schema-reserving the slot makes this a deferral, not a redesign. If client-proofing galleries ever
enter scope, this moves up.

---

## Budgets this doc owes `docs/12-spec-ux.md`

| Action | Budget |
|---|---|
| Export dialog open, recipe toggle, setting edit | ≤100 ms |
| Soft proof toggle (`S`), SDR-proof toggle (`⌥H`) | ≤100 ms |
| Delivery-preview mode switch | ≤200 ms (encode+decode at preview resolution) |
| Display headroom change → viewport settled | smooth slew ≤300 ms, no frame drops |
| 45MP JPEG export, warm cache | ≤2 s per worker |
| Export impact on viewport interaction | zero — one-frame rule holds during export |

Every number is a release-gate measurement, not an aspiration (D47).

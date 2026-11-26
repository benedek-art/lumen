# Render lab

Render (photo, recipe) jobs and get back PNGs, measurements and labelled contact sheets.
Two renderers, one manifest format, one stats implementation (`Sources/LumenCore/RenderLab`):

| path name | renderer | where | what it is |
|---|---|---|---|
| `export` | `PipelineRenderer.export` → PNG 8-bit sRGB | macOS runner | **shipping**: the file the app writes |
| `settled` | `PipelineRenderer.renderPreviewDelivery(draft: false)` | macOS runner | **shipping**: the viewer at rest |
| `draft` | `renderPreviewDelivery(draft: true)` | macOS runner | **shipping**: the viewer mid-drag (colour tables may be stale, as in the app) |
| `reference` | `ReferenceRenderer` (CPU, f32) | Linux (CI or this container) | **reference, not shipping**: same maths, different implementation |

Every sheet title says which path made it. A reference render is evidence about the maths,
never about what the app ships; check anything you rely on with the `drift` comparison.

## 1. Write a manifest

```json
{
  "name": "my-check",
  "defaults": {"longEdge": 1536, "paths": ["export"], "tile": 300},
  "luts": {"lab:warm-teal": "../luts/lab-warm-teal.cube"},
  "jobs": [
    {"id": "exposure", "photos": ["6929", "chart:greyRamp"], "paths": ["export", "settled"],
     "sweep": {"path": "develop.tone.exposure", "values": [-2, -1, 1, 2], "neutral": 0}},
    {"id": "film", "photo": "6929",
     "grid": {"x": {"path": "look.filmLab.grain.amount", "values": [0, 40, 80]},
              "y": {"path": "look.filmLab.stock", "values": ["lumen/portra400", "lumen/trix400"]}}},
    {"id": "nr", "photo": "2607", "crop": [0.4, 0.4, 0.12, 0.12], "compare": ["settled", "export"],
     "variants": [{"label": "off", "recipe": {"develop.denoise.mode": "off"}},
                  {"label": "luma 60", "recipe": {"develop.denoise.classic.luma": 60}}]},
    {"id": "one", "photo": "5812", "recipe": {"develop.tone.contrast": 30, "look": {"vignette": -1}}}
  ]
}
```

Job keys (unknown keys are an error):

- `id` (letters, digits, `._-+`), `photo` or `photos` (see §3), `description`.
- `recipe`: sparse patch over the base recipe, using the recipe's JSON field names, nested
  (`{"develop": {"tone": {"exposure": 1}}}`) or dotted (`"develop.tone.exposure": 1`). Numeric
  segments index arrays (`"look.bw.bands.2": 40`, `"develop.mixer.bands.0.sat": -30`). An
  absent optional block (`look.filmLab`, `look.grain`, `look.bw`) is created with defaults.
  A path the recipe does not have is an error (the recipe decoder would otherwise drop it
  silently). A value the decoder changes is reported under `recipeAdjusted` in the stats.
  **Every field, with range and default: [CONTROLS.md](CONTROLS.md).**
- `base`: `imported` (default: what the app gives a new file, including ISO-based noise
  reduction) or `blank` (`Recipe()`).
- `sweep`: `{"path" | "paths", "values" | "from"/"to"/"steps", "label", "neutral"}`. Renders
  one tile per value plus a reference tile (the job `recipe`, with `neutral` written to the
  path if given) that every delta is measured against. Values may be strings (stocks, presets).
- `grid`: `{"x": <sweep>, "y": <sweep>}`: x across, y down.
- `variants`: `[{"label", "recipe"}]`: explicit patches, each merged over the job `recipe`.
- `longEdge` (default 1024), `draftLongEdge`, `paths`, `tile` (sheet tile px), `columns`.
- `crop`: `[x, y, w, h]` unit rectangle, top-left origin: **1:1**. `export` crops in the
  recipe and delivers the crop at native pixels; `settled`/`draft` render the same rectangle
  as a region of the native frame (the app's zoomed viewer). Reference path: use crop plates.
- `compare`: two paths, e.g. `["settled", "export"]`: renders both at matched scale and
  reports what the viewer showed against what export delivered (`compare.tsv`, a sheet).

Top level: `name`, `defaults` (any job key), `photos` (default photo list), `luts`
(ref → `.cube` path relative to the manifest; then `"look.lut": {"ref": "lab:warm-teal",
"name": "x", "tap": "display"|"log", "amount": 0-100}`).

Committed manifests: `manifests/smoke.json`, `proof-core.json` (tone, WB, saturation, film,
sharpening), `creative-stack.json` (NR modes, capture sharpening, grain, every stock, halation,
LUTs, display transforms, B&W, wheels, colour balance, printer lights, curves, vignette,
presence), `drift-sample.json`.

## 2. Run it on GitHub (shipping path, and reference at scale)

Workflow `.github/workflows/render-lab.yml`. Two ways in:

**A. Request file (works with push access only).** On your branch, write
`docs/renderlab-request.json` and push. Changing only that file fires only this workflow.

```json
{"manifests": "proof-core,creative-stack", "lane": "both", "shards": 6,
 "drift": "drift-sample", "manifest": {"jobs": [ ... inline jobs ... ]}}
```

**B. workflow_dispatch** (needs an Actions write token; the MCP integration used while
building this returned 403):
`mcp__github__actions_run_trigger` method `run_workflow`, owner `benedek-art`, repo `lumen`,
workflow_id `render-lab.yml`, ref `<branch>`, inputs
`{"manifests": "proof-core", "lane": "macos", "label": "my-check"}` (inputs: `manifests`,
`manifest` (inline JSON string), `lane` = macos|linux|both, `shards`, `drift`, `plates`,
`runs-on`, `label`).

Any run with `lane` `linux` or `both` also runs the drift check (`drift-sample.json`: the
same recipes on the shipping export and on the reference path, diffed per render) unless
`"drift": "none"`; name another manifest to check that instead.

Jobs: `plan` → `plates` (macOS, only when plates are not cached) → `shipping` (macOS:
manifests on export/settled/draft, then drift) and `reference` (Linux, `shards` parallel
jobs over plates) → `report` (merges everything into artifact **`renderlab-report`**).
Several runs proceed in parallel; nothing cancels another. The build is cached per commit
SHA (falls back to the newest cache for an incremental build).

**Wait, download, read** (from a container like this one):

```bash
python3 renderlab/lab.py wait <run_id>        # polls the public API, lists artifact ids
# then: mcp__github__actions_get method=download_workflow_run_artifact
#       owner=benedek-art repo=lumen resource_id=<renderlab-report artifact id>
python3 renderlab/lab.py fetch <run_id> --url '<signed url>'   # unzips, prints table + sheets
```

Find your run id with `mcp__github__actions_list` method `list_workflow_runs`,
resource_id `render-lab.yml`, branch filter. Then open sheets with the Read tool.

## 3. Photos

`photo` is a raw-corpus id or a chart:

| id | file | why |
|---|---|---|
| `6929` | Sony A7 IV ARW, 33 MP | the owner's camera class; clipped highlights; shadows |
| `5812` | Nikon Z 30 NEF | portrait (EXIF orientation 8) |
| `2607` | Panasonic GH5S RW2 | shadow-heavy; denoise |
| `6001` | Fujifilm X-H2 RAF, X-Trans | different demosaic, 40 MP, orientation 6 |
| `1346` | Canon 5D CR2 | control case, shadows |
| `4145` | Sony A7C ARW, ISO 12800 | high ISO, full frame: fern foliage, wood, white pot |
| `2260` | Nikon D5600 NEF, ISO 12800 | high ISO, night street: deep shadows, mixed street light |
| `2127` | Nikon D5500 NEF, ISO 6400 | high ISO event (wedding proxy): faces, hair, satin gowns |

All CC0 from raw.pixls.us, sha256-verified (`photos.tsv`, `fetch-photos.sh`). `4145`, `2260` and `2127`
are the high-ISO frames (6400 to 12800) for noise reduction. `6001` (X-H2 RAF) is refused by
`AppleRawSource` on the hosted macos-15 runner (`undecodable`), so it has no plate and fails
on the shipping path there.

Charts (scene-linear, linear Rec.2020, mid-grey 0.18, generated at the render size, 3:2):
`chart:greyRamp` (−8…+4 EV ramp + 13 one-stop patches), `chart:colorChecker` (24 patches,
Neutral 5 = 0.18), `chart:hueRing` (12 OKLCh hues × chroma 0.04–0.16 at mid-grey, ±1 stop),
`chart:skin` (Monk scale 1–10 + ColorChecker skins), `chart:detail` (frequency chirp, line
pairs, high/low-contrast edges), `chart:flatGrey` (vignette, grain), `chart:gradient` (shallow
grey, sky and shadow ramps: banding), `chart:pointLights` (+3/+5/+7 EV discs, a clipped
window: halation). Chart stats include per-patch readouts (`patches`) with the scene value fed
in, so "Exposure +1 doubled linear values" is `patchRatioMedian` ≈ 2.00 on the Linear
display transform (`look.render.preset: "Linear"`).

## 4. What you get

```
renderlab-report/<lane>/<manifest>/
  sheets/<job>__<photo>__<path>.png          contact sheet (value, L, clip %, Δ under each tile)
  sheets/<job>__<photo>__settled-vs-export.png   compare sheet
  <job>/<photo>/<path>/NN_<label>.png + .json    each render + its stats
  summary.tsv  compare.tsv  index.json  run.json
renderlab-report/shipping/drift/drift.tsv + sheets/   reference vs shipping
```

Stats (`stats`): `histogram` (r, g, b, luma; 256 bins; luma = relative luminance re-encoded
to sRGB codes), `luma` (mean, median, p01…p99, stdev, `meanLinearY`), `clipping` (fractions
with any/all channels at 0 or 255, per channel), `colour` (OKLab mean L/a/b, mean chroma,
chroma p95, chromatic fraction, 36-bin chroma-weighted hue histogram), `tonalZones`,
`patches` (charts). `timingsMs`. Delta against the reference tile (`deltaFromReference`):
`meanAbs`, `maxAbs`, `p99Abs` (code values), `changedFraction`, `meanLumaShift`,
`linearYRatio`, `byTone` (shift per starting luma quarter: where in the tonal range it
landed), `meanChromaShift`, `meanAbsHueShift`/`meanHueShift` (degrees, chroma-weighted:
should stay ~0 for tone controls), per-patch `dL dC dh ratioY`, `patchRatioMedian`.

## 5. Run the reference path here (Linux, seconds per render)

```bash
export PATH=/opt/swift/usr/bin:$PATH
python3 renderlab/lab.py local renderlab/manifests/smoke.json --out /tmp/rl        # charts only
python3 renderlab/lab.py local my.json --plates /path/to/plates --out /tmp/rl      # real RAWs
```

Plates: download artifact `renderlab-plates` from any run that built them (the `plates`
job), unzip to a directory. Options: `--lut 33` (faster, interactive table size; default 65,
export's), `--max-edge`, `--shard k/n`. RAW ids without plates are skipped on this path.

Plate format (`RenderLabPlate.swift`): `LUMENPLATE1\n`, UInt32 LE header length, JSON header
(`id, width, height, asShotTemperature, asShotTint, iso, nativeWidth, nativeHeight, scale,
crop, decodeRecipe, decoder, decoderVersion`), then Float32 LE RGB rows, top first: the
scene-linear Rec.2020 buffer AppleRawSource hands Lumen's stages, decoded with the
`imported` recipe. `<id>.plate` is 2048 px long edge; `<id>-crop40-40`, `-crop15-20`,
`-crop65-60` are native-resolution 20% crops (photo ids on the reference path).

## 6. Which stages each path covers

| stage | shipping (GPU) | reference |
|---|---|---|
| RAW decode, demosaic, lens profile, CA, defringe, capture sharpening, AI NR stand-in (Apple decoder NR), RAW denoise prepass | yes | **no**: baked into the plate at the `imported` recipe; changing them does nothing on the reference path |
| Classic NR (S3) | yes | yes |
| Heal/clone spots, WB, tone, zones, presence, colour, mixer, point colour, grade, masks, sharpening, vignette, halation, creative LUT, display transform, curves, grain | yes | yes (same maths, f32 CPU) |
| Geometry (crop, straighten, upright), resize, export output sharpening, dither, watermark, soft proof | yes | **no** |
| Draft stale tables, interactive LUT size (33) | `draft`/`settled` | `--lut 33` only approximates |

Scale matters for grain, NR, sharpening, capture sharpening, texture and halation: judge them
at 1:1 (`crop` on the shipping path, crop plates on reference). At a downsized frame NR is
scaled by the decode factor squared and can fall below its threshold and do nothing.

## 6b. Cost (measured on hosted runners, Nov 2026)

- Build cache is keyed by `Package.swift` + `Sources/**` + `Tests/**`, so any number of
  request pushes or dispatches against the same code skip the build: warm, a macOS job
  restores in ~6 s and starts rendering; a Linux shard is ~30–40 s end to end (run
  45741396379). Cold: macOS 4–6 min, Linux 3–4 min.
- A request push that changes only `docs/renderlab-request.json` fires no other workflow.
- macOS `shipping`: renders: a 33 MP ARW export at
  1536 px ≈ 10 s (full-resolution decode each time), 24 MP NEF ≈ 3.5–5 s, charts ≈ 0.4–1 s,
  viewer `settled` frames 0.1–1.4 s; proof-core (200 renders) 18.7 min, creative-stack (360
  renders, many 1:1 crops) 18.7 min. Plates for 4 RAWs: 45 s after the build.
- Linux `reference`: build ≈ 3.5 min (release); 8 shards of creative-stack rendered in
  20–40 s each. In a 4-core container: ≈ 0.35 s per 768 px chart render, ≈ 1.3 s per
  1536 px render (charts and plates mixed). One job per runner: the 65³ table bake already
  uses every core (`--lut 33` is ~8× cheaper and approximates the viewer's table).
- `renderlab-out` artifacts are large (≈ 300 MB per 200 renders); per-render PNGs are kept
  so an agent can crop them at 1:1.

Measured drift, reference vs shipping export at 1024 px (run 45739626987, `drift.tsv`):
charts 0.2–0.4 code values mean |Δ| (p99 1–2) for tone, WB, saturation, film stock and
vignette; clarity +50 with sharpening 80 is 1.1–3.9 (p99 up to 16): treat presence and
sharpening numbers from the reference path as approximate. Real RAWs: 5812 ≈ 0.9; 6929
≈ 3.4 (p99 ≈ 30), almost all of it fine detail, because the plate is a 2048 px decode and
export decodes the full 33 MP.

## 7. Not reachable yet

Masks (brush, AI subject/sky, linear/radial gradients: the patch accepts `masks` JSON but
brush strokes and AI mattes need inputs the lab does not supply), heal strokes (blob refs),
crop/straighten on the reference path, Upright, soft proof, HDR/gain-map export,
JPEG/HEIC/TIFF export settings (export is PNG 8-bit sRGB), the true AI denoise model (not
shipped; the AI mode is an Apple-decoder stand-in), and
interactive drag timing (the `draft` path renders single frames).

## 8. Maintenance

`CONTROLS.md` is generated:
`LUMEN_RENDERLAB_CONTROLS=/tmp/c.json swift test --filter RenderLabControlsDump && python3 renderlab/gen-controls.py /tmp/c.json > renderlab/CONTROLS.md`.
`RenderLabTests` validates every committed manifest against the recipe model.

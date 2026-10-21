# Proof corpus

Real photographs and synthetic targets that Linux agents can push through LumenCore
(`ReferenceRenderer.render`, or the RenderGraph on macOS) without Apple's RAW engine.

```
scripts/proof/fetch_corpus.sh          # downloads, verifies, decodes, generates -> corpus/
LONG_EDGE=0 scripts/proof/fetch_corpus.sh   # native resolution instead of 2400 px
```

`corpus/` sits at the repository root and is git-ignored. Only the scripts and
`corpus.manifest.json` are committed. A populated copy may also be at `/home/user/corpus`
on shared agent machines; pass `RAW_CACHE=/home/user/corpus/raw` to reuse its RAWs.

| path | what |
|---|---|
| `corpus/raw/<id>_<make>-<model>.<ext>` | the CC0 RAW, byte-identical to raw.pixls.us (sha256 in the manifest) |
| `corpus/lfi/<name>.lfi` + `.json` | its decode (below) and sidecar |
| `corpus/synthetic/<frame>.lfi` + `.json` | synthetic frames with ground truth |
| `corpus/corpus.manifest.json` | copy of the manifest |

Requirements: `python3`, `numpy`, `rawpy` (0.27.1 / LibRaw 0.22.1 tested), `curl`,
`sha256sum`. `lfi_preview.py` additionally needs Pillow.

## The `.lfi` format

```
bytes 0..3    b"LFI1"
bytes 4..15   uint32 LE  width, height, channels (always 3)
bytes 16..    width*height*3 float32 LE, RGB interleaved, row-major, top row first
```

Lumen's `ImageBuffer` is RGBA: a loader appends A = 1. Python: `decode_raw.read_lfi(path)`
returns an `(h, w, 3)` float32 array.

## The input convention (what the numbers mean)

This is the contract `AppleRawSource.decode` delivers on macOS (docs/14 §1.3, §2.1.4,
§4; `WhiteBalanceEngine.swift`; `RenderPlan.init`), reproduced on LibRaw:

1. **Linear Rec.2020, D65 white**, scene-referred, unbounded float32. No transfer curve,
   no tone curve, no gamut mapping. (`RGBColorSpace.rec2020`, the working space of every
   stage.)
2. **White balance is pre-applied at the as-shot neutral.** Apple's decode runs with
   `neutralTemperature/neutralTint` set to the file's own as-shot pair ("camera
   reference"), so a surface the camera judged neutral arrives as R = G = B. Lumen's
   CAT16 white balance at S6 adapts *from* the as-shot neutral to the recipe's target; a
   recipe whose `develop.raw.temp`/`tint` are nil renders with an identity WB matrix.
   Here: LibRaw's camera multipliers (`use_camera_wb`) on the mosaic, then a
   camera→Rec.2020 matrix with rows normalised so camera (1,1,1) → (1,1,1).
3. **As-shot metadata in the sidecar**, `recipe_hint.asShotKelvin` / `asShotTint`, in the
   **DNG SDK convention** (Robertson table, kTintScale −3000) — the convention
   `CIRAWFilter.neutralTemperature/neutralTint` report and `AppleRawSource` hands to
   `RenderPlan(recipe:asShotKelvin:asShotTint:captureISO:)` (see `DNGTemperature.swift`;
   `decode_raw.dng_temperature_tint` is a port of its inverse). `captureISO` is there too
   (it selects the denoise noise profile). Build the plan with exactly these three.
   Synthetic frames carry D65 = 6503.7 K / +9.77.
4. **Exposure**: black subtracted (no extra bias — Apple runs `shadowBias = 0`), the
   green channel's sensor white = 1.0, no auto-brightness, LibRaw `adjust_maximum` off so
   the scale never depends on content. Then `2^baseline_ev`: DNG `BaselineExposure` for
   `.dng`, else 0. Mid-grey in a well-exposed frame lands near 0.18 only approximately.
5. **Geometry**: the camera's default crop is applied (LibRaw `raw_inset_crops`, the same
   frame Apple delivers: A7 IV 7008×4672, GX85 4:3 4592×3448), then the orientation, so
   pixels are **upright** like CIRAWFilter's. Origin top-left.
6. **Size**: `--long-edge 2400` by default — an exact area (box-integral) downsample in
   linear light. `0` keeps native resolution.
7. **Deterministic**: LibRaw runs single-threaded, because its threaded X-Trans path gives
   different bytes run to run (measured: 0.16 % of pixels, up to 0.043).

## How this differs from Apple's decode — read before trusting a measurement

| | Apple (AppleRawSource, flat) | this decode (LibRaw) | consequence |
|---|---|---|---|
| Demosaic | proprietary, incl. X-Trans | AHD (Bayer), LibRaw 3-pass (X-Trans) | more zipper/maze and false colour here; fine-texture, moiré and X-Trans detail differ |
| Highlights | `isHighlightRecoveryEnabled` reconstruction | **clip**: each channel stops at white, blown areas go flat neutral | harder clipping, no recovered colour above the first clipped channel; sidecar `clipped_fraction` says how much |
| Lens corrections | embedded profile when `geometry.lens.profile` (distortion, vignetting, CA) | **none** | m4/3, Fujifilm and Sony frames keep barrel distortion and dark corners; framing differs slightly |
| Capture sharpening | Apple's at-demosaic sharpener × `detail.capture` strength | **none** | softer here |
| Noise reduction | zero for Off/Classic (Lumen's Tier 1 runs in the graph) | none | matches, except the `.ai` stand-in |
| Colour | Apple per-camera profiles, dual-illuminant | one D65 Adobe ColorMatrix + von Kries in camera space | close: RawCorpusTests R-7c measured Apple vs LibRaw R/G, B/G within ln 0.028 on four makes; this decode's whole-frame R/G, B/G reproduce R-7c's LibRaw references (6929 0.950/0.773 vs 0.950/0.770; 2545 1.102/0.822 vs 1.101/0.818; 1346 1.050/0.916 vs 1.048/0.915). Saturated colours outside the matrix's reach can go negative (1192's blue glass: 1.7 % of pixels, green down to −0.11) — kept, not clipped |
| Exposure | Apple's per-camera baseline exposure | 0 EV (DNG tag if present) | Apple is **+0.19…+0.43 EV brighter** on proprietary raws (R-7c: green 1.14–1.35×). Don't compare absolute levels to better than ~0.5 EV |
| As-shot Kelvin/Tint | Apple's own (DNG convention) | derived from WB multipliers via the single D65 matrix | approximation; pixels don't depend on it while the recipe's WB is "as shot" |

## RAW files

All **CC0 1.0** (public domain) from <https://raw.pixls.us>, checked per row; the fetch
refuses anything else. raw.pixls.us asks contributors not to upload photographs of
people, so there is **no real skin** in the corpus — use `synthetic/skin_tones.lfi`.
Full metadata (URL, ISO, exposure, scene, tags, sha256) is in `corpus.manifest.json`.

| id | camera | ISO | scene |
|---|---|---|---|
| 6929 | Sony ILCE-7M4 (A7 IV) | 250 | street: trees, ivy, rendered wall, gate; overcast — **owner's camera** |
| 6933 | Sony ILCE-7M4 (APS-C mode) | 640 | same scene, ISO pair — **owner's camera** |
| 2545 | Panasonic DMC-GX85 | 200 | lawn, trees, fence, blue sky, hard shadow — **owner's camera** |
| 1569 | Panasonic DMC-GX80 | 200 | pond, reflections, sunlit foliage — **owner's camera** (GX80 = GX85) |
| 2242 | Panasonic DC-GX850 | 2000 | colourful jigsaw close-up — saturated, high ISO |
| 2348 | Panasonic DC-G9 | 3200 | black jacket on a wire shelf — deep shadows, high ISO |
| 1346 | Canon EOS 5D | 400 | ColorChecker Passport, daylight |
| 983 | Canon EOS 5D Mark IV | 100 | sunlit snow, blue sky, lantern, Passport — HDR |
| 4694 | Canon EOS R5 | 100 | fruit bowl on blue cloth — saturated |
| 7881 | Canon EOS R5 Mark II | 640 | tomatoes, potato, blue bottle on green dish — saturated, bokeh |
| 2062 | Canon EOS Kiss X9 | 6400 | pastry on poppy tablecloth — high ISO, saturated reds |
| 1332 | Canon EOS 77D | 3200 | white painted pot, dried flowers, figurine — high ISO, whites |
| 3437 | Canon EOS Rebel T7i | 100 | meadow, oaks, beehive — foliage |
| 1840 | Nikon D850 | 64 | field, treeline, clear sky — sky gradient |
| 3582 | Nikon Z 6 | 100 | indoor still life, 1 s, artificial light — low light |
| 832 | Nikon D7200 | 1600 | plush toys indoors — high ISO |
| 4213 | Nikon Z 7_2 (Z 7II) | 100 | overcast landscape, white castle — flat sky, neutrals |
| 8559 | Nikon Z fc | 100 | shaded garden, red watering can, pots — saturated red |
| 6001 | Fujifilm X-H2 (X-Trans) | 125 | flower bed, sky — portrait orientation |
| 1192 | Fujifilm X-T10 (X-Trans) | 4000 | backlit stained-glass window — high ISO, HDR |
| 3914 | Fujifilm X-T4 (X-Trans) | 160 | anemone foliage + ColorChecker |
| 7301 | Fujifilm X100VI (X-Trans) | 125 | stone church facade, sky — portrait orientation |
| 864 | Fujifilm X-T2 (X-Trans) | 200 | grey-scale step chart — neutral greys |
| 967 | Sony ILCE-7M2 | 100 | ColorChecker Passport, daylight |
| 4144 | Sony ILCE-7C | 2000 | single leaf against bokeh — high ISO |

## Synthetic frames (`gen_synthetic.py`)

All in the same convention (neutral R = G = B, mid grey 0.18); each sidecar holds the
ground truth (patch rectangles, reference values).

| frame | size | content |
|---|---|---|
| `colorchecker` | 1368×920 | 24 patches, BabelColor ColorChecker 2005 Lab D50 → XYZ → Bradford D50→D65 → linear Rec.2020 (sidecar has Lab, XYZ D65 and RGB per patch); surround 0.03 |
| `grey_ramp` | 2800×400 | −10…+4 EV around 0.18: continuous top (200 px/EV, `ev = -10 + (x+0.5)/200`), 15 one-EV steps bottom |
| `hue_wheel` | 1200×1200 | OKLab, L of 0.18 grey; hue = angle, radius = fraction of the Rec.2020 boundary chroma for that hue; 0.18 surround |
| `zone_plate` | 2048×2048 | `0.18·(1 + 0.8·cos(π r²/2R))`, Nyquist at the inscribed circle (corners alias by design) |
| `hard_edge` | 1600×1200 | +4.5 EV disk on a −5 EV field; −5 EV square rotated 5° on a +4.5 EV field; 1/2/4 px bright and dark lines on 0.18 |
| `skin_tones` | 1530×530 | Monk Skin Tone scale (10 published sRGB swatches, decoded to linear and treated as reflectance — a convention, not a measurement) + ColorChecker dark/light skin |
| `flat_grey` | 1024×1024 | uniform 0.18, for grain/noise |

## Looking at a frame

```
python3 scripts/proof/lfi_preview.py corpus/lfi/6929_sony-ilce-7m4.lfi /tmp/p.png
```

Auto-exposes to a 0.18 geometric mean, converts to sRGB, clips. For eyes only — it is
not Lumen's display transform.

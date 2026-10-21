// lumen-render — the headless renderer: recipe + scene-linear image → the PNG the app
// would show, plus the numbers that say what a slider did.
//
// WHY THIS EXISTS. Every agent working on this repository runs on Linux, with no GPU and
// no display, and until this tool none of them could look at an output pixel. A slider
// whose shader is wrong passes every structural test; it only fails when somebody looks.
// This renders through `ReferenceRenderer` — the f32 CPU definition of the whole
// pipeline that the GPU path is golden-tested against — and encodes exactly the way the
// app does, so the picture an agent opens with its image viewer is the app's picture.
//
// BUILD (Linux or macOS; depends only on LumenCore):
//
//     export PATH=/opt/swift/usr/bin:$PATH        # Linux toolchain location
//     swift build -c release --product lumen-render
//     BIN=$(swift build -c release --show-bin-path)/lumen-render
//
// Release matters: the reference renderer is plain Swift over Double RGB and debug
// builds are an order of magnitude slower.
//
// COMMANDS
//
//   lumen-render render --input in.lfi [--recipe recipe.json] [--set key=value ...]
//                       [--long-edge 1600] --out out.png [--metrics out.json]
//
//   lumen-render sweep  --input in.lfi [--base recipe.json] [--set key=value ...]
//                       --key develop.tone.exposure --values -2,-1,0,1,2
//                       [--long-edge 512] [--columns 5]
//                       --out sheet.png [--metrics sweep.json] [--tiles-dir dir]
//
//   lumen-render keys   [--base recipe.json] [--json]
//
//   lumen-render upright --input in.lfi [--long-edge 1024] [--modes level,vertical,full,auto]
//                       [--out-dir dir]
//                       (Upright: detected lines, each mode's solve, residual tilt before
//                        and after — carried through the map and re-detected)
//
//   lumen-render synth  --out test.lfi [--width 960 --height 540]
//                       (the same test frame scripts/proof/make_test_lfi.py writes,
//                        for machines without numpy)
//
//   Shared options (render, sweep):
//     --as-shot-kelvin K   the file's as-shot neutral temperature (default 5500)
//     --as-shot-tint T     the file's as-shot tint (default 0)
//     --iso N              capture ISO, selects the classical-NR noise profile
//     --space srgb|p3      output encoding (default srgb, what the export ships)
//     --no-dither          skip the 8-bit ordered dither the preview/export apply
//     --lut-size N         finish/grade table size (default 33 = the app's interactive
//                          size; 65 = export size)
//     --resampler F        S16's filter: lanczos3 (the stage, default), bicubic or
//                          bilinear (what Core Image's transform sampled with) — for
//                          comparison sheets only
//
// KEY PATHS are the recipe's JSON spelling, dotted: `develop.tone.exposure`,
// `look.wheels.shadows.hue`, `develop.mixer.bands.3.sat` (numeric segments index
// arrays). `keys` lists every numeric one with its default and its range where the
// model or the proof registry states one. A value is set by encoding the recipe to its
// canonical JSON tree, writing the number at the path, and decoding back; the tool then
// re-encodes and READS THE PATH BACK, so a misspelt path (which the tolerant decoder
// would silently ignore) is an error, and a value the model normalized or clamped is
// reported as `effectiveValue`. Optional subtrees (`look.grain`, `look.filmLab`,
// `look.bw`, `develop.raw.temp`, `look.render.contrast` …) are created on demand from
// their decoders' defaults. `--set` takes numbers, `true`/`false`, or strings
// (`--set look.render.preset=Punchy`, `--set look.filmLab.stock=lumen/portra400`).
//
// INPUT FORMAT `.lfi` (Lumen float image), little-endian throughout:
//
//     bytes 0..3   magic "LFI1"
//     UInt32       width
//     UInt32       height
//     UInt32       channels (must be 3)
//     Float32 × width × height × 3   RGB interleaved, row-major, top row first
//
// `.pfm` (Portable Float Map, "PF" colour) is accepted too, same colour convention.
// TIFF is not: Foundation on Linux has no TIFF decoder and a hand-written one for the
// float/16-bit variants is not trivial.
//
// INPUT COLOUR CONVENTION — the exact contract `ReferenceRenderer.render` starts from
// (it begins at stage S6; the app's decode and S3 denoise run upstream of it):
//
//   · scene-linear light, NOT display-referred: 0.18 is mid-grey, 1.0 is no ceiling
//     (values above 1 are legitimate highlight data, negatives are tolerated);
//   · linear Rec.2020 primaries, D65 white (`RGBColorSpace.rec2020`, the working space
//     `RenderPlan`/`ReferenceRenderer` default to — the app's CIContext working space
//     is extendedLinearITUR_2020);
//   · at CAMERA-REFERENCE white balance: a neutral surface under the as-shot
//     illuminant arrives as R = G = B (WhiteBalanceEngine.swift: "the decode always
//     runs at camera-reference WB"). White balance is NOT baked in as multipliers;
//     the recipe's `develop.raw.temp/tint` is applied at S6 as a CAT16 adaptation
//     from the as-shot neutral (`--as-shot-kelvin/--as-shot-tint`, default 5500 K /
//     0, which is the rendered-file reference `WhiteBalanceEngine.Neutral.reference`)
//     to the target. With `raw.temp` unset (as shot) S6 applies no WB at all.
//
// So a synthetic frame is authored as linear-light colours in Rec.2020 with neutrals
// neutral; an sRGB colour is decoded to linear and converted with
// `RGBColorSpace.srgb.matrix(to: .rec2020)`, never reinterpreted.
//
// WHAT RUNS, in order — the app's own CPU fallback (`PipelineRenderer.renderReference`)
// step for step:
//
//   1. area-average downsample to --long-edge (before rendering, as the app decodes at
//      a scale factor); the stage's spatial radii are all long-edge-denominated;
//   2. `RenderPlan(recipe:asShotKelvin:asShotTint:captureISO:bandMeanHues:)`, with
//      Uniformity's measured band hues taken from the input when the mixer needs them;
//   3. S3 classical denoise when the plan has one (`classicalDenoise.scaled(noiseScale:
//      scale²)`), exactly as renderReference does;
//   4. `ReferenceRenderer.render` → display-linear, still in Rec.2020 primaries;
//   5. the encode: ordered 8×8 Bayer dither of one sRGB code (`Dither`, added in the
//      working primaries as `PipelineRenderer.applyDither` does), Rec.2020 → sRGB (or
//      Display P3) matrix, clamp to [0,1], sRGB transfer, round(v × 255). That is
//      `PipelineRenderer.cgImage(from:)` plus the dither the preview and export apply.
//
//   4b. S16 geometry (`GeometryStage`: crop, straighten, flip, Upright, one Lanczos-3
//      resample), after the render and before the encode, as renderReference runs it.
//      An automatic Upright mode with no stored lines is solved from
//      `UprightDetector.detect` on the input, as the app does when the mode is picked;
//
// Not rendered (no input for them): brush-stroke masks (no stroke blobs), AI mattes
// (no Vision), heal strokes, creative LUT cubes not on the shared shelf, lens
// corrections and the RAW-domain stages before S3.
//
// METRICS (JSON, written with --metrics). All are computed on the encoded output BEFORE
// the dither (so they are deterministic), from the clamped display-linear values in the
// OUTPUT space:
//
//   luminance.linear*  : Y = output-space luminance weights · display-linear RGB, 0…1
//   luminance.encoded* : sRGB-transfer encoded Y, 0…1 (×255 ≈ the grey code value);
//                        mean, median and p1/p5/p50/p95/p99 for both
//   clipping           : % of pixels per channel at code 255 (highlightsPct) and at
//                        code 0 (shadowsPct), plus `any`
//   colour             : OKLab of the output (LumenCore's OKLabTransform, CAT16 cone,
//                        built for the output space): mean chroma over all pixels,
//                        chromaticPct (C > 0.02), and a 12-bin hue histogram (30° bins
//                        from 0°, OKLab hue) as fractions of the chromatic pixels, and a
//                        chroma-weighted twin
//   meanEncodedRGB     : mean encoded R,G,B, 0…1
//
// Sweep metrics add, per tile, CIEDE2000 against the REFERENCE tile (the tile whose
// value is 0; otherwise the tile equal to the base recipe's own value; otherwise the
// middle tile) — mean, p95 and max over pixels, CIELAB D65 from the output's XYZ — and a
// ZONE TABLE: the reference tile's pixels split into 10 equal bins of encoded luminance
// (0–0.1, …, 0.9–1.0); for each value, the mean change of encoded luminance in each
// zone (`deltaEncoded`, 0…1 units; ×255 for codes) and the change in stops of mean
// linear luminance (`deltaEV`). The zone membership is fixed by the reference, so a
// pixel that brightens out of its zone is still counted where it started. Those are
// the numbers an audit uses to say "Shadows +100 moved zone 1 by 0.12 and zone 8 by
// 0.004: correct" or "Exposure +1 did nothing above zone 7: wrong".
//
// EXAMPLE
//
//     python3 scripts/proof/make_test_lfi.py /tmp/test.lfi
//     $BIN render --input /tmp/test.lfi --out /tmp/neutral.png --metrics /tmp/neutral.json
//     $BIN sweep --input /tmp/test.lfi --key develop.tone.exposure \
//                --values -2,-1,0,1,2 --out /tmp/exposure.png --metrics /tmp/exposure.json
//     $BIN keys | grep tone

import Foundation
import LumenCore

LumenRenderCLI.main(Array(CommandLine.arguments.dropFirst()))

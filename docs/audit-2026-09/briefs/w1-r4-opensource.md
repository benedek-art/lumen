# R4 — darktable + RawTherapee (+ ART, vkdt)

Read `briefs/w1-common.md` first. Output: `docs/audit-2026-09/w1/r4-opensource.md`.

The only competitors whose maths can be read. Lumen's engine tests already cross-check
against RT 5.10 and dt 4.6 (`scripts/baselines/crosscheck.py`, `docs/26-tone-baselines.md`
— read both). Give the audit **algorithms with parameters**, and source-file names where
you know them (`src/iop/<module>.c` in darktable, `rtengine/` in RT). Search
`github.com/darktable-org/darktable` and `github.com/Beep6581/RawTherapee` — GitHub may
be reachable via WebFetch where other domains are not; try once.

## Must cover
1. **Tone mapping**: dt `filmic rgb` (white/black relative exposure, contrast,
   latitude, shadows/highlights balance, the spline, preserve chrominance modes) and
   `sigmoid` (contrast, skew, per-channel vs RGB ratio, hue preservation, display
   target); RT's tone curve modes (standard / weighted standard / film-like /
   saturation & value blending / luminance / perceptual), Dynamic Range Compression.
   Lumen's `DisplayTransform` is an AgX-class sigmoid — state exactly how dt's sigmoid
   parameters map to "contrast, skew, hue preservation, black/white target".
2. **dt `color balance rgb`** — the 4-ways (global/shadows/mid/highlights), chroma
   vs saturation vs brilliance definitions, the masks (shadows/highlights fulcrum,
   white/grey fulcrum), perceptual saturation. Lumen's grading wheels have a known
   inversion defect (docs/31 r2 #1); what does dt do to keep luminance monotonic?
3. **dt `color calibration`** (CAT16/Bradford, illuminant detection) vs Lumen's
   `WhiteBalanceEngine` CAT16.
4. **Sharpening**: RT **capture sharpening** (auto radius from corner/centre analysis,
   contrast threshold, iterations — Richardson–Lucy deconvolution), RT
   deconvolution/unsharp; dt `diffuse or sharpen` presets and what each does; dt
   `sharpen`; local contrast (dt `local contrast` bilateral/local laplacian; RT
   `local contrast`).
5. **Denoise**: dt `denoise (profiled)` (non-local means, wavelets, the noise
   profiles, "wavelets auto" Y0U0V0), dt `astrophoto denoise`, RT `noise reduction`
   (luminance/chrominance wavelet modes, "median"), dt `raw denoise`. Which are
   candidates for Lumen to adopt outright (licence: dt GPL3, RT GPL3 — flag it).
6. **Texture/clarity/dehaze**: dt `haze removal`, RT `haze removal` + `dehaze`; how
   they estimate airlight and avoid the sky cast.
7. **Masks**: dt's drawn masks (circle/ellipse/gradient/path/brush, feather, opacity,
   the on-canvas scroll gestures for size/feather/opacity), parametric masks (L/C/h
   sliders with feather), raster masks reuse; RT local adjustments (spots, excluding
   spots, shapes, ΔE scope).
8. **Film emulation & grain**: dt `grain` (coarseness/strength, its noise model),
   `lut 3D`, RT `film simulation` (HaldCLUT), G'MIC film emulation; ART's "film
   negative", "grain".
9. **Colour**: dt `color zones`, RT `color toning`, `HSV equalizer`, `L*a*b*
   adjustments`, `vibrance`; RT `wavelet levels`.
10. **Raw decode**: demosaic options (AMaZE, RCD, DCB, LMMSE, dual), hot pixel, CA
    correction (RT auto CA), flat-field. What Lumen (Apple `CIRAWFilter`, flat) cannot
    match and what it could.
11. **UI/UX lessons**: dt's module groups/quick access panel, RT's tool panels,
    keyboard grammar; what a modern rebuild should NOT copy from them.
12. **vkdt / ART / RapidRAW** — one paragraph each: what is novel.

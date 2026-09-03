# R5 — the creative bar: Luminar Neo · ON1 Photo RAW · Radiant Photo · Dehancer · Filmbox · RNI

Read `briefs/w1-common.md` first. Output: `docs/audit-2026-09/w1/r5-creative.md`.

These set the bar for "fun, easy, beautiful" — film looks, grain, halation, bloom,
presets UX — and for what a modern editing UI feels like in 2026. The owner wants
editing to "feel fun". Be concrete about mechanisms, not adjectives.

## Must cover
1. **Film emulation approaches** — for each of Dehancer, Filmbox (Video Village),
   FilmConvert Nitrate, RNI, ON1 Effects "Film Grain"/"Vintage", Luminar "Film
   Grain"/LUTs: is it LUT-based, a curve+matrix model, or a physical/spectral model?
   What user controls exist (film stock, "print"/paper, push/pull, exposure, bleach
   bypass, halation, bloom, breath, gate weave, vignette, grain)? Defaults and ranges.
2. **Grain models** — Dehancer's (size, amount, per-channel, "true grain" from scans),
   Filmbox's (film-scan grain, resolution independence), FilmConvert's, LR's. Is grain
   applied in linear or after the print curve? Is it luminance-dependent (more in
   mid-tones), chroma-carrying, resolution-independent at export?
3. **Halation and bloom** — threshold, radius, colour (red/orange from the anti-
   halation layer), how they differ; where in the chain.
4. **Luminar Neo** — Relight AI, Sky AI, Structure AI, Enhance AI, Portrait tools,
   presets ("templates") UX with previews; the layers/masking model; what is
   local-only vs cloud.
5. **ON1 Photo RAW** — Effects stack (filters with blend modes and per-filter masks),
   NoNoise AI, Super Select AI, Sky Swap, the preset browser with live thumbnails,
   Sync/Batch.
6. **Radiant Photo** — the "smart preset"/auto-correct pipeline: what it decides
   automatically (per-scene), and how the user overrides.
7. **Presets UX across all** — live preview thumbnails on the actual image, hover
   preview, amount/opacity slider, favourites, preset packs, "apply on import".
8. **UI systems** — for Luminar, ON1, Radiant, Dehancer: what makes each feel modern
   or dated (surfaces, spacing, type, iconography, motion, onboarding, empty states).
   One paragraph each, concrete.
9. **AI features worth noting** for a local-only app: which run locally, model sizes.

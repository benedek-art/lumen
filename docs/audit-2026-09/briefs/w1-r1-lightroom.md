# R1 — Lightroom Classic (current release)

Read `briefs/w1-common.md` first. Output: `docs/audit-2026-09/w1/r1-lightroom.md`.

Lightroom Classic is the owner's stated reference ("copy it bar for bar" for masking).
`docs/02` is a 15.5 teardown; refresh it against the current release and go DEEPER on the
items below, which the audit needs at control-by-control resolution.

## Must cover, in depth
1. **Masking on-canvas grammar** — the audit's most explicit target. For Radial and
   Linear gradients: every handle (centre pin, edge handles, feather line/ring, rotate
   affordance and where it appears on hover), what drag-inside vs drag-edge vs drag-
   outside do, modifier keys (⌥, ⇧, ⌘), double-click, invert, duplicate, delete, the
   pin's behaviour when hidden/auto. For Brush: cursor ring, size/feather/flow/density
   keys (`[` `]`, ⇧), pressure, erase (⌥), auto-mask. For Range masks (Luminance, Color,
   Depth): the eyedropper and the range/feather handles. For Select Subject/Sky/
   Background/Objects/People: what each produces, per-person parts, refresh behaviour.
2. **The Masks panel itself** — every control top to bottom: Create New Mask roster
   (icons, order), mask rows (thumbnail, chevron, eye, name, ⋯ menu contents), Add/
   Subtract/Intersect, per-mask Invert, Amount, overlay controls (Show Overlay, mode
   list, colour), per-mask adjustment sections and their order, the panel's collapse.
3. **Point Color** — sample, range, hue/sat/lum shift, the swatch grid, "visualize".
4. **Lens Blur** — depth map source, focal range, bokeh, boost; on-canvas focus.
5. **Denoise (AI)** — what it produces (a DNG), amount, when it is greyed, speed.
6. **Presets** — Amount slider, Adaptive presets, preset previews on hover, groups.
7. **Sliders** — every modifier and gesture: drag, ⇧-drag, ⌥-drag, scrubby on the value,
   double-click reset, arrow keys ±, ⇧-arrows, type-in, the "Auto" affordances.
8. **Tone** — PV5/PV6 tone behaviour (Exposure as gain, Contrast pivot, Highlights/
   Shadows range compression, Whites/Blacks clip), Curve (parametric + point +
   per-channel), the histogram's draggable regions.
9. **Color** — HSL/Color/B&W panels, Color Grading wheels (blend/balance semantics),
   Calibration, Vibrance vs Saturation behaviour.
10. **Detail** — Sharpening (amount/radius/detail/masking with ⌥ preview), NR classic
    sliders, and how Enhance interacts.
11. **Library/cull** — flags/ratings/labels keys, Survey/Compare, filter bar, Quick
    Develop, Auto Advance, the Library filter grammar.
12. **Export** — presets, resize modes, output sharpening, watermark, metadata options.
13. **Crop/Transform** — crop overlay cycling (`O`), aspect lock, straighten tool,
    Upright modes, Guided.
14. **Effects** — Vignette (style/midpoint/roundness/feather/highlights), Grain
    (amount/size/roughness) — defaults and ranges.

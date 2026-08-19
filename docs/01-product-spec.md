# 01 — Product Spec: What Lumen Is (and Isn't)

## The one-sentence spec

Lumen is a native macOS app that replaces Adobe Lightroom Classic for **one photographer's** workflow: import → cull → develop (non-destructively, with great denoise and masking) → export.

## Guiding principles

1. **One user.** No sync, no cloud, no multi-user catalogs, no plugin ecosystem, no Windows. Every feature Adobe builds for "everyone" that we don't need is a feature we skip. This is how a solo project beats a 20-year-old product *for us*.
2. **Non-destructive always.** Originals are never touched. Edits are a recipe (an ordered parameter set) stored in the catalog and mirrored to XMP sidecars, rendered live on the GPU.
3. **Lean on the platform.** macOS ships a GPU-accelerated RAW engine (Core Image's `CIRAWFilter`), a segmentation stack (Vision), and an ML runtime (Core ML). We use them instead of rebuilding them, and only replace a piece when it limits us.
4. **The picture is the product.** Priorities are ordered by how much they improve finished photos: develop quality > masking > denoise > culling speed > library management > everything else.

## Full Lightroom Classic feature inventory → scope decision

Legend: **M** = must have (core product) · **S** = should have (build after core) · **L** = later/maybe · **✗** = deliberately never.

### Library / catalog

| Lightroom feature | Scope | Notes |
|---|---|---|
| Import from folder/card, copy or add-in-place | M | Add-in-place first; copy-with-rename later (S) |
| Folder tree browsing | M | Filesystem is the source of truth; no "collections database only" photos |
| Grid view + filmstrip + loupe | M | |
| Flags (pick/reject), star ratings, color labels | M | Keyboard-first culling: P/X/U, 1–5, 6–9 |
| Filter bar (by flag/rating/label/file type) | M | |
| Collections / smart collections | S | Smart collections = saved SQL filters, cheap once catalog exists |
| Keywords, keyword hierarchy | L | Personal workflow rarely uses them; EXIF search covers most needs |
| Face recognition | ✗ | Not worth it for one user; Photos.app exists |
| Map module / GPS | ✗ | |
| Metadata editing (IPTC/copyright) | L | Write-on-export template is enough |
| Sort orders, custom sort | S | Capture time, edit time, rating |
| Stacks / virtual copies | S | Virtual copies are cheap in our edit model (a second recipe row) |
| Catalog backup | M | It's a SQLite file: snapshot on close, keep N copies |
| Preview/thumbnail cache | M | Multi-resolution cache; see 06-catalog-library.md |
| Publish services, slideshow, book, print, web modules | ✗ | Export to disk covers everything we do |
| Tethered capture | ✗ | |

### Develop — global adjustments

| Lightroom feature | Scope | Notes |
|---|---|---|
| RAW decode + demosaic (Bayer + X-Trans) | M | Via `CIRAWFilter` (Apple RAW), custom pipeline as escape hatch |
| White balance (temp/tint, eyedropper, as-shot) | M | |
| Exposure, contrast | M | |
| Highlights / shadows / whites / blacks | M | |
| Presence: texture, clarity, dehaze | M | Clarity+dehaze first; texture is a frequency-band variant |
| Vibrance / saturation | M | |
| Tone curve (parametric + point, per-channel RGB) | M | Point curve first; parametric later |
| HSL / color mixer (8 bands: hue/sat/lum) | M | |
| Color grading (shadows/midtones/highlights wheels) | S | |
| B&W mix | S | Falls out of HSL implementation |
| Camera profiles (Adobe Color, camera-matching looks) | S | Start with Apple RAW rendering + our own base look; DCP support is L |
| Sharpening (amount/radius/detail/masking) | M | |
| Noise reduction: luminance + color sliders | M | Milestone 1 uses Apple RAW NR; then ours — see 04-denoise.md |
| **AI Denoise** | **M** | Flagship feature — Core ML model, see 04-denoise.md |
| Lens corrections (distortion/vignette/CA) | M | Apple RAW applies built-in lens corrections for most mirrorless lenses; lensfun-style manual DB is L |
| Chromatic aberration removal | M | Comes with the above; manual defringe is S |
| Crop / rotate / straighten (with level tool) | M | |
| Geometry / Upright / perspective | L | Manual vertical/horizontal sliders S; auto-upright L |
| Vignette (post-crop), grain | S | Both are easy shaders |
| Calibration panel | ✗ | Legacy; HSL + profiles cover it |
| Process versions | M (design for it) | Every recipe stores a pipeline version number from day 1 |

### Develop — local adjustments (masking)

| Lightroom feature | Scope | Notes |
|---|---|---|
| Linear gradient mask | M | |
| Radial gradient mask | M | |
| Brush mask (size/feather/flow/erase) | M | |
| Luminance range mask | M | |
| Color range mask | M | |
| Depth range mask | L | Only works on files with depth data |
| **AI: Select subject** | **M** | Vision `VNGenerateForegroundInstanceMaskRequest` — free on macOS |
| **AI: Select sky** | **M** | Segmentation model via Core ML — see 05-masking.md |
| AI: Select people (face/skin/hair parts) | S | Vision person segmentation gets 80%; body parts are L |
| AI: Select objects (click/box) | S | SAM2-family model via Core ML |
| AI: Select background | M | Trivial: invert subject |
| Mask combine: add/subtract/intersect/invert | M | Mask algebra is core architecture, not a feature |
| Per-mask adjustments (most global sliders, locally) | M | |
| Duplicate/rename masks, mask overlay display modes | M | |
| Healing: clone/heal brush | S | Content-aware fill is L (inpainting model) |
| Red eye | ✗ | |

### AI / compute features

| Lightroom feature | Scope | Notes |
|---|---|---|
| AI Denoise (RAW-domain) | M | See 04-denoise.md |
| Super Resolution / enhance | L | Same infrastructure as denoise once that exists |
| Generative remove/expand | ✗ | Cloud-scale models; out of scope |
| Auto settings (AI auto-tone) | S | Simple histogram-based auto first |
| Content-aware search ("find photos of dogs") | ✗ | |

### Output

| Lightroom feature | Scope | Notes |
|---|---|---|
| Export: JPEG/TIFF, quality, resize, sharpen-for-output | M | HEIF/AVIF S |
| Export presets, batch export | M | |
| Color space on export (sRGB/Display P3/Adobe RGB) | M | |
| Watermark | L | |
| Edit-in-Photoshop round trip | L | Export TIFF + open-with covers it |
| Copy/paste settings, sync settings across photos | M | |
| Presets (develop presets, import presets) | M | Presets are just saved partial recipes |
| Before/after views, snapshots, history | M | History = recipe versions; snapshots = named versions |

## What "better than Lightroom for me" concretely means

These are the acceptance targets that justify the project — write them down now, measure against them later:

1. **Speed of culling**: grid scroll and loupe next/prev at 60fps on 45MP RAW previews, zero "loading…" beachballs. (LR's pain point #1.)
2. **Slider latency**: < 50 ms from slider drag to updated full-window preview at fit zoom.
3. **Denoise we control**: one-click AI denoise that runs locally in seconds (not LR's minutes-long DNG round trip), applied non-destructively as a pipeline stage — no duplicate DNG files littering the library.
4. **Masking parity**: subject/sky/background AI masks + gradient/brush/range masks, combinable with mask algebra.
5. **No subscription, no catalog lock-in**: SQLite + XMP sidecars, everything inspectable.
6. **Our taste, built in**: default rendering we like (base look), our export presets, our keyboard layout.

## Explicit non-goals (to keep the line straight)

- No Windows/Linux, no iPad, no phone.
- No cloud sync, no accounts, no telemetry.
- No plugin API until the core is done.
- No video.
- No attempt at pixel-identical Lightroom rendering — LR recipes don't migrate; we start fresh with our own look.

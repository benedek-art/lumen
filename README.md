# Lumen

A personal RAW photo editor for macOS. One photographer, one platform, no subscription:
**import → cull → develop → grade → export**, non-destructively, at the speed of the keyboard.

The one-line thesis: **Photo Mechanic's culling speed + FastRawViewer's raw truth + Lightroom's
workflow grammar + Capture One's color + Resolve-grade grading depth + DxO-class denoise ambition —
in one native macOS app, local-only, owned forever.** No product on the market combines even three
of these. That is the whole plan.

## Why now

The field cleared out while nobody was watching. Apple bought the Pixelmator team and put
Pixelmator Pro and Photomator — the best Apple-native editors — into caretaker mode. Aperture is a
decade dead and photographers still hack it onto modern macOS. Affinity was absorbed by Canva.
Capture One burned two decades of goodwill with subscription pivots and a 344% studio price hike.
Adobe added generative-credit metering to a subscription that had already stopped earning it. The
"own your tools" photographer has no home — and macOS ships more free imaging machinery than ever:
a GPU RAW engine for essentially every camera, on-device segmentation, an ML runtime, and EDR
displays, waiting to be assembled by someone with taste and exactly one user to please. RapidRAW
(a solo developer shipping a usable GPU raw editor in months) proves the shape is one-person-sized;
Apple's platform is what makes it one-person-sized *well*.

## Status

**Phase 1 — walking skeleton in progress.** The planning package below (v2) is complete — the
product of a full research sweep (August 2026): the color-grading and editing literature, a
slider-by-slider teardown of Lightroom Classic 15.5, deep teardowns of Capture One, DxO, Topaz,
the Mac-native field, the culling tools, the open-source engines, and cinema color, with every
feature carrying a named verdict against the best in class.

Code so far: `LumenCore` (recipe model, canonical JSON + fingerprints, curve/zone/mask reference
math, XMP sidecars, catalog schema) builds green with all tests passing on CI's macOS runner,
cross-verified against an executable Python reference; the walking-skeleton app (browse → loupe →
basic sliders → JPEG export) compiles and awaits its first launch. See [BUILDING.md](BUILDING.md)
for the honest ledger and how to run it.

## What "better, for me" means — measurably

1. **Culling at key-repeat speed.** Next photo in <50 ms from a pre-decoded cache; grid scroll with
   zero hitches at 120 Hz; browse a card without importing it. (Photo Mechanic's bar.)
2. **One-frame sliders.** Drag → visible change within one display frame, full quality within
   200 ms. Nothing synchronous on the input path, ever. (The bar Lightroom keeps failing.)
3. **Raw truth.** A real raw histogram and per-channel clipping stats at cull time — the embedded
   JPEG lies by 0.3–2 EV. (FastRawViewer's bar, folded into the cull loop.)
4. **Color depth no stills editor ships.** Zone-based tone with visible pivots, grading wheels,
   printer lights, hue-stable curves, skin uniformity, a physically grounded Film Lab with real
   halation and density grain, and scopes with a skin-tone line. (Resolve's and C1's bars.)
5. **AI denoise in seconds, cached, previewed full-frame.** No DNG copies, no patch previews, no
   cloud, no credits. Masking with subject/sky/people-parts/anything-I-click, recomputed in the
   background, never blocking the UI. (Adobe's quality bar, nobody's workflow bar.)
6. **No lock-in.** Originals read-only forever; edits are inspectable JSON recipes mirrored to XMP
   sidecars; the catalog is one SQLite file. If Lumen dies, the work survives. (Aperture's lesson.)

## The plan

Read in order, or jump to what you care about.

| Doc | Contents |
|---|---|
| [00 — Vision](docs/00-vision.md) | The design laws: fast/accurate/easy defined measurably; what Lumen refuses to build |
| [01 — The literature](docs/01-research-literature.md) | What the books teach (Adams to Margulis to the colorist canon) and what Lumen takes from each |
| [02 — Lightroom teardown](docs/02-research-lightroom.md) | Every panel, slider, and hidden interaction of LrC 15.5; verdict tables for all of it |
| [03 — The field](docs/03-research-competitors.md) | Capture One, DxO, Topaz, the Mac-natives, the cullers, the open-source engines, Resolve & film science |
| [04 — Tone](docs/04-spec-tone.md) | WB, the six sliders, the Zones panel, the display transform, curves, Auto, histogram |
| [05 — Color](docs/05-spec-color.md) | Mixer, point color, grading wheels, printer lights, skin tools, Film Lab, scopes |
| [06 — Detail](docs/06-spec-detail.md) | Texture/clarity/dehaze without halos; three-pass sharpening |
| [07 — Denoise](docs/07-spec-denoise.md) | Live classical NR + cached AI denoise; the bake-off protocol |
| [08 — Masking](docs/08-spec-masking.md) | Mask algebra, every component type, AI selection, local curves & wheels |
| [09 — Geometry](docs/09-spec-geometry.md) | Crop, lens corrections, guided upright, heal/clone, dust removal |
| [10 — Library](docs/10-spec-library.md) | Browse-without-import, the culling grammar, raw-truth instruments, AI assists, verified ingest |
| [11 — Output](docs/11-spec-output.md) | Multi-recipe export, color management, HDR gain-map authoring |
| [12 — UX](docs/12-spec-ux.md) | The latency contract, keyboard system, Speed Edit, the slider contract, Mac-nativeness |
| [13 — Architecture](docs/13-architecture.md) | Swift + Core Image/Metal + Vision/Core ML stack; concurrency; caching discipline |
| [14 — Pipeline](docs/14-pipeline.md) | Scene-referred linear core, stage order, Apple RAW stage vs ours, golden tests |
| [15 — Catalog](docs/15-catalog.md) | SQLite schema, recipe format, XMP sidecars, preview cache |
| [16 — Roadmap](docs/16-roadmap.md) | Phases with exit tests on real photos; risk register |
| [17 — Appendix](docs/17-appendix.md) | License ledger, model zoo, version snapshot, bibliography |

## Roadmap at a glance

1. **Walking skeleton** — browse a folder, edit a RAW with basic sliders, export a JPEG.
2. **Catalog + culling** — Photo Mechanic-grade culling with raw-truth instruments and verified
   ingest; Lumen becomes the daily culling tool.
3. **Develop engine** — our own tone stack, curves, and the one display transform; the look
   becomes ours.
4. **Masking** — LR-semantics masks with AI selection, plus local curves and wheels LR doesn't have.
5. **Denoise** — profiled classical NR + cached AI denoise, benchmarked against our old LR exports.
6. **Color depth** — mixer, point color, grading wheels, printer lights, skin tools.
7. **Film Lab, output recipes, HDR** — the Look layer's flagship, multi-recipe export, gain-map HDR.
8. **Dailies** — everything else, ordered by what annoys us while using it for real.

Every phase ends in a build the owner actually uses, gated by exit tests on real photos
([16 — Roadmap](docs/16-roadmap.md)).

## Principles

- Originals are read-only, forever. Edits are recipes; rendering is a pure function.
- Scene-referred, linear, float, unbounded — exactly one display transform, at the end.
- Develop normalizes; Look expresses. Looks are portable across a whole shoot.
- Every feature ships with keyboard access and a latency budget; the five-loop perf gate decides
  what ships.
- AI is local, evidence-first, and reversible. It fixes defects and selects regions; it never
  invents content and never phones home.
- Every pipeline stage lands with a golden-image test; rendering never changes silently.
- Ship-to-self weekly from Phase 1; annoyance drives the backlog.

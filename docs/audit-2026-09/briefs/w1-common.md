# W1 research — common brief

You are one of eight research agents feeding a 30-agent audit of **Lumen**, a Swift/SwiftUI
macOS raw photo editor at `/home/user/lumen`. Your dossier is read by auditors who each
own ONE area and will read ONLY your section for that area. Write for them.

## What the auditors need from you
Not marketing. For each capability: **how it actually works** — control names, ranges,
defaults, modifier keys, on-canvas grammar, what the algorithm visibly does, where it
lives in the UI, what it costs (speed, a model download). Concrete enough that an auditor
can hold Lumen's code up against it and say "present / partial / absent".

## Read first (prior art already in the repo — do not restart it)
- `docs/02-research-lightroom.md` — the LrC 15.5 teardown
- `docs/03-research-competitors.md` — C1, DxO, Topaz, cullers, open-source engines
- `docs/01-research-literature.md` — the imaging/colour canon
- `docs/17-appendix.md` — competitor version snapshot, licence ledger, model zoo
- `docs/00-vision.md` §"laws" — Lumen's constraints (Law 7: zero-chroma chrome; scene-referred linear; local AI only)
Refresh what is stale, deepen what is thin, and say explicitly which of your findings are
NEW relative to docs/02–03.

## Web access, as measured
- `WebSearch` **works** and returns result summaries with URLs.
- `WebFetch` is **blocked** by the egress proxy on helpx.adobe.com, arxiv.org,
  docs.darktable.org, rawpedia.rawtherapee.com, en.wikipedia.org. Try it on a domain
  once; if blocked, do not retry that domain.
- `WebFetch` **works on github.com and raw.githubusercontent.com** (verified: darktable
  `src/iop/sigmoid.c` and the NAFNet LICENSE both fetched). Source code, README.md,
  LICENSE files, docs folders and release pages of open-source projects are therefore
  readable in full — use that for algorithms, parameter structs and licences.
- Use many specific searches rather than a few broad ones. Tag every claim:
  `[search: <url>]` when a search result states it, `[knowledge]` when it is from your
  training, `[docs/02 §n]` when it is already in the repo. An auditor must be able to
  tell which claims are verified.

## Areas (write one section per area, in this order; write "Not applicable" if so)
A tone & sliders · B colour & grading · C film & grain · D looks/presets & effects ·
E denoise & sharpening · F masks (canvas grammar, engine, persistence, panel, AI) ·
G UI/UX (layout, design system, navigation/keys) · H viewer & scopes · I pipeline &
performance · J library/culling/export/ingest · K crop/lens/geometry · L state/undo ·
M recipe/serialization/sidecars

## Output
- Write `docs/audit-2026-09/w1/<your-name>.md`. Markdown. Per area: a table or tight
  bullets — capability · how it works · source tag · "Lumen would need: …" (one line,
  from what you can see in `Sources/` — grep, don't guess).
- End with **"New relative to docs/02–03"** (bullets) and **"Could not verify"** (bullets).
- Then return a ≤150-word receipt: what you covered, what was unreachable, the file path.

## Rules
- Read-only outside `docs/audit-2026-09/w1/`. No edits to Sources, Tests, docs. No git.
- 25 minutes. Past that, write what you have, mark the file PARTIAL at the top, return.
- No model names, no session ids in the file.

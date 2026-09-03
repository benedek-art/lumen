# R-S — synthesis: the gap table

Read `briefs/w1-common.md` first. Runs AFTER R1–R7 have written their files.
Output: `docs/audit-2026-09/w1/gap-table.md`.

## Job
Merge `w1/r1-lightroom.md` … `w1/r7-film-grain.md` into ONE table per area A–M:

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|

- Cells for competitors: how it works, in ≤12 words, with the dossier's source tag.
- **Lumen** cell: `present` / `partial` / `absent` / `model-only` (exists in the
  recipe with no UI) / `ui-only` (control wired to nothing) — determined by reading
  `Sources/` (grep; the inventory in `docs/audit-2026-09/PLAN.md` §"What the app
  actually is" lists files per feature). Cite the file.
- `gap` cell: one line — what Lumen would need, and a size guess S/M/L.

Then, per area, a **"Top 5 gaps by owner impact"** list — the ones a photographer using
Lumen for a day would notice first. Do not rank by engineering interest.

Finally, one section **"Cross-cutting"**: things every competitor does that Lumen does
not (e.g. preset amount, live preset previews, on-canvas mask handles, output
sharpening per medium…), and things Lumen does that no competitor does (local point
curve and wheels in a mask, the query sentence, zones panel…) — the audit should protect
the second list.

Rules: read-only outside `w1/`; no git; 20 minutes; return a ≤150-word receipt.

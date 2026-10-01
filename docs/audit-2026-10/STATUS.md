# October run: where it landed

Trunk `claude/jolly-sagan-k7ch7z` = `main` + PR #5 + everything below. Every stream's own
report is in `streams/`, every verifier's in `verify/`. This file is the index and the
list of what is NOT on trunk.

## Phase 1: PR #5 verified (V1–V7)
Of the Astra programme's 31 "verifying" repairs: most confirmed. Wrong as landed and
fixed this run: UX-02 (panel resize measured in the moving handle's space), AI-06 (WB
picker wrote magenta tints the render never used), REL-02 (a darktable `NAME.NEF.xmp`
could displace Lumen's own sidecar), REL-06 (first scan after upgrade, or a drive
remount, wiped every photo's signature, EXIF and previews). REL-09 was half done (quit
flush). The 29 unreviewed 4–6 September commits had nine defects (V7), now fixed by P7.

## Phase 2/3: streams on trunk
| Stream | What |
|---|---|
| P1 ingest | S-01..S-04: twin frames, aliased backup roots, honest accounting, idempotent re-ingest. 16 expected failures closed; 12 tests now run on Linux. |
| P2 persistence | REL-02/06/09 regressions, Auto Tone mid-drag, matte-pending previews. |
| P3 masks | brush-plane cache regression, stale thumbnails, GPU clamp, duplicate mask ids, F1/F4/F5 rows. |
| P4 curves | AI-04 purple deep blacks (+ master curve), AI-05 handles off trace, S-05/S-06. |
| P6 film | M09 GPU halation gate, N-006 calibration (byte-identical), N-005 retired. |
| P7 shell | D1–D9, duplicate catalog rows, export on exFAT/SMB, release refuses a stale build. |
| P8 raw | DNG RAW9 boundary, RAW tests wired to the corpus lane, noise estimator bias. |
| P9 layout | S-08, M12, S-11/KG-01 batch geometry, UX-03 slider VoiceOver. |
| P10 enums | PR #2's refactor redone: one PhotoFlag/ColorLabel, LibraryFilter in LumenCore. |
| P11 hygiene | surface-checker false findings, one string-aware comment blanker for 21 files. |
| P12 sweep A | 16 September S2/S3 fixes (before view, compare panes, window-resize decode storm…). |
| P13 sweep B | 18 September S2/S3 fixes (search debounce, updater freeze, M-02 version stamp…). |
| P14 colour science | B1-05 Density dark-colour hue turn; AI-07 measured. Two records re-pinned. |
| P15 brush | M04 + S-10 resolution independence (one band above 2048 px open). |
| P16 perf | four byte-identical hotspots: 5–7× on fingerprint/slider tick, grid refresh 185→40 ms. |
| P17 polish | curve editor VoiceOver, mask overlay staleness, warnings. |
| P18 raw refusal | null-extent RAW decodes refused instead of reaching the graph. |
| P21 geometry | KG-03 cropped portraits. K-056 (first card open) specced only. |
| F1 denoise | already on GPU; tile-halo miscount 24→79 px; README corrected. |
| F2 LUTs | creative `.cube` LUTs, display and log taps, both renderers. |
| F3 HDR | opt-in EDR loupe preview (View ▸ HDR Preview). |
| F4 heal | Heal/Clone spots, `Q`. |
| F5 culling | sharpness score, bursts, closed eyes; filters + grid dot. |
| R1/R2 | adversarial re-audits; four weak tests and two merge breakages caught and fixed. |

## NOT on trunk at close (branches kept locally, reports inside them)
- **P5 colour (AI-03, AI-02, float cube lookup)** — `worktree-agent-aa91835df5f0c7bd3`. Conflicts
  with three landings in RenderCoordinator / PreviewCache / Kernels; an integration agent was
  working on it at close. Moves all 50 colour proof records: land, then dispatch `proof.yml`
  with `record_proofs` and commit the artifact.
- **F8 heal second slice** — `worktree-agent-ac34044782a712106` (conflicts in AppState, RenderGraph, README).
- **R2's catalog clamp variant** — `d91abfe` on `worktree-agent-acd084c346e07dc47`; trunk carries an
  equivalent clamp (`min(recipe.pipelineVersion, supportedPipelineVersion)`); R2's sidecar-stamp
  note in CatalogService is still open.
- **Q2 docs refresh** — `worktree-agent-a06da12c9166cc51d` (README conflict).
- Streams still running at close: F6 output/gain-map writer, F7 library, P19 panel honesty,
  P20 RAW corpus, Q1/Q3–Q7.

## Container caveat
Branches named `worktree-agent-*` exist only in this container. Anything not on
`origin/claude/jolly-sagan-k7ch7z` is lost if the container is reclaimed.

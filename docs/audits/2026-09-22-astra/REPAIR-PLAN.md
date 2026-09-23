# Lumen verified repair programme

Started 22 September 2026, following the owner's authorization to plan and implement the audited fixes with continuous verification.

## Baseline and safeguards

- Working branch: `codex/lumen-verified-repairs`, based on the newest audited development revision `a6e694103a3676e059847ac48b82c0031281ea53`, with the audit documentation copied by commit. Main and the installed application are not changed.
- The installed build's origin remains unknown. This does not block isolated development, but must be resolved before migration/installation testing.
- The original audit is a historical record. Corrections and repair evidence belong in this plan and the repair ledger; do not rewrite old results to appear green.
- No private photographs, original sidecars or live catalog are edited or published. Reproductions use temporary catalogs, synthetic fixtures and private RAW copies.
- No repair is pushed into an automatic distribution path before release gating is addressed. No production installation, migration, automatic merge or release without an explicit handoff decision.
- Existing newer-branch fixes are retained. AI-11, AI-12 and AI-14 start as **inherited, requiring regression verification**, not newly fixed by this programme.

## Definition of done for every finding

Owner decision, 22 September 2026: **preserve the intended current creative look; fix inconsistencies** in film response, halation and colour uniformity. Do not redesign these looks as part of a correctness fix. Flag any unavoidable material change in appearance for approval before implementation.

Later owner clarification for **M10 only**, after being told that exposure-coupled halation could change saved film looks: “whatever makes it look the best.” Evaluate an exposure-coherent, controlled highlight glow with numerical tests and private-photo comparisons; document the chosen contract and compatibility effects before qualification. This is not approval to redesign Uniformity or every creative control.

The original 47-item denominator is retained for historical comparison, not treated as the entire backlog. [Supplemental tracking](SUPPLEMENTAL-BACKLOG.md) explicitly carries inherited expected failures already listed in the audit's test results, plus newly established boundaries. Safety follow-ups take priority over appearance tuning.

1. Read the production path, audit trigger, existing tests and intended user contract.
2. Add a regression that fails for the right reason on the selected baseline. If the audit is no longer reproducible, investigate and document why; do not force a fix.
3. Make the smallest coherent change that satisfies the contract and preserves supported behaviour.
4. Run the new regression and negative controls, adjacent subsystem tests, and appropriate integration/GPU/persistence checks.
5. For pixel changes, compare actual rendered pixels to an independent intended result; for saved-state changes, verify reopen/catalog/XMP; for performance, separate warm/cold, draft/current and settled output.
6. Review the diff for secondary effects, compatibility and unintended public-data exposure.
7. Record commands, red/green outcomes, runtime/environment, commit and remaining limitations. Only then mark **verified** within that explicit scope.
8. At each phase boundary, run the full relevant suite and a cross-subsystem smoke workflow. Carry known failures/skips explicitly. A skipped camera corpus or source-only UI assertion is not an executed workflow test.

Status vocabulary: queued → reproducing → red confirmed → implemented → verifying → verified. Also allowed: inherited awaiting verification, blocked with a concrete dependency, or not reproduced with evidence. Never equate code changed with fixed.

## Phase 0 — establish a repeatable safety net

- Refresh remote refs; preserve current uncommitted work; use an isolated repair branch.
- Save this plan and a finding-by-finding ledger with all 47 IDs.
- Set up temporary fixture/catalog/cache helpers for AppState tests so tests can exercise real application transitions.
- Record baseline failures: main's old hash issue is already fixed in the selected baseline; the newer branch's draft/settle timing-ratio assertion failed twice during audit.
- Keep synthetic data in tests; private RAW corpus opt-in. Never silently use the owner's real application directories.

Exit: baseline identified, test infrastructure builds, no unaccounted source differences, every finding assigned below.

## Phase 1 — prevent wrong-photo edits and lost/rejected state

| Finding | Work | Required verification |
|---|---|---|
| UX-01 | Order undo/redo against queued gesture persistence | Open/closed gestures; undo and redo; release and quit; in-memory, reopened catalog and XMP agree; multiple photos and unrelated pending edits preserved |
| BR-01 | Correct common-ancestor/path identity | Sibling trees with repeated directory names and identical basenames stay distinct; common prefix ends at first mismatch; mixed folder/file selections |
| BR-02 | Distinguish partial registration from full reconciliation | Opening a subset cannot mark unseen photos missing; a true full rescan still detects deleted files; album membership survives |
| REL-01 | Separate corruption from busy/unavailable catalog checks | Exclusive lock with stale backup leaves original untouched; valid/corrupt/missing DB controls; operational errors never authorize replacement |
| REL-03 | Validate already-present ingest against planned size | Matching truncated source/destination fails verification; valid already-present copy succeeds; fresh-copy short read and cancellation still work |
| REL-04 | Make export final publication respect overwrite policy | Concurrent destination creation is preserved; output gets collision-safe name or clear failure; existing intended overwrite semantics remain explicit |
| REL-02 | Stabilize sidecar ownership through sibling transitions | Add/remove same-basename RAW siblings after edits; no inheritance; safe migration/ambiguity handling; reopen and portable XMP checks |
| REL-08 | Publish complete backup snapshots atomically | Blob-copy failure never creates eligible incomplete snapshot; restore actual brush; interrupted publication; legacy complete backup compatibility |
| REL-09 | Surface sidecar persistence failures | One actionable notification; retry retains pending edits; recovery clears state; quit handling does not falsely claim portable save succeeded |
| REL-12 | Gate automatic releases on successful checks and intended branch | CI dependency and branch conditions tested/reviewed; feature branch cannot replace shared update feed; failed checks cannot publish; no live release used as a test |

Exit: all above regressions green, catalog/ingest/history/export suites green, isolated edit–undo–quit–reopen and backup–restore smoke tests agree on recipes and brush pixels. Do not proceed to tuning photo appearance while saved-state regressions remain unexplained.

## Phase 2 — trustworthy source pixels and preview identity

| Finding | Work | Required verification |
|---|---|---|
| AI-01 | Validated decoder/working-space policy | All three private RAWs plus synthetic colour checks; retain explicit recipe pins; decoder default/fallback conditions; no unexplained neutral cast; record OS dependence |
| AI-15 | Stable source dimensions independent of decode history | Repeated small/large previews, zoom, orientation and full export; requested render dimensions honoured without oscillation |
| REL-06 | Invalidate changed originals at the same URL | Same-path replacement with different dimensions/pixels/signature; cached previews and render sources refresh; unchanged files remain cached |
| REL-07 | Bind cached pixels to the recipe that rendered them | Delayed preview publication racing newer edits; old pixels never receive new fingerprint; reopen selects correct preview |

Exit: neutral import, thumbnail, interactive preview, settled preview and export derive from the same identified original/recipe. No slider compensation for decoder defects.

## Phase 3 — global colour and slider contracts

- AI-02: picker membership evaluated in a documented stage/domain; test preceding mixer/primaries changes and local contexts.
- AI-03: actual GPU approximation error bounded against intended exact functions; narrow gates, gamut boundaries, deep shadows, legal extremes and moderate realistic edits; compare preview and export resolutions separately.
- AI-04: lifted-black luma continuity and neutrality; exact black, tiny positive values and gray ramp; real GPU output.
- AI-05: curve handles and displayed trace accurately describe editable versus composite curves; parametric and point combinations.
- AI-06: neutral picker honours the full supported tint domain or clearly declares a narrower contract; reachable synthetic neutrals and real RAW controls.
- AI-07: replace or explicitly resolve silent broad tonal flattening under zone combinations; monotonicity alone is insufficient—measure retained tonal separation and actual adjustment authority.
- AI-08: define texture-preserving uniformity/variance behaviour, then implement the required spatial context without breaking cache identity or latency. An artistic tradeoff that changes intended behaviour requires a documented decision.
- AI-09: align accepted black-target range with engine response; numeric input, drag, sidecar load and reset.
- AI-10: align names, painted ranges and actual band ownership; hue ring, overlapping feathers and natural oranges/greens.
- AI-13: correct grading luminance help/range contract and verify scene exposure mapping.
- AI-11, AI-12, AI-14: verify inherited hash portability, contrast protection and wheel colour agreement; preserve their corrected behaviour.

Exit: independent exact/GPU contract tests, gradient and boundary fixtures, control-proof registry and private-photo contact sheets reviewed. Tolerances must describe a real metric; encoded-code equivalents are not Delta-E. No golden updates without explained intentional change.

## Phase 4 — dependable masks and spatial adjustments

- M01/M02: compute the contributing reference dependency closure for source preparation and cache identity; disabled/inverted donors, transitive references, cycles, edits and small-native final export.
- M03: apply local curve results through the chosen mask blend contract; RGB and luma curves under Normal/Brightness-only/Colour-only.
- M04: source-normalized brush coverage independent of raster scale; dabs, strokes, flow, feather, pressure, ceiling, eraser, edge-aware masks and export parity.
- M05: scale negative local sharpness in image space; frequency fixtures at preview/zoom/export sizes and real detail.
- M06: consistent geometry coordinates for crop/flip/vignette; off-centre crops and operation combinations.
- M11: consistent strength above 100 across CPU/GPU and colour/spatial/Kelvin operations; explicitly document any intended cap.
- M12: reject or honour extreme custom aspect ratios; visible ratio, normalized crop bounds and exported pixel dimensions agree.
- M13: ramp-shape help and mathematical direction agree, with alpha-ramp regression.

Exit: same selected region and adjustment intent survive resolution changes, reference edits, undo, export and reopen. Keep real-photo segmentation limitations visible rather than declaring all AI masks accurate after algebra tests pass.

## Phase 5 — honest creative/detail controls and delivery

- M07: film strength smoothly scales intended grain/halation contribution; zero/epsilon/1/50/100 and compositional controls.
- M08: allow or explain the base display-transform contribution in partial film blends; UI enablement matches pipeline.
- M09: reconcile intended halation threshold/response across reference and GPU; independent highlight fixtures, not shared wrong formula comparisons.
- M10: define film exposure's relationship to halation onset and test combined controls; confirm artistic contract before changing an intentional model.
- M14: hide/disable or implement stock-specific inactive halation controls; no enabled dead sliders.
- M15: render-input denoise mode/amount honestly reflects supported consumers; JPEG/TIFF versus RAW and manual override preservation.
- REL-10/REL-11: verify requested resolution and contact metadata after encoding/reopening every supported format; retain metadata privacy filters.

Exit: every visible creative/detail/delivery control has a clear, live or explicitly conditional role; pixel effects and delivered metadata tested, not merely UI binding.

## Phase 6 — performance and native interaction completeness

- REL-05: remove repeated directory enumeration from sidecar resolution; size-scaling benchmark and membership-transition correctness together.
- UX-02: stable gesture-start panel resizing; event-count-independent motion and layout bounds.
- UX-03: native adjustable accessibility roles, labels, values and actions; keyboard and actual VoiceOver verification.
- Resolve the existing PlanCostProbe timing failure with a controlled benchmark and measured architectural change or justified test contract—not an arbitrary threshold increase.
- Investigate the two separately labelled follow-ups: numeric entry on focus loss and cumulative polygon-vertex dragging. Promote only reproduced/established defects, with separate IDs.
- Test every visible control at reset, small step, midrange, ends and numeric hard limits; reverse direction, undo/redo, copy/paste and reopen. Cover representative combined edits after single-control tests.
- Measure first image, warm image, drag drafts, correct settles, mask recomputation, full exports, larger catalogs and memory/cache growth during a long session. Report pointer-to-frame separately from engine time.

Exit: quantified latency and resource budgets on the target machine, no unexplained timing failure, and a coverage ledger that honestly distinguishes automatic, manual and still-unverified checks.

## Phase 7 — integrated release candidate, not automatic release

Use an isolated copy of a representative shoot: ingest → cull → edit → masks → undo → copy/paste → quit/reopen → export → verify metadata → backup/restore. Exercise cancellation and recoverable I/O failure. Compare edited/settled/exported pixels with appropriately matched colour management.

Run full optimized tests, control proofs, actual GPU tests and opt-in private RAW tests. Separate known environmental failures from product failures with evidence. Perform a user-visible review of before/after images. Resolve the installed-build baseline and migration compatibility before installation.

No claim of being better than Lightroom without matched exports and an agreed evaluation. No claim of complete coverage from a test-count total. Owner approval is required before replacing the installed build or publishing an update.

## Separate expansion backlog

Healing/clone, perspective/Upright, local denoise/defringe, new semantic masks, own neural denoise and finished HDR workflows are feature projects, not automatically included as small fixes. Define requirements, architecture, fixtures and acceptance criteria with the owner after core trust is restored. Preserve known good creative tools while doing so.

## Execution record

The machine-readable `repair-ledger.json` tracks all original IDs. Phase evidence and current work are appended below, with exact test commands/results. Local full logs stay outside the repository unless sanitized for publication.

### Start

- Remote refreshed; audited newest development revision unchanged.
- Isolated repair branch created; audit documentation preserved.
- First regression batch: UX-01, BR-01, BR-02, REL-01 and REL-03. Tests will be run red before fixes.

### First implementation checkpoint

Nine findings now have changes under verification: UX-01, BR-01, BR-02, REL-01, REL-03, REL-04, REL-08, REL-09 and REL-12. See [execution record 01](EXECUTION-01.md) for exact reproduced failures, passing adjacent checks, the full-suite run and remaining limitations. This does not close phase 1 or certify any later phase.

### Ownership and recovery follow-up

REL-02 implementation and deeper REL-08 recovery checks are recorded in [execution record 02](EXECUTION-02.md). The first public implementation checkpoint is [draft PR #5](https://github.com/benedek-art/lumen/pull/5). Keep it a draft; no automatic merge, release or installation is authorized.

The next independent Astra lanes and UI-contract consistency repairs are tracked in [execution record 03](EXECUTION-03.md). Source-level UI checks are distinguished from native interaction, and unintegrated agent work is not counted as complete.

RAW, referenced masks, source/preview identity, WB/control contracts, local softening, sidecar scaling and delivered metadata now have integrated changes under combined qualification. The independent [colour-table investigation](EXECUTION-04-colour-lut.md) keeps AI-03 open: measured adaptive alternatives were rejected, and strict expected-failure tests preserve four known accuracy misses while an exact-stage implementation is investigated. M04's partial single-stroke correction was also withheld after repeated paint/erase regressions exposed a larger component-state requirement. Neither is represented as fixed.

The next checkpoint adds local-curve blend semantics (M03), rendered-input denoise availability (M15), and batch export-contact validation. The [exact Mixer prerequisite](EXECUTION-05-exact-mixer.md) is independently tested but deliberately not enabled: mixing it with the old colour cube creates a large zero-crossing discontinuity. The [plan-cost diagnosis](EXECUTION-06-plan-cost.md) replaces an invalid timing inference with mutation-tested operation-count and exact-publication gates, retaining timing telemetry and making no speedup claim. All new repairs remain under integration qualification.

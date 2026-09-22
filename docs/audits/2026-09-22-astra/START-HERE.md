# Lumen — context for future building

Public text-only edition: see [publication notes](README.md). Personal-photo evidence remains local; identifying machine paths below are sanitized placeholders.

Saved: 22 September 2026. Status: audit and planning context only; implementation has not started.

Read this first when resuming with Codex, Claude or another developer. Read the linked evidence before changing the affected system. This document records the state at the audit date, not a guarantee about subsequent repository changes.

## What we are trying to build

Lumen is the owner's personal macOS photo editor, intended to replace their Lightroom subscription. The aspiration is to exceed Lightroom in accuracy, creative flexibility, masking and speed—not merely resemble its interface.

The owner developed it with Claude and requested an independent, deep review by multiple Astra agents. Their immediate concern was that sliders were good but not great and sometimes produced odd results. They described the app as perhaps 80% complete. That was an informal impression, not a measured completion estimate; neither readiness nor remaining engineering effort has been quantified.

The request covered every slider and the whole application. Three Astra specialists plus the coordinating agent investigated colour/RAW, masks/detail/creative tools, reliability/performance and application behaviour. This produced a broad audit, not exhaustive verification of every possible interaction.

## Important correction about audit coverage

**No defensible percentage of the app inspected was measured. Do not describe this as a 90%, 100%, every-line or complete top-to-bottom verification.**

The previous statement “audit complete” meant that the conducted investigation and its deliverables were finished. It did not mean that every subsystem, control, gesture, image type and workflow had been exhaustively validated. The original request was more exhaustive than the testing ultimately achieved.

Coverage included RAW decoding, tone/colour/curves, mask construction and local adjustments, detail/creative effects, geometry, rendering/cache performance, catalogs, XMP, undo/persistence, backups, ingest, export, update/release logic and the main interface. Depth varied:

- 327 control roles were inventoried/traced across two inventories. This includes overlapping roles, non-slider controls and marked unavailable/model-only fields; it is not 327 unique sliders individually dragged and visually certified.
- The existing test suites were executed, including six optimized control-proof tests covering a 135-entry registry. Passing endpoints establish activity or a tested invariant, not universal perceptual correctness.
- Bespoke numerical, actual GPU, RAW and state-transition probes investigated selected risks. Some findings are dynamically reproduced; others are source-confirmed. Read the evidence scope on each finding.
- Actual production views were inspected through an isolated audit host. Coordinate-driven pointer automation was unavailable. Do not claim every native drag, brush stroke or interaction was exercised end to end.
- Real-photo validation used three supplied Sony RAWs. No broad camera/lens corpus, calibrated Lightroom comparison, long-duration stability/memory soak, full VoiceOver study or physical stylus test was completed.
- Every slider combination on real photos and every complete import–edit–export–reopen workflow remain unverified. Source-only suspicions about numeric-entry focus loss and polygon dragging remain separate from confirmed findings.

## Repository and branch state

Repository: `benedek-art/lumen` on GitHub. Local audit checkout: `/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/lumen`.

| Baseline | Audited revision | Date |
|---|---|---|
| `main` | `99c37272b42c211a04262ceb98cfb39355d1ab99` | September 3, 2026 |
| `claude/photo-editor-design-plan-8ahzmm` | `a6e694103a3676e059847ac48b82c0031281ea53` | September 6, 2026 |

The owner does not know which branch their installed build uses. Resolve that before choosing an implementation baseline. Re-check the remote and local state at resume time; these hashes are historical audit anchors.

Last merged work included saturation/hue fixes, highlight/shadow separation, tone/grade limiting and mask erosion. The newer branch includes contrast endpoint protection, wheel hue agreement, slider travel/naming changes, selected-file opening and zoom/layout work.

Three ledger findings are already fixed on the newer branch: AI-11 (architecture-dependent hash test), AI-12 (contrast clipping) and AI-14 (wheel paint/engine hue mismatch). It also introduces BR-01 and BR-02 in selected-file opening. Do not treat a blanket merge as an approved or verified repair.

Most bespoke probes ran against main; newer-branch persistence is commonly established by unchanged-source comparison. The coordinator also built and ran the newer branch's full suite. Those are different levels of verification.

## Findings and evidence to retain

The ledger has **47 prioritized findings: 13 P1, 28 P2 and 6 P3**. These include known issues independently revalidated and branch-fixed cases—not 47 newly discovered, still-open runtime bugs. Priorities are repair priorities, not a numerical readiness score.

Start with these high-impact problems:

- **RAW baseline (AI-01, AI-15):** forced Apple RAW9 plus Lumen's linear-Rec.2020 working context produced a strong cyan cast on all three supplied RAWs. RAW9 was healthy in default/linear-sRGB context on the isolated test file; this is not a claim that RAW9 is universally broken. Mutable decoder dimensions also disturbed preview scale; native exports retained full dimensions.
- **Colour correctness (AI-02 through AI-08):** picker/selection stage mismatch, substantial exact-function versus actual GPU table differences, lifted-black colour artefacts, curve-display mismatch and other range/tonal behaviour. The reported encoded-code-equivalent metric is not Delta-E or a literal final sRGB pixel difference.
- **Mask correctness (M01–M06, M11):** missing disabled-donor input, stale referenced-mask cache, local curve blend bypass, resolution-dependent brush/blur response and geometry interaction. Actual People segmentation missed the small airborne person in one supplied image; that is a specific quality limitation, not a general accuracy score.
- **Edit and identity safety (UX-01, BR-01/02, REL-01/02/06/07/08/09):** undone values can remain queued for saving; selected files can collide or hide unselected photos; lock errors can trigger stale catalog restoration; sidecar ownership, preview identity and backup completeness have reproduced edge cases. Read each trigger and recovery limitation rather than assuming all cases happen in normal use.
- **Delivery/release risks (REL-03/04/10/11/12):** ingest's already-present shortcut, destination publication races, export metadata and release-test gating need attention.
- **Performance (REL-05 and measurements):** folder registration has a quadratic sidecar-lookup path. Warm render timings were encouraging, but some fast drafts intentionally use stale colour tables. Renderer time is not pointer-to-screen latency.

Preserve the strengths: non-destructive recipes, deep creative/local colour tools, working Classic denoise and manual sharpening, useful control mechanics and substantial existing tests. Repair against explicit contracts instead of replacing whole systems without evidence.

Missing usable capabilities include healing/clone, perspective correction, local denoise/defringe, several semantic masks and finished HDR delivery. Recipe fields or a badge are not proof of a functioning feature. Prioritize gaps against the owner's actual photography workflow before implementing all of them.

## Executed test baseline

| Run | Tests | Skipped | Failing |
|---|---:|---:|---:|
| Main baseline, debug, excluding separately run control proofs | 2,321 | 12 | 1 |
| Main optimized control proofs, 135 registry entries | 6 | 0 | 0 |
| Newer branch, optimized full suite | 2,398 | 14 | 1 |
| Newer branch, isolated optimized timing rerun | 2 | 0 | 1 |

Main's failure is the platform-dependent hash test already fixed on the newer branch. The newer branch's failure is a timing-ratio target: an isolated rerun measured draft plan cost at 26.8% of settle cost against a required below-25% ratio. Do not report either complete suite as green. Main also recorded 32 accepted expected-failure assertions across 26 methods; they are not 32 new bugs. Skips include the unset standard RAW corpus and opt-in benchmark/probe utilities.

Environment: Apple M4, macOS 27 build 26A428, Swift 6.4. OS/decoder-specific results require revalidation on the intended shipping environment.

## Recommended build sequence — not yet authorized implementation

1. **Establish the baseline and protect work.** Identify the installed build/current branch; inspect new changes; agree on a working branch and isolated test library. Do not overwrite originals, live catalogs or unrelated work.
2. **Protect edits, identity and recovery.** Reproduce the persistence/catalog/sidecar/ingest/export failures first. Add failing regression tests, then targeted fixes. Verify restart, undo, lock contention, same-name files and complete brush recovery. Review release gating before distributing changes.
3. **Stabilize RAW decoding and dimensions.** Preserve explicit recipe decoder choices, validate fresh-image policy and working-space conversion, and test preview/zoom/export dimensions. Do not compensate for a decoder cast by retuning sliders.
4. **Validate the actual rendered colour.** Compare intended exact functions with the real GPU across near-black values, colour boundaries, narrow selections, typical midranges and legal extremes. Define tolerances and combined-control contracts; do not simply regenerate goldens to hide differences.
5. **Make masks stable across context.** Test dependencies, edits, inversion, blends, group strength, geometry, preview resolution, final export and reopen together.
6. **Complete the missing hands-on audit and speed work.** Exercise every visible slider and native gesture, numeric typing/focus loss, keyboard control and accessibility. Measure input-to-visible-frame and correct-final-settle latency separately; add long-session and larger-library testing.
7. **Close selected workflow gaps and compare against Lightroom.** Use matched representative photos/exports, agreed visual criteria, delivery metadata and shoot-level recovery tests before deciding whether to cancel Lightroom.

For each fix, record: finding ID, affected revision, failing reproduction, implementation commit, passing regression, visual evidence where relevant, branch applicability and remaining limitations. Do not mark a finding fixed from source inspection alone when its original evidence was a runtime failure.

## Fixtures, privacy and current changes

Original user-supplied folder: `/Users/AUDIT_USER/Downloads/pix`. It contained `A7401502.ARW`, `A7401654.ARW`, `A7401693.ARW` and two XMP sidecars. Audit copies are under `work/audit/ui/photos` in this task workspace. All five originals matched the unmodified copies at the final check.

No product code fixes, branch merges, commits, GitHub issues or existing-user-catalog changes were made. The product checkout was clean at handoff. Scratch probes and isolated catalogs are not the user's production library.

Evidence includes personal-photo thumbnails. Keep this bundle local/private unless the owner explicitly authorizes sharing. No RAW originals are included in the deliverable. The evidence harnesses include machine-specific paths and are not a turnkey test package. Temporary build directories may not survive; retain source/log evidence and rebuild when resuming.

## Reading order and durable files

1. [Visual audit](Lumen-Audit.html): screenshots, comparisons, searchable ledger and controls. Open this file directly; the audit's temporary localhost server is not required.
2. [Written audit and full finding index](Lumen-Audit.md).
3. [Structured findings](findings.json): exact IDs, triggers, source locations, branch status and evidence scope.
4. [Control inventory](control-inventory.json): what was probed versus source-traced or unavailable.
5. [Colour and RAW detail](details/colour-raw.md), [masks/detail/creative detail](details/masks-spatial.md), [reliability and performance](details/reliability.md), [UI inspection limits](details/ui-inspection.md).
6. [Executed test results](details/test-results.md) and [evidence guide](evidence/README.md).

Keep the `outputs` folder together so relative links and images continue to work. This context is explicitly saved to disk; do not assume a new conversation automatically inherits it. Give the next agent this file and the audit bundle.

## Resume prompt

> Read START-HERE.md and the linked Lumen audit evidence before making changes. First inspect the current repository/branch and compare it with the audited revisions. Summarize what has changed, which findings still apply and the next bounded implementation phase. Preserve originals, existing catalogs and unrelated work. Do not treat the audit as exhaustive, assume the installed branch, repeat already-fixed findings as new, or claim superiority to Lightroom without comparison evidence. Begin implementation only within the scope I authorize next.

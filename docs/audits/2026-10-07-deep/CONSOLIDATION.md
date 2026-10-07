# Consolidation inventory — 7 October 2026

Baseline: public main `56434971cf57dfc3f87f4603477d2d96ea3baab9` (October 2 merge #6).

The September working directory and its sibling worktrees are preserved untouched. All Git refs were captured in a local bundle, all dirty tracked files in patches and relevant untracked source/test/report files copied to local preservation storage. These backups contain no new uploaded photographs and are not publication artifacts. Do not delete the September worktrees until the consolidation is verified.

## Unpublished September commits

| Commit | Disposition | Reason / next check |
|---|---|---|
| a9a9f8a | superseded production; retain evidence | October P4 implements deletionCoalescingKey=nil and real app persistence regression tests. |
| 1a64eef | superseded wiring; retain evidence | Current deletePoint lives in observing CurveEditorView and current history tests cover two discrete deletions. Old checker line-location changes should not replace newer checker. |
| dde18c4 | archive experimental implementation | ExactColorPrefix/ExactMixer candidates were non-enabled prerequisites. October exact S9 is connected and replaces them; importing dead duplicate kernels would expand failure surface. |
| 43a0721 | adapt missing contract to current implementation | October per-photo BatchFraming is newer but silently skips ineligible targets, still guesses primary dimensions and clamps orientation swaps. Preserve all-or-none/refusal/identity checks by porting the contract, not replacing CropPanel wholesale. |
| f98ca78 | superseded ingest implementation; retain evidence | October P1 implements landing claims and directory identity refusal independently. Audit remaining filesystem aliases separately. |
| 75b4e15 | retain qualification evidence | Native contrast intersection report records an untested legal combination; rerun against current main. Wheel paint qualification remains useful, not a new production repair. |
| cdcaa5b | partly superseded with different progress contract | Current P1 progress intentionally reaches 100% when attempts finish and reports failures separately. Preserve current explicit semantics; revisit delivered-byte accounting and primary-folder navigation with behavioural tests. |

## Dirty local work

- Main September repair checkout: stricter GPU availability guards and inherited qualification report/ledger edits. Report archived here; old live ledger is historical and must not become current completion accounting.
- Ingest checkout: re-ingest tests and proposal. October P1 has idempotent re-ingest, so compare regressions before duplicating tests.
- Mask checkout: unfinished BrushScale changes. October P15 is newer. Retain candidate but do not wire an older raster algorithm into current rendering.
- Preview checkout: stricter GPU availability guards, retained locally.
- Other discovered sibling worktrees were clean.

## Publication policy for this run

The user requests one main containing the useful work, a top-to-bottom audit, a detailed plan and parallel repairs. Integrate reviewed fixes and preserved written evidence; do not enable failed prototypes merely to claim every branch was merged. No installed app replacement, updater release or upload of private photos is part of this request. Merge only after relevant baseline/integrated checks and independent review; preserve unresolved test failures explicitly rather than silently loosening their thresholds.

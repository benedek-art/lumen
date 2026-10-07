# October 7 — crop request safety reconciliation

Current October BatchFraming fixed per-target angle arithmetic but left discrete ratio/swap requests partially applied when one selected file had unknown/unrepresentable dimensions. Before decode, the primary could also authorize requests from a guessed 3:2 frame. The unpublished September crop branch contained useful safety contracts absent from main; this change adapts those contracts while preserving October BatchFraming angle handling, menus, Original and Reset behavior.

## Changed behavior

- Ratio and swap requests preflight all selected sources using their own oriented metadata. Unknown/unrepresentable dimensions refuse the whole request with a filename/range message. No guessed frame authorizes those mutations.
- Metadata reads run off the main actor, propagate cancellation and check source identities before/after reading.
- Before committing, the selection, primary, source identities and geometry must still match. Other edits such as exposure are preserved because only the planned crop is written.
- A successful request records one existing updateRecipe/history operation. Failed requests write no recipes/history. Only successful custom requests enter recent-ratio history.
- Impossible reciprocal swaps are declined in BatchFraming as well; legacy CropGeometry recipe interpretation stays unchanged.
- The padlock and resize overlay honor a requested session lock only while it matches actual crop geometry and usable frame. Undo or changed source geometry cannot force a stale ratio on the next drag.

## Evidence

An added BatchFraming regression returned a normalized 0.35:1 crop for a requested 1:140 swap on a 7:1 source. The new test failed before the checked swap repair, then passed afterward.

Focused suite covers generated TIFF orientation metadata vs rendered dimensions; all-or-none unknown/impossible batches; selection, framing, primary and source replacement races; preservation of concurrent tone edits; cancellation; duplicate targets; representability boundaries; lock invalidation without mutation; and existing angle, crop tool and scope tests. Existing source-only custom-parser assertion was retired because the async production tests now verify source eligibility directly. Existing BatchFraming routing assertion was updated for the new discrete request path.

No user originals were touched. Real RAW camera dimensions, real image appearance, on-screen interaction and device accessibility remain later validation gates. Existing asynchronous fixture cleanup emits sandbox bookmark and closed-catalog diagnostic messages; these do not fail the focused assertions.

Final validation: native SwiftPM macOS compilation and 51 focused tests passed, zero failures (`CropAspect|BatchFraming|CropGeometry|CropRatioLimit|BatchCropPanel|CropTool|CropScope`). Log: `/private/tmp/lumen-oct07-app-final.log`. `git diff --check` passed. Full optimized integration suite belongs to the consolidating parent.

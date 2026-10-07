# M12 — source-aware crop-ratio eligibility

Base: `1dda467249a2c4ac3692ff0d3ced357bd6dacbc2`.
Branch: `codex/lumen-crop-ratio-validity`.
Commit: `998fde887e359bbb8d7f41fafb33ee871c80c5d7` (7 owned source/test files; clean worktree, no push/merge).
Scope: new ratio/preset/recent/custom requests, orientation swap, and read-only session lock eligibility. No renderer/pixel math, persisted recipe schema, parser limit, minimum crop extent, or cache revision changed.

## Reproduction and boundary

The unchanged parser accepts `60:1` and `1:60`. Legacy `CropGeometry.refit` on a 6000 × 4000 source at 0° produces actual continuous pixel aspects **30** and **0.075**, respectively, because both normalized crop edges are constrained to at least 0.05.

For the current straightened usable frame aspect A, the exact continuous feasible range is `[A × 0.05, A / 0.05]`. This is not a global parser restriction: a 12000 × 1000 panorama can represent 60:1, and its tall counterpart can represent 1:60. Integer output pixel rounding remains unchanged and can introduce subpixel-scale ratio rounding at delivery.

Red: six new constraint tests were first compiled against checked entry points extracted with the old permissive behavior. **27 tests, 69 expected assertion failures, 0 unexpected failures**; 21 existing CropGeometry/CropReangle cases remained green. Explicit legacy readback assertions established the 30 and 0.075 values above.

## Implementation

- `CropAspectConstraints.swift:7`: finite source/angle-aware domain. Checked refit/swap return nil rather than silently clamp an impossible new request. The legacy geometry functions still interpret existing recipes unchanged.
- `CropAspectConstraints.swift:48`: an effective session lock must fit the current frame and agree with the current normalized crop. Reading eligibility does not mutate the crop or stored session lock. An old invalid lock, changed source shape, undo, or a newly incompatible straighten angle makes it inactive.
- `CropAspectEdit.swift:33`: whole-batch planning uses each target's own geometry and oriented source dimensions. One unavailable or unrepresentable target rejects the entire request with the filename, angle/source-aware range and an explicit no-change message. Duplicate URL entries are rejected in plan, snapshot comparison, and production application before constructing a keyed dictionary; no trap or silent overwrite.
- `CropAspectEdit.swift:69`: metadata is read off the main actor. Source generation is checked before/after reading and before application. EXIF orientations 5–8 transpose dimensions; missing dimensions are never replaced with 3:2. The primary is treated like every other target, avoiding the sensor-oriented `primaryFrameSize` that may precede whole-frame reconciliation. A cancellation handler forwards parent cancellation to the detached worker.
- `CropAspectEdit.swift:106`: selection, primary identity, target geometry and source generation are revalidated after the asynchronous read. Whole recipes are not snapshotted for replacement. The final synchronous photo-aware crop-only write preserves concurrent unrelated adjustments and groups the action through existing history/persistence machinery.
- `CropPanel.swift:761`: standard, recent, custom, and swap actions share the checked request path. A rejected custom value remains in the field and does not enter recents or arm a false lock. New requests wait for real dimensions; text controls are disabled while a request is pending.
- `CropPanel.swift:653` and `ViewerOverlays.swift:1971`: padlock display and resize gestures use effective eligibility. Inactive old locks are explained visibly; merely inspecting a saved photo never refits its crop. Original/reset still perform their explicitly requested existing actions.
- Layout source citation updated to `CropPanel.swift:363`; no thresholds loosened. New messages wrap outside the fixed-height entry row.

## Qualification

First green: **98 optimized native tests, 0 failures, 0 skips** (63 core; 35 app), build 104.75 seconds. Includes 16 new tests at that point.

Second green: **116 optimized native tests, 0 failures, 0 skips** (63 core; 53 app), build 110.20 seconds. Added a real CropTool read-only lock test, primary-selection race control, clarified parser-vs-source range copy, removed the unsafe primary-size override, and included the correctly named PanelLayoutBroadcast suite.

Final qualification: **118 optimized native tests, 0 failures, 0 skips** (63 core; 55 app), including **19 new tests** (7 core constraints, 12 app behavior/integration/source-contract tests). Build: 126.53 seconds; core test execution 0.019 seconds, app 10.239 seconds. This includes the final duplicate-selection and bounded cancellation controls. The selected suites are CropAspectConstraints, CropAspectEdit, CropGeometry, CropDrag, CropReangle, FrameOrientation, LayoutMetric, LayoutMetricSelf and PanelLayoutBroadcast. `git diff --check` is clean.

Dynamic scope: real temporary TIFFs, ImageIO metadata orientation readback independently compared with RenderedImageSource, original byte equality, fully separate temporary AppState catalogs and caches, actual multiple selections, successful application, all-or-none refusal/history negative controls, and deterministic injected interleavings for concurrent exposure, framing, selection, primary, and atomic same-path source replacement. No personal source/catalog was opened. User defaults temporarily touched by the existing open-folder path are saved/restored by the test fixture.

Evidence logs: `lumen-crop-ratio-red.log`, `lumen-crop-ratio-green.log`, `lumen-crop-ratio-final.log`, `lumen-crop-ratio-qualified.log` in the local temporary evidence directory. The no-file-I/O follow-up harness is `CropRotationFollowup.swift` alongside this report.

## Newly discovered separate follow-up: batch straightening

**Not repaired or claimed qualified by M12.** `CropPanel.angleBinding` (currently line 801) and `LoupeView.applyRotation` (line 1952) still capture the PRIMARY source size, then use the ordinary selection-wide recipe mutation to reangle every target. A differently shaped selected photo therefore gets the wrong normalized crop when the angle slider, rotate gesture, or ruler operates on the selection.

Deterministic actual-core reproduction: both targets start with `Crop(x:0.25,y:0.25,w:0.5,h:0.5)`, angle 0°. Primary is 6000 × 4000; another selected target is 4000 × 6000. Reangle 0°→15°:

- Applying the primary's dimensions to the portrait target produces actual aspect **0.3534655405829404**.
- Reangling the portrait target with its own dimensions preserves **0.6666666666666666**.

`CropRotationFollowup.swift` links the actual optimized LumenCore object, asserts both values/tolerances, and performs no file IO. M12 makes a now-mismatched lock inactive, but deliberately does not expand into a redesign of per-event batch straightening. Discrete ratio and swap requests do use every target's own dimensions after this change.

## Limits

- No hosted native pointer/hover/keyboard interaction or visual clipping certification; source-wiring and existing AppKit layout metric tests only.
- Source dimensions are the standard ImageIO source-header dimensions with EXIF orientation; real TIFF orientations 1/6/8 and all eight pure orientation rules tested. This bounded run is not a new all-camera RAW decoder/dimension qualification.
- Generation fencing uses the existing stat identity, not a content hash or filesystem lock. There is no filesystem watcher here, nor protection against an external writer changing the file after the last synchronous check.
- All-or-none refers to preflight and the in-memory/history application. Existing per-photo catalog/sidecar durability/failure handling is unchanged; this is not a new cross-file transactional persistence guarantee.
- An inactive session lock is retained as session state and may become effective again if the same source/framing is restored (for example by undo). Explicit padlock, new ratio, original/reset actions replace or clear it as before. Merely reading it never rewrites a saved recipe.
- Async metadata reads occur once per discrete request, not per drag. Cancellation stops between file reads and cannot interrupt a single in-progress ImageIO read. The test uses a bounded semaphore barrier, no sleeps, and checks no canceled dimensions are published/no second file is visited. Large-selection latency was not benchmarked; no responsive-I/O cancellation or speedup claim.


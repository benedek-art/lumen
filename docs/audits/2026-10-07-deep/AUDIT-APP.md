# Lumen whole-app audit — App/UI, interaction, packaging and status

Baseline: main 5643497; source-read audit, no full suite or hardware UI session run by this agent. Findings below distinguish verified source paths from proposed improvements. No RAW photos are needed for the immediate work.

## Immediate repair candidates

### APP-01 P1 — Crop edits silently partially apply to a selection
Evidence: `Sources/LumenApp/CropPanel.swift:724–734` applies BatchFraming individually and leaves a target unchanged when it returns nil. `Sources/LumenCore/Model/BatchFraming.swift:58–82` refuses unknown frames/unrepresentable ratios per target. `Sources/LumenApp/AppState.swift:437–450` asynchronously fetches selected dimensions. Click immediately after a multi-selection change and some selected images can be skipped; there is no result/count/refusal surfaced.
Impact: “apply ratio to selection” can change only the primary, while appearing successful. This is not data loss, but a substantial editing consistency bug.
Repair: a discrete ratio/swap needs a preflight plan for every edit target with known, oriented dimensions; either all targets apply or the UI explicitly reports the skipped targets. Prefer the September all-or-none contract. Preserve current BatchFraming per-target angle functionality.
Validation: mixed portrait/landscape, unknown second frame, unrepresentable ratio, selection changed during metadata read, unrelated exposure edited during preflight; verify no partial recipes/history/persistence on refusal and one undo step on success.

### APP-02 P1 — Crop requests can be authorized from a guessed primary frame
Evidence: `CropPanel.swift:686–690` returns assumedFrameAspect × 1 when the decoded frame is unavailable; `CropPanel.swift:737–739` passes it as fallback; `AppState.swift:460–470` accepts this fallback for primary. Single selections do not get catalog frames (`AppState.swift:441–443`). A portrait source before decode can receive landscape arithmetic.
Repair: guessed dimensions may support layout but cannot authorize discrete crop geometry mutations. Read oriented source metadata, validate identity before/after, and decline with an actionable message when unavailable.
Validation: synthetic portrait JPEG with EXIF orientations 5–8, selection before delivered frame, missing/unreadable source, source replacement during metadata read. Confirm geometry computed from source size rather than guessed 3:2.

### APP-03 P2 — Crop orientation swap does not refuse impossible reciprocal ratios
Evidence: `BatchFraming.swift:77–81` calls legacy `CropGeometry.swappingOrientation`; `CropGeometry.swift:561–570` caps the desired ratio and then normalizes. CropPanel swap (`783–790`) accepts the new actual ratio. September branch had checked swap refusal; October is not equivalent.
Repair: keep legacy recipe interpretation unchanged; new UI requests use a checked reciprocal eligibility helper. Explain supported aspect range and avoid modifying photo/lock/history on refusal.
Validation: 7:1 frame and 140:1 narrow crop; exact feasible-boundary ratios; angles 0/45/89; swap twice restores feasible cases.

### APP-04 P2 — Crop padlock can outlive the crop it describes
Evidence: `CropPanel.swift:632–635` displays locked whenever a session ratio exists; ratio eligibility/match is not checked there. Undo can restore prior recipe geometry without restoring session lock. Source dimensions can become known after an assumed-frame edit. September effectiveLockedAspect helper explicitly covered undo/source-change mismatch.
Repair: derive effective lock read-only from requested session lock, actual displayed aspect and current source frame; do not “fix” the recipe while reading UI state. Invalid requested lock becomes inactive and shows unlocked. Audit LoupeView's drag lock consumers too.
Validation: ratio then undo, custom ratio then original then undo, source extent change, swapped ratio then undo; next handle drag must not snap back to stale lock.

### APP-05 P2 — Updater terminates after a failed relaunch
Evidence: `Sources/LumenApp/AppUpdater.swift:327–329` ignores `NSWorkspace.openApplication` failure then unconditionally terminates current process.
Repair: terminate only after launch succeeds. On failure keep running and explain that update installed but relaunch failed; offer manual retry. Separate post-install errors from pre-install “untouched” message (`331–334`) since bundle replacement already succeeded.
Validation: injectable relaunch operation throwing; assert termination is not requested and message accurately says installed. Success invokes termination once.

### APP-06 P2 — Updater still performs large synchronous work on main actor
Evidence: AppUpdater is MainActor; `263–265` reads/hashes entire downloaded zip; `316–317` copies app bundle and replaces it synchronously. Process waits were fixed, these expensive phases were not. UI can freeze on a large archive or slow destination.
Repair: detached file-work helper with immutable inputs, bounded file cleanup and results returned to main actor; keep alert/UI transitions main actor. Avoid a full-memory Data payload where streaming SHA is practical.
Validation: helper checks digest, stages same-volume bundle and returns result. A synthetic slow worker must not block main-actor heartbeat. Real installed-bundle replacement remains manual gate.

### APP-07 P3 — Updater temp extraction directories are not cleaned
Evidence: AppUpdater `272–277` creates unique work directory; only staged destination gets cleanup (`315`). Success, codesign failure and extract failure leave extracted bundles in temp.
Repair: register defer immediately after work creation to remove directory on all exits. Preserve installed/staged bundle policy.
Validation: extraction/signature/replacement injected failures each leave no scratch directory. No need RAW or app launch.

### APP-08 P2 — Browse scan includes directories named with image extensions
Evidence: `Sources/LumenApp/AppState.swift:3051–3059` requests `.isRegularFileKey` but never checks it, filtering only extension. A directory `album.jpg` enters results as a photo and gets registered/decoded.
Repair: require resourceValues.isRegularFile true (explicit symlink policy); collect/report enumeration errors rather than silently treating an unreadable directory as empty roll. Keep recursive directory opening behavior.
Validation: synthetic temp tree with photo file, `.jpg` directory containing photo, non-image regular file, broken symlink. Directory is never a photo but its nested valid photo is scanned.

## Release/CI repairs and improvements

### APP-09 P2 — Publishing deletes known-good rolling release before replacement succeeds
Evidence: `.github/workflows/ci.yml:221–230` force-moves tag, deletes release, then creates replacement. Upload/network failure leaves no dev-latest release even though comment promises failures preserve existing release.
Repair: stage an immutable SHA-addressed candidate with its asset/digest first, verify it; only then promote the updater-visible release. If retaining fixed-tag architecture, upload/validate replacement assets before deleting prior assets and define recovery. Do not weaken current tip-of-main gate or optimized-suite gate.
Validation: mock gh command failure at each stage, assert previous release remains available until candidate verified. Release-policy script should reject delete-before-stage pattern.

### APP-10 P2 — Release gate does not aggregate independent RAW/UI/GPU workflow results
Evidence: ci publish-release needs only ci jobs (`ci.yml:187`). RAW corpus, GPU parity and UI layout are separate workflow files. Full optimized suite provides GPU test coverage, but fetched RAW corpus is not part of that local suite and independent workflow failures do not prevent publishing.
Repair: classify current corpus assertions before making noisy thresholds blocking. Then unify validated corpus/layout checks into reusable required jobs or verify exact-SHA successful check runs before promotion. Never interpret “green main ci” as all checks green.
Validation: exact SHA with failing required check must not promote; older green check does not count; cancelled/missing required check refuses. Hardware EDR/native accessibility tests remain explicitly deferred.

### APP-11 P2 — Feature/status documents contradict current implementation
Evidence: README `41` says HDR viewport unbuilt; `Sources/LumenApp/EDRViewport.swift` implements an fp16 CAMetalLayer and headroom tracking. README `37` lists snapshots; HistoryPanel `39–44` explicitly refuses wiring snapshots because no per-photo persistence. BUILDING `421` says gain-map output attachment is missing despite October implementation. raw-corpus.yml header says lane never run despite runs already reviewed by parent.
Repair: one verified feature ledger links source, tests, limitations, camera/hardware gates and benchmark provenance. Rewrite README summary and add historical labels to BUILDING session notes. Avoid inferring implemented from Recipe fields or tests that merely scan strings.
Validation: source-backed review; named owners and last-verified SHA; docs checks for known obsolete claims. No new false assurance about real-photo output.

## Product and validation backlog

### APP-12 P2 improvement — Persistent per-photo snapshots
Current HistoryStack snapshots (`HistoryStack.swift:235–250`) have recipe/name/date but no photo identity or persistence; HistoryPanel correctly exposes none. Session history clears on folder switch (`AppState.swift:3075`). Add snapshot rows bound to catalog photo identity with recipe and blob dependencies; restore through regular persistence/preview invalidation. Do not merely expose the current global array. Tests: two photos, relaunch, rename/delete, undo restoration, blob-backed LUT/brush dependencies, catalog backup/recovery.

### APP-13 P2 improvement — Durable export/ingest result report
`AppStateActions.swift:469–477` stores count and first failure only in transient status text. Large batch troubleshooting needs per-file outputs, renamed destinations, skips/failures and operation timestamps, with copy/save/reveal actions. Existing engine progress likely provides the data. Test structured reporting with two failures/collisions and cancelled run; preserve accurate partial completion wording.

### APP-14 P2 improvement — Missing-original relinking and availability surface
Source currently handles unavailable decoding, but no app relink surface was found. Add catalog-backed missing-file status, locate-one/locate-folder workflows with file-identity checks and preview invalidation; do not bind changed photos solely by matching filename. Tests copied synthetic originals, moved folder, duplicate names, replaced file, offline volume; real external volume gate later.

### APP-15 P2 validation — Native accessibility and keyboard flow
October P17 added wheel/curve AT actions, but explicitly could not inspect native accessibility tree in headless tests. Help strings are not accessibility labels. Build a launched-window accessibility smoke lane for crop icon controls, history rows, survey removal, mask component creation, export stop, disabled controls and tab order. Synthetic RGB photos suffice. Use meaningful action/value assertions; avoid tests that only count source string literals. Full VoiceOver/device audit later.

### APP-16 P2 validation — Interaction/memory benchmark on synthetic catalog
Current performance fixes improved query/deferred persistence. Establish generated catalog (5k–20k entries) and instrument next-photo/drag/selection-query latency, resident memory and cancellation under long bursts. Dimensions/metadata supplied by generated JPEGs; synthetic assets expose scheduling and memory defects even without RAW. Separate cold decode cost from prepared-frame interaction. Avoid adding arbitrary performance thresholds until measured on owner hardware.

### APP-17 P3 improvement — Expose parametric curve limiter
P19 report notes CurveStack's parametric slope limiter is private. Current `Sources/LumenCore/Engine/CurveStack.swift:162–177` confirms calculation remains internal. Publish read-only applied-scale diagnostic and explain requested vs effective curve-region adjustment in panel. Preserve exact rendering arithmetic and proof records. Tests diagnostic scale matches bake implementation under adversarial slider combinations. Black target was already aligned to 0...9 in LookPanel (`1322–1324`); do NOT reopen the old 9...15 defect from stale report.

## Sept unpublished-branch reconciliation

Curve deletion and ingest fixes already have October replacements per parent reconciliation. Crop is different: Sept `Sources/LumenApp/CropAspectEdit.swift` provides all-or-none planning, oriented source metadata, before/after SourceFileIdentity validation, selection/geometry guards during async work, and explicit refusals. Sept `Sources/LumenCore/Model/CropAspectConstraints.swift` supplies checked requests/effective session lock while leaving legacy interpretation unchanged. October BatchFraming is valuable and must remain; adapt these safety contracts to its APIs rather than replacing newer CropPanel or importing obsolete UI/tests wholesale. In particular preserve unrelated recipe edits during asynchronous metadata checks and current per-target angle/rotation handling.

## Suggested dispatch ownership

1. Crop safety: CropPanel/CropGeometry/BatchFraming/CropTool + focused tests (APP-01–04). Needs one agent due intertwined ownership.
2. Updater: AppUpdater + injectable filesystem/relaunch helper + tests (APP-05–07).
3. App workflow: scan/result reports/relink in staged order (APP-08,13,14); broad AppState conflicts with crop must be managed.
4. Release/docs: workflows/release-policy/README + ledger (APP-09–11).
5. Later isolated feature wave: persistent snapshots (APP-12), accessibility smoke (APP-15), performance (APP-16), diagnostic readouts (APP-17).

Immediate patches should run targeted tests plus affected macOS compilation; integration runs complete optimized suite and synthetic end-to-end. Visual tuning, EDR appearance, actual decoder/camera output, denoise quality and cross-app colour comparisons remain RAW/hardware gates. Do not use absence of RAW as reason to skip source identity, persistence, filesystem, cancellation or generated-image workflow checks.

# Lumen — whole-app audit and execution plan, 7 October 2026

## Objective and scope

Consolidate every useful saved change onto a current reviewed baseline, inspect the entire app top to bottom, preserve a large prioritized improvement plan, and repair independent high-value issues in parallel. The owner currently has no RAW photographs available. That limits camera and aesthetic acceptance, not data-safety, workflow, numerical, synthetic GPU or metadata validation.

Baseline: main `56434971cf57dfc3f87f4603477d2d96ea3baab9`. The three independent audits cover persistence/library/ingest/output; rendering/colour/detail/denoise/film/masks/heal/HDR; and app/history/interaction/accessibility/performance/packaging/CI. See the domain reports for source locations and distinctions between evidence, hypothesis and product choice.

This is a forward-looking backlog, not a claim that every item is a defect or a promise to finish all feature projects in one day. A title marked feature/product/performance/investigation means exactly that. Prioritize confirmed defects and executable qualification before speculative redesign. The final ledger records what actually landed.

## Consolidation rules

1. Current main is newer than the September repair checkout. Preserve all refs/dirty files before any changes.
2. Compare unpublished commits semantically against October replacements. Port missing safety contracts and retain evidence; do not overwrite newer source or wire obsolete disabled colour/brush prototypes.
3. One integration branch owns the combined tree. Agents use separate branches/worktrees, exclusive file ownership and isolated test scratch paths.
4. Completed code is committed with regressions; integration cherry-picks reviewed commits. Parent tests the combined app and reviews data/compatibility/latency implications.
5. Public repository publication contains source, tests and textual reports only. No private photographs, user catalogs, installed application mutation or updater release is part of this run.

## Verification levels

- **Source-confirmed:** exact current code path supports finding; no executed reproducer claimed.
- **Red reproduced:** ordinary failing assertion or isolated numeric/process probe demonstrates intended failure. Crash probes must say if they tested an expression rather than full app.
- **Targeted green:** focused meaningful tests pass after fix and adjacent contracts remain intact.
- **Integrated qualified:** current macOS release build and relevant combined checks pass; known baseline failures and skips remain explicit.
- **Visual/camera accepted:** owner photos and supported hardware confirm the intended quality. Cannot be earned from source review or CPU/GPU agreement alone.

A test pass is not app-completion percentage. A failed check is not automatically a product defect: classify infrastructure, unrealistic guessed threshold, platform rounding and genuine behaviour separately.

## Execution waves

### Wave 0 — baseline and preservation

Inventory branches and dirty worktrees, archive useful September evidence, prepare current-main worktree, run native optimized suite with isolated caches. Preserve current failure details on colour proof records and RAW corpus; exact SHA matters. Compile and test using native Swift build system if the Xcode build-system dSYM step cannot run within the sandbox.

### Wave 1 — independent correctness repairs, active today

- Persistence agent: PS-01 through PS-05; one owner for CatalogService and durable keyword delta architecture.
- Crop/app agent: APP-01 through APP-04, adapting the missing September all-or-none contract to October BatchFraming.
- Rendering agent: RENDER-01 geometry hardening, then mask characterization without default aesthetic changes.
- Integration owner: PS-06 and OUT-01 filesystem identity; plan/status consolidation, baseline classification and combined review.

### Wave 2 — workflow reliability

Updater lifecycle APP-05–07; photo scanning APP-08; safe release staging APP-09–10; export metadata OUT-02 and hierarchical interoperability LIB-01. Partition AppState/CatalogService ownership carefully. Do not run competing refactors while safety patches are in flight.

### Wave 3 — synthetic quality and performance qualification

Mask matrix RENDER-02–05; stage isolation RENDER-09; denoise/detail NR-01/DETAIL-01–03; HDR OUT-07/HDR-02; caches MASK-02; interaction UX-03/APP-16. Establish measurements before implementation. Add only tests that demonstrate a contract, detect wrong results or identify a real missing proof.

### Wave 4 — bounded feature work

Snapshots, relinking, persistent result reports, scoped smart albums, resize controls, delivery preview and painted-heal source management. Every feature needs migration, undo, source identity, cancellation, cache and failure behaviour—not just a UI control.

### Wave 5 — rendering/model decisions and owner acceptance

Use preserved synthetic sheets as reviewable candidates for colour overlap, spatial uniformity, endpoint deposition, B&W normalization, H-K magnitude, capture sharpening and output-sharpening. Dedicated AI models need license/performance/quality evidence. Never silently change all saved looks by re-pinning records. Version changed rendering and confirm original/recipe compatibility.

## Per-item acceptance template

For each implemented item record: current trigger; baseline reproduction and its scope; chosen contract; exact changed files; meaningful regression and red/green evidence; adjacent checks; combined commit SHA; preview/recipe version implications; memory/latency cost; remaining RAW/hardware/product gates. A refusal must preserve data and explain the next action. Async work must verify source/selection/recipe generation before publication. Failure accounting must count actual delivery, not planned work.

## Prioritized backlog


| ID | Priority | Kind | Work | Owner | Acceptance | Gate | State |
|---|---|---|---|---|---|---|---|
| PS-01 | P1 | defect | Refuse XMP creation after a failed existing-document read | persistence | Read-error injection leaves foreign XMP byte-identical; owed edit survives retry and restart | Synthetic/macOS tests now | integrated-green |
| PS-02 | P1 | defect | Retain owed sidecar edits on safe-write refusal | persistence | Malformed/UTF16/ownership failures retain queue and durable record; corrected document replays safely | Synthetic/macOS tests now | integrated-green |
| PS-03 | P1 | defect | Persist and replay keyword removals | persistence | Remove/fail/quit/reopen does not resurrect tag; ordered delta composition preserves third-party additions | Synthetic/macOS tests now | integrated-green |
| PS-04 | P2 | defect | Recover hierarchical tags using flat leaf projection | persistence | Normal successful save and failed-save recovery yield same dc:subject bag | Synthetic/macOS tests now | integrated-green |
| PS-05 | P2 | defect | Keep shared leaf until last hierarchical membership is removed | persistence | Per-photo batch membership before/after determines leaf delta | Synthetic/macOS tests now | integrated-green |
| PS-06 | P1 | defect | Use actual file identity for verified ingest claims | integration | Hard-link/case alias twins never share one proven landing; normal re-ingest remains idempotent | Synthetic/macOS tests now | integrated-green |
| APP-01 | P1 | defect | Preflight discrete crop requests for every target | app-crop | Any unknown/ineligible target refuses whole request with no recipe/history write | Synthetic/macOS tests now | integrated-green |
| APP-02 | P1 | defect | Never authorize crop mutations from guessed source dimensions | app-crop | Oriented metadata and source identity checked before/after async read | Synthetic/macOS tests now | integrated-green |
| APP-03 | P2 | defect | Refuse unrepresentable reciprocal crop orientation | app-crop | Impossible swaps leave geometry/lock/history unchanged; feasible double swap roundtrips | Synthetic/macOS tests now | integrated-green |
| APP-04 | P2 | defect | Derive effective crop lock after undo/source changes | app-crop | Reading lock does not mutate recipe; mismatched lock cannot snap next drag | Synthetic/macOS tests now | integrated-green |
| APP-05 | P2 | defect | Keep app running when updated bundle relaunch fails | app-updater | Injected launch error never terminates; success terminates once; notice accurately says installed | Synthetic/macOS tests now | integrated-green |
| APP-06 | P2 | performance | Move updater hashing and staging off main actor | app-updater | Slow file helper does not block actor heartbeat; checksum and staging failures preserve old bundle | Synthetic/macOS tests now | integrated-green |
| APP-07 | P3 | defect | Clean updater extraction directories on every exit | app-updater | Success/failure/extract/signature paths remove only owned temporary directories | Synthetic/macOS tests now | integrated-green |
| APP-08 | P2 | defect | Exclude image-extension directories from photo scans | integration | Nested regular image included; directory/broken link not catalogued as photo | Synthetic/macOS tests now | integrated-green |
| APP-09 | P2 | defect | Stage release candidate before replacing known-good updater release | release | Mock failures at create/upload/promote preserve known-good delivery; no release performed during audit | Synthetic/macOS tests now | planned |
| APP-10 | P2 | validation | Require exact-revision release qualification across workflows | release | Old/missing/cancelled checks never qualify new SHA; classify corpus noise before required gate | Synthetic/macOS tests now | partial-release-opt-in |
| APP-11 | P2 | documentation | Publish one current feature and verification ledger | integration | Every implemented claim has code/test evidence; historical BUILDING notes clearly dated | Synthetic/macOS tests now | documented |
| APP-12 | P2 | feature | Persist per-photo named snapshots with blob dependencies | library | Two-photo save/reopen/restore/delete/backup tests; snapshots not global session array | Synthetic/macOS tests now | planned |
| APP-13 | P2 | feature | Keep durable per-file ingest/export result reports | workflow | Report destinations/collisions/skips/failures/cancel outcome; counts reflect delivered files | Synthetic/macOS tests now | planned |
| APP-14 | P2 | feature | Add explicit missing-original relinking | library | Identity/size/signature preflight, ambiguity refusal, transaction rollback and cache invalidation | Synthetic/macOS tests now | planned |
| APP-15 | P2 | validation | Inspect native accessibility and keyboard interaction | accessibility | Generated-image launched-window action/value/tab-order tests; physical VoiceOver review later | Synthetic/macOS tests now | planned |
| APP-16 | P2 | validation | Benchmark interactive latency and memory on generated large catalog | performance | 5k/20k roll, cold/warm next-photo, p50/p95/p99 drag/selection/cancel, memory bounded | Synthetic/macOS tests now | planned |
| APP-17 | P3 | feature | Expose applied parametric curve limiter without changing pixels | app-controls | Readout shares bake calculation, ordinary and adversarial fixtures byte-identical | Synthetic/macOS tests now | planned |
| RENDER-01 | P1 | defect | Bound healing geometry before integer conversions | rendering | Huge finite/nonfinite/overflowed lengths/offsets do not crash; valid off-canvas and ordinary strokes unchanged | Synthetic/macOS tests now | integrated-green |
| RENDER-02 | P2 | validation | Measure tiny-mask resolution boundary aliasing | mask-quality | Resolution matrix around 2048/2049/2050/2550/2730; area and cell error tracked separately | Synthetic/macOS tests now | characterized |
| RENDER-03 | P2 | validation | Measure hard tiny-brush preview/export differences | mask-quality | Feather0/10/50/100 and flow/pressure compared to independent high-resolution coverage | Synthetic/macOS tests now | characterized |
| RENDER-04 | P2 | product | Define endpoint deposition rule for brush strokes | mask-quality | Spacing boundary and reversed-path probes; proposed change needs saved-look version policy | Synthetic/macOS tests now | characterized |
| RENDER-05 | P2 | performance | Bound mixed thin/ordinary brush cold and settle cost | mask-performance | 10/60/200 strokes and 1/3/8 components, evictions/timings/peak memory measured | Synthetic/macOS tests now | planned |
| RENDER-06 | P2 | product | Prototype spatial Uniformity/Variance preserving colour texture | colour | Guided local mean/residual comparison, scale/edge/mask parity; no default look change without review | Synthetic/macOS tests now | planned |
| RENDER-07 | P2 | product | Define normalized mixer overlap versus own-centre authority | colour | Legal core/feather sweeps; choose disclosure or geometry cap with matching ring | Synthetic/macOS tests now | planned |
| RENDER-08 | P2 | product | Decide B&W common gain, band centres and H-K strength | colour | Independent wedges and saved-look migration tests; separate decisions rather than one broad rewrite | Synthetic/macOS tests now | planned |
| RENDER-09 | P2 | investigation | Locate downstream saturation/density hue rotation | colour | Stage-isolated in/out-of-gamut patches identify first responsible stage before repair | Synthetic/macOS tests now | planned |
| RENDER-10 | P2 | performance | Share compatible upstream work across output recipes/HDR renditions | export-render | Before/after output equality incl grain/resize/watermark/dither; bounded master cache | Synthetic/macOS tests now | planned |
| RENDER-11 | P2 | feature | Add painted-heal source drag and re-pick | heal-ui | Coordinate transforms, undo/reopen/blob backup, async stale-result guards | Synthetic/macOS tests now | planned |
| RENDER-12 | P1 | investigation | Classify confirmed unrenderable RAW and uncertain chroma alarms | raw | No blanket all-black refusal; capability/fixture-backed rejection; known-neutral references | Synthetic/macOS tests now | planned |
| CORE-01 | P1 | validation | Requalify contrast intersection inherited from unpublished September tests | colour | Whites+100/Pivot+4/Contrast-100 exact and native GPU; preserve original numerical limits | Synthetic/macOS tests now | planned |
| CORE-02 | P1 | investigation | Resolve macOS versus Linux proof-record drift | proof | Emit fieldwise differences on protectSkin/red hue/BW red; repeated native and Linux runs; no blind re-pinning | Synthetic/macOS tests now | planned |
| OUT-01 | P1 | defect | Prevent same-batch overwrite through case/hard-link aliases | integration | Prior delivery alias always renamed under all policies; normal pre-run overwrite remains opt-in | Synthetic/macOS tests now | integrated-green |
| OUT-02 | P2 | feature | Merge Lumen catalog keyword additions into delivery metadata | export-metadata | Catalog leaf additions merge with embedded source IPTC; keyword switch strips; source removal authority deferred until import/tombstone model | Synthetic/macOS tests now | integrated-green-additions-only |
| OUT-03 | P2 | feature | Implement destination-specific gamut mapping intent | export-colour | Opt-in per recipe; in-gamut unchanged; saturated wedges finite/hue-controlled; real-photo review later | Synthetic/macOS tests now | planned |
| OUT-04 | P3 | feature | Support fit-within W×H and percent resizing | export-ui | Portrait/landscape no-enlarge, zero/extreme dimensions, units and roundtrip presets | Synthetic/macOS tests now | planned |
| OUT-05 | P3 | feature | Offer TIFF LZW/ZIP encoding | export-codec | Generated image pixel readback, declared compression tags and unsupported option handling | Synthetic/macOS tests now | planned |
| OUT-06 | P3 | feature | Reveal/open delivery and save recipe sets | workflow | Correct destinations for renamed/skipped outputs; persistence compatibility | Synthetic/macOS tests now | planned |
| OUT-07 | P2 | validation | Verify HDR delivery metadata and image roundtrip | hdr | Gain map present, SDR base unchanged, HDR peak>1, geometry/resize/watermark correct | Synthetic/macOS tests now | planned |
| OUT-08 | P2 | product | Separate viewing soft proof from delivery gamut policy | export-colour | Export intent explicit; toggling screen proof does not unexpectedly change delivery | Synthetic/macOS tests now | planned |
| OUT-09 | P2 | product | Evaluate luminance-only output sharpening | detail | No chroma fringe/halo, screen/matte/glossy fixtures; version saved-output behaviour | Synthetic/macOS tests now | planned |
| OUT-10 | P3 | feature | Persistent cancellable export queue | workflow | Pause/resume/order/relaunch, atomic completed files and accurate partial report | Synthetic/macOS tests now | planned |
| LIB-01 | P2 | feature | Roundtrip hierarchical keywords in Lightroom XMP | interop | lr:hierarchicalSubject with foreign namespaces and same-leaf tags; documented precedence | Synthetic/macOS tests now | planned |
| LIB-02 | P2 | feature | Persist smart album scope and matching count | library | Current/subtree/catalog results and count match including offline sources | Synthetic/macOS tests now | planned |
| LIB-03 | P3 | feature | Add IPTC title/caption/copyright/job editing | metadata | Schema migration, batch edit/undo/XMP/export/backup coherence | Synthetic/macOS tests now | planned |
| LIB-04 | P3 | feature | Save ingest naming/metadata presets | ingest-ui | Versioned tolerant preset decode; preview and final plan share grammar | Synthetic/macOS tests now | planned |
| LIB-05 | P3 | feature | Expose storage health and backup locations | backup-ui | Last successful backup, usable payload verification, explicit restore preview | Synthetic/macOS tests now | planned |
| LIB-06 | P3 | performance | Cache unchanged sidecar classification during scans | library-performance | mtime/size/generation invalidation, large synthetic directory benchmark | Synthetic/macOS tests now | planned |
| LIB-07 | P3 | feature | Album sets and user ordering | library | Tree moves/reparent/delete/target album survive reopen; query order correct | Synthetic/macOS tests now | planned |
| LIB-08 | P2 | validation | Calibrate sharpness/burst/closed-eye assistance | culling | Generated ground truth and frozen thresholds; never automatically flag/reject photos | Synthetic characterization now; real photos/display/model corpus required before acceptance | planned |
| LIB-09 | P2 | performance | Incremental first-card opening | library-performance | First usable rows before complete walk; cancellation newer-folder wins and scan completeness remains honest | Synthetic/macOS tests now | planned |
| MASK-01 | P2 | validation | Prove mask pick coordinates across geometry/EDR | mask-quality | Crop/flip/rotate/orient generated grid; click samples same stage displayed | Synthetic/macOS tests now | planned |
| MASK-02 | P2 | validation | Adversarial source/matte/brush cache invalidation | render-cache | Replacement and paused stale worker publication never contaminate settled pixels | Synthetic/macOS tests now | planned |
| MASK-03 | P2 | feature | Model-backed sky/object/landscape/depth masks | ai-models | License/model provenance, quality corpus, cancellation/cache/refusal, bounded memory | Synthetic characterization now; real photos/display/model corpus required before acceptance | planned |
| NR-01 | P2 | validation | Measure luminance ISO anchors and texture retention | denoise | Known clean/noisy fields/edges/fine texture; stronger slider not judged only by lower sigma | Synthetic/macOS tests now | planned |
| NR-02 | P2 | feature | Dedicated local AI denoise model | ai-models | Licensed model bake-off, artifact identity, tiles/halo/cache, quality/speed/memory on real RAWs | Synthetic characterization now; real photos/display/model corpus required before acceptance | planned |
| DETAIL-01 | P2 | validation | Requalify Texture band strength and edge coherence | detail | Fine texture/steep gradient/edge wedges, independent band decomposition truth | Synthetic/macOS tests now | planned |
| DETAIL-02 | P2 | feature | Decide proper capture deconvolution or honest supported scope | detail | Richardson-Lucy ringing/noise/amplitude/invariance tests; real camera quality gate | Synthetic/macOS tests now | planned |
| DETAIL-03 | P2 | validation | Measure sharpening halo suppression and grain shipping paths | detail | Graph output authority and halo/grain frequency independent oracle, preview/delivery scaling | Synthetic/macOS tests now | planned |
| GEOM-01 | P2 | feature | Perspective/Upright correction | geometry | Grid/vanishing-line fixtures, crop coverage/interpolation/mask inverse/persistence | Synthetic/macOS tests now | planned |
| GEOM-02 | P2 | feature | Chromatic aberration/defringe implementation | geometry | Channel-offset procedural edges, hue range/threshold, identity when off and localized effect | Synthetic/macOS tests now | planned |
| HDR-01 | P2 | validation | Verify EDR display orientation/headroom transitions | hdr | Native compatible panel, layer raises headroom, overlays align, SDR instruments remain explicit | Synthetic characterization now; real photos/display/model corpus required before acceptance | planned |
| HDR-02 | P2 | feature | HDR delivery preview at reduced display headroom | hdr | Gain-map reconstruction rather than alternate transform, SDR/full/intermediate reference equality | Synthetic/macOS tests now | planned |
| UX-01 | P2 | validation | Whole synthetic shoot lifecycle smoke test | integration | Import/cull/edit/mask/heal/LUT/export/quit/reopen restores all recipe and payload identities | Synthetic/macOS tests now | planned |
| UX-02 | P2 | feature | Discoverable supported shortcuts and tool modes | app-controls | No conflicting bare keys; disabled/unbuilt actions omitted; keyboard and menus agree | Synthetic/macOS tests now | planned |
| UX-03 | P2 | validation | Slider drag/coalescing/undo interruption matrix | history | Mid-drag auto/reset/undo/switch/close retains intended value and durable state | Synthetic/macOS tests now | partial-reset-interruption-green |
| UX-04 | P3 | feature | Speed Edit keyboard-held adjustment | app-controls | Mode conflict/focus/latency/undo correctness; implement only after interaction benchmarks | Synthetic/macOS tests now | planned |
| QA-01 | P1 | validation | Integration release build and full optimized suite | integration | All fixes together; baseline failures tracked separately; expected failures/skips reported | Synthetic/macOS tests now | planned |
| QA-02 | P2 | validation | Linux portable-core verification | ci | SQLite code active, complete diagnostics parse both XCTest formats; exact SHA | Synthetic/macOS tests now | planned |
| QA-03 | P2 | validation | Fault injection for disconnected/full/read-only volumes | filesystem | No partial final outputs, no false success/eject, retry-safe reports | Synthetic/macOS tests now | planned |
| QA-04 | P2 | validation | Recipe/version migration across oldest supported catalogs | compatibility | Unknown fields/presets retained, unsupported blobs/recipes explicit, no silent downgrade | Synthetic/macOS tests now | planned |
| QA-05 | P2 | validation | Mutation checks for high-risk regressions | integration | Remove repair and regression goes red for intended reason; no broad test mirroring | Synthetic/macOS tests now | planned |
| QA-06 | P2 | validation | Owner real-shoot acceptance and Lightroom comparison | owner | Preserve original bytes, difficult skin/highlights/noise/brush/heal/film, reliable completion | Synthetic characterization now; real photos/display/model corpus required before acceptance | planned |
| QA-07 | P2 | validation | Installed build identity and packaging smoke | release | Visible SHA/version matches source; signed bundle launch/update manually qualified | Synthetic/macOS tests now | planned |

## Definition of the next usable milestone

Finish one complete generated-image shoot now and one real owner shoot later. It must preserve original bytes; record/import/restore portable edits; cull responsively; edit/mask/heal with coherent preview and export; produce correctly named/encoded deliveries; survive cancellation/quit/reopen; and give honest failures. Required checks must be green or explicitly unresolved without release promotion. Only the later real-photo pass qualifies appearance, camera compatibility and daily-use readiness.

## Deferred validation register

The unavailable owner RAW set means real camera neutrality/colour, highlight recovery, noise/detail retention and preferred film/halation appearance stay pending. Native tests can compile/render procedural Core Image fixtures and ImageIO deliveries today, but physical EDR brightness, VoiceOver experience, external-volume disconnects and third-party-tool interoperability need their actual environments. Keep fixture-generated evidence and future owner-photo evidence separate.

## Domain evidence

- [Persistence/library/ingest/output audit](AUDIT-PERSISTENCE.md)
- [Rendering/colour/masks/healing/HDR audit](AUDIT-RENDERING.md)
- [Application/interaction/CI audit](AUDIT-APP.md)
- [September consolidation decisions](CONSOLIDATION.md)
- `repair-ledger.json` is the machine-readable companion; updates record actual implementation states.

## Additional defects discovered during repair review

- **PS-07, P1, integrated-green:** Merge newer pending edits after a refused concurrent sidecar flush. Owner: persistence. Acceptance: Fault-injected read enqueues newer rating while older keyword flush fails; both fields persist/replay.
- **PS-08, P1, integrated-green:** Require independent primary and backup file identities. Owner: app-ingest. Acceptance: Same-source cross-directory hardlinks cannot count as two verified copies; ordinary re-ingest stays idempotent.
- **PS-09, P1, integrated-green:** Reject source aliases as verified ingest deliveries. Owner: app-ingest. Acceptance: Source/hardlink/symlink destination never permits eject without independent landing.

The current ledger contains 84 items. The additional four were found by deeper review and deterministic race/alias probes after the initial 79-item audit.

- **PS-10, P2, integrated-green:** restore a tag re-added in the catalog after an older durable removal. Regression requires the current disk tag to be absent, rather than assuming it already exists.

Delivery keyword additions must merge with original embedded IPTC because those tags are not yet imported into the catalog. Removing embedded source tags requires a known imported baseline or explicit tombstones; an empty catalog must not silently delete them.

- **RENDER-13, P1, integrated-green:** macOS 27 Core Image unary Boolean helper conversion omitted a generated Metal destination argument. Four equivalent comparisons compile primaries/mixer/point kernels. Existing 16 colour/roster tests pass; no math or bounds changed.

## Qualification after integration

The first full optimized run executed 3157 tests and exposed macOS 27 kernel conversion failures plus two stale source-test references and a SQLite diagnostic wording change. The kernel defect was repaired against unchanged independent GPU/CPU assertions; source-test references were updated; the index guard now permits SQLite’s optional EXISTS annotation and rejects a deliberately degraded query. The final full optimized rerun executed 3158 tests: 3135 passed, 22 intentional skips and the one reproduced baseline proof-drift failure. All repair-related checks passed. No proof tolerance or golden was altered.

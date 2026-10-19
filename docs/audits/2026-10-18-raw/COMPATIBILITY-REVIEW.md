# Checkpoint-to-head compatibility review

Compared `0f57d65710e8f13b919a06257825507bdd6ff1b4` through `a4bc1506e0e744f58089b56bfbc8953b2d3e6fc0`. This is a targeted source review, not exhaustive feature or aesthetic certification.

Commands: `git diff --unified=0 0f57d65..a4bc150 -- Tests`, and compare changed paths to `git ls-tree -r --name-only 0f57d65`. No changed pre-existing non-Swift artifact whose path contains `fixture` or `golden` was found. No removed `accuracy:`/`tolerance` assertion line or added expected-failure annotation was found. All3 existing expected precision-floor annotations remain unchanged. This mechanical scan is not a proof about every conceivable tolerance spelling or asset name.

Five removed assertion lines required semantic review:

| Test file | Change | Assessment |
|---|---|---|
| CatalogKeywordExportTests.swift | An unavailable catalog previously permitted a stripped-keyword export; now both keyword policies refuse, both destinations must be absent, both outcomes failed, both actual destinations nil | Strengthened preservation policy, not a math tolerance relaxation. Export cannot safely assume current edits were loaded merely because metadata is omitted |
| SidecarConflictRetentionTests.swift | The failed culling write rating0 assertion is replaced by rating0 plus unchanged flag and label assertions | Rating assertion retained and coverage strengthened to the whole refused culling update |

The final post-c7 production delta is one exact identity-flag propagation in absolute local WB. It does not change its matrix or interpolation, and the nonneutral Core control retains the engine result exactly. Its neutral GPU behavior intentionally changes from unnecessary bounded-table sampling to passthrough when the existing engine's exact predicate is true. Native causal and whole-source outcomes must be read from CLOUD-PROGRESS.md; review alone is not execution.

Classic/AI denoise algorithms, camera noise seeds, positive Dehaze formulas, creative defaults and saved recipe data were not retuned to make diagnostics green. Positive local Amount LUT-domain behavior remains an unresolved compatibility decision; no broad continuity repair or reference retargeting was introduced.

# Dehaze sky terms: unresolved CPU/GPU semantics

Read-only production review at `5d1ff3a9793a6ea6487dcf67a304f47bc438e0d1`. No engine, golden, tolerance or saved-look changes. `witness.py` ran once with Python 3.12.14 (exit 0); output is preserved beside it. It computes independent scalar equations, not an execution of either renderer. The values below reproduce the separately reported native bright-flat witness exactly after f32 rounding.

## Cause and independently derived values

Take a neutral flat interior patch `I=.8`, with atmospheric estimate `A=1` from a separate brighter plateau, far from filtering boundaries. This is NOT a globally constant .8 image (which would estimate A=.8 and cancel positive recovery). Here gains and relative luminance trust are one, raw/refined transmission locally is `t=1-.95*.8=.24`, and the shared Distance20 floor is `.55+(.05-.55)*.2=.45`. The CPU log signal is `log2(.8/.18)>2` and flat gradient is zero, so sky evidence `s=1`.

| Branch | CPU equation | GPU equation | CPU/GPU f32 values |
| --- | --- | --- | --- |
| +100 | `(I-A)/max(t, mix(.45,.9,s))+A` | `(I-A)/max(t,.45)+A` | `.777777791023 / .555555582047` |
| -100 | `I+(A-I)*.9*max(1-t,s)` | `I+(A-I)*.9*(1-t)` | `.980000019073 / .936800003052` |

The positive mismatch is exactly the omitted sky transmission floor; the negative mismatch is a DIFFERENT omitted use of the same sky evidence in the estimated distance. GPU does not merely reuse a raised positive floor for the negative branch: it has no sky evidence at all. With sky evidence zero these scalar branches coincide. All amount blends remain continuous; the difference is semantic, not amount units, rounding or a ±100 scaling error.

## Exact source contracts

- `Sources/LumenCore/Image/DetailEngine.swift:101-103`: omega .95, Distance20. `:146-165` builds log2 luminance relative to .18; `:199-215` normalizes by estimated A, dark-channel transmission and guided refinement. `:399-438` defines positive sky floor; `:461-481` explicitly fixes negative depth to `max(1-t,skyness)` so distant sky receives more synthetic atmosphere.
- `Sources/LumenPipeline/RenderGraph.swift:1079-1097` normalizes amount and constructs minimum; `:1139-1198` normalized dark channel and refinement; `:1200-1224` passes only constant floor .45 and no sky plane. `Sources/LumenPipeline/Kernels.swift:145-175` admits missing guard and implements the equations above, including negative `distant=clamp(1-raw,0,1)`.
- Global production call: `RenderGraph.swift:220`, `:911-942`; local production call `:1308-1314` reaches the same presence implementation. CPU global `ReferenceRenderer.swift:80-87` and local `:455-465` reach DetailEngine. Thus both global and masked nonzero Dehaze can differ; this is not a dead CPU function.
- `docs/14-pipeline.md:75-78` says the f32 reference defines math and shipping path must match stage tolerance. `docs/06-spec-detail.md:188-193` promises the sky floor. `BUILDING.md:603-609` explicitly records positive guard as reference-only and describes extra GPU sky stripping. It does NOT describe the missing negative sky-distance term. Kernel comments identify the CPU as reference, not a separately approved GPU creative target.

## Decision still required

Documentation supports CPU as intended oracle, but the shipped GPU has established output and this note does not authorize changing it. Adding the two sky terms to GPU would lighten bright-flat positive-dehaze regions and increase negative-dehaze haze there; saved looks and both global/mask renders change. It also requires matching log/gradient definitions, input stage, proxy scale and tiled field behavior, not an arbitrary brightness heuristic. Changing CPU to match GPU would instead remove an explicitly documented sky-preservation behavior and undo CPU's intentional negative-depth correction; it would weaken the reference rather than prove accuracy. Neither direction is a harmless numeric fix.

Before integration, freeze an explicit product/math decision and qualify bright/flat versus textured/foreground controls, colored airlight, amounts around zero/endpoints, local/group strength and tiled/native exports. Other known estimator differences (CPU top-fraction versus GPU relative-max threshold) can independently affect A on general images; this controlled scalar witness deliberately fixes A and t, and does not certify those estimators equivalent. No broad new acceptance threshold is proposed.

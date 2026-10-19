# Local WB exact matrix candidate

Isolated base `0e9e4a4`. This is a bounded accuracy correction candidate, NOT a general Amount continuity fix or a claim that existing saved looks are unchanged. No old assertions, goldens, defaults or tolerances were changed. The strict wheel Amount diagnostic remains unchanged.

## Production change

`ReferenceRenderer.LocalColourFront.colourStageInput` defines exposure→tone→WB matrix; exact colour and hue/tint/grade follow. Previously GPU LocalPlan fused WB into the bounded log-domain tone cube. The candidate retains tone alone in preLUT and evaluates the exact WB matrix afterward, before exact colour. A nonneutral WB-only edit therefore no longer projects signed/HDR input into the cube domain. Mixed tone/WB still has the tone cube's domain limitation; wheels, hue, tint and point curves retain their separate table limitations.

`LocalPlan.whiteBalance` is nil ONLY when the resolver's exact identity flag is true (or the entire local stage is zero/identity). It stores the same resolver matrix otherwise. The global `applyMatrix` retains its existing1e−12 identity policy. Its unchanged CIColorMatrix construction was factored into `applyMatrixUnconditionally`, so the new local path does not introduce or inherit an approximate matrix bypass. First-order/shaper approximations, epsilon cutoffs and residual-domain extensions were not added.

## Qualification prepared

The NEW three-method `LocalWhiteBalanceExactMatrixTests` uses only APIs already present in0e, so the entire original RenderGraph.swift can replace the candidate with identical tests and still compile:

1. Relative/absolute WB at mask and group Amount0/1e−8/100, cubes33/65, signed/interior/HDR RGB, all-channel independent row-dot matrix oracle and direct ReferenceRenderer comparison at existing1e−3 bound. The group resolves a100-strength mask through the group Amount and must equal the direct mask strength. Normal alpha0/.25/.75/1 uses actual scalar RGBAf images with exact alpha readback; zero controls require full-buffer exact identity.
2. Neutral absolute WB and zero relative/absolute WB retain exact identity and no preLUT, unchanged healthy behavior on the old source too.
3.24 compatibility records compare actual historical fused table, actual shipping candidate and direct CPU, for relative/absolute modes, Contrast0/30, Amount1e−8/1/100, cubes33/65. Each logs graphAssemblySeconds and completedSeconds around actual shipping graph plus synchronous RGBAf readback, excluding counterfactual old-table work. This is tiny generated-fixture ordered timing, not a GUI/RAW/statistical speed claim. Mixed tone CPU agreement is measured, NOT approved by a broadened tolerance.

Native execution has NOT occurred here. Syntax-only macOS-target parse and diff checks passed. Hosted baseline should run all3methods GREEN on the candidate; replace the ENTIRE production RenderGraph with `git show 0e9e4a4:Sources/LumenPipeline/RenderGraph.swift` (helper script supplied) and require the first strict WB test RED while neutral/zero and finite compatibility controls remain GREEN. Restore the exact candidate hash before further work. This proves the actual old bounded route fails, rather than merely disabling a new wire. Existing mixed temp/tone table-size and zero/neutral tests remain unmodified and must pass natively.

## Executed portable compatibility evidence (not GPU execution)

Fresh output directory `/workspace/scratch/2982a056243e/local-wb-exact-portable` holds driver, full129-source Core manifest, compile command/log, execution log/status and summary. All129 current Core Swift hashes exactly matched `neutral-kelvin-evidence/fixed-postbuild-core-sha256.json` before linking actual release Core objects. Driver used actual public ToneEngine, LocalWhiteBalance, LUT3D bytes and LumenLog, with explicitly implemented trilinear interpolation of those bytes. Core `LUT3D.sample` is tetrahedral, so it was deliberately NOT used. Portable interpolation uses Double arithmetic and is not a numerical certification of the GPU Float kernel, new RenderGraph or CIColorMatrix. Direct CPU equations use the actual tone and WB functions; the full ReferenceRenderer entry point was not executed in this portable driver.

Initial compile rejected unnecessary `@testable import` because the release module was not built for testing; exact error archived as `initial-compile-module-not-testing.log`. Changed only that import to ordinary public `import LumenCore`. Compile and single execution then exited0,24 records, no Signal4/retry.

Across12 WB-only configurations, new direct matrix matches the direct CPU equations exactly in this portable arithmetic. Historical route exceeds1e−3 on multiple signed/HDR/interior patches (exact count in summary.json). At epsilon, signed R old≈−4.937137e−6 versus direct≈−.01; HDR R old737.28 versus direct≈1024. This independently reproduces why the native strict old-route test must fail. Max WB-only old/new difference across tested cases:289.054848 at33,289.093239 at65. For mixed Contrast30, max old/new difference .698315 at33/.169736 at65; new versus direct CPU still reaches289.104266 due the remaining tone-domain projection. These large out-of-domain differences are expected compatibility impacts, not accepted new accuracy tolerances.

Even in-domain WB output can change: old log-encoded fused-table interpolation is not generally equal to applying a linear matrix after decoding an interpolated tone-only table. This correction is justified by the independent matrix/CPU contract, not by claiming saved-look identity. Real photos/RAW/native pointers and completed native performance remain acceptance items.

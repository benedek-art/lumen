# Matrix cross terms at partial local/global WB

Candidate base222cf96276d9e9c3a027c2f0ed18404a73401014, with a follow-up generalization over the isolated local-only7aa1533 candidate. The shared matrix helper now retains cross terms for both global and local matrices; creative formulas, saved values, tolerances and goldens are unchanged. Native execution of this candidate is pending. The earlier222 extraction fixed the WB-only bounded-domain jump, but its native strict test omitted partial Amount1. Compatibility records exposed a separate remaining precision problem there.

## Causal evidence

Native222 relative WB (Temp20,Tint13, Amount1%) produced HDR `[1024.08740234375,127.99261474609375,256.17108154296875]`, versus CPU `[1024.1065673828125,127.95045471191406,256.1844787597656]`: maxerror .0421600341796875, identically at cube33/65. This was a measured unresolved error, not accepted by the original zero/epsilon/full-strength strict coverage.

A new public-API actual-Core driver evaluated relative Amount1/100 and absolute Amount1. All129 current Core-source hashes matched the release object's recorded manifest before linking. Compile and single execution exited0 after correcting initially invalid Swift shorthand decimal literals (exact failed compile archived). No engine stub, native GPU rerun or changed tolerance. The raw3matrix records, exact driver, full manifest, command and compiler logs are in `partial-probe/`.

`native-diagonal-proof.json` independently compares those actual coefficients with the archived native222 compatibility records. ALL9unique channel observations across signed/interior/HDR patches match EXACTLY `Float(Float(input_i)*Float(M_ii))`. The second cube repeats this control, giving18 exact native channel comparisons. ALL corresponding CPU values match full matrix row-dot-products rounded to Float. Merely rounding coefficients to Float cannot explain the observed error. This pins omission of cross-channel terms in that CIColorMatrix execution; the internal classification cutoff is unknown and is NOT guessed or reproduced in production. The exploratory `trimmedSmallOffDiagonal` field in the raw driver was an earlier falsified hypothesis, not the accepted diagonal-only explanation or an implementation proposal.

For reference, relative Amount1's exact Core matrix is:

```
[1.0000853804132361, 0.0001311852332050124, 0.000008952017481578256]
[-0.00002341554939833045, 0.9999423108583965, -0.00007103183202240154]
[0.000007963642567195597, 0.0000409784518768698, 1.0006682769259623]
```

## Bounded production repair

The shared unconditional matrix helper now uses one explicit float Core Image color kernel with3uniform vec3 rows, returning their dot products with original RGB and preserving alpha. The exact resolver identity flag still controls whether the local matrix exists; GLOBAL `applyMatrix` retains its existing1e−12 bypass line byte-for-byte. Kernel/helper names are generic `matrixRows`/`applyMatrixUnconditionally`, because proof and denoise transforms also use the shared full matrix operator. There are no new amount thresholds, coefficient dropping, domain projection or residual extensions.

The new kernel is included in the FULL availability roster and its absence is reported there. Important limitation: `PipelineRenderer` gates its GPU route using `KernelLibrary.coreAvailable`, a narrower preexisting policy, NOT `unavailableKernels.isEmpty`. Therefore absence/failure of matrixRows does NOT automatically select CPU: the helper retains stock CIColorMatrix as fallback, including its measured partial-matrix limitation. This candidate does not silently broaden coreAvailable policy. Native qualification must demonstrate the new kernel compiles and executes; availability reporting alone is not proof of precise fallback behavior.

Partial-strength local/global WB-only pixels change to honor all coefficients of the already-defined CPU matrix. Other global matrix operations can also change by Float rounding/FMA differences relative to the stock filter; all existing matrix, proof and denoise goldens remain mandatory unchanged validation gates. This is a mathematically motivated correction with explicit saved-look impact, not a claim of legacy bit identity. It does not fix tone/wheel/curve Amount discontinuity, and mixed tone retains its existing bounded tone table.

## Tests and causal qualification

Existing new-test class `LocalWhiteBalanceExactMatrixTests` retains its3methods and all assertions/bounds. The strict independent row-dot/CPU stage and scalar-alpha test now includes Amount1/25/50/200 in addition to0/epsilon100, for BOTH mask/group strength, relative/absolute modes and cubes33/65. This gives56 local stage configurations,56 direct GLOBAL `applyMatrix` checks against the same independent matrix oracle, and224 alpha-composite configurations on the small signed/interior/HDR fixture. The active strict method also checks signed premultiplied RGBAf storage at alpha.25/.75, independent matrix products and exact alpha preservation; the neutral/zero method remains a healthy old-route control. Matrix and CPU bounds remain1e−3; zero/neutral and alpha0 identity remain exact. Scalar alpha readback remains checked. The healthy neutral/zero method and24 finite compatibility records remain unchanged.

Native causal requirement: candidate all3 methods GREEN; restore the ENTIRE exact222 RenderGraph using supplied `mutate-ci-matrix-route.py` while retaining identical tests and new Kernel definitions; strict active matrix method must become RED at partial Amount1 on both global/local operators, while neutral/zero and finite compatibility controls remain GREEN. Restore exact candidate source/test hashes. This is separate from the historical entire0e fused-LUT mutation, which already established domain projection causality. No old assertion was weakened and the strict wheel Amount diagnostic remains unchanged.

Linux macOS-target syntax parse/diff checks passed only. No Apple SDK typecheck, GPU result, complete-suite result, performance or native-photo acceptance is claimed for this candidate. Further hosted CI owns those gates. `candidate-source-sha256.json` freezes source/test/docs inputs; `partial-probe` preserves the measured failure and provenance, not a claim that the kernel remedy passed.

# October 7 — exact preview provenance diagnostic

The optimized full suite reported nil developed-preview provenance in two AuditPreviewReliabilityTests. A direct unsandboxed run of the same existing suite reproduced the three assertions on this worktree. RenderCoordinator, PreviewStore, ExactColorStage and the original test file were unchanged against baseline main 5643497 before diagnostics.

Failure messages now include the render's note, source identity, draft and embedded status without changing any assertion or policy. Diagnostic run:

- `sourceIdentity` is present and matches the current original.
- `isDraft` is false; `usedEmbeddedPreview` is false.
- `note` is `Reduced — 3 GPU kernels unavailable: colourPrimaries, colourMixer, colourPoint`.
- The existing provenance guard intentionally rejects a render with a Reduced note. Nil previewIdentity is therefore the correct protective behavior; it is not failure to read the source identity.

The full suite independently fails ExactColorStageGPUTests.testEveryColourKernelCompiles for precisely those three kernels and colour oracle tests observe unchanged RGB for mixer edits. The underlying baseline kernel compilation defect belongs to the rendering repair stream. Do not relax provenance, skip GPU tests, or update numerical fixtures to hide it.

Diagnostics validation: native macOS build completed and 13 AuditPreviewReliability tests executed outside sandbox, with three existing failing assertions in two tests. Log `/private/tmp/lumen-oct07-preview-diagnostic.log`; first unchanged reproduction `/private/tmp/lumen-oct07-preview.log`. No original photos, application installation or preview guard changes.

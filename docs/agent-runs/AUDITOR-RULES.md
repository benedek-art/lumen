# Rules for Lumen code auditors

Read `FIXER-RULES.md` and `QUEUE-NOTE.md` in this same folder first; they apply to you, with these additions.

You find defects by reading code, then PROVE each one before you fix it. This project's history is full of confident fixes argued from code that turned out wrong, so reading alone never counts.

- **Proof, in order of preference:** (1) a LumenCore test on Linux that fails before your fix and passes after; (2) a small driver scenario or render-lab manifest that shows it on a real run (batch these: one request at the end, not one per finding); (3) if neither is possible, do NOT change the code: list it as a candidate with the exact scenario that would prove it.
- **Fix only what is proven and small.** A fix that needs a redesign goes in the report, not the branch.
- **Ownership.** Other agents own these files right now; do not edit them, report findings in them instead: `LoupeView.swift`, `RenderCoordinator.swift`, `RenderPump.swift`, `PipelineRenderer.swift`, `RenderGraph.swift`, `Kernels.swift`, `AppleRawSource.swift`, `FilmLab.swift`, `DetailEngine.swift`, `MaskPanel.swift`, `MaskCanvas.swift`, everything in `Sources/LumenApp/Driver/`, and `AppState.swift` (except where your brief says otherwise). Panel files are shared: append, do not move lines (slider citations are line numbers; keep `recite-slider-inventory.py` at 0 unplaced).
- **Rank by harm to a photographer:** lost or corrupted edits, damaged originals, wrong pixels in an export, crashes and hangs, then lag, then everything else.
- **Report:** a table of findings (file:line, what a user would see, severity, proven how, fixed or candidate), then commits. At most 15 findings; quality over count.

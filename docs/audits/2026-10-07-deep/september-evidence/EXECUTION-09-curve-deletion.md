# Execution 09 — discrete curve deletion Undo identity (S-05)

22 September 2026. Supplemental safety work; the original 47-item count is unchanged.

## Reproduction

The existing core expected-failure fixture fabricated two identical deletion keys. The actual production delete action was first extracted, without changing the key or curve update. Its core regression now calls the production key generator and runs normally on Linux too, instead of returning early.

Native regressions through `AppState` reproduced the defect for both a global context-style deletion and two separate mask gesture epochs: delete point index 1 twice, Undo, Undo, Redo, close, then read the real catalog and portable XMP. Both deletions folded into one history step, so undo/readback did not represent the user's separate decisions. **Three tests failed 13 assertions** before the repair.

## Repair

`CurveEditing.deletionCoalescingKey` gives each actual deletion a fresh action identity, retaining the existing target/channel/index prefix. All existing option-click, context menu and drag-out paths still share the same guarded deletion action. Anchor and invalid-index refusal happens before creating an edit. An active drag-out deletion still joins the drag via the existing gesture epoch; generic history semantics are unchanged. Recipe formats, curve mathematics and broadcast semantics are unchanged. The random identity is an in-memory Undo key, not recipe/XMP data.

## Qualification

Optimized native run:

```sh
swift test --package-path work/lumen --scratch-path <isolated-build> \
  --build-system native -c release --jobs 2 \
  --filter 'AuditStateSafetyTests|CurveAdversarialTests|CurveEditingTests|History|Gesture|PanelBinding'
```

**107 tests, zero unexpected failures or skips**, 2.225 seconds test time after build. Seven unrelated inherited group-movement expected assertions remain in CurveAdversarial; the deletion expectation has been removed, not broadened. Tests exercise actual global/mask edits, separate gesture epochs, Undo/Redo, catalog and XMP reopen, protected anchors, invalid indices and preserving one-step drag-out behaviour, alongside existing curve and history contracts.

This is an application-action/state qualification, not pointer delivery or a full native curve-panel accessibility study. No performance, rendering-accuracy or exhaustive UI claim is made.

The later full suite caught two structural checks missed by the first selection: the deletion helper's separate extension file was outside the existing core-wiring scan and looked like an unobserving recipe reader. The helper now lives inside the observing `CurveEditorView` declaration. Both original assertions remain unchanged and pass in the 364-test integrated selection, along with all above state tests. This was a source-layout correction, not a history or pixel behaviour change.

# Pick source-snapshot projection

The generation preflight introduced at5d1 searched all selected snapshots for every distinct secondary URL. That is quadratic before sampling/file checks start. The follow-up builds one first-occurrence PhotoItem index, retaining first-nil identity and primary override semantics, while keeping the existing distinct-URL set and physical generation checks. No recipe, picker result or history contract changes.

A standalone optimized Swift witness passed5 exact equivalence cases (empty, duplicate nil/non-nil order and primary overrides). One synthetic timing cell per size measured1000 targets11.681ms→0.667ms and20000 targets3898.467ms→62.773ms. These exclude file stats, AppState and rendering; no native interaction speedup or statistical confidence is claimed. The witness indexes a small synthetic Snapshot, rather than production PhotoItem. The production lookup is independently covered by the existing pending native pick regressions.

observations.json contains the exact executed commands and faithfully transcribed tool stdout; a raw stdout file was not captured. The unchanged witness is retained for reproduction. With an ordinary Swift installation: `swiftc -O witness.swift -o /tmp/lumen-pick-projection` then `/tmp/lumen-pick-projection`. No timing threshold, tolerance or golden was introduced.

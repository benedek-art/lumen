# WS-09 needs from other lanes

1. **Whites authority (WS-05, zonal tone / `ToneEngine` anchors).** Whites +100 moves the white
   anchor 1.5 EV (`whiteBlackRangeEV`). On flat frames (overcast, indoor) the brightest 0.2 % sits
   2.5-3 EV under the +5 EV anchor after Exposure, so "just clip" needs more than +100. Auto caps
   Whites at +60 and adds at most Contrast +20 to close the gap; 7 corpus frames still end with p99
   between 0.54 and 0.84 (1332, 2242, 2545, 3582, 4144, 832, plus 1192 which is protection-bound).
   If WS-05 gives Whites more reach, Auto will use it with no change (it solves against `ToneEngine`).
2. **WS-03 Auto WB.** `origin/quality/ws-03-white-balance` has a spec only, no
   `AutoWhiteBalance` yet. Auto Tone does not call WB. When it lands, `applyAutoTone` can call it
   before measuring (the probe must be rendered at Auto's WB for the tone read to match).
3. **Stale comment, `LumenControls.swift:517`** (not owned) still names `AutoTone.suggest(from:)`;
   the app now calls `AutoTone.auto(from:render:)`.

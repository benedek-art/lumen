# Deliver (areas 30 + 9): soft proof, export sheet, compare / survey / before-after

App: claude/loving-cray-d58nrb-integration (build a7f3c8dc0d). All findings PROVEN on driver run 45751022899
(request 5224c692; scenarios repro/batch1.json). R1 = scratchpad/deliver-run1, IMG = findings/deliver/img.
Export-sheet run (repro/batch2.json, request 9e9ab9957c7c87ad90b3277f20c48054b1640e48) was still QUEUED at wrap-up.
Counts: 0 blocker, 3 major, 5 minor.

1. MAJOR - Shift-Y split at 1:1 shows an empty viewer. Fiducial, Exposure +3, Shift-Y, double-click viewer -> 1:1:
   viewer is all surround, readout R0 G0 B0, histogram "100% black, visible region only"; state zoom 1, render 6000x4000
   region false, viewport.image w 6000 h 4000. Panning does not recover. IMG/split-zoom.png, split-zoom-pan.png,
   R1/ba-fiducial/state-split-zoom.json. Scenario ba-fiducial. Possibly same root as known "zoom blank viewer" (split
   path disables region renders and draws two full 6000-pt plates); plain-loupe control is in batch2 x7-scale.
   Code reading (not proven): divider is placed in image coordinates, so off-screen when zoomed.
2. MAJOR - Compare "1:1" is not 1:1 and panes differ in magnification. 5D+A7IV in C, click -> badge 1:1. Timeline:
   one pane got 4096x2731 after 4 s, the other stayed on its 768x512 fit proxy 14 s and was drawn at ~0.16 of 1:1
   (chart card grew x1.8 from fit: IMG/c-fit.png vs c-zoom.png). Settled: each pane = 1 pt per pixel of a 4096 proxy:
   5D ~0.94, A7 IV ~0.58 (IMG/c-pan.png). Cause in code: ComparePane caps at maxRenderLongEdge 4096 and normalises
   zoom to the proxy's own size. Focus comparison in C is at wrong and unequal magnification. Scenario compare-raw.
3. MAJOR (layout) - Y and Option-Y panes off-centre, zoom badge covers labels. Y: pair pushed to the viewer bottom,
   438 pt empty above; Option-Y: flush left, ~250 pt empty right; "FIT" badge over BEFORE/AFTER ("FIT ORE").
   IMG/sbs.png, topbottom.png, raw-sbs.png. Scenarios ba-fiducial, ba-raw.
4. minor - Y/Option-Y pair ignores Cmd-B assessment surround (stays 0.165; loupe and compare go mid-grey).
   IMG/raw-sbs-assess.png vs raw-loupe-assess.png. BeforeAfterPair paints Lumen.viewerBackground. ba-raw.
5. minor - Double-click on a compare pane (make active) also toggles zoom fit->1:1 and re-windows the pair (clicked
   photo jumps panes, other pane changes photo). IMG/c-dbl.png. compare-raw.
6. minor - Backslash in Compare or Grid silently sets showBefore; loupe later opens on BEFORE and edits appear dead.
   IMG/loupe-after-c-backslash.png; states c-backslash, grid-flip.
7. minor - Survey (N) with 3 photos overflows: 2x2 tiles of ~410 pt, third tile needs scrolling. IMG/survey-x.png.
8. minor/confusing - Shift-Y split persists into masking (M); before half shown while drawing masks.
   IMG/raw-split-then-m.png. (R: crop canvas takes over, split returns after: defined.)

WORKING (run 45751022899): backslash before = imported render (|orig-before| 1.3 on A7IV, 3.5 fiducial; edit restored
exactly); before framed like edit with crop + 10.8 deg straighten in \, Shift-Y, Y; Y + Exposure drag: BEFORE pane
unchanged (0.0), AFTER follows; split divider drag 0.15/0.999/0.5; Y keys toggle and switch to loupe; R with split;
C with 1 photo; C/N -> grid; arrows move pair window; Can't read pane; synced pan; compare/survey follow Cmd-B;
Shift-S proofs compare panes (AREAS "compare panes do not soft-proof" is stale); survey reject dims tile; soft proof
sRGB+gamut warning on Saturation +~95 ARW flags 0.9% px grey 188 where unproofed loupe had a channel at 0, off restores
exactly; Cmd-E opens sheet; Opt-Shift-Cmd-E with no previous opens sheet with reason; X with sheet up does nothing;
Esc closes sheet.

NOT TESTED: all export-file checks (formats, depth, ICC, sizing, output sharpening, naming tokens, subfolder, metadata,
copyright, watermark, multi-recipe, Rename/Overwrite/Skip, Cancel mid-batch, several photos, proof-on export, pixel
parity) - driver gained sheets at 05:00; batch2 scenarios x1-x6 written and queued. Fetch with
`python3 driver/tools/results.py 9e9ab9957c7c87ad90b3277f20c48054b1640e48 --out <dir>`; files are under $OUT/x* in the
artifact. Driver 5D-12MP.CR2 == render-lab 1346 (same sha256): compare x2-png-parity with lab run 45757371037
(export+settled, 1346 @2048; artifact id 15089002817, not fetched). Open risk (code reading only): AppState.export
passes activeSoftProof, so exporting with Shift-S on gamut-maps the file to the proof space (x6-proof-export checks it).
Compare/split scale with pixel witness + loupe control: batch2 x7-scale. Key holds ([ ]) in split: driver has no
key-hold verb.

TASTE: gamut warning grey (sRGB 188) reads like white blossom on foliage (findings/deliver/crop-proof-on.png vs
crop-deliver.png); LR uses a saturated warning colour. Crop panel pickers show blue accent chevrons (area 21).

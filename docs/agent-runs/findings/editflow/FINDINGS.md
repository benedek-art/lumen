# FINDINGS: editflow (AREAS 11, 27, 28) — saved by orchestrator from the tester's report
Runs on integration 805455c0: 45744798281, 45747030310, 45752972736. Evidence (scenarios, states/, screenshots, analyze.py) in this folder.
1. MAJOR Clicking a slider's value pill anywhere but its digits does not open the field; typed digits become star ratings, auto-advance moves on, next edit lands on the wrong photo. Integer sliders with 1-2 digit readouts worst. Cause (inferred): LumenControls.swift valueField puts the tap handler and contentShape on the Text before .padding/.frame(width: 52). Scenarios ef-pill, ef-pill-raw. pill-click-no-field.png, pill-raw-before/after-advanced.png.
2. MINOR Cmd-Z / Shift-Cmd-Z silently change a photo that is not on screen (and Sync can then copy the loss).
3. MINOR A newly saved develop preset is missing from Photo > Develop Presets for 6+ s (medium confidence: driver reads the menu without opening it).
4. MINOR Creating a linear-gradient mask is two undo steps (first leaves an empty mask).
5. MINOR (low conf) typing -0 into Exposure at -10 did nothing.
DOC QUESTIONS: merge window is the code's 1.2 s, not the docs' 2 s (measured). History across folder change / relaunch: not testable by the driver.
WORKING: slider drag/typing/clamps/expressions, reset by double-click, arrow and modifier steps, alt-scroll; undo/redo exact across tools; Auto Tone one step; Reset; history card; snapshots; copy/paste/sync/presets carry exactly the ticked groups; multi-select rules (global to all, masks/spots active only); XMP sidecar equals the recipe within ~2 s.
TASTE: same-slider edits within ~1 s fold into one undo step; plain paste copies ISO-based NR to a different-ISO frame; status line still says "Auto applied" after undo.
DRIVER BUGS: key step with count and interval < 0.03 s crashes the app (DriverPacer negative floorGap -> UInt64 trap, DriverSteps.swift:64); preferences leak between scenarios in one request; slider anchors one row off after scrolling; menu walker may miss runtime-added items.

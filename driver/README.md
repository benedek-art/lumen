# The driver: run the real app, act like a user, see what happened

Lumen is a macOS app and this repository is usually worked on from Linux. The driver
is how an agent with no Mac runs the real app: a scenario file lists steps (move, click,
drag, pinch, scroll, press keys, take a screenshot, check a value); a macOS GitHub runner
builds the app, runs it under the driver, and uploads what it saw.

Everything here is observed on a `macos-15` hosted runner unless it says otherwise.

## The five-minute version

```sh
# 1. Write a scenario (or copy one from driver/scenarios/).
cat > /tmp/zoom.json <<'EOF'
{
  "name": "zoom-check",
  "fixture": "fiducial",
  "steps": [
    {"do": "open", "photo": "fiducial.png", "workspace": "develop"},
    {"do": "pinch", "id": "p", "target": "viewer", "at": [0.4, 0.4], "scale": 2, "duration": 0.6},
    {"do": "waitSettled"},
    {"do": "shot", "name": "zoomed"},
    {"do": "expect", "that": "viewport.zoom", "gt": 0, "note": "a pinch zooms"}
  ]
}
EOF

# 2. Ask for a run. This pushes one small commit; the run starts on the push.
python3 driver/tools/request.py --scenario /tmp/zoom.json --branch <a branch you may push>
#    prints the request commit's SHA

# 3. Find the run and its artifact (GitHub MCP tools; there is no `gh` here):
#    actions_list  method=list_workflow_runs  resource_id=driver.yml      -> the run whose head_sha is that SHA
#    actions_list  method=list_workflow_run_artifacts  resource_id=<run id>   (once status is "completed")
#    actions_get   method=download_workflow_run_artifact  resource_id=<artifact id>   -> a signed URL

# 4. Unpack and read.
python3 driver/tools/results.py '<signed URL>' --out /tmp/run
```

`results.py` prints the verdict table, every failed check with its note, the numbers each
gesture measured, and the folder of screenshots. Look at a screenshot with the Read tool.

A run takes about 5 minutes when the app has to be built and about 1.5 minutes when the
same sources were built before (the binary is cached by a hash of `Sources/`), plus the
scenarios' own time. Do not poll faster than once a minute.

### Why a push and not a dispatch

`driver.yml` has `workflow_dispatch` inputs (`suite`, `scenario`, `ref`, `runs_on`,
`config`, `strict`) and a person can use them from the Actions page. The GitHub
integration agents have in this environment may not dispatch workflows (HTTP 403), so the
lane also starts on any push that adds or changes `docs/driver-requests/*.json`. That
path is under `docs/` on purpose: a docs-only push starts no other workflow in this
repository, so a request costs one macOS job, not six.

A request file is `{"suite": "...", "scenarios": [...], "ref": "...", "config": "release",
"strict": false}`, every key optional. `request.py` writes it and pushes it for you:

| option | meaning |
|---|---|
| `--suite "smoke.json repro-*.json"` | committed scenarios, as files or globs under `driver/scenarios/` |
| `--scenario file.json` (repeatable) | scenarios sent inline; they need not be committed. A file may hold one scenario or an array |
| `--ref <branch or sha>` | the app code to test, when it is not the commit you are pushing from. The driver, tools and scenarios still come from your commit, and the hooks are re-installed onto that ref, so a branch that predates the driver can be tested |
| `--branch`, `--force` | where the request commit is pushed. Default: your current branch. A throwaway branch with `--force` keeps request commits out of real history |
| `--strict` | fail the job when an expectation fails. Without it the job is red only for a driver error, hang, timeout or crash |
| `--config debug` | faster build, meaningless timings |

Several runs proceed in parallel; no run cancels another. The account runs about five
macOS jobs at once, so put many scenarios in one request rather than one request each.

## What a run produces

The artifact `driver-<run id>` unpacks to:

```
summary.txt / summary.md / summary.json     the verdict table
fiducial.json                               the fixture's cell map (for the pixel witness)
build.log
<scenario>/
  report.json        verdict, machine, every step's result and measurements
  timeline.jsonl     every input event sent and received, every frame, hitch and commit
  state-<name>.json  state dumps asked for by `state` steps; state-final.json always
  shots/<name>.png   window screenshots; shots/<id>-NNN.png from a captured gesture
  witness.json       geometry measured from the screenshots' pixels (fiducial runs)
  probe.json         from a `probe` step
  scenario.json, app.log, exit.txt
  watchdog.json, watchdog-sample.txt        only after a hang or timeout
```

Verdicts: `PASS` every check held · `FAIL` a check failed · `ERROR` the driver could
not do a step (unknown target, event never arrived) · `HANG` the main thread stalled
longer than `hangSeconds` (default 30; a stack sample is saved) · `TIMEOUT` the scenario
outlived `timeoutSeconds` (default 300) · `CRASH` · `KILLED` the outer limit.

**A failed check is a finding, not a broken lane.** The three `repro-*` scenarios state
what the owner wants and fail today on purpose.

`report.json` → `machine` names the hardware (`model`, `chip`, `gpu`, `os`, display size
and scale). Hosted runners are 3-core virtual machines with a paravirtual GPU and a 1x
display; never compare their timings with numbers from another machine.

## Scenario format

```json
{
  "name": "my-scenario",
  "description": "one sentence a stranger can act on",
  "fixture": "fiducial",
  "window": {"width": 1440, "height": 900},
  "via": "auto",
  "timeoutSeconds": 300,
  "hangSeconds": 30,
  "steps": [ {"do": "...", "id": "optional-name", "note": "why this step exists"} ],
  "witness": [ {"that": "groups.<id>.driftMaxPt", "lt": 2} ]
}
```

`fixture` is the folder the app opens: `fiducial` (one synthetic 6000x4000 PNG, see
"The pixel witness") or `raw` (three CC0 camera files from raw.pixls.us, pinned by
sha256 in `driver/fixtures/raw.tsv`: `A7IV-33MP.ARW`, `XH2-40MP.RAF`, `5D-12MP.CR2`).
Each scenario gets its own copy of the folder, a new empty catalog and an empty
preferences domain, so nothing carries over from one scenario to the next.

Steps run in order. A step that errors is recorded and the run continues, unless the
step says `"fatal": true`. Give a step an `id` to refer to its measurements later
(`steps.<id>.framesDuring`).

A scenario is plain JSON, so generating hundreds from a script is a loop that writes
dictionaries; `request.py --scenario` takes a file holding an array.

### Targets

Every pointer verb takes `"target"` and optionally `"at": [fx, fy]` (a fraction of the
target's rectangle, default its centre `[0.5, 0.5]`) and `"offset": [dx, dy]` in points.

| target | means |
|---|---|
| `"viewer"` | the picture area of the loupe |
| `"viewer.image"` | the picture itself, wherever zoom and pan have put it |
| `"slider/<Label>#track"` | a slider's track, by the label the app shows: `slider/Exposure#track`. `slider/<Label>` is the whole row (label, track, number) |
| `"develop.column"`, `"sidebar"`, `"filterbar"`, `"filmstrip"`, `"rail"`, `"statusbar"`, `"grid"`, `"compare"` | the window's regions |
| `"mask.kind/<Name>"`, `"mask.create"`, `"mask.row"` | the mask kind tiles (`mask.kind/Linear Gradient`), the + button, a row of the mask list |
| `{"anchor": "slider/Saturation#track", "index": 1, "within": "develop.column"}` | the same names, choosing among several with one label (reading order) or only those inside another target |
| `{"text": "Presence", "within": "develop.column", "index": 0}` | the words on screen, found by OCR on a screenshot. Works for anything with a visible label; costs about a second |
| `{"point": [x, y]}` | window points from the window's top-left corner |
| `"window"`, `"cursor"` | the whole window; wherever the pointer is |

A named target must be on screen. For a control further down a scrolling column use
`{"do": "scrollTo", "target": "slider/Texture#track"}` first (default container
`develop.column`, or `"in": "<target>"`). When a target is not found the error lists the
names that are on screen; a `state` step lists them all with their rectangles, and
`"texts": true` on it adds everything OCR can read.

Named targets are views carrying `.driverAnchor("name")`, a modifier that does nothing
outside the driver. To make a new control addressable, add that modifier to it (and to
`driver/tools/install-hooks.py`, which keeps the hook lines installable on older refs).

### Input verbs

All of these synthesize events that go through AppKit's normal dispatch into SwiftUI's
gesture recognizers. None calls the app's own functions.

| verb | fields (defaults) |
|---|---|
| `move` | `target`, `at`, `duration` (0: one event), `hz` (60) |
| `click` | `target`, `at`, `count` (1; 2 is a double-click), `button` (`left`/`right`), `hold` (0.04 s), `modifiers` |
| `drag` | `target`, `from` and `to` (fractions of the target), or `toTarget`/`toAt`; `path` (extra `[fx, fy]` waypoints); `duration`, `hz` (60), `ease` (`linear`/`inout`), `pressHold` (0.05), `hold` before release (0.05), `button`, `modifiers` |
| `scroll` | a mouse wheel: `target`, `at`, `lines` `[dx, dy]`, `count` (1), `interval` (0.05), `modifiers` (`["option"]` zooms sliders) |
| `swipe` | a two-finger trackpad scroll with began/changed/ended phases: `target`, `at`, `by` `[dx, dy]` total points, `duration`, `hz`; `momentum`: `{"by": [dx, dy], "duration": 0.5}` adds the coasting phase |
| `pinch` | a trackpad pinch with began/changed/ended phases: `target`, `at`, `scale` (the whole gesture's factor; each event carries an equal share of `scale - 1`), `duration`, `hz`, or explicit `deltas` |
| `smartMagnify` | the two-finger double-tap: `target`, `at` |
| `key` | `key` (a letter, digit, symbol, or `return tab space delete escape left right up down`), `modifiers` (`cmd shift option ctrl`), `count`, `interval` |
| `modifiers` | `hold`: modifiers to keep down across the following steps; `[]` releases |
| `scrollTo` | brings `target` into view by scrolling `in` (default `develop.column`) |

Every pointer verb also takes:

- `"via"`: `hid`, `app` or `auto` (the scenario's `via`, else `auto`). See the table below.
- `"capture": N` or `"each"`: take a screenshot after every Nth event of the gesture.
  The events are then sent one at a time with a pause (`captureDelay`, 0.05 s), so the
  gesture's shape is tested but its timing is not. Shots are `<id>-000.png`, `-001`, …
  and the pixel witness treats them as one series (`groups.<id>`).
- `"settle": seconds`: after the gesture, wait up to that long for the sharp frame and
  record `releaseToSettledMs`.
- `"watch": "develop.tone.exposure"`: a recipe key to trace; the step's `frameTrace`
  lists `[ms, value, draft|sharp, long edge]` for every frame.

Without `capture`, a gesture's events are posted from their own thread on a fixed
schedule, whatever the main thread is doing, the way a device keeps reporting while the
app is busy. That is what makes the timing numbers meaningful.

### Which events take the real path

Measured by the `probe` scenario, which posts one of everything by each backend and
counts what the app's own event monitor receives.

| | `hid` | `app` |
|---|---|---|
| how | `CGEvent.post` at the HID tap: the window server routes it, the real cursor moves | `NSEvent`s put on this process's queue (`NSApp.postEvent`) |
| needs | event-posting permission (the hosted runner grants it to processes started from the job's shell) and the point to be on the display | nothing; works for a window that is partly off-screen or covered |
| mouse move, hover, click, drag | real | real dispatch; the cursor is warped to match |
| wheel and trackpad scroll, pinch, smart magnify | real | SEE THE STATUS TABLE BELOW |
| keys, shortcuts | real | real dispatch |
| `NSEvent.modifierFlags` (read by slider fine-drag and option-drag code) | follows | does NOT follow: a held modifier is on the events but not in the global state |

`auto` uses `hid` when it works and every point of the step is on the display, else `app`.
The step's result says which was used (`via`).

@@STATUS@@

### Verbs that are not input

| verb | does |
|---|---|
| `open` | selects a photo (`photo`: file name or part of one, or `index`) and enters a workspace (`workspace`: `cull develop crop grade deliver`; `masking`: true), then waits for the sharp frame (`timeout`, 30 s). Setup by direct call, marked `via: direct` |
| `menu` | chooses a menu item by path, `"View > Zoom In"`: AppKit performs the item's own action, honouring its enabled state. Marked `via: menu`. `allowDisabled` records a disabled item instead of erroring |
| `direct` | `call`: `fit oneToOne setZoom enterMasking toggleMasking showLoupe showGrid resetRecipe undo selectNext selectPrevious showLatencyHUD`. The second tier: calls the app directly, marked `via: direct`. For setup and teardown, never for the thing under test |
| `wait` | `seconds` |
| `waitSettled` | waits (`timeout` 30) for a sharp frame of the current settings followed by `quiet` (0.5 s) without another frame. A timeout is a failed check |
| `waitFor` | an `expect` that polls until it holds (`timeout` 10) |
| `expect` | a check; see below |
| `shot` | a window screenshot `shots/<name>.png`; also stores the mean colour of `region` (default `viewer.image`) as `shots.<name>.r/g/b/luma/lumaSD` |
| `compare` | `a`, `b`: two shot names; stores `compare.<name>.meanAbs`, `.changedFraction`, `.dr/.dg/.db` and `.redShift` (positive when the region moved toward red, the mask overlay's signature) for `region` (default `viewer.image`) |
| `state` | writes `state-<name>.json`: everything below plus every named target's rectangle, the menu bar and the sidecar; `"texts": true` adds OCR |
| `mark` | a named row in the timeline |
| `probe` | writes `probe.json`: permissions, display modes, each capture method, each backend's delivery |

### Checks

```json
{"do": "expect", "that": "viewport.zoom", "gt": 0, "note": "what this proves"}
```

`that` is a dotted path; one operator: `eq`, `ne`, `gt`, `ge`, `lt`, `le`, `near`
(with `tol`, default 0.01), `exists` (true/false). A string on the right that is itself
a path is read as that path's value: `{"that": "viewport.zoom", "gt": "steps.before.zoom"}`.
Checks are evaluated inside the app, so a scenario passes or fails on its own.

Paths you can read:

| path | what |
|---|---|
| `viewMode`, `workspace`, `masking`, `scanning`, `status` | `grid loupe compare survey`; the workspace; the status-bar message |
| `photo.name`, `photo.index`, `photo.count` | the selected photo and the roll size |
| `viewport.zoom`, `.panX`, `.panY` | the app's zoom (0 is fit, 1 is 1:1) and pan |
| `viewport.viewer.x/y/w/h`, `viewport.image.x/y/w/h` | the viewer and the drawn picture, in window points, as the app lays them out |
| `viewport.insetLeft/Top/Right/Bottom` | how far each edge of the picture is inside the viewer; positive means surround is showing on that side |
| `viewport.scale`, `viewport.lastCursorX/Y` | drawn long edge over native long edge; the last hover position the viewer received |
| `render.draft`, `.longEdge`, `.nativeLongEdge`, `.frames`, `.age`, `.current`, `.region` | the last frame the loupe put on screen; `current` is whether it shows the current settings |
| `recipe.<key>` | the edit, as the app's own sparse JSON: only values that differ from the default appear (`recipe.develop.tone.exposure`). A key that is absent is at its default, so test "unchanged" with `"exists": false` |
| `masks.count`, `.active`, `.overlay`, `.overlayShown`, `.overlayRasterized`, `.panelVisible`, `.list.N.name` | masks and the red overlay |
| `steps.<id>.<measurement>`, `last.<measurement>` | what a gesture step measured (next section) |
| `shots.<name>.*`, `compare.<name>.*` | from `shot` and `compare` |
| `app.<property>` | any stored property of `AppState`, by reflection: `app.autoAdvance`, `app.lightsOut`, `app.clippingOverlay`, `app.showHistogram`, `app.developPanelWidth`, `app.sidebarVisible`, `app.activeSheet`, `app.pickTarget`, `app.inspectionHold`, `app.softProof.*`, `app.filter.*`, `app.sortOrder`, `app.selection.count`, `app.activeMaskID`, `app.maskOverlayMode` … |
| `panel.*`, `loupe.*`, `heal.*`, `crop.*`, `brush.*`, `info.*`, `history.*` | `PanelLayout.shared.layout`, `LoupeViewport.shared` (`loupe.beforeMode`, `loupe.splitPosition`, `loupe.showCrop`, `loupe.hdrPreview`), `HealTool.shared`, `CropTool.shared`, `MaskBrushStore.shared`, `CaptureInfoDisplay.shared`, the undo stack |
| `menu.<Path>.enabled`, `.checked` | a menu item: `menu.Edit > Paste Settings.enabled` |

The reflected sections show stored properties under their source names. Dump a `state`
once and read the file to learn the exact keys; enums print as their case name,
collections as `{count, items}`.

### What a gesture step measures

In its row of `report.json`, and readable as `steps.<id>.<name>`:

| name | meaning |
|---|---|
| `via`, `events`, `delivered` | backend used, events sent, whether the app received the last one |
| `postingMs`, `gestureMs` | how long sending took; how long until the app had handled the last event. A healthy app has them nearly equal; a gap is the main thread falling behind |
| `framesDuring`, `framesDuringDraft`, `framesAfter` | frames the loupe put on screen while the gesture ran, and after |
| `maxFrameGapMs`, `firstFrameMs`, `fpsDuring` | the longest wait without a new frame inside the gesture; the first frame's delay |
| `distinctValues`, `distinctValuesShown` | how many different settings the gesture produced, and how many of those ever reached the screen |
| `latencyMs.min/p50/p90/max/n` | for each frame during the gesture: time from the moment its settings first existed to the frame showing them |
| `staleFramesDuring` | frames that showed settings already superseded when they landed |
| `releaseToFinalValueMs`, `releaseToSharpMs`, `releaseToSettledMs` | from the end of the gesture to the first frame of the final settings, to the first sharp one, and (with `settle`) to the settled one. Negative: it was already there |
| `hitches`, `hitchMaxMs`, `hitchTotalMs` | main-thread run-loop turns longer than 25 ms during the gesture |
| `watchStart`, `watchEnd`, `frameTrace` | with `watch` |

"Frame" means the loupe's render model replaced the image it shows. Zoom and pan move
the existing image without a new frame, so judge those from screenshots.

`timeline.jsonl` has the raw rows (`t` is seconds since the driver started): `in` an
event sent, `rx` an event the app received, `frame`, `commit` (the frame left for the
window server), `hitch`, `step`, `shot`, `mark`.

## The pixel witness

The app's own report of where the picture is (`viewport.image`) comes from the code
under test. The witness reads it from the screenshot instead.

The `fiducial` fixture is a 60x40 grid of 100-pixel cells in seven colours. Every cell
differs from its neighbours and every 3x3 block is unique, so a screenshot showing two
grid lines each way says exactly which part of the image is where, at what scale.
`driver/tools/fiducial.py` does that (`locate(rgb, map, roi)`), to well under a point.

After each fiducial scenario the lane runs `driver/tools/witness.py`, which writes
`witness.json` and evaluates the scenario's `"witness"` checks (same operators):

| path | what |
|---|---|
| `shots.<name>.located`, `.scale`, `.rect.x/y/w/h` | whether the grid was found; points per image pixel; the picture's true rectangle in window points |
| `shots.<name>.insetLeft/Top/Right/Bottom` | as above, from pixels |
| `shots.<name>.claimErrorPt` | how far the app's `viewport.image` is from the pixels |
| `shots.<name>.underCursor.u/v` | the image pixel under the pointer |
| `groups.<id>.driftMaxPt`, `.driftEndPt` | for a captured gesture: how far the image point that began under the pointer strays from it, at worst and at the end |
| `groups.<id>.jumpMaxPt` | the largest change of that drift between two consecutive captures |
| `groups.<id>.scaleStart`, `.scaleEnd`, `.scaleRatio`, `.scaleMonotonic`, `.moveX`, `.moveY` | the on-screen scale through the gesture; how far the picture travelled |
| `drift.<shotA>.<shotB>` | the same drift between any two named shots |

It needs at least two grid lines each way: from fit up to about 4:1 in a 770-point
viewer. Beyond that `located` is false.

You can run it yourself on a downloaded run:
`python3 driver/tools/witness.py /tmp/run/<scenario> --map /tmp/run/fiducial.json`
(needs numpy and Pillow), or on one image:
`python3 driver/tools/fiducial.py shot.png --map fiducial.json --roi x,y,w,h`.

## The scenarios in this folder

| file | what it is |
|---|---|
| `smoke.json` | every verb once on the fiducial. Should pass on a healthy build; runs on any push that touches the driver |
| `probe.json` | what works on the machine: read `probe.json` in its output |
| `repro-pinch-zoom.json` | owner report: trackpad zoom and pan. Anchor drift, compounding, two-finger pan, pan past the borders |
| `repro-slider-drag.json` | owner report: the picture does not update during a slider drag. Exposure, Saturation, Texture on the 33 MP ARW |
| `repro-mask-overlay.json` | owner report: the red mask overlay never goes away |

## How it is built

- `Sources/LumenApp/Driver/` is the whole driver. With `LUMEN_DRIVER` unset none of it
  runs: `LumenDriver.isActive` is false, `makeAppState()` returns a plain `AppState()`,
  and `.driverAnchor` returns the view it was given.
- The hooks in app files are single lines (`install-hooks.py` lists every one).
  `LumenApp.swift` asks the driver for its `AppState` (a temporary catalog and preview
  cache when active) and, when active, starts it instead of reopening the last folder
  and checking for updates.
- `driver/tools/run-suite.sh` is the lane's body and runs locally on a Mac too:
  `driver/tools/run-suite.sh smoke.json`. It builds, wraps the binary in a bundle with
  its own identifier (`dev.lumenapp.lumen.driver`, so a run never touches the real app's
  preferences), and starts one process per scenario with `LUMEN_DRIVER=<scenario>`,
  `LUMEN_DRIVER_OUT=<dir>`, `LUMEN_DRIVER_PHOTOS=<folder>`.
- Process exit status: 0 pass, 1 a check failed, 2 driver error, 3 hang, 4 timeout.

## Known limits

@@LIMITS@@

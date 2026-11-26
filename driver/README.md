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

# 2. Ask for a run against the branch you want tested, and wait for it.
python3 driver/tools/request.py --scenario /tmp/zoom.json \
    --ref claude/loving-cray-d58nrb-integration --wait --out /tmp/run
```

That pushes one small commit to the shared requests branch
(`claude/loving-cray-d58nrb-driver`), waits for the run it starts, downloads the
artifact to `/tmp/run` and prints the verdict table, every failed check with its note,
the numbers each gesture measured, and the folder of screenshots. Look at a screenshot
with the Read tool. It does not touch your working tree or your own branch, so you can
run it from any checkout that has `driver/tools/`.

Without `--wait`, `request.py` prints the request commit's SHA and returns; later,
`python3 driver/tools/results.py <that SHA> --out /tmp/run` waits for the run and
prints the same thing. `results.py` also takes a run id, an artifact URL, a zip or an
unpacked folder. Both use `curl` against the GitHub REST API, which this environment's
proxy authenticates for reads. (If that ever stops working: GitHub MCP `actions_list`
`list_workflow_runs` for `driver.yml`, find the run whose `head_sha` is your SHA, then
`list_workflow_run_artifacts`, then `actions_get` `download_workflow_run_artifact`, and
give `results.py` the signed URL.)

@@TIMES@@

### Why a push, why one shared branch

`driver.yml` has `workflow_dispatch` inputs (`suite`, `scenario`, `ref`, `runs_on`,
`config`, `strict`) and a person can use them from the Actions page. Agents here cannot:
dispatching returns HTTP 403 both through the GitHub MCP tools and through the REST API.
So the lane also starts on any push that adds `docs/driver-requests/<name>.json`.

- The file is under `docs/` because a push that touches only `docs/` starts no other
  workflow in this repository. A request costs one macOS job.
- Everyone pushes to the same branch, `claude/loving-cray-d58nrb-driver`, because
  GitHub scopes build caches to a branch: on a shared branch the second request for the
  same app sources skips the build. (A request pushed as a brand-new branch works but
  always builds; a request force-pushed over an existing branch is compared with the
  branch's old tip and starts CI, UI layout and GPU parity as well. `request.py` does
  neither unless you ask with `--base`/`--branch`.)
- Each request is its own file with a unique name (a timestamp plus random hex unless
  you give `--name`), so concurrent testers never conflict. If two push at once the
  second is rejected and `request.py` retries on the new tip. Each run belongs to its
  own commit, so runs never cancel one another.
- The requests branch carries a copy of the driver and of the app. A request names the
  app to test with `--ref`; the lane checks that ref out, lays the requests branch's
  driver over it and re-installs the hook lines, so any branch can be tested, including
  one that predates the driver. Committed scenarios (`--suite`) are the requests
  branch's; your own go inline with `--scenario`.
- To update the driver on the requests branch (driver maintainers only):
  `git push --force origin <driver commit>:claude/loving-cray-d58nrb-driver`, where that
  commit's message contains `[skip ci]` so the update itself starts nothing.

A request file is `{"suite": "...", "scenarios": [...], "ref": "...", "config": "release",
"strict": false}`, every key optional. `request.py` options:

| option | meaning |
|---|---|
| `--scenario file.json` (repeatable) | scenarios sent inline. A file may hold one scenario or an array of them |
| `--suite "smoke.json repro-*.json"` | committed scenarios, as files or globs under `driver/scenarios/` on the requests branch |
| `--ref <branch, tag or sha>` | the app code to test, resolved to its full commit SHA before the request is written (a short SHA or a branch name is fine). Default: the requests branch's own copy |
| `--name`, `--note` | the request's file name and a line for the commit message |
| `--strict` | fail the job when a check fails. Without it the job is red only for a driver error, hang, timeout or crash |
| `--config debug` | faster build, meaningless timings |
| `--wait`, `--out DIR` | wait for the run and print its results |
| `--base <commit> --branch <new branch>` | one-off: build the request on any pushed commit instead, to test a change to the driver itself |

The account runs about five macOS jobs at once across every workflow, so at most five
requests are in flight and the rest queue. Put many scenarios in one request rather
than one request each.

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
  shots/<name>.png   window screenshots, every sheet, popover, panel and open menu
                     over the window composited in; shots/<id>-NNN.png from a gesture
  targets-<name>.txt from `listTargets`: every name on screen, by window
  witness.json       geometry measured from the screenshots' pixels (fiducial runs)
  probe.json         from a `probe` step
  scenario.json, app.log, exit.txt
  watchdog.json, watchdog-sample.txt        only after a hang or timeout
```

Verdicts: `PASS` every check held · `FAIL` a check failed · `ERROR` the driver could
not do a step (unknown target, event never arrived) · `HANG` the main thread did not
answer for `hangSeconds` (default 30; `watchdog-sample.txt` has every thread's stack) ·
`TIMEOUT` the scenario outlived `timeoutSeconds` (default 300) or one step outlived
`stepTimeoutSeconds` (default 120) · `CRASH` · `KILLED` the outer limit.

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
dictionaries; `request.py --scenario` takes a file holding an array:

```python
import json
scenarios = []
for title, key in [("Exposure", "develop.tone.exposure"), ("Contrast", "develop.tone.contrast")]:
    for to in (0.2, 0.8):
        scenarios.append({
            "name": f"drag-{title}-{to}", "fixture": "fiducial",
            "steps": [
                {"do": "open", "photo": "fiducial.png"},
                {"do": "scrollTo", "target": f"slider/{title}#track"},
                {"do": "drag", "id": "d", "target": f"slider/{title}#track",
                 "from": [0.5, 0.5], "to": [to, 0.5], "duration": 0.6, "settle": 15},
                {"do": "expect", "that": f"recipe.{key}", "exists": True,
                 "note": f"dragging {title} changes it"},
            ]})
json.dump(scenarios, open("/tmp/sweep.json", "w"))
# then: request.py --scenario /tmp/sweep.json ...
```

One process is started per scenario (about 3 s of launch each), so many small scenarios
in one request are cheap; many requests are not.

### Targets

Every pointer verb takes `"target"` and optionally `"at": [fx, fy]` (a fraction of the
target's rectangle, default its centre `[0.5, 0.5]`) and `"offset": [dx, dy]` in points.
All rectangles are main-window points from the window's top-left corner, including those
of sheets, popovers, panels and menus.

**Discover names first**: `{"do": "listTargets", "name": "develop"}` writes
`targets-develop.txt`, every name on screen grouped by window. Copy names from it.

A name is `kind/Label`. It is looked up as an anchor first (exact), then in the app's
accessibility tree (kind by role, then the label: exact, then ignoring case with `...`
equal to `…`, then as a prefix). `*/Label` takes any kind.

| name | what it is | source |
|---|---|---|
| `viewer`, `viewer.image`, `develop.column`, `sidebar`, `filterbar`, `filmstrip`, `rail`, `statusbar`, `grid`, `compare` | the window's regions; `viewer.image` is the picture wherever zoom and pan put it | anchor |
| `slider/<Label>`, `slider/<Label>#track` | a `LumenSlider` row, its track: `slider/Exposure#track` (also in the export sheet: `slider/Quality#track`) | anchor |
| `toggle/<Title>` | a `LumenToggleRow`: `toggle/Strip GPS` | anchor |
| `segment/<Label>` | one option of a `LumenSegmented`: `segment/PNG`, `segment/Screen` | anchor |
| `section/<Title>` | a `LumenSectionHeader` (click folds it): `section/Format` | anchor |
| `menu/<Shown title>`, `picker/<Title>`, `menuitem/<Title>` | a `LumenMenu` trigger by what it shows; a `LumenMenuPicker` by its row title (`picker/Colour`); an item of an open `LumenMenu` | anchor |
| `checkbox/<Group>` | a box in Copy / Sync Settings: `checkbox/Spot Removal` | anchor |
| `rail/<Workspace>` | the rail tabs: `rail/Cull` `rail/Develop` `rail/Crop` `rail/Grade` `rail/Deliver` | anchor |
| `source/<Title>` | a sidebar source row: `source/All photos`, `source/Picked` | anchor |
| `filmstrip-cell/<file>`, `grid-cell/<file>` | a photo's cell: `grid-cell/fiducial.png` | anchor |
| `mask-kind/<Name>`, `mask-create`, `mask-row` | the mask kind tiles, the + button, a row of the mask list | anchor |
| `crop-corner/<topLeft topRight bottomLeft bottomRight>`, `crop-edge/<top bottom left right>`, `heal.canvas` | the crop frame's handles in Crop; the heal tool's canvas (spots are drawn, not views: aim at fractions of it) | anchor |
| `button/<Title>` | any button by its title, description or tooltip: `button/Export…`, `button/Close`, `button/Export Here` | accessibility |
| `checkbox/…` `toggle/…` `radio/…` `popup/…` `field/…` `text/…` `stepper/…` `image/…` `link/…` | AppKit and SwiftUI controls by role: `popup/…` is an AppKit pop-up button, `field/…` a text field (click it, then `type`), `text/…` a label | accessibility |
| `menubar/<Title>`, `menuitem/<Title>` | the menu bar (`menubar/View`), items of an open menu | accessibility |
| `sheet`, `popover`, `alert`, `filePanel`, `colors`, `panel`, `child`, `menu`, `keyWindow` | the frontmost window of that role; `{"window": "sheet", "index": 1}` for another | window list |
| `window`, `cursor` | the main window; wherever the pointer is | |
| `{"name": "button/Reset", "index": 1, "within": "sheet"}` | the second match in reading order, only those whose centre is inside another target (any target, including a window role) | |
| `{"ax": "Export", "role": "AXButton"}` | accessibility by label and raw role | accessibility |
| `{"text": "Presence", "within": "develop.column"}` | the words on screen, found by OCR. Large clear words only; costs about a second | OCR |
| `{"point": [x, y]}` | main-window points | |

A target must be on screen. For a control further down a scrolling column use
`{"do": "scrollTo", "target": "slider/Texture#track"}` first (default container
`develop.column`; `"in": "sheet"` scrolls a sheet). When a target is not found the error
names similar ones and the open windows. Each pointer step's row says how its target was
found (`lastTarget`).

Anchors are views carrying `.driverAnchor("name")`, a modifier that does nothing outside
the driver. The shared controls register themselves (`LumenSlider`, `LumenToggleRow`,
`LumenSegmented`, `LumenSectionHeader`, `LumenMenu`, `LumenMenuPicker`, `LumenMenuItem`),
so a new panel built from them is named with no work. To name something else, append the
modifier to an existing line (tests cite panel lines by number) and add the hook to
`driver/tools/install-hooks.py`, which installs it on refs that predate it. Everything
else is reachable by its accessibility name, which needs no hook.

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
| `pinch` | a trackpad pinch with began/changed/ended phases: `target`, `at`, `scale` (the whole gesture's factor: every event carries the same magnification d with (1 + d) multiplied over all events equal to `scale`, AppKit's convention), `duration`, `hz`, or explicit `deltas` |
| `smartMagnify` | the two-finger double-tap: `target`, `at` |
| `key` | `key` (a letter, digit, symbol, or `return tab space delete escape left right up down`), `modifiers` (`cmd shift option ctrl`), `count`, `interval` |
| `type` | `text`: typed one character at a time into whatever has keyboard focus |
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
- `"film": hz`: watch the screen from a separate thread while the gesture runs, by
  grabbing the window `hz` times a second and noting each time the pixels of
  `filmRegion` (default `viewer`) changed. This is the outside view of "did the picture
  update": it does not depend on anything the app reports.
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

`probe.json` asserts each row for each backend; the last run of it (hosted `macos-15`,
see its report) passed all 26 checks:

| what the scenario did | effect it checked | `hid` | `app` |
|---|---|---|---|
| mouse move over the viewer | the viewer's `onContinuousHover` reports that exact point | yes | yes |
| wheel over the viewer | zoom leaves fit | yes | yes |
| pinch (began, 18 changes, ended) | `MagnifyGesture` fires, zoom leaves fit | yes | yes |
| double-click | fit goes to 1:1 | yes | yes |
| drag on the zoomed picture | pan changes | yes | yes |
| two-finger scroll on the zoomed picture | pan changes | yes | yes |
| bare key `G`, `E` | grid, loupe | yes | yes |
| chord `cmd-4`, `cmd-2` | Grade, Develop (through the menu bar) | yes | yes |
| drag on a slider track | the recipe value changes | yes | yes |
| double-click on a slider label | the value resets | yes | yes |
| smart magnify, right-click | received by the app; the app has no handler for smart magnify | received | received |

How `app` delivers scroll and gesture events, since they cannot be built as `NSEvent`s
directly: a `CGEvent` is converted with `NSEvent(cgEvent:)` and queued. AppKit attaches
no window to such an event, so the driver takes it back at dispatch and calls the view
under the point (`scrollWheel`, `magnify`), which is what `NSWindow.sendEvent` does.
The event's own location is then a screen point; the driver parks the window on the
display's origin so screen and window points coincide. Gesture events are the
undocumented layout WebKit's tests use (type 29, field 110 = 8, 113 = magnification,
132 = phase).

Not the real path, and marked so in each step's `via`: `open` and `direct` (`direct`),
`menu` (`menu`).


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
| `state` | writes `state-<name>.json`: everything below plus every named target's rectangle, the menu bar and the sidecar; `"texts": true` adds OCR, `"ax": true` the accessibility names |
| `listTargets` | writes `targets-<name>.txt` and `.json`: every window, every anchor and every accessibility name on screen, grouped by window, with rectangles. Run it once wherever you are going to aim |
| `press` | performs `AXPress` (or `action`) on a named accessibility element: no pointer, `via: ax`. For a control the pointer cannot reach |
| `filePanel` | waits for the open or save panel and points it at `folder` (`$OUT`, `$PHOTOS`, `$TMP` expand; created if missing), optionally `fileName`. `via: direct`. Confirm it with a click or `return`; `"confirm": "direct"` calls the panel's OK |
| `files` | lists `dir` (default `$OUT`): `steps.<id>.count`, `.bytes`. Files under `$OUT` are in the artifact |
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
| `windows.sheet`, `.popover`, `.alert`, `.filePanel`, `.colors`, `.panel`, `.menu` | whether such a window is on screen (`waitFor` `windows.sheet` `eq true` after opening one); `windows.count`, `.roles`, `.key` (the key window's role), `.sheetTitle`, `.list.N.role/title/x/y/w/h` |
| `export.running`, `.progress`, `.recipes.items.N.<field>` | the export batch, and the export recipes as the sheet edits them (`export.recipes.items.0.quality`, `.metadata.includeGPS`, `.sharpen.medium`) |
| `lastTarget.source`, `.name` | how the last pointer step's target was found: `anchor`, `ax`, `window` or `text` |
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
| `postingMs`, `gestureMs` | how long sending took; when the app received the gesture's last event. A healthy app has them nearly equal; a gap is the main thread falling behind. "During" below means up to that moment |
| `framesDuring`, `framesDuringDraft`, `framesAfter` | frames the loupe put on screen while the gesture ran, and after |
| `maxFrameGapMs`, `firstFrameMs`, `fpsDuring` | the longest wait without a new frame inside the gesture; the first frame's delay |
| `distinctValues`, `distinctValuesShown` | how many different settings the gesture produced, and how many of those ever reached the screen |
| `latencyMs.min/p50/p90/max/n` | for each frame during the gesture: time from the moment its settings first existed to the frame showing them |
| `staleFramesDuring` | frames that showed settings already superseded when they landed |
| `releaseToFinalValueMs`, `releaseToSharpMs`, `releaseToSettledMs` | from the end of the gesture to the first frame of the final settings, to the first sharp one, and (with `settle`) to the settled one. Negative: it was already there |
| `hitches`, `hitchMaxMs`, `hitchTotalMs`, `hitchAfterMaxMs` | main-thread run-loop turns longer than 25 ms during the gesture; the longest one after it |
| `screenChangesDuring`, `screenChangesAfter`, `screenFirstChangeMs`, `screenMaxGapMs`, `screenLastChangeMs`, `screenTrace` | with `film`: how many times the watched region visibly changed during and after the gesture, when it first changed, the longest stretch without a change inside the gesture, when it last changed relative to the gesture's end, and `[ms, amount]` per change |
| `watchStart`, `watchEnd`, `frameTrace` | with `watch` |

"Frame" means the loupe's render model replaced the image it shows. Zoom and pan move
the existing image without a new frame, so judge those from screenshots.

`timeline.jsonl` has the raw rows (`t` is seconds since the driver started): `in` an
event sent, `rx` an event the app received, `frame`, `commit` (the frame left for the
window server), `hitch`, `step`, `shot`, `mark`.

`tl` rows are the app's own stamps (`LatencyHUD.noteTimeline`), each with `stage` and
`rev` (the edit revision it concerns): `input` an edit written; `turn` the end of that
edit's run-loop turn, `main` = main-thread ms it cost; `request` and `start` a draft
asked for and begun; `frame` handed to the view (`draft`, `edge`, `ms` as the viewer
saw it, `lane` inside the renderer); `overlay` an overlay picture put on screen
(`name`: `sampler`, `maskAlpha`, `maskWash`, `clipping`, `peaking`, `spots`).

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

- **Timings are a virtual machine's.** Three cores, a paravirtual GPU, 60 Hz, 1x. A
  9-second stall here may be 300 ms on a real Mac. Compare runs on the same runner
  class only, and read `machine` in the report.
- **"Frame" is the app's render model, not the glass.** `film` is the outside check
  (it samples at the rate you give it, so it cannot count above that).
- **Hover of `onHover` views in `app` mode is unverified.** `onContinuousHover` is
  verified for both backends; plain `onHover` (the mask rows) has only been exercised
  through `hid`.
- **`NSEvent.modifierFlags` does not follow `app`-mode modifiers** (slider fine-drag
  with shift, option-drag in the mask canvas read it). Use `hid` for those.
- **OCR is weak on this runner.** The accurate recognizer returns nothing on the VM and
  the fast one misreads small 1x type ("Pivot" comes back as "Diwot"). `{"text": ...}`
  targets work for large, clear words only; prefer named targets.
- **Accessibility names cost main-thread time.** The tree is read the way an outside
  client reads it (from a background thread, while the main thread answers), and once a
  client has asked, SwiftUI keeps the tree up to date. A scenario that measures timing
  should aim only at anchors (slider tracks, regions) and not run `listTargets`, `press`
  or a name that is not an anchor before its measured gestures.
- **Heal spots and mask pins have no names**: they are drawn on a canvas; aim at fractions of `heal.canvas` or `viewer.image`.
- **The pixel witness needs the fiducial fixture** and at least two grid lines each
  way. It does not understand rotation, flips or crops.
- **One process per scenario.** Sheets, popovers, panels, alerts and the open panel are
  targetable and in screenshots. A window that reaches past the main window is also saved
  whole as `shots/<name>.<role><n>.png` (listed in the shot's `windows`).
- **A menu-bar menu runs its own tracking loop.** Clicking `menubar/View` by `hid` opens
  it; prefer the `menu` verb, which performs the item without the loop.
- **The catalog database is not copied into the artifact.** The XMP sidecar is in every
  `state` dump (`sidecar`).
- **HID events need the point on the display.** The driver switches the runner's display
  to a mode that holds the window (1600x1200 for the default 1440x900); a larger
  `window` than any mode falls back to `app` for the part that is off-screen.


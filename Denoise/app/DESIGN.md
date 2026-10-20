# Lumen Denoise Mac app: design (v0.2)

The binding contract the five source files were written against, updated to what was actually built.
The last section lists every change made after the first draft of this contract. App lives in Denoise/app/ only.
Target: macOS 14+ (Package.swift platforms .macOS(.v14), swift-tools-version 5.9 => Swift 5 language mode; the Mac
builds with a Swift 6.x compiler from Xcode 16). No third-party dependencies. Native SwiftUI / AppKit / Core Image / ImageIO /
UserNotifications only. The cloud CANNOT build macOS apps. Linux has a Swift 6.0.3 toolchain at /opt/swift/usr/bin
(export PATH=/opt/swift/usr/bin:$PATH). Foundation-only files (Engine.swift, Core.swift) MUST compile and run on Linux
(use `#if canImport(Darwin) import Darwin #else import Glibc #endif` where libc is needed). Mac-only files can only be
checked with `swiftc -parse` (syntax) plus careful reading; check every API against the macOS 14 SDK from memory and
avoid anything macOS 15+ (or mark it `if #available(macOS 15, *)`). Prefer boring, well-known APIs over clever ones.

The Python engine (owned by another team, DO NOT modify anything under Denoise/lumen_denoise):
`python -m lumen_denoise.infer IN1 IN2 ... --out DIR --strength S` (S in 0...1). It loads the model once, then for each
input in order writes `DIR/<stem>-Denoised.dng` (writes directly, not atomically; DNG Converter is spawned as a child
subprocess) and prints exactly one JSON line per file, flushed:
`{"file": "...", "out": "...", "iso": 3200, "model": "ILCE-7M4", "K": .., "read_sd": .., "denoise_s": 2.1, "total_s": 3.4}`
Any exception aborts the whole process (nonzero exit, Python traceback on stderr). Inputs: .ARW (Sony A7 IV), .RW2
(Panasonic GX85), .DNG.

## Files (exactly these; Sources/LumenDenoise/)

1. Engine.swift  (Foundation only, Linux-testable)  - config, output guard, file discovery, process runner.
2. Core.swift    (Foundation only, Linux-testable)  - pure queue logic: types, persistence codec, naming, chunk planning,
                                                       ISO strength bands, ETA/throughput, error translation.
3. Model.swift   (SwiftUI/AppKit/ImageIO/UserNotifications) - @MainActor QueueModel: ObservableObject, glues Core + Engine.
4. Preview.swift (SwiftUI/AppKit/CoreImage)          - before/after split preview with 100% zoom.
5. LumenDenoiseApp.swift (SwiftUI/AppKit)            - @main App, ContentView, commands/shortcuts, Settings scene,
                                                       snapshot/selftest/autotest hooks.
Tests/ (Denoise/app/Tests/, NOT part of the SwiftPM target): EngineTests.swift, CoreTests.swift, main.swift,
fake_engine/lumen_denoise/{__init__.py,infer.py}, run_linux_tests.sh (also runs on Mac:
`swiftc Sources/LumenDenoise/Engine.swift Sources/LumenDenoise/Core.swift Tests/*.swift -o /tmp/lumen-tests && /tmp/lumen-tests`).
Tests/main.swift runs both `runEngineTests()` and `runCoreTests()` unconditionally (both `func ... -> Bool`, printing
PASS/FAIL lines) and exits 0 only if both pass. Each test func must clean up its temp dirs.

## Engine.swift public API (names are binding)

```swift
enum Cfg {
    static var projectRoot: String   // env LUMEN_DENOISE_ROOT ?? UserDefaults "engineRoot" ?? "/Users/benedekpurnhauser/Projects/lumen-denoise"
    static var python: String        // env LUMEN_PYTHON ?? projectRoot + "/.venv/bin/python"
    static let module = "lumen_denoise.infer"
    static let forbiddenRoot = "/Volumes/Offload Drive"
    static let defaultOut: String    // NSHomeDirectory() + "/Pictures/Lumen Denoise"
    static let exts: Set<String>     // ["arw", "rw2", "dng"]
    static let stagingPrefix = ".lumen-staging-"
}
func isForbiddenOutput(_ path: String) -> Bool   // must also catch symlinks whose target is on the drive when the
                                                  // drive is NOT mounted (resolve links component-wise with lstat/readlink,
                                                  // max 40 hops, any loop/err => treat as forbidden), case-insensitive,
                                                  // "/Volumes/Offload Drive Two" is NOT forbidden.
func guardSelfTest() -> Bool                      // the old selfTest() cases + unmounted-drive symlink cases; prints PASS/FAIL
func collectInputs(_ urls: [URL]) -> [URL]        // recursive, skips hidden + package contents, skips our own "*-Denoised.dng"
                                                  // outputs and anything inside a ".lumen-staging-*" dir, sorted by path
                                                  // (localizedStandardCompare) per dropped folder, dedup by standardized path.
struct EngineResult: Decodable, Equatable { let file: String; let out: String; let iso: Int?; let model: String?; let denoise_s: Double?; let total_s: Double? }
// Tolerant decoding: iso may be a float (3200.0), NaN/Infinity anywhere (JSON5 decoder) become nil.

/// One python process for one chunk of files with one strength. Writes into a private staging dir inside the
/// output folder; the caller moves each finished file into place. All callbacks are delivered on the MAIN queue,
/// in order, and `onExit` is delivered exactly once, after every `onResult`/`onLog`.
final class EngineRun {
    init(files: [String], outDir: String, strength: Double)
    let stagingDir: String                        // "<outDir>/.lumen-staging-p<pid>-<uuid>"  (created by start())
    var onResult: ((EngineResult) -> Void)?
    var onLog: ((String) -> Void)?                // non-JSON stdout lines and stderr lines (for the log panel)
    var onExit: ((EngineExit) -> Void)?
    func start() throws                           // throws EngineError.launch(String) with a human message
    func cancel()                                 // SIGTERM the whole process group, SIGKILL after 3 s; idempotent
    var isRunning: Bool { get }
    func removeStaging()                          // rm -rf stagingDir (only if its last path component has stagingPrefix)
}
struct EngineExit { let code: Int32; let cancelled: Bool; let stderrTail: String /* last ~40 lines */; let uncaughtSignal: Bool }
enum EngineError: Error, LocalizedError { case launch(String) }
func sweepStaleStaging(in outDir: String)          // removes leftover ".lumen-staging-*" dirs (crash recovery); spares
                                                   // live runs of this process and "-p<pid>-" dirs of another live process
func killAllRunningEngines()                       // for applicationWillTerminate: SIGKILL every live EngineRun group
```

Process requirements (these are the bug fixes; the old code had them wrong):
- Launch via Foundation `Process` with executable `Cfg.python` and arguments
  `["-c", BOOTSTRAP, Cfg.module] + files + ["--out", stagingDir, "--strength", String(format: "%.3f", strength)]`
  where BOOTSTRAP is a short python snippet that: `os.setpgrp()` (own process group so cancel also kills the DNG Converter
  child), starts a daemon thread that `os.killpg(0, SIGTERM)`s if `os.getppid()` changes (app died), sets `sys.argv`
  from the remaining args, then `runpy.run_module(sys.argv[0], run_name="__main__", alter_sys=True)`. cwd = projectRoot.
  env: inherit + PYTHONUNBUFFERED=1, PYTHONIOENCODING=utf-8, PATH prefixed with the python's bin dir, /opt/homebrew/bin,
  /usr/local/bin (Finder launches have no Homebrew PATH; the engine runs exiftool), TMPDIR=stagingDir (the DNG Converter's
  intermediates are then removed with staging).
- Check before launch: python exists & executable, projectRoot exists, else EngineError.launch with a fix-it message.
- Read stdout and stderr each on its own background thread with blocking `availableData` loops until EOF (no
  readabilityHandler races). Line-split on "\n" with a carry-over buffer; a JSON line split across reads must decode.
  Only lines starting with "{" are decoded; decode failures go to onLog. Trailing data without newline at EOF is
  processed too. onExit fires when the process has terminated AND both readers hit EOF, or 2 s after termination if a
  grandchild still holds a pipe open.
- cancel(): `kill(-pgid, SIGTERM)` (pgid == pid because of setpgrp; fall back to proc.terminate()), then SIGKILL the
  group after 3 s if still alive. A cancelled run must leave no partial file outside the staging dir (by construction).
- Keep a static registry of live runs for killAllRunningEngines().

## Core.swift public API (names are binding)

```swift
enum ItemState: String, Codable { case queued, working, done, skipped, failed, cancelled }
struct QueueItem: Identifiable, Codable, Equatable {
    var id: UUID
    var source: String            // absolute path
    var output: String            // planned final DNG path (assigned by assignOutputs)
    var state: ItemState
    var iso: Int?                 // from EXIF at enqueue, overwritten by engine result
    var camera: String?
    var strengthOverride: Double? // 0...1, per-item override from the preview panel
    var usedStrength: Double?     // strength actually used for the finished output
    var seconds: Double?          // engine total_s
    var error: UserFacingError?
    var finishedAt: Date?
    init(source: String)
}
struct UserFacingError: Codable, Equatable { var title: String; var detail: String; var raw: String }
/// Translate engine stderr / launch errors into a short title + one-sentence fix. Cover at least: python/venv missing,
/// ModuleNotFoundError/ImportError, weights/calib file missing, DNG Converter missing, rawpy/LibRaw unsupported or corrupt
/// file, MemoryError / killed by signal 9 (out of memory), "No space left on device", PermissionError / Operation not
/// permitted (Full Disk Access hint), Offload Drive refusal, cancelled, unknown (last traceback line as detail).
func translateError(stderr: String, code: Int32, uncaughtSignal: Bool) -> UserFacingError
/// isFatal == the remaining files would fail the same way (env problems: python/module/weights/converter/disk full).
func isFatal(_ e: UserFacingError) -> Bool

struct ISOBand: Codable, Equatable, Identifiable { var id: UUID; var maxISO: Int; var strength: Double }  // inclusive upper bound
struct StrengthSettings: Codable, Equatable {
    var global: Double = 1.0
    var autoByISO: Bool = true
    var bands: [ISOBand]          // default: <=800: 0.55, <=3200: 0.75, <=12800: 0.9, <=Int.max: 1.0
    static let `default`: StrengthSettings
    func strength(for item: QueueItem) -> Double   // override ?? (autoByISO && iso != nil ? band : global), clamped 0...1, rounded to 0.05
}
/// Final output names: "<outDir>/<stem>-Denoised.dng"; if another item in the list (different source) already claims that
/// name, append "-2", "-3" ... (case-insensitive compare, APFS is case-insensitive). Stable: items that already have an
/// output in outDir keep it.
func assignOutputs(_ items: inout [QueueItem], outDir: String)
/// Chunk plan: queued items grouped by identical strength (NOT only consecutive ones: each chunk takes the first remaining
/// item's strength and every later remaining item with that strength), no two items in one chunk share a stem
/// (case-insensitive; the engine names by stem inside staging), max 60 items per chunk. Chunks come out in
/// first-appearance order of their strength; queue order is kept within a chunk.
struct Chunk: Equatable { var itemIDs: [UUID]; var strength: Double }
func planChunks(_ items: [QueueItem], settings: StrengthSettings) -> [Chunk]
/// True when output exists, is non-empty, is newer than the source and (if it records one) was made from this source.
func isAlreadyDone(source: String, output: String) -> Bool
/// Output ownership: Model writes the source path as an xattr on every finished DNG; assignOutputs moves on to "-N" when
/// a file on disk records a different source.
let outputOwnerXattr: String                     // "com.lumen.denoise.source" ("user." prefixed on Linux, tests only)
func outputOwner(_ path: String) -> String?

/// Throughput: exponential moving average (alpha 0.3) of wall-clock seconds between successive results, seeded by the first
/// result of a run (which includes model load). ETA = remaining * avg. Ignores gaps across pauses (reset() at run start).
struct Throughput {
    mutating func reset(now: Date)
    mutating func record(now: Date)
    mutating func restartClock()                   // next result only starts the clock (each engine run reloads the model)
    var secondsPerFile: Double? { get }
    var filesPerMinute: Double? { get }
    func eta(remaining: Int) -> TimeInterval?
}
func formatDuration(_ s: TimeInterval) -> String      // "42 s", "3 min", "1 h 05 min"

/// Persistence: ~/Library/Application Support/Lumen Denoise/queue.json  (directory passed in for tests).
struct SavedQueue: Codable { var version: Int = 1; var items: [QueueItem]; var outDir: String }
func saveQueue(_ q: SavedQueue, to dir: String) throws      // atomic write
func loadQueue(from dir: String) -> SavedQueue?             // on load: working -> queued; done/skipped whose output is
                                                             // gone -> queued; sources that no longer exist -> failed("Source missing")
```

## Model.swift (QueueModel) contract, used by the views

```swift
@MainActor final class QueueModel: ObservableObject {
    @Published var items: [QueueItem]
    @Published var selection: Set<UUID>         // List selection; preview shows `selectedItem` (first selected)
    @Published var outDir: String               // persisted (UserDefaults "outDir"); setOut(_:) validates with guard
    @Published var strength: StrengthSettings   // persisted (UserDefaults "strength", JSON)
    @Published var skipDone: Bool               // persisted, default true
    @Published var notifyWhenDone: Bool         // persisted, default true
    @Published private(set) var running: Bool
    @Published private(set) var cancelling: Bool
    @Published var alert: AlertInfo?            // struct AlertInfo: Identifiable { id, title, message }
    @Published private(set) var log: [String]   // last 500 engine log lines
    @Published private(set) var throughput: Throughput
    var selectedItem: QueueItem? { get }
    var counts: (total: Int, done: Int, skipped: Int, failed: Int, remaining: Int) { get }
    var progressFraction: Double { get }
    var statusLine: String { get }              // e.g. "12 of 300 · 14.6 photos/min · about 19 min left, finishes ≈14:32"
    func add(_ urls: [URL])                     // async EXIF ISO read off-main; allowed while running (new items just queue)
    func addViaPanel()                          // NSOpenPanel, files + folders, multiple
    func chooseOut()  ;  func setOut(_ path: String)
    func start()                                // runs all queued (and re-queues failed/cancelled) items, chunk by chunk
    func cancel()
    func retryFailed()
    func remove(_ ids: Set<UUID>)               // not the working item
    func clearFinished()                        // removes done + skipped
    func clearAll()                             // only when not running
    func reprocess(_ ids: Set<UUID>)            // force re-run even if already done (ignores skipDone for these)
    func setOverride(_ id: UUID, _ s: Double?)
    func reveal(_ id: UUID?)                    // reveal output (or out folder) in Finder (activateFileViewerSelecting)
    func openOutput(_ id: UUID)                 // open DNG in default app
    func copyError(_ id: UUID)
    func strengthFor(_ item: QueueItem) -> Double
    func autotestIfRequested()                  // see below
    func appWillTerminate()                     // cancel + killAllRunningEngines + removeStaging + save
}
```
Behaviour: start() validates outDir (guard, create dir, re-check guard after creating, writable test file), sweeps stale
staging, assigns outputs, marks skip-done items `.skipped`, requests notification permission lazily, then runs chunks
sequentially. On each EngineResult: verify `result.out` is inside the run's stagingDir, re-check guard on the final path,
move into final (replace existing atomically via FileManager.replaceItemAt or remove+move), mark done, record throughput.
On non-cancelled nonzero exit: the first not-yet-finished item of the chunk gets the translated error; if isFatal ->
all remaining queued items get that error and the batch stops (one alert); else continue with a new chunk for the rest.
On cancel: working + queued items in the current run -> .cancelled, staging removed, no partial DNGs anywhere.
Exit code 0 but items without results -> failed "Engine finished without a result for this file".
After the batch: if notifyWhenDone and app is not active -> UNUserNotificationCenter notification ("Denoised 298 photos ·
2 failed · 21 min") (guard `Bundle.main.bundleIdentifier != nil` so `swift run` does not crash), NSApp.requestUserAttention,
dock badge shows remaining count while running and is cleared after. Queue saved (debounced 0.5 s) on every change; loaded
on init unless autotest mode. EXIF ISO via CGImageSourceCopyPropertiesAtIndex (kCGImagePropertyExifDictionary /
kCGImagePropertyExifISOSpeedRatings, and TIFF Model for camera) on a background queue, batched back to main.

Autotest (env-driven, used by the main session on the Mac, keep backward compatible):
LUMEN_AUTOTEST_FILES (colon-separated paths, files or folders), LUMEN_AUTOTEST_OUT (output dir). Optional:
LUMEN_AUTOTEST_CANCEL_AFTER=N (cancel after N results; verifies cleanup), LUMEN_AUTOTEST_STRENGTH=0.8 (global, disables auto-ISO),
LUMEN_AUTOTEST_PREVIEW=/path.png (after the batch, render before/after preview of the first done item at fit and 100%
via Preview.swift's renderer and write a side-by-side PNG). Autotest does not load or save the persisted queue or
UserDefaults. Writes `<OUT>/autotest.json`: {outDir, alert, staleStagingDirs: [..], partialFilesOutsideStaging: [..],
items: [{file, output, status, seconds, iso, strength, error}]} then terminates.

## Preview.swift contract

```swift
final class RawRenderer {                         // CIRAWFilter based, renders off-main, caches last 2 pairs
    static let shared: RawRenderer
    func render(url: URL, maxPixel: CGFloat?, completion: @escaping (CGImage?, String?) -> Void)   // main-queue completion; nil maxPixel = full res
    func renderDetailed(url:maxPixel:group:matchExposureOf:completion:)  // + 100% size, stale-request skipping, exposure match
}
enum PreviewZoom { static let notification /* "fit" | "actual" */; static let keyNotification /* "holdOn" | "holdOff" | "toggleZoom" | "toggleSplit" */ }
struct BeforeAfterView: View { init(item: QueueItem) }   // whole preview pane incl. its toolbar row
func writePreviewPNG(before: URL, after: URL, to path: String, completion: @escaping (Bool) -> Void)  // for autotest
```
Both images rendered with identical CIRAWFilter settings: luminanceNoiseReductionAmount = 0, colorNoiseReductionAmount = 0
(if supported) so the comparison is honest, same scale. Fit mode renders at ~2x view size; 100% mode renders full res
(1 image pixel = 1 device pixel, i.e. point size = pixels / backingScaleFactor). Draggable vertical split handle (before left,
after right), labels "Before" / "After", drag to pan when zoomed, double-click toggles fit / 100% centred on the click,
keyboard: Z or ⌘1 = 100%, ⌘0 = fit, Space (hold or toggle) = show Before full frame, \ = toggle split vs. after only.
If the item is not done: show the original only with a caption. Loading spinner; error text if CIRAWFilter fails.
Strength override slider for the selected item lives here ("Re-run this photo at 70%" button calls reprocess).

## LumenDenoiseApp.swift contract

Window: NavigationSplitView (sidebar = queue list with multi-select, status icons, per-row ISO/strength/time, context
menu: Reveal, Open, Re-process, Remove, Copy error; detail = BeforeAfterView or an empty-state drop zone). Bottom bar:
progress bar + statusLine, strength controls (global slider, "Auto by ISO" toggle, link to settings), output folder chooser,
Start / Cancel. Whole window accepts file drops. Errors shown inline per row (title red, detail secondary, raw in help/tooltip
and copyable) and batch-level problems in an alert. Settings scene (⌘,): ISO band table editor, skip-done, notify toggle,
engine folder picker (UserDefaults "engineRoot"), log viewer. Menu commands with shortcuts: Add Files… ⌘O, Choose Output
Folder… ⇧⌘O, Start Denoising ⌘R, Cancel ⌘. , Retry Failed ⇧⌘R, Remove Selected ⌫ (list only; no ⌘⌫ menu equivalent, it would fire while editing text fields), Clear Finished ⇧⌘K,
Reveal in Finder ⌥⌘R, Show Log ⌥⌘L, zoom ⌘0/⌘1 (forwarded to preview through a FocusedValue or the model).
Light/dark: only semantic colours (Color.primary/secondary, .background, NSColor.controlBackgroundColor...), status colours
green/orange/red that read in both modes, materials for bars; no hard-coded white/black except image letterboxing.
`--selftest` CLI flag: runs guardSelfTest() and a few Core checks then exit(0/1). LUMEN_SNAPSHOT=/x.png keeps working.
NSApplicationDelegateAdaptor for applicationWillTerminate -> model.appWillTerminate(), and
applicationShouldTerminate: if running, ask "Cancel the batch and quit?".

## Changes after the first draft (review and fix rounds)

Engine.swift
- `isForbiddenOutput` also refuses "/Volumes/Offload Drive <digits>" (how macOS renumbers a mount when a stale mount-point
  folder exists) and, on macOS, any path whose volume is named "Offload Drive" wherever it is mounted.
- Staging dirs carry the owner pid (`.lumen-staging-p<pid>-<uuid>`) so a second app instance never deletes live staging.
- PATH/TMPDIR environment as above; cancel-before-start leaves `isRunning == false`; venv fix-it names the packages
  (`pip install torch rawpy numpy tifffile`).

Core.swift
- New: `ErrorTitle.converterFailed` (non-fatal), `outputOwnerXattr`, `outputOwner(_:)`, `Throughput.restartClock()`.
- The Offload error only matches the engine's exact refusal; a missing source on the drive is "File not found".
- planChunks groups by strength across the queue (Auto by ISO on a mixed shoot no longer reloads the model per photo).

Model.swift
- Same-name output from another shoot (camera numbering repeats): EXIF DateTimeOriginal + SubsecTimeOriginal + camera
  model, plus the owner xattr, decide; a different shot gets `<stem>-N-Denoised.dng` and is never overwritten.
- `reprocess` / `retryFailed` while idle run only those photos (batch scope); while running they join the batch.
- Two consecutive engine runs dying before any result with the same error stop the batch with one alert.
- Output folder gone mid-batch (drive ejected) stops with one alert; an unmounted `/Volumes/<name>` is never created.
- Files are moved into place with POSIX rename (atomic, works on exFAT/SMB); the source path is written as an xattr.
- A strength change for a photo the engine already has re-queues it after its result.
- `LUMEN_AUTOTEST_CANCEL_AFTER=0` cancels 3 s after the engine launches (cancel during model load); the autotest report
  and preview PNG are never written onto the Offload Drive.

Preview.swift
- The denoised DNG is rendered with the original's baselineExposure / neutralTemperature / neutralTint so the split
  shows only noise differences. Cache capped at 320 MB / 2 full-res frames. Selecting a photo never steals list focus;
  the queue list forwards Space / Z / \ via `PreviewZoom.keyNotification`.

LumenDenoiseApp.swift
- With Auto by ISO on, the bottom bar shows the band summary (opens Settings) instead of the global slider; the global
  value is edited in Settings as "Photos without ISO". Band editor binds by id (no index-out-of-range on delete).
- Queue list follows the photo in progress while nothing is selected; Return / double-click opens the DNG or reveals the
  original; missing engine shown in the empty state with a Settings link; VoiceOver labels on icon-only controls.

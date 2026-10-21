// PanelSnapshotTests.swift — every editing panel, drawn to a PNG on a real Mac.
//
// WHY THIS FILE EXISTS. Every UI check in this tree before it was either a text scan or
// a CoreText measurement (`LayoutMetricTests`): numbers about the interface, never the
// interface. The agents that do most of the UI work here run on Linux and have never
// seen the app at all. This file is their eyes: on the macOS runner it hosts the real
// views — the same structs the window builds, against a real `AppState` opened on
// temporary directories (`AppStateSeamTests`) — in an offscreen window, in the dark
// appearance the app forces, at 2x, and writes what they draw to PNG files. The
// `ui-snapshots` workflow commits those files to the `ui-snapshots` branch, where any
// checkout can `git fetch` them and open them.
//
// IT IS AN INSTRUMENT, NOT A GATE. Nothing here asserts on pixels and nothing here
// fails the run: a panel that cannot be built or drawn is RECORDED in `index.md` with
// the reason, and the rest still render. A snapshot suite that goes red over one
// AppKit-backed control would stop showing the forty views that were fine.
//
// OPT-IN, because the full optimized suite (`ci.yml` test-fast) runs every test in this
// target: the test skips unless `SNAPSHOT_DIR` is set (or `LUMEN_UI_SNAPSHOTS=1`, which
// writes to `build/snapshots` at the package root). The workflow sets `SNAPSHOT_DIR`.
//
// HOW A VIEW BECOMES A PNG. `NSHostingController` in a borderless `NSWindow`, then
// `cacheDisplay(in:to:)` into a bitmap whose pixel extent is twice its point size — the
// route `swift-snapshot-testing` takes on macOS, and the one that draws AppKit-backed
// pieces (every `LumenSlider` carries an `NSViewRepresentable` overlay for ⌥-scroll,
// and the develop column scrolls in an `NSScrollView`). `ImageRenderer` is the
// fallback, used only when the hosted capture comes back a single flat colour: it
// cannot draw AppKit views (it substitutes a placeholder), but it can always draw the
// SwiftUI around them. Which route produced each file is written beside it.
//
// The window reports a backing scale of 2 so SwiftUI rasterizes text and shapes at
// Retina density rather than drawing 1x layers into a 2x bitmap. `index.md` records the
// pixel size of every file; a 2x file is exactly twice its point size.
//
// WHAT THE STATE IS. Panels draw against a synthetic RAW frame (`DSC04821.arw`, ISO
// 3200, no file behind it — panels read the recipe and the item, never the pixels) with
// a representative edit on it, so the modified dots, readouts and reset affordances are
// in their working state rather than all at zero. The full window opens a folder of
// three synthetic PNG "photographs" through the real scan, so the grid, the filmstrip,
// the loupe, the histogram and the mask overlay are the pipeline's own output.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI
import XCTest
@testable import LumenApp

final class PanelSnapshotTests: XCTestCase {

    /// THE ONE TEST. A single method rather than one per panel because the expensive
    /// part — an `AppState`, its catalog, a scanned folder, a loaded loupe frame — is
    /// shared, and because one method makes the order of the state changes (empty masks
    /// before two masks before a selection) the order of the files.
    @MainActor
    func testRenderEveryPanelToPNG() async throws {
        guard let directory = SnapshotRecorder.outputDirectory() else {
            throw XCTSkip("UI snapshots are opt-in: set SNAPSHOT_DIR (or "
                          + "LUMEN_UI_SNAPSHOTS=1) to render them")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-snapshots-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remembered = SnapshotDefaults.capture()
        defer {
            SnapshotDefaults.restore(remembered)
            try? FileManager.default.removeItem(at: root)
        }

        // A process with no `NSApplication` has `NSApp == nil`, and AppKit-backed pieces
        // of the app read `NSApp.currentEvent` from `hitTest`. Accessory: windows, no
        // Dock icon, no activation.
        let app = NSApplication.shared
        _ = app.setActivationPolicy(.accessory)

        let recorder = SnapshotRecorder(directory: directory)
        await renderPanels(recorder, root: root)
        await renderWindow(recorder, root: root)
        recorder.writeIndex()
        print("UI snapshots: \(recorder.entries.count) entries, "
              + "\(recorder.entries.filter { $0.file != nil }.count) files, in \(directory.path)")
    }

    // MARK: - Panels, against a synthetic RAW frame

    @MainActor
    private func renderPanels(_ recorder: SnapshotRecorder, root: URL) async {
        let state = AppState(catalogDirectory: { root.appendingPathComponent("panel-catalog") },
                             previewDirectory: { root.appendingPathComponent("panel-previews") })
        defer { state.prepareToQuit() }
        recorder.attach(state)

        let photo = PhotoItem(id: root.appendingPathComponent("DSC04821.arw"), iso: 3200)
        state.developPanelWidth = Lumen.defaultPanelWidth
        state.primarySelection = photo
        state.selection = [photo.id]
        PanelLayout.shared.select(.develop)
        SnapshotFixtures.applySampleEdit(state)
        await recorder.settle(0.5)

        let width = state.developPanelWidth

        // One card per accordion section, drawn the way `WorkspaceSectionView` draws it.
        let sections: [(name: String, section: WorkspaceSection, caption: String)] = [
            ("panel-develop-white-balance", .whiteBalance, "Develop ▸ White Balance"),
            ("panel-develop-tone", .tone, "Develop ▸ Tone (the Light controls)"),
            ("panel-develop-curve", .curve, "Develop ▸ Curve"),
            ("panel-develop-presence", .presence, "Develop ▸ Presence"),
            ("panel-develop-detail", .detail, "Develop ▸ Detail (sharpening and Denoise)"),
            ("panel-crop-frame", .frame, "Crop ▸ Crop (ratio, angle, guides)"),
            ("panel-crop-lens", .optics, "Crop ▸ Lens"),
            ("panel-grade-looks", .looks, "Grade ▸ Looks"),
            ("panel-grade-colour", .color, "Grade ▸ Colour (mixer and point colour), no swatches"),
            ("panel-grade-grading", .grading, "Grade ▸ Grading (colour wheels)"),
            ("panel-grade-film-lab", .filmLab, "Grade ▸ Film Lab, no stock loaded"),
            ("panel-grade-effects", .effects, "Grade ▸ Effects (vignette, grain)"),
            ("panel-deliver-soft-proof", .softProof, "Deliver ▸ Soft Proof"),
        ]
        for entry in sections {
            await recorder.render(entry.name, entry.caption, width: width) {
                SnapshotSectionCard(entry.section, isModified: recorder.isModified(entry.section)) {
                    SnapshotSectionBody(section: entry.section)
                }
            }
        }

        // Folds that start closed, opened by a click.
        await recorder.render("panel-develop-detail-noise-open",
                              "Develop ▸ Detail with the Noise Reduction fold opened",
                              width: width, press: ["Noise Reduction"]) {
            SnapshotSectionCard(.detail, isModified: recorder.isModified(.detail)) {
                DetailPanel(only: .detail)
            }
        }
        await recorder.render("panel-develop-tone-zones-open",
                              "Develop ▸ Tone with the Zones fold opened",
                              width: width, press: ["Zones"]) {
            SnapshotSectionCard(.tone, isModified: recorder.isModified(.tone)) {
                BasicPanel(only: .tone)
            }
        }

        // Grade states: a selected mixer band with point-colour swatches, every band at
        // once, and a loaded film stock.
        state.mixerBand = 2
        SnapshotFixtures.addPointColours(state)
        await recorder.settle(0.3)
        await recorder.render("panel-grade-colour-point-colour",
                              "Grade ▸ Colour with mixer band 3 selected and two point-colour swatches",
                              width: width) {
            SnapshotSectionCard(.color, isModified: recorder.isModified(.color)) {
                ColorPanel(only: .color)
            }
        }
        state.mixerAllBands = true
        await recorder.render("panel-grade-colour-all-bands",
                              "Grade ▸ Colour with All bands on",
                              width: width) {
            SnapshotSectionCard(.color, isModified: recorder.isModified(.color)) {
                ColorPanel(only: .color)
            }
        }
        state.mixerAllBands = false
        if SnapshotFixtures.loadFilmStock(state) {
            await recorder.render("panel-grade-film-lab-stock",
                                  "Grade ▸ Film Lab with the first stock in the catalogue loaded",
                                  width: width) {
                SnapshotSectionCard(.filmLab, isModified: recorder.isModified(.filmLab)) {
                    LookPanel(only: .filmLab)
                }
            }
        } else {
            recorder.record("panel-grade-film-lab-stock", "Grade ▸ Film Lab with a stock",
                            failure: "FilmStock.all is empty — there is no stock to load")
        }

        // Masks: empty, two, one of the two selected.
        await recorder.render("panel-masks-empty", "Masks editor, no masks", width: width) {
            SnapshotMaskEditor()
        }
        let ids = SnapshotFixtures.addTwoMasks(state)
        await recorder.settle(0.3)
        await recorder.render("panel-masks-two", "Masks editor, two masks, none selected",
                              width: width) {
            SnapshotMaskEditor()
        }
        state.activeMaskID = ids.radial
        state.activeComponentIndex = 0
        await recorder.settle(0.3)
        await recorder.render("panel-masks-selected",
                              "Masks editor, the radial mask \"Sun\" selected",
                              width: width) {
            SnapshotMaskEditor()
        }
        await recorder.render("panel-masks-selected-folds-open",
                              "Masks editor, \"Sun\" selected, Presence & Detail and "
                                  + "Point Colour folds opened",
                              width: width, press: ["Presence & Detail", "Point Colour"]) {
            SnapshotMaskEditor()
        }

        // Whole columns, as `DevelopPanel` draws them: once at the height the window
        // gives it, and once tall with every section of the workspace open.
        let columnHeight: CGFloat = 900
        let tallHeight: CGFloat = 2600
        PanelLayout.shared.setMasking(false)
        for workspace in [Workspace.develop, .crop, .grade, .deliver] {
            SnapshotFixtures.openEverySection(of: workspace)
            await recorder.render("column-\(workspace.rawValue)-all-open",
                                  "\(workspace.title) column, every section open, "
                                      + "\(Int(tallHeight)) pt tall",
                                  width: width, height: tallHeight, settle: 1.2) {
                DevelopPanel()
            }
        }
        PanelLayout.shared.reveal(.tone)
        await recorder.render("column-develop-tone-open",
                              "Develop column at window height, Tone open",
                              width: width, height: columnHeight, settle: 1.0) {
            DevelopPanel()
        }
        PanelLayout.shared.setMasking(true)
        await recorder.render("column-masking",
                              "The column while masking: return bar and mask editor",
                              width: width, height: columnHeight, settle: 1.0) {
            DevelopPanel()
        }
        PanelLayout.shared.setMasking(false)

        // The on-image overlays over a synthetic photograph.
        guard let sample = SnapshotFixtures.samplePhotograph(width: 1800, height: 1200) else {
            recorder.record("overlay-crop", "Crop overlay", failure: "could not draw the sample image")
            recorder.record("overlay-mask-radial", "Mask overlay", failure: "could not draw the sample image")
            return
        }
        let viewer = CGSize(width: 1000, height: 700)
        let crop = Crop(x: 0.06, y: 0.08, w: 0.86, h: 0.82)
        await recorder.render("overlay-crop",
                              "Crop overlay (CropOverlayView) over a sample frame",
                              width: viewer.width, height: viewer.height) {
            SnapshotCropOverlay(image: sample, crop: crop, photoID: photo.id,
                                container: viewer)
        }
        let overlay = SnapshotFixtures.radialMaskOverlay(over: sample)
        if overlay == nil {
            recorder.note("overlay-mask-radial", "MaskOverlayView.build returned nil — "
                          + "the frame is drawn without the wash")
        }
        await recorder.render("overlay-mask-radial",
                              "Mask overlay (colour overlay, red) of a radial mask over a sample frame",
                              width: viewer.width, height: viewer.height) {
            SnapshotMaskOverlay(image: sample, overlay: overlay, container: viewer)
        }

        // Appended for quality lane K3 (WS-32/33): Primaries open with its six matrix
        // rows moved, and the first Point Colour swatch with its Range refined.
        state.activeMaskID = nil
        state.updateRecipe(label: "Snapshot primaries and refined swatch") { recipe in
            recipe.look.primaries = Primaries(rHue: 30, rPurity: 40, gHue: -20,
                                              gPurity: -30, bHue: 25, bPurity: 50)
            if !recipe.develop.pointColors.isEmpty {
                recipe.develop.pointColors[0].hueRange = 80
                recipe.develop.pointColors[0].lumRange = 25
            }
        }
        await recorder.settle(0.3)
        await recorder.render("panel-grade-grading-primaries-open",
                              "Grade ▸ Grading with Primaries open and its six matrix rows moved",
                              width: width, press: ["Primaries"]) {
            SnapshotSectionCard(.grading, isModified: recorder.isModified(.grading)) {
                LookPanel(only: .grading)
            }
        }
        await recorder.render("panel-grade-colour-point-refined",
                              "Grade ▸ Colour, first swatch with Hue range 80 and Lum range 25",
                              width: width) {
            SnapshotSectionCard(.color, isModified: recorder.isModified(.color)) {
                ColorPanel(only: .color)
            }
        }
    }

    // MARK: - The whole window, against a scanned folder

    @MainActor
    private func renderWindow(_ recorder: SnapshotRecorder, root: URL) async {
        let state = AppState(catalogDirectory: { root.appendingPathComponent("window-catalog") },
                             previewDirectory: { root.appendingPathComponent("window-previews") })
        defer { state.prepareToQuit() }
        recorder.attach(state)
        state.developPanelWidth = Lumen.defaultPanelWidth

        let folder = root.appendingPathComponent("Shoot", isDirectory: true)
        do {
            try SnapshotFixtures.writeSampleRoll(to: folder)
        } catch {
            recorder.record("window-*", "Full window", failure: "could not write the sample "
                            + "roll: \(error.localizedDescription)")
            return
        }
        state.openFolder(folder)
        let scanned = await recorder.wait(timeout: 30) {
            !state.isScanning && !state.photos.isEmpty
        }
        guard scanned, let first = state.photos.first else {
            recorder.record("window-*", "Full window",
                            failure: "the sample folder did not scan within 30 s "
                                + "(\(state.photos.count) photos, status: "
                                + "\(state.statusMessage ?? state.catalogStatus ?? "none"))")
            return
        }
        state.select(first)
        SnapshotFixtures.applySampleEdit(state)

        let sizes = [CGSize(width: 1512, height: 982), CGSize(width: 1920, height: 1080)]
        let small = sizes[0]
        func label(_ size: CGSize) -> String { "\(Int(size.width))x\(Int(size.height))" }

        state.enter(.cull)
        await recorder.render("window-\(label(small))-cull-grid",
                              "Full window, Cull workspace (grid)",
                              width: small.width, height: small.height, settle: 2.5) {
            ContentView()
        }

        state.enter(.develop)
        PanelLayout.shared.reveal(.tone)
        for size in sizes {
            await recorder.render("window-\(label(size))-develop",
                                  "Full window, Develop workspace, loupe, Tone open",
                                  width: size.width, height: size.height, settle: 2.5,
                                  ready: { state.primaryFrameSize != nil },
                                  readyNote: "the loupe frame had not arrived — the "
                                      + "viewer may be empty") {
                ContentView()
            }
        }

        state.enter(.crop)
        await recorder.render("window-\(label(small))-crop",
                              "Full window, Crop workspace with the crop tool armed",
                              width: small.width, height: small.height, settle: 2.5,
                              ready: { state.primaryFrameSize != nil },
                              readyNote: "the loupe frame had not arrived") {
            ContentView()
        }

        state.enter(.grade)
        await recorder.render("window-\(label(small))-grade",
                              "Full window, Grade workspace",
                              width: small.width, height: small.height, settle: 2.5) {
            ContentView()
        }

        let ids = SnapshotFixtures.addTwoMasks(state)
        state.enterMasking()
        state.activeMaskID = ids.radial
        state.activeComponentIndex = 0
        state.beginPersistentMaskOverlay(ids.radial)
        await recorder.render("window-\(label(small))-masking-overlay",
                              "Full window, masking, radial mask selected with its overlay",
                              width: small.width, height: small.height, settle: 2.5,
                              ready: { state.maskOverlayAlpha != nil },
                              readyNote: "the mask overlay's alpha had not been "
                                  + "rasterized — the wash may be missing") {
            ContentView()
        }
        PanelLayout.shared.setMasking(false)
        state.enter(.develop)
    }
}

// MARK: - Recorder

/// Hosts, captures, writes, and remembers what happened, so `index.md` can say it.
@MainActor
private final class SnapshotRecorder {

    struct SnapshotEntry {
        let name: String
        let caption: String
        var file: String?
        var points: CGSize = .zero
        var pixels: (width: Int, height: Int)?
        var method: String = "—"
        var notes: [String] = []
    }

    static let scale: CGFloat = 2

    let directory: URL
    private(set) var entries: [SnapshotEntry] = []
    private var pendingNotes: [String: [String]] = [:]
    private var state: AppState?

    init(directory: URL) {
        self.directory = directory
    }

    /// `SNAPSHOT_DIR` if set (relative paths against the working directory), else
    /// `build/snapshots` at the package root when `LUMEN_UI_SNAPSHOTS=1`, else nil.
    nonisolated static func outputDirectory() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["SNAPSHOT_DIR"], !configured.isEmpty {
            let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath,
                           isDirectory: true)
            return URL(fileURLWithPath: configured, isDirectory: true, relativeTo: base)
                .standardizedFileURL
        }
        guard environment["LUMEN_UI_SNAPSHOTS"] == "1" else { return nil }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LumenAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("build/snapshots", isDirectory: true)
    }

    /// The state every hosted view is handed as its environment.
    func attach(_ state: AppState) {
        self.state = state
    }

    /// The modified dot a section's header would wear in the real column — the same
    /// call `DevelopPanel.sectionContent` makes.
    func isModified(_ section: WorkspaceSection) -> Bool {
        guard let state else { return false }
        var denoiseDefault: Denoise?
        var renderDefault: RenderParams?
        if let photo = state.primarySelection {
            renderDefault = AppState.startingRecipe(for: photo.id, iso: photo.iso).look.render
            if !PhotoFormats.isRendered(photo.id), let iso = photo.iso {
                denoiseDefault = ISODefaults.startingDenoise(forISO: Double(iso))
            }
        }
        return WorkspaceSection.nonDefault(in: state.currentRecipe,
                                           softProofEnabled: state.softProof.enabled,
                                           denoiseDefault: denoiseDefault,
                                           renderDefault: renderDefault)
            .contains(section)
    }

    // MARK: Waiting

    /// Lets the main run loop turn — SwiftUI updates, `.task`s, catalog hops — for a
    /// fixed time. `Task.sleep` rather than spinning `RunLoop` by hand, so the main
    /// actor is genuinely free while the test waits.
    func settle(_ seconds: TimeInterval) async {
        let steps = Swift.max(1, Int((seconds / 0.05).rounded()))
        for _ in 0..<steps {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Waits for `condition` or `timeout`, whichever is first; reports which.
    func wait(timeout: TimeInterval, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    // MARK: Recording

    func note(_ name: String, _ text: String) {
        pendingNotes[name, default: []].append(text)
    }

    func record(_ name: String, _ caption: String, failure: String) {
        var entry = SnapshotEntry(name: name, caption: caption)
        entry.method = "not rendered"
        entry.notes = (pendingNotes.removeValue(forKey: name) ?? []) + ["FAILED: \(failure)"]
        entries.append(entry)
    }

    // MARK: Rendering

    /// Host `content` at `width` (and `height`, or its own fitted height when nil) in
    /// an offscreen window, wait, capture at 2x, write `<name>.png`.
    ///
    /// `ready` is an optional condition worth waiting for (up to 15 s) before the fixed
    /// `settle` — a loupe frame, a mask raster. When it never comes the snapshot is
    /// still taken and `readyNote` says what is probably missing from it.
    ///
    /// `press` names fold headers to click open first, for the disclosures a panel
    /// keeps in private `@State` (Noise Reduction, Zones…) that no test can set. Each
    /// is found by its accessibility text and clicked with a synthesized mouse event;
    /// one that cannot be found is a note, and the snapshot shows the fold closed.
    func render<Content: View>(_ name: String, _ caption: String,
                               width: CGFloat, height: CGFloat? = nil,
                               settle: TimeInterval = 0.8,
                               ready: (() -> Bool)? = nil,
                               readyNote: String? = nil,
                               press: [String] = [],
                               @ViewBuilder _ content: () -> Content) async {
        var entry = SnapshotEntry(name: name, caption: caption)
        entry.notes = pendingNotes.removeValue(forKey: name) ?? []
        guard let state else {
            entry.method = "not rendered"
            entry.notes.append("FAILED: no AppState attached")
            entries.append(entry)
            return
        }

        let base = content()
            .environmentObject(state)
            .environmentObject(state.commands)
            .environmentObject(state.edits)
            .environment(\.colorScheme, .dark)
            // Animations need a display link, and an offscreen window may never get a
            // tick: a fold caught at frame zero would be a snapshot of a transition.
            .transaction { transaction in
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        let root: AnyView
        if let height {
            root = AnyView(base.frame(width: width, height: height))
        } else {
            root = AnyView(base
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true))
        }

        let controller = NSHostingController(rootView: root)
        let provisional = CGSize(width: width, height: height ?? 1600)
        let window = SnapshotWindow(contentRect: NSRect(origin: Self.windowOrigin,
                                                        size: provisional),
                                    styleMask: [.borderless],
                                    backing: .buffered,
                                    defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.colorSpace = NSColorSpace.sRGB
        window.backgroundColor = NSColor(white: 0.18, alpha: 1)
        window.hasShadow = false
        window.contentView = controller.view
        controller.view.frame = NSRect(origin: .zero, size: provisional)
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        if let ready {
            let arrived = await wait(timeout: 15, until: ready)
            if !arrived, let readyNote { entry.notes.append(readyNote) }
        }
        await self.settle(settle)

        if !press.isEmpty {
            window.makeKey()
            for label in press {
                if Self.click(label, in: controller.view, window: window) {
                    await self.settle(0.6)
                } else {
                    entry.notes.append("could not find \"\(label)\" to open it")
                }
            }
        }

        var size = provisional
        if height == nil {
            let fitted = controller.sizeThatFits(in: CGSize(width: width, height: 10_000))
            let fittedHeight = fitted.height.isFinite ? fitted.height.rounded(.up) : 0
            if fittedHeight < 8 {
                entry.notes.append("the fitted height came back \(fittedHeight) pt; "
                                   + "drawn at \(Int(provisional.height)) pt instead")
            } else {
                size = CGSize(width: width, height: Swift.min(fittedHeight, 4000))
                window.setContentSize(size)
                controller.view.frame = NSRect(origin: .zero, size: size)
                await self.settle(0.3)
            }
        }
        controller.view.layoutSubtreeIfNeeded()
        controller.view.display()
        // The hosting view's own size constraints can overrule the frame set above
        // (its default sizing options pin the window to the content's ideal size), so
        // the capture follows what the view actually is.
        let laidOut = controller.view.bounds.size
        if laidOut.width >= 1, laidOut.height >= 1,
           abs(laidOut.width - size.width) > 0.5 || abs(laidOut.height - size.height) > 0.5 {
            entry.notes.append("laid out at \(Int(laidOut.width))×\(Int(laidOut.height)) pt, "
                               + "not the \(Int(size.width))×\(Int(size.height)) asked for")
            size = laidOut
        }
        entry.points = size

        var image: NSBitmapImageRep?
        if let hosted = Self.hostedCapture(controller.view, size: size) {
            if Self.isUniform(hosted) {
                entry.notes.append("the hosted capture was one flat colour")
            } else {
                image = hosted
                entry.method = "NSHostingView.cacheDisplay"
            }
        } else {
            entry.notes.append("could not allocate the capture bitmap")
        }
        if image == nil {
            let renderer = ImageRenderer(content: root.frame(width: size.width,
                                                             height: size.height))
            renderer.scale = Self.scale
            if let cg = renderer.cgImage {
                image = NSBitmapImageRep(cgImage: cg)
                entry.method = "ImageRenderer (fallback: AppKit-backed views are placeholders)"
                if Self.isUniform(NSBitmapImageRep(cgImage: cg)) {
                    entry.notes.append("the ImageRenderer output is one flat colour too")
                }
            } else {
                entry.notes.append("ImageRenderer produced no image")
            }
        }

        guard let image,
              let data = image.representation(using: .png, properties: [:]) else {
            entry.method = "not rendered"
            entry.notes.append("FAILED: neither capture route produced a PNG")
            entries.append(entry)
            return
        }
        let file = "\(name).png"
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
            entry.file = file
            entry.pixels = (image.pixelsWide, image.pixelsHigh)
        } catch {
            entry.method = "not written"
            entry.notes.append("FAILED: \(error.localizedDescription)")
        }
        entries.append(entry)
    }

    /// On the main screen when there is one — a window off every screen is a window
    /// AppKit has less reason to draw — otherwise far away.
    private static var windowOrigin: CGPoint {
        NSScreen.main?.frame.origin ?? CGPoint(x: -20_000, y: -20_000)
    }

    /// Click the element whose accessibility text is `label` (exactly, or failing that
    /// as a prefix — a combined header can read "Zones, collapsed"). False when none.
    private static func click(_ label: String, in root: NSView, window: NSWindow) -> Bool {
        guard let frame = accessibilityFrame(of: label, in: root, exact: true)
                ?? accessibilityFrame(of: label, in: root, exact: false) else { return false }
        let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let strokes: [(type: NSEvent.EventType, pressure: Float)] = [(.leftMouseDown, 1),
                                                                     (.leftMouseUp, 0)]
        for stroke in strokes {
            guard let event = NSEvent.mouseEvent(with: stroke.type,
                                                 location: point,
                                                 modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber,
                                                 context: nil,
                                                 eventNumber: 0,
                                                 clickCount: 1,
                                                 pressure: stroke.pressure) else { return false }
            window.sendEvent(event)
        }
        return true
    }

    /// A breadth-first walk of the accessibility tree, read through key-value coding so
    /// it works on SwiftUI's private element classes, and guarded by `responds(to:)` so
    /// a node without a property is skipped rather than raising.
    private static func accessibilityFrame(of label: String, in root: NSView,
                                           exact: Bool) -> NSRect? {
        var queue: [NSObject] = [root]
        var index = 0
        while index < queue.count, index < 20_000 {
            let node = queue[index]
            index += 1
            for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                guard node.responds(to: NSSelectorFromString(key)),
                      let text = node.value(forKey: key) as? String else { continue }
                let matches = exact ? text == label : text.hasPrefix(label)
                guard matches,
                      node.responds(to: NSSelectorFromString("accessibilityFrame")),
                      let boxed = node.value(forKey: "accessibilityFrame") as? NSValue
                else { continue }
                let frame = boxed.rectValue
                guard frame.width > 0, frame.height > 0 else { continue }
                return frame
            }
            if node.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = node.value(forKey: "accessibilityChildren") as? [Any] {
                queue.append(contentsOf: children.compactMap { $0 as? NSObject })
            }
        }
        return nil
    }

    /// The hosted view drawn into a bitmap of `scale` pixels per point.
    private static func hostedCapture(_ view: NSView, size: CGSize) -> NSBitmapImageRep? {
        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelsWide,
                                         pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Whether a 48×48 sample of the image is all one colour — the signature of a
    /// capture route that drew nothing (transparent) or only a background.
    private static func isUniform(_ rep: NSBitmapImageRep) -> Bool {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        guard width > 1, height > 1,
              let first = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else {
            return true
        }
        let steps = 48
        for j in 0..<steps {
            for i in 0..<steps {
                let x = (width - 1) * i / (steps - 1)
                let y = (height - 1) * j / (steps - 1)
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let distance = abs(colour.redComponent - first.redComponent)
                    + abs(colour.greenComponent - first.greenComponent)
                    + abs(colour.blueComponent - first.blueComponent)
                    + abs(colour.alphaComponent - first.alphaComponent)
                if distance > 0.02 { return false }
            }
        }
        return true
    }

    // MARK: Index

    /// `index.md`: one row per snapshot, failures included, so a reader on Linux knows
    /// what exists, what it shows, and what could not be drawn.
    func writeIndex() {
        let environment = ProcessInfo.processInfo.environment
        let branch = environment["SNAPSHOT_BRANCH"] ?? environment["GITHUB_REF_NAME"] ?? "local"
        let commit = environment["GITHUB_SHA"] ?? "local"
        let screen = NSScreen.main
        var lines: [String] = []
        lines.append("# Lumen UI snapshots")
        lines.append("")
        lines.append("Rendered by `Tests/LumenAppTests/PanelSnapshotTests.swift` on a "
                     + "headless macOS runner: real views, real fonts, dark appearance, "
                     + "\(Int(Self.scale))x. Panels use a synthetic RAW frame with a sample "
                     + "edit; the full window opens a folder of synthetic PNGs.")
        lines.append("")
        lines.append("- branch: `\(branch)`")
        lines.append("- commit: `\(commit)`")
        lines.append("- rendered: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let screen {
            lines.append("- main screen: \(Int(screen.frame.width))x\(Int(screen.frame.height)) "
                         + "pt at \(screen.backingScaleFactor)x")
        } else {
            lines.append("- main screen: none")
        }
        let written = entries.filter { $0.file != nil }.count
        lines.append("- \(written) of \(entries.count) snapshots written")
        lines.append("")
        lines.append("| file | shows | points | pixels | captured with | notes |")
        lines.append("|---|---|---|---|---|---|")
        for entry in entries {
            let file = entry.file.map { "[\($0)](\($0))" } ?? "`\(entry.name)` (none)"
            let points = entry.points == .zero ? "—"
                : "\(Int(entry.points.width))×\(Int(entry.points.height))"
            let pixels = entry.pixels.map { "\($0.width)×\($0.height)" } ?? "—"
            let notes = entry.notes.isEmpty ? "" : entry.notes.joined(separator: "; ")
            lines.append("| \(file) | \(Self.cell(entry.caption)) | \(points) | \(pixels) | "
                         + "\(Self.cell(entry.method)) | \(Self.cell(notes)) |")
        }
        lines.append("")
        let text = lines.joined(separator: "\n")
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            try text.write(to: directory.appendingPathComponent("index.md"),
                           atomically: true, encoding: .utf8)
        } catch {
            print("UI snapshots: could not write index.md: \(error.localizedDescription)")
        }
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// Reports a Retina backing scale whatever screen it is (or is not) on, so SwiftUI
/// rasterizes at 2x rather than drawing 1x layers into the 2x bitmap.
private final class SnapshotWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
    /// Borderless windows refuse key status by default, and a fold header clicked in a
    /// window that is not key may spend the click on activation instead.
    override var canBecomeKey: Bool { true }
}

// MARK: - User defaults the run touches

/// Opening a folder, moving the accordion and folding History all write the owner's
/// defaults. A snapshot run on a developer's Mac must leave them as it found them.
private enum SnapshotDefaults {
    static let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files",
                       "develop.workspace", "develop.expanded", "develop.masking",
                       "develop.history", "develop.panelWidth"]

    static func capture() -> [(key: String, value: Any?)] {
        keys.map { (key: $0, value: UserDefaults.standard.object(forKey: $0)) }
    }

    static func restore(_ remembered: [(key: String, value: Any?)]) {
        for (key, value) in remembered {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

// MARK: - Fixtures

@MainActor
private enum SnapshotFixtures {

    /// A representative edit: enough on every panel that modified dots, readouts and
    /// reset affordances are in their working state.
    static func applySampleEdit(_ state: AppState) {
        state.updateRecipe(label: "Snapshot sample edit") { recipe in
            recipe.develop.tone.exposure = 0.35
            recipe.develop.tone.contrast = 12
            recipe.develop.tone.highlights = -38
            recipe.develop.tone.shadows = 24
            recipe.develop.tone.whites = 6
            recipe.develop.tone.blacks = -8
            recipe.develop.color.vibrance = 18
            recipe.develop.color.saturation = -4
            recipe.develop.detail.texture = 6
            recipe.develop.detail.clarity = 10
            recipe.develop.detail.dehaze = 4
            if recipe.develop.mixer.bands.count > 2 {
                recipe.develop.mixer.bands[2].hue = 12
                recipe.develop.mixer.bands[2].sat = -18
            }
            recipe.look.wheels.shadows.hue = 210
            recipe.look.wheels.shadows.sat = 0.25
            recipe.look.wheels.high.hue = 40
            recipe.look.wheels.high.sat = 0.2
            recipe.look.vignette = -0.6
            recipe.look.grain = CreativeGrain(amount: 30, size: 40, roughness: 55)
        }
    }

    static func addPointColours(_ state: AppState) {
        state.updateRecipe(label: "Snapshot point colours") { recipe in
            recipe.develop.pointColors = [
                PointColor(sample: [0.82, 0.55, 0.40], range: 45, variance: 0,
                           shift: HSLShift(h: -6, s: -12, l: 4)),
                PointColor(sample: [0.30, 0.48, 0.70], range: 60, variance: 10,
                           shift: HSLShift(h: 8, s: 15, l: -5)),
            ]
        }
    }

    /// Picks the first stock the way the Stock menu does. False when there is none.
    static func loadFilmStock(_ state: AppState) -> Bool {
        guard let stock = FilmStock.all.first else { return false }
        state.updateRecipe(label: "Snapshot film stock") { recipe in
            recipe.look.filmLab = FilmChain.defaultRecipe(for: stock)
        }
        return true
    }

    /// A linear "Sky" and a radial "Sun", with an adjustment on each.
    static func addTwoMasks(_ state: AppState) -> (linear: String, radial: String) {
        var gradient = MaskComponent(op: .add, kind: .linear)
        gradient.line = [0.5, 0.0, 0.5, 0.55]
        var sky = Mask(id: "snapshot-sky", name: "Sky", components: [gradient])
        sky.adjust.exposure = -0.4

        var disc = MaskComponent(op: .add, kind: .radial)
        disc.center = [0.68, 0.30]
        disc.radii = [0.20, 0.24]
        disc.feather = 60
        var sun = Mask(id: "snapshot-sun", name: "Sun", components: [disc])
        sun.adjust.exposure = 0.3

        state.updateRecipe(label: "Snapshot masks") { recipe in
            recipe.masks = [sky, sun]
        }
        return (sky.id, sun.id)
    }

    /// Select `workspace` and open every one of its sections.
    static func openEverySection(of workspace: Workspace) {
        let panel = PanelLayout.shared
        panel.select(workspace)
        for section in workspace.sections where !panel.layout.expanded.contains(section) {
            panel.click(section, keepingOthersOpen: true)
        }
    }

    /// A landscape-ish frame with real tonal range and colour: sky gradient, a sun, two
    /// ridges, and a strip of saturated patches so the mixer and the overlay have
    /// something to bite on.
    static func samplePhotograph(width: Int, height: Int, shift: CGFloat = 0) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let w = CGFloat(width)
        let h = CGFloat(height)
        // CoreGraphics' origin is bottom-left: the sky is the top of the frame.
        let skyColours = [CGColor(red: 0.16, green: 0.30, blue: 0.58, alpha: 1),
                          CGColor(red: 0.62 + shift, green: 0.70, blue: 0.82, alpha: 1),
                          CGColor(red: 0.96, green: 0.78, blue: 0.56, alpha: 1)] as CFArray
        if let sky = CGGradient(colorsSpace: space, colors: skyColours,
                                locations: [0, 0.6, 1]) {
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h),
                                       end: CGPoint(x: 0, y: h * 0.35), options: [])
        }
        context.setFillColor(CGColor(red: 1.0, green: 0.93, blue: 0.75, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.62, width: w * 0.11,
                                       height: w * 0.11))
        func ridge(_ points: [(CGFloat, CGFloat)], _ colour: CGColor) {
            context.setFillColor(colour)
            context.move(to: CGPoint(x: 0, y: 0))
            for (x, y) in points { context.addLine(to: CGPoint(x: w * x, y: h * y)) }
            context.addLine(to: CGPoint(x: w, y: 0))
            context.closePath()
            context.fillPath()
        }
        ridge([(0, 0.48), (0.18, 0.58), (0.36, 0.50), (0.55, 0.62), (0.78, 0.47), (1, 0.55)],
              CGColor(red: 0.30, green: 0.36, blue: 0.42, alpha: 1))
        ridge([(0, 0.30), (0.25, 0.40), (0.50, 0.33), (0.72, 0.42), (1, 0.31)],
              CGColor(red: 0.14 + shift, green: 0.24, blue: 0.12, alpha: 1))
        let patches: [CGColor] = [
            CGColor(red: 0.85, green: 0.15, blue: 0.12, alpha: 1),
            CGColor(red: 0.95, green: 0.55, blue: 0.10, alpha: 1),
            CGColor(red: 0.95, green: 0.88, blue: 0.20, alpha: 1),
            CGColor(red: 0.20, green: 0.70, blue: 0.25, alpha: 1),
            CGColor(red: 0.10, green: 0.65, blue: 0.75, alpha: 1),
            CGColor(red: 0.15, green: 0.30, blue: 0.85, alpha: 1),
            CGColor(red: 0.55, green: 0.20, blue: 0.75, alpha: 1),
            CGColor(red: 0.90, green: 0.35, blue: 0.60, alpha: 1),
        ]
        let patch = w / CGFloat(patches.count + 4)
        for (index, colour) in patches.enumerated() {
            context.setFillColor(colour)
            context.fill(CGRect(x: patch * (CGFloat(index) + 2), y: h * 0.06,
                                width: patch * 0.9, height: patch * 0.9))
        }
        return context.makeImage()
    }

    /// Three frames as PNG files, slightly different so the filmstrip reads as a roll.
    static func writeSampleRoll(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<3 {
            guard let image = samplePhotograph(width: 1800, height: 1200,
                                               shift: CGFloat(index) * 0.08) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard let data = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = folder.appendingPathComponent(String(format: "LUM_%04d.png", 101 + index))
            try data.write(to: url, options: .atomic)
        }
    }

    /// The overlay `MaskOverlayView` would draw for the "Sun" radial, built directly
    /// with its own static compositor so no `.task` has to finish first.
    static func radialMaskOverlay(over image: CGImage) -> CGImage? {
        var disc = MaskComponent(op: .add, kind: .radial)
        disc.center = [0.68, 0.30]
        disc.radii = [0.20, 0.24]
        disc.feather = 60
        let longEdge = 1024
        let aspect = Double(image.height) / Double(Swift.max(image.width, 1))
        let alpha = MaskRaster.rasterize(component: disc,
                                         size: (width: longEdge,
                                                height: Swift.max(1, Int(Double(longEdge) * aspect))))
        let sampler = PixelSampler.make(from: image)
        return MaskOverlayView.build(alpha: alpha, sampler: sampler, geometry: Geometry(),
                                     sourceSize: CGSize(width: image.width, height: image.height),
                                     mode: .colorOverlay, tint: .red,
                                     strength: MaskOverlay.defaultStrength)
    }
}

// MARK: - Hosted compositions

/// One accordion card, drawn as `WorkspaceSectionView` (DevelopColumn.swift) draws it,
/// inside the scroll column's 4-point gutter on the column's own background. That view
/// is private to its file, so this restates its modifiers in the same order.
private struct SnapshotSectionCard<Content: View>: View {
    let section: WorkspaceSection
    let isModified: Bool
    let content: Content

    init(_ section: WorkspaceSection, isModified: Bool,
         @ViewBuilder content: () -> Content) {
        self.section = section
        self.isModified = isModified
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LumenSectionHeader(title: section.title,
                               symbol: section.symbolName,
                               isExpanded: .constant(true),
                               isModified: isModified,
                               topRhythm: 0,
                               onToggle: { _ in })
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .lumenSurface(radius: Lumen.radiusCard, elevation: .flush, fill: Lumen.panel)
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(Lumen.windowBase)
        .foregroundStyle(Lumen.primaryText)
    }
}

/// `WorkspaceSectionBody`'s switch, restated for the same reason: it is private.
private struct SnapshotSectionBody: View {
    let section: WorkspaceSection
    @EnvironmentObject var state: AppState

    var body: some View {
        switch section {
        case .whiteBalance: BasicPanel(only: .whiteBalance)
        case .tone: BasicPanel(only: .tone)
        case .presence: BasicPanel(only: .presence)
        case .curve: CurveEditorView(histogram: state.scopes?.histogram)
        case .detail: DetailPanel(only: .detail)
        case .frame: EffectsPanel(only: .frame)
        case .optics: EffectsPanel(only: .optics)
        case .looks: LookPanel(only: .looks)
        case .color: ColorPanel(only: .color)
        case .grading: LookPanel(only: .grading)
        case .filmLab: LookPanel(only: .filmLab)
        case .effects: EffectsPanel(only: .effects)
        case .softProof: EffectsPanel(only: .softProof)
        case .exportRecipes: Text("Export recipes are edited in the export sheet.")
        }
    }
}

/// The mask editor card as the masking column hosts it.
private struct SnapshotMaskEditor: View {
    var body: some View {
        MaskEditor(panel: PanelLayout.shared)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .background(Lumen.windowBase)
            .foregroundStyle(Lumen.primaryText)
    }
}

/// The crop tool's picture: the frame, fitted, with `CropOverlayView` on top at the
/// frame's drawn size — `LoupeView`'s crop canvas without the zoom and rotation.
private struct SnapshotCropOverlay: View {
    let image: CGImage
    let crop: Crop
    let photoID: URL
    let container: CGSize

    var body: some View {
        let inset: CGFloat = 40
        let k = Swift.min((container.width - inset * 2) / CGFloat(image.width),
                          (container.height - inset * 2) / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * k, height: CGFloat(image.height) * k)
        ZStack {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.high)
                .frame(width: drawn.width, height: drawn.height)
            CropOverlayView(crop: .constant(crop),
                            geometry: Geometry(crop: crop),
                            sourceSize: CGSize(width: image.width, height: image.height),
                            viewShowsCrop: false,
                            photoID: photoID,
                            onAngle: { _ in },
                            frameAspect: Double(image.width) / Double(image.height))
                .frame(width: drawn.width, height: drawn.height)
        }
        .frame(width: container.width, height: container.height)
        .background(Color(nsColor: NSColor(white: 0.165, alpha: 1)))
    }
}

/// The frame with a prebuilt mask overlay composited on top, the way the loupe stacks
/// `MaskOverlayView` over its plate.
private struct SnapshotMaskOverlay: View {
    let image: CGImage
    let overlay: CGImage?
    let container: CGSize

    var body: some View {
        let inset: CGFloat = 40
        let k = Swift.min((container.width - inset * 2) / CGFloat(image.width),
                          (container.height - inset * 2) / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * k, height: CGFloat(image.height) * k)
        ZStack {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.high)
                .frame(width: drawn.width, height: drawn.height)
            if let overlay {
                Image(decorative: overlay, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: drawn.width, height: drawn.height)
            }
        }
        .frame(width: container.width, height: container.height)
        .background(Color(nsColor: NSColor(white: 0.165, alpha: 1)))
    }
}

#endif

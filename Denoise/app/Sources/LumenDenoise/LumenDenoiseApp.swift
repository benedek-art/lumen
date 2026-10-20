import SwiftUI
import AppKit
import UniformTypeIdentifiers

// App shell: scenes, menu commands, the main window (queue sidebar + preview + bottom bar) and Settings.
// All state lives in QueueModel (Model.swift); the preview is BeforeAfterView (Preview.swift).

// MARK: - App

@main
struct LumenDenoiseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var ui = AppUI()

    init() {
        if CommandLine.arguments.contains("--selftest") { exit(runSelfTest() ? 0 : 1) }
    }

    var body: some Scene {
        WindowGroup("Lumen Denoise") {
            ContentView()
                .environmentObject(appDelegate.model)
                .environmentObject(ui)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear { appDelegate.model.autotestIfRequested(); snapshotIfRequested() }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { LumenCommands(m: appDelegate.model, ui: ui) }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.model)
        }
    }
}

/// Owns the model so termination hooks can reach it. The model is created lazily so `--selftest` has no side effects.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var model = QueueModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let env = ProcessInfo.processInfo.environment
        guard model.running, env["LUMEN_AUTOTEST_FILES"] == nil, env["LUMEN_SNAPSHOT"] == nil else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Cancel the batch and quit?"
        a.informativeText = "\(model.counts.remaining) photos are not finished yet. Finished DNGs are kept; the photo in progress "
            + "is discarded and the rest stay queued for next launch."
        a.alertStyle = .warning
        a.addButton(withTitle: "Cancel Batch and Quit")
        a.addButton(withTitle: "Keep Running")
        return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) { model.appWillTerminate() }
}

/// Window-only UI state that menu commands also drive (kept out of QueueModel on purpose).
@MainActor
final class AppUI: ObservableObject {
    @Published var showLog = false
}

/// Asks the visible BeforeAfterView to zoom. Preview.swift observes `PreviewZoom.notification`; object is "fit" or "actual".
@MainActor
func postZoom(_ actual: Bool) {
    NotificationCenter.default.post(name: PreviewZoom.notification, object: actual ? "actual" : "fit")
}

// MARK: - Commands

struct LumenCommands: Commands {
    @ObservedObject var m: QueueModel
    @ObservedObject var ui: AppUI

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Files…") { m.addViaPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Choose Output Folder…") { m.chooseOut() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(m.running)
            Divider()
            Button("Reveal in Finder") { m.reveal(m.selectedItem?.id) }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
        CommandGroup(after: .toolbar) {
            Button("Actual Size (100%)") { postZoom(true) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(m.selectedItem == nil)
            Button("Zoom to Fit") { postZoom(false) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(m.selectedItem == nil)
            Divider()
        }
        CommandMenu("Denoise") {
            Button("Start Denoising") { m.start() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(m.running || !hasRunnable(m.items))
            Button("Cancel") { m.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!m.running || m.cancelling)
            Button("Retry Failed") { m.retryFailed() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!m.items.contains { $0.state == .failed || $0.state == .cancelled })
            Button("Re-process Selected") { m.reprocess(m.selection) }
                .disabled(m.selection.isEmpty)
            Divider()
            // No ⌘⌫ key equivalent: menu shortcuts beat the field editor, so it would remove photos while editing a
            // text field. ⌫ in the queue list goes through QueueList's onDeleteCommand instead.
            Button("Remove Selected (⌫)") { m.remove(m.selection) }
                .disabled(m.selection.isEmpty)
            Button("Clear Finished") { m.clearFinished() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!m.items.contains { $0.state == .done || $0.state == .skipped })
            Button("Clear All") { m.clearAll() }
                .disabled(m.running || m.items.isEmpty)
            Divider()
            Button("Show Log") { ui.showLog = true }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}

/// Something Start would actually run (Start also re-queues failed and cancelled items).
private func hasRunnable(_ items: [QueueItem]) -> Bool {
    items.contains { $0.state == .queued || $0.state == .failed || $0.state == .cancelled }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var m: QueueModel
    @EnvironmentObject var ui: AppUI
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                QueueList()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 520)
            } detail: {
                if let item = m.selectedItem {
                    BeforeAfterView(item: item)
                } else {
                    EmptyDropZone(targeted: targeted, hasItems: !m.items.isEmpty)
                }
            }
            Divider()
            BottomBar()
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { handleDrop($0) }
        .overlay {
            if targeted && m.selectedItem != nil {   // the empty state highlights itself; elsewhere outline the window
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3).allowsHitTesting(false)
            }
        }
        .alert(m.alert?.title ?? "", isPresented: Binding(get: { m.alert != nil }, set: { if !$0 { m.alert = nil } }),
               presenting: m.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { a in
            Text(a.message)
        }
        .sheet(isPresented: $ui.showLog) { LogSheet() }
    }

    /// Collects every dropped file URL (in drop order), then hands them to the model in one call on the main queue.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let box = DropBox(count: providers.count)
        let group = DispatchGroup()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { box.set(i, url) }
                group.leave()
            }
        }
        let model = m
        group.notify(queue: .main) {
            let urls = box.urls
            MainActor.assumeIsolated { if !urls.isEmpty { model.add(urls) } }
        }
        return !providers.isEmpty
    }
}

/// Thread-safe slots for drop callbacks, which arrive on arbitrary queues.
private final class DropBox: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [URL?]
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ url: URL) { lock.lock(); slots[i] = url; lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return slots.compactMap { $0 } }
}

// MARK: Empty state

struct EmptyDropZone: View {
    let targeted: Bool
    let hasItems: Bool
    @EnvironmentObject var m: QueueModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(hasItems ? "Select a photo to compare before and after" : "Drop ARW, RW2 or DNG files or folders")
                .font(.title3)
            Text(hasItems ? "Drop more files here to add them to the queue."
                          : "Denoised DNGs are written to the output folder below. Photos already done are skipped.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !FileManager.default.isExecutableFile(atPath: Cfg.python) {
                HStack(spacing: 8) {
                    Label("Engine not found at \(Cfg.projectRoot)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).lineLimit(2).truncationMode(.middle)
                    SettingsLink { Text("Open Settings…") }
                }
                .font(.callout)
                .padding(.top, 4)
            }
            Button("Add Files…") { m.addViaPanel() }.padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [7])))
        .padding(20)
    }
}

// MARK: Queue list

struct QueueList: View {
    @EnvironmentObject var m: QueueModel

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $m.selection) {
                ForEach(m.items) { item in
                    QueueRow(item: item, strength: m.strengthFor(item), selected: m.selection.contains(item.id))
                        .tag(item.id)
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: UUID.self) { ids in
                rowMenu(ids)
            } primaryAction: { ids in
                primaryAction(ids)
            }
            .onDeleteCommand { m.remove(m.selection) }
            // Preview keys (hold Space = Before, Z = 100%, \ = split) also work while the list has focus.
            .onKeyPress(keys: [.space, "z", "Z", "\\"], phases: [.down, .repeat, .up]) { press in
                forwardPreviewKey(press)
            }
            // Follow the photo in progress, but only while the user isn't browsing a selection.
            .onChange(of: m.items.first(where: { $0.state == .working })?.id) { _, id in
                if let id, m.selection.isEmpty { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .overlay {
            if m.items.isEmpty {
                ContentUnavailableView("No Photos", systemImage: "photo.stack",
                                       description: Text("Drop files or folders here, or press ⌘O."))
            }
        }
    }

    /// Posts PreviewZoom.keyNotification for the visible BeforeAfterView. Auto-repeat is swallowed (no beeps).
    private func forwardPreviewKey(_ press: KeyPress) -> KeyPress.Result {
        guard m.selectedItem != nil, !press.modifiers.contains(.command) else { return .ignored }
        var action: String?
        if press.key == .space {
            if press.phase == .down { action = "holdOn" } else if press.phase == .up { action = "holdOff" }
        } else if press.phase == .down {
            action = press.key == "\\" ? "toggleSplit" : "toggleZoom"
        }
        if let action { NotificationCenter.default.post(name: PreviewZoom.keyNotification, object: action) }
        return .handled
    }

    /// Double-click / Return: open the denoised DNG when there is one, otherwise show the original in Finder.
    private func primaryAction(_ ids: Set<UUID>) {
        for id in ids {
            if let it = m.items.first(where: { $0.id == id }), FileManager.default.fileExists(atPath: it.output) {
                m.openOutput(id)
            } else {
                m.reveal(id)
            }
        }
    }

    @ViewBuilder private func rowMenu(_ ids: Set<UUID>) -> some View {
        let picked = m.items.filter { ids.contains($0.id) }
        let first = picked.first
        Button("Reveal in Finder") { m.reveal(first?.id) }
        Button("Open Denoised DNG") { if let first { m.openOutput(first.id) } }
            .disabled(!(first.map { $0.state == .done || $0.state == .skipped } ?? false))
        Button(picked.count > 1 ? "Re-process \(picked.count) Photos" : "Re-process") { m.reprocess(ids) }
            .disabled(picked.isEmpty || picked.allSatisfy { $0.state == .working })
        if let e = first?.error, let first {
            Button("Copy Error") { m.copyError(first.id) }.help(e.title)
        }
        Divider()
        Button(picked.count > 1 ? "Remove \(picked.count) Photos" : "Remove") { m.remove(ids) }
            .disabled(picked.isEmpty || picked.allSatisfy { $0.state == .working })
    }
}

struct QueueRow: View {
    let item: QueueItem
    let strength: Double
    var selected = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusIcon(state: item.state).frame(width: 16, height: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text((item.source as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                if item.state == .failed, let e = item.error {
                    // Red on the accent-coloured selection highlight reads badly; fall back to primary there.
                    Text(e.title).font(.caption.weight(.semibold)).foregroundStyle(selected ? Color.primary : Color.red)
                        .lineLimit(2)
                    if !e.detail.isEmpty {
                        Text(e.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        // The raw traceback stays available through Copy Error and the log; a tooltip only gets the readable part.
        .help(item.error.map { "\($0.title): \($0.detail)\n\(item.source)" } ?? item.source)
    }

    private var caption: String {
        var parts: [String] = []
        switch item.state {
        case .queued: parts.append("Queued")
        case .working: parts.append("Denoising…")
        case .done: parts.append(item.seconds.map { String(format: "Done in %.1f s", $0) } ?? "Done")
        case .skipped: parts.append("Already done")
        case .failed: parts.append("Failed")
        case .cancelled: parts.append("Cancelled")
        }
        if (item.state == .done || item.state == .skipped), let f = item.finishedAt, !Calendar.current.isDateInToday(f) {
            parts.append(f.formatted(date: .abbreviated, time: .omitted))   // result from an earlier session
        }
        if let iso = item.iso { parts.append("ISO \(iso)") }
        // Finished outputs show the strength they were made with; a skipped file's strength is unknown unless recorded.
        let s: Double? = switch item.state {
        case .done: item.usedStrength ?? strength
        case .skipped: item.usedStrength
        default: strength
        }
        if let s { parts.append("\(Int((s * 100).rounded()))%" + (item.strengthOverride != nil ? " (custom)" : "")) }
        if let cam = item.camera, !cam.isEmpty { parts.append(cam) }
        return parts.joined(separator: " · ")
    }
}

struct StatusIcon: View {
    let state: ItemState

    var body: some View {
        switch state {
        case .queued: symbol("clock", .secondary, "Queued")
        case .working: ProgressView().controlSize(.small).help("Denoising").accessibilityLabel("Denoising")
        case .done: symbol("checkmark.circle.fill", .green, "Done")
        case .skipped: symbol("arrow.uturn.forward", .secondary, "Skipped", help: "Skipped: output already exists")
        case .failed: symbol("exclamationmark.octagon.fill", .red, "Failed")
        case .cancelled: symbol("minus.circle.fill", .orange, "Cancelled")
        }
    }

    private func symbol(_ name: String, _ color: some ShapeStyle, _ label: String, help: String? = nil) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .help(help ?? label)
            .accessibilityLabel(label)
    }
}

// MARK: Bottom bar

struct BottomBar: View {
    @EnvironmentObject var m: QueueModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: m.progressFraction).progressViewStyle(.linear)
                .opacity(m.items.isEmpty ? 0.4 : 1)
            Text(m.statusLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1).truncationMode(.tail)
            HStack(spacing: 12) {
                strengthControls
                Divider().frame(height: 18)
                outputControls
                Spacer(minLength: 8)
                runButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// With Auto by ISO on, the bands decide (the fallback lives in Settings), so show them instead of a slider
    /// that would barely matter; with it off, a plain strength slider.
    private var strengthControls: some View {
        HStack(spacing: 8) {
            if m.strength.autoByISO {
                SettingsLink {
                    Text(bandSummary).monospacedDigit().lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: 340, alignment: .leading)
                }
                .help("Strength follows the photo's ISO: \(bandSummary). Edit ISO bands (⌘,)")
                .accessibilityLabel("ISO strength bands: \(bandSummary). Open Settings to edit")
            } else {
                Text("Strength").help("Denoise strength for every photo without a per-photo override.")
                Slider(value: $m.strength.global, in: 0...1, step: 0.05).frame(width: 130)
                    .accessibilityLabel("Strength")
                Text("\(Int((m.strength.global * 100).rounded()))%").monospacedDigit().frame(width: 38, alignment: .trailing)
            }
            Toggle("Auto by ISO", isOn: $m.strength.autoByISO).toggleStyle(.checkbox)
                .help("Pick the strength from the photo's ISO (bands are editable in Settings).")
            if !m.strength.autoByISO {
                SettingsLink { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless).help("ISO bands and other settings (⌘,)")
                    .accessibilityLabel("Settings")
            }
        }
        .disabled(m.running)
    }

    /// "ISO ≤800 55% · ≤3200 75% · ≤12800 90% · above 100%"
    private var bandSummary: String {
        "ISO " + m.strength.bands.sorted { $0.maxISO < $1.maxISO }.map {
            ($0.maxISO == Int.max ? "above" : "≤\($0.maxISO)") + " \(Int(($0.strength * 100).rounded()))%"
        }.joined(separator: " · ")
    }

    private var outputControls: some View {
        HStack(spacing: 6) {
            Button { m.chooseOut() } label: {
                Label((m.outDir as NSString).lastPathComponent, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading)
            }
            .disabled(m.running)
            .help("Output folder: \(m.outDir) (⇧⌘O to change)")
            Button { m.reveal(nil) } label: { Image(systemName: "arrow.forward.circle") }
                .buttonStyle(.borderless).help("Show the output folder in Finder")
                .accessibilityLabel("Show output folder in Finder")
        }
    }

    @ViewBuilder private var runButton: some View {
        if m.running {
            Button(role: .cancel) { m.cancel() } label: {
                Label(m.cancelling ? "Cancelling…" : "Cancel", systemImage: "stop.fill")
            }
            .disabled(m.cancelling)
            .help("Stop the batch (⌘.). Finished photos are kept, nothing partial is left behind.")
        } else {
            let n = m.items.filter { $0.state == .queued || $0.state == .failed || $0.state == .cancelled }.count
            Button { m.start() } label: {
                Label(n > 0 ? "Denoise \(n)" : "Denoise", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .disabled(n == 0)
            .help("Start denoising (⌘R)")
        }
    }
}

// MARK: - Log

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(lines.isEmpty ? "No engine output yet." : lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(lines.isEmpty ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: lines.count) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct LogSheet: View {
    @EnvironmentObject var m: QueueModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Engine Log").font(.headline)
                Spacer()
                Button("Copy All") { copyToPasteboard(m.log.joined(separator: "\n")) }.disabled(m.log.isEmpty)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            LogView(lines: m.log)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 380, idealHeight: 480)
    }
}

private func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var m: QueueModel
    @AppStorage("engineRoot") private var engineRoot = ""

    var body: some View {
        Form {
            Section {
                Toggle("Choose strength automatically from ISO", isOn: $m.strength.autoByISO)
                // Bindings by id, not `ForEach($bands)`: removing a band while its field or slider binding is live
                // would otherwise index out of range.
                ForEach(m.strength.bands) { band in
                    BandRow(band: bandBinding(band), isCatchAll: band.maxISO == Int.max,
                            onCommit: sortBands, onDelete: { remove(band.id) })
                }
                .disabled(!m.strength.autoByISO)
                HStack(spacing: 10) {
                    Text("Photos without ISO").frame(width: 150, alignment: .leading)
                    Slider(value: $m.strength.global, in: 0...1, step: 0.05).accessibilityLabel("Photos without ISO")
                    Text("\(Int((m.strength.global * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    Color.clear.frame(width: 16, height: 1)   // lines up with the band rows' remove buttons
                }
                .disabled(!m.strength.autoByISO)
                HStack {
                    Button("Add Band") { addBand() }.disabled(!m.strength.autoByISO)
                    Spacer()
                    Button("Restore Defaults") { m.strength = .default }
                }
            } header: {
                Text("Strength by ISO")
            } footer: {
                Text("Each photo uses the first band whose limit is at or above its ISO. Photos without an ISO use the "
                     + "\u{201C}Photos without ISO\u{201D} strength. A per-photo override in the preview always wins.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Batch") {
                Toggle("Skip photos that already have an up-to-date denoised DNG", isOn: $m.skipDone)
                Toggle("Notify me when a batch finishes in the background", isOn: $m.notifyWhenDone)
            }

            Section {
                LabeledContent("Engine folder") {
                    Text(Cfg.projectRoot).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Python") {
                    let ok = FileManager.default.isExecutableFile(atPath: Cfg.python)
                    Label(ok ? Cfg.python : "Not found: \(Cfg.python)",
                          systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ok ? Color.green : Color.orange)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("Choose Engine Folder…") { chooseEngineRoot() }
                    Button("Use Default") { engineRoot = "" }.disabled(engineRoot.isEmpty)
                }
            } header: {
                Text("Engine")
            } footer: {
                Text(ProcessInfo.processInfo.environment["LUMEN_DENOISE_ROOT"] != nil
                     ? "LUMEN_DENOISE_ROOT is set in the environment and overrides this setting."
                     : "The lumen-denoise project folder containing .venv and the model weights.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LogView(lines: m.log).frame(height: 180)
                Button("Copy Log") { copyToPasteboard(m.log.joined(separator: "\n")) }.disabled(m.log.isEmpty)
            } header: {
                Text("Engine Log")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520)
    }

    private func bandBinding(_ band: ISOBand) -> Binding<ISOBand> {
        Binding(get: { m.strength.bands.first { $0.id == band.id } ?? band },
                set: { nb in if let i = m.strength.bands.firstIndex(where: { $0.id == band.id }) { m.strength.bands[i] = nb } })
    }

    private func sortBands() { m.strength.bands.sort { $0.maxISO < $1.maxISO } }

    private func remove(_ id: UUID) {
        m.strength.bands.removeAll { $0.id == id && $0.maxISO != Int.max }
    }

    private func addBand() {
        let finite = m.strength.bands.map(\.maxISO).filter { $0 != Int.max }
        let iso = min((finite.max() ?? 400) * 2, 409_600)
        m.strength.bands.append(ISOBand(maxISO: iso, strength: 0.8))
        if !m.strength.bands.contains(where: { $0.maxISO == Int.max }) {
            m.strength.bands.append(ISOBand(maxISO: Int.max, strength: 1.0))
        }
        sortBands()
    }

    private func chooseEngineRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Use Folder"
        p.message = "Choose the lumen-denoise project folder (it contains .venv and lumen_denoise)."
        if FileManager.default.fileExists(atPath: Cfg.projectRoot) { p.directoryURL = URL(fileURLWithPath: Cfg.projectRoot) }
        if p.runModal() == .OK, let url = p.url { engineRoot = url.path }
    }
}

/// One editable ISO band: limit (or "above" for the catch-all), strength slider, delete.
struct BandRow: View {
    @Binding var band: ISOBand
    let isCatchAll: Bool
    let onCommit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if isCatchAll {
                Text("Any higher ISO").frame(width: 150, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    Text("Up to ISO")
                    TextField("ISO", value: $band.maxISO, format: .number.grouping(.never))
                        .frame(width: 70).multilineTextAlignment(.trailing)
                        .onSubmit(onCommit)
                }
                .frame(width: 150, alignment: .leading)
            }
            Slider(value: $band.strength, in: 0...1, step: 0.05, onEditingChanged: { if !$0 { onCommit() } })
            Text("\(Int((band.strength * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            Button(action: onDelete) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(isCatchAll)
                .help(isCatchAll ? "The catch-all band can't be removed" : "Remove this band")
                .accessibilityLabel("Remove band")
        }
    }
}

// MARK: - Self-test and snapshot hooks

/// `--selftest`: output-guard cases plus a few Core sanity checks. Prints PASS/FAIL lines.
func runSelfTest() -> Bool {
    var ok = guardSelfTest()
    func check(_ name: String, _ cond: Bool) {
        print("\(cond ? "PASS" : "FAIL") core: \(name)")
        if !cond { ok = false }
    }
    var lowISO = QueueItem(source: "/tmp/a.ARW"); lowISO.iso = 200
    var highISO = QueueItem(source: "/tmp/b.ARW"); highISO.iso = 6400
    var custom = highISO; custom.strengthOverride = 0.3
    let s = StrengthSettings.default
    check("ISO 200 -> 55%", abs(s.strength(for: lowISO) - 0.55) < 1e-9)
    check("ISO 6400 -> 90%", abs(s.strength(for: highISO) - 0.9) < 1e-9)
    check("override wins", abs(s.strength(for: custom) - 0.3) < 1e-9)
    check("no ISO -> global", abs(s.strength(for: QueueItem(source: "/tmp/c.ARW")) - s.global) < 1e-9)
    check("formatDuration 42 s", formatDuration(42) == "42 s")
    check("chunks of empty queue", planChunks([], settings: s).isEmpty)
    print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
    return ok
}

/// Debug: LUMEN_SNAPSHOT=/path.png writes the window contents to a PNG (works without screen-recording permission) and quits.
func snapshotIfRequested() {
    guard let path = ProcessInfo.processInfo.environment["LUMEN_SNAPSHOT"] else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        if let v = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible })?.contentView?.superview,
           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        NSApp.terminate(nil)
    }
}

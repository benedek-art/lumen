import SwiftUI
import UniformTypeIdentifiers

@main
struct LumenDenoiseApp: App {
    @StateObject private var model = QueueModel()

    init() {
        if CommandLine.arguments.contains("--selftest") { exit(selfTest() ? 0 : 1) }
    }

    var body: some Scene {
        WindowGroup("Lumen Denoise") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 560)
                .onAppear { model.autotestIfRequested(); snapshotIfRequested() }
        }
        .defaultSize(width: 600, height: 700)
    }
}

struct ContentView: View {
    @EnvironmentObject var m: QueueModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 14) {
            dropZone
            if !m.items.isEmpty { fileList }
            controls
        }
        .padding(18)
        .alert("Not allowed", isPresented: Binding(get: { m.alert != nil }, set: { if !$0 { m.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(m.alert ?? "") }
    }

    var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.system(size: 38, weight: .light))
            Text("Drop ARW / RW2 files or folders").font(.title3)
            Text("Denoised DNGs go to the output folder below").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: m.items.isEmpty ? 240 : 120)
        .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                                                style: StrokeStyle(lineWidth: 2, dash: [7])))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { m.add([url]) } }
                }
            }
            return true
        }
    }

    var fileList: some View {
        List(m.items) { it in
            HStack(spacing: 8) {
                icon(it.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.url.lastPathComponent).lineLimit(1)
                    detail(it.status)
                }
                Spacer()
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 140)
    }

    @ViewBuilder func icon(_ s: Status) -> some View {
        switch s {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder func detail(_ s: Status) -> some View {
        switch s {
        case .queued: Text("Queued").font(.caption).foregroundStyle(.secondary)
        case .working: Text("Working…").font(.caption).foregroundStyle(.secondary)
        case .done(let t, let iso):
            Text(String(format: "Done in %.1f s", t) + (iso.map { " · ISO \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
        case .failed(let e): Text(e).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
        }
    }

    var controls: some View {
        VStack(spacing: 12) {
            if !m.items.isEmpty {
                ProgressView(value: Double(m.finished), total: Double(max(m.items.count, 1)))
                Text("\(m.finished) of \(m.items.count) files").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Strength")
                Slider(value: $m.strength, in: 0...100).disabled(m.running)
                Text("\(Int(m.strength.rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack {
                Image(systemName: "folder")
                Text(m.outDir).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") { m.chooseOut() }.disabled(m.running)
            }
            HStack {
                Button { m.reveal() } label: { Label("Reveal in Finder", systemImage: "folder.badge.gearshape") }
                Button("Clear") { m.clear() }.disabled(m.running || m.items.isEmpty)
                Spacer()
                if m.running {
                    Button("Cancel", role: .cancel) { m.cancel() }
                } else {
                    Button { m.start() } label: { Label("Denoise", systemImage: "wand.and.stars") }
                        .buttonStyle(.borderedProminent).disabled(m.items.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
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

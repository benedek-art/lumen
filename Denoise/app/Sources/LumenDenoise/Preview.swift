import SwiftUI
import AppKit
import CoreImage
import ImageIO

// MARK: - Renderer

/// A rendered raw frame plus the oriented pixel size it would have at 100% (needed to place a downscaled render
/// exactly where the full-resolution one will land).
struct RenderedImage: @unchecked Sendable {
    let cg: CGImage
    let fullSize: CGSize
    var isFullRes: Bool { CGFloat(cg.width) >= fullSize.width - 1 }
}

/// CIRAWFilter based renderer. One shared CIContext, one serial queue, a small LRU cache and per-group generation
/// counters so a stale request (selection or zoom changed) is skipped before it costs a full raw decode.
final class RawRenderer: @unchecked Sendable {
    static let shared = RawRenderer()

    private let queue = DispatchQueue(label: "lumen.denoise.preview", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    private var cache: [(key: String, image: RenderedImage)] = []   // queue-confined, most recent last
    private let maxEntries = 6, maxBytes = 320 << 20, maxLargeFullRes = 2   // ~131 MB per 33 MP RGBA8 frame
    private let lock = NSLock()
    private var generations: [String: Int] = [:]                     // lock-protected

    /// Contract API: main-queue completion, `nil` maxPixel = full resolution.
    func render(url: URL, maxPixel: CGFloat?, completion: @escaping (CGImage?, String?) -> Void) {
        renderDetailed(url: url, maxPixel: maxPixel, group: nil) { completion($0?.cg, $1) }
    }

    /// Like `render`, plus the 100% size. A newer request in the same `group` makes older queued ones complete
    /// with (nil, nil) without rendering; callers ignore that pair. `matchExposureOf` (the original raw) makes the
    /// denoised DNG render with the original's baseline exposure and white balance, so the split only shows noise.
    func renderDetailed(url: URL, maxPixel: CGFloat?, group: String?, matchExposureOf: URL? = nil,
                        completion: @escaping (RenderedImage?, String?) -> Void) {
        let gen = group.map(bump)
        queue.async {
            if let group, let gen, self.generation(group) != gen {
                DispatchQueue.main.async { completion(nil, nil) }; return
            }
            let (img, err) = autoreleasepool { self.renderNow(url: url, maxPixel: maxPixel, matchExposureOf: matchExposureOf) }
            DispatchQueue.main.async { completion(img, err) }
        }
    }

    func image(url: URL, maxPixel: CGFloat?, group: String?, matchExposureOf: URL? = nil) async -> (RenderedImage?, String?) {
        await withCheckedContinuation { c in
            renderDetailed(url: url, maxPixel: maxPixel, group: group, matchExposureOf: matchExposureOf) {
                c.resume(returning: ($0, $1))
            }
        }
    }

    private func bump(_ group: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        generations[group, default: 0] += 1
        return generations[group]!
    }
    private func generation(_ group: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return generations[group] ?? 0
    }

    /// Runs on `queue`. Noise reduction off for both images so the comparison is honest.
    private func renderNow(url: URL, maxPixel: CGFloat?, matchExposureOf src: URL?) -> (RenderedImage?, String?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let attrs else { return (nil, "File not found: \(url.lastPathComponent)") }
        let stamp = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)|\(attrs[.size] ?? 0)|\(maxPixel.map { "\(Int($0))" } ?? "full")|\(src?.path ?? "")"
        if let i = cache.firstIndex(where: { $0.key == key }) {
            let hit = cache.remove(at: i); cache.append(hit); return (hit.image, nil)
        }
        guard let f = CIRAWFilter(imageURL: url) else {
            return (nil, "macOS can't decode \(url.lastPathComponent) (camera or DNG variant not supported by Core Image).")
        }
        if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = 0 }
        if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = 0 }
        if let src, let ref = CIRAWFilter(imageURL: src) {   // metadata only, no decode
            f.baselineExposure = ref.baselineExposure
            f.neutralTemperature = ref.neutralTemperature
            f.neutralTint = ref.neutralTint
        }
        var scale: CGFloat = 1
        let longSide = max(f.nativeSize.width, f.nativeSize.height)
        if let maxPixel, maxPixel > 0, longSide > maxPixel {
            scale = maxPixel / longSide
            f.scaleFactor = Float(scale)
        }
        guard let out = f.outputImage, !out.extent.isInfinite, !out.extent.isEmpty else {
            return (nil, "Core Image produced no image for \(url.lastPathComponent).")
        }
        let rect = out.extent.integral
        guard let cg = context.createCGImage(out, from: rect, format: .RGBA8, colorSpace: colorSpace) else {
            return (nil, "Rendering \(url.lastPathComponent) failed (out of memory?).")
        }
        let full = CGSize(width: (rect.width / scale).rounded(), height: (rect.height / scale).rounded())
        let img = RenderedImage(cg: cg, fullSize: scale == 1 ? rect.size : full)
        cache.append((key, img))
        let isLarge: ((key: String, image: RenderedImage)) -> Bool = { $0.image.isFullRes && $0.image.cg.width > 4096 }
        while cache.filter(isLarge).count > maxLargeFullRes, let i = cache.firstIndex(where: isLarge) {
            cache.remove(at: i)
        }
        while cache.count > maxEntries || (cache.count > 1 && cache.reduce(0, { $0 + $1.image.cg.bytesPerRow * $1.image.cg.height }) > maxBytes) {
            cache.removeFirst()
        }
        if maxPixel == nil { context.clearCaches() }
        return (img, nil)
    }
}

/// Posted by menu commands (⌘0 / ⌘1) to drive the visible preview. `object` is "fit" or "actual".
enum PreviewZoom {
    static let notification = Notification.Name("LumenDenoise.previewZoom")
    /// Posted by the queue list so preview keys work while the list has focus. `object` is "holdOn", "holdOff",
    /// "toggleZoom" or "toggleSplit".
    static let keyNotification = Notification.Name("LumenDenoise.previewKey")
}

// MARK: - Before / after view

struct BeforeAfterView: View {
    let item: QueueItem
    init(item: QueueItem) { self.item = item }

    @EnvironmentObject var m: QueueModel
    @Environment(\.displayScale) private var displayScale
    @State private var before: RenderedImage?
    @State private var after: RenderedImage?
    @State private var beforeError: String?
    @State private var afterError: String?
    @State private var loading = false
    @State private var zoomed = false
    @State private var split: CGFloat = 0.5
    @State private var splitOn = true
    @State private var holdBefore = false
    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var paneSize: CGSize = .zero
    @State private var draft: Double = 1
    @State private var cursorPushed = false
    @FocusState private var focused: Bool

    private struct RenderKey: Equatable { var source: String; var output: String?; var stamp: Date?; var maxPixel: CGFloat? }

    private var hasOutput: Bool {
        (item.state == .done || item.state == .skipped) && !item.output.isEmpty
            && FileManager.default.fileExists(atPath: item.output)
    }
    private var renderKey: RenderKey {
        let stamp = hasOutput ? (try? FileManager.default.attributesOfItem(atPath: item.output))?[.modificationDate] as? Date : nil
        // Fit renders at ~2x the pane, bucketed so small window resizes don't re-decode; 0 = pane not laid out yet.
        let long = max(paneSize.width, paneSize.height) * max(2, displayScale)
        return RenderKey(source: item.source, output: hasOutput ? item.output : nil, stamp: stamp,
                         maxPixel: zoomed ? nil : (long / 512).rounded(.up) * 512)
    }
    private var showAfter: Bool { after != nil && !holdBefore }
    private var frameSize: CGSize? { (after ?? before)?.fullSize }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geo in
                pane(geo.size)
                    .onAppear { paneSize = geo.size }
                    .onChange(of: geo.size) { paneSize = geo.size; offset = clamped(offset, in: geo.size) }
            }
            .background(Color(nsColor: .underPageBackgroundColor))   // letterbox, adapts to light/dark
            .clipped()
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.space, "z", "Z", "0", "1", "\\"], phases: [.down, .repeat, .up]) { handleKey($0) }
            Divider()
            strengthBar
        }
        .task(id: renderKey) { await load(renderKey) }
        .onChange(of: item.id) { resetForNewItem() }
        .onChange(of: focused) { if !focused { holdBefore = false } }
        .onAppear { draft = currentStrength }   // don't steal focus: ↑/↓ must keep stepping through the queue
        .onReceive(NotificationCenter.default.publisher(for: PreviewZoom.notification)) { n in
            setZoom((n.object as? String) == "actual", at: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: PreviewZoom.keyNotification)) { n in
            switch n.object as? String {
            case "holdOn": holdBefore = true
            case "holdOff": holdBefore = false
            case "toggleZoom": setZoom(!zoomed, at: nil)
            case "toggleSplit": splitOn.toggle()
            default: break
            }
        }
    }

    // MARK: Header and strength bar

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text((item.source as NSString).lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("Zoom", selection: Binding(get: { zoomed }, set: { setZoom($0, at: nil) })) {
                Text("Fit").tag(false)
                Text("100%").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 110)
            .help("Fit (⌘0) or 100% (Z, ⌘1). Double-click the image to zoom there.")
            Toggle(isOn: $splitOn) { Image(systemName: "rectangle.split.2x1") }
                .toggleStyle(.button)
                .disabled(after == nil)
                .help("Split before/after (\\). Hold Space to see the original.")
                .accessibilityLabel("Split before and after")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private var detailLine: String {
        var parts: [String] = []
        if let c = item.camera { parts.append(c) }
        if let iso = item.iso { parts.append("ISO \(iso)") }
        if let s = item.usedStrength, hasOutput { parts.append("denoised at \(pct(s))") }
        if let t = item.seconds, hasOutput { parts.append(String(format: "%.1f s", t)) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private var currentStrength: Double { item.strengthOverride ?? item.usedStrength ?? m.strengthFor(item) }

    private var strengthBar: some View {
        let rerun = item.state != .queued
        return HStack(spacing: 8) {
            Text("Strength").font(.callout).foregroundStyle(.secondary)
            Slider(value: $draft, in: 0...1, step: 0.05).frame(minWidth: 100, maxWidth: 180).controlSize(.small)
            Text(pct(draft)).monospacedDigit().frame(width: 40, alignment: .trailing)
            if item.strengthOverride != nil {
                Button {
                    var auto = item; auto.strengthOverride = nil   // `item` is a stale copy that still has the override
                    m.setOverride(item.id, nil)
                    draft = m.strengthFor(auto)
                } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("Back to the automatic strength for this photo")
                    .accessibilityLabel("Reset strength to automatic")
            }
            Spacer(minLength: 8)
            Button(rerun ? "Re-run this photo at \(pct(draft))" : "Use \(pct(draft)) for this photo") {
                m.setOverride(item.id, draft)
                if rerun { m.reprocess([item.id]) }
            }
            .disabled(item.state == .working
                      || (!rerun && item.strengthOverride.map { abs($0 - draft) < 0.001 } == true))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: Image pane

    @ViewBuilder private func pane(_ size: CGSize) -> some View {
        let splitX = splitOn ? split * size.width : 0
        ZStack {
            layer(before, size)
            if showAfter {
                layer(after, size).mask {
                    HStack(spacing: 0) { Color.clear.frame(width: splitX); Rectangle() }
                }
            }
            labels
            if showAfter && splitOn { handle(at: splitX, size) }
            if before == nil && after == nil {
                if let e = beforeError {
                    ContentUnavailableView("Can't show this photo", systemImage: "exclamationmark.triangle",
                                           description: Text(e))
                } else {
                    ProgressView()
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(.named("lumenPreviewPane"))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { v in
                if zoomed {
                    let start = panStart ?? offset
                    if panStart == nil { panStart = offset }
                    offset = clamped(CGSize(width: start.width + v.translation.width,
                                            height: start.height + v.translation.height), in: size)
                } else if showAfter && splitOn {
                    split = min(max(v.location.x / max(size.width, 1), 0), 1)
                }
            }
            .onEnded { _ in panStart = nil })
        .onTapGesture(count: 2) { p in setZoom(!zoomed, at: p) }
        .simultaneousGesture(TapGesture().onEnded { focused = true })
        .simultaneousGesture(MagnifyGesture().onEnded { v in
            if v.magnification > 1.15 { setZoom(true, at: v.startLocation) }
            else if v.magnification < 0.87 { setZoom(false, at: nil) }
        })
        .overlay(alignment: .bottom) { caption.padding(10) }
    }

    /// Both images share one scale and one centre, each at its own size (the raw and the DNG crop can differ by
    /// a few pixels).
    private func rect(for img: RenderedImage, in size: CGSize) -> CGRect {
        guard zoomed else {
            let f = fitRect(in: size)
            guard let fs = frameSize, fs.width > 0 else { return f }
            let k = f.width / fs.width
            let w = img.fullSize.width * k, h = img.fullSize.height * k
            return CGRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
        }
        let s = CGSize(width: img.fullSize.width / displayScale, height: img.fullSize.height / displayScale)
        return CGRect(x: size.width / 2 + offset.width - s.width / 2, y: size.height / 2 + offset.height - s.height / 2,
                      width: s.width, height: s.height)
    }

    private func fitRect(in size: CGSize) -> CGRect {
        guard let fs = frameSize, fs.width > 0, fs.height > 0 else { return .zero }
        let k = min(size.width / fs.width, size.height / fs.height)
        let w = fs.width * k, h = fs.height * k
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    @ViewBuilder private func layer(_ img: RenderedImage?, _ size: CGSize) -> some View {
        if let img {
            let r = rect(for: img, in: size)
            Image(decorative: img.cg, scale: 1)
                .resizable()
                .interpolation(zoomed && img.isFullRes ? .none : .high)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
        } else {
            Color.clear
        }
    }

    private func handle(at x: CGFloat, _ size: CGSize) -> some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 1.5)   // drawn over the photo, not chrome
                .shadow(color: .black.opacity(0.5), radius: 1)
            Circle().fill(.regularMaterial).frame(width: 28, height: 28)
                .overlay(Image(systemName: "arrow.left.and.right").font(.caption.bold()).foregroundStyle(.primary))
                .shadow(radius: 2)
        }
        .frame(width: 28, height: size.height)
        .contentShape(Rectangle())
        .onHover { inside in   // balanced push/pop, also when the handle vanishes while hovered
            if inside && !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
            else if !inside && cursorPushed { NSCursor.pop(); cursorPushed = false }
        }
        .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("lumenPreviewPane"))
            .onChanged { v in split = min(max(v.location.x / max(size.width, 1), 0), 1) })
        .position(x: x, y: size.height / 2)
    }

    private var labels: some View {
        HStack {
            if before != nil && (!showAfter || splitOn) { tag("Before") }
            Spacer()
            if showAfter { tag("After") }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(10)
        .allowsHitTesting(false)
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
    }

    @ViewBuilder private var caption: some View {
        let note = captionText
        if loading || note != nil {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(note ?? (zoomed ? "Rendering at 100%…" : "Rendering…"))
                    .font(.callout)
                    .foregroundStyle(afterError != nil || item.state == .failed ? Color.red : Color.primary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .allowsHitTesting(false)
        }
    }

    private var captionText: String? {
        if let e = afterError { return "Denoised file: \(e)" }
        if hasOutput { return nil }
        switch item.state {
        case .queued: return "Not denoised yet. Showing the original."
        case .working: return "Denoising… showing the original."
        case .cancelled: return "Cancelled. Showing the original."
        case .failed: return (item.error?.title ?? "Failed") + ". Showing the original."
        case .done, .skipped: return "Output file is missing. Showing the original."
        }
    }

    // MARK: Actions

    private func handleKey(_ p: KeyPress) -> KeyPress.Result {
        if p.key == .space { holdBefore = p.phase != .up; return .handled }
        guard p.phase == .down else { return p.phase == .repeat ? .handled : .ignored }   // no beeps on auto-repeat
        let cmd = p.modifiers.contains(.command)
        switch p.key {
        case "z" where !cmd, "Z" where !cmd: setZoom(!zoomed, at: nil)
        case "1" where cmd: setZoom(true, at: nil)
        case "0" where cmd: setZoom(false, at: nil)
        case "\\" where !cmd: splitOn.toggle()
        default: return .ignored
        }
        return .handled
    }

    /// Zoom to 100% keeping the image point under `p` (pane coordinates) under the cursor; centre if nil.
    private func setZoom(_ z: Bool, at p: CGPoint?) {
        guard z != zoomed else { return }
        if z, let fs = frameSize {
            let fit = fitRect(in: paneSize)
            let s = CGSize(width: fs.width / displayScale, height: fs.height / displayScale)
            let pt = p ?? CGPoint(x: fit.midX, y: fit.midY)
            let ux = fit.width > 0 ? min(max((pt.x - fit.minX) / fit.width, 0), 1) : 0.5
            let uy = fit.height > 0 ? min(max((pt.y - fit.minY) / fit.height, 0), 1) : 0.5
            // Image origin = centre + offset - s/2 and we want origin + u*s == pt.
            zoomed = true
            offset = clamped(CGSize(width: pt.x - ux * s.width + s.width / 2 - paneSize.width / 2,
                                    height: pt.y - uy * s.height + s.height / 2 - paneSize.height / 2), in: paneSize)
        } else {
            zoomed = z
            offset = .zero
        }
    }

    private func clamped(_ o: CGSize, in size: CGSize) -> CGSize {
        guard zoomed, let fs = frameSize else { return .zero }
        let mx = max(0, (fs.width / displayScale - size.width) / 2)
        let my = max(0, (fs.height / displayScale - size.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }

    private func resetForNewItem() {
        before = nil; after = nil; beforeError = nil; afterError = nil
        offset = .zero; zoomed = false; holdBefore = false
        draft = currentStrength
    }

    @MainActor private func load(_ k: RenderKey) async {
        if k.maxPixel == 0 { return }                        // pane not laid out yet
        if before != nil || k.maxPixel == nil {              // debounce resizes / selection changes / stale full-res
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
        }
        loading = true
        let r = RawRenderer.shared
        let (b, be) = await r.image(url: URL(fileURLWithPath: k.source), maxPixel: k.maxPixel, group: "preview.before")
        if Task.isCancelled { return }
        if b != nil || be != nil { before = b; beforeError = be }
        if let out = k.output {
            let (a, ae) = await r.image(url: URL(fileURLWithPath: out), maxPixel: k.maxPixel, group: "preview.after",
                                        matchExposureOf: URL(fileURLWithPath: k.source))
            if Task.isCancelled { return }
            if a != nil || ae != nil { after = a; afterError = ae }
        } else {
            after = nil; afterError = nil
        }
        loading = false
        offset = clamped(offset, in: paneSize)
    }
}

private func pct(_ s: Double) -> String { "\(Int((s * 100).rounded()))%" }

// MARK: - Autotest PNG

/// Side-by-side PNG for autotest: top row before|after at fit (1600 px long side), bottom row the centre
/// 800x800 px crop of each at 100%. Completion on main.
func writePreviewPNG(before: URL, after: URL, to path: String, completion: @escaping (Bool) -> Void) {
    if isForbiddenOutput(path) { DispatchQueue.main.async { completion(false) }; return }
    let r = RawRenderer.shared
    r.renderDetailed(url: before, maxPixel: 1600, group: nil) { bf, _ in
        r.renderDetailed(url: after, maxPixel: 1600, group: nil, matchExposureOf: before) { af, _ in
            r.renderDetailed(url: before, maxPixel: nil, group: nil) { bz, _ in
                r.renderDetailed(url: after, maxPixel: nil, group: nil, matchExposureOf: before) { az, _ in
                    guard let bf, let af, let bz, let az else { completion(false); return }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let ok = composePNG(fit: (bf.cg, af.cg), full: (bz.cg, az.cg), space: r.colorSpace, to: path)
                        DispatchQueue.main.async { completion(ok) }
                    }
                }
            }
        }
    }
}

private func composePNG(fit: (CGImage, CGImage), full: (CGImage, CGImage), space: CGColorSpace, to path: String) -> Bool {
    func crop(_ i: CGImage) -> CGImage? {
        let w = min(800, i.width), h = min(800, i.height)
        return i.cropping(to: CGRect(x: (i.width - w) / 2, y: (i.height - h) / 2, width: w, height: h))
    }
    guard let cb = crop(full.0), let ca = crop(full.1) else { return false }
    let gap = 16
    let cellW = max(fit.0.width, fit.1.width, cb.width, ca.width)
    let fitH = max(fit.0.height, fit.1.height), cropH = max(cb.height, ca.height)
    let W = cellW * 2 + gap * 3, H = fitH + cropH + gap * 3
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    // CoreGraphics origin is bottom-left: fit row on top, crops below.
    for (col, pair) in [(fit.0, cb), (fit.1, ca)].enumerated() {
        let x = gap + col * (cellW + gap)
        ctx.draw(pair.0, in: CGRect(x: x, y: H - gap - pair.0.height, width: pair.0.width, height: pair.0.height))
        ctx.draw(pair.1, in: CGRect(x: x, y: gap + cropH - pair.1.height, width: pair.1.width, height: pair.1.height))
    }
    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
}

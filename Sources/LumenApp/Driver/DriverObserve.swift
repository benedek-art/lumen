// DriverObserve.swift
// What a scenario can see: the state dump, screenshots, gesture metrics, expectations.

#if os(macOS)

import AppKit
import LumenCore
import SwiftUI

extension DriverSession {

    // MARK: State

    func recipeValues(_ recipe: Recipe) -> [String: Any] {
        guard let text = try? CanonicalJSON.canonicalRecipeJSON(recipe),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        else { return [:] }
        var flat: [String: Any] = [:]
        DriverJSON.flatten(object, into: &flat)
        return flat
    }

    /// The first on-screen frame of an anchor, in main-window points.
    func anchorRect(_ id: String) -> CGRect? {
        anchorRects(id: id).first
    }

    /// Everything `expect` and `state` can read. Keys are documented in driver/README.md.
    func snapshot() -> [String: Any] {
        var out: [String: Any] = ["t": DriverClock.now()]
        let layout = PanelLayout.shared.layout
        out["viewMode"] = state.viewMode.rawValue
        out["workspace"] = layout.workspace.rawValue
        out["masking"] = layout.isMasking
        out["scanning"] = state.isScanning
        out["status"] = state.statusMessage ?? ""

        let photos = state.photos
        var photo: [String: Any] = ["count": photos.count]
        if let selected = state.primarySelection {
            photo["name"] = selected.id.lastPathComponent
            photo["index"] = photos.firstIndex { $0.id == selected.id } ?? -1
        }
        out["photo"] = photo

        let viewport = LoupeViewport.shared
        var view: [String: Any] = ["zoom": viewport.zoom,
                                   "panX": Double(viewport.pan.width),
                                   "panY": Double(viewport.pan.height)]
        if let cursor = viewport.lastCursor {
            view["lastCursorX"] = Double(cursor.x)
            view["lastCursorY"] = Double(cursor.y)
        }
        if let viewer = anchorRect("viewer") {
            view["viewer"] = DriverJSON.rect(viewer)
        }
        if let image = anchorRect("viewer.image") {
            view["image"] = DriverJSON.rect(image)
            if let viewer = anchorRect("viewer") {
                // How far each image edge sits inside (+) or outside (-) the viewer.
                view["insetLeft"] = Double(image.minX - viewer.minX)
                view["insetTop"] = Double(image.minY - viewer.minY)
                view["insetRight"] = Double(viewer.maxX - image.maxX)
                view["insetBottom"] = Double(viewer.maxY - image.maxY)
            }
            if let last = frames.last, last.nativeLongEdge > 0 {
                view["scale"] = Double(Swift.max(image.width, image.height))
                    / Double(last.nativeLongEdge)
            }
        }
        out["viewport"] = view

        var render: [String: Any] = ["frames": frames.count]
        if let last = frames.last {
            render["draft"] = last.isDraft
            render["width"] = last.width
            render["height"] = last.height
            render["longEdge"] = Swift.max(last.width, last.height)
            render["nativeLongEdge"] = last.nativeLongEdge
            render["region"] = last.region
            render["embedded"] = last.embedded
            render["age"] = DriverClock.now() - last.t
            render["current"] = last.recipe == state.currentRecipe
        }
        out["render"] = render

        let recipe = state.currentRecipe
        out["recipe"] = recipeValues(recipe)

        var masks: [String: Any] = ["count": recipe.masks.count]
        masks["list"] = recipe.masks.map { mask -> [String: Any] in
            ["id": mask.id, "name": mask.name, "enabled": mask.enabled,
             "components": mask.components.count]
        }
        masks["active"] = state.activeMaskID ?? ""
        masks["overlay"] = state.soloMaskOverlay ?? ""
        masks["overlayShown"] = state.soloMaskOverlay != nil
        masks["overlayRasterized"] = state.maskOverlayAlpha != nil
        masks["panelVisible"] = state.maskPanelVisible
        masks["createBoardOpen"] = state.maskCreateBoardOpen
        out["masks"] = masks

        if let window, let input {
            let windowState: [String: Any] = [
                "frame": DriverJSON.rect(window.frame), "key": window.isKeyWindow,
                "active": NSApp.isActive,
            ]
            out["window"] = windowState
            out["cursor"] = DriverJSON.point(input.cursor)
            let listed = DriverWindows.list(main: window)
            var windows: [String: Any] = [
                "count": listed.count,
                "roles": listed.map { $0.role }.joined(separator: ","),
                "key": listed.first { $0.isKey }?.role ?? "",
                "list": listed.enumerated().map { $0.element.json(index: $0.offset) },
            ]
            for role in ["sheet", "popover", "alert", "filePanel", "colors", "panel", "menu"] {
                windows[role] = listed.contains { $0.role == role }
            }
            windows["sheetTitle"] = listed.first { $0.role == "sheet" }?.title ?? ""
            out["windows"] = windows
        }
        return out
    }

    /// The snapshot plus everything earlier steps stored, flattened to dotted paths.
    /// The reflected sections are only built when `path` asks for one.
    func lookupTable(for path: String = "") -> [String: Any] {
        var flat: [String: Any] = [:]
        DriverJSON.flatten(snapshot(), into: &flat)
        DriverJSON.flatten(values, into: &flat)
        if DriverSession.reflectedPrefixes.contains(where: { path.hasPrefix($0) }) {
            DriverJSON.flatten(reflectedState(), into: &flat)
        }
        if path.hasPrefix("menu.") {
            for row in DriverReflect.menus() {
                guard let name = row["path"] as? String else { continue }
                flat["menu." + name + ".enabled"] = row["enabled"]
                flat["menu." + name + ".checked"] = row["checked"]
            }
        }
        return flat
    }

    /// Recognized text on a fresh screenshot, in window-frame points.
    func screenTexts() -> [[String: Any]] {
        guard let window, let input, let image = captureImage(method: captureMethod).image
        else { return [] }
        input.refreshGeometry()
        let scale = Double(image.width) / Double(Swift.max(window.frame.width, 1))
        return DriverReflect.texts(in: image).map { hit in
            var row = DriverJSON.rect(CGRect(x: hit.rect.minX / scale, y: hit.rect.minY / scale,
                                             width: hit.rect.width / scale,
                                             height: hit.rect.height / scale))
            row["text"] = hit.text
            return row
        }
    }

    func dumpState(_ step: DriverStep) async -> [String: Any] {
        var dump = snapshot()
        for (key, value) in reflectedState() { dump[key] = value }
        dump["menus"] = DriverReflect.menus()
        dump["sidecar"] = sidecar()
        if step.bool("texts") == true { dump["texts"] = screenTexts() }
        var anchors: [[String: Any]] = []
        for anchor in liveAnchors() {
            var row = DriverJSON.rect(anchor.rect)
            row["id"] = anchor.id
            if let other = anchor.window, other !== window { row["inWindow"] = other.title }
            anchors.append(row)
        }
        dump["anchors"] = anchors
        if step.bool("ax") == true {
            let snapshot = await DriverAX.snapshot()
            dump["ax"] = snapshot.nodes.filter { !$0.label.isEmpty }.prefix(3000).map { (node) -> [String: Any] in
                var row = DriverJSON.rect(axRect(node))
                row["name"] = node.name
                row["role"] = node.role
                row["enabled"] = node.enabled
                if !node.value.isEmpty { row["value"] = String(node.value.prefix(80)) }
                return row
            }
            if let error = snapshot.error { dump["axError"] = error }
        }
        let name = step.string("name") ?? step.id
        DriverJSON.write(dump, to: outDir.appendingPathComponent("state-\(name).json"))
        return ["file": "state-\(name).json"]
    }

    // MARK: Expectations

    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        return String(describing: value)
    }

    /// Evaluates a step's condition. Operators: eq ne gt ge lt le near(+tol) exists.
    /// A right-hand string that names a path is read as that path's value.
    func evaluate(_ step: DriverStep, in table: [String: Any])
        -> (holds: Bool, actual: Any, summary: String) {
        let path = step.string("that") ?? ""
        let actual = table[path]
        let shown: Any = actual ?? NSNull()
        func rhs(_ key: String) -> Any? {
            let value = step.raw[key]
            if let name = value as? String, let referenced = table[name] { return referenced }
            return value
        }
        if let wanted = step.bool("exists") {
            return ((actual != nil) == wanted, shown, "\(path) exists == \(wanted)")
        }
        for (key, symbol) in [("gt", ">"), ("ge", ">="), ("lt", "<"), ("le", "<=")]
        where step.has(key) {
            guard let a = number(actual), let b = number(rhs(key)) else {
                return (false, shown, "\(path) \(symbol) \(text(rhs(key))) (not numeric)")
            }
            let holds: Bool
            switch key {
            case "gt": holds = a > b
            case "ge": holds = a >= b
            case "lt": holds = a < b
            default: holds = a <= b
            }
            return (holds, shown, "\(path) \(symbol) \(text(rhs(key)))")
        }
        if step.has("near") {
            let tolerance = step.double("tol") ?? 0.01
            guard let a = number(actual), let b = number(rhs("near")) else {
                return (false, shown, "\(path) ≈ \(text(rhs("near"))) (not numeric)")
            }
            return (abs(a - b) <= tolerance, shown,
                    "\(path) ≈ \(text(rhs("near"))) ± \(tolerance)")
        }
        for (key, negate) in [("eq", false), ("ne", true)] where step.has(key) {
            let expected = rhs(key)
            var same: Bool
            if let a = number(actual), let b = number(expected),
               !(actual is String), !(expected is String) {
                same = abs(a - b) <= (step.double("tol") ?? 1e-9)
            } else {
                same = text(actual) == text(expected)
            }
            if actual == nil { same = false }
            return (same != negate, shown,
                    "\(path) \(negate ? "!=" : "==") \(text(expected))")
        }
        return (false, shown, "\(path): no operator (eq ne gt ge lt le near exists)")
    }

    func expect(_ step: DriverStep) -> [String: Any] {
        let result = evaluate(step, in: lookupTable(for: step.string("that") ?? ""))
        if result.holds { expectPasses += 1 } else { expectFailures += 1 }
        return ["status": result.holds ? "pass" : "fail", "actual": result.actual,
                "check": result.summary]
    }

    /// Like `expect`, but polls until it holds. A timeout is a failed expectation.
    func waitFor(_ step: DriverStep) async -> [String: Any] {
        let timeout = step.double("timeout") ?? 10
        let began = DriverClock.now()
        let path = step.string("that") ?? ""
        var result = evaluate(step, in: lookupTable(for: path))
        while !result.holds, DriverClock.now() - began < timeout {
            await sleep(0.05)
            result = evaluate(step, in: lookupTable(for: path))
        }
        if result.holds { expectPasses += 1 } else { expectFailures += 1 }
        return ["status": result.holds ? "pass" : "fail", "actual": result.actual,
                "check": result.summary, "waitedMs": (DriverClock.now() - began) * 1000]
    }

    // MARK: Settling

    /// Waits for a sharp frame of the current recipe followed by `quiet` seconds with
    /// no further frame. Returns when that frame landed, or nil on timeout.
    func settled(timeout: Double, quiet: Double) async -> Double? {
        let deadline = DriverClock.now() + timeout
        while DriverClock.now() < deadline {
            if let last = frames.last, !last.isDraft, !last.embedded,
               last.recipe == state.currentRecipe,
               DriverClock.now() - last.t >= quiet {
                return last.t
            }
            await sleep(0.03)
        }
        return nil
    }

    func waitSettled(_ step: DriverStep) async -> [String: Any] {
        let began = DriverClock.now()
        let at = await settled(timeout: step.double("timeout") ?? 30,
                               quiet: step.double("quiet") ?? 0.5)
        var out: [String: Any] = ["settled": at != nil,
                                  "waitedMs": (DriverClock.now() - began) * 1000]
        if let last = frames.last {
            out["longEdge"] = Swift.max(last.width, last.height)
            out["draft"] = last.isDraft
        }
        if at == nil, step.verb == "waitSettled" {
            expectFailures += 1
            out["status"] = "fail"
            out["check"] = "a sharp frame of the current settings within the timeout"
        }
        return out
    }

    // MARK: Screenshots

    /// The main window as `method` captures it; with `windowList`, every sheet, popover,
    /// panel and menu over it composited in.
    func captureImage(method: DriverCapture.Method) -> (image: CGImage?, extra: [DriverWindowInfo]) {
        guard let window else { return (nil, []) }
        var extra: [DriverWindowInfo] = []
        if method == .windowList {
            let image = DriverWindows.composite(main: window, extra: &extra)
            return (image, extra)
        }
        return (DriverCapture.image(window: window, method: method), [])
    }

    func takeShot(name: String, group: String?, keep: Bool) async throws -> [String: Any] {
        guard let window, let input else { throw DriverError("no window") }
        input.refreshGeometry()
        var method = captureMethod
        var captured = captureImage(method: method)
        if captured.image == nil, method != .cacheDisplay {
            method = .cacheDisplay
            captured = captureImage(method: method)
        }
        guard let image = captured.image else {
            throw DriverError("no capture method produced an image")
        }
        let file = "shots/\(name).png"
        DriverCapture.write(image, to: outDir.appendingPathComponent(file))
        var windowRows: [[String: Any]] = []
        let bounds = CGRect(origin: .zero, size: window.frame.size)
        for (index, other) in captured.extra.enumerated() {
            var row = other.json(index: index)
            // A window that reaches past the main window's edges is also saved whole.
            if !bounds.insetBy(dx: -1, dy: -1).contains(other.frame),
               let alone = DriverWindows.single(other) {
                let extraFile = "shots/\(name).\(other.role)\(index).png"
                DriverCapture.write(alone, to: outDir.appendingPathComponent(extraFile))
                row["file"] = extraFile
            }
            windowRows.append(row)
        }
        let scale = Double(image.width) / Double(Swift.max(window.frame.width, 1))
        var row: [String: Any] = [
            "name": name, "file": file, "t": DriverClock.now(), "method": method.rawValue,
            "width": image.width, "height": image.height, "scale": scale,
            "cursor": DriverJSON.point(input.cursor),
            "zoom": LoupeViewport.shared.zoom,
            "panX": Double(LoupeViewport.shared.pan.width),
            "panY": Double(LoupeViewport.shared.pan.height),
            "frames": frames.count,
            "draft": frames.last?.isDraft ?? false,
            "overlay": state.soloMaskOverlay != nil,
        ]
        if let group { row["group"] = group }
        if !windowRows.isEmpty { row["windows"] = windowRows }
        if let viewer = anchorRect("viewer") { row["viewer"] = DriverJSON.rect(viewer) }
        if let imageRect = anchorRect("viewer.image") {
            row["image"] = DriverJSON.rect(imageRect)
        }
        shotRows.append(row)
        DriverTimeline.shared.add("shot", ["name": name])
        if keep {
            keptShots[name] = image
            keptOrder.append(name)
            while keptOrder.count > 24 {
                keptShots[keptOrder.removeFirst()] = nil
            }
        }
        return row
    }

    /// Pixel rectangle of a named region in a screenshot of the given scale.
    private func pixelRect(_ region: String, scale: Double, size: CGSize) -> CGRect {
        let whole = CGRect(origin: .zero, size: size)
        if region == "window" { return whole }
        guard let rect = anchorRect(region) else { return whole }
        var clipped = rect
        if region == "viewer.image", let viewer = anchorRect("viewer") {
            clipped = rect.intersection(viewer)
        }
        return CGRect(x: clipped.minX * scale, y: clipped.minY * scale,
                      width: clipped.width * scale, height: clipped.height * scale)
            .intersection(whole)
    }

    func shot(_ step: DriverStep) async throws -> [String: Any] {
        let name = step.string("name") ?? step.id
        if let delay = step.double("after") { await sleep(delay) }
        let row = try await takeShot(name: name, group: step.string("group"), keep: true)
        var out: [String: Any] = ["file": row["file"] ?? "", "method": row["method"] ?? ""]
        if let image = keptShots[name], let pixels = DriverPixels(image),
           let scale = row["scale"] as? Double {
            let size = CGSize(width: image.width, height: image.height)
            let region = step.string("region") ?? "viewer.image"
            var stats = pixels.stats(in: pixelRect(region, scale: scale, size: size))
            // `also`: the same moment by another capture method, to tell what the app
            // drew from what the window server composited.
            if let name2 = step.string("also"), let method = DriverCapture.Method(rawValue: name2),
               let window, let second = captureImage(method: method).image {
                DriverCapture.write(second, to: outDir.appendingPathComponent(
                    "shots/\(name).\(name2).png"))
                if let other = DriverPixels(second) {
                    let otherSize = CGSize(width: second.width, height: second.height)
                    let otherScale = Double(second.width) / Double(Swift.max(window.frame.width, 1))
                    stats[name2] = other.stats(in: pixelRect(region, scale: otherScale,
                                                             size: otherSize))
                }
            }
            out["stats"] = stats
            values["shots." + name] = stats
        }
        return out
    }

    /// Measures how screenshot `b` differs from `a` inside a region (default the image).
    func compare(_ step: DriverStep) throws -> [String: Any] {
        guard let a = step.string("a"), let b = step.string("b") else {
            throw DriverError("compare needs a and b")
        }
        guard let first = keptShots[a], let second = keptShots[b] else {
            throw DriverError("compare: shot \(keptShots[a] == nil ? a : b) was not taken")
        }
        guard let pixelsA = DriverPixels(first), let pixelsB = DriverPixels(second) else {
            throw DriverError("compare: could not read pixels")
        }
        guard let window else { throw DriverError("no window") }
        let scale = Double(first.width) / Double(Swift.max(window.frame.width, 1))
        let size = CGSize(width: first.width, height: first.height)
        let region = step.string("region") ?? "viewer.image"
        guard let difference = pixelsA.difference(
            to: pixelsB, in: pixelRect(region, scale: scale, size: size),
            threshold: step.int("threshold") ?? 12) else {
            throw DriverError("compare: the two shots differ in size")
        }
        let name = step.string("name") ?? step.id
        values["compare." + name] = difference
        return difference
    }

    // MARK: Gesture metrics

    /// What `film` saw: how often the pixels of the region changed, from outside the app.
    func filmMetrics(_ changes: [(t: Double, delta: Double)], samples: Int, began: Double,
                     ended: Double) -> [String: Any] {
        var out: [String: Any] = ["screenSamples": samples]
        let during = changes.filter { $0.t >= began && $0.t <= ended }
        out["screenChangesDuring"] = during.count
        out["screenChangesAfter"] = changes.filter { $0.t > ended }.count
        if let first = changes.first(where: { $0.t >= began }) {
            out["screenFirstChangeMs"] = (first.t - began) * 1000
        }
        var edges: [Double] = [began] + during.map { $0.t } + [ended]
        edges.sort()
        var gap = 0.0
        for k in 1..<edges.count { gap = Swift.max(gap, edges[k] - edges[k - 1]) }
        out["screenMaxGapMs"] = gap * 1000
        if let last = changes.last {
            out["screenLastChangeMs"] = (last.t - ended) * 1000
        }
        var trace: [[Any]] = []
        for change in changes.prefix(300) {
            trace.append([(change.t - began) * 1000, change.delta])
        }
        out["screenTrace"] = trace
        return out
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Swift.min(Int((Double(sorted.count - 1) * p).rounded()), sorted.count - 1)
        return sorted[index]
    }

    /// Frames, gaps and latency over one gesture. `began`…`ended` is the gesture;
    /// frames up to `settledAt` (or now) count toward release-to-final numbers.
    func gestureMetrics(began: Double, posted: Double, ended: Double, settledAt: Double?,
                        framesFrom: Int, samplesFrom: Int, hitchesFrom: Int,
                        watch: String?) -> [String: Any] {
        var out: [String: Any] = ["gestureMs": (ended - began) * 1000,
                                  "postingMs": (posted - began) * 1000]
        let newFrames = Array(frames[framesFrom...])
        let newSamples = Array(samples[samplesFrom...])
        let during = newFrames.filter { $0.t <= ended }
        out["framesDuring"] = during.count
        out["framesDuringDraft"] = during.filter { $0.isDraft }.count
        out["framesAfter"] = newFrames.count - during.count
        out["samples"] = newSamples.count

        // Gaps: gesture start, each frame, gesture end.
        var edges: [Double] = [began] + during.map { $0.t } + [ended]
        edges.sort()
        var maxGap = 0.0
        for k in 1..<edges.count { maxGap = Swift.max(maxGap, edges[k] - edges[k - 1]) }
        out["maxFrameGapMs"] = maxGap * 1000
        if let first = during.first { out["firstFrameMs"] = (first.t - began) * 1000 }
        if ended > began, !during.isEmpty {
            out["fpsDuring"] = Double(during.count) / (ended - began)
        }

        // Value identity: when did each distinct recipe first exist, and when was a
        // frame of it shown?
        var firstSeen: [(recipe: Recipe, t: Double)] = []
        for sample in newSamples where !firstSeen.contains(where: { $0.recipe == sample.recipe }) {
            firstSeen.append((sample.recipe, sample.t))
        }
        out["distinctValues"] = firstSeen.count
        var latencies: [Double] = []
        var stale = 0
        var shownValues: [Int] = []
        for frame in newFrames {
            guard let index = firstSeen.firstIndex(where: { $0.recipe == frame.recipe }) else {
                continue
            }
            if !shownValues.contains(index) { shownValues.append(index) }
            guard frame.t <= ended else { continue }
            latencies.append((frame.t - firstSeen[index].t) * 1000)
            let newest = newSamples.last { $0.t <= frame.t }
            if let newest, newest.recipe != frame.recipe { stale += 1 }
        }
        out["distinctValuesShown"] = shownValues.count
        out["staleFramesDuring"] = stale
        if !latencies.isEmpty {
            let sorted = latencies.sorted()
            let latency: [String: Any] = [
                "min": sorted[0], "p50": percentile(sorted, 0.5),
                "p90": percentile(sorted, 0.9), "max": sorted[sorted.count - 1],
                "n": sorted.count,
            ]
            out["latencyMs"] = latency
        }

        // After release: first frame of the final value, and the sharp one.
        if let final = newSamples.last?.recipe {
            if let frame = newFrames.first(where: { $0.recipe == final }) {
                out["releaseToFinalValueMs"] = (frame.t - ended) * 1000
            }
            if let frame = newFrames.first(where: { $0.recipe == final && !$0.isDraft }) {
                out["releaseToSharpMs"] = (frame.t - ended) * 1000
            }
        }
        if let settledAt { out["releaseToSettledMs"] = (settledAt - ended) * 1000 }
        out["settled"] = settledAt != nil

        // A hitch row is stamped at its end; one that began inside the gesture counts.
        let newHitches = hitches[hitchesFrom...].filter { $0.t - $0.ms / 1000 <= ended }
        out["hitches"] = newHitches.count
        out["hitchMaxMs"] = newHitches.map { $0.ms }.max() ?? 0
        out["hitchTotalMs"] = newHitches.map { $0.ms }.reduce(0, +)
        let later = hitches[hitchesFrom...].filter { $0.t - $0.ms / 1000 > ended }
        out["hitchAfterMaxMs"] = later.map { $0.ms }.max() ?? 0

        if let watch {
            func value(_ recipe: Recipe) -> Any { recipeValues(recipe)[watch] ?? NSNull() }
            if let first = newSamples.first { out["watchStart"] = value(first.recipe) }
            if let last = newSamples.last { out["watchEnd"] = value(last.recipe) }
            // The per-frame trace, for reading by hand: [ms since gesture start, value].
            var trace: [[Any]] = []
            for frame in newFrames.prefix(400) {
                trace.append([(frame.t - began) * 1000, value(frame.recipe),
                              frame.isDraft ? "draft" : "sharp",
                              Swift.max(frame.width, frame.height)])
            }
            out["frameTrace"] = trace
        }
        return out
    }
}

#endif

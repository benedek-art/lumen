// DriverCapture.swift
// Window screenshots and pixel statistics. See driver/README.md.

#if os(macOS)

import AppKit
import CoreGraphics
import ImageIO

enum DriverCapture {

    enum Method: String {
        /// The composited window from the window server: what is on the glass.
        case windowList
        /// AppKit redraws the view tree into a bitmap. No Metal layers.
        case cacheDisplay
        /// `/usr/sbin/screencapture -l`. Slow; needs screen-recording permission.
        case screencapture
    }

    // CGWindowListCreateImage is marked unavailable in the macOS 15 SDK but still
    // exported; a process may always capture its own windows through it.
    private typealias WindowListCreateImage =
        @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func windowList(windowNumber: Int) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "CGWindowListCreateImage") else { return nil }
        let function = unsafeBitCast(symbol, to: WindowListCreateImage.self)
        // 8 = include just this window; 1 | 8 = ignore the shadow, native resolution.
        return function(CGRect.null, 8, UInt32(windowNumber), 1 | 8)?.takeRetainedValue()
    }

    @MainActor
    static func viewTree(window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    static func screencapture(windowNumber: Int, to url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(windowNumber), url.path]
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
            && FileManager.default.fileExists(atPath: url.path)
    }

    @MainActor
    static func image(window: NSWindow, method: Method) -> CGImage? {
        switch method {
        case .windowList:
            return windowList(windowNumber: window.windowNumber)
        case .cacheDisplay:
            return viewTree(window: window)
        case .screencapture:
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("lumen-driver-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: url) }
            guard screencapture(windowNumber: window.windowNumber, to: url),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    // MARK: Writing

    private static let writer = DispatchQueue(label: "lumen.driver.png")

    /// Encodes off the main thread so a burst of captures does not stall the gesture
    /// being captured. `drain()` before exit.
    static func write(_ image: CGImage, to url: URL) {
        writer.async {
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    static func drain() {
        writer.sync {}
    }
}

/// An image as plain 8-bit sRGB RGBA, for arithmetic.
struct DriverPixels {

    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.bytes = buffer
    }

    /// Row 0 is the top of the image.
    func rgb(x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let cx = Swift.min(Swift.max(x, 0), width - 1)
        let cy = Swift.min(Swift.max(y, 0), height - 1)
        let i = (cy * width + cx) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    private func clamp(_ rect: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let x0 = Swift.min(Swift.max(Int(rect.minX.rounded()), 0), width)
        let y0 = Swift.min(Swift.max(Int(rect.minY.rounded()), 0), height)
        let x1 = Swift.min(Swift.max(Int(rect.maxX.rounded()), x0), width)
        let y1 = Swift.min(Swift.max(Int(rect.maxY.rounded()), y0), height)
        return (x0, y0, x1, y1)
    }

    /// Channel means and luma standard deviation over `rect` (pixels).
    func stats(in rect: CGRect) -> [String: Any] {
        let c = clamp(rect)
        var sr = 0.0, sg = 0.0, sb = 0.0, sl = 0.0, sl2 = 0.0
        var n = 0.0
        var y = c.y0
        while y < c.y1 {
            var i = (y * width + c.x0) * 4
            var x = c.x0
            while x < c.x1 {
                let r = Double(bytes[i]), g = Double(bytes[i + 1]), b = Double(bytes[i + 2])
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                sr += r; sg += g; sb += b; sl += l; sl2 += l * l
                n += 1
                i += 4
                x += 1
            }
            y += 1
        }
        guard n > 0 else { return ["n": 0] }
        let mean = sl / n
        return ["n": Int(n), "r": sr / n, "g": sg / n, "b": sb / n, "luma": mean,
                "lumaSD": (Swift.max(sl2 / n - mean * mean, 0)).squareRoot()]
    }

    /// How `other` differs from this image inside `rect`. Same-size images only.
    func difference(to other: DriverPixels, in rect: CGRect,
                    threshold: Int = 12) -> [String: Any]? {
        guard other.width == width, other.height == height else { return nil }
        let c = clamp(rect)
        var dr = 0.0, dg = 0.0, db = 0.0, total = 0.0, changed = 0.0, n = 0.0
        var y = c.y0
        while y < c.y1 {
            var i = (y * width + c.x0) * 4
            var x = c.x0
            while x < c.x1 {
                let r = Int(other.bytes[i]) - Int(bytes[i])
                let g = Int(other.bytes[i + 1]) - Int(bytes[i + 1])
                let b = Int(other.bytes[i + 2]) - Int(bytes[i + 2])
                dr += Double(r); dg += Double(g); db += Double(b)
                let magnitude = abs(r) + abs(g) + abs(b)
                total += Double(magnitude)
                if magnitude > threshold * 3 { changed += 1 }
                n += 1
                i += 4
                x += 1
            }
            y += 1
        }
        guard n > 0 else { return ["n": 0] }
        let meanR = dr / n, meanG = dg / n, meanB = db / n
        return ["n": Int(n), "dr": meanR, "dg": meanG, "db": meanB,
                "meanAbs": total / n / 3, "changedFraction": changed / n,
                // Positive when the region moved toward red: the mask overlay's mark.
                "redShift": meanR - (meanG + meanB) / 2]
    }
}

#endif

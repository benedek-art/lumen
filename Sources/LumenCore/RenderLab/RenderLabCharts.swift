// RenderLabCharts.swift
// Synthetic scene-linear test charts for the render lab. Values are in the working
// space (linear Rec.2020) with mid-grey at 0.18, the same convention as a RAW decode.
// Every chart is 3:2 landscape and is generated at the size it is rendered at.

import Foundation

public enum RenderLabCharts {

    public struct Chart {
        public var name: String
        public var image: ImageBuffer
        public var patches: [RenderLabPatch]
    }

    public static let names = ["greyRamp", "colorChecker", "hueRing", "skin", "detail", "flatGrey",
                               "gradient", "pointLights"]

    static let midGrey = 0.18
    static let background = RGB(gray: 0.18 * 0.25)

    public static func make(_ name: String, longEdge: Int) throws -> Chart {
        let w = Swift.max(48, longEdge)
        let h = Swift.max(32, longEdge * 2 / 3)
        switch name {
        case "greyRamp": return greyRamp(w, h)
        case "colorChecker": return patchChart(name, w, h, cols: 6, rows: 4, colorChecker)
        case "hueRing": return patchChart(name, w, h, cols: 12, rows: 6, hueRing)
        case "skin": return patchChart(name, w, h, cols: 6, rows: 2, skinTones)
        case "detail": return detail(w, h)
        case "flatGrey": return flatGrey(w, h)
        case "gradient": return gradient(w, h)
        case "pointLights": return pointLights(w, h)
        default:
            throw RenderLabError.missingPhoto("no chart \"\(name)\"; charts: \(names.joined(separator: ", "))")
        }
    }

    // MARK: - Grey ramp and step wedge

    /// Top 40%: continuous ramp −8…+4 EV around mid-grey. Bottom: 13 one-stop steps.
    static func greyRamp(_ w: Int, _ h: Int) -> Chart {
        let steps = Array(-8...4)
        var image = ImageBuffer(width: w, height: h)
        for y in 0..<h {
            let v = (Double(y) + 0.5) / Double(h)
            for x in 0..<w {
                let u = (Double(x) + 0.5) / Double(w)
                let ev: Double
                if v < 0.4 {
                    ev = -8 + 12 * u
                } else {
                    ev = Double(steps[Swift.min(steps.count - 1, Int(u * Double(steps.count)))])
                }
                image[x, y] = RGB(gray: midGrey * exp2(ev))
            }
        }
        let cell = 1.0 / Double(steps.count)
        let patches = steps.enumerated().map { i, ev in
            RenderLabPatch(name: "ev\(ev >= 0 ? "+" : "")\(ev)", x: Double(i) * cell, y: 0.45,
                           w: cell, h: 0.5, scene: RGB(gray: midGrey * exp2(Double(ev))))
        }
        return Chart(name: "greyRamp", image: image, patches: patches)
    }

    // MARK: - Patch charts

    static func patchChart(_ name: String, _ w: Int, _ h: Int, cols: Int, rows: Int,
                           _ colours: [(String, RGB)]) -> Chart {
        let gap = 0.12
        var patches: [RenderLabPatch] = []
        for (i, entry) in colours.enumerated() {
            let col = i % cols, row = i / cols
            let cw = 1.0 / Double(cols), rh = 1.0 / Double(rows)
            patches.append(RenderLabPatch(
                name: entry.0, x: (Double(col) + gap / 2) * cw, y: (Double(row) + gap / 2) * rh,
                w: cw * (1 - gap), h: rh * (1 - gap), scene: entry.1))
        }
        let image = ImageBuffer(width: w, height: h) { u, v in
            for (p, c) in zip(patches, colours)
            where u >= p.x && u < p.x + p.w && v >= p.y && v < p.y + p.h {
                return c.1
            }
            return background
        }
        return Chart(name: name, image: image, patches: patches)
    }

    /// An 8-bit sRGB colour as a scene value, scaled so sRGB 122 (ColorChecker
    /// Neutral 5) lands on mid-grey. Same construction as `ProofFrames.colourChart`.
    static func sceneFromSRGB(_ r: Double, _ g: Double, _ b: Double) -> RGB {
        let tf = TransferFunction.srgb
        let scale = midGrey / tf.decode(122.0 / 255.0)
        let toWorking = RGBColorSpace.srgb.matrix(to: .rec2020)
        return toWorking.apply(RGB(tf.decode(r / 255) * scale, tf.decode(g / 255) * scale,
                                   tf.decode(b / 255) * scale))
    }

    static let colorChecker: [(String, RGB)] = {
        let p: [(String, Double, Double, Double)] = [
            ("1 dark skin", 115, 82, 68), ("2 light skin", 194, 150, 130),
            ("3 blue sky", 98, 122, 157), ("4 foliage", 87, 108, 67),
            ("5 blue flower", 133, 128, 177), ("6 bluish green", 103, 189, 170),
            ("7 orange", 214, 126, 44), ("8 purplish blue", 80, 91, 166),
            ("9 moderate red", 193, 90, 99), ("10 purple", 94, 60, 108),
            ("11 yellow green", 157, 188, 64), ("12 orange yellow", 224, 163, 46),
            ("13 blue", 56, 61, 150), ("14 green", 70, 148, 73),
            ("15 red", 175, 54, 60), ("16 yellow", 231, 199, 31),
            ("17 magenta", 187, 86, 149), ("18 cyan", 8, 133, 161),
            ("19 white 9.5", 243, 243, 242), ("20 neutral 8", 200, 200, 200),
            ("21 neutral 6.5", 160, 160, 160), ("22 neutral 5", 122, 122, 122),
            ("23 neutral 3.5", 85, 85, 85), ("24 black 2", 52, 52, 52),
        ]
        return p.map { ($0.0, sceneFromSRGB($0.1, $0.2, $0.3)) }
    }()

    /// 12 hues (every 30°, OKLCh) × 6 rows: chroma 0.04, 0.08, 0.12, 0.16 at mid-grey
    /// lightness, then chroma 0.10 one stop darker and one stop brighter.
    static let hueRing: [(String, RGB)] = {
        let ctx = OKLabTransform.working
        let midL = ctx.toLab(RGB(gray: midGrey)).L
        let darkL = ctx.toLab(RGB(gray: midGrey / 2)).L
        let lightL = ctx.toLab(RGB(gray: midGrey * 2)).L
        let rows: [(String, Double, Double)] = [
            ("C04", midL, 0.04), ("C08", midL, 0.08), ("C12", midL, 0.12),
            ("C16", midL, 0.16), ("C10dark", darkL, 0.10), ("C10light", lightL, 0.10),
        ]
        var out: [(String, RGB)] = []
        for row in rows {
            for k in 0..<12 {
                let hue = Double(k * 30)
                let c = ctx.toRGB(OKLCh(L: row.1, C: row.2, h: hue))
                out.append(("h\(Int(hue)) \(row.0)", RGB(Swift.max(0, c.r), Swift.max(0, c.g),
                                                        Swift.max(0, c.b))))
            }
        }
        return out
    }()

    /// Monk Skin Tone scale (10 tones, sRGB as published) plus the two ColorChecker
    /// skin patches, under the same mid-grey scaling as `colorChecker`.
    static let skinTones: [(String, RGB)] = {
        let hex = ["f6ede4", "f3e7db", "f7ead0", "eadaba", "d7bd96",
                   "a07e56", "825c43", "604134", "3a312a", "292420"]
        var out: [(String, RGB)] = hex.enumerated().map { i, s in
            let v = Int(s, radix: 16)!
            return ("monk\(i + 1)", sceneFromSRGB(Double(v >> 16), Double((v >> 8) & 255),
                                                  Double(v & 255)))
        }
        out.append(("cc dark skin", sceneFromSRGB(115, 82, 68)))
        out.append(("cc light skin", sceneFromSRGB(194, 150, 130)))
        return out
    }()

    // MARK: - Detail

    /// Left half: a horizontal frequency chirp (top) and fine line pairs (bottom).
    /// Right half: hard high-contrast and low-contrast step edges with flat sides,
    /// where halos and clarity show. Patches sit on the flats beside each edge.
    static func detail(_ w: Int, _ h: Int) -> Chart {
        var image = ImageBuffer(width: w, height: h)
        let lo = midGrey / 4, hi = midGrey * 3
        for y in 0..<h {
            let v = (Double(y) + 0.5) / Double(h)
            for x in 0..<w {
                let u = (Double(x) + 0.5) / Double(w)
                var value = midGrey
                if u < 0.5 {
                    if v < 0.5 {
                        // Chirp: period from 64 px down to 2 px across the quarter.
                        let t = u / 0.5
                        let px = Double(x)
                        let phase = 2 * Double.pi * px / (64 * pow(1.0 / 32, t))
                        value = midGrey * exp2(1.5 * sin(phase))
                    } else {
                        let band = Int(v * 8) % 2
                        let period = band == 0 ? 2 : 4
                        value = (x / (period / 2)) % 2 == 0 ? lo : hi
                    }
                } else {
                    if v < 0.5 {
                        value = u < 0.75 ? lo : hi
                    } else {
                        value = u < 0.75 ? midGrey * 0.8 : midGrey * 1.25
                    }
                }
                image[x, y] = RGB(gray: value)
            }
        }
        let patches = [
            RenderLabPatch(name: "hi-edge dark side", x: 0.68, y: 0.1, w: 0.06, h: 0.3, scene: RGB(gray: lo)),
            RenderLabPatch(name: "hi-edge light side", x: 0.76, y: 0.1, w: 0.06, h: 0.3, scene: RGB(gray: hi)),
            RenderLabPatch(name: "hi-edge dark far", x: 0.52, y: 0.1, w: 0.1, h: 0.3, scene: RGB(gray: lo)),
            RenderLabPatch(name: "hi-edge light far", x: 0.88, y: 0.1, w: 0.1, h: 0.3, scene: RGB(gray: hi)),
            RenderLabPatch(name: "lo-edge dark side", x: 0.68, y: 0.6, w: 0.06, h: 0.3,
                           scene: RGB(gray: midGrey * 0.8)),
            RenderLabPatch(name: "lo-edge light side", x: 0.76, y: 0.6, w: 0.06, h: 0.3,
                           scene: RGB(gray: midGrey * 1.25)),
            RenderLabPatch(name: "chirp coarse", x: 0.0, y: 0.05, w: 0.12, h: 0.4, scene: nil),
            RenderLabPatch(name: "chirp fine", x: 0.38, y: 0.05, w: 0.12, h: 0.4, scene: nil),
            RenderLabPatch(name: "lines 1px", x: 0.05, y: 0.5, w: 0.4, h: 0.125, scene: nil),
            RenderLabPatch(name: "lines 2px", x: 0.05, y: 0.625, w: 0.4, h: 0.125, scene: nil),
        ]
        return Chart(name: "detail", image: image, patches: patches)
    }

    // MARK: - Gradients (banding)

    /// Three smooth bands: a shallow grey ramp (0.6 stop over the width), a sky-like
    /// blue-to-cyan ramp, and a dark ramp in the shadows (−6…−4 EV).
    static func gradient(_ w: Int, _ h: Int) -> Chart {
        let sky0 = sceneFromSRGB(70, 110, 170), sky1 = sceneFromSRGB(150, 195, 225)
        let image = ImageBuffer(width: w, height: h) { u, v in
            if v < 1.0 / 3 { return RGB(gray: midGrey * exp2(-0.3 + 0.6 * u)) }
            if v < 2.0 / 3 { return sky0 * (1 - u) + sky1 * u }
            return RGB(gray: midGrey * exp2(-6 + 2 * u))
        }
        let third = 1.0 / 3
        let patches = [
            RenderLabPatch(name: "grey ramp mid", x: 0.4, y: 0.05, w: 0.2, h: third - 0.1, scene: RGB(gray: midGrey)),
            RenderLabPatch(name: "sky ramp mid", x: 0.4, y: third + 0.05, w: 0.2, h: third - 0.1,
                           scene: sky0 * 0.5 + sky1 * 0.5),
            RenderLabPatch(name: "shadow ramp mid", x: 0.4, y: 2 * third + 0.05, w: 0.2, h: third - 0.1,
                           scene: RGB(gray: midGrey * exp2(-5))),
        ]
        return Chart(name: "gradient", image: image, patches: patches)
    }

    // MARK: - Point lights (halation, highlight handling)

    /// Dark surround (−4 EV) with small discs at +3, +5 and +7 EV over mid-grey, white
    /// and warm, plus one large clipped window. Patches sit on the dark ring around
    /// each light, where halation lands.
    static func pointLights(_ w: Int, _ h: Int) -> Chart {
        let dark = RGB(gray: midGrey / 16)
        let r = Double(Swift.min(w, h)) * 0.02
        var lights: [(x: Double, y: Double, radius: Double, c: RGB)] = []
        let evs = [3.0, 5.0, 7.0]
        for (i, ev) in evs.enumerated() {
            let x = (Double(i) + 0.5) / Double(evs.count)
            lights.append((x, 0.3, r, RGB(gray: midGrey * exp2(ev))))
            lights.append((x, 0.62, r, RGB(1.0, 0.7, 0.35) * (midGrey * exp2(ev))))
        }
        let image = ImageBuffer(width: w, height: h) { u, v in
            let px = u * Double(w), py = v * Double(h)
            for l in lights {
                let dx = px - l.x * Double(w), dy = py - l.y * Double(h)
                if dx * dx + dy * dy <= l.radius * l.radius { return l.c }
            }
            if v > 0.82, u > 0.3, u < 0.7 { return RGB(gray: midGrey * exp2(6)) }
            return dark
        }
        var patches: [RenderLabPatch] = []
        let ring = 4 * r / Double(w), ringH = 4 * r / Double(h)
        for (i, ev) in evs.enumerated() {
            let x = (Double(i) + 0.5) / Double(evs.count)
            patches.append(RenderLabPatch(name: "ring white +\(Int(ev))", x: x + ring * 0.6, y: 0.3 - ringH / 2,
                                          w: ring, h: ringH, scene: dark))
            patches.append(RenderLabPatch(name: "ring warm +\(Int(ev))", x: x + ring * 0.6, y: 0.62 - ringH / 2,
                                          w: ring, h: ringH, scene: dark))
        }
        patches.append(RenderLabPatch(name: "surround", x: 0.02, y: 0.45, w: 0.1, h: 0.08, scene: dark))
        patches.append(RenderLabPatch(name: "window edge below", x: 0.4, y: 0.74, w: 0.2, h: 0.06, scene: dark))
        return Chart(name: "pointLights", image: image, patches: patches)
    }

    // MARK: - Flat grey

    /// Uniform mid-grey; patches at the centre, corners and edge midpoints read
    /// vignette (mean) and grain (stdev).
    static func flatGrey(_ w: Int, _ h: Int) -> Chart {
        let image = ImageBuffer(width: w, height: h) { _, _ in RGB(gray: midGrey) }
        let s = 0.12
        let spots: [(String, Double, Double)] = [
            ("centre", 0.5, 0.5), ("top-left", 0.06, 0.06), ("top-right", 0.94, 0.06),
            ("bottom-left", 0.06, 0.94), ("bottom-right", 0.94, 0.94),
            ("top", 0.5, 0.06), ("bottom", 0.5, 0.94), ("left", 0.06, 0.5), ("right", 0.94, 0.5),
        ]
        let patches = spots.map { name, cx, cy in
            RenderLabPatch(name: name, x: Swift.min(1 - s, Swift.max(0, cx - s / 2)),
                           y: Swift.min(1 - s, Swift.max(0, cy - s / 2)), w: s, h: s,
                           scene: RGB(gray: midGrey))
        }
        return Chart(name: "flatGrey", image: image, patches: patches)
    }
}

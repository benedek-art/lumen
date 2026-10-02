// InspectionGain.swift
// What `[` and `]` actually do to the picture (docs/10 §10.5).
//
// The holds are a DISPLAY transform, not an edit. `InspectionHolds.gain` says how much
// light to multiply by; this applies it to the proxy already on screen and hands back
// another image to draw. Nothing here touches a `Recipe`, nothing is persisted, and
// releasing the key draws the untouched image again — which is the whole difference
// between an inspection and the "drag Shadows, look, drag it back" ritual it replaces.
//
// Linear light, and it matters. The displayed proxy is sRGB-encoded; multiplying its
// code values would lift the shadows by the wrong amount and shift hue while doing it.
// `CIExposureAdjust` is a linear-light multiply, and Core Image converts into and out
// of its linear working space around it, so the gain lands where an exposure move
// belongs. On a Lumen-rendered proxy that makes the boost exact; on a frame that fell
// back to the camera's embedded preview it is approximate for the same reason
// everything else about that frame is, and the viewer already carries the EMBEDDED
// PREVIEW badge that says so.
//
// A small memo, because the gain is applied inside a view body and the body runs far
// more often than the key changes. Key-down transforms once per plate; every redraw after
// it hits the cache; key-up drops it.
//
// SEVERAL ENTRIES, NOT ONE, and key-up genuinely drops them (W2/H1-06, the half of K-031
// the row did not name). The memo was one entry deep, keyed on the image's identity, and
// every surface that shows the hold shows MORE than one plate — split before/after,
// two-pane before/after, Compare's two panes. The plates alternated through the single
// slot at a 100% miss rate: a full-extent Core Image pass per plate per body pass, on the
// main thread, for as long as the key was held. And the nil-hold path returned before
// touching the memo, so after key-up it kept two full-resolution frames resident for the
// life of the process under a header that said key-up dropped them.

#if os(macOS)

import CoreGraphics
import CoreImage
import Foundation
import LumenCore

/// Deliberately NOT `@MainActor`. The call sites are `plate(_:ratio:drawn:)` in the loupe
/// and the two in Compare — plain methods on a `View`, which are nonisolated even though
/// `body` is not, so a main-actor member would be unreachable from exactly the three
/// places that need it. Every one of those call sites runs while SwiftUI is evaluating a
/// body, which is the main thread; the memo is not shared with anything else, and the
/// worst a race could cost is one wasted filter pass.
enum InspectionGain {

    private static let context: CIContext = CIContext()
    private static var memo = InspectionGainMemo<CGImage>()

    /// The image to draw for a given hold. Nil hold, or a transform that fails, draws
    /// the original — an inspection that cannot be computed shows the picture as it is
    /// rather than nothing at all.
    static func displayed(_ image: CGImage, hold: InspectionHold?) -> CGImage {
        memo.value(for: image, hold: hold) { apply($1, to: $0) }
    }

    private static func apply(_ hold: InspectionHold, to image: CGImage) -> CGImage? {
        // The EV comes from the rule, sign included, so this file cannot lift the
        // shadows when the user asked to inspect the highlights.
        let ev: Double = InspectionHolds.ev(hold)
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIExposureAdjust") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: ev), forKey: kCIInputEVKey)
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: input.extent)
    }
}

/// The memo behind `InspectionGain.displayed`, as a value a test can drive without
/// Core Image: identity-keyed on the source plate, most recently used first, bounded,
/// and EMPTIED by the first nil-hold call so key-up releases every frame it held.
///
/// Eight entries: enough for every surface that shows the hold to hit on every plate it
/// draws (split and two-pane before/after are two, Compare is two, a modest survey grid
/// fits), and a ceiling on what a held key can pin — eight display-sized frames, for as
/// long as the key is down and not a moment longer.
struct InspectionGainMemo<Plate: AnyObject> {
    static var capacity: Int { 8 }

    private(set) var entries: [(source: Plate, hold: InspectionHold, result: Plate)] = []

    mutating func value(for source: Plate, hold: InspectionHold?,
                        make: (Plate, InspectionHold) -> Plate?) -> Plate {
        guard let hold else {
            if !entries.isEmpty { entries.removeAll() }
            return source
        }
        if let i = entries.firstIndex(where: { $0.source === source && $0.hold == hold }) {
            let hit = entries.remove(at: i)
            entries.insert(hit, at: 0)
            return hit.result
        }
        guard let made = make(source, hold) else { return source }
        entries.insert((source, hold, made), at: 0)
        if entries.count > Self.capacity {
            entries.removeLast(entries.count - Self.capacity)
        }
        return made
    }
}

#endif

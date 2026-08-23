// DraftResolution.swift
// How many pixels the draft pass may render, given that at some zoom rungs the
// photograph's size on screen is decided by that number.
//
// The second half of the owner's "lots of zoom in, zoom out things that happen when
// I'm not pressed on the image". Nothing moves `zoomLevel` here at all — the picture
// changes size while the zoom state sits still, which is why looking for a stray
// gesture would never have found it.
//
// The mechanism. The viewer draws a frame at `pixels × ratio ÷ displayScale`, where
// `pixels` is the extent of the PROXY it happens to be holding. At fit that is
// harmless: the fit ratio is itself derived from the same extent, the two cancel, and
// a proxy of any size draws at exactly the container. Above fit they do not cancel —
// `ratio` is a fixed number and `pixels` is whatever came back — so the drawn size is
// directly proportional to how many pixels the last pass produced.
//
// And the two passes deliberately produce different numbers. Zoomed, the viewer asks
// for a 4096 px settle and the refine driver takes half of it, capped, for the draft:
// 2048. `renderPreview` scales the decode by `maxLongEdge ÷ native`, identically for
// draft and settle, so the draft's extent is exactly half the settle's — and the
// photograph is therefore drawn at exactly half size for the length of the draft, then
// doubles when quality lands. That happens on every render, and during a slider drag a
// render is every mouse event: the frame pumps between half and full size under the
// cursor for the whole gesture.
//
// The rule below is the narrow one: a draft may be as coarse as it likes wherever its
// coarseness is invisible in the geometry, and must match the settle wherever it is
// not. It does not make the draft expensive at fit, which is where a drag normally
// happens, and it does not change what either pass renders — only how many pixels the
// cheap one is asked for.

import Foundation

public enum DraftResolution {

    /// True when the frame's size on screen is decided by the proxy's pixel count
    /// rather than by the container.
    ///
    /// This is the whole of it. Fit normalizes — the ratio is computed from the same
    /// extent it is then multiplied by — so the proxy's resolution shows up as
    /// sharpness and nothing else. Every rung above fit multiplies a fixed ratio by
    /// whatever extent arrived, so the resolution shows up as SIZE.
    public static func sizeFollowsProxyPixels(zoomRatio: Double) -> Bool {
        !ZoomLadder.isFit(zoomRatio)
    }

    /// The long edge the draft pass may be asked for.
    ///
    /// `fitLongEdge` is the viewer's own lower bound for a draft — the value it uses
    /// at fit, where a coarse draft costs sharpness for a few tens of milliseconds and
    /// nothing else. Zoomed, the answer is the settle's own long edge, because any
    /// smaller number is a visible change of size rather than of sharpness.
    public static func draftLongEdge(settledLongEdge: Int, fitLongEdge: Int,
                                     zoomRatio: Double) -> Int {
        guard sizeFollowsProxyPixels(zoomRatio: zoomRatio) else { return fitLongEdge }
        return Swift.max(fitLongEdge, settledLongEdge)
    }

    /// The on-screen long edge, in points, of a proxy drawn at `zoomRatio`.
    ///
    /// Only meaningful above fit, which is exactly where the defect lives; it is here
    /// so the size difference between two passes can be stated as a number rather than
    /// described.
    public static func drawnLongEdge(proxyLongEdge: Int, zoomRatio: Double,
                                     displayScale: Double) -> Double {
        let scale = Swift.max(displayScale, 1)
        guard proxyLongEdge > 0, zoomRatio.isFinite, zoomRatio > 0, scale > 0 else {
            return 0
        }
        return Double(proxyLongEdge) * zoomRatio / scale
    }
}

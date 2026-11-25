// ContinuousZoom.swift
// The two numbers the continuous zoom gestures share. The gestures themselves —
// anchoring, the fit floor, the pan limit — are `ViewerViewport`.

import Foundation

public enum ContinuousZoom {

    /// A continuous zoom that ENDS within this factor above fit becomes fit, so a
    /// pinch released a hair above fit does not leave the viewer zoomed with nothing
    /// to show for it. It applies when the hand leaves, never while it is moving.
    public static let fitSnapSlack: Double = 1.02

    /// The long edge a zoomed render asks for: the cap, or the frame's own pixels
    /// when the photograph is smaller. Nil native (not yet known) assumes the cap.
    public static func zoomedFullLongEdge(nativeLongEdge: Int?, renderCap: Int) -> Int {
        guard let nativeLongEdge, nativeLongEdge > 0 else { return renderCap }
        return Swift.min(renderCap, nativeLongEdge)
    }
}

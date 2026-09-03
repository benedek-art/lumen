// SharpeningFrameTests.swift
//
// The guard on the sharpening proof frames' SIZE, which is the half of E2-04 that a
// green suite hid.
//
// Sharpening's radius is denominated in the frame — `SpatialOps.frameDenominatedSigma`,
// `radius × longEdge / 2560` — so the frame a sharpen control is swept on decides
// whether the stage runs at all. On the 128 px `stepEdge` the five records used, the
// whole of Radius's 0.5…3.0 travel scaled to σ = 0.025…0.15, `SpatialOps.gaussianBlur`
// returned the plane untouched below its own `sigma > 0.05` floor, and every render in
// the sweep came out byte-identical: authority 0.0000 with 20 dead steps, on controls
// that work. The frame was answering a question it could not express.
//
// Same class of mistake as `testTheFilmGateFramesAreBigEnoughForTheirKernels` next door
// — halation's 65 µm bounce at 0.23 px, grain's cell under the half-pixel floor — and
// the same fix: state the arithmetic here, against the registry's own frames, so that
// shrinking a frame fails with the number instead of going quietly green.

import Foundation
import XCTest
@testable import LumenCore

final class SharpeningFrameTests: XCTestCase {

    /// The radii a spec's sweep actually reaches, taken from the registry's own `apply`
    /// rather than written down — a sweep that stops pushing Radius, or a panel range
    /// that moves, has to show up here as a different number and not as a stale constant.
    private func radiusTravel(_ spec: ControlSpec) -> (low: Double, high: Double) {
        var atLow = Recipe()
        spec.apply(&atLow, spec.low)
        var atHigh = Recipe()
        spec.apply(&atHigh, spec.high)
        let a = Num.clamp(atLow.develop.detail.sharpen.radius, 0.5, 3.0)
        let b = Num.clamp(atHigh.develop.detail.sharpen.radius, 0.5, 3.0)
        return (Swift.min(a, b), Swift.max(a, b))
    }

    func testTheSharpeningProofFramesAreBigEnoughForTheRadiusTheySweep() {
        for spec in ProofRegistry.sharpen {
            let frame = spec.frame()
            let longEdge = Swift.max(frame.width, frame.height)
            let travel = radiusTravel(spec)
            let smallest = SpatialOps.frameDenominatedSigma(radius: travel.low,
                                                            longEdge: longEdge)
            let largest = SpatialOps.frameDenominatedSigma(radius: travel.high,
                                                           longEdge: longEdge)

            // THE ENGINE'S OWN FLOOR, restated rather than called: below `sigma > 0.05`
            // `SpatialOps.gaussianBlur` returns the plane untouched, so the unsharp half
            // of the stage does not run and the sweep measures the fine band alone.
            XCTAssertGreaterThan(
                smallest, 0.05,
                "\(spec.id) is swept on \(spec.frameName) at \(longEdge) px, where the "
                    + "bottom of its Radius travel scales to a sigma of \(smallest) — "
                    + "under `SpatialOps.gaussianBlur`'s own support floor, so those "
                    + "renders come back byte-identical and the record reads a dead "
                    + "control that works")

            // AND FAR ENOUGH ABOVE IT TO BE A BLUR. Clearing 0.05 is not the same as
            // having support: at σ = 0.1 an exact Gaussian gives its immediate
            // neighbour exp(−1/(2·0.01)) ≈ 2e-22 of the centre weight, which is a
            // rounding difference wearing a blur's name. At σ = 0.5 that neighbour
            // carries exp(−1/(2·0.25)) = 13.5%, which is where the operator starts
            // moving light between pixels. The sibling test upstairs makes the same
            // argument for halation's first bounce and puts its bar at two pixels.
            XCTAssertGreaterThanOrEqual(
                largest, 0.5,
                "\(spec.id)'s widest sigma on \(spec.frameName) is \(largest) px at "
                    + "\(longEdge) px of frame — a Gaussian that cannot reach its own "
                    + "neighbour, so the sweep is reading the fine band and calling it "
                    + "sharpening")
        }
    }
}

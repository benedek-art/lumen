// ProofFrameTests.swift
//
// The proof frames and the evidence writer are measuring instruments, and an instrument
// nobody calibrated is a source of confident wrong answers. These tests check the
// instruments themselves, not the engine: that each frame actually contains the thing
// its consumers sweep on, and that the PNG writer emits a file a viewer can open.
//
// docs/19 recorded three "dead control" readings that were the probe's fault. This file
// is the standing answer to that class of mistake.

import XCTest
import LumenCore

final class ProofFrameTests: XCTestCase {

    // MARK: - The frames contain their subject

    func testTheNeutralRampSpansTheDeclaredExposureRange() {
        let frame = ProofFrames.neutralRamp()
        let first = frame[0, 0].r, last = frame[frame.width - 1, 0].r
        // −8…+5 EV around mid-grey, minus half a pixel at each end.
        XCTAssertEqual(log2(first / ProofFrames.midGrey), -8, accuracy: 0.1)
        XCTAssertEqual(log2(last / ProofFrames.midGrey), 5, accuracy: 0.1)
        // Strictly increasing, or a tone proof cannot read a direction off it.
        for x in 1..<frame.width {
            XCTAssertGreaterThan(frame[x, 0].r, frame[x - 1, 0].r)
        }
    }

    func testTheColourChartAnchorsNeutralFiveOnMidGrey() {
        let frame = ProofFrames.colourChart()
        let p = ProofFrames.chartPatchCentre(22)
        let c = frame[p.x, p.y]
        // Neutral 5 is the chart's own 18% patch; the whole frame is scaled onto it.
        XCTAssertEqual(c.r, ProofFrames.midGrey, accuracy: 0.005)
        XCTAssertEqual(c.g, ProofFrames.midGrey, accuracy: 0.005)
        XCTAssertEqual(c.b, ProofFrames.midGrey, accuracy: 0.005)
    }

    func testTheColourChartCarriesTwoRealSkinTones() {
        let frame = ProofFrames.colourChart()
        let ctx = OKLabTransform.working
        // Patches 1 and 2 are dark and light skin. Both must land in the hue band the
        // skin tools claim to act on — if they do not, every skin proof is measuring
        // something that is not skin, which is the exact failure `skinLineDegrees` had.
        for patch in [1, 2] {
            let p = ProofFrames.chartPatchCentre(patch)
            let lch = ctx.toLCh(frame[p.x, p.y])
            XCTAssertGreaterThan(lch.C, 0.02, "patch \(patch) has no chroma to have a hue")
            let hue = Num.wrapHue(lch.h)
            XCTAssertTrue((10...70).contains(hue),
                          "patch \(patch) sits at \(hue)°, outside the skin band")
        }
    }

    func testTheStepEdgeIsFourStopsAndHard() {
        let frame = ProofFrames.stepEdge()
        let left = frame[frame.width / 4, frame.height / 2].r
        let right = frame[3 * frame.width / 4, frame.height / 2].r
        XCTAssertEqual(log2(right / left), 4, accuracy: 0.01)
        // Hard: the transition occupies one pixel, so an overshoot metric has an
        // unambiguous plateau on each side to measure against.
        let mid = frame.width / 2
        XCTAssertEqual(frame[mid - 1, 0].r, left, accuracy: 1e-9)
        XCTAssertEqual(frame[mid, 0].r, right, accuracy: 1e-9)
    }

    func testFineTextureCarriesFourDistinctFrequencies() {
        let frame = ProofFrames.fineTexture()
        // Each strip must actually modulate, or a band-selective control measured on it
        // reports dead for the strips that do not.
        for strip in 0..<4 {
            let x0 = strip * frame.width / 4, x1 = (strip + 1) * frame.width / 4
            var lo = Double.infinity, hi = -Double.infinity
            for x in x0..<x1 {
                lo = Swift.min(lo, frame[x, 0].r); hi = Swift.max(hi, frame[x, 0].r)
            }
            XCTAssertGreaterThan(hi / lo, 1.2, "strip \(strip) is flat")
        }
    }

    func testTheNoisyFrameIsNoisyAndItsTwinIsNot() {
        let noisy = ProofFrames.noisyISO6400()
        let clean = ProofFrames.cleanISO6400()
        XCTAssertEqual(noisy.width, clean.width)
        // The noise has to be big enough to measure a denoiser against.
        let rms = ProofMetrics.rmsAgainst(clean, noisy)
        XCTAssertGreaterThan(rms, 1.0, "ISO 6400 frame carries \(rms) code values of noise")
        XCTAssertLessThan(rms, 60.0, "noise this large is not a photograph")
        // Deterministic: a record cannot be committed against a frame that moves.
        XCTAssertEqual(ProofMetrics.rmsAgainst(ProofFrames.noisyISO6400(), noisy), 0,
                       accuracy: 1e-12)
    }

    func testTheCleanFrameIsNotFlat() {
        // A denoiser that smooths everything scores perfectly against a flat truth.
        let clean = ProofFrames.cleanISO6400()
        var lo = Double.infinity, hi = -Double.infinity
        for x in 0..<clean.width {
            lo = Swift.min(lo, clean[x, clean.height / 2].r)
            hi = Swift.max(hi, clean[x, clean.height / 2].r)
        }
        XCTAssertGreaterThan(hi / lo, 1.2, "the denoise ground truth has no detail in it")
    }

    func testTheHazyFrameInvertsToItsKnownAirlight() {
        let frame = ProofFrames.hazySky()
        // At the top of the frame transmission is lowest, so the pixel sits closest to
        // pure airlight. This is the ground truth a dehaze proof scores against.
        let top = frame[frame.width / 2, 0]
        let a = ProofFrames.hazySkyAirlight
        XCTAssertEqual(top.b / top.r, a.b / a.r, accuracy: 0.25,
                       "the veil at the top of the frame is not the airlight's colour")
    }

    func testTheHazyFrameCarriesASmoothSteepGradient() {
        // The case that has twice reverted the Texture port: a ramp a structure tensor
        // reads as coherent almost everywhere. If this frame stops being a smooth ramp,
        // the gate proof silently stops testing the thing it exists for.
        let frame = ProofFrames.hazySky()
        let column = frame.width / 2
        let rows = 1..<Int(Double(frame.height) * 0.55)
        // Monotone in EITHER direction. The physical answer is decreasing — haze
        // brightens a sky toward the horizon, so the veiled top is the bright end — and
        // the first version of this assertion hard-coded "increasing" and failed on a
        // correct frame. What the Texture gate needs from this frame is a smooth ramp,
        // not a particular sign.
        var rising = true, falling = true
        var previous = frame[column, 0].g
        for y in rows {
            let now = frame[column, y].g
            if now < previous - 1e-9 { rising = false }
            if now > previous + 1e-9 { falling = false }
            previous = now
        }
        XCTAssertTrue(rising || falling, "the sky half is no longer a monotone ramp")
        // And steep enough that a structure tensor reads real coherence off it.
        let top = frame[column, 0].g, bottom = frame[column, rows.upperBound - 1].g
        XCTAssertGreaterThan(abs(top - bottom), 0.05,
                             "the sky ramp is too shallow to exercise the gate")
    }

    func testTheHotPixelFrameHasSpikesOfBothPolaritiesAndALineToSpare() {
        let frame = ProofFrames.hotPixels()
        for site in ProofFrames.hotPixelSites {
            let here = frame[site.x, site.y].r
            let neighbour = frame[site.x + 1, site.y].r
            if site.hot {
                XCTAssertGreaterThan(here / neighbour, 5, "spike at \(site) is not hot")
            } else {
                XCTAssertLessThan(here / neighbour, 0.2, "spike at \(site) is not dark")
            }
        }
        // The one-pixel line a median must not eat.
        let x = frame.width / 3
        XCTAssertGreaterThan(frame[x, frame.height / 2].r / frame[x + 2, frame.height / 2].r,
                             1.5, "the survivable one-pixel line is missing")
    }

    func testTheChromaEdgeIsChromaOnly() {
        let frame = ProofFrames.chromaEdge()
        let ctx = OKLabTransform.working
        let left = ctx.toLCh(frame[frame.width / 4, frame.height / 2])
        let right = ctx.toLCh(frame[3 * frame.width / 4, frame.height / 2])
        // Same brightness, different hue — so a luminance change measured across it is
        // the operation's doing and not the frame's.
        XCTAssertEqual(left.L, right.L, accuracy: 0.06,
                       "the two sides differ in lightness, so this is not a chroma edge")
        var hueGap = abs(Num.wrapHue(right.h - left.h))
        if hueGap > 180 { hueGap = 360 - hueGap }
        XCTAssertGreaterThan(hueGap, 90, "the two sides are not far enough apart in hue")
        XCTAssertGreaterThan(left.C, 0.05)
        XCTAssertGreaterThan(right.C, 0.05)
    }

    // MARK: - The evidence writer

    func testEveryProofFrameRendersAndWritesAReadablePNG() throws {
        let frames: [(String, ImageBuffer)] = [
            ("neutral-ramp", ProofFrames.neutralRamp()),
            ("colour-chart", ProofFrames.colourChart()),
            ("step-edge", ProofFrames.stepEdge()),
            ("fine-texture", ProofFrames.fineTexture()),
            ("noisy-iso6400", ProofFrames.noisyISO6400()),
            ("clean-iso6400", ProofFrames.cleanISO6400()),
            ("hazy-sky", ProofFrames.hazySky()),
            ("hot-pixels", ProofFrames.hotPixels()),
            ("chroma-edge", ProofFrames.chromaEdge()),
        ]
        let plan = RenderPlan(recipe: Recipe())
        for (name, frame) in frames {
            let rendered = ReferenceRenderer.render(frame, plan: plan)
            let url = try ProofEvidence.write(rendered, named: "frame-\(name)")
            let data = try Data(contentsOf: url)
            XCTAssertGreaterThan(data.count, 100, "\(name) wrote an empty PNG")
            XCTAssertEqual(Array(data.prefix(8)),
                           [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
                           "\(name) is not a PNG")
        }
    }
}

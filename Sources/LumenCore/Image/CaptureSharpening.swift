// CaptureSharpening.swift
// S4 — capture sharpening: Lumen's own Richardson–Lucy deconvolution, as a stage the
// plan carries (D24, docs/06 §11.1).
//
// WHY LUMEN'S OWN AND NOT APPLE'S. Until this file the only capture sharpening in the
// app was `CIRAWFilter.sharpnessAmount`, scaled by the toggle. That had four costs the
// panel could not hide:
//
//   · it ran INSIDE the decode, upstream of S3, so the profiled denoise was handed a
//     frame whose noise had already been sharpened — the noise model S3 is denominated
//     in stopped being true before S3 ever saw a pixel;
//   · `detail.capture.radius` had no reader at all (Apple's sharpener takes one scalar);
//   · nothing on Linux or in `ReferenceRenderer` could render or measure it, so the
//     stage was the one part of the picture no proof could reach;
//   · its behaviour is whatever this macOS release's decoder does, unpinned.
//
// So the decoder's sharpener is now held at zero (`AppleRawSource`) and this stage runs
// where docs/14 puts S4: immediately after S3, on the cleanest estimate of the optical
// image, in BOTH renderers (`RenderGraph.applyCaptureSharpen` is the GPU twin, built from
// the same constants and the same discrete taps).
//
// THE ALGORITHM, and why each piece is there:
//
//   1. Richardson–Lucy on luminance, `iterations` rounds against a Gaussian PSF of σ
//      decode pixels, with a fixed 13-tap discrete kernel both renderers share. RL is a
//      deconvolution: it restores what the optics and the demosaic took, rather than
//      adding an unsharp mask's fixed overshoot.
//   2. An overshoot clamp in log2 luminance that separates EDGES from TEXTURE. The
//      sharpened value may not leave the 3×3 neighbourhood's [min, max] — which is what
//      a halo is — EXCEPT at a pixel that is a genuine one-dimensional peak or trough
//      along some direction (one pixel, or one of a two-pixel ridge), where it may
//      extend by `peakAllowance` × how far that peak stands above its neighbours. Gate
//      and Amount scale the correction BEFORE this clamp, so no setting can get past
//      it. A step edge has no such pixel (along every direction one neighbour is the
//      plateau), so a step edge gets 0 % overshoot; a twig, a
//      leaf vein or a zone-plate ring is a ridge, and keeps its restored amplitude.
//      Measured on a σ 1.0 blurred slanted edge: overshoot 8.9 % → 0.0 % against the
//      unclamped deconvolution, MTF50 within 1 %. A plain range-relative clamp could
//      not do both: tight enough to kill halos it also removed 70 % of the zone plate's
//      gain.
//   3. A noise gate that is a statement about the SENSOR, not a tuned constant. The
//      luminance goes through the generalized Anscombe transform for this ISO's noise
//      profile (the one S3 uses), so noise has unit σ everywhere from shadow to
//      highlight; the gate is the window-averaged gradient magnitude of that plane,
//      with knees in units of that σ (`gateLow`/`gateHigh` say why). Flat areas — sky,
//      skin, a grey card — are therefore never sharpened at any ISO, and an edge opens
//      the gate as soon as it stands clear of the noise.
//   4. Recombination as an RGB ratio (one multiply per pixel), so a sharpened edge
//      cannot fringe or shift hue.
//
// RAW ONLY, by construction: a plan built without a capture ISO is identity. Every
// rendered source (`RenderedImageSource`) reports `iso: nil` — a JPEG has no sensor
// noise model left and was sharpened in the camera — and every RAW source reports the
// file's ISO. That is the same signal S3 selects its profile from.
//
// SCALE. σ is the optics' blur in NATIVE sensor pixels. A decode at linear scale s has
// a σ·s blur and a variance s² of the native one, so `scaled(decodeScale:)` carries
// both; below `minimumSigma` decode pixels the downsample has already removed more blur
// than the deconvolution could, and the stage does not run (fit view). 1:1 and export
// are at s = 1.

import Foundation

public struct CaptureStage: Sendable, Equatable {

    /// Multiplier on the deconvolution's log-luminance correction: `strengthFraction`,
    /// 0…`CaptureSharpen.maxStrength`.
    public let strength: Double
    /// PSF σ in the pixels of the buffer this stage will run on.
    public let sigma: Double
    /// The sensor noise model in the same buffer's units.
    public let profile: NoiseProfile

    /// RL rounds. docs/06 §11.1 says 8; measured, 8 recovers 85 % of what 12 does on a
    /// σ 1.0 edge (MTF50 0.257 vs 0.266 cyc/px at σ 0.8) at two thirds of the cost.
    public static let iterations = 8
    /// The native-pixel PSF σ used when the recipe pins no radius.
    ///
    /// A stated default, not a measurement: `SpatialOps.estimatePSFSigma` returned 0.78
    /// on a noisy ISO 3200 fabric crop (noise reads as sharp peaks) and 1.58 on a target
    /// blurred by σ 1.0 — it cannot be trusted to pick the radius, and an estimate the
    /// GPU graph cannot reproduce would split the two renderers anyway. 0.8 sits under
    /// what modern AA-filtered bodies with a good demosaic deliver (0.8–1.0), which is
    /// the safe side: an under-sized PSF under-sharpens, an over-sized one rings.
    public static let defaultRadius: Double = 0.8
    /// Below this σ in decode pixels the stage is the identity.
    public static let minimumSigma: Double = 0.3
    /// How far a genuine peak or trough may be extended past the observed 3×3 range, as
    /// a multiple of how far it already stands above (below) its neighbours.
    public static let peakAllowance: Double = 1.0
    /// The gate's averaging window: three radius-1 box passes per axis on the GPU,
    /// `SpatialOps.boxApproximatedGaussian(_, sigma: 1.5)` here (the pair
    /// `testEdgeMapMatchesTheReference` already pins as one operator).
    public static let gateBlurSigma: Double = 1.5
    /// Gate knees on the window-averaged gradient MAGNITUDE of the variance-stabilized
    /// luminance, so in units of the noise σ. Pure noise at the profile's own level
    /// averages 0.88 and peaks at 1.56 (measured, 512² flat field, ISO 100 and 6400
    /// seed profiles alike — the transform makes them the same). Real bodies run
    /// noisier than the generic seed profile: 1.25–1.75× on the G9 ISO 3200 frame's
    /// flat wall and 2–4× on its fabric. The first cut (2.5/4.5) opened on that
    /// fabric and the verifier measured isolated bright specks up ~7× with default
    /// capture sharpening; 4/7 keeps a sensor ~2.5× noisier than its profile shut, at
    /// a cost of 0.05 in acutance gain on the ISO 250 A7 IV crop (1.34× → 1.28×).
    ///
    /// Why the gradient is averaged rather than the plane blurred first (which is what
    /// the denoise's edge map does): blurring by σ 1.5 first removes 94 % of a 4 px
    /// grating's amplitude, so the gate never opened on exactly the fine texture
    /// capture sharpening exists for — a blurred 4 px grating took 0 % gain.
    /// Averaging |∇| keeps the texture's energy and still averages the noise down.
    public static let gateLow: Double = 4
    public static let gateHigh: Double = 7
    /// The most the stage may move a pixel, in EV.
    public static let limitEV: Double = 2
    /// Floor under luminance before the log, the same order as RL's own division floor.
    public static let logFloor: Double = 1e-6
    /// Half-width of the discrete Gaussian both renderers use: 13 taps, ≥ 3σ at the
    /// 2.0 px ceiling.
    public static let tapRadius = 6

    public init(strength: Double, sigma: Double, profile: NoiseProfile) {
        self.strength = strength.isFinite ? Num.clamp(strength, 0, CaptureSharpen.maxStrength) : 0
        self.sigma = sigma.isFinite ? sigma : 0
        self.profile = profile
    }

    /// The stage a recipe asks for at native scale. `captureISO == nil` — a rendered
    /// file — is the identity whatever the recipe says.
    public init(capture: CaptureSharpen, captureISO: Double?) {
        guard let iso = captureISO else {
            self.init(strength: 0, sigma: 0, profile: NoiseProfile.forISO(100))
            return
        }
        let r = capture.radius.flatMap { $0.isFinite ? $0 : nil } ?? Self.defaultRadius
        self.init(strength: capture.strengthFraction,
                  sigma: Num.clamp(r, SpatialOps.minPSFSigma, SpatialOps.maxPSFSigma),
                  profile: NoiseProfile.forISO(iso))
    }

    /// True when the stage cannot move a pixel.
    public var isIdentity: Bool { strength <= 0 || sigma < Self.minimumSigma }

    /// The same stage for a decode at linear scale `decodeScale` (≤ 1): the blur
    /// shrinks with the pixel and the noise variance with the area averaged.
    public func scaled(decodeScale: Double) -> CaptureStage {
        let s = (decodeScale.isFinite && decodeScale > 0) ? Swift.min(decodeScale, 1) : 1
        guard s < 1 else { return self }
        return CaptureStage(strength: strength, sigma: sigma * s,
                            profile: NoiseProfile(a: profile.a * s * s, b: profile.b * s * s))
    }

    // MARK: - Shared constants (both renderers read these)

    /// The 7 one-sided weights of the normalized 13-tap Gaussian, centre first. The GPU
    /// kernel is handed exactly these Floats.
    public static func gaussianTaps(sigma: Double) -> [Float] {
        let s = Swift.max(sigma, 1e-3)
        var w = (0...tapRadius).map { i -> Double in exp(-Double(i * i) / (2 * s * s)) }
        let total = w[0] + 2 * w.dropFirst().reduce(0, +)
        w = w.map { $0 / total }
        return w.map { Float($0) }
    }

    // MARK: - Reference implementation

    public func apply(_ image: ImageBuffer, space: RGBColorSpace = .rec2020) -> ImageBuffer {
        guard !isIdentity, image.width >= 3, image.height >= 3 else { return image }
        let w = image.width
        let h = image.height
        let lum = image.luminancePlane(space: space).map { Swift.max($0, 0) }

        let deconvolved = Self.richardsonLucy(lum, taps: Self.gaussianTaps(sigma: sigma),
                                              iterations: Self.iterations)
        let gate = gate(luminance: lum)
        let delta = clampedDelta(observed: lum, deconvolved: deconvolved,
                                      gate: gate, strength: strength)

        var out = image
        for y in 0..<h {
            for x in 0..<w {
                let d = Num.clamp(delta[x, y], -Self.limitEV, Self.limitEV)
                if d == 0 { continue }
                out[x, y] = image[x, y] * exp2(d)
            }
        }
        return out
    }

    /// The gate alone, for tests and for the evidence sheets.
    public func gatePlane(_ image: ImageBuffer, space: RGBColorSpace = .rec2020) -> Plane {
        gate(luminance: image.luminancePlane(space: space).map { Swift.max($0, 0) })
    }

    /// Step 3: smoothstep over the window-averaged |∇| of the VST'd luminance.
    func gate(luminance lum: Plane) -> Plane {
        let v = lum.map { VST.forward($0, profile: profile) }
        var magnitude = Plane(width: v.width, height: v.height)
        for y in 0..<v.height {
            for x in 0..<v.width {
                let gx = (v.clampedSample(x + 1, y) - v.clampedSample(x - 1, y)) * 0.5
                let gy = (v.clampedSample(x, y + 1) - v.clampedSample(x, y - 1)) * 0.5
                magnitude[x, y] = (gx * gx + gy * gy).squareRoot()
            }
        }
        let averaged = SpatialOps.boxApproximatedGaussian(magnitude,
                                                          sigma: Self.gateBlurSigma)
        return averaged.map { Num.smoothstep(Self.gateLow, Self.gateHigh, $0) }
    }

    /// One separable pass of the shared discrete Gaussian, edge-clamped.
    static func blur(_ plane: Plane, taps: [Float], horizontal: Bool) -> Plane {
        let w = plane.width
        let h = plane.height
        var out = Plane(width: w, height: h)
        let r = taps.count - 1
        for y in 0..<h {
            for x in 0..<w {
                var acc = Double(taps[0]) * plane[x, y]
                for i in 1...r {
                    let a = horizontal ? plane.clampedSample(x - i, y)
                                       : plane.clampedSample(x, y - i)
                    let b = horizontal ? plane.clampedSample(x + i, y)
                                       : plane.clampedSample(x, y + i)
                    acc += Double(taps[i]) * (a + b)
                }
                out[x, y] = acc
            }
        }
        return out
    }

    static func blur(_ plane: Plane, taps: [Float]) -> Plane {
        blur(blur(plane, taps: taps, horizontal: true), taps: taps, horizontal: false)
    }

    /// RL against the shared kernel. Same guards as `SpatialOps.richardsonLucy`: the
    /// division is skipped under a floor and the ratio clamped to 8×.
    static func richardsonLucy(_ observed: Plane, taps: [Float], iterations: Int) -> Plane {
        var estimate = observed
        for _ in 0..<iterations {
            let blurred = blur(estimate, taps: taps)
            var ratio = Plane(width: observed.width, height: observed.height)
            for i in 0..<ratio.values.count {
                let b = Double(blurred.values[i])
                let r = b > 1e-7 ? Double(observed.values[i]) / b : 1.0
                ratio.values[i] = Float(Num.clamp(r, 0, 8))
            }
            let correction = blur(ratio, taps: taps)
            for i in 0..<estimate.values.count {
                let v = Double(estimate.values[i]) * Double(correction.values[i])
                estimate.values[i] = Float(Swift.max(v, 0))
            }
        }
        return estimate
    }

    /// The log2 correction, scaled by gate × strength and THEN held by the
    /// edge/texture overshoot clamp (step 2 above). Scaling after the clamp would let
    /// Amount 150 push an edge 50 % past the bound the clamp just set — measured, 2.8 %
    /// overshoot on a blurred edge — so the clamp is the last word.
    ///
    /// "A genuine peak" along a direction is either a one-pixel peak (`c` above both
    /// neighbours) or one pixel of a TWO-pixel ridge (`c` level with one neighbour,
    /// above the pixel beyond it and above the other side). Without the second form a
    /// 4 px grating sampled two-up-two-down reads as a row of step edges and keeps
    /// none of its restored modulation; with it, a step edge still has no peak pixel
    /// (one side is always the plateau), and a plateau three pixels wide is an edge
    /// pair, as it should be. The two-pixel term is discounted by how far the paired
    /// pixel is from level, so the shoulder of a one-pixel peak does not qualify.
    func clampedDelta(observed: Plane, deconvolved: Plane, gate: Plane,
                      strength: Double) -> Plane {
        let w = observed.width
        let h = observed.height
        let lo = observed.map { log2(Swift.max($0, Self.logFloor)) }
        var out = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let c = lo[x, y]
                let n = Self.peakExtents(lo, x, y)
                // A peak earns its allowance only once it stands clear of this ISO's
                // noise: a one-pixel spike of sensor noise IS a one-pixel peak, and on
                // the G9 ISO 3200 fabric the unweighted allowance grew isolated bright
                // specks ~7× (the WS-18 verifier's B1). σ in log2 units at this level.
                let sigma = noiseLog2Sigma(level: observed[x, y])
                let wUp = Num.smoothstep(Self.peakSignificanceLow * sigma,
                                         Self.peakSignificanceHigh * sigma, n.up)
                let wDown = Num.smoothstep(Self.peakSignificanceLow * sigma,
                                           Self.peakSignificanceHigh * sigma, n.down)
                let target = log2(Swift.max(deconvolved[x, y], Self.logFloor))
                let wanted = c + (target - c) * Num.saturate(gate[x, y]) * strength
                out[x, y] = Num.clamp(wanted, n.mn - Self.peakAllowance * wDown * n.down,
                                      n.mx + Self.peakAllowance * wUp * n.up) - c
            }
        }
        return out
    }

    /// A peak must stand this many noise σ (of the PROFILE, which real sensors exceed —
    /// see `gateLow`) above its neighbours before it is extended. 8/16 rather than a
    /// textbook 3/6 for that reason: at 3/6 the G9 ISO 3200 fabric still grew its
    /// specks 3×; at 8/16 the fine detail of the ISO 250 A7 IV frame keeps its gain.
    public static let peakSignificanceLow: Double = 8
    public static let peakSignificanceHigh: Double = 16

    /// The profile's noise σ at a linear level, in log2 units.
    func noiseLog2Sigma(level y: Double) -> Double {
        let v = Swift.max(y, Self.logFloor)
        return profile.sigma(at: v) / (v * 0.6931471805599453)   // ln 2, as the GPU kernel spells it
    }

    /// The range a pixel may move to without drawing a halo: the 3×3 [min, max],
    /// extended by `allowance` × how far the pixel stands proud as a one- or two-pixel
    /// peak (or trough) along any of four directions. Shared by S4 and S12
    /// (`SharpenStage`), and written out the same way in both GPU kernels.
    static func peakBounds(_ p: Plane, _ x: Int, _ y: Int,
                           allowance: Double) -> (lo: Double, hi: Double) {
        let n = peakExtents(p, x, y)
        return (n.mn - allowance * n.down, n.mx + allowance * n.up)
    }

    /// The 3×3 [min, max] and how far the pixel stands proud as a one- or two-pixel
    /// peak (`up`) or trough (`down`) along any of four directions.
    static func peakExtents(_ p: Plane, _ x: Int, _ y: Int)
        -> (mn: Double, mx: Double, up: Double, down: Double) {
        let c = p[x, y]
        var mn = c
        var mx = c
        var up = 0.0
        var down = 0.0
        for (dx, dy) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
            let a1 = p.clampedSample(x - dx, y - dy)
            let b1 = p.clampedSample(x + dx, y + dy)
            let a2 = p.clampedSample(x - 2 * dx, y - 2 * dy)
            let b2 = p.clampedSample(x + 2 * dx, y + 2 * dy)
            mn = Swift.min(mn, Swift.min(a1, b1))
            mx = Swift.max(mx, Swift.max(a1, b1))
            up = Swift.max(up, c - Swift.max(a1, b1))
            up = Swift.max(up, c - Swift.max(a2, b1) - abs(a1 - c))
            up = Swift.max(up, c - Swift.max(a1, b2) - abs(b1 - c))
            down = Swift.max(down, Swift.min(a1, b1) - c)
            down = Swift.max(down, Swift.min(a2, b1) - c - abs(a1 - c))
            down = Swift.max(down, Swift.min(a1, b2) - c - abs(b1 - c))
        }
        return (mn, mx, up, down)
    }
}

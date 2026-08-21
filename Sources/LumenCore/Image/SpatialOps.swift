// SpatialOps.swift
// The spatial kernels every neighbourhood-aware stage in the pipeline is built from:
// box and Gaussian blurs, the guided filter, the à-trous wavelet stack, the dark-channel
// dehaze primitives, and Richardson–Lucy deconvolution.
//
// Reference-implementation policy (docs/14 §1.4): these ARE the definitions. The Metal
// kernels that ship are optimizations measured against this file. Nothing here imports a
// platform framework, so the whole spatial substrate is testable on any host.
//
// Two rules hold throughout and are not restated at every call site:
//   · Every sample goes through `clampedSample`, so a kernel never invents darkness at
//     the frame border and no index can leave the buffer.
//   · Maths in Double, storage in f32. The f32 rounding at each Plane write is deliberate:
//     it is the precision the GPU path has, so the golden tolerances mean something.
//
// The load-bearing entry is `guidedFilter`. Four separate features depend on it — S7's
// edge-aware tone mask, S8's base–detail split, mask feathering (S11), and dehaze's
// transmission refinement — which is why it is O(1) per pixel via box filters rather than
// the textbook O(r²) form: one filter, four callers, all inside the frame budget.

import Foundation

public enum SpatialOps {

    // MARK: - Box blur

    /// Separable box blur with a running sum: O(1) per pixel regardless of radius.
    ///
    /// Each pass slides a `2r+1` window, adding the entering sample and subtracting the
    /// leaving one. Both are read through `clampedSample`, which makes the edge behaviour
    /// "repeat the border pixel" — the same convention the whole engine uses — and makes
    /// every index provably in range without a special case per border.
    ///
    /// This is the primitive `gaussianBlur` and `guidedFilter` are built on, so its exact
    /// normalization (divide by the full window count, including the clamped repeats) is
    /// part of the contract: a constant plane blurs to itself, everywhere, exactly.
    public static func boxBlur(_ plane: Plane, radius: Int) -> Plane {
        guard radius > 0 else { return plane }
        let w = plane.width
        let h = plane.height
        // A window wider than the image degenerates to the global mean; capping the radius
        // keeps the loop bounds small without changing the result.
        let r = Swift.min(radius, Swift.max(w, h))
        let n = Double(2 * r + 1)

        var tmp = Plane(width: w, height: h)
        for y in 0..<h {
            var sum = 0.0
            for k in -r...r { sum += plane.clampedSample(k, y) }
            tmp[0, y] = sum / n
            if w > 1 {
                for x in 1..<w {
                    sum += plane.clampedSample(x + r, y)
                    sum -= plane.clampedSample(x - r - 1, y)
                    tmp[x, y] = sum / n
                }
            }
        }

        var out = Plane(width: w, height: h)
        for x in 0..<w {
            var sum = 0.0
            for k in -r...r { sum += tmp.clampedSample(x, k) }
            out[x, 0] = sum / n
            if h > 1 {
                for y in 1..<h {
                    sum += tmp.clampedSample(x, y + r)
                    sum -= tmp.clampedSample(x, y - r - 1)
                    out[x, y] = sum / n
                }
            }
        }
        return out
    }

    /// RGB box blur. Alpha passes through untouched — blurring coverage would soften the
    /// very mask edges the compositor relies on.
    public static func boxBlur(_ image: ImageBuffer, radius: Int) -> ImageBuffer {
        guard radius > 0 else { return image }
        var out = image
        for c in 0..<3 {
            let blurred = boxBlur(channelPlane(image, c), radius: radius)
            writeChannel(blurred, into: &out, channel: c)
        }
        return out
    }

    // MARK: - Gaussian blur

    /// Three successive box passes, which is the standard box approximation to a Gaussian
    /// (three passes give a piecewise-quadratic kernel — within ~3% of a true Gaussian,
    /// and indistinguishable once quantized to f32 display values).
    ///
    /// Box widths follow Kovesi's "Fast Almost-Gaussian Filtering" (2010): with `n = 3`
    /// passes and the ideal width `wIdeal = sqrt(12σ²/n + 1)`, take the largest odd
    /// `wl ≤ wIdeal`, set `wu = wl + 2`, and use `wl` for the first
    /// `m = round((12σ² − n·wl² − 4n·wl − 3n) / (−4·wl − 4))` passes and `wu` for the rest.
    /// Mixing two widths is what lets three integer boxes hit a non-integer σ; using one
    /// width three times quantizes σ badly at the small radii capture sharpening lives at.
    /// Below this sigma the blur is an EXACT separable Gaussian rather than the
    /// three-box approximation.
    ///
    /// The box widths are integers, so the result only changes when a width changes.
    /// Measured across the Sharpen Radius range of 0.5…3.0 at Amount 100, thirteen of
    /// twenty settings rendered BYTE-IDENTICAL: the control was a seven-position switch
    /// wearing a slider's clothes. The GPU's `CIGaussianBlur` is continuous in sigma, so
    /// the two paths could not agree there either, and no golden could have told a
    /// staircase from a smooth ramp.
    ///
    /// Boxes are kept above it because a mask feather or a halation radius runs to tens
    /// of pixels, where an exact kernel is hundreds of taps and one integer step in a
    /// box width is under a percent — invisible, and not worth paying for. At sigma 8
    /// the step is already 1.6%.
    public static let exactGaussianMaxSigma: Double = 8

    public static func gaussianBlur(_ plane: Plane, sigma: Double) -> Plane {
        guard sigma > 0.05 else { return plane }
        if sigma <= exactGaussianMaxSigma { return exactGaussian(plane, sigma: sigma) }
        var out = plane
        for r in boxRadiiForGaussian(sigma: sigma) { out = boxBlur(out, radius: r) }
        return out
    }

    public static func gaussianBlur(_ image: ImageBuffer, sigma: Double) -> ImageBuffer {
        guard sigma > 0.05 else { return image }
        if sigma <= exactGaussianMaxSigma {
            var out = image
            for c in 0..<3 {
                writeChannel(exactGaussian(channelPlane(image, c), sigma: sigma),
                             into: &out, channel: c)
            }
            return out
        }
        var out = image
        for r in boxRadiiForGaussian(sigma: sigma) { out = boxBlur(out, radius: r) }
        return out
    }

    /// A true separable Gaussian, normalized over the taps it actually keeps so the
    /// blur preserves the mean exactly rather than losing the truncated tails.
    static func exactGaussian(_ plane: Plane, sigma: Double) -> Plane {
        guard sigma.isFinite, sigma > 0 else { return plane }
        // FOUR sigma, not three. Normalizing over the taps that are kept makes the
        // blur preserve a flat field either way, but truncation still bites the
        // kernel's SHAPE: a 3σ window has a second moment of 0.973σ², so the blur
        // measures 1.4% narrower than it was asked for, and the GPU's `CIGaussianBlur`
        // measures the sigma it is given. At 4σ the error is 0.06%, and the cost at the
        // Sharpen range's widest setting is six extra taps.
        let radius = Swift.max(Int((sigma * 4).rounded(.up)), 1)
        var kernel = [Double](repeating: 0, count: 2 * radius + 1)
        let denominator = 2 * sigma * sigma
        var total = 0.0
        for i in 0...(2 * radius) {
            let d = Double(i - radius)
            let w = exp(-d * d / denominator)
            kernel[i] = w
            total += w
        }
        guard total > 0 else { return plane }
        for i in kernel.indices { kernel[i] /= total }

        let w = plane.width
        let h = plane.height
        var horizontal = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                for t in 0...(2 * radius) {
                    acc += kernel[t] * plane.clampedSample(x + t - radius, y)
                }
                horizontal[x, y] = acc
            }
        }
        var out = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                for t in 0...(2 * radius) {
                    acc += kernel[t] * horizontal.clampedSample(x, y + t - radius)
                }
                out[x, y] = acc
            }
        }
        return out
    }

    /// The three box radii approximating `sigma`. Radius 0 means "skip that pass", which
    /// is the correct behaviour for a σ smaller than one pixel.
    public static func boxRadiiForGaussian(sigma: Double) -> [Int] {
        let n = 3.0
        // A non-finite sigma would carry straight through to `Int(floor(wIdeal))` and
        // trap. Nothing shipped reaches it today; the contract is that nothing traps.
        guard sigma.isFinite else { return [0, 0, 0] }
        let s = Swift.max(sigma, 0.0)
        let wIdeal = ((12.0 * s * s / n) + 1.0).squareRoot()
        var wl = Int(floor(wIdeal))
        if wl % 2 == 0 { wl -= 1 }
        if wl < 1 { wl = 1 }
        let dwl = Double(wl)
        // Denominator is ≤ −8 for any wl ≥ 1, so this division is always defined.
        let mIdeal = (12.0 * s * s - n * dwl * dwl - 4.0 * n * dwl - 3.0 * n) / (-4.0 * dwl - 4.0)
        var m = Int(mIdeal.rounded())
        if m < 0 { m = 0 }
        if m > 3 { m = 3 }
        var radii: [Int] = []
        for i in 0..<3 {
            let width = i < m ? wl : wl + 2
            radii.append((width - 1) / 2)
        }
        return radii
    }

    // MARK: - Guided filter

    /// He/Sun/Tang guided filter (ECCV 2010 / TPAMI 2013), box-filter formulation.
    ///
    /// Inside every `(2r+1)²` window the output is modelled as an affine function of the
    /// guide, `q = a·I + b`, with the least-squares solution
    /// `a = cov(I,p) / (var(I) + ε)` and `b = mean(p) − a·mean(I)`; overlapping windows
    /// are averaged, which is the second box-filter pass over `a` and `b`.
    ///
    /// Why this and not a bilateral filter: the affine model has no gradient reversal, so
    /// a base–detail split built on it cannot produce the ringing that makes bilateral
    /// clarity halo (docs/14 §5.3). `ε` is a *variance* threshold in the guide's own units
    /// — on log2 luminance it reads directly as "smooth anything flatter than √ε EV".
    ///
    /// Total cost: six box blurs, i.e. O(1) per pixel in the radius.
    public static func guidedFilter(input: Plane, guide: Plane, radius: Int, epsilon: Double) -> Plane {
        let w = input.width
        let h = input.height
        let g = (guide.width == w && guide.height == h)
            ? guide
            : guide.resized(width: w, height: h)
        guard radius > 0 else { return input }
        let eps = Swift.max(epsilon, 1e-12)

        let meanI = boxBlur(g, radius: radius)
        let meanP = boxBlur(input, radius: radius)
        let corrI = boxBlur(g.zip(g) { $0 * $1 }, radius: radius)
        let corrIP = boxBlur(g.zip(input) { $0 * $1 }, radius: radius)

        var a = Plane(width: w, height: h)
        var b = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let mi = meanI[x, y]
                let mp = meanP[x, y]
                // f32 round-trip can push a near-zero variance slightly negative.
                let varI = Swift.max(corrI[x, y] - mi * mi, 0)
                let cov = corrIP[x, y] - mi * mp
                let av = cov / (varI + eps)
                a[x, y] = av
                b[x, y] = mp - av * mi
            }
        }

        let meanA = boxBlur(a, radius: radius)
        let meanB = boxBlur(b, radius: radius)
        var out = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                out[x, y] = meanA[x, y] * g[x, y] + meanB[x, y]
            }
        }
        return out
    }

    /// Exposure-independent guided filter — darktable's "eigf", the mask S7's zone
    /// weighting rides on (docs/14 §5.2). Input is **log2 luminance**, in EV.
    ///
    /// Three things separate it from `guidedFilter`:
    ///
    /// 1. **Self-guided.** Guide and input are the same plane, so `cov(I,p) = var(I)` and
    ///    the affine model collapses to `a = var/(var+ε)`, `b = (1−a)·mean`. There is no
    ///    second signal to align to; the job is a piecewise-smooth surface, not a transfer.
    /// 2. **Log domain, so ε is a contrast threshold.** On log2 luminance, ε is measured in
    ///    EV² and means "flatter than √ε stops of local contrast is one surface" — a
    ///    statement about the scene, not about the exposure it was captured at.
    /// 3. **Exposure-equivariant by construction.** Adding a constant Δ (what the Exposure
    ///    slider is, in this domain) leaves `var` and therefore `a` untouched, and shifts
    ///    `mean`, `b`, and the output by exactly Δ. So the renderer answers an Exposure drag
    ///    by *adding* ΔEV to the cached mask instead of rebuilding it — the reason moving
    ///    Exposure does not cost a decomposition (docs/14 §5.2, cache discipline D49).
    ///
    /// Iterating feeds the result back as its own guide. Each pass flattens what is already
    /// below the contrast threshold without widening the window, so the mask gets more
    /// piecewise-constant while its edges stay exactly where they were — the property
    /// darktable's tone equalizer makes users hand-tune and we set once.
    public static func exposureIndependentGuidedFilter(luminance: Plane, radius: Int,
                                                       epsilon: Double, iterations: Int) -> Plane {
        guard radius > 0 else { return luminance }
        let w = luminance.width
        let h = luminance.height
        let eps = Swift.max(epsilon, 1e-9)
        let passes = Swift.min(Swift.max(iterations, 1), 8)

        var current = luminance
        for _ in 0..<passes {
            let mean = boxBlur(current, radius: radius)
            let corr = boxBlur(current.zip(current) { $0 * $1 }, radius: radius)
            var a = Plane(width: w, height: h)
            var b = Plane(width: w, height: h)
            for y in 0..<h {
                for x in 0..<w {
                    let m = mean[x, y]
                    let v = Swift.max(corr[x, y] - m * m, 0)
                    let av = v / (v + eps)
                    a[x, y] = av
                    b[x, y] = m * (1 - av)
                }
            }
            let meanA = boxBlur(a, radius: radius)
            let meanB = boxBlur(b, radius: radius)
            var next = Plane(width: w, height: h)
            for y in 0..<h {
                for x in 0..<w {
                    next[x, y] = meanA[x, y] * current[x, y] + meanB[x, y]
                }
            }
            current = next
        }
        return current
    }

    // MARK: - À-trous wavelets

    /// The B3-spline row the à-trous transform convolves with, separably.
    /// `[1, 4, 6, 4, 1] / 16` — the standard starlet kernel (Starck/Murtagh).
    public static let b3SplineKernel: [Double] = [1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16]

    /// À-trous ("with holes") wavelet decomposition: an undecimated pyramid where every
    /// level keeps the full resolution and the kernel is dilated instead of the image being
    /// downsampled — level `i` samples at a stride of `2^i`.
    ///
    /// Undecimated matters here: because no level is subsampled, the reconstruction is an
    /// exact sum (`residual + Σ details`) with no interpolation, so a band gain is a pure
    /// coefficient scale and cannot introduce the resampling ripple a decimated pyramid
    /// would. That is what makes Texture a recombination rather than a re-filter.
    ///
    /// Level `i` carries structure of roughly `2^(i+1)` px, so the returned stack for
    /// `levels = 5` spans ~2 px through ~64 px of detail.
    public static func atrousWavelet(_ plane: Plane, levels: Int) -> (details: [Plane], residual: Plane) {
        let n = Swift.min(Swift.max(levels, 1), 10)
        var details: [Plane] = []
        var current = plane
        for i in 0..<n {
            let smooth = b3Spline(current, step: 1 << i)
            details.append(current.zip(smooth) { $0 - $1 })
            current = smooth
        }
        return (details, current)
    }

    /// Inverse transform with a per-level gain. `gains[i] == 1` reproduces the input
    /// exactly (up to f32); missing entries default to 1, so a caller may pass only the
    /// bands it wants to touch.
    public static func atrousReconstruct(details: [Plane], residual: Plane, gains: [Double]) -> Plane {
        var out = residual
        for i in 0..<details.count {
            let d = details[i]
            guard d.width == residual.width && d.height == residual.height else { continue }
            let g = i < gains.count ? gains[i] : 1.0
            if g == 0 { continue }
            out = out.zip(d) { $0 + g * $1 }
        }
        return out
    }

    // MARK: - Dehaze primitives (He/Sun/Tang, TPAMI 2011)

    /// Dark channel: the minimum over RGB, then a windowed minimum over a `(2r+1)²` patch.
    ///
    /// The prior it encodes: in a haze-free outdoor patch, at least one colour channel is
    /// near zero somewhere. Whatever the dark channel actually reads is therefore the
    /// airlight that has been added on top — the haze thickness, measured directly.
    ///
    /// The erosion is separable (a min over a square is a min of row-mins), and here it is
    /// the straightforward O(r) sliding window per axis rather than van Herk/Gil-Werman:
    /// the radii dehaze uses are small and the reference must stay readable.
    public static func darkChannel(_ image: ImageBuffer, radius: Int) -> Plane {
        var minChannel = Plane(width: image.width, height: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                minChannel[x, y] = image[x, y].minComponent
            }
        }
        return minFilter(minChannel, radius: radius)
    }

    /// Atmospheric light. He et al. take the brightest `topFraction` of the dark channel
    /// and read the scene colour there; we average that set rather than taking its single
    /// brightest pixel, because one specular highlight should not define the whole render's
    /// airlight — and this value is a **global statistic frozen for the render** so tiled
    /// export matches untiled (docs/14 §6.3, the proxy-field rule).
    ///
    /// The result is floored away from zero per channel: every dehaze recovery divides by
    /// it, and a channel that estimated to exactly zero would take the whole frame with it.
    public static func estimateAirlight(_ image: ImageBuffer, darkChannel: Plane,
                                        topFraction: Double) -> RGB {
        let w = image.width
        let h = image.height
        let dc = (darkChannel.width == w && darkChannel.height == h)
            ? darkChannel
            : darkChannel.resized(width: w, height: h)
        let fraction = Num.clamp(topFraction, 1e-5, 0.5)
        let span = dc.range
        let lo = span.min
        let hi = span.max

        var sum = RGB.zero
        var n = 0.0
        if hi - lo > 1e-9, (hi - lo).isFinite {
            // Histogram instead of a sort: 4M elements, one pass, no allocation storm.
            let bins = 1024
            var hist = [Double](repeating: 0, count: bins)
            let scale = Double(bins) / (hi - lo)
            for v in dc.values {
                // Clamp in Double BEFORE converting. `Plane.range` drops NaN but
                // carries ±Inf through, and one infinity makes this product NaN for
                // the pixel that holds it — or, if the infinity is negative, for every
                // pixel. `Int(nan)` traps, and it traps before the clamp below runs.
                let t = (Double(v) - lo) * scale
                let raw = t.isFinite ? Int(Num.clamp(t, 0, Double(bins - 1))) : bins - 1
                hist[Swift.min(Swift.max(raw, 0), bins - 1)] += 1
            }
            let target = Double(dc.values.count) * fraction
            var acc = 0.0
            var cut = bins - 1
            var i = bins - 1
            while i >= 0 {
                acc += hist[i]
                if acc >= target { cut = i; break }
                i -= 1
            }
            let threshold = lo + (Double(cut) / Double(bins)) * (hi - lo)
            for y in 0..<h {
                for x in 0..<w {
                    if dc[x, y] >= threshold {
                        sum = sum + image[x, y]
                        n += 1
                    }
                }
            }
        }

        if n <= 0 {
            // Degenerate frame (flat dark channel): fall back to the global mean.
            for y in 0..<h {
                for x in 0..<w {
                    sum = sum + image[x, y]
                    n += 1
                }
            }
        }
        guard n > 0 else { return RGB(gray: 1) }
        let a = sum / n
        return RGB(Swift.max(a.r, 1e-4), Swift.max(a.g, 1e-4), Swift.max(a.b, 1e-4))
    }

    // MARK: - Deconvolution

    /// Richardson–Lucy deconvolution against a Gaussian PSF of the given σ.
    ///
    /// Each iteration is `estimate ← estimate · (PSF ⊛ (observed / (PSF ⊛ estimate)))`.
    /// The correlation with the flipped PSF is just another blur here, because a Gaussian
    /// is symmetric — which is the whole reason the σ-parameterized PSF is worth having.
    ///
    /// Guards that make it survive real scene-linear data:
    ///   · RL's Poisson model is defined on non-negative intensities, so the input is
    ///     floored at zero (scene-referred data legitimately carries small negatives).
    ///   · The division is skipped wherever the blurred estimate is below a floor, and the
    ///     ratio is clamped to 8×. Without both, one near-black pixel next to a specular
    ///     drives a runaway that shows up as a black speckle after four iterations.
    public static func richardsonLucy(_ plane: Plane, sigma: Double, iterations: Int) -> Plane {
        guard sigma > 0.05, iterations > 0 else { return plane }
        let n = Swift.min(iterations, 64)
        let floorValue = 1e-7
        let observed = plane.map { Swift.max($0, 0) }
        var estimate = observed

        for _ in 0..<n {
            let blurred = gaussianBlur(estimate, sigma: sigma)
            var ratio = Plane(width: plane.width, height: plane.height)
            for i in 0..<ratio.values.count {
                let o = Double(observed.values[i])
                let b = Double(blurred.values[i])
                let r = b > floorValue ? o / b : 1.0
                ratio.values[i] = Float(Num.clamp(r, 0, 8))
            }
            let correction = gaussianBlur(ratio, sigma: sigma)
            for i in 0..<estimate.values.count {
                let v = Double(estimate.values[i]) * Double(correction.values[i])
                estimate.values[i] = Float(Swift.max(v, 0))
            }
        }
        return estimate
    }

    /// Lower bound of the auto-radius estimate — docs/06's manual Radius range starts here.
    public static let minPSFSigma: Double = 0.4
    /// Upper bound. Beyond ~2 px the deconvolution stops recovering detail and starts
    /// inventing it, so the estimator refuses to ask for more.
    public static let maxPSFSigma: Double = 2.0

    /// Auto-radius for capture sharpening: measure the system PSF from the image's own
    /// pixels, so no lens database is needed and adapted glass is covered too (D24).
    ///
    /// The heuristic. A Gaussian PSF of width σ maps a point source to
    /// `exp(−d²/2σ²)`, so the ratio between a local peak and its neighbour one pixel away
    /// is at most `exp(1/2σ²)` — sharper optics allow a larger single-pixel ratio, and
    /// nothing in the image can exceed it. docs/06 §11.2 states the inverted form directly:
    /// `σ = sqrt(1 / ln(maxRatio))`.
    ///
    /// Three restrictions turn that into a statistic instead of a lottery:
    ///   · **Only 1-D local peaks count.** A pair straddling a step edge measures the
    ///     scene's contrast, not the optics; a sample that is higher than *both* its
    ///     neighbours along an axis is the point-source geometry the formula assumes.
    ///   · **Only unclipped mid-to-high tones count.** A clipped highlight has had its
    ///     ratio destroyed by the sensor, and a shadow pair's ratio is noise.
    ///   · **A high quantile, not the maximum.** One hot pixel would otherwise report a
    ///     perfect lens. The 99.5th percentile is the tuning knob, calibrated against the
    ///     golden corpus (docs/06 §17.3).
    ///
    /// Result is clamped to `[minPSFSigma, maxPSFSigma]`; a frame with too few valid peaks
    /// (flat scan, synthetic gradient) returns 0.8 px, the middle of the range where the
    /// deconvolution is harmless either way.
    public static func estimatePSFSigma(_ plane: Plane) -> Double {
        let defaultSigma = 0.8
        let w = plane.width
        let h = plane.height
        guard w >= 3 && h >= 3 else { return defaultSigma }
        let span = plane.range
        let peak = span.max
        guard peak > 0 else { return defaultSigma }

        let clipLevel = peak * 0.95
        let noiseFloor = Swift.max(peak * 0.02, 1e-6)

        // Histogram over ln(ratio). The top of the range corresponds to σ = minPSFSigma,
        // so the whole representable σ interval maps inside the bins.
        let bins = 256
        let maxLn = 1.0 / (minPSFSigma * minPSFSigma)
        var hist = [Double](repeating: 0, count: bins)
        var total = 0.0

        for y in 0..<h {
            for x in 0..<w {
                let c = plane[x, y]
                if c <= noiseFloor || c > clipLevel { continue }
                // Horizontal peak.
                let left = plane.clampedSample(x - 1, y)
                let right = plane.clampedSample(x + 1, y)
                if c > left && c > right {
                    let neighbour = Swift.max(left, right)
                    if neighbour > noiseFloor {
                        let l = log(c / neighbour)
                        if l > 0 {
                            let idx = Swift.min(Int(l / maxLn * Double(bins)), bins - 1)
                            hist[Swift.max(idx, 0)] += 1
                            total += 1
                        }
                    }
                }
                // Vertical peak.
                let up = plane.clampedSample(x, y - 1)
                let down = plane.clampedSample(x, y + 1)
                if c > up && c > down {
                    let neighbour = Swift.max(up, down)
                    if neighbour > noiseFloor {
                        let l = log(c / neighbour)
                        if l > 0 {
                            let idx = Swift.min(Int(l / maxLn * Double(bins)), bins - 1)
                            hist[Swift.max(idx, 0)] += 1
                            total += 1
                        }
                    }
                }
            }
        }

        guard total >= 64 else { return defaultSigma }
        let target = total * 0.995
        var acc = 0.0
        var cut = 0
        for i in 0..<bins {
            acc += hist[i]
            if acc >= target { cut = i; break }
        }
        let lnRatio = (Double(cut) + 0.5) / Double(bins) * maxLn
        guard lnRatio > 1e-6 else { return maxPSFSigma }
        let sigma = (1.0 / lnRatio).squareRoot()
        guard sigma.isFinite else { return defaultSigma }
        return Num.clamp(sigma, minPSFSigma, maxPSFSigma)
    }

    // MARK: - Unsharp mask

    /// Unsharp mask with a soft threshold.
    ///
    /// `out = v + amount · gate(|v − blur|) · (v − blur)`. The threshold is a smoothstep
    /// ramp from `threshold` to `2·threshold` rather than a hard cut: a hard threshold
    /// draws a visible contour where the gate flips, exactly along the edges the user is
    /// looking at. `threshold ≤ 0` opens the gate everywhere.
    ///
    /// Callers in this engine run it on log2 luminance, where `amount` is a contrast gain
    /// in EV and the operator is exposure-invariant.
    public static func unsharpMask(_ plane: Plane, sigma: Double, amount: Double,
                                   threshold: Double) -> Plane {
        guard amount != 0, sigma > 0 else { return plane }
        let blurred = gaussianBlur(plane, sigma: sigma)
        let t0 = Swift.max(threshold, 0)
        var out = plane
        for i in 0..<out.values.count {
            let v = Double(plane.values[i])
            let d = v - Double(blurred.values[i])
            let gate = t0 > 0 ? Num.smoothstep(t0, 2 * t0, abs(d)) : 1.0
            out.values[i] = Float(v + amount * gate * d)
        }
        return out
    }

    // MARK: - Internals

    /// Separable erosion. A min over a square window is the min of the row-mins.
    private static func minFilter(_ plane: Plane, radius: Int) -> Plane {
        guard radius > 0 else { return plane }
        let w = plane.width
        let h = plane.height
        let r = Swift.min(radius, Swift.max(w, h))

        var tmp = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var m = plane[x, y]
                for k in -r...r { m = Swift.min(m, plane.clampedSample(x + k, y)) }
                tmp[x, y] = m
            }
        }
        var out = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var m = tmp[x, y]
                for k in -r...r { m = Swift.min(m, tmp.clampedSample(x, y + k)) }
                out[x, y] = m
            }
        }
        return out
    }

    /// Separable B3-spline convolution with the taps spread `step` pixels apart — the
    /// "holes" the à-trous transform is named for.
    ///
    /// Public because the GPU has a twin of exactly this one step, and a golden that can
    /// only compare the whole five-level stack reports "the denoise is wrong" when what
    /// it means is "one tap is in the wrong place". A primitive with a reference is a
    /// primitive a test can bisect.
    public static func atrousSmooth(_ plane: Plane, step: Int) -> Plane {
        b3Spline(plane, step: step)
    }

    private static func b3Spline(_ plane: Plane, step: Int) -> Plane {
        let s = Swift.max(step, 1)
        let w = plane.width
        let h = plane.height
        let k = b3SplineKernel

        var tmp = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                for t in 0..<5 { acc += k[t] * plane.clampedSample(x + (t - 2) * s, y) }
                tmp[x, y] = acc
            }
        }
        var out = Plane(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                for t in 0..<5 { acc += k[t] * tmp.clampedSample(x, y + (t - 2) * s) }
                out[x, y] = acc
            }
        }
        return out
    }

    private static func channelPlane(_ image: ImageBuffer, _ c: Int) -> Plane {
        var p = Plane(width: image.width, height: image.height)
        for y in 0..<image.height {
            for x in 0..<image.width { p[x, y] = image[x, y][c] }
        }
        return p
    }

    private static func writeChannel(_ plane: Plane, into image: inout ImageBuffer, channel c: Int) {
        for y in 0..<image.height {
            for x in 0..<image.width {
                var v = image[x, y]
                v[c] = plane[x, y]
                image[x, y] = v
            }
        }
    }
}

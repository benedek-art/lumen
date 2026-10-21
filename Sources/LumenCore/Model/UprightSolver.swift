// UprightSolver.swift
// Upright: Lightroom's automatic perspective correction, as line detection, vanishing
// points and a constrained camera rotation (docs/09 §Upright).
//
// THE MODEL. A tilted camera photographing a building is a camera ROTATION away from
// the picture that keeps verticals vertical, so the correction is the homography of a
// pure rotation, H = K · R · K⁻¹ (K the pinhole intrinsics, focal length `focal` in units
// of the long edge), not an arbitrary four-corner warp. That is the constraint: whatever
// the lines say, the result is a picture some real camera could have taken, which is
// why Upright can be trusted on a facade where a free homography would shear it.
//
//   · Level    roll only — the vertical vanishing direction (or, with no verticals, the
//              near-horizontal lines) put on the axis.
//   · Vertical roll, then pitch about the camera's x-axis until the vertical vanishing
//              point is at infinity: converging verticals become parallel and upright.
//   · Full     Vertical, then yaw about the (now vertical) y-axis until the dominant
//              horizontal vanishing point is at infinity, then a vertical shear — which
//              keeps verticals vertical — takes the remaining common slope out of the
//              horizontals.
//   · Auto     Vertical, plus Full's yaw at half strength and only when the horizontal
//              evidence is strong; Lightroom's "balanced" Auto, stated as a rule.
//   · Guided   the photographer's lines: two verticals fix the vertical vanishing point
//              exactly, two horizontals the horizontal one; one line of either kind
//              levels by its direction alone.
//
// Each automatic angle is clamped to ±45° and scaled by `strength`; the manual Vertical,
// Horizontal and Rotate sliders add pitch, yaw and roll on top, Aspect stretches x
// against y, and the whole is then re-centred and zoomed so the warped picture covers
// the frame (Lightroom's Constrain Crop, always on). Scale and the offsets apply after
// the fit, so Scale 100 is exactly "fill the frame" and below it shows the borders.
//
// The homography is in NORMALIZED, centred, y-up coordinates — `(x − W/2, H/2 − y) / L`
// with L the long edge — so it is resolution independent and the same numbers drive a
// 1024 px proxy and a 60 MP export. `GeometryMap` conjugates it into pixels.
//
// The automatic modes solve from `Upright.segments`, which the app fills ONCE when the
// mode is chosen (`UprightDetector.detect`) and stores in the recipe. A render never
// detects: it is a pure function of the recipe, so the CPU and GPU paths cannot solve
// two different homographies from two decodes of the same file.

import Foundation

public enum UprightSolver {

    /// Focal length over long edge. 0.9 is a 32 mm lens on a 3:2 full frame, the middle
    /// of the range architecture is shot with. It only sets the aspect of the
    /// correction: verticals come out parallel for ANY focal length, because K·R·K⁻¹
    /// sends the vanishing direction to (0, f, 0) whatever f is.
    public static let focal: Double = 0.9

    /// Pitch and yaw the manual Vertical/Horizontal sliders reach at ±100.
    public static let manualTiltDegrees: Double = 25

    /// The constraint on every solved angle.
    public static let limitDegrees: Double = 45

    /// The rotation one mode solved, before strength and the manual sliders.
    public struct Solution: Equatable, Sendable {
        public var roll: Double = 0     // radians, about the optical axis
        public var pitch: Double = 0    // radians, about the camera x-axis
        public var yaw: Double = 0      // radians, about the camera y-axis
        /// Vertical shear taking the horizontals' remaining common slope out.
        public var shear: Double = 0
        public var verticalVP: (Double, Double, Double)?
        public var horizontalVP: (Double, Double, Double)?

        public init() {}

        public static func == (a: Solution, b: Solution) -> Bool {
            a.roll == b.roll && a.pitch == b.pitch && a.yaw == b.yaw && a.shear == b.shear
        }
    }

    // MARK: - Lines

    /// A segment in normalized centred y-up coordinates, with its length as weight.
    struct Line {
        var p: (Double, Double)
        var q: (Double, Double)
        var length: Double { hypot(q.0 - p.0, q.1 - p.1) }
        /// Homogeneous line through both points, scaled so (a, b) is a unit normal.
        var homogeneous: (Double, Double, Double) {
            let a = p.1 - q.1, b = q.0 - p.0, c = p.0 * q.1 - q.0 * p.1
            let n = hypot(a, b)
            return n > 0 ? (a / n, b / n, c / n) : (0, 0, 0)
        }
        /// Degrees from horizontal, folded into (−90, 90].
        var angle: Double {
            var a = atan2(q.1 - p.1, q.0 - p.0) * 180 / .pi
            while a <= -90 { a += 180 }
            while a > 90 { a -= 180 }
            return a
        }
        var midpoint: (Double, Double) { ((p.0 + q.0) / 2, (p.1 + q.1) / 2) }
    }

    static func lines(_ segments: [Upright.Segment], width: Double, height: Double) -> [Line] {
        let long = Swift.max(width, height)
        let sx = width / long, sy = height / long
        return segments.compactMap { s in
            let l = Line(p: ((s.x0 - 0.5) * sx, (0.5 - s.y0) * sy),
                         q: ((s.x1 - 0.5) * sx, (0.5 - s.y1) * sy))
            return l.length > 1e-6 ? l : nil
        }
    }

    // MARK: - The homography

    /// Source → uprighted, normalized centred y-up. Identity for nil or a default
    /// Upright, exactly.
    public static func homography(_ upright: Upright?, sourceWidth w: Double,
                                  sourceHeight h: Double) -> Homography {
        guard let u = upright, !u.isIdentity, w > 0, h > 0 else { return .identity }
        let solution = solve(u, sourceWidth: w, sourceHeight: h)
        let strength = Num.clamp(u.strength, 0, 100) / 100
        let limit = limitDegrees * .pi / 180
        let roll = Num.clamp(solution.roll * strength, -limit, limit)
            - Num.clamp(u.rotate, -45, 45) * .pi / 180
        let pitch = Num.clamp(solution.pitch * strength, -limit, limit)
            + Num.clamp(u.vertical, -100, 100) / 100 * manualTiltDegrees * .pi / 180
        let yaw = Num.clamp(solution.yaw * strength, -limit, limit)
            + Num.clamp(u.horizontal, -100, 100) / 100 * manualTiltDegrees * .pi / 180
        let shear = solution.shear * strength
        let aspect = pow(2, Num.clamp(u.aspect, -100, 100) / 200)
        let core = Homography.scale(aspect, 1 / aspect)
            * Homography(1, 0, 0, shear, 1, 0, 0, 0, 1)
            * camera(roll: roll, pitch: pitch, yaw: yaw)

        let user = Homography.scale(Num.clamp(u.scale, 50, 150) / 100,
                                    Num.clamp(u.scale, 50, 150) / 100)
        let long = Swift.max(w, h)
        let offset = Homography.translation(Num.clamp(u.offsetX, -100, 100) / 100 * 0.25 * w / long,
                                            -Num.clamp(u.offsetY, -100, 100) / 100 * 0.25 * h / long)
        if core.maxDifference(.identity) < 1e-15 { return (offset * user).normalized }
        // Backed off until the warped frame is a convex quad around its own centre —
        // a rotation that sends a corner behind the camera is no picture at all.
        var tilt = 1.0
        for _ in 0..<8 {
            let candidate = tilt == 1 ? core
                : Homography.scale(aspect, 1 / aspect)
                    * Homography(1, 0, 0, shear * tilt, 1, 0, 0, 0, 1)
                    * camera(roll: roll * tilt, pitch: pitch * tilt, yaw: yaw * tilt)
            if let fit = fill(candidate, width: w / long, height: h / long) {
                return (offset * user * fit * candidate).normalized
            }
            tilt *= 0.5
        }
        return (offset * user).normalized
    }

    /// K · Ry(yaw) · Rx(pitch) · Rz(roll) · K⁻¹ on normalized image points.
    public static func camera(roll: Double, pitch: Double, yaw: Double,
                              focal f: Double = focal) -> Homography {
        let k = Homography.scale(f, f)
        let kInv = Homography.scale(1 / f, 1 / f)
        let rz = Homography.rotation(roll)
        let (cp, sp) = (cos(pitch), sin(pitch))
        let rx = Homography(1, 0, 0, 0, cp, -sp, 0, sp, cp)
        let (cy, sy) = (cos(yaw), sin(yaw))
        let ry = Homography(cy, 0, sy, 0, 1, 0, -sy, 0, cy)
        return k * ry * rx * rz * kInv
    }

    /// The translate-and-zoom that makes `h`'s image of the frame cover the frame
    /// exactly: centroid to the origin, then the smallest zoom putting every frame
    /// corner inside the warped quad. Nil when the quad is not a usable picture.
    static func fill(_ h: Homography, width: Double, height: Double) -> Homography? {
        let hw = width / 2, hh = height / 2
        let corners = [(-hw, hh), (hw, hh), (hw, -hh), (-hw, -hh)]
        var quad: [(Double, Double)] = []
        for c in corners {
            let p = h.apply(c.0, c.1)
            guard p.w > 0.05, p.x.isFinite, p.y.isFinite else { return nil }
            quad.append((p.x, p.y))
        }
        let cx = quad.map(\.0).reduce(0, +) / 4
        let cy = quad.map(\.1).reduce(0, +) / 4
        let centred = quad.map { ($0.0 - cx, $0.1 - cy) }
        var gauge = 0.0
        for i in 0..<4 {
            let a = centred[i], b = centred[(i + 1) % 4]
            // Outward normal of edge a→b; the corners run clockwise in y-up.
            var n = (b.1 - a.1, a.0 - b.0)
            var d = n.0 * a.0 + n.1 * a.1
            if d < 0 { n = (-n.0, -n.1); d = -d }
            guard d > 1e-9 else { return nil }
            for c in corners {
                gauge = Swift.max(gauge, (n.0 * c.0 + n.1 * c.1) / d)
            }
        }
        guard gauge > 1e-6, gauge.isFinite, gauge < 20 else { return nil }
        return Homography.scale(gauge, gauge) * Homography.translation(-cx, -cy)
    }

    // MARK: - Solving a mode

    public static func solve(_ u: Upright, sourceWidth w: Double,
                             sourceHeight h: Double) -> Solution {
        switch u.mode {
        case .off:
            return Solution()
        case .guided:
            return solveGuided(lines(u.guides, width: w, height: h))
        case .level, .vertical, .full, .auto:
            return solveAutomatic(u.mode, lines(u.segments, width: w, height: h))
        }
    }

    /// Lines within this many degrees of vertical are vertical candidates; of
    /// horizontal, horizontal candidates. Converging verticals at the frame edge of a
    /// wide lens shot steeply up reach about 30°, horizontals on a receding wall 40°.
    static let verticalTolerance: Double = 30
    static let horizontalTolerance: Double = 40

    /// What a vanishing point needs before an automatic mode will act on it: this many
    /// agreeing lines, this much agreeing length (in long edges), and an implied tilt
    /// inside the plausible range. Two tree trunks on a hillside meet somewhere; that is
    /// not a building, and a 60° pitch solved from them (the first cut, on corpus 4213)
    /// is the failure this gate exists for.
    static let minimumInliers = 4
    static let minimumSupport = 0.35
    static let plausiblePitchDegrees = 35.0
    static let plausibleYawDegrees = 35.0
    /// The automatic modes level by at most this much. A frame that needs more was
    /// turned on purpose, or the lines are not what they look like.
    static let automaticRollDegrees = 15.0

    static func solveAutomatic(_ mode: Upright.Mode, _ all: [Line]) -> Solution {
        var s = Solution()
        let verticals = all.filter { abs(abs($0.angle) - 90) < verticalTolerance }
        let horizontals = all.filter { abs($0.angle) < horizontalTolerance }
        let rollLimit = automaticRollDegrees * .pi / 180
        if let v = vanishingPoint(verticals, nearVertical: true),
           v.inliers >= minimumInliers, v.support >= minimumSupport {
            let (roll, pitch) = rollPitch(v.point)
            if abs(pitch) <= plausiblePitchDegrees * .pi / 180, abs(roll) <= rollLimit {
                s.verticalVP = v.point
                s.roll = roll
                if mode != .level { s.pitch = pitch }
            }
        }
        if s.verticalVP == nil {
            // No building to stand up: level by the near-level lines, when there are
            // enough of them to call it a horizon rather than a slope.
            let level = horizontals.filter { abs($0.angle) < 5 }
            if level.count >= 3, level.reduce(0, { $0 + $1.length }) >= minimumSupport {
                s.roll = Num.clamp(levelRoll(level), -rollLimit, rollLimit)
            }
            return s
        }
        guard mode == .full || mode == .auto else { return s }
        // The dominant plane whose correction is plausible: a receding side wall wins
        // the vote on a corner view and asks for a 55° yaw (corpus 7301). Its lines are
        // set aside and the next plane is asked.
        var pool = horizontals
        let total = horizontals.reduce(0) { $0 + $1.length }
        for _ in 0..<3 {
            guard let h = vanishingPoint(pool, nearVertical: false),
                  h.inliers >= minimumInliers, h.support >= minimumSupport else { return s }
            let (yaw, shear) = yawShear(h.point, roll: s.roll, pitch: s.pitch)
            if abs(yaw) <= plausibleYawDegrees * .pi / 180 {
                // Auto takes the horizontal correction only on strong evidence, and at half.
                if mode == .auto, h.support < 0.5 * total { return s }
                s.horizontalVP = h.point
                s.yaw = mode == .auto ? yaw * 0.5 : yaw
                s.shear = mode == .auto ? 0 : shear
                return s
            }
            pool = pool.filter { deviation($0, h.point) >= 1.5 }
        }
        return s
    }

    static func solveGuided(_ guides: [Line]) -> Solution {
        var s = Solution()
        let verticals = guides.filter { abs($0.angle) >= 45 }
        let horizontals = guides.filter { abs($0.angle) < 45 }
        if verticals.count >= 2 {
            let v = leastSquaresPoint(verticals.map(\.homogeneous),
                                      weights: verticals.map(\.length))
            s.verticalVP = v
            (s.roll, s.pitch) = rollPitch(v)
        } else if let line = verticals.first {
            s.roll = rollPitch(direction(line)).roll
        } else if let line = horizontals.first, horizontals.count == 1 {
            s.roll = -line.angle * .pi / 180
            return s
        }
        if horizontals.count >= 2 {
            let hv = leastSquaresPoint(horizontals.map(\.homogeneous),
                                       weights: horizontals.map(\.length))
            s.horizontalVP = hv
            (s.yaw, s.shear) = yawShear(hv, roll: s.roll, pitch: s.pitch)
        } else if let line = horizontals.first {
            (s.yaw, s.shear) = yawShear(direction(line), roll: s.roll, pitch: s.pitch)
        }
        return s
    }

    /// A line's own direction as a vanishing point at infinity.
    static func direction(_ l: Line) -> (Double, Double, Double) {
        (l.q.0 - l.p.0, l.q.1 - l.p.1, 0)
    }

    /// Roll then pitch that put the vertical vanishing direction on the y-axis.
    static func rollPitch(_ v: (Double, Double, Double), focal f: Double = focal)
        -> (roll: Double, pitch: Double) {
        var d = (v.0 / f, v.1 / f, v.2)
        if d.1 < 0 { d = (-d.0, -d.1, -d.2) }
        let roll = atan2(d.0, d.1)
        let rho = hypot(d.0, d.1)
        let pitch = atan2(-d.2, rho)
        return (roll, pitch)
    }

    /// Yaw that sends the horizontal vanishing direction to infinity once roll and pitch
    /// are applied, and the shear that then levels it.
    static func yawShear(_ hp: (Double, Double, Double), roll: Double, pitch: Double,
                         focal f: Double = focal) -> (yaw: Double, shear: Double) {
        // Direction in camera space after Rx·Rz: rotate the ray, not the image point.
        var d = (hp.0 / f, hp.1 / f, hp.2)
        let (cr, sr) = (cos(roll), sin(roll))
        d = (cr * d.0 - sr * d.1, sr * d.0 + cr * d.1, d.2)
        let (cp, sp) = (cos(pitch), sin(pitch))
        d = (d.0, cp * d.1 - sp * d.2, sp * d.1 + cp * d.2)
        if d.0 < 0 { d = (-d.0, -d.1, -d.2) }
        let yaw = atan2(d.2, d.0)
        let (cy, sy) = (cos(yaw), sin(yaw))
        let x = cy * d.0 + sy * d.2
        let y = d.1
        let slope = x > 1e-9 ? y / x : 0
        return (yaw, Num.clamp(-slope, -1, 1))
    }

    /// Length-weighted median deviation from horizontal, as the roll that cancels it.
    static func levelRoll(_ lines: [Line]) -> Double {
        guard !lines.isEmpty else { return 0 }
        let sorted = lines.map { ($0.angle, $0.length) }.sorted { $0.0 < $1.0 }
        let half = sorted.reduce(0) { $0 + $1.1 } / 2
        var run = 0.0
        for (a, w) in sorted {
            run += w
            if run >= half { return -a * .pi / 180 }
        }
        return 0
    }

    // MARK: - Vanishing points

    struct Vanishing {
        var point: (Double, Double, Double)
        var support: Double
        var inliers: Int
    }

    /// Angle between a segment and the direction from its midpoint to a homogeneous
    /// point, in degrees (0…90).
    static func deviation(_ l: Line, _ v: (Double, Double, Double)) -> Double {
        let m = l.midpoint
        var dir: (Double, Double)
        if abs(v.2) < 1e-12 {
            dir = (v.0, v.1)
        } else {
            dir = (v.0 / v.2 - m.0, v.1 / v.2 - m.1)
        }
        let seg = (l.q.0 - l.p.0, l.q.1 - l.p.1)
        let n1 = hypot(dir.0, dir.1), n2 = hypot(seg.0, seg.1)
        guard n1 > 1e-12, n2 > 1e-12 else { return 90 }
        let c = abs(dir.0 * seg.0 + dir.1 * seg.1) / (n1 * n2)
        return acos(Swift.min(1, c)) * 180 / .pi
    }

    /// RANSAC over pairs of the longest lines, consensus by length within 1.5°, then a
    /// weighted least-squares refinement on the inliers. A vertical vanishing point must
    /// lie above or below the frame (within 35° of the y-axis as seen from the centre),
    /// a horizontal one left or right of it.
    static func vanishingPoint(_ lines: [Line], nearVertical: Bool) -> Vanishing? {
        guard lines.count >= 2 else { return nil }
        let pool = Array(lines.sorted { $0.length > $1.length }.prefix(60))
        let threshold = 1.5
        var best: Vanishing?
        for i in 0..<pool.count {
            for j in (i + 1)..<pool.count {
                let a = pool[i].homogeneous, b = pool[j].homogeneous
                var v = cross(a, b)
                let n = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
                guard n > 1e-12 else { continue }
                v = (v.0 / n, v.1 / n, v.2 / n)
                guard plausible(v, nearVertical: nearVertical) else { continue }
                var support = 0.0, count = 0
                for l in lines where deviation(l, v) < threshold {
                    support += l.length
                    count += 1
                }
                if support > (best?.support ?? 0) { best = Vanishing(point: v, support: support,
                                                                     inliers: count) }
            }
        }
        guard var found = best, found.inliers >= 2 else { return nil }
        let inliers = lines.filter { deviation($0, found.point) < threshold }
        var refined = leastSquaresPoint(inliers.map(\.homogeneous),
                                        weights: inliers.map(\.length))
        if refined.0 * found.point.0 + refined.1 * found.point.1 + refined.2 * found.point.2 < 0 {
            refined = (-refined.0, -refined.1, -refined.2)
        }
        if plausible(refined, nearVertical: nearVertical) { found.point = refined }
        return found
    }

    static func plausible(_ v: (Double, Double, Double), nearVertical: Bool) -> Bool {
        // Direction of the point from the frame centre (sign-free).
        let dx: Double, dy: Double
        if abs(v.2) < 1e-12 {
            dx = v.0; dy = v.1
        } else {
            dx = v.0 / v.2; dy = v.1 / v.2
            // A vanishing point inside the frame is not one these lines can have.
            if abs(dx) < 0.5 && abs(dy) < 0.5 { return false }
        }
        let fromVertical = atan2(abs(dx), abs(dy)) * 180 / .pi
        return nearVertical ? fromVertical < 35 : fromVertical > 50
    }

    static func cross(_ a: (Double, Double, Double), _ b: (Double, Double, Double))
        -> (Double, Double, Double) {
        (a.1 * b.2 - a.2 * b.1, a.2 * b.0 - a.0 * b.2, a.0 * b.1 - a.1 * b.0)
    }

    /// The unit point minimizing Σ wᵢ (lᵢ · v)²: the smallest eigenvector of Σ wᵢ lᵢ lᵢᵀ.
    static func leastSquaresPoint(_ lines: [(Double, Double, Double)],
                                  weights: [Double]) -> (Double, Double, Double) {
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        for (l, w) in zip(lines, weights) {
            let v = [l.0, l.1, l.2]
            for i in 0..<3 { for j in 0..<3 { a[i][j] += w * v[i] * v[j] } }
        }
        let e = smallestEigenvector(a)
        return (e[0], e[1], e[2])
    }

    /// Cyclic Jacobi on a symmetric 3×3.
    static func smallestEigenvector(_ input: [[Double]]) -> [Double] {
        var a = input
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<50 {
            var off = 0.0
            for i in 0..<3 { for j in 0..<3 where i != j { off += a[i][j] * a[i][j] } }
            if off < 1e-30 { break }
            for p in 0..<2 {
                for q in (p + 1)..<3 where abs(a[p][q]) > 1e-300 {
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<3 {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<3 {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<3 {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        var idx = 0
        for i in 1..<3 where a[i][i] < a[idx][idx] { idx = i }
        return [v[0][idx], v[1][idx], v[2][idx]]
    }
}

// MARK: - Measuring a correction

extension UprightSolver {

    /// How far a set of segments sits from the axes once a geometry is applied: the
    /// length-weighted RMS deviation, in degrees, of the near-vertical ones from vertical
    /// and of the near-horizontal ones from horizontal, measured in the OUTPUT frame.
    /// The number Upright's acceptance lines are stated in, shared by the tests and
    /// `lumen-render upright` so the two cannot measure different things.
    public struct Residual: Sendable {
        public var verticalRMS: Double
        public var horizontalRMS: Double
        public var verticals: Int
        public var horizontals: Int
        /// Length-weighted MEDIAN |deviation| of the lines within 20° of vertical. The
        /// robust reading on a real frame, where the near-vertical set also holds spire
        /// flanks, arch tangents and foliage that no correction should make vertical.
        public var verticalMedian: Double
    }

    public static func residual(_ segments: [Upright.Segment], map: GeometryMap) -> Residual {
        let w = Double(map.sourceWidth), h = Double(map.sourceHeight)
        var v = (sum: 0.0, weight: 0.0, n: 0), hz = (sum: 0.0, weight: 0.0, n: 0)
        var near: [(Double, Double)] = []
        for s in segments {
            let a = map.sourceToOutput.apply(s.x0 * w, s.y0 * h)
            let b = map.sourceToOutput.apply(s.x1 * w, s.y1 * h)
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0, len.isFinite else { continue }
            var angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
            while angle <= -90 { angle += 180 }
            while angle > 90 { angle -= 180 }
            let fromVertical = 90 - abs(angle)
            if fromVertical < verticalTolerance {
                v.sum += fromVertical * fromVertical * len; v.weight += len; v.n += 1
                if fromVertical < 20 { near.append((fromVertical, len)) }
            } else if abs(angle) < horizontalTolerance {
                hz.sum += angle * angle * len; hz.weight += len; hz.n += 1
            }
        }
        near.sort { $0.0 < $1.0 }
        let half = near.reduce(0) { $0 + $1.1 } / 2
        var run = 0.0, median = Double.nan
        for (d, w) in near {
            run += w
            if run >= half { median = d; break }
        }
        return Residual(verticalRMS: v.weight > 0 ? (v.sum / v.weight).squareRoot() : .nan,
                        horizontalRMS: hz.weight > 0 ? (hz.sum / hz.weight).squareRoot() : .nan,
                        verticals: v.n, horizontals: hz.n, verticalMedian: median)
    }
}

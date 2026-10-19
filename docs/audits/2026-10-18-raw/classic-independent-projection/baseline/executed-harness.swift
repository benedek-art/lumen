// Optional independent clean-ground-truth diagnostic. No quality acceptance bars.
// Compile/run through audit-classic-projection.py; the engine is linked, not copied.
import Foundation
import LumenCore

struct Generator {
    var state: UInt64
    mutating func uniform() -> Double {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z ^= z >> 31
        return (Double(z >> 11) + 0.5) / 9007199254740992.0
    }
    mutating func normal() -> Double {
        sqrt(-2 * log(uniform())) * cos(2 * Double.pi * uniform())
    }
}
struct Pattern {
    let name: String
    let cycles: Int // zero denotes a step
    let amplitude: Double
    let chroma: Bool
    // Published Rec.2020 coefficients, not the production wavelet/metric surface.
    var direction: RGB { chroma ? RGB(1, -0.2627 / 0.6780, 0) : RGB(gray: 1) }
    func basis(_ x: Int, _ width: Int) -> Double {
        cycles == 0 ? (x < width / 2 ? -1 : 1)
            : sin(2 * Double.pi * Double(cycles) * (Double(x) + 0.5) / Double(width))
    }
    func signal(_ rgb: RGB) -> Double {
        let d = direction
        return ((rgb.r - 0.18) * d.r + (rgb.g - 0.18) * d.g + (rgb.b - 0.18) * d.b)
            / (d.r * d.r + d.g * d.g + d.b * d.b)
    }
}
struct Metrics {
    var mse: Double = 0
    var sinCoefficient: Double = 0
    var cosCoefficient: Double = 0
    var dc: Double = 0
    var nearStep: Double = 0
    var farStep: Double = 0
    var amplitude: Double { hypot(sinCoefficient, cosCoefficient) }
    var phase: Double { atan2(cosCoefficient, sinCoefficient) }
}
enum AuditFailure: Error { case identity(String), nonfinite(String), oracle(String) }

func metrics(_ image: ImageBuffer, clean: ImageBuffer, pattern: Pattern) -> Metrics {
    var m = Metrics()
    let w = image.width, h = image.height, n = Double(w * h)
    var leftNear = 0.0, rightNear = 0.0, leftFar = 0.0, rightFar = 0.0
    for y in 0..<h {
        for x in 0..<w {
            let c = image[x, y], truth = clean[x, y]
            m.mse += (pow(c.r - truth.r, 2) + pow(c.g - truth.g, 2) + pow(c.b - truth.b, 2)) / (3 * n)
            let value = pattern.signal(c)
            m.dc += value / n
            if pattern.cycles > 0 {
                let theta = 2 * Double.pi * Double(pattern.cycles) * (Double(x) + 0.5) / Double(w)
                m.sinCoefficient += 2 * value * sin(theta) / n
                m.cosCoefficient += 2 * value * cos(theta) / n
            }
            // Near: four columns on each side of the edge. Far: eight columns,
            // eight pixels from both image boundary and the step. No wavelet calls.
            if x >= w / 2 - 4 && x < w / 2 { leftNear += value / Double(4 * h) }
            if x >= w / 2 && x < w / 2 + 4 { rightNear += value / Double(4 * h) }
            if x >= 8 && x < 16 { leftFar += value / Double(8 * h) }
            if x >= w - 16 && x < w - 8 { rightFar += value / Double(8 * h) }
        }
    }
    m.nearStep = rightNear - leftNear
    m.farStep = rightFar - leftFar
    return m
}
func run() throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let width = 64, height = 64
    let patterns = [
        Pattern(name: "luma-low-low", cycles: 2, amplitude: 0.01, chroma: false),
        Pattern(name: "luma-high-low", cycles: 16, amplitude: 0.01, chroma: false),
        Pattern(name: "luma-low-high", cycles: 2, amplitude: 0.08, chroma: false),
        Pattern(name: "luma-high-high", cycles: 16, amplitude: 0.08, chroma: false),
        Pattern(name: "chroma-high", cycles: 16, amplitude: 0.04, chroma: true),
        Pattern(name: "luma-step", cycles: 0, amplitude: 0.08, chroma: false),
        Pattern(name: "chroma-step", cycles: 0, amplitude: 0.08, chroma: true),
    ]
    var rows = ["pattern,cycles,cleanAmplitude,iso,seed,setting,luma,chroma,hotPixels,noiseA,noiseB,noisyNegativeChannels,noisyAboveOneChannels,cleanSin,cleanCos,cleanDC,cleanNearStep,cleanFarStep,mse,mseRatioToOff,sinCoefficient,cosCoefficient,amplitudeRetention,phaseRadians,dcBias,nearStepRetention,farStepRetention,worseMSEThanOff"]
    var worse: [[String: Any]] = []
    var zeroIdentities = 0, finiteImages = 0, negativeChannels = 0, aboveOneChannels = 0
    for iso in [1600.0, 6400.0] {
        let profile = NoiseProfile.forISO(iso)
        for seed: UInt64 in [17, 29] {
            for pattern in patterns {
                var clean = ImageBuffer(width: width, height: height)
                for y in 0..<height { for x in 0..<width {
                    clean[x, y] = RGB(gray: 0.18) + pattern.direction * (pattern.amplitude * pattern.basis(x, width))
                } }
                let cleanMetric = metrics(clean, clean: clean, pattern: pattern)
                // Analytic oracle self-checks only: f32 storage error is bounded here,
                // not used to turn measured denoise quality into a pass criterion.
                if pattern.cycles > 0 {
                    guard abs(cleanMetric.sinCoefficient - pattern.amplitude) < 1e-7,
                          abs(cleanMetric.cosCoefficient) < 1e-7 else { throw AuditFailure.oracle(pattern.name) }
                } else {
                    guard abs(cleanMetric.nearStep - 2 * pattern.amplitude) < 1e-7,
                          abs(cleanMetric.farStep - 2 * pattern.amplitude) < 1e-7 else { throw AuditFailure.oracle(pattern.name) }
                }
                var rng = Generator(state: seed)
                var noisy = clean
                for y in 0..<height { for x in 0..<width {
                    let c = clean[x, y]
                    // Gaussian samples with the profile's signal-dependent variance.
                    // This is variance-matched synthetic noise, not a camera fit or
                    // exact low-count Poisson sampling. No clipping of negative noise.
                    noisy[x, y] = RGB(c.r + sqrt(profile.a * max(c.r, 0) + profile.b) * rng.normal(),
                                      c.g + sqrt(profile.a * max(c.g, 0) + profile.b) * rng.normal(),
                                      c.b + sqrt(profile.a * max(c.b, 0) + profile.b) * rng.normal())
                } }
                let negative = stride(from: 0, to: noisy.pixels.count, by: 4).reduce(0) { count, offset in
                    count + (0..<3).filter { noisy.pixels[offset + $0] < 0 }.count
                }
                let aboveOne = stride(from: 0, to: noisy.pixels.count, by: 4).reduce(0) { count, offset in
                    count + (0..<3).filter { noisy.pixels[offset + $0] > 1 }.count
                }
                negativeChannels += negative
                aboveOneChannels += aboveOne
                let off = metrics(noisy, clean: clean, pattern: pattern)
                let settings: [(String, ClassicNR)] = [
                    ("off", ClassicNR(luma: 0, chroma: 0, hotPixels: 0)),
                    ("iso-default", ISODefaults.classic(forISO: iso)),
                    ("maximum", ClassicNR(luma: 100, chroma: 100, hotPixels: 0)),
                ]
                for (label, config) in settings {
                    let result = ClassicalDenoise(config, profile: profile).apply(noisy)
                    if label == "off" {
                        guard result.pixels == noisy.pixels else { throw AuditFailure.identity(pattern.name) }
                        zeroIdentities += 1
                    }
                    guard result.pixels.allSatisfy({ $0.isFinite }) else { throw AuditFailure.nonfinite(pattern.name) }
                    finiteImages += 1
                    let m = metrics(result, clean: clean, pattern: pattern)
                    let ratio = m.mse / off.mse
                    let amplitudeRetention = pattern.cycles > 0 ? m.amplitude / pattern.amplitude : 0
                    let near = pattern.cycles == 0 ? m.nearStep / (2 * pattern.amplitude) : 0
                    let far = pattern.cycles == 0 ? m.farStep / (2 * pattern.amplitude) : 0
                    let row = [pattern.name, String(pattern.cycles), String(pattern.amplitude), String(Int(iso)), String(seed), label,
                               String(config.luma), String(config.chroma), String(config.hotPixels), String(profile.a), String(profile.b),
                               String(negative), String(aboveOne), String(cleanMetric.sinCoefficient), String(cleanMetric.cosCoefficient),
                               String(cleanMetric.dc), String(cleanMetric.nearStep), String(cleanMetric.farStep), String(m.mse), String(ratio),
                               String(m.sinCoefficient), String(m.cosCoefficient), String(amplitudeRetention), String(m.phase),
                               String(m.dc), String(near), String(far), String(ratio > 1 && label != "off")]
                    rows.append(row.joined(separator: ","))
                    if ratio > 1 && label != "off" {
                        worse.append(["pattern": pattern.name, "iso": iso, "seed": seed, "setting": label, "mseRatioToOff": ratio])
                    }
                }
            }
        }
    }
    try (rows.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("metrics.csv"), atomically: true, encoding: .utf8)
    let summary: [String: Any] = ["rows": rows.count - 1, "zeroStageExactIdentities": zeroIdentities,
        "finiteImages": finiteImages, "worseMSECells": worse, "qualityThresholdsApplied": false,
        "noisyNegativeChannels": negativeChannels, "noisyAboveOneChannels": aboveOneChannels,
        "inputClippingApplied": false, "noise": "independent RGB heteroscedastic Gaussian, variance=a*clean+b; common standard normal seeds across patterns",
        "projectionBoundaryPolicy": "entire64x64 plane including boundaries; no window for integer-cycle sinusoids",
        "stepBoundaryPolicy": "near4columns each side of midpoint; far8columns atx8...15/x48...55; all64rows",
        "cameraAcceptance": false, "AIQualityAcceptance": false]
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("summary.json"))
    print("CLASSIC-INDEPENDENT rows=\(rows.count - 1) zeroExact=\(zeroIdentities) finite=\(finiteImages) worseMSE=\(worse.count) qualityAcceptance=false")
}
do { try run() }
catch {
    FileHandle.standardError.write(Data("CLASSIC-INDEPENDENT failure=\(error)\n".utf8))
    exit(1)
}

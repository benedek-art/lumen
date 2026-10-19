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
    let pattern = Pattern(name: "chroma-high", cycles: 16, amplitude: 0.04, chroma: true)
    let width = 64, height = 64, iso = 6400.0
    let seed: UInt64 = 17
    let profile = NoiseProfile.forISO(iso)
    var clean = ImageBuffer(width: width, height: height)
    for y in 0..<height { for x in 0..<width {
        clean[x, y] = RGB(gray: 0.18) + pattern.direction * (pattern.amplitude * pattern.basis(x, width))
    } }
    var noisy = clean
    var rng = Generator(state: seed)
    for y in 0..<height { for x in 0..<width {
        let c = clean[x, y]
        noisy[x, y] = RGB(c.r + sqrt(profile.a * max(c.r, 0) + profile.b) * rng.normal(),
                          c.g + sqrt(profile.a * max(c.g, 0) + profile.b) * rng.normal(),
                          c.b + sqrt(profile.a * max(c.b, 0) + profile.b) * rng.normal())
    } }
    func hash(_ image: ImageBuffer) -> String {
        let raw = image.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return String(format: "%016llx", XXH64.hash([UInt8](raw)))
    }
    let inputHash = hash(noisy)
    guard inputHash == "4177df68f4a227fc" else { throw AuditFailure.oracle("different input hash " + inputHash) }
    let baseline = metrics(noisy, clean: clean, pattern: pattern)
    let isoDefaults = ISODefaults.classic(forISO: iso)
    let maximum = ClassicNR(luma: 100, chroma: 100, hotPixels: 0)
    var settings: [(String, ClassicNR)] = [("off", ClassicNR(luma: 0, chroma: 0, hotPixels: 0))]
    for (name, base) in [("iso-default-chroma-only", isoDefaults), ("maximum-chroma-only", maximum)] {
        for detail in [0.0, 50.0, 100.0] {
            var config = base
            config.luma = 0
            config.colorDetail = detail
            settings.append((name + "-detail-" + String(Int(detail)), config))
        }
    }
    var lumaDefault = isoDefaults; lumaDefault.chroma = 0
    var lumaMaximum = maximum; lumaMaximum.chroma = 0
    settings.append(("iso-default-luma-only", lumaDefault))
    settings.append(("maximum-luma-only", lumaMaximum))
    var rows = ["setting,iso,seed,inputXXH64,outputXXH64,luma,chroma,hotPixels,lumaDetail,lumaContrast,colorDetail,colorSmoothness,mse,mseRatioToOff,amplitudeRetention,phaseRadians,dcBias,exactEqualToBlockDetail0,maxFloatDifferenceToBlockDetail0"]
    var blockZero: [String: ImageBuffer] = [:]
    var comparisons: [[String: Any]] = []
    var zeroIdentity = 0
    for (name, config) in settings {
        let result = ClassicalDenoise(config, profile: profile).apply(noisy)
        guard result.pixels.allSatisfy({ $0.isFinite }) else { throw AuditFailure.nonfinite(name) }
        if name == "off" {
            guard result.pixels == noisy.pixels else { throw AuditFailure.identity(name) }
            zeroIdentity += 1
        }
        let m = metrics(result, clean: clean, pattern: pattern)
        let key = name.components(separatedBy: "-detail-")[0]
        if name.hasSuffix("-detail-0") { blockZero[key] = result }
        let exact = blockZero[key].map { $0.pixels == result.pixels }
        let difference = blockZero[key].map { previous in
            zip(previous.pixels, result.pixels).reduce(0.0) { max($0, abs(Double($1.0) - Double($1.1))) }
        }
        let fields: [String] = [name, String(Int(iso)), String(seed), inputHash, hash(result),
            String(config.luma), String(config.chroma), String(config.hotPixels), String(config.lumaDetail),
            String(config.lumaContrast), String(config.colorDetail), String(config.colorSmoothness),
            String(m.mse), String(m.mse / baseline.mse), String(m.amplitude / pattern.amplitude),
            String(m.phase), String(m.dc), exact.map { String($0) } ?? "NA", difference.map { String($0) } ?? "NA"]
        rows.append(fields.joined(separator: ","))
        if let exact, let difference {
            comparisons.append(["setting": name, "exactEqualToDetail0": exact, "maxFloatDifferenceToDetail0": difference])
        }
    }
    let negative = stride(from: 0, to: noisy.pixels.count, by: 4).reduce(0) { n, i in
        n + (0..<3).filter { noisy.pixels[i + $0] < 0 }.count
    }
    let high = stride(from: 0, to: noisy.pixels.count, by: 4).reduce(0) { n, i in
        n + (0..<3).filter { noisy.pixels[i + $0] > 1 }.count
    }
    let rec2020YDirection = 0.2627 * pattern.direction.r + 0.6780 * pattern.direction.g + 0.0593 * pattern.direction.b
    let linearY0Direction = (pattern.direction.r + pattern.direction.g + pattern.direction.b) / sqrt(3)
    let summary: [String: Any] = ["calls": settings.count, "finiteOutputs": settings.count,
        "zeroExactIdentities": zeroIdentity, "inputXXH64": inputHash, "noiseA": profile.a, "noiseB": profile.b,
        "negativeInputRGBChannels": negative, "aboveOneInputRGBChannels": high, "inputClipping": false,
        "rec2020YDirectionCoefficient": rec2020YDirection, "linearOrthonormalY0DirectionCoefficient": linearY0Direction,
        "basisQualification": "Rec2020 constant linear Y is not constant arithmetic-mean orthonormal Y0; production applies per-RGB VST before Y0U0V0 rotation, so linearY0 coefficient is not claimed to be actual VST Y0 amplitude",
        "detailComparisons": comparisons, "qualityAcceptance": false, "cameraAcceptance": false,
        "sourceHypothesis": "chroma-magnitude edge weighting may suppress Detail authority here; no causal gate mutation was performed"]
    try (rows.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("metrics.csv"), atomically: true, encoding: .utf8)
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("summary.json"))
    print("CHROMA-ISOLATION calls=\(settings.count) finite=\(settings.count) zeroExact=\(zeroIdentity) input=\(inputHash) qualityAcceptance=false")
}
do { try run() }
catch {
    FileHandle.standardError.write(Data("CHROMA-ISOLATION failure=\(error)\n".utf8))
    exit(1)
}

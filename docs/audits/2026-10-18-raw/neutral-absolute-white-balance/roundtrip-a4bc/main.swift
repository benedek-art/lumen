import Foundation
import LumenCore
let samples = [RGB(-0.01, 0.18, 0.3), RGB(1024, 128, 256)]
let values: [(String, Double)] = [("5500",5500), ("6500",6500), ("3333.3",3333.3),
    ("6177.2",6177.2), ("Float6177.2",Double(Float(6177.2)))]
for (label, kelvin) in values {
    for amount in [1.0, 0.5] {
        let balanced = WhiteBalanceEngine.Neutral(kelvin: kelvin, tint: 0)
        let fromMired = 1e6 / kelvin
        let interpolatedMired = fromMired + (1e6 / kelvin - fromMired) * amount
        let roundtrip = 1e6 / max(interpolatedMired, 1e-9)
        let exactEngine = WhiteBalanceEngine(asShotKelvin: kelvin, asShotTint: 0,
            targetKelvin: kelvin, targetTint: 0, space: .rec2020)
        let roundtripEngine = WhiteBalanceEngine(asShotKelvin: kelvin, asShotTint: 0,
            targetKelvin: roundtrip, targetTint: 0, space: .rec2020)
        var localRecords: [[String: Any]] = []
        for tint: Double? in [nil, 0] {
            let local = ReferenceRenderer.LocalWhiteBalance(kelvin: kelvin, tint: tint,
                amount: amount, balanced: balanced, space: .rec2020)
            localRecords.append(["tint": tint == nil ? "nil" : "0", "localIdentity": local.isIdentity,
                "matrixError": local.matrix.maxAbsDifference(.identity),
                "directRGBErrors": samples.map { local.apply($0).maxAbsDifference($0) },
                "matrixMatchesRoundtripEngine": local.matrix == roundtripEngine.matrix])
        }
        let record: [String: Any] = ["label":label, "kelvin":kelvin, "amount":amount,
            "inputBitPatternEqual":kelvin.bitPattern == balanced.kelvin.bitPattern,
            "inputBits":String(kelvin.bitPattern,radix:16),"roundtripBits":String(roundtrip.bitPattern,radix:16),
            "roundtripKelvin":roundtrip,"roundtripDelta":roundtrip-kelvin,
            "exactEngineIdentity":exactEngine.isIdentity,
            "roundtripEngineIdentity":roundtripEngine.isIdentity,
            "roundtripEngineMatrixError":roundtripEngine.matrix.maxAbsDifference(.identity),
            "local":localRecords]
        let data = try JSONSerialization.data(withJSONObject: record,options:[.sortedKeys])
        var line=Data("NEUTRAL-KELVIN-ROUNDTRIP ".utf8);line.append(data);line.append(10)
        FileHandle.standardOutput.write(line)
    }
}

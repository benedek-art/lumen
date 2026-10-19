import LumenCore
import Glibc
let balanced = WhiteBalanceEngine.Neutral(kelvin: 5500, tint: 0)
let local = ReferenceRenderer.LocalWhiteBalance(kelvin: 5500, tint: nil, amount: 1, balanced: balanced, space: .rec2020)
let engine = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0, targetKelvin: 5500, targetTint: 0, space: .rec2020)
print("matrixExactIdentity=\(local.matrix == .identity) engineIdentity=\(engine.isIdentity) localIdentity=\(local.isIdentity)")
if !(local.matrix == engine.matrix && engine.isIdentity) { exit(2) }
if local.isIdentity != engine.isIdentity { exit(1) }

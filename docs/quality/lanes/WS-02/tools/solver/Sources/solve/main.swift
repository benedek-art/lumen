import LumenCore
import Foundation
while let line = readLine() {
  let p = line.split(separator: " ").compactMap { Double($0) }
  guard p.count == 5 else { continue }
  let wb = WhiteBalanceEngine(asShotKelvin: p[3], asShotTint: p[4], targetKelvin: nil, targetTint: nil)
  let s = WhiteBalanceEngine.neutralizing(sample: RGB(p[0], p[1], p[2]), asShotKelvin: p[3], asShotTint: p[4], current: wb)
  print(String(format: "%.1f %.2f", s.kelvin, s.tint))
}

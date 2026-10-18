#if os(macOS)
import Foundation
import LumenCore

/// Explains the target's existing physical tint guard, without changing stored values.
enum WhiteBalanceTintCaption {
    static func text(kelvin: Double, tint: Double, atFullStrength: Bool = false) -> String? {
        guard kelvin.isFinite, tint.isFinite, tint > 0 else { return nil }
        let effective = ColorTemperature.clampedTint(kelvin: kelvin, tint: tint)
        guard effective < tint - 0.5,
              let shownTint = Int(exactly: effective.rounded()),
              let shownKelvin = Int(exactly: kelvin.rounded()) else { return nil }
        if atFullStrength {
            return "At full strength, magenta is bounded by physics at +\(shownTint) "
                + "for \(shownKelvin) K."
        }
        return "Magenta is bounded by physics at +\(shownTint) for "
            + "\(shownKelvin) K — the render uses that value."
    }
}
#endif

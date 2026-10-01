import LumenCore

/// Input capability policy, separate from the persisted denoise recipe.
struct DenoiseControlAvailability {
    let isRendered: Bool

    var modeOptions: [(value: Denoise.Mode, label: String)] {
        var modes: [(value: Denoise.Mode, label: String)] = [
            (value: .off, label: "Off"), (value: .classic, label: "Classic")]
        if supportsAmount { modes.append((value: .ai, label: "AI (stand-in)")) }
        return modes
    }

    var supportsAmount: Bool { !isRendered }
}

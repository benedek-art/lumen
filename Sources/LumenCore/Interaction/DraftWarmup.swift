// DraftWarmup.swift
// The recipes the viewer renders and throws away once a photograph has settled, so the
// GPU programs a drag of each common control needs exist before a hand asks for one.

import Foundation

/// Moving a control off its default adds a stage to the render graph, and Core Image
/// compiles the new fused program on that graph's first render: 80–430 ms of render
/// lane on the first draft of a drag, measured on the Driver lane. Each recipe here
/// moves one control off its default; a control already moved is skipped, its stage
/// already being in the graph. Decode inputs (`Recipe.decodeInputs`) and white balance
/// are never touched, so a warm never pays a decode.
public enum DraftWarmup {

    public struct Nudge {
        public let name: String
        let isAtDefault: (Recipe) -> Bool
        let apply: (inout Recipe) -> Void
    }

    public static let nudges: [Nudge] = [
        tone("exposure", \.develop.tone.exposure, 0.5),
        tone("contrast", \.develop.tone.contrast, 20),
        tone("highlights", \.develop.tone.highlights, -20),
        tone("shadows", \.develop.tone.shadows, 20),
        tone("whites", \.develop.tone.whites, 10),
        tone("blacks", \.develop.tone.blacks, -10),
        tone("texture", \.develop.detail.texture, 20),
        tone("clarity", \.develop.detail.clarity, 20),
        tone("dehaze", \.develop.detail.dehaze, 20),
        tone("vibrance", \.develop.color.vibrance, 20),
        tone("saturation", \.develop.color.saturation, 20),
        mixer("mixer.hue", \.hue),
        mixer("mixer.sat", \.sat),
        mixer("mixer.lum", \.lum),
    ]

    /// One recipe per control still at its default, in `nudges` order.
    public static func recipes(from recipe: Recipe) -> [Recipe] {
        nudges.filter { $0.isAtDefault(recipe) }.map { nudge in
            var moved = recipe
            nudge.apply(&moved)
            return moved
        }
    }

    /// Names the controls still at their default: a photograph whose signature has
    /// been warmed needs no second warm.
    public static func signature(of recipe: Recipe) -> String {
        nudges.filter { $0.isAtDefault(recipe) }.map(\.name).joined(separator: ",")
    }

    private static func tone(_ name: String, _ path: WritableKeyPath<Recipe, Double>,
                             _ by: Double) -> Nudge {
        Nudge(name: name,
              isAtDefault: { $0[keyPath: path] == 0 },
              apply: { $0[keyPath: path] = by })
    }

    private static func mixer(_ name: String,
                              _ path: WritableKeyPath<MixerBand, Double>) -> Nudge {
        Nudge(name: name,
              isAtDefault: { recipe in
                  recipe.develop.mixer.bands.allSatisfy { $0[keyPath: path] == 0 }
              },
              apply: { recipe in
                  for i in recipe.develop.mixer.bands.indices {
                      recipe.develop.mixer.bands[i][keyPath: path] = 20
                  }
              })
    }
}

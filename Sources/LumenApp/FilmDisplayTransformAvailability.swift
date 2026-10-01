import LumenCore

/// Pure UI availability, separate from SwiftUI and the active catalog.
enum FilmDisplayTransformAvailability {
    static func replacingStock(for film: FilmLab?) -> FilmStock? {
        // FilmChain blends the user's solved transform with the film at amount/100,
        // clamped to 0...1. A live chain is not a full replacement until that is 1.
        // Unknown stocks never build a chain, so the display controls remain live.
        guard let film, film.amount >= 100,
              let stock = FilmStock.named(film.stock) else { return nil }
        return stock
    }

    static let transformHelp = "Below 100% Film Strength, these settings remain part of the film blend. "
        + "At 100%, the selected film replaces this stage; lower Strength to edit it."
    static let stockHelp = "Film Strength blends the stock with your Display Transform. "
        + "Only 100% fully replaces it."
}

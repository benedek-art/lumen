// PreviousPhoto.swift
// Which photograph "Paste from Previous" reads: the one the cursor was on before it moved.
//
// Lightroom's Previous button. It is fed every change of the primary selection; the
// photograph being left becomes the previous one. Clearing the selection (Esc, ⌘D) is
// not a photograph, so it does not overwrite the answer — arrowing A → B is "previous
// is A" whether or not the selection was empty for a moment in between.

import Foundation

public struct PreviousPhoto: Equatable, Sendable {

    /// The photograph the cursor was on before the current one; nil until it has moved.
    public private(set) var previous: URL?
    /// The photograph under the cursor as of the last `note`.
    public private(set) var current: URL?

    public init() {}

    /// Record that the primary selection is now `photo`.
    public mutating func note(_ photo: URL?) {
        guard photo != current else { return }
        if let current { previous = current }
        current = photo
    }

    /// Where Paste from Previous should read from, given what it would write to: nil when
    /// nothing was visited before, or when the previous photograph is the only target
    /// (pasting a recipe onto itself is a step in the history that changes nothing).
    public func source(writingTo targets: [URL]) -> URL? {
        guard let previous else { return nil }
        return targets.contains(where: { $0 != previous }) ? previous : nil
    }
}

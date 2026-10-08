/// Resolves sparse selections in source order without scanning the entire library.
/// Rebuild whenever the source array changes; returned positions refer to that array.
public struct SelectionMembershipIndex<ID: Hashable & Sendable>: Sendable {
    private let positionsByID: [ID: Int]
    private let count: Int
    private let hasDuplicates: Bool

    public init(_ ids: [ID]) {
        var positions: [ID: Int] = [:]
        var duplicates = false
        for (position, id) in ids.enumerated() {
            if positions.updateValue(position, forKey: id) != nil { duplicates = true }
        }
        positionsByID = positions
        count = ids.count
        hasDuplicates = duplicates
    }

    /// Nil requests a linear scan for dense selections or duplicate source IDs.
    /// A scan preserves every duplicate and avoids sorting a large selected set.
    public func positions(for selection: Set<ID>) -> [Int]? {
        if selection.isEmpty { return [] }
        guard !hasDuplicates, selection.count <= count / 2 else { return nil }
        return selection.compactMap { positionsByID[$0] }.sorted()
    }
}

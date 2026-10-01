// An in-tree `drop(_:)` shares its NAME with the stdlib's `Sequence.drop(while:)`.
// The labels pass is name-based, so before the stdlib table it judged the stdlib call
// below against the in-tree declaration and reported a perfectly good call
// (docs/audit-2026-09/STATUS.md, "a third class of surface-checker false finding").
struct FixtureQueue {
    var items: [Int] = []
    mutating func drop(_ n: Int) { items.removeFirst(n) }
}

func fixtureTail(_ values: [Int]) -> [Int] {
    var queue = FixtureQueue(items: values)
    queue.drop(1)
    let rest = queue.items
    return Array(rest.drop(while: { $0 < 3 }))
}

// The stdlib table must stay NARROW: it may clear `drop(while:)`, which the stdlib
// really declares, and nothing else. `drop(count:)` exists nowhere — not in-tree, not
// in the stdlib — and must still be reported.
struct FixtureQueue {
    var items: [Int] = []
    mutating func drop(_ n: Int) { items.removeFirst(n) }
}

func fixtureShorten(_ values: [Int]) -> [Int] {
    var queue = FixtureQueue(items: values)
    queue.drop(count: 1)
    return queue.items
}

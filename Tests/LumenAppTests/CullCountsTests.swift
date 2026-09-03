// The first tests the app layer has ever had. docs/21 pattern 6: "the app layer has
// no test target… every UI-to-recipe binding, the keymap, culling, the prefetch ring…
// unfalsifiable by construction." This file starts paying that down with the memoised
// chrome counts — the numbers the filter bar and sidebar show on every body pass.
#if os(macOS)
import XCTest
@testable import LumenApp

final class CullCountsTests: XCTestCase {

    private func photo(_ name: String, flag: PhotoFlag = .none, rating: Int = 0,
                       label: ColorLabel = .none) -> PhotoItem {
        var item = PhotoItem(id: URL(fileURLWithPath: "/roll/\(name).arw"))
        item.flag = flag
        item.rating = rating
        item.label = label
        return item
    }

    func testCountsMatchTheFourteenReducesTheyReplaced() {
        let roll = [
            photo("a", flag: .picked, rating: 5, label: .red),
            photo("b", flag: .picked, rating: 3),
            photo("c", flag: .rejected, label: .blue),
            photo("d", rating: 1, label: .red),
            photo("e"),
        ]
        let counts = AppState.CullCounts.counting(roll)

        // The exact expressions FilterBar used to evaluate per body pass.
        for flag in PhotoFlag.allCases {
            XCTAssertEqual(counts.flags[flag] ?? 0,
                           roll.reduce(0) { $0 + ($1.flag == flag ? 1 : 0) },
                           "flag \(flag)")
        }
        for minimum in 1...5 {
            XCTAssertEqual(counts.ratingAtLeast[minimum],
                           roll.reduce(0) { $0 + ($1.rating >= minimum ? 1 : 0) },
                           "rating ≥ \(minimum)")
        }
        for label in ColorLabel.allCases {
            XCTAssertEqual(counts.labels[label] ?? 0,
                           roll.reduce(0) { $0 + ($1.label == label ? 1 : 0) },
                           "label \(label)")
        }
    }

    func testAnEmptyRollCountsToZeroEverywhere() {
        let counts = AppState.CullCounts.counting([])
        XCTAssertTrue(counts.flags.isEmpty)
        XCTAssertTrue(counts.labels.isEmpty)
        XCTAssertEqual(counts.ratingAtLeast, [Int](repeating: 0, count: 6))
    }

    func testARatingCountsIntoEveryThresholdItClears() {
        let counts = AppState.CullCounts.counting([photo("a", rating: 3)])
        XCTAssertEqual(Array(counts.ratingAtLeast[1...5]), [1, 1, 1, 0, 0],
                       "a 3-star photo satisfies ≥1, ≥2 and ≥3 and nothing above")
    }

    func testARatingPastFiveDoesNotWalkOffTheArray() {
        // `rating` is clamped at count time, not trusted: a corrupt catalog row must
        // cost a wrong count, not a crash in the filter bar.
        let counts = AppState.CullCounts.counting([photo("a", rating: 9)])
        XCTAssertEqual(Array(counts.ratingAtLeast[1...5]), [1, 1, 1, 1, 1])
    }
}
#endif

#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

@MainActor
final class MemoryPhotoOrderingTests: XCTestCase {
    private func photo(_ name: String, folder: String = "first", rating: Int = 0,
                       flag: PhotoFlag = .unflagged, label: ColorLabel? = nil) -> PhotoItem {
        var item = PhotoItem(id: URL(fileURLWithPath: "/synthetic/\(folder)/\(name)"))
        item.rating = rating; item.flag = flag; item.label = label
        return item
    }

    func testMemoryComparatorIsStrictForEqualKeysAndNamesInEitherDirection() {
        let values = [photo("DSC_2.JPG"), photo("DSC_2.JPG", folder: "second"),
                      photo("DSC_10.JPG", rating: 4, flag: .pick, label: .blue),
                      photo("DSC_1.JPG", rating: 4, flag: .reject, label: .red)]
        for order in [SortOrder.rating, .flag, .label, .filename] {
            for ascending in [true, false] {
                func precedes(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
                    AppState.memoryOrderPrecedes(a, b, order: order, ascending: ascending)
                }
                for a in values {
                    XCTAssertFalse(precedes(a, a), "irreflexivity: \(order) ascending=\(ascending)")
                    for b in values {
                        XCTAssertFalse(precedes(a, b) && precedes(b, a), "asymmetry: \(order)")
                        for c in values where precedes(a, b) && precedes(b, c) {
                            XCTAssertTrue(precedes(a, c), "transitivity: \(order)")
                        }
                    }
                }
            }
        }
    }

    func testDescendingEqualKeysRetainIncomingSourceOrder() {
        let values = [photo("DSC_1.JPG"), photo("DSC_2.JPG"), photo("DSC_10.JPG")]
        for order in [SortOrder.rating, .flag, .label] {
            XCTAssertEqual(values.sorted {
                AppState.memoryOrderPrecedes($0, $1, order: order, ascending: false)
            }.map(\.id), values.map(\.id))
        }
        let equalNames = [photo("same.JPG", folder: "z"), photo("same.JPG", folder: "a")]
        XCTAssertEqual(equalNames.sorted {
            AppState.memoryOrderPrecedes($0, $1, order: .filename, ascending: false)
        }.map(\.id), equalNames.map(\.id))
    }

    func testScalarDirectionsAndNaturalFilenameOrderingStayCompatible() {
        let values = [photo("DSC_10.JPG", rating: 2, flag: .unflagged, label: .red),
                      photo("DSC_2.JPG", rating: 5, flag: .pick, label: .blue),
                      photo("DSC_1.JPG", rating: 0, flag: .reject)]
        func names(_ order: SortOrder, _ ascending: Bool) -> [String] {
            values.sorted { AppState.memoryOrderPrecedes($0, $1, order: order,
                                                        ascending: ascending) }.map(\.filename)
        }
        XCTAssertEqual(names(.rating, true), ["DSC_1.JPG", "DSC_10.JPG", "DSC_2.JPG"])
        XCTAssertEqual(names(.rating, false), ["DSC_2.JPG", "DSC_10.JPG", "DSC_1.JPG"])
        XCTAssertEqual(names(.flag, true), ["DSC_1.JPG", "DSC_10.JPG", "DSC_2.JPG"])
        XCTAssertEqual(names(.flag, false), ["DSC_2.JPG", "DSC_10.JPG", "DSC_1.JPG"])
        XCTAssertEqual(names(.label, true), ["DSC_1.JPG", "DSC_10.JPG", "DSC_2.JPG"])
        XCTAssertEqual(names(.label, false), ["DSC_2.JPG", "DSC_10.JPG", "DSC_1.JPG"])
        XCTAssertEqual(names(.filename, true), ["DSC_1.JPG", "DSC_2.JPG", "DSC_10.JPG"])
        XCTAssertEqual(names(.filename, false), ["DSC_10.JPG", "DSC_2.JPG", "DSC_1.JPG"])
    }
}
#endif

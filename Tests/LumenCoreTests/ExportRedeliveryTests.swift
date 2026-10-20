// ExportRedeliveryTests.swift
//
// Overwrite is "the re-delivery of a corrected batch". Two frames of a batch that
// render to one name (day1/DSC_0001.NEF and day2/DSC_0001.NEF under `{name}`) land
// at X and X-1. Re-delivering used to skip X-1 because it was on disk from the last
// run, write a fresh X-2, and leave the stale render at X-1, one more copy per run.

import XCTest
@testable import LumenCore

final class ExportRedeliveryTests: XCTestCase {

    private let folder = URL(fileURLWithPath: "/Deliveries")
    private var x: URL { folder.appendingPathComponent("DSC_0001.jpg") }
    private var x1: URL { folder.appendingPathComponent("DSC_0001-1.jpg") }
    private var x2: URL { folder.appendingPathComponent("DSC_0001-2.jpg") }

    func testOverwriteReplacesTheDuplicateItDeliveredLastTime() {
        let onDisk: Set<URL> = [x, x1]
        let claimed: Set<URL> = [x]
        XCTAssertEqual(ExportRecipe.placement(for: x, policy: .overwrite,
                                              claimedThisRun: { claimed.contains($0) },
                                              existsOnDisk: { onDisk.contains($0) }),
                       .write(x1, replacing: true))
    }

    func testOverwriteStillNeverLandsOnAnOriginal() {
        let onDisk: Set<URL> = [x, x1]
        let claimed: Set<URL> = [x]
        XCTAssertEqual(ExportRecipe.placement(for: x, policy: .overwrite,
                                              claimedThisRun: { claimed.contains($0) },
                                              existsOnDisk: { onDisk.contains($0) },
                                              isOriginal: { $0 == self.x1 }),
                       .write(x2, replacing: false))
    }

    func testRenameStillStepsOverWhatIsOnDisk() {
        let onDisk: Set<URL> = [x, x1]
        let claimed: Set<URL> = [x]
        XCTAssertEqual(ExportRecipe.placement(for: x, policy: .rename,
                                              claimedThisRun: { claimed.contains($0) },
                                              existsOnDisk: { onDisk.contains($0) }),
                       .write(x2, replacing: false))
    }
}

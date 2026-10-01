// ExportCollisionTests.swift
// docs/11 §Naming: "Collision policy | rename / overwrite / skip | rename". Export had
// only the first; `ExportRecipe.placement` is the decision for all three, and the
// batch loop in `AppStateActions.export` asks it once per file.

import XCTest
@testable import LumenCore

final class ExportCollisionTests: XCTestCase {

    private let folder = URL(fileURLWithPath: "/Deliveries")
    private func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    private func place(_ wanted: URL, _ policy: ExportCollisionPolicy,
                       claimed: Set<URL> = [], onDisk: Set<URL> = []) -> ExportPlacement {
        ExportRecipe.placement(for: wanted, policy: policy,
                               claimedThisRun: { claimed.contains($0) },
                               existsOnDisk: { onDisk.contains($0) })
    }

    // MARK: - A free name is written, whatever the policy

    func testAFreeNameIsWrittenWithoutReplacingAnything() {
        for policy in ExportCollisionPolicy.allCases {
            XCTAssertEqual(place(file("a.jpg"), policy), .write(file("a.jpg"), replacing: false),
                           "\(policy)")
        }
    }

    // MARK: - The three answers to a file that was already there

    func testRenameIsTheCallTheBatchMadeBeforeThePolicyExisted() {
        let onDisk: Set<URL> = [file("a.jpg"), file("a-1.jpg")]
        let claimed: Set<URL> = [file("a-2.jpg")]
        let legacy = ExportRecipe.disambiguated(file("a.jpg")) {
            claimed.contains($0) || onDisk.contains($0)
        }
        XCTAssertEqual(place(file("a.jpg"), .rename, claimed: claimed, onDisk: onDisk),
                       .write(legacy, replacing: false))
        XCTAssertEqual(legacy, file("a-3.jpg"))
    }

    func testOverwriteReplacesTheFileThatWasThere() {
        XCTAssertEqual(place(file("a.jpg"), .overwrite, onDisk: [file("a.jpg")]),
                       .write(file("a.jpg"), replacing: true))
    }

    func testSkipLeavesTheFileThatWasThere() {
        XCTAssertEqual(place(file("a.jpg"), .skip, onDisk: [file("a.jpg")]),
                       .skip(file("a.jpg")))
    }

    // MARK: - A name this run claimed is never an overwrite or a skip

    /// `day1/DSC_0001.NEF` and `day2/DSC_0001.NEF` render to one name. Under Overwrite
    /// the second would replace the first and the count would claim both; under Skip
    /// the second frame would silently not be delivered. Neither is what a policy about
    /// files from BEFORE the run asked for.
    func testTwoFramesOfOneBatchNeverReplaceOrDropEachOther() {
        let first = file("DSC_0001.jpg")
        for policy in ExportCollisionPolicy.allCases {
            // Written this run, so it is now on disk too.
            let placed = place(first, policy, claimed: [first], onDisk: [first])
            XCTAssertEqual(placed, .write(file("DSC_0001-1.jpg"), replacing: false),
                           "\(policy): the second frame of the batch")
        }
    }

    /// Default and decode: a preset stored before the policy existed keeps renaming.
    func testAPresetWithoutAPolicyRenames() throws {
        XCTAssertEqual(ExportRecipe(name: "x").collision, .rename)
        for recipe in ExportRecipe.defaults {
            XCTAssertEqual(recipe.collision, .rename, recipe.name)
        }
        let old = #"{"id":"a","name":"web","format":"jpeg"}"#
        XCTAssertEqual(try JSONDecoder().decode(ExportRecipe.self,
                                                from: Data(old.utf8)).collision, .rename)
        let later = #"{"id":"a","name":"web","collision":"askEveryTime"}"#
        XCTAssertEqual(try JSONDecoder().decode(ExportRecipe.self,
                                                from: Data(later.utf8)).collision, .rename,
                       "a policy a later build invented falls back to the safe one")
        let round = try JSONDecoder().decode(
            ExportRecipe.self,
            from: JSONEncoder().encode(ExportRecipe(name: "x", collision: .skip)))
        XCTAssertEqual(round.collision, .skip)
    }
}

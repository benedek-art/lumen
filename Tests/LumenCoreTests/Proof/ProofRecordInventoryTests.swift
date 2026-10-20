// ProofRecordInventoryTests.swift
//
// The drift gate (ControlProofTests, nightly) walks ProofRegistry.all and opens one
// record per id, so a record left behind by a renamed or removed control is never read,
// and recording mode never deletes one. This checks the inventory on every push without
// rendering anything: records/ holds exactly the registry's ids, and the fields the
// runner copies from the registry (panel, frame, travel, no baseline claim) still match.
import XCTest

final class ProofRecordInventoryTests: XCTestCase {

    func testRecordsDirectoryHoldsExactlyTheRegistrysIds() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: ProofRecordStore.directory, includingPropertiesForKeys: nil)
        let onDisk = Set(files.map(\.lastPathComponent))
        let ids = ProofRegistry.all.map(\.id)
        let expected = Set(ids.map { "\($0).json" })
        XCTAssertEqual(ids.count, expected.count, "duplicate ids in ProofRegistry")
        XCTAssertEqual(onDisk.subtracting(expected).sorted(), [],
                       "records with no registry entry: delete them")
        XCTAssertEqual(expected.subtracting(onDisk).sorted(), [],
                       "registry ids with no committed record")
    }

    func testCommittedRecordsCarryTheRegistrysMetadata() throws {
        for spec in ProofRegistry.all {
            guard let record = ProofRecordStore.read(spec.id) else {
                XCTFail("\(spec.id): record missing or undecodable")
                continue
            }
            XCTAssertEqual(record.id, spec.id)
            XCTAssertEqual(record.panel, spec.panel, spec.id)
            XCTAssertEqual(record.frame, spec.frameName, spec.id)
            XCTAssertEqual(record.travelLow, spec.low, spec.id)
            XCTAssertEqual(record.travelHigh, spec.high, spec.id)
            // ProofRunner never measures a baseline; a tier here was written by hand.
            XCTAssertNil(record.baselineTier, spec.id)
            XCTAssertNil(record.baselineNote, spec.id)
        }
    }
}

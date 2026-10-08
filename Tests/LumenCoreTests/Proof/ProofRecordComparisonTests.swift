import XCTest

final class ProofRecordComparisonTests: XCTestCase {
    private func record() throws -> ProofRecord {
        try XCTUnwrap(ProofRecordStore.read("color.protectSkin"))
    }

    func testTinyDriftHiddenBySummaryNamesTheFieldAndExactDelta() throws {
        let committed = try record()
        var measured = committed
        // Plant drift relative to the ruler: an intentional numerical correction
        // must not accidentally turn the negative control into self-comparison.
        measured.frontLoading -= 1.2e-6
        XCTAssertEqual(measured.summary, committed.summary)
        XCTAssertFalse(measured.agrees(with: committed))
        let differences = measured.comparisonDifferences(with: committed)
        XCTAssertEqual(differences.count, 1)
        let difference = try XCTUnwrap(differences.first)
        XCTAssertTrue(difference.hasPrefix("frontLoading:"))
        XCTAssertTrue(difference.contains(String(measured.frontLoading)))
        XCTAssertTrue(difference.contains("absolute delta"))
        XCTAssertTrue(difference.contains("tolerance 1e-06"))
    }

    func testEveryNumericalFieldUsesTheExistingAbsoluteTolerance() throws {
        let committed = try record()
        let fields: [(String, WritableKeyPath<ProofRecord, Double>)] = [
            ("smallestLiveStep", \.smallestLiveStep), ("authority", \.authority),
            ("meanSeparation", \.meanSeparation), ("frontLoading", \.frontLoading),
            ("givenBack", \.givenBack)]
        for (name, path) in fields {
            var measured = committed
            measured[keyPath: path] += 0.5e-6
            XCTAssertTrue(measured.agrees(with: committed), name)
            measured[keyPath: path] += 2e-6
            XCTAssertFalse(measured.agrees(with: committed), name)
            XCTAssertEqual(measured.comparisonDifferences(with: committed).count, 1)
            XCTAssertTrue(measured.comparisonDifferences(with: committed)[0].hasPrefix(name + ":"))
        }
        let optionalFields: [(String, WritableKeyPath<ProofRecord, Double?>)] = [
            ("overshoot", \.overshoot), ("overshootAbove", \.overshootAbove),
            ("overshootBelow", \.overshootBelow), ("hueRotation", \.hueRotation)]
        for (name, path) in optionalFields {
            var baseline = committed
            baseline[keyPath: path] = 1
            var measured = baseline
            measured[keyPath: path] = 1 + 0.5e-6
            XCTAssertTrue(measured.agrees(with: baseline), name)
            measured[keyPath: path] = 1 + 2e-6
            XCTAssertFalse(measured.agrees(with: baseline), name)
            measured[keyPath: path] = nil
            XCTAssertFalse(measured.agrees(with: baseline), name)
            XCTAssertTrue(measured.comparisonDifferences(with: baseline)[0].hasPrefix(name + ":"))
        }
    }

    func testNonfiniteMeasurementsCannotDisappearFromDiagnostics() throws {
        let committed = try record()
        for invalid in [Double.nan, .infinity, -.infinity] {
            var measured = committed
            measured.meanSeparation = invalid
            XCTAssertFalse(measured.agrees(with: committed))
            XCTAssertEqual(measured.comparisonDifferences(with: committed).count, 1)
            XCTAssertTrue(measured.comparisonDifferences(with: committed)[0].hasPrefix("meanSeparation:"))
        }
    }

    func testDiscreteFieldsRemainExactAndSelfComparisonStillAgrees() throws {
        let committed = try record()
        XCTAssertTrue(committed.agrees(with: committed))
        XCTAssertTrue(committed.comparisonDifferences(with: committed).isEmpty)
        var measured = committed
        measured.id += "-other"
        measured.frame += "-other"
        measured.deadSteps += 1
        measured.isMonotone.toggle()
        XCTAssertFalse(measured.agrees(with: committed))
        XCTAssertEqual(measured.comparisonDifferences(with: committed).count, 4)
    }
}

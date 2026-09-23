#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

/// UI eligibility tied to the actual tonal blend. Complements the pure-core
/// FilmLabDisplayTransformTests; this does not claim hosted pointer verification.
final class FilmDisplayTransformAvailabilityTests: XCTestCase {
    func testMissingUnknownAndNonpositiveFilmsDoNotDisableTheTransform() {
        XCTAssertNil(FilmDisplayTransformAvailability.replacingStock(for: nil))
        for amount in [-1.0, 0, 1, 50, 99, 100, 101] {
            XCTAssertNil(FilmDisplayTransformAvailability.replacingStock(
                for: FilmLab(stock: "unknown-stock-for-availability-test", amount: amount)))
        }
        for stock in FilmStock.all {
            for amount in [-1.0, 0] {
                XCTAssertNil(FilmDisplayTransformAvailability.replacingStock(
                    for: FilmLab(stock: stock.id, amount: amount)))
            }
        }
    }

    func testEveryKnownStockKeepsTheTransformEditableUntilFullStrength() {
        for stock in FilmStock.all {
            for amount in [0.001, 1.0, 50, 99, 99.999, 100.0.nextDown] {
                XCTAssertNil(FilmDisplayTransformAvailability.replacingStock(
                    for: FilmLab(stock: stock.id, amount: amount))?.name,
                    "\(stock.id) at \(amount)% still blends the display transform")
            }
        }
    }

    func testFullOrClampedHigherStrengthNamesTheReplacingStock() {
        for stock in FilmStock.all {
            for amount in [100.0, 100.0.nextUp, 101, 200] {
                XCTAssertEqual(FilmDisplayTransformAvailability.replacingStock(
                    for: FilmLab(stock: stock.id, amount: amount))?.id, stock.id)
            }
        }
    }

    func testStockLookupKeepsItsExistingCaseInsensitiveBehavior() {
        let stock = FilmStock.portra400
        XCTAssertEqual(FilmDisplayTransformAvailability.replacingStock(
            for: FilmLab(stock: stock.id.uppercased(), amount: 100))?.id, stock.id)
        XCTAssertNil(FilmDisplayTransformAvailability.replacingStock(
            for: FilmLab(stock: stock.id.uppercased(), amount: 50)))
    }

    func testUnknownStockAtFullStrengthStillUsesTheChosenTransform() {
        var recipe = Recipe()
        recipe.look.filmLab = FilmLab(stock: "unknown-stock-for-availability-test", amount: 100)
        let neutral = RenderPlan(recipe: recipe, lutSize: 5)
        recipe.look.render = RenderParams(preset: "Linear")
        let linear = RenderPlan(recipe: recipe, lutSize: 5)
        XCTAssertNil(neutral.filmChain)
        XCTAssertNil(linear.filmChain)
        XCTAssertNil(FilmDisplayTransformAvailability.replacingStock(for: recipe.look.filmLab))
        let scene = RGB(gray: 0.72)
        XCTAssertGreaterThan(abs(neutral.exactColor(scene).r - linear.exactColor(scene).r), 0.01,
                             "unknown stocks must not hide an active display transform")
    }

    func testAvailabilityAgreesWithActualDisplayBaseInfluenceAtPartialAndFullStrength() {
        // Same solved-base contract as FilmLabDisplayTransformTests: the transform
        // preset affects the partial blend, but has zero weight at full strength.
        for amount in [0.0, 1, 50, 99, 100, 101] {
            var neutral = Recipe()
            neutral.look.filmLab = FilmLab(stock: FilmStock.portra400.id, amount: amount)
            var linear = neutral
            linear.look.render = RenderParams(preset: "Linear")
            let a = RenderPlan(recipe: neutral, lutSize: 5)
            let b = RenderPlan(recipe: linear, lutSize: 5)
            var difference = 0.0
            for ev in stride(from: -6.0, through: 3.0, by: 0.5) {
                let sample = RGB(gray: 0.18 * pow(2, ev))
                let x = a.exactColor(sample), y = b.exactColor(sample)
                for channel in 0..<3 { difference = max(difference, abs(x[channel] - y[channel])) }
            }
            let inert = FilmDisplayTransformAvailability.replacingStock(for: neutral.look.filmLab) != nil
            XCTAssertEqual(inert, amount >= 100, "UI boundary must match the solved blend")
            if amount < 100 {
                XCTAssertGreaterThan(difference, 1e-5, "partial fixture must retain real display-base influence")
            } else {
                XCTAssertLessThan(difference, 1e-12, "full film replacement must not depend on the preset")
            }
        }
    }

    func testUIUsesThePureAvailabilityForBadgeDisablingAndAccurateHelp() throws {
        let raw = try LayoutSource.read("Sources/LumenApp/LookPanel.swift")
        let source = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let stockProperty = try XCTUnwrap(source.components(separatedBy: "private var replacingStock: String?").last)
            .components(separatedBy: "private var transformIsInert").first ?? ""
        XCTAssertTrue(stockProperty.contains("FilmDisplayTransformAvailability.replacingStock("))
        XCTAssertTrue(stockProperty.contains("for: state.currentRecipe.look.filmLab)?.name"))
        XCTAssertTrue(source.contains("private var transformIsInert: Bool { replacingStock != nil }"))
        XCTAssertTrue(source.contains(".disabled(transformIsInert)"))
        XCTAssertTrue(source.contains(".opacity(transformIsInert ? 0.30 : 1)"))
        XCTAssertTrue(source.contains("badge: replacingStockName"))
        XCTAssertTrue(source.contains("guard let stock = replacingStock else { return nil }"))
        XCTAssertTrue(source.contains("help: FilmDisplayTransformAvailability.stockHelp"))
        XCTAssertEqual(source.components(separatedBy: ".help(FilmDisplayTransformAvailability.transformHelp)").count - 1, 2,
                       "the transform header and Film Strength must both explain the blend")
        XCTAssertFalse(source.contains("Loading a stock replaces the Display Transform"))
        XCTAssertTrue(FilmDisplayTransformAvailability.transformHelp.contains("Below 100%"))
        XCTAssertTrue(FilmDisplayTransformAvailability.transformHelp.contains("lower Strength to edit it"))
        XCTAssertTrue(FilmDisplayTransformAvailability.stockHelp.contains("Only 100% fully replaces it"))
        XCTAssertTrue(source.contains("the render uses your Display Transform"))
    }
}
#endif

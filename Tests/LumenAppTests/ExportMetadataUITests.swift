#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

final class ExportMetadataUITests: XCTestCase {
    func testEnabledInvalidRecipeBlocksTheBatchAndNamesTheOffendingPreset() {
        let web = ExportRecipe(name: "Web", metadata: MetadataPolicy(contact: "studio@example.invalid"))
        let print = ExportRecipe(name: "Print TIFF", metadata: MetadataPolicy(contact: "ask the studio"))
        let eligibility = ExportContactEligibility(recipes: [web, print])
        XCTAssertFalse(eligibility.canExport)
        XCTAssertEqual(eligibility.issue?.recipeID, print.id)
        XCTAssertEqual(eligibility.issue?.recipeName, "Print TIFF")
        XCTAssertEqual(eligibility.issue?.message, print.metadata.contactValidationMessage)
    }

    func testDisabledInvalidRecipeDoesNotBlockAndCheckingItDoes() {
        let web = ExportRecipe(name: "Web")
        var print = ExportRecipe(name: "Print", enabled: false, metadata: MetadataPolicy(contact: "ask the studio"))
        XCTAssertTrue(ExportContactEligibility(recipes: [web, print]).canExport)
        print.enabled = true
        XCTAssertFalse(ExportContactEligibility(recipes: [web, print]).canExport)
        print.metadata.contact = "example.invalid/studio"
        XCTAssertTrue(ExportContactEligibility(recipes: [web, print]).canExport)
    }

    func testFirstEnabledProblemAdvancesWithoutRewritingPresets() {
        let first = ExportRecipe(name: " ", metadata: MetadataPolicy(contact: " first unsupported value "))
        let second = ExportRecipe(name: "Second", metadata: MetadataPolicy(contact: "second unsupported value"))
        var recipes = [first, second]
        let original = recipes
        let issue = ExportContactEligibility(recipes: recipes).issue
        XCTAssertEqual(issue?.recipeID, first.id)
        XCTAssertEqual(issue?.recipeName, "Untitled recipe")
        XCTAssertEqual(recipes, original)
        recipes[0].enabled = false
        XCTAssertEqual(ExportContactEligibility(recipes: recipes).issue?.recipeID, second.id)
        XCTAssertEqual(recipes[0].metadata.contact, first.metadata.contact)
        XCTAssertEqual(recipes[1].metadata.contact, second.metadata.contact)
        XCTAssertTrue(ExportContactEligibility(recipes: []).canExport,
                      "No-photo/no-recipe eligibility remains the existing footer's responsibility")
    }

    func testReadbackCaptionNamesTestedFormatsAndLimitsWithoutOldUnverifiedClaim() {
        let text = ExportContactEligibility.metadataReadbackNote
        for phrase in ["JPEG", "HEIC", "TIFF", "PNG", "email/site contact", "print density",
                       "Proprietary fields and other readers may vary"] { XCTAssertTrue(text.contains(phrase)) }
        XCTAssertFalse(text.contains("not yet verified"))
        XCTAssertFalse(text.contains("guarantee"))
    }

    func testUIWiresInlineErrorFooterActionAndBothExportGates() throws {
        let source = try sourceWithoutComments()
        let footer = try body("private var footerActions", in: source)
        XCTAssertTrue(footer.contains("|| !contactEligibility.canExport"))
        XCTAssertTrue(footer.contains("guard contactEligibility.canExport else { return }"))
        XCTAssertTrue(footer.contains(".disabled(exportDisabled)"))
        XCTAssertTrue(footer.contains("state.chooseExportDestination()"))
        let footerContainer = try body("private var footer: some View", in: source)
        XCTAssertTrue(footerContainer.contains("contactValidationSection"))
        let warning = try body("private var contactValidationSection", in: source)
        XCTAssertTrue(warning.contains("selectedRecipeID = issue.recipeID"))
        XCTAssertTrue(warning.contains("issue.recipeName"))
        XCTAssertTrue(warning.contains("issue.message"))
        let metadata = try body("private var metadataSection", in: source)
        XCTAssertTrue(metadata.contains("recipe.metadata.contactValidationMessage"))
        XCTAssertTrue(metadata.contains(".accessibilityLabel(\"Contact error: \" + message)"))
        XCTAssertTrue(metadata.contains("ExportNote(ExportContactEligibility.metadataReadbackNote)"))
        XCTAssertTrue(metadata.contains("optionalText(\\.metadata.contact)"))
        let binding = try body("private func optionalText", in: source)
        XCTAssertTrue(binding.contains("trimmed.isEmpty ? nil : value"), "Do not replace user text with a normalized validation value")
    }

    private func sourceWithoutComments() throws -> String {
        let raw = try LayoutSource.read("Sources/LumenApp/ExportSheet.swift")
        // Full-line comments are sufficient here: the pins below are complete code
        // expressions and scoped bodies, never claims copied from prose.
        return raw.replacingOccurrences(of: "(?m)^\\s*//[^\\n]*", with: "", options: .regularExpression)
    }

    private func body(_ declaration: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration))
        let open = try XCTUnwrap(source[start.upperBound...].firstIndex(of: "{"))
        var depth = 0
        for cursor in source[open...].indices {
            if source[cursor] == "{" { depth += 1 }
            if source[cursor] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...cursor]) }
            }
        }
        XCTFail("Unclosed body: \(declaration)")
        return ""
    }
}
#endif

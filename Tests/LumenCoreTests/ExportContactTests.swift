import XCTest
@testable import LumenCore

final class ExportContactTests: XCTestCase {
    func testEmailAndWebsiteKindsReflectTheExistingUIContract() throws {
        for email in ["studio@example.invalid", "name+photos@example.invalid", " user@local "] {
            let policy = MetadataPolicy(contact: email)
            XCTAssertEqual(policy.contactKind, .email)
            XCTAssertNoThrow(try policy.validateContact())
            XCTAssertEqual(policy.contact, email, "Validation must not mutate stored presets")
        }
        for site in ["https://example.invalid/studio?x=1&y=2", "http://example.invalid", "example.invalid/photos", "www.example.invalid"] {
            let policy = MetadataPolicy(contact: site)
            XCTAssertEqual(policy.contactKind, .website)
            XCTAssertNoThrow(try policy.validateContact())
        }
    }

    func testUnsupportedNonemptyTextIsNotMislabelledOrSilentlyDropped() {
        for text in ["ask the studio", "@example.invalid", "user@", "a@@example.invalid",
                     "a@example.invalid,b@example.invalid", "ftp://example.invalid", "file:///tmp/contact",
                     "mailto:studio@example.invalid", "https://user:password@example.invalid"] {
            let policy = MetadataPolicy(contact: text)
            XCTAssertNil(policy.contactKind, text)
            XCTAssertNotNil(policy.contactValidationMessage, text)
            XCTAssertThrowsError(try policy.validateContact(), text) { error in
                XCTAssertEqual(error.localizedDescription, policy.contactValidationMessage)
            }
        }
    }

    func testAbsentContactAddsNoRequirementAndIsNotAnOptIn() {
        for contact in [nil, "", " \n\t"] as [String?] {
            let policy = MetadataPolicy(contact: contact)
            XCTAssertNil(policy.contactKind)
            XCTAssertNil(policy.contactValidationMessage)
            XCTAssertNoThrow(try policy.validateContact())
        }
    }
}

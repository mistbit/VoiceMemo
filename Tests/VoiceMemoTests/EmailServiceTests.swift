import XCTest
@testable import VoiceMemo

final class EmailServiceTests: XCTestCase {

    func testParseRecipients_SingleEmail() {
        let input = "test@example.com"
        let expected = "test@example.com"
        let result = EmailService.parseRecipients(input)
        XCTAssertEqual(result, expected)
    }

    func testParseRecipients_MultipleEmails() {
        let input = "a@b.com,c@d.com"
        let expected = "a@b.com,c@d.com"
        let result = EmailService.parseRecipients(input)
        XCTAssertEqual(result, expected)
    }

    func testParseRecipients_WithSpaces() {
        let input = " a@b.com , c@d.com "
        let expected = "a@b.com,c@d.com"
        let result = EmailService.parseRecipients(input)
        XCTAssertEqual(result, expected)
    }

    func testParseRecipients_EmptyParts() {
        let input = "a@b.com,,c@d.com,"
        let expected = "a@b.com,c@d.com"
        let result = EmailService.parseRecipients(input)
        XCTAssertEqual(result, expected)
    }

    func testParseRecipients_OnlySpaces() {
        let input = "   "
        let expected = ""
        let result = EmailService.parseRecipients(input)
        XCTAssertEqual(result, expected)
    }
}

import XCTest
@testable import SummonCore

/// The grounding guard keeps a model-written value only when the copied text
/// states it, tolerating format and rejecting content the text never had.
final class SmartPasteGroundingTests: XCTestCase {
    private let bio = """
        Hi, I'm Ananya Iyer, a senior iOS engineer with 9 years of experience. Since March 2021 I \
        have led the patient-app team at Lumora Health in Bengaluru. Day to day I work in Swift, \
        SwiftUI, Combine and Core Data. I studied Computer Science (B.Tech) at the College of \
        Engineering, Pune, graduating in 2016. Reach me at ananya.iyer@lumora.example or \
        +91 55555 01234. Portfolio: https://ananya.example.dev, LinkedIn: linkedin.com/in/ananya-iyer-ios. \
        Address: Flat 4B, Palm Grove Apartments, 12th Main Road, Bengaluru 560038. Joined 04/01/2020.
        """

    func testKeepsCopiedValuesWhateverTheirCaseOrSpacing() {
        for value in ["Ananya Iyer", "ANANYA  IYER", "senior iOS engineer", "Lumora Health",
                      "ananya.iyer@lumora.example", "Flat 4B, Palm Grove Apartments, 12th Main Road", "patient-app team"] {
            XCTAssertTrue(SmartPasteGrounding.isGrounded(value, in: bio), value)
        }
    }

    func testDropsValuesTheTextNeverStates() {
        // The three values Apple FM made up for r1-speaker on 2026-10-31, and kin.
        for value in ["Building Patient Apps at Scale", "30 minutes", "@ananya_ios", "Ananya Sharma",
                      "senior Android engineer", "+91 55555 09999", "2019-05"] {
            XCTAssertFalse(SmartPasteGrounding.isGrounded(value, in: bio), value)
        }
    }

    func testMatchesAListPartByPart() {
        XCTAssertTrue(SmartPasteGrounding.isGrounded("Swift, SwiftUI; Core Data", in: bio))
        XCTAssertTrue(SmartPasteGrounding.isGrounded("B.Tech, Computer Science", in: bio))
        XCTAssertFalse(SmartPasteGrounding.isGrounded("Swift, Kotlin", in: bio), "one made-up part drops the list")
    }

    func testMatchesAURLWithOrWithoutScheme() {
        XCTAssertTrue(SmartPasteGrounding.isGrounded("ananya.example.dev", in: bio))
        XCTAssertTrue(SmartPasteGrounding.isGrounded("https://www.linkedin.com/in/ananya-iyer-ios/", in: bio))
        XCTAssertFalse(SmartPasteGrounding.isGrounded("https://ananya.example.com", in: bio))
    }

    func testMatchesNumbersAcrossSeparatorsAndCountryCodes() {
        XCTAssertTrue(SmartPasteGrounding.isGrounded("+91-55555-01234", in: bio))
        XCTAssertTrue(SmartPasteGrounding.isGrounded("5555501234", in: bio), "a dropped country code")
        XCTAssertTrue(SmartPasteGrounding.isGrounded("560038", in: bio))
        XCTAssertTrue(SmartPasteGrounding.isGrounded("9", in: bio))
        XCTAssertTrue(SmartPasteGrounding.isGrounded("$120,000", in: "Base salary 120000 USD"))
    }

    /// Codex review 2026-11-02: digits from two numbers must not join into a third.
    func testNeverBuildsANumberFromTwoSeparateOnes() {
        let address = "Apartment 12, 34 Main Road, Pune 411001"
        XCTAssertFalse(SmartPasteGrounding.isGrounded("1234", in: address))
        XCTAssertFalse(SmartPasteGrounding.isGrounded("12 34", in: "Flat 12 and 34 Main Road"), "an unstated pair of numbers")
        XCTAssertTrue(SmartPasteGrounding.isGrounded("12", in: address))
        XCTAssertTrue(SmartPasteGrounding.isGrounded("411001", in: address))
        XCTAssertTrue(SmartPasteGrounding.isGrounded("1234", in: "Total 1,234 USD"), "a thousands comma joins")
        XCTAssertTrue(SmartPasteGrounding.isGrounded("4155550198", in: "Call (415) 555-0198 today"))
    }

    /// Codex review 2026-11-02 (second pass): a made-up prefix is not a country code, invalid comma
    /// grouping is two numbers, and the optional trunk zero is notation, not part of the number.
    func testNumberRulesStayTightAndAcceptCommonNotation() {
        XCTAssertFalse(SmartPasteGrounding.isGrounded("99999994155550198", in: "Call 4155550198"))
        XCTAssertTrue(SmartPasteGrounding.isGrounded("+14155550198", in: "Call 4155550198"), "a 1-digit country code")
        XCTAssertTrue(SmartPasteGrounding.isGrounded("+919876543210", in: "Call 9876543210"), "a 2-digit country code")
        XCTAssertFalse(SmartPasteGrounding.isGrounded("1234", in: "Apartment 12,34 Main Road"))
        XCTAssertTrue(SmartPasteGrounding.isGrounded("1234567", in: "Cost 12,34,567 rupees"), "Indian grouping")
        XCTAssertTrue(SmartPasteGrounding.isGrounded("1234567", in: "Cost 1,234,567 dollars"), "Western grouping")
        XCTAssertTrue(SmartPasteGrounding.isGrounded("+44 20 7123 4567", in: "Tel +44 (0)20 7123 4567"), "optional trunk zero")
        XCTAssertTrue(SmartPasteGrounding.isGrounded("020 7123 4567", in: "Tel +44 (0)20 7123 4567"), "UK local form")
        XCTAssertFalse(SmartPasteGrounding.isGrounded("+000 415 555 0198", in: "Call 4155550198"), "a 0 code is made up")
        XCTAssertFalse(SmartPasteGrounding.isGrounded("14155550198", in: "Call 4155550198"), "an added code needs a +")
        XCTAssertTrue(SmartPasteGrounding.isGrounded("1234.56", in: "Cost $1,234.56"), "grouped decimal")
        XCTAssertFalse(SmartPasteGrounding.isGrounded("123456", in: "Cost $1,234.56"), "100 times the amount")
        XCTAssertFalse(SmartPasteGrounding.isGrounded("1234.56", in: "Total 123456"), "a decimal is not the integer")
        XCTAssertFalse(SmartPasteGrounding.isGrounded("1234", in: "Total: 1234.56"), "the integer part is not the amount")
        XCTAssertFalse(SmartPasteGrounding.isGrounded("-123", in: "Balance: 123"), "the sign counts")
        XCTAssertFalse(SmartPasteGrounding.isGrounded("234", in: "Total: 1,234"), "not read out of a grouped number")
        XCTAssertTrue(SmartPasteGrounding.isGrounded("33123456789", in: "Tel +33\u{00A0}1\u{00A0}23\u{00A0}45\u{00A0}67\u{00A0}89"),
                      "non-breaking spaces in a phone")
        XCTAssertTrue(SmartPasteGrounding.isGrounded("10:30", in: "Meet at 10:30 today"), "a time written exactly")
        XCTAssertFalse(SmartPasteGrounding.isGrounded("1234567", in: "Account 1234 (0) 567"), "a (0) mid-number is not a trunk")
    }

    func testMatchesADateInAnotherFormat() {
        XCTAssertTrue(SmartPasteGrounding.isGrounded("2021-03", in: bio))
        XCTAssertTrue(SmartPasteGrounding.isGrounded("03/2021", in: bio))
        XCTAssertTrue(SmartPasteGrounding.isGrounded("2020-04-01", in: bio), "day-first 04/01/2020")
        XCTAssertTrue(SmartPasteGrounding.isGrounded("2020-01-04", in: bio), "month-first 04/01/2020")
        XCTAssertFalse(SmartPasteGrounding.isGrounded("2021-04", in: bio))
        XCTAssertFalse(SmartPasteGrounding.isGrounded("March 2022", in: bio))
    }

    func testRejectsAnEmptyValue() {
        XCTAssertFalse(SmartPasteGrounding.isGrounded("  ", in: bio))
    }
}

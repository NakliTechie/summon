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

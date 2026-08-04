import XCTest
@testable import SummonCore

final class FTSConsentTests: XCTestCase {
    func testEnableWithoutConsentFails() throws {
        let core = try SummonCore.inMemory()
        XCTAssertThrowsError(try core.setFTSEnabled(true))
        XCTAssertFalse(core.search.ftsEnabled)
    }

    func testEnableAfterConsent() throws {
        let core = try SummonCore.inMemory()
        try core.grantFTSConsent()
        try core.setFTSEnabled(true)
        XCTAssertTrue(core.search.ftsEnabled)
        try core.setFTSEnabled(false)
        XCTAssertFalse(core.search.ftsEnabled)
    }
}

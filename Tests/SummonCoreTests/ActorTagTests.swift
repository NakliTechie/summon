import XCTest
@testable import SummonCore

final class ActorTagTests: XCTestCase {
    func testJournalLabels() {
        XCTAssertEqual(ActorTag.user.journalLabel, "user")
        XCTAssertEqual(ActorTag.agent.journalLabel, "agent")
        XCTAssertEqual(ActorTag.system.journalLabel, "system")
        XCTAssertEqual(ActorTag.ext(id: "clipboard").journalLabel, "ext:clipboard")
    }

    func testRoundTrip() throws {
        let tags: [ActorTag] = [.user, .agent, .system, .ext(id: "raycast.foo")]
        for tag in tags {
            let parsed = try ActorTag(journalLabel: tag.journalLabel)
            XCTAssertEqual(parsed, tag)
        }
    }

    func testCodable() throws {
        let tag = ActorTag.ext(id: "x")
        let data = try JSONEncoder().encode(tag)
        let decoded = try JSONDecoder().decode(ActorTag.self, from: data)
        XCTAssertEqual(decoded, tag)
    }

    func testInvalid() {
        XCTAssertThrowsError(try ActorTag(journalLabel: "ext:"))
        XCTAssertThrowsError(try ActorTag(journalLabel: "nope"))
    }
}

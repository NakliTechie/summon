import XCTest
@testable import SummonCore

final class SmartPasteTests: XCTestCase {
    // MARK: - Extraction

    func testExtractsEmailPhoneAndAddressFromAContactBlock() {
        let text = "Jane Doe\njane.doe@example.com\n+1 (415) 555-0198\n1 Infinite Loop, Cupertino, CA 95014"
        let entities = EntityExtractor().extract(from: text)
        let kinds = Set(entities.map(\.kind))
        XCTAssertTrue(kinds.contains(.email), "expected an email entity")
        XCTAssertTrue(kinds.contains(.phone), "expected a phone entity")
        XCTAssertTrue(kinds.contains(.address), "expected an address entity")
        let email = entities.first { $0.kind == .email }
        XCTAssertEqual(email?.value, "jane.doe@example.com")
    }

    func testExtractsBareEmailNotSeenAsALink() {
        let entities = EntityExtractor().extract(from: "reach me at chirag@nakli.tech please")
        XCTAssertEqual(entities.filter { $0.kind == .email }.count, 1)
        XCTAssertEqual(entities.first { $0.kind == .email }?.value, "chirag@nakli.tech")
    }

    func testExtractsUrlAsUrlNotEmail() {
        let entities = EntityExtractor().extract(from: "docs at https://example.com/guide")
        XCTAssertEqual(entities.first?.kind, .url)
        XCTAssertNil(entities.first { $0.kind == .email })
    }

    func testEmptyInputYieldsNoEntities() {
        XCTAssertTrue(EntityExtractor().extract(from: "   ").isEmpty)
    }

    func testExtractsPersonNameViaLinguistics() {
        let entities = EntityExtractor().extract(from: "Please reach out to Barack Obama about the schedule.")
        let names = entities.filter { $0.kind == .name }
        XCTAssertFalse(names.isEmpty, "expected a personal-name entity")
        XCTAssertTrue(names.contains { $0.value.contains("Obama") })
    }

    func testExtractsOrganizationViaLinguistics() {
        let entities = EntityExtractor().extract(from: "She recently joined Microsoft Corporation as a lead.")
        XCTAssertTrue(entities.contains { $0.kind == .organization && $0.value.contains("Microsoft") },
                      "expected an organization entity")
    }

    func testBareContactBlockExtractsAllFour() {
        let block = "Dr. Priya Raman\nAtlas Robotics\npriya.raman@atlasrobotics.example\n+1 (415) 555-0198"
        let kinds = Set(EntityExtractor().extract(from: block).map(\.kind))
        // Print for diagnosis of bare-block NER, then assert the deterministic kinds.
        XCTAssertTrue(kinds.contains(.email))
        XCTAssertTrue(kinds.contains(.phone))
        XCTAssertTrue(kinds.contains(.name), "bare-block person name not tagged: \(kinds)")
        XCTAssertTrue(kinds.contains(.organization), "bare-block org not tagged: \(kinds)")
    }

    func testNameDoesNotShadowAnEmail() {
        // A name and an email in one block must both surface, not overlap-drop.
        let entities = EntityExtractor().extract(from: "Barack Obama <president@example.com>")
        XCTAssertTrue(entities.contains { $0.kind == .email && $0.value == "president@example.com" })
        XCTAssertTrue(entities.contains { $0.kind == .name && $0.value.contains("Obama") })
    }

    // MARK: - Deterministic routing

    func testRoutesEntitiesToLabelledFields() async throws {
        let entities = [
            SmartPasteEntity(id: "e-email", kind: .email, value: "jane@example.com", raw: "jane@example.com"),
            SmartPasteEntity(id: "e-phone", kind: .phone, value: "+14155550198", raw: "+1 415 555 0198"),
        ]
        let fields = [
            SmartPasteFieldDescriptor(id: "f-email", label: "Email address"),
            SmartPasteFieldDescriptor(id: "f-phone", label: "Phone number"),
            SmartPasteFieldDescriptor(id: "f-notes", label: "Notes"),
        ]
        let fills = try await DeterministicSmartPasteRouter().route(entities: entities, into: fields)
        XCTAssertEqual(fills.count, 2)
        let byField = Dictionary(uniqueKeysWithValues: fills.map { ($0.fieldID, $0) })
        XCTAssertEqual(byField["f-email"]?.entityID, "e-email")
        XCTAssertEqual(byField["f-phone"]?.entityID, "e-phone")
        XCTAssertNil(byField["f-notes"], "an unmatched field must stay empty, never guessed")
        XCTAssertTrue(fills.allSatisfy { $0.confidenceKind == .heuristic })
    }

    func testNeverFillsASecureField() async throws {
        let entities = [SmartPasteEntity(id: "e", kind: .email, value: "a@b.com", raw: "a@b.com")]
        let fields = [SmartPasteFieldDescriptor(id: "pw", label: "Email", role: "AXSecureTextField", isSecure: true)]
        let fills = try await DeterministicSmartPasteRouter().route(entities: entities, into: fields)
        XCTAssertTrue(fills.isEmpty, "a secure field is never auto-filled even on a label match")
    }

    func testFailsClosedWhenNoFieldMatches() async throws {
        let entities = [SmartPasteEntity(id: "e", kind: .email, value: "a@b.com", raw: "a@b.com")]
        let fields = [SmartPasteFieldDescriptor(id: "f", label: "Favourite colour")]
        let fills = try await DeterministicSmartPasteRouter().route(entities: entities, into: fields)
        XCTAssertTrue(fills.isEmpty, "no confident match means no fill")
    }

    func testEachEntityAndFieldUsedAtMostOnce() async throws {
        let entities = [
            SmartPasteEntity(id: "e1", kind: .email, value: "a@b.com", raw: "a@b.com"),
            SmartPasteEntity(id: "e2", kind: .email, value: "c@d.com", raw: "c@d.com"),
        ]
        let fields = [SmartPasteFieldDescriptor(id: "only-email", label: "Email")]
        let fills = try await DeterministicSmartPasteRouter().route(entities: entities, into: fields)
        XCTAssertEqual(fills.count, 1, "one field takes at most one entity")
    }

    func testPlacesPostalCodeByZipLabel() async throws {
        let entities = [SmartPasteEntity(id: "z", kind: .postalCode, value: "95014", raw: "95014")]
        let fields = [SmartPasteFieldDescriptor(id: "zip", label: "ZIP")]
        let fills = try await DeterministicSmartPasteRouter().route(entities: entities, into: fields)
        XCTAssertEqual(fills.first?.fieldID, "zip")
        XCTAssertGreaterThanOrEqual(fills.first?.confidence ?? 0, 0.9)
    }
}

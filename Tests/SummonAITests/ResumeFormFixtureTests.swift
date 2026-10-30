import Foundation
import XCTest

/// The resume-to-form fixture (`Fixtures/smartpaste-resume-forms.json`) for the
/// Smart Paste extractor experiment, its scorer, and integrity checks that keep
/// the ground truth honest: complete per form, secure fields empty, and every
/// expected value stated in its source.
struct ResumeFormFixture: Decodable {
    struct Source: Decodable { let id: String; let kind: String; let text: String }
    struct Field: Decodable { let id: String; let label: String; let secure: Bool? }
    struct Form: Decodable { let id: String; let fields: [Field] }
    struct Expectation: Decodable {
        let mode: String
        let value: Value?
        enum Value: Decodable {
            case one(String), many([String])
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let list = try? container.decode([String].self) { self = .many(list) } else {
                    self = .one(try container.decode(String.self))
                }
            }
            var items: [String] {
                switch self {
                case .one(let value): return [value]
                case .many(let values): return values
                }
            }
        }
    }
    struct Case: Decodable {
        let id: String
        let source: String
        let form: String
        let expected: [String: Expectation]
    }

    let version: Int
    let sources: [Source]
    let forms: [Form]
    let cases: [Case]

    static func load() throws -> ResumeFormFixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/smartpaste-resume-forms.json")
        return try JSONDecoder().decode(ResumeFormFixture.self, from: Data(contentsOf: url))
    }

    func source(_ id: String) -> Source? { sources.first { $0.id == id } }
    func form(_ id: String) -> Form? { forms.first { $0.id == id } }

    /// Fields filled correctly out of the scored fields (`skip` is not scored).
    static func score(_ testCase: Case, fills: [String: String]) -> (correct: Int, scored: Int) {
        var correct = 0
        var scored = 0
        for (fieldID, expectation) in testCase.expected where expectation.mode != "skip" {
            scored += 1
            if matches(expectation, fill: fills[fieldID]) { correct += 1 }
        }
        return (correct, scored)
    }

    static func matches(_ expectation: Expectation, fill: String?) -> Bool {
        let filled = fill.map(collapsed) ?? ""
        let items = expectation.value?.items ?? []
        switch expectation.mode {
        case "empty":
            return filled.isEmpty
        case "exact":
            return filled.lowercased() == collapsed(items.first ?? "").lowercased()
        case "contains":
            return !filled.isEmpty && filled.lowercased().contains((items.first ?? "").lowercased())
        case "digits":
            return lastTen(filled) == lastTen(items.first ?? "") && lastTen(filled).count == 10
        case "url":
            return !filled.isEmpty && urlKey(filled) == urlKey(items.first ?? "")
        case "month":
            return monthKey(filled) == items.first
        case "set":
            let listed = Set(filled.split(whereSeparator: { $0 == "," || $0 == ";" })
                .map { collapsed(String($0)).lowercased() })
            return items.allSatisfy { listed.contains($0.lowercased()) }
        default:
            return false
        }
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func lastTen(_ text: String) -> String {
        String(text.filter(\.isNumber).suffix(10))
    }

    static func urlKey(_ text: String) -> String {
        var key = text.lowercased().trimmingCharacters(in: .whitespaces)
        for prefix in ["https://", "http://", "www."] where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count)
        }
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// "2021-03", "03/2021", "March 2021", "01/04/2020" (day first) → "YYYY-MM".
    static func monthKey(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil { return trimmed }
        let numbers = trimmed.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if let year = numbers.first(where: { $0 >= 1900 }) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            let lower = trimmed.lowercased()
            if let index = months.firstIndex(where: { lower.contains($0) }) {
                return String(format: "%04d-%02d", year, index + 1)
            }
            let small = numbers.filter { $0 < 100 }
            // dd/mm/yyyy (the European order the fixture uses) or mm/yyyy.
            if let month = small.count >= 2 ? small[1] : small.first, (1...12).contains(month) {
                return String(format: "%04d-%02d", year, month)
            }
        }
        return nil
    }
}

final class ResumeFormFixtureTests: XCTestCase {
    func testEveryCaseCoversEveryFieldOfItsForm() throws {
        let fixture = try ResumeFormFixture.load()
        XCTAssertEqual(fixture.version, 1)
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 9)
        for testCase in fixture.cases {
            XCTAssertNotNil(fixture.source(testCase.source), testCase.id)
            let form = try XCTUnwrap(fixture.form(testCase.form), testCase.id)
            XCTAssertEqual(Set(testCase.expected.keys), Set(form.fields.map(\.id)), testCase.id)
            for field in form.fields where field.secure == true {
                XCTAssertEqual(testCase.expected[field.id]?.mode, "empty", "\(testCase.id) secure \(field.id)")
            }
        }
    }

    /// Ground truth must be stated in the source, never invented by the fixture.
    func testEveryExpectedValueIsStatedInItsSource() throws {
        let fixture = try ResumeFormFixture.load()
        for testCase in fixture.cases {
            let text = try XCTUnwrap(fixture.source(testCase.source)).text
            let lower = text.lowercased()
            let digits = text.filter(\.isNumber)
            for (field, expectation) in testCase.expected {
                let where_ = "\(testCase.id).\(field)"
                for item in expectation.value?.items ?? [] {
                    switch expectation.mode {
                    case "exact", "contains", "set":
                        XCTAssertTrue(lower.contains(item.lowercased()), "\(where_): '\(item)' not in source")
                    case "digits":
                        XCTAssertTrue(digits.contains(item.filter(\.isNumber)), "\(where_): digits not in source")
                    case "url":
                        let host = ResumeFormFixture.urlKey(item).split(separator: "/").first.map(String.init) ?? ""
                        XCTAssertTrue(lower.contains(host), "\(where_): host '\(host)' not in source")
                    case "month":
                        XCTAssertTrue(text.contains(String(item.prefix(4))), "\(where_): year not in source")
                    default:
                        XCTFail("\(where_): mode '\(expectation.mode)' carries a value")
                    }
                }
            }
        }
    }

    func testScorerCreditsExactFillsAndPenalisesInventedOnes() throws {
        let fixture = try ResumeFormFixture.load()
        let job = try XCTUnwrap(fixture.cases.first { $0.id == "r1-job" })
        let perfect: [String: String] = [
            "full-name": "Ananya  Iyer", "email": "ANANYA.IYER@lumora.example",
            "phone": "+91-55555-01234",
            "title": "senior iOS engineer", "employer": "Lumora Health", "city": "Bengaluru",
            "street": "Flat 4B, Palm Grove Apartments, 12th Main Road, Indiranagar",
            "postal": "560038", "linkedin": "https://www.linkedin.com/in/ananya-iyer-ios/",
            "website": "ananya.example.dev", "years": "9",
            "skills": "SwiftUI, Swift; Core Data, Combine", "degree": "B.Tech, Computer Science",
            "university": "College of Engineering, Pune", "grad-year": "2016",
        ]
        let full = ResumeFormFixture.score(job, fills: perfect)
        XCTAssertEqual(full.correct, full.scored, "a correct fill scores every field")

        var invented = perfect
        invented["password"] = "hunter2"
        invented["cover"] = "I am excited to apply."
        let penalised = ResumeFormFixture.score(job, fills: invented)
        XCTAssertEqual(penalised.correct, full.scored - 2, "filling secure or unstated fields loses credit")

        XCTAssertEqual(ResumeFormFixture.monthKey("March 2021"), "2021-03")
        XCTAssertEqual(ResumeFormFixture.monthKey("01/04/2020"), "2020-04")
        XCTAssertEqual(ResumeFormFixture.monthKey("2022-06"), "2022-06")
    }
}

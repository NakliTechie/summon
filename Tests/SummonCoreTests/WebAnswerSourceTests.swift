import XCTest
@testable import SummonCore

/// The web answer names the result it came from (Chirag 2026-11-15: "name the source first").
final class WebAnswerSourceTests: XCTestCase {
    /// The five results SearXNG gave on 2026-11-15 for "who is the third prime minister of India?".
    private let hits = [
        WebHit(title: "List of prime ministers of India - Wikipedia",
               url: "https://en.wikipedia.org/wiki/List_of_prime_ministers_of_India",
               snippet: "The prime minister of India is the chief executive of the Government of India "
                   + "and chair of the Union Council of Ministers."),
        WebHit(title: "List of Prime Ministers of India, 1947-2026, Tenure, Party",
               url: "https://vajiramandravi.com/current-affairs/prime-ministers-of-india/",
               snippet: "Narendra Modi is the current Prime Minister of India, serving since 2014. "
                   + "He took the oath for his third term on June 9, 2024."),
        WebHit(title: "Prime Minister of India", url: "https://www.pmindia.gov.in/en/",
               snippet: "Shri Narendra Modi was sworn-in as India's Prime Minister for the third time."),
        WebHit(title: "Who is the third prime minister of india? - Careers360",
               url: "https://learn.careers360.com/school/question-who-is-the-third-prime-minister-of-india-46861/",
               snippet: "Who is the third prime minister of india? Answers (1) The third prime minister of India was Mrs. Indira Gandhi. "
                   + "She was the daughter of the first prime minister of India Mr. Jawaharlal Nehru."),
        WebHit(title: "Prime Minister of India - Wikipedia", url: "https://en.wikipedia.org/wiki/Prime_Minister_of_India",
               snippet: "Executive authority is vested in the prime minister and the Union Council of Ministers."),
    ]
    private let question = "who  is the third prime minister of India?"

    func testNamesTheResultThatStatesTheAnswer() {
        let line = WebAnswerSource.line(answer: "Mrs. Indira Gandhi is the third prime minister of India.", question: question, hits: hits)
        XCTAssertEqual(line, "From: Who is the third prime minister of india? - Careers360 (learn.careers360.com)")
    }

    func testSaysSoWhenNoResultStatesTheAnswer() {
        let line = WebAnswerSource.line(answer: "Lal Bahadur Shastri was the third prime minister.", question: question, hits: hits)
        XCTAssertEqual(line, "No result above states this answer; check it before relying on it.")
    }

    func testAddsNothingWhenTheModelSaysTheSourcesDoNotAnswer() {
        XCTAssertNil(WebAnswerSource.line(answer: "The sources do not answer who the third prime minister was.",
                                          question: question, hits: hits))
        XCTAssertNil(WebAnswerSource.line(answer: "The provided results don't say.", question: question, hits: hits))
    }

    func testPrefersTheHigherRankedResultOnATie() {
        let line = WebAnswerSource.line(answer: "Narendra Modi.", question: question, hits: hits)
        XCTAssertEqual(line, "From: List of Prime Ministers of India, 1947-2026, Tenure, Party (vajiramandravi.com)")
    }

    func testDropsWwwFromTheSite() {
        let line = WebAnswerSource.line(answer: "Shri Narendra Modi was sworn-in.", question: "who is pm",
                                        hits: [hits[2]])
        XCTAssertEqual(line, "From: Prime Minister of India (pmindia.gov.in)")
    }

    /// Codex review 2026-11-15 of 8127d9c.
    func testATieGoesToTheResultThatStatesTheWholeAnswer() {
        let race = [WebHit(title: "Race preview", url: "https://a.example/preview", snippet: "Alice withdrew before the race."),
                    WebHit(title: "Race report", url: "https://b.example/report", snippet: "Alice won the race.")]
        XCTAssertEqual(WebAnswerSource.line(answer: "Alice won the race.", question: "Who won the race?", hits: race),
                       "From: Race report (b.example)")
    }

    func testANegationThatIsNotAboutAnsweringKeepsTheSource() {
        let race = [WebHit(title: "Race report", url: "https://b.example/report", snippet: "Alice won the race.")]
        XCTAssertNotNil(WebAnswerSource.line(answer: "The sources do not disagree: Alice won the race.",
                                             question: "Who won the race?", hits: race))
    }

    func testAResultStatingTooLittleOfTheAnswerIsNotNamed() {
        let line = WebAnswerSource.line(answer: "Indira Gandhi, daughter of Jawaharlal Nehru, served from 1966.",
                                        question: question, hits: [hits[1]])
        XCTAssertEqual(line, "No result above states this answer; check it before relying on it.")
    }

    func testThePromptAsksForACountingCaveat() {
        XCTAssertTrue(WebEnrich.enrichPrompt(question: question, hits: hits).contains("how something is counted"))
    }
}

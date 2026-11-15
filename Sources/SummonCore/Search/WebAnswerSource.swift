import Foundation

/// Names the web result a model's answer came from, worked out on the Mac rather than
/// trusted to the model. On 2026-11-15 Apple FM answered "who was the third prime minister of
/// India" from a Careers360 Q&A snippet and named no source, although the prompt asked it to.
///
/// The answer's distinctive words (not in the question, not stop words) are matched against
/// each result's title and snippet. The result stating most of them is named; when none states
/// any, the card says so, so an answer from the model's memory is not mistaken for a sourced one.
public enum WebAnswerSource {
    public static func line(answer: String, question: String, hits: [WebHit]) -> String? {
        guard !hits.isEmpty, !saysSourcesDoNotAnswer(answer) else { return nil }
        let asked = Set(words(question))
        let distinctive = Set(words(answer)).subtracting(asked).subtracting(stopWords)
        guard !distinctive.isEmpty else { return nil }
        var best: (index: Int, score: Int)?
        for (index, hit) in hits.enumerated() {
            let stated = Set(words(hit.title + " " + hit.snippet))
            let score = distinctive.intersection(stated).count
            if score > (best?.score ?? 0) { best = (index, score) }
        }
        guard let best else { return "No result above states this answer; check it before relying on it." }
        let hit = hits[best.index]
        let site = URL(string: hit.url)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        return "From: \(hit.title)" + (site.map { " (\($0))" } ?? "")
    }

    /// "The sources do not say …": there is no answer to attribute.
    static func saysSourcesDoNotAnswer(_ answer: String) -> Bool {
        answer.range(
            of: #"\b(?:sources?|results?)\b[^.]{0,40}\b(?:do not|don't|does not|doesn't|did not|cannot|can't)\b"#
                + #"|\bno (?:information|answer|mention)\b|\bnot (?:mentioned|stated|answered)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func words(_ text: String) -> [String] {
        SmartPasteGrounding.normalized(text).split(separator: " ").map(String.init).filter { $0.count >= 3 || $0.first?.isNumber == true }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "was", "were", "are", "is", "has", "had", "have", "his", "her", "she", "him", "they", "their",
        "this", "that", "with", "for", "from", "but", "not", "who", "what", "which", "when", "where", "also",
        "been", "being", "its", "into", "than", "then", "there", "these", "those", "about", "after", "before",
        "source", "sources", "result", "results", "according", "answer", "question", "information", "provided",
        "mentioned", "states", "stated", "says", "said",
    ]
}

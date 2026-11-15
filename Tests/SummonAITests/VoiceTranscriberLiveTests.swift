import XCTest
@testable import SummonAI

/// Real speech through Apple's on-device transcriber. Gated: it needs macOS 26 and the speech
/// files, so `make verify` skips it; run with `SUMMON_RUN_VOICE_LIVE=1 swift test --filter VoiceTranscriberLiveTests`.
final class VoiceTranscriberLiveTests: XCTestCase {
    func testTranscribesSpokenLauncherQueries() async throws {
        guard ProcessInfo.processInfo.environment["SUMMON_RUN_VOICE_LIVE"] == "1" else {
            throw XCTSkip("set SUMMON_RUN_VOICE_LIVE=1 to run")
        }
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let phrases = ["what day is the twentieth of november", "who was the third prime minister of india"]
        let locale = await VoiceTranscriber.locale()
        for (index, phrase) in phrases.enumerated() {
            let file = directory.appendingPathComponent("\(index).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", file.path, phrase]
            try say.run()
            say.waitUntilExit()
            let heard = try await VoiceTranscriber.transcribe(file: file, locale: locale)
            let words = Set(phrase.split(separator: " ").map { $0.lowercased() })
            let got = Set(heard.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
            let recall = Double(words.intersection(got).count) / Double(words.count)
            print("voice-live \(locale.identifier): \"\(phrase)\" → \"\(heard)\" recall \(recall)")
            XCTAssertGreaterThanOrEqual(recall, 0.7, heard)
        }
    }

    /// Hindi goes to `DictationTranscriber` (Apple's `SpeechTranscriber` has no Hindi). The first
    /// run downloads the Hindi speech files. Audio comes from the built-in Hindi voice, Lekha.
    func testTranscribesHindi() async throws {
        guard ProcessInfo.processInfo.environment["SUMMON_RUN_VOICE_LIVE"] == "1" else {
            throw XCTSkip("set SUMMON_RUN_VOICE_LIVE=1 to run")
        }
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let locale = await VoiceTranscriber.locale(setting: "hi_IN")
        XCTAssertEqual(locale.identifier, "hi_IN")
        let british = await VoiceTranscriber.locale(setting: "en_GB")
        XCTAssertEqual(british.identifier, "en_GB", "an exact choice keeps its region")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-hi-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let phrase = "भारत की राजधानी क्या है"
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Lekha", "-o", file.path, phrase]
        try say.run()
        say.waitUntilExit()
        let heard = try await VoiceTranscriber.transcribe(file: file, locale: locale)
        let words = Set(phrase.split(separator: " ").map(String.init))
        let got = Set(heard.components(separatedBy: CharacterSet.letters.union(.nonBaseCharacters).inverted).filter { !$0.isEmpty })
        let recall = Double(words.intersection(got).count) / Double(words.count)
        print("voice-live \(locale.identifier): \"\(phrase)\" → \"\(heard)\" recall \(recall)")
        XCTAssertGreaterThanOrEqual(recall, 0.6, heard)
    }

    /// Reserved locales may come back as variants, so the limit check compares language and region.
    func testReservationsTreatVariantsAsTheSameLanguage() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        XCTAssertTrue(SpeechReservations.same(Locale(identifier: "hi_IN"), Locale(identifier: "hi-Deva_IN")))
        XCTAssertFalse(SpeechReservations.same(Locale(identifier: "en_IN"), Locale(identifier: "en_GB")))
        XCTAssertFalse(SpeechReservations.same(Locale(identifier: "en_IN"), Locale(identifier: "hi_IN")))
    }

    /// Codex review of 7f65e10: a waiter gives up at the limit and never takes the turn beside a
    /// download that has not returned; the turn stays held until that download releases it.
    func testAWaiterGivesUpAtTheLimitWithoutTakingTheTurn() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let turns = SpeechReservations()
        let first = await turns.acquire(within: .seconds(1))
        XCTAssertTrue(first)
        let start = ContinuousClock.now
        let second = await turns.acquire(within: .milliseconds(200))
        XCTAssertFalse(second)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        await turns.release()
        let third = await turns.acquire(within: .milliseconds(200))
        XCTAssertTrue(third, "a released turn is free again")
    }

    /// A waiter gets the turn as soon as the holder releases it.
    func testAWaiterGetsTheTurnWhenTheHolderReleases() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26") }
        let turns = SpeechReservations()
        let first = await turns.acquire(within: .seconds(1))
        XCTAssertTrue(first)
        let waiter = Task { await turns.acquire(within: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        await turns.release()
        let start = ContinuousClock.now
        let got = await waiter.value
        XCTAssertTrue(got)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }
}

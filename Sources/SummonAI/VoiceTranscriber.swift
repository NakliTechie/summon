import AVFoundation
import Foundation
import Speech
import SummonCore

/// Speech to text on this Mac with Apple's `SpeechAnalyzer` (macOS 26). English uses
/// `SpeechTranscriber`; the other languages (Hindi among 54 on 2026-11-15) use
/// `DictationTranscriber`, which `SpeechTranscriber` does not cover. No audio leaves the Mac and
/// Summon downloads no model: macOS installs the language files (`AssetInventory`) on first use.
///
/// The microphone is open only between `start` and `finish`; there is no wake word.
@available(macOS 26.0, *)
public final class VoiceTranscriber: @unchecked Sendable {
    /// What the launcher shows while you talk: `text` is everything heard so far.
    public enum Update: Sendable, Equatable {
        /// macOS is fetching the language's speech files (first use of that language).
        case preparing(String)
        case listening
        case text(String)
        case failed(String)
    }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// The setup `start` runs. `finish` waits for it, so once `finish` returns nothing of this
    /// session is still starting: no microphone, no analyzer, no results task left behind.
    private var setupTask: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""
    /// Set by `finish` (or a speech error); a `start` still waiting on permission or speech files
    /// then opens no microphone. Only the flags change under `lock`; the engine calls run outside
    /// it, so a slow driver never holds up a release. `start` marks the microphone open after the
    /// engine starts and closes it itself if a stop came in meanwhile, so it is never left open.
    private var stopRequested = false
    private var microphoneOpen = false
    private let lock = NSLock()

    public init() {}

    /// The locale to transcribe: the Mac's own when the transcriber supports it, else US English.
    public static func locale() async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en_US")
    }

    /// The locale for the `voice.language` setting: a locale identifier either recognizer
    /// supports, or the automatic choice for "auto", a missing setting or an unsupported one.
    public static func locale(setting: String?) async -> Locale {
        if let setting, setting != VoiceLanguage.automatic {
            let wanted = Locale(identifier: setting)
            if let found = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) { return found }
            if let found = await DictationTranscriber.supportedLocale(equivalentTo: wanted) { return found }
        }
        return await locale()
    }

    /// Every language either recognizer can transcribe, for the Settings list.
    public static func languages() async -> [Locale] {
        var seen = Set<String>()
        let all = await SpeechTranscriber.supportedLocales + DictationTranscriber.supportedLocales
        return all.filter { seen.insert($0.identifier).inserted }
    }

    /// Ask for the microphone. macOS shows its prompt once; after that this answers at once.
    public static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Starts listening in `language` (a `voice.language` setting value; nil is automatic).
    /// `onUpdate` runs on the main actor with the text heard so far. Does nothing after
    /// `finish`, or when called a second time.
    public func start(language: String? = nil, onUpdate: @escaping @MainActor @Sendable (Update) -> Void) async {
        let setup: Task<Void, Never>? = lock.withLock {
            guard setupTask == nil, !stopRequested else { return nil }
            let task = Task { await self.setUp(language: language, onUpdate: onUpdate) }
            setupTask = task
            return task
        }
        await setup?.value
    }

    private func setUp(language: String?, onUpdate: @escaping @MainActor @Sendable (Update) -> Void) async {
        let span = UsageLog.span("voice.start")
        guard await Self.microphoneAllowed() else {
            span.end(["outcome": "microphone denied"])
            await onUpdate(.failed("Summon cannot use the microphone. Allow it in System Settings › Privacy & Security › Microphone."))
            return
        }
        guard !lock.withLock({ stopRequested }) else {
            span.end(["outcome": "let go before the microphone opened"])
            return
        }
        do {
            let locale = await Self.locale(setting: language)
            let recognizer = await Self.makeRecognizer(locale: locale)
            try await Self.install(recognizer.module) {
                let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
                await onUpdate(.preparing("Getting the \(name) speech files from Apple… (first use only)"))
            }
            let analyzer = SpeechAnalyzer(modules: [recognizer.module])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [recognizer.module]) else {
                throw CoreError.io("no audio format for speech in \(locale.identifier)")
            }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            lock.withLock {
                self.analyzer = analyzer
                self.input = continuation
                self.finalized = ""
                self.volatile = ""
            }
            let results = Task { [weak self] in
                do {
                    for try await result in recognizer.results {
                        guard let self else { return }
                        let text = result.text
                        let heard: String = self.lock.withLock {
                            if result.isFinal { self.finalized += text; self.volatile = "" } else { self.volatile = text }
                            return (self.finalized + self.volatile).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        await onUpdate(.text(heard))
                    }
                } catch {
                    self?.requestStop()
                    await onUpdate(.failed("Speech stopped: \(error.localizedDescription)"))
                }
            }
            lock.withLock { resultsTask = results }
            try await analyzer.start(inputSequence: stream)
            guard !lock.withLock({ stopRequested }) else {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                span.end(["outcome": "let go before the microphone opened"])
                return
            }
            do {
                try startMicrophone(feeding: continuation, as: format)
            } catch {
                closeEngine()
                throw error
            }
            let keep = lock.withLock { () -> Bool in
                microphoneOpen = true
                return !stopRequested
            }
            guard keep else {
                stopMicrophone()
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                span.end(["outcome": "let go while the microphone opened"])
                return
            }
            span.end(["locale": locale.identifier])
            await onUpdate(.listening)
        } catch {
            span.fail(error)
            stopMicrophone()
            // Ending the input does not end the analysis, so cancel it rather than leave it running.
            await lock.withLock { self.analyzer }?.cancelAndFinishNow()
            await onUpdate(.failed("Voice input is unavailable: \(error.localizedDescription)"))
        }
    }

    /// Stops listening and waits for the last words. Returns everything heard. Safe to call more
    /// than once, and before `start` has opened the microphone.
    @discardableResult
    public func finish() async -> String {
        let span = UsageLog.span("voice.finish")
        requestStop()
        await lock.withLock { setupTask }?.value
        let (analyzer, results) = lock.withLock { (self.analyzer, self.resultsTask) }
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        let heard = lock.withLock { (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }
        lock.withLock { self.analyzer = nil }
        span.end(["chars": String(heard.count)])
        return heard
    }

    /// One recognizer and its results as plain text. `SpeechTranscriber` when it covers the
    /// locale (English), else `DictationTranscriber`; both give live (volatile) results.
    struct Recognizer {
        let module: any SpeechModule
        let results: AsyncThrowingStream<(text: String, isFinal: Bool), Error>
    }

    static func makeRecognizer(locale: Locale) async -> Recognizer {
        if await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier == locale.identifier }) {
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults], attributeOptions: [])
            return Recognizer(module: transcriber, results: relay(transcriber.results) { (String($0.text.characters), $0.isFinal) })
        }
        let dictation = DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation],
                                             reportingOptions: [.volatileResults], attributeOptions: [])
        return Recognizer(module: dictation, results: relay(dictation.results) { (String($0.text.characters), $0.isFinal) })
    }

    private static func relay<S: AsyncSequence & Sendable>(
        _ results: S, _ read: @escaping @Sendable (S.Element) -> (text: String, isFinal: Bool)
    ) -> AsyncThrowingStream<(text: String, isFinal: Bool), Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in results { continuation.yield(read(result)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Installs the language's speech files when macOS does not have them yet, calling
    /// `beforeDownload` first so the launcher can say why it is waiting.
    static func install(_ module: any SpeechModule, beforeDownload: () async -> Void = {}) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            await beforeDownload()
            try await request.downloadAndInstall()
        }
    }

    /// Transcribes an audio file with the same recognizer setup, for the live test
    /// (`SUMMON_RUN_VOICE_LIVE=1`), which cannot use the microphone without a person.
    static func transcribe(file url: URL, locale: Locale) async throws -> String {
        let recognizer = await makeRecognizer(locale: locale)
        try await install(recognizer.module)
        let analyzer = SpeechAnalyzer(modules: [recognizer.module])
        // As in a live session: final text plus the latest partial text, because on 2026-11-15
        // `DictationTranscriber` (Hindi) marked none of its results final, even at the end of input.
        let collect = Task { () throws -> String in
            var finalized = ""
            var latest = ""
            for try await result in recognizer.results {
                if result.isFinal { finalized += result.text; latest = "" } else { latest = result.text }
            }
            return finalized + latest
        }
        let audio = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startMicrophone(feeding continuation: AsyncStream<AnalyzerInput>.Continuation,
                                 as format: AVAudioFormat) throws {
        let node = engine.inputNode
        let micFormat = node.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: micFormat, to: format) else {
            throw CoreError.io("cannot convert microphone audio to the speech format")
        }
        node.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            let ratio = format.sampleRate / micFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, converted.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
        engine.prepare()
        try engine.start()
    }

    private func requestStop() {
        lock.withLock { stopRequested = true }
        stopMicrophone()
    }

    /// Closes the microphone if this call is the one that finds it open, and ends the audio input.
    /// Idempotent: only one caller sees `microphoneOpen` true.
    private func stopMicrophone() {
        let (close, input) = lock.withLock { () -> (Bool, AsyncStream<AnalyzerInput>.Continuation?) in
            let open = microphoneOpen
            microphoneOpen = false
            return (open, self.input)
        }
        if close { closeEngine() }
        input?.finish()
    }

    private func closeEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
}

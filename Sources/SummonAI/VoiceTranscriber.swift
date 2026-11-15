import AVFoundation
import Foundation
import Speech
import SummonCore

/// Speech to text on this Mac with Apple's `SpeechAnalyzer` and `SpeechTranscriber` (macOS 26).
/// No audio leaves the Mac and Summon downloads no model: macOS installs the language files
/// (`AssetInventory`), and on 2026-11-15 Indian English (`en_IN`) was already installed here.
///
/// The microphone is open only between `start` and `finish`; there is no wake word.
@available(macOS 26.0, *)
public final class VoiceTranscriber: @unchecked Sendable {
    /// What the launcher shows while you talk: `text` is everything heard so far.
    public enum Update: Sendable, Equatable {
        case listening
        case text(String)
        case failed(String)
    }

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
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

    /// Ask for the microphone. macOS shows its prompt once; after that this answers at once.
    public static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Starts listening. `onUpdate` runs on the main actor with the text heard so far.
    public func start(onUpdate: @escaping @MainActor @Sendable (Update) -> Void) async {
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
            let locale = await Self.locale()
            let transcriber = try await Self.makeTranscriber(locale: locale)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw CoreError.io("no audio format for speech in \(locale.identifier)")
            }
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            lock.withLock {
                self.analyzer = analyzer
                self.input = continuation
                self.finalized = ""
                self.volatile = ""
            }
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let text = String(result.text.characters)
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
            await onUpdate(.failed("Voice input is unavailable: \(error.localizedDescription)"))
        }
    }

    /// Stops listening and waits for the last words. Returns everything heard. Safe to call more
    /// than once, and before `start` has opened the microphone.
    @discardableResult
    public func finish() async -> String {
        let span = UsageLog.span("voice.finish")
        requestStop()
        let analyzer = lock.withLock { self.analyzer }
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        let heard = lock.withLock { (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }
        lock.withLock { self.analyzer = nil }
        span.end(["chars": String(heard.count)])
        return heard
    }

    /// A transcriber with live (volatile) results; macOS fetches its language files once if needed.
    static func makeTranscriber(locale: Locale) async throws -> SpeechTranscriber {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        return transcriber
    }

    /// Transcribes an audio file with the same transcriber setup, for the live test
    /// (`SUMMON_RUN_VOICE_LIVE=1`), which cannot use the microphone without a person.
    static func transcribe(file url: URL, locale: Locale) async throws -> String {
        let transcriber = try await makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () throws -> String in
            var heard = ""
            for try await result in transcriber.results where result.isFinal { heard += String(result.text.characters) }
            return heard
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

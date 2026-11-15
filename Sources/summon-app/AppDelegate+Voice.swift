import AppKit
import Foundation
import SummonAI
import SummonCore
import SummonUI

/// Hold-to-talk into the launcher (Chunk V, layer 1). The default mode keeps ⌥Space as it was:
/// a tap opens the launcher; holding it past `holdDelay` also listens until you let go. The other
/// modes use a key of their own, held or pressed on and off. Listening stops after `maxListening`
/// in any mode, so a forgotten toggle never leaves the microphone open.
extension AppDelegate {
    static let holdDelay: TimeInterval = 0.3
    static let maxListening: TimeInterval = 60

    var voiceSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// While the launcher is open a press may be a tap (close it) or a hold (talk), so the choice
    /// waits for the release or for `holdDelay`, whichever comes first. A closed launcher opens at
    /// once, as before.
    func launcherPressed() {
        let holdable = voiceSupported && shortcutSettings.voiceMode == .holdLauncher && voiceSession == nil
        clipboardHistory.hide()
        launcherTapHides = holdable && panel.isShowing
        if !launcherTapHides { panel.toggle() }
        guard holdable else { return }
        holdToTalkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.launcherTapHides = false
            self?.startVoice()
        }
        holdToTalkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    }

    func launcherReleased() {
        holdToTalkWork?.cancel()
        holdToTalkWork = nil
        if launcherTapHides {
            launcherTapHides = false
            panel.hide()
        }
        if shortcutSettings.voiceMode == .holdLauncher { stopVoice() }
    }

    func voiceKeyPressed() {
        switch shortcutSettings.voiceMode {
        case .hold: startVoice()
        case .toggle:
            if voiceSession == nil { startVoice() } else { stopVoice() }
        case .holdLauncher, .off: break
        }
    }

    func voiceKeyReleased() {
        if shortcutSettings.voiceMode == .hold { stopVoice() }
    }

    /// Each session gets a generation number. Its updates, its time limit and its final text apply
    /// only while it is still the latest session, so a stopping session never touches a newer one.
    func startVoice() {
        guard #available(macOS 26.0, *), voiceSession == nil else { return }
        if !panel.isShowing {
            clipboardHistory.hide()
            panel.show()
        }
        let transcriber = VoiceTranscriber()
        voiceGeneration += 1
        let generation = voiceGeneration
        voiceSession = transcriber
        panel.setListening(true)
        let language = (try? core.settings.get(VoiceLanguage.settingsKey))?.stringValue
        Task { @MainActor [weak self] in
            await transcriber.start(language: language) { update in
                guard let self, self.voiceSession === transcriber else { return }
                switch update {
                case .preparing(let message): self.panel.showVoicePreparing(message)
                case .listening:
                    self.panel.setListening(true)
                    self.startVoiceLimit(generation)
                case .text(let heard): self.panel.showVoiceText(heard)
                case .failed(let reason): self.failVoice(transcriber, reason: reason)
                }
            }
        }
    }

    /// The limit counts from when the microphone opens, not from the press, so time spent on the
    /// first-use permission prompt or a speech-file download is not taken from the recording.
    private func startVoiceLimit(_ generation: Int) {
        voiceLimitWork?.cancel()
        let limit = DispatchWorkItem { [weak self] in
            guard let self, self.voiceGeneration == generation else { return }
            self.stopVoice()
        }
        voiceLimitWork = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxListening, execute: limit)
    }

    func stopVoice() {
        voiceLimitWork?.cancel()
        voiceLimitWork = nil
        guard #available(macOS 26.0, *), let transcriber = voiceSession as? VoiceTranscriber else { return }
        voiceSession = nil
        let generation = voiceGeneration
        Task { @MainActor [weak self] in
            let heard = await transcriber.finish()
            guard let self, self.voiceGeneration == generation else { return }
            self.panel.setListening(false)
            if !heard.isEmpty { self.panel.showVoiceText(heard) }
        }
    }

    /// A failed session still closes the microphone, through the same `finish` as a normal stop.
    @available(macOS 26.0, *)
    private func failVoice(_ transcriber: VoiceTranscriber, reason: String) {
        voiceLimitWork?.cancel()
        voiceLimitWork = nil
        voiceSession = nil
        panel.showVoiceProblem(reason)
        Task { await transcriber.finish() }
    }
}

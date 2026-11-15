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

    func launcherPressed() {
        let wasShowing = panel.isShowing
        clipboardHistory.hide()
        panel.toggle()
        guard !wasShowing, voiceSupported, shortcutSettings.voiceMode == .holdLauncher else { return }
        let work = DispatchWorkItem { [weak self] in self?.startVoice() }
        holdToTalkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    }

    func launcherReleased() {
        holdToTalkWork?.cancel()
        holdToTalkWork = nil
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

    func startVoice() {
        guard #available(macOS 26.0, *), voiceSession == nil else { return }
        if !panel.isShowing {
            clipboardHistory.hide()
            panel.show()
        }
        let transcriber = VoiceTranscriber()
        voiceSession = transcriber
        panel.setListening(true)
        let limit = DispatchWorkItem { [weak self] in self?.stopVoice() }
        voiceLimitWork = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxListening, execute: limit)
        Task { @MainActor [weak self] in
            await transcriber.start { update in
                guard let self, self.voiceSession === transcriber else { return }
                switch update {
                case .listening: break
                case .text(let heard): self.panel.showVoiceText(heard)
                case .failed(let reason):
                    self.voiceSession = nil
                    self.panel.showVoiceProblem(reason)
                }
            }
        }
    }

    func stopVoice() {
        voiceLimitWork?.cancel()
        voiceLimitWork = nil
        guard #available(macOS 26.0, *), let transcriber = voiceSession as? VoiceTranscriber else { return }
        voiceSession = nil
        Task { @MainActor [weak self] in
            let heard = await transcriber.finish()
            guard let self else { return }
            self.panel.setListening(false)
            if !heard.isEmpty { self.panel.showVoiceText(heard) }
        }
    }
}

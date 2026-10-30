import AVFoundation
import Foundation

/// Speaks a short sentence in the app's language: coaching cues during a set and the headline of a review.
/// It ducks other audio while it talks and gives it back afterwards. The caller decides whether voice cues
/// are wanted (`SettingKey.voiceCues`).
///
/// Everything that touches AVFoundation (the audio session, the voice lookup, the synthesizer) lives in an
/// actor, so none of it can stall the main thread: activating an audio session and finding a voice can take
/// seconds, and the live set must keep drawing meanwhile.
@MainActor
final class CuePlayer {
    private let engine: SpeechEngine

    init() {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        engine = SpeechEngine(voiceLanguage: language.hasPrefix("zh") ? "zh-CN" : "en-US")
    }

    /// Speaks `text`, cutting off an earlier sentence that is still playing.
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let engine = engine
        Task { await engine.speak(trimmed) }
    }

    func stop() {
        let engine = engine
        Task { await engine.stop() }
    }
}

private actor SpeechEngine {
    private let voiceLanguage: String
    private var synthesizer: AVSpeechSynthesizer?
    private var delegate: Delegate?

    init(voiceLanguage: String) {
        self.voiceLanguage = voiceLanguage
    }

    func speak(_ text: String) {
        let synthesizer = makeSynthesizerIfNeeded()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        activateAudio()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguage)
        synthesizer.speak(utterance)
    }

    func stop() {
        guard let synthesizer else { return }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        deactivateAudio()
    }

    fileprivate func utteranceEnded() {
        if synthesizer?.isSpeaking != true { deactivateAudio() }
    }

    private func makeSynthesizerIfNeeded() -> AVSpeechSynthesizer {
        if let synthesizer { return synthesizer }
        let made = AVSpeechSynthesizer()
        let delegate = Delegate { [weak self] in
            guard let self else { return }
            Task { await self.utteranceEnded() }
        }
        made.delegate = delegate
        synthesizer = made
        self.delegate = delegate
        return made
    }

    private func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
    }

    private func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        private let onEnd: @Sendable () -> Void

        init(onEnd: @escaping @Sendable () -> Void) {
            self.onEnd = onEnd
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            onEnd()
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            onEnd()
        }
    }
}

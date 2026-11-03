import Testing
@testable import AppLogic

@Suite("Speech voice choice")
struct SpeechVoiceChoiceTests {
    private func voice(_ id: String, _ language: String, _ quality: SpeechVoiceQuality, novelty: Bool = false) -> SpeechVoiceCandidate {
        SpeechVoiceCandidate(identifier: id, language: language, quality: quality, isNoveltyOrPersonal: novelty)
    }

    private var installed: [SpeechVoiceCandidate] {
        [
            voice("samantha.compact", "en-US", .standard),
            voice("samantha.enhanced", "en-US", .enhanced),
            voice("zoe.premium", "en-US", .premium),
            voice("daniel.premium", "en-GB", .premium),
            voice("tingting.compact", "zh-CN", .standard),
            voice("lilian.enhanced", "zh-CN", .enhanced),
            voice("meijia.premium", "zh-TW", .premium),
        ]
    }

    @Test("premium beats enhanced beats standard, per language")
    func qualityOrder() {
        #expect(SpeechVoiceChoice.best(for: "en-US", among: installed)?.identifier == "zoe.premium")
        #expect(SpeechVoiceChoice.best(for: "zh-CN", among: installed)?.identifier == "lilian.enhanced")
        #expect(SpeechVoiceChoice.best(for: "en-US", among: Array(installed.prefix(2)))?.identifier == "samantha.enhanced")
        #expect(SpeechVoiceChoice.best(for: "en-US", among: Array(installed.prefix(1)))?.identifier == "samantha.compact")
    }

    @Test("only the requested language counts, so a premium voice of another region is not used")
    func exactLanguage() {
        let onlyTaiwan = [voice("meijia.premium", "zh-TW", .premium), voice("daniel.premium", "en-GB", .premium)]
        #expect(SpeechVoiceChoice.best(for: "zh-CN", among: onlyTaiwan) == nil)
        #expect(SpeechVoiceChoice.best(for: "en-US", among: onlyTaiwan) == nil)
        #expect(SpeechVoiceChoice.best(for: "en_us", among: installed)?.identifier == "zoe.premium", "tag spelling does not matter")
    }

    @Test("novelty and personal voices are never chosen, however good they are")
    func noNovelty() {
        let voices = [voice("bubbles", "en-US", .premium, novelty: true), voice("samantha.compact", "en-US", .standard)]
        #expect(SpeechVoiceChoice.best(for: "en-US", among: voices)?.identifier == "samantha.compact")
        #expect(SpeechVoiceChoice.best(for: "en-US", among: [voice("bubbles", "en-US", .standard, novelty: true)]) == nil)
    }

    @Test("equally good voices: the system default first, then a stable order")
    func ties() {
        let voices = [voice("b", "en-US", .standard), voice("a", "en-US", .standard), voice("c", "en-US", .standard)]
        #expect(SpeechVoiceChoice.best(for: "en-US", among: voices, systemDefaultIdentifier: "c")?.identifier == "c")
        #expect(SpeechVoiceChoice.best(for: "en-US", among: voices, systemDefaultIdentifier: "missing")?.identifier == "a")
        #expect(SpeechVoiceChoice.best(for: "en-US", among: voices.reversed())?.identifier == "a")
        // The system default only breaks ties: a better voice still wins over it.
        let better = voices + [voice("z", "en-US", .enhanced)]
        #expect(SpeechVoiceChoice.best(for: "en-US", among: better, systemDefaultIdentifier: "c")?.identifier == "z")
    }

    @Test("no voices at all gives nil")
    func empty() {
        #expect(SpeechVoiceChoice.best(for: "en-US", among: []) == nil)
    }
}

import AVFoundation

/// Reads text aloud with the system's speech voices. Nothing leaves the Mac.
@MainActor
final class Pronouncer {
    static let shared = Pronouncer()

    private let synthesizer = AVSpeechSynthesizer()

    /// The BCP 47 tag of the voice to read `text` with, from its detected language.
    /// nil means the system picks a voice, which is right for languages not listed here.
    nonisolated static func voiceLanguage(for text: String) -> String? {
        switch LanguageDetector.detect(text)?.code {
        case "zh": return "zh-CN"
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        default: return nil
        }
    }

    /// Stops any speech in progress, then reads `text`.
    func speak(_ text: String) {
        let spoken = text.trimmed
        guard !spoken.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: spoken)
        if let tag = Self.voiceLanguage(for: spoken) {
            utterance.voice = AVSpeechSynthesisVoice(language: tag)
        }
        synthesizer.speak(utterance)
    }
}

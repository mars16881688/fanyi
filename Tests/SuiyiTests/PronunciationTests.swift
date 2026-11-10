import Foundation
import Testing
@testable import Suiyi

@Suite("Pronunciation")
struct PronunciationTests {
    @Test("Each working language maps to its voice", arguments: [
        ("Could we move the meeting to Thursday?", "en-US"),
        ("我们周四开会可以吗？", "zh-CN"),
        ("明日の会議は何時からですか？", "ja-JP"),
        ("내일 회의는 몇 시에 시작하나요?", "ko-KR"),
        ("我哋聽日開會得唔得？", "zh-HK"),
    ])
    func voiceLanguage(text: String, expected: String) {
        #expect(Pronouncer.voiceLanguage(for: text) == expected)
    }

    @Test("Empty text has no voice")
    func emptyText() {
        #expect(Pronouncer.voiceLanguage(for: "   ") == nil)
    }

    @Test("The reading prompt carries the selected text as the user message")
    func promptCarriesText() {
        let messages = Prompts.pronunciation(text: "schedule", labelsIn: .chinese)
        #expect(messages.count == 2)
        #expect(messages[0].role == "system")
        #expect(messages[0].content.contains("IPA"))
        #expect(messages[0].content.contains("Simplified Chinese"))
        #expect(messages[1].role == "user")
        #expect(messages[1].content == "schedule")
    }
}

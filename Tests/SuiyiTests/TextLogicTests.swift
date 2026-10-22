import Foundation
import Testing
@testable import Suiyi

@Suite("LanguageDetector")
struct LanguageDetectorTests {
    @Test("Auto: English goes to Chinese")
    func englishToChinese() {
        let direction = LanguageDetector.direction(for: "Could we move the meeting to Thursday?", preference: .auto)
        #expect(direction.sourceLabel == "EN")
        #expect(direction.target == .simplifiedChinese)
    }

    @Test("Auto: Chinese goes to English")
    func chineseToEnglish() {
        let direction = LanguageDetector.direction(for: "我们周四开会可以吗？", preference: .auto)
        #expect(direction.sourceLabel == "中文")
        #expect(direction.target == .english)
    }

    @Test("Auto: Japanese goes to Chinese")
    func japaneseToChinese() {
        let direction = LanguageDetector.direction(for: "明日の会議は何時からですか？", preference: .auto)
        #expect(direction.sourceLabel == "日本語")
        #expect(direction.target == .simplifiedChinese)
    }

    @Test("A fixed target equal to the source flips to the other side")
    func fixedTargetFlips() {
        let direction = LanguageDetector.direction(for: "The build passed on CI today.", preference: .english)
        #expect(direction.target == .simplifiedChinese)
        let toJapanese = LanguageDetector.direction(for: "The build passed on CI today.", preference: .japanese)
        #expect(toJapanese.target == .japanese)
    }

    @Test("Script counting")
    func counts() {
        let counts = LanguageDetector.scriptCounts("Hi 你好 カナ 한")
        #expect(counts.latin == 2)
        #expect(counts.han == 2)
        #expect(counts.kana == 2)
        #expect(counts.hangul == 1)
    }
}

@Suite("Prompts")
struct PromptTests {
    private let context = AppContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                     windowTitle: "#release", surrounding: "QA signed off.", scene: .chat)

    @Test("Short phrase detection", arguments: [
        ("ship it", true), ("上线", true), ("This sentence clearly has more than four words", false),
        ("line one\nline two", false), ("", false), ("这是一个比较长的中文句子", false),
    ])
    func shortPhrase(text: String, expected: Bool) {
        #expect(Prompts.isShortPhrase(text) == expected)
    }

    @Test("Translate prompt carries target, context and the raw text")
    func translatePrompt() {
        let direction = TranslationDirection(sourceLabel: "EN", target: .simplifiedChinese)
        let messages = Prompts.translate(text: "ship it Friday", direction: direction, context: context, shortPhrase: false)
        #expect(messages.count == 2)
        #expect(messages[0].role == "system")
        #expect(messages[0].content.contains("Simplified Chinese"))
        #expect(messages[0].content.contains("#release"))
        #expect(messages[0].content.contains("QA signed off."))
        #expect(messages[0].content.contains("Never answer it"))
        #expect(messages[1].content == "ship it Friday")
    }

    @Test("Rewrite prompt asks for the three tagged blocks")
    func rewritePrompt() {
        let system = Prompts.rewrite(text: "我想问一下进展", context: context)[0].content
        for tag in ["[简洁]", "[正式]", "[口语]"] { #expect(system.contains(tag)) }
    }

    @Test("Copy uses only the first line of a short-term translation")
    func translationOutput() {
        #expect(TranslationOutput.primary(" 上线 \n指发布到生产环境", isTranslation: true, shortPhrase: true) == "上线")
        #expect(TranslationOutput.primary("第一行\n第二行", isTranslation: true, shortPhrase: false) == "第一行\n第二行")
        #expect(TranslationOutput.primary("a\nb", isTranslation: false, shortPhrase: true) == "a\nb")
    }
}

@Suite("RewriteParser")
struct RewriteParserTests {
    @Test("Parses the three tagged blocks")
    func basic() throws {
        let raw = "[简洁] 进展如何？\n[正式] 请问目前进展如何？\n[口语] 咋样了？"
        let variants = try #require(RewriteParser.parse(raw))
        #expect(variants.map(\.title) == ["更简洁", "更正式", "更口语"])
        #expect(variants[1].text == "请问目前进展如何？")
    }

    @Test("Tolerates markdown, full-width brackets and multi-line blocks")
    func tolerant() throws {
        let raw = "- **【简洁】**：第一行\n第二行\n* [formal] Formal one\n> [口语] casual"
        let variants = try #require(RewriteParser.parse(raw))
        #expect(variants.count == 3)
        #expect(variants[0].text == "第一行\n第二行")
        #expect(variants[1].text == "Formal one")
    }

    @Test("Returns nil when no tag is present")
    func noTags() {
        #expect(RewriteParser.parse("just some text") == nil)
        #expect(RewriteParser.parse("[简洁]   ") == nil)
    }
}

@Suite("Settings helpers")
struct SettingsTests {
    @Test("Excluded bundle IDs accept mixed separators and case")
    func excluded() {
        let set = AppSettings.parseExcluded("com.A.one, com.b.two，com.c.three\n  com.d.four  ")
        #expect(set == ["com.a.one", "com.b.two", "com.c.three", "com.d.four"])
        #expect(AppSettings.parseExcluded("  ").isEmpty)
    }

    @Test("Scene classification", arguments: [
        ("com.tinyspeck.slackmacgap", SceneKind.chat), ("com.alibaba.DingTalkMac", .chat),
        ("com.apple.Terminal", .code), ("com.apple.mail", .email), ("com.google.Chrome", .browser),
        ("com.example.unknown", .document),
    ])
    func scenes(bundleID: String, expected: SceneKind) {
        #expect(SceneKind.forBundleID(bundleID) == expected)
        #expect(SceneKind.forBundleID(nil) == .document)
    }
}

@Suite("AgentIntegration")
struct AgentIntegrationTests {
    @Test("Strips the current block and keeps surrounding text")
    func stripsCurrent() {
        let text = "前文\n\n\(AgentIntegration.begin)\n@~/.suiyi/profile.md\n\(AgentIntegration.end)\n后文"
        let stripped = AgentIntegration.strippingBlock(text)
        #expect(!stripped.contains("suiyi:begin"))
        #expect(stripped.contains("前文") && stripped.contains("后文"))
    }

    @Test("Recognises blocks written by Fanyi before the rename")
    func stripsLegacy() {
        let text = "a\n\(AgentIntegration.legacyBegin)\n@~/.fanyi/profile.md\n\(AgentIntegration.legacyEnd)\nb"
        #expect(AgentIntegration.strippingBlock(text) == "a\n\nb")
    }

    @Test("New blocks point at ~/.suiyi")
    func newPaths() {
        for file in AgentIntegration.files {
            #expect(file.content.contains("~/.suiyi/profile.md"))
            #expect(!file.content.contains("Fanyi"))
        }
    }
}

@Suite("HistoryEntry")
struct HistoryEntryTests {
    @Test("Encodes with snake_case keys")
    func encoding() throws {
        let entry = HistoryEntry(mode: "reply", appBundleID: "com.x", appName: "X", original: "hi",
                                 translation: "你好", replyZH: "好", replyEN: "OK")
        let json = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        for key in ["app_bundle_id", "app_name", "reply_zh", "reply_en", "timestamp"] {
            #expect(json.contains("\"\(key)\""))
        }
    }
}

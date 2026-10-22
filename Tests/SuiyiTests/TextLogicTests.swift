import Foundation
import Testing
@testable import Suiyi

@Suite("LanguageDetector")
struct LanguageDetectorTests {
    private static let english = "Could we move the meeting to Thursday?"
    private static let chinese = "我们周四开会可以吗？"
    private static let japanese = "明日の会議は何時からですか？"

    @Test("Detects the three working languages")
    func detects() {
        #expect(LanguageDetector.detect(Self.english) == .english)
        #expect(LanguageDetector.detect(Self.chinese) == .chinese)
        #expect(LanguageDetector.detect(Self.japanese) == .japanese)
        #expect(LanguageDetector.detect("   ") == nil)
    }

    @Test("Any pair: foreign text goes into my language, mine goes out", arguments: [
        // (text, mine, outgoing, expected target)
        (english, Language.chinese, Language.english, Language.chinese),
        (japanese, .chinese, .english, .chinese),
        (chinese, .chinese, .english, .english),
        (chinese, .chinese, .japanese, .japanese),
        (chinese, .english, .chinese, .english),
        (japanese, .english, .chinese, .english),
        (english, .english, .japanese, .japanese),
        (english, .japanese, .english, .japanese),
        (chinese, .japanese, .english, .japanese),
        (japanese, .japanese, .chinese, .chinese),
    ])
    func pairs(text: String, mine: Language, outgoing: Language, expected: Language) {
        #expect(LanguageDetector.direction(for: text, mine: mine, outgoing: outgoing).target == expected)
    }

    @Test("Replies go back in the sender's language")
    func replies() throws {
        let fromJapanese = LanguageDetector.direction(for: Self.japanese, mine: .chinese, outgoing: .english)
        let reply = try #require(LanguageDetector.replyDirection(for: fromJapanese, mine: .chinese))
        #expect(reply.source == .chinese && reply.target == .japanese)

        let fromChinese = LanguageDetector.direction(for: Self.chinese, mine: .english, outgoing: .japanese)
        #expect(try #require(LanguageDetector.replyDirection(for: fromChinese, mine: .english)).target == .chinese)

        let outgoing = LanguageDetector.direction(for: Self.chinese, mine: .chinese, outgoing: .english)
        #expect(LanguageDetector.replyDirection(for: outgoing, mine: .chinese) == nil)
        let unknown = TranslationDirection(source: nil, target: .chinese)
        #expect(LanguageDetector.replyDirection(for: unknown, mine: .chinese) == nil)
    }

    @Test("NaturalLanguage mapping and prompt names")
    func mapping() {
        #expect(Language(.traditionalChinese) == .chinese)
        #expect(Language(.simplifiedChinese) == .chinese)
        #expect(Language(.undetermined) == nil)
        #expect(Language(.french)?.code == "fr")
        #expect(Language(code: "fr").promptName == "French")
        #expect(Language.japanese.promptName.contains("Japanese"))
        #expect(Language.selectable == [.chinese, .english, .japanese])
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

@Suite("Language settings")
struct LanguageSettingsTests {
    @Test("Stored choices win")
    func stored() {
        let result = AppSettings.languages(mine: "ja", outgoing: "zh", legacyTarget: "auto", preferred: ["en-US"])
        #expect(result.mine == .japanese && result.outgoing == .chinese)
    }

    @Test("Migrates the old targetLanguage setting", arguments: [
        ("auto", Language.chinese, Language.english),
        ("simplifiedChinese", .chinese, .english),
        ("english", .english, .chinese),
        ("japanese", .japanese, .english),
    ])
    func legacy(raw: String, mine: Language, outgoing: Language) {
        let result = AppSettings.languages(mine: nil, outgoing: nil, legacyTarget: raw, preferred: ["fr-FR"])
        #expect(result.mine == mine && result.outgoing == outgoing)
    }

    @Test("Fresh installs follow the system language", arguments: [
        (["ja-JP", "en-US"], Language.japanese, Language.english),
        (["zh-Hans-CN"], .chinese, .english),
        (["en-GB"], .english, .chinese),
        (["de-DE"], .english, .chinese),
    ])
    func system(preferred: [String], mine: Language, outgoing: Language) {
        let result = AppSettings.languages(mine: nil, outgoing: nil, legacyTarget: nil, preferred: preferred)
        #expect(result.mine == mine && result.outgoing == outgoing)
    }

    @Test("Outgoing never equals my language; unknown codes are ignored")
    func neverSame() {
        #expect(AppSettings.languages(mine: "en", outgoing: "en", legacyTarget: nil, preferred: []).outgoing == .chinese)
        #expect(AppSettings.languages(mine: "zh", outgoing: "zh", legacyTarget: nil, preferred: []).outgoing == .english)
        let unknown = AppSettings.languages(mine: "xx", outgoing: "yy", legacyTarget: nil, preferred: ["ja"])
        #expect(unknown.mine == .japanese && unknown.outgoing == .english)
    }

    @Test("Interface language resolution", arguments: [
        (["zh-Hant-TW"], UILanguage.zh), (["ja"], .ja), (["en-US"], .en), (["ko-KR", "ja-JP"], .ja), ([String](), .en),
    ])
    func uiLanguage(preferred: [String], expected: UILanguage) {
        #expect(UILanguage.resolve(preferred) == expected)
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
        let direction = TranslationDirection(source: .english, target: .chinese)
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
        #expect(variants.map(\.title) == (0..<3).map(RewriteParser.title(at:)))
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

import AppKit
import Foundation
import Testing
@testable import Suiyi

/// Everything that sets UILanguage.override lives here, serialized, so no
/// other test observes a switched interface language.
///
/// Renders the floating UI in each interface language, light and dark.
/// Always checks that rendering works; writes PNGs when SUIYI_SNAPSHOT_DIR is set.
@Suite("Localized UI", .serialized)
@MainActor
struct LocalizedUITests {
    private static let languages: [UILanguage] = [.zh, .en, .ja]

    init() {
        _ = NSApplication.shared
        FloatingPanel.isHeadless = true
    }

    private func withLanguage(_ language: UILanguage, _ body: () throws -> Void) rethrows {
        UILanguage.override = language
        defer { UILanguage.override = nil }
        try body()
    }

    // MARK: Strings

    @Test("Error messages are translated")
    func errorStrings() {
        withLanguage(.zh) {
            #expect(LLMError.userMessage(for: URLError(.notConnectedToInternet)).contains("网络未连接"))
            #expect(LLMError.hint(forStatus: 402)?.contains("余额") == true)
        }
        withLanguage(.en) {
            #expect(LLMError.userMessage(for: URLError(.timedOut)).contains("timed out"))
            #expect(LLMError.missingKey.errorDescription?.contains("API key") == true)
        }
        withLanguage(.ja) {
            #expect(LLMError.userMessage(for: URLError(.cannotFindHost)).contains("Base URL"))
            #expect(LLMError.hint(forStatus: 429)?.contains("リクエスト") == true)
        }
    }

    @Test("Language names and rewrite titles follow the interface")
    func names() {
        withLanguage(.zh) {
            #expect(Language.japanese.uiName == "日文")
            #expect(RewriteParser.title(at: 0) == "更简洁")
            #expect(TranslationDirection(source: nil, target: .chinese).sourceLabel == "自动")
        }
        withLanguage(.en) {
            #expect(Language.chinese.uiName == "Chinese")
            #expect(RewriteParser.title(at: 2) == "Casual")
        }
        withLanguage(.ja) {
            #expect(Language.english.uiName == "英語")
            #expect(RewriteParser.title(at: 1) == "丁寧")
        }
    }

    // MARK: Snapshots

    private func render(_ view: NSView, appearance: NSAppearance.Name) throws -> NSImage {
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let dark = appearance == .darkAqua
        let size = NSSize(width: view.bounds.width + 40, height: view.bounds.height + 40)
        return NSImage(size: size, flipped: false) { rect in
            // Stand-in for the blurred desktop behind the glass.
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.9, alpha: 1)).setFill()
            rect.fill()
            (dark ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: view.bounds.width, height: view.bounds.height),
                         xRadius: 20, yRadius: 20).fill()
            rep.draw(in: NSRect(x: 20, y: 20, width: view.bounds.width, height: view.bounds.height))
            return true
        }
    }

    private func save(_ image: NSImage, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["SUIYI_SNAPSHOT_DIR"] else { return }
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func check(_ view: NSView?, _ name: String, _ language: UILanguage) throws {
        let view = try #require(view)
        #expect(view.bounds.width > 0 && view.bounds.height > 0)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try save(try render(view, appearance: appearance), "\(name)-\(language)-\(suffix)")
        }
    }

    @Test("Anchor bubble", arguments: languages)
    func anchor(language: UILanguage) throws {
        try withLanguage(language) {
            let anchor = AnchorController()
            anchor.show(at: NSPoint(x: 400, y: 400))
            try check(anchor.contentView, "anchor-bubble", language)
            anchor.hide()
        }
    }

    @Test("Clicking the bubble translates straight away")
    func bubbleTranslates() throws {
        let anchor = AnchorController()
        var picked: [ActionKind] = []
        anchor.onPick = { picked.append($0) }
        anchor.show(at: NSPoint(x: 400, y: 400))
        let button = try #require(findButtons(in: anchor.contentView).first)
        button.performClick(nil)
        #expect(picked == [.translate])
    }

    @Test("Tabs switch between translate and rewrite")
    func tabs() throws {
        withLanguage(.zh) {
            let card = ResultPanelController()
            var switched: [ActionKind] = []
            card.onSwitchKind = { switched.append($0) }
            card.present(kind: .translate, header: "EN → 中文  ·  Slack", editable: false,
                         shortPhrase: false, at: NSPoint(x: 400, y: 700))
            let buttons = findButtons(in: card.contentView)
            let translate = buttons.first { $0.title == "翻译" }
            let rewrite = buttons.first { $0.title == "改写" }
            #expect(translate != nil && rewrite != nil)
            translate?.performClick(nil)   // already selected: no request
            rewrite?.performClick(nil)
            #expect(switched == [.rewrite])
            #expect((rewrite as? GlassButton)?.style == .plain)   // selection follows the re-present

            // AppDelegate re-presents in place for the other tab.
            let before = card.frame
            card.present(kind: .rewrite, header: "保持原语言  ·  Slack", editable: false, shortPhrase: false,
                         at: NSPoint(x: before.minX, y: before.maxY), keepPosition: true)
            #expect((rewrite as? GlassButton)?.style == .secondary)
            #expect((translate as? GlassButton)?.style == .plain)
            #expect(card.frame.minX == before.minX && card.frame.maxY == before.maxY)

            card.showNotice("x", at: NSPoint(x: 400, y: 700))   // notices have no tabs
            #expect(rewrite?.superview?.isHidden == true)
            card.hide()
        }
    }

    private func findButtons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        if let button = view as? NSButton { return [button] }
        return view.subviews.flatMap { findButtons(in: $0) }
    }

    @Test("Translation card with a reply back to Japanese", arguments: languages)
    func translationCard(language: UILanguage) throws {
        try withLanguage(language) {
            let card = ResultPanelController()
            let direction = TranslationDirection(source: .japanese, target: .chinese)
            card.present(kind: .translate, header: "\(direction.sourceLabel) → \(direction.target.shortLabel)  ·  Slack",
                         editable: false, shortPhrase: false, at: NSPoint(x: 400, y: 700),
                         reply: LanguageDetector.replyDirection(for: direction, mine: .chinese))
            card.append("明天的会议几点开始？我想提前准备一下资料。")
            card.finish()
            try check(card.contentView, "card-translate", language)
            card.expandReply(nil)
            try check(card.contentView, "card-reply", language)
            card.hide()
        }
    }

    @Test("Rewrite card with replace", arguments: languages)
    func rewriteCard(language: UILanguage) throws {
        try withLanguage(language) {
            let card = ResultPanelController()
            card.present(kind: .rewrite, header: L("保持原语言", "Same language", "同じ言語のまま") + "  ·  Notes",
                         editable: true, shortPhrase: false, at: NSPoint(x: 400, y: 700))
            card.append("[简洁] 这件事进展如何？\n[正式] 请问该事项目前进展如何？\n[口语] 那件事现在咋样了？")
            card.finish()
            try check(card.contentView, "card-rewrite", language)
            card.hide()
        }
    }

    @Test("Error card", arguments: languages)
    func errorCard(language: UILanguage) throws {
        try withLanguage(language) {
            let card = ResultPanelController()
            card.present(kind: .translate, header: "EN → 中文  ·  Safari", editable: false,
                         shortPhrase: false, at: NSPoint(x: 400, y: 700))
            card.showError(LLMError.http(402, #"{"error":"Insufficient Balance"}"#).errorDescription ?? "")
            try check(card.contentView, "card-error", language)
            card.hide()
        }
    }
}

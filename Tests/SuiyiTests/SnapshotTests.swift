import AppKit
import Foundation
import Testing
@testable import Suiyi

/// Renders the floating UI in light and dark. Always checks that rendering
/// works; writes PNGs when SUIYI_SNAPSHOT_DIR is set, for visual review.
@Suite("UI snapshots")
@MainActor
struct SnapshotTests {
    init() {
        FloatingPanel.isHeadless = true
    }

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

    private func check(_ view: NSView?, _ name: String) throws {
        let view = try #require(view)
        #expect(view.bounds.width > 0 && view.bounds.height > 0)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try save(try render(view, appearance: appearance), "\(name)-\(suffix)")
        }
    }

    @Test("Anchor bubble and expanded choices")
    func anchor() throws {
        let anchor = AnchorController()
        anchor.show(at: NSPoint(x: 400, y: 400))
        try check(anchor.contentView, "anchor-bubble")
        anchor.expand()
        try check(anchor.contentView, "anchor-choices")
        anchor.hide()
    }

    @Test("Translation card, collapsed and with the reply composer")
    func translationCard() throws {
        let card = ResultPanelController()
        card.present(kind: .translate, header: "EN → 中文  ·  Google Chrome", editable: false,
                     shortPhrase: false, at: NSPoint(x: 400, y: 700), offersReply: true)
        card.append("从任何兼容 MCP 的 AI 客户端整理 iPhone 主屏幕。用自然语言移动应用和网页剪辑、创建文件夹、重新排列页面。")
        card.finish()
        try check(card.contentView, "card-translate")
        card.expandReply(nil)
        try check(card.contentView, "card-reply")
        card.hide()
    }

    @Test("Rewrite card with replace")
    func rewriteCard() throws {
        let card = ResultPanelController()
        card.present(kind: .rewrite, header: "保持原语言  ·  备忘录", editable: true,
                     shortPhrase: false, at: NSPoint(x: 400, y: 700))
        card.append("[简洁] 这件事进展如何？\n[正式] 请问该事项目前进展如何？\n[口语] 那件事现在咋样了？")
        card.finish()
        try check(card.contentView, "card-rewrite")
        card.hide()
    }

    @Test("Error card")
    func errorCard() throws {
        let card = ResultPanelController()
        card.present(kind: .translate, header: "EN → 中文  ·  Safari", editable: false,
                     shortPhrase: false, at: NSPoint(x: 400, y: 700))
        card.showError(LLMError.http(402, #"{"error":"Insufficient Balance"}"#).errorDescription ?? "")
        try check(card.contentView, "card-error")
        card.hide()
    }
}

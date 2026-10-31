import AppKit

enum ActionKind {
    case translate
    case rewrite
    /// Reads the selection aloud and explains how to pronounce it. Has no tab.
    case pronounce
}

/// The small round button shown after a mouse selection. One click translates;
/// rewriting is a tab on the result card. Hovering only keeps it from hiding,
/// so nothing is sent to the model without an explicit click. A right-click (or
/// two-finger click) copies the selection instead (0.2.1.k.06); nothing is sent.
@MainActor
final class AnchorController: NSObject {
    var onPick: (@MainActor (ActionKind) -> Void)?
    var onCopy: (@MainActor () -> Void)?
    /// 0.2.1.k.11: called after the button appears or goes (the global key monitor follows it).
    var onVisibilityChange: (@MainActor () -> Void)?
    private(set) var referencePoint = NSPoint.zero

    private static let bubbleSize: CGFloat = 30
    private static let autoHideSeconds: UInt64 = 4

    private let panel: FloatingPanel
    private let root: HoverView
    private let circle: NSView
    private let bubble: GlassButton

    private var hideTask: Task<Void, Never>?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    /// For snapshot tests.
    var contentView: NSView? { panel.contentView }

    override init() {
        let size = AnchorController.bubbleSize
        let square = NSRect(x: 0, y: 0, width: size, height: size)
        panel = FloatingPanel.make(size: square.size, allowsKey: false)
        root = HoverView(frame: square)
        circle = RoundedMaterialView(frame: square)
        bubble = GlassButton(title: "", symbol: "character.bubble", style: .plain, target: nil, action: nil)
        super.init()
        configure()
    }

    private func configure() {
        let size = AnchorController.bubbleSize
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        (circle as? RoundedMaterialView)?.radius = size / 2
        root.addSubview(circle)

        bubble.frame = NSRect(x: 0, y: 0, width: size, height: size)
        bubble.tint = .controlAccentColor
        bubble.iconPointSize = 15
        bubble.setAccessibilityLabel(L("随译：翻译", "Suiyi: Translate", "Suiyi：翻訳", "Suiyi: 번역"))
        bubble.toolTip = L("翻译（⌥⌘T）· 右键或双指按下：复制", "Translate (⌥⌘T) · Right-click or two-finger click: Copy",
                           "翻訳（⌥⌘T）· 右クリック／2 本指クリック：コピー", "번역 (⌥⌘T) · 오른쪽 클릭 또는 두 손가락 클릭: 복사")
        bubble.target = self
        bubble.action = #selector(bubbleClicked(_:))
        bubble.onSecondaryClick = { [weak self] in self?.copyClicked() }
        circle.addSubview(bubble)

        root.onEnter = { [weak self] in self?.hideTask?.cancel() }
        root.onExit = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.scheduleHide()
        }
    }

    func show(at point: NSPoint) {
        hideTask?.cancel()
        bubble.symbolName = "character.bubble"   // a copy checkmark from just before may still be showing
        referencePoint = point
        let size = AnchorController.bubbleSize
        let rect = NSRect(x: point.x + 8, y: point.y - 8 - size, width: size, height: size)
        panel.setFrame(ScreenGeometry.fit(rect, reference: point), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        scheduleHide()
        onVisibilityChange?()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        if wasVisible { onVisibilityChange?() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: AnchorController.autoHideSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.hide()
        }
    }

    @objc private func bubbleClicked(_ sender: Any?) {
        hide()
        onPick?(.translate)
    }

    /// Copies, then shows a checkmark for a moment so the copy is visible before the button goes.
    private func copyClicked() {
        hideTask?.cancel()
        onCopy?()
        bubble.symbolName = "checkmark"
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.hide()
            self.bubble.symbolName = "character.bubble"
        }
    }
}

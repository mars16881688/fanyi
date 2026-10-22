import AppKit

enum ActionKind {
    case translate
    case rewrite
}

/// The small round button shown after a mouse selection. One click translates;
/// rewriting is a tab on the result card. Hovering only keeps it from hiding,
/// so nothing is sent to the model without an explicit click.
@MainActor
final class AnchorController: NSObject {
    var onPick: (@MainActor (ActionKind) -> Void)?
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
        bubble.toolTip = L("翻译（⌥⌘T）", "Translate (⌥⌘T)", "翻訳（⌥⌘T）", "번역 (⌥⌘T)")
        bubble.target = self
        bubble.action = #selector(bubbleClicked(_:))
        circle.addSubview(bubble)

        root.onEnter = { [weak self] in self?.hideTask?.cancel() }
        root.onExit = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.scheduleHide()
        }
    }

    func show(at point: NSPoint) {
        hideTask?.cancel()
        referencePoint = point
        let size = AnchorController.bubbleSize
        let rect = NSRect(x: point.x + 8, y: point.y - 8 - size, width: size, height: size)
        panel.setFrame(ScreenGeometry.fit(rect, reference: point), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        scheduleHide()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel.orderOut(nil)
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
}
